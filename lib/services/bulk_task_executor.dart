import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/bulk_task.dart';
import '../models/scene_data.dart';
import '../services/browser_video_generator.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';
import '../utils/config.dart';
import 'mobile/mobile_browser_service.dart';
import 'package:flutter/foundation.dart'; // for debugging/foundation
import 'dart:io' show Platform;

/// Manages execution of heavy bulk tasks with multi-browser support
/// Uses direct API calls with batch polling and retry logic (up to 7 times)
/// Singleton to persist across screen navigations
class BulkTaskExecutor {
  // Singleton pattern
  static final BulkTaskExecutor _instance = BulkTaskExecutor._internal();
  factory BulkTaskExecutor({Function(BulkTask)? onTaskStatusChanged}) {
    if (onTaskStatusChanged != null) {
      _instance._onTaskStatusChanged = onTaskStatusChanged;
    }
    return _instance;
  }
  BulkTaskExecutor._internal();

  final Map<String, BulkTask> _runningTasks = {};
  final Map<String, int> _activeGenerations = {};
  final Map<String, List<_PendingPoll>> _pendingPolls = {};
  final Map<String, bool> _generationComplete = {};
  
  Timer? _schedulerTimer;
  Function(BulkTask)? _onTaskStatusChanged;
  
  /// Update callback when screen is recreated
  void setOnTaskStatusChanged(Function(BulkTask)? callback) {
    _onTaskStatusChanged = callback;
  }
  
  /// Get running task by ID (for reconnecting UI)
  BulkTask? getRunningTask(String taskId) => _runningTasks[taskId];
  
  /// Get all running tasks
  List<BulkTask> get runningTasks => _runningTasks.values.toList();
  
  /// Check if a task is running
  bool isTaskRunning(String taskId) => _runningTasks.containsKey(taskId);
  
  // Multi-browser support
  ProfileManagerService? _profileManager;
  MobileBrowserService? _mobileService;
  MultiProfileLoginService? _loginService;
  String _email = '';
  String _password = '';
  
  final Random _random = Random();

  /// Set multi-browser profile manager
  void setProfileManager(ProfileManagerService? manager) {
    _profileManager = manager;
  }

  void setMobileBrowserService(MobileBrowserService? service) {
    _mobileService = service;
  }

  /// Set login service for re-login on 403
  void setLoginService(MultiProfileLoginService? service) {
    _loginService = service;
  }

  /// Set credentials for re-login
  void setCredentials(String email, String password) {
    _email = email;
    _password = password;
  }
  
  /// Set default account type (e.g. ai_pro, ai_ultra) for model key mapping
  void setAccountType(String type) {
    _accountType = type;
  }
  
  String _accountType = 'ai_ultra'; // Default to Ultra but configurable

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

        if (shouldStart && !_isProfileBusy(task.profile)) {
          startTask(task);
        }
      }
    }
  }

  bool _isProfileBusy(String profile) {
    return _runningTasks.values.any((t) => t.profile == profile);
  }

  /// Start executing a bulk task
  Future<void> startTask(BulkTask task) async {
    print('\n');
    print('[TASK] ========================================');
    print('[TASK] START BULK TASK: ${task.name}');
    print('[TASK] Using Multi-Browser Direct API Mode');
    print('[TASK] Scenes: ${task.scenes.length}');
    print('[TASK] Model: ${task.model}');
    print('[TASK] ========================================');
    
    if (_runningTasks.containsKey(task.id)) {
      print('[TASK] Task ${task.name} is already running');
      return;
    }

    task.status = TaskStatus.running;
    task.startedAt = DateTime.now();
    _runningTasks[task.id] = task;
    _activeGenerations[task.id] = 0;
    _pendingPolls[task.id] = [];
    _generationComplete[task.id] = false;
    
    _onTaskStatusChanged?.call(task);

    try {
      await _executeTaskMultiBrowser(task);
      
      task.status = TaskStatus.completed;
      task.completedAt = DateTime.now();
      print('[TASK] ✓ Task completed successfully');
    } catch (e, stackTrace) {
      print('[TASK] ✗ Task FAILED: $e');
      print('[TASK] Stack trace: $stackTrace');
      task.status = TaskStatus.failed;
      task.error = e.toString();
      task.completedAt = DateTime.now();
    } finally {
      _cleanup(task.id);
      _onTaskStatusChanged?.call(task);
    }
  }
  
  /// Public method to trigger checking scheduled tasks immediately
  void checkScheduledTasksNow(List<BulkTask> tasks) {
    _checkScheduledTasks(tasks);
  }

  /// Execute task using multi-browser direct API
  Future<void> _executeTaskMultiBrowser(BulkTask task) async {
    print('\n${'=' * 60}');
    print('BULK TASK: ${task.name}');
    print('Profile: ${task.profile}');
    print('Scenes: ${task.totalScenes}');
    print('=' * 60);

    // Debug: Show configuration status
    print('\n[CONFIG] Profile Manager: ${_profileManager != null ? "SET" : "NULL"}');
    print('[CONFIG] Login Service: ${_loginService != null ? "SET" : "NULL"}');
    print('[CONFIG] Email: ${_email.isNotEmpty ? "SET (${_email.length} chars)" : "EMPTY"}');
    
    if (_profileManager != null) {
      print('[CONFIG] Connected browsers: ${_profileManager!.countConnectedProfiles()}');
      for (final profile in _profileManager!.profiles) {
        print('[CONFIG]   - ${profile.name}: ${profile.status} (Port: ${profile.debugPort})');
      }
    }

    // Check for connected browsers
    if (_countConnectedProfiles() == 0) {
      print('[ERROR] No connected browsers available!');
      throw Exception('No connected browsers. Please connect browsers using Profile Manager.');
    }

    // Convert model display name to API key
    final apiModelKey = AppConfig.getApiModelKey(task.model, _accountType);
    print('\n[MODEL] Display: ${task.model}');
    print('[MODEL] Account Type: $_accountType');
    print('[MODEL] API Key: $apiModelKey');
    print('[ASPECT RATIO] ${task.aspectRatio}');

    // Determine concurrency limit
    final isRelaxedModel = task.model.contains('Lower Priority') || 
                            task.model.contains('relaxed') ||
                            apiModelKey.contains('relaxed');
    final maxConcurrent = isRelaxedModel ? 4 : 10;
    print('[CONCURRENCY] ===============================');
    print('[CONCURRENCY] Model Display Name: "${task.model}"');
    print('[CONCURRENCY] API Model Key: "$apiModelKey"');
    print('[CONCURRENCY] Contains "Lower Priority": ${task.model.contains('Lower Priority')}');
    print('[CONCURRENCY] Contains "relaxed" in key: ${apiModelKey.contains('relaxed')}');
    print('[CONCURRENCY] Is Relaxed Mode: $isRelaxedModel');
    print('[CONCURRENCY] Max Concurrent: $maxConcurrent');
    print('[CONCURRENCY] ===============================');

    // Start generation and polling workers
    final scenesToProcess = task.scenes.where((s) => s.status == 'queued').toList();
    print('\n[WORKERS] Scenes to process: ${scenesToProcess.length}');
    print('[WORKERS] Connected browsers: ${_countConnectedProfiles()}');

    try {
      await Future.wait([
        _processGenerationQueueMultiBrowser(task, scenesToProcess, maxConcurrent, apiModelKey),
        _processBatchPollingQueue(task, maxConcurrent),
      ]);
    } catch (e, stackTrace) {
      print('[WORKERS] ERROR: $e');
      print('[WORKERS] Stack: $stackTrace');
      rethrow;
    }

    print('\n${'=' * 60}');
    print('TASK COMPLETE: ${task.name}');
    print('Completed: ${task.completedScenes}/${task.totalScenes}');
    print('Failed: ${task.failedScenes}');
    print('=' * 60);
  }

  /// Process generation queue with multi-browser round-robin and retry logic
  Future<void> _processGenerationQueueMultiBrowser(
    BulkTask task,
    List<SceneData> scenesToProcess,
    int maxConcurrent,
    String apiModelKey,
  ) async {
    print('\n${'=' * 60}');
    print('GENERATION PRODUCER STARTED (Multi-Browser Direct API)');
    print('=' * 60);

    for (var i = 0; i < scenesToProcess.length; i++) {
      if (task.status != TaskStatus.running) {
        print('\n[STOP] Task stopped by user');
        break;
      }

      // Wait for available slot
      while (_activeGenerations[task.id]! >= maxConcurrent && task.status == TaskStatus.running) {
        print('\r[LIMIT] Waiting for slots (Active: ${_activeGenerations[task.id]}/$maxConcurrent)...');
        await Future.delayed(const Duration(seconds: 1));
      }

      final scene = scenesToProcess[i];

      // Get next available browser (round-robin) - only gets healthy profiles (< 3 403s)
      final profile = _getNextAvailableProfile();
      if (profile == null) {
        // Android-only: Check if all browsers have hit 403 threshold
        if (Platform.isAndroid && _mobileService != null) {
          final totalConnected = _countConnectedProfiles();
          final healthyCount = _countHealthyProfiles();
          
          if (totalConnected > 0 && healthyCount == 0) {
            // ALL browsers have 403 errors - need re-login
            print('[GENERATE] ❌ ALL browsers have reached 403 threshold!');
            print('[GENERATE] ⚠️ PAUSING - Auto relogin in progress...');
            print('[GENERATE] Browsers connected: $totalConnected, Healthy: $healthyCount');
            
            // Trigger auto-relogin for all profiles that need it
            _mobileService!.reloginAllNeeded(onAnySuccess: () {
              print('[GENERATE] ✓ A browser recovered - generation will resume');
            });
            
            // Pause the task
            task.status = TaskStatus.paused;
            _onTaskStatusChanged?.call(task);
            
            // Wait and check periodically if any browser becomes healthy
            while (_countHealthyProfiles() == 0 && task.status == TaskStatus.paused) {
              await Future.delayed(const Duration(seconds: 5));
              print('[GENERATE] Waiting for auto-relogin... (Healthy: ${_countHealthyProfiles()})');
            }
            
            if (task.status == TaskStatus.paused) {
              task.status = TaskStatus.running;
              _onTaskStatusChanged?.call(task);
              print('[GENERATE] ✓ Resuming generation!');
            }
            i--; // Retry this scene
            continue;
          }
        }
        
        print('[GENERATE] No available browsers, waiting...');
        await Future.delayed(const Duration(seconds: 2));
        i--;
        continue;
      }

      try {
        // Anti-detection delay
        if (i > 0) {
          final jitter = 2.0 + (3.0 * _random.nextDouble());
          print('\n[ANTI-BOT] Waiting ${jitter.toStringAsFixed(1)}s');
          await Future.delayed(Duration(milliseconds: (jitter * 1000).toInt()));
        }

        await _generateWithProfile(task, scene, profile, i + 1, scenesToProcess.length, apiModelKey);
      } on _RetryableException catch (e) {
        // Retryable error - push back to queue
        scene.retryCount = (scene.retryCount ?? 0) + 1;

        if (scene.retryCount! < 7) {
          print('[RETRY] Scene ${scene.sceneId} retry ${scene.retryCount}/7 - pushing back to queue');
          scene.status = 'queued';
          scene.error = 'Retrying (${scene.retryCount}/7): ${e.message}';
          _onTaskStatusChanged?.call(task);
          scenesToProcess.add(scene);
        } else {
          print('[GENERATE] ✗ Scene ${scene.sceneId} failed after 7 retries: ${e.message}');
          scene.status = 'failed';
          scene.error = 'Failed after 7 retries: ${e.message}';
          _onTaskStatusChanged?.call(task);
        }
      } catch (e) {
        scene.status = 'failed';
        scene.error = e.toString();
        _onTaskStatusChanged?.call(task);
        print('[GENERATE] ✗ Exception: $e');
      }
    }

    // Mark generation as complete
    _generationComplete[task.id] = true;
    print('\n[PRODUCER] All scenes processed');
  }

  /// Generate video using specific browser profile (direct API)
  Future<void> _generateWithProfile(
    BulkTask task,
    SceneData scene,
    dynamic profile, // Supported: ChromeProfile, MobileProfile
    int currentIndex,
    int totalScenes,
    String apiModelKey,
  ) async {
    // Take slot immediately
    _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 0) + 1;
    print('[SLOT] Took slot - Active: ${_activeGenerations[task.id]}');

    scene.status = 'generating';
    scene.error = null;
    _onTaskStatusChanged?.call(task);

    print('\n[GENERATE $currentIndex/$totalScenes] Scene ${scene.sceneId}');
    print('[GENERATE] Browser: ${profile.name} (Port: ${profile.debugPort})');
    print('[GENERATE] Using Direct API Method (batchAsyncGenerateVideoText)');
    print('[GENERATE] Model: $apiModelKey');
    print('[GENERATE] Aspect Ratio: ${task.aspectRatio}');
    print('[GENERATE] Prompt: ${scene.prompt.substring(0, scene.prompt.length > 100 ? 100 : scene.prompt.length)}...');
    print('[API REQUEST] Sending generation request...');

    final result = await profile.generator!.generateVideo(
      prompt: scene.prompt,
      accessToken: profile.accessToken!,
      aspectRatio: task.aspectRatio,
      model: apiModelKey,
      startImageMediaId: scene.firstFrameMediaId,
      endImageMediaId: scene.lastFrameMediaId,
    );

    print('[API RESPONSE] Result received: ${result != null ? "SUCCESS" : "NULL"}');
    if (result != null) {
      print('[API RESPONSE] Status: ${result['status']}');
      print('[API RESPONSE] Success: ${result['success']}');
      if (result['error'] != null) print('[API RESPONSE] Error: ${result['error']}');
    }

    if (result == null) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      print('[SLOT] Released slot (null result) - Active: ${_activeGenerations[task.id]}');
      throw _RetryableException('No result from generateVideo');
    }

    // Check for errors
    if (result['status'] != null && result['status'] != 200) {
      final statusCode = result['status'] as int;
      final errorMsg = result['error'] ?? result['statusText'] ?? 'API error';
      print('[API ERROR] Status Code: $statusCode');
      print('[API ERROR] Message: $errorMsg');

      if (statusCode == 403) {
        profile.consecutive403Count++;
        print('[403] ${profile.name} 403 count: ${profile.consecutive403Count}/3');

        // Handle relogin for Chrome profiles
        if (profile is ChromeProfile && 
            profile.consecutive403Count >= 3 && 
            _loginService != null && 
            _email.isNotEmpty && 
            _password.isNotEmpty) {
          print('[403] ${profile.name} threshold reached, triggering relogin...');
          _loginService!.reloginProfile(profile, _email, _password);
        }
        
        // Handle token refresh for Mobile profiles - trigger auto-relogin
        if (Platform.isAndroid && 
            _mobileService != null &&
            profile.consecutive403Count >= 3) {
          print('[403] ${profile.name} threshold reached, triggering mobile auto-relogin...');
          final mobileProfile = profile as MobileProfile;
          
          // Don't await - let it run in background so generation can continue on other browsers
          _mobileService!.autoReloginProfile(mobileProfile, onSuccess: () {
            print('[403] ${profile.name} relogin SUCCESS - browser now healthy');
          });
        }
      }

      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      print('[SLOT] Released slot (API error $statusCode) - Active: ${_activeGenerations[task.id]}');
      throw _RetryableException('API error $statusCode: $errorMsg');
    }

    if (result['success'] != true) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      throw _RetryableException(result['error'] ?? 'Generation failed');
    }

    // Extract operation name from nested structure
    final responseData = result['data'] as Map<String, dynamic>;
    final operations = responseData['operations'] as List?;
    if (operations == null || operations.isEmpty) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      throw _RetryableException('No operations in response');
    }

    final operationWrapper = operations[0] as Map<String, dynamic>;
    final operation = operationWrapper['operation'] as Map<String, dynamic>?;
    if (operation == null) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      throw _RetryableException('No operation object in response');
    }

    final operationName = operation['name'] as String?;
    if (operationName == null) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      throw _RetryableException('No operation name in response');
    }

    final sceneUuid = operationWrapper['sceneId'] as String? ?? result['sceneId'] as String?;

    scene.operationName = operationName;
    scene.status = 'polling';
    _onTaskStatusChanged?.call(task);

    // Add to pending polls
    _pendingPolls[task.id]!.add(_PendingPoll(scene, sceneUuid ?? operationName));

    print('[GENERATE] ✓ Scene ${scene.sceneId} queued for polling (operation: $operationName)');
  }

  /// Batch polling queue (single API call for ALL videos)
  Future<void> _processBatchPollingQueue(BulkTask task, int maxConcurrent) async {
    print('\n${'=' * 60}');
    print('POLLING CONSUMER STARTED (Batch Mode)');
    print('=' * 60);

    while (task.status == TaskStatus.running && 
           (!_generationComplete[task.id]! || _pendingPolls[task.id]!.isNotEmpty || _activeGenerations[task.id]! > 0)) {
      
      if (_pendingPolls[task.id]!.isEmpty) {
        await Future.delayed(const Duration(seconds: 1));
        
        // Check for retry scenes
        final retryScenes = task.scenes
            .where((s) => s.status == 'queued' && (s.retryCount ?? 0) > 0)
            .toList();
        
        if (retryScenes.isNotEmpty && _activeGenerations[task.id]! < maxConcurrent) {
          // These will be picked up by the generation loop
        }
        
        continue;
      }

      final pollInterval = 3 + _random.nextInt(3); // 3-5 seconds
      print('\n[POLLER] Monitoring ${_pendingPolls[task.id]!.length} active videos... (Next check in ${pollInterval}s)');

      try {
        // Build batch poll request
        final pollRequests = _pendingPolls[task.id]!.map((poll) =>
            PollRequest(poll.scene.operationName!, poll.sceneUuid)).toList();

        // Find generator for polling
        dynamic pollGenerator;
        String? pollToken;

        if (Platform.isAndroid && _mobileService != null) {
          for (final profile in _mobileService!.profiles) {
            if (profile.status == MobileProfileStatus.ready && // ready means connected + token
                profile.generator != null) {
              pollGenerator = profile.generator;
              pollToken = profile.accessToken;
              break;
            }
          }
        } else if (_profileManager != null) {
          for (final profile in _profileManager!.profiles) {
            if (profile.status == ProfileStatus.connected &&
                profile.generator != null &&
                profile.accessToken != null) {
              pollGenerator = profile.generator;
              pollToken = profile.accessToken;
              break;
            }
          }
        }

        if (pollGenerator == null || pollToken == null) {
          print('[POLLER] No connected browser - skipping poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        // Batch poll
        final results = await pollGenerator.pollVideoStatusBatch(pollRequests, pollToken);

        if (results == null || results.isEmpty) {
          print('[POLLER] No results from batch poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        // Process results
        final completedIndices = <int>[];

        for (var i = 0; i < results.length && i < _pendingPolls[task.id]!.length; i++) {
          final result = results[i];
          final poll = _pendingPolls[task.id]![i];
          final scene = poll.scene;
          final status = result['status'] as String?;

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
            print('[SLOT] Video ready, freed slot - Active: ${_activeGenerations[task.id]}');

            String? videoUrl;
            if (result.containsKey('operation')) {
              final metadata = (result['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] as String?;
            }

            if (videoUrl != null) {
              print('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
              _downloadVideo(task, scene, videoUrl, pollGenerator);
            } else {
              scene.status = 'failed';
              scene.error = 'No video URL';
              _onTaskStatusChanged?.call(task);
            }

            completedIndices.add(i);
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
            String errorMsg = 'Generation failed';
            if (result.containsKey('operation')) {
              final metadata = (result['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
              final errorDetails = metadata?['error'] as Map<String, dynamic>?;
              if (errorDetails != null) {
                errorMsg = '${errorDetails['message'] ?? 'No details'} (Code: ${errorDetails['code'] ?? 'Unknown'})';
              }
            }

            scene.retryCount = (scene.retryCount ?? 0) + 1;
            _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;

            if (scene.retryCount! < 7) {
              print('[RETRY] Scene ${scene.sceneId} poll failed (${scene.retryCount}/7) - pushing back for regeneration');
              scene.status = 'queued';
              scene.operationName = null;
              scene.error = 'Retrying (${scene.retryCount}/7): $errorMsg';
              _onTaskStatusChanged?.call(task);
            } else {
              print('[POLLER] ✗ Scene ${scene.sceneId} failed after 7 retries: $errorMsg');
              scene.status = 'failed';
              scene.error = 'Failed after 7 retries: $errorMsg';
              _onTaskStatusChanged?.call(task);
            }

            completedIndices.add(i);
          }
        }

        // Remove completed items
        for (final index in completedIndices.reversed) {
          _pendingPolls[task.id]!.removeAt(index);
        }
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('closed') || errorStr.contains('WebSocket')) {
          print('[POLLER] WebSocket closed (browser relogging?) - skipping poll');
        } else {
          print('[POLLER] Error during batch poll: $e');
        }
      }

      if (_pendingPolls[task.id]!.isNotEmpty) {
        await Future.delayed(Duration(seconds: pollInterval));
      }
    }

    print('[POLLER] Poll worker finished');
  }

  /// Download video
  Future<void> _downloadVideo(BulkTask task, SceneData scene, String videoUrl, dynamic generator) async {
    try {
      scene.status = 'downloading';
      _onTaskStatusChanged?.call(task);
      print('[DOWNLOAD] Scene ${scene.sceneId} STARTED');

      // Create output folder (use directly, don't nest with task.name)
      final projectFolder = task.outputFolder;
      await Directory(projectFolder).create(recursive: true);
      
      final outputPath = path.join(
        projectFolder,
        'scene_${scene.sceneId.toString().padLeft(4, '0')}.mp4',
      );

      final fileSize = await generator.downloadVideo(videoUrl, outputPath);

      scene.videoPath = outputPath;
      scene.fileSize = fileSize;
      scene.downloadUrl = videoUrl;
      scene.generatedAt = DateTime.now().toIso8601String();
      scene.status = 'completed';
      _onTaskStatusChanged?.call(task);

      print('[DOWNLOAD] ✓ Scene ${scene.sceneId} Complete (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      scene.status = 'failed';
      scene.error = 'Download failed: $e';
      _onTaskStatusChanged?.call(task);
      print('[DOWNLOAD] ✗ Scene ${scene.sceneId} Failed: $e');
    }
  }

  void _cleanup(String taskId) {
    _runningTasks.remove(taskId);
    _activeGenerations.remove(taskId);
    _pendingPolls.remove(taskId);
    _generationComplete.remove(taskId);
  }

  void dispose() {
    _schedulerTimer?.cancel();
    _runningTasks.clear();
    _activeGenerations.clear();
    _pendingPolls.clear();
    _generationComplete.clear();
  }
}

/// Helper class for pending poll tracking
class _PendingPoll {
  final SceneData scene;
  final String sceneUuid;

  _PendingPoll(this.scene, this.sceneUuid);
}

/// Exception that can be retried on a different browser
class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);

  @override
  String toString() => message;
}

// Helpers for cross-platform profile management
extension _BulkTaskExecutorHelpers on BulkTaskExecutor {
  int _countConnectedProfiles() {
    if (Platform.isAndroid && _mobileService != null) {
      return _mobileService!.countConnected();
    }
    return _profileManager?.countConnectedProfiles() ?? 0;
  }

  dynamic _getNextAvailableProfile() {
    if (Platform.isAndroid && _mobileService != null) {
      return _mobileService!.getNextAvailableProfile();
    }
    return _profileManager?.getNextAvailableProfile();
  }
  
  /// Count profiles that haven't hit 403 threshold
  int _countHealthyProfiles() {
    if (Platform.isAndroid && _mobileService != null) {
      return _mobileService!.countHealthy();
    }
    // For desktop, return all connected count (no 403 filtering on PC)
    if (_profileManager != null) {
      return _profileManager!.countConnectedProfiles();
    }
    return 0;
  }
}
