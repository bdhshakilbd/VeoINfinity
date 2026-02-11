/// Story Prompt Processor - Standalone App with YouTube Clone Feature
/// Three tabs: 1) Create Story 2) Clone YouTube Video 3) Generate Videos

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'veo3_video_service.dart';

void main() => runApp(const StoryPromptApp());

class StoryPromptApp extends StatelessWidget {
  const StoryPromptApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Story Prompt Processor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.light),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey.shade50,
      ),
      home: const MainScreen(),
    );
  }
}

// ============================================================================
// MODELS
// ============================================================================
class StoryProject {
  final String title;
  final VisualStyle visualStyle;
  final List<Character> characters;
  final Map<String, String> sizeIndexMap;
  final List<Location> locations;
  final List<StoryFrame> frames;
  final List<VideoClip> videoClips;

  StoryProject({required this.title, required this.visualStyle, required this.characters,
    required this.sizeIndexMap, required this.locations, required this.frames, required this.videoClips});

  factory StoryProject.fromJson(Map<String, dynamic> json) {
    final story = json['story'] as Map<String, dynamic>? ?? json;
    
    // Parse characters - handle both object array and string array formats
    List<Character> parseCharacters(dynamic charData) {
      if (charData == null) return [];
      if (charData is! List) return [];
      
      return charData.map((c) {
        if (c is Map<String, dynamic>) {
          // Detailed object format: {id, name, description, ...}
          return Character.fromJson(c);
        } else if (c is String) {
          // Simple string format: "Name: Description"
          final colonIdx = c.indexOf(':');
          if (colonIdx > 0) {
            final name = c.substring(0, colonIdx).trim();
            final desc = c.substring(colonIdx + 1).trim();
            final id = 'char_${name.toLowerCase().replaceAll(' ', '_').replaceAll(RegExp(r'[^a-z0-9_]'), '')}';
            return Character(id: id, name: name, description: desc, sizeIndex: 5, sizeReference: '');
          } else {
            return Character(id: 'char_${c.toLowerCase().replaceAll(' ', '_')}', name: c, description: c, sizeIndex: 5, sizeReference: '');
          }
        }
        return Character(id: '', name: '', description: '', sizeIndex: 5, sizeReference: '');
      }).toList();
    }
    
    // Parse locations - handle both object array and string array formats
    List<Location> parseLocations(dynamic locData) {
      if (locData == null) return [];
      if (locData is! List) return [];
      
      return locData.map((l) {
        if (l is Map<String, dynamic>) {
          // Detailed object format: {id, name, description}
          return Location.fromJson(l);
        } else if (l is String) {
          // Simple string format: "Name: Description"
          final colonIdx = l.indexOf(':');
          if (colonIdx > 0) {
            final name = l.substring(0, colonIdx).trim();
            final desc = l.substring(colonIdx + 1).trim();
            final id = 'loc_${name.toLowerCase().replaceAll(' ', '_').replaceAll(RegExp(r'[^a-z0-9_]'), '')}';
            return Location(id: id, name: name, description: desc);
          } else {
            return Location(id: 'loc_${l.toLowerCase().replaceAll(' ', '_')}', name: l, description: l);
          }
        }
        return Location(id: '', name: '', description: '');
      }).toList();
    }
    
    return StoryProject(
      title: story['title'] ?? 'Untitled',
      visualStyle: VisualStyle.fromJson(story['visual_style'] ?? {}),
      characters: parseCharacters(story['characters']),
      sizeIndexMap: (story['size_index_map'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
      locations: parseLocations(story['locations']),
      frames: (json['frames'] as List?)?.map((f) => StoryFrame.fromJson(f)).toList() ?? [],
      videoClips: (json['video_clips'] as List?)?.map((v) => VideoClip.fromJson(v)).toList() ?? [],
    );
  }

  /// Factory to convert ANY array of JSON objects to StoryProject
  /// Each prompt = 1 frame. Auto-reuse pattern: 1,2 generate, then odd skip/even generate
  /// @param autoReuse - when true, applies the alternating reuse pattern
  factory StoryProject.fromSimplePromptArray(List<dynamic> prompts, {bool autoReuse = true}) {
    final frames = <StoryFrame>[];
    final clips = <VideoClip>[];
    
    for (int i = 0; i < prompts.length; i++) {
      final p = prompts[i] as Map<String, dynamic>;
      final promptIndex = i + 1; // 1-based index
      final frameId = 'frame_${promptIndex.toString().padLeft(3, '0')}';
      
      // Build prompt by concatenating ALL string values from the object
      final promptParts = <String>[];
      int durationSec = 8; // default
      
      for (final entry in p.entries) {
        final key = entry.key.toLowerCase();
        final value = entry.value;
        
        // Skip certain keys
        if (key.contains('duration') && value is String) {
          final match = RegExp(r'(\d+)').firstMatch(value);
          if (match != null) durationSec = int.tryParse(match.group(1)!) ?? 8;
          continue;
        }
        // Skip these attributes (already in prompt or not needed)
        if (key.contains('aspect') || 
            key.contains('negative') || 
            key == 'id' || 
            key.contains('char_in_this_scene') ||
            key.contains('characters_in_scene')) continue;
        
        // Add strings to prompt
        if (value is String && value.isNotEmpty) {
          promptParts.add(value);
        } else if (value is List) {
          for (final item in value) {
            if (item is String && item.isNotEmpty) promptParts.add(item);
          }
        }
      }
      
      final fullPrompt = promptParts.join('\n\n');
      
      // Determine if this frame should be generated or reused
      // Pattern when autoReuse is ON:
      //   ID 1: Generate (first frame)
      //   ID 2: Generate (second frame)
      //   ID 3: Skip/Reuse from ID 2
      //   ID 4: Generate
      //   ID 5: Skip/Reuse from ID 4
      //   ID 6: Generate
      //   ... (odd >= 3 skip, even >= 4 generate)
      
      bool shouldGenerate;
      String? reuseFrom;
      
      if (autoReuse) {
        if (promptIndex == 1 || promptIndex == 2) {
          shouldGenerate = true;
        } else if (promptIndex % 2 == 1) {
          // Odd index >= 3: Skip, reuse from previous (which is even)
          shouldGenerate = false;
          reuseFrom = 'frame_${(promptIndex - 1).toString().padLeft(3, '0')}';
        } else {
          // Even index >= 4: Generate
          shouldGenerate = true;
        }
      } else {
        // No auto-reuse: generate all frames
        shouldGenerate = true;
      }
      
      frames.add(StoryFrame(
        frameId: frameId,
        videoClipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        framePosition: 'single',
        locationId: '',
        charactersInScene: [],
        prompt: fullPrompt,
        camera: '',
        generateImage: shouldGenerate,
        reuseFrame: reuseFrom,
        notes: shouldGenerate ? null : 'AUTO-REUSE: Uses image from $reuseFrom',
      ));
      
      // Create video clip (each prompt is one clip)
      // Clip uses current frame as both first and last
      // When generating video, the auto-reuse toggle handles using previous frame
      clips.add(VideoClip(
        clipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        firstFrame: frameId,
        lastFrame: frameId,
        durationSeconds: durationSec,
        veo3Prompt: fullPrompt,
        audioDescription: '',
      ));
    }
    
    // Count stats
    final generateCount = frames.where((f) => f.generateImage).length;
    final reuseCount = frames.where((f) => !f.generateImage).length;
    
    return StoryProject(
      title: 'Prompt Array (${frames.length} prompts, $generateCount generate, $reuseCount reuse)',
      visualStyle: VisualStyle(
        artStyle: 'Cinematic',
        colorPalette: 'Cinematic',
        lighting: 'Volumetric lighting',
        aspectRatio: '16:9',
        quality: '8K, ultra-detailed',
      ),
      characters: [],
      sizeIndexMap: {},
      locations: [],
      frames: frames,
      videoClips: clips,
    );
  }

  /// Factory to convert plain text prompts (one prompt per line) to StoryProject
  /// Supports format: [MM:SS - MM:SS] Prompt text here...
  /// Each non-empty line becomes one frame/video clip
  factory StoryProject.fromPlainTextPrompts(String text, {bool autoReuse = true}) {
    final frames = <StoryFrame>[];
    final clips = <VideoClip>[];
    
    // Split by newlines, filter empty lines
    final lines = text.split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    
    // Regex to extract timestamp: [00:00 - 00:08] or [00:00-00:08]
    final timestampRegex = RegExp(r'^\[(\d+):(\d+)\s*-\s*(\d+):(\d+)\]\s*');
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final promptIndex = i + 1; // 1-based index
      final frameId = 'frame_${promptIndex.toString().padLeft(3, '0')}';
      
      String promptText = line;
      int durationSec = 8; // default
      
      // Try to extract timestamp and calculate duration
      final match = timestampRegex.firstMatch(line);
      if (match != null) {
        final startMin = int.parse(match.group(1)!);
        final startSec = int.parse(match.group(2)!);
        final endMin = int.parse(match.group(3)!);
        final endSec = int.parse(match.group(4)!);
        
        final startTotal = startMin * 60 + startSec;
        final endTotal = endMin * 60 + endSec;
        durationSec = (endTotal - startTotal).clamp(5, 60);
        
        // Remove timestamp from prompt
        promptText = line.substring(match.end).trim();
      }
      
      // Determine if this frame should be generated or reused
      // Same pattern as JSON parser
      bool shouldGenerate;
      String? reuseFrom;
      
      if (autoReuse) {
        if (promptIndex == 1 || promptIndex == 2) {
          shouldGenerate = true;
        } else if (promptIndex % 2 == 1) {
          shouldGenerate = false;
          reuseFrom = 'frame_${(promptIndex - 1).toString().padLeft(3, '0')}';
        } else {
          shouldGenerate = true;
        }
      } else {
        shouldGenerate = true;
      }
      
      frames.add(StoryFrame(
        frameId: frameId,
        videoClipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        framePosition: 'single',
        locationId: '',
        charactersInScene: [],
        prompt: promptText,
        camera: '',
        generateImage: shouldGenerate,
        reuseFrame: reuseFrom,
        notes: shouldGenerate ? null : 'AUTO-REUSE: Uses image from $reuseFrom',
      ));
      
      // Create video clip
      clips.add(VideoClip(
        clipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        firstFrame: frameId,
        lastFrame: frameId,
        durationSeconds: durationSec,
        veo3Prompt: promptText,
        audioDescription: '',
      ));
    }
    
    final generateCount = frames.where((f) => f.generateImage).length;
    final reuseCount = frames.where((f) => !f.generateImage).length;
    
    return StoryProject(
      title: 'Text Prompts (${frames.length} prompts, $generateCount generate, $reuseCount reuse)',
      visualStyle: VisualStyle(
        artStyle: 'Hyper-realistic 3D cinematic',
        colorPalette: 'Cinematic',
        lighting: 'Volumetric lighting',
        aspectRatio: '16:9',
        quality: '8K, ultra-detailed',
      ),
      characters: [],
      sizeIndexMap: {},
      locations: [],
      frames: frames,
      videoClips: clips,
    );
  }

  Character? getCharacterById(String id) => characters.where((c) => c.id == id).firstOrNull;
  Location? getLocationById(String id) => locations.where((l) => l.id == id || l.name == id).firstOrNull;
  StoryFrame? getFrameById(String id) => frames.where((f) => f.frameId == id).firstOrNull;
  String getSizeDescription(int idx) => sizeIndexMap[idx.toString()] ?? 'unknown';
}

class VisualStyle {
  final String artStyle, colorPalette, lighting, aspectRatio, quality;
  VisualStyle({required this.artStyle, required this.colorPalette, required this.lighting, 
    required this.aspectRatio, required this.quality});
  factory VisualStyle.fromJson(Map<String, dynamic> json) => VisualStyle(
    artStyle: json['art_style'] ?? '', colorPalette: json['color_palette'] ?? '',
    lighting: json['lighting'] ?? '', aspectRatio: json['aspect_ratio'] ?? '16:9', quality: json['quality'] ?? '');
  String toPromptString() => [artStyle, colorPalette, lighting, quality].where((s) => s.isNotEmpty).join('. ');
}

class Character {
  final String id, name, description, sizeReference;
  final int sizeIndex;
  Character({required this.id, required this.name, required this.description, required this.sizeIndex, required this.sizeReference});
  factory Character.fromJson(Map<String, dynamic> json) => Character(
    id: json['id'] ?? '', name: json['name'] ?? '', description: json['description'] ?? '',
    sizeIndex: json['size_index'] ?? 5, sizeReference: json['size_reference'] ?? '');
}

class Location {
  final String id, name, description;
  Location({required this.id, required this.name, required this.description});
  factory Location.fromJson(Map<String, dynamic> json) => Location(
    id: json['id'] ?? '', name: json['name'] ?? '', description: json['description'] ?? '');
}

class StoryFrame {
  final String frameId, videoClipId, framePosition, locationId;
  final List<String> charactersInScene;
  String? prompt; // Made non-final for editing
  final String? camera, refImage, reuseFrame, notes;
  final bool generateImage;
  final int? timestampStart, timestampEnd;
  String? generatedImagePath, processedPrompt, error;
  bool isGenerating = false;

  StoryFrame({required this.frameId, required this.videoClipId, required this.framePosition,
    required this.locationId, required this.charactersInScene, this.prompt, this.camera,
    this.refImage, required this.generateImage, this.reuseFrame, this.notes,
    this.timestampStart, this.timestampEnd});

  factory StoryFrame.fromJson(Map<String, dynamic> json) => StoryFrame(
    frameId: json['frame_id'] ?? '', 
    videoClipId: json['video_clip_id'] ?? '',
    framePosition: json['frame_position'] ?? 'first', 
    locationId: json['location_id']?.toString() ?? '',  // Can be ID or name
    charactersInScene: (json['characters_in_scene'] as List?)?.map((c) => c.toString()).toList() ?? [],
    prompt: json['prompt'], 
    camera: json['camera'], 
    refImage: json['ref_image'],
    generateImage: json['generate_image'] ?? true, 
    reuseFrame: json['reuse_frame'], 
    notes: json['notes'],
    timestampStart: json['timestamp_start'] as int?,
    timestampEnd: json['timestamp_end'] as int?);
}

class VideoClip {
  final String clipId, firstFrame, lastFrame, veo3Prompt, audioDescription;
  final int durationSeconds;
  VideoClip({required this.clipId, required this.firstFrame, required this.lastFrame,
    required this.durationSeconds, required this.veo3Prompt, required this.audioDescription});
  factory VideoClip.fromJson(Map<String, dynamic> json) {
    // Handle audio_description as either String or detailed object
    String audioDesc = '';
    final audioData = json['audio_description'];
    if (audioData is String) {
      audioDesc = audioData;
    } else if (audioData is Map) {
      // Convert detailed audio object to formatted string
      final parts = <String>[];
      if (audioData['sfx'] != null) {
        final sfx = audioData['sfx'];
        if (sfx is List) {
          parts.add('SFX: ${sfx.join(", ")}');
        } else {
          parts.add('SFX: $sfx');
        }
      }
      if (audioData['bgm'] != null) parts.add('BGM: ${audioData['bgm']}');
      if (audioData['speech'] != null && audioData['speech'] != 'None') {
        parts.add('Speech: ${audioData['speech']}');
      }
      if (audioData['ambient'] != null) parts.add('Ambient: ${audioData['ambient']}');
      audioDesc = parts.join(' | ');
    }
    
    return VideoClip(
      clipId: json['clip_id'] ?? '', 
      firstFrame: json['first_frame'] ?? '', 
      lastFrame: json['last_frame'] ?? '',
      durationSeconds: json['duration_seconds'] ?? 5, 
      veo3Prompt: json['veo3_prompt'] ?? '',
      audioDescription: audioDesc);
  }
}

// ============================================================================
// WHISK API SERVICE
// ============================================================================
class WhiskApiService {
  String? _authToken, _cookie;
  DateTime? _sessionExpiry;
  bool get isAuthenticated => _authToken != null;

  Future<bool> loadCredentials() async {
    try {
      final credFile = File('${Directory.current.path}/whisk_credentials.json');
      if (!await credFile.exists()) return false;
      final json = jsonDecode(await credFile.readAsString());
      final expiry = DateTime.parse(json['expiry']);
      if (expiry.isBefore(DateTime.now().add(const Duration(minutes: 5)))) return false;
      _cookie = json['cookie']; _authToken = json['authToken']; _sessionExpiry = expiry;
      return true;
    } catch (_) { return false; }
  }

  Future<bool> checkSession(String cookie) async {
    try {
      final response = await http.get(Uri.parse('https://labs.google/fx/api/auth/session'),
        headers: {'host': 'labs.google', 'cookie': cookie, 'content-type': 'application/json'});
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        _authToken = json['access_token']; _cookie = cookie; _sessionExpiry = DateTime.parse(json['expires']);
        await File('${Directory.current.path}/whisk_credentials.json').writeAsString(jsonEncode({
          'cookie': _cookie, 'expiry': _sessionExpiry!.toIso8601String(), 'authToken': _authToken}));
        return true;
      }
      return false;
    } catch (_) { return false; }
  }

  Future<Uint8List?> generateImage({required String prompt, String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE', 
    String imageModel = 'IMAGEN_3_5', int maxRetries = 2}) async {
    if (_authToken == null) throw Exception('Not authenticated');
    
    print('\n🎨 ========================================');
    print('🎨 IMAGE GENERATION REQUEST');
    print('🎨 ========================================');
    print('📝 Prompt: ${prompt.length > 100 ? prompt.substring(0, 100) + '...' : prompt}');
    print('📐 Aspect Ratio: $aspectRatio');
    print('🤖 Primary Model: $imageModel');
    print('🔄 Max Retries: $maxRetries');
    
    String currentModel = imageModel;
    final alternativeModel = imageModel == 'IMAGEN_3_5' ? 'GEM_PIX' : 'IMAGEN_3_5';
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final waitSeconds = attempt * 2; // Exponential backoff: 2s, 4s
          print('\n⏳ Retry attempt $attempt/$maxRetries - Waiting ${waitSeconds}s...');
          await Future.delayed(Duration(seconds: waitSeconds));
          
          // Model switching logic
          if (attempt == 1) {
            currentModel = alternativeModel;
            print('🔀 Switching to alternative model: $currentModel');
          } else if (attempt == 2) {
            currentModel = imageModel;
            print('🔙 Reverting to original model: $currentModel');
          }
        }
        
        print('\n📤 Sending request to Whisk API...');
        print('🤖 Using Model: $currentModel');
        final startTime = DateTime.now();
        
        final response = await http.post(Uri.parse('https://aisandbox-pa.googleapis.com/v1/whisk:generateImage'),
          headers: {'authorization': 'Bearer $_authToken', 'content-type': 'text/plain;charset=UTF-8', 
            'origin': 'https://labs.google'},
          body: jsonEncode({"clientContext": {"workflowId": DateTime.now().millisecondsSinceEpoch.toString(), "tool": "BACKBONE"},
            "imageModelSettings": {"imageModel": currentModel, "aspectRatio": aspectRatio},
            "seed": DateTime.now().millisecondsSinceEpoch % 1000000, "prompt": prompt}));
        
        final duration = DateTime.now().difference(startTime);
        print('📥 Response received in ${duration.inSeconds}s');
        print('📊 Status Code: ${response.statusCode}');
        
        if (response.statusCode == 200) {
          print('✅ Request successful!');
          final responseJson = jsonDecode(response.body);
          final panels = responseJson['imagePanels'] as List?;
          
          if (panels?.isNotEmpty == true) {
            final img = (panels![0]['generatedImages'] as List?)?.firstOrNull?['encodedImage'];
            if (img != null) {
              final imageBytes = base64Decode(img);
              print('🖼️  Image decoded: ${(imageBytes.length / 1024).toStringAsFixed(2)} KB');
              if (currentModel != imageModel) {
                print('ℹ️  Generated with fallback model: $currentModel');
              }
              print('🎨 ========================================\n');
              return imageBytes;
            } else {
              print('⚠️  No image data in response');
            }
          } else {
            print('⚠️  No image panels in response');
          }
        } else {
          print('❌ Request failed with status ${response.statusCode}');
          print('📄 Error body: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');
          
          // Check for specific error types
          if (response.statusCode == 400) {
            print('⚠️  Invalid argument error detected - will try alternative model on retry');
          }
          
          if (attempt < maxRetries) {
            print('🔄 Will retry with ${attempt == 0 ? alternativeModel : (attempt == 1 ? imageModel : currentModel)}...');
          } else {
            print('❌ Max retries reached. Giving up.');
          }
        }
      } catch (e, stackTrace) {
        print('❌ Exception during image generation: $e');
        print('📚 Stack trace: ${stackTrace.toString().split('\n').take(3).join('\n')}');
        
        if (attempt < maxRetries) {
          print('🔄 Will retry with ${attempt == 0 ? alternativeModel : currentModel}...');
        } else {
          print('❌ Max retries reached. Giving up.');
          print('🎨 ========================================\n');
          rethrow;
        }
      }
    }
    
    print('🎨 ========================================\n');
    return null;
  }
  
  static String convertAspectRatio(String r) => r == '9:16' ? 'IMAGE_ASPECT_RATIO_PORTRAIT' : 
    r == '1:1' ? 'IMAGE_ASPECT_RATIO_SQUARE' : 'IMAGE_ASPECT_RATIO_LANDSCAPE';
}

// ============================================================================
// GEMINI API SERVICE - Uses file_data for YouTube video analysis
// ============================================================================
class GeminiService {
  String? apiKey;
  String model = 'gemini-3-flash-preview';
  bool _isCancelled = false;

  void cancelAnalysis() {
    _isCancelled = true;
    print('\n🛑 Analysis cancellation requested by user');
  }

  void resetCancellation() {
    _isCancelled = false;
  }

  /// Analyze YouTube video using file_data format (proper Gemini API format)
  Future<String?> analyzeYouTubeVideo(String videoUrl, String masterPrompt, int sceneCount) async {
    if (apiKey == null || apiKey!.isEmpty) throw Exception('Gemini API key not set');
    
    // Build request with file_data for YouTube URL
    final requestBody = {
      "contents": [{
        "parts": [
          {
            "file_data": {
              "file_uri": videoUrl
            }
          },
          {
            "text": '''$masterPrompt

Generate exactly $sceneCount scene prompts (frames will be 2x this number). 
Output ONLY valid JSON, no markdown, no explanations.'''
          }
        ]
      }],
      "generationConfig": {
        "temperature": 0.7,
        "maxOutputTokens": 8192
      }
    };

    final response = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return json['candidates']?[0]?['content']?['parts']?[0]?['text'];
    }
    throw Exception('Gemini API error: ${response.statusCode} - ${response.body}');
  }

  /// Analyze YouTube video in batches - SMART VERSION
  /// - Analyzes video only in first batch
  /// - Saves progress after each batch
  /// - Resumes from last completed batch
  /// - Shows results progressively
  Future<String?> analyzeInBatches(
    String videoUrl, 
    String masterPrompt, 
    int totalScenes,
    Function(int, int) onProgress,
    Function(String) onBatchComplete, // NEW: Callback for progressive results
  ) async {
    if (apiKey == null) throw Exception('API key not set');
    
    const batchSize = 10;
    final batches = (totalScenes / batchSize).ceil();
    
    // Create organized cache folder structure
    final videoId = Uri.parse(videoUrl).queryParameters['v'] ?? 'unknown';
    final cacheDir = Directory('${Directory.current.path}/yt_stories/$videoId');
    await cacheDir.create(recursive: true);
    
    final progressFile = File('${cacheDir.path}/progress_${totalScenes}scenes.json');
    final storyFile = File('${cacheDir.path}/story.json');
    
    List<Map<String, dynamic>> allFrames = [];
    List<Map<String, dynamic>> allClips = [];
    Map<String, dynamic>? storyData;
    String extractedStory = '';
    int startBatch = 0;

    // Try to load cached progress
    if (await progressFile.exists()) {
      try {
        final cached = jsonDecode(await progressFile.readAsString());
        allFrames = List<Map<String, dynamic>>.from(cached['frames'] ?? []);
        allClips = List<Map<String, dynamic>>.from(cached['video_clips'] ?? []);
        startBatch = cached['last_completed_batch'] ?? 0;
        
        // Load complete story structure (includes frames and clips)
        if (await storyFile.exists()) {
          final storyContent = await storyFile.readAsString();
          print('📖 Story file found: ${storyFile.path}');
          print('📄 Story content length: ${storyContent.length} chars');
          
          final completeStory = jsonDecode(storyContent);
          storyData = completeStory['story'];
          extractedStory = jsonEncode(storyData); // Just the metadata for subsequent batches
          
          print('✅ Complete story loaded: ${storyData?.keys.toList()}');
        } else {
          print('⚠️  Story file not found: ${storyFile.path}');
        }
        
        print('\n📂 Found cached progress!');
        print('✅ Story extracted: ${storyData != null ? 'Yes' : 'No'}');
        print('🎞️  Cached frames: ${allFrames.length}');
        print('🎬 Cached clips: ${allClips.length}');
        print('▶️  Resuming from batch ${startBatch + 1}/$batches\n');
        
        // Send cached results immediately
        if (allFrames.isNotEmpty || allClips.isNotEmpty) {
          final partialResult = jsonEncode({
            "story": storyData ?? {},
            "frames": allFrames,
            "video_clips": allClips
          });
          onBatchComplete(partialResult);
        }
      } catch (e) {
        print('⚠️  Could not load cache: $e');
        startBatch = 0;
      }
    }

    print('\n========================================');
    print('🎬 Starting YouTube Video Analysis');
    print('========================================');
    print('📹 Video URL: $videoUrl');
    print('🎯 Total Scenes: $totalScenes');
    print('📦 Batch Size: $batchSize');
    print('🔢 Total Batches: $batches');
    print('🤖 Model: $model');
    if (startBatch > 0) print('⏭️  Skipping batches 1-$startBatch (already done)');
    print('========================================\n');

    for (int i = startBatch; i < batches; i++) {
      // Check for cancellation
      if (_isCancelled) {
        print('\n🛑 Analysis cancelled by user at batch ${i + 1}/$batches');
        print('📊 Partial results: ${allFrames.length} frames, ${allClips.length} clips');
        break;
      }
      
      onProgress(i + 1, batches);
      final start = i * batchSize + 1;
      final end = ((i + 1) * batchSize).clamp(1, totalScenes);
      
      print('\n--- Batch ${i + 1}/$batches ---');
      print('📊 Scenes: $start to $end');

      String batchPrompt;
      Map<String, dynamic> requestBody;

      if (i == 0) {
        // FIRST BATCH: Analyze video + extract story
        print('🎥 Analyzing video (first batch only)...');
        
        batchPrompt = '''$masterPrompt

**FIRST BATCH - Extract Story & Generate Scenes $start to $end**

1. Watch the video and extract:
   - Visual style (art_style, color_palette, lighting, aspect_ratio, quality)
   - All characters with descriptions and size_index
   - All locations with descriptions
   
2. Generate scenes $start to $end with frames and video_clips

Output valid JSON with "story", "frames", and "video_clips".''';

        requestBody = {
          "contents": [{
            "parts": [
              {"file_data": {"file_uri": videoUrl}},
              {"text": batchPrompt}
            ]
          }],
          "generationConfig": {"temperature": 0.7, "maxOutputTokens": 8192}
        };
      } else {
        // SUBSEQUENT BATCHES: Use extracted story (text-only, no video analysis)
        print('📝 Using extracted story (no video re-analysis)...');
        
        final lastClipPrompt = allClips.lastOrNull?['veo3_prompt'] ?? 'Story beginning';
        
        batchPrompt = '''Continue the story from where we left off.

**EXTRACTED STORY CONTEXT:**
$extractedStory

**Last scene:** $lastClipPrompt

**Generate scenes $start to $end of $totalScenes total**

Create frames and video_clips for scenes $start to $end.
Frame IDs: frame_${start.toString().padLeft(3, '0')} to frame_${(end * 2).toString().padLeft(3, '0')}

Output ONLY "frames" and "video_clips" arrays in valid JSON.''';

        // TEXT-ONLY REQUEST (no video file_data)
        requestBody = {
          "contents": [{
            "parts": [{"text": batchPrompt}]
          }],
          "generationConfig": {"temperature": 0.7, "maxOutputTokens": 8192}
        };
      }

      print('📤 Sending request to Gemini API...');
      
      try {
        final response = await http.post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(requestBody),
        );

        print('📥 Response Status: ${response.statusCode}');

        if (response.statusCode == 200) {
          print('✅ API call successful');
          
          final responseJson = jsonDecode(response.body);
          final text = responseJson['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
          
          if (text.isEmpty) {
            print('⚠️  WARNING: Empty response text');
            continue;
          }
          
          print('📝 Response length: ${text.length} characters');
          
          try {
            final cleaned = text.replaceAll('```json', '').replaceAll('```', '').trim();
            final batchJson = jsonDecode(cleaned);
            
            print('✅ JSON parsed successfully');
            
            // Extract story data from first batch
            if (i == 0 && batchJson['story'] != null) {
              storyData = batchJson['story'];
              extractedStory = jsonEncode(storyData);
              print('📖 Story extracted: ${storyData!.keys.toList()}');
            }
            
            // Collect frames and clips
            if (batchJson['frames'] != null) {
              final newFrames = List<Map<String, dynamic>>.from(batchJson['frames']);
              allFrames.addAll(newFrames);
              print('🎞️  Added ${newFrames.length} frames (Total: ${allFrames.length})');
            }
            if (batchJson['video_clips'] != null) {
              final newClips = List<Map<String, dynamic>>.from(batchJson['video_clips']);
              allClips.addAll(newClips);
              print('🎬 Added ${newClips.length} clips (Total: ${allClips.length})');
            }
            
            // SAVE PROGRESS IMMEDIATELY
            // Save COMPLETE story file (metadata + all frames + all clips so far)
            if (storyData != null) {
              await storyFile.writeAsString(jsonEncode({
                "story": storyData,
                "frames": allFrames,
                "video_clips": allClips,
              }));
              print('📖 Complete story saved (${allFrames.length} frames, ${allClips.length} clips)');
            }
            
            // Save individual batch file
            final batchFile = File('${cacheDir.path}/batch_${(i + 1).toString().padLeft(2, '0')}.json');
            await batchFile.writeAsString(jsonEncode({
              "batch_number": i + 1,
              "scenes": "$start-$end",
              "frames": batchJson['frames'] ?? [],
              "video_clips": batchJson['video_clips'] ?? [],
            }));
            print('💾 Batch ${i + 1} saved to batch file');
            
            // SAVE PROGRESS IMMEDIATELY
            await progressFile.writeAsString(jsonEncode({
              "story": storyData ?? {},
              "frames": allFrames,
              "video_clips": allClips,
              "extracted_story": extractedStory,
              "last_completed_batch": i + 1,
              "total_batches": batches,
            }));
            print('� Progress saved to cache');
            
            // SEND PROGRESSIVE RESULTS TO UI
            final progressiveResult = jsonEncode({
              "story": storyData ?? {},
              "frames": allFrames,
              "video_clips": allClips
            });
            onBatchComplete(progressiveResult);
            print('📤 Results sent to UI');
            
          } catch (e) {
            print('❌ JSON Parse Error in batch ${i + 1}: $e');
            print('🔍 Raw text (first 500 chars): ${text.substring(0, text.length > 500 ? 500 : text.length)}');
          }
        } else {
          print('❌ API Error: ${response.statusCode}');
          print('🔍 Error body: ${response.body}');
          
          try {
            final errorJson = jsonDecode(response.body);
            print('🔍 Error details: ${errorJson['error']?['message'] ?? 'No error message'}');
          } catch (_) {}
        }
      } catch (e, stackTrace) {
        print('❌ Exception in batch ${i + 1}: $e');
        print('📚 Stack trace: $stackTrace');
      }
      
      // Delay between batches
      if (i < batches - 1) {
        print('⏳ Waiting 2 seconds before next batch...\n');
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    print('\n========================================');
    print('✅ Analysis Complete!');
    print('========================================');
    print('📖 Story data: ${storyData != null ? 'Yes' : 'No'}');
    print('🎞️  Total frames: ${allFrames.length}');
    print('🎬 Total clips: ${allClips.length}');
    print('💾 Cache folder: ${cacheDir.path}');
    print('========================================\n');

    return jsonEncode({
      "story": storyData ?? {},
      "frames": allFrames,
      "video_clips": allClips
    });
  }
}

// ============================================================================
// MAIN SCREEN WITH TABS
// ============================================================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final WhiskApiService _whiskApi = WhiskApiService();
  final GeminiService _geminiApi = GeminiService();
  final Veo3VideoService _veo3Api = Veo3VideoService();
  
  // Shared state
  StoryProject? _project;
  final Map<String, Uint8List> _imageBytes = {};
  String _outputDir = '';
  
  // Auto-reuse toggle (shared across tabs)
  bool _autoReusePreviousFrame = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _initOutputDir();
    _whiskApi.loadCredentials().then((_) => setState(() {}));
  }

  Future<void> _initOutputDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    _outputDir = path.join(appDir.path, 'story_frames');
    await Directory(_outputDir).create(recursive: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Story Prompt Processor', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white, elevation: 1,
        bottom: TabBar(controller: _tabController, tabs: const [
          Tab(icon: Icon(Icons.edit_note), text: 'Create Story'),
          Tab(icon: Icon(Icons.video_library), text: 'Clone YouTube'),
          Tab(icon: Icon(Icons.movie_creation), text: 'Generate Videos'),
        ]),
        actions: [
          // Auto-Reuse Toggle (always visible)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _autoReusePreviousFrame ? Colors.purple.shade50 : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _autoReusePreviousFrame ? Colors.purple.shade300 : Colors.orange.shade300),
            ),
            child: Tooltip(
              message: _autoReusePreviousFrame 
                ? 'ON: Skip odd frames (reuse previous). Re-parse to apply.'
                : 'OFF: Generate ALL frames. Re-parse to apply.',
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_autoReusePreviousFrame ? Icons.fast_forward : Icons.all_inclusive,
                  color: _autoReusePreviousFrame ? Colors.purple.shade600 : Colors.orange.shade600, size: 16),
                const SizedBox(width: 4),
                Text(_autoReusePreviousFrame ? 'Skip Mode' : 'All Frames', style: TextStyle(
                  color: _autoReusePreviousFrame ? Colors.purple.shade700 : Colors.orange.shade700, fontSize: 11, fontWeight: FontWeight.w600)),
                Switch(
                  value: _autoReusePreviousFrame,
                  onChanged: (v) {
                    setState(() => _autoReusePreviousFrame = v);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(v 
                        ? '🔗 Skip Mode: Will skip odd frames. Re-parse JSON to apply!' 
                        : '🎯 All Frames Mode: Will generate every frame. Re-parse JSON to apply!'),
                      backgroundColor: v ? Colors.purple : Colors.orange,
                      duration: const Duration(seconds: 3),
                    ));
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeColor: Colors.purple,
                  inactiveTrackColor: Colors.orange.shade200,
                ),
              ]),
            ),
          ),
          if (_veo3Api.isConnected)
            Container(margin: const EdgeInsets.all(8), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.blue.shade300)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.videocam, color: Colors.blue.shade600, size: 16),
                const SizedBox(width: 4),
                Text('VEO3 OK', style: TextStyle(color: Colors.blue.shade700, fontSize: 12)),
              ])),
          if (_whiskApi.isAuthenticated)
            Container(margin: const EdgeInsets.all(8), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.green.shade300)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle, color: Colors.green.shade600, size: 16),
                const SizedBox(width: 4),
                Text('Whisk OK', style: TextStyle(color: Colors.green.shade700, fontSize: 12)),
              ])),
        ],
      ),
      body: TabBarView(controller: _tabController, children: [
        CreateStoryTab(whiskApi: _whiskApi, project: _project, imageBytes: _imageBytes, outputDir: _outputDir,
          autoReuse: _autoReusePreviousFrame,
          onProjectChanged: (p) => setState(() => _project = p),
          onImageGenerated: (id, bytes) => setState(() => _imageBytes[id] = bytes)),
        CloneYouTubeTab(geminiApi: _geminiApi, whiskApi: _whiskApi, 
          onProjectLoaded: (p) { setState(() => _project = p); _tabController.animateTo(0); }),
        GenerateVideosTab(veo3Api: _veo3Api, project: _project, imageBytes: _imageBytes, outputDir: _outputDir,
          onVeo3Connected: () => setState(() {}), autoReusePreviousFrame: _autoReusePreviousFrame),
      ]),
    );
  }

  @override
  void dispose() { _tabController.dispose(); super.dispose(); }
}

// ============================================================================
// CREATE STORY TAB
// ============================================================================
class CreateStoryTab extends StatefulWidget {
  final WhiskApiService whiskApi;
  final StoryProject? project;
  final Map<String, Uint8List> imageBytes;
  final String outputDir;
  final bool autoReuse;
  final Function(StoryProject?) onProjectChanged;
  final Function(String, Uint8List) onImageGenerated;

  const CreateStoryTab({super.key, required this.whiskApi, this.project, required this.imageBytes,
    required this.outputDir, this.autoReuse = true, required this.onProjectChanged, required this.onImageGenerated});

  @override State<CreateStoryTab> createState() => _CreateStoryTabState();
}

class _CreateStoryTabState extends State<CreateStoryTab> {
  final _jsonController = TextEditingController();
  final _cookieController = TextEditingController();
  String? _parseError;
  bool _isGeneratingAll = false;
  int _currentIdx = 0, _totalFrames = 0;
  String _selectedModel = 'IMAGEN_3_5';
  
  // Ultrafast Scene Generator settings
  int _batchSize = 5;
  int _generatedCount = 0;
  int _failedCount = 0;
  final List<String> _models = ['IMAGEN_3_5', 'GEM_PIX'];
  int _currentModelIndex = 0;
  String _generationMode = 'ultrafast'; // 'ultrafast' or 'sequential'
  String _generationStatus = '';

  void _parseJson() {
    final inputText = _jsonController.text.trim();
    if (inputText.isEmpty) {
      setState(() => _parseError = 'Please enter text or JSON');
      return;
    }
    
    StoryProject? project;
    String formatDetected = '';
    
    // First, try to parse as JSON
    try {
      final decoded = jsonDecode(inputText);
      
      if (decoded is List) {
        // Any array of objects - each object becomes a video clip prompt
        if (decoded.isNotEmpty && decoded[0] is Map) {
          project = StoryProject.fromSimplePromptArray(decoded, autoReuse: widget.autoReuse);
          final genCount = project.frames.where((f) => f.generateImage).length;
          final reuseCount = project.frames.where((f) => !f.generateImage).length;
          formatDetected = 'JSON array (${decoded.length} prompts, $genCount generate, $reuseCount reuse)';
        } else {
          throw Exception('Array must contain objects');
        }
      } else if (decoded is Map<String, dynamic>) {
        // Standard StoryProject format
        project = StoryProject.fromJson(decoded);
        formatDetected = 'StoryProject JSON';
      }
    } catch (jsonError) {
      // JSON parsing failed - try as plain text (line-by-line prompts)
      try {
        project = StoryProject.fromPlainTextPrompts(inputText, autoReuse: widget.autoReuse);
        final genCount = project.frames.where((f) => f.generateImage).length;
        final reuseCount = project.frames.where((f) => !f.generateImage).length;
        formatDetected = 'Plain text (${project.videoClips.length} lines, $genCount generate, $reuseCount reuse)';
        print('📋 JSON parse failed, using plain text format');
      } catch (textError) {
        setState(() => _parseError = 'Could not parse as JSON or plain text.\nJSON error: $jsonError');
        return;
      }
    }
    
    if (project == null) {
      setState(() => _parseError = 'Could not create project from input');
      return;
    }
    
    print('📋 Detected format: $formatDetected');
    
    for (final frame in project.frames) {
      frame.processedPrompt = _buildPrompt(project, frame);
    }
    widget.onProjectChanged(project);
    setState(() => _parseError = null);
    
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ $formatDetected → ${project.frames.length} frames, ${project.videoClips.length} clips'),
      backgroundColor: Colors.green));
  }

  String _buildPrompt(StoryProject p, StoryFrame f) {
    // Build prompt WITHOUT any formatting/labels that could appear in images
    final parts = <String>[];
    
    // Add visual style (no label)
    final style = p.visualStyle.toPromptString();
    if (style.isNotEmpty) parts.add(style);
    
    // Add location description (no label)
    final loc = p.getLocationById(f.locationId);
    if (loc != null && loc.description.isNotEmpty) {
      parts.add(loc.description);
    }
    
    // Add character descriptions (no label, no bullet points)
    if (f.charactersInScene.isNotEmpty) {
      for (final cid in f.charactersInScene) {
        final c = p.getCharacterById(cid);
        if (c != null && c.description.isNotEmpty) {
          parts.add(c.description);
        }
      }
    }
    
    // Add scene prompt (no label)
    if (f.prompt != null && f.prompt!.isNotEmpty) {
      parts.add(f.prompt!);
    }
    
    // Add camera info (no label)
    if (f.camera != null && f.camera!.isNotEmpty) {
      parts.add(f.camera!);
    }
    
    return parts.join('. ');
  }

  Future<void> _loadExistingImages() async {
    print('\n📂 ========================================');
    print('📂 LOADING EXISTING IMAGES');
    print('📂 ========================================');
    print('📁 Folder: ${widget.outputDir}');
    
    final dir = Directory(widget.outputDir);
    if (!await dir.exists()) {
      print('❌ Folder does not exist');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Images folder does not exist'), backgroundColor: Colors.red));
      return;
    }
    
    int loadedCount = 0;
    final files = await dir.list().toList();
    
    for (final entity in files) {
      if (entity is File && entity.path.toLowerCase().endsWith('.png')) {
        final fileName = path.basename(entity.path);
        final frameId = fileName.replaceAll('.png', '');
        
        try {
          final bytes = await entity.readAsBytes();
          widget.onImageGenerated(frameId, bytes);
          loadedCount++;
          print('✅ Loaded: $fileName');
          
          // Also update frame if project is loaded
          if (widget.project != null) {
            final frame = widget.project!.getFrameById(frameId);
            if (frame != null) {
              frame.generatedImagePath = fileName;
            }
          }
        } catch (e) {
          print('❌ Failed to load $fileName: $e');
        }
      }
    }
    
    print('📂 ========================================');
    print('✅ Loaded $loadedCount images');
    print('📂 ========================================\n');
    
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Loaded $loadedCount images from folder'), backgroundColor: Colors.green));
  }

  /// Ultrafast Scene Generator - No reference image upload, batch processing
  Future<void> _generateAllUltrafast() async {
    if (widget.project == null) return;
    
    final framesToGenerate = widget.project!.frames.where((f) => f.generateImage && !widget.imageBytes.containsKey(f.frameId)).toList();
    if (framesToGenerate.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All images already generated!'), backgroundColor: Colors.orange));
      return;
    }
    
    setState(() {
      _isGeneratingAll = true;
      _currentIdx = 0;
      _totalFrames = framesToGenerate.length;
      _generatedCount = 0;
      _failedCount = 0;
      _generationStatus = 'Starting Ultrafast Scene Generator...';
    });
    
    print('\n⚡ ========================================');
    print('⚡ ULTRAFAST SCENE GENERATOR');
    print('⚡ Total frames to generate: ${framesToGenerate.length}');
    print('⚡ Batch size: $_batchSize');
    print('⚡ ========================================\n');
    
    // Process in batches
    for (int batchStart = 0; batchStart < framesToGenerate.length; batchStart += _batchSize) {
      if (!_isGeneratingAll) break;
      
      final batchEnd = (batchStart + _batchSize).clamp(0, framesToGenerate.length);
      final batch = framesToGenerate.sublist(batchStart, batchEnd);
      
      setState(() => _generationStatus = 'Processing batch ${(batchStart ~/ _batchSize) + 1}... (${batchStart + 1}-$batchEnd of ${framesToGenerate.length})');
      print('\n📦 Processing batch ${(batchStart ~/ _batchSize) + 1}: frames ${batchStart + 1} to $batchEnd');
      
      // Generate batch concurrently
      final futures = batch.map((frame) => _generateFrameWithRetry(frame, isBatchMode: true));
      await Future.wait(futures);
      
      setState(() => _currentIdx = batchEnd);
    }
    
    setState(() {
      _isGeneratingAll = false;
      _generationStatus = 'Complete! Generated $_generatedCount, Failed $_failedCount';
    });
    
    print('\n⚡ ========================================');
    print('⚡ GENERATION COMPLETE');
    print('⚡ Generated: $_generatedCount');
    print('⚡ Failed: $_failedCount');
    print('⚡ ========================================\n');
    
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ Ultrafast complete! Generated $_generatedCount, Failed $_failedCount'),
      backgroundColor: _failedCount == 0 ? Colors.green : Colors.orange));
  }

  /// Generate single frame with retry logic (3 retries, 15 second wait)
  /// @param isBatchMode - if true, respects _isGeneratingAll flag
  Future<void> _generateFrameWithRetry(StoryFrame frame, {bool isBatchMode = false}) async {
    const maxRetries = 3;
    const retryWaitSeconds = 15;
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      // Only check _isGeneratingAll during batch mode
      if (isBatchMode && !_isGeneratingAll) return;
      
      // Rotate model for each attempt
      final model = _models[_currentModelIndex % _models.length];
      _currentModelIndex++;
      
      print('\n🖼️ Generating ${frame.frameId} (Attempt $attempt/$maxRetries, Model: $model)');
      setState(() { frame.isGenerating = true; frame.error = null; });
      
      try {
        // Use the frame's prompt directly (no fancy formatting)
        final prompt = frame.prompt ?? '';
        if (prompt.isEmpty) {
          print('⚠️ ${frame.frameId}: Empty prompt, skipping');
          setState(() { 
            frame.isGenerating = false; 
            frame.error = 'Empty prompt';
          });
          return;
        }
        
        final bytes = await widget.whiskApi.generateImage(
          prompt: prompt,
          aspectRatio: WhiskApiService.convertAspectRatio(widget.project!.visualStyle.aspectRatio),
          imageModel: model,
        );
        
        if (bytes != null) {
          final filePath = path.join(widget.outputDir, '${frame.frameId}.png');
          await File(filePath).writeAsBytes(bytes);
          widget.onImageGenerated(frame.frameId, bytes);
          frame.generatedImagePath = '${frame.frameId}.png';
          
          print('✅ ${frame.frameId}: Generated successfully with $model');
          setState(() { 
            frame.isGenerating = false; 
            if (isBatchMode) _generatedCount++;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✅ ${frame.frameId} generated!'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ));
          return; // Success, exit retry loop
        } else {
          throw Exception('API returned null');
        }
      } catch (e) {
        print('❌ ${frame.frameId}: Attempt $attempt failed - $e');
        
        if (attempt < maxRetries) {
          print('⏳ Waiting $retryWaitSeconds seconds before retry...');
          setState(() => frame.error = 'Attempt $attempt failed, retrying...');
          await Future.delayed(Duration(seconds: retryWaitSeconds));
        } else {
          print('❌ ${frame.frameId}: All retries exhausted');
          setState(() { 
            frame.isGenerating = false; 
            frame.error = 'Failed after $maxRetries attempts';
            if (isBatchMode) _failedCount++;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('❌ ${frame.frameId} failed: ${frame.error}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      // Left Panel
      Container(width: 360, color: Colors.white, padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.code), const SizedBox(width: 8),
            const Text('Story JSON', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton(onPressed: () { _jsonController.clear(); widget.onProjectChanged(null); },
              child: const Text('Clear', style: TextStyle(color: Colors.red))),
          ]),
          const SizedBox(height: 8),
          Expanded(child: TextField(controller: _jsonController, maxLines: null, expands: true,
            decoration: const InputDecoration(hintText: 'Paste JSON...', border: OutlineInputBorder()),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 10))),
          if (_parseError != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(_parseError!, style: const TextStyle(color: Colors.red, fontSize: 11))),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: _parseJson, child: const Text('Parse')),
          const Divider(height: 24),
          TextField(controller: _cookieController, obscureText: true,
            decoration: InputDecoration(labelText: 'Whisk Cookie', border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.login), 
                onPressed: () async { await widget.whiskApi.checkSession(_cookieController.text); setState(() {}); }))),
          const SizedBox(height: 12),
          
          // ULTRAFAST SCENE GENERATOR
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.deepPurple.shade50, Colors.purple.shade50]),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.deepPurple.shade200),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.bolt, color: Colors.deepPurple.shade700, size: 20),
                const SizedBox(width: 8),
                Text('Ultrafast Scene Generator', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple.shade700)),
              ]),
              const SizedBox(height: 4),
              Text('No ref image upload • Model rotation • Batch processing', 
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              const SizedBox(height: 12),
              
              // Batch size input
              Row(children: [
                const Text('Batch Size:', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                SizedBox(width: 60, height: 36,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                    ),
                    controller: TextEditingController(text: _batchSize.toString()),
                    onChanged: (v) => _batchSize = int.tryParse(v) ?? 5,
                  )),
                const Spacer(),
                Text('Models: IMAGEN ↔ GemPix', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ]),
              const SizedBox(height: 8),
              
              // Load existing images button
              OutlinedButton.icon(
                onPressed: _loadExistingImages,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Load Existing Images', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(height: 8),
              
              // Progress & Status
              if (_isGeneratingAll) ...[
                LinearProgressIndicator(value: _totalFrames > 0 ? _currentIdx / _totalFrames : 0),
                const SizedBox(height: 4),
                Text('$_currentIdx / $_totalFrames frames • $_generatedCount ✅ $_failedCount ❌', 
                  style: const TextStyle(fontSize: 11), textAlign: TextAlign.center),
                if (_generationStatus.isNotEmpty) 
                  Text(_generationStatus, style: TextStyle(fontSize: 10, color: Colors.grey.shade600), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => setState(() => _isGeneratingAll = false),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Cancel'),
                ),
              ] else ...[
                ElevatedButton.icon(
                  onPressed: widget.project != null && widget.whiskApi.isAuthenticated ? _generateAllUltrafast : null,
                  icon: const Icon(Icons.bolt),
                  label: Text('Generate ${widget.project?.frames.where((f) => f.generateImage && !widget.imageBytes.containsKey(f.frameId)).length ?? 0} Images'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ]),
          ),
        ])),
      // Right Panel - Video Clips
      Expanded(child: Container(color: Colors.grey.shade100,
        child: widget.project == null ? const Center(child: Text('Parse JSON to view clips'))
          : Column(children: [
              // Compact Status Bar
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(children: [
                  _buildMiniStat('Total', widget.project!.frames.length, Colors.blue),
                  _buildMiniStat('Generate', widget.project!.frames.where((f) => f.generateImage).length, Colors.orange),
                  _buildMiniStat('Reuse', widget.project!.frames.where((f) => !f.generateImage).length, Colors.green),
                  _buildMiniStat('Done', widget.imageBytes.length, Colors.purple),
                ]),
              ),
              // Grid View - 2 per row with editable prompts
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: (widget.project!.frames.length / 2).ceil(),
                  itemBuilder: (ctx, rowIndex) {
                    final startIdx = rowIndex * 2;
                    final frames = widget.project!.frames.skip(startIdx).take(2).toList();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ...frames.map((f) => Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: _buildFrameWithPrompt(f),
                            ),
                          )),
                          // Fill empty space if odd number
                          if (frames.length == 1) const Expanded(child: SizedBox()),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ]))),
    ]);
  }

  Widget _buildMiniStat(String label, int value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          Text('$value', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
        ]),
      ),
    );
  }

  Widget _buildFrameWithPrompt(StoryFrame frame) {
    final isReused = !frame.generateImage && frame.reuseFrame != null;
    final displayFrameId = isReused ? frame.reuseFrame! : frame.frameId;
    final hasImg = widget.imageBytes.containsKey(displayFrameId);
    
    // Get the video clip for this frame
    final clip = widget.project!.videoClips.where((c) => c.firstFrame == frame.frameId || c.lastFrame == frame.frameId).firstOrNull;
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isReused ? Colors.blue.shade200 : Colors.grey.shade300),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isReused ? Colors.blue.shade50 : Colors.grey.shade100,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isReused ? Colors.blue : Colors.deepPurple,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(frame.frameId.replaceAll('frame_', '#'), 
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
              ),
              if (isReused) ...[
                const SizedBox(width: 6),
                Icon(Icons.link, size: 14, color: Colors.blue.shade600),
                Text(' ${frame.reuseFrame!.replaceAll("frame_", "")}', 
                  style: TextStyle(fontSize: 10, color: Colors.blue.shade600)),
              ],
              const Spacer(),
              if (frame.isGenerating)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else if (hasImg)
                Icon(Icons.check_circle, size: 16, color: Colors.green.shade500)
              else if (frame.generateImage)
                Icon(Icons.pending_outlined, size: 16, color: Colors.orange.shade400),
            ]),
          ),
          // Image - 16:9
          AspectRatio(
            aspectRatio: 16/9,
            child: hasImg 
              ? Stack(fit: StackFit.expand, children: [
                  ClipRRect(
                    child: Image.memory(widget.imageBytes[displayFrameId]!, fit: BoxFit.cover),
                  ),
                  // Delete button
                  if (!isReused) Positioned(top: 4, right: 4,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(4),
                        minimumSize: const Size(24, 24),
                      ),
                      onPressed: () => setState(() => widget.imageBytes.remove(frame.frameId)),
                    ),
                  ),
                ])
              : Container(
                  color: Colors.grey.shade100,
                  child: Center(
                    child: frame.isGenerating 
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(isReused ? Icons.link : Icons.image_outlined, size: 32, color: Colors.grey.shade400),
                          if (isReused) Text('Uses ${frame.reuseFrame}', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                        ]),
                  ),
                ),
          ),
          // Editable Prompt
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Prompt TextField
                TextField(
                  maxLines: 3,
                  style: const TextStyle(fontSize: 10, height: 1.3),
                  decoration: InputDecoration(
                    hintText: 'Enter prompt...',
                    hintStyle: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                    contentPadding: const EdgeInsets.all(8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                    isDense: true,
                  ),
                  controller: TextEditingController(text: frame.prompt ?? clip?.veo3Prompt ?? ''),
                  onChanged: (v) => frame.prompt = v,
                ),
                const SizedBox(height: 6),
                // Regenerate button
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: isReused || frame.isGenerating || !widget.whiskApi.isAuthenticated
                        ? null 
                        : () => _generateFrameWithRetry(frame),
                      icon: Icon(frame.isGenerating ? Icons.hourglass_empty : Icons.refresh, size: 14),
                      label: Text(frame.isGenerating ? 'Generating...' : (hasImg ? 'Regenerate' : 'Generate'), 
                        style: const TextStyle(fontSize: 10)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        minimumSize: const Size(0, 28),
                      ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactFrameCard(StoryFrame frame) {
    final isReused = !frame.generateImage && frame.reuseFrame != null;
    final displayFrameId = isReused ? frame.reuseFrame! : frame.frameId;
    final hasImg = widget.imageBytes.containsKey(displayFrameId);
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isReused ? Colors.blue.shade200 : Colors.grey.shade300),
      ),
      child: Column(children: [
        // Compact header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isReused ? Colors.blue.shade50 : Colors.grey.shade100,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
          ),
          child: Row(children: [
            Text(frame.frameId, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
            const Spacer(),
            if (isReused) 
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(3)),
                child: Text('↩${frame.reuseFrame!.replaceAll("frame_", "")}', 
                  style: const TextStyle(color: Colors.white, fontSize: 8)),
              )
            else if (!frame.generateImage)
              const Icon(Icons.check, color: Colors.green, size: 12),
          ]),
        ),
        // Image
        Expanded(
          child: hasImg 
            ? Stack(fit: StackFit.expand, children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
                  child: Image.memory(widget.imageBytes[displayFrameId]!, fit: BoxFit.cover),
                ),
                if (frame.isGenerating)
                  Container(
                    color: Colors.black38,
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ])
            : Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
                ),
                child: Center(
                  child: frame.isGenerating 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(isReused ? Icons.link : Icons.image, size: 24, color: Colors.grey.shade400),
                ),
              ),
        ),
      ]),
    );
  }

  Widget _buildStatusSummary() {
    if (widget.project == null) return const SizedBox();
    
    final totalFrames = widget.project!.frames.length;
    final framesToGenerate = widget.project!.frames.where((f) => f.generateImage).length;
    final reusedFrames = widget.project!.frames.where((f) => !f.generateImage && f.reuseFrame != null).length;
    final generatedCount = widget.imageBytes.length;
    
    return Row(children: [
      _buildMiniStat('Total', totalFrames, Colors.blue),
      _buildMiniStat('Generate', framesToGenerate, Colors.orange),
      _buildMiniStat('Reuse', reusedFrames, Colors.green),
      _buildMiniStat('Done', generatedCount, Colors.purple),
    ]);
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(children: [
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
      ]),
    );
  }

  Widget _buildClipCard(VideoClip clip) {
    final first = widget.project!.getFrameById(clip.firstFrame);
    final last = widget.project!.getFrameById(clip.lastFrame);
    final isSingleFrame = clip.firstFrame == clip.lastFrame;
    
    return Card(margin: const EdgeInsets.only(bottom: 16), child: Column(children: [
      Container(padding: const EdgeInsets.all(12), color: Colors.deepPurple.shade50,
        child: Row(children: [
          Chip(label: Text(clip.clipId), backgroundColor: Colors.deepPurple, labelStyle: const TextStyle(color: Colors.white)),
          const SizedBox(width: 8), Text('${clip.durationSeconds}s'),
          const SizedBox(width: 16), Expanded(child: Text(clip.veo3Prompt, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700))),
        ])),
      Padding(padding: const EdgeInsets.all(12), child: isSingleFrame
        // Single frame mode - show one larger frame
        ? (first != null ? _buildFrameCard(first) : const SizedBox())
        // Two frame mode - show first and last with arrow
        : Row(children: [
            if (first != null) Expanded(child: _buildFrameCard(first)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, color: Colors.grey)),
            if (last != null) Expanded(child: _buildFrameCard(last)),
          ])),
    ]));
  }

  Widget _buildFrameCard(StoryFrame frame) {
    // Check if frame reuses another frame's image
    final isReused = !frame.generateImage && frame.reuseFrame != null;
    final displayFrameId = isReused ? frame.reuseFrame! : frame.frameId;
    final hasImg = widget.imageBytes.containsKey(displayFrameId);
    
    return Container(decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Container(padding: const EdgeInsets.all(8), color: isReused ? Colors.blue.shade50 : Colors.grey.shade100,
          child: Row(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(
              color: frame.framePosition == 'first' ? Colors.green : Colors.orange, borderRadius: BorderRadius.circular(4)),
              child: Text(frame.framePosition.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 10))),
            const SizedBox(width: 8), 
            Text(frame.frameId, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
            const SizedBox(width: 4),
            // Show generation status indicator
            if (!frame.generateImage) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.shade600,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: const [
                  Icon(Icons.check_circle, color: Colors.white, size: 10),
                  SizedBox(width: 2),
                  Text('NO GEN', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                ]),
              ),
            ],
            // Show reuse indicator
            if (isReused) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: 'Reuses ${frame.reuseFrame}',
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade600,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.link, size: 10, color: Colors.white),
                    const SizedBox(width: 2),
                    Text(frame.reuseFrame!.replaceAll('frame_', ''), 
                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            ],
          ])),
        AspectRatio(aspectRatio: 16/9, child: hasImg ? Stack(fit: StackFit.expand, children: [
          Image.memory(widget.imageBytes[displayFrameId]!, fit: BoxFit.cover),
          // Show "REUSED" badge overlay if this frame reuses another
          if (isReused) Positioned(
            top: 8, left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.shade700.withOpacity(0.9),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white, width: 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.link, color: Colors.white, size: 12),
                const SizedBox(width: 4),
                Text('FROM ${frame.reuseFrame}', 
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
          if (!isReused) Positioned(top: 4, right: 4, child: IconButton(icon: const Icon(Icons.close, size: 16), 
            style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
            onPressed: () => setState(() => widget.imageBytes.remove(frame.frameId)))),
        ]) : Container(color: Colors.grey.shade200, child: frame.isGenerating 
          ? const Center(child: CircularProgressIndicator())
          : Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(isReused ? Icons.link : Icons.image, color: Colors.grey),
              if (isReused) Text('Reuses ${frame.reuseFrame}', 
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            ])))),
        Padding(padding: const EdgeInsets.all(8), child: ElevatedButton(
          onPressed: isReused ? null : (frame.isGenerating ? null : () => _generateFrameWithRetry(frame)),
          style: ElevatedButton.styleFrom(
            backgroundColor: isReused ? Colors.blue.shade100 : null,
          ),
          child: Text(
            isReused ? 'Reused Frame' : (frame.isGenerating ? 'Generating...' : 'Generate'),
            style: TextStyle(color: isReused ? Colors.blue.shade700 : null),
          ))),
        ExpansionTile(title: const Text('Prompt', style: TextStyle(fontSize: 12)), children: [
          Container(height: 100, margin: const EdgeInsets.all(8), padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(4)),
            child: Scrollbar(child: SingleChildScrollView(
              child: SelectableText(frame.processedPrompt ?? '', style: const TextStyle(fontSize: 9, fontFamily: 'monospace'))))),
        ]),
      ]));
  }
}

// ============================================================================
// CLONE YOUTUBE TAB
// ============================================================================
class CloneYouTubeTab extends StatefulWidget {
  final GeminiService geminiApi;
  final WhiskApiService whiskApi;
  final Function(StoryProject) onProjectLoaded;

  const CloneYouTubeTab({super.key, required this.geminiApi, required this.whiskApi, required this.onProjectLoaded});

  @override State<CloneYouTubeTab> createState() => _CloneYouTubeTabState();
}

class _CloneYouTubeTabState extends State<CloneYouTubeTab> {
  final _urlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  String _selectedModel = 'gemini-3-flash-preview';
  int _sceneCount = 30;
  bool _isAnalyzing = false;
  String? _error, _result;
  int _currentBatch = 0, _totalBatches = 0;

  static const _masterPrompt = '''# YouTube Video to VEO3 Story Prompt Generator

Analyze the YouTube video and create a complete story structure with narrative flow.

## JSON Schema Structure

Create a detailed "story bible" capturing:

### 1. Story Object
{
  "title": "Story Title",
  "description": "Brief story overview and narrative arc",
  "visual_style": {
    "art_style": "cinematic style description",
    "color_palette": "dominant colors and tones",
    "lighting": "lighting style description",
    "aspect_ratio": "16:9",
    "quality": "quality descriptors (8K, film grain, etc.)"
  },
  "characters": [...],
  "locations": [...]
}

### 2. Characters Array
Each character must have:
- "id": "char_unique_id"
- "name": "Character Name"
- "description": "Detailed appearance including age, clothing, features"
- "size_index": 1-10 (1=tiny, 2=child, 5=average, 8=very tall, 10=massive)
- "size_reference": "height reference (e.g., average adult 5'10\")"

### 3. Locations Array
- "id": "loc_unique_id"
- "name": "Location Name"
- "description": "Rich environment description"

### 4. Frames Array - CRITICAL: TWO FRAMES PER CLIP + FRAME REUSE
Each video clip requires EXACTLY 2 frames: "first" and "last"

**FRAME REUSE LOGIC (IMPORTANT):**
When clip N+1 starts from same position/angle as clip N ended:
- Set "generate_image": false
- Add "reuse_frame": "frame_XXX" (pointing to previous clip's last frame)

{
  "frame_id": "frame_001",
  "video_clip_id": "video_001",
  "frame_position": "first" or "last",
  "location_id": "loc_id",
  "characters_in_scene": ["char_id1", "char_id2"],
  "prompt": "Detailed scene description for image generation",
  "camera": "shot type, angle, movement",
  "generate_image": true,
  "reuse_frame": "frame_XXX" (optional - when reusing previous frame)
}

### 5. Video Clips Array
{
  "clip_id": "video_001",
  "first_frame": "frame_001",
  "last_frame": "frame_002",
  "duration_seconds": 8,
  "veo3_prompt": "Action description from first to last frame",
  "audio_description": "Sound, music, dialogue description"
}

## Camera Angle Types
- Wide/Establishing: Shows full environment
- Medium Shot: Waist-up, dialogue and action
- Close-up: Face/detail focus, emotional
- Over-the-shoulder: From behind one character
- Low Angle: Camera below eye level, imposing
- High Angle: Camera above, vulnerable/small
- Dutch Angle: Tilted for tension
- POV: First-person perspective
- Tracking: Camera follows subject
- Pan/Tilt: Camera rotates

## Key Rules
1. Each clip has EXACTLY 2 frames (first and last)
2. VEO3 interpolates between these keyframes
3. Use "generate_image": false + "reuse_frame" when clip N+1 starts where clip N ended
4. Include title and description for story context
5. Frame IDs must be unique and sequential
6. Output ONLY valid JSON - no markdown, no explanations

Output complete JSON with "story", "frames", and "video_clips".''';


  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final settingsFile = File('${Directory.current.path}/youtube_clone_settings.json');
      if (await settingsFile.exists()) {
        final json = jsonDecode(await settingsFile.readAsString());
        setState(() {
          _urlController.text = json['youtube_url'] ?? '';
          _apiKeyController.text = json['gemini_api_key'] ?? '';
          _selectedModel = json['selected_model'] ?? 'gemini-3-flash-preview';
          _sceneCount = json['scene_count'] ?? 30;
        });
        print('✅ Loaded saved settings');
      }
    } catch (e) {
      print('⚠️  Could not load settings: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final settingsFile = File('${Directory.current.path}/youtube_clone_settings.json');
      await settingsFile.writeAsString(jsonEncode({
        'youtube_url': _urlController.text,
        'gemini_api_key': _apiKeyController.text,
        'selected_model': _selectedModel,
        'scene_count': _sceneCount,
      }));
      print('💾 Settings saved');
    } catch (e) {
      print('⚠️  Could not save settings: $e');
    }
  }

  Future<void> _analyze() async {
    if (_urlController.text.isEmpty || _apiKeyController.text.isEmpty) {
      setState(() => _error = 'Enter URL and API key');
      return;
    }
    
    widget.geminiApi.apiKey = _apiKeyController.text;
    widget.geminiApi.model = _selectedModel;
    widget.geminiApi.resetCancellation(); // Reset cancellation flag
    
    // Save settings for next time
    await _saveSettings();
    
    setState(() { _isAnalyzing = true; _error = null; _result = null; });
    
    try {
      final result = await widget.geminiApi.analyzeInBatches(
        _urlController.text, 
        _masterPrompt, 
        _sceneCount,
        (current, total) { if (mounted) setState(() { _currentBatch = current; _totalBatches = total; }); },
        (batchResult) {
          // PROGRESSIVE RESULTS: Update UI after each batch
          if (mounted) setState(() => _result = batchResult);
          
          // Don't switch tabs yet - only update JSON display
          // Tab switching happens only when ALL batches are complete
          try {
            final project = StoryProject.fromJson(jsonDecode(batchResult));
            print('✅ Batch complete: ${project.frames.length} frames, ${project.videoClips.length} clips');
          } catch (e) {
            print('⚠️  Could not parse batch result: $e');
          }
        },
      );
      
      if (mounted) setState(() => _result = result);
      
      // Final load
      if (result != null) {
        try {
          final project = StoryProject.fromJson(jsonDecode(result));
          for (final f in project.frames) f.processedPrompt = '${project.visualStyle.toPromptString()}\n${f.prompt ?? ''}';
          widget.onProjectLoaded(project);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('✅ Complete: ${project.frames.length} frames'),
              backgroundColor: Colors.green));
          }
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _isAnalyzing = false);
  }

  void _stopAnalysis() {
    widget.geminiApi.cancelAnalysis();
    setState(() => _isAnalyzing = false);
  }

  Future<void> _startOver() async {
    if (_urlController.text.isEmpty) return;
    
    try {
      final videoId = Uri.parse(_urlController.text).queryParameters['v'] ?? 'unknown';
      final cacheDir = Directory('${Directory.current.path}/yt_stories/$videoId');
      
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        print('🗑️  Cleared cache for video $videoId');
      }
      
      setState(() {
        _result = null;
        _error = null;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Cache cleared! Ready to start fresh.'), backgroundColor: Colors.orange),
        );
      }
    } catch (e) {
      print('⚠️  Error clearing cache: $e');
    }
  }

  Future<void> _openFolder() async {
    if (_urlController.text.isEmpty) return;
    
    try {
      final videoId = Uri.parse(_urlController.text).queryParameters['v'] ?? 'unknown';
      final cacheDir = Directory('${Directory.current.path}/yt_stories/$videoId');
      
      if (await cacheDir.exists()) {
        // Open folder in Windows Explorer
        await Process.run('explorer', [cacheDir.path.replaceAll('/', '\\')]);
        print('📂 Opened folder: ${cacheDir.path}');
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⚠️  No files generated yet. Run analysis first.'), backgroundColor: Colors.orange),
          );
        }
      }
    } catch (e) {
      print('⚠️  Error opening folder: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      // Left Panel - Settings
      Container(width: 400, color: Colors.white, padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.video_library, color: Colors.red.shade600),
            const SizedBox(width: 8),
            const Text('Clone YouTube Video', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          const SizedBox(height: 16),
          TextField(controller: _urlController, decoration: const InputDecoration(
            labelText: 'YouTube URL', hintText: 'https://youtube.com/watch?v=...',
            prefixIcon: Icon(Icons.link), border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _apiKeyController, obscureText: true, decoration: const InputDecoration(
            labelText: 'Gemini API Key', prefixIcon: Icon(Icons.key), border: OutlineInputBorder())),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: _selectedModel, decoration: const InputDecoration(
            labelText: 'AI Model', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'gemini-3-flash-preview', child: Text('Gemini 3 Flash')),
              DropdownMenuItem(value: 'gemini-2.5-flash', child: Text('Gemini 2.5 Flash')),
              DropdownMenuItem(value: 'gemini-2.0-flash', child: Text('Gemini 2.0 Flash')),
            ],
            onChanged: (v) { setState(() => _selectedModel = v!); _saveSettings(); }),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Scene Count: '),
            Expanded(child: Slider(value: _sceneCount.toDouble(), min: 10, max: 100, divisions: 9,
              label: '$_sceneCount', onChanged: (v) { setState(() => _sceneCount = v.round()); _saveSettings(); })),
            Text('$_sceneCount', style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 8),
          Text('Frames: ${_sceneCount * 2} | Batches: ${(_sceneCount / 10).ceil()}', 
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          const SizedBox(height: 16),
          if (_isAnalyzing) Column(children: [
            LinearProgressIndicator(value: _totalBatches > 0 ? _currentBatch / _totalBatches : null),
            const SizedBox(height: 8),
            Text('Analyzing batch $_currentBatch of $_totalBatches...', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _stopAnalysis,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop Analysis'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade700,
                side: BorderSide(color: Colors.red.shade700),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
              ),
            ),
          ]) else ElevatedButton.icon(onPressed: _analyze, icon: const Icon(Icons.auto_awesome),
            label: const Text('Analyze & Generate Prompts'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14))),
          if (!_isAnalyzing && _urlController.text.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: _startOver,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Start Over (Clear Cache)'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.orange.shade700),
            ),
          ),
          if (!_isAnalyzing && _urlController.text.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ElevatedButton.icon(
              onPressed: _openFolder,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Open Folder'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade600,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: const TextStyle(color: Colors.red))),
          const Divider(height: 32),
          const Text('Instructions:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('1. Paste YouTube URL\n2. Enter Gemini API key\n3. Select model & scene count\n4. Click Analyze\n5. Results load in "Create Story" tab',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
        ])),
      // Right Panel - Result
      Expanded(child: Container(color: Colors.grey.shade100, padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('Generated JSON', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_result != null) IconButton(icon: const Icon(Icons.copy),
              onPressed: () { Clipboard.setData(ClipboardData(text: _result!));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied!'))); }),
          ]),
          const SizedBox(height: 8),
          Expanded(child: Container(decoration: BoxDecoration(color: Colors.white, 
            border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
            child: _result == null ? const Center(child: Text('Analyze a video to see results'))
              : Scrollbar(child: SingleChildScrollView(padding: const EdgeInsets.all(12),
                child: SelectableText(_result!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)))))),
        ]))),
    ]);
  }
}

// ============================================================================
// GENERATE VIDEOS TAB - Enhanced with concurrency, retry, and error recovery
// ============================================================================
class GenerateVideosTab extends StatefulWidget {
  final Veo3VideoService veo3Api;
  final StoryProject? project;
  final Map<String, Uint8List> imageBytes;
  final String outputDir;
  final VoidCallback onVeo3Connected;
  final bool autoReusePreviousFrame;

  const GenerateVideosTab({super.key, required this.veo3Api, this.project, 
    required this.imageBytes, required this.outputDir, required this.onVeo3Connected,
    this.autoReusePreviousFrame = true});

  @override State<GenerateVideosTab> createState() => _GenerateVideosTabState();
}

class _GenerateVideosTabState extends State<GenerateVideosTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // Keep tab alive when switching
  bool _isConnected = false;
  bool _isGenerating = false;
  String _status = 'Not connected';
  String _selectedModel = 'veo_3_1_t2v_fast_ultra';
  final List<String> _logs = [];
  String _videosOutputDir = '';
  
  // Credentials for auto-relogin
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  
  // Clip status tracking
  final Map<String, VideoResult> _clipStatus = {};
  int _maxRetries = 10;
  
  // Concurrency control
  int _activeGenerations = 0;
  bool _useRelaxedMode = false;
  
  // Cache for uploaded image mediaIds (imagePath -> mediaId)
  final Map<String, String> _uploadedImageCache = {};
  
  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initOutputDir();
    widget.veo3Api.onLog = _log;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _initOutputDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    _videosOutputDir = path.join(appDir.path, 'story_videos');
    await Directory(_videosOutputDir).create(recursive: true);
  }

  void _log(String message) {
    print(message);
    if (mounted) setState(() {
      _logs.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $message');
    });
    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _connect() async {
    if (mounted) setState(() => _status = 'Connecting...');
    _log('🌐 Connecting to Chrome DevTools...');
    
    final connected = await widget.veo3Api.connect();
    if (connected) {
      _log('✅ Connected to Chrome');
      
      // Save credentials for recovery
      if (_emailController.text.isNotEmpty && _passwordController.text.isNotEmpty) {
        widget.veo3Api.savedEmail = _emailController.text;
        widget.veo3Api.savedPassword = _passwordController.text;
        _log('🔐 Credentials saved for auto-recovery');
      }
      
      _log('🔑 Getting access token...');
      final token = await widget.veo3Api.getAccessToken();
      if (token != null) {
        _log('✅ Access token obtained');
        if (mounted) setState(() {
          _isConnected = true;
          _status = 'Connected & Ready';
        });
        widget.onVeo3Connected();
        _initializeClipStatus();
      } else {
        _log('❌ Failed to get access token');
        _log('💡 Make sure you are logged into labs.google');
        if (mounted) setState(() => _status = 'Token failed - check login');
      }
    } else {
      _log('❌ Failed to connect');
      _log('💡 Chrome must be started with: chrome.exe --remote-debugging-port=9222');
      if (mounted) setState(() => _status = 'Connection failed');
    }
  }

  void _initializeClipStatus() {
    if (widget.project == null) return;
    _clipStatus.clear();
    for (final clip in widget.project!.videoClips) {
      _clipStatus[clip.clipId] = VideoResult(clipId: clip.clipId);
    }
    if (mounted) setState(() {});
    // Auto-load existing videos
    _loadExistingVideos();
  }

  int get _maxConcurrent {
    if (_useRelaxedMode) return 4;
    return 100; // Unlimited for fast mode
  }

  int get _completedCount => _clipStatus.values.where((v) => v.status == VideoStatus.complete).length;
  int get _failedCount => _clipStatus.values.where((v) => v.status == VideoStatus.failed).length;
  int get _pendingCount => _clipStatus.values.where((v) => v.status == VideoStatus.pending).length;

  Future<String?> _getImagePath(StoryFrame? frame) async {
    if (frame == null) return null;
    
    String sourceFrameId = frame.frameId;
    if (!frame.generateImage && frame.reuseFrame != null) {
      sourceFrameId = frame.reuseFrame!;
    }
    
    final imageFile = File(path.join(widget.outputDir, '$sourceFrameId.png'));
    if (await imageFile.exists()) {
      return imageFile.path;
    }
    return null;
  }

  Future<void> _generateSingleVideo(VideoClip clip, {bool isRetry = false, bool isSingle = false}) async {
    final clipId = clip.clipId;
    final result = _clipStatus[clipId]!;
    
    if (!isRetry && result.status != VideoStatus.pending && result.status != VideoStatus.failed) {
      return;
    }
    
    if (result.retryCount >= _maxRetries) {
      _log('❌ $clipId: Max retries ($_maxRetries) reached');
      result.status = VideoStatus.failed;
      result.error = 'Max retries exceeded';
      if (mounted) setState(() {});
      return;
    }
    
    // For batch mode, check if cancelled. For single mode, always proceed.
    if (!isSingle && !_isGenerating) {
      _log('⏹️ $clipId: Cancelled before start');
      return;
    }
    
    if (mounted) setState(() {
      result.status = VideoStatus.uploading;
      result.startTime = DateTime.now();
      if (isRetry) result.retryCount++;
      _activeGenerations++;
    });
    
    _log('\n========================================');
    _log('🎬 ${isRetry ? "RETRY" : "Generating"} $clipId (Attempt ${result.retryCount + 1}/$_maxRetries)');
    _log('========================================');
    
    try {
      final firstFrame = widget.project!.getFrameById(clip.firstFrame);
      final lastFrame = widget.project!.getFrameById(clip.lastFrame);
      
      String? startImagePath;
      
      // Auto-reuse: Use previous clip's end frame as this clip's start frame
      if (widget.autoReusePreviousFrame && firstFrame != null) {
        // Find current clip index
        final clips = widget.project!.videoClips;
        final currentIndex = clips.indexWhere((c) => c.clipId == clipId);
        
        if (currentIndex > 0) {
          // Not the first clip - try to reuse previous clip's end frame
          final prevClip = clips[currentIndex - 1];
          final prevLastFrame = widget.project!.getFrameById(prevClip.lastFrame);
          final prevEndImagePath = await _getImagePath(prevLastFrame);
          
          if (prevEndImagePath != null) {
            startImagePath = prevEndImagePath;
            _log('♻️ Auto-reusing previous clip\'s end frame: ${prevEndImagePath.split(Platform.pathSeparator).last}');
          } else {
            _log('⚠️ Auto-reuse enabled but previous end frame not found, using original start frame');
            startImagePath = await _getImagePath(firstFrame);
          }
        } else {
          // First clip - use its own start frame
          startImagePath = await _getImagePath(firstFrame);
        }
      } else {
        // Auto-reuse disabled - use original logic
        startImagePath = await _getImagePath(firstFrame);
      }
      
      final endImagePath = await _getImagePath(lastFrame);
      
      if (startImagePath == null || endImagePath == null) {
        throw Exception('Missing images for $clipId');
      }
      
      _log('🖼️ Start: ${startImagePath.split(Platform.pathSeparator).last}');
      _log('🖼️ End: ${endImagePath.split(Platform.pathSeparator).last}');
      
      // Check cancellation before upload (only in batch mode)
      if (!isSingle && !_isGenerating) {
        _log('⏹️ $clipId: Cancelled before upload');
        result.status = VideoStatus.cancelled;
        return;
      }
      
      // Upload or use cached start image
      String? startMediaId;
      if (_uploadedImageCache.containsKey(startImagePath)) {
        startMediaId = _uploadedImageCache[startImagePath];
        _log('✅ Start image cached: ${startMediaId!.substring(0, 20)}...');
      } else {
        _log('📤 Uploading start image...');
        startMediaId = await widget.veo3Api.uploadImage(startImagePath);
        if (startMediaId == null) throw Exception('Failed to upload start image');
        _uploadedImageCache[startImagePath] = startMediaId;
        _log('💾 Cached start image mediaId');
      }
      
      // Check cancellation after first upload (only in batch mode)
      if (!isSingle && !_isGenerating) {
        _log('⏹️ $clipId: Cancelled after start image upload');
        result.status = VideoStatus.cancelled;
        return;
      }
      
      // Upload or use cached end image
      String? endMediaId;
      if (_uploadedImageCache.containsKey(endImagePath)) {
        endMediaId = _uploadedImageCache[endImagePath];
        _log('✅ End image cached: ${endMediaId!.substring(0, 20)}...');
      } else {
        _log('📤 Uploading end image...');
        endMediaId = await widget.veo3Api.uploadImage(endImagePath);
        if (endMediaId == null) throw Exception('Failed to upload end image');
        _uploadedImageCache[endImagePath] = endMediaId;
        _log('💾 Cached end image mediaId');
      }
      
      // Check cancellation after uploads (only in batch mode)
      if (!isSingle && !_isGenerating) {
        _log('⏹️ $clipId: Cancelled after uploads');
        result.status = VideoStatus.cancelled;
        return;
      }
      
      if (mounted) setState(() => result.status = VideoStatus.generating);
      
      // Build prompt
      String fullPrompt = clip.veo3Prompt;
      if (clip.audioDescription.isNotEmpty) {
        fullPrompt += '\n\nAudio: ${clip.audioDescription}';
      }
      
      // Start generation
      _log('🎬 Starting video generation...');
      final genResult = await widget.veo3Api.startVideoGeneration(
        prompt: fullPrompt,
        startImageMediaId: startMediaId,
        endImageMediaId: endMediaId,
        model: _selectedModel,
      );
      
      if (genResult == null || genResult['success'] != true) {
        throw Exception('Generation API failed');
      }
      
      // Extract operation name - handle both 'responses' and 'operations' formats
      final data = genResult['data'] as Map<String, dynamic>;
      String? operationName;
      
      // Try 'responses' format first
      if (data.containsKey('responses')) {
        final responses = data['responses'] as List?;
        if (responses != null && responses.isNotEmpty) {
          operationName = responses[0]['name'] as String?;
        }
      }
      
      // Try 'operations' format
      if (operationName == null && data.containsKey('operations')) {
        final operations = data['operations'] as List?;
        if (operations != null && operations.isNotEmpty) {
          final op = operations[0];
          if (op is Map) {
            // Could be nested as op['operation']['name'] or directly op['name']
            if (op.containsKey('operation')) {
              operationName = op['operation']?['name'] as String?;
            }
            operationName ??= op['name'] as String?;
          }
        }
      }
      
      if (operationName == null) {
        _log('❌ Could not extract operation name from: ${data.keys.toList()}');
        throw Exception('No operation name in response');
      }
      
      final sceneId = genResult['sceneId'] as String;
      _log('📋 Operation: $operationName');
      _log('📋 Scene ID: $sceneId');
      
      if (mounted) setState(() {
        result.status = VideoStatus.polling;
        result.operationName = operationName;
        result.sceneId = sceneId;
      });
      
      // Poll and download
      final outputPath = path.join(_videosOutputDir, '$clipId.mp4');
      final videoPath = await widget.veo3Api.waitAndDownload(
        operationName: operationName,
        sceneId: sceneId,
        outputPath: outputPath,
      );
      
      if (videoPath != null) {
        result.status = VideoStatus.complete;
        result.videoPath = videoPath;
        _log('✅ $clipId complete!');
      } else {
        throw Exception('Video download failed');
      }
    } catch (e) {
      _log('❌ $clipId failed: $e');
      result.status = VideoStatus.failed;
      result.error = e.toString();
      
      // Auto-retry if under limit
      if (result.retryCount < _maxRetries - 1) {
        _log('🔄 Will retry $clipId...');
        await Future.delayed(const Duration(seconds: 3));
        if (_isGenerating) {
          await _generateSingleVideo(clip, isRetry: true);
          return;
        }
      }
    } finally {
      if (mounted) setState(() => _activeGenerations--);
    }
  }

  Future<void> _generateAllVideos() async {
    if (widget.project == null) return;
    
    _initializeClipStatus();
    if (mounted) setState(() => _isGenerating = true);
    widget.veo3Api.resetCancellation();
    
    final clips = widget.project!.videoClips;
    _log('🎬 Starting generation for ${clips.length} clips (max concurrent: $_maxConcurrent)');
    
    // Create a queue of pending clips
    final pendingQueue = List<VideoClip>.from(clips);
    
    // Worker function that processes clips from the queue
    Future<void> worker(int slotId) async {
      while (pendingQueue.isNotEmpty && _isGenerating) {
        // Get next clip from queue
        final clip = pendingQueue.removeAt(0);
        _log('🔧 Slot $slotId: Starting ${clip.clipId}');
        
        try {
          await _generateSingleVideo(clip);
        } catch (e) {
          _log('❌ Slot $slotId: Error processing ${clip.clipId}: $e');
        }
        
        // Small delay between tasks
        await Future.delayed(const Duration(milliseconds: 200));
      }
      _log('🔧 Slot $slotId: Finished (no more pending clips)');
    }
    
    // Start workers up to maxConcurrent
    final workerCount = _maxConcurrent.clamp(1, clips.length);
    final workers = <Future<void>>[];
    
    for (int i = 0; i < workerCount; i++) {
      workers.add(worker(i + 1));
    }
    
    // Wait for all workers to complete
    await Future.wait(workers);
    
    if (mounted) setState(() => _isGenerating = false);
    _log('\n========================================');
    _log('✅ Batch complete!');
    _log('📊 Success: $_completedCount | Failed: $_failedCount');
    _log('========================================\n');
  }

  Future<void> _retryFailed() async {
    if (widget.project == null) return;
    
    final failedClips = widget.project!.videoClips.where((c) {
      final status = _clipStatus[c.clipId];
      return status?.status == VideoStatus.failed;
    }).toList();
    
    if (failedClips.isEmpty) {
      _log('ℹ️ No failed clips to retry');
      return;
    }
    
    if (mounted) setState(() => _isGenerating = true);
    widget.veo3Api.resetCancellation();
    _log('🔄 Retrying ${failedClips.length} failed clips with $_maxConcurrent concurrent slots...');
    
    // Create queue of failed clips
    final pendingQueue = List<VideoClip>.from(failedClips);
    
    // Reset retry counts
    for (final clip in failedClips) {
      _clipStatus[clip.clipId]!.retryCount = 0;
    }
    
    // Worker function
    Future<void> worker(int slotId) async {
      while (pendingQueue.isNotEmpty && _isGenerating) {
        final clip = pendingQueue.removeAt(0);
        _log('🔧 Retry Slot $slotId: Starting ${clip.clipId}');
        
        try {
          await _generateSingleVideo(clip, isRetry: true);
        } catch (e) {
          _log('❌ Retry Slot $slotId: Error processing ${clip.clipId}: $e');
        }
        
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    
    // Start workers
    final workerCount = _maxConcurrent.clamp(1, failedClips.length);
    final workers = <Future<void>>[];
    
    for (int i = 0; i < workerCount; i++) {
      workers.add(worker(i + 1));
    }
    
    await Future.wait(workers);
    
    if (mounted) setState(() => _isGenerating = false);
    _log('✅ Retry batch complete!');
  }

  void _stopGeneration() {
    widget.veo3Api.cancelOperations();
    if (mounted) setState(() => _isGenerating = false);
    _log('⏹️ Generation stopped');
  }

  Future<void> _loadExistingVideos() async {
    _log('\n📂 Scanning for existing videos...');
    
    final dir = Directory(_videosOutputDir);
    if (!await dir.exists()) {
      _log('❌ Videos folder does not exist');
      return;
    }
    
    int loadedCount = 0;
    final files = await dir.list().toList();
    
    for (final entity in files) {
      if (entity is File && entity.path.toLowerCase().endsWith('.mp4')) {
        final fileName = path.basename(entity.path);
        final clipId = fileName.replaceAll('.mp4', '');
        
        // Mark as complete if in our status
        if (_clipStatus.containsKey(clipId)) {
          _clipStatus[clipId]!.status = VideoStatus.complete;
          _clipStatus[clipId]!.videoPath = entity.path;
          loadedCount++;
          _log('✅ Found: $fileName');
        }
      }
    }
    
    if (mounted) setState(() {});
    _log('📂 Found $loadedCount existing videos');
  }

  Future<void> _openOutputFolder() async {
    if (_videosOutputDir.isNotEmpty) {
      final uri = Uri.file(_videosOutputDir.replaceAll('/', '\\'));
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    }
  }

  Color _getStatusColor(VideoStatus status) {
    switch (status) {
      case VideoStatus.complete: return Colors.green;
      case VideoStatus.failed: return Colors.red;
      case VideoStatus.generating:
      case VideoStatus.polling:
      case VideoStatus.downloading: return Colors.blue;
      case VideoStatus.uploading: return Colors.orange;
      default: return Colors.grey;
    }
  }

  String _getStatusText(VideoStatus status) {
    switch (status) {
      case VideoStatus.complete: return 'Complete';
      case VideoStatus.failed: return 'Failed';
      case VideoStatus.generating: return 'Generating...';
      case VideoStatus.polling: return 'Processing...';
      case VideoStatus.downloading: return 'Downloading...';
      case VideoStatus.uploading: return 'Uploading...';
      case VideoStatus.cancelled: return 'Cancelled';
      default: return 'Pending';
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final clips = widget.project?.videoClips ?? [];
    
    return Row(children: [
      // Left Panel - Controls
      Container(width: 380, color: Colors.white, padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.movie_creation, color: Colors.deepPurple.shade700),
            const SizedBox(width: 8),
            const Text('VEO3 Video Generator', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          const SizedBox(height: 16),
          
          // Connection Status
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _isConnected ? Colors.green.shade50 : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _isConnected ? Colors.green.shade300 : Colors.orange.shade300),
            ),
            child: Row(children: [
              Icon(_isConnected ? Icons.check_circle : Icons.warning,
                color: _isConnected ? Colors.green.shade700 : Colors.orange.shade700),
              const SizedBox(width: 8),
              Expanded(child: Text(_status)),
            ]),
          ),
          
          if (!_isConnected) ...[
            const SizedBox(height: 16),
            const Text('Login Credentials (for auto-recovery):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(controller: _emailController, decoration: const InputDecoration(
              labelText: 'Google Email', border: OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            TextField(controller: _passwordController, obscureText: true, decoration: const InputDecoration(
              labelText: 'Password', border: OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _connect,
              icon: const Icon(Icons.link),
              label: const Text('Connect to Chrome'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
            ),
          ],
          
          if (_isConnected) ...[
            const Divider(height: 24),
            
            // Model Selection
            DropdownButtonFormField<String>(value: _selectedModel,
              decoration: const InputDecoration(labelText: 'VEO3 Model', border: OutlineInputBorder(), isDense: true),
              items: const [
                DropdownMenuItem(value: 'veo_3_1_t2v_fast_ultra', child: Text('VEO 3.1 Fast (Unlimited)')),
                DropdownMenuItem(value: 'veo_3_1_t2v_quality_ultra', child: Text('VEO 3.1 Quality (Unlimited)')),
                DropdownMenuItem(value: 'veo_3_1_t2v_fast_ultra_relaxed', child: Text('VEO 3.1 Fast Relaxed (Max 4)')),
                DropdownMenuItem(value: 'veo_2_t2v_fast', child: Text('VEO 2 Fast')),
              ],
              onChanged: (v) => setState(() {
                _selectedModel = v!;
                _useRelaxedMode = v.contains('_relaxed');
              })),
            
            const SizedBox(height: 12),
            
            // Auto-reuse status indicator (toggle is in AppBar)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: widget.autoReusePreviousFrame ? Colors.purple.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: widget.autoReusePreviousFrame ? Colors.purple.shade200 : Colors.grey.shade300),
              ),
              child: Row(children: [
                Icon(widget.autoReusePreviousFrame ? Icons.link : Icons.link_off,
                  size: 18, color: widget.autoReusePreviousFrame ? Colors.purple : Colors.grey),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  widget.autoReusePreviousFrame 
                    ? 'Auto-Reuse ON: Using previous clip\'s end frame as start' 
                    : 'Auto-Reuse OFF: Using each clip\'s own start frame',
                  style: TextStyle(fontSize: 12, color: widget.autoReusePreviousFrame ? Colors.purple.shade700 : Colors.grey.shade600))),
              ]),
            ),
            
            const SizedBox(height: 12),
            
            // Stats
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Project: ${widget.project?.title ?? 'None'}', style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Row(children: [
                  _buildStat('Total', clips.length, Colors.blue),
                  _buildStat('Done', _completedCount, Colors.green),
                  _buildStat('Failed', _failedCount, Colors.red),
                  _buildStat('Active', _activeGenerations, Colors.orange),
                ]),
              ]),
            ),
            
            const SizedBox(height: 16),
            
            // Buttons
            if (_isGenerating) ...[
              LinearProgressIndicator(value: clips.isNotEmpty ? _completedCount / clips.length : 0),
              const SizedBox(height: 8),
              Text('Active: $_activeGenerations | Complete: $_completedCount/${clips.length}', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _stopGeneration,
                icon: const Icon(Icons.stop),
                label: const Text('Stop All'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              ),
            ] else ...[
              ElevatedButton.icon(
                onPressed: clips.isNotEmpty ? _generateAllVideos : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Generate All Videos'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
              ),
              const SizedBox(height: 8),
              if (_failedCount > 0)
                ElevatedButton.icon(
                  onPressed: _retryFailed,
                  icon: const Icon(Icons.refresh),
                  label: Text('Retry Failed ($_failedCount)'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                ),
            ],
            
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _openOutputFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open Videos Folder'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _loadExistingVideos,
              icon: const Icon(Icons.refresh),
              label: const Text('Load Existing Videos'),
            ),
          ],
          
          const Divider(height: 24),
          const Text('Instructions:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 4),
          Text('• Start Chrome with: --remote-debugging-port=9222\n• Log into labs.google\n• Enter credentials above for auto-recovery\n• Max 10 retries per video\n• Relaxed mode: max 4 concurrent',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
        ]))),
      
      // Middle Panel - Clip Status
      Container(width: 320, color: Colors.grey.shade50,
        child: Column(children: [
          Container(padding: const EdgeInsets.all(12), color: Colors.grey.shade200,
            child: const Row(children: [Text('Clip Status', style: TextStyle(fontWeight: FontWeight.bold))])),
          Expanded(child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: clips.length,
            itemBuilder: (ctx, i) {
              final clip = clips[i];
              final status = _clipStatus[clip.clipId] ?? VideoResult(clipId: clip.clipId);
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(
                        color: _getStatusColor(status.status), shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      Text(clip.clipId, style: const TextStyle(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text(_getStatusText(status.status), style: TextStyle(
                        color: _getStatusColor(status.status), fontSize: 11)),
                    ]),
                    if (status.retryCount > 0) Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Retries: ${status.retryCount}/$_maxRetries', 
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                    ),
                    if (status.error != null) Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(status.error!, style: const TextStyle(fontSize: 10, color: Colors.red), maxLines: 2),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      if (status.status == VideoStatus.pending || status.status == VideoStatus.failed)
                        Expanded(child: OutlinedButton.icon(
                          onPressed: _isGenerating ? null : () => _generateSingleVideo(clip, isRetry: status.status == VideoStatus.failed, isSingle: true),
                          icon: Icon(status.status == VideoStatus.failed ? Icons.refresh : Icons.play_arrow, size: 16),
                          label: Text(status.status == VideoStatus.failed ? 'Retry' : 'Generate', style: const TextStyle(fontSize: 11)),
                        )),
                      if (status.status == VideoStatus.complete)
                        Expanded(child: OutlinedButton.icon(
                          onPressed: () async {
                            if (status.videoPath != null) {
                              final uri = Uri.file(status.videoPath!);
                              if (await canLaunchUrl(uri)) await launchUrl(uri);
                            }
                          },
                          icon: const Icon(Icons.play_circle, size: 16),
                          label: const Text('Play', style: TextStyle(fontSize: 11)),
                        )),
                    ]),
                  ])),
              );
            },
          )),
        ])),
      
      // Right Panel - Logs
      Expanded(child: Container(color: Colors.grey.shade900, padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('Generation Log', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.grey),
              onPressed: () => setState(() => _logs.clear()), tooltip: 'Clear'),
          ]),
          const SizedBox(height: 8),
          Expanded(child: Container(
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
            child: Scrollbar(
              controller: _logScrollController,
              child: ListView.builder(
                controller: _logScrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _logs.length,
                itemBuilder: (ctx, i) {
                  final log = _logs[i];
                  Color color = Colors.grey.shade400;
                  if (log.contains('✅')) color = Colors.green.shade400;
                  if (log.contains('❌')) color = Colors.red.shade400;
                  if (log.contains('⚠️')) color = Colors.orange.shade400;
                  if (log.contains('🎬')) color = Colors.purple.shade300;
                  if (log.contains('========')) color = Colors.blue.shade400;
                  return Padding(padding: const EdgeInsets.symmetric(vertical: 1),
                    child: SelectableText(log, style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 10)));
                },
              ),
            ),
          )),
        ]))),
    ]);
  }

  Widget _buildStat(String label, int value, Color color) {
    return Expanded(child: Column(children: [
      Text('$value', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
    ]));
  }
}
