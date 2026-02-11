/// VEO3 Video Generation Service for Story Prompt Processor
/// Enhanced with concurrency, retry logic, and error recovery

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Video generation status
enum VideoStatus { pending, uploading, generating, polling, downloading, complete, failed, cancelled }

/// Video generation result
class VideoResult {
  final String clipId;
  VideoStatus status;
  String? videoPath;
  String? error;
  int retryCount;
  String? operationName;
  String? sceneId;
  DateTime? startTime;
  
  VideoResult({required this.clipId, this.status = VideoStatus.pending, 
    this.videoPath, this.error, this.retryCount = 0, this.operationName, this.sceneId, this.startTime});
}

class Veo3VideoService {
  final int debugPort;
  WebSocketChannel? ws;
  Stream<dynamic>? _broadcastStream;
  int msgId = 0;
  String? _accessToken;
  bool _isCancelled = false;
  int _consecutive403Count = 0;
  
  // Credentials for auto-relogin
  String? savedEmail;
  String? savedPassword;
  
  // Callbacks
  Function(String)? onLog;
  Function()? onStateChanged;
  
  // Active generations for concurrency tracking
  final Map<String, VideoResult> activeGenerations = {};
  
  Veo3VideoService({this.debugPort = 9222});
  
  // Getters
  bool get isConnected => ws != null;
  bool get hasToken => _accessToken != null;
  
  void log(String message) {
    print(message);
    onLog?.call(message);
  }

  /// Cancel ongoing operations
  void cancelOperations() {
    _isCancelled = true;
  }
  
  void resetCancellation() {
    _isCancelled = false;
  }

  /// Connect to Chrome DevTools - scans ports 9222-9230
  Future<bool> connect() async {
    final portsToTry = List.generate(9, (i) => 9222 + i); // 9222-9230
    
    for (final port in portsToTry) {
      try {
        log('🔍 Trying port $port...');
        final response = await http.get(Uri.parse('http://localhost:$port/json'))
          .timeout(const Duration(seconds: 2), onTimeout: () => throw Exception('Timeout'));
        
        final tabs = jsonDecode(response.body) as List;

        Map<String, dynamic>? targetTab;
        for (var tab in tabs) {
          if ((tab['url'] as String).contains('labs.google')) {
            targetTab = tab as Map<String, dynamic>;
            break;
          }
        }

        if (targetTab != null) {
          final wsUrl = targetTab['webSocketDebuggerUrl'] as String;
          ws = WebSocketChannel.connect(Uri.parse(wsUrl));
          _broadcastStream = ws!.stream.asBroadcastStream();
          
          log('✅ Connected to Chrome on port $port');
          _consecutive403Count = 0;
          return true;
        } else {
          log('⚠️ Port $port: No labs.google tab found');
        }
      } catch (e) {
        // Port not available or no response, try next
        log('⚠️ Port $port: Not available');
      }
    }
    
    log('❌ No Chrome with labs.google tab found on ports 9222-9230');
    log('📋 Start Chrome with: chrome.exe --remote-debugging-port=9222');
    log('📋 Then open https://labs.google');
    return false;
  }

  /// Send a CDP command
  Future<Map<String, dynamic>> sendCommand(String method, [Map<String, dynamic>? params]) async {
    if (ws == null || _broadcastStream == null) throw Exception('Not connected');

    msgId++;
    final currentMsgId = msgId;
    final msg = {'id': currentMsgId, 'method': method, 'params': params ?? {}};

    ws!.sink.add(jsonEncode(msg));

    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription subscription;
    
    subscription = _broadcastStream!.listen((message) {
      final response = jsonDecode(message as String) as Map<String, dynamic>;
      if (response['id'] == currentMsgId) {
        subscription.cancel();
        completer.complete(response);
      }
    }, onError: (error) {
      subscription.cancel();
      completer.completeError(error);
    });
    
    return completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        subscription.cancel();
        throw Exception('Command timeout');
      },
    );
  }

  /// Execute JavaScript in browser context
  Future<dynamic> executeJs(String expression) async {
    final result = await sendCommand('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    return result['result']?['result']?['value'];
  }

  /// Navigate to URL
  Future<void> navigateTo(String url) async {
    log('🔗 Navigating to: $url');
    await sendCommand('Page.navigate', {'url': url});
    await Future.delayed(const Duration(seconds: 3));
  }

  /// Clear all browser data (cookies, cache, storage)
  Future<void> clearBrowserData() async {
    log('🧹 Clearing browser data...');
    try {
      // Clear cookies
      await sendCommand('Network.clearBrowserCookies');
      // Clear cache
      await sendCommand('Network.clearBrowserCache');
      // Clear storage via JS
      await executeJs('''
        (function() {
          localStorage.clear();
          sessionStorage.clear();
          return 'cleared';
        })()
      ''');
      log('✅ Browser data cleared');
    } catch (e) {
      log('⚠️ Error clearing browser data: $e');
    }
  }

  /// Login with email and password
  Future<bool> autoLogin(String email, String password) async {
    log('🔐 Attempting auto-login...');
    try {
      // Navigate to labs.google
      await navigateTo('https://labs.google');
      await Future.delayed(const Duration(seconds: 3));
      
      // Click sign in button
      await executeJs('''
        (function() {
          const signInBtn = document.querySelector('[data-testid="sign-in-button"], button[aria-label*="Sign in"], a[href*="accounts.google"]');
          if (signInBtn) signInBtn.click();
          return 'clicked';
        })()
      ''');
      await Future.delayed(const Duration(seconds: 3));
      
      // Enter email
      await executeJs('''
        (function() {
          const emailInput = document.querySelector('input[type="email"]');
          if (emailInput) {
            emailInput.value = '$email';
            emailInput.dispatchEvent(new Event('input', {bubbles: true}));
          }
          return 'entered';
        })()
      ''');
      await Future.delayed(const Duration(seconds: 1));
      
      // Click next
      await executeJs('''
        (function() {
          const nextBtn = document.querySelector('#identifierNext, button[jsname="LgbsSe"]');
          if (nextBtn) nextBtn.click();
          return 'clicked';
        })()
      ''');
      await Future.delayed(const Duration(seconds: 3));
      
      // Enter password
      await executeJs('''
        (function() {
          const passInput = document.querySelector('input[type="password"]');
          if (passInput) {
            passInput.value = '$password';
            passInput.dispatchEvent(new Event('input', {bubbles: true}));
          }
          return 'entered';
        })()
      ''');
      await Future.delayed(const Duration(seconds: 1));
      
      // Click next
      await executeJs('''
        (function() {
          const nextBtn = document.querySelector('#passwordNext, button[jsname="LgbsSe"]');
          if (nextBtn) nextBtn.click();
          return 'clicked';
        })()
      ''');
      await Future.delayed(const Duration(seconds: 5));
      
      // Navigate back to labs
      await navigateTo('https://labs.google');
      await Future.delayed(const Duration(seconds: 3));
      
      // Get token
      final token = await getAccessToken();
      if (token != null) {
        log('✅ Auto-login successful');
        _consecutive403Count = 0;
        return true;
      }
      
      log('❌ Auto-login failed - could not get token');
      return false;
    } catch (e) {
      log('❌ Auto-login error: $e');
      return false;
    }
  }

  /// Handle 403 error with recovery
  Future<bool> handle403Error() async {
    _consecutive403Count++;
    log('⚠️ 403 Error count: $_consecutive403Count');
    
    if (_consecutive403Count >= 3) {
      log('🔄 Too many 403 errors. Attempting recovery...');
      
      if (savedEmail != null && savedPassword != null) {
        await clearBrowserData();
        final success = await autoLogin(savedEmail!, savedPassword!);
        if (success) {
          _consecutive403Count = 0;
          return true;
        }
      } else {
        log('❌ No credentials saved for auto-relogin');
        log('💡 Please manually log in and reconnect');
      }
      return false;
    }
    
    // Refresh and retry
    log('🔄 Refreshing page...');
    await sendCommand('Page.reload', {'ignoreCache': true});
    await Future.delayed(const Duration(seconds: 5));
    
    final token = await getAccessToken();
    return token != null;
  }

  /// Get access token from browser session
  Future<String?> getAccessToken() async {
    log('🔑 Fetching access token...');
    const jsCode = '''
    (async function() {
      try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 10000);
        
        const response = await fetch('https://labs.google/fx/api/auth/session', {
          credentials: 'include',
          signal: controller.signal
        });
        clearTimeout(timeout);
        
        const data = await response.json();
        return JSON.stringify({
          success: response.ok,
          token: data.access_token,
          expires: data.expires
        });
      } catch (error) {
        return JSON.stringify({success: false, error: error.message || 'Unknown error'});
      }
    })()
    ''';

    try {
      final result = await executeJs(jsCode).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          log('⚠️ Token fetch timed out');
          return null;
        },
      );
      
      if (result != null) {
        final parsed = jsonDecode(result as String) as Map<String, dynamic>;
        if (parsed['success'] == true && parsed['token'] != null) {
          _accessToken = parsed['token'] as String?;
          log('✅ Access token obtained');
          return _accessToken;
        } else {
          log('❌ Token response: ${parsed['error'] ?? 'No token in response'}');
        }
      }
    } catch (e) {
      log('❌ Token fetch error: $e');
    }
    
    log('❌ Failed to get access token - make sure you are logged into labs.google');
    return null;
  }

  /// Upload an image and get mediaId
  Future<String?> uploadImage(String imagePath) async {
    if (_accessToken == null) throw Exception('No access token');
    
    log('📤 Uploading: ${imagePath.split(Platform.pathSeparator).last}');
    
    try {
      final imageBytes = await File(imagePath).readAsBytes();
      final imageB64 = base64Encode(imageBytes);
      
      String mimeType = 'image/jpeg';
      if (imagePath.toLowerCase().endsWith('.png')) mimeType = 'image/png';
      if (imagePath.toLowerCase().endsWith('.webp')) mimeType = 'image/webp';
      
      // Split base64 into chunks
      const chunkSize = 50000;
      final chunks = <String>[];
      for (var i = 0; i < imageB64.length; i += chunkSize) {
        final end = (i + chunkSize < imageB64.length) ? i + chunkSize : imageB64.length;
        chunks.add(imageB64.substring(i, end));
      }
      final chunksJs = jsonEncode(chunks);

      final jsCode = '''
      (async function() {
        try {
          const chunks = $chunksJs;
          const rawImageBytes = chunks.join('');
          
          const payload = {
            imageInput: {
              rawImageBytes: rawImageBytes,
              mimeType: "$mimeType",
              isUserUploaded: true,
              aspectRatio: "IMAGE_ASPECT_RATIO_LANDSCAPE"
            },
            clientContext: {
              sessionId: ';' + Date.now(),
              tool: 'ASSET_MANAGER'
            }
          };
          
          const response = await fetch(
            'https://aisandbox-pa.googleapis.com/v1:uploadUserImage',
            {
              method: 'POST',
              headers: { 
                'Content-Type': 'text/plain;charset=UTF-8',
                'authorization': 'Bearer $_accessToken'
              },
              body: JSON.stringify(payload),
              credentials: 'include'
            }
          );
          
          const text = await response.text();
          let data = null;
          try { data = JSON.parse(text); } catch (e) { data = text; }
          
          return JSON.stringify({
            success: response.ok,
            status: response.status,
            data: data
          });
        } catch (error) {
          return JSON.stringify({success: false, error: error.message});
        }
      })()
      ''';

      final resultStr = await executeJs(jsCode);
      if (resultStr != null) {
        final result = jsonDecode(resultStr as String) as Map<String, dynamic>;
        
        // Handle 403
        if (result['status'] == 403) {
          final recovered = await handle403Error();
          if (recovered) {
            return await uploadImage(imagePath); // Retry
          }
          return null;
        }
        
        if (result['success'] == true) {
          _consecutive403Count = 0;
          final data = result['data'] as Map<String, dynamic>;
          String? mediaId;
          
          if (data.containsKey('mediaGenerationId')) {
            final mediaGen = data['mediaGenerationId'];
            if (mediaGen is Map) {
              mediaId = mediaGen['mediaGenerationId'] as String?;
            } else {
              mediaId = mediaGen as String?;
            }
          } else if (data.containsKey('mediaId')) {
            mediaId = data['mediaId'] as String?;
          }
          
          if (mediaId != null) {
            log('✅ Upload success: $mediaId');
            return mediaId;
          }
        } else {
          log('❌ Upload failed: ${result['data']}');
        }
      }
      return null;
    } catch (e) {
      log('❌ Upload exception: $e');
      return null;
    }
  }

  /// Generate UUID
  String _generateUuid() {
    final random = Random();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    return '${hex(values[0])}${hex(values[1])}${hex(values[2])}${hex(values[3])}-'
        '${hex(values[4])}${hex(values[5])}-'
        '${hex(values[6])}${hex(values[7])}-'
        '${hex(values[8])}${hex(values[9])}-'
        '${hex(values[10])}${hex(values[11])}${hex(values[12])}${hex(values[13])}${hex(values[14])}${hex(values[15])}';
  }

  /// Generate a video with start/end images - returns operation name and sceneId
  Future<Map<String, dynamic>?> startVideoGeneration({
    required String prompt,
    String? startImageMediaId,
    String? endImageMediaId,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String model = 'veo_3_1_t2v_fast_ultra',
  }) async {
    if (_accessToken == null) throw Exception('No access token');
    
    final sceneId = _generateUuid();
    final seed = DateTime.now().millisecondsSinceEpoch % 50000;
    
    final hasStartImage = startImageMediaId != null;
    final hasEndImage = endImageMediaId != null;
    final isI2v = hasStartImage || hasEndImage;
    
    var adjustedModel = model;
    if (isI2v && adjustedModel.contains('t2v')) {
      adjustedModel = adjustedModel.replaceAll('t2v', 'i2v_s');
      
      if (hasStartImage && hasEndImage) {
        if (adjustedModel.contains('_fast')) {
          adjustedModel = adjustedModel.replaceFirst('_fast', '_fast_fl');
        } else if (adjustedModel.contains('_quality')) {
          adjustedModel = adjustedModel.replaceFirst('_quality', '_quality_fl');
        }
      }
    }
    
    log('🎬 Starting generation with model: $adjustedModel');
    
    Map<String, dynamic> requestObj = {
      'aspectRatio': aspectRatio,
      'seed': seed,
      'textInput': {'prompt': prompt},
      'videoModelKey': adjustedModel,
      'metadata': {'sceneId': sceneId},
    };
    
    if (startImageMediaId != null) {
      requestObj['startImage'] = {'mediaId': startImageMediaId};
    }
    if (endImageMediaId != null) {
      requestObj['endImage'] = {'mediaId': endImageMediaId};
    }
    
    // Debug: Log the full request
    log('📦 Request payload:');
    log('  - aspectRatio: $aspectRatio');
    log('  - seed: $seed');
    log('  - model: $adjustedModel');
    log('  - startImage: $startImageMediaId');
    log('  - endImage: $endImageMediaId');
    log('  - prompt: ${prompt.length > 50 ? "${prompt.substring(0, 50)}..." : prompt}');
    
    final requestJson = jsonEncode(requestObj);
    
    String endpoint;
    if (hasStartImage && hasEndImage) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartAndEndImage';
    } else if (hasStartImage) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage';
    } else {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';
    }
    
    final projectId = _generateUuid();
    
    // NEW PAYLOAD FORMAT: recaptchaContext with token + applicationType
    final jsCode = '''
    (async function() {
      try {
        await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1000) + 500));
        
        const token = await grecaptcha.enterprise.execute(
          '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
          { action: 'VIDEO_GENERATION' }
        );
        
        const payload = {
          clientContext: {
            recaptchaContext: {
              token: token,
              applicationType: 'RECAPTCHA_APPLICATION_TYPE_WEB'
            },
            sessionId: ';' + Date.now(),
            projectId: '$projectId',
            tool: 'PINHOLE',
            userPaygateTier: 'PAYGATE_TIER_TWO'
          },
          requests: [$requestJson]
        };
        
        console.log('[VEO3] Sending request to: $endpoint');
        
        const response = await fetch(
          '$endpoint',
          {
            method: 'POST',
            headers: { 
              'Content-Type': 'text/plain;charset=UTF-8',
              'authorization': 'Bearer $_accessToken'
            },


            body: JSON.stringify(payload),
            credentials: 'include'
          }
        );
        
        const text = await response.text();
        let data = null;
        try { data = JSON.parse(text); } catch (e) { data = text; }
        
        console.log('[VEO3] Response status:', response.status);
        console.log('[VEO3] Response data:', JSON.stringify(data));
        
        return JSON.stringify({
          success: response.ok,
          status: response.status,
          data: data,
          sceneId: '$sceneId'
        });
      } catch (error) {
        console.error('[VEO3] Error:', error.message);
        return JSON.stringify({success: false, error: error.message});
      }
    })()
    ''';


    final resultStr = await executeJs(jsCode);
    if (resultStr != null) {
      final result = jsonDecode(resultStr as String) as Map<String, dynamic>;
      
      // Handle 403
      if (result['status'] == 403) {
        final recovered = await handle403Error();
        if (recovered) {
          return await startVideoGeneration(
            prompt: prompt,
            startImageMediaId: startImageMediaId,
            endImageMediaId: endImageMediaId,
            aspectRatio: aspectRatio,
            model: model,
          );
        }
        return null;
      }
      
      // Log full response details
      log('📊 API Response Status: ${result['status']}');
      log('📊 API Response Data: ${jsonEncode(result['data'])}');
      
      if (result['success'] == true) {
        _consecutive403Count = 0;
        log('✅ Generation started successfully');
        return result;
      } else {
        final errorData = result['data'];
        if (errorData is Map) {
          final error = errorData['error'];
          if (error is Map) {
            log('❌ Error Code: ${error['code']}');
            log('❌ Error Message: ${error['message']}');
            log('❌ Error Status: ${error['status']}');
            if (error['details'] != null) {
              log('❌ Error Details: ${jsonEncode(error['details'])}');
            }
          }
        }
        log('❌ Generation failed: ${result['status']}');
      }
    }
    return null;
  }

  /// Poll video status
  Future<Map<String, dynamic>?> pollVideoStatus(String operationName, String sceneId) async {
    if (_accessToken == null) return null;
    
    final payload = {
      'operations': [
        {
          'operation': {'name': operationName},
          'sceneId': sceneId,
          'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
        }
      ]
    };

    final jsCode = '''
    (async function() {
      try {
        const response = await fetch(
          'https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus',
          {
            method: 'POST',
            headers: { 
              'Content-Type': 'text/plain;charset=UTF-8',
              'authorization': 'Bearer $_accessToken'
            },
            body: JSON.stringify(${jsonEncode(payload)}),
            credentials: 'include'
          }
        );
        
        const text = await response.text();
        let data = null;
        try { data = JSON.parse(text); } catch (e) { data = text; }
        
        return JSON.stringify({
          success: response.ok,
          status: response.status,
          data: data
        });
      } catch (error) {
        return JSON.stringify({success: false, error: error.message});
      }
    })()
    ''';

    final resultStr = await executeJs(jsCode);
    if (resultStr != null) {
      final result = jsonDecode(resultStr as String) as Map<String, dynamic>;
      
      // Log full poll response
      log('📡 Poll Response Status: ${result['status']}');
      log('📡 Poll Response: ${jsonEncode(result['data'])}');
      
      // Handle 403
      if (result['status'] == 403) {
        await handle403Error();
        return null;
      }
      
      if (result['success'] == true) {
        _consecutive403Count = 0;
        final responseData = result['data'] as Map<String, dynamic>;
        if (responseData.containsKey('operations') && (responseData['operations'] as List).isNotEmpty) {
          return (responseData['operations'] as List)[0] as Map<String, dynamic>;
        }
      }
    }
    return null;
  }

  /// Download video from URL
  Future<bool> downloadVideo(String videoUrl, String outputPath) async {
    log('📥 Downloading video...');
    try {
      final response = await http.get(Uri.parse(videoUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      });

      if (response.statusCode == 200) {
        final file = File(outputPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
        log('✅ Downloaded: ${(response.bodyBytes.length / 1024 / 1024).toStringAsFixed(2)} MB');
        return true;
      }
      log('❌ Download failed: ${response.statusCode}');
      return false;
    } catch (e) {
      log('❌ Download error: $e');
      return false;
    }
  }

  /// Poll until video complete and download
  Future<String?> waitAndDownload({
    required String operationName,
    required String sceneId,
    required String outputPath,
    int maxWaitMinutes = 20,
  }) async {
    log('⏳ Waiting for video completion...');
    
    final maxPolls = maxWaitMinutes * 12; // Poll every 5 seconds
    
    for (int i = 0; i < maxPolls; i++) {
      if (_isCancelled) {
        log('⏹️ Polling cancelled');
        return null;
      }
      
      await Future.delayed(const Duration(seconds: 5));
      
      log('🔄 Polling... (attempt ${i + 1})');
      final status = await pollVideoStatus(operationName, sceneId);
      
      if (status == null) {
        log('⚠️ No status returned, retrying...');
        continue;
      }
      
      final genStatus = status['status'] as String?;
      log('📊 Status: $genStatus');
      
      // Handle both COMPLETE and SUCCESSFUL statuses
      if (genStatus == 'MEDIA_GENERATION_STATUS_COMPLETE' || 
          genStatus == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
        
        String? videoUrl;
        
        // Try new structure: operation.metadata.video.fifeUrl
        final operation = status['operation'] as Map?;
        if (operation != null) {
          final metadata = operation['metadata'] as Map?;
          if (metadata != null) {
            final video = metadata['video'] as Map?;
            if (video != null) {
              videoUrl = video['fifeUrl'] as String?;
              log('🔗 Found fifeUrl in operation.metadata.video');
            }
          }
        }
        
        // Fallback: try old structure mediaGeneration.generatedVideoResults
        if (videoUrl == null) {
          final mediaGen = status['mediaGeneration'] as Map?;
          if (mediaGen != null) {
            final videos = mediaGen['generatedVideoResults'] as List?;
            if (videos != null && videos.isNotEmpty) {
              videoUrl = videos[0]['videoUri'] as String?;
              log('🔗 Found videoUri in mediaGeneration');
            }
          }
        }
        
        if (videoUrl != null) {
          log('✅ Video ready! Downloading from: ${videoUrl.substring(0, 80)}...');
          final success = await downloadVideo(videoUrl, outputPath);
          if (success) {
            return outputPath;
          }
        } else {
          log('❌ Video URL not found in response');
          log('📋 Response keys: ${status.keys.toList()}');
        }
        break;
      } else if (genStatus == 'MEDIA_GENERATION_STATUS_FAILED') {
        log('❌ Video generation failed on server');
        return null;
      }
      
      // Only log every minute to avoid spam
      if (i % 12 == 0 && i > 0) {
        log('⏳ Still generating... (${i ~/ 12} min)');
      }
    }
    
    log('❌ Timeout waiting for video');
    return null;
  }

  /// Check if mode is relaxed (has concurrency limit)
  bool isRelaxedMode(String model) {
    return model.contains('_relaxed');
  }

  /// Get max concurrent generations for mode
  int getMaxConcurrent(String model) {
    if (isRelaxedMode(model)) {
      return 4; // Max 4 for relaxed mode
    }
    return 100; // Effectively unlimited for fast mode
  }

  /// Close connection
  void close() {
    try {
      ws?.sink.close();
    } catch (_) {}
    ws = null;
    _broadcastStream = null;
    _accessToken = null;
  }
}
