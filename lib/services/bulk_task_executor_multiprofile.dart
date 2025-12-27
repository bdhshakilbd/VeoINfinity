import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/bulk_task.dart';
import '../models/scene_data.dart';
import 'browser_video_generator.dart';
import 'profile_manager_service.dart';
import 'multi_profile_login_service.dart';
import '../utils/config.dart';

/// Manages execution of bulk video generation with multi-profile support
class BulkTaskExecutor {
  final Map<String, BulkTask> _runningTasks = {};
  final Map<String, List<SceneData>> _queueToGenerate = {};
  final Map<String, List<_ActiveVideo>> _activeVideos = {};
  final Map<String, int> _videoRetryCounts = {};
  final Map<String, bool> _generationComplete = {};
  
  // Track active videos per account (for concurrency limiting)
  final Map<String, int> _activeVideosByAccount = {};
  
  ProfileManagerService? _profileManager;
  MultiProfileLoginService? _loginService;
  
  Timer? _schedulerTimer;
  final Function(BulkTask)? onTaskStatusChanged;
  final Random _random = Random();
  
  // Multi-profile settings
  String? _email;
  String? _password;
  bool _multiProfileMode = false;
  
  BulkTaskExecutor({this.onTaskStatusChanged});

  /// Initialize multi-profile system
  Future<void> initializeMultiProfile({
    required int profileCount,
    required String email,
    required String password,
    String? profilesDirectory,
  }) async {
    _email = email;
    _password = password;
    _multiProfileMode = profileCount > 1;

    _profileManager = ProfileManagerService(
      profilesDirectory: profilesDirectory ?? AppConfig.profilesDir,
      baseDebugPort: AppConfig.debugPort,
    );

    _loginService = MultiProfileLoginService(profileManager: _profileManager!);

    // Login all profiles
    await _loginService!.loginAllProfiles(profileCount, email, password);

    print('\n[MULTI-PROFILE] ✓ Initialized with $profileCount profiles');
    print('[MULTI-PROFILE] Connected: ${_profileManager!.countConnectedProfiles()}');
  }

  /// Start the task scheduler
  void startScheduler(List<BulkTask> tasks) {
    _schedulerTimer?.cancel();
    _schedulerTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkScheduledTasks(tasks);
    });
  }

  void stopScheduler() {
    _schedulerTimer?.cancel();
  }

  /// Check and start scheduled tasks
  void _checkScheduledTasks(List<BulkTask> tasks) {
    for (var task in tasks) {
      if (task.status == TaskStatus.scheduled) {
        bool shouldStart = false;

        switch (task.scheduleType) {
          case TaskScheduleType.immediate:
            shouldStart = true;
            break;
            
          case TaskScheduleType.scheduledTime:
            if (task.scheduledTime != null && 
                DateTime.now().isAfter(task.scheduledTime!)) {
              shouldStart = true;
            }
            break;
            
          case TaskScheduleType.afterTask:
            if (task.afterTaskId != null) {
              final afterTask = tasks.firstWhere(
                (t) => t.id == task.afterTaskId,
                orElse: () => task,
              );
              if (afterTask.status == TaskStatus.completed) {
                shouldStart = true;
              }
            }
            break;
        }

        if (shouldStart) {
          startTask(task);
        }
      }
    }
  }

  /// Start executing a bulk task
  Future<void> startTask(BulkTask task) async {
    print('[TASK] ========================================');
    print('[TASK] START TASK: ${task.name}');
    print('[TASK] ========================================');
    
    if (_runningTasks.containsKey(task.id)) {
      print('[TASK] Task ${task.name} is already running');
      return;
    }

    task.status = TaskStatus.running;
    task.startedAt = DateTime.now();
    _runningTasks[task.id] = task;
    _queueToGenerate[task.id] = [];
    _activeVideos[task.id] = [];
    _videoRetryCounts.clear(); // Reset retry counts
    
    onTaskStatusChanged?.call(task);

    try {
      await _executeTask(task);
      
      task.status = TaskStatus.completed;
      task.completedAt = DateTime.now();
    } catch (e) {
      task.status = TaskStatus.failed;
      task.error = e.toString();
      task.completedAt = DateTime.now();
    } finally {
      _cleanup(task.id);
      onTaskStatusChanged?.call(task);
    }
  }
  
  /// Public method to trigger checking scheduled tasks immediately
  void checkScheduledTasksNow(List<BulkTask> tasks) {
    _checkScheduledTasks(tasks);
  }

  Future<void> _executeTask(BulkTask task) async {
    print('\n${'=' * 60}');
    print('BULK TASK: ${task.name}');
    print('Scenes: ${task.totalScenes}');
    print('Multi-Profile: $_multiProfileMode');
    print('=' * 60);

    // Check if multi-profile mode is enabled
    if (_multiProfileMode && _profileManager != null) {
      await _executeMultiProfileTask(task);
    } else {
      // Fall back to single-profile mode
      await _executeSingleProfileTask(task);
    }

    print('\n${'=' * 60}');
    print('TASK COMPLETE: ${task.name}');
    print('Completed: ${task.completedScenes}/${task.totalScenes}');
    print('Failed: ${task.failedScenes}');
    print('=' * 60);
  }

  /// Execute task with multi-profile concurrent generation
  Future<void> _executeMultiProfileTask(BulkTask task) async {
    print('\n[MULTI-PROFILE] Using concurrent generation across profiles');

    // Verify at least one profile is connected
    if (!_profileManager!.hasAnyConnectedProfile()) {
      throw Exception('No connected profiles available for generation');
    }

    // Initialize queue with all queued scenes
    final scenesToProcess = task.scenes.where((s) => s.status == 'queued').toList();
    _queueToGenerate[task.id] = List.from(scenesToProcess);
    _generationComplete[task.id] = false;

    // Determine concurrency limit
    final isRelaxedModel = task.model.contains('relaxed') || task.model.contains('fast');
    final maxConcurrent = isRelaxedModel ? 4 : 10;

    print('[CONCURRENT] Max concurrent: $maxConcurrent');
    print('[QUEUE] Initial queue size: ${_queueToGenerate[task.id]!.length}');

    // Start concurrent generation and polling
    await Future.wait([
      _runConcurrentGeneration(task, maxConcurrent),
      _runBatchPolling(task),
    ]);
  }

  /// Concurrent generation worker (PRODUCER)
  Future<void> _runConcurrentGeneration(BulkTask task, int maxConcurrent) async {
    print('\n[PRODUCER] Concurrent generation started');
    print('[CONCURRENT] Max concurrent per account: $maxConcurrent');

    while (_queueToGenerate[task.id]!.isNotEmpty || _activeVideos[task.id]!.isNotEmpty) {
      // Get current active count for this account (re-check each iteration)
      final accountEmail = _email ?? 'default';
      final currentActive = _activeVideosByAccount[accountEmail] ?? 0;
      
      // Fill up to maxConcurrent PER ACCOUNT
      while ((_activeVideosByAccount[accountEmail] ?? 0) < maxConcurrent && 
             _queueToGenerate[task.id]!.isNotEmpty) {
        
        // Check if relogin is in progress for any profile
        final reloggingProfiles = _profileManager!.getProfilesByStatus(ProfileStatus.relogging);
        if (reloggingProfiles.isNotEmpty) {
          print('[PRODUCER] Waiting for relogin to complete...');
          await Future.delayed(Duration(seconds: 5));
          continue;
        }

        // Get next available profile
        final profile = _profileManager!.getNextAvailableProfile();
        if (profile == null) {
          print('[PRODUCER] No available profiles, waiting...');
          await Future.delayed(Duration(seconds: 2));
          continue;
        }

        // Get next scene from queue
        final scene = _queueToGenerate[task.id]!.removeAt(0);
        
        // Increment account counter
        _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 0) + 1;
        print('[PRODUCER] Account active: ${_activeVideosByAccount[accountEmail]}/$maxConcurrent');
        
        // Start generation (don't await - fire and forget)
        _startSingleGeneration(task, scene, profile, accountEmail);

        // Delay between API requests to avoid rate limiting (2s minimum)
        await Future.delayed(Duration(seconds: 2));
      }

      // Wait before checking again
      await Future.delayed(Duration(seconds: 2));
    }

    _generationComplete[task.id] = true;
    print('[PRODUCER] All scenes processed');
  }

  /// Start generating a single video
  Future<void> _startSingleGeneration(
    BulkTask task,
    SceneData scene,
    ChromeProfile profile,
    String accountEmail,
  ) async {
    print('\n[GENERATE] Scene ${scene.sceneId} -> ${profile.name}');

    // Check retry limit
    final sceneId = scene.sceneId;
    final retryCount = _videoRetryCounts[sceneId.toString()] ?? 0;
    if (retryCount >= 3) {
      print('[GENERATE] Scene $sceneId exceeded max retries (3)');
      scene.status = 'failed';
      scene.error = 'Max retries exceeded';
      onTaskStatusChanged?.call(task);
      return;
    }

    try {
      scene.status = 'generating';
      scene.error = null;
      onTaskStatusChanged?.call(task);

      // Handle image uploads if needed
      String? startImageMediaId;
      String? endImageMediaId;

      if (scene.firstFramePath != null) {
        final uploadResult = await profile.generator!.uploadImage(
          scene.firstFramePath!,
          profile.accessToken!,
          aspectRatio: _aspectRatioToImageFormat(task.aspectRatio),
        );
        
        if (uploadResult is String) {
          startImageMediaId = uploadResult;
          scene.firstFrameMediaId = uploadResult;
        } else if (uploadResult is Map && uploadResult['error'] == true) {
          throw Exception(uploadResult['message'] ?? 'Image upload failed');
        }
      }

      if (scene.lastFramePath != null) {
        final uploadResult = await profile.generator!.uploadImage(
          scene.lastFramePath!,
          profile.accessToken!,
          aspectRatio: _aspectRatioToImageFormat(task.aspectRatio),
        );
        
        if (uploadResult is String) {
          endImageMediaId = uploadResult;
          scene.lastFrameMediaId = uploadResult;
        }
      }

      // Generate video
      final result = await profile.generator!.generateVideo(
        prompt: scene.prompt,
        accessToken: profile.accessToken!,
        aspectRatio: task.aspectRatio,
        model: task.model,
        startImageMediaId: startImageMediaId,
        endImageMediaId: endImageMediaId,
      );

      if (result == null) {
        throw Exception('No result from generateVideo');
      }

      // Check for 403 error
      if (result['status'] == 403) {
        print('[403] Scene $sceneId got 403 from ${profile.name}');
        _handle403Error(task, scene, profile, accountEmail);
        return;
      }

      // Check for 429 error (quota exhausted)
      if (result['status'] == 429) {
        print('[429] Scene $sceneId got 429 (quota exhausted)');
        _handle429Error(task, scene, accountEmail);
        return;
      }

      if (result['success'] != true) {
        throw Exception(result['error'] ?? 'Generation failed');
      }

      // Extract operation name
      final responseData = result['data'] as Map<String, dynamic>;
      final operations = responseData['operations'] as List?;
      if (operations == null || operations.isEmpty) {
        throw Exception('No operations in response');
      }

      final operation = operations[0] as Map<String, dynamic>;
      final operationName = operation['name'] as String?;
      if (operationName == null) {
        throw Exception('No operation name in response');
      }

      scene.operationName = operationName;
      scene.status = 'polling';
      onTaskStatusChanged?.call(task);

      // Add to active videos for batch polling
      _activeVideos[task.id]!.add(_ActiveVideo(
        scene: scene,
        sceneUuid: result['sceneId'] as String,
        profile: profile,
      ));

      print('[GENERATE] ✓ Scene $sceneId queued for polling');

    } catch (e) {
      print('[GENERATE] ✗ Scene ${scene.sceneId} error: $e');
      scene.status = 'failed';
      scene.error = e.toString();
      onTaskStatusChanged?.call(task);
      
      // Decrement account counter on failure
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    }
  }

  /// Handle 403 error: increment counter, trigger relogin, re-queue scene
  void _handle403Error(BulkTask task, SceneData scene, ChromeProfile profile, String accountEmail) {
    // Decrement account counter
    _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    
    // Increment 403 counter for this profile
    profile.consecutive403Count++;
    print('[403] ${profile.name} 403 count: ${profile.consecutive403Count}/3');

    // Increment retry count for this scene
    final sceneId = scene.sceneId.toString();
    _videoRetryCounts[sceneId] = (_videoRetryCounts[sceneId] ?? 0) + 1;

    // Trigger relogin if threshold reached
    if (profile.consecutive403Count >= 3 && _email != null && _password != null) {
      print('[403] ${profile.name} threshold reached, triggering relogin...');
      _loginService!.reloginProfile(profile, _email!, _password!);
    }

    // Re-queue scene at front for immediate retry
    scene.status = 'queued';
    scene.error = '403 error - retrying';
    _queueToGenerate[task.id]!.insert(0, scene);
    onTaskStatusChanged?.call(task);
    
    print('[403] Scene ${scene.sceneId} re-queued for retry');
  }

  /// Handle 429 error: decrement counter, wait before retry
  void _handle429Error(BulkTask task, SceneData scene, String accountEmail) {
    // Decrement account counter
    _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    print('[429] Account active after release: ${_activeVideosByAccount[accountEmail]}');
    
    // Increment retry count for this scene
    final sceneId = scene.sceneId.toString();
    _videoRetryCounts[sceneId] = (_videoRetryCounts[sceneId] ?? 0) + 1;

    // Re-queue scene with delay
    scene.status = 'queued';
    scene.error = '429 quota exhausted - waiting before retry';
    
    // Add to end of queue (not front) to give time for quota to recover
    _queueToGenerate[task.id]!.add(scene);
    onTaskStatusChanged?.call(task);
    
    print('[429] Scene ${scene.sceneId} re-queued (will retry after other scenes)');
    
    // Wait 30 seconds before allowing more generations
    Future.delayed(Duration(seconds: 30), () {
      print('[429] Quota cooldown complete, resuming...');
    });
  }

  /// Batch polling worker (CONSUMER)
  Future<void> _runBatchPolling(BulkTask task) async {
    print('\n[POLLER] Batch polling started');
    final Set<int> downloadingScenes = {};

    while (!_generationComplete[task.id]! || _activeVideos[task.id]!.isNotEmpty || downloadingScenes.isNotEmpty) {
      if (_activeVideos[task.id]!.isEmpty && downloadingScenes.isEmpty) {
        await Future.delayed(Duration(seconds: 1));
        continue;
      }

      // Random interval (5-10 seconds) to mimic human behavior
      final waitSeconds = 5 + _random.nextInt(6);
      print('[POLLER] Waiting ${waitSeconds}s before batch poll...');
      await Future.delayed(Duration(seconds: waitSeconds));

      await _pollAndUpdateActiveBatch(task, downloadingScenes);
    }

    // Final check: Wait for any remaining downloads to complete
    while (downloadingScenes.isNotEmpty) {
      print('[POLLER] Waiting for ${downloadingScenes.length} downloads to complete...');
      await Future.delayed(Duration(seconds: 2));
    }

    print('[POLLER] All videos polled and downloaded');
  }

  /// Poll all active videos in a single batch and update statuses
  Future<void> _pollAndUpdateActiveBatch(BulkTask task, Set<int> downloadingScenes) async {
    final activeList = _activeVideos[task.id]!;
    if (activeList.isEmpty) return;

    print('\n[BATCH POLL] Polling ${activeList.length} videos...');

    // Get any available profile for polling
    final profile = activeList.first.profile;
    if (profile.accessToken == null) {
      print('[BATCH POLL] No access token available');
      return;
    }

    // Build batch poll requests
    final pollRequests = activeList
        .map((v) => PollRequest(v.scene.operationName!, v.sceneUuid))
        .toList();

    try {
      final results = await profile.generator!.pollVideoStatusBatch(
        pollRequests,
        profile.accessToken!,
      );

      if (results == null) {
        print('[BATCH POLL] No results from batch poll');
        return;
      }

      // Process results
      for (var i = 0; i < results.length; i++) {
        final opData = results[i];
        final activeVideo = activeList[i];
        final scene = activeVideo.scene;

        final status = opData['status'] as String?;
        
        if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
            status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
          // Extract video URL
          String? videoUrl;
          if (opData.containsKey('operation')) {
            final metadata = (opData['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
            final video = metadata?['video'] as Map<String, dynamic>?;
            videoUrl = video?['fifeUrl'] as String?;
          }

          if (videoUrl != null) {
            // Download video (don't await) and track it
            downloadingScenes.add(scene.sceneId);
            _downloadVideo(task, scene, videoUrl, activeVideo, downloadingScenes);
          }
        } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
          scene.status = 'failed';
          scene.error = 'Generation failed on server';
          onTaskStatusChanged?.call(task);
          _activeVideos[task.id]!.remove(activeVideo);
          print('[BATCH POLL] Scene ${scene.sceneId} failed');
        }
      }
    } catch (e) {
      print('[BATCH POLL] Error: $e');
    }
  }

  /// Download a video file
  Future<void> _downloadVideo(
    BulkTask task,
    SceneData scene,
    String videoUrl,
    _ActiveVideo activeVideo,
    Set<int> downloadingScenes,
  ) async {
    try {
      print('[DOWNLOAD] Scene ${scene.sceneId} downloading...');
      scene.status = 'downloading';
      onTaskStatusChanged?.call(task);

      // Create output path (use outputFolder directly, don't nest with task.name)
      final projectFolder = task.outputFolder;
      await Directory(projectFolder).create(recursive: true);
      
      final outputPath = path.join(
        projectFolder,
        'scene_${scene.sceneId.toString().padLeft(4, '0')}.mp4',
      );

      final fileSize = await activeVideo.profile.generator!.downloadVideo(videoUrl, outputPath);

      scene.videoPath = outputPath;
      scene.downloadUrl = videoUrl;
      scene.fileSize = fileSize;
      scene.generatedAt = DateTime.now().toIso8601String();
      scene.status = 'completed';
      onTaskStatusChanged?.call(task);

      // Remove from active videos
      _activeVideos[task.id]!.remove(activeVideo);
      
      // Decrement account counter
      final accountEmail = _email ?? 'default';
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;

      print('[DOWNLOAD] ✓ Scene ${scene.sceneId} complete (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
      
      // Remove from downloading set
      downloadingScenes.remove(scene.sceneId);
    } catch (e) {
      print('[DOWNLOAD] ✗ Scene ${scene.sceneId} error: $e');
      scene.status = 'failed';
      
      // Remove from downloading set
      downloadingScenes.remove(scene.sceneId);
      scene.error = 'Download failed: $e';
      onTaskStatusChanged?.call(task);
      _activeVideos[task.id]!.remove(activeVideo);
      
      // Decrement account counter on failure
      final accountEmail = _email ?? 'default';
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    }
  }

  /// Execute task in single-profile mode (original behavior)
  Future<void> _executeSingleProfileTask(BulkTask task) async {
    // This maintains backward compatibility with the original single-profile Flow UI automation
    // [Previous implementation remains unchanged for now]
    throw UnimplementedError('Single-profile mode not yet migrated to new architecture');
  }

  String _aspectRatioToImageFormat(String videoAspectRatio) {
    return videoAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE'
        ? 'IMAGE_ASPECT_RATIO_LANDSCAPE'
        : 'IMAGE_ASPECT_RATIO_PORTRAIT';
  }

  void _cleanup(String taskId) {
    _queueToGenerate.remove(taskId);
    _activeVideos.remove(taskId);
    _generationComplete.remove(taskId);
    _runningTasks.remove(taskId);
  }

  void dispose() {
    stopScheduler();
    _profileManager?.dispose();
  }
}

class _ActiveVideo {
  final SceneData scene;
  final String sceneUuid;
  final ChromeProfile profile;

  _ActiveVideo({
    required this.scene,
    required this.sceneUuid,
    required this.profile,
  });
}
