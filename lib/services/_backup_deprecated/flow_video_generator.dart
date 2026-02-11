/// Flow Video Generator - Dart CDP Client
/// 
/// This library provides a Dart interface to control the Flow Video Generator
/// Chrome extension via CDP (Chrome DevTools Protocol).
/// 
/// Usage:
/// ```dart
/// final generator = FlowVideoGenerator();
/// await generator.connect();
/// final result = await generator.generateVideo('A sunset over the ocean');
/// print('Video URL: ${result.videoUrl}');
/// ```

library flow_video_generator;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Configuration for the Flow Video Generator
class FlowGeneratorConfig {
  /// CDP port to connect to (default: 9222)
  final int cdpPort;
  
  /// Host for CDP connection (default: localhost)
  final String cdpHost;
  
  /// Timeout for video generation in seconds (default: 300)
  final int generationTimeoutSeconds;
  
  /// Poll interval for checking generation status in milliseconds
  final int pollIntervalMs;

  const FlowGeneratorConfig({
    this.cdpPort = 9222,
    this.cdpHost = 'localhost',
    this.generationTimeoutSeconds = 300,
    this.pollIntervalMs = 2000,
  });
}

/// Result of a video generation request
class GenerationResult {
  final String status;
  final String? videoUrl;
  final String? thumbnailUrl;
  final String? errorMessage;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;

  GenerationResult({
    required this.status,
    this.videoUrl,
    this.thumbnailUrl,
    this.errorMessage,
    this.metadata,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isSuccess => status == 'complete' && videoUrl != null;
  bool get isError => status == 'error';
  bool get isPending => status == 'pending' || status == 'generating';

  factory GenerationResult.fromJson(Map<String, dynamic> json) {
    return GenerationResult(
      status: json['status'] ?? 'unknown',
      videoUrl: json['videoUrl'],
      thumbnailUrl: json['thumbnailUrl'],
      errorMessage: json['error'] ?? json['errorMessage'],
      metadata: json['metadata'],
    );
  }

  Map<String, dynamic> toJson() => {
    'status': status,
    'videoUrl': videoUrl,
    'thumbnailUrl': thumbnailUrl,
    'errorMessage': errorMessage,
    'metadata': metadata,
    'timestamp': timestamp.toIso8601String(),
  };
}

/// Options for video generation
class GenerationOptions {
  /// Text prompt for video generation
  final String prompt;
  
  /// Aspect ratio: '16:9', '9:16', or '1:1'
  final String aspectRatio;
  
  /// Model: 'Veo 3.1 - Fast' or 'Veo 3.1 - Quality'
  final String model;
  
  /// Number of variations to generate
  final int outputCount;
  
  /// Optional project ID to use
  final String? projectId;

  const GenerationOptions({
    required this.prompt,
    this.aspectRatio = '16:9',
    this.model = 'Veo 3.1 - Fast',
    this.outputCount = 1,
    this.projectId,
  });

  Map<String, dynamic> toJson() => {
    'prompt': prompt,
    'aspectRatio': aspectRatio,
    'model': model,
    'outputCount': outputCount,
    'projectId': projectId,
  };
}

/// CDP Session information
class CdpSession {
  final String targetId;
  final String sessionId;
  final WebSocket webSocket;

  CdpSession({
    required this.targetId,
    required this.sessionId,
    required this.webSocket,
  });
}

/// Main class for controlling the Flow Video Generator extension via CDP
class FlowVideoGenerator {
  final FlowGeneratorConfig config;
  
  WebSocket? _webSocket;
  String? _targetId;
  int _messageId = 0;
  final Map<int, Completer<dynamic>> _pendingRequests = {};
  bool _isConnected = false;
  
  /// Stream controller for generation progress updates
  final _progressController = StreamController<Map<String, dynamic>>.broadcast();
  
  /// Stream of generation progress updates
  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  FlowVideoGenerator({this.config = const FlowGeneratorConfig()});

  /// Check if connected to Chrome via CDP
  bool get isConnected => _isConnected;

  /// Connect to Chrome browser via CDP
  Future<void> connect() async {
    try {
      // Get available targets
      final response = await http.get(
        Uri.parse('http://${config.cdpHost}:${config.cdpPort}/json'),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to connect to Chrome CDP: ${response.statusCode}');
      }

      final targets = jsonDecode(response.body) as List;
      
      // Find Google Flow tab
      final flowTarget = targets.firstWhere(
        (t) => (t['url'] as String).contains('labs.google/fx/tools/flow'),
        orElse: () => null,
      );

      if (flowTarget == null) {
        throw Exception('No Google Flow tab found. Please open https://labs.google/fx/tools/flow/');
      }

      _targetId = flowTarget['id'];
      final wsUrl = flowTarget['webSocketDebuggerUrl'];

      // Connect to WebSocket
      _webSocket = await WebSocket.connect(wsUrl);
      _isConnected = true;

      // Listen for messages
      _webSocket!.listen(
        _handleMessage,
        onError: (error) {
          print('WebSocket error: $error');
          _isConnected = false;
        },
        onDone: () {
          print('WebSocket closed');
          _isConnected = false;
        },
      );

      print('[FlowVideoGenerator] Connected to Chrome CDP');
      print('[FlowVideoGenerator] Target: ${flowTarget['title']}');
    } catch (e) {
      throw Exception('Failed to connect to Chrome CDP: $e');
    }
  }

  /// Disconnect from Chrome CDP
  Future<void> disconnect() async {
    await _webSocket?.close();
    _webSocket = null;
    _isConnected = false;
    print('[FlowVideoGenerator] Disconnected from Chrome CDP');
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic message) {
    final data = jsonDecode(message as String);
    
    if (data['id'] != null) {
      final completer = _pendingRequests.remove(data['id']);
      if (completer != null) {
        if (data['error'] != null) {
          completer.completeError(Exception(data['error']['message']));
        } else {
          completer.complete(data['result']);
        }
      }
    }

    // Handle events
    if (data['method'] == 'Runtime.consoleAPICalled') {
      final args = data['params']['args'] as List?;
      if (args != null && args.isNotEmpty) {
        final message = args.map((a) => a['value']?.toString() ?? '').join(' ');
        if (message.contains('[FlowGenerator]')) {
          print(message);
        }
      }
    }
  }

  /// Send CDP command
  Future<dynamic> _sendCommand(String method, [Map<String, dynamic>? params]) async {
    if (!_isConnected) {
      throw Exception('Not connected to Chrome CDP');
    }

    final id = ++_messageId;
    final completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    final message = {
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };

    _webSocket!.add(jsonEncode(message));

    return completer.future.timeout(
      Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw TimeoutException('CDP command timed out: $method');
      },
    );
  }

  /// Execute JavaScript in the page context
  Future<dynamic> _executeScript(String expression) async {
    final result = await _sendCommand('Runtime.evaluate', {
      'expression': expression,
      'awaitPromise': true,
      'returnByValue': true,
    });

    if (result['exceptionDetails'] != null) {
      throw Exception('Script execution failed: ${result['exceptionDetails']}');
    }

    return result['result']['value'];
  }

  /// Generate a video with the given prompt
  Future<GenerationResult> generateVideo(GenerationOptions options) async {
    if (!_isConnected) {
      throw Exception('Not connected to Chrome CDP. Call connect() first.');
    }

    print('[FlowVideoGenerator] Starting generation: ${options.prompt}');

    // Enable Runtime to receive console messages
    await _sendCommand('Runtime.enable');

    // Execute generation script
    final script = '''
      (async () => {
        if (!window.flowGenerator) {
          return { status: 'error', error: 'Extension not loaded' };
        }
        
        try {
          const result = await window.flowGenerator.generate(
            ${jsonEncode(options.prompt)},
            ${jsonEncode({
              'aspectRatio': options.aspectRatio,
              'model': options.model,
              'outputCount': options.outputCount,
              'projectId': options.projectId,
            })}
          );
          return result;
        } catch (error) {
          return { status: 'error', error: error.message };
        }
      })()
    ''';

    // Start generation
    final startResult = await _executeScript(script);
    
    if (startResult is Map && startResult['status'] == 'error') {
      return GenerationResult(
        status: 'error',
        errorMessage: startResult['error'],
      );
    }

    // Poll for completion
    final stopwatch = Stopwatch()..start();
    
    while (stopwatch.elapsed.inSeconds < config.generationTimeoutSeconds) {
      await Future.delayed(Duration(milliseconds: config.pollIntervalMs));

      final status = await _executeScript('''
        (() => {
          if (!window.flowGenerator) return { status: 'error', error: 'Extension not loaded' };
          return window.flowGenerator.getStatus();
        })()
      ''');

      if (status is Map) {
        _progressController.add(Map<String, dynamic>.from(status));

        if (status['isGenerating'] == false && status['generationCount'] != null) {
          // Check for video URL
          final videoUrl = await _executeScript('''
            (() => {
              if (!window.flowGenerator) return null;
              return window.flowGenerator.findVideoUrl();
            })()
          ''');

          if (videoUrl != null) {
            return GenerationResult(
              status: 'complete',
              videoUrl: videoUrl,
            );
          }
        }
      }

      final progress = (stopwatch.elapsed.inSeconds / config.generationTimeoutSeconds * 100).clamp(0, 95);
      print('[FlowVideoGenerator] Progress: ${progress.toStringAsFixed(1)}%');
    }

    return GenerationResult(
      status: 'timeout',
      errorMessage: 'Video generation timed out after ${config.generationTimeoutSeconds} seconds',
    );
  }

  /// Generate a video with just a prompt string
  Future<GenerationResult> generate(String prompt, {
    String aspectRatio = '16:9',
    String model = 'Veo 3.1 - Fast',
  }) {
    return generateVideo(GenerationOptions(
      prompt: prompt,
      aspectRatio: aspectRatio,
      model: model,
    ));
  }

  /// Get current generation status
  Future<Map<String, dynamic>> getStatus() async {
    if (!_isConnected) {
      return {'status': 'disconnected'};
    }

    final result = await _executeScript('''
      (() => {
        if (!window.flowGenerator) return { status: 'extension_not_loaded' };
        return window.flowGenerator.getStatus();
      })()
    ''');

    return Map<String, dynamic>.from(result ?? {});
  }

  /// List all generations from current session
  Future<List<Map<String, dynamic>>> listGenerations() async {
    if (!_isConnected) {
      return [];
    }

    final result = await _executeScript('''
      (() => {
        if (!window.flowGenerator) return [];
        return window.flowGenerator.listGenerations();
      })()
    ''');

    if (result is List) {
      return result.map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }

  /// Download a generated video to a file
  Future<File> downloadVideo(String videoUrl, String outputPath) async {
    final response = await http.get(Uri.parse(videoUrl));
    
    if (response.statusCode != 200) {
      throw Exception('Failed to download video: ${response.statusCode}');
    }

    final file = File(outputPath);
    await file.writeAsBytes(response.bodyBytes);
    
    print('[FlowVideoGenerator] Video downloaded to: $outputPath');
    return file;
  }

  /// Open Google Flow in a new tab
  Future<void> openFlow({String? projectId}) async {
    final url = projectId != null
        ? 'https://labs.google/fx/tools/flow/project/$projectId'
        : 'https://labs.google/fx/tools/flow/';
    
    await _sendCommand('Target.createTarget', {'url': url});
    print('[FlowVideoGenerator] Opened Google Flow');
  }

  /// Dispose resources
  void dispose() {
    _progressController.close();
    disconnect();
  }
}

/// Extension for batch video generation
extension BatchGeneration on FlowVideoGenerator {
  /// Generate multiple videos in sequence
  Future<List<GenerationResult>> generateBatch(
    List<GenerationOptions> options, {
    Duration delayBetween = const Duration(seconds: 5),
  }) async {
    final results = <GenerationResult>[];
    
    for (int i = 0; i < options.length; i++) {
      print('[FlowVideoGenerator] Batch ${i + 1}/${options.length}');
      
      final result = await generateVideo(options[i]);
      results.add(result);
      
      if (i < options.length - 1) {
        await Future.delayed(delayBetween);
      }
    }
    
    return results;
  }
}
