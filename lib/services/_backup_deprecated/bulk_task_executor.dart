import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/bulk_task.dart';
import '../models/scene_data.dart';
import '../services/browser_video_generator.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';
import '../services/foreground_service.dart';
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

  /// Cancel a running task by ID
  void cancelTask(String taskId) {
    final task = _runningTasks[taskId];
    if (task == null) {
      print('[TASK] Task $taskId not found in running tasks');
      return;
    }
    
    print('[TASK] ⏹ Cancelling task: ${task.name}');
    task.status = TaskStatus.cancelled;
    task.completedAt = DateTime.now();
    _onTaskStatusChanged?.call(task);
    
    // Clean up
    _cleanup(taskId);
    
    print('[TASK] ✓ Task cancelled successfully');
  }
  
  /// Cancel all running tasks
  void cancelAllTasks() {
    final taskIds = _runningTasks.keys.toList();
    for (final taskId in taskIds) {
      cancelTask(taskId);
    }
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
    
    // Start foreground service to keep app running in background (Android)
    await ForegroundServiceHelper.startService(
      status: 'Starting: ${task.name} (${task.scenes.length} videos)'
    );
    
    _onTaskStatusChanged?.call(task);

    try {
      await _executeTaskMultiBrowser(task);
      
      task.status = TaskStatus.completed;
      task.completedAt = DateTime.now();
      print('[TASK] ✓ Task completed successfully');
      
      // Update notification to show completion
      await ForegroundServiceHelper.updateStatus('✓ ${task.name} completed!');
    } catch (e, stackTrace) {
      print('[TASK] ✗ Task FAILED: $e');
      print('[TASK] Stack trace: $stackTrace');
      task.status = TaskStatus.failed;
      task.error = e.toString();
      task.completedAt = DateTime.now();
      
      // Update notification to show failure
      await ForegroundServiceHelper.updateStatus('✗ ${task.name} failed');
    } finally {
      _cleanup(task.id);
      _onTaskStatusChanged?.call(task);
      
      // Stop foreground service if no more tasks running
      if (_runningTasks.isEmpty) {
        await ForegroundServiceHelper.stopService();
      }
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
    
    // Debug: Show mobile service status
    if (_mobileService != null) {
      print('[CONFIG] Mobile Service: SET');
      print('[CONFIG] Mobile Connected: ${_mobileService!.countConnected()}');
      print('[CONFIG] Mobile Healthy: ${_mobileService!.countHealthy()}');
      for (final profile in _mobileService!.profiles) {
        print('[CONFIG]   - ${profile.name}: hasToken=${profile.accessToken != null}, 403Count=${profile.consecutive403Count}');
      }
    } else {
      print('[CONFIG] Mobile Service: NULL');
    }

    // Check for connected browsers
    final connectedCount = _countConnectedProfiles();
    print('[CONFIG] Total Connected Profiles: $connectedCount');
    
    if (connectedCount == 0) {
      print('[ERROR] No connected browsers available!');
      final isMobile = Platform.isAndroid || Platform.isIOS;
      throw Exception(isMobile 
        ? 'No connected mobile browsers. Please login first on Browser tab.'
        : 'No connected browsers. Please connect using Profile Manager.');
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
    final maxConcurrent = isRelaxedModel ? 4 : 20;
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
    
    // Step: Prefetch reCAPTCHA tokens for ALL browsers (Python strategy)
    // Get 16 tokens per browser to avoid generating them during video generation
    print('\n[RECAPTCHA] Prefetching reCAPTCHA tokens for all browsers...');
    final List<Future> prefetchFutures = [];
    if (_profileManager != null) {
      for (final profile in _profileManager!.profiles) {
        if (profile.status == ProfileStatus.connected && profile.generator != null) {
          print('[RECAPTCHA] - Prefetching for ${profile.name}...');
          prefetchFutures.add(profile.generator!.prefetchRecaptchaTokens(16));
        }
      }
    }
    if (_mobileService != null) {
      for (final profile in _mobileService!.profiles) {
        if (profile.accessToken != null && profile.generator != null) {
          print('[RECAPTCHA] - Prefetching for ${profile.name}...');
          prefetchFutures.add(profile.generator!.prefetchRecaptchaTokens(16));
        }
      }
    }
    if (prefetchFutures.isNotEmpty) {
      print('[RECAPTCHA] Waiting for initial token prefetch...');
      await Future.wait(prefetchFutures).timeout(const Duration(minutes: 2), onTimeout: () => []);
    }
    print('[RECAPTCHA] ✓ Token prefetch phase complete');

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
      // Stop if task is not running and not paused
      if (task.status != TaskStatus.running && task.status != TaskStatus.paused) {
        print('\n[STOP] Task no longer running (status: ${task.status})');
        break;
      }
      
      // Wait if paused (relogin in progress)
      while (task.status == TaskStatus.paused) {
        await Future.delayed(const Duration(seconds: 2));
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
        // Android-only: Check if browsers need relogin
        if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
          final totalConnected = _countConnectedProfiles();
          final healthyCount = _countHealthyProfiles();
          final needsRelogin = _mobileService!.getProfilesNeedingRelogin();
          
          print('[GENERATE] No available browser. Connected: $totalConnected, Healthy: $healthyCount, NeedsRelogin: ${needsRelogin.length}');
          
          // Trigger relogin for browsers that need it (even if some are healthy)
          if (needsRelogin.isNotEmpty) {
            print('[GENERATE] Starting relogin for ${needsRelogin.length} unhealthy browsers...');
            // Start relogin in background (don't await if we have healthy browsers)
            _mobileService!.reloginAllNeeded(
              email: _email,
              password: _password,
              onAnySuccess: () {
                print('[GENERATE] ✓ A browser recovered!');
              },
            );
          }
          
          if (healthyCount == 0) {
            // ALL browsers are unhealthy - pause and wait
            print('[GENERATE] ❌ ALL browsers unhealthy - PAUSING...');
            task.status = TaskStatus.paused;
            _onTaskStatusChanged?.call(task);
            
            // Wait for at least one browser to become healthy
            int waitCount = 0;
            while (_countHealthyProfiles() == 0 && task.status == TaskStatus.paused && waitCount < 60) {
              await Future.delayed(const Duration(seconds: 5));
              waitCount++;
              print('[GENERATE] Waiting for relogin... (${waitCount * 5}s, Healthy: ${_countHealthyProfiles()})');
            }
            
            if (_countHealthyProfiles() > 0 && task.status == TaskStatus.paused) {
              task.status = TaskStatus.running;
              _onTaskStatusChanged?.call(task);
              print('[GENERATE] ✓ Resuming generation!');
            }
          }
          
          i--; // Retry this scene
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        
        print('[GENERATE] No available browsers, waiting...');
        await Future.delayed(const Duration(seconds: 2));
        i--;
        continue;
      }

      // IMMEDIATE RETRY LOOP - cycles through browsers up to maxRetries times for 403 errors
      final maxRetries = (Platform.isAndroid || Platform.isIOS) ? 10 : 7;
      bool success = false;
      
      while (!success && (scene.retryCount ?? 0) < maxRetries && task.status == TaskStatus.running) {
        // Get next available browser (round-robin cycles to different browser each retry)
        final retryProfile = (scene.retryCount ?? 0) == 0 ? profile : _getNextAvailableProfile();
        
        if (retryProfile == null) {
          // No healthy browser available
          print('[RETRY] No healthy browser available for retry');
          
          // Check if all browsers have hit 403 threshold - need to pause and wait
          if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
            final healthyCount = _countHealthyProfiles();
            if (healthyCount == 0) {
              print('[RETRY] ⏸ ALL browsers unhealthy - PAUSING for relogin...');
              
              // Trigger relogin for any profiles that need it
              _mobileService!.reloginAllNeeded(
                email: _email,
                password: _password,
                onAnySuccess: () {
                  print('[RETRY] ✓ Browser recovered from relogin');
                },
              );
              
              // Wait for at least one browser to become healthy
              int waitAttempts = 0;
              while (_countHealthyProfiles() == 0 && waitAttempts < 60 && task.status == TaskStatus.running) {
                await Future.delayed(const Duration(seconds: 5));
                waitAttempts++;
                print('[RETRY] Waiting for relogin... (${waitAttempts * 5}s, Healthy: ${_countHealthyProfiles()})');
              }
              
              if (_countHealthyProfiles() > 0) {
                print('[RETRY] ✓ Browser available, resuming...');
                continue; // Retry with the newly available browser
              } else {
                print('[RETRY] ✗ Timeout waiting for browser relogin');
                break; // Exit retry loop
              }
            }
          }
          
          // Wait a bit and retry
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }
        
        try {
          // Check for empty prompt - Veo3 API requires a text prompt even for I2V
          final hasImage = scene.firstFramePath != null || scene.lastFramePath != null;
          if (scene.prompt.trim().isEmpty) {
            if (hasImage) {
              scene.prompt = 'Animate this image with natural, fluid motion';
              print('[GENERATE] Using default I2V prompt for scene ${scene.sceneId}');
            } else {
              print('[GENERATE] Skipping scene ${scene.sceneId} - no prompt or image');
              scene.status = 'failed';
              scene.error = 'No prompt or image provided';
              _onTaskStatusChanged?.call(task);
              continue;
            }
          }

          // HTTP is fast - minimal delay needed (300-700ms)
          final delay = 300 + _random.nextInt(400); // 300-700ms
          print('[DELAY] Waiting ${delay}ms before HTTP request');
          await Future.delayed(Duration(milliseconds: delay));

          // Upload images if needed (before generating)
          if (scene.firstFramePath != null && scene.firstFrameMediaId == null) {
            print('[GENERATE] Uploading first frame image...');
            final result = await retryProfile.generator!.uploadImage(
              scene.firstFramePath!,
              retryProfile.accessToken!,
            );
            if (result is String) {
              scene.firstFrameMediaId = result;
              print('[GENERATE] ✓ First frame uploaded: $result');
            } else if (result is Map && result['error'] == true) {
              print('[GENERATE] ✗ First frame upload failed: ${result['message']}');
              scene.error = 'Image upload failed: ${result['message']}';
            }
          }
          
          if (scene.lastFramePath != null && scene.lastFrameMediaId == null) {
            print('[GENERATE] Uploading last frame image...');
            final result = await retryProfile.generator!.uploadImage(
              scene.lastFramePath!,
              retryProfile.accessToken!,
            );
            if (result is String) {
              scene.lastFrameMediaId = result;
              print('[GENERATE] ✓ Last frame uploaded: $result');
            } else if (result is Map && result['error'] == true) {
              print('[GENERATE] ✗ Last frame upload failed: ${result['message']}');
              scene.error = 'Image upload failed: ${result['message']}';
            }
          }

          await _generateWithProfile(task, scene, retryProfile, i + 1, scenesToProcess.length, apiModelKey);
          success = true; // Generation started successfully (now polling)
          
        } on _RetryableException catch (e) {
          // Retryable error (403, etc.) - retry with different browser after delay
          scene.retryCount = (scene.retryCount ?? 0) + 1;
          
          // Add delay before retry (3-5 seconds)
          final retryDelay = 3 + _random.nextInt(3);
          print('[RETRY] Scene ${scene.sceneId} retry ${scene.retryCount}/$maxRetries - waiting ${retryDelay}s...');
          print('[RETRY] Error was: ${e.message}');
          await Future.delayed(Duration(seconds: retryDelay));
          
          scene.status = 'queued';
          scene.error = 'Retrying (${scene.retryCount}/$maxRetries): ${e.message}';
          _onTaskStatusChanged?.call(task);
          
          if (scene.retryCount! >= maxRetries) {
            print('[GENERATE] ✗ Scene ${scene.sceneId} failed after $maxRetries retries: ${e.message}');
            scene.status = 'failed';
            scene.error = 'Failed after $maxRetries retries: ${e.message}';
            _onTaskStatusChanged?.call(task);
          }
          // Loop continues to retry with different browser
          
        } catch (e) {
          // Non-retryable error
          scene.status = 'failed';
          scene.error = e.toString();
          _onTaskStatusChanged?.call(task);
          print('[GENERATE] ✗ Exception: $e');
          success = true; // Exit retry loop (failed permanently)
        }
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
        print('[403 DETECTED] ${profile.name} - Count: ${profile.consecutive403Count}/16');
        
        // PYTHON STRATEGY: Use ALL 16 prefetched tokens before relogin 
        if (profile.consecutive403Count < 16) {
          print('[403 STRATEGY] Continuing to use remaining tokens (${16 - profile.consecutive403Count} left)...');
        } else {
          print('[403 STRATEGY] All 16 tokens exhausted → Triggering relogin');
          
          // Handle relogin for Chrome profiles
          if (profile is ChromeProfile && 
              _loginService != null && 
              _email.isNotEmpty && 
              _password.isNotEmpty) {
            print('[403 RELOGIN] ${profile.name} - All tokens used, relogging...');
            _loginService!.reloginProfile(profile, _email, _password);
            profile.consecutive403Count = 0; // Reset after triggering
          }
          
          // Handle token refresh for Mobile profiles
          if ((Platform.isAndroid || Platform.isIOS) && 
              _mobileService != null) {
            print('[403 RELOGIN] ${profile.name} - All tokens used, relogging...');
            final mobileProfile = profile as MobileProfile;
            
            _mobileService!.autoReloginProfile(
              mobileProfile,
              email: _email,
              password: _password,
              onSuccess: () {
                print('[403 RELOGIN] ✓ ${profile.name} relogin SUCCESS');
                mobileProfile.consecutive403Count = 0; // Reset on success
              }
            );
            
            profile.consecutive403Count = 0;
          }
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

    // Add to pending polls with saved access token (for HTTP polling)
    _pendingPolls[task.id]!.add(_PendingPoll(scene, sceneUuid ?? operationName, profile.accessToken!));

    print('[GENERATE] ✓ Scene ${scene.sceneId} queued for polling (operation: $operationName)');
  }

  /// Batch polling queue (single API call for ALL videos)
  Future<void> _processBatchPollingQueue(BulkTask task, int maxConcurrent) async {
    print('\n${'=' * 60}');
    print('POLLING CONSUMER STARTED (Batch Mode)');
    print('=' * 60);

    // Continue polling while task is running OR paused (paused = waiting for relogin)
    // Only exit if task is stopped or completed
    while ((task.status == TaskStatus.running || task.status == TaskStatus.paused) && 
           (!_generationComplete[task.id]! || _pendingPolls[task.id]!.isNotEmpty || _activeGenerations[task.id]! > 0)) {
      
      // If paused, wait for resume
      if (task.status == TaskStatus.paused) {
        print('[POLLER] Task paused, waiting...');
        while (task.status == TaskStatus.paused) {
          await Future.delayed(const Duration(seconds: 2));
        }
        print('[POLLER] Task resumed, continuing...');
      }
      
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
        // HTTP-BASED BATCH POLL (Python strategy - no browser needed!)
        // Extract access token from first pending poll (saved during generation)
        final firstPollToken = _pendingPolls[task.id]!.first.accessToken;
        
        // Build batch poll request
        final pollRequests = _pendingPolls[task.id]!.map((poll) =>
            PollRequest(poll.scene.operationName!, poll.sceneUuid)).toList();

        // Find generator for download (we still need it for download)
        dynamic pollGenerator;

        if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
          final healthyProfile = _mobileService!.getNextAvailableProfile();
          if (healthyProfile != null) {
            pollGenerator = healthyProfile.generator;
          }
        } else if (_profileManager != null) {
          for (final profile in _profileManager!.profiles) {
            if (profile.status == ProfileStatus.connected &&
                profile.generator != null) {
              pollGenerator = profile.generator;
              break;
            }
          }
        }

        // Use HTTP polling with saved token (continues working after relogin!)
        print('[HTTP POLL] Polling ${pollRequests.length} videos via HTTP...');
        
        // HTTP poll - doesn't need browser connection!
        List<Map<String, dynamic>>? results;
        if (pollGenerator != null) {
          results = await pollGenerator.pollVideoStatusBatchHTTP(pollRequests, firstPollToken);
        } else {
          // Fallback: use static HTTP client if no generator available
          print('[HTTP POLL] No generator, using static HTTP poll...');
          final generator = BrowserVideoGenerator();
          results = await generator.pollVideoStatusBatchHTTP(pollRequests, firstPollToken);
        }

        if (results == null || results.isEmpty) {
          print('[HTTP POLL] No results from batch poll');
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

          if (status == 'MEDIA_GENERATION_STATUS_COMPLETE' || 
              status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
            print('[SLOT] Video ready, freed slot - Active: ${_activeGenerations[task.id]}');

            String? videoUrl;
            String? videoMediaId;
            
            // Handle multiple possible response structures
            if (result.containsKey('video')) {
              videoUrl = result['video']?['uri'] as String?;
              final mediaGenId = result['video']?['mediaGenerationId'];
              if (mediaGenId != null) {
                videoMediaId = (mediaGenId is Map) ? mediaGenId['mediaGenerationId'] : mediaGenId.toString();
              }
            } 
            
            if (videoUrl == null && result.containsKey('operation')) {
              final op = result['operation'] as Map<String, dynamic>;
              final metadata = op['metadata'] as Map<String, dynamic>?;
              final video = (metadata != null) ? metadata['video'] : null;
              videoUrl = (video != null) ? (video['uri'] ?? video['fifeUrl']) : null;
              
              final mediaGenId = video?['mediaGenerationId'];
              if (mediaGenId != null) {
                videoMediaId = (mediaGenId is Map) ? mediaGenId['mediaGenerationId'] : mediaGenId.toString();
              }
            }

            if (videoUrl != null) {
              print('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
              if (videoMediaId != null) {
                scene.videoMediaId = videoMediaId;
                scene.downloadUrl = videoUrl;
                print('[POLLER] Video MediaId: $videoMediaId (saved for upscaling)');
              }
              _downloadVideo(task, scene, videoUrl, pollGenerator);
            } else {
              print('[POLLER] ✗ Scene ${scene.sceneId} COMPLETE but no video URL found');
              scene.status = 'failed';
              scene.error = 'No video URL';
              _onTaskStatusChanged?.call(task);
            }

            completedIndices.add(i);
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
            String errorMsg = 'Generation failed';
            
            // Extract error message
            final errorData = result['error'] as Map<String, dynamic>?;
            if (errorData != null) {
              errorMsg = errorData['message'] ?? 'Generation failed';
            } else if (result.containsKey('operation')) {
              final op = result['operation'] as Map<String, dynamic>;
              final metadata = op['metadata'] as Map<String, dynamic>?;
              final errorDetails = (metadata != null) ? metadata['error'] : null;
              if (errorDetails != null) {
                errorMsg = '${errorDetails['message'] ?? 'No details'}';
              }
            }

            print('[POLLER] ✗ Scene ${scene.sceneId} FAILED: $errorMsg');
            
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

      // Use HTTP download (no browser needed - Python strategy)
      final fileSize = await generator.downloadVideoHTTP(videoUrl, outputPath);

      scene.videoPath = outputPath;
      scene.fileSize = fileSize;
      scene.downloadUrl = videoUrl;
      scene.generatedAt = DateTime.now().toIso8601String();
      scene.status = 'completed';
      _onTaskStatusChanged?.call(task);

      // Update notification with progress (only every 5 videos or at completion to reduce spam)
      final completed = task.scenes.where((s) => s.status == 'completed').length;
      final total = task.scenes.length;
      if (completed % 5 == 0 || completed == total) {
        await ForegroundServiceHelper.updateStatus('$completed/$total | ${task.name}');
      }

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
  final String accessToken; // Store token for HTTP-based polling

  _PendingPoll(this.scene, this.sceneUuid, this.accessToken);
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
    if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
      return _mobileService!.countConnected();
    }
    return _profileManager?.countConnectedProfiles() ?? 0;
  }

  dynamic _getNextAvailableProfile() {
    if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
      return _mobileService!.getNextAvailableProfile();
    }
    return _profileManager?.getNextAvailableProfile();
  }
  
  /// Count profiles that haven't hit 403 threshold
  int _countHealthyProfiles() {
    if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
      return _mobileService!.countHealthy();
    }
    // For desktop, return all connected count (no 403 filtering on PC)
    if (_profileManager != null) {
      return _profileManager!.countConnectedProfiles();
    }
    return 0;
  }
}
