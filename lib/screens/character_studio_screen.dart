import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import '../utils/browser_utils.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../models/character_studio/character_data.dart';
import '../models/character_studio/entity_data.dart';
import '../models/character_studio/image_model_config.dart';
import '../models/scene_data.dart';
import '../models/poll_request.dart';
import '../services/gemini_hub_connector.dart';
import '../services/gemini_api_service.dart';
import '../services/google_image_api_service.dart';
import '../services/project_service.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';
import '../services/video_generation_service.dart';

import '../services/log_service.dart' as log_svc;
import '../utils/config.dart';
import '../widgets/studio_components.dart';
import '../models/project_data.dart';
import 'package:path/path.dart' as path;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'video_mastering_screen.dart';
import '../utils/video_export_helper.dart';
import '../utils/media_duration_helper.dart';

/// Character Studio — Full
/// Port of Python new_simplified.py to Flutter
class CharacterStudioScreen extends StatefulWidget {
  final ProjectService projectService;
  final bool isActivated;
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  final String? initialVideoModel;
  final String? initialAspectRatio;
  final String? initialEmail;
  final String? initialPassword;
  final bool embedded;
  final void Function(Map<String, dynamic>)? onAddToVideoGen;

  const CharacterStudioScreen({
    super.key,
    required this.projectService,
    required this.isActivated,
    this.profileManager,
    this.loginService,
    this.initialVideoModel,
    this.initialAspectRatio,
    this.initialEmail,
    this.initialPassword,
    this.embedded = false,
    this.onAddToVideoGen,
  });

  @override
  State<CharacterStudioScreen> createState() => _CharacterStudioScreenState();
}

class _CharacterStudioScreenState extends State<CharacterStudioScreen> with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  
  @override
  bool get wantKeepAlive => true; // Keep this tab alive when switching
  
  // ====================== TAB CONTROLLER ======================
  TabController? _tabController;
  
  // Story Prompt Tab State
  final TextEditingController _storyInputController = TextEditingController();
  final TextEditingController _promptCountController = TextEditingController(text: '10');
  String _selectedStoryModel = 'gemini-3-flash-preview';
  final List<Map<String, String>> _storyModels = [
    {'name': 'GEMINI 3 LATEST', 'id': 'gemini-3-flash-preview'},
    {'name': 'GEMINI 2.5 PRO', 'id': 'gemini-2.5-flash'},
    {'name': 'GEMINI 2 PRO', 'id': 'gemini-2.5-flash-preview-09-2025'},
  ];
  bool _storyGenerating = false;
  bool _useStructuredOutput = true;
  bool _useTemplate = true; // When false, just use raw story input as prompt
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
      'name': 'Character & Entity Consistent Masterprompt',
      'prompt': '''You are given a story or scene prompts.

⚠️ CRITICAL: DO NOT modify, rewrite, or creatively change the story content. Your job is to EXTRACT and STRUCTURE the exact content provided.

Your task is to extract CHARACTERS, ENTITIES (locations, objects, interiors, buildings, damaged items), and scenes for visual consistency.

═══════════════════════════════════════════════════════════
PART A: CHARACTER EXTRACTION (MANDATORY)
═══════════════════════════════════════════════════════════

1. CHARACTER EXTRACTION
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

═══════════════════════════════════════════════════════════
PART B: ENTITY EXTRACTION (MANDATORY FOR SCENE CONSISTENCY)
═══════════════════════════════════════════════════════════

3. ENTITY EXTRACTION
Extract EVERY significant visual element that appears in multiple scenes OR needs to stay consistent:

3.1 Entity Types (MUST categorize each):
- "location": Outdoor environments, landscapes, backgrounds (forest, beach, city street, mountain)
- "interior": Indoor spaces, rooms (bedroom, kitchen, throne room, spaceship bridge)
- "building": Structures, architecture (castle, house, tower, shop, temple)
- "object": Important props, vehicles, items (magic sword, spaceship, treasure chest, car)
- "damaged": Destroyed/damaged versions of locations or objects (burning_house, crashed_car, broken_bridge)
- "environment": Weather conditions, time of day, atmospheric effects (sunset, storm, foggy_morning)

3.2 Entity ID Naming Convention
Use descriptive snake_case: village_square, enchanted_forest, grandma_house, magic_crystal, burning_village
For damaged versions: original_id + "_damaged" (e.g., village_square_damaged, castle_ruins)

3.3 Entity Description
For each entity, provide:
- visual appearance (colors, textures, style, size)
- key distinguishing features
- condition/state (pristine, weathered, damaged, burning, etc.)
- atmosphere/mood it conveys

4. ENTITY OBJECT STRUCTURE
{
  "id": "unique entity ID",
  "name": "Human readable name",
  "type": "location|interior|building|object|damaged|environment",
  "description": "detailed visual description for AI image generation"
}

═══════════════════════════════════════════════════════════
PART C: SCENE CONSTRUCTION
═══════════════════════════════════════════════════════════

5. SCENE CONSTRUCTION (PRESERVE ORIGINAL CONTENT)
Break the story into exactly [SCENE_COUNT] continuous scenes.
⚠️ USE THE EXACT SCENE DESCRIPTIONS FROM THE INPUT. Do NOT rewrite or enhance them creatively.

5.1 Character Presence Rules
A character ID appears in a scene ONLY IF physically present.
❌ Do NOT include characters who are: mentioned verbally, remembered, imagined, referenced by possession

5.2 Entity Presence Rules
An entity ID appears in a scene ONLY IF it is VISIBLE in that scene.
✅ Include: The current location, visible objects, buildings in background, environmental conditions
❌ Do NOT include: Entities that are mentioned but not shown

5.3 Clothing & Appearance Rules
Do NOT describe outfits again inside scenes. A character's visual appearance is fixed by its character ID.
❌ No clothing_appearance field

6. SCENE STRUCTURE
Each scene must follow:
{
  "scene_number": N,
  "prompt": "Use the EXACT visual description from the input. Reference character and entity IDs. Do NOT rewrite creatively.",
  "video_action_prompt": "Use the EXACT action description from the input if provided, or extract from context.",
  "characters_in_scene": ["CharacterID1", "CharacterID2"],
  "entities_in_scene": ["location_id", "object_id", "building_id"],
  "negative_prompt": "do not alter character appearances, no extra characters, no distorted features, avoid text in image"
}

═══════════════════════════════════════════════════════════
PART D: TRACKING & MUSIC
═══════════════════════════════════════════════════════════

7. TRACKING
- List all character IDs under: output_structure.characters.included_characters
- List all entity IDs under: output_structure.entities.included_entities

8. BACKGROUND MUSIC
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

Story/Prompts (USE EXACTLY AS PROVIDED):
[STORY_TEXT]

Generate exactly [SCENE_COUNT] scenes using the EXACT content from above.''',
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
          "entity_reference": {
            "type": "ARRAY",
            "items": {
              "type": "OBJECT",
              "properties": {
                "id": {"type": "STRING"},
                "name": {"type": "STRING"},
                "type": {"type": "STRING"},
                "description": {"type": "STRING"}
              },
              "required": ["id", "name", "type", "description"]
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
              "entities": {
                "type": "OBJECT",
                "properties": {
                  "included_entities": {
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
                    "entities_in_scene": {
                      "type": "ARRAY",
                      "items": {"type": "STRING"}
                    },
                    "negative_prompt": {"type": "STRING"}
                  },
                  "required": ["scene_number", "prompt", "video_action_prompt", "characters_in_scene", "entities_in_scene"]
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
            "required": ["scenes", "characters", "entities", "story_title", "bgmusic"]
          }
        },
        "required": ["character_reference", "entity_reference", "output_structure"]
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
  
  // Entities for Scene Consistency (locations, objects, interiors, etc.)
  List<EntityData> _entities = [];
  int _leftPanelTabIndex = 0; // 0: Characters, 1: Entities
  bool _entityGenerating = false;
  String _detectedEntitiesDisplay = '';
  final ScrollController _entitiesScrollController = ScrollController();
  
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
  int _currentHubIndex = 0; // For round-robin browser selection
  final Map<int, DateTime> _hubCooldowns = {}; // Track browser cooldowns after failures
  
  // Gemini API for Story Prompt Tab (official Google AI API with multi-key support)
  GeminiApiService? _geminiApi;
  
  // Google Image API for direct API image generation (Flow models)
  GoogleImageApiService? _googleImageApi;
  
  // UI State
  int _selectedSceneIndex = 0;
  int _selectedVideoSceneIndex = 0;
  String? _playingVideoPath; // Track currently playing video
  Player? _inlineVideoPlayer; // Inline video player
  VideoController? _inlineVideoController; // Inline video controller
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
  Map<String, SceneData> _videoSceneStates = {};  // Map image path -> video generation state
  bool _logCollapsed = true;  // Log panel collapsed by default
  bool _controlPanelCollapsed = true;  // Control panel collapsed by default to save space
  
  // Main Section Selection
  int _mainSectionIndex = 0; // 0: Image to Video, 1: Text to Video, 2: Trending Templates
  
  // Live Generation Stats
  int _statsTotal = 0;
  List<Map<String, dynamic>> _failedQueue = [];
  int _statsGenerating = 0;
  int _statsPolling = 0;
  int _statsCompleted = 0;
  int _statsFailed = 0;
  
  // Character Image Generation
  static const List<String> _charImageStyles = [
    'No Style',  // Uses prompt as-is, no extra modifiers
    'Realistic',
    '3D Pixar',
    '2D Cartoon',
    'Anime',
    'Watercolor',
    'Oil Painting',
  ];
  String _selectedCharStyle = 'No Style';
  bool _charGenerating = false;
  final Map<String, String> _charImagePrompts = {}; // imagePath -> prompt used
  // Cache for uploaded reference images (base64 -> upload info) to avoid re-uploading
  final Map<String, RecipeMediaInput> _uploadedRefImageCache = {};
  
  // Style Image for Generation
  String? _styleImagePath; // Path to selected style image
  RecipeMediaInput? _uploadedStyleInput; // Cached uploaded style media
  
  // Dio for HTTP requests (image upload, etc.)
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 60),
  ));
  
  // Text to Video Section
  int _t2vTabIndex = 0; // 0: Prompts, 1: Video
  int _t2vStoryInputTab = 0; // 0: Story Concept, 1: Raw Story Prompt
  final TextEditingController _t2vStoryController = TextEditingController();
  final TextEditingController _t2vRawPromptController = TextEditingController(); // NEW: For raw prompts
  final TextEditingController _t2vResponseController = TextEditingController();
  final TextEditingController _t2vPromptsCountController = TextEditingController(text: '10');
  List<Map<String, dynamic>> _t2vScenes = [];
  bool _t2vGenerating = false;
  bool _t2vUseTemplate = true;
  bool _t2vJsonOutput = true;
  String _t2vSelectedModel = 'gemini-3-flash-preview';
  int _t2vResponseViewTab = 0; // 0: Scenes, 1: Raw Response
  String _t2vStoryTitle = ''; // Story title from generated JSON
  List<Map<String, dynamic>> _t2vBgMusic = []; // Background music prompts from JSON
  
  // Video Generation State
  bool _videoGenerationRunning = false;
  bool _videoGenerationPaused = false;
  int _activeGenerationsCount = 0;
  final List<_PendingPoll> _pendingPolls = [];
  bool _generationComplete = false;
  int _consecutiveFailures = 0;
  List<SceneData> _videoScenes = [];
  String _videoSelectedModel = 'Veo 3.1 - Fast [Lower Priority]';
  String _videoSelectedAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE';
  String _savedEmail = '';
  String _savedPassword = '';
  int _maxConcurrentRelaxed = 4;
  int _maxConcurrentFast = 20;
  
  // Project Management
  ProjectManager? _projectManager;
  ProjectData? _currentProject;
  StreamSubscription? _videoStatusSubscription;

  static const List<String> _videoModelOptions = [
    'Veo 3.1 - Fast [Lower Priority]',
    'Veo 3.1 - Quality [Lower Priority]',
    'Veo 3.1 - Fast',
    'Veo 3.1 - Quality',
    'Veo 2 - Fast [Lower Priority]',
    'Veo 2 - Quality [Lower Priority]',
    'Veo 2 - Fast',
    'Veo 2 - Quality',
  ];
  
  static const List<Map<String, String>> _aspectRatioOptions = [
    {'name': 'Landscape 16:9', 'value': 'VIDEO_ASPECT_RATIO_LANDSCAPE'},
    {'name': 'Portrait 9:16', 'value': 'VIDEO_ASPECT_RATIO_PORTRAIT'},
    {'name': 'Square 1:1', 'value': 'VIDEO_ASPECT_RATIO_SQUARE'},
  ];

  // ====================== INIT / DISPOSE ======================
  
  @override
  void initState() {
    super.initState();
    // Initialize TabController - force length 3 for Prompts/Images/Video
    _tabController?.dispose();
    _tabController = TabController(length: 3, vsync: this);
    
    // Load Gemini API key
    _loadGeminiApiKey();
    
    // Initialize Video Settings from widget if provided
    if (widget.initialVideoModel != null) {
      _videoSelectedModel = widget.initialVideoModel!;
    }
    if (widget.initialAspectRatio != null) {
      _videoSelectedAspectRatio = widget.initialAspectRatio!;
    }
    if (widget.initialEmail != null) {
      _savedEmail = widget.initialEmail!;
    }
    if (widget.initialPassword != null) {
      _savedPassword = widget.initialPassword!;
    }
    
    // Use Downloads folder for output
    _cdpOutputFolder = path.join(Platform.environment['USERPROFILE'] ?? Directory.current.path, 'Downloads');
    
    // Load video scene states
    _loadVideoSceneStates();
    _loadImageModels();
    _loadProfiles();
    _loadExistingCharacterImages();
    _initializeProjectManager(); // Initialize project system (handles all persistence)

    // Listen to tab changes to update toolbar
    _tabController?.addListener(() {
      if (mounted) setState(() {});
    });

    // Initialize Video Generation Service
    VideoGenerationService().initialize(
      profileManager: widget.profileManager,
      loginService: widget.loginService,
      email: _savedEmail,
      password: _savedPassword,
      accountType: 'ai_ultra',
    );
    
    // Listen to video status updates
    _videoStatusSubscription = VideoGenerationService().statusStream.listen((msg) {
      if (msg == 'UPDATE' && mounted) {
        setState(() {}); // Refresh UI on updates
        _saveVideoSceneStates(); // Auto-save progress
      } else if (msg == 'COMPLETED' && mounted) {
        if (_videoGenerationRunning) {
          _log('✅ Video generation batch completed');
          setState(() {
            _videoGenerationRunning = false;
            _videoGenerationPaused = false;
          });
        }
      } else if (mounted) {
         // Log generation messages to UI log if needed
         if (msg.startsWith('[GENERATE]') || msg.startsWith('[BATCH')) {
           // _log(msg); // Optional: verbose logging
         }
      }
    });
  }

  @override
  void didUpdateWidget(CharacterStudioScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-initialize service if profile manager reference changes (e.g. was null, now initialized)
    if (widget.profileManager != oldWidget.profileManager) {
      if (widget.profileManager != null) {
        _log('🔄 ProfileManager updated from parent, updating VideoGenerationService');
        VideoGenerationService().initialize(
          profileManager: widget.profileManager,
          loginService: widget.loginService,
          email: _savedEmail,
          password: _savedPassword,
          accountType: 'ai_ultra',
        );
        if (mounted) setState(() {});
      }
    }
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
    _videoStatusSubscription?.cancel();
    // Auto-save before disposing
    _autoSaveProject();
    
    _tabController?.dispose();
    _storyInputController.dispose();
    _promptCountController.dispose();
    _responseEditorController.dispose();
    _responseScrollController.dispose();
    _t2vRawPromptController.dispose(); // NEW: Dispose raw prompt controller
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
    if (msg.isEmpty) return;
    final now = DateTime.now();
    final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    final fullMsg = "[$timeStr] $msg";
    
    setState(() {
      _logController.text += "$fullMsg\n";
    });
    
    // Also push to global LogService
    log_svc.LogService().info(msg);

    // Scroll to bottom if not collapsed
    if (!_logCollapsed) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_logScrollController.hasClients) {
          _logScrollController.animateTo(
            _logScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }
  void _clearLog() {
    setState(() => _logController.clear());
    log_svc.LogService().clear();
  }

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
        
        // Restore generated image paths
        if (json['generatedImagePaths'] != null) {
          final List<dynamic> imagePaths = json['generatedImagePaths'];
          _generatedImagePaths = imagePaths
            .map((p) => p.toString())
            .where((p) => File(p).existsSync()) // Only keep existing files
            .toList();
          if (_generatedImagePaths.isNotEmpty) {
            _log('✅ Restored ${_generatedImagePaths.length} generated images');
          }
        }
        
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
        'generatedImagePaths': _generatedImagePaths, // Save generated images
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
      
      _log('📁 Scanning character folders...');
      
      for (final character in _characters) {
        // Clear existing images list
        character.images.clear();
        
        // Look for folder matching character ID
        final charDir = Directory(path.join(charRootDir.path, character.id));
        
        if (await charDir.exists()) {
          _log('  📂 Found folder: ${character.id}');
          
          // Scan for all image files
          final files = await charDir.list().where((e) => e is File).toList();
          for (final file in files) {
            final ext = path.extension(file.path).toLowerCase();
            if (['.png', '.jpg', '.jpeg', '.webp'].contains(ext)) {
              character.images.add(file.path);
              _log('    📸 Found: ${path.basename(file.path)}');
            }
          }
          
          if (character.images.isNotEmpty) {
            _log('  ✅ Loaded ${character.images.length} images for ${character.id}');
          }
        } else {
          _log('  ⚠️ No folder found for ${character.id}');
        }
      }

      if (mounted) setState(() {});
    } catch (e) {
      _log('❌ Failed to load character images: $e');
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
    
    //Default options: Nano Banana, Imagen 4, and Google Flow models
    final defaultModels = [
      ImageModelConfig(name: 'Whisk Ai', url: 'IMAGEN_3_5', modelType: 'api', apiModelId: 'IMAGEN_3_5'),
      ImageModelConfig(name: 'Nano Banana (Default)', url: 'GEMINI_2_FLASH_IMAGE', modelType: 'cdp'),
      ImageModelConfig(name: 'Imagen 4', url: 'IMAGEN_4', modelType: 'cdp'),
      ImageModelConfig(name: 'Whisk Ai Precise', url: 'GEM_PIX', modelType: 'api', apiModelId: 'GEM_PIX'),
    ];

    // Remove all default models first (to ensure fresh objects with correct types)
    final defaultNames = defaultModels.map((m) => m.name).toSet();
    final defaultUrls = defaultModels.map((m) => m.url).toSet();
    
    // Also include the legacy URL to clean up old configs
    defaultUrls.add('GEMINI_2_5_FLASH_IMAGE');
    
    _imageModels.removeWhere((m) => defaultNames.contains(m.name) || defaultUrls.contains(m.url));
    
    // Add fresh default models
    _imageModels.addAll(defaultModels);
    _log('Loaded ${defaultModels.length} default models');
    
    // Remove GemPix 2 if it's there (user requested to remove it)
    _imageModels.removeWhere((m) => m.url == 'GEM_PIX_2');
    
    // Save updated models to file
    await _saveImageModels();
    
    // Log all models and their types
    _log('=== Image Models Loaded ===');
    for (var model in _imageModels) {
      _log('${model.name}: type=${model.modelType}, apiId=${model.apiModelId ?? "none"}');
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
  
  // ====================== VIDEO SCENE STATE PERSISTENCE ======================
  
  Future<void> _loadVideoSceneStates() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final stateFile = File(path.join(appDir.path, 'VEO3', 'video_scene_states.json'));
      
      if (await stateFile.exists()) {
        final content = await stateFile.readAsString();
        final Map<String, dynamic> json = jsonDecode(content);
        
        _videoSceneStates = json.map((key, value) => 
          MapEntry(key, SceneData.fromJson(value as Map<String, dynamic>))
        );
        
        _log('📂 Loaded ${_videoSceneStates.length} video scene states');
        
        // Restore generated image paths if they exist
        final imagePaths = _videoSceneStates.keys.where((p) => File(p).existsSync()).toList();
        if (imagePaths.isNotEmpty) {
          // Merge with any paths already loaded from session state
          final existingPaths = _generatedImagePaths.toSet();
          for (final path in imagePaths) {
            if (!existingPaths.contains(path)) {
              _generatedImagePaths.add(path);
            }
          }
          _log('✅ Total ${_generatedImagePaths.length} generated images available');
        }
        
        setState(() {});
      }
    } catch (e) {
      _log('⚠️ Failed to load video scene states: $e');
    }
  }
  
  Future<void> _saveVideoSceneStates() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final veoDir = Directory(path.join(appDir.path, 'VEO3'));
      if (!await veoDir.exists()) await veoDir.create(recursive: true);
      
      final stateFile = File(path.join(veoDir.path, 'video_scene_states.json'));
      final json = _videoSceneStates.map((key, value) => 
        MapEntry(key, value.toJson())
      );
      
      await stateFile.writeAsString(jsonEncode(json));
    } catch (e) {
      _log('⚠️ Failed to save video scene states: $e');
    }
  }
  
  Future<void> _clearVideoSceneStates() async {
    try {
      _videoSceneStates.clear();
      await _saveVideoSceneStates();
      _log('🗑️ Cleared all video scene states');
      setState(() {});
    } catch (e) {
      _log('⚠️ Failed to clear video scene states: $e');
    }
  }
  
  // ====================== PROJECT MANAGEMENT ======================
  
  Future<void> _initializeProjectManager() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final projectsDir = path.join(appDir.path, 'VEO3', 'projects');
      
      _projectManager = ProjectManager(projectsDir);
      await _projectManager!.initialize();
      
      // Load or create default project
      if (_projectManager!.projects.isEmpty) {
        await _createNewProject('My First Project');
      } else {
        _currentProject = _projectManager!.projects.first;
        await _loadProjectData(_currentProject!);
      }
      
      _log('📁 Project system initialized (${_projectManager!.projects.length} projects)');
      setState(() {});
    } catch (e) {
      _log('⚠️ Failed to initialize project manager: $e');
    }
  }
  
  Future<void> _createNewProject(String name, {String? description}) async {
    try {
      final project = await _projectManager!.createProject(name, description: description);
      _currentProject = project;
      
      // Clear current data
      _scenes.clear();
      _generatedImagePaths.clear();
      _videoSceneStates.clear();
      
      _log('✨ Created new project: $name');
      setState(() {});
    } catch (e) {
      _log('❌ Failed to create project: $e');
    }
  }
  
  Future<void> _loadProjectData(ProjectData project) async {
    try {
      _currentProject = project;
      
      // Restore scenes
      _scenes = List<Map<String, dynamic>>.from(project.scenes);
      
      // Restore generated images (filter non-existent files)
      _generatedImagePaths = project.generatedImagePaths
          .where((p) => File(p).existsSync())
          .toList();
      
      // Restore video scene states
      _videoSceneStates.clear();
      for (final entry in project.videoSceneStates.entries) {
        try {
          _videoSceneStates[entry.key] = SceneData.fromJson(entry.value);
        } catch (e) {
          _log('⚠️ Failed to restore video state for ${entry.key}: $e');
        }
      }
      
      // Restore settings
      _aspectRatio = project.aspectRatio;
      _videoSelectedModel = project.videoModel;
      _videoSelectedAspectRatio = project.videoAspectRatio;
      
      _log('📂 Loaded project: ${project.name}');
      _log('   Scenes: ${_scenes.length}, Images: ${_generatedImagePaths.length}');
      
      // Parse characters from scenes
      if (_scenes.isNotEmpty) {
        // First, try to restore the full JSON data from the project
        if (project.fullJsonData != null) {
          // Use the saved full JSON structure (includes character_reference, etc.)
          _data = project.fullJsonData!;
          _log('✅ Restored full JSON data from project');
        } else if (project.jsonPath != null && await File(project.jsonPath!).exists()) {
          // Fallback: Load from the original JSON file
          try {
            final jsonContent = await File(project.jsonPath!).readAsString();
            _data = jsonDecode(jsonContent) as Map<String, dynamic>;
            _log('✅ Loaded JSON from file: ${project.jsonPath}');
          } catch (e) {
            _log('⚠️ Could not load original JSON: $e');
            _data = {'scenes': _scenes};
          }
        } else {
          // Last resort: Reconstruct minimal structure
          _data = {'scenes': _scenes};
          _log('⚠️ No full JSON data available, using scenes only');
        }
        
        _parseCharacters();
        
        // Restore character images from saved data
        if (project.characterData.isNotEmpty) {
          for (final charJson in project.characterData) {
            try {
              final savedChar = CharacterData.fromJson(charJson);
              // Find matching character in _characters and update its images
              final index = _characters.indexWhere((c) => c.id == savedChar.id);
              if (index != -1) {
                _characters[index].images = savedChar.images
                    .where((img) => File(img).existsSync()) // Only keep existing files
                    .toList();
              }
            } catch (e) {
              _log('⚠️ Failed to restore character data: $e');
            }
          }
          _log('✅ Restored character images');
        }
        
        // Initialize UI state for first scene
        _selectedSceneIndex = 0;
        _toRangeController.text = _scenes.length.toString();
        
        // Display first scene prompt
        const encoder = JsonEncoder.withIndent('  ');
        _promptController.text = encoder.convert(_scenes[0]);
        _detectCharsInPrompt(); // Auto-detect characters in first scene
        
        // Scan character/entity folders for existing images
        await _scanAndLoadImagesFromDisk();
      }
      
      setState(() {});
    } catch (e) {
      _log('❌ Failed to load project data: $e');
    }
  }
  
  /// Scan character/entity folders and load existing images from disk
  /// Called on app startup and when switching to Characters/Entities tabs
  Future<void> _scanAndLoadImagesFromDisk() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      
      // Scan character folders
      for (final char in _characters) {
        final charFolderPath = path.join(appDir.path, 'VEO3', 'characters', char.id);
        final charFolder = Directory(charFolderPath);
        
        if (await charFolder.exists()) {
          final images = await charFolder
              .list()
              .where((f) => f is File && (f.path.endsWith('.jpg') || f.path.endsWith('.png') || f.path.endsWith('.jpeg')))
              .map((f) => f.path)
              .toList();
          
          if (images.isNotEmpty) {
            char.images = images;
            _log('📁 Loaded ${images.length} images for character: ${char.id}');
          }
        }
      }
      
      // Scan entity folders
      for (final entity in _entities) {
        final entityFolderPath = path.join(appDir.path, 'VEO3', 'entities', entity.id);
        final entityFolder = Directory(entityFolderPath);
        
        if (await entityFolder.exists()) {
          final images = await entityFolder
              .list()
              .where((f) => f is File && (f.path.endsWith('.jpg') || f.path.endsWith('.png') || f.path.endsWith('.jpeg')))
              .map((f) => f.path)
              .toList();
          
          if (images.isNotEmpty) {
            entity.images = images;
            _log('📁 Loaded ${images.length} images for entity: ${entity.id}');
          }
        }
      }
      
      // Auto-save the updated image lists to project
      await _autoSaveProject();
      
      if (mounted) setState(() {});
    } catch (e) {
      _log('⚠️ Failed to scan folders for images: $e');
    }
  }
  
  Future<void> _autoSaveProject() async {
    if (_currentProject == null || _projectManager == null) return;
    
    try {
      // Update project data
      _currentProject = _currentProject!.copyWith(
        jsonPath: _jsonPath,
        scenes: _scenes,
        fullJsonData: _data, // Save the complete JSON structure
        characterData: _characters.map((c) => c.toJson()).toList(), // Save character data with images
        generatedImagePaths: _generatedImagePaths,
        videoSceneStates: _videoSceneStates.map(
          (key, value) => MapEntry(key, value.toJson())
        ),
        aspectRatio: _aspectRatio,
        videoModel: _videoSelectedModel,
        videoAspectRatio: _videoSelectedAspectRatio,
      );
      
      await _projectManager!.saveProject(_currentProject!);
    } catch (e) {
      // Silent fail for auto-save
    }
  }
  
  Future<void> _deleteProject(String projectId) async {
    try {
      await _projectManager!.deleteProject(projectId);
      
      // If we deleted the current project, load another one
      if (_currentProject?.id == projectId) {
        if (_projectManager!.projects.isNotEmpty) {
          await _loadProjectData(_projectManager!.projects.first);
        } else {
          await _createNewProject('My First Project');
        }
      }
      
      _log('🗑️ Deleted project');
      setState(() {});
    } catch (e) {
      _log('❌ Failed to delete project: $e');
    }
  }
  
  void _showProjectsDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.folder, color: Colors.deepPurple),
              const SizedBox(width: 12),
              const Text('Projects'),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_circle, color: Colors.green),
                onPressed: () {
                  Navigator.pop(context);
                  _showCreateProjectDialog();
                },
                tooltip: 'New Project',
              ),
            ],
          ),
          content: SizedBox(
            width: 600,
            height: 400,
            child: _projectManager == null || _projectManager!.projects.isEmpty
                ? const Center(child: Text('No projects yet'))
                : ListView.builder(
                    itemCount: _projectManager!.projects.length,
                    itemBuilder: (context, index) {
                      final project = _projectManager!.projects[index];
                      final isActive = project.id == _currentProject?.id;
                      
                      return Card(
                        color: isActive ? Colors.blue.shade50 : null,
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(
                            Icons.folder,
                            color: isActive ? Colors.blue : Colors.grey,
                          ),
                          title: Text(
                            project.name,
                            style: TextStyle(
                              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (project.description != null)
                                Text(project.description!),
                              const SizedBox(height: 4),
                              Text(
                                'Updated: ${_formatDate(project.updatedAt)} • '
                                '${project.scenes.length} scenes • '
                                '${project.generatedImagePaths.length} images',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isActive)
                                IconButton(
                                  icon: const Icon(Icons.open_in_new, size: 20),
                                  onPressed: () async {
                                    Navigator.pop(context);
                                    await _loadProjectData(project);
                                  },
                                  tooltip: 'Load Project',
                                ),
                              IconButton(
                                icon: const Icon(Icons.delete, size: 20, color: Colors.red),
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Delete Project?'),
                                      content: Text('Delete "${project.name}"? This cannot be undone.'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        ElevatedButton(
                                          onPressed: () => Navigator.pop(ctx, true),
                                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  );
                                  
                                  if (confirm == true) {
                                    await _deleteProject(project.id);
                                    setDialogState(() {});
                                    if (mounted) setState(() {});
                                  }
                                },
                                tooltip: 'Delete Project',
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showCreateProjectDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Project Name',
                hintText: 'My Awesome Story',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'A brief description...',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                Navigator.pop(context);
                _createNewProject(
                  nameController.text.trim(),
                  description: descController.text.trim().isEmpty 
                    ? null 
                    : descController.text.trim(),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
  
  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    
    return '${date.day}/${date.month}/${date.year}';
  }
  
  /// Get output folder for current project
  String _getProjectOutputFolder() {
    if (_currentProject == null) {
      return _cdpOutputFolder;
    }
    
    // Sanitize project name for folder
    final safeName = _currentProject!.name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .trim();
    
    return path.join(_cdpOutputFolder, safeName);
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
      _tabController?.animateTo(1);  // Navigate to Images tab (index 1)
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

  /// Pick a style image for generation
  Future<void> _pickStyleImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    
    if (result != null && result.files.isNotEmpty) {
      final filePath = result.files.first.path;
      if (filePath != null) {
        setState(() {
          _styleImagePath = filePath;
          _uploadedStyleInput = null; // Clear cache when new image selected
        });
        _log('🎨 Style image selected: ${path.basename(filePath)}');
      }
    }
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
      
      // Auto-save project with new scenes
      await _autoSaveProject();
      
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
        await _autoSaveProject();
      } else {
        await _processJsonContent(content, sourceName: path.basename(targetPath));
      }
    } catch (e) {
      _log('❌ Failed to load: $e');
    }
  }
  
  void _parseCharacters() {
    _characters.clear();
    
    // 1. Try part_a.characters (New format with full character details)
    if (_data.containsKey('part_a') && _data['part_a'] is Map) {
      final partA = _data['part_a'] as Map;
      if (partA.containsKey('characters') && partA['characters'] is List) {
        for (final charData in partA['characters'] as List) {
          if (charData is Map && charData.containsKey('id')) {
            _characters.add(CharacterData(
              id: charData['id'].toString(),
              name: (charData['name'] ?? charData['id']).toString(),
              description: (charData['description'] ?? charData['visual_description'] ?? charData['appearance'] ?? '').toString(),
              keyPath: ['part_a', 'characters', charData['id'].toString()],
              images: [],
            ));
          }
        }
      }
    }
    
    // 2. Try output_structure.characters.character_details (Another new format)
    if (_characters.isEmpty && _data.containsKey('output_structure') && _data['output_structure'] is Map) {
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

    // 3. Try character_reference (Old list format)
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
    
    // 4. Try character_reference (Old map format with main/secondary)
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

    // 5. Try root characters list
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
    
    // Also parse entities
    _parseEntities();
  }

  /// Parse entities from JSON data (locations, objects, interiors, buildings, damaged items, environments)
  void _parseEntities() {
    _entities.clear();
    
    // 1. Try part_b.entities (New format with full entity details)
    if (_data.containsKey('part_b') && _data['part_b'] is Map) {
      final partB = _data['part_b'] as Map;
      if (partB.containsKey('entities') && partB['entities'] is List) {
        for (final entityData in partB['entities'] as List) {
          if (entityData is Map<String, dynamic> && entityData.containsKey('id')) {
            _entities.add(EntityData.fromJson(entityData));
          }
        }
      }
    }
    
    // 2. Try entity_reference (primary format from new prompt template)
    if (_entities.isEmpty && _data.containsKey('entity_reference') && _data['entity_reference'] is List) {
      for (final entityData in _data['entity_reference']) {
        if (entityData is Map<String, dynamic> && entityData.containsKey('id')) {
          _entities.add(EntityData.fromJson(entityData));
        }
      }
    }
    
    // 3. Try output_structure.entities.entity_details (alternative format)
    if (_entities.isEmpty && _data.containsKey('output_structure') && _data['output_structure'] is Map) {
      final os = _data['output_structure'] as Map;
      if (os.containsKey('entities') && os['entities'] is Map) {
        final entities = os['entities'] as Map;
        if (entities.containsKey('entity_details') && entities['entity_details'] is List) {
          final details = entities['entity_details'] as List;
          for (final entityData in details) {
            if (entityData is Map<String, dynamic> && entityData.containsKey('id')) {
              _entities.add(EntityData.fromJson(entityData));
            }
          }
        }
      }
    }
    
    // 4. Try root entities list
    if (_entities.isEmpty && _data.containsKey('entities') && _data['entities'] is List) {
      for (final entityData in _data['entities'] as List) {
        if (entityData is Map<String, dynamic> && entityData.containsKey('id')) {
          _entities.add(EntityData.fromJson(entityData));
        }
      }
    }
    
    // 5. Extract entities from scenes (fallback: look for entities_in_scene references)
    if (_entities.isEmpty && _scenes.isNotEmpty) {
      final entityIds = <String>{};
      for (final scene in _scenes) {
        if (scene.containsKey('entities_in_scene') && scene['entities_in_scene'] is List) {
          for (final entityId in scene['entities_in_scene']) {
            if (entityId is String && !entityIds.contains(entityId)) {
              entityIds.add(entityId);
            }
          }
        }
      }
      // Create placeholder entities from scene references
      for (final entityId in entityIds) {
        _entities.add(EntityData(
          id: entityId,
          name: entityId.replaceAll('_', ' ').split(' ').map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : w).join(' '),
          description: 'Entity referenced in scenes',
          type: _guessEntityType(entityId),
        ));
      }
    }
    
    _log('🏞️ Parsed ${_entities.length} entities from JSON');
  }

  /// Guess entity type from ID naming conventions
  EntityType _guessEntityType(String entityId) {
    final id = entityId.toLowerCase();
    if (id.contains('damaged') || id.contains('destroyed') || id.contains('broken') || id.contains('ruins') || id.contains('burning')) {
      return EntityType.damaged;
    }
    if (id.contains('room') || id.contains('kitchen') || id.contains('bedroom') || id.contains('hall') || id.contains('interior') || id.contains('inside')) {
      return EntityType.interior;
    }
    if (id.contains('house') || id.contains('castle') || id.contains('tower') || id.contains('building') || id.contains('shop') || id.contains('temple')) {
      return EntityType.building;
    }
    if (id.contains('sword') || id.contains('car') || id.contains('ship') || id.contains('chest') || id.contains('item') || id.contains('object')) {
      return EntityType.object;
    }
    if (id.contains('sunset') || id.contains('storm') || id.contains('rain') || id.contains('fog') || id.contains('night') || id.contains('weather')) {
      return EntityType.environment;
    }
    return EntityType.location; // Default to location
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
        
        if (prevScene.isNotEmpty) {
          // Add entire scene object as context (requested by user)
          promptJson['previous_scenes_context'].add(prevScene);
        }
      }
      
      // Reverse for chronological order (oldest first)
      promptJson['previous_scenes_context'] = (promptJson['previous_scenes_context'] as List).reversed.toList();
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
          
          // Maintain resolution (don't scale down) but compress to stay under 100KB
          img.Image resizedImage = originalImage;
          /* Removed resize cap to 256px as per user request to avoid pixelation
          const int maxDim = 256;
          if (originalImage.width > maxDim || originalImage.height > maxDim) {
            if (originalImage.width >= originalImage.height) {
              resizedImage = img.copyResize(originalImage, width: maxDim);
            } else {
              resizedImage = img.copyResize(originalImage, height: maxDim);
            }
          }
          */
          
          // Compress with progressive quality reduction to get under 100KB
          const int targetSizeBytes = 100 * 1024; // 100KB
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
      
      // Clean up stale paths that no longer exist
      character.images.removeWhere((imgPath) => !File(imgPath).existsSync());
      
      setState(() {});
      _log('✅ Imported $imported (resolution preserved, target <100KB)');
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
    String desc = character.description;
    if (desc.isEmpty) {
      desc = 'A character named ${character.name}';
    }
    
    // If 'No Style' is selected, use description as-is with minimal framing
    if (_selectedCharStyle == 'No Style') {
      return '$desc. Character portrait with face clearly visible, centered composition.';
    }
    
    final stylePrefix = {
      'Realistic': 'Photorealistic portrait photo,',
      '3D Pixar': '3D Pixar-style character, round friendly features, vibrant colors,',
      '2D Cartoon': '2D cartoon character illustration, clean lines, bold colors,',
      'Anime': 'Anime-style character portrait, large expressive eyes, detailed hair,',
      'Watercolor': 'Watercolor painting portrait, soft edges, artistic,',
      'Oil Painting': 'Classical oil painting portrait, rich textures, fine brushwork,',
    }[_selectedCharStyle] ?? '';
    
    // Add background and framing instructions
    return '$stylePrefix $desc. Character portrait with face clearly visible, centered composition, flat solid gray-white background, professional studio lighting, high quality, detailed features.';
  }
  
  /// Build style-enhanced prompt for entity image generation
  String _buildEntityPrompt(EntityData entity) {
    String desc = entity.description;
    if (desc.isEmpty) {
      desc = 'A ${entity.type} named ${entity.name}';
    }
    
    // If 'No Style' is selected, use description as-is with minimal framing
    if (_selectedCharStyle == 'No Style') {
      return '$desc. ${entity.type} view, centered composition.';
    }
    
    final stylePrefix = {
      'Realistic': 'Photorealistic photo,',
      '3D Pixar': '3D Pixar-style rendering, vibrant colors,',
      '2D Cartoon': '2D cartoon illustration, clean lines, bold colors,',
      'Anime': 'Anime-style illustration, detailed,',
      'Watercolor': 'Watercolor painting, soft edges, artistic,',
      'Oil Painting': 'Classical oil painting, rich textures, fine brushwork,',
    }[_selectedCharStyle] ?? '';
    
    // Build type-specific instructions
    String typeInstructions = '';
    switch (entity.type) {
      case 'location':
        typeInstructions = 'wide establishing shot, atmospheric, detailed environment';
        break;
      case 'interior':
        typeInstructions = 'interior view, detailed architecture, good lighting';
        break;
      case 'building':
        typeInstructions = 'exterior architectural view, detailed structure';
        break;
      case 'object':
        typeInstructions = 'centered product shot, neutral background, high detail';
        break;
      case 'damaged':
        typeInstructions = 'detailed damage and destruction, dramatic lighting';
        break;
      case 'environment':
        typeInstructions = 'atmospheric environmental shot, immersive';
        break;
      default:
        typeInstructions = 'detailed view, high quality';
    }
    
    return '$stylePrefix $desc. $typeInstructions, professional lighting, high quality, detailed.';
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
  
  /// Get the next available CDP hub using round-robin with cooldown
  /// Returns null if all hubs are in cooldown or no hubs connected
  GeminiHubConnector? _getNextAvailableHub({bool markCooldown = false, int? failedPort}) {
    if (_cdpHubs.isEmpty) return null;
    
    // If a specific hub failed, mark it for cooldown
    if (markCooldown && failedPort != null) {
      _hubCooldowns[failedPort] = DateTime.now().add(const Duration(seconds: 15));
      _log('⏸️ Browser on port $failedPort cooling down for 15 seconds');
    }
    
    final now = DateTime.now();
    final hubList = _cdpHubs.entries.toList();
    
    // Try to find an available hub starting from current index
    for (int i = 0; i < hubList.length; i++) {
      final index = (_currentHubIndex + i) % hubList.length;
      final entry = hubList[index];
      final port = entry.key;
      final hub = entry.value;
      
      // Check if this hub is in cooldown
      if (_hubCooldowns.containsKey(port)) {
        if (now.isBefore(_hubCooldowns[port]!)) {
          // Still in cooldown
          continue;
        } else {
          // Cooldown expired, remove it
          _hubCooldowns.remove(port);
        }
      }
      
      // Found an available hub!
      _currentHubIndex = (index + 1) % hubList.length; // Move to next for next call
      return hub;
    }
    
    // All hubs are in cooldown
    _log('⏸️ All browsers are in cooldown. Waiting...');
    return null;
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
      final modelIdJs = (_selectedImageModel == null || _selectedImageModel!.url.isEmpty)
          ? 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE'
          : 'window.geminiHub.models.${_selectedImageModel!.url}';
          
      final spawnResult = await hub.spawnImage(
        prompt,
        aspectRatio: '1:1',
        refImages: refImages.isNotEmpty ? refImages : null,
        model: modelIdJs,
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
  
  /// Ensure we have a valid Whisk API session, automatically launching browser if needed
  Future<bool> _ensureWhiskSession({bool forceRefresh = false}) async {
    _googleImageApi ??= GoogleImageApiService();
    
    // If not forcing refresh and session appears valid, stick with it
    if (!forceRefresh && _googleImageApi!.isSessionValid) return true;
    
    if (forceRefresh) {
      _log('🔄 Forcing session refresh...');
      // We assume the service has a way to reset, but if not, we just proceed to overwrite
    }
    
    for (int attempt = 1; attempt <= 3; attempt++) {
      // If we just got a valid session in a previous loop iteration (rare but possible)
      // and we are not in the very first iteration of a forceRefresh...
      if (!forceRefresh && _googleImageApi!.isSessionValid) return true;
      
      _log('🔑 Whisk Session: Attempt $attempt/3...');
      
      // 1. Try loading from file first (skip if forcing refresh as file might be stale)
      if (!forceRefresh) {
        final loaded = await _googleImageApi!.loadCredentials();
        if (loaded && _googleImageApi!.isSessionValid) {
          _log('  ✓ Loaded from credentials file');
          return true;
        }
      }
      
      // 2. Ensure browser is open and connected
      if (_cdpHubs.isEmpty) {
        _log('  🌐 No browser connected. Auto-launching...');
        await _autoConnectBrowser();
      }
      
      // 3. Try to extract cookies
      if (_cdpHubs.isNotEmpty) {
        final hub = _cdpHubs.values.first;
        try {
          _log('  📂 Extracting cookies from browser...');
          var cookieString = await hub.getCookiesForDomain('https://labs.google/fx/tools/whisk/project');
          
          // If no cookies or forcing refresh, open the page for the user
          if (forceRefresh || cookieString == null || cookieString.isEmpty) {
             _log('  ⚠️ No valid session found. Opening Whisk login page...');
             await hub.navigateTo('https://labs.google/fx/tools/whisk');
             
             _log('  ⏳ Waiting up to 60s for login (please login in browser)...');
             // Poll for cookies
             for (int i = 0; i < 30; i++) {
               await Future.delayed(const Duration(seconds: 2));
               cookieString = await hub.getCookiesForDomain('https://labs.google/fx/tools/whisk/project');
               // Check if we got a potentially valid cookie (length > 100 is a heuristic)
               if (cookieString != null && cookieString.length > 50) {
                 _log('  ✓ Detected cookies!');
                 break;
               }
             }
          }
          
          if (cookieString != null && cookieString.isNotEmpty) {
            final session = await _googleImageApi!.checkSession(cookieString);
            if (session.isActive) {
               _log('  ✓ Authenticated via browser cookies');
               return true;
            } else {
               _log('  ⚠️ Cookies found but session invalid/expired.');
            }
          } else {
            _log('  ⚠️ Still no cookies found after waiting.');
          }
        } catch (e) {
          _log('  ⚠️ Connection lost or error: $e');
          _cdpHubs.clear(); // Clear so next attempt re-connects/re-launches
          _log('  🔄 Connection lost. Cleared status, will retry with fresh launch');
        }
      }
      
      // Small delay before retry
      if (attempt < 3) {
        _log('  ⏳ Waiting 2s before retry...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    
    return false;
  }

  /// Generate images for all characters (grouped by base name for consistency)
  Future<void> _generateAllCharacterImages() async {
    final isApiModel = _selectedImageModel?.modelType == 'api';

    if (isApiModel) {
      final ok = await _ensureWhiskSession();
      if (!ok) {
        _log('❌ Could not establish Whisk session after 3 attempts');
        return;
      }
    } else if (_cdpHubs.isEmpty) {
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
    _log('🎨 Model: ${_selectedImageModel?.name} (${isApiModel ? "API" : "CDP"})');
    _log('✨ Style: $_selectedCharStyle');
    
    int success = 0;
    int failed = 0;
    
    if (isApiModel) {
      // === API METHOD - Process sequentially ===
      for (final baseName in charGroups.keys) {
        final group = charGroups[baseName]!;
        
        for (int gi = 0; gi < group.length; gi++) {
          if (!_charGenerating) break;
          
          final character = group[gi];
          
          try {
            final prompt = _buildCharacterPrompt(character);
            _log('Generating ${character.id}...');
            
            final apiModelId = _selectedImageModel?.apiModelId ?? 'IMAGEN_3_5';
            final aspectRatio = GoogleImageApiService.convertAspectRatio('1:1');
            
            final response = await _googleImageApi!.generateImage(
              prompt: prompt,
              aspectRatio: aspectRatio,
              imageModel: apiModelId,
            );
            
            if (response.imagePanels.isNotEmpty && response.imagePanels.first.generatedImages.isNotEmpty) {
              final base64Image = response.imagePanels.first.generatedImages.first.encodedImage;
              await _saveCharacterImage(base64Image, character, prompt);
              _log('✓ Generated ${character.id}');
              success++;
            } else {
              _log('✗ Failed ${character.id}: Empty response');
              failed++;
            }
          } catch (e) {
            _log('Error ${character.id}: $e');
            failed++;
          }
        }
      }
    } else {
      // === CDP METHOD - Process in PARALLEL batches ===
      _log('🚀 Using ${_cdpHubs.length} browsers in parallel');
      
      // Flatten all characters into a queue
      final queue = <CharacterData>[];
      for (final baseName in charGroups.keys) {
        queue.addAll(charGroups[baseName]!);
      }
      
      // Process in batches matching number of browsers
      final batchSize = _cdpHubs.length;
      
      for (int i = 0; i < queue.length && _charGenerating; i += batchSize) {
        final batch = queue.skip(i).take(batchSize).toList();
        _log('📦 Processing batch ${(i ~/ batchSize) + 1}/${(queue.length / batchSize).ceil()} (${batch.length} characters)');
        
        // Process all characters in this batch in parallel
        final results = await Future.wait(
          batch.map((character) async {
            try {
              final prompt = _buildCharacterPrompt(character);
              
              // Get next available hub (round-robin with cooldown)
              final hub = _getNextAvailableHub();
              if (hub == null) {
                _log('⏸️ No available browsers for ${character.id}. Waiting...');
                await Future.delayed(const Duration(seconds: 3));
                final retryHub = _getNextAvailableHub();
                if (retryHub == null) {
                  _log('✗ Failed ${character.id}: All browsers unavailable');
                  return {'success': false, 'character': character.id};
                }
              }
              
              final activeHub = hub ?? _getNextAvailableHub()!;
              final hubPort = _cdpHubs.entries.firstWhere((e) => e.value == activeHub).key;
              
              try {
                await activeHub.focusChrome();
                await activeHub.checkLaunchModal();
                
                final modelIdJs = (_selectedImageModel == null || _selectedImageModel!.url.isEmpty)
                    ? 'window.geminiHub.models.GEMINI_2_FLASH_IMAGE'
                    : 'window.geminiHub.models.${_selectedImageModel!.url}';
                    
                final spawnResult = await activeHub.spawnImage(
                  prompt,
                  aspectRatio: '1:1',
                  model: modelIdJs,
                );
                
                if (spawnResult == null) {
                  _log('Failed to spawn (null) for ${character.id} on port $hubPort');
                  _getNextAvailableHub(markCooldown: true, failedPort: hubPort);
                  return {'success': false, 'character': character.id};
                }
                
                String? threadId;
                if (spawnResult is Map && spawnResult.containsKey('id')) {
                  threadId = spawnResult['id']?.toString();
                } else if (spawnResult is String && spawnResult.isNotEmpty) {
                  threadId = spawnResult;
                }
                
                if (threadId == null || threadId.isEmpty) {
                  _log('Failed to spawn for ${character.id} on port $hubPort');
                  _getNextAvailableHub(markCooldown: true, failedPort: hubPort);
                  return {'success': false, 'character': character.id};
                }
                
                _log('Spawned ${character.id} on Port $hubPort');
                
                await Future.delayed(const Duration(seconds: 2));
                await activeHub.focusChrome();
                await activeHub.checkLaunchModal();
                
                // Poll for completion
                final startPoll = DateTime.now();
                while (DateTime.now().difference(startPoll).inSeconds < 180) {
                  final res = await activeHub.getThread(threadId);
                  
                  if (res is Map) {
                    if (res['status'] == 'COMPLETED' && res['result'] != null) {
                      final result = res['result'];
                      if (result is String && result.isNotEmpty) {
                        await _saveCharacterImage(result, character, prompt);
                        _log('✓ Generated ${character.id} on Port $hubPort');
                        return {'success': true, 'character': character.id};
                      }
                    } else if (res['status'] == 'FAILED') {
                      _log('✗ Failed ${character.id} on Port $hubPort');
                      _getNextAvailableHub(markCooldown: true, failedPort: hubPort);
                      return {'success': false, 'character': character.id};
                    }
                  }
                  
                  if (DateTime.now().difference(startPoll).inSeconds % 5 == 0) {
                    await activeHub.checkLaunchModal();
                  }
                  
                  await Future.delayed(const Duration(milliseconds: 800));
                }
                
                _log('Timeout ${character.id} on Port $hubPort');
                _getNextAvailableHub(markCooldown: true, failedPort: hubPort);
                return {'success': false, 'character': character.id};
                
              } catch (hubError) {
                _log('❌ Browser error for ${character.id} on Port $hubPort: $hubError');
                _getNextAvailableHub(markCooldown: true, failedPort: hubPort);
                return {'success': false, 'character': character.id};
              }
            } catch (e) {
              _log('Error ${character.id}: $e');
              return {'success': false, 'character': character.id};
            }
          }),
        );
        
        // Count successes and failures
        for (final result in results) {
          if (result['success'] == true) {
            success++;
          } else {
            failed++;
          }
        }
        
        // Small delay between batches
        if (i + batchSize < queue.length) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    
    _log('Complete: $success success, $failed failed');
    setState(() => _charGenerating = false);
  }

  /// Generate image for a SINGLE character
  Future<void> _generateSingleCharacterImage(CharacterData character, {int retryCount = 0}) async {
    if (_charGenerating) {
      _log('Character generation already in progress');
      return;
    }
    
    setState(() => _charGenerating = true);
    
    try {
      final prompt = _buildCharacterPrompt(character);
      _log('Generating single character: ${character.id}...');
      
      // Check if the selected model is an API model (Flow models)
      final isApiModel = _selectedImageModel?.modelType == 'api';
      _log('Using ${isApiModel ? "API" : "CDP"} method');
      
      if (isApiModel) {
        // === API METHOD ===
        final ok = await _ensureWhiskSession();
        if (!ok) {
          _log('❌ Could not establish Whisk session');
          setState(() => _charGenerating = false);
          return;
        }
        
        final apiModelId = _selectedImageModel?.apiModelId ?? 'IMAGEN_3_5';
        final aspectRatio = GoogleImageApiService.convertAspectRatio('1:1');
        
        final response = await _googleImageApi!.generateImage(
          prompt: prompt,
          aspectRatio: aspectRatio,
          imageModel: apiModelId,
        );
        
        if (response.imagePanels.isEmpty || response.imagePanels.first.generatedImages.isEmpty) {
          throw 'No images returned from API';
        }
        
        final base64Image = response.imagePanels.first.generatedImages.first.encodedImage;
        await _saveCharacterImage(base64Image, character, prompt);
        _log('✓ Generated ${character.id} via API');
        
      } else {
        // === CDP METHOD ===
        if (_cdpHubs.isEmpty) {
          _log('No browsers connected! Open browsers first.');
          setState(() => _charGenerating = false);
          return;
        }
        
        _log('Using CDP method for ${_selectedImageModel?.name ?? "default model"}');
        
        final hub = _cdpHubs.values.first;
        
        // Attempt to find a reference image from the SAME character group (base name)
        // e.g. if gen "cow_outfit_002", try to find "cow_outfit_001" image
        List<String>? refImages;
        final baseName = _getBaseCharacterName(character.id);
        
        // Find other characters with same base name
        final group = _characters.where((c) => _getBaseCharacterName(c.id) == baseName).toList();
        group.sort((a, b) => a.id.compareTo(b.id)); // Sort by ID
        
        // If this is NOT the first char in group, try to find an earlier char with an image
        if (group.indexOf(character) > 0) {
          final firstChar = group.first;
          if (firstChar.images.isNotEmpty) {
             final imgPath = firstChar.images.first;
             final file = File(imgPath);
             if (await file.exists()) {
               try {
                 final bytes = await file.readAsBytes();
                 final b64 = base64Encode(bytes);
                 refImages = ['data:image/jpeg;base64,$b64'];
                 _log('Using ${firstChar.id} as reference');
               } catch (e) {
                 _log('Error reading ref: $e');
               }
             }
          }
        }
        
        await hub.focusChrome();
        await hub.checkLaunchModal();
        
        final modelIdJs = (_selectedImageModel == null || _selectedImageModel!.url.isEmpty)
            ? 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE'
            : 'window.geminiHub.models.${_selectedImageModel!.url}';
            
        final spawnResult = await hub.spawnImage(
          prompt,
          aspectRatio: '1:1',
          refImages: refImages,
          model: modelIdJs,
        );
        
        if (spawnResult == null) {
          throw 'Failed to spawn (null response)';
        }
        
        String? threadId;
        if (spawnResult is Map && spawnResult.containsKey('id')) {
          threadId = spawnResult['id']?.toString();
        } else if (spawnResult is String && spawnResult.isNotEmpty) {
          threadId = spawnResult;
        }
        
        if (threadId == null) {
          throw 'Invalid thread ID';
        }
        
        _log('Spawned ${character.id}');
        
        await Future.delayed(const Duration(seconds: 2));
        await hub.focusChrome();
        
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
                _log('✓ Generated ${character.id} via CDP');
                completed = true;
              }
              break;
            } else if (res['status'] == 'FAILED') {
              throw 'Generation status FAILED';
            }
          }
          
          await Future.delayed(const Duration(milliseconds: 800));
        }
        
        if (!completed) throw 'Timeout waiting for image';
      }
      
    } catch (e) {
      if (e.toString().contains('401') && retryCount < 1) {
        _log('⚠️ Auth 401. Refreshing session...');
        try {
          final refreshed = await _ensureWhiskSession(forceRefresh: true);
          if (refreshed) {
            _log('✅ Session refreshed. Retrying...');
            setState(() => _charGenerating = false); // Unlock for retry
            await _generateSingleCharacterImage(character, retryCount: retryCount + 1);
            return;
          }
        } catch (authErr) {
          _log('❌ Failed to refresh auth: $authErr');
        }
      }
      _log('❌ Generation failed: $e');
    } finally {
      setState(() => _charGenerating = false);
    }
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
      
      // Maintain resolution but compress to JPEG
      /* Removed resize cap to 256px as per user request
      img.Image resized;
      if (originalImage.width > originalImage.height) {
        resized = img.copyResize(originalImage, width: 256);
      } else {
        resized = img.copyResize(originalImage, height: 256);
      }
      */
      
      // Compress to JPEG
      List<int> outputBytes = img.encodeJpg(originalImage, quality: 80);
      
      // Reduce quality if needed to stay under 100KB
      int quality = 80;
      while (outputBytes.length > 100 * 1024 && quality > 20) {
        quality -= 10;
        outputBytes = img.encodeJpg(originalImage, quality: quality);
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
        // User requested to replace the old image with the new one
        character.images = [destPath];
      });
      
      return destPath;
      
    } catch (e) {
      _log('Save error: $e');
      return null;
    }
  }
  
  /// Save generated entity image (similar to character images but in entities folder)
  Future<String?> _saveEntityImage(String base64Data, EntityData entity, [String? prompt]) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final entityDir = Directory(path.join(appDir.path, 'VEO3', 'entities', entity.id));
      if (!await entityDir.exists()) await entityDir.create(recursive: true);
      
      // Extract base64
      String b64Part = base64Data;
      if (base64Data.contains(',')) {
        b64Part = base64Data.split(',').last;
      }
      
      final bytes = base64Decode(b64Part);
      
      // Decode image
      final img.Image? originalImage = img.decodeImage(bytes);
      if (originalImage == null) {
        _log('[Entity] Failed to decode generated image');
        return null;
      }
      
      // Compress to JPEG
      List<int> outputBytes = img.encodeJpg(originalImage, quality: 80);
      
      // Reduce quality if needed to stay under 100KB
      int quality = 80;
      while (outputBytes.length > 100 * 1024 && quality > 20) {
        quality -= 10;
        outputBytes = img.encodeJpg(originalImage, quality: quality);
      }
      
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'gen_${timestamp}.jpg';
      final destPath = path.join(entityDir.path, filename);
      
      await File(destPath).writeAsBytes(outputBytes);
      
      // Store the prompt used for this image
      if (prompt != null) {
        _charImagePrompts[destPath] = prompt;
      }
      
      setState(() {
        // Replace old image with new one
        entity.images = [destPath];
      });
      
      return destPath;
      
    } catch (e) {
      _log('[Entity] Save error: $e');
      return null;
    }
  }
  
  /// Show image preview dialog with prompt editing and regeneration
  void _showCharacterImageDialog(CharacterData character, String imagePath, int imageIndex) {
    final promptController = TextEditingController(
      text: _charImagePrompts[imagePath] ?? _buildCharacterPrompt(character),
    );
    bool isRegenerating = false;
    String? newImagePath; // Will store the path ONLY after Save & Replace
    String? newImageB64; // Store regenerated image as base64 temporarily
    String? refImagePath; // For imported reference image
    String? refImageB64; // Base64 encoded reference
    // Use the model from the main page (_selectedImageModel) instead of local selection
    
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
                      child: newImageB64 != null
                          ? Image.memory(
                              base64Decode(newImageB64!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 40),
                            )
                          : imagePath.isNotEmpty && File(imagePath).existsSync()
                              ? Image.file(
                                  File(imagePath),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 40),
                                )
                              : Container(
                                  color: Colors.grey.shade100,
                                  child: const Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
                                        SizedBox(height: 8),
                                        Text('No image yet', style: TextStyle(color: Colors.grey)),
                                        SizedBox(height: 4),
                                        Text('Generate or import below', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                      ],
                                    ),
                                  ),
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
                        // Clickable icon area to import images
                        InkWell(
                          onTap: () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              allowMultiple: true, // Allow selecting multiple images
                            );
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
                                
                                // If multiple images selected, log them for future use
                                if (result.files.length > 1) {
                                  _log('${result.files.length} images selected (using first one)');
                                }
                              } catch (e) {
                                _log('Error loading ref image: $e');
                              }
                            }
                          },
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: refImagePath != null ? null : Colors.grey.shade200,
                              border: Border.all(color: refImagePath != null ? Colors.blue : Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: refImagePath != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: Image.file(File(refImagePath!), fit: BoxFit.cover),
                                  )
                                : const Icon(Icons.image, size: 20, color: Colors.grey),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            refImagePath != null ? path.basename(refImagePath!) : 'Click icon to import',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis,
                          ),
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
                      onPressed: () async {
                        // Check if we have either a prompt or reference image
                        final hasPrompt = promptController.text.trim().isNotEmpty;
                        final hasRefImage = refImageB64 != null;
                        
                        if (!hasPrompt && !hasRefImage) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter a prompt or import a reference image')),
                          );
                          return;
                        }
                        
                        // Set regenerating state immediately for instant UI feedback
                        setDialogState(() => isRegenerating = true);
                        
                        // Check requirements based on model
                        final selectedModel = _selectedImageModel?.name ?? 'Nano Banana (Default)';
                        final isWhiskModel = selectedModel == 'Whisk Ai' || selectedModel == 'Whisk Ai Precise';
                        
                        if (isWhiskModel) {
                          // Whisk models use API - use same method as main scene generation
                          _googleImageApi ??= GoogleImageApiService();
                          
                          // Try to load stored credentials first
                          if (!_googleImageApi!.isSessionValid) {
                            _log('🔑 Checking stored credentials...');
                            final loaded = await _googleImageApi!.loadCredentials();
                            
                            if (loaded && _googleImageApi!.isSessionValid) {
                              final expiry = _googleImageApi!.sessionExpiry;
                              final remaining = expiry!.difference(DateTime.now());
                              _log('✅ Using stored credentials (${remaining.inHours}h ${remaining.inMinutes % 60}m remaining)');
                            } else {
                              // Need to extract fresh cookies from browser
                              _log('🔑 Need fresh cookies from browser...');
                              
                              // Auto-connect to Chrome if not connected
                              if (_cdpHubs.isEmpty) {
                                _log('🌐 Auto-connecting to Chrome...');
                                await _autoConnectBrowser();
                                
                                if (_cdpHubs.isEmpty) {
                                  setDialogState(() => isRegenerating = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Could not connect to Chrome. Please open Chrome with --remote-debugging-port=9222')),
                                  );
                                  return;
                                }
                              }
                              
                              _log('🔑 Extracting cookies from labs.google/fx/tools/whisk...');
                              final hub = _cdpHubs.values.first;
                              final cookieString = await hub.getCookiesForDomain('https://labs.google/fx/tools/whisk/project');
                              
                              if (cookieString == null || cookieString.isEmpty) {
                                _log('❌ Failed to extract cookies');
                                setDialogState(() => isRegenerating = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Failed to extract cookies from browser')),
                                );
                                return;
                              }
                              
                              try {
                                final session = await _googleImageApi!.checkSession(cookieString);
                                _log('✅ Authenticated (expires: ${session.timeRemainingFormatted})');
                                _log('💾 Credentials saved for future use');
                              } catch (e) {
                                _log('❌ Auth failed: $e');
                                setDialogState(() => isRegenerating = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Authentication failed: $e')),
                                );
                                return;
                              }
                            }
                          } else {
                            final expiry = _googleImageApi!.sessionExpiry;
                            final remaining = expiry!.difference(DateTime.now());
                            _log('✅ Session still valid (${remaining.inHours}h ${remaining.inMinutes % 60}m remaining)');
                          }
                        } else {
                          // CDP models require AI Studio
                          if (_cdpHubs.isEmpty) {
                            setDialogState(() => isRegenerating = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Please connect to AI Studio first (check Image Generation settings)')),
                            );
                            return;
                          }
                        }
                        
                        _log('Regenerating ${character.id}...');
                        _log('Model: $selectedModel');
                        _log('Full prompt: ${promptController.text}');
                        if (refImageB64 != null) {
                          _log('Using imported reference image');
                        }
                        
                        try {
                          if (isWhiskModel) {
                            // Use Google Image API for Whisk models
                            String apiModel = selectedModel == 'Whisk Ai Precise' ? 'GEM_PIX' : 'IMAGEN_3_5';
                            _log('Using Whisk API model: $apiModel');
                            
                            ImageGenerationResponse response;
                            
                            if (refImageB64 != null) {
                              // Use uploadImageWithCaption + runImageRecipe for ref images
                              // Same method as main screen generation
                              _log('📤 Uploading reference image...');
                              
                              // Strip data URL prefix if present
                              String cleanB64 = refImageB64!;
                              if (cleanB64.contains(',')) {
                                cleanB64 = cleanB64.split(',').last;
                              }
                              
                              final workflowId = _googleImageApi!.getNewWorkflowId();
                              
                              final uploaded = await _googleImageApi!.uploadImageWithCaption(
                                base64Image: cleanB64,
                                workflowId: workflowId,
                                mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                              );
                              
                              final recipeInputs = [
                                RecipeMediaInput(
                                  caption: uploaded.caption,
                                  mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                                  mediaGenerationId: uploaded.mediaGenerationId,
                                ),
                              ];
                              
                              _log('⏳ Generating with reference image...');
                              response = await _googleImageApi!.runImageRecipe(
                                userInstruction: promptController.text,
                                recipeMediaInputs: recipeInputs,
                                workflowId: workflowId,
                                aspectRatio: 'IMAGE_ASPECT_RATIO_SQUARE',
                                imageModel: apiModel,
                              );
                            } else {
                              // No reference image - simple generation
                              response = await _googleImageApi!.generateImage(
                                prompt: promptController.text,
                                aspectRatio: 'IMAGE_ASPECT_RATIO_SQUARE',
                                imageModel: apiModel,
                              );
                            }
                            
                            if (response.imagePanels.isNotEmpty && 
                                response.imagePanels.first.generatedImages.isNotEmpty) {
                              final generatedImage = response.imagePanels.first.generatedImages.first;
                              final base64Image = generatedImage.encodedImage;
                              
                              // Store base64 temporarily - don't save to disk yet
                              // Strip data URI prefix if present
                              String cleanB64 = base64Image;
                              if (cleanB64.contains(',')) {
                                cleanB64 = cleanB64.split(',').last;
                              }
                              newImageB64 = cleanB64;
                              _log('✅ Regenerated ${character.id} using $apiModel (not saved yet)');
                            } else {
                              _log('⚠️ No images generated');
                            }
                          } else {
                            // Use CDP for Nano Banana and Imagen 4
                            final hub = _cdpHubs.values.first;
                            await hub.focusChrome();
                            await hub.checkLaunchModal();
                            
                            // Map model names to JS identifiers
                            String modelIdJs;
                            switch (selectedModel) {
                              case 'Nano Banana (Default)':
                                modelIdJs = 'window.geminiHub.models.NANO_BANANA';
                                break;
                              case 'Imagen 4':
                                modelIdJs = 'window.geminiHub.models.IMAGEN_4';
                                break;
                              default:
                                modelIdJs = 'window.geminiHub.models.NANO_BANANA';
                            }
                            
                            _log('Using CDP model: $modelIdJs');
                                
                            final spawnResult = await hub.spawnImage(
                              promptController.text,
                              aspectRatio: '1:1',
                              refImages: refImageB64 != null ? [refImageB64!] : null,
                              model: modelIdJs,
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
                                    // Store base64 temporarily - don't save to disk yet
                                    // Strip data URI prefix if present
                                    String cleanB64 = result;
                                    if (cleanB64.contains(',')) {
                                      cleanB64 = cleanB64.split(',').last;
                                    }
                                    newImageB64 = cleanB64;
                                    _log('Regenerated ${character.id} (not saved yet)');
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
            if (newImageB64 != null)
              TextButton(
                onPressed: () async {
                  try {
                    // Save the new image to disk
                    final savedPath = await _saveCharacterImage(newImageB64!, character, promptController.text);
                    
                    if (savedPath != null) {
                      // Delete old image file if it exists
                      if (imagePath.isNotEmpty) {
                        final oldFile = File(imagePath);
                        if (await oldFile.exists()) {
                          await oldFile.delete();
                        }
                        _charImagePrompts.remove(imagePath);
                      }
                      
                      // Update character images list
                      setState(() {
                        if (imagePath.isNotEmpty) {
                          final idx = character.images.indexOf(imagePath);
                          if (idx >= 0) {
                            character.images[idx] = savedPath; // Replace with new path
                          } else {
                            character.images.add(savedPath); // Add if not found
                          }
                        } else {
                          character.images.add(savedPath); // Add as first image
                        }
                      });
                      
                      _log('✅ Saved and replaced image');
                    }
                  } catch (e) {
                    _log('❌ Error saving: $e');
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
    
    const targetUrl = 'https://labs.google/fx/tools/flow';
    
    final args = BrowserUtils.getChromeArgs(
      debugPort: 9222,
      profilePath: userDataDir,
      url: targetUrl,
      windowSize: '650,500',
      windowPosition: '50,50', // Open at top-left, not center-screen
    );
    // Add profile directory (custom for this class)
    args.insert(args.length - 1, '--profile-directory=$_selectedProfile');
    
    _log('🚀 Launching Chrome on port 9222...');
    
    try {
      final process = await Process.start(chromePath, args, mode: ProcessStartMode.detached);
      // Removed forceAlwaysOnTop - let browser stay in background
      // if (Platform.isWindows) {
      //   BrowserUtils.forceAlwaysOnTop(process.pid, width: 650, height: 500);
      // }
      _log('✅ Chrome launched (background)');
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
    
    // Determine URL based on active tab
    String targetUrl = 'https://labs.google/fx/tools/flow'; // Default to Video (Flow)
    
    // If in Image to Video section (0) and specifically on Image Generation tab (1)
    if (_mainSectionIndex == 0 && _tabController != null && _tabController!.index == 1) {
      targetUrl = 'https://ai.studio/apps/drive/1Ya1yVIDQwYUszdiS9qzqS7pQvYP1_UL8?fullscreenApplet=true';
      _log('🖼️ Detected Image Tab - Opening AI Studio for Image Generation...');
    } else {
      _log('🎥 Detected Video/Story Tab - Opening Google Flow for Video Generation...');
    }
    
    // Calculate window positions (tile horizontally)
    const windowWidth = 500;
    const windowHeight = 400;
    
    for (int i = 0; i < count; i++) {
      final port = _cdpBasePort + i;
      final profileName = 'Profile ${i + 1}';
      final userDataDir = path.join(Directory.current.path, profileName, 'User Data');
      await Directory(userDataDir).create(recursive: true);
      
      // Calculate position: tile horizontally at top of screen
      final xPos = 10 + (i * 210); // 200 width + 10px spacing
      final yPos = 10; // Top of screen
      
      final args = BrowserUtils.getChromeArgs(
        debugPort: port,
        profilePath: userDataDir,
        url: targetUrl,
        windowSize: '200,350',
        windowPosition: '$xPos,$yPos',
      );
      
      _log('  🖥️ Opening $profileName (Port $port)...');
      
      try {
        final process = await Process.start(chromePath, args, mode: ProcessStartMode.detached);
        // Removed forceAlwaysOnTop - let browsers stay in background
        // if (Platform.isWindows) {
        //   BrowserUtils.forceAlwaysOnTop(process.pid, width: 200, height: 350, offsetIndex: i);
        // }
        _log('    ✅ Launched (background)');
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
  
  Future<int> _connectAllBrowsers({int maxAttempts = 5}) async {
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
    
    // Update status
    int connectedCount = _cdpHubs.length;
    _browserStatus = connectedCount > 0 ? '$connectedCount Browsers Connected' : 'Disconnected';
    
    // SYNC with ProfileManager for Video Generation
    if (widget.profileManager != null) {
      _log('📡 Syncing with Video Profile Manager...');
      // Initialize profiles list if not already
      await widget.profileManager!.initializeProfiles(count);
      
      for (int i = 0; i < count; i++) {
        final port = _cdpBasePort + i;
        final profile = widget.profileManager!.profiles[i];
        
        if (_cdpHubs.containsKey(port)) {
          // Connected! Create a Video Generator for it
          final vGen = DesktopGenerator(debugPort: port);
          await vGen.connect();
          profile.generator = vGen;
          profile.status = ProfileStatus.connected;
          
          // Try to get token
          try {
            final token = await vGen.getAccessToken();
            if (token != null) {
              profile.accessToken = token;
              _log('  ✓ Video Token synced for Port $port');
            }
          } catch(e) {}
        }
      }
    }
    
    setState(() {});
    _log('✓ Connected to $connectedCount browsers');
    return connectedCount;
  }
  
  /// Auto-connect to a single Chrome browser for API cookie extraction
  // Logic to launch if not found
  Future<void> _autoConnectBrowser() async {
    const port = 9222;
    _log('  Attempting to connect to Chrome on port $port...');
    
    try {
      final connector = GeminiHubConnector();
      await connector.connect(port: port);
      _cdpHubs[port] = connector;
      _log('  ✓ Connected to Chrome on port $port');
      setState(() => _browserStatus = '● 1 Browser');
    } catch (e) {
      _log('  ⚠️ Chrome not found on port $port. Launching...');
      
      String? chromePath;
      final candidates = [
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        path.join(Platform.environment['LOCALAPPDATA'] ?? '', 'Google', 'Chrome', 'Application', 'chrome.exe'),
      ];
      
      for (final p in candidates) {
        if (await File(p).exists()) {
          chromePath = p;
          break;
        }
      }
      
      if (chromePath == null) {
        _log('  ❌ Chrome executable not found');
        return;
      }
      
      final userDataDir = path.join(Directory.current.path, 'User Data');
      await Directory(userDataDir).create(recursive: true);

      try {
        await Process.start(chromePath, [
          '--remote-debugging-port=$port',
          '--user-data-dir=$userDataDir',
          '--profile-directory=$_selectedProfile',
          '--check-for-update-interval=604800',
          'https://labs.google/fx/tools/whisk/project'
        ], mode: ProcessStartMode.detached);
        _log('  🚀 Launched Chrome. Waiting for startup...');
        
        // Wait for Chrome to start and connect - increased attempts for slower systems
        for (int i = 0; i < 15; i++) {
          await Future.delayed(const Duration(seconds: 2));
          try {
             final connector = GeminiHubConnector();
             await connector.connect(port: port);
             _cdpHubs[port] = connector;
             _log('  ✓ Connected to Chrome on port $port');
             setState(() => _browserStatus = '● 1 Browser');
             return;
          } catch (e) {
            if (i == 14) _log('  ❌ Connection failed after 30s: $e');
          }
        }
        _log('  ❌ Failed to connect after launch');
      } catch (e2) {
        _log('  ❌ Failed to launch Chrome: $e2');
      }
    }
  }
  
  // ====================== CDP GENERATION (EXACT PYTHON LOGIC) ======================
  
  Future<List<String>> _getRefImagesForScene(int sceneIndex) async {
    if (sceneIndex < 0 || sceneIndex >= _scenes.length) return [];
    
    final scene = _scenes[sceneIndex];
    final charsInScene = (scene['characters_in_scene'] as List?)?.map((e) => e.toString()).toList() ?? [];
    
    final List<String> refImagesB64 = [];
    for (final charId in charsInScene) {
      final char = _characters.firstWhere((c) => c.id == charId, orElse: () => CharacterData(id: charId, name: charId, description: ''));
      if (char.images.isNotEmpty) {
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
    return refImagesB64;
  }

  Future<void> _regenerateSingleScene(int sceneNum, String prompt) async {
    final isApiModel = _selectedImageModel?.modelType == 'api';
    _log('⚡ Regenerating Scene $sceneNum with edited prompt... (${isApiModel ? "API" : "CDP"} method)');
    
    if (isApiModel) {
      // === API METHOD (Whisk models) ===
      try {
        final ok = await _ensureWhiskSession();
        if (!ok) {
          _log('❌ Could not establish Whisk session for regen');
          return;
        }
        
        final apiModelId = _selectedImageModel?.apiModelId ?? 'IMAGEN_3_5';
        final aspectRatio = GoogleImageApiService.convertAspectRatio(_aspectRatio);
        
        // Get ref images for this scene
        final refImgs = await _getRefImagesForScene(sceneNum - 1);
        
        ImageGenerationResponse response;
        
        if (refImgs.isNotEmpty) {
          _log('⏳ Scene $sceneNum: Uploading ${refImgs.length} ref images...');
          
          final workflowId = _googleImageApi!.getNewWorkflowId();
          final recipeInputs = <RecipeMediaInput>[];
          
          for (int idx = 0; idx < refImgs.length; idx++) {
            final b64 = refImgs[idx];
            
            // Check cache first
            if (_uploadedRefImageCache.containsKey(b64)) {
              recipeInputs.add(_uploadedRefImageCache[b64]!);
              _log('  ♻️ Reusing cached ref image ${idx + 1}');
              continue;
            }
            
            try {
              final uploaded = await _googleImageApi!.uploadImageWithCaption(
                base64Image: b64,
                workflowId: workflowId,
                mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
              );
              
              final input = RecipeMediaInput(
                caption: uploaded.caption,
                mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                mediaGenerationId: uploaded.mediaGenerationId,
              );
              
              _uploadedRefImageCache[b64] = input;
              recipeInputs.add(input);
              _log('  📤 Uploaded ref image ${idx + 1}/${refImgs.length}');
            } catch (e) {
              _log('  ⚠️ Failed to upload ref image ${idx + 1}: $e');
            }
          }
          
          if (recipeInputs.isEmpty) {
            _log('⏳ Scene $sceneNum: Generating (no refs available)...');
            response = await _retryApiCall(() => _googleImageApi!.generateImage(
              prompt: prompt,
              aspectRatio: aspectRatio,
              imageModel: apiModelId,
            ));
          } else {
            _log('⏳ Scene $sceneNum: Generating with ${recipeInputs.length} refs...');
            response = await _retryApiCall(() => _googleImageApi!.runImageRecipe(
              userInstruction: prompt,
              recipeMediaInputs: recipeInputs,
              workflowId: workflowId,
              aspectRatio: aspectRatio,
              imageModel: apiModelId,
            ));
          }
        } else {
          _log('⏳ Scene $sceneNum: Generating via API...');
          response = await _retryApiCall(() => _googleImageApi!.generateImage(
            prompt: prompt,
            aspectRatio: aspectRatio,
            imageModel: apiModelId,
          ));
        }
        
        if (response.imagePanels.isEmpty || response.imagePanels.first.generatedImages.isEmpty) {
          throw 'No images returned from API';
        }
        
        final base64Image = response.imagePanels.first.generatedImages.first.encodedImage;
        await _saveCdpImage(base64Image, sceneNum);
        _log('✅ Scene $sceneNum regenerated via API!');
      } catch (e) {
        _log('❌ Regen Error (API): $e');
      }
    } else {
      // === CDP METHOD (non-API models) ===
      if (_cdpHubs.isEmpty) {
        _log('⚠️ No browsers connected');
        return;
      }
      
      final hub = _cdpHubs.values.first;
      
      try {
        await hub.focusChrome();
        await hub.checkLaunchModal();
        
        // Determine model
        String modelIdJs = 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE';
        if (_selectedImageModel != null && _selectedImageModel!.url.isNotEmpty) {
          modelIdJs = 'window.geminiHub.models.${_selectedImageModel!.url}';
        }
        
        // Get ref images
        final refImgs = await _getRefImagesForScene(sceneNum - 1);
        
        // Spawn
        final spawnResult = await hub.spawnImage(
          prompt,
          aspectRatio: _aspectRatio,
          refImages: refImgs.isNotEmpty ? refImgs : null,
          model: modelIdJs,
        );
        
        if (spawnResult == null) throw 'Spawn failed';
        
        String? threadId;
        if (spawnResult is Map && spawnResult.containsKey('id')) {
          threadId = spawnResult['id']?.toString();
        } else if (spawnResult is String && spawnResult.isNotEmpty) {
          threadId = spawnResult;
        }
        
        if (threadId == null) throw 'Invalid thread ID';
        
        _log('✓ Spawned Scene $sceneNum (Regen)');
        
        // Poll
        final startTime = DateTime.now();
        while (DateTime.now().difference(startTime).inSeconds < 180) {
          final res = await hub.getThread(threadId);
          if (res is Map) {
            if (res['status'] == 'COMPLETED' && res['result'] != null) {
              await _saveCdpImage(res['result'], sceneNum);
              _log('✅ Scene $sceneNum regenerated!');
              return;
            } else if (res['status'] == 'FAILED') {
              throw 'Generation status FAILED';
            }
          }
          await Future.delayed(const Duration(milliseconds: 1000));
        }
        throw 'Timeout waiting for image';
      } catch (e) {
        _log('❌ Regen Error (CDP): $e');
      }
    }
  }

  /// Helper to retry API calls on quota exhaustion (429)
  Future<T> _retryApiCall<T>(Future<T> Function() call) async {
    int attempts = 0;
    const maxRetries = 10;
    
    while (true) {
      try {
        return await call();
      } catch (e) {
        attempts++;
        final errStr = e.toString();
        // Check for 429 or Resource Exhausted
        bool isQuotaError = errStr.contains('429') || 
                            errStr.contains('RESOURCE_EXHAUSTED') || 
                            errStr.contains('Resource has been exhausted');
        
        bool isServiceError = errStr.contains('503') || errStr.contains('Service Unavailable');
                            
        if ((isQuotaError || isServiceError) && attempts <= maxRetries) {
           _log('⏳ API Quota/Service Error ($attempts/$maxRetries). Waiting 20s...');
           await Future.delayed(const Duration(seconds: 20));
           continue;
        }
        rethrow;
      }
    }
  }

  /// API-based scene generation for Flow models (Imagen 3.5, GemPix)
  Future<void> _startApiSceneGeneration({List<Map<String, dynamic>>? retryQueue}) async {
    _log('🚀 _startApiSceneGeneration called. RetryQueue: ${retryQueue?.length ?? "null"}');
    setState(() => _cdpRunning = true);
    _log('=' * 50);
    _log('🚀 Starting API Image Generation (Flow models)...');
    
    final fromIdx = (int.tryParse(_fromRangeController.text) ?? 1) - 1;
    final toIdx = int.tryParse(_toRangeController.text) ?? _scenes.length;
    final batchSize = int.tryParse(_batchSizeController.text) ?? 2;
    
    final apiModelId = _selectedImageModel?.apiModelId ?? 'IMAGEN_3_5';
    final modelName = _selectedImageModel?.name ?? 'Flow Image';
    _log('🎨 Using API model: $modelName ($apiModelId)');
    
    // Initialize Google Image API if needed
    _googleImageApi ??= GoogleImageApiService();
    
    // Try to load stored credentials first
    if (!_googleImageApi!.isSessionValid) {
      _log('🔑 Checking stored credentials...');
      final loaded = await _googleImageApi!.loadCredentials();
      
      if (loaded && _googleImageApi!.isSessionValid) {
        final expiry = _googleImageApi!.sessionExpiry;
        final remaining = expiry!.difference(DateTime.now());
        _log('✅ Using stored credentials (${remaining.inHours}h ${remaining.inMinutes % 60}m remaining)');
      } else {
        // Need to extract fresh cookies from browser
        _log('🔑 Need fresh cookies from browser...');
        
        // Auto-connect to Chrome if not connected
        if (_cdpHubs.isEmpty) {
          _log('🌐 Auto-connecting to Chrome...');
          await _autoConnectBrowser();
          
          if (_cdpHubs.isEmpty) {
            _log('❌ Could not connect to Chrome. Please open Chrome with --remote-debugging-port=9222');
            setState(() => _cdpRunning = false);
            return;
          }
        }
        
        _log('🔑 Extracting cookies from labs.google/whisk...');
        final hub = _cdpHubs.values.first;
        final cookieString = await hub.getCookiesForDomain('https://labs.google/fx/tools/whisk/project');
        
        if (cookieString == null || cookieString.isEmpty) {
          _log('❌ Failed to extract cookies');
          setState(() => _cdpRunning = false);
          return;
        }
        
        try {
          final session = await _googleImageApi!.checkSession(cookieString);
          _log('✅ Authenticated (expires: ${session.timeRemainingFormatted})');
          _log('💾 Credentials saved for future use');
        } catch (e) {
          _log('❌ Auth failed: $e');
          setState(() => _cdpRunning = false);
          return;
        }
      }
    } else {
      final expiry = _googleImageApi!.sessionExpiry;
      final remaining = expiry!.difference(DateTime.now());
      _log('✅ Session still valid (${remaining.inHours}h ${remaining.inMinutes % 60}m remaining)');
    }
    
    // Build prompt queue with reference images
    final queue = retryQueue != null ? List<Map<String, dynamic>>.from(retryQueue) : <Map<String, dynamic>>[];
    
    if (retryQueue != null) {
       _log('🚀 Retrying ${queue.length} failed scenes...');
       // Clear failed queue AFTER copying to queue variable
       _failedQueue.clear(); 
    } else {
       // Normal generation - clear failed queue at start
       _failedQueue.clear();
    }
    
    if (retryQueue == null)
    for (int i = fromIdx; i < toIdx && i < _scenes.length; i++) {
      final scene = _scenes[i];
      final sceneNumRaw = scene['scene_number'];
      final sceneNum = sceneNumRaw is int ? sceneNumRaw : (int.tryParse(sceneNumRaw?.toString() ?? '') ?? (i + 1));
      final rawPrompt = scene['prompt']?.toString() ?? '';
      final prompt = _includeHistory ? _buildPromptWithHistory(i, rawPrompt) : rawPrompt;
      
      // Collect reference images from characters in this scene
      List<String> refImagesB64 = [];
      final charsInScene = scene['characters_in_scene'];
      List<String> charIds = [];
      if (charsInScene is List) {
        charIds = charsInScene.map((e) => e.toString().toLowerCase()).toList();
      }
      
      // Check characters that match scene or are mentioned in prompt
      for (final char in _characters) {
        final charIdLower = char.id.toLowerCase();
        bool shouldInclude = charIds.contains(charIdLower) || 
                            rawPrompt.toLowerCase().contains(charIdLower);
        
        if (shouldInclude && char.images.isNotEmpty) {
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
      
      // Collect reference images from entities in this scene
      final entitiesInScene = scene['entities_in_scene'];
      List<String> entityIds = [];
      if (entitiesInScene is List) {
        entityIds = entitiesInScene.map((e) => e.toString().toLowerCase()).toList();
      }
      
      // Check entities that match scene or are mentioned in prompt
      for (final entity in _entities) {
        final entityIdLower = entity.id.toLowerCase();
        bool shouldInclude = entityIds.contains(entityIdLower) || 
                            rawPrompt.toLowerCase().contains(entityIdLower);
        
        if (shouldInclude && entity.images.isNotEmpty) {
          for (final imgPath in entity.images) {
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
        'index': i,
        'ref_images': refImagesB64,
      });
    }
    
    _log('📋 Queued ${queue.length} prompts');
    
    // Count total reference images (characters + entities)
    int totalRefImages = 0;
    for (final item in queue) {
      if (item['ref_images'] != null) {
        totalRefImages += (item['ref_images'] as List<String>).length;
      }
    }
    if (totalRefImages > 0) {
      _log('🖼️ Found $totalRefImages total reference images (characters + entities)');
    }
    
    // Initialize stats
    setState(() {
      _statsTotal = queue.length;
      _statsCompleted = 0;
      _statsFailed = 0;
    });
    
    final aspectRatio = GoogleImageApiService.convertAspectRatio(_aspectRatio);
    int successful = 0;
    int failed = 0;
    
    // Pre-upload all unique reference images
    if (_cdpRunning) {
       final allRefImages = <String>{};
       for (final item in queue) {
         if (item['ref_images'] != null) {
           allRefImages.addAll(item['ref_images'] as List<String>);
         }
       }
       
       final pendingUploads = allRefImages.where((b64) => !_uploadedRefImageCache.containsKey(b64)).toList();
       
       if (pendingUploads.isNotEmpty) {
          _log('🔍 Found ${allRefImages.length} images (${pendingUploads.length} new). Pre-uploading in batches...');
          
          final uploadWorkflowId = _googleImageApi!.getNewWorkflowId();
          int upCount = 0;
          
          // Batch upload in parallel (chunks of 5)
          const chunkSize = 5;
          for (var i = 0; i < pendingUploads.length; i += chunkSize) {
             if (!_cdpRunning) break;
             final chunk = pendingUploads.skip(i).take(chunkSize).toList();
             
             _log('  📤 Batch uploading ${i+1}-${i+chunk.length} / ${pendingUploads.length}...');
             
             await Future.wait(chunk.map((b64) async {
                try {
                   final uploaded = await _googleImageApi!.uploadImageWithCaption(
                        base64Image: b64,
                        workflowId: uploadWorkflowId,
                        mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                   );
                   
                   _uploadedRefImageCache[b64] = RecipeMediaInput(
                        caption: uploaded.caption,
                        mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                        mediaGenerationId: uploaded.mediaGenerationId,
                   );
                   upCount++;
                } catch (e) {
                   _log('  ⚠️ Failed to upload image: $e');
                }
             }));
          }
           
          if (_cdpRunning) _log('✅ Pre-upload complete. Starting generation...');
       } else if (allRefImages.isNotEmpty) {
          _log('✅ All reference images already cached.');
       }
    }
    
    // Pre-upload style image if selected (MEDIA_CATEGORY_STYLE)
    if (_cdpRunning && _styleImagePath != null && _uploadedStyleInput == null) {
      _log('🎨 Pre-uploading style image...');
      
      try {
        final styleFile = File(_styleImagePath!);
        if (await styleFile.exists()) {
          final styleBytes = await styleFile.readAsBytes();
          final styleB64 = base64Encode(styleBytes);
          
          final styleWorkflowId = _googleImageApi!.getNewWorkflowId();
          final uploaded = await _googleImageApi!.uploadImageWithCaption(
            base64Image: styleB64,
            workflowId: styleWorkflowId,
            mediaCategory: 'MEDIA_CATEGORY_STYLE',
          );
          
          _uploadedStyleInput = RecipeMediaInput(
            caption: uploaded.caption,
            mediaCategory: 'MEDIA_CATEGORY_STYLE',
            mediaGenerationId: uploaded.mediaGenerationId,
          );
          
          _log('✅ Style image uploaded successfully');
        }
      } catch (e) {
        _log('⚠️ Failed to upload style image: $e');
      }
    }

    
    // Process in batches
    for (int i = 0; i < queue.length && _cdpRunning; i += batchSize) {
      final batch = queue.skip(i).take(batchSize).toList();
      _log('🔄 Processing batch ${(i ~/ batchSize) + 1}/${(queue.length / batchSize).ceil()}');
      
      // Generate batch in parallel
      final futures = batch.map((item) async {
        final sceneNum = item['scene_num'];
        final prompt = item['prompt'] as String;
        final refImages = item['ref_images'] as List<String>?;
        
        try {
          ImageGenerationResponse response;
          
          if (refImages != null && refImages.isNotEmpty) {
            _log('⏳ Scene $sceneNum: Uploading ${refImages.length} ref images...');
            
            // Get workflow ID for this batch
            final workflowId = _googleImageApi!.getNewWorkflowId();
            
            // Upload each reference image and collect media inputs
            final recipeInputs = <RecipeMediaInput>[];
            for (int idx = 0; idx < refImages.length; idx++) {
              final b64 = refImages[idx];
              
              // Check cache first
              if (_uploadedRefImageCache.containsKey(b64)) {
                recipeInputs.add(_uploadedRefImageCache[b64]!);
                _log('  ♻️ Reusing cached ref image ${idx + 1}');
                continue;
              }
              
              try {
                final uploaded = await _googleImageApi!.uploadImageWithCaption(
                  base64Image: b64,
                  workflowId: workflowId,
                  mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                );
                
                final input = RecipeMediaInput(
                  caption: uploaded.caption,
                  mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
                  mediaGenerationId: uploaded.mediaGenerationId,
                );
                
                _uploadedRefImageCache[b64] = input;
                recipeInputs.add(input);
                
                _log('  📤 Uploaded ref image ${idx + 1}/${refImages.length}');
              } catch (e) {
                _log('  ⚠️ Failed to upload ref image ${idx + 1}: $e');
              }
            }
            
            // Add style image to recipeInputs if available
            if (_uploadedStyleInput != null) {
              recipeInputs.add(_uploadedStyleInput!);
              _log('  🎨 Added style image to recipe');
            }
            
            if (recipeInputs.isEmpty) {
              // Fallback to simple generation if all uploads failed
              _log('⏳ Scene $sceneNum: Generating (no refs available)...');
              response = await _retryApiCall(() => _googleImageApi!.generateImage(
                prompt: prompt,
                aspectRatio: aspectRatio,
                imageModel: apiModelId,
              ));
            } else {
              final styleCount = recipeInputs.where((i) => i.mediaCategory == 'MEDIA_CATEGORY_STYLE').length;
              _log('⏳ Scene $sceneNum: Generating with ${recipeInputs.length} inputs ($styleCount style)...');
              response = await _retryApiCall(() => _googleImageApi!.runImageRecipe(
                userInstruction: prompt,
                recipeMediaInputs: recipeInputs,
                workflowId: workflowId,
                aspectRatio: aspectRatio,
                imageModel: apiModelId,
              ));
            }
          } else {
            // No ref images - check if we have style only
            if (_uploadedStyleInput != null) {
              final workflowId = _googleImageApi!.getNewWorkflowId();
              _log('⏳ Scene $sceneNum: Generating with style only...');
              response = await _retryApiCall(() => _googleImageApi!.runImageRecipe(
                userInstruction: prompt,
                recipeMediaInputs: [_uploadedStyleInput!],
                workflowId: workflowId,
                aspectRatio: aspectRatio,
                imageModel: apiModelId,
              ));
            } else {
              // No refs, no style - simple generation
              _log('⏳ Scene $sceneNum: Generating...');
              response = await _retryApiCall(() => _googleImageApi!.generateImage(
                prompt: prompt,
                aspectRatio: aspectRatio,
                imageModel: apiModelId,
              ));
            }
          }
          
          if (response.imagePanels.isEmpty || response.imagePanels.first.generatedImages.isEmpty) {
            throw 'No images returned';
          }
          
          final base64Image = response.imagePanels.first.generatedImages.first.encodedImage;
          await _saveCdpImage(base64Image, sceneNum);
          
          _log('✅ Scene $sceneNum completed');
          setState(() => _statsCompleted++);
          return true;
        } catch (e) {
          _log('❌ Scene $sceneNum failed: $e');
          setState(() => _statsFailed++);
          _failedQueue.add(item);
          _log('  📝 Added to retry queue (Total: ${_failedQueue.length})');
          return false;
        }
      });
      
      final results = await Future.wait(futures);
      successful += results.where((r) => r).length;
      failed += results.where((r) => !r).length;
      
      // Small delay between batches
      if (i + batchSize < queue.length && _cdpRunning) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    
    _log('=' * 50);
    _log('✨ Complete: $successful success, $failed failed');
    _log('📁 Images saved to: $_cdpOutputFolder');
    setState(() => _cdpRunning = false);
  }

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
    
    // Check if selected model is API type (Flow models)
    final isApiModel = _selectedImageModel?.modelType == 'api';
    
    if (isApiModel) {
      // Use API-based generation for Flow models
      await _startApiSceneGeneration();
      return;
    }
    
    // CDP models require browser connection
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
      modelIdJs = 'window.geminiHub.models.GEMINI_2_FLASH_IMAGE';
      modelName = 'Gemini 2 Flash Image';
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
      
      // Find entity references
      final entitiesInScene = scene['entities_in_scene'];
      List<String> entityIds = [];
      if (entitiesInScene is List) {
        entityIds = entitiesInScene.map((e) => e.toString().toLowerCase()).toList();
      }
      
      for (final entity in _entities) {
        final entityIdLower = entity.id.toLowerCase();
        bool shouldInclude = entityIds.contains(entityIdLower) || 
                            rawPrompt.toLowerCase().contains(entityIdLower);
        
        if (shouldInclude && entity.images.isNotEmpty) {
          _log('    🏗️ Found entity: ${entity.id} (${entity.images.length} images)');
          for (final imgPath in entity.images) {
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
      
      // Brief wait for API
      await Future.delayed(const Duration(milliseconds: 1000));
      
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
      // Use project-specific output folder
      final outputFolder = _getProjectOutputFolder();
      await Directory(outputFolder).create(recursive: true);
      
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '').replaceAll('-', '').substring(0, 15);
      final filename = 'scene_${sceneNum}_$timestamp.png';
      final filepath = path.join(outputFolder, filename);
      
      // Extract base64
      String b64Part = base64Data;
      if (base64Data.contains(',')) {
        b64Part = base64Data.split(',').last;
      }
      
      final bytes = base64Decode(b64Part);
      await File(filepath).writeAsBytes(bytes);

      // Note: Removed auto-download to root Downloads folder
      // Images are now only saved in project-specific folder
      
      
      // Add to generated images for display
      setState(() {
        _generatedImagePaths.add(filepath);
      });
      
      // Auto-save project
      await _autoSaveProject();
      
      _log('  💾 Saved: $filename');
    } catch (e) {
      _log('  ❌ Save error: $e');
    }
  }
  
  void _openOutputFolder() {
    if (Platform.isWindows) {
      final outputFolder = _getProjectOutputFolder();
      Process.run('explorer', [outputFolder]);
    }
  }
  
  Future<void> _deleteAllGeneratedFiles() async {
    if (_generatedImagePaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No files to delete')),
      );
      return;
    }
    
    // Show confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 12),
            Text('Delete All Images?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will permanently delete ${_generatedImagePaths.length} image(s) from disk and clear them from the project.'),
            const SizedBox(height: 12),
            const Text(
              'Note: Associated videos will NOT be deleted.',
              style: TextStyle(fontWeight: FontWeight.w500, color: Colors.blue),
            ),
            const SizedBox(height: 8),
            const Text(
              'This action cannot be undone!',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete Images'),
          ),
        ],
      ),
    );
    
    if (confirm != true) return;
    
    int deletedCount = 0;
    int errorCount = 0;
    
    try {
      // Delete only image files (keep videos)
      for (final imagePath in _generatedImagePaths) {
        try {
          final imageFile = File(imagePath);
          if (await imageFile.exists()) {
            await imageFile.delete();
            deletedCount++;
            _log('🗑️ Deleted image: ${path.basename(imagePath)}');
          }
        } catch (e) {
          errorCount++;
          _log('❌ Failed to delete ${path.basename(imagePath)}: $e');
        }
      }
      
      // Clear from project (but keep video states for manual deletion later)
      setState(() {
        _generatedImagePaths.clear();
      });
      
      // Auto-save project
      await _autoSaveProject();
      
      // Show result
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              errorCount > 0
                  ? '🗑️ Deleted $deletedCount images ($errorCount errors)'
                  : '🗑️ Successfully deleted $deletedCount images',
            ),
            backgroundColor: errorCount > 0 ? Colors.orange : Colors.green,
          ),
        );
      }
      
      _log('✅ Delete all images complete: $deletedCount deleted, $errorCount errors');
    } catch (e) {
      _log('❌ Delete all failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete files: $e')),
        );
      }
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
    final result = {
      'action': 'add_to_video_gen',
      'sceneId': sceneNum,
      'imagePath': imagePath,
      'prompt': videoPrompt,
      'imageFileName': path.basename(imagePath),
    };
    
    if (widget.embedded && widget.onAddToVideoGen != null) {
      widget.onAddToVideoGen!(result);
    } else {
      Navigator.pop(context, result);
    }
  }

  
  // ====================== BUILD UI ======================
  
  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    
    // Handle case where tab controller isn't initialized yet (hot reload)
    if (_tabController == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    
    final isDesktop = MediaQuery.of(context).size.width > 700;
    
    return Scaffold(
      body: Column(
        children: [
          // Premium Header - matching reference design exactly
          _buildPremiumHeader(isDesktop),
          // Body content with left sidebar
          Expanded(
            child: Row(
              children: [
                // Left Sidebar - Main Section Icons
                _buildMainSidebar(),
                // Main Content Area
                Expanded(
                  child: _buildMainContent(isDesktop),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Left Sidebar with 3 main section icons
  Widget _buildMainSidebar() {
    return Container(
      width: 72,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border(right: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // Image to Video
          _buildSidebarButton(
            index: 0,
            icon: Icons.video_library,
            label: 'Image to\nVideo',
            gradient: const [Color(0xFF6366F1), Color(0xFF818CF8)], // Indigo 500/400
          ),
          const SizedBox(height: 12),
          // Text to Video
          _buildSidebarButton(
            index: 1,
            icon: Icons.text_fields,
            label: 'Text to\nVideo',
            gradient: const [Color(0xFF6366F1), Color(0xFF818CF8)], // Same theme
          ),

          const Spacer(),
        ],
      ),
    );
  }

  /// Sidebar button widget
  Widget _buildSidebarButton({
    required int index,
    required IconData icon,
    required String label,
    required List<Color> gradient,
  }) {
    final isSelected = _mainSectionIndex == index;
    final primaryColor = gradient[0];
    
    return GestureDetector(
      onTap: () => setState(() => _mainSectionIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor.withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: isSelected ? Border.all(color: primaryColor.withOpacity(0.2), width: 1) : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected)
              ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: gradient,
                ).createShader(bounds),
                child: Icon(
                  icon,
                  size: 24,
                  color: Colors.white,
                ),
              )
            else
              Icon(
                icon,
                size: 24,
                color: const Color(0xFF94A3B8), // Slate 400
              ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? primaryColor : const Color(0xFF64748B), // Slate 500
                height: 1.2,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Main content area based on selected section
  Widget _buildMainContent(bool isDesktop) {
    switch (_mainSectionIndex) {
      case 0:
        // Image to Video - Current Content (Prompts, Images, Video tabs)
        return TabBarView(
          controller: _tabController!,
          children: [
            isDesktop ? _buildStoryPromptTab() : _buildMobileStoryPromptTab(),
            isDesktop ? _buildDesktopImageGenTab() : _buildMobileImageGenTab(),
            isDesktop ? _buildVideoTab() : _buildMobileVideoTab(),
          ],
        );
      case 1:
        // Text to Video - Two tabs: Prompts and Video
        return _buildTextToVideoSection(isDesktop);

      default:
        return const SizedBox.shrink();
    }
  }



  /// Text to Video Section - Two tabs: Prompts and Video
  Widget _buildTextToVideoSection(bool isDesktop) {
    return Column(
      children: [
        // Tab Bar Header
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 16),
              // Tab: Prompts
              _buildT2VTabButton(
                label: 'Prompts',
                icon: Icons.edit_note,
                tabIndex: 0,
              ),
              const SizedBox(width: 8),
              // Tab: Video
              _buildT2VTabButton(
                label: 'Video',
                icon: Icons.videocam,
                tabIndex: 1,
              ),
              const Spacer(),
            ],
          ),
        ),
        // Tab Content
        Expanded(
          child: _t2vTabIndex == 0
              ? _buildT2VPromptsTab(isDesktop)
              : _buildT2VVideoTab(isDesktop),
        ),
      ],
    );
  }

  /// Tab button for Text to Video section
  Widget _buildT2VTabButton({
    required String label,
    required IconData icon,
    required int tabIndex,
  }) {
    final isSelected = _t2vTabIndex == tabIndex;
    return GestureDetector(
      onTap: () => setState(() => _t2vTabIndex = tabIndex),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEEF2FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected 
              ? Border.all(color: const Color(0xFF6366F1).withOpacity(0.3))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? const Color(0xFF6366F1) : Colors.grey.shade500,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? const Color(0xFF6366F1) : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Text to Video - Prompts Tab (similar to Story Prompt Tab)
  Widget _buildT2VPromptsTab(bool isDesktop) {
    return Container(
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left Panel - Story Input
          Expanded(
            flex: 2,
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                      border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.description, size: 18, color: Color(0xFF6366F1)),
                        const SizedBox(width: 8),
                        const Text('Story Input', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6366F1).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.smart_toy, size: 12, color: Color(0xFF6366F1)),
                              SizedBox(width: 4),
                              Text('Gemini API', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF6366F1))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Scrollable Content - entire panel scrolls together
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Use Template Checkbox
                          Row(
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: Checkbox(
                                  value: _t2vUseTemplate,
                                  onChanged: (v) => setState(() => _t2vUseTemplate = v ?? true),
                                  activeColor: const Color(0xFF6366F1),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text('Use Template', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Template Dropdown
                          if (_t2vUseTemplate) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: DropdownButton<String>(
                                value: _selectedTemplate,
                                isExpanded: true,
                                underline: const SizedBox(),
                                isDense: true,
                                items: _promptTemplates.keys.map((k) => DropdownMenuItem(
                                  value: k,
                                  child: Text(k.toUpperCase().replaceAll('_', ' '), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                                )).toList(),
                                onChanged: (v) => setState(() => _selectedTemplate = v ?? 'char_consistent'),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                          // Model Dropdown
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: DropdownButton<String>(
                                    value: _storyModels.any((m) => m['id'] == _t2vSelectedModel) 
                                        ? _t2vSelectedModel 
                                        : (_storyModels.isNotEmpty ? _storyModels[0]['id'] : null),
                                    isExpanded: true,
                                    underline: const SizedBox(),
                                    isDense: true,
                                    items: _storyModels.map((m) => DropdownMenuItem(
                                      value: m['id'], 
                                      child: Text(m['name']!, style: const TextStyle(fontSize: 11)),
                                    )).toList(),
                                    onChanged: (v) => setState(() => _t2vSelectedModel = v ?? 'gemini-3-flash-preview'),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF6366F1).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.key, size: 10, color: Color(0xFF6366F1)),
                                      const SizedBox(width: 3),
                                      Text('${_geminiApi?.keyCount ?? 0}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF6366F1))),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Prompts Count
                          Row(
                            children: [
                              const Text('Prompts:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 55,
                                child: TextField(
                                  controller: _t2vPromptsCountController,
                                  textAlign: TextAlign.center,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                  ),
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // JSON Output Checkbox
                          Row(
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: Checkbox(
                                  value: _t2vJsonOutput,
                                  onChanged: (v) => setState(() => _t2vJsonOutput = v ?? true),
                                  activeColor: const Color(0xFF6366F1),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text('JSON Output', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 16),
                          
                          // Story Input Tabs
                          Row(
                            children: [
                              // Story Concept Tab
                              GestureDetector(
                                onTap: () => setState(() => _t2vStoryInputTab = 0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: _t2vStoryInputTab == 0 ? const Color(0xFF6366F1) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: _t2vStoryInputTab == 0 ? const Color(0xFF6366F1) : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Text(
                                    'RAW STORY',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: _t2vStoryInputTab == 0 ? Colors.white : const Color(0xFF64748B),
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Raw Story Prompt Tab
                              GestureDetector(
                                onTap: () => setState(() => _t2vStoryInputTab = 1),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: _t2vStoryInputTab == 1 ? const Color(0xFF10B981) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: _t2vStoryInputTab == 1 ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Text(
                                    'RAW PROMPT',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: _t2vStoryInputTab == 1 ? Colors.white : const Color(0xFF64748B),
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          
                          // Story Input Field (switches based on tab)
                          SizedBox(
                            height: 140,
                            child: _t2vStoryInputTab == 0
                                ? TextField(
                                    controller: _t2vStoryController,
                                    maxLines: null,
                                    expands: true,
                                    decoration: InputDecoration(
                                      hintText: 'Describe your video story concept...\n\nExample: A peaceful sunrise over mountains, transitioning to a bustling city morning...',
                                      hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Colors.grey.shade300),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(color: Color(0xFF6366F1)),
                                      ),
                                    ),
                                  )
                                : TextField(
                                    key: const ValueKey('t2v_raw_prompt_field'),
                                    controller: _t2vRawPromptController,
                                    maxLines: null,
                                    expands: true,
                                    enableInteractiveSelection: true,
                                    autocorrect: false,
                                    decoration: InputDecoration(
                                      hintText: 'Paste your raw story prompts here...\n\nSupported formats:\n- JSON array of scenes\n- Plain text (one scene per line)\n- Full story text',
                                      hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Colors.grey.shade300),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(color: Color(0xFF10B981)),
                                      ),
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 12),
                          // Generate Button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _t2vGenerating ? null : _generateT2VScenes,
                              icon: _t2vGenerating 
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.auto_awesome, size: 16),
                              label: Text(_t2vGenerating ? 'Generating...' : 'Generate Video Scenes', style: const TextStyle(fontSize: 12)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6366F1),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Right Panel - AI Response / Generated Scenes
          Expanded(
            flex: 3,
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header with Tab Switcher
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                      border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.movie_creation, size: 20, color: Color(0xFF6366F1)),
                        const SizedBox(width: 8),
                        const Text('Generated Video Scenes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        // Tab Switcher (Scenes vs Raw Response)
                        _buildT2VResponseTabSwitcher(),
                      ],
                    ),
                  ),
                  // Content
                  Expanded(
                    child: _t2vGenerating 
                        ? _buildFunnyLoadingAnimation()
                        : _t2vResponseViewTab == 1
                            ? _buildT2VRawResponseView()
                            : _buildT2VScenesListView(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// T2V Right Panel Tab Switcher
  Widget _buildT2VResponseTabSwitcher() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildT2VViewTabButton('Scenes', 0),
          _buildT2VViewTabButton('Raw API', 1),
        ],
      ),
    );
  }

  Widget _buildT2VViewTabButton(String label, int index) {
    final isSelected = _t2vResponseViewTab == index;
    return GestureDetector(
      onTap: () => setState(() => _t2vResponseViewTab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(0, 1))] : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            color: isSelected ? const Color(0xFF6366F1) : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  /// T2V Scenes List View
  Widget _buildT2VScenesListView() {
    if (_t2vScenes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.movie_filter, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('Video scenes will appear here', style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _t2vScenes.length,
      itemBuilder: (context, index) {
        final scene = _t2vScenes[index];
        return Card(
          elevation: 0,
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: Colors.grey.shade100),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold),
                ),
              ),
            ),
            title: Text(
              scene['title'] ?? 'Scene ${index + 1}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              scene['description'] ?? '',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.4),
            ),
          ),
        );
      },
    );
  }

  /// T2V Raw Response View (Live Streaming)
  Widget _buildT2VRawResponseView() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF0F172A), // Modern dark slate
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.code, size: 14, color: Colors.cyanAccent),
              const SizedBox(width: 8),
              const Text('LIVE API STREAM', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
              const Spacer(),
              if (_t2vGenerating)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              controller: _responseScrollController,
              child: TextField(
                controller: _t2vResponseController,
                maxLines: null,
                readOnly: true,
                style: const TextStyle(
                  color: Color(0xFFE2E8F0),
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Waiting for AI response...',
                  hintStyle: TextStyle(color: Color(0xFF475569)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Text to Video - Video Tab (video generation panel with scenes list)
  Widget _buildT2VVideoTab(bool isDesktop) {
    // If no scenes parsed yet, show placeholder
    if (_t2vScenes.isEmpty) {
      return Container(
        color: const Color(0xFFF8FAFC),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.videocam, size: 48, color: Color(0xFF6366F1)),
              ),
              const SizedBox(height: 16),
              const Text(
                'Video Generation',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
              ),
              const SizedBox(height: 8),
              Text(
                'Generate scenes first in the Prompts tab,\nthen come here to create your video.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    // Show scenes list with video generation controls
    return Container(
      color: const Color(0xFFF8FAFC),
      child: Column(
        children: [
          // Header with Generate All button
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: [
                Text(
                  '${_t2vScenes.length} Scenes Ready',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                ),
                const Spacer(),
                // Model selector
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: DropdownButton<String>(
                    value: _videoSelectedModel,
                    items: _videoModelOptions.map((m) => DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 12)))).toList(),
                    onChanged: (v) => setState(() => _videoSelectedModel = v!),
                    underline: const SizedBox(),
                    isDense: true,
                  ),
                ),
                const SizedBox(width: 12),
                // Generate All button
                ElevatedButton.icon(
                  onPressed: _videoGenerationRunning ? null : _startT2VVideoGeneration,
                  icon: _videoGenerationRunning 
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow, size: 18),
                  label: Text(_videoGenerationRunning ? 'Generating...' : 'Generate All'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
                const SizedBox(width: 12),
                // Add to Mastering button
                ElevatedButton.icon(
                  onPressed: _t2vScenes.any((s) => s['status'] == 'completed') ? _addT2VToMastering : null,
                  icon: const Icon(Icons.movie_creation, size: 18),
                  label: const Text('Add to Mastering'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
          
          // Scenes list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _t2vScenes.length,
              itemBuilder: (context, index) {
                final scene = _t2vScenes[index];
                final sceneNum = scene['scene_number'] ?? (index + 1);
                final prompt = scene['prompt']?.toString() ?? '';
                final status = scene['status']?.toString() ?? 'queued';
                final videoPath = scene['videoPath']?.toString();
                
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: status == 'completed' ? Colors.green.shade300 : Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6366F1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('Scene $sceneNum', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          // Status indicator
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: status == 'completed' ? Colors.green.shade100 : 
                                     status == 'generating' ? Colors.orange.shade100 : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              status.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10, 
                                fontWeight: FontWeight.w600,
                                color: status == 'completed' ? Colors.green.shade700 : 
                                       status == 'generating' ? Colors.orange.shade700 : Colors.grey.shade600,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // Generate single scene button
                          if (status != 'completed' && status != 'generating')
                            IconButton(
                              onPressed: () => _generateSingleT2VScene(index),
                              icon: const Icon(Icons.play_circle_outline, color: Color(0xFF6366F1)),
                              tooltip: 'Generate this scene',
                            ),
                          // Open video button
                          if (videoPath != null && File(videoPath).existsSync())
                            IconButton(
                              onPressed: () => Process.run('explorer', [videoPath]),
                              icon: const Icon(Icons.folder_open, color: Colors.blue),
                              tooltip: 'Open video',
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        prompt.length > 200 ? '${prompt.substring(0, 200)}...' : prompt,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
  
  /// Start video generation for all T2V scenes
  Future<void> _startT2VVideoGeneration() async {
    if (_t2vScenes.isEmpty) {
      _log('⚠️ No scenes to generate');
      return;
    }
    
    setState(() => _videoGenerationRunning = true);
    _log('🎬 Starting T2V video generation for ${_t2vScenes.length} scenes...');
    
    for (int i = 0; i < _t2vScenes.length; i++) {
      if (!mounted || !_videoGenerationRunning) break;
      await _generateSingleT2VScene(i);
    }
    
    if (mounted) {
      setState(() => _videoGenerationRunning = false);
      _log('✅ T2V video generation complete!');
    }
  }
  
  /// Generate video for a single T2V scene
  Future<void> _generateSingleT2VScene(int index) async {
    if (index < 0 || index >= _t2vScenes.length) return;
    
    final scene = _t2vScenes[index];
    final prompt = scene['prompt']?.toString() ?? '';
    
    if (prompt.isEmpty) {
      _log('⚠️ Scene ${index + 1} has no prompt');
      return;
    }
    
    setState(() {
      _t2vScenes[index]['status'] = 'generating';
    });
    
    _log('🎥 Generating video for Scene ${index + 1}...');
    
    try {
      // Connect to browsers if not connected
      final connectedCount = widget.profileManager?.countConnectedProfiles() ?? 0;
      if (connectedCount == 0) {
        _log('📡 No browsers connected, attempting to connect...');
        final connected = await _connectAllBrowsers();
        if (connected == 0) {
          _log('❌ No browsers found. Please open Chrome with remote debugging.');
          setState(() => _t2vScenes[index]['status'] = 'failed');
          return;
        }
      }
      
      // Get first available profile
      final profile = widget.profileManager?.getNextAvailableProfile();
      if (profile == null) {
        _log('❌ No available browser profiles');
        setState(() => _t2vScenes[index]['status'] = 'failed');
        return;
      }
      
      // Get access token
      final accessToken = await profile.generator?.getAccessToken();
      if (accessToken == null) {
        _log('❌ Failed to get access token');
        setState(() => _t2vScenes[index]['status'] = 'failed');
        return;
      }
      
      // Map video model name to API model key (inline logic)
      String modelKey = 'veo_3_1_t2v_fast_ultra_relaxed';
      final isVeo2 = _videoSelectedModel.contains('Veo 2');
      final isQuality = _videoSelectedModel.contains('Quality');
      final isRelaxed = _videoSelectedModel.contains('Lower Priority');
      
      if (isVeo2) {
        modelKey = isQuality 
          ? (isRelaxed ? 'veo_2_t2v_quality_relaxed' : 'veo_2_t2v_quality')
          : (isRelaxed ? 'veo_2_t2v_fast_relaxed' : 'veo_2_t2v_fast');
      } else {
        modelKey = isQuality 
          ? (isRelaxed ? 'veo_3_1_t2v_quality_ultra_relaxed' : 'veo_3_1_t2v_quality_ultra')
          : (isRelaxed ? 'veo_3_1_t2v_fast_ultra_relaxed' : 'veo_3_1_t2v_fast_ultra');
      }
      
      // Generate video via API
      final result = await profile.generator?.generateVideo(
        prompt: prompt,
        accessToken: accessToken,
        model: modelKey,
        aspectRatio: _videoSelectedAspectRatio,
      );
      
      if (result != null && result['success'] == true) {
        // Handle successful generation - poll for result
        final data = result['data'];
        if (data is Map && data['responses'] is List && (data['responses'] as List).isNotEmpty) {
          final response = (data['responses'] as List)[0];
          final operation = response['operation'];
          final opName = operation?['name']?.toString();
          final sceneId = result['sceneId']?.toString() ?? '';
          
          if (opName != null) {
            _log('  [Scene ${index + 1}] Video generation started, polling...');
            
            // Poll for completion
            final videoPath = await _pollT2VVideoCompletion(profile, opName, sceneId, accessToken, index);
            
            if (videoPath != null && mounted) {
              setState(() {
                _t2vScenes[index]['status'] = 'completed';
                _t2vScenes[index]['videoPath'] = videoPath;
              });
              _log('✅ Scene ${index + 1} video saved: ${path.basename(videoPath)}');
              return;
            }
          }
        }
      }
      
      // If we get here, generation failed
      if (mounted) {
        setState(() => _t2vScenes[index]['status'] = 'failed');
        _log('❌ Scene ${index + 1} video generation failed');
      }
    } catch (e) {
      _log('❌ Scene ${index + 1} error: $e');
      if (mounted) {
        setState(() => _t2vScenes[index]['status'] = 'failed');
      }
    }
  }
  
  /// Poll for T2V video completion
  Future<String?> _pollT2VVideoCompletion(dynamic profile, String opName, String sceneId, String accessToken, int sceneIndex) async {
    for (int i = 0; i < 60; i++) { // Max 5 minutes
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted) return null;
      
      try {
        final pollResult = await profile.generator?.pollVideoStatus(opName, sceneId, accessToken);
        
        if (pollResult != null && pollResult['success'] == true) {
          final data = pollResult['data'];
          if (data is Map && data['responses'] is List) {
            final statuses = data['responses'] as List;
            if (statuses.isNotEmpty) {
              final status = statuses[0]['status']?.toString() ?? '';
              
              if (status == 'MEDIA_GENERATION_STATUS_COMPLETE') {
                // Extract video URL and download
                final media = statuses[0]['generatedVideo']?['videoMedia'];
                final videoUrl = media?['uri']?.toString() ?? media?['url']?.toString();
                
                if (videoUrl != null) {
                  // Download video
                  final videoPath = await _downloadT2VVideo(videoUrl, sceneIndex);
                  return videoPath;
                }
              } else if (status.contains('FAILED') || status.contains('ERROR')) {
                _log('  [Scene ${sceneIndex + 1}] Generation failed: $status');
                return null;
              }
            }
          }
        }
      } catch (e) {
        _log('  [Scene ${sceneIndex + 1}] Poll error: $e');
      }
    }
    return null;
  }
  
  /// Download T2V video
  Future<String?> _downloadT2VVideo(String url, int sceneIndex) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final outputDir = path.join(Platform.environment['USERPROFILE'] ?? '', 'Downloads', 'T2V_Videos');
        await Directory(outputDir).create(recursive: true);
        
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final outputPath = path.join(outputDir, 'scene_${sceneIndex + 1}_$timestamp.mp4');
        
        await File(outputPath).writeAsBytes(response.bodyBytes);
        return outputPath;
      }
    } catch (e) {
      _log('  Download error: $e');
    }
    return null;
  }
  
  /// Add completed T2V videos to the Mastering screen (launches as separate process)
  Future<void> _addT2VToMastering() async {
    // Collect completed video paths
    final completedVideos = _t2vScenes
        .where((s) => s['status'] == 'completed' && s['videoPath'] != null)
        .map((s) => s['videoPath'] as String)
        .where((p) => File(p).existsSync())
        .toList();
    
    if (completedVideos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No completed videos to add'), backgroundColor: Colors.orange),
      );
      return;
    }
    
    _log('🎬 Launching Mastering as separate process...');
    _log('📁 ${completedVideos.length} videos');
    _log('🎵 ${_t2vBgMusic.length} background music prompts');
    
    try {
      // Write data to temp file
      final tempDir = await Directory.systemTemp.createTemp('veo3_mastering_');
      final dataFile = File(path.join(tempDir.path, 'mastering_data.json'));
      
      final masteringData = {
        'projectName': _t2vStoryTitle.isNotEmpty ? _t2vStoryTitle : 'T2V Project',
        'videoPaths': completedVideos,
        'bgMusicPrompts': _t2vBgMusic,
      };
      
      await dataFile.writeAsString(jsonEncode(masteringData));
      
      // Write a flag file that the new process will detect (with data file path)
      final masteringFlagFile = File(path.join(Directory.systemTemp.path, 'veo3_mastering_mode.flag'));
      await masteringFlagFile.writeAsString(dataFile.path);
      
      final exePath = Platform.resolvedExecutable;
      _log('📂 Exe path: $exePath');
      _log('📄 Data file: ${dataFile.path}');
      _log('🚩 Flag file: ${masteringFlagFile.path}');
      
      // Launch the app (it will detect the flag file and open in mastering mode)
      if (Platform.isWindows) {
        final result = await Process.run(
          'cmd',
          ['/c', 'start', '""', exePath],
          runInShell: false,
        );
        _log('✅ Mastering launched via cmd start (exit: ${result.exitCode})');
      } else {
        final process = await Process.start(
          exePath,
          [],
          mode: ProcessStartMode.detached,
        );
        _log('✅ Mastering launched as separate process (PID: ${process.pid})');
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Mastering opened in new window (${completedVideos.length} videos)'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      _log('❌ Failed to launch mastering: $e');
      
      // Fallback to in-app navigation if process launch fails
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not launch separate window: $e'), backgroundColor: Colors.orange),
        );
        
        // Fallback: open in-app
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => VideoMasteringScreen(
              projectService: widget.projectService,
              initialVideoPaths: completedVideos,
              initialProjectName: _t2vStoryTitle.isNotEmpty ? _t2vStoryTitle : 'T2V Project',
              bgMusicPrompts: _t2vBgMusic,
            ),
          ),
        );
      }
    }
  }

  /// Generate video scenes from story using Gemini API
  Future<void> _generateT2VScenes() async {
    // Check which input mode is active and validate
    final inputText = _t2vStoryInputTab == 0 
        ? _t2vStoryController.text 
        : _t2vRawPromptController.text;
    
    if (inputText.isEmpty) {
      final message = _t2vStoryInputTab == 0 
          ? 'Please enter a story concept first'
          : 'Please paste your raw story prompts first';
      _log('⚠️ $message');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.orange),
      );
      return;
    }

    // Check for API keys
    if (_geminiApi == null || _geminiApi!.keyCount == 0) {
      _log('⚠️ No Gemini API keys configured');
      _showApiKeyDialog();
      return;
    }

    setState(() {
      _t2vGenerating = true;
      _t2vScenes.clear();
      _t2vResponseController.clear();
      _t2vResponseViewTab = 1; // Show raw response during generation
    });

    final promptCount = int.tryParse(_t2vPromptsCountController.text) ?? 10;

    String systemPrompt;

    // MODE 1: RAW STORY PROMPT - Analyze existing prompts
    if (_t2vStoryInputTab == 1) {
      _log('🔍 [RAW MODE] Analyzing raw prompts...');
      systemPrompt = '''Analyze these raw story prompts and extract characters:

$inputText

Extract all characters, create character IDs (name_outfit_001 format), generate descriptions, and structure as $promptCount enhanced scenes with character_reference array.''';
    }
    // MODE 0: STORY CONCEPT - Generate from concept
    else if (_t2vUseTemplate) {
      final template = _promptTemplates[_selectedTemplate]!;
      _log('🎬 [CONCEPT MODE] Generating $promptCount scenes using "${template['name']}"...');
      systemPrompt = (template['prompt'] as String)
          .replaceAll('[STORY_TEXT]', inputText)
          .replaceAll('[SCENE_COUNT]', promptCount.toString());
    } else {
      _log('🎬 [CONCEPT MODE] Raw instruction...');
      systemPrompt = inputText;
    }

    // Get schema if applies
    Map<String, dynamic>? schema;
    if (_t2vUseTemplate && _t2vJsonOutput) {
      schema = _promptTemplates[_selectedTemplate]?['schema'] as Map<String, dynamic>?;
    }

    _log('📋 [T2V] Model: $_t2vSelectedModel');

    try {
      _log('📤 [T2V] Sending request to Gemini API...');

      String fullResponse = '';
      
      final result = await _geminiApi!.generateText(
        prompt: systemPrompt,
        model: _t2vSelectedModel,
        jsonSchema: schema,
        onChunk: (chunk) {
          if (mounted && _t2vGenerating) {
            setState(() {
              fullResponse += chunk;
              _t2vResponseController.text = fullResponse;
            });
          }
        },
      );

      _log('✅ [T2V] Generation complete!');

      // Try to parse as JSON to extract scenes
      try {
        final decoded = jsonDecode(result ?? fullResponse);
        
        // Parse character_reference structure for ID -> description mapping
        Map<String, String> charIdToDescription = {};
        if (decoded is Map && decoded.containsKey('character_reference')) {
          final charRefs = decoded['character_reference'] as List;
          for (final char in charRefs) {
            final id = char['id']?.toString() ?? '';
            final name = char['name']?.toString() ?? '';
            final desc = char['description']?.toString() ?? '';
            if (id.isNotEmpty) {
              charIdToDescription[id] = '$name: $desc';
            }
          }
          _log('📋 [T2V] Found ${charIdToDescription.length} character definitions');
        }
        
        // Get style from output_structure
        String globalStyle = '';
        if (decoded is Map && decoded.containsKey('output_structure')) {
          final output = decoded['output_structure'];
          globalStyle = output['style']?.toString() ?? '';
          if (globalStyle.isNotEmpty) {
            _log('🎨 [T2V] Style: $globalStyle');
          }
        }
        
        // Parse scenes from output_structure.scenes
        if (decoded is Map && decoded.containsKey('output_structure')) {
          final output = decoded['output_structure'];
          if (output is Map && output.containsKey('scenes')) {
            final scenes = output['scenes'] as List;
            
            setState(() {
              _t2vScenes = scenes.map((scene) {
                String prompt = scene['prompt']?.toString() ?? '';
                String videoAction = scene['video_action_prompt']?.toString() ?? '';
                final charsInScene = (scene['characters_in_scene'] as List?)?.map((e) => e.toString()).toList() ?? [];
                
                // Replace character IDs with full descriptions in prompt
                for (final charId in charsInScene) {
                  if (charIdToDescription.containsKey(charId)) {
                    prompt = prompt.replaceAll(charId, charIdToDescription[charId]!);
                    videoAction = videoAction.replaceAll(charId, charIdToDescription[charId]!);
                  }
                }
                
                // Combine prompt + video_action + style for self-consistent video prompt
                String fullPrompt = prompt;
                if (videoAction.isNotEmpty) {
                  fullPrompt = '$prompt. $videoAction';
                }
                if (globalStyle.isNotEmpty) {
                  fullPrompt = '$fullPrompt. Style: $globalStyle';
                }
                
                return {
                  'scene_number': scene['scene_number'] ?? 0,
                  'title': 'Scene ${scene['scene_number'] ?? 0}',
                  'prompt': fullPrompt, // Full self-consistent prompt
                  'original_prompt': scene['prompt']?.toString() ?? '',
                  'video_action': videoAction,
                  'characters': charsInScene,
                  'negative_prompt': scene['negative_prompt']?.toString() ?? '',
                };
              }).toList().cast<Map<String, dynamic>>();
              
              // Extract story_title
              _t2vStoryTitle = output['story_title']?.toString() ?? 'Untitled Story';
              
              // Extract bgmusic prompts
              if (output['bgmusic'] is List) {
                _t2vBgMusic = (output['bgmusic'] as List).map((m) => Map<String, dynamic>.from(m as Map)).toList();
                _log('🎵 [T2V] Extracted ${_t2vBgMusic.length} background music prompts');
              }
              
              _t2vResponseViewTab = 0; // Switch to scenes view on success
            });
            _log('📝 [T2V] Processed ${_t2vScenes.length} scenes with character descriptions and style');
          }
        } else if (decoded is Map && decoded.containsKey('prompts')) {
          // Fallback for simple format
          final prompts = decoded['prompts'] as List;
          setState(() {
            _t2vScenes = prompts.map((p) => {
              'scene_number': p['scene_number'] ?? 0,
              'title': 'Scene ${p['scene_number'] ?? 0}',
              'prompt': p['prompt'] ?? p['description'] ?? '',
              'characters': p['characters'] ?? [],
            }).toList().cast<Map<String, dynamic>>();
            _t2vResponseViewTab = 0;
          });
          _log('📝 [T2V] Parsed ${_t2vScenes.length} scenes (simple format)');
        }
      } catch (e) {
        _log('ℹ️ [T2V] Response is not JSON format, keeping as raw text: $e');
      }

    } catch (e) {
      _log('❌ [T2V] Error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() => _t2vGenerating = false);
      }
    }
  }

  /// Premium Header - matching reference design exactly
  Widget _buildPremiumHeader(bool isDesktop) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Back button (hidden when embedded)
          if (!widget.embedded)
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20, color: Color(0xFF64748B)),
              onPressed: () => Navigator.of(context).pop(),
              tooltip: 'Back',
            )
          else
            const SizedBox(width: 16),
          // Logo with sparkle icon - hidden when embedded
          if (!widget.embedded)
            Row(
              children: [
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [Color(0xFF1E40AF), Color(0xFF7C3AED)],
                  ).createShader(bounds),
                  child: const Icon(Icons.auto_awesome, size: 22, color: Colors.white),
                ),
                const SizedBox(width: 8),
                const Text(
                  'SceneBuilder',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E40AF),
                    fontFamily: 'Inter',
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          if (_mainSectionIndex == 0) ...[
            const SizedBox(width: 24),
            // Tabs - matching reference design
            _buildHeaderTab(0, Icons.edit_note, 'Prompts'),
            _buildHeaderTab(1, Icons.image, 'Images'),
            _buildHeaderTab(2, Icons.movie, 'Video'),
          ],
          
          const Spacer(),
          
          // Video count indicator (only show on Video tab)
          if (_mainSectionIndex == 0 && _tabController!.index == 2)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1E40AF).withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.videocam, size: 16, color: Color(0xFF1E40AF)),
                  const SizedBox(width: 6),
                  Text(
                    '${_getAvailableVideoCount()}/${_getTotalVideoScenes()} Available',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E40AF),
                    ),
                  ),
                ],
              ),
            ),
          
          // Add to Mastering button (only show on Video tab)
          if (_mainSectionIndex == 0 && _tabController!.index == 2 && _canAddToMastering())
            Container(
              margin: const EdgeInsets.only(right: 12),
              child: ElevatedButton.icon(
                onPressed: _addClipsToMastering,
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('Add to Mastering'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0D9488),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          
          // Controls icon button (only show on Video tab)
          if (_mainSectionIndex == 0 && _tabController!.index == 2)
            Container(
              margin: const EdgeInsets.only(right: 12),
              child: IconButton(
                onPressed: _showControlsDialog,
                icon: const Icon(Icons.settings, size: 20),
                tooltip: 'Generation Controls',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFF8FAFC),
                  foregroundColor: const Color(0xFF64748B),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          
          // Project selector
          if (_currentProject != null)
            Container(
              margin: const EdgeInsets.only(right: 12),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _showProjectsDialog,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_open, size: 16, color: Color(0xFF1E40AF)),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: Text(
                            _currentProject!.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1E40AF),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_drop_down, size: 18, color: Color(0xFF64748B)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  /// Header tab button
  Widget _buildHeaderTab(int index, IconData icon, String label) {
    final isSelected = _tabController!.index == index;
    
    return GestureDetector(
      onTap: () {
        _tabController!.animateTo(index);
        setState(() {});
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEFF6FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? const Color(0xFF1E40AF) : const Color(0xFF64748B),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                fontFamily: 'Inter',
                color: isSelected ? const Color(0xFF1E40AF) : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> get _sortedVideoImagePaths {
    final sortedPaths = List<String>.from(_generatedImagePaths);
    sortedPaths.sort((a, b) {
      final matchA = RegExp(r'scene_(\d+)_').firstMatch(path.basename(a));
      final matchB = RegExp(r'scene_(\d+)_').firstMatch(path.basename(b));
      final numA = int.tryParse(matchA?.group(1) ?? '9999') ?? 9999;
      final numB = int.tryParse(matchB?.group(1) ?? '9999') ?? 9999;
      return numA.compareTo(numB);
    });
    return sortedPaths;
  }

  void _navigateVideoImage(int delta) {
    if (_generatedImagePaths.isEmpty) return;
    
    // Stop inline video when navigating to different scene
    if (_playingVideoPath != null) {
      _stopInlineVideo();
    }
    
    setState(() {
      int newIndex = _selectedVideoSceneIndex + delta;
      if (newIndex < 0) newIndex = 0;
      if (newIndex >= _generatedImagePaths.length) newIndex = _generatedImagePaths.length - 1;
      _selectedVideoSceneIndex = newIndex;
    });
  }

  /// Video tab content
  Widget _buildVideoTab() {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _navigateVideoImage(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _navigateVideoImage(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _navigateVideoImage(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _navigateVideoImage(1),
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: const Color(0xFFF7F9FC),
          child: Column(
        children: [
          _buildPremiumToolbarRow1(),
          _buildPremiumToolbarRow2(),
          // Main content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // LEFT: Select Scenes list
                  Expanded(
                    flex: 2,
                    child: _buildVideoImageSelector(),
                  ),
                  const SizedBox(width: 16),
                  // RIGHT: Video generation preview
                  Expanded(
                    flex: 5,
                    child: _buildVideoGenerationPanel(),
                  ),
                ],
              ),
            ),
          ),
          // Terminal
          if (!_logCollapsed) SizedBox(height: 160, child: _buildTerminalPanel()),
        ],
      ),
    ),),);
  }

  /// Video tab - Image selector panel
  Widget _buildVideoImageSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: Row(
              children: [
                const Icon(Icons.collections_bookmark_outlined, size: 18, color: Color(0xFF1E40AF)),
                const SizedBox(width: 8),
                const Text('Select Scenes', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_generatedImagePaths.length} images',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                  ),
                ),
              ],
            ),
          ),
          
          // Generate All Button
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton.icon(
                onPressed: _videoGenerationRunning ? _stopVideoGeneration : _startVideoGeneration,
                icon: _videoGenerationRunning 
                  ? const Icon(Icons.stop, size: 16)
                  : const Icon(Icons.auto_awesome, size: 16),
                label: Text(_videoGenerationRunning ? 'Stop' : 'Generate All', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _videoGenerationRunning ? Colors.red : const Color(0xFF1E40AF),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
          

          // Scrollable List of cards
          Expanded(
            child: _generatedImagePaths.isEmpty
                ? const Center(
                    child: Text('No images generated yet', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                  )
                : Builder(
                    builder: (context) {
                      // Sort by scene number ascending (Scene 1, Scene 2, ...)
                      final sortedPaths = List<String>.from(_generatedImagePaths);
                      sortedPaths.sort((a, b) {
                        final matchA = RegExp(r'scene_(\d+)_').firstMatch(path.basename(a));
                        final matchB = RegExp(r'scene_(\d+)_').firstMatch(path.basename(b));
                        final numA = int.tryParse(matchA?.group(1) ?? '9999') ?? 9999;
                        final numB = int.tryParse(matchB?.group(1) ?? '9999') ?? 9999;
                        return numA.compareTo(numB);
                      });

                      return ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: sortedPaths.length,
                        itemBuilder: (context, index) {
                          final imgPath = sortedPaths[index];
                          final filename = path.basename(imgPath);
                          final match = RegExp(r'scene_(\d+)_').firstMatch(filename);
                          final sceneNo = match?.group(1) ?? '${index + 1}';
                          final isActive = _selectedVideoSceneIndex == index;

                          return InkWell(
                            onTap: () {
                              setState(() {
                                _selectedVideoSceneIndex = index;
                              });
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isActive ? const Color(0xFF1E40AF) : const Color(0xFFE2E8F0),
                                width: isActive ? 1.5 : 1,
                              ),
                            ),
                            child: Column(
                              children: [
                                Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                                      child: AspectRatio(
                                        aspectRatio: 16 / 9,
                                        child: Image.file(File(imgPath), fit: BoxFit.cover),
                                      ),
                                    ),
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.6),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          'Scene $sceneNo',
                                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ),
                                    // Status indicator overlay
                                    if (_videoSceneStates.containsKey(imgPath))
                                      Builder(
                                        builder: (context) {
                                          final sceneState = _videoSceneStates[imgPath]!;
                                          final status = sceneState.status;
                                          
                                          Color statusColor;
                                          IconData statusIcon;
                                          String statusText;
                                          
                                          switch (status) {
                                            case 'queued':
                                              statusColor = Colors.orange;
                                              statusIcon = Icons.schedule;
                                              statusText = 'Queued';
                                              break;
                                            case 'generating':
                                              statusColor = Colors.blue;
                                              statusIcon = Icons.auto_awesome;
                                              statusText = 'Generating';
                                              break;
                                            case 'polling':
                                              statusColor = Colors.purple;
                                              statusIcon = Icons.hourglass_empty;
                                              statusText = 'Processing';
                                              break;
                                            case 'downloading':
                                              statusColor = Colors.teal;
                                              statusIcon = Icons.download;
                                              statusText = 'Downloading';
                                              break;
                                            case 'completed':
                                              statusColor = Colors.green;
                                              statusIcon = Icons.check_circle;
                                              statusText = 'Completed';
                                              break;
                                            case 'failed':
                                              statusColor = Colors.red;
                                              statusIcon = Icons.error;
                                              statusText = 'Failed';
                                              break;
                                            default:
                                              return const SizedBox.shrink();
                                          }
                                          
                                          return Positioned(
                                            top: 8,
                                            left: 8,
                                            right: 8,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                  decoration: BoxDecoration(
                                                    color: statusColor.withOpacity(0.9),
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(statusIcon, color: Colors.white, size: 12),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        statusText,
                                                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                                      ),
                                                    ],
                                              ),
                                            ),
                                            // Show error message for failed status
                                            if (status == 'failed' && sceneState.error != null)
                                              Container(
                                                margin: const EdgeInsets.only(top: 4),
                                                padding: const EdgeInsets.all(8),
                                                decoration: BoxDecoration(
                                                  color: Colors.red.withOpacity(0.9),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  sceneState.error!,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                  maxLines: 3,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                          ],
                                        ),
                                          );
                                        },
                                      ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // Play button if video is completed
                                  if (_videoSceneStates.containsKey(imgPath) && 
                                      _videoSceneStates[imgPath]!.status == 'completed' &&
                                      _videoSceneStates[imgPath]!.videoPath != null)
                                    TextButton.icon(
                                      onPressed: () => _playVideo(_videoSceneStates[imgPath]!.videoPath!),
                                      icon: const Icon(Icons.play_circle_filled, size: 16, color: Color(0xFF10B981)),
                                      label: const Text('PLAY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF10B981))),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: _videoGenerationRunning ? null : () => _generateSingleVideo(index),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      side: const BorderSide(color: Color(0xFFDBEAFE)),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                    ),
                                    child: const Text('GENERATE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF1E40AF))),
                                  ),
                                ],
                              ),
                            ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );
  }




  /// Video tab - Generation panel
  Widget _buildVideoGenerationPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: Row(
              children: [
                const Icon(Icons.movie_filter_outlined, size: 18, color: Color(0xFF7C3AED)),
                const SizedBox(width: 8),
                const Text('Video Generation Preview', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                const Spacer(),
                const Text('Resolution: 1080p', style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                const SizedBox(width: 12),
                Container(width: 1, height: 12, color: const Color(0xFFE2E8F0)),
                const SizedBox(width: 12),
                const Text('Duration: 00:15', style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
              ],
            ),
          ),
          
          // Large Preview Area
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 25,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Base Image or Video Player
                          if (_playingVideoPath != null && _inlineVideoController != null)
                            // Video Player (when playing)
                            Video(
                              controller: _inlineVideoController!,
                              controls: MaterialVideoControls,
                            )
                          else
                            // Base Image (when not playing)
                            _generatedImagePaths.isEmpty
                                ? Container(color: const Color(0xFFF1F5F9), child: const Icon(Icons.videocam_off, size: 64, color: Color(0xFF94A3B8)))
                                : Builder(
                                    builder: (context) {
                                      final sortedPaths = _sortedVideoImagePaths;
                                      
                                      final currentIdx = _selectedVideoSceneIndex < sortedPaths.length ? _selectedVideoSceneIndex : 0;
                                      return Image.file(
                                        File(sortedPaths[currentIdx]), 
                                        fit: BoxFit.contain,
                                        filterQuality: FilterQuality.high,
                                        isAntiAlias: true,
                                      );
                                    },
                                  ),
                          
                          //Overlays
                          Positioned(
                            top: 16,
                            left: 16,
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.6),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text('Scene #${_selectedVideoSceneIndex + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                ),
                                const SizedBox(width: 8),
                                Builder(builder: (context) {
                                  String statusText = 'Ready';
                                  Color statusColor = const Color(0xFF3B82F6).withOpacity(0.8);
                                  
                                  if (_videoScenes.length > _selectedVideoSceneIndex) {
                                    final scene = _videoScenes[_selectedVideoSceneIndex];
                                    statusText = scene.status.toUpperCase();
                                    switch (scene.status) {
                                      case 'queued': statusColor = Colors.grey.withOpacity(0.8); break;
                                      case 'generating': statusColor = Colors.orange.withOpacity(0.8); break;
                                      case 'polling': statusColor = Colors.blue.withOpacity(0.8); break;
                                      case 'downloading': statusColor = Colors.teal.withOpacity(0.8); break;
                                      case 'completed': statusColor = Colors.green.withOpacity(0.8); break;
                                      case 'failed': statusColor = Colors.red.withOpacity(0.8); break;
                                    }
                                  }
                                  
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: statusColor,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(statusText, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                  );
                                }),
                              ],
                            ),
                          ),
                          
                          // Fullscreen button (top right)
                          if (_playingVideoPath != null)
                            Positioned(
                              top: 16,
                              right: 16,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.fullscreen, color: Colors.white, size: 28),
                                  onPressed: () {
                                    if (_playingVideoPath != null) {
                                      showDialog(
                                        context: context,
                                        builder: (context) => _VideoPlayerDialog(videoPath: _playingVideoPath!),
                                      );
                                    }
                                  },
                                  tooltip: 'Fullscreen',
                                ),
                              ),
                            ),
                          
                          // Central Play Button (only show when not playing)
                          if (_playingVideoPath == null && _videoScenes.length > _selectedVideoSceneIndex && _videoScenes[_selectedVideoSceneIndex].status == 'completed')
                            Center(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.3),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white.withOpacity(0.5), width: 1.5),
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.play_arrow, size: 40, color: Colors.white),
                                  onPressed: () {
                                    final path = _videoScenes[_selectedVideoSceneIndex].videoPath;
                                    if (path != null) {
                                      _playVideo(path);
                                    }
                                  },
                                ),
                              ),
                            ),
                          
                          // Stop button (when video is playing)
                          if (_playingVideoPath != null)
                            Positioned(
                              bottom: 80,
                              right: 20,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.stop, color: Colors.white, size: 28),
                                  onPressed: _stopInlineVideo,
                                  tooltip: 'Stop',
                                ),
                              ),
                            ),
                          
                          // Progress Bar at bottom
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  height: 4,
                                  width: double.infinity,
                                  color: Colors.white.withOpacity(0.2),
                                ),
                                Container(
                                  height: 4,
                                  width: double.infinity, // Actual progress would be a fraction of width
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF3B82F6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Navigation Arrows
                          if (_generatedImagePaths.isNotEmpty) ...[
                             Positioned(
                               left: 20,
                               top: 0, bottom: 0,
                               child: Center(
                                 child: Container(
                                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.3), shape: BoxShape.circle),
                                    child: IconButton(
                                      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 24),
                                      onPressed: () => _navigateVideoImage(-1),
                                    ),
                                 ),
                               ),
                             ),
                             Positioned(
                               right: 20,
                               top: 0, bottom: 0,
                               child: Center(
                                 child: Container(
                                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.3), shape: BoxShape.circle),
                                    child: IconButton(
                                      icon: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 24),
                                      onPressed: () => _navigateVideoImage(1),
                                    ),
                                 ),
                               ),
                             ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ),
            ),
          ),
          
          // Footer with stats and videos count
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
              border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: Row(
              children: [
                const Text('Est. generation time: ', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                const Text('45s', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF64748B))),
                const Spacer(),
                OutlinedButton(
                  onPressed: () {},
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Discard', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.videocam, size: 18),
                  label: const Text('Generate Video', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Mobile Video tab
  Widget _buildMobileVideoTab() {
    return Container(
      color: const Color(0xFFF7F9FC),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Header with Generate All
          Row(
            children: [
              const Icon(Icons.movie_filter_outlined, size: 20, color: Color(0xFF1E40AF)),
              const SizedBox(width: 8),
              const Text('Text to Video', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              ElevatedButton(
                onPressed: _videoGenerationRunning ? null : _startVideoGeneration,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E40AF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(_videoGenerationRunning ? '...' : 'Gen All', style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Image preview grid
          Expanded(
            child: _generatedImagePaths.isEmpty
                ? const Center(child: Text('Generate images first', style: TextStyle(color: Color(0xFF94A3B8))))
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 16 / 9,
                    ),
                    itemCount: _generatedImagePaths.length,
                    itemBuilder: (context, index) {
                      final imgPath = _generatedImagePaths[index];
                      String statusText = 'Ready';
                      Color statusColor = const Color(0xFF3B82F6);
                      
                      if (_videoScenes.length > index) {
                        final scene = _videoScenes[index];
                        statusText = scene.status;
                        switch (scene.status) {
                          case 'queued': statusColor = Colors.grey; break;
                          case 'generating': statusColor = Colors.orange; break;
                          case 'polling': statusColor = Colors.blue; break;
                          case 'downloading': statusColor = Colors.teal; break;
                          case 'completed': statusColor = Colors.green; break;
                          case 'failed': statusColor = Colors.red; break;
                        }
                      }

                      return InkWell(
                        onTap: () => setState(() => _selectedVideoSceneIndex = index),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _selectedVideoSceneIndex == index ? const Color(0xFF1E40AF) : Colors.transparent,
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.file(File(imgPath), fit: BoxFit.cover),
                                // Opacity overlay for status
                                if (statusText != 'Ready' && statusText != 'completed')
                                  Container(color: Colors.black.withOpacity(0.4)),
                                // Status Badge
                                Positioned(
                                  top: 6,
                                  left: 6,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: statusColor.withOpacity(0.8),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(statusText.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                                // Generate Button
                                if (statusText == 'Ready' || statusText == 'failed')
                                  Positioned(
                                    bottom: 6,
                                    right: 6,
                                    child: InkWell(
                                      onTap: () => _generateSingleVideo(index),
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: const BoxDecoration(
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.play_arrow, size: 16, color: Color(0xFF1E40AF)),
                                      ),
                                    ),
                                  ),
                                // Completed Checkmark
                                if (statusText == 'completed')
                                  Positioned(
                                    bottom: 6,
                                    right: 6,
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: const BoxDecoration(
                                        color: Colors.green,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.check, size: 16, color: Colors.white),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 20),
          // Generate button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _generatedImagePaths.isEmpty ? null : () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Video generation coming soon!')),
                );
              },
              icon: const Icon(Icons.play_circle_filled, size: 24),
              label: const Text('Generate Video', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F46E5),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  
  /// Desktop layout for Image Generation tab - Premium Design
  Widget _buildDesktopImageGenTab() {
    return Container(
      color: const Color(0xFFF7F9FC),
      child: Column(
        children: [
          // Main content - 3 columns (controls merged into left column)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left: Compact Controls + Characters panel
                  SizedBox(
                    width: 260,
                    child: Column(
                      children: [
                        _buildCompactControlPanel(),
                        const SizedBox(height: 8),
                        Expanded(child: _buildCharactersPanel()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Center: Scenes control + JSON editor
                  Expanded(flex: 1, child: _buildScenesPanel()),
                  const SizedBox(width: 12),
                  // Right: Generated images
                  Expanded(flex: 2, child: _buildGeneratedPanel()),
                ],
              ),
            ),
          ),
          // Bottom: Terminal/Logs
          if (!_logCollapsed) SizedBox(height: 160, child: _buildTerminalPanel()),
        ],
      ),
    );
  }

  /// Compact control panel that fits in the left column above the characters panel
  Widget _buildCompactControlPanel() {
    final currentModelName = _selectedImageModel?.name ?? 
        (_imageModels.isNotEmpty ? _imageModels.first.name : 'Nano Banana');
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: File ops
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
            child: Row(
              children: [
                _compactBtn(Icons.folder_open, 'Load', _loadJson),
                const SizedBox(width: 4),
                _compactBtn(Icons.content_paste, 'Paste', _pasteJson),
                const SizedBox(width: 4),
                _compactBtn(Icons.save, 'Save', _saveJson),
                const Spacer(),
                // Terminal toggle
                InkWell(
                  onTap: () => setState(() => _logCollapsed = !_logCollapsed),
                  borderRadius: BorderRadius.circular(4),
                  child: Icon(
                    _logCollapsed ? Icons.terminal : Icons.keyboard_arrow_down,
                    size: 14,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          
          // Divider
          Divider(height: 1, color: Colors.grey.shade200),
          
          // Row 2: Model selector (full width)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: Row(
              children: [
                const Icon(Icons.palette, size: 12, color: Color(0xFF7C3AED)),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _imageModels.any((m) => m.name == currentModelName) ? currentModelName : null,
                        hint: const Text('Model', style: TextStyle(fontSize: 10)),
                        style: const TextStyle(fontSize: 10, color: Colors.black, fontFamily: 'Inter'),
                        isExpanded: true,
                        selectedItemBuilder: (context) => _imageModels.map((m) => 
                          Align(alignment: Alignment.centerLeft, child: Text(m.name, style: const TextStyle(fontSize: 10, color: Colors.black, fontFamily: 'Inter'), overflow: TextOverflow.ellipsis))
                        ).toList(),
                        items: _imageModels.map((m) => DropdownMenuItem(
                          value: m.name, 
                          child: Text(m.name, style: const TextStyle(fontSize: 10, color: Colors.black87)),
                        )).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _selectedImageModel = _imageModels.firstWhere((m) => m.name == v);
                            });
                          }
                        },
                        isDense: true,
                        icon: const Icon(Icons.arrow_drop_down, size: 14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Divider
          Divider(height: 1, color: Colors.grey.shade200),
          
          // Row 3: Browser controls
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: Row(
              children: [
                const Text('Browser:', style: TextStyle(fontSize: 9, color: Color(0xFF64748B))),
                const SizedBox(width: 4),
                SizedBox(
                  width: 30,
                  height: 22,
                  child: TextField(
                    controller: _profileCountController,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _compactBtn(null, 'Open', _openMultipleBrowsers, color: const Color(0xFF1E40AF), bg: const Color(0xFFDBEAFE)),
                const SizedBox(width: 3),
                _compactBtn(null, 'Connect', _connectAllBrowsers, color: const Color(0xFF64748B)),
              ],
            ),
          ),
          
          // Row 4: Browser status
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
            child: Row(
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _cdpHubs.isEmpty ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _browserStatus,
                  style: TextStyle(
                    fontSize: 9, fontWeight: FontWeight.w600,
                    color: _cdpHubs.isEmpty ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                  ),
                ),
              ],
            ),
          ),
          
          // Divider
          Divider(height: 1, color: Colors.grey.shade200),
          
          // Row 5: Generation settings
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: Row(
              children: [
                _compactNumberField('Imgs:', _batchSizeController),
                const SizedBox(width: 6),
                _compactNumberField('Delay:', _delayController),
                const SizedBox(width: 6),
                _compactNumberField('Retry:', _retriesController),
              ],
            ),
          ),
          
          // Row 6: Prompt History
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 6, 4),
            child: Row(
              children: [
                SizedBox(
                  width: 20, height: 20,
                  child: Checkbox(
                    value: _includeHistory,
                    onChanged: (v) => setState(() => _includeHistory = v ?? true),
                    visualDensity: VisualDensity.compact,
                    activeColor: const Color(0xFF1E40AF),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 2),
                const Text('Prompt History', style: TextStyle(fontSize: 9, color: Color(0xFF64748B))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tiny compact button for the control panel
  Widget _compactBtn(IconData? icon, String label, VoidCallback onPressed, {Color? color, Color? bg}) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: bg ?? Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: bg == null ? Border.all(color: Colors.grey.shade300, width: 0.5) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 11, color: color ?? const Color(0xFF64748B)),
              const SizedBox(width: 3),
            ],
            Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w500, color: color ?? const Color(0xFF64748B))),
          ],
        ),
      ),
    );
  }

  /// Compact number input for the control panel
  Widget _compactNumberField(String label, TextEditingController controller) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF64748B))),
        const SizedBox(width: 3),
        SizedBox(
          width: 28,
          height: 20,
          child: TextField(
            controller: controller,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
  
  /// Premium Toolbar Row 1: File ops, Model, Profile, Chrome, Output
  Widget _buildPremiumToolbarRow1() {
    final isVideoTab = _tabController?.index == 2;
    
    // Determine Model UI
    Widget modelSelector;
    if (isVideoTab) {
      modelSelector = Row(
        children: [
          const Icon(Icons.movie, size: 16, color: Color(0xFF7C3AED)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _videoModelOptions.contains(_videoSelectedModel) ? _videoSelectedModel : _videoModelOptions.first,
                hint: const Text('Video Model', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, fontFamily: 'Inter')),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Colors.black, fontFamily: 'Inter'),
                items: _videoModelOptions.map((m) => DropdownMenuItem(
                  value: m, 
                  child: Text(m, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Colors.black87, fontFamily: 'Inter')),
                )).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _videoSelectedModel = v);
                },
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _aspectRatioOptions.any((a) => a['value'] == _videoSelectedAspectRatio) 
                    ? _videoSelectedAspectRatio 
                    : _aspectRatioOptions.first['value'],
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Colors.black, fontFamily: 'Inter'),
                items: _aspectRatioOptions.map((a) => DropdownMenuItem(
                  value: a['value'], 
                  child: Text(a['name']!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Colors.black87, fontFamily: 'Inter')),
                )).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _videoSelectedAspectRatio = v);
                },
                isDense: true,
              ),
            ),
          ),
        ],
      );
    } else {
      final currentModelName = _selectedImageModel?.name ?? 
          (_imageModels.isNotEmpty ? _imageModels.first.name : 'Nano Banana');
      modelSelector = Row(
        children: [
          const Icon(Icons.palette, size: 16, color: Color(0xFF7C3AED)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _imageModels.any((m) => m.name == currentModelName) ? currentModelName : null,
                hint: const Text('Model', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, fontFamily: 'Inter')),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Colors.black, fontFamily: 'Inter'),
                selectedItemBuilder: (context) => _imageModels.map((m) => 
                  Center(child: Text(m.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Colors.black, fontFamily: 'Inter')))
                ).toList(),
                items: _imageModels.map((m) => DropdownMenuItem(
                  value: m.name, 
                  child: Text(m.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Colors.black87, fontFamily: 'Inter')),
                )).toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      _selectedImageModel = _imageModels.firstWhere((m) => m.name == v);
                    });
                  }
                },
                isDense: true,
              ),
            ),
          ),
        ],
      );
    }
    
    return Container(
      height: _controlPanelCollapsed ? 40 : 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          // Collapse/Expand button
          IconButton(
            icon: Icon(
              _controlPanelCollapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
              size: 20,
              color: const Color(0xFF64748B),
            ),
            onPressed: () => setState(() => _controlPanelCollapsed = !_controlPanelCollapsed),
            tooltip: _controlPanelCollapsed ? 'Expand Controls' : 'Collapse Controls',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          
          if (!_controlPanelCollapsed) ...[
          // File operations group
          Row(
            children: [
              ToolbarButton(icon: Icons.folder_open, label: 'Load JSON', onPressed: _loadJson),
              const SizedBox(width: 8),
              ToolbarButton(icon: Icons.content_paste, label: 'Paste JSON', onPressed: _pasteJson),
              const SizedBox(width: 8),
              ToolbarButton(icon: Icons.save, label: 'Save', onPressed: _saveJson),
            ],
          ),
          
          Container(width: 1, height: 24, color: Colors.grey.shade300, margin: const EdgeInsets.symmetric(horizontal: 16)),
          
          // Model selector (Context sensitive)
          modelSelector,
          

          ], // End of !_controlPanelCollapsed
          
          // Show condensed status when collapsed
          if (_controlPanelCollapsed) ...[
            const SizedBox(width: 12),
            Text(
              'Controls',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
            const Spacer(),
            Text(
              _browserStatus,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade500,
              ),
            ),
          ],
          
          if (!_controlPanelCollapsed) const Spacer(),
        ],
      ),
    );
  }

  /// Premium Toolbar Row 2: Browser controls
  Widget _buildPremiumToolbarRow2() {
    // Hide completely when collapsed
    if (_controlPanelCollapsed) return const SizedBox.shrink();
    
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          // Browser controls
          const Text('Browser:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Color(0xFF64748B))),
          const SizedBox(width: 8),
          SizedBox(
            width: 48,
            height: 28,
            child: TextField(
              controller: _profileCountController,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Inter'),
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Open button - blue background, normal text
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFDBEAFE),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _openMultipleBrowsers,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Text('Open', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF1E40AF))),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Connect button - outlined, normal text
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE2E8F0)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _connectAllBrowsers,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Text('Connect', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Color(0xFF64748B))),
                ),
              ),
            ),
          ),
          
          Container(width: 1, height: 16, color: Colors.grey.shade300, margin: const EdgeInsets.symmetric(horizontal: 12)),
          
          // Browser status
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _cdpHubs.isEmpty ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _browserStatus,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Inter',
                  color: _cdpHubs.isEmpty ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                ),
              ),
            ],
          ),
          
          Container(width: 1, height: 16, color: Colors.grey.shade300, margin: const EdgeInsets.symmetric(horizontal: 12)),
          
          // Generation settings
          CompactNumberInput(label: 'Imgs/Browser:', controller: _batchSizeController),
          const SizedBox(width: 12),
          CompactNumberInput(label: 'Delay:', controller: _delayController),
          const SizedBox(width: 12),
          CompactNumberInput(label: 'Retry:', controller: _retriesController),
          
          const Spacer(),
          
          // Prompt History checkbox
          Row(
            children: [
              Checkbox(
                value: _includeHistory,
                onChanged: (v) => setState(() => _includeHistory = v ?? true),
                visualDensity: VisualDensity.compact,
                activeColor: const Color(0xFF1E40AF),
              ),
              const Text('Prompt History', style: TextStyle(fontSize: 11)),
            ],
          ),
          
          // Terminal toggle
          IconButton(
            icon: Icon(_logCollapsed ? Icons.terminal : Icons.keyboard_arrow_down, size: 18),
            onPressed: () => setState(() => _logCollapsed = !_logCollapsed),
            tooltip: _logCollapsed ? 'Show Terminal' : 'Hide Terminal',
          ),
        ],
      ),
    );
  }

  /// Characters & Entities panel - Left column with tabs
  Widget _buildCharactersPanel() {
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          // Tab Header - Characters | Entities | Import | Folder
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: [
                // Characters Tab
                _buildLeftPanelTab(
                  index: 0,
                  icon: Icons.people,
                  label: 'Characters',
                ),
                const SizedBox(width: 4),
                // Entities Tab
                _buildLeftPanelTab(
                  index: 1,
                  icon: Icons.landscape,
                  label: 'Entities',
                ),
                const Spacer(),
                // Folder button
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 16),
                  onPressed: () async {
                    final appDir = await getApplicationDocumentsDirectory();
                    final folderName = _leftPanelTabIndex == 0 ? 'characters' : 'entities';
                    final targetDir = path.join(appDir.path, 'VEO3', folderName);
                    await Directory(targetDir).create(recursive: true);
                    if (Platform.isWindows) {
                      Process.run('explorer', [targetDir]);
                    }
                  },
                  color: const Color(0xFF64748B),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Open Folder',
                ),
              ],
            ),
          ),
          // Style & Gen All Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFC),
              border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
            ),
            child: Row(
              children: [
                const Text('Style:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w400, color: Color(0xFF64748B))),
                const SizedBox(width: 4),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedCharStyle,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w400, color: Colors.black87),
                    items: _charImageStyles.map((s) => DropdownMenuItem(
                      value: s, 
                      child: Text(s, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w400)),
                    )).toList(),
                    onChanged: (v) => setState(() => _selectedCharStyle = v ?? 'No Style'),
                    isDense: true,
                  ),
                ),
                const Spacer(),
                // Gen All button
                PopupMenuButton<String>(
                  enabled: _leftPanelTabIndex == 0 ? !_charGenerating : !_entityGenerating,
                  onSelected: (value) {
                    if (_leftPanelTabIndex == 0) {
                      // Characters tab
                      if (value == 'missing') {
                        _generateMissingCharacterImages();
                      } else if (value == 'all') {
                        _generateAllCharacterImages();
                      }
                    } else {
                      // Entities tab
                      if (value == 'missing') {
                        _generateMissingEntityImages();
                      } else if (value == 'all') {
                        _generateAllEntityImages();
                      }
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'missing',
                      child: Row(
                        children: [
                          Icon(
                            Icons.auto_awesome,
                            size: 16,
                            color: _leftPanelTabIndex == 0 ? const Color(0xFF1E40AF) : const Color(0xFF16A34A),
                          ),
                          const SizedBox(width: 8),
                          const Text('Gen Missing', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'all',
                      child: Row(
                        children: [
                          Icon(
                            Icons.refresh,
                            size: 16,
                            color: _leftPanelTabIndex == 0 ? const Color(0xFF1E40AF) : const Color(0xFF16A34A),
                          ),
                          const SizedBox(width: 8),
                          const Text('Generate All', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                  child: Container(
                    decoration: BoxDecoration(
                      color: _leftPanelTabIndex == 0 ? const Color(0xFFDBEAFE) : const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Gen All', 
                          style: TextStyle(
                            fontSize: 10, 
                            fontWeight: FontWeight.w500, 
                            color: _leftPanelTabIndex == 0
                                ? (_charGenerating ? const Color(0xFF1E40AF).withOpacity(0.5) : const Color(0xFF1E40AF))
                                : (_entityGenerating ? const Color(0xFF16A34A).withOpacity(0.5) : const Color(0xFF16A34A)),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 16,
                          color: _leftPanelTabIndex == 0
                              ? (_charGenerating ? const Color(0xFF1E40AF).withOpacity(0.5) : const Color(0xFF1E40AF))
                              : (_entityGenerating ? const Color(0xFF16A34A).withOpacity(0.5) : const Color(0xFF16A34A)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Content - either Characters or Entities list
          Expanded(
            child: _leftPanelTabIndex == 0
                ? _buildCharactersList()
                : _buildEntitiesList(),
          ),
        ],
      ),
    );
  }

  /// Build tab button for left panel (Characters/Entities)
  Widget _buildLeftPanelTab({required int index, required IconData icon, required String label}) {
    final isSelected = _leftPanelTabIndex == index;
    final color = index == 0 ? const Color(0xFF1E40AF) : const Color(0xFF16A34A);
    
    return GestureDetector(
      onTap: () {
        setState(() => _leftPanelTabIndex = index);
        // Scan folders for images when switching tabs
        _scanAndLoadImagesFromDisk();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: isSelected ? Border.all(color: color.withOpacity(0.3)) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isSelected ? color : const Color(0xFF94A3B8)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? color : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build characters list
  Widget _buildCharactersList() {
    if (_characters.isEmpty) {
      return const Center(child: Text('No characters', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11)));
    }
    return ListView.builder(
      controller: _charsScrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _characters.length,
      itemBuilder: (ctx, i) {
        final char = _characters[i];
        final isActive = _detectedCharsDisplay.contains(char.id);
        return _buildCharacterItem(char, isActive);
      },
    );
  }

  /// Build entities list
  Widget _buildEntitiesList() {
    if (_entities.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.landscape, size: 32, color: Colors.grey.shade300),
            const SizedBox(height: 8),
            const Text('No entities', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
            const SizedBox(height: 4),
            Text(
              'Generate prompts to extract\nlocations, objects, etc.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 9),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _entitiesScrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _entities.length,
      itemBuilder: (ctx, i) {
        final entity = _entities[i];
        final isActive = _detectedEntitiesDisplay.contains(entity.id);
        return _buildEntityItem(entity, isActive);
      },
    );
  }

  /// Get color for entity type
  Color _getEntityColor(EntityType type) {
    switch (type) {
      case EntityType.location:
        return const Color(0xFF16A34A); // Green
      case EntityType.interior:
        return const Color(0xFFD97706); // Amber
      case EntityType.building:
        return const Color(0xFF7C3AED); // Purple
      case EntityType.object:
        return const Color(0xFF0891B2); // Cyan
      case EntityType.damaged:
        return const Color(0xFFDC2626); // Red
      case EntityType.environment:
        return const Color(0xFF2563EB); // Blue
    }
  }

  /// Get icon for entity type
  IconData _getEntityIcon(EntityType type) {
    switch (type) {
      case EntityType.location:
        return Icons.landscape;
      case EntityType.interior:
        return Icons.home;
      case EntityType.building:
        return Icons.business;
      case EntityType.object:
        return Icons.category;
      case EntityType.damaged:
        return Icons.broken_image;
      case EntityType.environment:
        return Icons.cloud;
    }
  }

  /// Entity list item (similar to character item)
  Widget _buildEntityItem(EntityData entity, bool isActive) {
    final typeColor = _getEntityColor(entity.type);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? typeColor.withOpacity(0.3) : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showEntityImageDialog(entity, entity.images.isNotEmpty ? entity.images.first : null, 0),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Entity image or placeholder
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: typeColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: typeColor.withOpacity(0.2)),
                  ),
                  child: entity.images.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: Image.file(File(entity.images.first), fit: BoxFit.cover),
                        )
                      : Icon(_getEntityIcon(entity.type), size: 20, color: typeColor),
                ),
                const SizedBox(width: 10),
                // Entity info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entity.id.replaceAll('_', ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          // Type badge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: typeColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              entity.type.name,
                              style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: typeColor),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${entity.images.length} img',
                        style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ),
                // Generate button
                IconButton(
                  icon: Icon(Icons.auto_awesome, size: 16, color: typeColor),
                  onPressed: () => _generateSingleEntityImage(entity),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: 'Generate Image',
                ),
                // More options
                SizedBox(
                  width: 28,
                  height: 28,
                  child: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'import') {
                        _importImagesForEntity(entity);
                      } else if (value == 'clear') {
                        _clearImagesForEntity(entity);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'import', child: Row(children: [Icon(Icons.add_photo_alternate, size: 16), SizedBox(width: 8), Text('Import Images')])),
                      const PopupMenuItem(value: 'clear', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: Colors.red), SizedBox(width: 8), Text('Clear Images', style: TextStyle(color: Colors.red))])),
                    ],
                    icon: const Icon(Icons.more_vert, size: 16, color: Color(0xFF94A3B8)),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Import images for an entity
  Future<void> _importImagesForEntity(EntityData entity) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    final appDir = await getApplicationDocumentsDirectory();
    final entityDir = path.join(appDir.path, 'VEO3', 'entities', entity.id);
    await Directory(entityDir).create(recursive: true);

    for (final file in result.files) {
      if (file.path == null) continue;
      final bytes = await File(file.path!).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) continue;

      // Resize to 512x512 max, maintain aspect ratio
      final resized = img.copyResize(decoded, width: 512, height: 512, maintainAspect: true);
      final compressed = img.encodeJpg(resized, quality: 85);

      final fileName = 'entity_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savePath = path.join(entityDir, fileName);
      await File(savePath).writeAsBytes(compressed);

      if (!entity.images.contains(savePath)) {
        entity.images = [...entity.images, savePath];
      }
    }

    setState(() {});
    _log('[Entity] Imported ${result.files.length} images for ${entity.id}');
  }

  /// Clear images for an entity
  void _clearImagesForEntity(EntityData entity) {
    setState(() {
      entity.images = [];
    });
    _log('[Entity] Cleared images for ${entity.id}');
  }

  /// Generate image for a single entity
  Future<void> _generateSingleEntityImage(EntityData entity, {int retryCount = 0}) async {
    if (_charGenerating) {
      _log('Generation already in progress');
      return;
    }
    
    setState(() => _charGenerating = true);
    
    try {
      final prompt = _buildEntityPrompt(entity);
      _log('[Entity] Generating ${entity.id}...');
      
      // Check if the selected model is an API model
      final isApiModel = _selectedImageModel?.modelType == 'api';
      _log('Using ${isApiModel ? "API" : "CDP"} method');
      
      if (isApiModel) {
        // === API METHOD ===
        final ok = await _ensureWhiskSession();
        if (!ok) {
          _log('❌ Could not establish Whisk session');
          setState(() => _charGenerating = false);
          return;
        }
        
        final apiModelId = _selectedImageModel?.apiModelId ?? 'IMAGEN_3_5';
        final aspectRatio = GoogleImageApiService.convertAspectRatio('16:9'); // Entities use 16:9
        
        final response = await _googleImageApi!.generateImage(
          prompt: prompt,
          aspectRatio: aspectRatio,
          imageModel: apiModelId,
        );
        
        if (response.imagePanels.isEmpty || response.imagePanels.first.generatedImages.isEmpty) {
          throw 'No images returned from API';
        }
        
        final base64Image = response.imagePanels.first.generatedImages.first.encodedImage;
        await _saveEntityImage(base64Image, entity, prompt);
        _log('✓ Generated ${entity.id} via API');
        
      } else {
        // === CDP METHOD ===
        if (_cdpHubs.isEmpty) {
          _log('No browsers connected! Open browsers first.');
          setState(() => _charGenerating = false);
          return;
        }
        
        _log('Using CDP method for ${_selectedImageModel?.name ?? "default model"}');
        
        final hub = _cdpHubs.values.first;
        await hub.focusChrome();
        await hub.checkLaunchModal();
        
        final modelIdJs = (_selectedImageModel == null || _selectedImageModel!.url.isEmpty)
            ? 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE'
            : 'window.geminiHub.models.${_selectedImageModel!.url}';
            
        final spawnResult = await hub.spawnImage(
          prompt,
          aspectRatio: '16:9', // Entities use 16:9
          model: modelIdJs,
        );
        
        if (spawnResult == null) {
          throw 'Failed to spawn (null response)';
        }
        
        String? threadId;
        if (spawnResult is Map && spawnResult.containsKey('id')) {
          threadId = spawnResult['id']?.toString();
        } else if (spawnResult is String && spawnResult.isNotEmpty) {
          threadId = spawnResult;
        }
        
        if (threadId == null) {
          throw 'Invalid thread ID';
        }
        
        _log('[Entity] Spawned ${entity.id}');
        
        await Future.delayed(const Duration(seconds: 2));
        await hub.focusChrome();
        
        // Poll
        final startPoll = DateTime.now();
        bool completed = false;
        while (DateTime.now().difference(startPoll).inSeconds < 180) {
          final res = await hub.getThread(threadId);
          
          if (res is Map) {
            if (res['status'] == 'COMPLETED' && res['result'] != null) {
              final result = res['result'];
              if (result is String && result.isNotEmpty) {
                await _saveEntityImage(result, entity, prompt);
                _log('✓ Generated ${entity.id} via CDP');
                completed = true;
              }
              break;
            } else if (res['status'] == 'FAILED') {
              throw 'Generation status FAILED';
            }
          }
          
          await Future.delayed(const Duration(seconds: 3));
        }
        
        if (!completed) {
          throw 'Timeout waiting for entity generation';
        }
      }
      
    } catch (e) {
      _log('❌ Entity generation error: $e');
      
      // Retry logic
      if (retryCount < 2) {
        _log('⚠️ Retrying ${entity.id} (${retryCount + 1}/2)...');
        await Future.delayed(const Duration(seconds: 2));
        setState(() => _charGenerating = false);
        return _generateSingleEntityImage(entity, retryCount: retryCount + 1);
      }
    } finally {
      setState(() => _charGenerating = false);
    }
  }


  /// Generate images for all entities
  Future<void> _generateAllEntityImages() async {
    if (_entities.isEmpty) {
      _log('[Entity] No entities to generate');
      return;
    }
    
    _log('[Entity] Generating images for all ${_entities.length} entities...');
    
    for (int i = 0; i < _entities.length; i++) {
      final entity = _entities[i];
      _log('[Entity] Generating ${i + 1}/${_entities.length}: ${entity.id}');
      
      await _generateSingleEntityImage(entity);
      
      // Small delay between generations
      if (i < _entities.length - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    
    _log('[Entity] ✅ Completed batch generation for ${_entities.length} entities');
  }
  
  /// Generate images only for entities without images
  Future<void> _generateMissingEntityImages() async {
    if (_entities.isEmpty) {
      _log('[Entity] No entities to generate');
      return;
    }
    
    final missingEntities = _entities.where((e) => e.images.isEmpty).toList();
    
    if (missingEntities.isEmpty) {
      _log('[Entity] All entities already have images');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All entities already have images'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    
    _log('[Entity] Generating images for ${missingEntities.length} missing entities...');
    
    for (int i = 0; i < missingEntities.length; i++) {
      final entity = missingEntities[i];
      _log('[Entity] Generating ${i + 1}/${missingEntities.length}: ${entity.id}');
      
      await _generateSingleEntityImage(entity);
      
      // Small delay between generations
      if (i < missingEntities.length - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    
    _log('[Entity] ✅ Completed missing image generation for ${missingEntities.length} entities');
  }
  
  /// Generate images only for characters without images
  Future<void> _generateMissingCharacterImages() async {
    if (_characters.isEmpty) {
      _log('No characters to generate');
      return;
    }
    
    final missingCharacters = _characters.where((c) => c.images.isEmpty).toList();
    
    if (missingCharacters.isEmpty) {
      _log('All characters already have images');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All characters already have images'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    
    _log('Generating images for ${missingCharacters.length} missing characters...');
    
    for (int i = 0; i < missingCharacters.length; i++) {
      final character = missingCharacters[i];
      _log('Generating ${i + 1}/${missingCharacters.length}: ${character.id}');
      
      await _generateSingleCharacterImage(character);
      
      // Small delay between generations
      if (i < missingCharacters.length - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    
    _log('✅ Completed missing image generation for ${missingCharacters.length} characters');
  }

  /// Show entity image dialog with prompt editing and regeneration
  void _showEntityImageDialog(EntityData entity, String? imagePath, int imageIndex) {
    final promptController = TextEditingController(
      text: _charImagePrompts[imagePath ?? ''] ?? _buildEntityPrompt(entity),
    );
    bool isRegenerating = false;
    String? newImagePath; // Will store the path ONLY after Save & Replace
    String? newImageB64; // Store regenerated image as base64 temporarily
    String? refImagePath; // For imported reference image
    String? refImageB64; // Base64 encoded reference
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(_getEntityIcon(entity.type), color: _getEntityColor(entity.type), size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(entity.id, style: const TextStyle(fontSize: 16))),
              IconButton(
                onPressed: () async {
                  // Open entity folder
                  final appDir = await getApplicationDocumentsDirectory();
                  final entityDir = path.join(appDir.path, 'VEO3', 'entities', entity.id);
                  await Directory(entityDir).create(recursive: true);
                  if (Platform.isWindows) {
                    Process.run('explorer', [entityDir]);
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
                  // Entity type badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getEntityColor(entity.type).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      entity.type.name.toUpperCase(),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _getEntityColor(entity.type)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // Image preview
                  Container(
                    height: 200,
                    width: 350,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: newImageB64 != null
                          ? Image.memory(
                              base64Decode(newImageB64!.contains(',') ? newImageB64!.split(',').last : newImageB64!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 40),
                            )
                          : (imagePath != null && imagePath.isNotEmpty && File(imagePath).existsSync())
                              ? Image.file(
                                  File(imagePath),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 40),
                                )
                              : Container(
                                  color: Colors.grey.shade100,
                                  child: const Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
                                        SizedBox(height: 8),
                                        Text('No image yet', style: TextStyle(color: Colors.grey)),
                                        SizedBox(height: 4),
                                        Text('Generate or import below', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                      ],
                                    ),
                                  ),
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
                        InkWell(
                          onTap: () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              allowMultiple: false,
                            );
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
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: refImagePath != null ? null : Colors.grey.shade200,
                              border: Border.all(color: refImagePath != null ? Colors.blue : Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: refImagePath != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: Image.file(File(refImagePath!), fit: BoxFit.cover),
                                  )
                                : const Icon(Icons.image, size: 20, color: Colors.grey),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            refImagePath != null ? path.basename(refImagePath!) : 'Click icon to import',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis,
                          ),
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
                      onPressed: () async {
                        final hasPrompt = promptController.text.trim().isNotEmpty;
                        final hasRefImage = refImageB64 != null;
                        
                        if (!hasPrompt && !hasRefImage) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter a prompt or import a reference image')),
                          );
                          return;
                        }
                        
                        setDialogState(() => isRegenerating = true);
                        
                        try {
                          final isApiModel = _selectedImageModel?.modelType == 'api';
                          
                          if (isApiModel) {
                            // API method
                            final ok = await _ensureWhiskSession();
                            if (!ok) {
                              throw 'Could not establish API session';
                            }
                            
                            final apiModelId = _selectedImageModel?.apiModelId ?? 'IMAGEN_3_5';
                            final aspectRatio = GoogleImageApiService.convertAspectRatio('16:9');
                            
                            final response = await _googleImageApi!.generateImage(
                              prompt: promptController.text,
                              aspectRatio: aspectRatio,
                              imageModel: apiModelId,
                            );
                            
                            if (response.imagePanels.isNotEmpty && 
                                response.imagePanels.first.generatedImages.isNotEmpty) {
                              final base64Image = response.imagePanels.first.generatedImages.first.encodedImage;
                              newImageB64 = base64Image;
                              setDialogState(() => isRegenerating = false);
                              _log('✅ Entity regenerated via API');
                            } else {
                              throw 'No images returned from API';
                            }
                          } else {
                            // CDP method
                            if (_cdpHubs.isEmpty) {
                              throw 'No browsers connected';
                            }
                            
                            final hub = _cdpHubs.values.first;
                            await hub.focusChrome();
                            await hub.checkLaunchModal();
                            
                            final modelIdJs = (_selectedImageModel == null || _selectedImageModel!.url.isEmpty)
                                ? 'window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE'
                                : 'window.geminiHub.models.${_selectedImageModel!.url}';
                            
                            List<String>? refList;
                            if (refImageB64 != null) {
                              refList = [refImageB64!];
                            }
                            
                            final spawnResult = await hub.spawnImage(
                              promptController.text,
                              aspectRatio: '16:9',
                              refImages: refList,
                              model: modelIdJs,
                            );
                            
                            String? threadId;
                            if (spawnResult is Map && spawnResult.containsKey('id')) {
                              threadId = spawnResult['id']?.toString();
                            } else if (spawnResult is String && spawnResult.isNotEmpty) {
                              threadId = spawnResult;
                            }
                            
                            if (threadId == null) {
                              throw 'Invalid thread ID';
                            }
                            
                            await Future.delayed(const Duration(seconds: 2));
                            await hub.focusChrome();
                            
                            // Poll for result
                            final startPoll = DateTime.now();
                            bool completed = false;
                            while (DateTime.now().difference(startPoll).inSeconds < 180) {
                              final res = await hub.getThread(threadId);
                              
                              if (res is Map) {
                                if (res['status'] == 'COMPLETED' && res['result'] != null) {
                                  final result = res['result'];
                                  if (result is String && result.isNotEmpty) {
                                    newImageB64 = result;
                                    setDialogState(() => isRegenerating = false);
                                    _log('✅ Entity regenerated via CDP');
                                    completed = true;
                                  }
                                  break;
                                } else if (res['status'] == 'FAILED') {
                                  throw 'Generation failed';
                                }
                              }
                              
                              await Future.delayed(const Duration(seconds: 3));
                            }
                            
                            if (!completed) {
                              throw 'Timeout waiting for generation';
                            }
                          }
                        } catch (e) {
                          setDialogState(() => isRegenerating = false);
                          _log('❌ Entity regeneration error: $e');
                 ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Generation failed: $e')),
                          );
                        }
                      },
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('Regenerate', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _getEntityColor(entity.type),
                        foregroundColor: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            // Save & Replace button (only appears when there's a new image)
            if (newImageB64 != null)
              ElevatedButton.icon(
                onPressed: () async {
                  try {
                    final savedPath = await _saveEntityImage(newImageB64!, entity, promptController.text);
                    if (savedPath != null) {
                      newImagePath = savedPath;
                      _log('✅ Saved and replaced entity image');
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Image saved and replaced!'), duration: Duration(seconds: 1)),
                      );
                      Navigator.pop(ctx);
                    }
                  } catch (e) {
                    _log('Error saving entity image: $e');
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Save failed: $e')),
                    );
                  }
                },
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save & Replace'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }


  /// Character list item with popup menu for Import/Clear
  Widget _buildCharacterItem(CharacterData char, bool isActive) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? const Color(0xFF1E40AF).withOpacity(0.3) : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            // Open dialog even if no images - use a placeholder path
            final imagePath = char.images.isNotEmpty ? char.images.first : '';
            _showCharacterImageDialog(char, imagePath, 0);
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Avatar
                Stack(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF1E40AF), width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF1E40AF).withOpacity(0.2),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Builder(
                          builder: (context) {
                            // Find first existing image file
                            final firstExisting = char.images.cast<String?>().firstWhere(
                              (imgPath) => imgPath != null && File(imgPath).existsSync(),
                              orElse: () => null,
                            );
                            if (firstExisting != null) {
                              return Image.file(File(firstExisting), fit: BoxFit.cover);
                            }
                            return Container(
                              color: const Color(0xFF1E40AF).withOpacity(0.1),
                              child: Icon(Icons.person, color: const Color(0xFF1E40AF).withOpacity(0.5)),
                            );
                          },
                        ),
                      ),
                    ),
                    if (isActive)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                // Info
                Expanded(
                  child: Builder(
                    builder: (context) {
                      // Filter to only existing images for accurate count
                      final existingImages = char.images.where((imgPath) => File(imgPath).existsSync()).toList();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            char.id,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF1E293B),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isActive 
                                  ? const Color(0xFFEFF6FF)
                                  : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              isActive ? 'Active' : '${existingImages.length} img',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: isActive 
                                    ? const Color(0xFF1E40AF)
                                    : const Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                // Individual Generate Button
                IconButton(
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  color: const Color(0xFF7C3AED), // Sparkle purple
                  onPressed: () => _generateSingleCharacterImage(char),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Generate Image for ${char.id}',
                ),
                // Popup menu with Import/Clear options
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18, color: Color(0xFF64748B)),
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'import') {
                      _importImagesForCharacter(char);
                    } else if (value == 'clear') {
                      _clearImagesForCharacter(char);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'import',
                      child: Row(
                        children: [
                          Icon(Icons.add_photo_alternate, size: 16, color: Color(0xFF1E40AF)),
                          SizedBox(width: 8),
                          Text('Import', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'clear',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, size: 16, color: Color(0xFFEF4444)),
                          SizedBox(width: 8),
                          Text('Clear', style: TextStyle(fontSize: 12, color: Color(0xFFEF4444))),
                        ],
                      ),
                    ),
                ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Scenes panel - Center column
  Widget _buildScenesPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          // Scenes control header
          ScenesControlHeader(
            currentScene: _selectedSceneIndex + 1,
            totalScenes: _scenes.length,
            activeCharacters: _detectedCharsDisplay.isEmpty 
                ? [] 
                : _detectedCharsDisplay.split(', '),
            onPrevious: _selectedSceneIndex > 0 
                ? () => _onSceneChange(_selectedSceneIndex - 1) 
                : null,
            onNext: _selectedSceneIndex < _scenes.length - 1 
                ? () => _onSceneChange(_selectedSceneIndex + 1) 
                : null,
            onCopy: _copyPrompt,
          ),
          // Range and Aspect controls + Generate button
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              // Range
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Range', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: Color(0xFF64748B))),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 32,
                      child: TextField(
                        controller: _fromRangeController,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                      ),
                    ),
                    const Text('-', style: TextStyle(color: Color(0xFF94A3B8))),
                    SizedBox(
                      width: 32,
                      child: TextField(
                        controller: _toRangeController,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Aspect Ratio
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Aspect:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: Color(0xFF64748B))),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _aspectRatio,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: Colors.black87),
                        items: ['16:9', '1:1', '9:16', '4:3', '3:4'].map((a) => 
                          DropdownMenuItem(value: a, child: Text(a))
                        ).toList(),
                        onChanged: (v) => setState(() => _aspectRatio = v!),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              
              // Generate button - smaller size
              Container(
                decoration: BoxDecoration(
                  color: _cdpRunning ? const Color(0xFF1E40AF).withOpacity(0.5) : const Color(0xFF1E40AF),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF1E40AF).withOpacity(0.2), blurRadius: 4, offset: const Offset(0, 1)),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _cdpRunning ? null : _startCdpGeneration,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_cdpRunning)
                            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          else
                            const Icon(Icons.rocket_launch, size: 12, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(
                            _cdpRunning ? 'Running...' : 'Generate',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              
              // Style button - import style image
              InkWell(
                onTap: _pickStyleImage,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _styleImagePath != null ? const Color(0xFFEFF6FF) : Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _styleImagePath != null ? const Color(0xFF1E40AF) : Colors.grey.shade300,
                      width: _styleImagePath != null ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _styleImagePath != null ? Icons.check_circle : Icons.palette,
                        size: 12,
                        color: _styleImagePath != null ? const Color(0xFF1E40AF) : const Color(0xFF64748B),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Style',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: _styleImagePath != null ? const Color(0xFF1E40AF) : const Color(0xFF64748B),
                        ),
                      ),
                      if (_styleImagePath != null) ...[
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => setState(() {
                            _styleImagePath = null;
                            _uploadedStyleInput = null;
                          }),
                          child: const Icon(Icons.close, size: 12, color: Color(0xFF64748B)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              
              if (_cdpRunning)
                ElevatedButton.icon(
                  onPressed: () => setState(() => _cdpRunning = false),
                  icon: const Icon(Icons.stop, size: 14),
                  label: const Text('Stop', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
            ],
          ),
        ),
        // JSON Editor
        Expanded(
            child: Container(
              color: const Color(0xFFF8FAFC),
              child: Stack(
                children: [
                  // JSON badge
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('JSON', style: TextStyle(fontSize: 10, color: Color(0xFF64748B))),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _promptController,
                      maxLines: null,
                      expands: true,
                      style: const TextStyle(
                        fontSize: 14,
                        fontFamily: 'monospace',
                        height: 1.5,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Scene prompt...',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Generated images panel - Right column
  Widget _buildGeneratedPanel() {
    return Container(
      // width: 300, // Removed fixed width to allow expansion
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                const Icon(Icons.photo_library, size: 18, color: Color(0xFF1E40AF)),
                const SizedBox(width: 8),
                const Text('Generated', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_generatedImagePaths.length}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                ),
                if (_statsFailed > 0) ...[
                   const SizedBox(width: 12),
                   Text('Failed: $_statsFailed / Total: $_statsTotal', 
                        style: const TextStyle(fontSize: 11, color: Colors.red, fontWeight: FontWeight.bold)),
                   const SizedBox(width: 8),
                   if (!_cdpRunning)
                     TextButton.icon(
                        onPressed: () {
                           _log('🔄 Retrying ${_failedQueue.length} items...');
                           final retryItems = List<Map<String, dynamic>>.from(_failedQueue);
                           _startApiSceneGeneration(retryQueue: retryItems);
                        },
                        icon: const Icon(Icons.refresh, size: 14, color: Colors.orange),
                        label: const Text('RETRY FAILED', style: TextStyle(fontSize: 11, color: Colors.orange)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                     ),
                ],
                const Spacer(),
                // Output Folder button
                TextButton.icon(
                  onPressed: _openOutputFolder,
                  icon: const Icon(Icons.folder, size: 14, color: Color(0xFF64748B)),
                  label: const Text('Output Folder', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() => _generatedImagePaths.clear()),
                  child: const Text('CLEAR ALL', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _deleteAllGeneratedFiles,
                  icon: const Icon(Icons.delete_forever, size: 16, color: Colors.red),
                  label: const Text('DELETE ALL', style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ],
            ),
          ),
          // Image list
          Expanded(
            child: Container(
              color: const Color(0xFFF8FAFC),
              child: _generatedImagePaths.isEmpty
                  ? const Center(child: Text('No images yet', style: TextStyle(color: Color(0xFF94A3B8))))
                  : () {
                      // Extract scene number and sort numerically descending
                      final sortedPaths = List<String>.from(_generatedImagePaths);
                      sortedPaths.sort((a, b) {
                        final nameA = path.basename(a);
                        final nameB = path.basename(b);
                        
                        final matchA = RegExp(r'scene_(\d+)_').firstMatch(nameA);
                        final matchB = RegExp(r'scene_(\d+)_').firstMatch(nameB);
                        
                        final valA = int.tryParse(matchA?.group(1) ?? '0') ?? 0;
                        final valB = int.tryParse(matchB?.group(1) ?? '0') ?? 0;
                        
                        // Numeric descending sort
                        return valB.compareTo(valA);
                      });
                      
                      return GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1.75, // Perfect fit for 16:9 compact cards
                        ),
                        itemCount: sortedPaths.length,
                        itemBuilder: (context, index) {
                          final imgPath = sortedPaths[index];
                        final filename = path.basename(imgPath);
                        final match = RegExp(r'scene_(\d+)_').firstMatch(filename);
                        final sceneNo = match?.group(1) ?? '${index + 1}';
                        
                        return GeneratedImageCard(
                          imagePath: imgPath,
                          sceneNumber: (int.tryParse(sceneNo) ?? sceneNo).toString(),
                          prompt: _scenes.isNotEmpty && int.tryParse(sceneNo) != null
                              ? (_scenes[min(int.parse(sceneNo) - 1, _scenes.length - 1)]['prompt'] as String?)
                              : null,
                          duration: '2.4s',
                          onView: () => _showImagePreview(imgPath),
                          onRegenerate: (newPrompt) => _regenerateSingleScene(int.tryParse(sceneNo) ?? 0, newPrompt),
                        );
                      },
                    );
                  }(),
            ),
          ),
        ],
      ),
    );
  }

  /// Terminal panel at bottom
  Widget _buildTerminalPanel() {
    // Parse log entries
    final logText = _logController.text;
    final lines = logText.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final List<LogEntry> entries = lines.map((line) {
      final timeMatch = RegExp(r'\[(\d{2}:\d{2}:\d{2})\]').firstMatch(line);
      final time = timeMatch?.group(1) ?? '00:00:00';
      
      String level = 'INFO';
      if (line.contains('✅') || line.contains('SUCCESS')) level = 'SUCCESS';
      else if (line.contains('❌') || line.contains('ERROR')) level = 'ERROR';
      else if (line.contains('🎨') || line.contains('GEN')) level = 'GEN';
      else if (line.contains('⚠️') || line.contains('WARN')) level = 'WARN';
      
      final message = line.replaceAll(RegExp(r'\[\d{2}:\d{2}:\d{2}\]'), '').trim();
      
      return LogEntry(time: time, level: level, message: message);
    }).toList();
    
    return TerminalPanel(
      entries: entries,
      scrollController: _logScrollController,
      onClose: () => setState(() => _logCollapsed = true),
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
              const url = 'https://ai.studio/apps/drive/1Ya1yVIDQwYUszdiS9qzqS7pQvYP1_UL8?fullscreenApplet=true';
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
                  onChanged: (v) => setState(() => _selectedCharStyle = v ?? 'No Style'),
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
            value: _storyModels.any((m) => m['id'] == _selectedStoryModel) 
                ? _selectedStoryModel 
                : (_storyModels.isNotEmpty ? _storyModels[0]['id'] : null),
            isDense: true,
            decoration: const InputDecoration(labelText: 'Story Model', border: OutlineInputBorder()),
            items: _storyModels.map((m) => DropdownMenuItem(value: m['id'], child: Text(m['name']!, style: const TextStyle(fontSize: 12)))).toList(),
            onChanged: (v) => setState(() => _selectedStoryModel = v ?? 'gemini-3-flash-preview'),
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
        // Left Panel (320px) - Story Input
        Container(
          width: 320,
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            border: Border(right: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  children: [
                    const Icon(Icons.book_outlined, size: 20, color: Color(0xFF1E40AF)),
                    const SizedBox(width: 10),
                    const Text('Story Input', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1E293B), fontFamily: 'Inter')),
                    const Spacer(),
                    InkWell(
                      onTap: _showApiKeyDialog,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.key, size: 14, color: Color(0xFF64748B)),
                            const SizedBox(width: 6),
                            const Text(
                              'Gemini API',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Use Template
                      Row(
                        children: [
                          Transform.scale(
                            scale: 0.9,
                            child: Checkbox(
                              value: _useTemplate,
                              onChanged: (v) => setState(() => _useTemplate = v ?? false),
                              activeColor: const Color(0xFF1E40AF),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const Text('Use Template', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF334155), fontFamily: 'Inter')),
                        ],
                      ),
                      
                      const SizedBox(height: 12),
                      // Structure Mode
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade200),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedTemplate,
                            isExpanded: true,
                            style: const TextStyle(fontSize: 13, color: Color(0xFF334155), fontFamily: 'Inter'),
                            isDense: true,
                            items: _promptTemplates.entries.map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text((e.value['name'] as String).toUpperCase(), overflow: TextOverflow.ellipsis),
                            )).toList(),
                            onChanged: (v) => setState(() => _selectedTemplate = v!),
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 8),
                      // Model Engine
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: Colors.grey.shade200),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _selectedStoryModel,
                                  isExpanded: true,
                                  style: const TextStyle(fontSize: 13, color: Color(0xFF334155), fontFamily: 'Inter'),
                                  isDense: true,
                                  items: _storyModels.map((m) => DropdownMenuItem(
                                    value: m['id'],
                                    child: Text(m['name']!.toUpperCase()),
                                  )).toList(),
                                  onChanged: (v) => setState(() => _selectedStoryModel = v!),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFECFDF5),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.link, size: 12, color: Color(0xFF10B981)),
                                const SizedBox(width: 4),
                                Text('${_geminiApi?.keyCount ?? 0}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF10B981))),
                              ],
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 12),
                      // Prompts count and Sealed Output
                      Row(
                        children: [
                          const Text('Prompts:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B), fontFamily: 'Inter')),
                          const SizedBox(width: 8),
                          Container(
                            width: 40,
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: Colors.grey.shade200),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: TextField(
                              controller: _promptCountController,
                              textAlign: TextAlign.center,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 6)),
                            ),
                          ),
                          const Spacer(),
                          Transform.scale(
                            scale: 0.8,
                            child: Checkbox(
                              value: _useStructuredOutput,
                              onChanged: (v) => setState(() => _useStructuredOutput = v ?? true),
                              activeColor: const Color(0xFF1E40AF),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const Text('JSON Output', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF334155), fontFamily: 'Inter')),
                        ],
                      ),
                      
                      const SizedBox(height: 16),
                      
                      // Story Input Tabs
                      Row(
                        children: [
                          // Story Concept Tab
                          GestureDetector(
                            onTap: () => setState(() => _t2vStoryInputTab = 0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: _t2vStoryInputTab == 0 ? const Color(0xFF6366F1) : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: _t2vStoryInputTab == 0 ? const Color(0xFF6366F1) : const Color(0xFFE2E8F0),
                                ),
                              ),
                              child: Text(
                                'RAW STORY',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: _t2vStoryInputTab == 0 ? Colors.white : const Color(0xFF64748B),
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Raw Story Prompt Tab
                          GestureDetector(
                            onTap: () => setState(() => _t2vStoryInputTab = 1),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: _t2vStoryInputTab == 1 ? const Color(0xFF10B981) : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: _t2vStoryInputTab == 1 ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                                ),
                              ),
                              child: Text(
                                'RAW PROMPT',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: _t2vStoryInputTab == 1 ? Colors.white : const Color(0xFF64748B),
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      
                      // Paste Button for Raw Prompt (Windows workaround)
                      if (_t2vStoryInputTab == 1)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () async {
                              final data = await Clipboard.getData(Clipboard.kTextPlain);
                              if (data?.text != null) {
                                setState(() {
                                  _t2vRawPromptController.text = data!.text!;
                                });
                              }
                            },
                            icon: const Icon(Icons.content_paste, size: 14),
                            label: const Text('Paste from Clipboard', style: TextStyle(fontSize: 11)),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF10B981),
                            ),
                          ),
                        ),
                      
                      // Story Input Field (switches based on tab)
                      Container(
                        height: 160,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade200),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _t2vStoryInputTab == 0
                            ? TextField(
                                controller: _storyInputController,
                                maxLines: null,
                                expands: true,
                                textAlignVertical: TextAlignVertical.top,
                                style: const TextStyle(fontSize: 13, height: 1.5, fontFamily: 'Inter'),
                                decoration: const InputDecoration(
                                  hintText: 'Describe your story concept...',
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.all(16),
                                ),
                                onChanged: (_) => setState(() {}),
                              )
                            : TextField(
                                key: const ValueKey('raw_prompt_field'),
                                controller: _t2vRawPromptController,
                                maxLines: null,
                                expands: true,
                                textAlignVertical: TextAlignVertical.top,
                                style: const TextStyle(fontSize: 13, height: 1.5, fontFamily: 'Inter'),
                                enableInteractiveSelection: true,
                                autocorrect: false,
                                decoration: const InputDecoration(
                                  hintText: 'Paste your raw story prompts here...\n\nSupported formats:\n- JSON array of scenes\n- Plain text (one scene per line)\n- Full story text',
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.all(16),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              
              // Bottom Buttons
              Container(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text('${_storyInputController.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length} words', style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                        const SizedBox(width: 12),
                        // Copy Instruction button
                        InkWell(
                          onTap: () => _copyMasterPromptToClipboard(),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFF1E40AF).withOpacity(0.2)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.copy, size: 12, color: Color(0xFF1E40AF)),
                                SizedBox(width: 4),
                                Text('Copy Instruction', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Color(0xFF1E40AF))),
                              ],
                            ),
                          ),
                        ),
                        const Spacer(),
                        const Text('Ready', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF1E40AF))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _storyGenerating ? null : _generatePromptsFromStory,
                            icon: _storyGenerating 
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent))
                              : const Icon(Icons.auto_awesome, size: 16),
                            label: Text(_storyGenerating ? 'Generating...' : 'Generate', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF1F5F9),
                              foregroundColor: const Color(0xFF1E293B),
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        if (_storyGenerating) ...[
                          const SizedBox(width: 10),
                          ElevatedButton.icon(
                            onPressed: () => setState(() => _storyGenerating = false),
                            icon: const Icon(Icons.stop_rounded, size: 18),
                            label: const Text('Stop', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFEF4444),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        
        // Right Panel - AI Response
        Expanded(
          child: Container(
            color: Colors.white,
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.code, size: 20, color: Color(0xFF1E40AF)),
                      const SizedBox(width: 12),
                      const Text('AI Response', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF1E293B), fontFamily: 'Inter')),
                      const SizedBox(width: 10),
                      if (_rawResponse != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('${_rawResponse!.length} CHARS', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF64748B))),
                        ),
                      const Spacer(),
                      if (_rawResponse != null && _rawResponse!.isNotEmpty) ...[
                        ElevatedButton.icon(
                          onPressed: () async {
                             await Clipboard.setData(ClipboardData(text: _responseEditorController.text));
                          },
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text('Copy JSON', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF059669), foregroundColor: Colors.white, elevation: 0),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _saveGeneratedPrompts,
                          icon: const Icon(Icons.save, size: 14),
                          label: const Text('Save JSON', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E40AF), foregroundColor: Colors.white, elevation: 0),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _addToImageGeneration,
                          icon: const Icon(Icons.rocket_launch, size: 14),
                          label: const Text('Add to Studio', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F46E5), foregroundColor: Colors.white, elevation: 0),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: () => setState(() => _rawResponse = null),
                          icon: Icon(Icons.delete_outline, color: Colors.grey.shade400, size: 20),
                        ),
                      ],
                    ],
                  ),
                ),
                
                // Content area
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    color: const Color(0xFFF8FAFC),
                    child: (_rawResponse == null || _rawResponse!.isEmpty)
                      ? (_storyGenerating
                          ? _buildRawResponseView() // Show streaming/generating view
                          : Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.auto_awesome, size: 64, color: Colors.grey.shade200),
                                  const SizedBox(height: 16),
                                  const Text('AI Response will appear here', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14)),
                                ],
                              ),
                            ))
                      : _buildRawResponseView(),
                  ),
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

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          // Blue Generating Card (if active)
          if (_storyGenerating)
            Container(
              margin: const EdgeInsets.only(bottom: 24),
              height: 100,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF2563EB).withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8)),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.auto_awesome, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 20),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Generating Your Story Prompts',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, fontFamily: 'Inter'),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Agent is refining character consistency...',
                          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13, fontFamily: 'Inter'),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$generatedCount / $totalCount',
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, fontFamily: 'Inter'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          
          // JSON Output Container
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 20, offset: const Offset(0, 10)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Window Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
                  ),
                  child: Row(
                    children: [
                      _buildDot(const Color(0xFFFF5F56)),
                      const SizedBox(width: 8),
                      _buildDot(const Color(0xFFFFBD2E)),
                      const SizedBox(width: 8),
                      _buildDot(const Color(0xFF27C93F)),
                      const SizedBox(width: 20),
                      const Text(
                        'JSON OUTPUT',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF94A3B8), letterSpacing: 1.0),
                      ),
                    ],
                  ),
                ),
                // Code Area
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: _buildSyntaxHighlightedJson(_rawResponse ?? ''),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(Color color) => Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));

  Widget _buildSyntaxHighlightedJson(String json) {
    // Simple regex-based syntax highlighter to match the HTML look
    final spans = <TextSpan>[];
    
    // Split by lines to handle formatting line-by-line
    final lines = json.split('\n');
    
    for (var line in lines) {
      if (line.trim().isEmpty) {
        spans.add(const TextSpan(text: '\n'));
        continue;
      }
      
      // Regex to detect keys, strings, numbers, booleans, and punctuation
      // Note: This is a basic implementation for visual purposes
      
      String remaining = line;
      while (remaining.isNotEmpty) {
        // Match key: "key":
        final keyMatch = RegExp(r'^(\s*"[^"]+":)').firstMatch(remaining);
        if (keyMatch != null) {
           spans.add(TextSpan(text: keyMatch.group(1), style: const TextStyle(color: Color(0xFF2563EB)))); // Blue 600
           remaining = remaining.substring(keyMatch.group(0)!.length);
           continue;
        }
        
        // Match string value: "value"
        final strMatch = RegExp(r'^(\s*"[^"]*")').firstMatch(remaining);
        if (strMatch != null) {
           spans.add(TextSpan(text: strMatch.group(1), style: const TextStyle(color: Color(0xFF059669)))); // Emerald 600
           remaining = remaining.substring(strMatch.group(0)!.length);
           continue;
        }
        
        // Match numbers, booleans, null
         final primitiveMatch = RegExp(r'^(\s*(true|false|null|\d+(\.\d+)?))').firstMatch(remaining);
        if (primitiveMatch != null) {
           spans.add(TextSpan(text: primitiveMatch.group(1), style: const TextStyle(color: Color(0xFFD97706)))); // Amber 600
           remaining = remaining.substring(primitiveMatch.group(0)!.length);
           continue;
        }

        // Match braces/brackets/commas
        final puncMatch = RegExp(r'^(\s*[{},\[\]])').firstMatch(remaining);
        if (puncMatch != null) {
           spans.add(TextSpan(text: puncMatch.group(1), style: const TextStyle(color: Color(0xFFA855F7)))); // Purple 500
           remaining = remaining.substring(puncMatch.group(0)!.length);
           continue;
        }
        
        // Fallback for whitespace or other chars
        if (remaining.isNotEmpty) {
           spans.add(TextSpan(text: remaining[0], style: const TextStyle(color: Color(0xFF1E293B))));
           remaining = remaining.substring(1);
        }
      }
      spans.add(const TextSpan(text: '\n'));
    }

    return SelectableText.rich(
      TextSpan(
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.6),
        children: spans,
      ),
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
                  if (mounted && (_storyGenerating || _t2vGenerating)) {
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

  /// Copy the fully processed master prompt to clipboard (for use in aistudio.google.com)
  Future<void> _copyMasterPromptToClipboard() async {
    // Get input text from the active tab (Story or Raw Prompts)
    final inputText = _t2vStoryInputTab == 0 
        ? _storyInputController.text 
        : _t2vRawPromptController.text;
    
    if (inputText.trim().isEmpty) {
      final message = _t2vStoryInputTab == 0
          ? 'Please enter a story concept first'
          : 'Please paste your raw story prompts first';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.orange),
      );
      return;
    }
    
    final promptCount = int.tryParse(_promptCountController.text) ?? 10;
    String finalPrompt;
    
    if (_useTemplate) {
      // Build prompt using selected template
      final template = _promptTemplates[_selectedTemplate]!;
      finalPrompt = (template['prompt'] as String)
          .replaceAll('[STORY_TEXT]', inputText)
          .replaceAll('[SCENE_COUNT]', promptCount.toString());
      
      // If structured output is enabled, append the schema
      if (_useStructuredOutput && template.containsKey('schema')) {
        final schema = template['schema'];
        final schemaJson = const JsonEncoder.withIndent('  ').convert(schema);
        finalPrompt += '\n\n---\n\n**JSON Schema (for Structured Output):**\n\n```json\n$schemaJson\n```\n\n**Instructions for AI Studio:**\n1. Paste the prompt above into the prompt field\n2. Enable "JSON mode" or "Structured Output" if available\n3. Use the schema above to configure the expected JSON structure\n4. Generate the response';
      }
    } else {
      // No template - use raw input as prompt
      finalPrompt = inputText;
    }
    
    await Clipboard.setData(ClipboardData(text: finalPrompt));
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _useStructuredOutput 
                      ? 'Instruction + Schema copied! Paste it in aistudio.google.com'
                      : 'Instruction copied! Paste it in aistudio.google.com',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF16A34A),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
  
  Future<void> _generatePromptsFromStory() async {
    print('[DEBUG] _generatePromptsFromStory called');
    
    // Check which tab is active
    final inputText = _t2vStoryInputTab == 0 
        ? _storyInputController.text 
        : _t2vRawPromptController.text;
    
    if (inputText.trim().isEmpty) {
      final message = _t2vStoryInputTab == 0
          ? 'Please enter a story concept first'
          : 'Please paste your raw story prompts first';
      _log('⚠️ $message');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.orange),
      );
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
    final storyText = inputText; // Use the active tab's input
    
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

  // ====================== VIDEO GENERATION WORKERS ======================

  Future<void> _stopVideoGeneration() async {
    _log('🛑 Video generation stopping...');
    VideoGenerationService().stop();
  }

  Future<void> _startVideoGeneration() async {
    if (_generatedImagePaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please generate images first')),
      );
      return;
    }

    // Connect to browsers if not connected
    final connectedCount = widget.profileManager?.countConnectedProfiles() ?? 0;
    if (connectedCount == 0) {
      _log('📡 No browsers connected, attempting to connect...');
      final connected = await _connectAllBrowsers();
      if (connected == 0) {
        _log('❌ No browsers found. Please open Chrome with remote debugging.');
        return;
      }
    }

    setState(() {
      _videoGenerationRunning = true;
      _videoGenerationPaused = false;
      _consecutiveFailures = 0;
      
      // Initialize _videoScenes from _generatedImagePaths
      _videoScenes = _sortedVideoImagePaths.asMap().entries.map((entry) {
        final index = entry.key;
        final imagePath = entry.value;
        
        // Check if we have existing state for this image
        if (_videoSceneStates.containsKey(imagePath)) {
          final existingState = _videoSceneStates[imagePath]!;
          // Only queue if not completed, or if failed/generating from previous run
          if (existingState.status != 'completed') {
            existingState.status = 'queued';
          }
          return existingState;
        } else {
          // Create new scene data
          final newScene = SceneData(
            sceneId: index + 1,
            prompt: _scenes.length > index ? _scenes[index]['prompt'] ?? '' : 'Scene ${index + 1}',
            firstFramePath: imagePath,
            status: 'queued',
            aspectRatio: _videoSelectedAspectRatio,
          );
          _videoSceneStates[imagePath] = newScene;
          return newScene;
        }
      }).toList();
      
      // Save initial states
      _saveVideoSceneStates();
    });

    _log('🎬 Offloading batch generation to VideoGenerationService (${_videoScenes.length} scenes)');
    
    try {
      await VideoGenerationService().startBatch(
        _videoScenes,
        model: _videoSelectedModel,
        aspectRatio: _videoSelectedAspectRatio,
        maxConcurrentOverride: 4,
      );
    } catch (e) {
      _log('❌ Start failed: $e');
    } finally {
      if (mounted) {
        setState(() => _videoGenerationRunning = VideoGenerationService().isRunning);
      }
    }
  }

  Future<void> _generateSingleVideo(int index) async {
    if (_generatedImagePaths.isEmpty) return;

    // Connect to browsers if not connected
    final connectedCount = widget.profileManager?.countConnectedProfiles() ?? 0;
    if (connectedCount == 0) {
      _log('📡 No browsers connected, attempting to connect...');
      final connected = await _connectAllBrowsers();
      if (connected == 0) {
        _log('❌ No browsers found. Please open Chrome with remote debugging.');
        return;
      }
    }

    if (_videoScenes.isEmpty) {
      // Initialize if empty
      setState(() {
        _videoScenes = _sortedVideoImagePaths.asMap().entries.map((entry) {
          final idx = entry.key;
          final path = entry.value;
          return SceneData(
            sceneId: idx + 1,
            prompt: _scenes.length > idx ? _scenes[idx]['prompt'] ?? '' : 'Scene ${idx + 1}',
            firstFramePath: path,
            status: 'queued',
          );
        }).toList();
      });
    }

    final scene = _videoScenes[index];
    if (scene.status == 'generating' || scene.status == 'polling' || scene.status == 'downloading') {
      return;
    }

    setState(() {
      scene.status = 'queued';
      scene.error = null;
      _videoGenerationRunning = true;
    });

    _log('🎬 Starting single video generation for Scene ${scene.sceneId}');
    
    // Process only this single scene
    await _processSingleScene(scene);
  }

  /// Process a single scene (for individual generation)
  Future<void> _processSingleScene(SceneData scene) async {
    try {
      _log('[SINGLE] Offloading single scene generation to VideoGenerationService');
      
      // Reset status for this scene
      setState(() {
        scene.status = 'queued';
        scene.error = null;
        _saveVideoSceneStates();
      });
      
      // Start batch with just this scene
      await VideoGenerationService().startBatch(
        [scene],
        model: _videoSelectedModel,
        aspectRatio: _videoSelectedAspectRatio,
      );
      
    } catch (e) {
      _log('❌ Single video error: $e');
      setState(() {
        scene.status = 'failed';
        scene.error = e.toString();
        _videoGenerationRunning = false;
      });
    }
  }

  // Track if polling worker is running
  bool _pollingWorkerRunning = false;

  /// Poll a single scene for completion (removed - using main polling worker instead)

  Future<void> _multiProfileVideoWorker() async {
    try {
      // Skip already completed videos - only process queued or failed
      final completedCount = _videoScenes.where((s) => s.status == 'completed').length;
      final scenesToProcess = _videoScenes.where((s) => s.status == 'queued' || s.status == 'failed').toList();
      
      if (completedCount > 0) {
        _log('⏭️ Skipping $completedCount already completed video(s)');
      }
      
      if (scenesToProcess.isEmpty) {
        _log('✅ All videos already completed!');
        setState(() => _videoGenerationRunning = false);
        return;
      }

      _log('🎬 Starting batch generation for ${scenesToProcess.length} scene(s)');

      // Reset concurrent state
      _activeGenerationsCount = 0;
      _pendingPolls.clear();
      _generationComplete = false;

      // Start Polling Worker
      _pollVideoWorker();

      // Concurrency settings
      final isRelaxed = _videoSelectedModel.toLowerCase().contains('relaxed') || 
                        _videoSelectedModel.toLowerCase().contains('lower priority');
      final maxConcurrent = isRelaxed ? _maxConcurrentRelaxed : _maxConcurrentFast;
      
      _log('🚀 [Video] Concurrent mode active (Max: $maxConcurrent, Relaxed: $isRelaxed)');

      // Process queue
      await _processVideoQueue(scenesToProcess, maxConcurrent);

      _generationComplete = true;

      // Wait for polls
      while (_pendingPolls.isNotEmpty || _activeGenerationsCount > 0) {
        await Future.delayed(const Duration(seconds: 2));
      }

      _log('✅ Video generation complete');
    } catch (e) {
      _log('❌ Fatal video error: $e');
    } finally {
      if (mounted) setState(() => _videoGenerationRunning = false);
    }
  }

  Future<void> _processVideoQueue(List<SceneData> scenesToProcess, int maxConcurrent) async {
    for (var i = 0; i < scenesToProcess.length; i++) {
      if (!_videoGenerationRunning) break;
      while (_videoGenerationPaused) await Future.delayed(const Duration(milliseconds: 500));

      // Wait for slot
      while (_activeGenerationsCount >= maxConcurrent && _videoGenerationRunning) {
        await Future.delayed(const Duration(seconds: 1));
      }

      final scene = scenesToProcess[i];
      final profile = widget.profileManager?.getNextAvailableProfile();

      if (profile == null) {
        await Future.delayed(const Duration(seconds: 2));
        i--; continue;
      }

      try {
        await _generateVideoWithProfile(scene, profile);
      } on _RetryableException catch (e) {
        scene.retryCount++;
        if (scene.retryCount < 10) {
          _log('🔄 Retrying ${scene.sceneId} (${scene.retryCount}/10): ${e.message}');
          setState(() => scene.status = 'queued');
          scenesToProcess.insert(i + 1, scene);
        } else {
          setState(() {
            scene.status = 'failed';
            scene.error = 'Max retries: ${e.message}';
          });
        }
      } catch (e) {
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
      }
    }
  }

  /// Upload image via HTTP (matches video_generation_service.dart implementation)
  Future<String?> _uploadImageHTTP(String imagePath, String accessToken) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final b64 = base64Encode(bytes);
      final mime = imagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      
      final aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE';

      final payload = jsonEncode({
        'imageInput': {
          'rawImageBytes': b64, 
          'mimeType': mime, 
          'isUserUploaded': true,
          'aspectRatio': aspectRatio
        },
        'clientContext': {
          'sessionId': ';${DateTime.now().millisecondsSinceEpoch}', 
          'tool': 'ASSET_MANAGER'
        }
      });

      final res = await _dio.post('https://aisandbox-pa.googleapis.com/v1:uploadUserImage', 
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'text/plain;charset=UTF-8'}));

      if (res.statusCode == 200) {
        final data = res.data is String ? jsonDecode(res.data) : res.data;
        final mediaId = data['mediaGenerationId']?['mediaGenerationId'] ?? data['mediaId'];
        if (mediaId != null) {
          _log('[UPLOAD] ✅ Image uploaded: ${path.basename(imagePath)}');
          return mediaId as String?;
        }
      }
    } catch (e) {
      _log('[UPLOAD] ❌ Error: $e');
    }
    return null;
  }

  Future<void> _generateVideoWithProfile(SceneData scene, dynamic profile) async {
    _activeGenerationsCount++;
    setState(() {
      scene.status = 'generating';
      // Update state map
      if (scene.firstFramePath != null) {
        _videoSceneStates[scene.firstFramePath!] = scene;
      }
    });

    try {
      // Connect generator if needed
      if (profile.generator == null) {
        _log('[GEN] 🔌 Creating new generator for ${profile.name} on port ${profile.debugPort}...');
        try {
          profile.generator = DesktopGenerator(debugPort: profile.debugPort);
          await profile.generator!.connect();
          profile.status = ProfileStatus.connected;
          _log('[GEN] ✓ Generator connected for ${profile.name}');
        } catch (e) {
          _log('[GEN] ❌ Failed to connect generator: $e');
          throw Exception('Failed to connect generator: $e');
        }
      } else {
        _log('[GEN] ✓ Reusing existing generator for ${profile.name}');
      }
      
      // Get access token if needed
      if (profile.accessToken == null) {
        _log('[GEN] 🔑 Fetching access token for ${profile.name}...');
        try {
          profile.accessToken = await profile.generator!.getAccessToken();
          if (profile.accessToken == null) {
            _log('[GEN] ❌ getAccessToken() returned null');
            throw Exception('Failed to get access token - returned null');
          }
          _log('[GEN] ✓ Got access token for ${profile.name}: ${profile.accessToken!.substring(0, 50)}...');
        } catch (e) {
          _log('[GEN] ❌ Exception while fetching token: $e');
          throw Exception('Failed to get access token: $e');
        }
      } else {
        _log('[GEN] ✓ Using existing token for ${profile.name}: ${profile.accessToken!.substring(0, 50)}...');
      }

      // Upload image using HTTP method (matches video_generation_service.dart)
      if (scene.firstFramePath != null && scene.firstFrameMediaId == null) {
        _log('[GEN] 📤 Uploading first frame image...');
        scene.firstFrameMediaId = await _uploadImageHTTP(scene.firstFramePath!, profile.accessToken!);
        if (scene.firstFrameMediaId == null) {
          _activeGenerationsCount--;
          throw _RetryableException('Failed to upload first frame image');
        }
        _log('[GEN] ✅ First frame uploaded: ${scene.firstFrameMediaId}');
      }

      // Map UI model name to API key
      // Map UI model name to API key
      String apiModel = 'veo_3_1_t2v_fast_ultra_relaxed';
      
      final isVeo2 = _videoSelectedModel.contains('Veo 2');
      final isQuality = _videoSelectedModel.contains('Quality');
      final isRelaxed = _videoSelectedModel.contains('Lower Priority') || _videoSelectedModel.contains('relaxed');
      
      if (isVeo2) {
        if (isQuality) {
          apiModel = isRelaxed ? 'veo_2_t2v_quality_relaxed' : 'veo_2_t2v_quality';
        } else {
          apiModel = isRelaxed ? 'veo_2_t2v_fast_relaxed' : 'veo_2_t2v_fast';
        }
      } else {
        // Veo 3.1
        if (isQuality) {
          apiModel = isRelaxed ? 'veo_3_1_t2v_quality_ultra_relaxed' : 'veo_3_1_t2v_quality_ultra';
        } else {
          apiModel = isRelaxed ? 'veo_3_1_t2v_fast_ultra_relaxed' : 'veo_3_1_t2v_fast_ultra';
        }
      }

      // CRITICAL: Convert t2v models to i2v_s when using first frames
      // This matches the video_generation_service.dart implementation
      if (scene.firstFrameMediaId != null && apiModel.contains('t2v')) {
        apiModel = apiModel.replaceAll('t2v', 'i2v_s');
        _log('🔄 Converted model to I2V: $apiModel');
      }

      // CRITICAL: Get fresh reCAPTCHA token (required for generation)
      // This matches video_generation_service.dart implementation
      String? recaptchaToken;
      _log('[GEN] 🔑 Fetching reCAPTCHA token...');
      try {
        recaptchaToken = await profile.generator!.getRecaptchaToken();
        if (recaptchaToken == null || recaptchaToken.length < 20) {
          throw Exception('Invalid reCAPTCHA token');
        }
        _log('[GEN] ✅ reCAPTCHA token obtained');
      } catch (e) {
        _log('[GEN] ❌ Failed to get reCAPTCHA token: $e');
        _activeGenerationsCount--;
        throw _RetryableException('Failed to get reCAPTCHA token: $e');
      }

      final result = await profile.generator!.generateVideo(
        prompt: scene.prompt,
        accessToken: profile.accessToken!,
        aspectRatio: _videoSelectedAspectRatio,
        model: apiModel,
        startImageMediaId: scene.firstFrameMediaId,
        recaptchaToken: recaptchaToken,
      );

      if (result == null || result['success'] != true) {
        final statusCode = result?['status'] as int? ?? 0;
        if (statusCode == 403) {
          profile.consecutive403Count++;
          if (profile.consecutive403Count >= 7 && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty && widget.loginService != null) {
             _log('⚠️ Profile ${profile.name} hit 7x 403. Attempting auto-relogin...');
             await widget.loginService!.reloginProfile(profile, _savedEmail, _savedPassword);
             profile.consecutive403Count = 0;
             // Update token after relogin
             profile.accessToken = await profile.generator?.getAccessToken();
          } else if (profile.consecutive403Count >= 7) {
             _log('⚠️ Profile ${profile.name} hit 7x 403. Manual relogin required.');
          }
        }
        _activeGenerationsCount--;
        throw _RetryableException(result?['error'] ?? 'API Error');
      }

      // Parse operation name from response
      // Response structure: {"operations":[{"operation":{"name":"..."},"sceneId":"...","status":"..."}]}
      final operations = result['data'] ?? result; // Handle both wrapped and unwrapped responses
      final opName = operations['operations'][0]['operation']['name'] as String;
      scene.operationName = opName;
      setState(() {
        scene.status = 'polling';
        // Update state map
        if (scene.firstFramePath != null) {
          _videoSceneStates[scene.firstFramePath!] = scene;
        }
      });
      _pendingPolls.add(_PendingPoll(scene, opName, DateTime.now()));
      profile.consecutive403Count = 0;

    } catch (e) {
      _activeGenerationsCount--;
      rethrow;
    }
  }

  Future<void> _pollVideoWorker() async {
    _pollingWorkerRunning = true;
    _log('[POLLER] Polling worker started');
    
    try {
      const pollInterval = 5; // Fixed 5 second interval like main.dart
      
      while (_videoGenerationRunning || _pendingPolls.isNotEmpty) {
        // Check if we should stop polling (no pending polls and no connected profiles)
        if (_pendingPolls.isEmpty) {
          final hasConnectedProfiles = widget.profileManager?.profiles.any((p) => p.status == ProfileStatus.connected) ?? false;
          if (!hasConnectedProfiles || !_videoGenerationRunning) {
            _log('[POLLER] No pending polls and no active generation - stopping');
            break;
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        _log('[POLLER] Monitoring ${_pendingPolls.length} active videos... (Next check in ${pollInterval}s)');

        try {
          final validPolls = _pendingPolls.where((p) => p.scene.operationName != null).toList();
          if (validPolls.isEmpty) {
            _log('[POLLER] No valid polls (all have null operationName)');
            await Future.delayed(Duration(seconds: pollInterval));
            continue;
          }

          final pollRequests = validPolls.map((p) => PollRequest(p.scene.operationName!, p.sceneUuid)).toList();
        
        // Find any connected generator with token
        dynamic poller;
        String? token;
        for (final p in widget.profileManager!.profiles) {
          if (p.status == ProfileStatus.connected && p.generator != null && p.accessToken != null) {
            poller = p.generator;
            token = p.accessToken;
            break;
          }
        }

        if (poller == null) {
          _log('[POLLER] No connected browser with token - skipping poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        _log('[POLLER] Calling pollVideoStatusBatch with ${pollRequests.length} requests...');
        final results = await poller.pollVideoStatusBatch(pollRequests, token!);
        
        if (results == null || results.isEmpty) {
          _log('[POLLER] No results from batch poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        final completedIndices = <int>[];
        for (final result in results) {
          // Get operation name from response
          String? opName;
          if (result.containsKey('operation') && result['operation'] is Map) {
            opName = (result['operation'] as Map)['name'] as String?;
          }
          
          final sceneIdValue = result['sceneId'];
          final resultSceneId = sceneIdValue?.toString();
          
          // Find matching pending poll
          int pollIndex = -1;
          if (opName != null) {
            pollIndex = _pendingPolls.indexWhere((p) => p.scene.operationName == opName);
          }
          if (pollIndex == -1 && resultSceneId != null) {
            pollIndex = _pendingPolls.indexWhere((p) => p.sceneUuid == resultSceneId);
          }
          
          if (pollIndex == -1) {
            _log('[POLLER] Poll result for unknown operation: opName=$opName, sceneId=$resultSceneId');
            continue;
          }
          
          final poll = _pendingPolls[pollIndex];
          final scene = poll.scene;
          
          final status = result['status'] as String?;
          _log('[POLLER] Scene ${scene.sceneId}: status=$status');

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' || status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
             _activeGenerationsCount--;
             _log('[SLOT] Video ready, freed slot - Active: $_activeGenerationsCount');
             
             // Extract video URL from metadata (exact code from main.dart)
             String? videoUrl;
             String? videoMediaId;
             
             if (result.containsKey('operation')) {
               final op = result['operation'] as Map<String, dynamic>;
               final metadata = op['metadata'] as Map<String, dynamic>?;
               final video = metadata?['video'] as Map<String, dynamic>?;
               videoUrl = video?['fifeUrl'] as String?;
               
               // Extract mediaId for upscaling
               final mediaGenId = video?['mediaGenerationId'];
               if (mediaGenId != null) {
                 if (mediaGenId is Map) {
                   videoMediaId = mediaGenId['mediaGenerationId'] as String?;
                 } else if (mediaGenId is String) {
                   videoMediaId = mediaGenId;
                 }
               }
             }

             if (videoUrl != null) {
               _log('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
               if (videoMediaId != null) {
                 _log('[POLLER] Video MediaId: $videoMediaId (saved for upscaling)');
                 scene.videoMediaId = videoMediaId;
                 scene.downloadUrl = videoUrl;
               }
               _downloadVideoLogic(scene, videoUrl);
             } else {
               _log('[POLLER] ERROR: Could not extract fifeUrl from operation.metadata.video');
               setState(() {
                 scene.status = 'failed';
                 scene.error = 'No video URL in response';
               });
             }
             
             completedIndices.add(pollIndex);
             
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
             _activeGenerationsCount--;
             scene.retryCount++;
             if (scene.retryCount < 10) {
               _log('[RETRY] Scene ${scene.sceneId} poll failed (${scene.retryCount}/10)');
               setState(() {
                 scene.status = 'queued';
                 scene.operationName = null;
                 scene.error = 'Retrying (${scene.retryCount}/10)';
               });
             } else {
               setState(() {
                 scene.status = 'failed';
                 scene.error = 'Failed after 10 retries';
               });
             }
             completedIndices.add(pollIndex);
          }
        }

        for (final idx in completedIndices.reversed) _pendingPolls.removeAt(idx);
      } catch (e) {
        _log('[POLLER] Error: $e');
      }
      
      // Wait 5 seconds before next poll - CRITICAL!
      await Future.delayed(Duration(seconds: pollInterval));
    }
    } catch (e) {
      _log('[POLLER] Fatal error: $e');
    } finally {
      _pollingWorkerRunning = false;
      _log('[POLLER] Polling worker stopped');
    }
  }

  Future<void> _downloadVideoLogic(SceneData scene, String url) async {
    setState(() {
      scene.status = 'downloading';
      // Update state map
      if (scene.firstFramePath != null) {
        _videoSceneStates[scene.firstFramePath!] = scene;
      }
    });
    try {
      dynamic loader;
      for (final p in widget.profileManager!.profiles) {
        if (p.generator != null) { loader = p.generator; break; }
      }
      
      // Use projectService for consistent path generation (same as main.dart)
      final outputPath = await widget.projectService.getVideoOutputPath(
        null,
        scene.sceneId,
        isQuickGenerate: false,
      );
      final size = await loader.downloadVideo(url, outputPath);
      
      setState(() {
        scene.status = 'completed';
        scene.videoPath = outputPath;
        scene.fileSize = size;
        scene.generatedAt = DateTime.now().toIso8601String();
        
        // Update the state map if this scene has a firstFramePath
        if (scene.firstFramePath != null) {
          _videoSceneStates[scene.firstFramePath!] = scene;
        }
      });
      
      _log('✅ Downloaded Scene ${scene.sceneId}: $outputPath');
      
      // Save state after successful download
      await _saveVideoSceneStates();
      
      // Auto-save project
      await _autoSaveProject();
    } catch (e) {
      setState(() {
        scene.status = 'failed';
        scene.error = 'Download failed: $e';
      });
    }
  }
  
  void _playVideo(String videoPath) async {
    try {
      if (!await File(videoPath).exists()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video file not found')),
        );
        return;
      }
      
      _log('▶️ Playing video inline: ${path.basename(videoPath)}');
      
      // Dispose previous player if exists
      _inlineVideoPlayer?.dispose();
      
      // Create new player for inline playback
      final player = Player();
      final controller = VideoController(player);
      
      // Listen for video completion to auto-stop
      player.stream.completed.listen((completed) {
        if (completed) {
          _log('✓ Video playback completed');
          _stopInlineVideo();
        }
      });
      
      setState(() {
        _playingVideoPath = videoPath;
        _inlineVideoPlayer = player;
        _inlineVideoController = controller;
      });
      
      // Open video
      await player.open(Media('file:///$videoPath'));
    } catch (e) {
      _log('❌ Failed to play video: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to play video: $e')),
      );
    }
  }
  
  void _stopInlineVideo() {
    _inlineVideoPlayer?.dispose();
    setState(() {
      _playingVideoPath = null;
      _inlineVideoPlayer = null;
      _inlineVideoController = null;
    });
  }

  bool _canAddToMastering() {
    // Check if there are any videos (completed or already downloaded)
    return _videoSceneStates.values.any((scene) {
      // Check if video is completed and exists
      if (scene.status == 'completed' && scene.videoPath != null && File(scene.videoPath!).existsSync()) {
        return true;
      }
      // Check if video exists locally (already downloaded)
      if (scene.videoPath != null && File(scene.videoPath!).existsSync()) {
        return true;
      }
      return false;
    });
  }
  
  int _getAvailableVideoCount() {
    return _videoSceneStates.values.where((scene) => 
      scene.videoPath != null && File(scene.videoPath!).existsSync()
    ).length;
  }
  
  int _getTotalVideoScenes() {
    return _videoSceneStates.length;
  }

  void _addClipsToMastering() async {
    print('[SceneBuilder] Starting _addClipsToMastering...');
    
    // Collect ALL available videos (completed, downloaded, or existing locally)
    final availableClips = <Map<String, dynamic>>[];
    
    // Sort by scene number
    final sortedPaths = List<String>.from(_generatedImagePaths);
    sortedPaths.sort((a, b) {
      final matchA = RegExp(r'scene_(\d+)_').firstMatch(path.basename(a));
      final matchB = RegExp(r'scene_(\d+)_').firstMatch(path.basename(b));
      final numA = int.tryParse(matchA?.group(1) ?? '9999') ?? 9999;
      final numB = int.tryParse(matchB?.group(1) ?? '9999') ?? 9999;
      return numA.compareTo(numB);
    });
    
    print('[SceneBuilder] Found ${sortedPaths.length} image paths, checking ${_videoSceneStates.length} scene states');
    
    for (final imgPath in sortedPaths) {
      if (_videoSceneStates.containsKey(imgPath)) {
        final scene = _videoSceneStates[imgPath]!;
        print('[SceneBuilder] Checking scene: ${path.basename(imgPath)}, videoPath: ${scene.videoPath}, exists: ${scene.videoPath != null ? File(scene.videoPath!).existsSync() : false}');
        
        // Check if video file exists (any status)
        if (scene.videoPath != null && File(scene.videoPath!).existsSync()) {
          // Add to list - duration will be detected in parallel below
          availableClips.add({
            'filePath': scene.videoPath!,
            'duration': 5.0, // Placeholder, will be updated with parallel detection
            'prompt': scene.prompt,
            'sceneData': scene.toJson(), // Include full scene data
            '_imgPath': imgPath, // Keep reference for logging
          });
        }
      }
    }
    
    // PARALLEL duration detection - much faster than sequential
    if (availableClips.isNotEmpty) {
      print('[SceneBuilder] Detecting durations for ${availableClips.length} videos in parallel...');
      
      final durationFutures = availableClips.map((clip) async {
        try {
          // Use MediaDurationHelper (native APIs) instead of ffprobe
          final duration = await MediaDurationHelper.getVideoDuration(clip['filePath'] as String);
          return duration ?? 5.0;
        } catch (e) {
          return 5.0;
        }
      }).toList();
      
      final durations = await Future.wait(durationFutures);
      
      // Update clips with detected durations
      for (int i = 0; i < availableClips.length; i++) {
        availableClips[i]['duration'] = durations[i];
        print('[SceneBuilder] Detected duration for ${path.basename(availableClips[i]['filePath'] as String)}: ${durations[i].toStringAsFixed(2)}s');
      }
      
      print('[SceneBuilder] Parallel duration detection complete!');
    }
    
    print('[SceneBuilder] Collected ${availableClips.length} available clips');
    
    if (availableClips.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No videos available to add')),
      );
      return;
    }
    
    // Prepare full JSON output with all scene data and prompts
    final fullProjectJson = {
      'prompts': _generatedPrompts,
      'scenes': availableClips,
      'character_reference': _currentProject?.characterData,
      'story_input': _storyInputController.text,
      'video_model': _videoSelectedModel,
      'aspect_ratio': _videoSelectedAspectRatio,
      'project_name': _currentProject?.name,
    };
    
    // Extract background music prompt from JSON or story
    String bgMusicPrompt = '';
    
    // Try to extract from generated prompts if available
    if (_generatedPrompts.isNotEmpty && _generatedPrompts.first.containsKey('background_music')) {
      final bgMusic = _generatedPrompts.first['background_music'];
      if (bgMusic is Map && bgMusic.containsKey('prompt')) {
        bgMusicPrompt = bgMusic['prompt'] as String;
      } else if (bgMusic is String) {
        bgMusicPrompt = bgMusic;
      }
    }
    
    // Fallback to story input if no music prompt found
    if (bgMusicPrompt.isEmpty && _storyInputController.text.isNotEmpty) {
      bgMusicPrompt = 'Create background music for: ${_storyInputController.text}';
    }
    
    // Call the onAddToVideoGen callback if provided, otherwise navigate
    if (widget.onAddToVideoGen != null) {
      print('[SceneBuilder] Calling onAddToVideoGen callback with ${availableClips.length} clips');
      
      widget.onAddToVideoGen!({
        'action': 'add_to_mastering',
        'clips': availableClips,
        'bgMusicPrompt': bgMusicPrompt,
        'fullJson': fullProjectJson,
      });
      
      // Show confirmation
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sending ${availableClips.length} clip(s) to Mastering tab...')),
      );
    } else {
      print('[SceneBuilder] Navigating to VideoMasteringScreen with ${availableClips.length} clips');
      
      // Navigate to mastering screen with clips and full JSON
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => VideoMasteringScreen(
            projectService: widget.projectService,
            isActivated: widget.isActivated,
            initialClips: availableClips,
            bgMusicPrompt: bgMusicPrompt,
            fullProjectJson: fullProjectJson,
          ),
        ),
      );
    }
  }

  void _showControlsDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 600,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6366F1), Color(0xFF818CF8)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.settings, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Generation Controls',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close, color: Color(0xFF64748B)),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              
              // Control Panel Content (Browser controls, model, etc.)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Browser controls row
                    Row(
                      children: [
                        const Text('Browser:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 80,
                          height: 36,
                          child: TextField(
                            controller: TextEditingController(text: _profileCountController.text),
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFF1E40AF)),
                              ),
                            ),
                            onChanged: (value) {
                              final num = int.tryParse(value);
                              if (num != null && num > 0) {
                                _profileCountController.text = num.toString();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton.icon(
                          onPressed: () {
                            // Launch browsers - placeholder for actual implementation
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Browser launch functionality available in main controls')),
                            );
                          },
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('Open'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            // Connect to browsers - placeholder for actual implementation
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Browser connection functionality available in main controls')),
                            );
                          },
                          icon: const Icon(Icons.link, size: 16),
                          label: const Text('Connect'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF3B82F6),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Browser status
                    Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Browser controls in main panel',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'Profiles: ${_profileCountController.text}',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                    
                    const Divider(height: 32),
                    
                    // Model & Settings
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Video Model:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFFE2E8F0)),
                                ),
                                child: Text(
                                  _videoSelectedModel,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Aspect Ratio:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFFE2E8F0)),
                                ),
                                child: Text(
                                  _videoSelectedAspectRatio,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Additional settings
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Delay (ms):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 36,
                                child: TextField(
                                  controller: _delayController,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: Color(0xFF1E40AF)),
                                    ),
                                  ),
                                  onChanged: (value) {
                                    final num = int.tryParse(value);
                                    if (num != null && num >= 0) {
                                      _delayController.text = num.toString();
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Retry:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 36,
                                child: TextField(
                                  controller: _retriesController,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: Color(0xFF1E40AF)),
                                    ),
                                  ),
                                  onChanged: (value) {
                                    final num = int.tryParse(value);
                                    if (num != null && num >= 0) {
                                      _retriesController.text = num.toString();
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 20),
              
              // Close button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E40AF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Done', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
  bool shouldRepaint(_FlyingBirdPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue;
  }
}

/// Video Player Dialog Widget for in-app video playback
class _VideoPlayerDialog extends StatefulWidget {
  final String videoPath;
  
  const _VideoPlayerDialog({required this.videoPath});
  
  @override
  State<_VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<_VideoPlayerDialog> {
  late final player = Player();
  late final controller = VideoController(player);
  
  @override
  void initState() {
    super.initState();
    player.open(Media('file:///${widget.videoPath}'));
  }
  
  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 1200,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              color: Colors.grey.shade900,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.play_circle, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      path.basename(widget.videoPath),
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Video Player
            Expanded(
              child: Video(
                controller: controller,
                controls: MaterialVideoControls,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pending Poll for video generation
class _PendingPoll {
  final SceneData scene;
  final String sceneUuid;
  final DateTime startTime;

  _PendingPoll(this.scene, this.sceneUuid, this.startTime);
}

/// Generic exception for retryable errors
class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);
  @override
  String toString() => message;
}
