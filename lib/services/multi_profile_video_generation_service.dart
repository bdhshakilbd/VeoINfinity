import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'browser_video_generator.dart';
import 'profile_manager_service.dart';
import 'multi_profile_login_service.dart';
import '../utils/config.dart';
import '../models/scene_data.dart';

/// Shared video generation service with multi-browser support, batch polling,
/// 403 handling, and retry logic (up to 7 times) - matches Python implementation
class MultiProfileVideoGenerationService {
  final ProfileManagerService profileManager;
  final MultiProfileLoginService loginService;
  final String email;
  final String password;
  
  // Generation state
  int _activeGenerationsCount = 0;
  final List<_PendingPoll> _pendingPolls = [];
  bool _isRunning = false;
  bool _isPaused = false;
  bool _generationComplete = false;
  
  // Single browser mode (fallback)
  BrowserVideoGenerator? _singleGenerator;
  String? _singleAccessToken;
  
  // Internal variables
  final Random _random = Random();
  
  // Callbacks
  final void Function(SceneData scene)? onSceneStatusChanged;
  final void Function(String message)? onLog;

  MultiProfileVideoGenerationService({
    required this.profileManager,
    required this.loginService,
    required this.email,
    required this.password,
    this.onSceneStatusChanged,
    this.onLog,
  });

  void log(String message) {
    print(message);
    onLog?.call(message);
  }

  /// Start concurrent video generation for a list of scenes
  Future<void> generateVideos({
    required List<SceneData> scenes,
    required String model,
    required String aspectRatio,
    required String accountType,
    int fromIndex = 0,
    int toIndex = -1,
    bool boostMode = false, // BOOST: 4 concurrent per browser
  }) async {
    if (scenes.isEmpty) {
      log('[ERROR] No scenes to process');
      return;
    }
    
    _isRunning = true;
    _isPaused = false;
    _generationComplete = false;
    _activeGenerationsCount = 0;
    _pendingPolls.clear();
    
    final endIndex = toIndex < 0 ? scenes.length - 1 : toIndex;
    final scenesToProcess = scenes
        .skip(fromIndex)
        .take(endIndex - fromIndex + 1)
        .where((s) => s.status == 'queued')
        .toList();

    log('\n${'=' * 60}');
    log('MULTI-BROWSER CONCURRENT GENERATION');
    log('Connected Browsers: ${profileManager.countConnectedProfiles()}');
    log('=' * 60);

    log('\n[QUEUE] Processing ${scenesToProcess.length} scenes (from $fromIndex to $endIndex)');
    log('[QUEUE] Model: $model');

    // Convert model display name to API key
    final apiModelKey = AppConfig.getApiModelKey(model, accountType);
    log('[QUEUE] API Model Key: $apiModelKey');

    // Determine concurrency limit based on model and boost mode
    final isRelaxedModel = model.contains('Lower Priority') || model.contains('relaxed');
    final baseConcurrent = isRelaxedModel ? 4 : 10;
    
    // BOOST MODE: Multiply by browser count (4 concurrent per browser)
    final connectedBrowsers = profileManager.countConnectedProfiles();
    final maxConcurrent = boostMode && connectedBrowsers > 0
        ? baseConcurrent * connectedBrowsers
        : baseConcurrent;
    
    log('[CONCURRENT] Base: $baseConcurrent, Browsers: $connectedBrowsers, Boost: $boostMode');
    log('[CONCURRENT] Max concurrent: $maxConcurrent ${boostMode ? "(BOOST MODE: ${connectedBrowsers}x speed!)" : ""}');

    try {
      // Start poll worker in background
      _pollWorker(apiModelKey, aspectRatio, accountType);

      // Process scenes with round-robin browser selection
      await _processQueue(scenesToProcess, maxConcurrent, apiModelKey, aspectRatio, accountType);

      // Signal completion
      _generationComplete = true;

      // Wait for polls and handle retries
      while (_isRunning && (_pendingPolls.isNotEmpty || _activeGenerationsCount > 0)) {
        await Future.delayed(const Duration(seconds: 2));

        // Check for retry scenes
        final retryScenes = scenes
            .where((s) => s.status == 'queued' && (s.retryCount ?? 0) > 0)
            .toList();

        if (retryScenes.isNotEmpty && _activeGenerationsCount < maxConcurrent) {
          log('[RETRY] Found ${retryScenes.length} scenes for retry');
          await _processQueue(retryScenes, maxConcurrent, apiModelKey, aspectRatio, accountType);
        }
      }

      log('\n${'=' * 60}');
      log('MULTI-BROWSER GENERATION COMPLETE');
      log('=' * 60);
    } catch (e) {
      log('\n[ERROR] Fatal error: $e');
    } finally {
      _isRunning = false;
    }
  }

  /// Process queue with round-robin browser selection
  Future<void> _processQueue(
    List<SceneData> scenesToProcess,
    int maxConcurrent,
    String apiModelKey,
    String aspectRatio,
    String accountType,
  ) async {
    log('\n${'=' * 60}');
    log('MULTI-PROFILE PRODUCER STARTED');
    log('=' * 60');

    // Save original total to prevent count from increasing during retries
    final originalTotal = scenesToProcess.length;

    for (var i = 0; i < scenesToProcess.length; i++) {
      if (!_isRunning) {
        log('\n[STOP] Generation stopped by user');
        break;
      }

      while (_isPaused && _isRunning) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Wait for available slot
      while (_activeGenerationsCount >= maxConcurrent && _isRunning) {
        log('\r[LIMIT] Waiting for slots (Active: $_activeGenerationsCount/$maxConcurrent)...');
        await Future.delayed(const Duration(seconds: 1));
      }

      final scene = scenesToProcess[i];

      // Get next available browser (round-robin)
      final profile = profileManager.getNextAvailableProfile();
      if (profile == null) {
        log('[GENERATE] No available browsers, waiting...');
        await Future.delayed(const Duration(seconds: 2));
        i--;
        continue;
      }

      try {
        // Anti-detection delay
        if (i > 0) {
          final jitter = 2.0 + (3.0 * _random.nextDouble());
          log('\n[ANTI-BOT] Waiting ${jitter.toStringAsFixed(1)}s');
          await Future.delayed(Duration(milliseconds: (jitter * 1000).toInt()));
        }

        // Use original total instead of growing list length
        await _generateWithProfile(scene, profile, i + 1, originalTotal, apiModelKey, aspectRatio);
      } on _RetryableException catch (e) {
        // Retryable error - push back to queue
        scene.retryCount = (scene.retryCount ?? 0) + 1;

        if (scene.retryCount! < 10) {
          log('[RETRY] Scene ${scene.sceneId} retry ${scene.retryCount}/10 - pushing to front of queue');
          scene.status = 'queued';
          scene.error = 'Retrying (${scene.retryCount}/10): ${e.message}';
          onSceneStatusChanged?.call(scene);
          // Insert at front of queue (after current position) for immediate retry
          scenesToProcess.insert(i + 1, scene);
        } else {
          log('[GENERATE] ✗ Scene ${scene.sceneId} failed after 10 retries: ${e.message}');
          scene.status = 'failed';
          scene.error = 'Failed after 10 retries: ${e.message}';
          onSceneStatusChanged?.call(scene);
        }
      } catch (e) {
        scene.status = 'failed';
        scene.error = e.toString();
        onSceneStatusChanged?.call(scene);
        log('[GENERATE] ✗ Exception: $e');
      }
    }

    log('\n[PRODUCER] All scenes processed');
  }

  /// Generate video using specific browser profile
  Future<void> _generateWithProfile(
    SceneData scene,
    ChromeProfile profile,
    int currentIndex,
    int totalScenes,
    String apiModelKey,
    String aspectRatio,
  ) async {
    // Take slot immediately
    _activeGenerationsCount++;
    log('[SLOT] Took slot - Active: $_activeGenerationsCount');

    scene.status = 'generating';
    onSceneStatusChanged?.call(scene);

    log('\n[GENERATE $currentIndex/$totalScenes] Scene ${scene.sceneId}');
    log('[GENERATE] Browser: ${profile.name} (Port: ${profile.debugPort})');
    log('[GENERATE] Using Direct API Method (batchAsyncGenerateVideoText)');
    log('[GENERATE] Model: $apiModelKey');

    final result = await profile.generator!.generateVideo(
      prompt: scene.prompt,
      accessToken: profile.accessToken!,
      aspectRatio: aspectRatio,
      model: apiModelKey,
      startImageMediaId: scene.firstFrameMediaId,
      endImageMediaId: scene.lastFrameMediaId,
    );

    if (result == null) {
      _activeGenerationsCount--;
      log('[SLOT] Released slot (null result) - Active: $_activeGenerationsCount');
      throw _RetryableException('No result from generateVideo');
    }

    // Check for errors
    if (result['status'] != null && result['status'] != 200) {
      final statusCode = result['status'] as int;
      final errorMsg = result['error'] ?? result['statusText'] ?? 'API error';

      if (statusCode == 403) {
        profile.consecutive403Count++;
        log('[403] ${profile.name} 403 count: ${profile.consecutive403Count}/3');

        if (profile.consecutive403Count >= 3 && email.isNotEmpty && password.isNotEmpty) {
          log('[403] ${profile.name} threshold reached, triggering relogin...');
          loginService.reloginProfile(profile, email, password);
        }
      }

      _activeGenerationsCount--;
      log('[SLOT] Released slot (API error $statusCode) - Active: $_activeGenerationsCount');
      throw _RetryableException('API error $statusCode: $errorMsg');
    }

    if (result['success'] != true) {
      _activeGenerationsCount--;
      log('[SLOT] Released slot (API failure) - Active: $_activeGenerationsCount');
      throw _RetryableException(result['error'] ?? 'Generation failed');
    }

    // Extract operation name from nested structure
    final responseData = result['data'] as Map<String, dynamic>;
    final operations = responseData['operations'] as List?;
    if (operations == null || operations.isEmpty) {
      _activeGenerationsCount--;
      throw _RetryableException('No operations in response');
    }

    final operationWrapper = operations[0] as Map<String, dynamic>;
    final operation = operationWrapper['operation'] as Map<String, dynamic>?;
    if (operation == null) {
      _activeGenerationsCount--;
      throw _RetryableException('No operation object in response');
    }

    final operationName = operation['name'] as String?;
    if (operationName == null) {
      _activeGenerationsCount--;
      throw _RetryableException('No operation name in response');
    }

    final sceneUuid = operationWrapper['sceneId'] as String? ?? result['sceneId'] as String?;

    scene.operationName = operationName;
    scene.status = 'polling';
    onSceneStatusChanged?.call(scene);

    // Add to pending polls
    _pendingPolls.add(_PendingPoll(scene, sceneUuid ?? operationName));

    log('[GENERATE] ✓ Scene ${scene.sceneId} queued for polling (operation: $operationName)');
  }

  /// Poll worker using batch polling
  Future<void> _pollWorker(String apiModelKey, String aspectRatio, String accountType) async {
    log('\n${'=' * 60}');
    log('THREAD 2: POLLING CONSUMER STARTED (Batch Mode)');
    log('=' * 60);

    while (_isRunning || _pendingPolls.isNotEmpty) {
      if (_pendingPolls.isEmpty) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      final pollInterval = 3 + _random.nextInt(3); // 3-5 seconds
      log('\n[POLLER] Monitoring ${_pendingPolls.length} active videos... (Next check in ${pollInterval}s)');

      try {
        // Build batch poll request
        final pollRequests = _pendingPolls.map((poll) =>
            PollRequest(poll.scene.operationName!, poll.sceneUuid)).toList();

        // Find generator for polling
        BrowserVideoGenerator? pollGenerator;
        String? pollToken;

        for (final profile in profileManager.profiles) {
          if (profile.status == ProfileStatus.connected &&
              profile.generator != null &&
              profile.accessToken != null) {
            pollGenerator = profile.generator;
            pollToken = profile.accessToken;
            break;
          }
        }

        if (pollGenerator == null || pollToken == null) {
          log('[POLLER] No connected browser - skipping poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        // Batch poll
        final results = await pollGenerator.pollVideoStatusBatch(pollRequests, pollToken);

        if (results == null || results.isEmpty) {
          log('[POLLER] No results from batch poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        // Process results
        final completedIndices = <int>[];

        for (var i = 0; i < results.length && i < _pendingPolls.length; i++) {
          final result = results[i];
          final poll = _pendingPolls[i];
          final scene = poll.scene;
          final status = result['status'] as String?;

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            _activeGenerationsCount--;
            log('[SLOT] Video ready, freed slot - Active: $_activeGenerationsCount');

            String? videoUrl;
            if (result.containsKey('operation')) {
              final metadata = (result['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] as String?;
            }

            if (videoUrl != null) {
              log('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
              _downloadVideo(scene, videoUrl, pollGenerator);
            } else {
              scene.status = 'failed';
              scene.error = 'No video URL';
              onSceneStatusChanged?.call(scene);
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
            _activeGenerationsCount--;

            if (scene.retryCount! < 10) {
              log('[RETRY] Scene ${scene.sceneId} poll failed (${scene.retryCount}/10) - pushing back for regeneration');
              scene.status = 'queued';
              scene.operationName = null;
              scene.error = 'Retrying (${scene.retryCount}/10): $errorMsg';
              onSceneStatusChanged?.call(scene);
            } else {
              log('[POLLER] ✗ Scene ${scene.sceneId} failed after 10 retries: $errorMsg');
              scene.status = 'failed';
              scene.error = 'Failed after 10 retries: $errorMsg';
              onSceneStatusChanged?.call(scene);
            }

            completedIndices.add(i);
          }
        }

        // Remove completed items
        for (final index in completedIndices.reversed) {
          _pendingPolls.removeAt(index);
        }
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('closed') || errorStr.contains('WebSocket')) {
          log('[POLLER] WebSocket closed (browser relogging?) - skipping poll');
        } else {
          log('[POLLER] Error during batch poll: $e');
        }
      }

      if (_pendingPolls.isNotEmpty) {
        await Future.delayed(Duration(seconds: pollInterval));
      }
    }

    log('[POLLER] Poll worker finished');
  }

  /// Download video
  Future<void> _downloadVideo(SceneData scene, String videoUrl, BrowserVideoGenerator generator) async {
    try {
      scene.status = 'downloading';
      onSceneStatusChanged?.call(scene);
      log('[DOWNLOAD] Scene ${scene.sceneId} STARTED');

      final outputDir = Directory('output');
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }
      final outputPath = '${outputDir.path}/scene_${scene.sceneId}.mp4';

      final fileSize = await generator.downloadVideo(videoUrl, outputPath);

      scene.videoPath = outputPath;
      scene.downloadUrl = videoUrl;
      scene.fileSize = fileSize;
      scene.generatedAt = DateTime.now().toIso8601String();
      scene.status = 'completed';
      onSceneStatusChanged?.call(scene);

      log('[DOWNLOAD] ✓ Scene ${scene.sceneId} Complete (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      scene.status = 'failed';
      scene.error = 'Download failed: $e';
      onSceneStatusChanged?.call(scene);
      log('[DOWNLOAD] ✗ Scene ${scene.sceneId} Failed: $e');
    }
  }

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  void stop() => _isRunning = false;
  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;
  int get activeCount => _activeGenerationsCount;
  int get pendingPollsCount => _pendingPolls.length;
}

class _PendingPoll {
  final SceneData scene;
  final String sceneUuid;
  _PendingPoll(this.scene, this.sceneUuid);
}

class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);

  @override
  String toString() => message;
}
