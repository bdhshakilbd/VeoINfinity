import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'profile_manager_service.dart';
import 'multi_profile_login_service.dart';
import 'mobile/mobile_browser_service.dart';
import 'settings_service.dart';
import '../models/scene_data.dart';
import '../models/poll_request.dart';
import '../utils/config.dart';
import '../utils/browser_utils.dart';
import 'foreground_service.dart';

/// Unified Video Generation Service
/// Following the same flow as BulkTaskExecutor with proper concurrent handling
class VideoGenerationService {
  static final VideoGenerationService _instance = VideoGenerationService._internal();
  factory VideoGenerationService() => _instance;
  VideoGenerationService._internal();

  ProfileManagerService? _profileManager;
  MobileBrowserService? _mobileService;
  MultiProfileLoginService? _loginService;
  
  String _email = '';
  String _password = '';
  String _accountType = 'ai_ultra';
  String _projectFolder = ''; // Project folder for video downloads
  
  /// Set the project folder for video downloads
  void setProjectFolder(String folder) {
    _projectFolder = folder;
    print('[VideoGenerationService] Project folder set to: $folder');
  }
  
  /// Get the current project folder
  String get projectFolder => _projectFolder;
  
  /// Clear permanent failure status for a scene (allows manual retry)
  void clearPermanentFailure(int sceneId) {
    if (_permanentlyFailedSceneIds.contains(sceneId)) {
      _permanentlyFailedSceneIds.remove(sceneId);
      print('[VideoGenerationService] Cleared permanent failure for scene $sceneId - retry allowed');
    }
  }

  bool _isRunning = false;
  bool _isPaused = false;
  bool _generationComplete = false;
  
  // Queue and active tracking
  final List<SceneData> _queueToGenerate = [];
  final List<_ActiveVideo> _activeVideos = [];
  final Map<int, int> _videoRetryCounts = {};
  
  // Track active videos per account (for concurrency limiting)
  final Map<String, int> _activeVideosByAccount = {};
  
  // Track pending API calls (generation requests that haven't completed yet)
  int _pendingApiCalls = 0;
  
  int _successCount = 0;
  int _failedCount = 0;
  
  final Random _random = Random();
  DateTime? _last429Time; // Global 429 time - deprecated, use per-profile tracking
  
  // PER-PROFILE 429 TRACKING - each profile has independent cooldown
  final Map<String, DateTime> _profile429Times = {}; // profileName -> cooldown end time
  
  int _requestsSinceRelogin = 0;
  bool _justReloggedIn = false;
  
  // Track profiles that completed login but are waiting for browser to be ready
  // Producer should NOT use these profiles until removed from this set
  final Set<String> _profilesWaitingForReady = {};
  
  // Track scenes that failed due to 403 (to retry after relogin)
  final List<SceneData> _403FailedScenes = [];
  
  // Track permanently failed scenes (UNSAFE content) - never retry these
  final Set<int> _permanentlyFailedSceneIds = {};
  
  // Store interrupted polling videos for resume functionality
  final List<Map<String, dynamic>> _pendingPolls = [];
  
  /// Get pending polls count for UI
  int get pendingPollsCount => _pendingPolls.length;
  
  /// Check if there are pending polls to resume
  bool get hasPendingPolls => _pendingPolls.isNotEmpty;
  
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 60),
  ));

  void _safeAdd(String msg) {
    try {
      if (!_statusController.isClosed) _statusController.add(msg);
    } catch (_) {}
  }
  
  /// Log message to both console and status stream
  /// Filters out recaptcha noise and reduces verbose logging
  void _log(String msg) {
    // Always print to console for debugging
    print(msg);
    
    // Filter messages for status stream (shown in UI logs viewer)
    final lowerMsg = msg.toLowerCase();
    
    // Skip recaptcha-related messages (very aggressive filtering)
    if (lowerMsg.contains('recaptcha') || 
        lowerMsg.contains('captcha') ||
        lowerMsg.contains('token obtained') ||
        lowerMsg.contains('fresh recaptcha') ||
        lowerMsg.contains('fetching fresh') ||
        (lowerMsg.contains('fresh') && lowerMsg.contains('token')) ||
        (lowerMsg.contains('fetching') && lowerMsg.contains('token')) ||
        (lowerMsg.contains('obtained') && lowerMsg.contains('token')) ||
        lowerMsg.contains('🔑') || // Key emoji used for token messages
        msg.contains('🔑') || // Check non-lowercase too
        (msg.contains('✅') && lowerMsg.contains('token')) || // Checkmark with token
        msg.contains('0cAFcWeA7QyZxr9AbZk3') || // Token samples
        msg.contains('0cAFcWeA')) { // Shorter token pattern
      return; // Don't add to UI stream
    }
    
    // Skip raw API response dumps
    if (lowerMsg.contains('api response:') || 
        lowerMsg.contains('"error"') && lowerMsg.contains('"code"') ||
        msg.startsWith('{') && msg.contains('"error"')) {
      return; // Don't show raw JSON responses
    }
    
    // Simplify retry messages
    if (lowerMsg.contains('retry')) {
      // Extract scene ID if present
      final sceneMatch = RegExp(r'scene (\d+)').firstMatch(msg);
      final sceneId = sceneMatch?.group(1) ?? '?';
      
      // Check if it's a retry attempt message
      if (lowerMsg.contains('attempt')) {
        final attemptMatch = RegExp(r'(\d+)/(\d+)').firstMatch(msg);
        if (attemptMatch != null) {
          _safeAdd('[RETRY] Scene $sceneId - Retrying (${attemptMatch.group(0)})...');
          return;
        }
      }
    }
    
    // Simplify generation start messages
    if (msg.startsWith('[GENERATE]') && lowerMsg.contains('scene')) {
      final sceneMatch = RegExp(r'scene (\d+)').firstMatch(msg);
      if (sceneMatch != null) {
        final sceneId = sceneMatch.group(1);
        _safeAdd('[GENERATE] Generating video for Scene $sceneId...');
        return;
      }
    }
    
    // Pass through all other messages
    _safeAdd(msg);
  }

  void initialize({
    ProfileManagerService? profileManager,
    MobileBrowserService? mobileService,
    MultiProfileLoginService? loginService,
    String? email,
    String? password,
    String accountType = 'ai_ultra',
  }) {
    _profileManager = profileManager;
    _mobileService = mobileService;
    _loginService = loginService;
    if (email != null) _email = email;
    if (password != null) _password = password;
    _accountType = accountType;
  }

  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  
  bool _stopRequested = false;  // New flag for stop
  
  void stop() {
    print('[VGEN] Stop requested - stopping generation immediately');
    
    // Set stop flag - this makes producer exit immediately
    _stopRequested = true;
    _generationComplete = true;
    
    // Clear queue to stop new generations
    _queueToGenerate.clear();
    print('[VGEN] Cleared generation queue');
    
    // Polling continues in background for active videos
    if (_activeVideos.isNotEmpty) {
      print('[VGEN] ⏳ ${_activeVideos.length} videos still polling in background');
    }
    
    _safeAdd('STOPPED');
  }
  
  /// Resume polling for interrupted videos
  Future<void> resumePolling() async {
    if (_pendingPolls.isEmpty) {
      print('[VGEN] No pending polls to resume');
      return;
    }
    
    if (_isRunning) {
      print('[VGEN] Cannot resume - generation already in progress');
      return;
    }
    
    print('[VGEN] Resuming polling for ${_pendingPolls.length} videos...');
    _isRunning = true;
    _generationComplete = true; // No new generation, just polling
    
    // Transfer pending polls to active videos
    for (final poll in _pendingPolls) {
      final scene = poll['scene'] as SceneData;
      final sceneUuid = poll['sceneUuid'] as String;
      final token = poll['accessToken'] as String;
      final port = poll['profileDebugPort'] as int;
      
      // Find or create profile connection
      dynamic profile;
      if (_profileManager != null) {
        profile = _profileManager!.profiles.firstWhere(
          (p) => p.debugPort == port,
          orElse: () => _profileManager!.profiles.isNotEmpty 
            ? _profileManager!.profiles.first 
            : throw Exception('No profiles available'),
        );
        
        // Refresh token if needed
        if (profile.accessToken != null) {
          _activeVideos.add(_ActiveVideo(
            scene: scene,
            sceneUuid: sceneUuid,
            profile: profile,
            accessToken: profile.accessToken!,
          ));
        } else {
          _activeVideos.add(_ActiveVideo(
            scene: scene,
            sceneUuid: sceneUuid,
            profile: profile,
            accessToken: token,
          ));
        }
      } else {
        // Use stored token
        _activeVideos.add(_ActiveVideo(
          scene: scene,
          sceneUuid: sceneUuid,
          profile: null,
          accessToken: token,
        ));
      }
    }
    
    _pendingPolls.clear();
    print('[VGEN] Loaded ${_activeVideos.length} videos for polling');
    _safeAdd('UPDATE');
    
    // Start polling
    try {
      await _runBatchPolling();
    } finally {
      _isRunning = false;
      _safeAdd('COMPLETED');
      print('[VGEN] Resume polling complete');
    }
  }
  
  /// Clear pending polls
  void clearPendingPolls() {
    _pendingPolls.clear();
    print('[VGEN] Cleared pending polls');
    _safeAdd('UPDATE');
  }

  Future<void> startBatch(List<SceneData> scenes, {
    required String model,
    required String aspectRatio,
    int? maxConcurrentOverride,
    bool use10xBoostMode = true,
  }) async {
    // Allow concurrent batches - the queue system handles this properly
    // Don't check _isRunning - just add to queue and process
    
    if (!_isRunning) {
      _isRunning = true;
      _isPaused = false;
      _generationComplete = false;
    }
    
    // Don't clear these if a batch is already running - just add to them
    // _queueToGenerate.clear();
    // _activeVideos.clear();
    // _videoRetryCounts.clear();
    // _activeVideosByAccount.clear();
    // _successCount = 0;
    // _failedCount = 0;

    final apiModelKey = AppConfig.getApiModelKey(model, _accountType);
    
    // Determine if this is an I2V batch (any scene has an image)
    final hasI2V = scenes.any((s) => 
      s.firstFramePath != null || s.lastFramePath != null || 
      s.firstFrameMediaId != null || s.lastFrameMediaId != null
    );
    
    // Concurrency strategy:
    // maxPollingPerProfile = How many videos can be in polling/active state PER PROFILE
    // When Boost OFF: Sequential generation (await each), but allow 4 polling per profile
    // When Boost ON: Parallel generation, 4 for I2V / unlimited for T2V
    final maxPollingPerProfile = 4;  // Always allow 4 active videos per profile
    final maxConcurrentGeneration = !use10xBoostMode 
        ? 1  // Sequential when boost OFF
        : (maxConcurrentOverride ?? (hasI2V ? 4 : 999));  // Parallel when boost ON

    _log('${'=' * 60}');
    _log('[VGEN] 🚀 BATCH GENERATION STARTED');
    _log('[VGEN] 📊 Preparing ${scenes.length} scenes');
    _log('[VGEN] 🎬 Model: $model');
    _log('[VGEN] ⚡ Mode: ${!use10xBoostMode ? "SEQUENTIAL (1 at a time, 4 polling/profile)" : (hasI2V ? "I2V BOOST (4)" : "T2V BOOST (unlimited)")}');
    _log('${'=' * 60}');

    // Auto-connect browsers if needed (desktop only)
    if (!Platform.isAndroid && !Platform.isIOS) {
      await _autoConnectBrowsers();
    }

    await ForegroundServiceHelper.startService(status: 'Generating ${scenes.length} videos...');

    try {
      // CRITICAL: Clear any existing queue items to prevent duplicates
      _queueToGenerate.clear();
      
      // Initialize queue with all queued/failed scenes (excluding permanently failed, already processing, or duplicates)
      final scenesToProcess = scenes.where((s) => 
        // Only add queued or failed scenes
        (s.status == 'queued' || s.status == 'failed') &&
        // Skip permanently failed
        !_permanentlyFailedSceneIds.contains(s.sceneId) &&
        // Skip scenes already being polled (in _activeVideos)
        !_activeVideos.any((v) => v.scene.sceneId == s.sceneId)
      ).toList();
      
      _queueToGenerate.addAll(scenesToProcess);
      
      final skippedCount = scenes.length - scenesToProcess.length - scenes.where((s) => s.status == 'completed').length;
      final activeCount = _activeVideos.length;
      if (skippedCount > 0 || activeCount > 0) {
        if (activeCount > 0) {
          _log('[QUEUE] ⏭️ Skipped $activeCount scenes already being polled');
        }
        if (skippedCount > 0) {
          _log('[QUEUE] ⏭️ Skipped $skippedCount permanently failed/active scenes');
        }
      }
      
      _log('[QUEUE] 📝 Prepared ${_queueToGenerate.length} scenes');

      // Start polling in background (continues even after stop)
      _runBatchPolling(); // Not awaited - runs in background
      
      // Run generation (will exit immediately when stop is called)
      await _runConcurrentGeneration(apiModelKey, aspectRatio, maxPollingPerProfile, maxConcurrentGeneration, use10xBoostMode);

      // Only show complete message if not stopped
      if (!_stopRequested) {
        _log('');
        _log('${'=' * 60}');
        _log('[VGEN] ✅ BATCH COMPLETE');
        _log('[VGEN] 📊 Success: $_successCount | Failed: $_failedCount');
        _log('${'=' * 60}');
      } else {
        print('[VGEN] Generation stopped - polling continues in background for active videos');
      }
    } catch (e) {
      print('[VGEN] Batch failed: $e');
    } finally {
      print('[VGEN] Generation cleanup...');
      _isPaused = false;
      _generationComplete = true;
      _queueToGenerate.clear();
      
      // Only fully cleanup if no active polling
      if (_activeVideos.isEmpty) {
        _isRunning = false;
        _activeVideosByAccount.clear();
        await ForegroundServiceHelper.stopService();
        _safeAdd('COMPLETED');
        print('[VGEN] All done - ready for next batch');
      } else {
        // Polling continues in background
        print('[VGEN] ${_activeVideos.length} videos still being polled in background');
        _safeAdd('POLLING_BACKGROUND');
      }
      
      // Reset stop flag for next batch
      _stopRequested = false;
    }
  }

  /// Concurrent generation worker (PRODUCER)
  /// maxPollingPerProfile = how many videos can be in polling/active state per profile (always 4)
  /// maxConcurrentGeneration = how many generation requests to fire (1 = sequential, >1 = parallel)
  Future<void> _runConcurrentGeneration(String model, String aspectRatio, int maxPollingPerProfile, int maxConcurrentGeneration, bool use10xBoostMode) async {
    final isSequential = maxConcurrentGeneration == 1;
    
    print('\n[PRODUCER] Generation started');
    print('[PRODUCER] Mode: ${isSequential ? "SEQUENTIAL (await each)" : "PARALLEL ($maxConcurrentGeneration at a time)"}');
    print('[PRODUCER] Max polling per profile: $maxPollingPerProfile');

    while (_isRunning && _queueToGenerate.isNotEmpty && !_stopRequested) {
      // Handle pause
      while (_isPaused && _isRunning && !_stopRequested) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!_isRunning || _stopRequested) {
        print('[PRODUCER] Stop requested - exiting generation loop immediately');
        break;
      }

      // Get next available profile (automatically skips profiles in 429 cooldown)
      final profile = _getNextProfile();
      if (profile == null) {
        // Check if profiles are in 429 cooldown
        if (_profile429Times.isNotEmpty) {
          final now = DateTime.now();
          final cooldownsStr = _profile429Times.entries
              .where((e) => now.isBefore(e.value))
              .map((e) => '${e.key}(${e.value.difference(now).inSeconds}s)')
              .join(', ');
          if (cooldownsStr.isNotEmpty) {
            print('[PRODUCER] ⏸️ All profiles in 429 cooldown: $cooldownsStr - waiting 3s...');
            await Future.delayed(const Duration(seconds: 3));
            continue;
          }
        }
        
        // If no profiles are available, check if some are relogging or waiting for browser ready
        bool anyRelogging = _profileManager?.getProfilesByStatus(ProfileStatus.relogging).isNotEmpty ?? false;
        bool anyWaitingForReady = _profilesWaitingForReady.isNotEmpty;
        
        if (anyRelogging || anyWaitingForReady) {
          if (anyWaitingForReady) {
            print('[PRODUCER] ⏳ Profiles waiting for browser to be ready: ${_profilesWaitingForReady.join(", ")} - waiting...');
          } else {
            print('[PRODUCER] Profiles are relogging, waiting...');
          }
          await Future.delayed(const Duration(seconds: 3));
        } else {
          print('[PRODUCER] No available profiles, waiting...');
          await Future.delayed(const Duration(seconds: 2));
        }
        continue;
      }
      
      // Get profile identifier for tracking
      final profileKey = profile.name ?? profile.email ?? 'default';
      
      // Check if this profile has room for more active videos
      final activeForProfile = _activeVideosByAccount[profileKey] ?? 0;
      if (activeForProfile >= maxPollingPerProfile) {
        // This profile is at max, wait and try again
        print('[PRODUCER] Profile "$profileKey" at max ($activeForProfile/$maxPollingPerProfile), waiting...');
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      
      // CRITICAL: Check if profile has valid token before using it
      final token = profile.accessToken as String?;
      if (token == null || token.isEmpty) {
        print('[PRODUCER] Profile ${profile.name} has no token yet (relogin in progress), waiting...');
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }
      
      // CRITICAL: Throttle requests after relogin
      if (_justReloggedIn) {
        if (_requestsSinceRelogin >= 4) {
          print('[PRODUCER] ⏸️  Sent 4 requests after relogin - waiting 10s before continuing...');
          await Future.delayed(const Duration(seconds: 10));
          _justReloggedIn = false;
          _requestsSinceRelogin = 0;
          print('[PRODUCER] ▶️  Resuming normal generation flow');
        }
      }

      // Get next scene from queue
      if (_queueToGenerate.isEmpty) break;
      final scene = _queueToGenerate.removeAt(0);
      
      // CRITICAL: Skip scenes that are already being processed/polled/completed
      if (scene.status == 'polling' || scene.status == 'generating' || 
          scene.status == 'completed' || scene.status == 'downloading') {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - already ${scene.status}');
        _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1; // Don't count slot
        continue;
      }
      
      // Skip scenes that are in activeVideos (race condition protection)
      if (_activeVideos.any((v) => v.scene.sceneId == scene.sceneId)) {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - already in active polling');
        _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
        continue;
      }
      
      // CRITICAL: Skip scenes that are permanently failed (UNSAFE content)
      if (_permanentlyFailedSceneIds.contains(scene.sceneId)) {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - permanently failed (UNSAFE)');
        continue;
      }
      
      // Also skip scenes already marked as failed status
      if (scene.status == 'failed' && scene.error?.contains('Unsafe') == true) {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - already marked as failed (UNSAFE)');
        _permanentlyFailedSceneIds.add(scene.sceneId); // Add to set for future reference
        continue;
      }
      
      // Increment profile counter
      _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 0) + 1;
      print('[PRODUCER] Profile "$profileKey" active: ${_activeVideosByAccount[profileKey]}/$maxPollingPerProfile');
      
      // Increment pending API calls counter
      _pendingApiCalls++;
      print('[PRODUCER] Pending API calls: $_pendingApiCalls');
      
      if (isSequential) {
        // SEQUENTIAL MODE (Boost OFF): Await each generation before starting next
        print('[PRODUCER] SEQUENTIAL: Generating scene ${scene.sceneId}...');
        try {
          await _startSingleGeneration(scene, profile, model, aspectRatio, profileKey, use10xBoostMode);
          _pendingApiCalls--;
          print('[PRODUCER] Generation complete. Active polling: ${_activeVideosByAccount[profileKey]}/$maxPollingPerProfile');
        } catch (e) {
          _pendingApiCalls--;
          print('[PRODUCER] Generation failed: $e');
        }
        
        // Small delay between generations
        await Future.delayed(const Duration(seconds: 2));
      } else {
        // PARALLEL MODE (Boost ON): Fire and forget
        _startSingleGeneration(scene, profile, model, aspectRatio, profileKey, use10xBoostMode).then((_) {
          _pendingApiCalls--;
          print('[PRODUCER] API call completed. Pending: $_pendingApiCalls');
        }).catchError((e) {
          _pendingApiCalls--;
          print('[PRODUCER] API call failed: $e. Pending: $_pendingApiCalls');
        });
        
        // Increment relogin request counter if in post-relogin mode
        if (_justReloggedIn) {
          _requestsSinceRelogin++;
          print('[PRODUCER] Post-relogin requests: $_requestsSinceRelogin/4');
        }

        // Delay between API requests
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    _generationComplete = true;
    print('[PRODUCER] All scenes processed');
  }

  /// Sequential generation for Normal Mode - 100% reliable, slower
  Future<void> _runSequentialGeneration(String model, String aspectRatio) async {
    print('\n[NORMAL MODE] Sequential generation started');
    print('[NORMAL MODE] Processing scenes one by one - 100% reliable');

    final accountEmail = _email.isNotEmpty ? _email : 'default';

    while (_isRunning && _queueToGenerate.isNotEmpty) {
      // Handle pause
      while (_isPaused && _isRunning) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!_isRunning) {
        print('[NORMAL MODE] Stop requested');
        break;
      }

      // Get next scene
      final scene = _queueToGenerate.removeAt(0);
      
      // Get profile
      final profile = _getNextProfile();
      if (profile == null || profile.accessToken == null) {
        print('[NORMAL MODE] No valid profile available, requeueing scene');
        _queueToGenerate.insert(0, scene); // Put back at front
        await Future.delayed(const Duration(seconds: 5));
        continue;
      }

      print('[NORMAL MODE] 🎬 Starting Scene ${scene.sceneId} (${_queueToGenerate.length} remaining)');
      
      // CRITICAL: Wait for this scene to FULLY complete before moving to next
      try {
        await _startSingleGeneration(scene, profile, model, aspectRatio, accountEmail, false);
        print('[NORMALMODE] ✅ Scene ${scene.sceneId} completed successfully');
      } catch (e) {
        print('[NORMAL MODE] ❌ Scene ${scene.sceneId} failed: $e');
      }
      
      // Wait 3 seconds between videos for extra reliability
      print('[NORMAL MODE] ⏸️  Waiting 3s before next video...');
      await Future.delayed(const Duration(seconds: 3));
    }

    _generationComplete = true;
    print('[NORMAL MODE] All scenes processed');
  }

  /// Start generating a single video
  Future<void> _startSingleGeneration(
    SceneData scene,
    dynamic profile,
    String model,
    String aspectRatio,
    String accountEmail,
    bool use10xBoostMode,
  ) async {
    _log('[GENERATE] 🎬 Scene ${scene.sceneId} -> ${profile.name}');

    // Check retry limit (increased to 7 for better resilience)
    final retryCount = _videoRetryCounts[scene.sceneId] ?? 0;
    if (retryCount >= 7) {
      _log('[GENERATE] ❌ Scene ${scene.sceneId} exceeded max retries (7)');
      scene.status = 'failed';
      scene.error = 'Max retries exceeded';
      _failedCount++;
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
      _safeAdd('UPDATE');
      return;
    }

    try {
      scene.status = 'generating';
      scene.error = null;
      _safeAdd('UPDATE');

      // Ensure token is available (auto-navigate to Flow URL if needed)
      final tokenAvailable = await _ensureTokenAvailable(profile);
      if (!tokenAvailable) {
        throw Exception('Unable to obtain access token. Please check browser session.');
      }

      final token = profile.accessToken as String;
      // Token is guaranteed to exist at this point due to _ensureTokenAvailable check

      // Handle both DesktopGenerator (CDP) and MobileVideoGenerator (embedded)
      final generator = profile.generator; // Don't cast - use dynamic
      if (generator == null) throw Exception('No generator');
      
      // Check connection for DesktopGenerator (includes health monitoring for AMD Ryzen stability)
      if (generator is DesktopGenerator) {
        // Check connection health and auto-reconnect if needed (AMD Ryzen stability)
        if (!generator.isConnected || !generator.isHealthy) {
          _log('[GENERATE] ⚠️ Connection unhealthy, auto-reconnecting...');
          try {
            await generator.ensureConnected();
            _log('[GENERATE] ✅ Reconnected successfully');
          } catch (e) {
            throw Exception('Desktop browser connection failed: $e');
          }
        }
      } else if (generator is! MobileVideoGenerator) {
        // If it's not Desktop or Mobile, it's unknown
        throw Exception('Unknown generator type');
      }
      // Note: For MobileVideoGenerator, if we got the generator from profile, it's already ready

      // Upload images if needed
      if (scene.firstFramePath != null && scene.firstFrameMediaId == null) {
        _log('[GENERATE] 📤 Uploading first frame image...');
        scene.firstFrameMediaId = await _uploadImageHTTP(scene.firstFramePath!, token);
        if (scene.firstFrameMediaId != null) {
          _log('[GENERATE] ✅ First frame uploaded');
        }
      }
      if (scene.lastFramePath != null && scene.lastFrameMediaId == null) {
        _log('[GENERATE] 📤 Uploading last frame image...');
        scene.lastFrameMediaId = await _uploadImageHTTP(scene.lastFramePath!, token);
        if (scene.lastFrameMediaId != null) {
          _log('[GENERATE] ✅ Last frame uploaded');
        }
      }

      // Get fresh reCAPTCHA token for this scene (never reuse tokens!)
      String? recaptchaToken;
      // _log('[GENERATE] 🔑 Fetching fresh reCAPTCHA token for scene ${scene.sceneId}...');
      
      if (use10xBoostMode) {
        // Boost Mode: Fail fast if token missing
        recaptchaToken = await generator.getRecaptchaToken();
      } else {
        // Normal Mode: Retry loop for reCAPTCHA failure (max 5 attempts, 10s interval)
        int recaptchaRetryCount = 0;
        const int maxRecaptchaRetries = 5;
        
        while (recaptchaToken == null && _isRunning && recaptchaRetryCount < maxRecaptchaRetries) {
          try {
            recaptchaToken = await generator.getRecaptchaToken();
          } catch (e) {
            print('[NORMAL MODE] Recaptcha attempt failed: $e');
          }
          
          if (recaptchaToken == null) {
            recaptchaRetryCount++;
            _log('[NORMAL MODE] ⚠️ Recaptcha fetch failed (attempt $recaptchaRetryCount/$maxRecaptchaRetries). Waiting 10s...');
            // Wait 10 seconds before retry
            await Future.delayed(const Duration(seconds: 10));
            _log('[NORMAL MODE] 🔄 Retrying reCAPTCHA...');
          }
        }
        
        // If stopped while waiting or max retries exceeded
        if (recaptchaToken == null && !_isRunning) return;
        if (recaptchaToken == null) {
          _log('[NORMAL MODE] ❌ reCAPTCHA failed after $maxRecaptchaRetries attempts');
        }
      }
      
      if (recaptchaToken == null) throw Exception('Failed to get reCAPTCHA token');
      // _log('[GENERATE] ✅ Fresh reCAPTCHA token obtained (${recaptchaToken.substring(0, 20)}...)');

      // Convert model key to i2v variant if images are present
      String actualModel = model;
      final hasFirstFrame = scene.firstFrameMediaId != null;
      final hasLastFrame = scene.lastFrameMediaId != null;
      
      if (hasFirstFrame || hasLastFrame) {
        // Convert t2v model to i2v model
        if (actualModel.contains('_t2v_')) {
          // First, do the basic t2v -> i2v_s conversion
          actualModel = actualModel.replaceFirst('_t2v_', '_i2v_s_');
          
          // If both frames are present, we need to insert _fl after _fast or _quality
          if (hasFirstFrame && hasLastFrame) {
            // Pattern: veo_3_1_i2v_s_fast_ultra -> veo_3_1_i2v_s_fast_fl_ultra
            // Pattern: veo_3_1_i2v_s_fast_ultra_relaxed -> veo_3_1_i2v_s_fast_fl_ultra_relaxed
            // Insert _fl after _fast or _quality but before _ultra or _relaxed or end
            
            // Use regex to insert _fl in the right place
            if (actualModel.contains('_fast_') && !actualModel.contains('_fl_')) {
              actualModel = actualModel.replaceFirst('_fast_', '_fast_fl_');
            } else if (actualModel.contains('_quality_') && !actualModel.contains('_fl_')) {
              actualModel = actualModel.replaceFirst('_quality_', '_quality_fl_');
            }
          }
          _log('[GENERATE] 🔄 Converted model to I2V: $actualModel');
        }
      }
      
      // Add portrait variant if aspect ratio is portrait
      // Portrait uses _portrait_ in the middle, not _p at the end
      if (aspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT') {
        // Replace _fast_ with _fast_portrait_ or _quality_ with _quality_portrait_
        if (actualModel.contains('_fast_') && !actualModel.contains('_portrait_')) {
          actualModel = actualModel.replaceFirst('_fast_', '_fast_portrait_');
          print('[GENERATE] Added portrait variant: $actualModel');
        } else if (actualModel.contains('_quality_') && !actualModel.contains('_portrait_')) {
          actualModel = actualModel.replaceFirst('_quality_', '_quality_portrait_');
          print('[GENERATE] Added portrait variant: $actualModel');
        }
      }

      // Use fallback prompt for I2V if no prompt provided
      String promptToUse = scene.prompt;
      if ((promptToUse.isEmpty || promptToUse.trim().isEmpty) && (hasFirstFrame || hasLastFrame)) {
        promptToUse = 'Animate this';
        _log('[GENERATE] Using fallback prompt for I2V: "$promptToUse"');
      }

      // Generate video via browser fetch
      final result = await generator.generateVideo(
        prompt: promptToUse,
        accessToken: token,
        aspectRatio: aspectRatio,
        model: actualModel,
        startImageMediaId: scene.firstFrameMediaId,
        endImageMediaId: scene.lastFrameMediaId,
        recaptchaToken: recaptchaToken,
      );

      // Note: Full response logged to console only (not shown in UI logs)

      // Check for 403 error (including reCAPTCHA errors as they are often session-related)
      final errorStr = result?['error']?.toString().toLowerCase() ?? '';
      if (result != null && (result['error']?.toString().contains('403') == true || 
          result['data']?['error']?['code'] == 403 ||
          errorStr.contains('recaptcha'))) {
        _handle403Error(scene, profile, accountEmail);
        return;
      }

      // Check for 429 error (quota exhausted)
      if (result != null && (result['error']?.toString().contains('429') == true ||
          result['error']?.toString().contains('exhausted') == true)) {
        final profileName = profile?.name ?? 'unknown';
        _handle429Error(scene, accountEmail, profileName: profileName);
        return;
      }

      if (result == null || result['success'] != true) {
        throw Exception(result?['error'] ?? 'Generation failed');
      }

      // Extract operation name
      final data = result['data'] as Map<String, dynamic>;
      final operations = data['operations'] as List?;
      if (operations == null || operations.isEmpty) {
        throw Exception('No operations in response');
      }

      final operation = operations[0] as Map<String, dynamic>;
      final opData = operation['operation'] as Map<String, dynamic>?;
      final operationName = opData?['name'] as String?;
      if (operationName == null) {
        throw Exception('No operation name in response');
      }

      scene.operationName = operationName;
      scene.status = 'polling';
      _safeAdd('UPDATE');

      // Reset 403 counter and refresh flag on success
      try { 
        profile.consecutive403Count = 0; 
        profile.browserRefreshedThisSession = false; // Allow refresh in future error cycles
      } catch (_) {}

      // Add to active videos for batch polling
      final sceneUuid = operation['sceneId']?.toString() ?? operationName;
      _activeVideos.add(_ActiveVideo(
        scene: scene,
        sceneUuid: sceneUuid,
        profile: profile,
        accessToken: token,
      ));

      _log('[GENERATE] ✅ Scene ${scene.sceneId} queued for polling');

    } catch (e) {
      _log('[GENERATE] ❌ Scene ${scene.sceneId} error: $e');
      
      // Increment retry counter
      _videoRetryCounts[scene.sceneId] = (_videoRetryCounts[scene.sceneId] ?? 0) + 1;
      final retryCount = _videoRetryCounts[scene.sceneId] ?? 0;
      
      // If within retry limit, re-queue at front for instant retry
      if (retryCount < 7) {
        scene.status = 'queued';
        scene.error = null;
        _queueToGenerate.insert(0, scene); // Insert at front for priority
        _log('[RETRY] 🔄 Scene ${scene.sceneId} re-queued at FRONT (retry $retryCount/7)');
      } else {
        // Max retries exceeded, mark as failed
        scene.status = 'failed';
        scene.error = 'Failed after $retryCount attempts: ${e.toString()}';
        _failedCount++;
        _log('[RETRY] ❌ Scene ${scene.sceneId} failed permanently after $retryCount attempts');
      }
      
      _safeAdd('UPDATE');
      
      // Decrement account counter on failure
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    }
  }

  /// Handle 403 or reCAPTCHA error: increment counter, trigger relogin, re-queue scene
  void _handle403Error(SceneData scene, dynamic profile, String accountEmail) async {
    // Decrement account counter
    _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    
    // Increment retry counter
    _videoRetryCounts[scene.sceneId] = (_videoRetryCounts[scene.sceneId] ?? 0) + 1;
    
    // Increment 403 counter for this profile
    try {
      profile.consecutive403Count = (profile.consecutive403Count ?? 0) + 1;
      _log('[403] ⚠️ ${profile.name} 403 count: ${profile.consecutive403Count}/7 | Scene retry ${_videoRetryCounts[scene.sceneId]}/7');
    } catch (_) {}

    // Wait 5 seconds before retry to avoid spam
    _log('[403] ⏳ Waiting 5s before retry...');
    await Future.delayed(const Duration(seconds: 5));

    // Check if scene is already in queue or active to prevent duplicates
    final alreadyInQueue = _queueToGenerate.any((s) => s.sceneId == scene.sceneId);
    final alreadyActive = _activeVideos.any((v) => v.scene.sceneId == scene.sceneId);
    
    if (alreadyInQueue || alreadyActive) {
      _log('[403] ⚠️ Scene ${scene.sceneId} already ${alreadyInQueue ? "in queue" : "active"} - skipping re-queue');
      return;
    }

    // Re-queue scene at FRONT for immediate retry with another profile
    scene.status = 'queued';
    scene.error = null;
    _queueToGenerate.insert(0, scene); // Insert at front for priority
    _log('[403] 🔄 Scene ${scene.sceneId} re-queued at FRONT for retry');
    _safeAdd('UPDATE');

    // Handle 403 errors:
    // - At 3 consecutive 403s: Refresh the browser ONCE (may fix stale session)
    // - At 7 consecutive 403s: Trigger full relogin
    try {
      // At 3 consecutive 403s, refresh the browser to reset session state
      // But only if we haven't already done a refresh (tracked via flag)
      if (profile.consecutive403Count == 3) {
        bool alreadyRefreshed = false;
        try { alreadyRefreshed = profile.browserRefreshedThisSession ?? false; } catch (_) {}
        
        if (!alreadyRefreshed) {
          _log('[403] 🔄 ${profile.name} hit 3 consecutive 403s - refreshing browser...');
          try {
            final generator = profile.generator;
            if (generator != null && generator.isConnected) {
              // Refresh the page to reset reCAPTCHA and session
              await generator.executeJs('window.location.reload()');
              _log('[403] ✅ ${profile.name} browser refreshed - waiting 5s for page load...');
              await Future.delayed(const Duration(seconds: 5));
              
              // Re-apply mobile emulation after page refresh (mobile mode persists but just in case)
              try {
                await BrowserUtils.applyMobileEmulation(profile.debugPort);
              } catch (_) {}
              
              // Mark that we've done a refresh for this profile (won't reset counter!)
              // If refresh helps, API will succeed and reset counter. If not, counter continues to 7.
              try { profile.browserRefreshedThisSession = true; } catch (_) {}
              _log('[403] ✅ ${profile.name} browser refreshed, continuing with count at 3...');
            }
          } catch (e) {
            _log('[403] ⚠️ Browser refresh failed for ${profile.name}: $e');
          }
        } else {
          _log('[403] ⚠️ ${profile.name} already refreshed this session - continuing to relogin threshold...');
        }
      }
      
      // At 7 consecutive 403s, trigger full relogin
      if (profile.consecutive403Count >= 7) {
        _log('[403] 🔄 ${profile.name} reached 7 consecutive 403s - triggering relogin');
        
        // Check if browser/generator is still connected
        final generator = profile.generator;
        if (generator == null || !generator.isConnected) {
          _log('[403] ⚠️ ${profile.name} disconnected - trying other browsers');
          // Scene is already queued, will be picked up by another browser
          return;
        }
        
        // Check if this is a mobile profile (MobileProfile) or desktop (ChromeProfile)
        final isMobileProfile = profile.runtimeType.toString().contains('Mobile');
        
        if (isMobileProfile) {
          // Mobile profiles: trigger auto-relogin (scene already queued above)
          
          // Cast to MobileProfile
          final mobileProfile = profile as MobileProfile;
          
          // Block profile temporarily (will be unblocked after relogin)
          mobileProfile.status = MobileProfileStatus.loading;
          mobileProfile.isReloginInProgress = true;
          
          // Get fresh credentials from SettingsService
          final accounts = SettingsService.instance.getGoogleAccounts();
          final firstAccount = accounts.isNotEmpty ? accounts.first : null;
          final email = firstAccount?['email'] ?? firstAccount?['username'] ?? _email;
          final password = firstAccount?['password'] ?? _password;
          
          _log('[403] 🔐 Retrieved credentials from settings: email=${email != null ? "set" : "NULL"}, password=${password != null ? "set" : "NULL"}');
          
          // Check if we have login credentials
          if (email != null && password != null && mobileProfile.generator != null) {
            _log('[403] 🔑 Starting auto-relogin for ${profile.name}...');
            
            // CRITICAL: Clear EVERYTHING first to force fresh login + Rotate UA for anti-bot
            try {
              _log('[403] 🧹 Clearing ALL browser data (cookies, cache, storage, IndexedDB, history)...');
              
              // Clear all web storage
              await mobileProfile.controller?.webStorage.localStorage.clear();
              await mobileProfile.controller?.webStorage.sessionStorage.clear();
              
              // Clear all cookies
              final cookieManager = CookieManager.instance();
              await cookieManager.deleteAllCookies();
              
              // Clear cache and all data via JS (comprehensive cleanup)
              try {
                await mobileProfile.controller?.evaluateJavascript(source: '''
                  (async function() {
                    // Clear all IndexedDB databases
                    if (window.indexedDB && window.indexedDB.databases) {
                      const dbs = await window.indexedDB.databases();
                      for (const db of dbs) {
                        if (db.name) {
                          window.indexedDB.deleteDatabase(db.name);
                          console.log('[CLEAR] Deleted IndexedDB:', db.name);
                        }
                      }
                    }
                    
                    // Clear all caches
                    if (window.caches) {
                      const keys = await caches.keys();
                      for (const key of keys) {
                        await caches.delete(key);
                        console.log('[CLEAR] Deleted cache:', key);
                      }
                    }
                    
                    // Clear service worker registrations
                    if (navigator.serviceWorker) {
                      const regs = await navigator.serviceWorker.getRegistrations();
                      for (const reg of regs) {
                        await reg.unregister();
                        console.log('[CLEAR] Unregistered service worker');
                      }
                    }
                    
                    // Clear any stored credentials
                    if (navigator.credentials && navigator.credentials.preventSilentAccess) {
                      await navigator.credentials.preventSilentAccess();
                    }
                    
                    console.log('[CLEAR] ✅ All browser data cleared completely');
                  })();
                ''');
              } catch (jsError) {
                _log('[403] ⚠️ JS clear error (non-critical): $jsError');
              }
              
              // ANTI-BOT: Rotate user agent after clearing data
              try {
                final newUA = UserAgentRotator.getRandomUA();
                await mobileProfile.controller?.setSettings(
                  settings: InAppWebViewSettings(userAgent: newUA)
                );
                _log('[403] 🎭 User Agent rotated: ${newUA.substring(0, 60)}...');
              } catch (uaError) {
                _log('[403] ⚠️ Could not rotate UA: $uaError');
              }
              
              mobileProfile.accessToken = null; // Clear old token
              _log('[403] ✅ ALL data cleared + UA rotated - forcing completely fresh login');
            } catch (e) {
              _log('[403] ⚠️ Error clearing data: $e');
            }
            
            // Navigate to Flow page to trigger login
            try {
              await mobileProfile.controller?.loadUrl(
                urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow'))
              );
              _log('[403] 🌐 Navigated to Flow page');
              await Future.delayed(const Duration(seconds: 2)); // Wait for page load
            } catch (e) {
              _log('[403] ⚠️ Error navigating: $e');
            }
            
            // Trigger auto-relogin (don't await - runs in background)
            mobileProfile.generator!.autoLogin(email, password).then((success) {
              if (success) {
                _log('[403] ✅ Auto-relogin successful for ${profile.name}');
                mobileProfile.consecutive403Count = 0;
                mobileProfile.browserRefreshedThisSession = false; // Allow refresh in future cycles
                mobileProfile.isReloginInProgress = false;
                mobileProfile.status = MobileProfileStatus.ready;
              } else {
                _log('[403] ❌ Auto-relogin failed for ${profile.name}');
                mobileProfile.isReloginInProgress = false;
                mobileProfile.status = MobileProfileStatus.ready; // Still allow retry
              }
            });
            
            // Wait for fresh token (max 45 seconds for full login)
            final oldToken = mobileProfile.accessToken;
            _log('[403] ⏳ Waiting for fresh token (max 45s)...');
            
            int waitCount = 0;
            while (waitCount < 45) {
              await Future.delayed(const Duration(seconds: 1));
              waitCount++;
              
              final newToken = mobileProfile.accessToken;
              if (newToken != null && newToken.isNotEmpty && newToken != oldToken) {
                _log('[403] ✅ Fresh token received after ${waitCount}s!');
                mobileProfile.consecutive403Count = 0;
                mobileProfile.browserRefreshedThisSession = false; // Allow refresh in future cycles
                mobileProfile.isReloginInProgress = false;
                mobileProfile.status = MobileProfileStatus.ready;
                break;
              }
              
              // Show progress every 10s
              if (waitCount % 10 == 0) {
                _log('[403] ⏳ Still waiting for token... (${waitCount}s elapsed)');
              }
            }
            
            if (waitCount >= 45) {
              _log('[403] ⚠️ Timeout waiting for fresh token');
              mobileProfile.isReloginInProgress = false;
              mobileProfile.status = MobileProfileStatus.ready; // Allow retry anyway
            }
          } else {
            _log('[403] ❌ Cannot auto-relogin: missing credentials or generator');
            _log('[403] ⏸️ ${profile.name} blocked - needs manual relogin via UI');
            // Profile stays blocked until manual relogin
          }
          
          _safeAdd('UPDATE');
          return;
        }
        
        // Desktop profile - trigger full relogin (scene already queued above)
        if (_loginService != null) {
          
          // Trigger relogin (this is async but we don't await it)
          _loginService!.reloginProfile(profile, _email, _password);
          
          // Wait for fresh token (max 30 seconds)
          final oldToken = profile.accessToken as String?;
          _log('[403] ⏳ Waiting for fresh token...');
          
          int waitCount = 0;
          while (waitCount < 30) {
            await Future.delayed(const Duration(seconds: 1));
            waitCount++;
            
            final newToken = profile.accessToken as String?;
            if (newToken != null && newToken.isNotEmpty && newToken != oldToken) {
              _log('[403] ✅ Fresh token received after ${waitCount}s');
              profile.consecutive403Count = 0;
              try { profile.browserRefreshedThisSession = false; } catch (_) {} // Allow refresh in future cycles
              break;
            }
            
            // Check if browser disconnected during wait (works for both types)
            if (generator.isConnected == false) {
              _log('[403] ❌ Browser disconnected during relogin wait');
              scene.status = 'failed';
              scene.error = 'Browser disconnected during relogin';
              _failedCount++;
              _safeAdd('UPDATE');
              return;
            }
          }
          
          if (waitCount >= 30) {
            _log('[403] ⚠️ Timeout waiting for fresh token - will retry anyway');
            profile.consecutive403Count = 0;
            try { profile.browserRefreshedThisSession = false; } catch (_) {}
          }
        } else {
          _log('[403] ❌ Cannot relogin: loginService is null');
          profile.consecutive403Count = 0;
          try { profile.browserRefreshedThisSession = false; } catch (_) {}
        }
      }
    } catch (e) {
      _log('[403] ❌ Error handling 403: $e');
    }

    // Add to retry tracking (if not already tracked)
    if (!_403FailedScenes.any((s) => s.sceneId == scene.sceneId)) {
      _403FailedScenes.add(scene);
      _log('[403] 🔄 Scene ${scene.sceneId} added to 403 retry tracking');
    }
  }
  
  /// Handle 429 rate limit error: wait 50s, mark profile for cooldown and requeue at front
Future<void> _handle429Error(SceneData scene, String accountEmail, {String? profileName}) async {
  _log('[429] ⚠️ Rate limit hit for scene ${scene.sceneId}');
  
  // Increment retry counter
  _videoRetryCounts[scene.sceneId] = (_videoRetryCounts[scene.sceneId] ?? 0) + 1;
  
  // Mark THIS PROFILE for 50s cooldown (not all profiles!)
  if (profileName != null && profileName.isNotEmpty) {
    final cooldownEnd = DateTime.now().add(const Duration(seconds: 50));
    _profile429Times[profileName] = cooldownEnd;
    _log('[429] ⏸️ Profile $profileName in cooldown for 50s (other profiles continue)');
  }
  
  // Also set global time for backward compatibility
  _last429Time = DateTime.now();
  
  // Decrement account counter
  _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
  
  // Show queued status with simple error message at bottom
  scene.status = 'queued';
  scene.error = '429 limit exceed';
  _safeAdd('UPDATE');
  
  // Wait 50 seconds (no countdown updates)
  _log('[429] ⏳ Waiting 50s before retry...');
  await Future.delayed(const Duration(seconds: 50));
  
  // Check if stop was requested during wait
  if (_stopRequested) {
    _queueToGenerate.insert(0, scene);
    _safeAdd('UPDATE');
    return;
  }
  
  // Clear error and re-queue for retry
  scene.error = null;
  _queueToGenerate.insert(0, scene); // Put at front for immediate retry
  _log('[429] 🔄 Scene ${scene.sceneId} re-queued at FRONT for retry');
  _safeAdd('UPDATE');
}

  /// Batch polling worker (CONSUMER)
  Future<void> _runBatchPolling() async {
    print('\n[POLLER] Batch polling started');
    final Set<int> downloadingScenes = {};
    int emptyLoopCount = 0;

    // Continue polling as long as there are active videos, downloads, queued items, OR pending API calls
    // The poller should keep running until ALL work is truly done
    while (true) {
      final hasActiveWork = _activeVideos.isNotEmpty || downloadingScenes.isNotEmpty;
      final hasQueuedWork = _queueToGenerate.isNotEmpty;
      final hasPendingCalls = _pendingApiCalls > 0;
      
      if (!hasActiveWork && !hasQueuedWork && !hasPendingCalls) {
        // No active work, no queued work, and no pending API calls
        if (_generationComplete) {
          // Wait a bit to catch any videos that are being added asynchronously
          emptyLoopCount++;
          if (emptyLoopCount >= 3) {
            print('[POLLER] No work for 3 cycles and generation complete - exiting');
            break;
          }
          print('[POLLER] Waiting for potential async additions... ($emptyLoopCount/3)');
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        // Producer still running, wait for work
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      
      // Reset empty loop counter when we have work
      emptyLoopCount = 0;
      
      // If we have pending API calls but no active videos yet, wait
      if (_activeVideos.isEmpty && hasPendingCalls) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      
      // If we have active videos to poll, do the polling
      if (_activeVideos.isEmpty) {
        // No active videos yet, but queue has items - wait for producer
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      
      // CRITICAL: Pause polling if any profile is relogging
      // This prevents browser from becoming unresponsive during login
      bool anyRelogging = _profileManager?.getProfilesByStatus(ProfileStatus.relogging).isNotEmpty ?? false;
      if (anyRelogging) {
        print('[POLLER] ⏸️  Profile is relogging - pausing polling to avoid browser freeze...');
        await Future.delayed(const Duration(seconds: 5));
        continue; // Skip this poll cycle, check again after 5s
      }
      
      // Check if profiles have valid tokens before polling
      // This ensures we don't poll with expired/empty tokens
      bool allProfilesHaveTokens = true;
      for (final activeVideo in _activeVideos) {
        final token = activeVideo.accessToken;
        if (token == null || token.isEmpty) {
          allProfilesHaveTokens = false;
          print('[POLLER] ⏸️  Active video has no token - waiting for relogin to complete...');
          break;
        }
      }
      
      if (!allProfilesHaveTokens) {
        await Future.delayed(const Duration(seconds: 3));
        continue; // Skip this poll cycle
      }

      // 10s interval to reduce browser load
      print('[POLLER] Waiting 10s before batch poll...');
      await Future.delayed(const Duration(seconds: 10));

      await _pollAndUpdateActiveBatch(downloadingScenes);
    }

    // Poller finished - cleanup
    print('[POLLER] All videos polled and downloaded');
    _isRunning = false;
    _activeVideos.clear();
    _activeVideosByAccount.clear();
    await ForegroundServiceHelper.stopService();
    _safeAdd('COMPLETED');
  }

  /// Poll all active videos in a single batch and update statuses
  Future<void> _pollAndUpdateActiveBatch(Set<int> downloadingScenes) async {
    if (_activeVideos.isEmpty) return;

    print('\n[BATCH POLL] Polling ${_activeVideos.length} videos...');

    // Group by token for batch polling
    final Map<String, List<_ActiveVideo>> groups = {};
    for (final v in _activeVideos) {
      groups.putIfAbsent(v.accessToken, () => []).add(v);
    }

    for (final entry in groups.entries) {
      final token = entry.key;
      final groupVideos = entry.value;
      
      print('[BATCH POLL] Checking ${groupVideos.length} operation(s)...');

      // Build poll requests
      final requests = groupVideos
          .map((v) => PollRequest(v.scene.operationName!, v.sceneUuid))
          .toList();

      try {
        List<Map<String, dynamic>>? results;
        
        // Use browser-based polling if available and connected
        final profile = groupVideos.first.profile;
        final generator = profile?.generator;
        final isProfileRelogging = profile?.status == ProfileStatus.relogging || 
                                   profile?.status == MobileProfileStatus.loading;
        
        // Use browser polling if generator is connected AND profile is not relogging
        if (generator != null && generator.isConnected && !isProfileRelogging) {
          print('[BATCH POLL] Using browser polling for ${groupVideos.length} videos');
          results = await generator.pollVideoStatusBatchHTTP(requests, token);
        } else {
          // Fallback to HTTP polling when:
          // - No generator available
          // - Generator not connected
          // - Profile is relogging
          final reason = !generator?.isConnected == true ? 'browser not connected' : 
                        isProfileRelogging ? 'profile relogging' : 'no generator';
          print('[BATCH POLL] Using HTTP polling ($reason) for ${groupVideos.length} videos');
          results = await _pollVideoStatusBatchHTTP(requests, token);
        }

        if (results == null) {
          print('[BATCH POLL] No results from batch poll');
          continue;
        }

        // Process results
        for (var i = 0; i < results.length && i < groupVideos.length; i++) {
          final opData = results[i];
          final activeVideo = groupVideos[i];
          final scene = activeVideo.scene;

          // Get status from various possible locations
          String? status = opData['status']?.toString();
          if (status == null && opData['operation'] != null) {
            final metadata = opData['operation']['metadata'] as Map<String, dynamic>?;
            status = metadata?['status']?.toString();
          }
          
          _log('[POLL] 🔎 Scene ${scene.sceneId}: ${status ?? "IN_PROGRESS"}');

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL' ||
              (status?.toUpperCase().contains('SUCCESS') == true)) {
            
            // CRITICAL: Release slot using the correct profile key
            final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
            _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
            _activeVideos.remove(activeVideo);
            print('[POLL] ✅ Scene ${scene.sceneId} success - Profile "$profileKey" active: ${_activeVideosByAccount[profileKey]}');
            
            // CRITICAL: Remove from 403 retry list so it won't be re-queued after relogin
            _403FailedScenes.removeWhere((s) => s.sceneId == scene.sceneId);
            
            // Extract video URL and mediaId for upscaling
            String? videoUrl;
            String? mediaId;
            if (opData['operation'] != null) {
              final operation = opData['operation'] as Map<String, dynamic>?;
              final metadata = operation?['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] ?? video?['uri'];
              
              // The mediaGenerationId is only available in successful responses
              // Try multiple locations:
              // 1. Top-level mediaGenerationId from opData
              mediaId = opData['mediaGenerationId'] as String?;
              
              // 2. Nested in video metadata
              if (mediaId == null || mediaId.isEmpty) {
                mediaId = video?['mediaGenerationId'] as String?;
              }
              
              // 3. Fallback to operation name (for pending/in-progress)
              if (mediaId == null || mediaId.isEmpty) {
                mediaId = operation?['name'] as String?;
              }
              
              // 4. Last fallback: use the operationName we already saved
              if (mediaId == null && scene.operationName != null) {
                mediaId = scene.operationName;
                print('[BATCH POLL] Scene ${scene.sceneId} using existing operationName as mediaId');
              }
              
              // Save mediaId for upscaling
              if (mediaId != null && mediaId.isNotEmpty) {
                scene.videoMediaId = mediaId;
                print('[BATCH POLL] Scene ${scene.sceneId} mediaId saved: ${mediaId.substring(0, min(50, mediaId.length))}...');
              } else {
                print('[BATCH POLL] Scene ${scene.sceneId} WARNING: No mediaId found in response');
              }
            }

            if (videoUrl != null) {
              _log('[POLL] ✅ Scene ${scene.sceneId} completed - starting download');
              downloadingScenes.add(scene.sceneId);
              _downloadVideo(scene, videoUrl, downloadingScenes);
            }
          } else if (status?.toUpperCase().contains('FAIL') == true) {
            // Extract error message from response
            String? errorMessage;
            try {
              // Try to get error from various locations in the response
              if (opData['operation'] != null) {
                final operation = opData['operation'] as Map<String, dynamic>?;
                final metadata = operation?['metadata'] as Map<String, dynamic>?;
                errorMessage = metadata?['error']?.toString() ?? 
                              metadata?['errorMessage']?.toString() ??
                              operation?['error']?.toString();
              }
              if (errorMessage == null && opData['error'] != null) {
                errorMessage = opData['error'].toString();
              }
            } catch (_) {}
            
            // Log the full response for debugging
            print('[BATCH POLL] Scene ${scene.sceneId} FAILED - Full response: $opData');
            if (errorMessage != null) {
              print('[BATCH POLL] Error message: $errorMessage');
            }
            
            // Check retry count before marking as failed
            final retryCount = _videoRetryCounts[scene.sceneId] ?? 0;
            
            // Special handling for HIGH_TRAFFIC
            final isHighTraffic = errorMessage?.contains('HIGH_TRAFFIC') == true || 
                                errorMessage?.contains('high traffic') == true;
            
            // UNSAFE_GENERATION - Mark as permanently failed (no retry - same prompt will always fail)
            final isUnsafeGeneration = errorMessage?.contains('UNSAFE_GENERATION') == true ||
                                       errorMessage?.contains('unsafe') == true;
            
            if (isUnsafeGeneration) {
              _log('[POLL] 🚫 Scene ${scene.sceneId} UNSAFE content - marking as permanently failed');
              scene.status = 'failed';
              scene.error = 'Unsafe content detected - will not retry';
              _failedCount++;
              _activeVideos.remove(activeVideo);
              
              // ADD TO PERMANENTLY FAILED SET - never retry this scene
              _permanentlyFailedSceneIds.add(scene.sceneId);
              
              // Decrement counter using correct profile key
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              
              _safeAdd('UPDATE');
              continue; // Skip to next video
            }
            
            if (isHighTraffic) {
               print('[BATCH POLL] 🚦 High Traffic detected - triggering 30s cooldown...');
               _last429Time = DateTime.now(); // Triggers 30s wait in producer
            }
            
            final maxRetries = isHighTraffic ? 20 : 5; // Allow more retries for capacity issues

            if (retryCount < maxRetries) {
              // Retry the failed video
              _videoRetryCounts[scene.sceneId] = retryCount + 1;
              scene.status = 'queued';
              scene.error = errorMessage ?? 'Generation failed - retrying (${retryCount + 1}/5)';
              _queueToGenerate.insert(0, scene); // Re-queue at front for immediate retry
              _activeVideos.remove(activeVideo);
              
              // Decrement counter using correct profile key
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              
              _safeAdd('UPDATE');
              _log('[POLL] ⚠️ Scene ${scene.sceneId} failed - retrying (${retryCount + 1}/$maxRetries)');
            } else {
              // Max retries exceeded
              scene.status = 'failed';
              scene.error = 'Generation failed on server (max retries exceeded)';
              _failedCount++;
              _activeVideos.remove(activeVideo);
              
              // Decrement counter using correct profile key
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              
              _safeAdd('UPDATE');
              _log('[POLL] ❌ Scene ${scene.sceneId} failed permanently after $maxRetries retries');
            }
          }
        }
      } catch (e) {
        print('[BATCH POLL] Error: $e');
      }
    }
  }

  /// Download a video file
  Future<void> _downloadVideo(
    SceneData scene,
    String videoUrl,
    Set<int> downloadingScenes,
  ) async {
    try {
      _log('[DOWNLOAD] 📥 Scene ${scene.sceneId} downloading...');
      scene.status = 'downloading';
      _safeAdd('UPDATE');

      final outputPath = await _getOutputPath(scene.sceneId);
      
      final response = await _dio.get(videoUrl, options: Options(responseType: ResponseType.bytes));
      if (response.statusCode == 200) {
        final bytes = response.data as List<int>;
        final file = File(outputPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);

        scene.videoPath = outputPath;
        scene.downloadUrl = videoUrl;
        scene.fileSize = bytes.length;
        scene.generatedAt = DateTime.now().toIso8601String();
        scene.status = 'completed';
        _successCount++;
        _safeAdd('UPDATE');

        _log('[DOWNLOAD] ✅ Scene ${scene.sceneId} complete (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
      } else {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      // Remove from downloading set
      downloadingScenes.remove(scene.sceneId);
      
    } catch (e) {
      _log('[DOWNLOAD] ❌ Scene ${scene.sceneId} error: $e');
      scene.status = 'failed';
      scene.error = 'Download failed: $e';
      _failedCount++;
      _safeAdd('UPDATE');
      
      downloadingScenes.remove(scene.sceneId);
    }
  }

  /// Get next available profile (skips profiles in 429 cooldown and waiting for browser ready)
  dynamic _getNextProfile() {
    dynamic profile;
    if (Platform.isAndroid || Platform.isIOS) {
      profile = _mobileService?.getNextAvailableProfile();
    } else {
      profile = _profileManager?.getNextAvailableProfile();
    }
    
    // Check if this profile is waiting for browser to be ready after relogin
    if (profile != null) {
      final profileName = profile.name ?? 'unknown';
      
      // CRITICAL: Skip profiles that are still waiting for browser to fully load
      if (_profilesWaitingForReady.contains(profileName)) {
        print('[PROFILE] ⏳ Profile $profileName waiting for browser to be ready - skipping');
        return null; // Don't use this profile yet
      }
      
      // Check if this profile is in 429 cooldown
      final cooldownEnd = _profile429Times[profileName];
      
      if (cooldownEnd != null) {
        final now = DateTime.now();
        if (now.isBefore(cooldownEnd)) {
          final remaining = cooldownEnd.difference(now).inSeconds;
          print('[PROFILE] ⏸️ Profile $profileName in 429 cooldown ($remaining s remaining)');
          return null; // Don't use this profile yet
        } else {
          // Cooldown expired, clear it
          _profile429Times.remove(profileName);
          print('[PROFILE] ✅ Profile $profileName cooldown expired, ready to use');
        }
      }
    }
    
    return profile;
  }

  /// Auto-connect to browsers on startup if not connected
  Future<void> _autoConnectBrowsers() async {
    // Skip if no profile manager or already connected
    if (_profileManager == null) {
      print('[AUTO-CONNECT] No profile manager available');
      return;
    }

    // Check if any profiles are already connected
    final connectedProfiles = _profileManager!.profiles.where((p) {
      final generator = p.generator;
      return generator != null && generator is DesktopGenerator && generator.isConnected;
    }).toList();

    if (connectedProfiles.isNotEmpty) {
      _log('[AUTO-CONNECT] ✅ ${connectedProfiles.length} browser(s) already connected');
      return;
    }

    // Get browser profiles from settings to determine how many to try
    final settings = SettingsService.instance;
    await settings.reload();
    final browserProfiles = settings.getBrowserProfiles();
    
    if (browserProfiles.isEmpty) {
      _log('[AUTO-CONNECT] ⚠️ No browser profiles configured in settings');
      return;
    }

    _log('[AUTO-CONNECT] 🔗 Attempting to connect to ${browserProfiles.length} browser(s)...');

    try {
      // Use existing connectToOpenProfiles method which tries ports 9222 onwards
      await _profileManager!.connectToOpenProfiles(browserProfiles.length);
      
      // Check how many connected successfully
      final newConnectedProfiles = _profileManager!.profiles.where((p) {
        final generator = p.generator;
        return generator != null && generator is DesktopGenerator && generator.isConnected;
      }).toList();
      
      if (newConnectedProfiles.isNotEmpty) {
        _log('[AUTO-CONNECT] ✅ Connected to ${newConnectedProfiles.length} browser(s)');
      } else {
        _log('[AUTO-CONNECT] ⚠️ No browsers found. Please launch browsers manually with debug ports starting at 9222.');
      }
    } catch (e) {
      _log('[AUTO-CONNECT] ⚠️ Auto-connect failed: $e');
    }
  }

  /// Ensure profile has a valid access token, navigate to Flow URL if needed
  Future<bool> _ensureTokenAvailable(dynamic profile) async {
    if (profile == null) return false;
    
    // Check if token already exists
    final token = profile.accessToken as String?;
    if (token != null && token.isNotEmpty) {
      return true; // Token already available
    }

    _log('[TOKEN] ⚠️ No access token found for profile ${profile.name}');
    
    // Only try auto-navigation for desktop generators
    final generator = profile.generator;
    if (generator == null || generator is! DesktopGenerator) {
      _log('[TOKEN] ❌ Cannot auto-navigate (not a desktop browser)');
      return false;
    }

    if (!generator.isConnected) {
      _log('[TOKEN] ❌ Browser not connected');
      return false;
    }

    try {
      _log('[TOKEN] 🔄 Navigating to Flow URL to fetch token...');
      
      // Navigate to Flow URL using JavaScript
      const flowUrl = 'https://labs.google/fx/tools/flow';
      await generator.executeJs('window.location.href = "$flowUrl"');
      
      // Wait for page to load
      _log('[TOKEN] ⏳ Waiting for page to load (5 seconds)...');
      await Future.delayed(const Duration(seconds: 5));
      
      // Try to fetch token again using the correct method
      _log('[TOKEN] 🔑 Attempting to fetch access token...');
      final newToken = await generator.getAccessToken();
      
      if (newToken != null && newToken.isNotEmpty) {
        profile.accessToken = newToken;
        _log('[TOKEN] ✅ Access token obtained successfully');
        return true;
      } else {
        _log('[TOKEN] ❌ Failed to fetch token after navigation');
        _safeAdd('[ERROR] Flow URL is not opened or session expired. Please open Flow manually and login.');
        return false;
      }
    } catch (e) {
      _log('[TOKEN] ❌ Error during token fetch: $e');
      _safeAdd('[ERROR] Failed to fetch token: $e. Please check browser session.');
      return false;
    }
  }

  Future<String> _getOutputPath(int sceneId) async {
    // Use project folder if set, otherwise fallback to 'v_output'
    final String basePath;
    if (_projectFolder.isNotEmpty) {
      // Use project folder with 'videos' subfolder
      basePath = path.join(_projectFolder, 'videos');
    } else {
      // Fallback to default v_output folder
      basePath = path.join(Directory.current.path, 'v_output');
    }
    
    final dir = Directory(basePath);
    if (!await dir.exists()) await dir.create(recursive: true);
    return path.join(dir.path, 'scene_${sceneId.toString().padLeft(4, '0')}.mp4');
  }

  Future<String?> _uploadImageHTTP(String imagePath, String accessToken) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final b64 = base64Encode(bytes);
      final mime = imagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      
      // Detect aspect ratio from image (you can enhance this with actual image dimension detection)
      // For now, we'll default to landscape, but ideally you'd decode the image to get actual dimensions
      final aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE'; // Could be PORTRAIT, SQUARE, etc.

      final payload = jsonEncode({
        'imageInput': {
          'rawImageBytes': b64, 
          'mimeType': mime, 
          'isUserUploaded': true,
          'aspectRatio': aspectRatio
        },
        'clientContext': {
          'sessionId': ';${DateTime.now().millisecondsSinceEpoch}', 
          'tool': 'ASSET_MANAGER'
        }
      });

      final res = await _dio.post('https://aisandbox-pa.googleapis.com/v1:uploadUserImage', 
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'text/plain;charset=UTF-8'}));

      if (res.statusCode == 200) {
        final data = res.data is String ? jsonDecode(res.data) : res.data;
        return data['mediaGenerationId']?['mediaGenerationId'] ?? data['mediaId'];
      }
    } catch (e) {
      print('[UPLOAD] Error: $e');
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> _pollVideoStatusBatchHTTP(List<PollRequest> requests, String accessToken) async {
    if (requests.isEmpty) return [];
    try {
      final payload = {
        'operations': requests.map((r) => {'operation': {'name': r.operationName}, 'status': 'MEDIA_GENERATION_STATUS_ACTIVE'}).toList()
      };

      final response = await _dio.post('https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus',
        data: jsonEncode(payload),
        options: Options(headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $accessToken'}));

      if (response.statusCode == 200) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        if (data['operations'] != null) {
          return List<Map<String, dynamic>>.from(data['operations']);
        }
      }
    } catch (e) {
      print('[HTTP POLL] Error: $e');
    }
    return null;
  }

  /// Call when a profile is about to start relogin - marks it as waiting for browser ready
  void onProfileStartingRelogin(String profileName) {
    if (profileName.isEmpty) return;
    _profilesWaitingForReady.add(profileName);
    print('[Relogin] Profile $profileName marked as waiting for browser ready');
  }
  
  /// Call when browser is fully ready after relogin - allows profile to be used for generation
  void markProfileReady(String profileName) {
    if (profileName.isEmpty) return;
    _profilesWaitingForReady.remove(profileName);
    print('[Relogin] Profile $profileName browser is ready - generation allowed');
  }

  void onProfileRelogin(dynamic profile, String newAccessToken) {
    if (newAccessToken.isEmpty) return;
    
    final profileName = profile?.name ?? profile?.email ?? 'unknown';
    
    // Mark that we just relogged in - will throttle next requests
    _justReloggedIn = true;
    _requestsSinceRelogin = 0;
    print('[Relogin] Relogin completed - will send 4 requests, then wait 10s');
    
    // CRITICAL: Add profile to waiting list - will be removed when browser is fully ready
    _profilesWaitingForReady.add(profileName);
    print('[Relogin] Profile $profileName added to waiting list until browser is ready');
    
    print('[Relogin] Updating active videos with new token...');
    for (final v in _activeVideos) {
      try {
        if (v.profile == profile) v.accessToken = newAccessToken;
      } catch (_) {}
    }
    
    // Re-queue all 403-failed scenes with fresh retry counters
    if (_403FailedScenes.isNotEmpty) {
      print('[Relogin] Re-queueing ${_403FailedScenes.length} scenes that failed due to 403...');
      
      for (final scene in List.from(_403FailedScenes)) { // Make a copy to iterate
        // CRITICAL: Skip scenes that are already completed
        if (scene.status == 'completed' || scene.status == 'downloading') {
          print('[Relogin] Scene ${scene.sceneId} already ${scene.status} - skipping re-queue');
          _403FailedScenes.remove(scene);
          continue;
        }
        
        // Skip scenes already in queue
        if (_queueToGenerate.any((s) => s.sceneId == scene.sceneId)) {
          print('[Relogin] Scene ${scene.sceneId} already in queue - skipping re-queue');
          _403FailedScenes.remove(scene);
          continue;
        }
        
        // Skip scenes currently being polled (active videos)
        if (_activeVideos.any((v) => v.scene.sceneId == scene.sceneId)) {
          print('[Relogin] Scene ${scene.sceneId} currently active/polling - skipping re-queue');
          _403FailedScenes.remove(scene);
          continue;
        }
        
        // Reset retry counter to give fresh attempts with new token
        _videoRetryCounts[scene.sceneId] = 0;
        
        // Re-queue at front for immediate retry
        scene.status = 'queued';
        scene.error = null;
        _queueToGenerate.insert(0, scene);
        
        print('[Relogin] Scene ${scene.sceneId} re-queued (fresh retry counter: 0/5)');
      }
      
      _403FailedScenes.clear();
      _safeAdd('UPDATE');
    }
  }
}

class _ActiveVideo {
  final SceneData scene;
  final String sceneUuid;
  final dynamic profile;
  String accessToken;

  _ActiveVideo({
    required this.scene,
    required this.sceneUuid,
    required this.profile,
    required this.accessToken,
  });
}

/// Compact Desktop CDP Generator
class DesktopGenerator {
  final int debugPort;
  WebSocketChannel? ws;
  Stream<dynamic>? _broadcastStream;
  int msgId = 0;
  
  // Pending subscriptions tracker for cleanup
  final Map<int, StreamSubscription> _pendingSubscriptions = {};

  DesktopGenerator({this.debugPort = 9222});

  Future<void> connect() async {
    // Close existing connection if any
    close();
    
    // Yield to UI thread before HTTP request to prevent UI freezing
    await Future.delayed(Duration.zero);
    
    final response = await http.get(Uri.parse('http://localhost:$debugPort/json'))
        .timeout(const Duration(seconds: 10), onTimeout: () {
          throw Exception('Connection timeout to port $debugPort');
        });
    
    // Yield to UI thread after HTTP request
    await Future.delayed(Duration.zero);
    
    final tabs = jsonDecode(response.body) as List;
    final targetTab = tabs.firstWhere((t) => (t['url'] as String).contains('labs.google'), orElse: () => null);
    if (targetTab == null) throw Exception('No labs.google tab found');
    ws = WebSocketChannel.connect(Uri.parse(targetTab['webSocketDebuggerUrl']));
    _broadcastStream = ws!.stream.asBroadcastStream();
    print('[CDP] Connected to port $debugPort');
  }

  void close() { 
    // Cancel all pending subscriptions
    for (final sub in _pendingSubscriptions.values) {
      try { sub.cancel(); } catch (_) {}
    }
    _pendingSubscriptions.clear();
    
    ws?.sink.close(); 
    ws = null; 
    _broadcastStream = null;
  }

  bool get isConnected => ws != null;
  bool get isHealthy => ws != null;
  
  /// Ensure connection is available, reconnect if needed
  Future<void> ensureConnected() async {
    if (!isConnected) {
      print('[CDP] Connection lost on port $debugPort, reconnecting...');
      close();
      await Future.delayed(const Duration(milliseconds: 500));
      await connect();
    }
  }
  
  /// Send CDP command  
  Future<Map<String, dynamic>> sendCommand(String method, [Map<String, dynamic>? params]) async {
    if (ws == null) throw Exception('Not connected');
    
    final currentId = ++msgId;
    final completer = Completer<Map<String, dynamic>>();
    StreamSubscription? sub;
    
    void cleanup() {
      sub?.cancel();
      _pendingSubscriptions.remove(currentId);
    }
    
    sub = _broadcastStream!.listen(
      (msg) {
        try {
          final res = jsonDecode(msg as String);
          if (res['id'] == currentId) {
            cleanup();
            if (!completer.isCompleted) {
              completer.complete(res);
            }
          }
        } catch (e) {
          // Ignore parse errors for other messages
        }
      },
      onError: (e) {
        cleanup();
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      cancelOnError: false,
    );
    
    _pendingSubscriptions[currentId] = sub;
    ws!.sink.add(jsonEncode({'id': currentId, 'method': method, 'params': params ?? {}}));
    
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        cleanup();
        throw Exception('CDP command timeout: $method');
      },
    );
  }

  Future<dynamic> executeJs(String expression) async {
    final res = await sendCommand('Runtime.evaluate', {'expression': expression, 'returnByValue': true, 'awaitPromise': true});
    return res['result']?['result']?['value'];
  }

  Future<String?> getAccessToken() async {
    final res = await executeJs('''
      (async () => {
        const resp = await fetch('https://labs.google/fx/api/auth/session', {
          credentials: 'include'
        });
        const data = await resp.json();
        return data.access_token;
      })()
    ''');
    return res is String ? res : null;
  }

  Future<String?> getRecaptchaToken() async {
    try {
      final token = await executeJs('''
        (async () => {
          const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
          return await grecaptcha.enterprise.execute(siteKey, {
            action: 'VIDEO_GENERATION'
          });
        })()
      ''');
      return (token is String && token.length > 20) ? token : null;
    } catch (e) {
      print('[VGEN] reCAPTCHA error: $e');
      return null;
    }
  }

  Future<String> getCurrentUrl() async {
    final result = await executeJs('window.location.href');
    return result as String;
  }

  // For compatibility
  Future<void> prefetchRecaptchaTokens([int count = 1]) async {}
  String? getNextPrefetchedToken() => null;
  void clearPrefetchedTokens() {}

  Future<dynamic> uploadImage(String path, String token, {String? aspectRatio}) async {
    final bytes = await File(path).readAsBytes();
    final b64 = base64Encode(bytes);
    final mime = path.endsWith('.png') ? 'image/png' : 'image/jpeg';
    final imageAspectRatio = aspectRatio ?? 'IMAGE_ASPECT_RATIO_LANDSCAPE';
    
    final payload = jsonEncode({
      'imageInput': {
        'rawImageBytes': b64, 
        'mimeType': mime, 
        'isUserUploaded': true,
        'aspectRatio': imageAspectRatio
      },
      'clientContext': {
        'sessionId': ';${DateTime.now().millisecondsSinceEpoch}', 
        'tool': 'ASSET_MANAGER'
      }
    });
    final js = '''
      fetch("https://aisandbox-pa.googleapis.com/v1:uploadUserImage", {
        method: "POST", 
        headers: {
          "authorization": "Bearer $token", 
          "content-type": "text/plain;charset=UTF-8"
        }, 
        body: JSON.stringify($payload)
      }).then(r => r.json())
    ''';
    final res = await executeJs(js);
    return res?['mediaGenerationId']?['mediaGenerationId'] ?? res?['mediaId'];
  }

  Future<Map<String, dynamic>?> generateVideo({
    required String prompt, 
    required String accessToken, 
    required String aspectRatio, 
    required String model,
    String? startImageMediaId, 
    String? endImageMediaId, 
    String? recaptchaToken,
  }) async {
    // Generate UUID for sceneId
    final random = Random();
    String generateUuid() {
      String hex(int length) => List.generate(length, (_) => random.nextInt(16).toRadixString(16)).join();
      return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
    }
    
    final sceneUuid = generateUuid();
    final projectId = generateUuid();
    final requestObj = {
      'aspectRatio': aspectRatio,
      'seed': Random().nextInt(50000),
      'textInput': {'prompt': prompt},
      'videoModelKey': model,
      if (startImageMediaId != null) 'startImage': {'mediaId': startImageMediaId},
      if (endImageMediaId != null) 'endImage': {'mediaId': endImageMediaId},
      'metadata': {'sceneId': sceneUuid},
    };
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    
    final payload = jsonEncode({
      'clientContext': {
        'recaptchaContext': {
          'token': recaptchaToken ?? '', 
          'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB'
        },
        'sessionId': sessionId,
        'projectId': projectId,
        'tool': 'PINHOLE',
        'userPaygateTier': 'PAYGATE_TIER_TWO'
      },
      'requests': [requestObj]
    });
    
    // Select endpoint based on which frames are present
    final String endpoint;
    if (startImageMediaId != null && endImageMediaId != null) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartAndEndImage';
    } else if (startImageMediaId != null) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage';
    } else {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';
    }
    
    final js = '''
      fetch("$endpoint", {
        method: "POST", 
        headers: {
          "authorization": "Bearer $accessToken", 
          "content-type": "text/plain;charset=UTF-8"
        }, 
        body: JSON.stringify($payload)
      }).then(async r => {
        const text = await r.text();
        if (!r.ok) return { error: { message: "HTTP " + r.status + ": " + text.substring(0, 100), status: r.status }, data: text };
        try {
          return JSON.parse(text);
        } catch(e) {
          return { error: { message: "Failed to parse JSON: " + text.substring(0, 100) } };
        }
      }).catch(e => ({ error: { message: e.message } }))
    ''';
    final res = await executeJs(js);
    
    if (res == null) return {'success': false, 'error': 'No response'};
    if (res['error'] != null) return {'success': false, 'error': res['error']['message'] ?? res['error'].toString(), 'data': res};
    if (res['operations'] != null) return {'success': true, 'data': res};
    
    // Fallback if the response is unexpected but not explicitly an error
    return {'success': false, 'error': 'Invalid response (missing operations)', 'data': res};
  }

  Future<List<Map<String, dynamic>>?> pollVideoStatusBatchHTTP(List<PollRequest> requests, String token) async {
    final payload = jsonEncode({
      'operations': requests.map((r) => {'operation': {'name': r.operationName}, 'status': 'MEDIA_GENERATION_STATUS_ACTIVE'}).toList()
    });
    final js = 'fetch("https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus", {method:"POST", headers:{"authorization":"Bearer $token", "content-type":"application/json"}, body:JSON.stringify($payload)}).then(r=>r.json())';
    final res = await executeJs(js);
    return res?['operations'] != null ? List<Map<String, dynamic>>.from(res['operations']) : null;
  }

  // Alias for upscale polling compatibility
  Future<List<Map<String, dynamic>>?> pollVideoStatusBatch(List<PollRequest> requests, String token) async {
    return pollVideoStatusBatchHTTP(requests, token);
  }

  // Single video polling for upscale
  Future<Map<String, dynamic>?> pollVideoStatus(String operationName, String sceneId, String token) async {
    final payload = jsonEncode({
      'operations': [{'operation': {'name': operationName}, 'status': 'MEDIA_GENERATION_STATUS_ACTIVE'}]
    });
    final js = 'fetch("https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus", {method:"POST", headers:{"authorization":"Bearer $token", "content-type":"application/json"}, body:JSON.stringify($payload)}).then(r=>r.json())';
    final res = await executeJs(js);
    if (res?['operations'] != null && res['operations'].isNotEmpty) {
      return res['operations'][0] as Map<String, dynamic>;
    }
    return null;
  }

  Future<void> downloadVideo(String url, String path) async {
    final bytes = await http.readBytes(Uri.parse(url));
    await File(path).writeAsBytes(bytes);
  }

  Future<Map<String, dynamic>> upscaleVideo({
    required String accessToken,
    required String videoMediaId,
    required String aspectRatio,
    required String resolution,
  }) async {
    // Get recaptcha token
    final recaptchaToken = await getRecaptchaToken();
    
    // Select correct model based on resolution
    final modelKey = resolution == 'VIDEO_RESOLUTION_4K' 
        ? 'veo_3_1_upsampler_4k' 
        : 'veo_3_1_upsampler_1080p';
    
    final payload = jsonEncode({
      'requests': [{
        'aspectRatio': aspectRatio,
        'resolution': resolution,
        'seed': Random().nextInt(100000),
        'videoInput': {
          'mediaId': videoMediaId,
        },
        'videoModelKey': modelKey,
      }],
      'clientContext': {
        'recaptchaContext': {
          'token': recaptchaToken ?? '',
        },
        'sessionId': ';${DateTime.now().millisecondsSinceEpoch}',
      },
    });
    
    final js = '''
      fetch("https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoUpsampleVideo", {
        method: "POST",
        headers: {
          "authorization": "Bearer $accessToken",
          "content-type": "application/json"
        },
        body: JSON.stringify($payload)
      }).then(r => r.json())
    ''';
    
    final res = await executeJs(js);
    if (res == null) return {'success': false, 'error': 'No response from upscale API'};
    if (res['error'] != null) return {'success': false, 'error': res['error']['message'] ?? res['error'].toString(), 'data': res};
    if (res['operations'] != null) return {'success': true, 'data': res};
    return {'success': false, 'error': 'Invalid response', 'data': res};
  }
}
