
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import '../log_service.dart';
import '../browser_video_generator.dart'; // import for PollRequest class if needed

/// Status of a Mobile profile
enum MobileProfileStatus {
  disconnected,
  loading,
  connected,  // Webview load stop
  ready,      // Has token
  error,
}

/// Represents a WebView profile on Mobile
class MobileProfile {
  final String id;
  final String name;
  InAppWebViewController? controller;
  MobileProfileStatus status = MobileProfileStatus.disconnected;
  String? accessToken;
  MobileVideoGenerator? generator;
  
  // Store cookies for this profile (for session isolation)
  List<Map<String, dynamic>> savedCookies = [];
  
  // Compatibility fields for main.dart
  int consecutive403Count = 0;
  int get debugPort => 0; // Dummy port
  
  // Relogin tracking
  int reloginAttempts = 0;
  bool isReloginInProgress = false;
  
  bool get isConnected => status == MobileProfileStatus.ready;
  bool get needsRelogin => consecutive403Count >= 3;

  MobileProfile({
    required this.id, 
    required this.name,
  });
  
  /// Save cookies for this profile
  Future<void> saveCookies() async {
    try {
      final cookieManager = CookieManager.instance();
      final cookies = await cookieManager.getCookies(url: WebUri('https://labs.google'));
      savedCookies = cookies.map((c) => {
        'name': c.name,
        'value': c.value,
        'domain': c.domain,
        'path': c.path,
        'expiresDate': c.expiresDate,
        'isSecure': c.isSecure,
        'isHttpOnly': c.isHttpOnly,
      }).toList();
      print('[PROFILE] $name: Saved ${savedCookies.length} cookies');
    } catch (e) {
      print('[PROFILE] $name: Error saving cookies: $e');
    }
  }
  
  /// Restore cookies for this profile
  Future<void> restoreCookies() async {
    try {
      final cookieManager = CookieManager.instance();
      for (final cookieData in savedCookies) {
        await cookieManager.setCookie(
          url: WebUri('https://labs.google'),
          name: cookieData['name'] ?? '',
          value: cookieData['value'] ?? '',
          domain: cookieData['domain'],
          path: cookieData['path'] ?? '/',
          isSecure: cookieData['isSecure'] ?? true,
          isHttpOnly: cookieData['isHttpOnly'] ?? false,
        );
      }
      print('[PROFILE] $name: Restored ${savedCookies.length} cookies');
    } catch (e) {
      print('[PROFILE] $name: Error restoring cookies: $e');
    }
  }
}

/// Mobile implementation of video generator using InAppWebViewController
class MobileVideoGenerator {
  final InAppWebViewController controller;

  MobileVideoGenerator(this.controller);

  /// Execute JS and return result
  Future<dynamic> _executeJs(String code) async {
    return await controller.evaluateJavascript(source: code);
  }
  
  /// Execute Async JS (await promise)
  Future<dynamic> _executeAsyncJs(String functionBody) async {
    try {
      final result = await controller.callAsyncJavaScript(functionBody: functionBody);
      return result?.value;
    } catch (e) {
      print('[MOBILE] Async JS execution failed: $e');
      return null;
    }
  }

  /// Get access token (with retry logic - 5 attempts, 15s interval)
  Future<String?> getAccessToken() async {
    const int maxRetries = 5;
    const int retryIntervalSeconds = 15;
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      print('[TOKEN] Attempt $attempt/$maxRetries...');
      
      const jsBody = '''
        try {
          const response = await fetch('https://labs.google/fx/api/auth/session', {
            credentials: 'include'
          });
          const data = await response.json();
          return {
            success: response.ok,
            token: data.access_token
          };
        } catch (error) {
          return {
            success: false,
            error: error.message
          };
        }
      ''';

      final result = await _executeAsyncJs(jsBody);
      
      if (result != null) {
        // callAsyncJavaScript returns the object directly (Map)
        if (result is Map) {
          if (result['success'] == true && result['token'] != null) {
            final token = result['token'] as String?;
            if (token != null && token.isNotEmpty) {
              print('[TOKEN] ✓ Got token on attempt $attempt');
              return token;
            }
          }
        } 
        // Fallback for stringified return
        else if (result is String) {
          try {
             final parsed = jsonDecode(result);
             if (parsed is Map && parsed['success'] == true && parsed['token'] != null) {
               final token = parsed['token'] as String?;
               if (token != null && token.isNotEmpty) {
                 print('[TOKEN] ✓ Got token on attempt $attempt');
                 return token;
               }
             }
          } catch (_) {}
        }
      }
      
      // Wait before retry (except on last attempt)
      if (attempt < maxRetries) {
        print('[TOKEN] No token yet, waiting ${retryIntervalSeconds}s before retry...');
        await Future.delayed(Duration(seconds: retryIntervalSeconds));
      }
    }
    
    print('[TOKEN] ✗ Failed to get token after $maxRetries attempts');
    return null;
  }

  /// Quick token fetch (single attempt, no retry - for Connect Opened)
  Future<String?> getAccessTokenQuick() async {
    const jsBody = '''
      try {
        const response = await fetch('https://labs.google/fx/api/auth/session', {
          credentials: 'include'
        });
        const data = await response.json();
        return {
          success: response.ok,
          token: data.access_token
        };
      } catch (error) {
        return {
          success: false,
          error: error.message
        };
      }
    ''';

    final result = await _executeAsyncJs(jsBody);
    
    if (result != null) {
      if (result is Map && result['success'] == true && result['token'] != null) {
        final token = result['token'] as String?;
        if (token != null && token.isNotEmpty) {
          return token;
        }
      } else if (result is String) {
        try {
           final parsed = jsonDecode(result);
           if (parsed is Map && parsed['success'] == true && parsed['token'] != null) {
             return parsed['token'] as String?;
           }
        } catch (_) {}
      }
    }
    return null;
  }

  /// Navigate to Flow and click "Create with Flow" to trigger Google login if not logged in
  Future<void> goToFlowAndTriggerLogin() async {
    print('[MOBILE] Navigating to Flow...');
    
    // Go to Flow Labs page (same URL as autoLogin)
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow')));
    
    // Wait for page to load
    await Future.delayed(const Duration(seconds: 4));
    
    // Click "Create with Flow" button
    await _executeJs('''
      (async function() {
          const buttons = Array.from(document.querySelectorAll('button, div[role="button"], a'));
          const createBtn = buttons.find(b => 
            b.innerText && b.innerText.includes('Create with Flow')
          );
          if (createBtn) {
            createBtn.scrollIntoView({block: "center"});
            await new Promise(r => setTimeout(r, 500));
            createBtn.click();
          }
      })()
    ''');
    
    print('[MOBILE] Clicked Create with Flow (may redirect to Google login)');
  }

  /// Clear all cookies, cache, and storage
  Future<void> clearAllData() async {
    print('[MOBILE] Clearing all browser data...');
    
    // Clear only specific domain cookies instead of all (to preserve other browser sessions)
    final cookieManager = CookieManager.instance();
    // Clear cookies for Flow and Google domains only
    await cookieManager.deleteCookies(url: WebUri('https://labs.google'));
    await cookieManager.deleteCookies(url: WebUri('https://accounts.google.com'));
    await cookieManager.deleteCookies(url: WebUri('https://aisandbox-pa.googleapis.com'));
    
    // Clear web storage via JS for this specific webview
    await _executeJs('''
      try {
        localStorage.clear();
        sessionStorage.clear();
        if (window.indexedDB && window.indexedDB.databases) {
          window.indexedDB.databases().then(dbs => {
            dbs.forEach(db => window.indexedDB.deleteDatabase(db.name));
          });
        }
      } catch(e) {}
    ''');
    
    // Clear cache via controller (this is per-WebView)
    await controller.clearCache();
    
    print('[MOBILE] Browser data cleared for this profile');
  }

  /// Auto login logic for mobile
  Future<bool> autoLogin(String email, String password) async {
    print('[MOBILE] Auto-login: Clearing browser data first...');
    
    // Clear all data before fresh login
    await clearAllData();
    
    print('[MOBILE] Auto-login: Navigating to Flow...');
    
    // Navigate
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow')));
    await Future.delayed(Duration(seconds: 6));
    
    // Click "Create with Flow"
    print('[MOBILE] Auto-login: Clicking Create with Flow...');
    await _executeJs('''
      (async function() {
          const buttons = Array.from(document.querySelectorAll('button, div[role="button"], a'));
          const createBtn = buttons.find(b => 
            b.innerText && b.innerText.includes('Create with Flow')
          );
          if (createBtn) {
            createBtn.scrollIntoView({block: "center"});
            await new Promise(r => setTimeout(r, 1000));
            createBtn.click();
          }
      })()
    ''');
    await Future.delayed(Duration(seconds: 5));
    
    // Email
    print('[MOBILE] Auto-login: Entering email...');
    await _executeJs('''
      (async function() {
        const input = document.getElementById('identifierId');
        if (input) {
          input.focus();
          await new Promise(r => setTimeout(r, 800));
          input.value = '$email';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          await new Promise(r => setTimeout(r, 800));
          
          const btn = document.getElementById('identifierNext');
          if (btn) {
             btn.scrollIntoView({block: "center"});
             await new Promise(r => setTimeout(r, 500));
             btn.click();
          }
        }
      })()
    ''');
    await Future.delayed(Duration(seconds: 7));
    
    // Password
    print('[MOBILE] Auto-login: Entering password...');
    await _executeJs('''
      (async function() {
        const input = document.querySelector('input[name="Passwd"]');
        if (input) {
          input.focus();
          await new Promise(r => setTimeout(r, 800));
          input.value = '$password';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          await new Promise(r => setTimeout(r, 800));
          
          const btn = document.querySelector('#passwordNext');
          if (btn) {
             btn.scrollIntoView({block: "center"});
             await new Promise(r => setTimeout(r, 500));
             btn.click();
          }
        }
      })()
    ''');
    
    // Wait for redirect to Flow and retry fetching token every 15 seconds (6 times = 90 seconds total)
    print('[MOBILE] Auto-login: Waiting for redirect and token (up to 90s)...');
    const maxAttempts = 6;
    const retryInterval = Duration(seconds: 15);
    
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      await Future.delayed(retryInterval);
      print('[MOBILE] Auto-login: Token fetch attempt $attempt/$maxAttempts...');
      
      // Check current URL
      final url = await controller.getUrl();
      print('[MOBILE] Auto-login: Current URL: $url');
      
      // If still on Google login page, wait more
      if (url.toString().contains('accounts.google.com')) {
        print('[MOBILE] Auto-login: Still on Google login page, waiting...');
        continue;
      }
      
      // Try to get token
      final token = await getAccessToken();
      if (token != null && token.isNotEmpty) {
        print('[MOBILE] Auto-login: ✓ Got token on attempt $attempt: ${token.substring(0, 30)}...');
        return true;
      }
      
      print('[MOBILE] Auto-login: Token not available yet (attempt $attempt)');
    }
    
    print('[MOBILE] Auto-login: ✗ Failed to get token after 90 seconds');
    return false;
  }

  /// Download video to file (Desktop method compatibility)
  Future<int> downloadVideo(String url, String outputPath) async {
    print('[MOBILE] Downloading video from $url to $outputPath');
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final file = File(outputPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes);
      return response.bodyBytes.length;
    }
    throw Exception('Download failed with status: ${response.statusCode}');
  }

  /// Upload an image using JS fetch
  Future<dynamic> uploadImage(
    String imagePath,
    String accessToken, {
    String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE',
  }) async {
    try {
      LogService().mobile('Starting upload for: ${imagePath.split(Platform.pathSeparator).last}');
      final imageBytes = await File(imagePath).readAsBytes();
      final imageB64 = base64Encode(imageBytes);

      String mimeType = 'image/jpeg';
      if (imagePath.toLowerCase().endsWith('.png')) {
        mimeType = 'image/png';
      } else if (imagePath.toLowerCase().endsWith('.webp')) {
        mimeType = 'image/webp';
      }

      print('[MOBILE] Uploading image: ${imagePath.split(Platform.pathSeparator).last} (${imageBytes.length} bytes)');

      // Split base64 into chunks to avoid JavaScript string length issues
      const chunkSize = 50000;
      final chunks = <String>[];
      for (var i = 0; i < imageB64.length; i += chunkSize) {
        final end = (i + chunkSize < imageB64.length) ? i + chunkSize : imageB64.length;
        chunks.add(imageB64.substring(i, end));
      }

      final chunksJs = jsonEncode(chunks);

      final jsBody = '''
        try {
          const chunks = $chunksJs;
          const rawImageBytes = chunks.join('');
          
          const payload = {
            imageInput: {
              rawImageBytes: rawImageBytes,
              mimeType: "$mimeType",
              isUserUploaded: true,
              aspectRatio: "$aspectRatio"
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
                'authorization': 'Bearer $accessToken'
              },
              body: JSON.stringify(payload),
              credentials: 'include'
            }
          );
          
          const text = await response.text();
          let data = null;
          try { data = JSON.parse(text); } catch (e) { data = text; }
          
          return {
            success: response.ok,
            status: response.status,
            statusText: response.statusText,
            data: data
          };
        } catch (error) {
          return {
            success: false,
            error: error.message
          };
        }
      ''';

      final result = await _executeAsyncJs(jsBody);
      
      if (result != null) {
        Map<String, dynamic>? resultMap;
        if (result is Map) {
          resultMap = Map<String, dynamic>.from(result);
        } else if (result is String) {
          try { resultMap = jsonDecode(result); } catch (_) {}
        }

        if (resultMap != null) {
           if (resultMap['success'] == true) {
             final data = resultMap['data'];
             
             // Extract Media ID
             if (data is Map) {
                String? mediaId;
                if (data.containsKey('mediaGenerationId')) {
                  final mediaGen = data['mediaGenerationId'];
                  mediaId = (mediaGen is Map) ? mediaGen['mediaGenerationId'] : mediaGen;
                } else if (data.containsKey('mediaId')) {
                  mediaId = data['mediaId'];
                }
                if (mediaId != null) return mediaId;
             }
           }
           
           return {'error': true, 'message': 'Upload failed or invalid response', 'details': resultMap};
        }
      }
      return {'error': true, 'message': 'No result from upload execution'};
       return {'error': true, 'message': 'No result from upload execution'};
    } catch (e) {
      LogService().error('Upload Exception: $e');
      return {'error': true, 'message': e.toString()};
    }
  }

  /// Generate video
  Future<Map<String, dynamic>?> generateVideo({
    required String prompt,
    required String accessToken,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String model = 'veo_3_1_t2v_fast_ultra',
    String? startImageMediaId,
    String? endImageMediaId,
  }) async {
    final sceneId = _generateUuid();
    final seed = (DateTime.now().millisecondsSinceEpoch % 50000);

    // [Model Adjustment Logic - Copied from BrowserVideoGenerator]
    var adjustedModel = model;
    if (aspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' && !model.contains('_portrait')) {
      bool isRelaxed = model.contains('_relaxed');
      var baseModel = model.replaceAll('_relaxed', '');
      if (baseModel.contains('fast')) {
        adjustedModel = baseModel.replaceFirst('fast', 'fast_portrait');
      } else if (baseModel.contains('quality')) {
        adjustedModel = baseModel.replaceFirst('quality', 'quality_portrait');
      }
      if (isRelaxed) adjustedModel += '_relaxed';
    }

    final isI2v = startImageMediaId != null || endImageMediaId != null;
    if (isI2v && adjustedModel.contains('t2v')) {
      adjustedModel = adjustedModel.replaceAll('t2v', 'i2v_s');
    }

    final requestObj = {
      'aspectRatio': aspectRatio,
      'seed': seed,
      'textInput': {'prompt': prompt},
      'videoModelKey': adjustedModel,
      'metadata': {'sceneId': sceneId},
    };
    
    if (startImageMediaId != null) requestObj['startImage'] = {'mediaId': startImageMediaId};
    if (endImageMediaId != null) requestObj['endImage'] = {'mediaId': endImageMediaId};

    final requestJson = jsonEncode(requestObj);
    final endpoint = isI2v
        ? 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage'
        : 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';

    final projectId = _generateUuid();
    
    // JS Payload
    final jsBody = '''
      try {
        let token = 'mock_token';
        let recaptchaStatus = 'missing';
        try {
           if (typeof grecaptcha !== 'undefined') {
             recaptchaStatus = 'found';
             token = await grecaptcha.enterprise.execute(
              '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
              { action: 'FLOW_GENERATION' }
             );
             recaptchaStatus = 'success';
           }
        } catch(e) { 
           console.log('Recaptcha error', e); 
           recaptchaStatus = 'error: ' + e.message;
        }
        
        const payload = {
          clientContext: {
            recaptchaToken: token,
            sessionId: ';' + Date.now(),
            projectId: '$projectId',
            tool: 'PINHOLE',
            userPaygateTier: 'PAYGATE_TIER_TWO'
          },
          requests: [$requestJson]
        };
        
        const response = await fetch(
          '$endpoint',
          {
            method: 'POST',
            headers: { 
              'Content-Type': 'text/plain;charset=UTF-8',
              'authorization': 'Bearer $accessToken'
            },
            body: JSON.stringify(payload),
            credentials: 'include'
          }
        );
        
        const text = await response.text();
        let data = null;
        try { data = JSON.parse(text); } catch (e) { data = text; }
        
        return {
          success: response.ok,
          status: response.status,
          statusText: response.statusText,
          data: data,
          sceneId: '$sceneId',
          debugRecaptcha: recaptchaStatus,
          tokenUsed: token.substring(0, 10) + '...',
          debugPayload: payload
        };
      } catch (error) {
        return {
          success: false,
          error: error.message
        };
      }
    ''';

    LogService().mobile('=== GENERATE REQUEST ===');
    LogService().mobile('Endpoint: $endpoint');
    LogService().mobile('Model: $adjustedModel');
    LogService().mobile('Prompt: "${prompt.length > 50 ? prompt.substring(0,50)+'...' : prompt}"');
    LogService().mobile('Payload: $requestJson');
    
    final result = await _executeAsyncJs(jsBody);
    
    LogService().mobile('=== GENERATE RESPONSE ===');
    if (result != null) {
      final resultStr = result is String ? result : jsonEncode(result);
      LogService().mobile('Response: $resultStr');
      
      Map<String, dynamic>? resultMap;
      if (result is Map) {
        resultMap = Map<String, dynamic>.from(result);
      } else if (result is String) {
        try { resultMap = jsonDecode(result); } catch (_) {}
      }

      if (resultMap != null) {
         return resultMap;
      }
    } else {
      LogService().error('Response: NULL');
    }
    return null;
  }

  /// Poll single video status
  Future<Map<String, dynamic>?> pollVideoStatus(
    String operationName,
    String sceneId,
    String accessToken,
  ) async {
    final payload = {
      'operations': [
        {
          'operation': {'name': operationName},
          'sceneId': sceneId,
          'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
        }
      ]
    };

    final jsBody = '''
      try {
        const response = await fetch(
          'https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus',
          {
            method: 'POST',
            headers: { 
              'Content-Type': 'text/plain;charset=UTF-8',
              'authorization': 'Bearer $accessToken'
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
        return JSON.stringify({ success: false, error: error.message });
      }
    ''';

    print('[pollVideoStatus] Polling Op: $operationName');
    final result = await _executeAsyncJs(jsBody);
    print('[pollVideoStatus] Raw result: $result');
    
    if (result != null) {
      // Parse JSON string result
      Map<String, dynamic>? resultMap;
      if (result is String) {
        try { resultMap = jsonDecode(result); } catch (_) {}
      } else if (result is Map) {
        resultMap = Map<String, dynamic>.from(result);
      }
      
      print('[pollVideoStatus] Parsed: $resultMap');
      
      if (resultMap != null && resultMap['success'] == true) {
         final data = resultMap['data'];
         if (data is Map && data.containsKey('operations')) {
            final ops = data['operations'] as List;
            if (ops.isNotEmpty) {
              print('[pollVideoStatus] Returning operation: ${ops[0]}');
              return ops[0] as Map<String, dynamic>;
            }
         }
      }
    }
    return null;
  }


  Future<List<Map<String, dynamic>>?> pollVideoStatusBatch(
    List<PollRequest> requests,
    String accessToken,
  ) async {
    if (requests.isEmpty) return [];

    final payload = {
      'operations': requests.map((r) {
        return <String, dynamic>{
          'operation': <String, dynamic>{'name': r.operationName},
          'sceneId': r.sceneId,
          'status': 'MEDIA_GENERATION_STATUS_ACTIVE',
        };
      }).toList(),
    };

    final jsBody = '''
      try {
        const response = await fetch(
          'https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus',
          {
            method: 'POST',
            headers: { 
              'Content-Type': 'text/plain;charset=UTF-8',
              'authorization': 'Bearer $accessToken'
            },
            body: JSON.stringify(${jsonEncode(payload)}),
            credentials: 'include'
          }
        );
        const text = await response.text();
        let data = null;
        try { data = JSON.parse(text); } catch (e) { data = text; }
        return {
          success: response.ok,
          status: response.status,
          data: data
        };
      } catch (error) {
        return { success: false, error: error.message };
      }
    ''';

    // Log the full request payload
    final payloadJson = jsonEncode(payload);
    LogService().mobile('=== POLL REQUEST ===');
    LogService().mobile('URL: https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus');
    LogService().mobile('Payload: $payloadJson');
    
    final result = await _executeAsyncJs(jsBody);
    
    // Log the full response
    LogService().mobile('=== POLL RESPONSE ===');
    if (result != null) {
      final resultStr = result is String ? result : jsonEncode(result);
      LogService().mobile('Response: $resultStr');
    } else {
      LogService().error('Response: NULL');
    }
    
    if (result != null) {
      Map<String, dynamic>? resultMap;
      if (result is Map) {
        resultMap = Map<String, dynamic>.from(result);
      } else if (result is String) {
        try { resultMap = jsonDecode(result); } catch (_) {}
      }
      
      LogService().mobile('[pollVideoStatusBatch] resultMap: ${resultMap != null ? jsonEncode(resultMap) : "NULL"}');

      if (resultMap != null && resultMap['success'] == true) {
         final data = resultMap['data'];
         LogService().mobile('[pollVideoStatusBatch] data type: ${data?.runtimeType}, contains operations: ${data is Map && data.containsKey("operations")}');
         
         if (data is Map && data.containsKey('operations')) {
            final ops = (data['operations'] as List).cast<Map<String, dynamic>>();
            LogService().mobile('[pollVideoStatusBatch] Raw operations count: ${ops.length}');
            
            // Merge sceneId from original request into each result for easier matching
            final enrichedOps = <Map<String, dynamic>>[];
            for (int i = 0; i < ops.length; i++) {
              final op = Map<String, dynamic>.from(ops[i]);
              // Try to match by index (API returns in same order as request)
              if (i < requests.length) {
                op['sceneId'] = requests[i].sceneId;
              }
              enrichedOps.add(op);
              LogService().mobile('[pollVideoStatusBatch] Op[$i]: status=${op['status']}, sceneId=${op['sceneId']}');
            }
            
            LogService().mobile('[pollVideoStatusBatch] Returning ${enrichedOps.length} enriched operations');
            return enrichedOps;
         } else {
            LogService().error('[pollVideoStatusBatch] data has no operations key or wrong type');
         }
      } else {
         LogService().error('[pollVideoStatusBatch] resultMap is null or success != true. success=${resultMap?["success"]}');
      }
    } else {
      LogService().error('[pollVideoStatusBatch] result from _executeAsyncJs is NULL');
    }
    return null;
  }
  
  String _generateUuid() {
    final random = Random();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}

/// Service to manage multiple mobile WebViews
class MobileBrowserService {
  static final MobileBrowserService _instance = MobileBrowserService._internal();
  factory MobileBrowserService() => _instance;
  MobileBrowserService._internal();

  final List<MobileProfile> profiles = [];
  
  void initialize(int count) {
    if (profiles.isNotEmpty) return;
    for (int i = 0; i < count; i++) {
      profiles.add(MobileProfile(id: 'mob_\$i', name: 'Browser \${i + 1}'));
    }
  }

  MobileProfile? getProfile(int index) {
    if (index >= 0 && index < profiles.length) return profiles[index];
    return null;
  }

  int countConnected() => profiles.where((p) => p.status == MobileProfileStatus.ready).length;
  
  /// Count profiles that are ready AND haven't hit 403 threshold AND not relogging
  int countHealthy() => profiles.where((p) => 
    p.status == MobileProfileStatus.ready && 
    p.consecutive403Count < 3 &&
    !p.isReloginInProgress
  ).length;
  
  MobileVideoGenerator? getGenerator(int index) => profiles[index].generator;
  
  int _currentIndex = 0;
  MobileProfile? getNextAvailableProfile() {
    for (int i = 0; i < profiles.length; i++) {
      final idx = (_currentIndex + i) % profiles.length;
      final p = profiles[idx];
      // Skip profiles that have hit 403 threshold, are relogging, or not ready
      if (p.status == MobileProfileStatus.ready && 
          p.generator != null && 
          p.consecutive403Count < 3 &&
          !p.isReloginInProgress) {
        _currentIndex = (idx + 1) % profiles.length;
        return p;
      }
    }
    return null;
  }
  
  /// Get profiles that need re-login (403 threshold reached)
  List<MobileProfile> getProfilesNeedingRelogin() {
    return profiles.where((p) => p.consecutive403Count >= 3 && !p.isReloginInProgress).toList();
  }
  
  /// Reset 403 count for a profile (after successful re-login)
  void resetProfile403Count(String profileId) {
    final p = profiles.firstWhere((p) => p.id == profileId, orElse: () => profiles.first);
    p.consecutive403Count = 0;
    p.reloginAttempts = 0;
  }
  
  /// Auto re-login for a profile that has hit 403 threshold
  /// - Clears browser data
  /// - Navigates to login page
  /// - Retries up to 15 times
  /// - On success, resets 403 count and resumes generation
  Future<bool> autoReloginProfile(MobileProfile profile, {Function()? onSuccess}) async {
    if (profile.isReloginInProgress) {
      print('[RELOGIN] ${profile.name} - Already in progress');
      return false;
    }
    
    profile.isReloginInProgress = true;
    profile.status = MobileProfileStatus.loading;
    print('[RELOGIN] ${profile.name} - Starting auto-relogin (attempt ${profile.reloginAttempts + 1}/15)');
    
    try {
      final controller = profile.controller;
      if (controller == null) {
        print('[RELOGIN] ${profile.name} - No controller available');
        profile.isReloginInProgress = false;
        return false;
      }
      
      // 1. Clear all browser data
      print('[RELOGIN] ${profile.name} - Clearing browser data...');
      await CookieManager.instance().deleteAllCookies();
      await controller.clearCache();
      // Clear local storage and session storage
      await controller.evaluateJavascript(source: '''
        try { localStorage.clear(); } catch(e) {}
        try { sessionStorage.clear(); } catch(e) {}
      ''');
      
      // 2. Navigate to Flow login page (same as PC version)
      print('[RELOGIN] ${profile.name} - Navigating to Flow login page...');
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow'))
      );
      
      // 3. Wait for page to load and try to get token
      await Future.delayed(const Duration(seconds: 5));
      
      // 4. Try to fetch token with retries
      const maxTokenAttempts = 6;
      for (int tokenAttempt = 1; tokenAttempt <= maxTokenAttempts; tokenAttempt++) {
        print('[RELOGIN] ${profile.name} - Fetching token (attempt $tokenAttempt/$maxTokenAttempts)...');
        
        if (profile.generator != null) {
          final token = await profile.generator!.getAccessToken();
          if (token != null && token.isNotEmpty) {
            // Success!
            print('[RELOGIN] ✓ ${profile.name} - Got token successfully!');
            profile.accessToken = token;
            profile.status = MobileProfileStatus.ready;
            profile.consecutive403Count = 0;
            profile.reloginAttempts = 0;
            profile.isReloginInProgress = false;
            
            // Call success callback if provided
            onSuccess?.call();
            return true;
          }
        }
        
        // Wait before retry
        await Future.delayed(const Duration(seconds: 3));
      }
      
      // Token fetch failed after 6 attempts, increment relogin attempt and try again
      profile.reloginAttempts++;
      print('[RELOGIN] ${profile.name} - Token fetch failed, relogin attempt ${profile.reloginAttempts}/15');
      
      if (profile.reloginAttempts < 15) {
        profile.isReloginInProgress = false;
        // Retry the entire relogin process
        return await autoReloginProfile(profile, onSuccess: onSuccess);
      } else {
        // Exhausted all attempts
        print('[RELOGIN] ❌ ${profile.name} - Failed after 15 attempts');
        profile.status = MobileProfileStatus.error;
        profile.isReloginInProgress = false;
        return false;
      }
      
    } catch (e) {
      print('[RELOGIN] ${profile.name} - Error: $e');
      profile.isReloginInProgress = false;
      profile.reloginAttempts++;
      
      if (profile.reloginAttempts < 15) {
        await Future.delayed(const Duration(seconds: 2));
        return await autoReloginProfile(profile, onSuccess: onSuccess);
      }
      return false;
    }
  }
  
  /// Trigger relogin for all profiles that need it
  Future<void> reloginAllNeeded({Function()? onAnySuccess}) async {
    final needsRelogin = getProfilesNeedingRelogin();
    if (needsRelogin.isEmpty) return;
    
    print('[RELOGIN] Found ${needsRelogin.length} profiles needing relogin');
    
    for (final profile in needsRelogin) {
      await autoReloginProfile(profile, onSuccess: onAnySuccess);
    }
  }
}
