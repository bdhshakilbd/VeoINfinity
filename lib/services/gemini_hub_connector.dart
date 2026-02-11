import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

/// Direct connection to both the blob iframe (for API) and main page (for interactions).
/// FULLY SELF-CONTAINED: Includes all methods for text/image generation and interaction.
/// 
/// Improvements for AMD Ryzen stability:
/// - WebSocket heartbeat to prevent connection dormancy
/// - Health monitoring for early detection of connection issues
class GeminiHubConnector {
  WebSocketChannel? _ws;
  int _msgId = 0;
  final Map<int, Completer<dynamic>> _responses = {};
  
  WebSocketChannel? _mainWs;
  int _mainMsgId = 0;
  final Map<int, Completer<dynamic>> _mainResponses = {}; // Tracker for top page responses
  
  bool firstImageGenerated = false;
  
  // Health monitoring (AMD Ryzen stability)
  Timer? _heartbeatTimer;
  bool _isHealthy = true;
  DateTime _lastSuccessfulCommand = DateTime.now();
  int _connectedPort = 9222;
  
  /// Check if connected to the browser
  bool get isConnected => _ws != null;
  
  /// Check if connection is healthy (recent successful command within 30s)
  bool get isHealthy => _isHealthy && 
      _ws != null && 
      DateTime.now().difference(_lastSuccessfulCommand).inSeconds < 30;

  /// Brings the Google AI Studio window to the front to ensure focus for interactions
  Future<bool> focusChrome() async {
    try {
      if (Platform.isWindows) {
         // Using PowerShell to activate window by title
         // Exact copy of Python logic: f'(New-Object -ComObject WScript.Shell).AppActivate("{win_title}")'
         const winTitle = "Google AI Studio";
         final psCmd = '(New-Object -ComObject WScript.Shell).AppActivate("$winTitle")';
         await Process.run('powershell', ['-command', psCmd]);
         await Future.delayed(const Duration(milliseconds: 500));
         return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Connect to both the blob iframe and the main AI Studio page
  /// Uses async yields to prevent UI freezing during connection
  Future<void> connect({int port = 9222}) async {
    // Close existing connection if any
    await close();
    
    _connectedPort = port;
    
    // Yield to UI thread before potentially blocking operations
    await Future.delayed(Duration.zero);
    
    await focusChrome();
    
    // Fetch targets from localhost:port/json with timeout
    String? blobWsUrl;
    String? mainWsUrl;
    
    try {
      // Yield to UI thread before HTTP request
      await Future.delayed(Duration.zero);
      
      final url = Uri.parse('http://localhost:$port/json');
      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Connection timeout to port $port'),
      );
      
      // Yield to UI thread after HTTP request
      await Future.delayed(Duration.zero);
      
      if (response.statusCode == 200) {
        final List<dynamic> targets = jsonDecode(response.body);
        
        for (final t in targets) {
          final urlStr = t['url'] as String? ?? '';
          if (urlStr.contains('blob:')) {
            blobWsUrl = t['webSocketDebuggerUrl'];
          } else if ((urlStr.contains('aistudio.google.com') || 
                      urlStr.contains('ai.studio') || 
                      urlStr.contains('labs.google')) && t['type'] == 'page') {
            mainWsUrl = t['webSocketDebuggerUrl'];
          }
        }
      } else {
         throw Exception("Failed to fetch targets from port $port");
      }
    } catch (e) {
      throw Exception("Port $port: Connection failed: $e");
    }

    if (blobWsUrl == null && mainWsUrl == null) {
      throw Exception("Port $port: No suitable targets found!");
    }

    // Connect to blob frame (if found)
    if (blobWsUrl != null) {
      try {
        _ws = WebSocketChannel.connect(Uri.parse(blobWsUrl));
        _listen(); // Start listening
        await _cmd("Runtime.enable");
        
        // Force page to front
        await _cmd("Page.bringToFront");
      } catch (e) {
         print("Error connecting to blob WS: $e");
      }
    }

    // Connect to main page
    if (mainWsUrl != null) {
      try {
        _mainWs = WebSocketChannel.connect(Uri.parse(mainWsUrl));
        _listenMain();
        await _cmdMain("Runtime.enable");

        // Force to active state
        await _cmd("Page.bringToFront");

        // Set Zoom to 30%
        await _cmdMain("Runtime.evaluate", {"expression": "document.body.style.zoom = '30%'", "returnByValue": true});
        
        await _cmd("Page.bringToFront");

        // Zoom back to 100%
        await _cmdMain("Runtime.evaluate", {"expression": "document.body.style.zoom = '100%'", "returnByValue": true});

        // Check for "Untrusted App" or "Launch!" modals
        for (int i = 0; i < 3; i++) {
          await _checkModalBlocking();
          await Future.delayed(const Duration(seconds: 1));
        }
        await Future.delayed(const Duration(seconds: 2));
        await _checkModalBlocking();

      } catch (e) {
         print("Error connecting to main WS: $e");
      }
    }
    
    // Mark as healthy and start heartbeat (critical for AMD Ryzen stability)
    _isHealthy = true;
    _lastSuccessfulCommand = DateTime.now();
    _startHeartbeat();
    print('[GeminiHub] Connected to port $port with heartbeat enabled');
  }
  
  /// Start periodic heartbeat to prevent connection dormancy
  /// This is crucial for AMD Ryzen CPUs which may aggressively throttle I/O
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_ws == null && _mainWs == null) return;
      try {
        // Send lightweight command to keep connection alive
        if (_mainWs != null) {
          await _cmdMainAwait('Runtime.evaluate', {'expression': '1', 'returnByValue': true}, 5);
        }
        _isHealthy = true;
        _lastSuccessfulCommand = DateTime.now();
      } catch (e) {
        print('[GeminiHub] Heartbeat failed on port $_connectedPort: $e');
        _isHealthy = false;
      }
    });
  }
  
  /// Ensure connection is healthy, reconnect if needed
  Future<void> ensureConnected() async {
    if (!isConnected || !isHealthy) {
      print('[GeminiHub] Connection unhealthy on port $_connectedPort, reconnecting...');
      await close();
      await Future.delayed(const Duration(milliseconds: 500));
      await connect(port: _connectedPort);
    }
  }

  Future<void> close() async {
    // Stop heartbeat
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    
    // Complete all pending responses with error to prevent memory leaks
    for (final completer in _responses.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Connection closed'));
      }
    }
    _responses.clear();
    
    for (final completer in _mainResponses.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Connection closed'));
      }
    }
    _mainResponses.clear();
    
    // Close WebSocket connections
    try { await _ws?.sink.close(status.goingAway); } catch (_) {}
    try { await _mainWs?.sink.close(status.goingAway); } catch (_) {}
    
    _ws = null;
    _mainWs = null;
    _isHealthy = false;
  }

  /// Send CDP command to blob frame
  Future<dynamic> _cmd(String method, [Map<String, dynamic>? params]) async {
    if (_ws == null) return null;
    _msgId++;
    final currentId = _msgId;
    final msg = {
      "id": currentId,
      "method": method,
      "params": params ?? {}
    };
    
    final completer = Completer<dynamic>();
    _responses[currentId] = completer;
    
    _ws!.sink.add(jsonEncode(msg));
    return completer.future;
  }

  /// Send CDP command to main page (Fire and Forget or tracked internally)
  /// Python: returns msg_id immediately
  Future<int> _cmdMain(String method, [Map<String, dynamic>? params]) async {
    if (_mainWs == null) return 0;
    _mainMsgId++;
    final msg = {
      "id": _mainMsgId,
      "method": method,
      "params": params ?? {}
    };
    _mainWs!.sink.add(jsonEncode(msg));
    return _mainMsgId;
  }

  /// Send CDP command to main page and WAIT for response
  Future<dynamic> _cmdMainAwait(String method, [Map<String, dynamic>? params, int timeoutSeconds = 10]) async {
     if (_mainWs == null) return null;
     _mainMsgId++;
     final currentId = _mainMsgId;
     final msg = {
       "id": currentId,
       "method": method,
       "params": params ?? {}
     };
     
     final completer = Completer<dynamic>();
     _mainResponses[currentId] = completer;
     _mainWs!.sink.add(jsonEncode(msg));
     
     try {
       return await completer.future.timeout(Duration(seconds: timeoutSeconds));
     } catch (e) {
       return null;
     }
  }

  void _listen() {
    _ws!.stream.listen((message) {
      if (message is! String) return;
      try {
        final data = jsonDecode(message);
        if (data is Map && data.containsKey('id')) {
          final id = data['id'];
          if (_responses.containsKey(id)) {
            final completer = _responses.remove(id);
            if (completer != null && !completer.isCompleted) {
              completer.complete(data);
            }
          }
        }
      } catch (e) {
        print("Error parsing blob WS message: $e");
      }
    }, onError: (err) => print("Blob WS Error: $err"));
  }

  void _listenMain() {
    _mainWs!.stream.listen((message) {
      if (message is! String) return;
      try {
        final data = jsonDecode(message);
        if (data is Map && data.containsKey('id')) {
          final id = data['id'];
          if (_mainResponses.containsKey(id)) {
            final completer = _mainResponses.remove(id);
            if (completer != null && !completer.isCompleted) {
              completer.complete(data);
            }
          }
        }
      } catch (e) {
        print("Error parsing main WS message: $e");
      }
    }, onError: (err) => print("Main WS Error: $err"));
  }

  /// Robust JS evaluation with automatic modal bypass (EXACT Python logic)
  Future<dynamic> _eval(String code, {int timeout = 60}) async {
    // We launch the command then wait
    final cmdFuture = _cmd("Runtime.evaluate", {
      "expression": code,
      "awaitPromise": true,
      "returnByValue": true
    });

    dynamic resp;
    try {
      // Step 1: Wait 3s
      resp = await cmdFuture.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // Step 2: Clear Modal if it appeared
      await _checkModalBlocking();
      // Step 3: Re-wait for the SAME task
      try {
        resp = await cmdFuture.timeout(Duration(seconds: timeout > 3 ? timeout - 3 : 1));
      } on TimeoutException {
        return {"error": "Operation timed out after $timeout seconds"};
      }
    } catch(e) {
      return {"error": e.toString()};
    }
    
    // Extract value from CDP response (Python: result['result']['value'])
    if (resp != null && resp is Map && resp.containsKey('result')) {
      final result = resp['result'];
      if (result is Map && result.containsKey('exceptionDetails')) {
        return {"error": result['exceptionDetails']['text'] ?? 'Unknown error'};
      }
      if (result is Map && result.containsKey('result')) {
        final resultObj = result['result'];
        if (resultObj is Map && resultObj.containsKey('value')) {
          return resultObj['value'];
        }
      }
    }
    return null;
  }
  
  Future<dynamic> _evalMainPage(String expression, {int timeout = 30}) async {
    if (_mainWs == null) return null;
    try {
      _mainMsgId++;
      final currentId = _mainMsgId;
      final msg = {
        "id": currentId,
        "method": "Runtime.evaluate",
        "params": {
          "expression": expression,
          "returnByValue": true,
          "awaitPromise": true
        }
      };
      
      final completer = Completer<dynamic>();
      _mainResponses[currentId] = completer;
      _mainWs!.sink.add(jsonEncode(msg));
      
      final response = await completer.future.timeout(Duration(seconds: timeout));
      // Extract value
      // response = {id: ..., result: {result: {type: ..., value: ...}}}
      if (response is Map && response['result'] is Map && response['result']['result'] is Map) {
         return response['result']['result']['value'];
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<void> _clickModalHumanlyCdp(Map<String, dynamic> rect) async {
    // cx, cy = rect['x'] + rect['width']/2, rect['y'] + rect['height']/2
    final double cx = (rect['x'] as num).toDouble() + (rect['width'] as num).toDouble() / 2;
    final double cy = (rect['y'] as num).toDouble() + (rect['height'] as num).toDouble() / 2;

    // 1. Direct JS Click
    const String jsForceClick = """
      (() => {
         let el = document.elementFromPoint(%CX%, %CY%);
         if(el) el.click();
      })()
    """;
    await _cmdMain("Runtime.evaluate", {"expression": jsForceClick.replaceAll('%CX%', '$cx').replaceAll('%CY%', '$cy')});

    // 2. Mouse Click Fallback
    await _cmdMain("Input.dispatchMouseEvent", {"type": "mousePressed", "x": cx, "y": cy, "button": "left", "clickCount": 1});
    await Future.delayed(const Duration(milliseconds: 100));
    await _cmdMain("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": cx, "y": cy, "button": "left", "clickCount": 1});
    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Restore Full "Human Sequence"
    for (int i = 0; i < 10; i++) {
        // Touch
        await _cmdMain("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": cx, "y": cy}]});
        await _cmdMain("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []});
        // Drag
        await _cmdMain("Input.dispatchMouseEvent", {"type": "mousePressed", "x": cx, "y": cy, "button": "left"});
        await _cmdMain("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": cx + 5, "y": cy + 5, "button": "left"});
        await _cmdMain("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": cx + 5, "y": cy + 5, "button": "left"});
        await Future.delayed(const Duration(milliseconds: 200));
    }
  }


  Future<void> _checkModalBlocking() async {
    if (_mainWs == null) return;
    
    // Check for BOTH modal types (Python combined logic)
    const checkJs = """(() => {
      // 1. Check for "Untrusted App" / "Continue to App" dialog
      let d = document.querySelector('#untrusted-dialog');
      if (d && d.offsetParent !== null) {
          let btn = d.querySelector('button.ms-button-primary');
          if (btn) {
              const r = btn.getBoundingClientRect();
              return {found: true, x: r.left, y: r.top, width: r.width, height: r.height, type: 'untrusted'};
          }
      }

      // 2. Check for standard 'Launch!' interaction modal (after first API request)
      const m = document.querySelector('.interaction-modal');
      if (m && m.offsetParent !== null) {
          const r = m.getBoundingClientRect();
          return {found: true, x: r.x, y: r.y, width: r.width, height: r.height, type: 'launch'};
      }
      return {found: false};
    })()""";

    final res = await _evalMainPage(checkJs, timeout: 2);
    if (res != null && res is Map && res['found'] == true) {
      await _clickModalHumanlyCdp(res as Map<String, dynamic>);
    }
  }
  
  /// Check and click "Continue to App" / "Untrusted App" dialog (shows on app load)
  Future<bool> checkContinueToAppModal() async {
    if (_mainWs == null) return false;
    
    const checkJs = """(() => {
      let d = document.querySelector('#untrusted-dialog');
      if (d && d.offsetParent !== null) {
          let btn = d.querySelector('button.ms-button-primary');
          if (btn) {
              const r = btn.getBoundingClientRect();
              return {found: true, x: r.left, y: r.top, width: r.width, height: r.height};
          }
      }
      return {found: false};
    })()""";

    final res = await _evalMainPage(checkJs, timeout: 3);
    if (res != null && res is Map && res['found'] == true) {
      await _clickModalHumanlyCdp(res as Map<String, dynamic>);
      return true;
    }
    return false;
  }
  
  /// Check and click "Launch!" modal (shows after first API request)
  Future<bool> checkLaunchModal() async {
    if (_mainWs == null) return false;
    
    const checkJs = """(() => {
      const m = document.querySelector('.interaction-modal');
      if (m && m.offsetParent !== null) {
          const r = m.getBoundingClientRect();
          return {found: true, x: r.x, y: r.y, width: r.width, height: r.height};
      }
      return {found: false};
    })()""";

    final res = await _evalMainPage(checkJs, timeout: 3);
    if (res != null && res is Map && res['found'] == true) {
      await _clickModalHumanlyCdp(res as Map<String, dynamic>);
      return true;
    }
    return false;
  }
  
  // --- High Level API (New geminiHub.generate API) ---
  
  /// Map of dropdown model IDs to actual Gemini model names
  static const Map<String, String> modelNames = {
    'GEMINI_3_FLASH': 'gemini-3-flash-preview',
    'GEMINI_3_PRO': 'gemini-3-pro-preview',
    'GEMINI_2_5_FLASH': 'gemini-2.5-flash',
    'GEMINI_2_5_PRO': 'gemini-2.5-pro',
  };
  
  /// Convert model ID to actual model name
  String _getModelName(String modelId) {
    return modelNames[modelId] ?? 'gemini-3-flash-preview';
  }
  
  /// Generate text using the new geminiHub.generate(prompt, options) API
  /// Options: { model, promptCount, temperature, useSchema, jsonSchema }
  Future<dynamic> generate(String prompt, {
    String? model,
    int? promptCount,
    double? temperature,
    Map<String, dynamic>? schema,
  }) async {
    final modelName = model != null ? _getModelName(model) : null;
    
    // Build options object
    List<String> optionParts = [];
    if (modelName != null) optionParts.add('model: ${jsonEncode(modelName)}');
    if (promptCount != null) optionParts.add('promptCount: $promptCount');
    if (temperature != null) optionParts.add('temperature: $temperature');
    if (schema != null) {
      optionParts.add('useSchema: true');
      optionParts.add('jsonSchema: JSON.stringify(${jsonEncode(schema)})');
    }
    
    String optionsStr = optionParts.isEmpty ? '' : ', { ${optionParts.join(', ')} }';
    
    String code = """(async () => {
      try {
        const result = await window.geminiHub.generate(${jsonEncode(prompt)}$optionsStr);
        return result;
      } catch(e) {
        return { error: e.message };
      }
    })()""";
    
    print('[DART-GENERATE] Calling generate with prompt: ${prompt.substring(0, prompt.length > 50 ? 50 : prompt.length)}...');
    final result = await _eval(code, timeout: 600); // 10 minute timeout
    print('[DART-GENERATE] Result type: ${result.runtimeType}');
    
    // Extract output from result
    if (result is Map && result.containsKey('output')) {
      return result['output'];
    }
    return result;
  }
  
  /// Generate with polling using lastResponse approach
  Future<dynamic> generateStreaming(String model, String prompt, {
    Map<String, dynamic>? schema,
    int? promptCount,
    void Function(String text, bool isComplete)? onUpdate,
  }) async {
    final modelName = _getModelName(model);
    
    // Clear lastResponse first
    await _eval("window.geminiHub.lastResponse = null", timeout: 5);
    
    // Build options object
    List<String> optionParts = ['model: ${jsonEncode(modelName)}'];
    if (promptCount != null) optionParts.add('promptCount: $promptCount');
    optionParts.add('temperature: 1.0');
    if (schema != null) {
      optionParts.add('useSchema: true');
      optionParts.add('jsonSchema: JSON.stringify(${jsonEncode(schema)})');
    }
    String optionsStr = '{ ${optionParts.join(', ')} }';
    
    // Start generation (fire and forget - don't await)
    String genCode = "window.geminiHub.generate(${jsonEncode(prompt)}, $optionsStr)";
    print('[DART-STREAM] Starting generation...');
    _eval(genCode, timeout: 600); // Don't await - let it run
    
    // Poll lastResponse for updates
    const maxPolls = 2000; // 2000 * 300ms = 600s max
    
    for (int i = 0; i < maxPolls; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Check lastResponse
      String checkCode = """(() => {
        const latest = window.geminiHub.lastResponse;
        if (latest && latest.output) {
          return {
            complete: true,
            output: latest.output,
            model: latest.model || '',
            durationMs: latest.durationMs || 0
          };
        }
        return { complete: false };
      })()""";
      
      final checkResult = await _eval(checkCode, timeout: 5);
      
      if (checkResult is Map) {
        if (checkResult['complete'] == true) {
          final output = checkResult['output'] ?? '';
          print('[DART-STREAM] COMPLETED: ${output.toString().length} chars, took ${checkResult['durationMs']}ms');
          onUpdate?.call(output.toString(), true);
          return output;
        }
      }
      
      // Log every 10 polls
      if (i % 10 == 0) {
        print('[DART-STREAM] Poll $i: waiting for completion...');
        // Notify with progress
        onUpdate?.call('⏳ Generating... (poll #$i)', false);
      }
    }
    
    // Timeout - try to get lastResponse one more time
    final lastCheck = await _eval("window.geminiHub.lastResponse?.output", timeout: 5);
    if (lastCheck != null && lastCheck.toString().isNotEmpty) {
      onUpdate?.call(lastCheck.toString(), true);
      return lastCheck;
    }
    
    return {'error': 'Generation timeout after 600s'};
  }
  
  /// Legacy askStreaming - now uses generateStreaming
  Future<dynamic> askStreaming(String model, String prompt, {
    Map<String, dynamic>? schema,
    void Function(String text, bool isComplete)? onUpdate,
  }) async {
    return generateStreaming(model, prompt, schema: schema, onUpdate: onUpdate);
  }
  
  /// Legacy ask method - now uses generate
  Future<dynamic> ask(String model, String prompt, [Map<String, dynamic>? schema]) async {
    return generate(prompt, model: model, schema: schema);
  }
  
  Future<dynamic> spawnImage(String prompt, {String aspectRatio = "1:1", dynamic refImages, String? model}) async {
    // Check for Continue to App modal before spawn (might still be waiting)
    await checkContinueToAppModal();
    
    // Python: spawnImage(prompt, aspect_ratio, ref_imgs, model_id_js)
    // Order: prompt, aspect, ref_images (or undefined), model
    String refArg = refImages != null && (refImages is List && refImages.isNotEmpty) 
        ? jsonEncode(refImages) 
        : "undefined";
    String modelArg = model ?? "window.geminiHub.models.GEMINI_2_FLASH_IMAGE";
    String code = "window.geminiHub.spawnImage(${jsonEncode(prompt)}, ${jsonEncode(aspectRatio)}, $refArg, $modelArg)";
    // Increased timeout for large ref image payloads
    return await _eval(code, timeout: 60);
  }
  
  Future<dynamic> getThread(String threadId) async {
    String code = """(() => {
        try {
            const t = window.geminiHub.getThread('$threadId');
            if (!t) return { status: 'NOT_FOUND' };
            return { status: t.status, error: t.error || null, result: t.status === 'COMPLETED' ? t.result : null };
        } catch(e) { return { status: 'ERROR', error: e.message }; }
    })()""";
    return await _eval(code, timeout: 10);
  }
  
  Future<dynamic> waitFor(String threadId) async {
    String code = "(async () => { try { return await window.geminiHub.waitFor('$threadId'); } catch(e) { return {error: e.message}; } })()";
    return await _eval(code, timeout: 120);
  }
  
  /// Public method to check and clear modals (for use during browser opening)
  Future<void> checkModalBlocking() async {
    await _checkModalBlocking();
  }
  
  /// Set browser window position and size via CDP (exact Python: set_browser_window_rect)
  Future<bool> setBrowserWindowRect(int x, int y, int width, int height) async {
    if (_mainWs == null) return false;
    try {
      // 1. Get window ID for the current target
      final win = await _cmdMainAwait("Browser.getWindowForTarget");
      if (win != null && win['result'] != null && win['result']['windowId'] != null) {
        final windowId = win['result']['windowId'];
        // 2. Set bounds
        await _cmdMain("Browser.setWindowBounds", {
          "windowId": windowId,
          "bounds": {
            "left": x,
            "top": y,
            "width": width,
            "height": height,
            "windowState": "normal"
          }
        });
        return true;
      }
    } catch (_) {}
    return false;
  }
  
  /// Navigate to a URL
  Future<void> navigateTo(String url) async {
    if (_mainWs == null) return;
    await _cmdMain("Page.navigate", {"url": url});
  }

  /// Navigate to a URL and extract cookies for labs.google domain only
  Future<String?> getCookiesForDomain(String url) async {
    if (_mainWs == null) return null;
    
    try {
      // Navigate to the URL
      await _cmdMain("Page.navigate", {"url": url});
      
      // Wait for navigation to complete (wait for load event)
      await Future.delayed(const Duration(seconds: 3));
      
      // Extract cookies using CDP - filter by domain
      final cookieResult = await _cmdMainAwait("Network.getCookies", {"urls": ["https://labs.google", "https://.google.com"]}, 10);
      
      if (cookieResult != null && cookieResult['result'] != null) {
        final cookies = cookieResult['result']['cookies'] as List?;
        if (cookies != null && cookies.isNotEmpty) {
          // Filter only cookies relevant to labs.google and google.com auth
          final relevantDomains = ['.google.com', 'labs.google', '.labs.google', 'google.com'];
          final relevantCookieNames = [
            '__Secure-1PSID', '__Secure-3PSID', '__Secure-1PSIDTS', '__Secure-3PSIDTS',
            '__Secure-1PSIDCC', '__Secure-3PSIDCC', '__Secure-ENID',
            'SID', 'SSID', 'HSID', 'APISID', 'SAPISID', 'NID', 'AEC',
            '1P_JAR', 'SOCS', 'CONSENT', 'SIDCC', '__Secure-1PAPISID', '__Secure-3PAPISID',
          ];
          
          final filteredCookies = cookies.where((cookie) {
            final domain = (cookie['domain'] ?? '').toString().toLowerCase();
            final name = (cookie['name'] ?? '').toString();
            
            // Check if domain is relevant
            final isDomainRelevant = relevantDomains.any((d) => domain.contains(d.toLowerCase()));
            if (!isDomainRelevant) return false;
            
            // For google.com domain, only keep auth-related cookies
            if (domain.contains('.google.com') && !domain.contains('labs.google')) {
              return relevantCookieNames.contains(name);
            }
            
            return true;
          }).toList();
          
          if (filteredCookies.isNotEmpty) {
            // Format cookies as a cookie string (name=value; name2=value2; ...)
            final cookieString = filteredCookies.map((cookie) {
              return '${cookie['name']}=${cookie['value']}';
            }).join('; ');
            
            print('Filtered ${filteredCookies.length} relevant cookies from ${cookies.length} total');
            return cookieString;
          }
        }
      }
    } catch (e) {
      print("Error extracting cookies: $e");
    }
    
    return null;
  }
}
