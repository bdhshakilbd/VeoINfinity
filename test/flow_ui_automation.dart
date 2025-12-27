import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:path/path.dart' as path;

// Import the config model (for standalone script, we'll inline the enums instead)
// In production, use: import 'package:veo3_another/models/video_generation_config.dart';

/// Aspect ratio options for video generation
enum AspectRatio {
  landscape('Landscape (16:9)', 'VIDEO_ASPECT_RATIO_LANDSCAPE'),
  portrait('Portrait (9:16)', 'VIDEO_ASPECT_RATIO_PORTRAIT');

  final String label;
  final String apiValue;
  const AspectRatio(this.label, this.apiValue);
}

/// Veo model options
enum VeoModel {
  veo31Fast('Veo 3.1 - Fast', 'veo_3_1_t2v_fast_ultra'),
  veo31Quality('Veo 3.1 - Quality', 'veo_3_1_t2v_quality_ultra'),
  veo2Fast('Veo 2 - Fast', 'veo_2_t2v_fast'),
  veo2Quality('Veo 2 - Quality', 'veo_2_t2v_quality');

  final String label;
  final String apiValue;
  const VeoModel(this.label, this.apiValue);
}

/// A standalone script to test UI automation on Google VideoFX Flow
/// Run this while Chrome is open with remote debugging enabled on port 9222
/// and you are logged into https://labs.google/fx
void main() async {
  print('Starting VideoFX UI Automation Test with Video Download...');
  final automation = FlowUiAutomation();

  try {
    await automation.connect();
    print('Connected to Chrome.');

    // Enable network monitoring to capture API responses
    await automation.enableNetworkMonitoring();

    // 1. Ensure we are on the Flow dashboard or navigate there
    // For this test, we assume the user might be on a project page or the dashboard.
    // If on a project page, we'll just try to generate. If on dashboard, we'll create a new project.
    
    final currentUrl = await automation.getCurrentUrl();
    print('Current URL: $currentUrl');

    if (currentUrl.contains('/project/')) {
      print('Already on a project page. Proceeding to generation...');
      await automation.generateVideo(prompt: "A futuristic city with flying cars, cyberpunk style, cinematic lighting");
      
      // Wait for generation to start and monitor completion
      print('Monitoring video generation status...');
      final videoUrl = await automation.waitForVideoCompletion();
      
      if (videoUrl != null) {
        print('Video completed! URL: $videoUrl');
        final downloadPath = path.join(Directory.current.path, 'downloads', 'generated_video_${DateTime.now().millisecondsSinceEpoch}.mp4');
        await automation.downloadVideo(videoUrl, downloadPath);
        print('Video downloaded to: $downloadPath');
      } else {
        print('Failed to get video URL or generation failed.');
      }
    } else {
      print('On dashboard (or other page). Attempting to create new project...');
      await automation.createNewProject();
      // Wait for navigation
      await Future.delayed(Duration(seconds: 3));
      
      // Configure settings before generating
      print('Configuring video settings...');
      await automation.configureSettings(
        aspectRatio: AspectRatio.portrait,
        model: VeoModel.veo31Quality,
        numberOfVideos: 1,
      );
      
      await automation.generateVideo(prompt: "A beautiful mountain landscape at sunset, 4k, realistic");
      
      // Monitor completion
      print('Monitoring video generation status...');
      final videoUrl = await automation.waitForVideoCompletion();
      
      if (videoUrl != null) {
        print('Video completed! URL: $videoUrl');
        final downloadPath = path.join(Directory.current.path, 'downloads', 'generated_video_${DateTime.now().millisecondsSinceEpoch}.mp4');
        await automation.downloadVideo(videoUrl, downloadPath);
        print('Video downloaded to: $downloadPath');
      } else {
        print('Failed to get video URL or generation failed.');
      }
    }

    print('Test sequence completed successfully.');
  } catch (e, stack) {
    print('Error: $e');
    print(stack);
  } finally {
    automation.close();
  }
}

class FlowUiAutomation {
  final int debugPort;
  WebSocketChannel? ws;
  Stream<dynamic>? _broadcastStream;
  int msgId = 0;
  List<Map<String, dynamic>> networkLogs = [];
  String? currentOperationName;
  String? currentSceneId;

  FlowUiAutomation({this.debugPort = 9222});

  Future<void> connect() async {
    try {
      final response = await http.get(Uri.parse('http://localhost:$debugPort/json'));
      final tabs = jsonDecode(response.body) as List;

      Map<String, dynamic>? targetTab;
      // Look for the Flow tab
      for (var tab in tabs) {
        final url = (tab['url'] as String);
        if (url.contains('labs.google/fx/tools/flow')) {
          targetTab = tab as Map<String, dynamic>;
          break;
        }
      }

      if (targetTab == null) {
        throw Exception('No VideoFX Flow tab found! Please open https://labs.google/fx/tools/flow');
      }

      final wsUrl = targetTab['webSocketDebuggerUrl'] as String;
      ws = WebSocketChannel.connect(Uri.parse(wsUrl));
      _broadcastStream = ws!.stream.asBroadcastStream();
      
      // Enable Page domain events
      await sendCommand('Page.enable');
    } catch (e) {
      throw Exception('Failed to connect to Chrome: $e');
    }
  }

  Future<void> enableNetworkMonitoring() async {
    print('Enabling network monitoring...');
    
    // Enable Network domain
    await sendCommand('Network.enable');
    
    // Listen to network events
    _broadcastStream!.listen((message) {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final method = data['method'] as String?;
      
      if (method == 'Network.responseReceived') {
        final params = data['params'] as Map<String, dynamic>;
        final response = params['response'] as Map<String, dynamic>;
        final url = response['url'] as String;
        
        // Track video generation endpoints
        if (url.contains('batchAsyncGenerateVideoText') || 
            url.contains('batchCheckAsyncVideoGenerationStatus')) {
          final requestId = params['requestId'] as String;
          networkLogs.add({
            'type': 'response',
            'url': url,
            'requestId': requestId,
            'timestamp': DateTime.now().toIso8601String(),
          });
          
          // Get response body
          _getResponseBody(requestId);
        }
      }
    });
  }

  Future<void> _getResponseBody(String requestId) async {
    try {
      final result = await sendCommand('Network.getResponseBody', {'requestId': requestId});
      if (result['result'] != null) {
        final body = result['result']['body'] as String?;
        if (body != null) {
          try {
            final jsonBody = jsonDecode(body) as Map<String, dynamic>;
            
            // Check if this is the initial generation response
            if (jsonBody.containsKey('operations')) {
              final operations = jsonBody['operations'] as List;
              if (operations.isNotEmpty) {
                final operation = operations[0] as Map<String, dynamic>;
                final op = operation['operation'] as Map<String, dynamic>?;
                if (op != null && op.containsKey('name')) {
                  currentOperationName = op['name'] as String;
                  currentSceneId = operation['sceneId'] as String?;
                  print('Captured Operation Name: $currentOperationName');
                }
                
                // Check if video is complete
                final status = operation['status'] as String?;
                if (status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
                  print('Video generation completed!');
                }
              }
            }
            
            networkLogs.last['responseBody'] = jsonBody;
          } catch (e) {
            // Not JSON or parsing failed
          }
        }
      }
    } catch (e) {
      // Ignore errors in getting response body
    }
  }

  Future<String?> waitForVideoCompletion({int maxWaitSeconds = 300}) async {
    print('Waiting for video completion (max ${maxWaitSeconds}s)...');
    
    // Wait a bit for the initial generation request to complete and network logs to populate
    await Future.delayed(Duration(seconds: 8));
    
    // Try to extract operation name from network logs
    if (currentOperationName == null) {
      print('Searching network logs for operation name...');
      for (var log in networkLogs.reversed) {
        if (log['responseBody'] != null) {
          final body = log['responseBody'] as Map<String, dynamic>;
          if (body.containsKey('operations')) {
            final operations = body['operations'] as List;
            if (operations.isNotEmpty) {
              final operation = operations[0] as Map<String, dynamic>;
              final op = operation['operation'] as Map<String, dynamic>?;
              if (op != null && op.containsKey('name')) {
                currentOperationName = op['name'] as String;
                currentSceneId = operation['sceneId'] as String?;
                print('Found operation name in logs: $currentOperationName');
                break;
              }
            }
          }
        }
      }
    }
    
    if (currentOperationName == null) {
      print('No operation name found. Trying DOM inspection...');
      // Fallback: try to extract from page
      final operationFromPage = await executeJs('''
        (function() {
          // Try multiple strategies to find the operation name
          
          // Strategy 1: Look in window.__INITIAL_STATE__ or similar
          if (window.__INITIAL_STATE__) {
            const state = window.__INITIAL_STATE__;
            if (state.operations && state.operations.length > 0) {
              return state.operations[0].operation?.name;
            }
          }
          
          // Strategy 2: Find the most recent video card and extract from its data
          const videoContainers = document.querySelectorAll('[class*="video"]');
          for (let container of videoContainers) {
            const opName = container.getAttribute('data-operation') || 
                          container.getAttribute('data-operation-name');
            if (opName) return opName;
          }
          
          return null;
        })()
      ''');
      
      if (operationFromPage != null && operationFromPage != '') {
        currentOperationName = operationFromPage as String;
        print('Found operation name from page: $currentOperationName');
      }
    }
    
    // Poll for completion by checking the DOM for video elements
    final startTime = DateTime.now();
    String? lastStatus;
    
    while (DateTime.now().difference(startTime).inSeconds < maxWaitSeconds) {
      // Check status via JavaScript by monitoring the page state
      final result = await executeJs('''
        (async function() {
          // Look for completed video cards with download buttons
          const videoCards = document.querySelectorAll('video');
          if (videoCards.length > 0) {
            // Find the most recent video element
            const video = videoCards[videoCards.length - 1];
            const src = video.src || video.querySelector('source')?.src;
            if (src && src.includes('storage.googleapis.com')) {
              return {status: 'complete', url: src};
            }
          }
          
          // Check for generation status text
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
          print('Status: $status');
          lastStatus = status;
        }
        
        if (status == 'complete' && url != null && url.isNotEmpty) {
          print('Video URL found: $url');
          return url;
        }
        
        if (status == 'failed') {
          print('Video generation failed.');
          return null;
        }
      }
      
      final elapsed = DateTime.now().difference(startTime).inSeconds;
      if (elapsed % 10 == 0) {
        print('Still waiting... (${elapsed}s elapsed)');
      }
      
      await Future.delayed(Duration(seconds: 5));
    }
    
    print('Timeout waiting for video completion.');
    return null;
  }

  Future<void> downloadVideo(String videoUrl, String outputPath) async {
    print('Downloading video from: $videoUrl');
    
    try {
      final response = await http.get(Uri.parse(videoUrl));
      
      if (response.statusCode == 200) {
        final file = File(outputPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
        print('Downloaded ${response.bodyBytes.length} bytes');
      } else {
        throw Exception('Download failed with status: ${response.statusCode}');
      }
    } catch (e) {
      print('Download error: $e');
      rethrow;
    }
  }

  /// Configure video generation settings (aspect ratio, model, number of videos)
  Future<void> configureSettings({
    AspectRatio? aspectRatio,
    VeoModel? model,
    int? numberOfVideos,
  }) async {
    print('Configuring video settings...');
    
    // First, open the settings panel by clicking the Settings button
    await _openSettingsPanel();
    
    // Wait for panel to open
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
    
    // Close settings panel (click outside or press Escape)
    await executeJs('document.activeElement?.blur()');
    
    print('Settings configured successfully.');
  }

  Future<void> _openSettingsPanel() async {
    final jsCode = '''
    (function() {
      // Find the Settings button (contains "tune" icon or "Settings" text)
      const buttons = Array.from(document.querySelectorAll('button'));
      const settingsBtn = buttons.find(b => 
        b.querySelector('i')?.textContent === 'tune' || 
        b.textContent.includes('Settings')
      );
      
      if (settingsBtn) {
        settingsBtn.click();
        return true;
      }
      return false;
    })()
    ''';
    
    final clicked = await executeJs(jsCode);
    if (clicked != true) {
      throw Exception('Could not find Settings button');
    }
    print('Opened settings panel.');
  }

  Future<void> _setAspectRatio(AspectRatio ratio) async {
    print('Setting aspect ratio to: ${ratio.label}');
    
    final jsCode = '''
    (async function() {
      // Find the Aspect Ratio combobox
      const comboboxes = Array.from(document.querySelectorAll('button[role="combobox"]'));
      const ratioBtn = comboboxes.find(cb => {
        const parent = cb.closest('[class*="field"]') || cb.parentElement;
        return parent && parent.textContent.includes('Aspect Ratio');
      });
      
      if (!ratioBtn) return 'COMBOBOX_NOT_FOUND';
      
      // Click to open dropdown
      ratioBtn.click();
      
      // Wait for options to appear
      await new Promise(r => setTimeout(r, 300));
      
      // Find and click the target option
      const options = Array.from(document.querySelectorAll('[role="option"]'));
      const targetOption = options.find(opt => opt.textContent.includes('${ratio.label}'));
      
      if (!targetOption) return 'OPTION_NOT_FOUND';
      
      targetOption.click();
      return 'SUCCESS';
    })()
    ''';
    
    final result = await executeJs(jsCode);
    if (result != 'SUCCESS') {
      print('Warning: Failed to set aspect ratio. Result: $result');
    }
  }

  Future<void> _setModel(VeoModel model) async {
    print('Setting model to: ${model.label}');
    
    final jsCode = '''
    (async function() {
      // Find the Model combobox
      const comboboxes = Array.from(document.querySelectorAll('button[role="combobox"]'));
      const modelBtn = comboboxes.find(cb => {
        const parent = cb.closest('[class*="field"]') || cb.parentElement;
        return parent && parent.textContent.includes('Model');
      });
      
      if (!modelBtn) return 'COMBOBOX_NOT_FOUND';
      
      // Click to open dropdown
      modelBtn.click();
      
      // Wait for options to appear
      await new Promise(r => setTimeout(r, 300));
      
      // Find and click the target option
      const options = Array.from(document.querySelectorAll('[role="option"]'));
      const targetOption = options.find(opt => opt.textContent.includes('${model.label}'));
      
      if (!targetOption) return 'OPTION_NOT_FOUND';
      
      targetOption.click();
      return 'SUCCESS';
    })()
    ''';
    
    final result = await executeJs(jsCode);
    if (result != 'SUCCESS') {
      print('Warning: Failed to set model. Result: $result');
    }
  }

  Future<void> _setNumberOfVideos(int count) async {
    if (count < 1 || count > 4) {
      throw ArgumentError('Number of videos must be between 1 and 4');
    }
    
    print('Setting number of videos to: $count');
    
    final jsCode = '''
    (async function() {
      // Find the Outputs per prompt combobox
      const comboboxes = Array.from(document.querySelectorAll('button[role="combobox"]'));
      const outputBtn = comboboxes.find(cb => {
        const parent = cb.closest('[class*="field"]') || cb.parentElement;
        return parent && (parent.textContent.includes('Outputs') || parent.textContent.includes('per prompt'));
      });
      
      if (!outputBtn) return 'COMBOBOX_NOT_FOUND';
      
      // Click to open dropdown
      outputBtn.click();
      
      // Wait for options to appear
      await new Promise(r => setTimeout(r, 300));
      
      // Find and click the target option
      const options = Array.from(document.querySelectorAll('[role="option"]'));
      const targetOption = options.find(opt => opt.textContent.trim() === '$count');
      
      if (!targetOption) return 'OPTION_NOT_FOUND';
      
      targetOption.click();
      return 'SUCCESS';
    })()
    ''';
    
    final result = await executeJs(jsCode);
    if (result != 'SUCCESS') {
      print('Warning: Failed to set number of videos. Result: $result');
    }
  }


  Future<String> getCurrentUrl() async {
    final result = await executeJs('window.location.href');
    return result as String;
  }

  Future<void> createNewProject() async {
    print('Looking for "New project" button...');
    
    // JS to find the button safely
    final jsCode = '''
    (function() {
      const buttons = Array.from(document.querySelectorAll('button'));
      // Find button containing "New project" text
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
      print('Clicked "New project".');
    } else {
      // Fallback: try the specific selector if generic text search fails
      // Selector found by inspection: .sc-c177465c-1.hVamcH.sc-a38764c7-0.fXsrxE
      // Note: Classes might be unstable, so warning logged.
      print('Could not find "New project" by text. Trying CSS selector...');
      final clickedSelector = await executeJs('''
        (function() {
          const btn = document.querySelector('.sc-a38764c7-0'); // Partial match on the card class
          if (btn) { btn.click(); return true; }
          return false; 
        })()
      ''');
      
      if (clickedSelector != true) {
        throw Exception('Could not find "New project" button.');
      }
    }
  }

  Future<void> generateVideo({required String prompt}) async {
    print('Preparing to generate video with prompt: "$prompt"');

    // 1. Find the Text Area (ID: PINHOLE_TEXT_AREA_ELEMENT_ID)
    print('Waiting for text area...');
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

    // 2. Focus and Type Prompt using CDP (simulates real user input)
    // This is much more reliable for enabling buttons in modern frameworks
    await executeJs("document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID').focus()");
    
    // Select all text first (ctrl+a) to overwrite if needed, or just clear
    await executeJs("document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID').value = ''");
    
    // Use Input.insertText to simulate typing
    await sendCommand('Input.insertText', {'text': prompt});
    
    // Dispatch input event just in case, to be safe
    final triggerEvents = '''
    (function() {
      const ta = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
      ta.dispatchEvent(new Event('input', { bubbles: true }));
      ta.dispatchEvent(new Event('change', { bubbles: true }));
    })()
    ''';
    await executeJs(triggerEvents);
    print('Prompt entered via CDP.');

    await Future.delayed(Duration(seconds: 2)); // Wait for validtion

    // 3. Find and Click Generate Button
    // We look for the button with the arrow icon or "Create" text next to the textarea
    print('Looking for "Create" button...');
    final clickGenerateJs = '''
    (function() {
      // Strategy 1: Look for the specific button class near the textarea container
      // The generate button is often a circular button with an arrow
      const buttons = Array.from(document.querySelectorAll('button'));
      
      // Look for a button that contains an arrow icon (material symbol often used)
      // or has "Create" text if expanded
      const generateBtn = buttons.find(b => 
        b.textContent.includes('arrow_forward') || 
        b.querySelector('i')?.textContent === 'arrow_forward' ||
        b.getAttribute('aria-label') === 'Generate'
      );
      
      if (generateBtn) {
        if (generateBtn.disabled) return 'DISABLED';
        generateBtn.click();
        return 'CLICKED';
      }
      return 'NOT_FOUND';
    })()
    ''';

    final result = await executeJs(clickGenerateJs);
    if (result == 'CLICKED') {
      print('Generate button clicked!');
    } else if (result == 'DISABLED') {
      print('Generate button is disabled. Maybe the prompt wasn\'t accepted?');
    } else {
      print('Generate button not found. Dumping buttons for debug...');
      // specific selector fallback: .sc-c177465c-1.gdArnN.sc-408537d4-2.gdXWm
      await executeJs("document.querySelector('.sc-408537d4-2')?.click()");
    }
  }

  // --- CDP Helper Methods ---

  Future<dynamic> executeJs(String expression) async {
    final result = await sendCommand('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    return result['result']?['result']?['value'];
  }

  Future<Map<String, dynamic>> sendCommand(String method, [Map<String, dynamic>? params]) async {
    if (ws == null) throw Exception('Not connected');
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
    });

    return completer.future.timeout(const Duration(seconds: 10));
  }

  void close() {
    ws?.sink.close();
  }
}
