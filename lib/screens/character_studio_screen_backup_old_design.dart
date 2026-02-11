import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../models/character_studio/character_data.dart';
import '../models/character_studio/image_model_config.dart';
import '../services/gemini_hub_connector.dart';
import '../services/gemini_api_service.dart';
import '../services/project_service.dart';
import 'package:path/path.dart' as path;

/// Character Studio — Full
/// Port of Python new_simplified.py to Flutter
class CharacterStudioScreen extends StatefulWidget {
  final ProjectService projectService;
  final bool isActivated;

  const CharacterStudioScreen({
    super.key,
    required this.projectService,
    required this.isActivated,
  });

  @override
  State<CharacterStudioScreen> createState() => _CharacterStudioScreenState();
}

class _CharacterStudioScreenState extends State<CharacterStudioScreen> with SingleTickerProviderStateMixin {
  // ====================== TAB CONTROLLER ======================
  TabController? _tabController;
  
  // Story Prompt Tab State
  final TextEditingController _storyInputController = TextEditingController();
  final TextEditingController _promptCountController = TextEditingController(text: '10');
  String _selectedStoryModel = 'gemini-2.5-flash';
  final List<Map<String, String>> _storyModels = [
    {'name': 'Gemini 3 Flash Preview', 'id': 'gemini-3-flash-preview'},
    {'name': 'Gemini 2.5 Flash', 'id': 'gemini-2.5-flash'},
    {'name': 'Gemini 2.5 Flash Preview', 'id': 'gemini-2.5-flash-preview-09-2025'},
  ];
  bool _storyGenerating = false;
  bool _useStructuredOutput = true;
  bool _useTemplate = false; // When false, just use raw story input as prompt
  bool _isCopied = false;
  bool _isSaved = false;
  List<Map<String, dynamic>> _generatedPrompts = [];
  Map<String, dynamic>? _generatedFullOutput; // Store full output with character_reference
  String? _rawResponse; // Store raw server response for display
  final TextEditingController _responseEditorController = TextEditingController();
  final ScrollController _responseScrollController = ScrollController();
  int _responseViewTab = 0; // 0 = Prompts Grid, 1 = Raw Response
  
  // Template System
  String _selectedTemplate = 'char_consistent';
  final Map<String, Map<String, dynamic>> _promptTemplates = {
    'char_consistent': {
      'name': 'Character Consistent Masterprompt',
      'prompt': '''You are given a story.

Your task is to extract characters and scenes using character IDs where each ID already represents a specific outfit/look.

There is NO separate outfit tracking.

1. CHARACTER EXTRACTION (MANDATORY)
Extract every character appearing anywhere in the story (major or minor).

1.1 Character Identity Rule (CRITICAL)
If the same person appears in different outfits or looks, you MUST:
- Create separate character IDs for each outfit/look
- Treat each ID as a fully independent character
❌ Do NOT create parent/child relationships
❌ Do NOT inherit or reference another character ID
Each character ID must be treated as a standalone visual entity.

1.2 Character ID Naming Convention (MANDATORY)
Use this format: {name}_outfit_001, {name}_outfit_002, {name}_outfit_003
Example: anika_outfit_001 → Anika in outfit/look A, anika_outfit_002 → Anika in outfit/look B
⚠ These IDs must never reference each other.

1.3 Character Description (OUTFIT INCLUDED HERE)
For each character ID, generate a complete English description including:
- physical appearance
- personality
- clothing / outfit / accessories (fully described here)
If no info is available → "not clearly described"

2. CHARACTER OBJECT STRUCTURE
Each character ID must follow this structure:
{ "id": "unique character ID", "name": "English name", "description": "appearance, personality, and full outfit description" }
🚫 No outfit attribute, 🚫 No clothing arrays

3. CHARACTER TRACKING
List all character IDs under: output_structure.characters.included_characters

4. SCENE CONSTRUCTION (LOGICAL PRESENCE RULE)
Break the story into exactly [SCENE_COUNT] continuous scenes.

4.1 Character Presence Rules
A character ID appears in a scene ONLY IF physically present.
❌ Do NOT include characters who are: mentioned verbally, remembered, imagined, referenced by possession

4.2 Clothing & Appearance Rules
Do NOT describe outfits again inside scenes. A character's visual appearance is fixed by its character ID.
❌ No clothing_appearance field

5. SCENE STRUCTURE
Each scene must follow:
{
  "scene_number": N,
  "prompt": "Visual description of the scene start (setting, lighting, composition) using ONLY character IDs. Do NOT describe the action/motion happening over time here.",
  "video_action_prompt": "Detailed description of the motion and action that happens in this scene. e.g. 'The character walks from left to right while waving'. This describes the video evolution.",
  "characters_in_scene": ["CharacterID1"],
  "negative_prompt": "do not alter character appearances, no extra characters, no distorted features, avoid text in image"
}

6. BACKGROUND MUSIC
You must also generate a list of background music prompts.
- Divide the total story duration into blocks (approx 30-40s each, or when mood changes).
- Assume each scene is approx 8 seconds long.
- Create a bgmusic array where each item covers a time range and provides a music prompt.

Structure:
{
  "start_time": "0s",
  "end_time": "32s",
  "prompt": "Upbeat cinematic orchestral music, adventurous mood"
}

Story:
[STORY_TEXT]

Generate exactly [SCENE_COUNT] scenes.''',
      'schema': {
        "type": "OBJECT",
        "properties": {
          "character_reference": {
            "type": "ARRAY",
            "items": {
              "type": "OBJECT",
              "properties": {
                "id": {"type": "STRING"},
                "name": {"type": "STRING"},
                "description": {"type": "STRING"}
              },
              "required": ["id", "name", "description"]
            }
          },
          "output_structure": {
            "type": "OBJECT",
            "properties": {
              "story_title": {"type": "STRING"},
              "duration": {"type": "STRING"},
              "style": {"type": "STRING"},
              "characters": {
                "type": "OBJECT",
                "properties": {
                  "included_characters": {
                    "type": "ARRAY",
                    "items": {"type": "STRING"}
                  }
                }
              },
              "scenes": {
                "type": "ARRAY",
                "items": {
                  "type": "OBJECT",
                  "properties": {
                    "scene_number": {"type": "INTEGER"},
                    "prompt": {"type": "STRING"},
                    "video_action_prompt": {"type": "STRING"},
                    "characters_in_scene": {
                      "type": "ARRAY",
                      "items": {"type": "STRING"}
                    },
                    "negative_prompt": {"type": "STRING"}
                  },
                  "required": ["scene_number", "prompt", "video_action_prompt", "characters_in_scene"]
                }
              },
              "bgmusic": {
                "type": "ARRAY",
                "items": {
                  "type": "OBJECT",
                  "properties": {
                    "start_time": {"type": "STRING"},
                    "end_time": {"type": "STRING"},
                    "prompt": {"type": "STRING"}
                  },
                  "required": ["start_time", "end_time", "prompt"]
                }
              }
            },
            "required": ["scenes", "characters", "story_title", "bgmusic"]
          }
        },
        "required": ["character_reference", "output_structure"]
      }
    },
    'simple': {
      'name': 'Simple Scene Prompts',
      'prompt': '''Analyze the following story and generate exactly [SCENE_COUNT] scene prompts for image generation.

For each scene:
1. Describe the visual scene in detail
2. Include character descriptions, actions, environment, lighting, mood
3. Make it suitable for AI image generation
4. Keep each prompt 2-4 sentences

Story:
[STORY_TEXT]

Generate [SCENE_COUNT] scene prompts.''',
      'schema': {
        "type": "ARRAY",
        "items": {
          "type": "OBJECT",
          "properties": {
            "scene_number": {"type": "INTEGER"},
            "prompt": {"type": "STRING"},
          },
          "required": ["scene_number", "prompt"]
        }
      }
    },
  };
  
  // ====================== STATE ======================
  
  // JSON Data
  String? _jsonPath;
  Map<String, dynamic> _data = {};
  List<Map<String, dynamic>> _scenes = [];
  List<CharacterData> _characters = [];
  
  // Image Models
  List<ImageModelConfig> _imageModels = [];
  ImageModelConfig? _selectedImageModel;
  
  // Profiles
  List<String> _profiles = ['Default'];
  String _selectedProfile = 'Default';
  
  // CDP for Image Generation (old app)
  final Map<int, GeminiHubConnector> _cdpHubs = {};
  final int _cdpBasePort = 9222;
  bool _cdpRunning = false;
  late String _cdpOutputFolder;
  
  // Gemini API for Story Prompt Tab (official Google AI API with multi-key support)
  GeminiApiService? _geminiApi;
  
  // UI State
  int _selectedSceneIndex = 0;
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _logController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();
  final ScrollController _charsScrollController = ScrollController();
  
  // Generation Settings
  final TextEditingController _fromRangeController = TextEditingController(text: '1');
  final TextEditingController _toRangeController = TextEditingController(text: '10');
  final TextEditingController _batchSizeController = TextEditingController(text: '2');
  final TextEditingController _delayController = TextEditingController(text: '1');
  final TextEditingController _retriesController = TextEditingController(text: '1');
  final TextEditingController _profileCountController = TextEditingController(text: '3');
  String _aspectRatio = '16:9';
  bool _includeHistory = true;  // Include previous 5 prompts in context
  
  // Status
  String _statusMessage = 'Ready';
  String _browserStatus = '● 0 Browsers';
  String _detectedCharsDisplay = '';
  List<String> _generatedImagePaths = [];  // Store paths of generated images
  bool _logCollapsed = true;  // Log panel collapsed by default
  
  // Live Generation Stats
  int _statsTotal = 0;
  int _statsGenerating = 0;
  int _statsPolling = 0;
  int _statsCompleted = 0;
  int _statsFailed = 0;
  
  // Character Image Generation
  static const List<String> _charImageStyles = [
    'Realistic',
    '3D Pixar',
    '2D Cartoon',
    'Anime',
    'Watercolor',
    'Oil Painting',
  ];
  String _selectedCharStyle = 'Realistic';
  bool _charGenerating = false;
  final Map<String, String> _charImagePrompts = {}; // imagePath -> prompt used
  
  // ====================== INIT / DISPOSE ======================
  
  @override
  void initState() {
    super.initState();
    // Initialize TabController (use ??= for hot reload safety)
    _tabController ??= TabController(length: 2, vsync: this);
    
    // Load Gemini API key
    _loadGeminiApiKey();
    
    // Use Downloads folder for output
    _cdpOutputFolder = path.join(Platform.environment['USERPROFILE'] ?? Directory.current.path, 'Downloads');
    _loadImageModels();
    _loadProfiles();
    _loadExistingCharacterImages();
    _loadSessionState(); // Restore previous session
  }
  
  Future<void> _loadGeminiApiKey() async {
    // Load multi-key service from file
    _geminiApi = await GeminiApiService.loadFromFile();
    
    if (_geminiApi!.keyCount > 0) {
      _log('✅ Loaded ${_geminiApi!.keyCount} Gemini API keys');
      setState(() {});
    } else {
      _log('⚠️ No Gemini API keys found. Click the key icon to add API keys.');
    }
  }
  
  @override
  void dispose() {
    _tabController?.dispose();
    _storyInputController.dispose();
    _promptCountController.dispose();
    _responseEditorController.dispose();
    _responseScrollController.dispose();
    for (final c in _cdpHubs.values) {
      c.close();
    }
    _promptController.dispose();
    _logController.dispose();
    _logScrollController.dispose();
    _charsScrollController.dispose();
    _fromRangeController.dispose();
    _toRangeController.dispose();
    _batchSizeController.dispose();
    _delayController.dispose();
    _retriesController.dispose();
    _profileCountController.dispose();
    super.dispose();
  }
  
  // ====================== LOGGING ======================
  
  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      final t = DateTime.now().toIso8601String().substring(11, 19);
      _logController.text += '[$t] $msg\n';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }
  
  void _clearLog() => setState(() => _logController.text = '');
  void _setStatus(String msg) => setState(() => _statusMessage = msg);
  
  // ====================== SESSION STATE PERSISTENCE ======================
  
  Future<void> _loadSessionState() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final sessionFile = File(path.join(appDir.path, 'VEO3', 'character_studio_session.json'));
      
      if (await sessionFile.exists()) {
        final content = await sessionFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        
        if (json['jsonPath'] != null && json['jsonPath'].toString().isNotEmpty) {
          final jsonFile = File(json['jsonPath']);
          if (await jsonFile.exists()) {
            _jsonPath = json['jsonPath'];
            _log('📂 Restoring: ${path.basename(_jsonPath!)}');
            await _loadJson(filePath: _jsonPath); // Prevent picker
          }
        }
        
        // Restore settings
        if (json['aspectRatio'] != null) _aspectRatio = json['aspectRatio'];
        if (json['fromRange'] != null) _fromRangeController.text = json['fromRange'];
        if (json['toRange'] != null) _toRangeController.text = json['toRange'];
        if (json['includeHistory'] != null) _includeHistory = json['includeHistory'];
        if (json['browserCount'] != null) _profileCountController.text = json['browserCount'];
        if (json['retryCount'] != null) _retriesController.text = json['retryCount'];
        if (json['batchSize'] != null) _batchSizeController.text = json['batchSize'];
        if (json['delay'] != null) _delayController.text = json['delay'];
        
        setState(() {});
      }
    } catch (e) {
      _log('Session restore failed: $e');
    }
  }
  
  Future<void> _saveSessionState() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final sessionDir = Directory(path.join(appDir.path, 'VEO3'));
      if (!await sessionDir.exists()) await sessionDir.create(recursive: true);
      
      final sessionFile = File(path.join(sessionDir.path, 'character_studio_session.json'));
      final json = {
        'jsonPath': _jsonPath,
        'aspectRatio': _aspectRatio,
        'fromRange': _fromRangeController.text,
        'toRange': _toRangeController.text,
        'includeHistory': _includeHistory,
        'browserCount': _profileCountController.text,
        'retryCount': _retriesController.text,
        'batchSize': _batchSizeController.text,
        'delay': _delayController.text,
      };
      await sessionFile.writeAsString(jsonEncode(json));
    } catch (_) {}
  }
  
  // ====================== LOAD EXISTING CHARACTER IMAGES ======================
  
  Future<void> _loadExistingCharacterImages() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final charRootDir = Directory(path.join(appDir.path, 'VEO3', 'characters'));
      if (!await charRootDir.exists()) return;
      
      _log('📁 Scanning character folder for matches...');
      
      // Instead of scanning all folders and adding them, 
      // we only look for images belonging to the characters WE PARSED FROM JSON.
      for (final character in _characters) {
        final charDir = Directory(path.join(charRootDir.path, character.id));
        if (await charDir.exists()) {
          final files = await charDir.list().where((e) => e is File).toList();
          for (final file in files) {
            final ext = path.extension(file.path).toLowerCase();
            if (['.png', '.jpg', '.jpeg', '.webp'].contains(ext)) {
              if (!character.images.contains(file.path)) {
                character.images.add(file.path);
              }
            }
          }
          _log('✅ Loaded ${character.images.length} images for ${character.id}');
        }
      }

      if (mounted) setState(() {});
    } catch (e) {
      _log('⚠️ Failed to load existing char images: $e');
    }
  }
  
  // ====================== IMAGE MODELS ======================
  
  Future<void> _loadImageModels() async {
    final configPath = path.join(Directory.current.path, 'image_models_config.json');
    final configFile = File(configPath);
    
    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        final List<dynamic> json = jsonDecode(content);
        _imageModels = json.map((e) => ImageModelConfig.fromJson(e)).toList();
      } catch (e) {
        _log('Failed to load image models: $e');
      }
    }
    
    // Default options: Nano Banana (default) and Imagen 4
    if (_imageModels.isEmpty) {
      _imageModels = [
        ImageModelConfig(name: 'Nano Banana (Default)', url: 'GEMINI_2_5_FLASH_IMAGE'),
        ImageModelConfig(name: 'Imagen 4', url: 'IMAGEN_4'),
      ];
    }
    
    // Set Flash Image as default
    if (_selectedImageModel == null && _imageModels.isNotEmpty) {
      _selectedImageModel = _imageModels.first;
    }
    setState(() {});
  }
  
  Future<void> _saveImageModels() async {
    final configPath = path.join(Directory.current.path, 'image_models_config.json');
    final json = _imageModels.map((m) => m.toJson()).toList();
    await File(configPath).writeAsString(jsonEncode(json));
  }
  
  void _addNewImageModel() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Image Model'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: 'Model ID (e.g. IMAGEN_4)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    
    if (result == true && nameController.text.isNotEmpty) {
      setState(() {
        _imageModels.add(ImageModelConfig(name: nameController.text, url: urlController.text));
      });
      await _saveImageModels();
    }
  }
  
  // ====================== PROFILES ======================
  
  Future<void> _loadProfiles() async {
    _profiles = ['Default'];
    for (int i = 1; i <= 10; i++) {
      _profiles.add('Profile $i');
    }
    setState(() {});
  }
  
  // ====================== JSON LOADING ======================
  
  Future<void> _addToImageGeneration() async {
    final rawText = _responseEditorController.text;
    if (rawText.isEmpty) {
      _log('⚠️ No content to add');
      return;
    }

    try {
      await _processJsonContent(rawText, sourceName: 'AI Studio');
      _tabController?.animateTo(0);
      _log('✅ Scenes added to Image Generation');
    } catch (e) {
      _log('❌ Failed to add to image generation: $e');
    }
  }
  void _showPasteJsonDialog() {
    final TextEditingController pasteController = TextEditingController();
    int detectedScenes = 0;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.paste, color: Colors.deepPurple),
              const SizedBox(width: 12),
              const Text('Paste Story JSON'),
              const Spacer(),
              if (detectedScenes > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Text(
                    '$detectedScenes scenes detected',
                    style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: 800, // Make it significantly wider
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F7FA), // Shiny silver background
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: TextField(
                    controller: pasteController,
                    maxLines: 18, // Increased max lines
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Paste your JSON here (Markdown blocks are ok)...',
                      contentPadding: EdgeInsets.all(12),
                      border: InputBorder.none,
                    ),
                    onChanged: (text) {
                      // Quick detection for UI feedback
                      String clean = text.trim();
                      if (clean.contains('```')) {
                        final match = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(clean);
                        if (match != null) clean = match.group(1)!.trim();
                      }
                      
                      int count = 0;
                      try {
                        final data = jsonDecode(clean);
                        if (data is Map) {
                          if (data['output_structure']?['scenes'] is List) {
                            count = (data['output_structure']['scenes'] as List).length;
                          } else if (data['scenes'] is List) {
                            count = (data['scenes'] as List).length;
                          }
                        } else if (data is List) {
                          count = data.length;
                        }
                      } catch (_) {}
                      
                      setDialogState(() => detectedScenes = count);
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final content = pasteController.text;
                if (content.isNotEmpty) {
                  await _processJsonContent(content, sourceName: 'Paste Dialog');
                  if (mounted) Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.check),
              label: const Text('Parse & Load'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pasteJson() async {
    _showPasteJsonDialog();
  }

  String _unwrapPrompt(dynamic p) {
    if (p == null) return '';
    if (p is String) {
      String s = p.trim();
      // If it looks like JSON, try to peak inside
      if (s.startsWith('{') && s.endsWith('}')) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is Map && decoded.containsKey('prompt')) {
            return _unwrapPrompt(decoded['prompt']);
          }
          if (decoded is Map && decoded.containsKey('description')) {
             return _unwrapPrompt(decoded['description']);
          }
        } catch (_) {}
      }
      return s;
    }
    if (p is Map) {
      if (p.containsKey('prompt')) return _unwrapPrompt(p['prompt']);
      if (p.containsKey('description')) return _unwrapPrompt(p['description']);
      // If it's a map but has no obvious prompt key, just return it as string for the user to fix
      return jsonEncode(p);
    }
    return p.toString();
  }

  Future<void> _processJsonContent(String content, {required String sourceName}) async {
    String cleanContent = content.trim();
    
    // Auto-handle Markdown JSON blocks: ```json ... ``` or ``` ... ```
    if (cleanContent.contains('```')) {
      final RegExp jsonBlockRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', multiLine: true);
      final match = jsonBlockRegex.firstMatch(cleanContent);
      if (match != null && match.groupCount >= 1) {
        cleanContent = match.group(1)!.trim();
        _log('📝 Extracted JSON from Markdown code block');
      }
    }

    try {
      final jsonData = jsonDecode(cleanContent);
      _scenes.clear();
      _generatedPrompts.clear(); // Clear old generation info
      
      _data = jsonData is Map<String, dynamic> ? jsonData : {};
      
      // 1. Handle standard output_structure.scenes
      if (_data.containsKey('output_structure') && _data['output_structure'] is Map) {
        final os = _data['output_structure'] as Map;
        if (os.containsKey('scenes') && os['scenes'] is List) {
          final rawScenes = os['scenes'] as List;
          for (final rs in rawScenes) {
            if (rs is Map) {
              _scenes.add(Map<String, dynamic>.from(rs));
            }
          }
        }
      }
      
      // 2. Handle raw scenes list at root
      if (_scenes.isEmpty && _data.containsKey('scenes') && _data['scenes'] is List) {
         final rawScenes = _data['scenes'] as List;
         for (final rs in rawScenes) {
            if (rs is Map) {
              _scenes.add(Map<String, dynamic>.from(rs));
            }
         }
      }

      // 3. Handle data if it IS a List directly
      if (_scenes.isEmpty && jsonData is List) {
        for (int i = 0; i < jsonData.length; i++) {
          final item = jsonData[i];
          if (item is Map) {
            _scenes.add({
              'scene_number': item['scene_number'] ?? item['sceneId'] ?? (i + 1),
              'prompt': item['prompt'] ?? item['description'] ?? '',
              ...Map<String, dynamic>.from(item),
            });
          }
        }
      }

      // 4. CRITICAL: Unwrap any nested JSON prompts created by AI hallucinations
      for (var scene in _scenes) {
        if (scene.containsKey('prompt')) {
          scene['prompt'] = _unwrapPrompt(scene['prompt']);
        }
      }
      
      _parseCharacters();
      
      setState(() {
        _selectedSceneIndex = 0;
        _toRangeController.text = _scenes.length.toString();
        if (_scenes.isNotEmpty) {
          const encoder = JsonEncoder.withIndent('  ');
          _promptController.text = encoder.convert(_scenes[0]);
          _detectCharsInPrompt(); // Auto-detect for first scene
        }
      });
      
      _log('✅ Loaded ${_scenes.length} scenes from $sourceName');
      _setStatus('Loaded from $sourceName');
      
      // Load character images from folder
      await _loadExistingCharacterImages();
      
      // Save session state for persistence
      await _saveSessionState();
      
    } catch (e) {
      _log('❌ Parsing error: $e');
      rethrow;
    }
  }

  Future<void> _loadJson({String? filePath}) async {
    try {
      String? targetPath = filePath;
      
      if (targetPath == null) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json', 'txt'],
        );
        if (result == null || result.files.single.path == null) return;
        targetPath = result.files.single.path!;
      }
      
      final file = File(targetPath);
      if (!await file.exists()) return;
      
      final content = await file.readAsString();
      final ext = path.extension(targetPath).toLowerCase();
      
      _jsonPath = targetPath;
      
      if (ext == '.txt') {
        _scenes.clear();
        final lines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();
        for (int i = 0; i < lines.length; i++) {
          _scenes.add({'scene_number': i + 1, 'prompt': lines[i].trim()});
        }
        _data = {'output_structure': {'scenes': _scenes}};
        
        setState(() {
          _selectedSceneIndex = 0;
          _toRangeController.text = _scenes.length.toString();
          if (_scenes.isNotEmpty) {
            _promptController.text = _scenes[0]['prompt'] ?? '';
          }
        });
        _log('✅ Loaded ${_scenes.length} scenes from ${path.basename(targetPath)}');
        _setStatus('Loaded: ${path.basename(targetPath)}');
        await _loadExistingCharacterImages();
        await _saveSessionState();
      } else {
        await _processJsonContent(content, sourceName: path.basename(targetPath));
      }
    } catch (e) {
      _log('❌ Failed to load: $e');
    }
  }
  
  void _parseCharacters() {
    _characters.clear();
    
    // 1. Try output_structure.characters.character_details (New format)
    if (_data.containsKey('output_structure') && _data['output_structure'] is Map) {
      final os = _data['output_structure'] as Map;
      if (os.containsKey('characters') && os['characters'] is Map) {
        final chars = os['characters'] as Map;
        if (chars.containsKey('character_details') && chars['character_details'] is List) {
          final details = chars['character_details'] as List;
          for (final charData in details) {
            if (charData is Map && charData.containsKey('id')) {
              _characters.add(CharacterData(
                id: charData['id'].toString(),
                name: (charData['name'] ?? charData['id']).toString(),
                description: (charData['description'] ?? charData['visual_description'] ?? charData['appearance'] ?? '').toString(),
                keyPath: ['output_structure', 'characters', 'character_details', charData['id'].toString()],
                images: [],
              ));
            }
          }
        }
      }
    }

    // 2. Try character_reference (Old list format)
    if (_characters.isEmpty && _data.containsKey('character_reference') && _data['character_reference'] is List) {
      for (final charData in _data['character_reference']) {
        if (charData is Map<String, dynamic> && charData.containsKey('id')) {
          _characters.add(CharacterData(
            id: charData['id'],
            name: charData['name'] ?? charData['id'],
            description: (charData['description'] ?? charData['visual_description'] ?? charData['appearance'] ?? '').toString(),
            keyPath: ['character_reference', charData['id']],
            images: (charData['images'] as List?)?.cast<String>() ?? [],
          ));
        }
      }
    } 
    
    // 3. Try character_reference (Old map format with main/secondary)
    if (_characters.isEmpty && _data.containsKey('character_reference') && _data['character_reference'] is Map) {
      final charRef = _data['character_reference'] as Map;
      
      if (charRef.containsKey('main_character') && charRef['main_character'] is Map) {
        final mc = charRef['main_character'] as Map;
        _characters.add(CharacterData(
          id: mc['id'] ?? 'main',
          name: mc['name'] ?? mc['id'] ?? 'Main Character',
          description: (mc['description'] ?? mc['visual_description'] ?? mc['appearance'] ?? '').toString(),
          keyPath: ['character_reference', 'main_character'],
          images: (mc['images'] as List?)?.cast<String>() ?? [],
        ));
      }
      
      if (charRef.containsKey('secondary_characters') && charRef['secondary_characters'] is List) {
        final secList = charRef['secondary_characters'] as List;
        for (int i = 0; i < secList.length; i++) {
          final sc = secList[i];
          if (sc is Map) {
            _characters.add(CharacterData(
              id: sc['id'] ?? 'secondary_$i',
              name: sc['name'] ?? sc['id'] ?? 'Secondary $i',
              description: (sc['description'] ?? sc['visual_description'] ?? sc['appearance'] ?? '').toString(),
              keyPath: ['character_reference', 'secondary_characters', i.toString()],
              images: (sc['images'] as List?)?.cast<String>() ?? [],
            ));
          }
        }
      }
    }

    // 4. Try root characters list
    if (_characters.isEmpty && _data.containsKey('characters') && _data['characters'] is List) {
      for (final charData in _data['characters'] as List) {
        if (charData is Map && charData.containsKey('id')) {
          _characters.add(CharacterData(
            id: charData['id'].toString(),
            name: (charData['name'] ?? charData['id']).toString(),
            description: (charData['description'] ?? charData['visual_description'] ?? charData['appearance'] ?? '').toString(),
            keyPath: ['characters', charData['id'].toString()],
            images: [],
          ));
        }
      }
    }

    _log('👥 Parsed ${_characters.length} characters from JSON');
  }
  
  Future<void> _saveJson() async {
    if (_jsonPath == null) {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save JSON',
        fileName: 'story.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null) return;
      _jsonPath = result;
    }
    
    try {
      if (_data.containsKey('output_structure')) {
        (_data['output_structure'] as Map)['scenes'] = _scenes;
      } else {
        _data['output_structure'] = {'scenes': _scenes};
      }
      
      await File(_jsonPath!).writeAsString(jsonEncode(_data));
      _log('✅ Saved');
    } catch (e) {
      _log('❌ Save failed: $e');
    }
  }
  
  // ====================== SCENE SELECTION ======================
  
  void _onSceneChange(int index) {
    // Save current content back to scene
    if (_selectedSceneIndex < _scenes.length) {
      final text = _promptController.text.trim();
      if (text.startsWith('{') && text.endsWith('}')) {
        try {
          // If it looks like JSON, try to parse it and update the whole scene object
          final parsed = jsonDecode(text);
          if (parsed is Map<String, dynamic>) {
            _scenes[_selectedSceneIndex] = parsed;
          } else {
            _scenes[_selectedSceneIndex]['prompt'] = text;
          }
        } catch (e) {
          // If JSON is invalid during navigation, we still save as prompt but log it
          _scenes[_selectedSceneIndex]['prompt'] = text;
        }
      } else {
        _scenes[_selectedSceneIndex]['prompt'] = text;
      }
    }
    
    setState(() {
      _selectedSceneIndex = index;
      if (index < _scenes.length) {
        final scene = _scenes[index];
        // Restore: Show the full JSON object for the scene so the user can see everything
        const encoder = JsonEncoder.withIndent('  ');
        _promptController.text = encoder.convert(scene);
        
        // Still auto-detect characters for the header display
        _detectCharsInPrompt();
      }
    });
  }
  
  void _copyPrompt() {
    Clipboard.setData(ClipboardData(text: _promptController.text));
    _setStatus('Copied!');
  }
  
  void _detectCharsInPrompt() {
    if (_selectedSceneIndex >= _scenes.length) return;
    
    final scene = _scenes[_selectedSceneIndex];
    final List<String> found = [];

    // 1. Try to get characters from the "characters_in_scene" field (Most accurate)
    if (scene.containsKey('characters_in_scene') && scene['characters_in_scene'] is List) {
      final chars = scene['characters_in_scene'] as List;
      for (var c in chars) {
        found.add(c.toString());
      }
    } 
    
    // 2. Fallback: Detect from prompt text if metadata is missing
    if (found.isEmpty) {
      final text = _promptController.text.toLowerCase();
      for (final c in _characters) {
        if (text.contains(c.id.toLowerCase()) || text.contains(c.name.toLowerCase())) {
          found.add(c.name);
        }
      }
    }

    setState(() {
      _detectedCharsDisplay = found.isEmpty ? '' : 'Chars: ${found.join(", ")}';
    });
  }
  
  /// Build prompt with history context (Python: build_scene_prompt_with_context)
  /// Returns structured JSON with previous_scenes_context when _includeHistory is true
  String _buildPromptWithHistory(int sceneIndex, String currentPrompt) {
    final sceneNumber = _scenes[sceneIndex]['scene_number'] ?? (sceneIndex + 1);
    
    // Build JSON structure
    final promptJson = <String, dynamic>{
      'previous_scenes_context': <Map<String, dynamic>>[],
      'current_prompt_to_proceed': {
        'scene_number': sceneNumber,
        'prompt': currentPrompt,
      },
    };
    
    // Add previous 5 scenes context if enabled
    if (_includeHistory) {
      final currentSceneNum = sceneNumber is int ? sceneNumber : int.tryParse(sceneNumber.toString()) ?? 1;
      
      for (int i = 1; i <= 5; i++) {
        final prevSceneNum = currentSceneNum - i;
        if (prevSceneNum < 1) break;
        
        // Find previous scene
        final prevScene = _scenes.firstWhere(
          (s) => (s['scene_number'] ?? 0).toString() == prevSceneNum.toString(),
          orElse: () => {},
        );
        
        if (prevScene.isNotEmpty && prevScene.containsKey('prompt')) {
          promptJson['previous_scenes_context'].add({
            'scene_number': prevSceneNum,
            'prompt': prevScene['prompt'].toString(),
          });
        }
      }
      
      // Reverse for chronological order (oldest first)
      (promptJson['previous_scenes_context'] as List).reversed.toList();
    }
    
    // Convert to formatted JSON string
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(promptJson);
  }
  
  // ====================== CHARACTER IMAGES ======================
  
  Future<void> _importImagesForCharacter(CharacterData character) async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      
      _log('📸 Importing ${result.files.length} for ${character.id}...');
      
      // Use app documents directory instead of hardcoded path
      final appDir = await getApplicationDocumentsDirectory();
      final charDir = Directory(path.join(appDir.path, 'VEO3', 'characters', character.id));
      if (!await charDir.exists()) await charDir.create(recursive: true);
      
      int imported = 0;
      for (final file in result.files) {
        if (file.path == null) continue;
        
        try {
          // Read original image
          final originalBytes = await File(file.path!).readAsBytes();
          
          // Decode image
          final img.Image? originalImage = img.decodeImage(originalBytes);
          if (originalImage == null) {
            _log('❌ Failed to decode: ${path.basename(file.path!)}');
            continue;
          }
          
          // Resize to max 256px to ensure small file size (target: under 30KB)
          img.Image resizedImage = originalImage;
          const int maxDim = 256;
          if (originalImage.width > maxDim || originalImage.height > maxDim) {
            if (originalImage.width >= originalImage.height) {
              resizedImage = img.copyResize(originalImage, width: maxDim);
            } else {
              resizedImage = img.copyResize(originalImage, height: maxDim);
            }
          }
          
          // Compress with progressive quality reduction to get under 30KB
          const int targetSizeBytes = 30 * 1024; // 30KB
          int quality = 80;
          List<int> jpegBytes = img.encodeJpg(resizedImage, quality: quality);
          
          while (jpegBytes.length > targetSizeBytes && quality > 20) {
            quality -= 10;
            jpegBytes = img.encodeJpg(resizedImage, quality: quality);
          }
          
          final finalSizeKB = (jpegBytes.length / 1024).toStringAsFixed(1);
          _log('    📐 ${originalImage.width}x${originalImage.height} → ${resizedImage.width}x${resizedImage.height} (${finalSizeKB}KB, Q:$quality)');
          
          String destFilename = '${character.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
          final destPath = path.join(charDir.path, destFilename);
          await File(destPath).writeAsBytes(jpegBytes);
          
          // Check if this path already exists in character images
          if (!character.images.contains(destPath)) {
            character.images.add(destPath);
          }
          imported++;
        } catch (e) {
          _log('❌ Import failed for file: $e');
        }
      }
      
      setState(() {});
      _log('✅ Imported $imported (resized to 256px, target <30KB)');
    } catch (e) {
      _log('❌ Import failed: $e');
    }
  }
  
  Future<void> _clearImagesForCharacter(CharacterData character) async {
    // Delete all image files
    for (final imgPath in character.images) {
      try {
        final f = File(imgPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    
    setState(() => character.images.clear());
    _log('Cleared ${character.id}');
  }
  
  /// Build style-enhanced prompt for character image generation
  String _buildCharacterPrompt(CharacterData character) {
    final stylePrefix = {
      'Realistic': 'Photorealistic portrait photo,',
      '3D Pixar': '3D Pixar-style character, round friendly features, vibrant colors,',
      '2D Cartoon': '2D cartoon character illustration, clean lines, bold colors,',
      'Anime': 'Anime-style character portrait, large expressive eyes, detailed hair,',
      'Watercolor': 'Watercolor painting portrait, soft edges, artistic,',
      'Oil Painting': 'Classical oil painting portrait, rich textures, fine brushwork,',
    }[_selectedCharStyle] ?? '';
    
    String desc = character.description;
    if (desc.isEmpty) {
      desc = 'A character named ${character.name}';
    }
    
    // Add background and framing instructions
    return '$stylePrefix $desc. Character portrait with face clearly visible, centered composition, flat solid gray-white background, professional studio lighting, high quality, detailed features.';
  }
  
  /// Extract base character name from ID (e.g., 'cowboy' from 'cowboy_outfit_001')
  String _getBaseCharacterName(String charId) {
    // Try to extract base name before _outfit or _001 etc
    final patterns = [
      RegExp(r'^(.+?)_outfit_\d+$', caseSensitive: false),
      RegExp(r'^(.+?)_\d+$', caseSensitive: false),
      RegExp(r'^(.+?)_v\d+$', caseSensitive: false),
    ];
    
    for (final pattern in patterns) {
      final match = pattern.firstMatch(charId);
      if (match != null) {
        return match.group(1)!;
      }
    }
    
    return charId; // Return as-is if no pattern matches
  }
  
  /// Find reference image from a related character (same base name, different outfit)
  Future<List<String>> _findCharacterReferenceImages(CharacterData character) async {
    final baseName = _getBaseCharacterName(character.id);
    final refImages = <String>[];
    
    // Look for characters with the same base name that have images
    for (final c in _characters) {
      if (c.id == character.id) continue; // Skip self
      
      final cBaseName = _getBaseCharacterName(c.id);
      if (cBaseName == baseName && c.images.isNotEmpty) {
        // Found a related character with images - use first image
        final imgPath = c.images.first;
        final file = File(imgPath);
        if (await file.exists()) {
          try {
            final bytes = await file.readAsBytes();
            final b64 = base64Encode(bytes);
            refImages.add('data:image/jpeg;base64,$b64');
            _log('Using ref image from ${c.id} for ${character.id}');
            break; // Use only first found
          } catch (e) {
            _log('Error reading ref image: $e');
          }
        }
      }
    }
    
    return refImages;
  }
  
  /// Generate image for a single character
  Future<void> _generateCharacterImage(CharacterData character) async {
    if (_cdpHubs.isEmpty) {
      _log('No browsers connected! Open browsers first.');
      return;
    }
    
    if (_charGenerating) {
      _log('Character generation already in progress');
      return;
    }
    
    setState(() => _charGenerating = true);
    _log('Generating image for ${character.id}...');
    
    try {
      final hub = _cdpHubs.values.first;
      final prompt = _buildCharacterPrompt(character);
      
      _log('Style: $_selectedCharStyle');
      _log('Full prompt: $prompt');
      
      // Find reference images from related characters (same base, different outfit)
      final refImages = await _findCharacterReferenceImages(character);
      if (refImages.isNotEmpty) {
        _log('Attaching ${refImages.length} reference image(s) for consistency');
      }
      
      // Focus and clear modals
      await hub.focusChrome();
      await hub.checkLaunchModal();
      
      // Spawn image with 1:1 aspect ratio
      final spawnResult = await hub.spawnImage(
        prompt,
        aspectRatio: '1:1',
        refImages: refImages.isNotEmpty ? refImages : null,
        model: 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE',
      );
      
      // Handle null or invalid spawn result
      if (spawnResult == null) {
        _log('Failed to spawn - null result for ${character.id}');
        setState(() => _charGenerating = false);
        return;
      }
      
      String? threadId;
      if (spawnResult is Map && spawnResult.containsKey('id')) {
        threadId = spawnResult['id']?.toString();
      } else if (spawnResult is String && spawnResult.isNotEmpty) {
        threadId = spawnResult;
      }
      
      if (threadId == null || threadId.isEmpty) {
        _log('Failed to get thread ID for ${character.id}: $spawnResult');
        setState(() => _charGenerating = false);
        return;
      }
      
      _log('Spawned, polling...');
      
      // Check for Launch modal
      await Future.delayed(const Duration(seconds: 2));
      await hub.focusChrome();
      await hub.checkLaunchModal();
      
      // Poll for completion
      final startPoll = DateTime.now();
      while (DateTime.now().difference(startPoll).inSeconds < 180) {
        final res = await hub.getThread(threadId);
        
        if (res is Map) {
          if (res['status'] == 'COMPLETED' && res['result'] != null) {
            final result = res['result'];
            if (result is String && result.isNotEmpty) {
              await _saveCharacterImage(result, character, prompt);
              _log('Generated image for ${character.id}');
            }
            break;

          } else if (res['status'] == 'FAILED') {
            _log('Generation failed for ${character.id}: ${res['error']}');
            break;
          }
        }
        
        // Periodic modal check
        if (DateTime.now().difference(startPoll).inSeconds % 5 == 0) {
          await hub.checkLaunchModal();
        }
        
        await Future.delayed(const Duration(milliseconds: 800));
      }
    } catch (e) {
      _log('Error generating ${character.id}: $e');
    }
    
    setState(() => _charGenerating = false);
  }
  
  /// Generate images for all characters (grouped by base name for consistency)
  Future<void> _generateAllCharacterImages() async {
    if (_cdpHubs.isEmpty) {
      _log('No browsers connected! Open browsers first.');
      return;
    }
    
    if (_characters.isEmpty) {
      _log('No characters to generate');
      return;
    }
    
    if (_charGenerating) {
      _log('Character generation already in progress');
      return;
    }
    
    setState(() => _charGenerating = true);
    
    // Group characters by base name for ordered generation
    final charGroups = <String, List<CharacterData>>{};
    for (final c in _characters) {
      final baseName = _getBaseCharacterName(c.id);
      charGroups.putIfAbsent(baseName, () => []).add(c);
    }
    
    // Sort each group so _001 comes before _002 etc
    for (final group in charGroups.values) {
      group.sort((a, b) => a.id.compareTo(b.id));
    }
    
    _log('Generating ${_characters.length} characters in ${charGroups.length} groups...');
    
    int success = 0;
    int failed = 0;
    
    // Process each group: first character first, then others with reference
    for (final baseName in charGroups.keys) {
      final group = charGroups[baseName]!;
      
      for (int gi = 0; gi < group.length; gi++) {
        if (!_charGenerating) break; // Allow cancel
        
        final character = group[gi];
        
        try {
          final hub = _cdpHubs.values.first;
          final prompt = _buildCharacterPrompt(character);
          
          _log('Generating ${character.id}...');
          _log('Full prompt: $prompt');
          
          // Find reference images (for 2nd+ outfit in group)
          List<String>? refImages;
          if (gi > 0) {
            // Use first character in group as reference
            final firstChar = group[0];
            if (firstChar.images.isNotEmpty) {
              final imgPath = firstChar.images.first;
              final file = File(imgPath);
              if (await file.exists()) {
                try {
                  final bytes = await file.readAsBytes();
                  final b64 = base64Encode(bytes);
                  refImages = ['data:image/jpeg;base64,$b64'];
                  _log('Using ${firstChar.id} as reference for consistency');
                } catch (e) {
                  _log('Error reading ref: $e');
                }
              }
            }
          }
          
          await hub.focusChrome();
          await hub.checkLaunchModal();
          
          final spawnResult = await hub.spawnImage(
            prompt,
            aspectRatio: '1:1',
            refImages: refImages,
            model: 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE',
          );
          
          if (spawnResult == null) {
            _log('Failed to spawn (null) for ${character.id}');
            failed++;
            continue;
          }
          
          String? threadId;
          if (spawnResult is Map && spawnResult.containsKey('id')) {
            threadId = spawnResult['id']?.toString();
          } else if (spawnResult is String && spawnResult.isNotEmpty) {
            threadId = spawnResult;
          }
          
          if (threadId == null || threadId.isEmpty) {
            _log('Failed to spawn for ${character.id}');
            failed++;
            continue;
          }
          
          _log('Spawned ${character.id}');
          
          await Future.delayed(const Duration(seconds: 2));
          await hub.focusChrome();
          await hub.checkLaunchModal();
          
          // Poll
          final startPoll = DateTime.now();
          bool completed = false;
          while (DateTime.now().difference(startPoll).inSeconds < 180) {
            final res = await hub.getThread(threadId);
            
            if (res is Map) {
              if (res['status'] == 'COMPLETED' && res['result'] != null) {
                final result = res['result'];
                if (result is String && result.isNotEmpty) {
                  await _saveCharacterImage(result, character, prompt);
                  _log('✓ Generated ${character.id}');
                  success++;
                  completed = true;
                }
                break;
              } else if (res['status'] == 'FAILED') {
                _log('✗ Failed ${character.id}');
                failed++;
                completed = true;
                break;
              }
            }
            
            if (DateTime.now().difference(startPoll).inSeconds % 5 == 0) {
              await hub.checkLaunchModal();
            }
            
            await Future.delayed(const Duration(milliseconds: 800));
          }
          
          if (!completed) {
            _log('Timeout ${character.id}');
            failed++;
          }
          
        } catch (e) {
          _log('Error ${character.id}: $e');
          failed++;
        }
      }
    }
    
    _log('Complete: $success success, $failed failed');
    setState(() => _charGenerating = false);
  }
  
  /// Save generated character image (resized and compressed like imports)
  Future<String?> _saveCharacterImage(String base64Data, CharacterData character, [String? prompt]) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final charDir = Directory(path.join(appDir.path, 'VEO3', 'characters', character.id));
      if (!await charDir.exists()) await charDir.create(recursive: true);
      
      // Extract base64
      String b64Part = base64Data;
      if (base64Data.contains(',')) {
        b64Part = base64Data.split(',').last;
      }
      
      final bytes = base64Decode(b64Part);
      
      // Decode and resize (same as import logic)
      final img.Image? originalImage = img.decodeImage(bytes);
      if (originalImage == null) {
        _log('Failed to decode generated image');
        return null;
      }
      
      // Resize to 256px (same as imported images)
      img.Image resized;
      if (originalImage.width > originalImage.height) {
        resized = img.copyResize(originalImage, width: 256);
      } else {
        resized = img.copyResize(originalImage, height: 256);
      }
      
      // Compress to JPEG
      List<int> outputBytes = img.encodeJpg(resized, quality: 80);
      
      // Reduce quality if needed
      int quality = 80;
      while (outputBytes.length > 30 * 1024 && quality > 20) {
        quality -= 10;
        outputBytes = img.encodeJpg(resized, quality: quality);
      }
      
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'gen_${timestamp}.jpg';
      final destPath = path.join(charDir.path, filename);
      
      await File(destPath).writeAsBytes(outputBytes);
      
      // Store the prompt used for this image
      if (prompt != null) {
        _charImagePrompts[destPath] = prompt;
      }
      
      setState(() {
        if (!character.images.contains(destPath)) {
          character.images = [...character.images, destPath];
        }
      });
      
      return destPath;
      
    } catch (e) {
      _log('Save error: $e');
      return null;
    }
  }
  
  /// Show image preview dialog with prompt editing and regeneration
  void _showCharacterImageDialog(CharacterData character, String imagePath, int imageIndex) {
    final promptController = TextEditingController(
      text: _charImagePrompts[imagePath] ?? _buildCharacterPrompt(character),
    );
    bool isRegenerating = false;
    String? newImagePath;
    String? refImagePath; // For imported reference image
    String? refImageB64; // Base64 encoded reference
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Expanded(child: Text(character.id, style: const TextStyle(fontSize: 16))),
              IconButton(
                onPressed: () async {
                  // Open character folder
                  final appDir = await getApplicationDocumentsDirectory();
                  final charDir = path.join(appDir.path, 'VEO3', 'characters', character.id);
                  await Directory(charDir).create(recursive: true);
                  if (Platform.isWindows) {
                    Process.run('explorer', [charDir]);
                  }
                },
                icon: const Icon(Icons.folder_open, size: 20),
                tooltip: 'Open Folder',
              ),
            ],
          ),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Image preview
                  Container(
                    height: 200,
                    width: 200,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(newImagePath ?? imagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 40),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // Reference image section
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      children: [
                        const Text('Ref Image:', style: TextStyle(fontSize: 11)),
                        const SizedBox(width: 8),
                        if (refImagePath != null)
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.blue),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.file(File(refImagePath!), fit: BoxFit.cover),
                            ),
                          )
                        else
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(Icons.image, size: 20, color: Colors.grey),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            refImagePath != null ? path.basename(refImagePath!) : 'None',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            final result = await FilePicker.platform.pickFiles(type: FileType.image);
                            if (result != null && result.files.isNotEmpty && result.files.first.path != null) {
                              final selectedPath = result.files.first.path!;
                              try {
                                final bytes = await File(selectedPath).readAsBytes();
                                final b64 = base64Encode(bytes);
                                setDialogState(() {
                                  refImagePath = selectedPath;
                                  refImageB64 = 'data:image/jpeg;base64,$b64';
                                });
                                _log('Ref image loaded: ${path.basename(selectedPath)}');
                              } catch (e) {
                                _log('Error loading ref image: $e');
                              }
                            }
                          },
                          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                          child: const Text('Import', style: TextStyle(fontSize: 10)),
                        ),
                        if (refImagePath != null)
                          TextButton(
                            onPressed: () {
                              setDialogState(() {
                                refImagePath = null;
                                refImageB64 = null;
                              });
                            },
                            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), foregroundColor: Colors.red),
                            child: const Text('Clear', style: TextStyle(fontSize: 10)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // Prompt editor
                  TextField(
                    controller: promptController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Prompt',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                  
                  // Regenerate button
                  if (isRegenerating)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: CircularProgressIndicator(),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: _cdpHubs.isEmpty 
                          ? null 
                          : () async {
                              if (_cdpHubs.isEmpty) return;
                              
                              setDialogState(() => isRegenerating = true);
                              _log('Regenerating ${character.id}...');
                              _log('Full prompt: ${promptController.text}');
                              if (refImageB64 != null) {
                                _log('Using imported reference image');
                              }
                              
                              try {
                                final hub = _cdpHubs.values.first;
                                await hub.focusChrome();
                                await hub.checkLaunchModal();
                                
                                final spawnResult = await hub.spawnImage(
                                  promptController.text,
                                  aspectRatio: '1:1',
                                  refImages: refImageB64 != null ? [refImageB64!] : null,
                                  model: 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE',
                                );
                              
                              if (spawnResult == null) {
                                _log('Regeneration failed - null spawn');
                                setDialogState(() => isRegenerating = false);
                                return;
                              }
                              
                              String? threadId;
                              if (spawnResult is Map && spawnResult.containsKey('id')) {
                                threadId = spawnResult['id']?.toString();
                              } else if (spawnResult is String && spawnResult.isNotEmpty) {
                                threadId = spawnResult;
                              }
                              
                              if (threadId == null || threadId.isEmpty) {
                                _log('Regeneration failed - no thread ID');
                                setDialogState(() => isRegenerating = false);
                                return;
                              }
                              
                              await Future.delayed(const Duration(seconds: 2));
                              await hub.focusChrome();
                              await hub.checkLaunchModal();
                              
                              // Poll
                              final startPoll = DateTime.now();
                              while (DateTime.now().difference(startPoll).inSeconds < 180) {
                                final res = await hub.getThread(threadId);
                                
                                if (res is Map) {
                                  if (res['status'] == 'COMPLETED' && res['result'] != null) {
                                    final result = res['result'];
                                    if (result is String && result.isNotEmpty) {
                                      final savedPath = await _saveCharacterImage(result, character, promptController.text);
                                      if (savedPath != null) {
                                        newImagePath = savedPath;
                                        _log('Regenerated ${character.id}');
                                      }
                                    }
                                    break;
                                  } else if (res['status'] == 'FAILED') {
                                    _log('Regeneration failed: ${res['error']}');
                                    break;
                                  }
                                }
                                
                                if (DateTime.now().difference(startPoll).inSeconds % 5 == 0) {
                                  await hub.checkLaunchModal();
                                }
                                
                                await Future.delayed(const Duration(milliseconds: 800));
                              }
                            } catch (e) {
                              _log('Regeneration error: $e');
                            }
                            
                            setDialogState(() => isRegenerating = false);
                          },
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Regenerate'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (newImagePath != null)
              TextButton(
                onPressed: () async {
                  // Delete old image and update prompt map
                  try {
                    final oldFile = File(imagePath);
                    if (await oldFile.exists()) {
                      await oldFile.delete();
                    }
                    _charImagePrompts.remove(imagePath);
                    
                    // Update character images list
                    setState(() {
                      final idx = character.images.indexOf(imagePath);
                      if (idx >= 0) {
                        character.images.removeAt(idx);
                      }
                    });
                    
                    _log('Replaced old image with regenerated one');
                  } catch (e) {
                    _log('Error cleaning up: $e');
                  }
                  Navigator.of(ctx).pop();
                },
                child: const Text('Save & Replace', style: TextStyle(color: Colors.green)),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
  
  
  // ====================== CHROME BROWSER MANAGEMENT ======================
  
  String? _findChromePath() {
    final paths = [
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      Platform.environment['LOCALAPPDATA'] != null
          ? path.join(Platform.environment['LOCALAPPDATA']!, r'Google\Chrome\Application\chrome.exe')
          : '',
    ];
    for (final p in paths) {
      if (p.isNotEmpty && File(p).existsSync()) return p;
    }
    return null;
  }
  
  Future<void> _openChromeSingle() async {
    final chromePath = _findChromePath();
    if (chromePath == null) {
      _log('❌ Chrome not found!');
      return;
    }
    
    final userDataDir = path.join(Directory.current.path, 'User Data');
    await Directory(userDataDir).create(recursive: true);
    
    const targetUrl = 'https://aistudio.google.com/apps/drive/10_Qs0vkJbQIOSKW-rwZOBlC-9lmYJjHo?showPreview=true&showAssistant=true';
    
    final args = [
      '--remote-debugging-port=9222',
      '--user-data-dir=$userDataDir',
      '--profile-directory=$_selectedProfile',
      targetUrl
    ];
    
    _log('🚀 Launching Chrome on port 9222...');
    
    try {
      await Process.start(chromePath, args, mode: ProcessStartMode.detached);
      _log('✅ Chrome launched');
    } catch (e) {
      _log('❌ Launch failed: $e');
    }
  }
  
  Future<void> _openMultipleBrowsers() async {
    final chromePath = _findChromePath();
    if (chromePath == null) {
      _log('❌ Chrome not found!');
      return;
    }
    
    int count = int.tryParse(_profileCountController.text) ?? 3;
    if (count < 1) count = 1;
    
    _log('=' * 40);
    _log('🌐 Opening $count Chrome profiles sequentially...');
    
    const targetUrl = 'https://aistudio.google.com/apps/drive/10_Qs0vkJbQIOSKW-rwZOBlC-9lmYJjHo?showPreview=true&showAssistant=true';
    
    // Calculate window positions (tile horizontally)
    const windowWidth = 500;
    const windowHeight = 400;
    
    for (int i = 0; i < count; i++) {
      final port = _cdpBasePort + i;
      final profileName = 'Profile ${i + 1}';
      final userDataDir = path.join(Directory.current.path, profileName, 'User Data');
      await Directory(userDataDir).create(recursive: true);
      
      final args = [
        '--remote-debugging-port=$port',
        '--user-data-dir=$userDataDir',
        '--no-first-run',
        '--no-default-browser-check',
        '--window-size=$windowWidth,$windowHeight',
        '--window-position=${i * 100},${i * 50}', // Offset each window
        targetUrl
      ];
      
      _log('  🖥️ Opening $profileName (Port $port)...');
      
      try {
        await Process.start(chromePath, args, mode: ProcessStartMode.detached);
        _log('    ✅ Launched');
      } catch (e) {
        _log('    ❌ Failed: $e');
      }
      
      // Delay between browser launches (Python pattern)
      if (i < count - 1) {
        _log('    ⏳ Waiting 2s before next browser...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    
    _log('✅ All browsers launched. Waiting 8s for page load...');
    
    // Longer wait for page to load before connecting (Python waits more)
    await Future.delayed(const Duration(seconds: 8));
    
    // AUTO-CONNECT with modal handling (more attempts since pages are loading)
    await _connectAllBrowsers(maxAttempts: 20);
    
    // Resize windows via CDP (Continue to App is already clicked during connection)
    for (final hub in _cdpHubs.values) {
      try {
        await hub.setBrowserWindowRect(0, 0, windowWidth, windowHeight);
      } catch (_) {}
    }
  }
  
  Future<void> _connectAllBrowsers({int maxAttempts = 5}) async {
    int count = int.tryParse(_profileCountController.text) ?? 3;
    _cdpHubs.clear();
    
    _log('Connecting to $count browsers (max $maxAttempts attempts per browser)...');
    
    // Connect to all browsers with retry logic
    final futures = <Future<MapEntry<int, GeminiHubConnector?>>>[];
    
    for (int i = 0; i < count; i++) {
      final port = _cdpBasePort + i;
      futures.add(() async {
        final connector = GeminiHubConnector();
        
        const retryDelay = Duration(seconds: 3);
        
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
          try {
            await connector.connect(port: port);
            _log('  ✓ Port $port connected (attempt $attempt)');
            return MapEntry(port, connector);
          } catch (e) {
            final errorStr = e.toString();
            if (attempt < maxAttempts) {
              // Log first and every 5th attempt
              if (attempt == 1 || attempt % 5 == 0) {
                _log('  Port $port: Attempt $attempt/$maxAttempts...');
              }
              await Future.delayed(retryDelay);
            } else {
              _log('  ✗ Port $port: Failed after $maxAttempts attempts');
              return MapEntry(port, null);
            }
          }
        }
        
        return MapEntry(port, null);
      }());
    }
    
    final results = await Future.wait(futures);
    
    int connected = 0;
    for (final result in results) {
      if (result.value != null) {
        _cdpHubs[result.key] = result.value!;
        connected++;
      }
    }
    
    setState(() => _browserStatus = '● $connected Browsers');
    _log(connected > 0 ? '✓ $connected browsers ready' : '✗ No browsers connected');
  }
  
  // ====================== CDP GENERATION (EXACT PYTHON LOGIC) ======================
  
  Future<void> _startCdpGeneration() async {
    if (_cdpRunning) {
      setState(() => _cdpRunning = false);
      _log('🛑 Stopping...');
      return;
    }
    
    if (_scenes.isEmpty) {
      _log('⚠️ No scenes');
      return;
    }
    
    if (_cdpHubs.isEmpty) {
      _log('⚠️ No browsers connected');
      return;
    }
    
    setState(() => _cdpRunning = true);
    _log('=' * 50);
    _log('⚡ Starting CDP Image Generation...');
    
    final fromIdx = (int.tryParse(_fromRangeController.text) ?? 1) - 1;
    final toIdx = int.tryParse(_toRangeController.text) ?? _scenes.length;
    final batchSize = int.tryParse(_batchSizeController.text) ?? 2;
    final delaySeconds = int.tryParse(_delayController.text) ?? 1;
    final retryCount = int.tryParse(_retriesController.text) ?? 1;
    
    // Determine model JS code (exact Python logic)
    String modelIdJs;
    String modelName;
    if (_selectedImageModel == null || _selectedImageModel!.url.isEmpty) {
      modelIdJs = 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE';
      modelName = 'Gemini 2.5 Flash Image';
    } else {
      modelIdJs = 'window.geminiHub.models.${_selectedImageModel!.url}';
      modelName = _selectedImageModel!.name;
    }
    _log('🎨 Using model: $modelName');
    
    // Build prompt queue with reference images
    final queue = <Map<String, dynamic>>[];
    for (int i = fromIdx; i < toIdx && i < _scenes.length; i++) {
      final scene = _scenes[i];
      final sceneNum = scene['scene_number'] ?? (i + 1);
      final rawPrompt = scene['prompt']?.toString() ?? '';
      
      // Build prompt with history if enabled (Python: build_scene_prompt_with_context)
      final prompt = _includeHistory ? _buildPromptWithHistory(i, rawPrompt) : rawPrompt;
      
      // Find character references from scene's characters_in_scene field
      List<String> refImagesB64 = [];
      
      // Get characters_in_scene from scene JSON
      final charsInScene = scene['characters_in_scene'];
      List<String> charIds = [];
      if (charsInScene is List) {
        charIds = charsInScene.map((e) => e.toString().toLowerCase()).toList();
      }
      
      // Also check raw prompt text as fallback
      for (final char in _characters) {
        final charIdLower = char.id.toLowerCase();
        bool shouldInclude = charIds.contains(charIdLower) || 
                            rawPrompt.toLowerCase().contains(charIdLower);
        
        if (shouldInclude && char.images.isNotEmpty) {
          _log('    🎭 Found character: ${char.id} (${char.images.length} images)');
          for (final imgPath in char.images) {
            try {
              final file = File(imgPath);
              if (await file.exists()) {
                final bytes = await file.readAsBytes();
                refImagesB64.add(base64Encode(bytes));
              }
            } catch (_) {}
          }
        }
      }
      
      queue.add({
        'scene_num': sceneNum,
        'prompt': prompt,
        'ref_images': refImagesB64,
        'index': i,
      });
    }
    
    _log('Queued ${queue.length} prompts');
    
    final activePorts = _cdpHubs.keys.toList();
    
    _log('Independent per-browser processing: $batchSize per browser');
    
    // Initialize live stats
    setState(() {
      _statsTotal = queue.length;
      _statsGenerating = 0;
      _statsPolling = 0;
      _statsCompleted = 0;
      _statsFailed = 0;
    });
    
    // Calculate fair share BEFORE distributing (queue.length changes during loop!)
    final totalItems = queue.length;
    final sharePerBrowser = (totalItems / activePorts.length).ceil();
    
    // Each browser processes independently in parallel
    final browserFutures = <Future<Map<String, int>>>[];
    
    for (final port in activePorts) {
      final hub = _cdpHubs[port]!;
      
      // Each browser gets its fair share
      final browserQueue = <Map<String, dynamic>>[];
      for (int i = 0; i < sharePerBrowser && queue.isNotEmpty; i++) {
        browserQueue.add(queue.removeAt(0));
      }
      
      // Launch independent processor for this browser
      browserFutures.add(_processBrowserQueue(
        port: port,
        hub: hub,
        queue: browserQueue,
        batchSize: batchSize,
        delaySeconds: delaySeconds,
        retryCount: retryCount,
        modelIdJs: modelIdJs,
      ));
    }
    
    // Wait for all browsers to finish independently
    final results = await Future.wait(browserFutures);
    
    // Aggregate results
    int successful = 0;
    int failed = 0;
    for (final result in results) {
      successful += result['successful'] ?? 0;
      failed += result['failed'] ?? 0;
    }

    setState(() => _cdpRunning = false);
    _log('=' * 50);
    _log('Complete: $successful success, $failed failed');
    _log('Images saved to: $_cdpOutputFolder');
  }
  
  /// Process queue for a single browser independently
  Future<Map<String, int>> _processBrowserQueue({
    required int port,
    required GeminiHubConnector hub,
    required List<Map<String, dynamic>> queue,
    required int batchSize,
    required int delaySeconds,
    required int retryCount,
    required String modelIdJs,
  }) async {
    int successful = 0;
    int failed = 0;
    final retryTracker = <int, int>{};
    bool hasFocused = false; // Only focus browser once at the start
    
    _log('[Port $port] Processing ${queue.length} prompts');
    
    // Focus this browser ONCE at the start
    try {
      await hub.focusChrome();
      hasFocused = true;
    } catch (_) {}
    
    while (queue.isNotEmpty &&  _cdpRunning) {
      final batch = <Map<String, dynamic>>[];
      for (int i = 0; i < batchSize && queue.isNotEmpty; i++) {
        batch.add(queue.removeAt(0));
      }
      
      if (batch.isEmpty) break;
      
      _log('[Port $port] Spawning ${batch.length} tasks...');
      
      // Modal clearing before spawn (no focus - browser already focused at start)
      for (int i = 0; i < 3; i++) {
        try {
          await Future.delayed(const Duration(milliseconds: 200));
          await hub.checkLaunchModal();
          await hub.checkContinueToAppModal();
        } catch (_) {}
      }
      
      // Spawn all tasks and AWAIT them
      final pendingTasks = <Map<String, dynamic>>[];
      final spawnFutures = <Future<void>>[];
      
      for (final item in batch) {
        if (!_cdpRunning) break;
        
        final sceneNum = item['scene_num'];
        final prompt = item['prompt'];
        final refImgs = item['ref_images'] as List<String>;
        
        // Spawn and collect futures
        final spawnFuture = hub.spawnImage(
          prompt,
          aspectRatio: _aspectRatio,
          refImages: refImgs.isNotEmpty ? refImgs : null,
          model: modelIdJs,
        ).then((spawnResult) {
          String? threadId;
          if (spawnResult is Map && spawnResult.containsKey('id')) {
            threadId = spawnResult['id']?.toString();
          } else if (spawnResult is String && spawnResult.isNotEmpty) {
            threadId = spawnResult;
          }
          
          if (threadId != null && threadId.isNotEmpty && !threadId.toLowerCase().contains('error')) {
            pendingTasks.add({
              'scene_num': sceneNum,
              't_id': threadId,
              'prompt': prompt,
              'ref_images': refImgs,
            });
            _log('[Port $port] Spawned Scene $sceneNum');
          } else {
            failed++;
            _log('[Port $port] Spawn failed Scene $sceneNum');
          }
        }).catchError((e) {
          failed++;
          _log('[Port $port] Spawn exception Scene $sceneNum: $e');
        });
        
        spawnFutures.add(spawnFuture);
        
        // Small delay between spawns
        await Future.delayed(Duration(milliseconds: delaySeconds * 1000));
      }
      
      // Wait for ALL spawns to complete
      await Future.wait(spawnFutures);
      
      // Give a moment for API registration
      await Future.delayed(const Duration(milliseconds: 500));
      
      if (pendingTasks.isEmpty) continue;
      
      // Brief wait for API\n      await Future.delayed(const Duration(milliseconds: 1000));
      
      // Modal check after spawn (no focus stealing - browser already focused at start)
      bool anyModalClicked = false;
      for (int i = 0; i < 5; i++) {
        try {
          await Future.delayed(const Duration(milliseconds: 200));
          final launched = await hub.checkLaunchModal();
          if (launched) {
            if (!anyModalClicked) {
              _log('[Port $port]   ✓ Clicked Launch modal');
              anyModalClicked = true;
            }
            await Future.delayed(const Duration(milliseconds: 300));
          } else {
            break;
          }
        } catch (_) {}
      }
      
      // Poll until all complete
      _log('[Port $port] Polling ${pendingTasks.length} tasks...');
      
      final startPoll = DateTime.now();
      int lastModalCheck = 0;
      
      while (pendingTasks.isNotEmpty && _cdpRunning) {
        if (DateTime.now().difference(startPoll).inSeconds > 180) {
          _log('[Port $port] Polling timeout');
          break;
        }
        
        final stillPending = <Map<String, dynamic>>[];
        
        for (final task in pendingTasks) {
          try {
            final res = await hub.getThread(task['t_id']);
            
            if (res is Map) {
              final status = res['status'];
              if (status == 'COMPLETED' && res['result'] != null) {
                successful++;
                _log('[Port $port] Scene ${task['scene_num']} completed');
                
                final result = res['result'];
                if (result is String && result.isNotEmpty) {
                  await _saveCdpImage(result, task['scene_num']);
                }
                setState(() => _statsCompleted++);
              } else if (status == 'FAILED') {
                final sceneNum = task['scene_num'] as int;
                final currentRetries = retryTracker[sceneNum] ?? 0;
                if (currentRetries < retryCount) {
                  retryTracker[sceneNum] = currentRetries + 1;
                  _log('[Port $port] Re-queue Scene $sceneNum (Retry ${currentRetries + 1}/$retryCount)');
                  queue.add({
                    'scene_num': sceneNum,
                    'prompt': task['prompt'],
                    'ref_images': task['ref_images'] ?? <String>[],
                    'index': 0,
                  });
                } else {
                  failed++;
                  setState(() => _statsFailed++);
                  _log('[Port $port] Scene $sceneNum failed permanently');
                }
              } else if (status == 'NOT_FOUND') {
                failed++;
                setState(() => _statsFailed++);
                _log('[Port $port] Scene ${task['scene_num']} lost');
              } else {
                stillPending.add(task);
              }
            } else {
              stillPending.add(task);
            }
          } catch (e) {
            if (e.toString().toLowerCase().contains('closed')) {
              failed++;
              setState(() => _statsFailed++);
              _log('[Port $port] Connection lost');
            } else {
              stillPending.add(task);
            }
          }
        }
        
        pendingTasks.clear();
        pendingTasks.addAll(stillPending);
        
        setState(() => _statsPolling = pendingTasks.length);
        
        if (pendingTasks.isNotEmpty) {
          // Periodic modal check (every 3 seconds) - no focus stealing
          if (DateTime.now().difference(startPoll).inSeconds - lastModalCheck >= 3) {
            lastModalCheck = DateTime.now().difference(startPoll).inSeconds;
            try {
              await Future.delayed(const Duration(milliseconds: 200));
              await hub.checkLaunchModal();
            } catch (_) {}
          }
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }
      
      // Timeout remaining
      for (final task in pendingTasks) {
        failed++;
        _log('[Port $port] Scene ${task['scene_num']} timeout');
      }
    }
    
    _log('[Port $port] Finished: $successful success, $failed failed');
    return {'successful': successful, 'failed': failed};
  }
  
  
  Future<void> _saveCdpImage(String base64Data, dynamic sceneNum) async {
    try {
      // Python exact logic
      await Directory(_cdpOutputFolder).create(recursive: true);
      
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '').replaceAll('-', '').substring(0, 15);
      final filename = 'scene_${sceneNum}_$timestamp.png';
      final filepath = path.join(_cdpOutputFolder, filename);
      
      // Extract base64
      String b64Part = base64Data;
      if (base64Data.contains(',')) {
        b64Part = base64Data.split(',').last;
      }
      
      final bytes = base64Decode(b64Part);
      await File(filepath).writeAsBytes(bytes);
      
      // Add to generated images for display
      setState(() {
        _generatedImagePaths.add(filepath);
      });
      
      _log('  💾 Saved: $filename');
    } catch (e) {
      _log('  ❌ Save error: $e');
    }
  }
  
  void _openOutputFolder() {
    if (Platform.isWindows) {
      Process.run('explorer', [_cdpOutputFolder]);
    }
  }
  
  /// Add generated image to video generation on main screen
  void _addToVideoGeneration(String imagePath, String sceneNoStr) {
    final sceneNum = int.tryParse(sceneNoStr) ?? 0;
    
    // Find the scene data to get the prompt
    String prompt = '';
    String? videoActionPrompt;
    
    for (final scene in _scenes) {
      final sn = scene['scene_number'];
      if (sn != null && sn.toString() == sceneNoStr) {
        // Prefer video_action_prompt for video generation, fallback to regular prompt
        videoActionPrompt = scene['video_action_prompt']?.toString();
        prompt = scene['prompt']?.toString() ?? '';
        break;
      }
    }
    
    // Use video_action_prompt if available, otherwise use regular prompt
    final videoPrompt = (videoActionPrompt != null && videoActionPrompt.isNotEmpty) 
        ? videoActionPrompt 
        : prompt;
    
    if (videoPrompt.isEmpty) {
      _log('⚠️ No prompt found for Scene $sceneNoStr');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No prompt found for Scene $sceneNoStr')),
      );
      return;
    }
    
    _log('➡️ Adding Scene $sceneNoStr to Video Generation');
    _log('   Image: ${path.basename(imagePath)}');
    _log('   Prompt: ${videoPrompt.length > 50 ? '${videoPrompt.substring(0, 50)}...' : videoPrompt}');
    
    // Pop back to main screen with the data for video generation
    Navigator.pop(context, {
      'action': 'add_to_video_gen',
      'sceneId': sceneNum,
      'imagePath': imagePath,
      'prompt': videoPrompt,
      'imageFileName': path.basename(imagePath),
    });
  }

  
  // ====================== BUILD UI ======================
  
  @override
  Widget build(BuildContext context) {
    // Handle case where tab controller isn't initialized yet (hot reload)
    if (_tabController == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    
    final isDesktop = MediaQuery.of(context).size.width > 700;
    
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: isDesktop ? 40 : 48,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: isDesktop 
          ? TabBar(
              controller: _tabController!,
              isScrollable: true,
              labelPadding: const EdgeInsets.symmetric(horizontal: 16),
              tabs: const [
                Tab(icon: Icon(Icons.auto_awesome, size: 18), text: 'Prompts'),
                Tab(icon: Icon(Icons.image, size: 18), text: 'Images'),
              ],
            )
          : TabBar(
              controller: _tabController!,
              isScrollable: true,
              labelPadding: const EdgeInsets.symmetric(horizontal: 8),
              tabs: const [
                Tab(icon: Icon(Icons.auto_awesome, size: 16), text: 'Prompts'),
                Tab(icon: Icon(Icons.image, size: 16), text: 'Images'),
              ],
            ),
        actions: [
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        ],
      ),
      body: TabBarView(
        controller: _tabController!,
        children: [
          // Tab 1: Generate Prompts from Story (now first)
          isDesktop ? _buildStoryPromptTab() : _buildMobileStoryPromptTab(),
          // Tab 2: Image Generation (now second)
          isDesktop ? _buildDesktopImageGenTab() : _buildMobileImageGenTab(),
        ],
      ),
    );
  }
  
  /// Desktop layout for Image Generation tab
  Widget _buildDesktopImageGenTab() {
    return Column(
      children: [
        _buildToolbarRow1(),
        _buildToolbarRow2(),
        Expanded(child: _buildMainContent()),
        _buildStatusBar(),
      ],
    );
  }
  
  /// Mobile layout for Image Generation tab
  Widget _buildMobileImageGenTab() {
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          // Compact toolbar
          _buildMobileToolbar(),
          // Tab bar for sections
          const TabBar(
            isScrollable: true,
            labelStyle: TextStyle(fontSize: 12),
            tabs: [
              Tab(text: 'Log'),
              Tab(text: 'Settings'),
              Tab(text: 'Images'),
              Tab(text: 'Scenes'),
              Tab(text: 'Characters'),
            ],
          ),
          // Content
          Expanded(
            child: TabBarView(
              children: [
                _buildMobileLogPanel(),
                _buildMobileSettingsPanel(),
                _buildMobileImagesPanel(),
                _buildMobileScenesPanel(),
                _buildMobileCharactersPanel(),
              ],
            ),
          ),
          _buildMobileStatusBar(),
        ],
      ),
    );
  }

  /// Mobile Settings Panel
  Widget _buildMobileSettingsPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('Processing Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const Divider(),
          
          // Image Model
          DropdownButtonFormField<ImageModelConfig>(
            value: _selectedImageModel,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Image Model', isDense: true, border: OutlineInputBorder()),
            items: _imageModels.map((m) => DropdownMenuItem(value: m, child: Text(m.name, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setState(() => _selectedImageModel = v),
          ),
          const SizedBox(height: 12),
          
          // Batch Size
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _batchSizeController,
                  decoration: const InputDecoration(labelText: 'Batch/Browser', isDense: true, border: OutlineInputBorder()),
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _delayController,
                  decoration: const InputDecoration(labelText: 'Delay (sec)', isDense: true, border: OutlineInputBorder()),
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Retries
          TextField(
            controller: _retriesController,
            decoration: const InputDecoration(labelText: 'Max Retries', isDense: true, border: OutlineInputBorder()),
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 12),
          ),
          
          const SizedBox(height: 20),
          const Text('API Configuration', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const Divider(),
          
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Gemini API Keys', style: TextStyle(fontSize: 12)),
            subtitle: Text('${_geminiApi?.keyCount ?? 0} keys loaded', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: ElevatedButton.icon(
              onPressed: _showApiKeyDialog,
              icon: const Icon(Icons.key, size: 14),
              label: const Text('Manage', style: TextStyle(fontSize: 11)),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            ),
          ),
          
          const SizedBox(height: 12),
          const Text('Actions', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const Divider(),
          
          ElevatedButton.icon(
            onPressed: _openMultipleBrowsers,
            icon: const Icon(Icons.add_to_queue), 
            label: const Text('Launch Browsers'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              const url = 'https://aistudio.google.com/apps/drive/10_Qs0vkJbQIOSKW-rwZOBlC-9lmYJjHo?showPreview=true&showAssistant=true';
              if (Platform.isWindows) {
                await Process.run('cmd', ['/c', 'start', url]);
              }
            }, 
            icon: const Icon(Icons.open_in_new), 
            label: const Text('Open AI Studio URL')
          ),
        ],
      ),
    );
  }
  
  /// Compact mobile toolbar
  Widget _buildMobileToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // Browser controls
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_browserStatus, style: TextStyle(fontSize: 10, color: _cdpHubs.isNotEmpty ? Colors.green : Colors.grey)),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _connectAllBrowsers,
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: const Text('Connect', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Start/Stop
            ElevatedButton.icon(
              onPressed: _cdpRunning ? () => setState(() => _cdpRunning = false) : _startCdpGeneration,
              icon: Icon(_cdpRunning ? Icons.stop : Icons.play_arrow, size: 14),
              label: Text(_cdpRunning ? 'Stop' : 'Start', style: const TextStyle(fontSize: 11)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _cdpRunning ? Colors.red : Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
            const SizedBox(width: 8),
            // Stats
            if (_cdpRunning)
              Text('${_statsCompleted}/${_statsTotal}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
  
  /// Mobile log panel
  Widget _buildMobileLogPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.grey.shade800,
            child: Row(
              children: [
                const Text('Log', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: _clearLog,
                  style: TextButton.styleFrom(foregroundColor: Colors.white, padding: EdgeInsets.zero, minimumSize: Size.zero),
                  child: const Text('Clear', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: Colors.grey.shade900,
              child: TextField(
                controller: _logController,
                scrollController: _logScrollController,
                maxLines: null,
                expands: true,
                readOnly: true,
                style: const TextStyle(fontSize: 10, color: Colors.lightGreenAccent, fontFamily: 'monospace'),
                decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.all(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  /// Mobile images panel
  Widget _buildMobileImagesPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.green.shade50,
            child: Row(
              children: [
                const Text('Generated', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('(${_generatedImagePaths.length})', style: const TextStyle(fontSize: 10)),
                TextButton(
                  onPressed: _openOutputFolder,
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                  child: const Text('Open Folder', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _generatedImagePaths.isEmpty
                ? const Center(child: Text('No images yet', style: TextStyle(color: Colors.grey)))
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: _generatedImagePaths.length,
                    itemBuilder: (ctx, i) {
                      final path = _generatedImagePaths[_generatedImagePaths.length - 1 - i];
                      return GestureDetector(
                        onTap: () => _showImagePreview(path),
                        child: Image.file(File(path), fit: BoxFit.cover),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
  
  /// Mobile scenes panel
  Widget _buildMobileScenesPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.blue.shade50,
            child: Row(
              children: [
                const Text('Scenes', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_scenes.isNotEmpty) ...[
                  IconButton(
                    onPressed: _selectedSceneIndex > 0 ? () => _onSceneChange(_selectedSceneIndex - 1) : null,
                    icon: const Icon(Icons.chevron_left, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  Text('${_selectedSceneIndex + 1}/${_scenes.length}', style: const TextStyle(fontSize: 11)),
                  IconButton(
                    onPressed: _selectedSceneIndex < _scenes.length - 1 ? () => _onSceneChange(_selectedSceneIndex + 1) : null,
                    icon: const Icon(Icons.chevron_right, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ],
            ),
          ),
          if (_detectedCharsDisplay.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Colors.amber.shade50,
              child: Row(
                children: [
                  Text(_detectedCharsDisplay, style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
          Expanded(
            child: _scenes.isEmpty
                ? const Center(child: Text('Load JSON to see scenes', style: TextStyle(color: Colors.grey)))
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      controller: _promptController,
                      maxLines: null,
                      expands: true,
                      style: const TextStyle(fontSize: 11),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Scene prompt...',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
  
  /// Mobile characters panel
  Widget _buildMobileCharactersPanel() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.purple.shade50,
            child: Row(
              children: [
                const Text('Characters', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const Spacer(),
                DropdownButton<String>(
                  value: _selectedCharStyle,
                  isDense: true,
                  items: _charImageStyles.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 10)))).toList(),
                  onChanged: (v) => setState(() => _selectedCharStyle = v ?? 'Realistic'),
                  underline: const SizedBox(),
                ),
                const SizedBox(width: 4),
                ElevatedButton(
                  onPressed: _charGenerating ? null : _generateAllCharacterImages,
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: _charGenerating 
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Gen All', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
          Expanded(
            child: _characters.isEmpty
                ? const Center(child: Text('No characters', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _characters.length,
                    itemBuilder: (ctx, i) => _buildCharacterCard(_characters[i]),
                  ),
          ),
        ],
      ),
    );
  }
  
  /// Mobile status bar
  Widget _buildMobileStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        border: Border(top: BorderSide(color: Colors.grey.shade400)),
      ),
      child: Text(_statusMessage, style: const TextStyle(fontSize: 10), overflow: TextOverflow.ellipsis),
    );
  }
  
  /// Mobile Story Prompt tab
  Widget _buildMobileStoryPromptTab() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            labelStyle: TextStyle(fontSize: 12),
            tabs: [
              Tab(text: 'Input'),
              Tab(text: 'Output'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // Input panel
                _buildMobileStoryInput(),
                // Output panel
                _buildMobileStoryOutput(),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  /// Mobile story input
  Widget _buildMobileStoryInput() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          // Model Select
          DropdownButtonFormField<String>(
            value: _selectedStoryModel,
            isDense: true,
            decoration: const InputDecoration(labelText: 'Story Model', border: OutlineInputBorder()),
            items: _storyModels.map((m) => DropdownMenuItem(value: m['id'], child: Text(m['name']!, style: const TextStyle(fontSize: 12)))).toList(),
            onChanged: (v) => setState(() => _selectedStoryModel = v ?? 'gemini-1.5-flash'),
          ),
          const SizedBox(height: 8),
          
          // Controls
          Row(
            children: [
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  value: _selectedTemplate,
                  isExpanded: true,
                  isDense: true,
                  decoration: const InputDecoration(labelText: 'Template', border: OutlineInputBorder()),
                  items: _promptTemplates.keys.map((k) => DropdownMenuItem(value: k, child: Text(k, style: const TextStyle(fontSize: 11)))).toList(),
                  onChanged: (v) => setState(() => _selectedTemplate = v ?? 'char_consistent'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 60,
                child: TextField(
                  controller: _promptCountController,
                  decoration: const InputDecoration(labelText: 'Count', isDense: true, border: OutlineInputBorder()),
                  style: const TextStyle(fontSize: 11),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Options
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: 20, height: 20, child: Checkbox(value: _useTemplate, onChanged: (v) => setState(() => _useTemplate = v ?? true))),
                    const SizedBox(width: 4),
                    const Text('Use Template', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: 20, height: 20, child: Checkbox(value: _useStructuredOutput, onChanged: (v) => setState(() => _useStructuredOutput = v ?? true))),
                    const SizedBox(width: 4),
                    const Text('Structured JSON', style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 8),
          // Story input
          Expanded(
            child: TextField(
              controller: _storyInputController,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Paste your story here...',
              ),
            ),
          ),
          const SizedBox(height: 8),
            // Generate button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _storyGenerating ? null : _generatePromptsFromStory,
                icon: _storyGenerating ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome),
                label: Text(_storyGenerating ? 'Generating...' : 'Generate Prompts'),
              ),
            ),
        ],
      ),
    );
  }
    
    /// Mobile story output
    Widget _buildMobileStoryOutput() {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                const Text('Generated Output', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: _addToImageGeneration,
                  child: const Text('Load to Image Studio', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _responseEditorController,
                scrollController: _responseScrollController,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'AI response will appear here...',
                ),
              ),
            ),
          ],
        ),
      );
    }
  
  void _showImagePreview(String path) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.file(File(path)),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
  
  
  Widget _buildStoryPromptTab() {
    return Row(
      children: [
        // Left Panel (20%) - Story Input (Mobile-like)
        Container(
          width: MediaQuery.of(context).size.width * 0.2,
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            border: Border(right: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Column(
            children: [
              
              // Header
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.deepPurple.shade50,
                  border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.auto_stories, size: 18, color: Colors.deepPurple),
                        SizedBox(width: 8),
                        Text('Story Input', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Template toggle
                    Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: _useTemplate,
                            onChanged: (v) => setState(() => _useTemplate = v ?? false),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text('Use Template', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                      ],
                    ),
                    // Template picker (only show when enabled)
                    if (_useTemplate) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.deepPurple.shade200),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: DropdownButton<String>(
                          value: _selectedTemplate,
                          underline: const SizedBox(),
                          isDense: true,
                          isExpanded: true,
                          style: const TextStyle(fontSize: 11, color: Colors.black87),
                          items: _promptTemplates.entries.map((e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value['name'] as String, style: const TextStyle(fontSize: 11)),
                          )).toList(),
                          onChanged: (v) => setState(() => _selectedTemplate = v!),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    // Model picker with API key button
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: DropdownButton<String>(
                              value: _selectedStoryModel,
                              underline: const SizedBox(),
                              isDense: true,
                              isExpanded: true,
                              style: const TextStyle(fontSize: 12, color: Colors.black87),
                              items: _storyModels.map((m) => DropdownMenuItem(
                                value: m['id'],
                                child: Text(m['name']!, style: const TextStyle(fontSize: 12)),
                              )).toList(),
                              onChanged: (v) => setState(() => _selectedStoryModel = v!),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // API Key settings button
                        Tooltip(
                          message: (_geminiApi?.keyCount ?? 0) > 0 
                              ? '${_geminiApi!.keyCount} API keys configured'
                              : 'Set API Keys',
                          child: InkWell(
                            onTap: _showApiKeyDialog,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: (_geminiApi?.keyCount ?? 0) > 0 
                                    ? Colors.green.shade50 
                                    : Colors.orange.shade50,
                                border: Border.all(
                                  color: (_geminiApi?.keyCount ?? 0) > 0 
                                      ? Colors.green.shade300 
                                      : Colors.orange.shade300,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.key,
                                    size: 14,
                                    color: (_geminiApi?.keyCount ?? 0) > 0 
                                        ? Colors.green.shade700 
                                        : Colors.orange.shade700,
                                  ),
                                  if ((_geminiApi?.keyCount ?? 0) > 0) ...[
                                    const SizedBox(width: 2),
                                    Text(
                                      '${_geminiApi!.keyCount}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Prompt count
                    Row(
                      children: [
                        const Text('Prompts:', style: TextStyle(fontSize: 11)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 50,
                          height: 28,
                          child: TextField(
                            controller: _promptCountController,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                            ),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Structured output checkbox
                    Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: _useStructuredOutput,
                            onChanged: (v) => setState(() => _useStructuredOutput = v ?? true),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text('Structured Output', style: TextStyle(fontSize: 11)),
                      ],
                    ),
                  ],
                ),
              ),
              
              // Story text area (tall mobile-like)
              Expanded(
                child: TextField(
                  controller: _storyInputController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText: 'Paste your story here...',
                    hintStyle: TextStyle(fontSize: 12, color: Colors.grey),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(12),
                  ),
                  style: const TextStyle(fontSize: 12, height: 1.4),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              
              // Bottom bar with word count and button
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border(top: BorderSide(color: Colors.grey.shade300)),
                ),
                child: Column(
                  children: [
                    Text(
                      '${_storyInputController.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length} words',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _storyGenerating ? null : _generatePromptsFromStory,
                              icon: _storyGenerating 
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.auto_fix_high, size: 16),
                              label: Text(_storyGenerating ? 'Generating...' : 'Generate', style: const TextStyle(fontSize: 12)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.deepPurple,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                              ),
                            ),
                          ),
                          if (_storyGenerating) ...[
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _storyGenerating = false;
                                  _log('⏹️ Generation stopped by user');
                                });
                              },
                              icon: const Icon(Icons.stop, size: 16),
                              label: const Text('Stop', style: TextStyle(fontSize: 12)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        
        // Right Panel (80%) - AI Response
        Expanded(
          child: Container(
            color: Colors.white,
            child: Column(
              children: [
                // Header with actions
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.code, size: 18, color: Colors.deepPurple),
                      const SizedBox(width: 8),
                      const Text('AI Response', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const Spacer(),
                      if (_rawResponse != null && _rawResponse!.isNotEmpty) ...[
                        Text('${_rawResponse!.length} chars', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: () async {
                            if (_isCopied) return;
                            await Clipboard.setData(ClipboardData(text: _responseEditorController.text));
                            setState(() => _isCopied = true);
                            Future.delayed(const Duration(seconds: 2), () {
                              if (mounted) setState(() => _isCopied = false);
                            });
                          },
                          icon: Icon(_isCopied ? Icons.check : Icons.copy, size: 14),
                          label: Text(_isCopied ? 'Copied!' : 'Copy JSON', style: const TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isCopied ? Colors.green.shade700 : Colors.green.shade600,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            elevation: 0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () async {
                            if (_isSaved) return;
                            await _saveGeneratedPrompts();
                          },
                          icon: Icon(_isSaved ? Icons.check : Icons.save, size: 14),
                          label: Text(_isSaved ? 'Saved!' : 'Save JSON', style: const TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isSaved ? Colors.blue.shade700 : Colors.blue.shade600,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            elevation: 0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _addToImageGeneration,
                          icon: const Icon(Icons.send, size: 14),
                          label: const Text('Add to Image Studio', style: TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurple.shade600,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            elevation: 0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: 'Clear',
                          onPressed: () => setState(() {
                            _rawResponse = null;
                            _responseEditorController.clear();
                            _generatedPrompts.clear();
                          }),
                           visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                ),
                
                // Content area
                Expanded(
                  child: (_rawResponse == null || _rawResponse!.isEmpty)
                    ? (_storyGenerating
                        ? _buildFunnyLoadingAnimation()
                        : Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.auto_awesome, size: 64, color: Colors.grey.shade200),
                                const SizedBox(height: 16),
                                Text(
                                  'AI Response will appear here',
                                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Paste a story and click "Generate"',
                                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                                ),
                              ],
                            ),
                          ))
                    : _buildRawResponseView(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildTabButton(String label, IconData icon, int tabIndex) {
    final isSelected = _responseViewTab == tabIndex;
    return InkWell(
      onTap: () => setState(() => _responseViewTab = tabIndex),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.deepPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isSelected ? Colors.deepPurple : Colors.grey.shade400),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isSelected ? Colors.white : Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isSelected ? Colors.white : Colors.grey.shade700)),
          ],
        ),
      ),
    );
  }
  
  Widget _buildPromptsGridView() {
    // Parse prompts from raw response
    List<Map<String, dynamic>> prompts = [];
    if (_rawResponse != null && _rawResponse!.isNotEmpty) {
      try {
        final parsed = jsonDecode(_rawResponse!);
        if (parsed is Map && parsed['output_structure'] is Map) {
          final scenes = parsed['output_structure']['scenes'];
          if (scenes is List) {
            prompts = scenes.map((s) => Map<String, dynamic>.from(s as Map)).toList();
          }
        } else if (parsed is List) {
          prompts = parsed.map((s) => Map<String, dynamic>.from(s as Map)).toList();
        }
      } catch (_) {}
    }
    
    // If still generating and no prompts parsed, show streaming preview
    if (prompts.isEmpty) {
      if (_storyGenerating && _rawResponse != null && _rawResponse!.isNotEmpty) {
        // Count how many scene_number patterns are found
        final scenePattern = RegExp(r'"scene_number"\s*:\s*(\d+)');
        final matches = scenePattern.allMatches(_rawResponse!).toList();
        final generatedCount = matches.length;
        final totalCount = int.tryParse(_promptCountController.text) ?? 10;
        
        // Show streaming preview - response is coming but not yet parseable
        return Container(
          color: Colors.grey.shade100,
          child: Column(
            children: [
              // Streaming indicator
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.deepPurple.shade50,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '✨ Generating Your Story Prompts',
                      style: TextStyle(color: Colors.deepPurple.shade700, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '$generatedCount / $totalCount',
                      style: TextStyle(color: Colors.deepPurple.shade900, fontWeight: FontWeight.w900, fontSize: 20),
                    ),
                  ],
                ),
              ),
              // Show raw preview
              Expanded(
                child: Scrollbar(
                  controller: _responseScrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _responseScrollController,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _rawResponse!,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11,
                        color: Colors.grey.shade700,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }
      
      // Not generating, no prompts - show empty state
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.grid_view, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('No prompts parsed', style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
            const SizedBox(height: 8),
            Text('Switch to "Raw Response" to view/edit', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
          ],
        ),
      );
    }
    
    return Scrollbar(
      controller: _responseScrollController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _responseScrollController,
        padding: const EdgeInsets.all(12),
        itemCount: prompts.length,
        itemBuilder: (context, index) {
          final prompt = prompts[index];
          final sceneNum = prompt['scene_number'] ?? (index + 1);
          final promptText = prompt['prompt'] ?? '';
          final characters = (prompt['characters_in_scene'] as List?)?.join(', ') ?? '';
          
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('Scene $sceneNum', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    if (characters.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('👥 $characters', style: TextStyle(fontSize: 11, color: Colors.grey.shade600), overflow: TextOverflow.ellipsis),
                      ),
                    ] else
                      const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Copy prompt',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: promptText));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Scene $sceneNum copied!'), duration: const Duration(seconds: 1)),
                          );
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(
                  promptText,
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
  
  Widget _buildRawResponseView() {
    int generatedCount = 0;
    int totalCount = int.tryParse(_promptCountController.text) ?? 10;
    
    if (_rawResponse != null && _rawResponse!.isNotEmpty) {
      final scenePattern = RegExp(r'"scene_number"\s*:\s*(\d+)');
      generatedCount = scenePattern.allMatches(_rawResponse!).length;
    }

    return Column(
      children: [
        if (_storyGenerating)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.deepPurple.shade50,
            child: Row(
              children: [
                const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurple),
                ),
                const SizedBox(width: 14),
                Text(
                  '✨ Generating Your Story Prompts',
                  style: TextStyle(
                    color: Colors.deepPurple.shade700, 
                    fontWeight: FontWeight.bold, 
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.shade100,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.deepPurple.shade200),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$generatedCount',
                        style: TextStyle(
                          color: Colors.deepPurple.shade900, 
                          fontWeight: FontWeight.w900, 
                          fontSize: 22,
                        ),
                      ),
                      Text(
                        ' / $totalCount',
                        style: TextStyle(
                          color: Colors.deepPurple.shade700, 
                          fontWeight: FontWeight.bold, 
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        Expanded(
          child: Container(
            color: const Color(0xFFF5F7FA), // Shiny Silver White background
            child: Theme(
              data: Theme.of(context).copyWith(
                scrollbarTheme: ScrollbarThemeData(
                  thumbColor: WidgetStateProperty.all(Colors.grey.shade300),
                  trackColor: WidgetStateProperty.all(Colors.grey.shade100),
                  thickness: WidgetStateProperty.all(8),
                  radius: const Radius.circular(10),
                ),
              ),
              child: Scrollbar(
                controller: _responseScrollController,
                thumbVisibility: true,
                trackVisibility: false,
                child: TextField(
                  controller: _responseEditorController,
                  scrollController: _responseScrollController,
                  maxLines: null,
                  expands: true,
                  readOnly: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: Color(0xFF2D3436), // Charcoal dark text
                    height: 1.6,
                    letterSpacing: 0.3,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(24),
                    filled: false, // Let the container color show through
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildFunnyLoadingAnimation() {
    return Container(
      color: const Color(0xFFF5F7FA), // Match the shiny silver background
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Looping Flying Bird
            SizedBox(
              width: 200,
              height: 180,
              child: TweenAnimationBuilder<double>(
                key: ValueKey('bird_anim_${DateTime.now().millisecondsSinceEpoch ~/ 1000}'),
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 1200),
                builder: (context, value, child) {
                  return CustomPaint(
                    painter: _FlyingBirdPainter(animationValue: value),
                    size: const Size(200, 180),
                  );
                },
                onEnd: () {
                  if (mounted && _storyGenerating) {
                    // Small delay to prevent tight loop recursion errors
                    Future.delayed(Duration.zero, () {
                      if (mounted) setState(() {});
                    });
                  }
                },
              ),
            ),
            const SizedBox(height: 32),
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Colors.deepPurple, Colors.blueAccent],
              ).createShader(bounds),
              child: const Text(
                '✨ AI is crafting your scenes...',
                style: TextStyle(
                  fontSize: 18, 
                  fontWeight: FontWeight.bold, 
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'A lovely bird is flying to bring your story to life',
              style: TextStyle(
                fontSize: 13, 
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blueAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _saveGeneratedPrompts() async {
    final content = _responseEditorController.text;
    if (content.isEmpty) {
      _log('⚠️ Nothing to save');
      return;
    }
    
    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save JSON',
        fileName: 'generated_prompts.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      
      if (result != null) {
        final file = File(result);
        await file.writeAsString(content);
        _log('💾 Saved to: $result');
        setState(() => _isSaved = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _isSaved = false);
        });
      }
    } catch (e) {
      _log('❌ Save error: $e');
    }
  }
  
  Future<void> _copyGeneratedPrompts() async {
    final text = _responseEditorController.text;
    if (text.isEmpty) {
      _log('⚠️ Nothing to copy');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard!'), duration: Duration(seconds: 1)));
    }
  }
  
  Future<void> _generatePromptsFromStory() async {
    print('[DEBUG] _generatePromptsFromStory called');
    
    if (_storyInputController.text.isEmpty) {
      _log('⚠️ Please enter a story first');
      return;
    }
    
    // Check for API keys
    if (_geminiApi == null || _geminiApi!.keyCount == 0) {
      _log('⚠️ No Gemini API keys configured. Please add your API keys.');
      _showApiKeyDialog();
      return;
    }
    
    setState(() {
      _storyGenerating = true;
      _rawResponse = '';
      _responseEditorController.clear();
      _generatedPrompts.clear();
      _log('🚀 Starting generation...');
    });
    
    final promptCount = int.tryParse(_promptCountController.text) ?? 10;
    final storyText = _storyInputController.text;
    
    String systemPrompt;
    
    if (_useTemplate) {
      // Use template
      final template = _promptTemplates[_selectedTemplate]!;
      _log('🎬 Generating $promptCount prompts using "${template['name']}" template...');
      systemPrompt = (template['prompt'] as String)
          .replaceAll('[STORY_TEXT]', storyText)
          .replaceAll('[SCENE_COUNT]', promptCount.toString());
      
      if (_useStructuredOutput) {
        _log('ℹ️ Note: Using structured output prompt');
      }
    } else {
      // Use raw story input as prompt (no template)
      _log('🎬 Sending raw instruction to AI...');
      systemPrompt = storyText;
    }
    
    // Get schema if applies
    Map<String, dynamic>? schema;
    if (_useTemplate && _useStructuredOutput) {
      schema = _promptTemplates[_selectedTemplate]?['schema'] as Map<String, dynamic>?;
    }
    
    _log('📋 Model: $_selectedStoryModel');
    
    if (_geminiApi == null) {
       _log('❌ Gemini API is not initialized');
       setState(() => _storyGenerating = false);
       return;
    }
    
    try {
      _log('📤 Sending request to Gemini API (streaming mode)...');
      
      // Use Gemini API for text generation with streaming
      final result = await _geminiApi!.generateText(
        prompt: systemPrompt,
        model: _selectedStoryModel,
        jsonSchema: schema,
        onChunk: (chunk) {
          // Update UI with streaming chunks
          if (mounted && _storyGenerating) {
            setState(() {
              _rawResponse = (_rawResponse ?? '') + chunk;
              
              // Only update editor if we're in Raw view, otherwise grid will handle it
              _responseEditorController.text = _rawResponse!;
              
              // Auto-scroll to bottom of raw response if visible
              if (_responseScrollController.hasClients) {
                _responseScrollController.jumpTo(_responseScrollController.position.maxScrollExtent);
              }
            });
          }
        },
      );
      
      _log('📦 Total received: ${result.length} chars');
      
      if (result.isEmpty) {
        _log('❌ Empty response from Gemini AI');
      } else {
        _log('✅ Generation complete');
      }
      
      // Update UI with final response
      if (mounted) {
        setState(() {
          _rawResponse = result;
          _responseEditorController.text = result;
          
          // Try to beautify final JSON
          try {
            final parsed = jsonDecode(result);
            final beautified = const JsonEncoder.withIndent('  ').convert(parsed);
            _responseEditorController.text = beautified;
            _rawResponse = beautified;
          } catch (_) {}
        });
      }
      
    } catch (e) {
      _log('❌ Error: $e');
      // Auto expand log on error
      setState(() => _logCollapsed = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _storyGenerating = false);
      }
    }
  }
  
  void _showApiKeyDialog() {
    // Get existing keys
    final existingKeys = _geminiApi?.apiKeys.join('\n') ?? '';
    final controller = TextEditingController(text: existingKeys);
    
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.key, color: Colors.deepPurple),
            const SizedBox(width: 8),
            const Text('Gemini API Keys'),
            const Spacer(),
            if (_geminiApi != null && _geminiApi!.keyCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_geminiApi!.keyCount} keys',
                  style: TextStyle(fontSize: 12, color: Colors.green.shade800),
                ),
              ),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste your API keys below (one per line):',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Keys will auto-rotate on quota exceeded or errors.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              Container(
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: 'AIzaSyB...\nAIzaSyC...\nAIzaSyD...',
                    hintStyle: TextStyle(color: Colors.grey, fontSize: 12),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.blue.shade400),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Get API keys from: aistudio.google.com/app/apikey',
                      style: TextStyle(fontSize: 11, color: Colors.blue.shade600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              controller.clear();
            },
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Save Keys'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final text = controller.text.trim();
              
              if (_geminiApi == null) {
                _geminiApi = GeminiApiService();
              }
              
              // Clear and add new keys
              _geminiApi!.apiKeys.clear();
              _geminiApi!.addKeysFromText(text);
              
              // Save to file
              await _geminiApi!.saveToFile();
              
              final keyCount = _geminiApi!.keyCount;
              _log('✅ Saved $keyCount API key${keyCount == 1 ? '' : 's'}');
              
              setState(() {});
              Navigator.pop(dialogContext);
            },
          ),
        ],
      ),
    );
  }
  
  Widget _buildToolbarRow1() {
    final currentModelName = _selectedImageModel?.name ?? 
        (_imageModels.isNotEmpty ? _imageModels.first.name : 'Flash Image');
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          // File ops
          OutlinedButton.icon(
            onPressed: _loadJson, 
            icon: const Icon(Icons.folder_open, size: 16), 
            label: const Text('Load JSON')
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: _pasteJson, 
            icon: const Icon(Icons.paste, size: 16), 
            label: const Text('Paste JSON')
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: _saveJson, 
            icon: const Icon(Icons.save, size: 16), 
            label: const Text('Save')
          ),
          
          _divider(),
          
          // Image Model
          const Icon(Icons.palette, size: 16, color: Colors.deepPurple),
          const SizedBox(width: 4),
          DropdownButton<String>(
            value: _imageModels.any((m) => m.name == currentModelName) ? currentModelName : null,
            hint: const Text('Model'),
            items: _imageModels.map((m) => DropdownMenuItem(value: m.name, child: Text(m.name))).toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _selectedImageModel = _imageModels.firstWhere((m) => m.name == v);
                });
              }
            },
            underline: const SizedBox(),
            isDense: true,
          ),
          
          _divider(),
          
          // Profile + Chrome
          const Text('Profile:'),
          const SizedBox(width: 4),
          DropdownButton<String>(
            value: _selectedProfile,
            items: _profiles.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (v) => setState(() => _selectedProfile = v!),
            underline: const SizedBox(),
            isDense: true,
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(onPressed: _openChromeSingle, icon: const Icon(Icons.language, size: 16), label: const Text('Open Chrome')),
          
          const Spacer(),
          
          // Live Generation Stats (top right)
          if (_statsTotal > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('📊 $_statsTotal', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                  const SizedBox(width: 8),
                  if (_statsGenerating > 0) Text('🔄$_statsGenerating', style: const TextStyle(color: Colors.orange, fontSize: 11)),
                  const SizedBox(width: 4),
                  if (_statsPolling > 0) Text('⏳$_statsPolling', style: const TextStyle(color: Colors.blue, fontSize: 11)),
                  const SizedBox(width: 4),
                  Text('✅$_statsCompleted', style: const TextStyle(color: Colors.green, fontSize: 11)),
                  const SizedBox(width: 4),
                  if (_statsFailed > 0) Text('❌$_statsFailed', style: const TextStyle(color: Colors.red, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
          
          // Output folder
          OutlinedButton.icon(onPressed: _openOutputFolder, icon: const Icon(Icons.folder, size: 16), label: const Text('Output Folder')),
        ],
      ),
    );
  }
  
  Widget _buildToolbarRow2() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          // Browser Controls
          const Icon(Icons.public, size: 16, color: Colors.blue),
          const SizedBox(width: 4),
          const Text('Browser:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 4),
          SizedBox(width: 35, child: TextField(controller: _profileCountController, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(4)))),
          const SizedBox(width: 4),
          ElevatedButton(onPressed: _openMultipleBrowsers, child: const Text('Open')),
          const SizedBox(width: 4),
          ElevatedButton(onPressed: _connectAllBrowsers, child: const Text('Connect')),
          const SizedBox(width: 8),
          Text(_browserStatus, style: TextStyle(color: _cdpHubs.isEmpty ? Colors.red : Colors.green, fontWeight: FontWeight.bold)),
          
          _divider(),
          
          // Generation settings
          const Text('Imgs/Browser:', style: TextStyle(fontSize: 11)),
          const SizedBox(width: 4),
          SizedBox(width: 35, child: TextField(controller: _batchSizeController, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(4)))),
          const SizedBox(width: 8),
          const Text('Delay:'),
          const SizedBox(width: 4),
          SizedBox(width: 35, child: TextField(controller: _delayController, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(4)))),
          const SizedBox(width: 8),
          const Text('Retry:'),
          const SizedBox(width: 4),
          SizedBox(width: 35, child: TextField(controller: _retriesController, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(4)))),
          
          _divider(),
          
          // History checkbox
          Checkbox(
            value: _includeHistory,
            onChanged: (v) => setState(() => _includeHistory = v ?? true),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const Text('Prompt History'),
        ],
      ),
    );
  }
  
  Widget _divider() => Container(width: 1, height: 24, color: Colors.grey.shade400, margin: const EdgeInsets.symmetric(horizontal: 10));
  
  Widget _buildMainContent() {
    return Row(
      children: [
        // Column 1: Log (collapsible, LEFT) + Generated Images (RIGHT)
        Expanded(
          flex: 4,
          child: Row(
            children: [
              // Progress Log (collapsible - LEFT side, only shown when not collapsed)
              if (!_logCollapsed)
                Expanded(
                  flex: 2,
                  child: Card(
                    margin: const EdgeInsets.all(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          color: Colors.grey.shade200,
                          child: Row(
                            children: [
                              const Text('Log', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.close, size: 14),
                                onPressed: () => setState(() => _logCollapsed = true),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Container(
                            color: const Color(0xFF1E1E1E),
                            padding: const EdgeInsets.all(4),
                            child: RawScrollbar(
                              controller: _logScrollController,
                              thumbVisibility: true,
                              trackVisibility: true,
                              thickness: 10,
                              radius: const Radius.circular(4),
                              thumbColor: Colors.grey.shade500,
                              trackColor: Colors.grey.shade800,
                              child: TextField(
                                controller: _logController,
                                scrollController: _logScrollController,
                                maxLines: null,
                                readOnly: true,
                                style: const TextStyle(fontFamily: 'Consolas', fontSize: 10, color: Color(0xFF00FF00)),
                                decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              
              // Generated Images Panel (expands when log collapsed)
              Expanded(
                flex: _logCollapsed ? 1 : 3,  // Full width when log collapsed
                child: Card(
                  margin: const EdgeInsets.all(4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        color: Colors.green.shade100,
                        child: Row(
                          children: [
                            // Log toggle button (on left to open log)
                            IconButton(
                              icon: Icon(_logCollapsed ? Icons.terminal : Icons.chevron_left, size: 16),
                              onPressed: () => setState(() => _logCollapsed = !_logCollapsed),
                              tooltip: _logCollapsed ? 'Show Log' : 'Hide Log',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                            ),
                            const Icon(Icons.image, size: 14, color: Colors.green),
                            const SizedBox(width: 4),
                            Text('Generated (${_generatedImagePaths.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            const Spacer(),
                            // Show in folder button
                            TextButton.icon(
                              icon: const Icon(Icons.folder_open, size: 14),
                              label: const Text('Show in Downloads', style: TextStyle(fontSize: 10)),
                              onPressed: _openOutputFolder,
                              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                            ),
                            const SizedBox(width: 4),
                            TextButton(
                              onPressed: () => setState(() => _generatedImagePaths.clear()),
                              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 20)),
                              child: const Text('Clear', style: TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _generatedImagePaths.isEmpty
                            ? const Center(child: Text('No images yet', style: TextStyle(color: Colors.grey)))
                            : Builder(
                                builder: (context) {
                                  // Sort by scene number for sequential display
                                  final sortedPaths = List<String>.from(_generatedImagePaths);
                                  sortedPaths.sort((a, b) {
                                    final matchA = RegExp(r'scene_(\d+)_').firstMatch(path.basename(a));
                                    final matchB = RegExp(r'scene_(\d+)_').firstMatch(path.basename(b));
                                    final numA = int.tryParse(matchA?.group(1) ?? '0') ?? 0;
                                    final numB = int.tryParse(matchB?.group(1) ?? '0') ?? 0;
                                    return numB.compareTo(numA); // Descending order
                                  });
                                  
                                  return GridView.builder(
                                padding: const EdgeInsets.all(4),
                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _logCollapsed ? 3 : 2,  // More columns when log collapsed
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                ),
                                itemCount: sortedPaths.length,
                                itemBuilder: (context, index) {
                                  final imgPath = sortedPaths[index];
                                  // Extract scene number from filename (scene_X_timestamp.png)
                                  final filename = path.basename(imgPath);
                                  String sceneNo = '';
                                  final match = RegExp(r'scene_(\d+)_').firstMatch(filename);
                                  if (match != null) {
                                    sceneNo = match.group(1) ?? '';
                                  }
                                  return Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.file(File(imgPath), fit: BoxFit.cover),
                                      ),
                                      // Modern gradient overlay at bottom with scene label
                                      if (sceneNo.isNotEmpty)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.bottomCenter,
                                                end: Alignment.topCenter,
                                                colors: [
                                                  Colors.black.withOpacity(0.8),
                                                  Colors.transparent,
                                                ],
                                              ),
                                              borderRadius: const BorderRadius.only(
                                                bottomLeft: Radius.circular(4),
                                                bottomRight: Radius.circular(4),
                                              ),
                                            ),
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                            child: Row(
                                              children: [
                                                Text(
                                                  'Scene $sceneNo',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    letterSpacing: 0.3,
                                                  ),
                                                ),
                                                const Spacer(),
                                                // Add to Video Generation button
                                                InkWell(
                                                  onTap: () => _addToVideoGeneration(imgPath, sceneNo),
                                                  child: Container(
                                                    padding: const EdgeInsets.all(4),
                                                    decoration: BoxDecoration(
                                                      color: Colors.deepPurple.withOpacity(0.9),
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: const Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Icon(Icons.videocam, color: Colors.white, size: 12),
                                                        SizedBox(width: 2),
                                                        Text('Video', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // Column 2: Scenes
        Expanded(
          flex: 4,
          child: Card(
            margin: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  color: Colors.grey.shade200,
                  child: Row(
                    children: [
                      const Text('Scenes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.chevron_left, size: 20),
                        onPressed: _selectedSceneIndex > 0 ? () => _onSceneChange(_selectedSceneIndex - 1) : null,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        tooltip: 'Previous Scene',
                      ),
                      DropdownButton<int>(
                        value: (_selectedSceneIndex >= 0 && _selectedSceneIndex < _scenes.length) ? _selectedSceneIndex : null,
                        items: List.generate(_scenes.length, (i) => DropdownMenuItem(value: i, child: Text('${i + 1}'))),
                        onChanged: (v) => _onSceneChange(v ?? 0),
                        underline: const SizedBox(),
                        isDense: true,
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, size: 20),
                        onPressed: _selectedSceneIndex < _scenes.length - 1 ? () => _onSceneChange(_selectedSceneIndex + 1) : null,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        tooltip: 'Next Scene',
                      ),
                      const Spacer(),
                      if (_detectedCharsDisplay.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50, 
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue.shade200),
                          ),
                          child: Text(_detectedCharsDisplay, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blue.shade800)),
                        ),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: _copyPrompt, style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)), child: const Text('Copy Prompt', style: TextStyle(fontSize: 11))),
                    ],
                  ),
                ),
                // Range controls
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      const Text('Range:', style: TextStyle(fontSize: 11)),
                      const SizedBox(width: 4),
                      SizedBox(width: 40, child: TextField(controller: _fromRangeController, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(4)))),
                      const Text(' to '),
                      SizedBox(width: 40, child: TextField(controller: _toRangeController, textAlign: TextAlign.center, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.all(4)))),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.chevron_left, size: 20),
                        onPressed: _selectedSceneIndex > 0 ? () => _onSceneChange(_selectedSceneIndex - 1) : null,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        tooltip: 'Previous Scene',
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, size: 20),
                        onPressed: _selectedSceneIndex < _scenes.length - 1 ? () => _onSceneChange(_selectedSceneIndex + 1) : null,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        tooltip: 'Next Scene',
                      ),
                      const SizedBox(width: 8),
                      const Text('Aspect:', style: TextStyle(fontSize: 11)),
                      const SizedBox(width: 4),
                      DropdownButton<String>(
                        value: _aspectRatio,
                        items: ['16:9', '1:1', '9:16', '4:3', '3:4'].map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
                        onChanged: (v) => setState(() => _aspectRatio = v!),
                        underline: const SizedBox(),
                        isDense: true,
                      ),
                      const SizedBox(width: 12),
                      // Generate button
                      ElevatedButton.icon(
                        onPressed: _cdpRunning ? null : _startCdpGeneration,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('Generate'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.green.shade200,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                      // Stop button (visible when running)
                      if (_cdpRunning)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: ElevatedButton.icon(
                            onPressed: () => setState(() => _cdpRunning = false),
                            icon: const Icon(Icons.stop, size: 16),
                            label: const Text('Stop'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: TextField(
                      controller: _promptController,
                      maxLines: null,
                      expands: true,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Prompt...', isDense: true),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Column 3: Characters
        Expanded(
          flex: 2,
          child: Card(
            margin: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  color: Colors.grey.shade200,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Row 1: Title and Open Folder
                      Row(
                        children: [
                          const Text('Characters', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          const Spacer(),
                          OutlinedButton(
                            onPressed: () async {
                              final appDir = await getApplicationDocumentsDirectory();
                              final charDir = path.join(appDir.path, 'VEO3', 'characters');
                              await Directory(charDir).create(recursive: true);
                              if (Platform.isWindows) {
                                Process.run('explorer', [charDir]);
                              }
                            },
                            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                            child: const Text('Open Folder', style: TextStyle(fontSize: 10)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Row 2: Style dropdown and Generate All
                      Row(
                        children: [
                          const Text('Style:', style: TextStyle(fontSize: 10)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: DropdownButton<String>(
                              value: _selectedCharStyle,
                              isExpanded: true,
                              isDense: true,
                              items: _charImageStyles.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 10)))).toList(),
                              onChanged: (v) => setState(() => _selectedCharStyle = v ?? 'Realistic'),
                              underline: const SizedBox(),
                            ),
                          ),
                          const SizedBox(width: 4),
                          ElevatedButton(
                            onPressed: _charGenerating ? null : _generateAllCharacterImages,
                            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                            child: _charGenerating 
                                ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text('Gen All', style: TextStyle(fontSize: 10)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _characters.isEmpty
                      ? const Center(child: Text('No characters', style: TextStyle(color: Colors.grey, fontSize: 11)))
                      : ListView.builder(
                          controller: _charsScrollController,
                          itemCount: _characters.length,
                          itemBuilder: (ctx, i) => _buildCharacterCard(_characters[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildCharacterCard(CharacterData character) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(character.id, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              Text('${character.images.length}', style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
            ],
          ),
          if (character.images.isNotEmpty)
            SizedBox(
              height: 36,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: character.images.length,
                itemBuilder: (ctx, i) {
                  final imagePath = character.images[i];
                  final file = File(imagePath);
                  if (!file.existsSync()) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(right: 2, top: 2),
                    child: GestureDetector(
                      onTap: () => _showCharacterImageDialog(character, imagePath, i),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Image.file(file, width: 36, height: 36, fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _charGenerating ? null : () => _generateCharacterImage(character), 
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: Colors.blue), 
                child: const Text('Gen', style: TextStyle(fontSize: 10)),
              ),
              const Text('|', style: TextStyle(color: Colors.grey, fontSize: 10)),
              TextButton(onPressed: () => _importImagesForCharacter(character), style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap), child: const Text('Import', style: TextStyle(fontSize: 10))),
              const Text('|', style: TextStyle(color: Colors.grey, fontSize: 10)),
              TextButton(onPressed: () => _clearImagesForCharacter(character), style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: Colors.red), child: const Text('Clear', style: TextStyle(fontSize: 10))),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        border: Border(top: BorderSide(color: Colors.grey.shade400)),
      ),
      child: Text(_statusMessage, style: const TextStyle(fontSize: 11)),
    );
  }
}

/// Custom painter for a lovely bird flying animation
class _FlyingBirdPainter extends CustomPainter {
  final double animationValue; // 0.0 to 1.0

  _FlyingBirdPainter({required this.animationValue});

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    
    // Calculate oscillating vertical position (bobbing)
    final double bobOffset = 8 * (0.5 - (0.5 - animationValue).abs()) * (animationValue > 0.5 ? 1 : -1);
    final double birdY = centerY + bobOffset;
    
    final Paint bodyPaint = Paint()
      ..color = Colors.blueAccent.shade100
      ..style = PaintingStyle.fill;
      
    final Paint wingPaint = Paint()
      ..color = Colors.blueAccent.shade400
      ..style = PaintingStyle.fill;

    // Draw Bird Wings (Animated Flapping)
    // wingFactor goes from -1 (fully up) to 1 (fully down)
    final double wingFactor = -sin(animationValue * 2 * pi);
    
    // Left Wing
    final Path leftWing = Path()
      ..moveTo(centerX, birdY)
      ..quadraticBezierTo(centerX - 40, birdY - 40 * wingFactor, centerX - 60, birdY + 10 * wingFactor)
      ..quadraticBezierTo(centerX - 20, birdY + 10, centerX, birdY)
      ..close();
    canvas.drawPath(leftWing, wingPaint);
    
    // Right Wing
    final Path rightWing = Path()
      ..moveTo(centerX, birdY)
      ..quadraticBezierTo(centerX + 40, birdY - 40 * wingFactor, centerX + 60, birdY + 10 * wingFactor)
      ..quadraticBezierTo(centerX + 20, birdY + 10, centerX, birdY)
      ..close();
    canvas.drawPath(rightWing, wingPaint);

    // Draw Bird Body (Oval)
    canvas.drawOval(
      Rect.fromCenter(center: Offset(centerX, birdY), width: 40, height: 25),
      bodyPaint,
    );
    
    // Draw Bird Head
    canvas.drawCircle(Offset(centerX + 20, birdY - 8), 12, bodyPaint);
    
    // Draw Beak (Small Triangle)
    final Paint beakPaint = Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill;
    final Path beak = Path()
      ..moveTo(centerX + 30, birdY - 10)
      ..lineTo(centerX + 45, birdY - 8)
      ..lineTo(centerX + 30, birdY - 2)
      ..close();
    canvas.drawPath(beak, beakPaint);
    
    // Draw Eye
    final Paint eyePaint = Paint()..color = Colors.black..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(centerX + 26, birdY - 12), 2, eyePaint);
    
    // Draw Cute Tail
    final Path tail = Path()
      ..moveTo(centerX - 20, birdY)
      ..lineTo(centerX - 45, birdY - 15)
      ..lineTo(centerX - 45, birdY + 5)
      ..close();
    canvas.drawPath(tail, bodyPaint);
  }

  @override
  bool shouldRepaint(covariant _FlyingBirdPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}
