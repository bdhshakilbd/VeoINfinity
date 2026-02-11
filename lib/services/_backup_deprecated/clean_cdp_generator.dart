import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Clean CDP-based Video Generator (No UI Automation)
/// Uses direct API calls with reCAPTCHA tokens
class CleanCDPGenerator {
  final int debugPort;
  WebSocketChannel? ws;
  Stream<dynamic>? _broadcastStream;
  int msgId = 0;

  CleanCDPGenerator({this.debugPort = 9222});

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
      throw Exception('No labs.google tab found! Please open https://labs.google/fx/tools/flow');
    }

    final wsUrl = targetTab['webSocketDebuggerUrl'] as String;
    ws = WebSocketChannel.connect(Uri.parse(wsUrl));
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

  /// Execute JavaScript in the page context
  Future<dynamic> executeJs(String expression, {Duration timeout = const Duration(seconds: 90)}) async {
    final result = await sendCommand('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });

    return result['result']?['result']?['value'];
  }

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

  /// Get OAuth access token from browser session
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

  final List<String> _recaptchaPool = [];

  /// Prefetch reCAPTCHA tokens to avoid delays during generation
  Future<int> prefetchRecaptchaTokens(int count) async {
    print('[CLEAN CDP] 🔑 Prefetching $count reCAPTCHA tokens...');
    int successCount = 0;
    
    for (int i = 0; i < count; i++) {
      try {
        final token = await _fetchNewRecaptchaToken();
        if (token != null) {
          _recaptchaPool.add(token);
          successCount++;
          if (successCount % 4 == 0) {
             print('[CLEAN CDP]   ✓ Got $successCount/$count tokens');
          }
        }
      } catch (e) {
        print('[CLEAN CDP]   ✗ Error prefetching token: $e');
      }
      // Small delay between tokens to avoid rate limits
      await Future.delayed(const Duration(milliseconds: 300));
    }
    print('[CLEAN CDP] ✓ Prefetched $successCount tokens (Total in pool: ${_recaptchaPool.length})');
    return successCount;
  }

  /// Get reCAPTCHA token (Uses pool if available)
  Future<String?> getRecaptchaToken() async {
    if (_recaptchaPool.length < 5) {
      // Opportunistically prefetch more in the background if running low
      prefetchRecaptchaTokens(10);
    }
    
    if (_recaptchaPool.isNotEmpty) {
      return _recaptchaPool.removeAt(0);
    }
    return await _fetchNewRecaptchaToken();
  }

  /// Internal: Fetch a fresh reCAPTCHA token from JS
  Future<String?> _fetchNewRecaptchaToken() async {
    const jsCode = '''
    (async function() {
      try {
        if (typeof grecaptcha === 'undefined' || !grecaptcha.enterprise) {
           return 'ERROR: grecaptcha not loaded';
        }
        const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
        return await grecaptcha.enterprise.execute(siteKey, {
          action: 'VIDEO_GENERATION'
        });
      } catch (e) {
        return 'ERROR: ' + e.message;
      }
    })()
    ''';
    
    final result = await executeJs(jsCode);
    if (result is String) {
      if (result.startsWith('ERROR:')) {
        print('[CLEAN CDP] ✗ reCAPTCHA error: $result');
        return null;
      }
      return result;
    }
    return null;
  }

  /// Generate UUID
  String _generateUuid() {
    final random = Random();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int byte) => byte.toRadixString(16).padLeft(2, '0');
    return '${hex(bytes[0])}${hex(bytes[1])}${hex(bytes[2])}${hex(bytes[3])}-'
        '${hex(bytes[4])}${hex(bytes[5])}-${hex(bytes[6])}${hex(bytes[7])}-'
        '${hex(bytes[8])}${hex(bytes[9])}-${hex(bytes[10])}${hex(bytes[11])}'
        '${hex(bytes[12])}${hex(bytes[13])}${hex(bytes[14])}${hex(bytes[15])}';
  }

  /// Generate video using clean CDP method (no UI automation)
  Future<Map<String, dynamic>?> generateVideo({
    required String prompt,
    required String accessToken,
    required String recaptchaToken,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String model = 'veo_3_1_t2v_fast_ultra_relaxed',
    String? projectId,
  }) async {
    final sceneId = _generateUuid();
    final seed = DateTime.now().millisecondsSinceEpoch % 10000;
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    projectId ??= '';

    final payload = {
      'clientContext': {
        'recaptchaContext': {
          'token': recaptchaToken,
          'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB'
        },
        'sessionId': sessionId,
        'projectId': projectId,
        'tool': 'PINHOLE',
        'userPaygateTier': 'PAYGATE_TIER_TWO'
      },
      'requests': [
        {
          'aspectRatio': aspectRatio,
          'seed': seed,
          'textInput': {'prompt': prompt},
          'videoModelKey': model,
          'metadata': {'sceneId': sceneId}
        }
      ]
    };

    print('[API] Generating video...');
    print('[API] Prompt: ${prompt.length > 50 ? "${prompt.substring(0, 50)}..." : prompt}');
    print('[API] Model: $model');

    final jsCode = '''
    (async function() {
      try {
        const response = await fetch(
          'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText',
          {
            method: 'POST',
            headers: { 
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken'
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
      
      if (result['success'] == true) {
        print('[API] ✓ Success: HTTP ${result['status']}');
        final data = result['data'] as Map<String, dynamic>;
        if (data.containsKey('operations')) {
          final ops = data['operations'] as List;
          if (ops.isNotEmpty) {
            final op = ops[0] as Map<String, dynamic>;
            final opName = op['operation']?['name'];
            print('[API] Operation: $opName');
          }
        }
      } else {
        print('[API] ✗ Failed: HTTP ${result['status']}');
        print('[API] Error: ${result['error'] ?? result['data']}');
      }

      return result;
    }
    return null;
  }

  /// Poll video status
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
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken'
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

      if (result['success'] == true) {
        final responseData = result['data'] as Map<String, dynamic>;
        if (responseData.containsKey('operations') && (responseData['operations'] as List).isNotEmpty) {
          return (responseData['operations'] as List)[0] as Map<String, dynamic>;
        }
      }
    }
    return null;
  }

  /// Download video from URL
  Future<void> downloadVideo(String videoUrl, String outputPath) async {
    print('[DOWNLOAD] Downloading: ${outputPath.split(Platform.pathSeparator).last}');
    
    final response = await http.get(Uri.parse(videoUrl));
    if (response.statusCode == 200) {
      final file = File(outputPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.bodyBytes);
      print('[DOWNLOAD] ✓ Saved: $outputPath');
    } else {
      throw Exception('Download failed: HTTP ${response.statusCode}');
    }
  }

  /// Get current URL of the page
  Future<String> getCurrentUrl() async {
    final result = await executeJs('window.location.href');
    return result as String;
  }
}
