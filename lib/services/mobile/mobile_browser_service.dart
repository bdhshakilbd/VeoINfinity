
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import '../log_service.dart';
import '../../models/poll_request.dart'; // Using common model
import 'mobile_log_manager.dart';  // For UI logging

/// User Agent Rotator - generates random realistic Chrome user agents
class UserAgentRotator {
  static final _random = Random();
  
  // Pool of Chrome versions (130-135)
  static const _chromeVersions = ['130.0.0.0', '131.0.0.0', '132.0.0.0', '133.0.0.0', '134.0.0.0', '135.0.0.0'];
  
  // Pool of Windows versions
  static const _windowsVersions = ['Windows NT 10.0; Win64; x64', 'Windows NT 11.0; Win64; x64'];
  
  // Pool of Android devices
  static const _androidDevices = [
    'Linux; Android 14; Pixel 8 Pro',
    'Linux; Android 14; Pixel 8',
    'Linux; Android 14; SM-S928B', // Samsung Galaxy S24 Ultra
    'Linux; Android 14; SM-S921B', // Samsung Galaxy S24
    'Linux; Android 13; SM-G998B', // Samsung Galaxy S21 Ultra
    'Linux; Android 14; Pixel 7 Pro',
    'Linux; Android 14; OnePlus 12',
  ];
  
  /// Get a random desktop user agent
  static String getDesktopUA() {
    final chrome = _chromeVersions[_random.nextInt(_chromeVersions.length)];
    final windows = _windowsVersions[_random.nextInt(_windowsVersions.length)];
    return 'Mozilla/5.0 ($windows) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chrome Safari/537.36';
  }
  
  /// Get a random mobile user agent
  static String getMobileUA() {
    final chrome = _chromeVersions[_random.nextInt(_chromeVersions.length)];
    final device = _androidDevices[_random.nextInt(_androidDevices.length)];
    return 'Mozilla/5.0 ($device) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chrome Mobile Safari/537.36';
  }
  
  /// Get random UA based on platform
  static String getRandomUA() {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return getDesktopUA();
    }
    return getMobileUA();
  }
}


/// Status of a Mobile profile
enum MobileProfileStatus {
  disconnected,
  loading,
  connected,  // Webview load stop
  ready,      // Has token
  error,
}

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
  
  // Track if browser has been refreshed this session (to prevent infinite refresh loops)
  bool browserRefreshedThisSession = false;
  
  bool get isConnected => status == MobileProfileStatus.ready;
  bool get isReady => status == MobileProfileStatus.ready;
  bool get needsRelogin => consecutive403Count >= 7;

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

  // For compatibility with desktop generator
  bool get isConnected => true; // Mobile webview is always connected if controller exists
  
  final List<String> _recaptchaPool = [];

  /// Prefetch reCAPTCHA tokens - DEPRECATED: Prefetched tokens cause 403 errors
  /// Each video generation MUST use a fresh token fetched at the moment of request
  @Deprecated('Prefetched tokens cause 403 errors. Use getRecaptchaToken() for fresh tokens.')
  Future<int> prefetchRecaptchaTokens(int count) async {
    print('[MOBILE BROWSER] ⚠️ Token prefetching disabled - using fresh tokens per request');
    return 0; // Return 0 to indicate no tokens prefetched (this is intentional)
  }

  /// Get reCAPTCHA token - ALWAYS fetch fresh (never use cache to avoid 403)
  Future<String?> getRecaptchaToken() async {
    // CRITICAL: Always fetch fresh token - cached tokens cause 403 errors
    // The pool is cleared here to ensure no stale tokens are ever used
    _recaptchaPool.clear();
    return await _fetchNewRecaptchaToken();
  }

  /// Internal: Fetch a fresh reCAPTCHA token from JS
  Future<String?> _fetchNewRecaptchaToken() async {
    try {
      // First, ensure we're on the right page
      final currentUrl = await controller.getUrl();
      if (currentUrl?.host != 'labs.google') {
        print('[MOBILE BROWSER] ⚠️  Not on labs.google, navigating...');
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri('https://labs.google')));
        // Wait for page to load
        await Future.delayed(const Duration(seconds: 3));
      }
      

      
      // Use callAsyncJavaScript like getAccessToken does
      const jsBody = '''
        try {
          // Wait for grecaptcha to be available
          for (let i = 0; i < 30; i++) {
            if (typeof grecaptcha !== 'undefined' && grecaptcha.enterprise) {
              break;
            }
            await new Promise(r => setTimeout(r, 200));
          }
          
          if (typeof grecaptcha === 'undefined' || !grecaptcha.enterprise) {
            return {
              success: false,
              error: 'grecaptcha not loaded after 6s'
            };
          }
          
          const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
          console.log('[RECAPTCHA] Executing with action: VIDEO_GENERATION');
          const token = await grecaptcha.enterprise.execute(siteKey, {
            action: 'VIDEO_GENERATION'
          });
          console.log('[RECAPTCHA] Got token length:', token.length);
          
          return {
            success: true,
            token: token
          };
        } catch (error) {
          console.error('[RECAPTCHA] Error:', error);
          return {
            success: false,
            error: error.message
          };
        }
      ''';
      
      final result = await _executeAsyncJs(jsBody, timeoutSeconds: 10);
      
      if (result is Map) {
        if (result['success'] == true && result['token'] != null) {
          final token = result['token'].toString();

          return token;
        } else {
          final error = result['error'] ?? 'Unknown error';
          print('[MOBILE BROWSER] ✗ reCAPTCHA error: $error');
          return null;
        }
      }
      

      return null;
    } catch (e) {
      print('[MOBILE BROWSER] ✗ Exception fetching reCAPTCHA: $e');

      return null;
    }
  }

  /// Generate video using BROWSER JS (like Desktop CDP) - Executes fetch() in browser to avoid reCAPTCHA flags
  /// This approach gets ~16 videos before reCAPTCHA errors vs ~4 with HTTP
  Future<Map<String, dynamic>?> generateVideo({
    required String prompt,
    required String accessToken,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String model = 'veo_3_1_t2v_fast_ultra',
    String? startImageMediaId,
    String? endImageMediaId,
    String? recaptchaToken,
  }) async {
    // Single attempt - retry logic is handled by caller (tracks consecutive 403s per browser)
    try {
      // Step 1: Fetch FRESH reCAPTCHA token
      final freshToken = await getRecaptchaToken();
      if (freshToken == null) {
        print('[MOBILE JS] ❌ Failed to get token');
        return {'success': false, 'error': 'Failed to get reCAPTCHA token'};
      }
      
      // Step 2: Generate UUIDs
      final random = Random();
      String generateUuid() {
        String hex(int length) => List.generate(length, (_) => random.nextInt(16).toRadixString(16)).join();
        return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(12)}';
      }
      
      final sceneUuid = generateUuid();
      final projectId = generateUuid();
      final seed = random.nextInt(50000);
      
      // Step 3: Determine endpoint
      final String endpoint;
      if (startImageMediaId != null && endImageMediaId != null) {
        endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartAndEndImage';
      } else if (startImageMediaId != null) {
        endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage';
      } else {
        endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';
      }
      
      // Step 4: Build payload (exactly like desktop)
      final requestObj = {
        'aspectRatio': aspectRatio,
        'seed': seed,
        'textInput': {'prompt': prompt},
        'videoModelKey': model,
        if (startImageMediaId != null) 'startImage': {'mediaId': startImageMediaId},
        if (endImageMediaId != null) 'endImage': {'mediaId': endImageMediaId},
        'metadata': {'sceneId': sceneUuid},
      };
      
      final payload = {
        'clientContext': {
          'recaptchaContext': {'token': freshToken, 'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB'},
          'sessionId': ';${DateTime.now().millisecondsSinceEpoch}',
          'projectId': projectId,
          'tool': 'PINHOLE',
          'userPaygateTier': 'PAYGATE_TIER_TWO'
        },
        'requests': [requestObj]
      };
      
      final payloadJson = jsonEncode(payload);
      
      // Step 5: Execute fetch in browser
      final jsCode = '''
try {
  const response = await fetch("$endpoint", {
    method: "POST",
    headers: {
      "authorization": "Bearer $accessToken",
      "content-type": "text/plain;charset=UTF-8"
    },


    body: JSON.stringify($payloadJson)
  });
  return await response.json();
} catch (error) {
  return {
    error: {
      code: 0,
      message: error.message || 'Fetch failed',
      status: 'INTERNAL_ERROR'
    }
  };
}
      ''';
      
      final result = await _executeAsyncJs(jsCode, timeoutSeconds: 30);
      
      // Parse response
      if (result == null) {
        print('[MOBILE JS] ❌ Null response');
        return {'success': false, 'error': 'No response'};
      }
      
      // Check for error
      if (result['error'] != null) {
        final errorCode = result['error']['code'];
        final errorMsg = result['error']['message'] ?? result['error'].toString();
        print('[MOBILE JS] ❌ Error $errorCode: $errorMsg');
        return {'success': false, 'error': errorMsg.toString(), 'data': result, 'errorCode': errorCode};
      }
      
      // Check for success
      if (result['operations'] != null) {
        print('[MOBILE JS] ✅ Success (200)');
        return {'success': true, 'data': result};
      }
      
      // Invalid response
      print('[MOBILE JS] ⚠️ Invalid response');
      return {'success': false, 'error': 'Invalid response', 'data': result};
      
    } catch (e, stack) {
      print('[MOBILE JS] ✗ Exception: $e');
      print('[MOBILE JS] Stack: $stack');
      return {'success': false, 'error': e.toString()};
    }
  }


  /// Execute JS and return result
  Future<dynamic> _executeJs(String code) async {
    return await controller.evaluateJavascript(source: code);
  }
  
  /// Execute Async JS (await promise) with timeout
  Future<dynamic> _executeAsyncJs(String functionBody, {int timeoutSeconds = 60}) async {
    try {
      final result = await controller.callAsyncJavaScript(functionBody: functionBody)
          .timeout(Duration(seconds: timeoutSeconds), onTimeout: () {
        return null;
      });
      return result?.value;
    } catch (e) {
      print('[MOBILE JS] ✗ JS Error: $e');
      return null;
    }
  }

  /// Get access token (with retry logic - 5 attempts, 15s interval)
  Future<String?> getAccessToken() async {
    const int maxRetries = 5;
    const int retryIntervalSeconds = 15;
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      mobileLog('[TOKEN] Attempt $attempt/$maxRetries...');
      
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
              mobileLog('[TOKEN] ✓ Got token on attempt $attempt');
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
                 mobileLog('[TOKEN] ✓ Got token on attempt $attempt');
                 return token;
               }
             }
          } catch (_) {}
        }
      }
      
      // Wait before retry (except on last attempt)
      if (attempt < maxRetries) {
        mobileLog('[TOKEN] No token yet, waiting ${retryIntervalSeconds}s before retry...');
        await Future.delayed(const Duration(seconds: retryIntervalSeconds));
      }
    }
    
    mobileLog('[TOKEN] ✗ Failed to get token after $maxRetries attempts');
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

  /// Clear only local storage, session storage, and cache (PRESERVE COOKIES)
  Future<void> clearLocalStorageOnly() async {
    mobileLog('[BROWSER] Clearing local storage and cache...');
    print('[MOBILE] Clearing local storage and cache (preserving cookies)...');
    
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
    
    await controller.clearCache();
    await Future.delayed(const Duration(seconds: 1));
  }

  /// Clear all cookies, cache, and storage
  Future<void> clearAllData() async {
    print('[MOBILE] Clearing all browser data (including cookies)...');
    
    // Clear cookies for Flow and Google domains
    final cookieManager = CookieManager.instance();
    await cookieManager.deleteCookies(url: WebUri('https://labs.google'));
    await cookieManager.deleteCookies(url: WebUri('https://accounts.google.com'));
    await cookieManager.deleteCookies(url: WebUri('https://aisandbox-pa.googleapis.com'));
    
    // Clear everything else
    await clearLocalStorageOnly();
    
    print('[MOBILE] All browser data cleared');
  }

  // Stop flag
  bool _stopRequested = false;

  void stopLogin() {
    _stopRequested = true;
    mobileLog('[LOGIN] Stop requested by user.');
  }

  /// Auto login logic for mobile - USING DESKTOP VERSION
  Future<bool> autoLogin(String email, String password) async {
    _stopRequested = false;
    
    // Rotate user agent on each login attempt
    final newUA = UserAgentRotator.getRandomUA();
    try {
      await controller.setSettings(settings: InAppWebViewSettings(userAgent: newUA));
      print('[LOGIN] 🔄 User Agent rotated: ${newUA.substring(0, 50)}...');
    } catch (e) {
      print('[LOGIN] ⚠️ Could not set UA: $e');
    }
    
    mobileLog('[LOGIN] Starting fast auto-login...');
    mobileLog('[LOGIN] 📧 Email: $email');
    mobileLog('[LOGIN] 🔑 Password: ${password.isNotEmpty ? "***${password.length} chars***" : "EMPTY"}');
    
    // Helper for polling checks
    Future<bool> pollCheck(Future<bool> Function() check, {int maxAttempts = 60, int intervalMs = 1000}) async {
      for (int i = 0; i < maxAttempts; i++) {
        if (_stopRequested) return false; // Early exit
        if (await check()) return true;
        await Future.delayed(Duration(milliseconds: intervalMs));
      }
      return false;
    }

    while (!_stopRequested) {
      try {
        if (_stopRequested) {
           mobileLog('[LOGIN] Process stopped.');
           return false;
        }

        // Step 0: Check session first
        if ((await getAccessTokenQuick()) != null) {
          mobileLog('[LOGIN] ✓ Session active!');
          return true;
        }

        // ... (rest of logic) ...
        // Step 1: Navigate to Flow
        mobileLog('[LOGIN] Navigating to Flow...');
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow')));
        
        // Wait for page to stabilize
        mobileLog('[LOGIN] Waiting for page to load...');
        await Future.delayed(const Duration(seconds: 5));
        
        // Step 2: Trigger Google Login via API (programmatic - bypass button)
        bool isOnGoogle = false;
        mobileLog('[LOGIN] Triggering Google Login via API...');
        
        final apiResult = await _executeAsyncJs('''
            (async function() {
              try {
                // 1. Get CSRF Token
                const csrfRes = await fetch('https://labs.google/fx/api/auth/csrf');
                const csrfData = await csrfRes.json();
                const token = csrfData.csrfToken;
                
                // 2. Post to Signin
                const formData = new URLSearchParams();
                formData.append('csrfToken', token);
                formData.append('callbackUrl', 'https://labs.google/fx/tools/flow');
                formData.append('json', 'true');
                
                const signinRes = await fetch('https://labs.google/fx/api/auth/signin/google', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/x-www-form-urlencoded'
                  },
                  body: formData.toString()
                });
                
                const signinData = await signinRes.json();
                
                // 3. Redirect
                if (signinData.url) {
                   window.location.href = signinData.url;
                   return 'REDIRECTING';
                }
                return 'NO_URL';
              } catch(e) {
                return 'ERROR: ' + e.toString();
              }
            })()
        ''');
        
        mobileLog('[LOGIN] API Result: $apiResult');

        if (_stopRequested) return false;

        // Wait for redirect to Google
        isOnGoogle = await pollCheck(() async {
           final url = (await controller.getUrl()).toString();
           return url.contains('accounts.google.com');
        }, maxAttempts: 15, intervalMs: 1000);
        
        if (!isOnGoogle) {
           mobileLog('[LOGIN] ✗ API Trigger failed to redirect to Google. Retrying...');
           await controller.reload();
           await Future.delayed(const Duration(seconds: 3));
           continue;
        }

        if (_stopRequested) return false;

         // Step 4: Login Flow
        if ((await controller.getUrl()).toString().contains('accounts.google.com')) {
          mobileLog('[LOGIN] Google Login detected');
          
          // Email - wait for field
          mobileLog('[LOGIN] Waiting for Email input...');
          bool emailReady = await pollCheck(() async {
            final res = await controller.evaluateJavascript(source: "document.getElementById('identifierId') != null");
            return res == true || res == 'true';
          }, maxAttempts: 20, intervalMs: 500);
          
          if (_stopRequested) return false;

          if (emailReady) {
            // Wait 3s before typing to allow UI to settle
            mobileLog('[LOGIN] Waiting 3s before entering email...');
            await Future.delayed(const Duration(seconds: 3));
            
            mobileLog('[LOGIN] Entering email...');
            await controller.evaluateJavascript(source: '''
              var input = document.getElementById('identifierId');
              if (input) {
                input.value = ${jsonEncode(email)};
                input.dispatchEvent(new Event('input', { bubbles: true }));
                setTimeout(function() {
                  document.getElementById('identifierNext').click();
                }, 1500);
              }
            ''');
            mobileLog('[LOGIN] Email entered, clicking Next...');
            
            // Wait 3s after clicking Next before looking for password
            await Future.delayed(const Duration(seconds: 3));
          } else {
            mobileLog('[LOGIN] ✗ Email field NOT found. Retrying...');
            await Future.delayed(const Duration(seconds: 2));
            continue; // Retry
          }
          
          // Password
          mobileLog('[LOGIN] Waiting for Password input...');
          bool passReady = await pollCheck(() async {
            final res = await controller.evaluateJavascript(source: "document.querySelector('input[name=\"Passwd\"]') != null");
            return res == true || res == 'true';
          }, maxAttempts: 15, intervalMs: 500);

          if (_stopRequested) return false;

          if (passReady) {
             // Wait 3s before typing password
             mobileLog('[LOGIN] Waiting 3s before entering password...');
             await Future.delayed(const Duration(seconds: 3));
             
             mobileLog('[LOGIN] Entering password...');
             await controller.evaluateJavascript(source: '''
               var input = document.querySelector('input[name="Passwd"]');
               if (input) {
                 input.value = ${jsonEncode(password)};
                 input.dispatchEvent(new Event('input', { bubbles: true }));
                 setTimeout(function() {
                   document.querySelector('#passwordNext').click();
                 }, 1500);
               }
             ''');
             mobileLog('[LOGIN] Password entered, clicking Next...');
          } else {
            mobileLog('[LOGIN] ✗ Password field NOT found. Retrying...');
            await Future.delayed(const Duration(seconds: 2));
            continue; // Retry
          }
        }

        // Step 5: Wait 15s for login to complete (page auto-redirects to Flow)
        mobileLog('[LOGIN] Waiting 15s for login to complete...');
        await Future.delayed(const Duration(seconds: 15));
        
        if (_stopRequested) return false;

        // Step 6: Verify Token (3 attempts, 15s interval)
        mobileLog('[LOGIN] Verifying token...');
        for (int tokenAttempt = 1; tokenAttempt <= 3; tokenAttempt++) {
          // On 2nd+ attempt, reload Flow URL to unstick if needed
          if (tokenAttempt >= 2) {
            mobileLog('[LOGIN] Reloading Flow URL...');
            await controller.loadUrl(urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow')));
            await Future.delayed(const Duration(seconds: 5));
          }
          
          final token = await getAccessTokenQuick();
          if (token != null) {
            mobileLog('[LOGIN] ✓ Success!');
            return true;
          }
          if (tokenAttempt < 3) {
            mobileLog('[LOGIN] Token check $tokenAttempt/3 failed, waiting 15s...');
            await Future.delayed(const Duration(seconds: 15));
          }
        }
        
        mobileLog('[LOGIN] ✗ Token not found after 3 attempts. Retrying login...');
        await Future.delayed(const Duration(seconds: 2));
        // Continue to retry the whole login

      } catch (e) {
        if (_stopRequested) return false;
        mobileLog('[LOGIN] Error: $e. Retrying...');
        await Future.delayed(const Duration(seconds: 3));
      }
    }
    mobileLog('[LOGIN] ✗ Failed after 30 attempts.');
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
    } catch (e) {
      LogService().error('Upload Exception: $e');
      return {'error': true, 'message': e.toString()};
    }
  }

  /// Batch Poll for Mobile (Python Style) - JS-based variant
  Future<List<Map<String, dynamic>>?> pollVideoStatusBatchViaJS(List<PollRequest> requests, String accessToken) async {
    final payload = {
      'operations': requests.map((r) => {
        'operation': {'name': r.operationName},
        'sceneId': r.sceneId,
        'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
      }).toList()
    };

    final jsCode = '''
      (async function() {
        try {
          const response = await fetch('https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer $accessToken' },
            body: JSON.stringify(${jsonEncode(payload)}),
            credentials: 'include'
          });
          const data = await response.json();
          return { success: response.ok, data: data };
        } catch (e) { return { success: false, error: e.toString() }; }
      })()
    ''';

    final result = await _executeAsyncJs(jsCode);
    if (result != null && result['success'] == true) {
      return List<Map<String, dynamic>>.from(result['data']['operations']);
    }
    return null;
  }

  // Token queue (Python Style)
  final List<String> _prefetchedTokens = [];
  
  String? getNextPrefetchedToken() {
    if (_prefetchedTokens.isEmpty) return null;
    return _prefetchedTokens.removeAt(0);
  }

  /// Generate video using Chrome Extension (NEW METHOD - More Reliable)
  Future<Map<String, dynamic>?> generateVideoViaExtension({
    required String prompt,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String model = 'Veo 3.1 - Fast',
    String? startImageMediaId,
    String? endImageMediaId,
    Function(int progress, String status)? onProgress,
  }) async {
    print('[MOBILE EXTENSION] Generating video via extension...');
    print('[MOBILE EXTENSION] Prompt: ${prompt.length > 50 ? "${prompt.substring(0, 50)}..." : prompt}');
    
    // Map aspect ratio from API format to UI format
    String uiAspectRatio;
    if (aspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE') {
      uiAspectRatio = 'Landscape (16:9)';
    } else if (aspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT') {
      uiAspectRatio = 'Portrait (9:16)';
    } else if (aspectRatio == 'VIDEO_ASPECT_RATIO_SQUARE') {
      uiAspectRatio = 'Square (1:1)';
    } else {
      uiAspectRatio = 'Landscape (16:9)';
    }
    
    // Determine mode
    String mode;
    if (startImageMediaId != null || endImageMediaId != null) {
      mode = 'Frames to Video';
    } else {
      mode = 'Text to Video';
    }
    
    final requestId = 'mobile_${DateTime.now().millisecondsSinceEpoch}';
    
    final jsCode = '''
    (async function() {
      const timeout = setTimeout(() => ({error: 'Timeout'}), 360000);
      
      return new Promise((resolve) => {
        const handler = (event) => {
          if (event.data.type === 'VEO3_RESPONSE' && event.data.requestId === '$requestId') {
            clearTimeout(timeout);
            window.removeEventListener('message', handler);
            resolve(event.data.result || {error: event.data.error});
          }
        };
        
        window.addEventListener('message', handler);
        window.postMessage({
          type: 'VEO3_GENERATE',
          opts: {
            prompt: ${jsonEncode(prompt)},
            aspectRatio: '$uiAspectRatio',
            model: '$model',
            outputCount: 1,
            mode: '$mode',
            createNewProject: false
          },
          requestId: '$requestId'
        }, '*');
      });
    })()
    ''';
    
    try {
      final result = await _executeAsyncJs(jsCode);
      
      if (result is Map) {
        final resultMap = Map<String, dynamic>.from(result);
        
        if (resultMap['status'] == 'complete') {
          print('[MOBILE EXTENSION] ✓ Video generated successfully!');
          return resultMap;
        } else if (resultMap['error'] != null) {
          print('[MOBILE EXTENSION] ✗ Error: ${resultMap['error']}');
          return resultMap;
        }
      }
      
      return result as Map<String, dynamic>?;
    } catch (e) {
      print('[MOBILE EXTENSION] ✗ Exception: $e');
      return {'error': e.toString()};
    }
  }

  /// NEW METHOD: Generate video using React Handler (Avoids Automation Detection)
  /// 
  /// This method directly calls React's onChange and onClick handlers to trigger
  /// video generation, which avoids being detected as automation and prevents 403 errors.
  Future<Map<String, dynamic>?> generateVideoReactHandler({
    required String prompt,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String model = 'Veo 3.1 - Fast',
    String? startImageMediaId,
    String? endImageMediaId,
    Function(int progress, String status)? onProgress,
  }) async {
    print('[MOBILE REACT] Generating video via React handlers...');
    print('[MOBILE REACT] Prompt: ${prompt.length > 50 ? "${prompt.substring(0, 50)}..." : prompt}');
    
    try {
      // Step 1: Setup network monitor
      await _setupNetworkMonitorMobile();
      
      // Step 2: Ensure project is open
      await _ensureProjectOpenMobile();
      
      // Step 3: Reset monitor
      await _resetMonitorMobile();
      
      // Step 4: Trigger generation
      final triggerResult = await _triggerGenerationReactMobile(prompt);
      
      if (triggerResult['success'] != true) {
        print('[MOBILE REACT] ✗ Failed to trigger: ${triggerResult['error']}');
        return {'error': triggerResult['error']};
      }
      
      print('[MOBILE REACT] ✓ Generation triggered!');
      
      // Step 5: Poll for completion
      return await _pollForCompletionMobile(onProgress: onProgress);
      
    } catch (e) {
      print('[MOBILE REACT] ✗ Exception: $e');
      return {'error': e.toString()};
    }
  }

  Future<void> _setupNetworkMonitorMobile() async {
    final jsCode = '''
(() => {
    if (window.__veo3_monitor) {
        return {success: true, alreadyInstalled: true};
    }
    
    window.__veo3_monitor = {
        startTime: Date.now(),
        operationName: null,
        videoUrl: null,
        status: 'idle',
        credits: null,
        lastUpdate: null,
        error: null,
        apiError: null
    };
    
    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        const url = args[0]?.toString() || '';
        
        if (url.includes('batchAsyncGenerateVideoText') || 
            url.includes('batchAsyncGenerateVideoStartImage') ||
            url.includes('batchAsyncGenerateVideoStartAndEndImage')) {
            try {
                const clone = response.clone();
                const data = await clone.json();
                
                if (response.status === 200 && data.operations && data.operations.length > 0) {
                    const op = data.operations[0];
                    window.__veo3_monitor.operationName = op.operation?.name;
                    window.__veo3_monitor.credits = data.remainingCredits;
                    
                    if (op.status === 'MEDIA_GENERATION_STATUS_PENDING') {
                        window.__veo3_monitor.status = 'pending';
                    } else {
                        window.__veo3_monitor.status = 'started';
                    }
                    
                    window.__veo3_monitor.lastUpdate = Date.now();
                    console.log('[Monitor] Started:', window.__veo3_monitor.operationName);
                } else if (response.status === 403) {
                    window.__veo3_monitor.status = 'auth_error';
                    window.__veo3_monitor.apiError = '403 Forbidden';
                }
            } catch (e) {
                console.error('[Monitor] Parse error:', e);
            }
        }
        
        if (url.includes('batchCheckAsyncVideoGenerationStatus')) {
            try {
                const clone = response.clone();
                const data = await clone.json();
                
                if (data.operations && data.operations.length > 0) {
                    const op = data.operations[0];
                    const opName = op.operation?.name;
                    const status = op.status;
                    
                    if (window.__veo3_monitor.operationName && opName !== window.__veo3_monitor.operationName) {
                        return response;
                    }
                    
                    window.__veo3_monitor.lastUpdate = Date.now();
                    
                    if (status === 'MEDIA_GENERATION_STATUS_PENDING') {
                        window.__veo3_monitor.status = 'pending';
                    } else if (status === 'MEDIA_GENERATION_STATUS_ACTIVE') {
                        window.__veo3_monitor.status = 'active';
                    } else if (status === 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
                        const videoUrl = op.operation?.metadata?.video?.fifeUrl;
                        if (videoUrl) {
                            window.__veo3_monitor.videoUrl = videoUrl;
                            window.__veo3_monitor.status = 'complete';
                        }
                    } else if (status.includes('FAIL') || status.includes('ERROR')) {
                        window.__veo3_monitor.status = 'failed';
                        window.__veo3_monitor.error = status;
                    }
                }
            } catch (e) {
                console.error('[Monitor] Status error:', e);
            }
        }
        
        return response;
    };
    
    console.log('[Monitor] Installed');
    return {success: true};
})();
''';

    final result = await _executeJs(jsCode);
    if (result is Map && result['alreadyInstalled'] == true) {
      print('[MOBILE REACT] Network monitor already installed');
    } else {
      print('[MOBILE REACT] Network monitor installed');
    }
  }

  Future<void> _ensureProjectOpenMobile() async {
    final jsCode = '''
(async () => {
    const buttons = [...document.querySelectorAll('button')];
    const newProjBtn = buttons.find(b => b.textContent.includes('New project'));
    
    if (newProjBtn) {
        newProjBtn.click();
        await new Promise(r => setTimeout(r, 3000));
        return {wasHomepage: true};
    }
    return {wasHomepage: false, hasProject: true};
})();
''';

    final result = await _executeAsyncJs(jsCode, timeoutSeconds: 10);
    if (result is Map && result['wasHomepage'] == true) {
      print('[MOBILE REACT] Created new project');
      await Future.delayed(const Duration(seconds: 2));
    } else {
      print('[MOBILE REACT] Already in a project');
    }
  }

  Future<void> _resetMonitorMobile() async {
    final jsCode = '''
(() => {
    if (window.__veo3_monitor) {
        window.__veo3_monitor.operationName = null;
        window.__veo3_monitor.videoUrl = null;
        window.__veo3_monitor.status = 'idle';
        window.__veo3_monitor.error = null;
        window.__veo3_monitor.apiError = null;
        window.__veo3_monitor.startTime = Date.now();
    }
    return {success: true};
})();
''';

    await _executeJs(jsCode);
  }

  Future<Map<String, dynamic>> _triggerGenerationReactMobile(String prompt) async {
    final jsCode = '''
(async () => {
    const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
    if (!textarea) {
        return {success: false, error: 'Textarea not found'};
    }
    
    const textareaPropsKey = Object.keys(textarea).find(key => key.startsWith('__reactProps\$'));
    if (!textareaPropsKey) {
        return {success: false, error: 'React props not found on textarea'};
    }
    
    const textareaProps = textarea[textareaPropsKey];
    
    textarea.value = ${jsonEncode(prompt)};
    
    if (textareaProps.onChange) {
        textareaProps.onChange({
            target: textarea,
            currentTarget: textarea,
            nativeEvent: new Event('change')
        });
    }
    
    textarea.dispatchEvent(new Event('input', {bubbles: true}));
    textarea.dispatchEvent(new Event('change', {bubbles: true}));
    
    await new Promise(r => setTimeout(r, 1000));
    
    const buttons = Array.from(document.querySelectorAll('button'));
    const createButton = buttons.find(b => b.innerText.includes('Create') || b.innerHTML.includes('arrow_forward'));
    
    if (!createButton) {
        return {success: false, error: 'Create button not found'};
    }
    
    if (createButton.disabled) {
        return {success: false, error: 'Button still disabled - prompt may not have been set'};
    }
    
    const reactPropsKey = Object.keys(createButton).find(key => key.startsWith('__reactProps\$'));
    if (!reactPropsKey) {
        return {success: false, error: 'React props key not found on button'};
    }
    
    const props = createButton[reactPropsKey];
    if (!props || !props.onClick) {
        return {success: false, error: 'onClick handler not found'};
    }
    
    try {
        props.onClick({
            preventDefault: () => {},
            stopPropagation: () => {},
            nativeEvent: new MouseEvent('click', {bubbles: true, cancelable: true})
        });
        return {success: true, method: 'react_handler', promptSet: true};
    } catch (e) {
        return {success: false, error: e.message};
    }
})();
''';

    final result = await _executeAsyncJs(jsCode, timeoutSeconds: 15);
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return {'success': false, 'error': 'Invalid response'};
  }

  Future<Map<String, dynamic>?> _pollForCompletionMobile({
    Function(int progress, String status)? onProgress,
    int maxWaitSeconds = 360,
  }) async {
    final startTime = DateTime.now();
    String? lastStatus;
    
    while (DateTime.now().difference(startTime).inSeconds < maxWaitSeconds) {
      await Future.delayed(const Duration(seconds: 1));
      
      final statusResult = await _executeJs('window.__veo3_monitor || {status: "not_initialized"}');
      
      if (statusResult is! Map) continue;
      
      final status = statusResult['status'] as String?;
      final operationName = statusResult['operationName'] as String?;
      final credits = statusResult['credits'];
      final videoUrl = statusResult['videoUrl'] as String?;
      final error = statusResult['error'] as String?;
      final apiError = statusResult['apiError'] as String?;
      
      if (status != lastStatus) {
        if (status == 'pending') {
          print('[MOBILE REACT] Operation: ${operationName?.substring(0, 25)}...');
          print('[MOBILE REACT] Credits: $credits');
          print('[MOBILE REACT] Status: PENDING - Generation queued');
          onProgress?.call(5, 'Polling');
        } else if (status == 'active') {
          print('[MOBILE REACT] Status: ACTIVE - Polling...');
          onProgress?.call(50, 'Polling');
        } else if (status == 'complete') {
          print('[MOBILE REACT] Status: SUCCESSFUL!');
          print('[MOBILE REACT] Video URL: ${videoUrl?.substring(0, 60)}...');
          onProgress?.call(100, 'Complete');
          
          return {
            'status': 'complete',
            'videoUrl': videoUrl,
            'operationName': operationName,
          };
        } else if (status == 'failed') {
          print('[MOBILE REACT] Status: FAILED - $error');
          onProgress?.call(0, 'Failed');
          return {'error': error ?? 'Generation failed'};
        } else if (status == 'auth_error') {
          print('[MOBILE REACT] AUTH ERROR: $apiError');
          onProgress?.call(0, 'Auth Error');
          return {'error': apiError ?? '403 Forbidden'};
        }
        
        lastStatus = status;
      }
    }
    
    print('[MOBILE REACT] Timeout!');
    return {'error': 'Timeout waiting for video'};
  }

  /// Upscale a video to 1080p or 4K - Updated to VEO 3.1 API format
  /// resolution can be 'VIDEO_RESOLUTION_1080P' or 'VIDEO_RESOLUTION_4K'
  Future<Map<String, dynamic>?> upscaleVideo({
    required String videoMediaId,
    required String accessToken,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String resolution = 'VIDEO_RESOLUTION_1080P',
  }) async {
    final sceneId = _generateUuid();
    final seed = (DateTime.now().millisecondsSinceEpoch % 50000);

    // Sanitize mediaId
    final cleanMediaId = videoMediaId.trim().replaceAll(RegExp(r'[\r\n\t]'), '');

    // Select model key based on resolution
    String modelKey;
    if (resolution == 'VIDEO_RESOLUTION_4K') {
      modelKey = 'veo_3_1_upsampler_4k';
    } else {
      modelKey = 'veo_3_1_upsampler_1080p';
    }

    // New request structure for VEO 3.1 upsampler
    final requestObj = {
      'aspectRatio': aspectRatio,
      'resolution': resolution,
      'seed': seed,
      'videoInput': {'mediaId': cleanMediaId},
      'videoModelKey': modelKey,
      'metadata': {'sceneId': sceneId},
    };

    final requestJson = jsonEncode(requestObj);
    const endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoUpsampleVideo';

    print('[MOBILE UPSCALE] Starting upscale for mediaId: $cleanMediaId');
    print('[MOBILE UPSCALE] Model: $modelKey');
    print('[MOBILE UPSCALE] AspectRatio: $aspectRatio, Resolution: $resolution');
    mobileLog('[UPSCALE] MediaId: ${cleanMediaId.length > 20 ? cleanMediaId.substring(0, 20) + "..." : cleanMediaId}');
    mobileLog('[UPSCALE] Payload: $requestJson');

    // Get recaptcha token from pool
    final recaptchaToken = await getRecaptchaToken();
    if (recaptchaToken == null) {
      mobileLog('[UPSCALE] ✗ Failed to get reCAPTCHA token');
      return {'success': false, 'error': 'Failed to get reCAPTCHA token from pool'};
    }

    // Use evaluateJavascript with direct fetch - works in release builds
    final jsCode = '''
      (async function() {
        try {
          // Small random delay
          await new Promise(r => setTimeout(r, Math.floor(Math.random() * 500) + 100));
          
          // Updated payload structure with recaptchaContext
          const payload = {
            requests: [$requestJson],
            clientContext: {
              recaptchaContext: {
                token: '$recaptchaToken',
                applicationType: 'RECAPTCHA_APPLICATION_TYPE_WEB'
              },
              sessionId: ';' + Date.now()
            }
          };

          const response = await fetch(
            '$endpoint',
            {
              method: 'POST',
              headers: { 
                'Content-Type': 'text/plain;charset=UTF-8',
                'authorization': 'Bearer $accessToken',
                'x-browser-channel': 'stable',
                'x-browser-year': '2026',
                'x-browser-validation': 'iB7C9P2Z85vwN6w2umx6Y90enzY=',
                'x-browser-copyright': 'Copyright 2026 Google LLC. All Rights reserved.'
              },
              body: JSON.stringify(payload),
              credentials: 'include'
            }
          );
          
          const text = await response.text();
          let data = null;
          try { data = JSON.parse(text); } catch (e) { data = text; }
          
          // Store result in window for retrieval
          window.__upscaleResult = JSON.stringify({
            success: response.ok,
            status: response.status,
            statusText: response.statusText,
            data: data,
            sceneId: '$sceneId'
          });
          return 'DONE';
        } catch (error) {
          window.__upscaleResult = JSON.stringify({
            success: false,
            error: error.message
          });
          return 'ERROR';
        }
      })()
    ''';

    print('[MOBILE UPSCALE] Executing JS...');
    mobileLog('[UPSCALE] Calling API...');

    try {
      // Execute the async code
      await controller.evaluateJavascript(source: jsCode);
      
      // Wait a bit for the async operation to complete
      await Future.delayed(const Duration(seconds: 3));
      
      // Retrieve the result
      String? resultStr;
      for (int i = 0; i < 30; i++) { // Try for up to 30 seconds
        final check = await controller.evaluateJavascript(source: 'window.__upscaleResult || null');
        if (check != null && check != 'null' && check.toString().isNotEmpty) {
          resultStr = check.toString();
          break;
        }
        await Future.delayed(const Duration(seconds: 1));
      }

      // Clear the result from window
      await controller.evaluateJavascript(source: 'window.__upscaleResult = null');

      print('[MOBILE UPSCALE] Got result: ${resultStr != null && resultStr != 'null'}');
      
      if (resultStr != null && resultStr != 'null') {
        Map<String, dynamic>? result;
        
        // Remove surrounding quotes if present (evaluateJavascript may add them)
        var cleanResult = resultStr;
        if (cleanResult.startsWith('"') && cleanResult.endsWith('"')) {
          cleanResult = cleanResult.substring(1, cleanResult.length - 1);
          // Unescape the JSON
          cleanResult = cleanResult.replaceAll('\\"', '"').replaceAll('\\\\', '\\');
        }
        
        try { 
          result = jsonDecode(cleanResult) as Map<String, dynamic>; 
        } catch (e) {
          print('[MOBILE UPSCALE] Failed to parse result as JSON: $e');
          print('[MOBILE UPSCALE] Raw result: $cleanResult');
        }
        
        if (result != null) {
          final status = result['status'];
          final success = result['success'];
          
          print('[MOBILE UPSCALE] Status: $status, Success: $success');
          
          if (status == 409) {
            // 409 = Entity already exists = upscale already in progress
            mobileLog('[UPSCALE] ⚠ 409: Already upscaling');
            print('[MOBILE UPSCALE] 409 - Entity already exists (already upscaling)');
            result['success'] = true;
            result['alreadyExists'] = true;
          } else if (success == true) {
            mobileLog('[UPSCALE] ✓ Started ($status)');
            print('[MOBILE UPSCALE] ✓ Upscale started');
          } else {
            mobileLog('[UPSCALE] ✗ Failed ($status)');
            print('[MOBILE UPSCALE] ✗ Error: ${result['error'] ?? result['data']}');
          }
          
          // Log the data
          if (result['data'] != null) {
            final dataStr = jsonEncode(result['data']);
            print('[MOBILE UPSCALE] Data: ${dataStr.length > 500 ? dataStr.substring(0, 500) + "..." : dataStr}');
          }
          
          return result;
        }
      } else {
        mobileLog('[UPSCALE] ✗ NULL result');
        print('[MOBILE UPSCALE] Result is NULL');
      }
    } catch (e) {
      print('[MOBILE UPSCALE] Exception: $e');
      mobileLog('[UPSCALE] ✗ Exception: $e');
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
    mobileLog('[POLL] Checking ${requests.length} videos...');
    LogService().mobile('=== POLL REQUEST ===');
    LogService().mobile('URL: https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus');
    LogService().mobile('Payload: $payloadJson');
    
    final result = await _executeAsyncJs(jsBody);
    
    // Log the full response
    LogService().mobile('=== POLL RESPONSE ===');
    if (result != null) {
      final resultStr = result is String ? result : jsonEncode(result);
      LogService().mobile('Response: $resultStr');
      mobileLog('[POLL] ✓ Got response');
    } else {
      mobileLog('[POLL] ✗ NULL response');
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

  // ========== HTTP-BASED METHODS (Python Strategy) ==========
  // These use pure HTTP instead of browser JS, so they continue working after relogin

  /// HTTP-based batch poll (no browser needed)
  Future<List<Map<String, dynamic>>?> pollVideoStatusBatchHTTP(
    List<PollRequest> requests,
    String accessToken,
  ) async {
    if (requests.isEmpty) return [];

    try {
      final payload = {
        'operations': requests
            .map((r) => {
                  'operation': {'name': r.operationName},
                  'sceneId': r.sceneId,
                  'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
                })
            .toList()
      };

      final response = await http.post(
        Uri.parse('https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data.containsKey('operations')) {
          final ops = (data['operations'] as List).cast<Map<String, dynamic>>();
          
          // Enrich with sceneId 
          final enrichedOps = <Map<String, dynamic>>[];
          for (int i = 0; i < ops.length; i++) {
            final op = Map<String, dynamic>.from(ops[i]);
            if (i < requests.length) {
              op['sceneId'] = requests[i].sceneId;
            }
            enrichedOps.add(op);
          }
          return enrichedOps;
        }
      } else {
        LogService().error('[HTTP POLL] Error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      LogService().error('[HTTP POLL] Exception: $e');
    }
    return null;
  }

  /// HTTP-based single poll (no browser needed)
  Future<Map<String, dynamic>?> pollVideoStatusHTTP(
    String operationName,
    String sceneId,
    String accessToken,
  ) async {
    try {
      final payload = {
        'operations': [
          {
            'operation': {'name': operationName},
            'sceneId': sceneId,
            'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
          }
        ]
      };

      final response = await http.post(
        Uri.parse('https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data.containsKey('operations') && (data['operations'] as List).isNotEmpty) {
          return (data['operations'] as List)[0] as Map<String, dynamic>;
        }
      } else {
        LogService().error('[HTTP POLL] Error ${response.statusCode}');
      }
    } catch (e) {
      LogService().error('[HTTP POLL] Exception: $e');
    }
    return null;
  }

  /// HTTP-based download (no browser needed)
  Future<int> downloadVideoHTTP(String videoUrl, String savePath) async {
    try {
      print('[HTTP DOWNLOAD] Downloading: $videoUrl');
      print('[HTTP DOWNLOAD] Save to: $savePath');

      final response = await http.get(Uri.parse(videoUrl));

      if (response.statusCode == 200) {
        final file = File(savePath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);

        final bytes = response.bodyBytes.length;
        print('[HTTP DOWNLOAD] ✓ Downloaded $bytes bytes');
        return bytes;
      } else {
        print('[HTTP DOWNLOAD] ✗ Error ${response.statusCode}');
        return 0;
      }
    } catch (e) {
      print('[HTTP DOWNLOAD] ✗ Exception: $e');
      return 0;
    }
  }
}

class MobileBrowserService {
  static final MobileBrowserService _instance = MobileBrowserService._internal();
  factory MobileBrowserService() => _instance;
  MobileBrowserService._internal();

  final List<MobileProfile> profiles = [];
  
  final _refreshController = StreamController<int>.broadcast();
  Stream<int> get refreshStream => _refreshController.stream;

  void initialize(int count) {
    // Adjust profile count to match the requested count
    while (profiles.length < count) {
      int nextIdx = profiles.length;
      profiles.add(MobileProfile(id: 'mob_$nextIdx', name: 'Browser ${nextIdx + 1}'));
      mobileLog('[SERVICE] Created Browser ${nextIdx + 1}');
    }
    while (profiles.length > count && profiles.length > 1) {
      final removed = profiles.removeLast();
      mobileLog('[SERVICE] Removed ${removed.name}');
    }
  }

  void addNewProfile() {
    int nextIdx = profiles.length;
    profiles.add(MobileProfile(id: 'mob_$nextIdx', name: 'Browser ${nextIdx + 1}'));
    mobileLog('[SERVICE] Added new browser profile: Browser ${nextIdx + 1}');
  }

  void removeLastProfile() {
    if (profiles.length > 1) {
      final removed = profiles.removeLast();
      mobileLog('[SERVICE] Removed browser profile: ${removed.name}');
    }
  }

  void removeProfileAt(int index) {
    if (profiles.length > 1 && index >= 0 && index < profiles.length) {
      final removed = profiles.removeAt(index);
      mobileLog('[SERVICE] Removed specific browser profile: ${removed.name}');
    }
  }

  void cycleProfileWebView(int index) {
    if (index >= 0 && index < profiles.length) {
      mobileLog('[BROWSER] Cycling WebView for profile ${index + 1}...');
      _refreshController.add(index);
    }
  }

  MobileProfile? getProfile(int index) {
    if (index >= 0 && index < profiles.length) return profiles[index];
    return null;
  }

  int countConnected() => profiles.where((p) => p.status == MobileProfileStatus.ready).length;
  
  /// Stop all login processes
  void stopLogin() {
    for (final profile in profiles) {
      profile.generator?.stopLogin();
    }
  }
  
  /// Count profiles that are ready AND haven't hit 403 threshold AND not relogging AND have generator
  int countHealthy() => profiles.where((p) => 
    p.status == MobileProfileStatus.ready && 
    p.generator != null &&
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
    return profiles.where((p) => p.consecutive403Count >= 7 && !p.isReloginInProgress).toList();
  }
  


  /// Reset 403 count for a profile (after successful re-login)
  void resetProfile403Count(int index) {
    if (index >= 0 && index < profiles.length) {
      final p = profiles[index];
      p.consecutive403Count = 0;
      p.reloginAttempts = 0;
    }
  }
  
  /// Auto re-login for a profile that has hit 403 threshold
  /// STRATEGY:
  /// 1. Cycle the browser (create new instance, close old)
  /// 2. Load Flow page
  /// 3. Verify session (cookies are shared)
  /// 4. Only if session is lost, perform full autoLogin

  Future<bool> autoReloginProfile(
    MobileProfile profile, {
    Function()? onSuccess,
    String? email,
    String? password,
  }) async {
    if (profile.isReloginInProgress) {
      print('[RELOGIN] ${profile.name} - Already in progress');
      return false;
    }
    
    profile.isReloginInProgress = true;
    profile.status = MobileProfileStatus.loading;
    final int profileIndex = profiles.indexOf(profile);
    
    mobileLog('[RELOGIN] ${profile.name} - Total Reset started (403 Recovery)');
    print('[RELOGIN] ${profile.name} - Total Reset started (403 Recovery)');
    
    try {
      // Step 1: Clear Everything ONLY for the primary browser (index 0)
      // Mobile browsers share a global cookie pool, so logging into one logs into all.
      if (profileIndex == 0) {
        mobileLog('[RELOGIN] Primary Profile - Performing Total Reset');
        final cookieManager = CookieManager.instance();
        await cookieManager.deleteAllCookies(); 
      } else {
        mobileLog('[RELOGIN] Slave Profile - Cycling only...');
      }
      
      // Step 2: Cycle the WebView to get a fresh instance
      cycleProfileWebView(profileIndex);
      
      // Wait for recreation
      for (int i = 0; i < 15; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (profile.controller != null && profile.generator != null) {
          mobileLog('[RELOGIN] ✓ New WebView instance attached');
          break;
        }
        if (i == 14) {
          mobileLog('[RELOGIN] ✗ Timeout waiting for new WebView instance');
          profile.isReloginInProgress = false;
          return false;
        }
      }
      final generator = profile.generator!;
      await generator.controller.clearCache();
      
      // Step 4: Full Auto Login / Refresh
      mobileLog('[RELOGIN] Starting session recovery...');
      if (email != null && password != null) {
        // Since cookies are shared, we just need to perform the login once on the primary,
        // and others will inherit it upon navigation to Flow.
        final success = await generator.autoLogin(email, password);
        if (success) {
          mobileLog('[RELOGIN] ✓ Recovery successful');
          final token = await generator.getAccessTokenQuick();
          if (token != null && token.isNotEmpty) {
            profile.accessToken = token;
            profile.status = MobileProfileStatus.ready;
            profile.consecutive403Count = 0;
            profile.reloginAttempts = 0;
            if (onSuccess != null) onSuccess();
            profile.isReloginInProgress = false;
            return true;
          }
        }
      } else {
        mobileLog('[RELOGIN] ✗ Credentials missing');
      }

      mobileLog('[RELOGIN] ✗ Recovery failed');
      profile.status = MobileProfileStatus.error;
      profile.isReloginInProgress = false;
      return false;
    } catch (e) {
      mobileLog('[RELOGIN] ✗ Exception: $e');
      profile.isReloginInProgress = false;
      return false;
    }
  }
  
  /// Trigger relogin for profiles that have hit 403 threshold
  Future<void> reloginAllNeeded({
    Function()? onAnySuccess,
    String? email,
    String? password,
  }) async {
    final needsRelogin = getProfilesNeedingRelogin();
    if (needsRelogin.isEmpty) {
      print('[RELOGIN] No profiles need relogin');
      return;
    }
    
    print('[RELOGIN] Found ${needsRelogin.length} profiles needing relogin');
    
    // Relogin each profile that needs it (individually, not all at once)
    for (final profile in needsRelogin) {
      print('[RELOGIN] Starting relogin for ${profile.name}...');
      await autoReloginProfile(
        profile,
        email: email,
        password: password,
        onSuccess: () {
          print('[RELOGIN] ${profile.name} recovered!');
          onAnySuccess?.call();
        },
      );
    }
  }
  
  /// Re-login ALL browsers when any one hits 403 threshold
  /// STRATEGY:
  /// 1. Login to first browser (full autoLogin)
  /// 2. Load Flow URL on all other browsers (session shared via cookies)
  /// 3. Fetch token for all browsers
  Future<bool> reloginAllBrowsers({
    required String? email,
    required String? password,
    Function()? onSuccess,
  }) async {
    if (email == null || password == null) {
      mobileLog('[RELOGIN-ALL] ✗ Credentials missing');
      return false;
    }
    
    if (profiles.isEmpty) return false;
    
    mobileLog('[RELOGIN-ALL] ========== Starting Session Recovery ==========');
    print('[RELOGIN-ALL] Starting session recovery for all ${profiles.length} browsers');
    
    // Mark all as loading
    for (final p in profiles) {
      p.isReloginInProgress = true;
      p.status = MobileProfileStatus.loading;
    }
    
    try {
      // Step 1: Clear all cookies (shared cookie pool on mobile)
      mobileLog('[RELOGIN-ALL] Clearing global cookies...');
      await CookieManager.instance().deleteAllCookies();
      
      // Step 2: Login to FIRST browser only
      final firstProfile = profiles.first;
      if (firstProfile.generator == null || firstProfile.controller == null) {
        mobileLog('[RELOGIN-ALL] ✗ First browser not initialized');
        _finishReloginAll(false);
        return false;
      }
      
      mobileLog('[RELOGIN-ALL] Logging into first browser...');
      final success = await firstProfile.generator!.autoLogin(email, password);
      
      if (!success) {
        mobileLog('[RELOGIN-ALL] ✗ First browser login failed');
        _finishReloginAll(false);
        return false;
      }
      
      // Verify token on first browser
      final firstToken = await firstProfile.generator!.getAccessTokenQuick();
      if (firstToken != null && firstToken.isNotEmpty) {
        firstProfile.accessToken = firstToken;
        firstProfile.status = MobileProfileStatus.ready;
        firstProfile.consecutive403Count = 0;
        firstProfile.reloginAttempts = 0;
        mobileLog('[RELOGIN-ALL] ✓ First browser ready');
      }
      
      // Step 3: Wait for session to settle
      mobileLog('[RELOGIN-ALL] Waiting 5s for session to settle...');
      await Future.delayed(const Duration(seconds: 5));
      
      // Step 4: Load Flow URL on all OTHER browsers
      for (int i = 1; i < profiles.length; i++) {
        final profile = profiles[i];
        if (profile.controller == null) {
          mobileLog('[RELOGIN-ALL] Browser ${i + 1}: Not initialized, skipping');
          continue;
        }
        
        mobileLog('[RELOGIN-ALL] Browser ${i + 1}: Loading Flow URL...');
        await profile.controller!.loadUrl(
          urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow'))
        );
        
        // Wait for page to load
        await Future.delayed(const Duration(seconds: 5));
        
        // Check token
        final token = await profile.generator?.getAccessTokenQuick();
        if (token != null && token.isNotEmpty) {
          profile.accessToken = token;
          profile.status = MobileProfileStatus.ready;
          profile.consecutive403Count = 0;
          profile.reloginAttempts = 0;
          mobileLog('[RELOGIN-ALL] ✓ Browser ${i + 1} ready (shared session)');
        } else {
          profile.status = MobileProfileStatus.connected;
          profile.consecutive403Count = 0;
          mobileLog('[RELOGIN-ALL] ~ Browser ${i + 1} loaded (token pending)');
        }
      }
      
      mobileLog('[RELOGIN-ALL] ========== Session Recovery Complete ==========');
      _finishReloginAll(true);
      if (onSuccess != null) onSuccess();
      return true;
      
    } catch (e) {
      mobileLog('[RELOGIN-ALL] ✗ Error: $e');
      _finishReloginAll(false);
      return false;
    }
  }
  
  void _finishReloginAll(bool success) {
    for (final p in profiles) {
      p.isReloginInProgress = false;
      if (!success && p.status == MobileProfileStatus.loading) {
        p.status = MobileProfileStatus.error;
      }
    }
  }
}
