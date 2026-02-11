import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// You will need to add this dependency to your pubspec.yaml:
// web_socket_channel: ^3.0.0 (or latest)
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'utils/app_logger.dart';

/// Configuration options for Lyria music generation.
class LyriaConfig {
  /// Beats per minute. Range [60, 200].
  final int? bpm;

  /// Variance in audio generation. Higher values = higher variance. Range [0.0, 3.0].
  final double? temperature;

  /// Top-k sampling. Range [1, 1000].
  final int? topK;

  /// Random seed for generation.
  final int? seed;

  /// How closely the model follows prompts. Range [0.0, 6.0].
  final double? guidance;

  /// Density of sounds. Range [0.0, 1.0].
  final double? density;

  /// Brightness of the music. Range [0.0, 1.0].
  final double? brightness;

  /// Scale of the music (e.g., 'C_MAJOR_A_MINOR', 'D_MAJOR_B_MINOR').
  final String? scale;

  /// Mute bass track.
  final bool? muteBass;

  /// Mute drums track.
  final bool? muteDrums;

  /// Play only bass and drums.
  final bool? onlyBassAndDrums;

  /// Music generation mode (e.g., 'QUALITY').
  final String? musicGenerationMode;

  LyriaConfig({
    this.bpm,
    this.temperature,
    this.topK,
    this.seed,
    this.guidance,
    this.density,
    this.brightness,
    this.scale,
    this.muteBass,
    this.muteDrums,
    this.onlyBassAndDrums,
    this.musicGenerationMode,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> json = {};
    if (bpm != null) json['bpm'] = bpm;
    if (temperature != null) json['temperature'] = temperature;
    if (topK != null) json['topK'] = topK;
    if (seed != null) json['seed'] = seed;
    if (guidance != null) json['guidance'] = guidance;
    if (density != null) json['density'] = density;
    if (brightness != null) json['brightness'] = brightness;
    if (scale != null) json['scale'] = scale;
    if (muteBass != null) json['muteBass'] = muteBass;
    if (muteDrums != null) json['muteDrums'] = muteDrums;
    if (onlyBassAndDrums != null) json['onlyBassAndDrums'] = onlyBassAndDrums;
    if (musicGenerationMode != null) json['musicGenerationMode'] = musicGenerationMode;
    return json;
  }
}

class LyriaMusicService {
  WebSocketChannel? _channel;
  final StreamController<Uint8List> _audioStreamController = StreamController<Uint8List>.broadcast();
  final String _baseUrl = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateMusic';
  
  Completer<void>? _setupCompleter;
  bool _isConnected = false;

  /// Stream of raw PCM 16-bit 48kHz audio bytes.
  Stream<Uint8List> get audioStream => _audioStreamController.stream;

  bool get isConnected => _isConnected;

  /// Connects to the Lyria WebSocket endpoint with the given API key.
  Future<void> connect(String apiKey) async {
    if (_isConnected) return;
    
    // Sanitize API Key
    final cleanKey = apiKey.replaceAll(RegExp(r"[^a-zA-Z0-9_\-]"), "");
    print('[Lyria] Connecting with API key: ${cleanKey.substring(0, 10)}...');

    final uri = Uri.parse('$_baseUrl?key=$cleanKey');
    print('[Lyria] WebSocket URI: ${uri.toString().replaceAll(cleanKey, '***')}');
    
    try {
      _channel = WebSocketChannel.connect(uri);
      _setupCompleter = Completer<void>();
      
      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onError: (error) {
          print('[Lyria] WebSocket Error: $error');
          AppLogger.e('WebSocket Error: $error');
          _cleanup();
        },
        onDone: () {
          print('[Lyria] WebSocket Connection Closed');
          AppLogger.i('WebSocket Connection Closed');
          _cleanup();
        },
      );

      // Perform Handshake
      print('[Lyria] Sending handshake...');
      await _sendHandshake();
      
      // Wait for setup confirmation with timeout
      print('[Lyria] Waiting for setup confirmation...');
      await _setupCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          print('[Lyria] Setup timeout after 30 seconds');
          throw Exception('Connection setup timeout');
        },
      );
      _isConnected = true;
      print('[Lyria] Connected and Setup Complete!');
      AppLogger.i('Lyria Service: Connected and Setup Complete');

    } catch (e) {
      print('[Lyria] Connection error: $e');
      _cleanup();
      rethrow;
    }
  }

  /// Sets the text prompt for music generation.
  Future<void> setPrompt(String text, {double weight = 1.0}) async {
    final msg = {
      "clientContent": {
        "weightedPrompts": [
          {
            "text": text,
            "weight": weight
          }
        ]
      }
    };
    _sendJson(msg);
  }

  /// Updates the music generation configuration.
  Future<void> setConfig(LyriaConfig config) async {
    final msg = {
      "musicGenerationConfig": config.toJson()
    };
    _sendJson(msg);
  }

  /// Sends the PLAY command to start the music stream.
  Future<void> play() async {
    _sendControl("PLAY");
  }

  /// Sends the PAUSE command.
  Future<void> pause() async {
    _sendControl("PAUSE");
  }

  /// Sends the STOP command.
  Future<void> stop() async {
    _sendControl("STOP");
  }

  /// Resets the context (clears history but keeps prompt).
  Future<void> resetContext() async {
    _sendControl("RESET_CONTEXT");
  }

  /// Closes the connection.
  void dispose() {
    _channel?.sink.close(status.goingAway);
    _cleanup();
  }

  // --- Private Helpers ---

  Future<void> _sendHandshake() async {
    final msg = {
      "setup": {
        "model": "models/lyria-realtime-exp"
      }
    };
    _sendJson(msg);
  }

  void _sendControl(String command) {
    if (!_isConnected && command != 'PLAY') return; // Basic guard
    final msg = {
      "playbackControl": command
    };
    _sendJson(msg);
  }

  void _sendJson(Map<String, dynamic> data) {
    if (_channel == null) {
      print('Error: WebSocket is not connected.');
      return;
    }
    final jsonStr = jsonEncode(data);
    _channel!.sink.add(jsonStr);
  }

  void _handleMessage(dynamic message) {
    String? jsonString;

    if (message is String) {
      jsonString = message;
    } else if (message is List<int>) {
      // Server sends binary frames (as seen in Python b'...' output)
      try {
        jsonString = utf8.decode(message);
      } catch (e) {
        print('Error decoding binary message: $e');
        return;
      }
    } else {
      print('Unknown message type: ${message.runtimeType}');
      return;
    }

    try {
      final data = jsonDecode(jsonString) as Map<String, dynamic>;

      // Check for Setup Complete
      if (data.containsKey('setupComplete')) {
        print("Received setupComplete");
        if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
          _setupCompleter!.complete();
        }
      }

      // Check for Audio Content
      if (data.containsKey('serverContent')) {
        final serverContent = data['serverContent'];
        if (serverContent != null && serverContent['audioChunks'] != null) {
          final chunks = serverContent['audioChunks'] as List;
          for (var chunk in chunks) {
            if (chunk['data'] != null) {
              final String base64Data = chunk['data'];
              final Uint8List bytes = base64Decode(base64Data);
              _audioStreamController.add(bytes);
            }
          }
        }
      }

    } catch (e) {
      print('Error parsing message: $e\nMessage was: $jsonString');
    }
  }

  void _cleanup() {
    _isConnected = false;
    _channel = null;
    if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
      _setupCompleter!.completeError("Connection closed before setup complete");
    }
  }
}
