import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'package:video_thumbnail/video_thumbnail.dart';
import '../models/bulk_task.dart';
import '../models/scene_data.dart';
import 'browser_video_generator.dart';
import 'profile_manager_service.dart';
import 'multi_profile_login_service.dart';
import '../utils/config.dart';
import '../utils/app_logger.dart';

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

    AppLogger.i('\n[MULTI-PROFILE] ✓ Initialized with $profileCount profiles');
    AppLogger.i('[MULTI-PROFILE] Connected: ${_profileManager!.countConnectedProfiles()}');
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
    AppLogger.i('[TASK] ========================================');
    AppLogger.i('[TASK] START TASK: ${task.name}');
    AppLogger.i('[TASK] ========================================');
    
    if (_runningTasks.containsKey(task.id)) {
      AppLogger.i('[TASK] Task ${task.name} is already running');
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

  // Track if we are in a 429 cooldown period
  bool _is429Cooldown = false;
  DateTime? _cooldownEndTime;

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

    // Determine concurrency limit per browser
    final isRelaxedModel = task.model.toLowerCase().contains('relaxed') || 
                            task.model.toLowerCase().contains('lower priority');
    
    // Per-browser limits: 4 for relaxed, UNLIMITED for fast
    final slotsPerBrowser = isRelaxedModel ? 4 : 9999; // 9999 = effectively unlimited
    final connectedCount = _profileManager!.countConnectedProfiles();
    final maxConcurrent = connectedCount * slotsPerBrowser;

    print('[CONCURRENCY] Model: "${task.model}"');
    print('[CONCURRENCY] IsRelaxed: $isRelaxedModel, Slots/Browser: $slotsPerBrowser');
    print('[CONCURRENCY] Total Max Concurrent: $maxConcurrent ($connectedCount browsers)');
    print('[QUEUE] Initial queue size: ${_queueToGenerate[task.id]!.length}');

    // Start concurrent generation and polling
    await Future.wait([
      _runConcurrentGeneration(task, slotsPerBrowser, isRelaxedModel),
      _runBatchPolling(task),
    ]);
  }

  /// Sequential generation worker (PRODUCER) - Smart Batching Strategy
  Future<void> _runConcurrentGeneration(BulkTask task, int slotsPerBrowser, bool isRelaxed) async {
    print('\n[PRODUCER] Sequential generation started (Smart batching strategy)');
    print('[STRATEGY] Prefetch 4 tokens → Generate → Repeat (no hard limit!)');
    print('[LIMIT] Max concurrent polling: ${isRelaxed ? "$slotsPerBrowser per browser (Relaxed)" : "Unlimited (Fast)"}');
    final accountEmail = _email ?? 'default';
    
    int videosGenerated = 0;
    int tokensUsed = 0;

    while (_queueToGenerate[task.id]!.isNotEmpty) {
      // Check for 429 Cooldown
      if (_is429Cooldown) {
        if (_cooldownEndTime != null && DateTime.now().isBefore(_cooldownEndTime!)) {
          final remaining = _cooldownEndTime!.difference(DateTime.now()).inSeconds;
          print('[PRODUCER] 429 Cooldown active: ${remaining}s remaining...');
          await Future.delayed(const Duration(seconds: 10));
          continue;
        } else {
          print('[PRODUCER] 429 Cooldown ended. Resuming...');
          _is429Cooldown = false;
        }
      }

      // RELAXED MODEL LIMIT: Wait if too many videos are actively polling
      // Fast models have no limit, relaxed models limited to slotsPerBrowser per profile
      if (isRelaxed) {
        final activePolling = _activeVideos[task.id]!.length;
        final connectedProfiles = _profileManager!.countConnectedProfiles();
        final maxActivePolling = connectedProfiles * slotsPerBrowser;
        
        while (activePolling >= maxActivePolling && isRunning && _queueToGenerate[task.id]!.isNotEmpty) {
          print('[LIMIT] Waiting for polling slots (${activePolling}/${maxActivePolling} active)...');
          await Future.delayed(const Duration(seconds: 3));
        }
      }

      // SMART STRATEGY: Prefetch 4 tokens every 4 videos
      if (tokensUsed % 4 == 0) {
        print('\n[SMART PREFETCH] Prefetching next batch of 4 tokens...');
        final availableProfiles = _profileManager!.profiles
            .where((p) => p.isAvailable && p.status != ProfileStatus.relogging)
            .toList();
        
        if (availableProfiles.isNotEmpty) {
          final profile = availableProfiles.first;
          if (profile.generator != null) {
            try {
              await profile.generator!.prefetchRecaptchaTokens(4);
              print('[SMART PREFETCH] ✓ Got 4 fresh tokens');
            } catch (e) {
              print('[SMART PREFETCH] Failed: $e');
            }
          }
        }
      }

      // Get next available profile (round-robin)
      final availableProfiles = _profileManager!.profiles
          .where((p) => p.isAvailable && p.status != ProfileStatus.relogging)
          .toList();
      
      if (availableProfiles.isEmpty) {
        print('[PRODUCER] No available profiles, waiting...');
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }

      // Get next scene from queue
      final scene = _queueToGenerate[task.id]!.removeAt(0);
      
      // Pick profile (round-robin)
      final profile = availableProfiles.first;
      
      // Increment tracking
      profile.activeTasks++;
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 0) + 1;
      
      videosGenerated++;
      tokensUsed++;
      print('[PRODUCER] Video $videosGenerated (Token #$tokensUsed) → ${profile.name}');
      
      // Wait for THIS generation to complete before starting next
      await _startSingleGeneration(task, scene, profile, accountEmail);
      
      // Delay 2-4 seconds between sequential calls
      final delaySeconds = 2 + (_random.nextInt(3)); // 2-4s
      print('[DELAY] Waiting ${delaySeconds}s before next generation...');
      await Future.delayed(Duration(seconds: delaySeconds));
    }

    _generationComplete[task.id] = true;
    print('[PRODUCER] All scenes processed');
    print('[STATS] Total videos generated: $videosGenerated');
    print('[STATS] Total tokens used: $tokensUsed');
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

      // Check for empty prompt - Veo3 API requires a text prompt even for I2V
      final hasImage = scene.firstFramePath != null || scene.lastFramePath != null ||
                       scene.firstFrameMediaId != null || scene.lastFrameMediaId != null;
      if (scene.prompt.trim().isEmpty) {
        if (hasImage) {
          scene.prompt = 'Animate this image with natural, fluid motion';
          print('[GENERATE] Using default I2V prompt for scene ${scene.sceneId}');
        } else {
          print('[GENERATE] Skipping scene ${scene.sceneId} - no prompt or image');
          scene.status = 'failed';
          scene.error = 'No prompt or image provided';
          onTaskStatusChanged?.call(task);
          return;
        }
      }

      // Handle image uploads - use stored mediaId if available
      String? startImageMediaId = scene.firstFrameMediaId;
      String? endImageMediaId = scene.lastFrameMediaId;

      // Upload first frame if path exists but no mediaId
      if (scene.firstFramePath != null && startImageMediaId == null) {
        print('[GENERATE] Uploading first frame image...');
        final uploadResult = await profile.generator!.uploadImage(
          scene.firstFramePath!,
          profile.accessToken!,
          aspectRatio: _aspectRatioToImageFormat(task.aspectRatio),
        );
        
        if (uploadResult is String) {
          startImageMediaId = uploadResult;
          scene.firstFrameMediaId = uploadResult;
          print('[GENERATE] ✓ First frame uploaded: $startImageMediaId');
        } else if (uploadResult is Map && uploadResult['error'] == true) {
          throw Exception(uploadResult['message'] ?? 'Image upload failed');
        }
      } else if (startImageMediaId != null) {
        print('[GENERATE] Using cached first frame mediaId: $startImageMediaId');
      }

      // Upload last frame if path exists but no mediaId
      if (scene.lastFramePath != null && endImageMediaId == null) {
        print('[GENERATE] Uploading last frame image...');
        final uploadResult = await profile.generator!.uploadImage(
          scene.lastFramePath!,
          profile.accessToken!,
          aspectRatio: _aspectRatioToImageFormat(task.aspectRatio),
        );
        
        if (uploadResult is String) {
          endImageMediaId = uploadResult;
          scene.lastFrameMediaId = uploadResult;
          print('[GENERATE] ✓ Last frame uploaded: $endImageMediaId');
        }
      } else if (endImageMediaId != null) {
        print('[GENERATE] Using cached last frame mediaId: $endImageMediaId');
      }

      // Debug: Print I2V status
      final isI2V = startImageMediaId != null || endImageMediaId != null;
      print('[GENERATE] Mode: ${isI2V ? "I2V" : "T2V"}, startImageMediaId: $startImageMediaId, endImageMediaId: $endImageMediaId');

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
        _handle429Error(task, scene, profile, accountEmail);
        return;
      }

      if (result['success'] != true) {
        throw Exception(result['error'] ?? 'Generation failed');
      }

      // SUCCESS (200) - Reset consecutive 403 count
      profile.consecutive403Count = 0;
      print('[SUCCESS] ${profile.name} - Reset consecutive 403 count (healthy session)');

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
      profile.activeTasks = (profile.activeTasks > 0) ? profile.activeTasks - 1 : 0;
    }
  }

  /// Handle 403 error: increment CONSECUTIVE counter, trigger relogin only after 4 in a row
  void _handle403Error(BulkTask task, SceneData scene, ChromeProfile profile, String accountEmail) {
    // Decrement account counter and profile active tasks
    _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    profile.activeTasks = (profile.activeTasks > 0) ? profile.activeTasks - 1 : 0;
    
    // Increment CONSECUTIVE 403 counter for this profile
    profile.consecutive403Count++;
    print('[403] ${profile.name} CONSECUTIVE 403s: ${profile.consecutive403Count}/4');

    // Increment retry count for this scene
    final sceneId = scene.sceneId.toString();
    _videoRetryCounts[sceneId] = (_videoRetryCounts[sceneId] ?? 0) + 1;

    // SMART STRATEGY: Only relogin after 4 CONSECUTIVE 403s
    // This means session is truly dead, not just a bad token
    if (profile.consecutive403Count < 4) {
      print('[403 STRATEGY] Will retry with next token (${4 - profile.consecutive403Count} strikes left)');
    } else {
      // 4 consecutive failures = session dead → Relogin
      print('[403 STRATEGY] 4 CONSECUTIVE 403s → Session dead, triggering relogin');
      if (_email != null && _password != null) {
        print('[403] ${profile.name} - Relogging after 4 consecutive failures...');
        _loginService!.reloginProfile(profile, _email!, _password!);
        profile.consecutive403Count = 0; // Reset after relogin
      }
    }

    // Re-queue scene at front for immediate retry
    scene.status = 'queued';
    scene.error = '403 error - retrying';
    _queueToGenerate[task.id]!.insert(0, scene);
    onTaskStatusChanged?.call(task);
    
    print('[403] Scene ${scene.sceneId} re-queued for retry');
  }

  /// Handle 429 error: decrement counter, wait before retry
  void _handle429Error(BulkTask task, SceneData scene, ChromeProfile profile, String accountEmail) {
    // Decrement account counter and profile active tasks
    _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    profile.activeTasks = (profile.activeTasks > 0) ? profile.activeTasks - 1 : 0;
    
    print('[429] Account active after release: ${_activeVideosByAccount[accountEmail]}');
    
    // Set global cooldown
    _is429Cooldown = true;
    _cooldownEndTime = DateTime.now().add(const Duration(seconds: 45)); // 45s cooldown
    print('[429] Triggering 45s global cooldown...');

    // Increment retry count for this scene
    final sceneId = scene.sceneId.toString();
    _videoRetryCounts[sceneId] = (_videoRetryCounts[sceneId] ?? 0) + 1;

    // Re-queue scene with delay
    scene.status = 'queued';
    scene.error = '429 quota exhausted - waiting before retry';
    
    // Add to end of queue to give time for quota to recover
    _queueToGenerate[task.id]!.add(scene);
    onTaskStatusChanged?.call(task);
    
    print('[429] Scene ${scene.sceneId} re-queued at the end');
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
          // Extract video URL and mediaId
          String? videoUrl;
          String? videoMediaId;
          if (opData.containsKey('operation')) {
            final metadata = (opData['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
            final video = metadata?['video'] as Map<String, dynamic>?;
            videoUrl = video?['fifeUrl'] as String?;
            
            // Extract mediaId for upscaling
            final mediaGenId = video?['mediaGenerationId'];
            if (mediaGenId != null) {
              if (mediaGenId is Map) {
                videoMediaId = mediaGenId['mediaGenerationId'] as String?;
              } else if (mediaGenId is String) {
                videoMediaId = mediaGenId;
              }
            }
          }

          if (videoUrl != null) {
            // Store mediaId for upscaling
            if (videoMediaId != null) {
              scene.videoMediaId = videoMediaId;
              scene.downloadUrl = videoUrl;
              print('[BATCH POLL] Video MediaId: $videoMediaId (saved for upscaling)');
            }
            // Download video (don't await) and track it
            downloadingScenes.add(scene.sceneId);
            _downloadVideo(task, scene, videoUrl, activeVideo, downloadingScenes);
          }
        } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
          scene.status = 'failed';
          scene.error = 'Generation failed on server';
          onTaskStatusChanged?.call(task);
          
          // Release slot on failure
          activeVideo.profile.activeTasks = (activeVideo.profile.activeTasks > 0) ? activeVideo.profile.activeTasks - 1 : 0;
          final accountEmail = _email ?? 'default';
          _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
          
          _activeVideos[task.id]!.remove(activeVideo);
          print('[BATCH POLL] Scene ${scene.sceneId} failed, slot released.');
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
      
      // Decrement account counter and profile active tasks
      final accountEmail = _email ?? 'default';
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
      activeVideo.profile.activeTasks = (activeVideo.profile.activeTasks > 0) ? activeVideo.profile.activeTasks - 1 : 0;

      print('[DOWNLOAD] ✓ Scene ${scene.sceneId} complete (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
      
      // Download thumbnail from video URL (much faster than FFmpeg)
      _downloadThumbnail(videoUrl, outputPath);
      
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
      activeVideo.profile.activeTasks = (activeVideo.profile.activeTasks > 0) ? activeVideo.profile.activeTasks - 1 : 0;
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

  /// Generate thumbnail (non-blocking)
  /// Desktop: Uses FFmpeg
  /// Mobile: Uses video_thumbnail package
  void _downloadThumbnail(String videoUrl, String videoPath) async {
    try {
      final videoDir = path.dirname(videoPath);
      final thumbDir = path.join(videoDir, 'thumbnails');
      final name = path.basenameWithoutExtension(videoPath);
      final thumbPath = path.join(thumbDir, '$name.thumb.jpg');
      
      // Skip if already exists
      if (File(thumbPath).existsSync()) return;
      
      // Ensure thumbnails directory exists
      await Directory(thumbDir).create(recursive: true);
      
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        // Desktop: Use FFmpeg
        // ffmpeg.exe should be in same folder as app executable
        final result = await Process.run('ffmpeg.exe', [
          '-y',
          '-i', videoPath,
          '-ss', '0.5',
          '-vframes', '1',
          '-q:v', '2',
          '-vf', 'scale=300:-1',
          thumbPath,
        ]);
        
        if (result.exitCode == 0 && File(thumbPath).existsSync()) {
          final size = File(thumbPath).lengthSync();
          print('[THUMBNAIL] ✓ Created: $thumbPath (${(size / 1024).toStringAsFixed(1)} KB)');
        } else {
          print('[THUMBNAIL] FFmpeg failed: ${result.stderr}');
        }
      } else {
        // Mobile: Use video_thumbnail package
        final thumbnail = await VideoThumbnail.thumbnailData(
          video: videoPath,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 300,
          quality: 75,
          timeMs: 500,
        );
        
        if (thumbnail != null) {
          await File(thumbPath).writeAsBytes(thumbnail);
          print('[THUMBNAIL] ✓ Created: $thumbPath (${(thumbnail.length / 1024).toStringAsFixed(1)} KB)');
        } else {
          print('[THUMBNAIL] video_thumbnail failed');
        }
      }
    } catch (e) {
      print('[THUMBNAIL] Error: $e');
    }
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
