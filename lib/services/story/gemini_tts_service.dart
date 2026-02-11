import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../gemini_key_service.dart';

/// Gemini TTS Service using Google's Generative Language API
class GeminiTtsService {
  List<String> _apiKeys = [];
  int _currentKeyIndex = 0;

  /// Load API keys from gemini_api_keys.txt
  Future<void> loadApiKeys() async {
    try {
      File keysFile;
      if (Platform.isAndroid) {
        final dir = Directory('/storage/emulated/0/veo3');
        // No create here, we expect Screen to create it or user to provide it? 
        // Better to check if exists, if not, maybe try fallback? No, consistency is key.
        keysFile = File(path.join(dir.path, 'gemini_api_keys.txt'));
      } else if (Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        keysFile = File(path.join(dir.path, 'gemini_api_keys.txt'));
      } else {
        final exePath = Platform.resolvedExecutable;
        final exeDir = File(exePath).parent.path;
        keysFile = File(path.join(exeDir, 'gemini_api_keys.txt'));
      }

      if (!await keysFile.exists()) {
        // Try global keys saved via GeminiKeyService
        final global = await GeminiKeyService.loadKeys();
        if (global.isNotEmpty) {
          _apiKeys = global.where((k) => k.trim().isNotEmpty).toList();
          print('[TTS] Loaded ${_apiKeys.length} API keys from GeminiKeyService (global)');
        } else {
          throw Exception('gemini_api_keys.txt not found at: ${keysFile.path}');
        }
      } else {
        final content = await keysFile.readAsString();
        _apiKeys = content
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty && !line.startsWith('#'))
            .toList();

        if (_apiKeys.isEmpty) {
          // fallback to global keys
          final global = await GeminiKeyService.loadKeys();
          if (global.isNotEmpty) {
            _apiKeys = global.where((k) => k.trim().isNotEmpty).toList();
            print('[TTS] Loaded ${_apiKeys.length} API keys from GeminiKeyService (global)');
          } else {
            throw Exception('No API keys found in gemini_api_keys.txt');
          }
        } else {
          print('[TTS] Loaded ${_apiKeys.length} API keys');
        }
      }
    } catch (e) {
      throw Exception('Failed to load API keys: $e');
    }
  }

  /// Get current API key (with rotation)
  String _getCurrentApiKey() {
    if (_apiKeys.isEmpty) {
      throw Exception('No API keys loaded');
    }
    final key = _apiKeys[_currentKeyIndex];
    _currentKeyIndex = (_currentKeyIndex + 1) % _apiKeys.length;
    return key;
  }

  /// Generate TTS audio file
  /// Returns true if successful, false otherwise
  Future<bool> generateTts({
    required String text,
    required String voiceModel,
    required String voiceStyle,
    required double speechRate,
    required String outputPath,
  }) async {
    const maxRetries = 3;
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        print('[TTS] Attempt $attempt/$maxRetries for: ${text.substring(0, text.length > 50 ? 50 : text.length)}...');
        
        final apiKey = _getCurrentApiKey();
        // Use the model found in Python code: gemini-2.5-flash-preview-tts
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent?key=$apiKey',
        );

        // Construct prompt with voice style
        // Based on Python implementation:
        // if "TRANSCRIPT" not in selected_style: final_content = f"{selected_style}\n\n#### TRANSCRIPT\n{text}"
        final prompt = (voiceStyle.contains('TRANSCRIPT')) 
            ? '$voiceStyle\n\n$text'
            : '$voiceStyle\n\n#### TRANSCRIPT\n$text';

        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'responseModalities': ['AUDIO'],
              'speechConfig': {
                'voiceConfig': {
                  'prebuiltVoiceConfig': {
                    'voiceName': voiceModel,
                  }
                }
              }
            },
          }),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          
          // data['candidates'][0]['content']['parts'][0]['inlineData']['data']
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates[0]['content'];
            final parts = content['parts'] as List?;
            
            if (parts != null && parts.isNotEmpty) {
              final audioData = parts[0]['inlineData']?['data'];
              
              if (audioData != null) {
                final pcmBytes = base64Decode(audioData);
                
                final outputFile = File(outputPath);
                await outputFile.parent.create(recursive: true);
                
                // Gemini apparantly returns raw PCM. We need to wrap it in a WAV header.
                // Defaults from Python code: 24kHz, 1 channel, 16-bit (2 bytes)
                await _writeWavFile(outputFile, pcmBytes);
                
                print('[TTS] ✓ Generated: $outputPath');
                return true;
              }
            }
          }
          
          throw Exception('No audio data in response: ${response.body}');
        } else {
          final errorBody = response.body;
          print('[TTS] API Error (${response.statusCode}): $errorBody');
          
          // Handle quota errors
          if (response.statusCode == 429) {
             print('[TTS] Quota exceeded. Rotating key...');
          }

          if (attempt < maxRetries) {
            await Future.delayed(Duration(seconds: 2 * attempt));
            continue;
          }
          
          return false;
        }
      } catch (e) {
        print('[TTS] Error on attempt $attempt: $e');
        
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: 2 * attempt));
          continue;
        }
        
        return false;
      }
    }
    
    return false;
  }

  /// Writes raw PCM data to a WAV file with correct header
  /// Matches Python's wave module behavior
  Future<void> _writeWavFile(File file, List<int> pcmData) async {
    if (await file.exists()) {
      await file.delete();
    }

    final int sampleRate = 24000;
    final int channels = 1;
    final int bitsPerSample = 16; // sample_width=2 in Python
    final int byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final int blockAlign = channels * (bitsPerSample ~/ 8); // 2 bytes
    
    // Ensure data alignment (RIFF chunks must be word-aligned)
    List<int> data = pcmData;
    if (data.length % 2 != 0) {
      data = [...pcmData, 0];
    }
    
    final int dataSize = data.length;
    final int riffSize = 36 + dataSize; 

    final buffer = ByteData(44);
    int offset = 0;

    // RIFF chunk
    _writeString(buffer, offset, 'RIFF'); offset += 4;
    buffer.setUint32(offset, riffSize, Endian.little); offset += 4;
    _writeString(buffer, offset, 'WAVE'); offset += 4;

    // fmt chunk
    _writeString(buffer, offset, 'fmt '); offset += 4;
    buffer.setUint32(offset, 16, Endian.little); offset += 4; // Subchunk1Size
    buffer.setUint16(offset, 1, Endian.little); offset += 2; // AudioFormat (1 = PCM)
    buffer.setUint16(offset, channels, Endian.little); offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little); offset += 4;
    buffer.setUint32(offset, byteRate, Endian.little); offset += 4;
    buffer.setUint16(offset, blockAlign, Endian.little); offset += 2;
    buffer.setUint16(offset, bitsPerSample, Endian.little); offset += 2;

    // data chunk
    _writeString(buffer, offset, 'data'); offset += 4;
    buffer.setUint32(offset, dataSize, Endian.little); offset += 4;

    final raf = await file.open(mode: FileMode.write);
    await raf.writeFrom(buffer.buffer.asUint8List());
    await raf.writeFrom(data);
    await raf.close();
    
    print('[TTS] Wrote WAV file: ${file.path} (Size: ${44 + dataSize} bytes)');
  }

  void _writeString(ByteData buffer, int offset, String text) {
    for (int i = 0; i < text.length; i++) {
      buffer.setUint8(offset + i, text.codeUnitAt(i));
    }
  }


  /// Get audio duration using ffprobe
  Future<double?> getDuration(String audioPath) async {
    try {
      // Get ffprobe from current folder
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent.path;
      final ffprobePath = path.join(exeDir, 'ffprobe.exe');
      
      final result = await Process.run(
        ffprobePath,
        [
          '-v',
          'error',
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          audioPath,
        ],
      );

      if (result.exitCode == 0) {
        final durationStr = result.stdout.toString().trim();
        return double.tryParse(durationStr);
      }
      
      return null;
    } catch (e) {
      print('[TTS] Error getting duration: $e');
      return null;
    }
  }
}
