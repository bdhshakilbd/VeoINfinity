import 'dart:convert';
import 'dart:io';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'gemini_key_service.dart';
import 'settings_service.dart';

/// Service to make direct calls to Google Gemini Official API
/// Supports multiple API keys with automatic rotation on failure/quota exceeded
class GeminiApiService {
  List<String> apiKeys = [];
  int _currentKeyIndex = 0;
  
  // Track failed keys to skip them temporarily
  final Map<String, DateTime> _failedKeys = {};
  static const Duration _failureCooldown = Duration(minutes: 5);
  
  // File path for saving API keys
  static const String keysFilePath = 'gemini_api_keys.txt';
  
  GeminiApiService({List<String>? keys}) {
    if (keys != null && keys.isNotEmpty) {
      apiKeys = keys.where((k) => k.trim().isNotEmpty).toList();
    }
  }
  
  void _log(String msg) {
    print('[GEMINI_SERVICE] $msg');
  }

  /// Load API keys - prioritizes SettingsService (SharedPreferences), then file, then GeminiKeyService
  static Future<GeminiApiService> loadFromFile() async {
    final service = GeminiApiService();
    
    // 1. First try SettingsService (SharedPreferences) - works in bundled apps
    try {
      await SettingsService.instance.load();
      final settingsKeys = SettingsService.instance.getGeminiKeys();
      if (settingsKeys.isNotEmpty) {
        service.apiKeys = settingsKeys.where((k) => k.trim().isNotEmpty && k.startsWith('AIza')).toList();
        print('[GEMINI] Loaded ${service.apiKeys.length} API keys from Settings');
        if (service.apiKeys.isNotEmpty) return service;
      }
    } catch (e) {
      print('[GEMINI] Could not load from Settings: $e');
    }
    
    // 2. Fallback to text file in current directory
    try {
      final file = File(keysFilePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        service.apiKeys = content
            .split('\n')
            .map((k) => k.trim())
            .where((k) => k.isNotEmpty && k.startsWith('AIza'))
            .toList();
        print('[GEMINI] Loaded ${service.apiKeys.length} API keys from file');
        if (service.apiKeys.isNotEmpty) return service;
      }
    } catch (e) {
      print('[GEMINI] Error loading API keys from file: $e');
    }
    
    // 3. Fallback to GeminiKeyService (Documents folder)
    try {
      if (service.apiKeys.isEmpty) {
        final globalKeys = await GeminiKeyService.loadKeys();
        if (globalKeys.isNotEmpty) {
          service.apiKeys = globalKeys.where((k) => k.trim().isNotEmpty).toList();
          print('[GEMINI] Loaded ${service.apiKeys.length} API keys from GeminiKeyService');
        }
      }
    } catch (e) {
      print('[GEMINI] Error loading from GeminiKeyService: $e');
    }
    
    return service;
  }
  
  /// Save API keys to file
  Future<void> saveToFile() async {
    try {
      final file = File(keysFilePath);
      await file.writeAsString(apiKeys.join('\n'));
      _log('Saved ${apiKeys.length} API keys to file');
    } catch (e) {
      _log('Error saving API keys: $e');
    }
  }
  
  /// Add API keys (parse from multi-line string)
  void addKeysFromText(String text) {
    final newKeys = text
        .split('\n')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty && k.startsWith('AIza'))
        .toList();
    
    // Add only new keys
    for (final key in newKeys) {
      if (!apiKeys.contains(key)) {
        apiKeys.add(key);
      }
    }
    _log('Added ${newKeys.length} keys, total: ${apiKeys.length}');
  }
  
  /// Get current API key
  String? get currentKey {
    if (apiKeys.isEmpty) return null;
    return apiKeys[_currentKeyIndex % apiKeys.length];
  }
  
  /// Get number of available keys
  int get keyCount => apiKeys.length;
  
  /// Rotate to next API key
  void _rotateToNextKey({String? failedKey}) {
    if (failedKey != null) {
      _failedKeys[failedKey] = DateTime.now();
    }
    
    if (apiKeys.isEmpty) return;
    
    // Try to find a non-failed key
    int attempts = 0;
    do {
      _currentKeyIndex = (_currentKeyIndex + 1) % apiKeys.length;
      attempts++;
      
      final key = apiKeys[_currentKeyIndex];
      final failTime = _failedKeys[key];
      
      // Check if this key has cooled down
      if (failTime != null) {
        if (DateTime.now().difference(failTime) > _failureCooldown) {
          _failedKeys.remove(key); // Cooldown expired, try again
          break;
        }
      } else {
        break; // Key hasn't failed
      }
    } while (attempts < apiKeys.length);
    
    _log('Rotated to key ${_currentKeyIndex + 1}/${apiKeys.length}');
  }
  
  /// Check if error is quota/rate limit related
  bool _isQuotaError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('quota') ||
           errorStr.contains('rate limit') ||
           errorStr.contains('resource exhausted') ||
           errorStr.contains('429') ||
           errorStr.contains('too many requests');
  }
  
  /// Convert JSON map to Schema object
  Schema _mapToSchema(Map<String, dynamic> schemaMap) {
    final typeStr = (schemaMap['type'] as String? ?? 'OBJECT').toUpperCase();
    SchemaType type;
    switch (typeStr) {
      case 'STRING': type = SchemaType.string; break;
      case 'NUMBER': type = SchemaType.number; break;
      case 'INTEGER': type = SchemaType.integer; break;
      case 'BOOLEAN': type = SchemaType.boolean; break;
      case 'ARRAY': type = SchemaType.array; break;
      default: type = SchemaType.object; break;
    }

    String? description = schemaMap['description'];
    bool nullable = schemaMap['nullable'] ?? false;

    if (type == SchemaType.array) {
      final itemsMap = schemaMap['items'] as Map<String, dynamic>?;
      return Schema.array(
         items: itemsMap != null ? _mapToSchema(itemsMap) : Schema.string(),
         description: description,
         nullable: nullable,
      );
    }

    if (type == SchemaType.object) {
       final properties = <String, Schema>{};
       if (schemaMap.containsKey('properties')) {
         final propsMap = schemaMap['properties'] as Map<String, dynamic>;
         propsMap.forEach((key, val) {
           properties[key] = _mapToSchema(val as Map<String, dynamic>);
         });
       }
       final requiredProps = (schemaMap['required'] as List?)?.cast<String>();
       
       return Schema.object(
         properties: properties,
         requiredProperties: requiredProps,
         description: description,
         nullable: nullable,
       );
    }
    
    switch(type) {
      case SchemaType.string: return Schema.string(description: description, nullable: nullable);
      case SchemaType.number: return Schema.number(description: description, nullable: nullable);
      case SchemaType.integer: return Schema.integer(description: description, nullable: nullable);
      case SchemaType.boolean: return Schema.boolean(description: description, nullable: nullable);
      default: return Schema.string(description: description, nullable: nullable);
    }
  }

  /// Generate text using Google Gemini Official API with automatic key rotation
  Future<String> generateText({
    required String prompt,
    required String model,
    Map<String, dynamic>? jsonSchema,
    Function(String chunk)? onChunk,
  }) async {
    // If no keys configured for this instance, try global keys saved via GeminiKeyService
    if (apiKeys.isEmpty) {
      try {
        final globalKeys = await GeminiKeyService.loadKeys();
        if (globalKeys.isNotEmpty) {
          apiKeys = globalKeys.where((k) => k.trim().isNotEmpty).toList();
        }
      } catch (e) {
        // ignore
      }
    }

    if (apiKeys.isEmpty) {
      throw Exception('No API keys configured. Please add your Gemini API keys.');
    }
    
    Exception? lastError;
    int maxRetries = apiKeys.length; // Try each key once
    
    for (int retry = 0; retry < maxRetries; retry++) {
      final apiKey = currentKey!;
      
      try {
        _log('Attempt ${retry + 1}/$maxRetries with key ${_currentKeyIndex + 1}');
        _log('Model: $model, Prompt: ${prompt.length} chars');
        
        // Build Schema if provided
        Schema? responseSchema;
        if (jsonSchema != null) {
          try {
            responseSchema = _mapToSchema(jsonSchema);
            _log('Using structured output schema');
          } catch (e) {
            _log('⚠️ Failed to parse schema: $e');
          }
        }

        // Create the model
        final generativeModel = GenerativeModel(
          model: model,
          apiKey: apiKey,
          generationConfig: GenerationConfig(
            temperature: 1.0,
            maxOutputTokens: 65536,
            responseMimeType: jsonSchema != null ? 'application/json' : null,
            responseSchema: responseSchema,
          ),
        );
        
        // Create content
        final content = [Content.text(prompt)];
        
        // Stream the response
        final responseStream = generativeModel.generateContentStream(content);
        
        final fullResponse = StringBuffer();
        bool receivedAny = false;
        
        await for (final response in responseStream) {
          final text = response.text;
          if (text != null && text.isNotEmpty) {
            receivedAny = true;
            fullResponse.write(text);
            onChunk?.call(text);
          }
        }
        
        if (!receivedAny) {
           throw Exception('API returned no content');
        }
        
        final result = fullResponse.toString();
        _log('Generation complete: ${result.length} chars');
        return result;
        
      } catch (e) {
        _log('Caught exception with key ${_currentKeyIndex + 1}: $e');
        lastError = Exception(e.toString());
        
        if (_isQuotaError(e)) {
          _log('Quota/Rate limit reached, rotating...');
          _rotateToNextKey(failedKey: apiKey);
        } else {
          _log('Error occurred, rotating to next key...');
          _rotateToNextKey(failedKey: apiKey);
        }
      }
    }
    
    // All keys failed
    throw lastError ?? Exception('All API keys failed');
  }
  
  /// Generate text without streaming
  Future<String> generateTextSync({
    required String prompt,
    required String model,
  }) async {
    // Fallback to global keys if instance has none
    if (apiKeys.isEmpty) {
      try {
        final globalKeys = await GeminiKeyService.loadKeys();
        if (globalKeys.isNotEmpty) {
          apiKeys = globalKeys.where((k) => k.trim().isNotEmpty).toList();
        }
      } catch (e) {
        // ignore
      }
    }

    if (apiKeys.isEmpty) {
      throw Exception('No API keys configured');
    }
    
    final apiKey = currentKey!;
    
    try {
      final generativeModel = GenerativeModel(
        model: model,
        apiKey: apiKey,
        generationConfig: GenerationConfig(
          temperature: 1.0,
          maxOutputTokens: 65536,
        ),
      );
      
      final content = [Content.text(prompt)];
      final response = await generativeModel.generateContent(content);
      
      return response.text ?? '';
      
    } catch (e) {
      if (_isQuotaError(e)) {
        _rotateToNextKey(failedKey: apiKey);
      }
      rethrow;
    }
  }
}
