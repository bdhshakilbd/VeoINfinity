import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Browser Video Generator using Chrome DevTools Protocol
class BrowserVideoGenerator {
  final int debugPort;
  WebSocketChannel? ws;
  Stream<dynamic>? _broadcastStream;
  int msgId = 0;

  BrowserVideoGenerator({this.debugPort = 9222});

  /// Connect to Chrome DevTools
  Future<void> connect() async {
    final response = await http.get(Uri.parse('http://localhost:$debugPort/json'));
    final tabs = jsonDecode(response.body) as List;

    Map<String, dynamic>? targetTab;
    for (var tab in tabs) {
      if ((tab['url'] as String).contains('labs.google')) {
        targetTab = tab as Map<String, dynamic>;
        break;
      }
    }

    if (targetTab == null) {
      throw Exception('No labs.google tab found! Please open https://labs.google in Chrome');
    }

    final wsUrl = targetTab['webSocketDebuggerUrl'] as String;
    ws = WebSocketChannel.connect(Uri.parse(wsUrl));
    
    // Create a broadcast stream so multiple listeners can subscribe
    _broadcastStream = ws!.stream.asBroadcastStream();
  }

  /// Send a CDP command and get response
  Future<Map<String, dynamic>> sendCommand(String method, [Map<String, dynamic>? params]) async {
    if (ws == null) throw Exception('Not connected');
    if (_broadcastStream == null) throw Exception('Stream not initialized');

    msgId++;
    final currentMsgId = msgId;
    final msg = {
      'id': currentMsgId,
      'method': method,
      'params': params ?? {},
    };

    ws!.sink.add(jsonEncode(msg));

    // Use a completer to wait for the specific response
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
    
    // Add timeout to prevent hanging
    return completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        subscription.cancel();
        throw Exception('Command timeout');
      },
    );
  }

  /// Execute JavaScript in the page context
  Future<dynamic> executeJs(String expression) async {
    final result = await sendCommand('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });

    return result['result']?['result']?['value'];
  }

  /// Refresh the browser page (useful to recover from 403/reCAPTCHA errors)
  Future<void> refreshPage() async {
    print('[BROWSER] Refreshing page...');
    await sendCommand('Page.reload', {'ignoreCache': true});
    // Wait for page to load
    await Future.delayed(const Duration(seconds: 5));
    print('[BROWSER] Page refreshed');
  }

  /// Check if connected to browser
  bool get isConnected => ws != null;

  /// Close the WebSocket connection
  void close() {
    try {
      ws?.sink.close();
    } catch (e) {
      // Ignore close errors
    }
    ws = null;
    _broadcastStream = null;
  }

  /// Human-like delay with randomization to avoid detection
  Future<void> _humanDelay({int minMs = 500, int maxMs = 1500}) async {
    final random = Random();
    final delay = minMs + random.nextInt(maxMs - minMs);
    await Future.delayed(Duration(milliseconds: delay));
  }

  // ========== CDP Helper Methods for UI Automation ==========
  
  /// Get the document root node ID
  Future<int> _getDocumentRoot() async {
    final result = await sendCommand('DOM.getDocument');
    return result['result']['root']['nodeId'] as int;
  }

  /// Query selector using CDP (more reliable than JavaScript)
  Future<int?> _querySelectorCDP(String selector, {int? nodeId}) async {
    try {
      nodeId ??= await _getDocumentRoot();
      final result = await sendCommand('DOM.querySelector', {
        'nodeId': nodeId,
        'selector': selector,
      });
      final foundNodeId = result['result']['nodeId'] as int?;
      return (foundNodeId != null && foundNodeId > 0) ? foundNodeId : null;
    } catch (e) {
      print('[CDP] querySelector failed for "$selector": $e');
      return null;
    }
  }

  /// Get element bounding box
  Future<Map<String, double>?> _getElementBox(int nodeId) async {
    try {
      final result = await sendCommand('DOM.getBoxModel', {'nodeId': nodeId});
      final content = result['result']['model']['content'] as List;
      
      // content is [x1, y1, x2, y2, x3, y3, x4, y4]
      final x = (content[0] as num).toDouble();
      final y = (content[1] as num).toDouble();
      final width = ((content[4] as num) - (content[0] as num)).toDouble();
      final height = ((content[5] as num) - (content[1] as num)).toDouble();
      
      return {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'centerX': x + width / 2,
        'centerY': y + height / 2,
      };
    } catch (e) {
      print('[CDP] getBoxModel failed for node $nodeId: $e');
      return null;
    }
  }

  /// Click element at its center using CDP mouse events
  Future<void> _clickElementCDP(int nodeId, {String? debugName}) async {
    final box = await _getElementBox(nodeId);
    if (box == null) {
      throw Exception('Could not get bounding box for ${debugName ?? "element"}');
    }

    final x = box['centerX']!;
    final y = box['centerY']!;

    print('[CDP] Clicking ${debugName ?? "element"} at ($x, $y)');

    // Move mouse to element first (human-like behavior)
    await sendCommand('Input.dispatchMouseEvent', {
      'type': 'mouseMoved',
      'x': x,
      'y': y,
    });
    
    // Small random delay before clicking
    await _humanDelay(minMs: 100, maxMs: 300);

    // Dispatch mouse events: mousePressed -> mouseReleased
    await sendCommand('Input.dispatchMouseEvent', {
      'type': 'mousePressed',
      'x': x,
      'y': y,
      'button': 'left',
      'clickCount': 1,
    });

    await Future.delayed(Duration(milliseconds: 50));

    await sendCommand('Input.dispatchMouseEvent', {
      'type': 'mouseReleased',
      'x': x,
      'y': y,
      'button': 'left',
      'clickCount': 1,
    });
  }


  /// Fetch access token from browser session
  Future<String?> getAccessToken() async {
    const jsCode = '''
    (async function() {
      try {
        const response = await fetch('https://labs.google/fx/api/auth/session', {
          credentials: 'include'
        });
        const data = await response.json();
        return JSON.stringify({
          success: response.ok,
          token: data.access_token
        });
      } catch (error) {
        return JSON.stringify({
          success: false,
          error: error.message
        });
      }
    })()
    ''';

    final result = await executeJs(jsCode);
    if (result != null) {
      final parsed = jsonDecode(result as String) as Map<String, dynamic>;
      if (parsed['success'] == true) {
        return parsed['token'] as String?;
      }
    }
    return null;
  }

  /// Simulate human activity to avoid bot detection
  Future<void> simulateHumanActivity() async {
    try {
      const jsCode = '''
      (function() {
        // Simulate random mouse movement
        const x = Math.floor(Math.random() * window.innerWidth);
        const y = Math.floor(Math.random() * window.innerHeight);
        const event = new MouseEvent('mousemove', {
          clientX: x, clientY: y,
          bubbles: true, cancelable: true
        });
        document.dispatchEvent(event);
        
        // Simulate random scroll
        window.scrollBy(0, Math.floor(Math.random() * 100) - 50);
        
        return 'OK';
      })()
      ''';
      await executeJs(jsCode);
    } catch (e) {
      // Ignore errors
    }
  }

  /// Upload an image and get mediaId for image-to-video generation
  Future<dynamic> uploadImage(
    String imagePath,
    String accessToken, {
    String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE',
  }) async {
    try {
      // Read and encode image
      final imageBytes = await File(imagePath).readAsBytes();
      final imageB64 = base64Encode(imageBytes);

      // Determine MIME type
      String mimeType = 'image/jpeg';
      if (imagePath.toLowerCase().endsWith('.png')) {
        mimeType = 'image/png';
      } else if (imagePath.toLowerCase().endsWith('.webp')) {
        mimeType = 'image/webp';
      }

      print('[UPLOAD] Uploading image: ${imagePath.split(Platform.pathSeparator).last} (${imageBytes.length} bytes)');

      // Split base64 into chunks to avoid JavaScript string length issues
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
          // Reconstruct base64 from chunks
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
          
          return JSON.stringify({
            success: response.ok,
            status: response.status,
            statusText: response.statusText,
            data: data
          });
        } catch (error) {
          return JSON.stringify({
            success: false,
            error: error.message,
            stack: error.stack
          });
        }
      })()
      ''';

      final resultStr = await executeJs(jsCode);
      if (resultStr != null) {
        final result = jsonDecode(resultStr as String) as Map<String, dynamic>;

        print('[UPLOAD] Status: ${result['status']}');

        if (result['success'] == true) {
          final data = result['data'] as Map<String, dynamic>;

          // Extract mediaId from nested structure
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
            print('[UPLOAD] ✓ Success! MediaId: $mediaId');
            return mediaId;
          } else {
            print('[UPLOAD] ✗ No mediaId in response:');
            print('[UPLOAD] Response data: ${jsonEncode(data)}');
          }
        } else {
          // Check for specific error reasons
          final errorData = result['data'] as Map<String, dynamic>? ?? {};
          final errorInfo = errorData['error'] as Map<String, dynamic>? ?? {};
          final errorMessage = errorInfo['message'] as String? ?? 'Unknown error';
          final errorDetails = errorInfo['details'] as List? ?? [];

          // Check for content policy violations
          String? userFriendlyMsg;
          for (var detail in errorDetails) {
            final reason = (detail as Map)['reason'] as String? ?? '';
            if (reason.contains('MINOR') || reason.contains('PUBLIC')) {
              userFriendlyMsg = "⚠️ IMAGE REJECTED: Google's content policy detected a minor, "
                  "public figure, or copyrighted content in your image. "
                  "Please use a different image without people or recognizable figures.";
              break;
            }
          }

          print('[UPLOAD] ✗ Failed!');
          if (userFriendlyMsg != null) {
            print('[UPLOAD] $userFriendlyMsg');
          } else {
            print('[UPLOAD] Error: $errorMessage');
          }
          print('[UPLOAD] Response body: ${jsonEncode(errorData)}');

          // Return error info for GUI display
          return {'error': true, 'message': userFriendlyMsg ?? errorMessage, 'details': errorData};
        }
      }

      return null;
    } catch (e) {
      print('[UPLOAD] ✗ Exception: $e');
      return null;
    }
  }

  /// Generate a video with the given prompt and optional start/end images
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

    // Adjust model key for Portrait if needed
    var adjustedModel = model;
    if (aspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' && !model.contains('_portrait')) {
      // Check if relaxed priority is requested
      bool isRelaxed = model.contains('_relaxed');
      
      // Create a base model by removing _relaxed suffix if present
      var baseModel = model.replaceAll('_relaxed', '');
      
      if (baseModel.contains('fast')) {
        // e.g. 'veo_3_1_t2v_fast_ultra' -> 'veo_3_1_t2v_fast_portrait_ultra'
        adjustedModel = baseModel.replaceFirst('fast', 'fast_portrait');
      } else if (baseModel.contains('quality')) {
        // e.g. 'veo_3_1_t2v_quality_ultra' -> 'veo_3_1_t2v_quality_portrait_ultra'
        adjustedModel = baseModel.replaceFirst('quality', 'quality_portrait');
      }
      
      // Re-append relaxed suffix if it was present
      if (isRelaxed) {
        adjustedModel += '_relaxed';
      }
      
      print('[API] Model Adjusted: $model -> $adjustedModel (Portrait Mode)');
    }

    // Determine if this is image-to-video and which mode
    final hasStartImage = startImageMediaId != null;
    final hasEndImage = endImageMediaId != null;
    final isI2v = hasStartImage || hasEndImage;

    if (isI2v) {
      // Use appropriate i2v model variant based on which images are provided
      // For both start+end, we need _fl_ suffix (first-last interpolation)
      // For start only, we use i2v_s variant
      // End-only is NOT supported by the API
      
      if (hasEndImage && !hasStartImage) {
        // End image only is NOT supported - warn and fallback to T2V
        print('[API] WARNING: End-only image mode is NOT supported by the API!');
        print('[API] Please provide a start image OR remove the end image.');
        // Continue with T2V mode, ignore endImage
      } else {
        // Convert T2V model to I2V model
        // Supports: veo_3_1_t2v_*, veo_2_t2v_*, and any other t2v patterns
        if (adjustedModel.contains('t2v')) {
          adjustedModel = adjustedModel.replaceAll('t2v', 'i2v_s');
        } else if (!adjustedModel.contains('i2v')) {
          // If model doesn't have t2v or i2v, try to insert i2v_s
          // Handle veo_2_fast, veo_2_quality patterns
          if (adjustedModel.contains('veo_2_')) {
            adjustedModel = adjustedModel.replaceFirst('veo_2_', 'veo_2_i2v_s_');
          } else if (adjustedModel.contains('veo_3_1_')) {
            adjustedModel = adjustedModel.replaceFirst('veo_3_1_', 'veo_3_1_i2v_s_');
          }
        }
        
        if (hasStartImage && hasEndImage) {
          // Both frames - insert _fl_ after fast/quality for first-last interpolation
          if (adjustedModel.contains('_fast')) {
            // Insert _fl_ right after _fast
            adjustedModel = adjustedModel.replaceFirst('_fast', '_fast_fl');
            // Clean up double underscores if any
            adjustedModel = adjustedModel.replaceAll('__', '_');
            print('[API] Mode: Start+End Frame (First-Last Interpolation)');
          } else if (adjustedModel.contains('_quality')) {
            adjustedModel = adjustedModel.replaceFirst('_quality', '_quality_fl');
            adjustedModel = adjustedModel.replaceAll('__', '_');
            print('[API] Mode: Start+End Frame (First-Last Interpolation)');
          }
        } else {
          print('[API] Mode: Start Image Only');
        }
        
        print('[API] Switched to I2V Model: $adjustedModel');
      }
    }

    // Simulate human activity before each request
    await simulateHumanActivity();

    // Escape prompt for JavaScript
    final promptEscaped = prompt.replaceAll('\\', '\\\\').replaceAll('`', '\\`').replaceAll('\$', '\\\$');

    // Build request object - structure differs for T2V vs I2V
    Map<String, dynamic> requestObj;
    
    if (isI2v) {
      // I2V request structure - startImage or endImage at top level
      requestObj = {
        'aspectRatio': aspectRatio,
        'seed': seed,
        'textInput': {'prompt': prompt},
        'videoModelKey': adjustedModel,
        'metadata': {'sceneId': sceneId},
      };
      
      // Add images
      if (startImageMediaId != null) {
        requestObj['startImage'] = {'mediaId': startImageMediaId};
      }
      if (endImageMediaId != null) {
        requestObj['endImage'] = {'mediaId': endImageMediaId};
      }
    } else {
      // T2V request structure 
      requestObj = {
        'aspectRatio': aspectRatio,
        'seed': seed,
        'textInput': {'prompt': prompt},
        'videoModelKey': adjustedModel,
        'metadata': {'sceneId': sceneId},
      };
    }
    
    // Debug: Print full request payload (without sensitive tokens)
    print('[API PAYLOAD] Mode: ${isI2v ? "I2V" : "T2V"}');
    print('[API PAYLOAD] Model: $adjustedModel');
    print('[API PAYLOAD] Aspect: $aspectRatio');
    print('[API PAYLOAD] Prompt: ${prompt.length > 50 ? "${prompt.substring(0, 50)}..." : prompt}');
    
    if (startImageMediaId != null) {
      print('[API PAYLOAD] startImage.mediaId: $startImageMediaId');
    }
    if (endImageMediaId != null) {
      print('[API PAYLOAD] endImage.mediaId: $endImageMediaId');
    }
    
    // Print full payload for debugging
    print('[API PAYLOAD] Full: ${jsonEncode(requestObj)}');

    final requestJson = jsonEncode(requestObj);

    // Use different endpoint based on mode:
    // - T2V: batchAsyncGenerateVideoText
    // - Start image only: batchAsyncGenerateVideoStartImage
    // - Start + End images: batchAsyncGenerateVideoStartAndEndImage
    String endpoint;
    if (hasStartImage && hasEndImage) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartAndEndImage';
      print('[API] Using Start+End Image endpoint');
    } else if (hasStartImage) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage';
      print('[API] Using Start Image endpoint');
    } else {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';
      print('[API] Using Text-to-Video endpoint');
    }

    final projectId = _generateUuid();

    final jsCode = '''
    (async function() {
      try {
        // Add small random delay before reCAPTCHA (human-like)
        await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1000) + 500));
        
        const token = await grecaptcha.enterprise.execute(
          '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
          { action: 'FLOW_GENERATION' }
        );
        
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
        
        return JSON.stringify({
          success: response.ok,
          status: response.status,
          statusText: response.statusText,
          headers: Object.fromEntries(response.headers),
          data: data,
          sceneId: '$sceneId'
        });
      } catch (error) {
        return JSON.stringify({
          success: false,
          error: error.message
        });
      }
    })()
    ''';

    final resultStr = await executeJs(jsCode);
    if (resultStr != null) {
      final result = jsonDecode(resultStr as String) as Map<String, dynamic>;

      // Detailed Logging
      final mode = isI2v ? 'I2V' : 'T2V';
      print('\n${'=' * 20} API RESPONSE [$mode] ${'=' * 20}');
      print('Status: ${result['status']} ${result['statusText'] ?? ''}');
      if (result['success'] != true) {
        print('Error: ${result['error']}');
        print('Body: ${result['data']}');
      } else {
        // Truncate success body to avoid spam
        final bodyStr = jsonEncode(result['data']);
        if (bodyStr.length > 1000) {
          print('Body: ${bodyStr.substring(0, 1000)}... (truncated)');
        } else {
          print('Body: $bodyStr');
        }
      }
      print('=' * 60 + '\n');

      return result;
    }
    return null;
  }

  /// Upscale a video to 1080p
  Future<Map<String, dynamic>?> upscaleVideo({
    required String videoMediaId,
    required String accessToken,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String resolution = 'VIDEO_RESOLUTION_1080P',
  }) async {
    final sceneId = _generateUuid();
    final seed = (DateTime.now().millisecondsSinceEpoch % 50000);
    final projectId = _generateUuid();

    final requestObj = {
      'aspectRatio': aspectRatio,
      'resolution': resolution,
      'seed': seed,
      'videoInput': {'mediaId': videoMediaId},
      'videoModelKey': 'veo_2_1080p_upsampler_8s',
      'metadata': {'sceneId': sceneId},
    };

    final requestJson = jsonEncode(requestObj);
    const endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoUpsampleVideo';

    print('[UPSCALE] Starting upscale for mediaId: $videoMediaId');
    print('[UPSCALE] Resolution: $resolution');

    final jsCode = '''
    (async function() {
      try {
        await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1000) + 500));
        
        const token = await grecaptcha.enterprise.execute(
          '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
          { action: 'FLOW_GENERATION' }
        );
        
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
        
        return JSON.stringify({
          success: response.ok,
          status: response.status,
          statusText: response.statusText,
          data: data,
          sceneId: '$sceneId'
        });
      } catch (error) {
        return JSON.stringify({
          success: false,
          error: error.message
        });
      }
    })()
    ''';

    final resultStr = await executeJs(jsCode);
    if (resultStr != null) {
      final result = jsonDecode(resultStr as String) as Map<String, dynamic>;
      
      print('[UPSCALE] Response status: ${result['status']}');
      if (result['success'] == true) {
        print('[UPSCALE] ✓ Upscale started');
      } else {
        print('[UPSCALE] ✗ Error: ${result['error'] ?? result['data']}');
      }
      
      return result;
    }
    return null;
  }

  /// Poll once for video generation status
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

    final jsCode = '''
    (async function() {
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
          statusText: response.statusText,
          data: data
        });
      } catch (error) {
        return JSON.stringify({
          success: false,
          error: error.message
        });
      }
    })()
    ''';

    final resultStr = await executeJs(jsCode);
    if (resultStr != null) {
      final result = jsonDecode(resultStr as String) as Map<String, dynamic>;

      // Log only on error or non-200 for poll to reduce spam
      if (result['success'] != true || result['status'] != 200) {
        print('\n[POLL API] Status: ${result['status']} ${result['statusText'] ?? ''}');
        print('Body: ${result['data']}');
      }

      if (result['success'] == true) {
        final responseData = result['data'] as Map<String, dynamic>;
        if (responseData.containsKey('operations') && (responseData['operations'] as List).isNotEmpty) {
          return (responseData['operations'] as List)[0] as Map<String, dynamic>;
        }
      }
    }
    return null;
  }

  /// Poll multiple video generation statuses in a single batch request
  /// 
  /// This is more efficient than calling pollVideoStatus multiple times
  /// as it makes only one API call for all active videos.
  /// 
  /// Returns a list of operation data maps, or null on error.
  Future<List<Map<String, dynamic>>?> pollVideoStatusBatch(
    List<PollRequest> requests,
    String accessToken,
  ) async {
    if (requests.isEmpty) return [];

    final payload = {
      'operations': requests
          .map((r) => {
                'operation': {'name': r.operationName},
                'sceneId': r.sceneId,
                'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
              })
          .toList()
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
          statusText: response.statusText,
          data: data
        });
      } catch (error) {
        return JSON.stringify({
          success: false,
          error: error.message
        });
      }
    })()
    ''';

    final resultStr = await executeJs(jsCode);
    if (resultStr != null) {
      final result = jsonDecode(resultStr as String) as Map<String, dynamic>;

      // Log only on error or non-200
      if (result['success'] != true || result['status'] != 200) {
        print('\n[BATCH POLL API] Status: ${result['status']} ${result['statusText'] ?? ''}');
        print('Body: ${result['data']}');
      }

      if (result['success'] == true) {
        final responseData = result['data'] as Map<String, dynamic>;
        if (responseData.containsKey('operations')) {
          return (responseData['operations'] as List)
              .cast<Map<String, dynamic>>();
        }
      }
    }
    return null;
  }

  /// Download video from URL
  Future<int> downloadVideo(String videoUrl, String outputPath) async {
    final headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept': '*/*',
    };

    try {
      final response = await http.get(Uri.parse(videoUrl), headers: headers);

      if (response.statusCode == 200) {
        final file = File(outputPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
        return response.bodyBytes.length;
      }
      return 0;
    } catch (e) {
      throw Exception('Download error: $e');
    }
  }

  /// Generate UUID
  String _generateUuid() {
    final random = Random();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  // ========== FLOW UI AUTOMATION METHODS ==========

  /// Get current URL of the page
  Future<String> getCurrentUrl() async {
    final result = await executeJs('window.location.href');
    return result as String;
  }

  /// Create a new project on the Flow dashboard
  Future<void> createNewProject() async {
    print('[FLOW] Looking for "New project" button...');
    
    final jsCode = '''
    (function() {
      const buttons = Array.from(document.querySelectorAll('button'));
      const newBtn = buttons.find(b => b.textContent && b.textContent.includes('New project'));
      if (newBtn) {
        newBtn.click();
        return true;
      }
      return false;
    })()
    ''';

    final clicked = await executeJs(jsCode);
    if (clicked == true) {
      print('[FLOW] Clicked "New project".');
    } else {
      print('[FLOW] Could not find "New project" by text. Trying CSS selector...');
      final clickedSelector = await executeJs('''
        (function() {
          const btn = document.querySelector('.sc-a38764c7-0');
          if (btn) { btn.click(); return true; }
          return false; 
        })()
      ''');
      
      if (clickedSelector != true) {
        throw Exception('Could not find "New project" button.');
      }
    }
    
    // CRITICAL: Wait for the new project page to fully load
    print('[FLOW] Waiting for new project page to load...');
    
    // Wait for URL to change to project page
    for (int i = 0; i < 10; i++) {
      await Future.delayed(Duration(milliseconds: 500));
      final currentUrl = await executeJs('window.location.href');
      if (currentUrl.toString().contains('/project/')) {
        print('[FLOW] URL changed to project page');
        break;
      }
    }
    
    // Wait for DOM to be ready
    await Future.delayed(Duration(seconds: 1));
    
    // Wait for document.readyState to be complete
    for (int i = 0; i < 10; i++) {
      final readyState = await executeJs('document.readyState');
      if (readyState == 'complete') {
        print('[FLOW] Document ready state: complete');
        break;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }
    
    // Additional wait for React components to mount and JavaScript to initialize
    await Future.delayed(Duration(seconds: 2));
    print('[FLOW] New project page fully loaded and ready.');
  }

  /// Configure video generation settings
  Future<void> configureFlowSettings({
    String? aspectRatio, // 'Landscape (16:9)' or 'Portrait (9:16)'
    String? model, // 'Veo 3.1 - Fast', 'Veo 3.1 - Quality', etc.
    int? numberOfVideos, // 1-4
  }) async {
    print('[FLOW] Configuring video settings...');
    
    // Open settings panel
    await _openSettingsPanel();
    await Future.delayed(Duration(milliseconds: 500));
    
    // Set aspect ratio if specified
    if (aspectRatio != null) {
      await _setAspectRatio(aspectRatio);
      await Future.delayed(Duration(milliseconds: 300));
    }
    
    // Set model if specified
    if (model != null) {
      await _setModel(model);
      await Future.delayed(Duration(milliseconds: 300));
    }
    
    // Set number of videos if specified
    if (numberOfVideos != null) {
      await _setNumberOfVideos(numberOfVideos);
      await Future.delayed(Duration(milliseconds: 300));
    }
    
    // Close settings panel
    await executeJs('document.activeElement?.blur()');
    
    print('[FLOW] Settings configured successfully.');
  }

  Future<void> _openSettingsPanel() async {
    print('[FLOW] Opening settings panel via CDP...');
    
    // Find the settings button (has 'tune' icon)
    final findSettingsJs = '''
    (function() {
      const buttons = Array.from(document.querySelectorAll('button'));
      const settingsBtn = buttons.find(b => 
        b.querySelector('i')?.textContent === 'tune' || 
        b.textContent.includes('Settings')
      );
      
      if (settingsBtn) {
        settingsBtn.setAttribute('data-settings-btn', 'true');
        return true;
      }
      return false;
    })()
    ''';
    
    final found = await executeJs(findSettingsJs);
    if (found != true) {
      throw Exception('Could not find Settings button');
    }
    
    // Click via CDP
    final btnNodeId = await _querySelectorCDP('button[data-settings-btn="true"]');
    if (btnNodeId == null) {
      throw Exception('Could not query Settings button via CDP');
    }
    
    await _clickElementCDP(btnNodeId, debugName: 'Settings button');
    print('[FLOW] Opened settings panel.');
    await _humanDelay(minMs: 1000, maxMs: 2000); // Wait for panel to fully open
  }

  Future<void> _setAspectRatio(String ratio, {int retryCount = 0}) async {
    if (retryCount > 2) {
      print('[FLOW] Warning: Max retries reached for aspect ratio selection.');
      return;
    }
    print('[FLOW] Setting aspect ratio to: $ratio via CDP (Attempt ${retryCount + 1})');
    
    try {
      // Find Aspect Ratio button
      final findBtnJs = '''
      (function() {
        const buttons = Array.from(document.querySelectorAll('button'));
        const btn = buttons.find(b => b.textContent.trim().includes('Aspect Ratio'));
        if (btn) {
          btn.setAttribute('data-ratio-btn', 'true');
          return true;
        }
        return false;
      })()
      ''';
      
      final found = await executeJs(findBtnJs);
      if (found != true) throw Exception('Aspect Ratio button not found');
      
      final btnNodeId = await _querySelectorCDP('button[data-ratio-btn="true"]');
      if (btnNodeId == null) throw Exception('Could not query Aspect Ratio button');
      
      await _clickElementCDP(btnNodeId, debugName: 'Aspect Ratio button');
      await Future.delayed(Duration(milliseconds: 600));
      
      // Find option
      final findOptionJs = '''
      (function() {
        const options = Array.from(document.querySelectorAll('[role="option"]'));
        const opt = options.find(o => o.textContent.trim().includes('$ratio'));
        if (opt) {
          opt.setAttribute('data-ratio-option', 'true');
          return true;
        }
        return false;
      })()
      ''';
      
      final optFound = await executeJs(findOptionJs);
      if (optFound != true) throw Exception('Aspect Ratio option not found');
      
      final optNodeId = await _querySelectorCDP('[data-ratio-option="true"]');
      if (optNodeId == null) throw Exception('Could not query Aspect Ratio option');
      
      await _clickElementCDP(optNodeId, debugName: 'Aspect Ratio option');
      await _humanDelay(minMs: 400, maxMs: 800);
      print('[FLOW] ✓ Aspect ratio set to: $ratio');
      
    } catch (e) {
      print('[FLOW] Error setting aspect ratio: $e');
      if (retryCount < 2) {
        await Future.delayed(Duration(milliseconds: 800));
        await _setAspectRatio(ratio, retryCount: retryCount + 1);
      }
    }
  }

  Future<void> _setModel(String model, {int retryCount = 0}) async {
    if (retryCount > 3) {
      print('[FLOW] ERROR: Max retries reached for model selection.');
      return;
    }
    print('[FLOW] ====== MODEL SELECTION VIA CDP (Attempt ${retryCount + 1}) ======');
    print('[FLOW] Requested model: "$model"');
    
    try {
      // Step 1: Find all buttons
      final rootId = await _getDocumentRoot();
      
      // Step 2: Use JavaScript to find the Model button (but only for finding, not clicking)
      final findButtonJs = '''
      (function() {
        const buttons = Array.from(document.querySelectorAll('button'));
        for (let i = 0; i < buttons.length; i++) {
          const btn = buttons[i];
          const text = btn.textContent.trim();
          if (text.includes('Model') && (text.includes('Veo') || text.includes('Fast') || text.includes('Quality'))) {
            // Add a unique ID so we can find it via CDP
            btn.setAttribute('data-model-btn', 'true');
            return true;
          }
        }
        return false;
      })()
      ''';
      
      final found = await executeJs(findButtonJs);
      if (found != true) {
        throw Exception('Could not find Model button');
      }
      
      // Step 3: Query the button via CDP using the data attribute
      final btnNodeId = await _querySelectorCDP('button[data-model-btn="true"]');
      if (btnNodeId == null) {
        throw Exception('Could not query Model button via CDP');
      }
      
      // Step 4: Click the button using CDP
      await _clickElementCDP(btnNodeId, debugName: 'Model button');
      await Future.delayed(Duration(milliseconds: 800)); // Wait for dropdown
      
      // Step 5: Find the option with the target model name
      final findOptionJs = '''
      (function() {
        const targetModel = '$model';
        const options = Array.from(document.querySelectorAll('[role="option"]'));
        
        for (let i = 0; i < options.length; i++) {
          const opt = options[i];
          const spans = opt.querySelectorAll('span');
          let modelText = '';
          
          for (const span of spans) {
            const text = span.textContent.trim();
            if (text && !text.includes('Audio') && !text.includes('Beta') && text.length > 3) {
              modelText = text;
              break;
            }
          }
          
          if (!modelText) {
            modelText = opt.textContent.trim().replace(/Beta Audio/g, '').replace(/No Audio/g, '').trim();
          }
          
          if (modelText === targetModel) {
            opt.setAttribute('data-target-option', 'true');
            return true;
          }
        }
        return false;
      })()
      ''';
      
      final optionFound = await executeJs(findOptionJs);
      if (optionFound != true) {
        throw Exception('Could not find option for model: $model');
      }
      
      // Step 6: Click the option via CDP
      final optionNodeId = await _querySelectorCDP('[data-target-option="true"]');
      if (optionNodeId == null) {
        throw Exception('Could not query option via CDP');
      }
      
      await _clickElementCDP(optionNodeId, debugName: 'Model option "$model"');
      await _humanDelay(minMs: 600, maxMs: 1200);
      
      print('[FLOW] ✓ Successfully selected model: $model');
      print('[FLOW] ==============================');
      
    } catch (e) {
      print('[FLOW] ERROR: Model selection failed: $e');
      print('[FLOW] ==============================');
      
      if (retryCount < 3) {
        print('[FLOW] Retrying model selection...');
        await Future.delayed(Duration(milliseconds: 1000));
        await _setModel(model, retryCount: retryCount + 1);
      }
    }
  }

  Future<void> _setNumberOfVideos(int count, {int retryCount = 0}) async {
    if (count < 1 || count > 4) {
      throw ArgumentError('Number of videos must be between 1 and 4');
    }
    if (retryCount > 2) {
      print('[FLOW] Warning: Max retries reached for number of videos selection.');
      return;
    }
    
    print('[FLOW] Setting number of videos to: $count via CDP (Attempt ${retryCount + 1})');
    
    try {
      // Find Outputs button
      final findBtnJs = '''
      (function() {
        const buttons = Array.from(document.querySelectorAll('button'));
        const btn = buttons.find(b => {
          const text = b.textContent.trim();
          return text.includes('Outputs per prompt') || text === 'Outputs';
        });
        if (btn) {
          btn.setAttribute('data-outputs-btn', 'true');
          return true;
        }
        return false;
      })()
      ''';
      
      final found = await executeJs(findBtnJs);
      if (found != true) throw Exception('Outputs button not found');
      
      final btnNodeId = await _querySelectorCDP('button[data-outputs-btn="true"]');
      if (btnNodeId == null) throw Exception('Could not query Outputs button');
      
      await _clickElementCDP(btnNodeId, debugName: 'Outputs button');
      await Future.delayed(Duration(milliseconds: 600));
      
      // Find option
      final findOptionJs = '''
      (function() {
        const options = Array.from(document.querySelectorAll('[role="option"]'));
        const opt = options.find(o => o.textContent.trim() === '$count');
        if (opt) {
          opt.setAttribute('data-outputs-option', 'true');
          return true;
        }
        return false;
      })()
      ''';
      
      final optFound = await executeJs(findOptionJs);
      if (optFound != true) throw Exception('Outputs option not found');
      
      final optNodeId = await _querySelectorCDP('[data-outputs-option="true"]');
      if (optNodeId == null) throw Exception('Could not query Outputs option');
      
      await _clickElementCDP(optNodeId, debugName: 'Outputs option');
      await _humanDelay(minMs: 400, maxMs: 800);
      print('[FLOW] ✓ Number of videos set to: $count');
      
    } catch (e) {
      print('[FLOW] Error setting number of videos: $e');
      if (retryCount < 2) {
        await Future.delayed(Duration(milliseconds: 800));
        await _setNumberOfVideos(count, retryCount: retryCount + 1);
      }
    }
  }

  /// Generate video using Flow UI automation
  Future<void> generateVideoViaFlow({required String prompt}) async {
    print('[FLOW] Preparing to generate video with prompt: "$prompt"');

    // 1. Find the Text Area (ID: PINHOLE_TEXT_AREA_ELEMENT_ID)
    print('[FLOW] Waiting for text area...');
    bool textAreaFound = false;
    for (int i = 0; i < 10; i++) {
      final found = await executeJs("!!document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID')");
      if (found == true) {
        textAreaFound = true;
        break;
      }
      await Future.delayed(Duration(seconds: 1));
    }
    
    if (!textAreaFound) throw Exception('Text area (#PINHOLE_TEXT_AREA_ELEMENT_ID) not found.');

    // 2. Focus and Type Prompt using CDP
    await executeJs("document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID').focus()");
    await executeJs("document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID').value = ''");
    
    // Type character by character with random delays (human-like typing)
    print('[FLOW] Typing prompt character-by-character...');
    for (int i = 0; i < prompt.length; i++) {
      final char = prompt[i];
      
      await sendCommand('Input.dispatchKeyEvent', {
        'type': 'char',
        'text': char,
      });
      
      // Random delay between characters (30-80ms = ~12-33 chars/sec, human typing speed)
      await _humanDelay(minMs: 30, maxMs: 80);
    }
    
    print('[FLOW] Prompt entered via CDP.');

    // Wait for UI to process the input (human-like pause)
    await _humanDelay(minMs: 1500, maxMs: 2500);
    
    // Press Enter to trigger generation
    print('[FLOW] Pressing Enter to submit...');
    await sendCommand('Input.dispatchKeyEvent', {
      'type': 'keyDown',
      'key': 'Enter',
      'code': 'Enter',
      'windowsVirtualKeyCode': 13,
      'nativeVirtualKeyCode': 13,
    });
    await sendCommand('Input.dispatchKeyEvent', {
      'type': 'keyUp',
      'key': 'Enter',
      'code': 'Enter',
      'windowsVirtualKeyCode': 13,
      'nativeVirtualKeyCode': 13,
    });

    await Future.delayed(Duration(milliseconds: 500));

    // Skip button check - Enter key already triggered generation
    print('[FLOW] Generation triggered via Enter key.');
  }

  /// Wait for video completion and return the video URL
  Future<String?> waitForFlowVideoCompletion({int maxWaitSeconds = 300}) async {
    print('[FLOW] Waiting for video completion (max ${maxWaitSeconds}s)...');
    
    final startTime = DateTime.now();
    String? lastStatus;
    
    while (DateTime.now().difference(startTime).inSeconds < maxWaitSeconds) {
      final result = await executeJs('''
        (async function() {
          const videoCards = document.querySelectorAll('video');
          if (videoCards.length > 0) {
            const video = videoCards[videoCards.length - 1];
            const src = video.src || video.querySelector('source')?.src;
            if (src && src.includes('storage.googleapis.com')) {
              return {status: 'complete', url: src};
            }
          }
          
          const statusElements = document.querySelectorAll('[class*="status"], [class*="progress"]');
          for (let el of statusElements) {
            const text = el.textContent || '';
            if (text.includes('Generating') || text.includes('Processing')) {
              return {status: 'generating', url: null};
            }
            if (text.includes('Failed') || text.includes('Error')) {
              return {status: 'failed', url: null};
            }
          }
          
          return {status: 'unknown', url: null};
        })()
      ''');
      
      if (result != null && result is Map) {
        final status = result['status'] as String?;
        final url = result['url'] as String?;
        
        if (status != lastStatus) {
          print('[FLOW] Status: $status');
          lastStatus = status;
        }
        
        if (status == 'complete' && url != null && url.isNotEmpty) {
          print('[FLOW] Video URL found: $url');
          return url;
        }
        
        if (status == 'failed') {
          print('[FLOW] Video generation failed.');
          return null;
        }
      }
      
      final elapsed = DateTime.now().difference(startTime).inSeconds;
      if (elapsed % 10 == 0) {
        print('[FLOW] Still waiting... (${elapsed}s elapsed)');
      }
      
      await Future.delayed(Duration(seconds: 5));
    }
    
    print('[FLOW] Timeout waiting for video completion.');
    return null;
  }

  /// Complete Flow workflow: create project, configure, generate, and download
  Future<String?> generateVideoCompleteFlow({
    required String prompt,
    required String outputPath,
    String aspectRatio = 'Landscape (16:9)',
    String model = 'Veo 3.1 - Fast',
    int numberOfVideos = 1,
  }) async {
    try {
      print('[FLOW] Starting complete video generation workflow...');
      
      // Check current URL
      final currentUrl = await getCurrentUrl();
      print('[FLOW] Current URL: $currentUrl');
      
      // If not on a project page, create new project
      if (!currentUrl.contains('/project/')) {
        print('[FLOW] Not on project page. Creating new project...');
        await createNewProject();
        await Future.delayed(Duration(seconds: 3));
      }
      
      // TEMPORARILY DISABLED: Skip settings configuration to test if it triggers 403
      // await configureFlowSettings(
      //   aspectRatio: aspectRatio,
      //   model: model,
      //   numberOfVideos: numberOfVideos,
      // );
      
      print('[FLOW] Skipping settings configuration - using defaults');
      
      // Generate video
      await generateVideoViaFlow(prompt: prompt);
      
      // Wait for completion
      final videoUrl = await waitForFlowVideoCompletion();
      
      if (videoUrl != null) {
        // Download video
        print('[FLOW] Downloading video...');
        final bytes = await downloadVideo(videoUrl, outputPath);
        print('[FLOW] Downloaded ${bytes} bytes to: $outputPath');
        return outputPath;
      } else {
        print('[FLOW] Failed to get video URL.');
        return null;
      }
    } catch (e, stack) {
      print('[FLOW] Error in complete workflow: $e');
      print(stack);
      return null;
    }
  }
}

/// Request for batch polling of video status
class PollRequest {
  final String operationName;
  final String sceneId;

  PollRequest(this.operationName, this.sceneId);
}

