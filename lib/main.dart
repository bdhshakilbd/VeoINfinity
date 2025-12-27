import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'models/scene_data.dart';
import 'models/project_data.dart';
import 'services/browser_video_generator.dart';
import 'services/project_service.dart';
import 'services/auth_service.dart';
import 'services/profile_manager_service.dart';
import 'services/multi_profile_login_service.dart';
import 'utils/prompt_parser.dart';
import 'utils/config.dart';
import 'utils/video_export_helper.dart';
import 'widgets/scene_card.dart';
import 'services/log_service.dart';
import 'widgets/profile_manager_widget.dart';
import 'widgets/queue_controls.dart';
import 'widgets/stats_display.dart';
import 'widgets/project_selection_screen.dart';
import 'widgets/heavy_bulk_tasks_screen.dart';
import 'widgets/video_clips_manager.dart';
import 'widgets/video_clips_manager.dart';
import 'screens/story_audio_screen.dart';
import 'services/mobile/mobile_browser_service.dart';
import 'widgets/mobile_browser_manager_widget.dart';
import 'widgets/compact_profile_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'services/foreground_service.dart';
import 'screens/ffmpeg_info_screen.dart';

void main() {
  runApp(const BulkVideoGeneratorApp());
}

class BulkVideoGeneratorApp extends StatefulWidget {
  const BulkVideoGeneratorApp({super.key});

  @override
  State<BulkVideoGeneratorApp> createState() => _BulkVideoGeneratorAppState();
}

class _BulkVideoGeneratorAppState extends State<BulkVideoGeneratorApp> {
  Project? _currentProject;
  final ProjectService _projectService = ProjectService();
  
  // License state
  bool _isActivated = false;
  bool _isCheckingLicense = true;
  String _deviceId = '';
  String _licenseMessage = '';
  String _licenseError = ''; // For network errors etc

  @override
  void initState() {
    super.initState();
    _verifyLicense();
  }

  Future<void> _verifyLicense() async {
    setState(() {
      _isCheckingLicense = true;
      _licenseError = '';
    });
    
    final result = await AuthService.verifyAccess();
    
    setState(() {
      _isActivated = result['authorized'] == true;
      _deviceId = result['id'] as String? ?? 'Unknown';
      _licenseMessage = result['message'] as String? ?? '';
      _isCheckingLicense = false;
      
      // Set error message for network issues
      if (_licenseMessage == 'NO_INTERNET_CONNECTION') {
        _licenseError = 'No internet connection. License verification failed.';
      } else if (_licenseMessage == 'AUTHORIZATION_SERVER_ERROR') {
        _licenseError = 'Could not reach license server. Please check your connection.';
      }
    });
  }

  void _onProjectSelected(Project project) {
    setState(() {
      _currentProject = project;
    });
  }

  void _changeProject() {
    setState(() {
      _currentProject = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VEO3 Infinity',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      // Always show UI - don't block based on license
      home: _currentProject == null
          ? ProjectSelectionScreen(
              onProjectSelected: _onProjectSelected,
              isActivated: _isActivated,
              isCheckingLicense: _isCheckingLicense,
              licenseError: _licenseError,
              deviceId: _deviceId,
              onRetryLicense: _verifyLicense,
            )
          : BulkVideoGeneratorPage(
              project: _currentProject!,
              projectService: _projectService,
              onChangeProject: _changeProject,
              isActivated: _isActivated,
              licenseError: _licenseError,
              deviceId: _deviceId,
              onRetryLicense: _verifyLicense,
            ),
    );
  }
}

class BulkVideoGeneratorPage extends StatefulWidget {
  final Project project;
  final ProjectService projectService;
  final VoidCallback onChangeProject;
  final bool isActivated;
  final String licenseError;
  final String deviceId;
  final VoidCallback onRetryLicense;
  
  const BulkVideoGeneratorPage({
    super.key,
    required this.project,
    required this.projectService,
    required this.onChangeProject,
    required this.isActivated,
    required this.licenseError,
    required this.deviceId,
    required this.onRetryLicense,
  });

  @override
  State<BulkVideoGeneratorPage> createState() => _BulkVideoGeneratorPageState();
}

class _BulkVideoGeneratorPageState extends State<BulkVideoGeneratorPage> with TickerProviderStateMixin {
  List<SceneData> scenes = [];
  BrowserVideoGenerator? generator;
  ProjectManager? projectManager;
  late String outputFolder;
  
  // Mobile tab controller
  late TabController _mobileTabController;
  
  // Multi-profile services
  ProfileManagerService? _profileManager;
  MultiProfileLoginService? _loginService;
  
  // Multi-profile credentials (saved in preferences)
  String _savedEmail = '';
  String _savedPassword = '';
  
  bool isRunning = false;
  bool isPaused = false;
  int currentIndex = 0;
  double rateLimit = 1.0;
  String? accessToken;
  
  String selectedProfile = 'Default';
  List<String> profiles = ['Default'];
  String selectedModel = 'Veo 3.1 - Fast [Lower Priority]'; // Flow UI model name
  String selectedAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE';
  String selectedAccountType = 'ai_ultra'; // 'free', 'ai_pro', 'ai_ultra'
  int fromIndex = 1;
  int toIndex = 999;
  
  Timer? autoSaveTimer;
  Timer? _sceneRefreshTimer;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _mobileBrowserManagerKey = GlobalKey(); // Key for mobile browser widget
  
  // Error handling state
  int _consecutiveFailures = 0;
  bool _isWaitingForUserAction = false;
  static const int _maxConsecutiveFailures = 10;
  static const Duration _errorRetryDelay = Duration(seconds: 45);
  static const Duration _autoPauseWaitTime = Duration(minutes: 5);
  
  // Quick Generate state
  final TextEditingController _quickPromptController = TextEditingController();
  final TextEditingController _fromIndexController = TextEditingController();
  final TextEditingController _toIndexController = TextEditingController();
  bool _isQuickGenerating = false;
  SceneData? _quickGeneratedScene;
  bool _isQuickInputCollapsed = false;
  bool _isControlsCollapsed = false;



  /// Show dialog when user tries to use a feature that requires activation
  void _showActivationRequiredDialog(String feature) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock, color: Colors.orange, size: 28),
            SizedBox(width: 8),
            Text('Activation Required'),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The "$feature" feature requires license activation.',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your Device ID:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        widget.deviceId,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: 'Copy ID',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: widget.deviceId));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Device ID copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Contact support:\nWhatsApp: +8801705010632',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              widget.onRetryLicense();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Retry License'),
          ),
        ],
      ),
    );
  }
  
  /// Check if feature is allowed (activated)
  bool _checkActivation(String feature) {
    if (!widget.isActivated) {
      _showActivationRequiredDialog(feature);
      return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    outputFolder = widget.project.exportPath;
    
    // Mobile tab controller (2 tabs: Queue, Browser)
    _mobileTabController = TabController(length: 2, vsync: this);
    
    // Chain async initialization properly
    _initializeApp();
    
    // Initialize From/To controllers
    _fromIndexController.text = fromIndex.toString();
    _toIndexController.text = toIndex.toString();
    
    // Auto-refresh scene cards for live status updates (e.g. when viewing expanded bulk task)
    _sceneRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }
  
  Future<void> _initializeApp() async {
    // Request storage permissions first (Android)
    if (Platform.isAndroid) {
      await _requestStoragePermissions();
    }
    
    // Initialize foreground service (Android only)
    await ForegroundServiceHelper.init();
    
    // First initialize output folder and profiles directory
    await _initializeOutputFolder();
    
    // Now that paths are set, ensure profiles dir exists
    await _ensureProfilesDir();
    
    // Load data
    await _loadProfiles();
    await _loadProjectData();
    await _loadPreferences();
    
    // Initialize multi-profile services (now that paths are correct)
    _profileManager = ProfileManagerService(
      profilesDirectory: AppConfig.profilesDir,
      baseDebugPort: AppConfig.debugPort,
    );
    _loginService = MultiProfileLoginService(profileManager: _profileManager!);
  }

  @override
  void dispose() {
    autoSaveTimer?.cancel();
    _sceneRefreshTimer?.cancel();
    generator?.close();
    _scrollController.dispose();
    _quickPromptController.dispose();
    _fromIndexController.dispose();
    _toIndexController.dispose();
    super.dispose();
  }

  Future<void> _initializeOutputFolder() async {
    if (Platform.isAndroid) {
      // Request storage permissions
      await _requestStoragePermissions();
      
      // Use /storage/emulated/0/veo3_generations/
      const externalPath = '/storage/emulated/0';
      outputFolder = '$externalPath/veo3_generations';
      AppConfig.profilesDir = '$externalPath/veo3_profiles';
    } else if (Platform.isIOS) {
      // On iOS, use app-scoped external storage
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        outputFolder = path.join(dir.path, 'veo3_videos');
        AppConfig.profilesDir = path.join(dir.path, 'veo3_profiles');
      }
    }
    
    // Create output directory
    final outputDir = Directory(outputFolder);
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
      print('[Storage] Created output folder: $outputFolder');
    }
    
    // Create profiles directory
    final profilesDir = Directory(AppConfig.profilesDir);
    if (!await profilesDir.exists()) {
      await profilesDir.create(recursive: true);
      print('[Storage] Created profiles folder: ${AppConfig.profilesDir}');
    }
  }
  
  Future<void> _requestStoragePermissions() async {
    if (!Platform.isAndroid) return;
    
    // Check and request storage permission
    var storageStatus = await Permission.storage.status;
    if (!storageStatus.isGranted) {
      storageStatus = await Permission.storage.request();
      print('[Permission] Storage: $storageStatus');
    }
    
    // For Android 11+, request MANAGE_EXTERNAL_STORAGE
    if (await Permission.manageExternalStorage.isDenied) {
      final status = await Permission.manageExternalStorage.request();
      print('[Permission] Manage External Storage: $status');
      
      if (!status.isGranted) {
        // Show dialog to open settings
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Storage Permission Required'),
              content: const Text(
                'This app needs access to external storage to save generated videos.\n\n'
                'Please grant "All files access" permission in the next screen.'
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    openAppSettings();
                  },
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          );
        }
      }
    }
  }
  
  Future<void> _loadProjectData() async {
    // Load any saved prompts from project
    try {
      final savedPrompts = await widget.projectService.loadPrompts();
      if (savedPrompts.isNotEmpty && mounted) {
        setState(() {
          scenes = savedPrompts.map((p) => SceneData(
            sceneId: p['sceneId'] as int? ?? 0,
            prompt: p['prompt'] as String? ?? '',
            status: p['status'] as String? ?? 'queued',
          )).toList();
          toIndex = scenes.length;
        });
      }
    } catch (e) {
      print('Error loading project data: $e');
    }
  }
  
  Future<void> _savePromptsToProject() async {
    try {
      final promptsData = scenes.map((s) => {
        'sceneId': s.sceneId,
        'prompt': s.prompt,
        'status': s.status,
        'firstFramePath': s.firstFramePath,
        'lastFramePath': s.lastFramePath,
      }).toList();
      await widget.projectService.savePrompts(promptsData);
    } catch (e) {
      print('Error saving prompts to project: $e');
    }
  }

  // ========== PREFERENCES PERSISTENCE ==========
  Future<String> _getPreferencesPath() async {
    if (Platform.isAndroid) {
      // Use public external storage on Android
      final dir = Directory('/storage/emulated/0/veo3');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return path.join(dir.path, 'veo_preferences.json');
    } else if (Platform.isIOS) {
      final docsDir = await getApplicationDocumentsDirectory();
      return path.join(docsDir.path, 'veo_preferences.json');
    } else {
      // Desktop
      final exePath = Platform.resolvedExecutable;
      final exeDir = path.dirname(exePath);
      return path.join(exeDir, 'veo_preferences.json');
    }
  }
  
  Future<void> _loadPreferences() async {
    try {
      final prefsPath = await _getPreferencesPath();
      final prefsFile = File(prefsPath);
      
      if (await prefsFile.exists()) {
        final content = await prefsFile.readAsString();
        final prefs = jsonDecode(content) as Map<String, dynamic>;
        
        if (mounted) {
          setState(() {
            // Load saved account type
            if (prefs['accountType'] != null) {
              final savedAccountType = prefs['accountType'] as String;
              if (['free', 'ai_pro', 'ai_ultra'].contains(savedAccountType)) {
                selectedAccountType = savedAccountType;
              }
            }
            
            // Load saved model
            if (prefs['model'] != null) {
              final savedModel = prefs['model'] as String;
              // Ensure model exists in current options
              if (AppConfig.flowModelOptions.values.contains(savedModel)) {
                selectedModel = savedModel;
              }
            }
            
            // Load saved aspect ratio
            if (prefs['aspectRatio'] != null) {
              final savedAspectRatio = prefs['aspectRatio'] as String;
              if (['VIDEO_ASPECT_RATIO_LANDSCAPE', 'VIDEO_ASPECT_RATIO_PORTRAIT'].contains(savedAspectRatio)) {
                selectedAspectRatio = savedAspectRatio;
              }
            }
            
            // Load saved email and password
            if (prefs['email'] != null) {
              _savedEmail = prefs['email'] as String;
            }
            if (prefs['password'] != null) {
              _savedPassword = prefs['password'] as String;
            }
          });
          print('[PREFS] Loaded: account=$selectedAccountType, model=$selectedModel, email=${_savedEmail.isNotEmpty ? "saved" : "none"}');
        }
      }
    } catch (e) {
      print('[PREFS] Error loading preferences: $e');
    }
  }

  Future<void> _savePreferences() async {
    try {
      final prefsPath = await _getPreferencesPath();
      final prefsFile = File(prefsPath);
      
      final prefs = {
        'accountType': selectedAccountType,
        'model': selectedModel,
        'aspectRatio': selectedAspectRatio,
        'email': _savedEmail,
        'password': _savedPassword,
        'savedAt': DateTime.now().toIso8601String(),
      };
      
      await prefsFile.writeAsString(jsonEncode(prefs));
      print('[PREFS] Saved: account=$selectedAccountType, model=$selectedModel, email=${_savedEmail.isNotEmpty ? "saved" : "none"}');
    } catch (e) {
      print('[PREFS] Error saving preferences: $e');
    }
  }

  Future<void> _ensureProfilesDir() async {
    await Directory(AppConfig.profilesDir).create(recursive: true);
    final defaultProfile = Directory(path.join(AppConfig.profilesDir, 'Default'));
    if (!await defaultProfile.exists()) {
      await defaultProfile.create(recursive: true);
    }
  }

  Future<void> _loadProfiles() async {
    final profilesDir = Directory(AppConfig.profilesDir);
    if (await profilesDir.exists()) {
      final dirs = await profilesDir.list().where((entity) => entity is Directory).toList();
      setState(() {
        profiles = dirs.map((d) => path.basename(d.path)).toList()..sort();
        if (profiles.isEmpty) {
          profiles = ['Default'];
        }
      });
    }
  }

  Future<void> _createNewProfile() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Profile'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Profile name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final cleanName = result.replaceAll(RegExp(r'[^\w\s.-]'), '');
      if (cleanName.isEmpty) return;

      final profilePath = path.join(AppConfig.profilesDir, cleanName);
      final dir = Directory(profilePath);

      if (await dir.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile already exists')),
          );
        }
        return;
      }

      try {
        await dir.create(recursive: true);
        await _loadProfiles();
        setState(() => selectedProfile = cleanName);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Created profile: $cleanName')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to create profile: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteProfile(String profileName) async {
    try {
      final profilePath = path.join(AppConfig.profilesDir, profileName);
      final dir = Directory(profilePath);

      if (await dir.exists()) {
        await dir.delete(recursive: true);
        print('[PROFILE] Deleted profile: $profileName');
      }

      await _loadProfiles();
      // Switch to first available profile or set empty if none left
      if (profiles.isNotEmpty) {
        setState(() => selectedProfile = profiles.first);
      } else {
        setState(() => selectedProfile = ''); // Keep empty
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted profile: $profileName')),
        );
      }
    } catch (e) {
      print('[PROFILE] Error deleting profile: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete profile: $e')),
        );
      }
    }
  }

  // Load file (JSON/TXT)
  Future<void> _loadFile() async {
    if (!_checkActivation('Load Prompts')) return;
    
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();

        List<SceneData> loadedScenes;
        if (result.files.single.extension == 'json') {
          loadedScenes = parseJsonPrompts(content);
        } else {
          loadedScenes = parseTxtPrompts(content);
        }

        setState(() {
          scenes = loadedScenes;
          fromIndex = 1;
          toIndex = scenes.length;
          _fromIndexController.text = fromIndex.toString();
          _toIndexController.text = toIndex.toString();
          _isQuickInputCollapsed = true; // Collapse quick input when bulk scenes loaded
        });
        
        // Save prompts to project
        await _savePromptsToProject();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Loaded ${scenes.length} scenes to project')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load file: $e')),
        );
      }
    }
  }

  // Paste JSON dialog
  Future<void> _pasteJson() async {
    if (!_checkActivation('Paste Prompts')) return;
    
    final controller = TextEditingController();
    final promptCountNotifier = ValueNotifier<String>('Prompts detected: 0');

    // Function to count prompts from content
    void updatePromptCount(String content) {
      if (content.isEmpty) {
        promptCountNotifier.value = 'Prompts detected: 0';
        return;
      }

      try {
        final loadedScenes = parsePrompts(content);
        final isJson = content.contains('[') && content.contains(']');
        promptCountNotifier.value = 'Prompts detected: ${loadedScenes.length} (${isJson ? "JSON" : "Text"} format)';
      } catch (e) {
        // Try line count as fallback
        final lines = content.split('\n').where((l) => l.trim().isNotEmpty).length;
        if (lines > 0) {
          promptCountNotifier.value = 'Lines detected: $lines (parsing failed)';
        } else {
          promptCountNotifier.value = 'No valid prompts detected';
        }
      }
    }

    controller.addListener(() => updatePromptCount(controller.text));

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste Prompts'),
        content: SizedBox(
          width: 600,
          height: 450,
          child: Column(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste JSON (auto-extracts [...]) or plain text (one prompt per line)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: promptCountNotifier,
                builder: (context, value, child) {
                  final color = value.contains('detected:') && !value.contains('0') && !value.contains('failed')
                      ? Colors.green
                      : Colors.grey;
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: color),
                    ),
                    child: Text(
                      value,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: color,
                        fontSize: 14,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Load Scenes'),
          ),
        ],
      ),
    );

    promptCountNotifier.dispose();

    if (result != null && result.isNotEmpty) {
      try {
        final loadedScenes = parsePrompts(result);
        setState(() {
          scenes = loadedScenes;
          fromIndex = 1;
          toIndex = scenes.length;
          _fromIndexController.text = fromIndex.toString();
          _toIndexController.text = toIndex.toString();
          _isQuickInputCollapsed = true; // Collapse quick input when bulk scenes loaded
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Loaded ${scenes.length} scenes')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to parse content: $e')),
          );
        }
      }
    }
  }

  // Save project
  Future<void> _saveProject() async {
    if (scenes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No scenes to save')),
      );
      return;
    }

    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Project',
        fileName: 'project.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null) {
        projectManager = ProjectManager(result);
        projectManager!.projectData['output_folder'] = outputFolder;
        await projectManager!.save(scenes);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Project saved')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save project: $e')),
        );
      }
    }
  }

  // Load project
  Future<void> _loadProject() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final loadResult = await ProjectManager.load(result.files.single.path!);
        setState(() {
          scenes = loadResult.scenes;
          outputFolder = loadResult.outputFolder;
        });

        projectManager = ProjectManager(result.files.single.path!);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Loaded ${scenes.length} scenes from project')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load project: $e')),
        );
      }
    }
  }

  // Set output folder
  Future<void> _setOutputFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Output Folder',
    );

    if (result != null) {
      setState(() {
        outputFolder = result;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Output folder set to: $result')),
        );
      }
    }
  }

  // Join Video Clips / Export with advanced options
  Future<void> _concatenateVideos() async {
    if (!_checkActivation('Join Video Clips / Export')) return;
    
    // Show clips manager screen immediately (Dashboard first)
    // User can pick files or folders from there
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => VideoClipsManager(
          initialFiles: const [], 
          exportFolder: outputFolder,
          onExport: (files) async {
            // Close clips manager
            Navigator.of(context).pop();
            
            // Show export settings dialog
            await _showExportSettings(files);
          },
        ),
      ),
    );
  }

  Future<void> _showExportSettings(List<PlatformFile> files) async {
    if (files.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select at least 2 videos to join')),
        );
      }
      return;
    }

    // Show settings dialog
    String selectedResolution = 'original';
    String selectedAspectRatio = 'original';
    double speedFactor = 1.0;
    bool forceReEncode = false;

    final settings = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            // Determine if re-encode is required
            final needsReEncode = selectedResolution != 'original' || 
                                  selectedAspectRatio != 'original' ||
                                  (speedFactor - 1.0).abs() > 0.01 ||
                                  forceReEncode;
            
            return AlertDialog(
              title: const Text('Export Settings'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Resolution:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        ChoiceChip(
                          label: const Text('Original'),
                          selected: selectedResolution == 'original',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedResolution = 'original');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('1080p'),
                          selected: selectedResolution == '1080p',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedResolution = '1080p');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('2K'),
                          selected: selectedResolution == '2k',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedResolution = '2k');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('4K'),
                          selected: selectedResolution == '4k',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedResolution = '4k');
                          },
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 16),
                    const Text('Aspect Ratio:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        ChoiceChip(
                          label: const Text('Original'),
                          selected: selectedAspectRatio == 'original',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedAspectRatio = 'original');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('16:9'),
                          selected: selectedAspectRatio == '16:9',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedAspectRatio = '16:9');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('9:16'),
                          selected: selectedAspectRatio == '9:16',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedAspectRatio = '9:16');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('1:1'),
                          selected: selectedAspectRatio == '1:1',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedAspectRatio = '1:1');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('4:5'),
                          selected: selectedAspectRatio == '4:5',
                          onSelected: (selected) {
                            if (selected) setState(() => selectedAspectRatio = '4:5');
                          },
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Speed: ${speedFactor.toStringAsFixed(2)}x', 
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        SizedBox(
                          width: 80,
                          child: TextField(
                            decoration: const InputDecoration(
                              labelText: 'Custom',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onSubmitted: (value) {
                              final parsed = double.tryParse(value);
                              if (parsed != null && parsed >= 0.25 && parsed <= 4.0) {
                                setState(() => speedFactor = parsed);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: speedFactor,
                      min: 0.25,
                      max: 4.0,
                      divisions: 375, // 0.01 increments
                      label: '${speedFactor.toStringAsFixed(2)}x',
                      onChanged: (value) {
                        setState(() => speedFactor = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: const Text('Force re-encode'),
                      subtitle: Text(needsReEncode 
                          ? 'Re-encoding required for selected settings' 
                          : 'Enabled: Force re-encode. Disabled: Fast copy mode'),
                      value: forceReEncode || needsReEncode,
                      onChanged: needsReEncode ? null : (value) {
                        setState(() => forceReEncode = value);
                      },
                    ),
                    if (needsReEncode && !forceReEncode)
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 16, color: Colors.blue.shade700),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Re-encoding will be used because you changed resolution, aspect ratio, or speed.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context, {
                      'resolution': selectedResolution,
                      'aspectRatio': selectedAspectRatio,
                      'speed': speedFactor,
                      'reEncode': needsReEncode || forceReEncode,
                    });
                  },
                  child: const Text('Export'),
                ),
              ],
            );
          },
        );
      },
    );

    if (settings == null) return;

    // Get output path - on mobile use outputFolder directly, on desktop use save dialog
    String? outputPath;
    
    if (Platform.isAndroid || Platform.isIOS) {
      // On mobile, save to outputFolder with timestamp filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      outputPath = path.join(outputFolder, 'exported_$timestamp.mp4');
      
      // Ensure directory exists
      final dir = Directory(outputFolder);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } else {
      // On desktop, use save file dialog
      outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Exported Video As',
        fileName: 'exported_video.mp4',
        type: FileType.custom,
        allowedExtensions: ['mp4'],
      );
    }

    if (outputPath == null) return;
    
    // Safe non-null variable after null check
    final String finalOutputPath = outputPath;

    // Show progress dialog with ValueNotifier for real-time updates
    final progressNotifier = ValueNotifier<Map<String, dynamic>>({
      'message': 'Processing ${files.length} videos...',
      'progress': null,
    });
    
    // Flag to track background execution
    bool runInBackground = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: progressNotifier,
        builder: (context, value, child) {
          return AlertDialog(
            title: const Text('Exporting Video'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value['progress'] != null)
                  LinearProgressIndicator(value: value['progress'] as double)
                else
                  const LinearProgressIndicator(),
                const SizedBox(height: 16),
                Text(value['message'] as String, textAlign: TextAlign.center),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  runInBackground = true;
                  Navigator.pop(dialogContext); // Close dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Exporting in background... Notification will appear when done.')),
                  );
                },
                child: const Text('Run in Background'),
              ),
            ],
          );
        },
      ),
    );

    // Start global tracking
    ExportStatus.start('Preparing export...');

    try {
      final ffmpegPath = AppConfig.ffmpegPath;
      final resolution = settings['resolution'] as String;
      final aspectRatio = settings['aspectRatio'] as String? ?? 'original';
      final speed = settings['speed'] as double;
      final shouldReEncode = settings['reEncode'] as bool;

      // Progress callback
      void updateProgress(String message, double? progress) {
         ExportStatus.update(message, progress);
         try {
            progressNotifier.value = {
             'message': message,
             'progress': progress,
           };
         } catch (_) {}
      }

      if (shouldReEncode) {
        // Re-encode with settings
        // ... (call helpers)
         await VideoExportHelper.concatenateWithReEncode(
          files,
          finalOutputPath,
          ffmpegPath,
          outputFolder,
          resolution,
          speed,
          onProgress: updateProgress,
          aspectRatio: aspectRatio,
        );
      } else {
        // Fast copy mode (no re-encoding)
         await VideoExportHelper.concatenateFastCopy(
          files,
          finalOutputPath,
          ffmpegPath,
          outputFolder,
          onProgress: updateProgress,
        );
      }

      // Dispose notifier
      progressNotifier.dispose();
      
      ExportStatus.finish();

      // Close progress dialog if NOT running in background
      if (!runInBackground && mounted) {
        Navigator.of(context).pop();
      }

      // Show success
      final outputFile = File(finalOutputPath);
      final fileSizeMB = (await outputFile.length()) / 1024 / 1024;
      
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('✅ Success'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Videos exported successfully!\n\n'
                  'Output: ${path.basename(finalOutputPath)}\n'
                  'Size: ${fileSizeMB.toStringAsFixed(1)} MB',
                ),
                if (Platform.isAndroid || Platform.isIOS) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Saved to: $finalOutputPath',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
              if (Platform.isAndroid || Platform.isIOS) ...[
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await OpenFilex.open(finalOutputPath);
                  },
                  child: const Text('Play'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await Share.shareXFiles([XFile(finalOutputPath)], text: 'Exported video');
                  },
                  child: const Text('Share'),
                ),
              ] else
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await Process.run('explorer', ['/select,', finalOutputPath]);
                  },
                  child: const Text('Open Folder'),
                ),
            ],
          ),
        );
      }
    } catch (e) {
      // Close progress dialog
      if (mounted) Navigator.of(context).pop();
      
      String errorMessage = e.toString();
      
      // Check for FFmpeg not found
      if (errorMessage.contains('is not recognized') || 
          errorMessage.contains('not found') ||
          errorMessage.contains('No such file')) {
        final exePath = Platform.resolvedExecutable;
        final exeDir = File(exePath).parent.path;
        errorMessage = 'FFmpeg not found!\n\n'
            'Checked path: ${AppConfig.ffmpegPath}\n'
            'App directory: $exeDir\n\n'
            'Please place ffmpeg.exe in the same folder as veo3_another.exe\n'
            'or install it from: https://ffmpeg.org/download.html';
      }
      
      // Show error
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('❌ Error'),
            content: Text(errorMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  // Launch Chrome
  Future<void> _launchChrome() async {
    final profilePath = path.join(AppConfig.profilesDir, selectedProfile);

    try {
      await Process.start(
        AppConfig.chromePath,
        [
          '--remote-debugging-port=${AppConfig.debugPort}',
          '--remote-allow-origins=*',
          '--user-data-dir=$profilePath',
          '--profile-directory=Default',
          'https://labs.google/fx/tools/flow',
        ],
        mode: ProcessStartMode.detached,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Chrome launched with profile \'$selectedProfile\'.\nPlease log in if needed, then connect.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to launch Chrome: $e')),
        );
      }
    }
  }

  // Start generation
  Future<void> _startGeneration() async {
    if (!_checkActivation('Video Generation')) return;
    
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
       final service = MobileBrowserService();
       if (service.countConnected() > 0) {
          setState(() {
             isRunning = true;
             isPaused = false;
             _consecutiveFailures = 0;
          });
          _mobileGenerationWorker();
       } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please Log In first (Auto Login)')));
       }
       return;
    }

    if (scenes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please load scenes first')),
      );
      return;
    }

    setState(() {
      isRunning = true;
      isPaused = false;
      _consecutiveFailures = 0;
      _isWaitingForUserAction = false;
    });

    // Check if multi-browser system is available
    final hasMultiBrowsers = _profileManager != null && 
                              _profileManager!.profiles.isNotEmpty &&
                              _profileManager!.countConnectedProfiles() > 0;

    if (hasMultiBrowsers) {
      print('\n[START] Multi-browser system detected (${_profileManager!.countConnectedProfiles()} browsers)');
      print('[START] Using concurrent multi-profile generation');
      _multiProfileGenerationWorker();
    } else {
      print('\n[START] Single-browser mode');
      print('[START] Tip: Use "🚀 Login All" in Profile section for faster concurrent generation');
      _generationWorker();
    }

    // Start auto-save
    _scheduleAutoSave();
  }

  void _pauseGeneration() {
    setState(() {
      isPaused = !isPaused;
    });
  }

  void _stopGeneration() {
    setState(() {
      isRunning = false;
    });
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Colors.blue, Colors.purple],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.video_library, color: Colors.white, size: 32),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('VEO3 Infinity', style: TextStyle(fontSize: 20)),
                Text('v1.0.0', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Professional Video Generation Tool',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              const Text(
                'Developed by',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.blue.shade100,
                    child: const Icon(Icons.person, color: Colors.blue),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Shakil Ahmed',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'BSc, MSc in Physics',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                        Text(
                          'Jagannath University',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.copyright, size: 16, color: Colors.blue),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '2024 GravityApps. All rights reserved.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _retryFailed() {
    setState(() {
      for (var scene in scenes) {
        if (scene.status == 'failed') {
          scene.status = 'queued';
          scene.error = null;
          scene.retryCount = 0;
        }
      }
    });
  }

  void _openHeavyBulkTasks() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HeavyBulkTasksScreen(
          profiles: profiles,
          profileManager: _profileManager,
          loginService: _loginService,
          email: _savedEmail,
          password: _savedPassword,
          onTaskAdded: (task) {
            // Load the task's scenes into the main screen
            setState(() {
              scenes = task.scenes;
              selectedProfile = task.profile;
              outputFolder = task.outputFolder;
              
              // Set model value
              selectedModel = task.model;
              
              // Set aspect ratio value
              selectedAspectRatio = task.aspectRatio;
            });
          },
        ),
      ),
    );
  }

  void _openStoryAudio({bool goToReelTab = false}) {
    if (!_checkActivation('Bulk REELS + Manual Audio')) return;
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StoryAudioScreen(
          projectService: widget.projectService,
          isActivated: widget.isActivated,
          profileManager: _profileManager,
          loginService: _loginService,
          email: _savedEmail,
          password: _savedPassword,
          selectedModel: selectedModel,
          selectedAccountType: selectedAccountType,
          initialTabIndex: goToReelTab ? 1 : 0, // 0 = Story Audio, 1 = Reel Special
        ),
      ),
    );
  }

  Future<void> _testFFmpeg() async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Testing FFmpeg...'),
          ],
        ),
      ),
    );

    try {
      final result = await AppConfig.testFFmpeg();
      
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(
                  result.startsWith('OK') ? Icons.check_circle : Icons.error,
                  color: result.startsWith('OK') ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                const Text('FFmpeg Test'),
              ],
            ),
            content: SelectableText(result),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error, color: Colors.red),
                SizedBox(width: 8),
                Text('FFmpeg Test Failed'),
              ],
            ),
            content: SelectableText('Error: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  /// Handle API errors with retry logic
  /// Returns: 'skip' to skip scene, 'retry' to retry, 'pause' if paused, 'continue' if resumed
  Future<String> _handleApiError({
    required int statusCode,
    required SceneData scene,
    required String errorMessage,
  }) async {
    print('[ERROR] HTTP $statusCode: $errorMessage');
    
    // 400 Bad Request - Content policy violation, skip immediately
    if (statusCode == 400) {
      print('[ERROR] 400 Bad Request - Skipping scene (content policy or invalid input)');
      setState(() {
        scene.status = 'failed';
        scene.error = 'Bad Request: $errorMessage';
      });
      _consecutiveFailures = 0; // Reset on handled error
      return 'skip';
    }
    
    // 403 Forbidden or 429 Rate Limit or 503 Service Unavailable - Retry with delay
    if (statusCode == 403 || statusCode == 429 || statusCode == 503) {
      scene.retryCount = (scene.retryCount ?? 0) + 1;
      
      final errorType = statusCode == 403 
          ? 'Forbidden (Auth/reCAPTCHA issue)' 
          : (statusCode == 429 ? 'Rate Limit Exceeded' : 'Service Unavailable');
      
      print('[ERROR] $statusCode $errorType - Attempt ${scene.retryCount}/3');
      
      // On 403 error, refresh the browser to help recover
      if (statusCode == 403 && generator != null) {
        print('[RECOVERY] 403 detected - Refreshing browser to recover...');
        try {
          await generator!.refreshPage();
        } catch (e) {
          print('[RECOVERY] Browser refresh failed: $e');
        }
      }
      
      // If 3 retries failed, skip this scene
      if (scene.retryCount! >= 3) {
        print('[ERROR] Max retries (3) reached for scene ${scene.sceneId} - Skipping');
        setState(() {
          scene.status = 'failed';
          scene.error = '$errorType after 3 retries';
          scene.retryCount = 0;
        });
        _consecutiveFailures++;
        
        // Check for continuous failures threshold
        if (_consecutiveFailures >= _maxConsecutiveFailures) {
          return await _handleContinuousFailures();
        }
        return 'skip';
      }
      
      // Wait 45 seconds before retry
      print('[RETRY] Waiting 45 seconds before retry...');
      setState(() {
        scene.status = 'queued';
        scene.error = 'Retrying in 45s (attempt ${scene.retryCount}/3)';
      });
      
      await Future.delayed(_errorRetryDelay);
      return 'retry';
    }
    
    // Other errors - increment failure counter
    _consecutiveFailures++;
    setState(() {
      scene.status = 'failed';
      scene.error = 'HTTP $statusCode: $errorMessage';
    });
    
    // Check for continuous failures threshold
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      return await _handleContinuousFailures();
    }
    
    return 'skip';
  }
  
  /// Handle 10+ consecutive failures - pause and notify user
  Future<String> _handleContinuousFailures() async {
    print('[CRITICAL] 🛑 ${_consecutiveFailures} consecutive failures! Pausing generation...');
    
    setState(() {
      isPaused = true;
      _isWaitingForUserAction = true;
    });
    
    // Show notification dialog
    if (mounted) {
      _showContinuousFailureDialog();
    }
    
    // Wait for user action or 5 minutes
    final startWait = DateTime.now();
    while (_isWaitingForUserAction && isRunning) {
      await Future.delayed(const Duration(seconds: 1));
      
      // Auto-resume after 5 minutes if no user action
      if (DateTime.now().difference(startWait) >= _autoPauseWaitTime) {
        print('[AUTO-RESUME] 5 minutes elapsed - Resuming generation automatically');
        setState(() {
          isPaused = false;
          _isWaitingForUserAction = false;
          _consecutiveFailures = 0;
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⏱️ Auto-resuming after 5 minute wait...'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return 'continue';
      }
    }
    
    // User took action (clicked resume or stop)
    if (!isRunning) {
      return 'pause';
    }
    
    _consecutiveFailures = 0;
    return 'continue';
  }
  
  /// Show dialog for continuous failures
  void _showContinuousFailureDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Text('Generation Paused'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$_consecutiveFailures consecutive failures detected!',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
            ),
            const SizedBox(height: 12),
            const Text('Possible causes:'),
            const SizedBox(height: 8),
            const Text('• API quota exhausted'),
            const Text('• Network connection issues'),
            const Text('• Account authorization expired'),
            const Text('• Service temporarily unavailable'),
            const SizedBox(height: 16),
            const Text(
              'Generation will auto-resume in 5 minutes if no action taken.',
              style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                isRunning = false;
                isPaused = false;
                _isWaitingForUserAction = false;
              });
            },
            child: const Text('Stop Generation'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                isPaused = false;
                _isWaitingForUserAction = false;
                _consecutiveFailures = 0;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('✓ Resuming generation...'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Resume Now'),
          ),
        ],
      ),
    );
  }

  // Concurrent processing state
  int _activeGenerationsCount = 0;
  final List<_PendingPoll> _pendingPolls = [];
  bool _generationComplete = false;

  Future<void> _generationWorker() async {
    try {
      print('\n${'=' * 60}');
      print('BULK VIDEO GENERATOR - STARTING CONCURRENT MODE');
      print('=' * 60);

      // Connect to browser with retry logic
      print('\n[CONNECT] Connecting to Chrome DevTools...');
      print('[CONNECT] Profile: $selectedProfile (Port: ${AppConfig.debugPort})');
      int connectionAttempts = 0;
      const maxConnectionAttempts = 3;
      
      while (connectionAttempts < maxConnectionAttempts) {
        try {
          generator = BrowserVideoGenerator();
          await generator!.connect();
          print('[CONNECT] ✓ Connected successfully (attempt ${connectionAttempts + 1})');
          break;
        } catch (e) {
          connectionAttempts++;
          print('[CONNECT] ✗ Connection failed (attempt $connectionAttempts): $e');
          
          // Close failed connection
          generator?.close();
          generator = null;
          
          if (connectionAttempts < maxConnectionAttempts) {
            print('[CONNECT] Launching Chrome with profile $selectedProfile...');
            await _launchChrome();
            await Future.delayed(const Duration(seconds: 5));
          } else {
            throw Exception('Failed to connect to Chrome after $maxConnectionAttempts attempts.\nPlease ensure Chrome is running with debugging enabled.');
          }
        }
      }
      
      if (generator == null) {
        throw Exception('Failed to establish browser connection');
      }

      // Get access token
      print('\n[AUTH] Fetching access token from browser session...');
      accessToken = await generator!.getAccessToken();
      if (accessToken == null) {
        print('[AUTH] ✗ Failed to get access token');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to get access token')),
          );
        }
        return;
      }
      print('[AUTH] ✓ Token: ${accessToken!.substring(0, 50)}...');

      // Get range
      final scenesToProcess = scenes
          .skip(fromIndex - 1)
          .take(toIndex - fromIndex + 1)
          .where((s) => s.status == 'queued')
          .toList();

      print('\n[QUEUE] Processing ${scenesToProcess.length} scenes (from $fromIndex to $toIndex)');
      print('[QUEUE] Rate limit: $rateLimit req/sec');
      print('[QUEUE] Model: $selectedModel');

      // Reset concurrent processing state
      _activeGenerationsCount = 0;
      _pendingPolls.clear();
      _generationComplete = false;

      // Start Polling Worker (runs in parallel)
      _pollWorker();

      // Start Generation Loop (producer)
      await _processGenerationQueue(scenesToProcess);

      // Signal completion and wait for polls to finish
      _generationComplete = true;
      
      // Wait for all active polls to complete
      while (_pendingPolls.isNotEmpty || _activeGenerationsCount > 0) {
        await Future.delayed(const Duration(seconds: 2));
      }

      print('\n${'=' * 60}');
      print('GENERATION & PROCESSING COMPLETE');
      print('=' * 60);
    } catch (e) {
      print('\n[ERROR] Fatal error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generation error: $e')),
        );
      }
    } finally {
      generator?.close();
      if (mounted) {
        setState(() {
          isRunning = false;
        });
      }
    }
  }

  // Mobile Generation Worker - Concurrent with Batch Polling
  Future<void> _mobileGenerationWorker() async {
    print('[MOBILE] Concurrent Worker Started');
    final service = MobileBrowserService();
    
    // Start foreground service to prevent Android from killing the app
    await ForegroundServiceHelper.startService(status: 'Starting video generation...');
    
    // Check at least one profile is ready
    final connectedCount = service.countConnected();
    if (connectedCount == 0) {
      print('[MOBILE] No profiles connected');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No browser profiles connected. Login first.')),
        );
      }
      await ForegroundServiceHelper.stopService();
      setState(() { isRunning = false; });
      return;
    }
    
    print('[MOBILE] Connected profiles: $connectedCount');
    
    try {
      // Get scenes to process
      final scenesToProcess = scenes
          .skip(fromIndex - 1)
          .take(toIndex - fromIndex + 1)
          .where((s) => s.status == 'queued' || s.status == 'failed')
          .toList();
      
      print('[MOBILE] Processing ${scenesToProcess.length} scenes');
      print('[MOBILE] Model: $selectedModel');
      
      await ForegroundServiceHelper.updateStatus('Processing ${scenesToProcess.length} videos...');
      
      // Reset concurrent processing state
      _activeGenerationsCount = 0;
      _pendingPolls.clear();
      _generationComplete = false;
      
      // Determine concurrency limit (4 for relaxed model, otherwise 4)
      final maxConcurrent = 4;
      print('[MOBILE] Max concurrent: $maxConcurrent');
      
      // Start Polling Worker (runs in parallel)
      _pollWorker();
      
      // Process queue with concurrency control
      await _processMobileQueue(scenesToProcess, maxConcurrent, service);
      
      // Signal completion and wait for polls to finish
      _generationComplete = true;
      
      // Wait for all active polls to complete
      while (isRunning && (_pendingPolls.isNotEmpty || _activeGenerationsCount > 0)) {
        await Future.delayed(const Duration(seconds: 2));
        
        // Update notification
        final completed = scenes.where((s) => s.status == 'completed').length;
        final pending = _pendingPolls.length;
        await ForegroundServiceHelper.updateStatus('Done: $completed | Polling: $pending | Active: $_activeGenerationsCount');
        
        // Check if any scenes need retry
        final retryScenes = scenesToProcess
            .where((s) => s.status == 'queued' && (s.retryCount ?? 0) > 0)
            .toList();
        
        if (retryScenes.isNotEmpty && _activeGenerationsCount < maxConcurrent) {
          print('[MOBILE RETRY] Found ${retryScenes.length} scenes for retry');
          await _processMobileQueue(retryScenes, maxConcurrent, service);
        }
      }
      
      print('[MOBILE] All scenes processed');
      
    } catch (e) {
      print('[MOBILE] Worker Error: $e');
    } finally {
      // Stop foreground service
      await ForegroundServiceHelper.stopService();
      setState(() { isRunning = false; });
    }
  }
  
  /// Process mobile queue with concurrency control
  Future<void> _processMobileQueue(List<SceneData> scenesToProcess, int maxConcurrent, MobileBrowserService service) async {
    int profileIndex = 0;
    
    for (var i = 0; i < scenesToProcess.length; i++) {
      if (!isRunning) break;
      
      while (isPaused) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      // Wait for available slot
      while (_activeGenerationsCount >= maxConcurrent && isRunning) {
        print('[MOBILE LIMIT] Waiting for slots (Active: $_activeGenerationsCount/$maxConcurrent)...');
        await Future.delayed(const Duration(seconds: 1));
      }
      
      if (!isRunning) break;
      
      // Round-robin profile selection
      MobileProfile? profile;
      for (int attempt = 0; attempt < service.profiles.length; attempt++) {
        final p = service.getProfile(profileIndex % service.profiles.length);
        profileIndex++;
        if (p != null && p.status == MobileProfileStatus.ready && p.generator != null && p.accessToken != null) {
          profile = p;
          break;
        }
      }
      
      if (profile == null) {
        print('[MOBILE] No available profile, waiting...');
        await Future.delayed(const Duration(seconds: 2));
        i--; // Retry this scene
        continue;
      }
      
      final scene = scenesToProcess[i];
      
      try {
        // Small delay between requests
        if (i > 0) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        
        // Generate using this profile
        await _generateWithMobileProfile(scene, profile, i + 1, scenesToProcess.length);
        
      } on _RetryableException catch (e) {
        // Retryable error (403, API errors) - push back to queue for retry
        scene.retryCount = (scene.retryCount ?? 0) + 1;
        
        if (scene.retryCount! < 10) {
          print('[MOBILE RETRY] Scene ${scene.sceneId} retry ${scene.retryCount}/10 - pushing back');
          setState(() {
            scene.status = 'queued';
            scene.error = 'Retrying (${scene.retryCount}/10): ${e.message}';
          });
          scenesToProcess.add(scene);
        } else {
          print('[MOBILE] ✗ Scene ${scene.sceneId} failed after 10 retries');
          setState(() {
            scene.status = 'failed';
            scene.error = 'Failed after 10 retries: ${e.message}';
          });
        }
      } catch (e) {
        // Non-retryable error
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
        print('[MOBILE] ✗ Exception: $e');
      }
    }
    
    print('[MOBILE PRODUCER] Queue processed');
  }
  
  /// Generate a single video using a mobile profile (concurrent-safe)
  Future<void> _generateWithMobileProfile(SceneData scene, MobileProfile profile, int currentIndex, int totalScenes) async {
    // Take slot IMMEDIATELY
    _activeGenerationsCount++;
    print('[MOBILE SLOT] Took slot - Active: $_activeGenerationsCount');
    
    setState(() {
      scene.status = 'generating';
      scene.error = null;
    });
    
    print('[MOBILE $currentIndex/$totalScenes] Scene ${scene.sceneId} using ${profile.name}');
    
    // Get API model key
    final apiModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
    print('[MOBILE] Model: $apiModelKey');
    
    // Generate video
    final result = await profile.generator!.generateVideo(
      prompt: scene.prompt,
      accessToken: profile.accessToken!,
      aspectRatio: selectedAspectRatio,
      model: apiModelKey,
    );
    
    if (result == null) {
      _activeGenerationsCount--;
      print('[MOBILE SLOT] Released (null result) - Active: $_activeGenerationsCount');
      throw Exception('No result from generateVideo');
    }
    
    // Check for error status
    if (result['status'] != null && result['status'] != 200) {
      final statusCode = result['status'] as int;
      final errorMsg = result['error'] ?? result['statusText'] ?? 'API error';
      
      // Handle 403 error - auto relogin
      if (statusCode == 403) {
        profile.consecutive403Count++;
        print('[MOBILE 403] ${profile.name} 403 count: ${profile.consecutive403Count}/3');
        
        // Trigger auto-relogin if threshold reached
        if (profile.consecutive403Count >= 3 && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty) {
          print('[MOBILE 403] ${profile.name} triggering auto-relogin...');
          profile.status = MobileProfileStatus.loading;
          
          // Relogin in background
          profile.generator!.autoLogin(_savedEmail, _savedPassword).then((_) async {
            final newToken = await profile.generator!.getAccessToken();
            if (newToken != null) {
              profile.accessToken = newToken;
              profile.status = MobileProfileStatus.ready;
              profile.consecutive403Count = 0;
              print('[MOBILE 403] ${profile.name} relogin SUCCESS');
            }
          });
        }
      }
      
      _activeGenerationsCount--;
      print('[MOBILE SLOT] Released (API $statusCode) - Active: $_activeGenerationsCount');
      throw _RetryableException('API error $statusCode: $errorMsg');
    }
    
    if (result['success'] != true) {
      _activeGenerationsCount--;
      print('[MOBILE SLOT] Released (API failure) - Active: $_activeGenerationsCount');
      throw Exception(result['error'] ?? 'Generation failed');
    }
    
    // Reset 403 count on success
    profile.consecutive403Count = 0;
    
    // Extract operation name
    final responseData = result['data'] as Map<String, dynamic>;
    final operations = responseData['operations'] as List?;
    if (operations == null || operations.isEmpty) {
      _activeGenerationsCount--;
      print('[MOBILE SLOT] Released (no operations) - Active: $_activeGenerationsCount');
      throw Exception('No operations in response');
    }
    
    final firstOp = operations[0] as Map<String, dynamic>;
    String? operationName = firstOp['name'] as String?;
    if (operationName == null && firstOp['operation'] is Map) {
      operationName = (firstOp['operation'] as Map)['name'] as String?;
    }
    
    if (operationName == null) {
      _activeGenerationsCount--;
      print('[MOBILE SLOT] Released (no op name) - Active: $_activeGenerationsCount');
      throw Exception('No operation name in response');
    }
    
    final sceneUuid = firstOp['sceneId']?.toString() ?? result['sceneId']?.toString() ?? operationName;
    
    scene.operationName = operationName;
    setState(() {
      scene.status = 'polling';
    });
    
    // Add to pending polls for batch polling worker
    _pendingPolls.add(_PendingPoll(scene, sceneUuid));
    
    print('[MOBILE] ✓ Scene ${scene.sceneId} queued for polling');
  }

  // Mobile Single Run - INLINE POLLING (same generator polls its own video)
  Future<void> _mobileRunSingle(SceneData scene, MobileProfile profile) async {
      setState(() { scene.status = 'generating'; scene.error = null; });
      
      print('[MOBILE] Starting generation for scene ${scene.sceneId}');
      
      try {
        final generator = profile.generator!;
        final token = profile.accessToken!;
        
        // Uploads (if needed)
        String? startMediaId = scene.firstFrameMediaId;
        String? endMediaId = scene.lastFrameMediaId;
        
        if (scene.firstFramePath != null && startMediaId == null) {
           print('[MOBILE] Uploading start image...');
           final res = await generator.uploadImage(scene.firstFramePath!, token);
             if (res is String) {
                startMediaId = res;
                scene.firstFrameMediaId = res; 
             } else {
                throw Exception('Image upload failed');
             }
        }
        if (scene.lastFramePath != null && endMediaId == null) {
           final res = await generator.uploadImage(scene.lastFramePath!, token);
             if (res is String) {
                endMediaId = res;
                scene.lastFrameMediaId = res;
             }
        }
        
        // Resolve Model Key using AppConfig
        final actualModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
        
        // Generate
        print('[MOBILE] Generating scene ${scene.sceneId} (Model: $actualModelKey)...');
        final res = await generator.generateVideo(
           prompt: scene.prompt, accessToken: token,
           aspectRatio: selectedAspectRatio, model: actualModelKey,
           startImageMediaId: startMediaId, endImageMediaId: endMediaId
        );
        
        if (res == null || res['data'] == null) {
            print('[MOBILE] Generate returned null or no data');
            throw Exception('API Error or Rate Limit');
        }
        
        final data = res['data'];
        final ops = data['operations'];
        if (ops == null || (ops is List && ops.isEmpty)) {
            print('[MOBILE] No operations in response: ${jsonEncode(data)}');
            throw Exception('No operation returned');
        }
        
        // Get operation name - try direct .name first, then .operation.name
        final firstOp = (ops as List)[0] as Map<String, dynamic>;
        String? opName = firstOp['name'] as String?;
        if (opName == null && firstOp['operation'] is Map) {
          opName = (firstOp['operation'] as Map)['name'] as String?;
        }
        
        if (opName == null) {
          print('[MOBILE] No operation name found in: $firstOp');
          throw Exception('No operation name in response');
        }
        
        final sceneUuid = firstOp['sceneId']?.toString() ?? res['sceneId']?.toString() ?? opName; 
        
        scene.operationName = opName;
        setState(() { scene.status = 'polling'; });
        print('[MOBILE] Scene ${scene.sceneId} polling started. Op: $opName');
        
        // INLINE POLLING - use same generator (no background worker)
        bool done = false;
        int pollCount = 0;
        
        while(!done && isRunning && pollCount < 120) { // Max 10 min (120 * 5s)
           await Future.delayed(const Duration(seconds: 5));
           pollCount++;
           
           print('[MOBILE] Poll #$pollCount for scene ${scene.sceneId}...');
           
           final poll = await generator.pollVideoStatus(opName, opName, token);
           
           if (poll != null) {
              final status = poll['status'] as String?;
              print('[MOBILE] Poll result: status=$status');
              
              if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' || 
                  status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
                  
                  // Extract video URL from operation.metadata.video.fifeUrl
                  String? videoUrl;
                  if (poll.containsKey('operation')) {
                      final op = poll['operation'] as Map<String, dynamic>;
                      final metadata = op['metadata'] as Map<String, dynamic>?;
                      final video = metadata?['video'] as Map<String, dynamic>?;
                      videoUrl = video?['fifeUrl'] as String?;
                  }
                  
                  if (videoUrl != null) {
                     print('[MOBILE] Video URL found! Downloading...');
                     setState(() { scene.status = 'downloading'; });
                     
                     final fileName = 'mob_${scene.sceneId}.mp4';
                     final savePath = path.join(outputFolder, fileName);
                     
                     await generator.downloadVideo(videoUrl, savePath);
                     
                     setState(() {
                         scene.videoPath = savePath;
                         scene.status = 'completed';
                     });
                     done = true;
                     print('[MOBILE] Scene ${scene.sceneId} COMPLETED!');
                  } else {
                     throw Exception('No fifeUrl in success response');
                  }
              } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
                  throw Exception('Generation failed on server');
              }
              // else: still pending, keep polling
           } else {
              print('[MOBILE] Poll returned null, continuing...');
           }
        }
        
        if (!done && pollCount >= 120) {
           throw Exception('Polling timeout (10 minutes)');
        }
        
      } catch(e) {
         print('[MOBILE] Scene ${scene.sceneId} Error: $e');
         setState(() { scene.status = 'failed'; scene.error = e.toString(); });
      }
  }


  Future<void> _processGenerationQueue(List<SceneData> scenesToProcess) async {
    print('\n${'=' * 60}');
    print('THREAD 1: GENERATION PRODUCER STARTED');
    print('=' * 60);

    for (var i = 0; i < scenesToProcess.length; i++) {
      if (!isRunning) {
        print('\n[STOP] Generation stopped by user');
        break;
      }

      while (isPaused) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final scene = scenesToProcess[i];

      try {
        // Concurrency limit for Relaxed/Free model (4 slots)
        if (selectedModel.contains('relaxed')) {
          while (isRunning) {
            if (_activeGenerationsCount < 4) {
              break;
            }
            print('\r[LIMIT] Waiting for slots (Active: $_activeGenerationsCount/4)...');
            await Future.delayed(const Duration(seconds: 1));
          }
        }

        // Anti-detection: Random delay with jitter (2-5 seconds)
        if (i > 0) {
          final baseDelay = 1.0 / rateLimit;
          final jitter = 2.0 + (3.0 * (DateTime.now().millisecond / 1000.0));
          final totalDelay = baseDelay + jitter;
          print('\n[ANTI-BOT] Waiting ${totalDelay.toStringAsFixed(1)}s (base: ${baseDelay.toStringAsFixed(1)}s + jitter: ${jitter.toStringAsFixed(1)}s)');
          await Future.delayed(Duration(milliseconds: (totalDelay * 1000).toInt()));
        }

        // Upload images if provided
        String? startMediaId;
        String? endMediaId;

        if (scene.firstFramePath != null && scene.firstFrameMediaId == null) {
          print('[GENERATE] Uploading first frame image...');
          final result = await generator!.uploadImage(
            scene.firstFramePath!,
            accessToken!,
          );

          if (result is Map && result['error'] == true) {
            final errorMsg = result['message'] as String? ?? 'Upload failed';
            print('[GENERATE] ✗ $errorMsg');
            setState(() {
              scene.status = 'failed';
              scene.error = 'Image upload failed: $errorMsg';
            });
            continue;
          } else if (result is String) {
            startMediaId = result;
            scene.firstFrameMediaId = startMediaId;
            print('[GENERATE] ✓ First frame uploaded: $startMediaId');
          }
        } else if (scene.firstFrameMediaId != null) {
          startMediaId = scene.firstFrameMediaId;
        }

        if (scene.lastFramePath != null && scene.lastFrameMediaId == null) {
          print('[GENERATE] Uploading last frame image...');
          final result = await generator!.uploadImage(
            scene.lastFramePath!,
            accessToken!,
          );

          if (result is Map && result['error'] == true) {
            final errorMsg = result['message'] as String? ?? 'Upload failed';
            print('[GENERATE] ✗ $errorMsg');
            setState(() {
              scene.status = 'failed';
              scene.error = 'Image upload failed: $errorMsg';
            });
            continue;
          } else if (result is String) {
            endMediaId = result;
            scene.lastFrameMediaId = endMediaId;
            print('[GENERATE] ✓ Last frame uploaded: $endMediaId');
          }
        } else if (scene.lastFrameMediaId != null) {
          endMediaId = scene.lastFrameMediaId;
        }

        // Generate video using Direct API (matching Python app)
        setState(() {
          scene.status = 'generating';
        });

        final mode = (startMediaId != null || endMediaId != null) ? 'I2V' : 'T2V';
        print('\n[GENERATE ${i + 1}/${scenesToProcess.length}] Scene ${scene.sceneId} ($mode)');
        print('[GENERATE] Browser: $selectedProfile (Port: ${AppConfig.debugPort})');
        print('[GENERATE] Using Direct API Method (batchAsyncGenerateVideoText)');

        // Convert Flow UI model display name to API model key
        final apiModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
        print('[GENERATE] Model: $selectedModel -> API Key: $apiModelKey');

        // Generate video via API
        final result = await generator!.generateVideo(
          prompt: scene.prompt,
          accessToken: accessToken!,
          aspectRatio: selectedAspectRatio,
          model: apiModelKey, // Use converted API model key
          startImageMediaId: startMediaId,
          endImageMediaId: endMediaId,
        );

        if (result == null) {
          throw Exception('No result from generateVideo');
        }

        // Check for error status
        if (result['status'] != null && result['status'] != 200) {
          final statusCode = result['status'] as int;
          final errorMsg = result['error'] ?? result['statusText'] ?? 'API error';
          
          // Handle 403, 429, 503 errors with retry logic
          final action = await _handleApiError(
            statusCode: statusCode,
            scene: scene,
            errorMessage: errorMsg.toString(),
          );
          
          if (action == 'retry') {
            // Retry this scene
            i--;
            continue;
          } else if (action == 'pause') {
            return;
          }
          // 'skip' - continue to next scene
          continue;
        }

        if (result['success'] != true) {
          throw Exception(result['error'] ?? 'Generation failed');
        }

        // Extract operation name from nested structure
        final responseData = result['data'] as Map<String, dynamic>;
        final operations = responseData['operations'] as List?;
        if (operations == null || operations.isEmpty) {
          throw Exception('No operations in response');
        }

        final operationWrapper = operations[0] as Map<String, dynamic>;
        
        // The operation name is nested: operations[0].operation.name
        final operation = operationWrapper['operation'] as Map<String, dynamic>?;
        if (operation == null) {
          throw Exception('No operation object in response');
        }
        
        final operationName = operation['name'] as String?;
        if (operationName == null) {
          throw Exception('No operation name in response');
        }

        // Extract sceneId from the wrapper
        final sceneUuid = operationWrapper['sceneId'] as String? ?? result['sceneId'] as String?;

        scene.operationName = operationName;
        setState(() {
          scene.status = 'polling';
        });

        // Add to pending polls for the poll worker
        _activeGenerationsCount++;
        _pendingPolls.add(_PendingPoll(scene, sceneUuid ?? operationName));

        _consecutiveFailures = 0;
        print('[GENERATE] ✓ Scene ${scene.sceneId} queued for polling (operation: ${operationName.length > 50 ? operationName.substring(0, 50) + '...' : operationName})');
      } catch (e) {
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
        print('[GENERATE] ✗ Exception: $e');
        
        _consecutiveFailures++;
        if (_consecutiveFailures >= _maxConsecutiveFailures) {
          final action = await _handleContinuousFailures();
          if (action == 'pause') {
            return;
          }
        }
      }
    }
  }

  /// Multi-profile generation worker (uses round-robin across browsers)
  Future<void> _multiProfileGenerationWorker() async {
    try {
      print('\n${'=' * 60}');
      print('MULTI-BROWSER CONCURRENT GENERATION');
      int connectedCount = 0;
      if (Platform.isAndroid || Platform.isIOS) {
        connectedCount = MobileBrowserService().countConnected();
      } else {
        connectedCount = _profileManager!.countConnectedProfiles();
      }
      print('Connected Browsers: $connectedCount');
      print('=' * 60);

      // Get range
      final scenesToProcess = scenes
          .skip(fromIndex - 1)
          .take(toIndex - fromIndex + 1)
          .where((s) => s.status == 'queued')
          .toList();

      print('\n[QUEUE] Processing ${scenesToProcess.length} scenes (from $fromIndex to $toIndex)');
      print('[QUEUE] Model: $selectedModel');

      // Reset concurrent processing state
      _activeGenerationsCount = 0;
      _pendingPolls.clear();
      _generationComplete = false;

      // Start Polling Worker (runs in parallel)
      _pollWorker();

      // Determine concurrency limit based on model
      final isRelaxedModel = selectedModel.contains('Lower Priority') || 
                             selectedModel.contains('relaxed');
      final maxConcurrent = isRelaxedModel ? 4 : 10;
      print('[CONCURRENT] Max concurrent: $maxConcurrent');

      // Start Generation Loop with round-robin browser selection
      await _processMultiProfileQueue(scenesToProcess, maxConcurrent);

      // Signal completion and wait for polls to finish
      _generationComplete = true;
      
      // Wait for all active polls to complete, but also check for retries
      while (isRunning && (_pendingPolls.isNotEmpty || _activeGenerationsCount > 0)) {
        await Future.delayed(const Duration(seconds: 2));
        
        // Check if any scenes need retry (pushed back to queued)
        final retryScenes = scenes
            .where((s) => s.status == 'queued' && (s.retryCount ?? 0) > 0)
            .toList();
        
        if (retryScenes.isNotEmpty && _activeGenerationsCount < maxConcurrent) {
          print('[RETRY] Found ${retryScenes.length} scenes for retry');
          await _processMultiProfileQueue(retryScenes, maxConcurrent);
        }
      }

      print('\n${'=' * 60}');
      print('MULTI-BROWSER GENERATION COMPLETE');
      print('=' * 60);
    } catch (e) {
      print('\n[ERROR] Fatal error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generation error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isRunning = false;
        });
      }
    }
  }

  /// Process queue with multi-profile round-robin
  Future<void> _processMultiProfileQueue(List<SceneData> scenesToProcess, int maxConcurrent) async {
    print('\n${'=' * 60}');
    print('MULTI-PROFILE PRODUCER STARTED');
    print('=' * 60);

    for (var i = 0; i < scenesToProcess.length; i++) {
      if (!isRunning) {
        print('\n[STOP] Generation stopped by user');
        break;
      }

      while (isPaused) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Wait for available slot
      while (_activeGenerationsCount >= maxConcurrent && isRunning) {
        print('\r[LIMIT] Waiting for slots (Active: $_activeGenerationsCount/$maxConcurrent)...');
        await Future.delayed(const Duration(seconds: 1));
      }

      final scene = scenesToProcess[i];

      // Get next available browser (round-robin)
      dynamic profile;
      if (Platform.isAndroid || Platform.isIOS) {
        profile = MobileBrowserService().getNextAvailableProfile();
        
        // TRICK: Restore this profile's cookies before using it
        if (profile != null && profile is MobileProfile) {
          await profile.restoreCookies();
        }
      } else {
        profile = _profileManager!.getNextAvailableProfile();
      }
      if (profile == null) {
        print('[GENERATE] No available browsers, waiting...');
        await Future.delayed(const Duration(seconds: 2));
        i--; // Retry this scene
        continue;
      }

      try {
        // Anti-detection: Reduced random delay (0.2s - 1.0s) for speed
        if (i > 0) {
          final jitter = 0.2 + (0.8 * (DateTime.now().millisecond / 1000.0));
          print('\n[ANTI-BOT] Waiting ${jitter.toStringAsFixed(2)}s to optimize speed');
          await Future.delayed(Duration(milliseconds: (jitter * 1000).toInt()));
        }

        // Generate video using selected profile
        await _generateWithProfile(scene, profile, i + 1, scenesToProcess.length);

      } on _RetryableException catch (e) {
        // Retryable error (403, API errors) - push back to queue for retry
        scene.retryCount = (scene.retryCount ?? 0) + 1;
        
        if (scene.retryCount! < 7) {
          print('[RETRY] Scene ${scene.sceneId} retry ${scene.retryCount}/7 - pushing back to queue');
          setState(() {
            scene.status = 'queued';
            scene.error = 'Retrying (${scene.retryCount}/7): ${e.message}';
          });
          // Add back to end of processing list
          scenesToProcess.add(scene);
        } else {
          print('[GENERATE] ✗ Scene ${scene.sceneId} failed after 7 retries: ${e.message}');
          setState(() {
            scene.status = 'failed';
            scene.error = 'Failed after 7 retries: ${e.message}';
          });
        }
      } catch (e) {
        // Non-retryable error
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
        print('[GENERATE] ✗ Exception: $e');
      }
    }

    print('\n[PRODUCER] All scenes processed');
  }

  /// Generate a single video using a specific browser profile
  Future<void> _generateWithProfile(
    SceneData scene,
    dynamic profile,
    int currentIndex,
    int totalScenes,
  ) async {
    // Take slot IMMEDIATELY before API call
    _activeGenerationsCount++;
    print('[SLOT] Took slot - Active: $_activeGenerationsCount');

    setState(() {
      scene.status = 'generating';
    });

    print('\n[GENERATE $currentIndex/$totalScenes] Scene ${scene.sceneId}');
    print('[GENERATE] Browser: ${profile.name} (Port: ${profile.debugPort})');
    print('[GENERATE] Using Direct API Method (batchAsyncGenerateVideoText)');

    // Convert Flow UI model display name to API model key
    final apiModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
    print('[GENERATE] Model: $selectedModel -> API Key: $apiModelKey');

    // Generate video via API
    final result = await profile.generator!.generateVideo(
      prompt: scene.prompt,
      accessToken: profile.accessToken!,
      aspectRatio: selectedAspectRatio,
      model: apiModelKey,
    );

    if (result == null) {
      _activeGenerationsCount--; // Release slot on failure
      print('[SLOT] Released slot (null result) - Active: $_activeGenerationsCount');
      throw Exception('No result from generateVideo');
    }

    // Check for error status
    if (result['status'] != null && result['status'] != 200) {
      final statusCode = result['status'] as int;
      final errorMsg = result['error'] ?? result['statusText'] ?? 'API error';
      
      // Handle 403 error - increment profile counter and trigger relogin
      if (statusCode == 403) {
        profile.consecutive403Count++;
        print('[403] ${profile.name} 403 count: ${profile.consecutive403Count}/3');
        
        // Trigger relogin if threshold reached
        if (profile.consecutive403Count >= 3 && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty) {
          print('[403] ${profile.name} threshold reached, triggering relogin...');
          _loginService!.reloginProfile(profile, _savedEmail, _savedPassword);
        }
      }
      
      // Release slot
      _activeGenerationsCount--;
      print('[SLOT] Released slot (API error $statusCode) - Active: $_activeGenerationsCount');
      
      // For 403 and other errors, throw RetryableException to trigger retry
      throw _RetryableException('API error $statusCode: $errorMsg');
    }

    if (result['success'] != true) {
      _activeGenerationsCount--;
      print('[SLOT] Released slot (API failure) - Active: $_activeGenerationsCount');
      throw Exception(result['error'] ?? 'Generation failed');
    }

    // Extract operation name from response
    // API returns: data.operations[0].name directly (not nested in .operation)
    final responseData = result['data'] as Map<String, dynamic>;
    final operations = responseData['operations'] as List?;
    if (operations == null || operations.isEmpty) {
      _activeGenerationsCount--;
      print('[SLOT] Released slot (no operations) - Active: $_activeGenerationsCount');
      throw Exception('No operations in response');
    }

    final firstOp = operations[0] as Map<String, dynamic>;
    
    // Try direct .name first, then fall back to .operation.name
    String? operationName = firstOp['name'] as String?;
    if (operationName == null && firstOp['operation'] is Map) {
      operationName = (firstOp['operation'] as Map)['name'] as String?;
    }
    
    if (operationName == null) {
      _activeGenerationsCount--;
      print('[SLOT] Released slot (no operation name) - Active: $_activeGenerationsCount');
      print('[DEBUG] firstOp: $firstOp');
      throw Exception('No operation name in response');
    }

    // Get sceneId from operation or from top-level result
    final sceneUuid = firstOp['sceneId']?.toString() ?? result['sceneId']?.toString();

    scene.operationName = operationName;
    setState(() {
      scene.status = 'polling';
    });

    // Add to pending polls for the poll worker (slot already taken at start)
    _pendingPolls.add(_PendingPoll(scene, sceneUuid ?? operationName));

    _consecutiveFailures = 0;
    print('[GENERATE] ✓ Scene ${scene.sceneId} queued for polling (operation: ${operationName.length > 50 ? operationName.substring(0, 50) + '...' : operationName})');
  }

  /// Poll worker that monitors active operations and downloads completed videos
  /// Uses batch polling like Python - single API call for ALL videos
  Future<void> _pollWorker() async {
    print('\n${'=' * 60}');
    print('THREAD 2: POLLING CONSUMER STARTED (Batch Mode)');
    print('=' * 60);

    // Random poll interval 5-10 seconds like Python
    final random = Random();

    while (isRunning || _pendingPolls.isNotEmpty) {
      if (_pendingPolls.isEmpty) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      final pollInterval = 5; // Fixed 5 second interval
      LogService().mobile('[POLLER] Loop iteration - ${_pendingPolls.length} pending');
      print('\n[POLLER] Monitoring ${_pendingPolls.length} active videos... (Next check in ${pollInterval}s)');

      try {
        // Filter out polls with null operationName
        final validPolls = _pendingPolls.where((p) => p.scene.operationName != null).toList();
        
        if (validPolls.isEmpty) {
          LogService().mobile('[POLLER] No valid polls (all have null operationName)');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }
        
        // Build batch poll request (all operations at once)
        final pollRequests = validPolls.map((poll) => 
          PollRequest(poll.scene.operationName!, poll.sceneUuid)
        ).toList();

        // Find a generator to use for polling
        dynamic pollGenerator = generator;
        String? pollToken = accessToken;
        
        if (Platform.isAndroid || Platform.isIOS) {
          // Mobile Mode: find any connected mobile profile
          final mService = MobileBrowserService();
          for (final p in mService.profiles) {
             if (p.status == MobileProfileStatus.ready && p.generator != null && p.accessToken != null) {
                 pollGenerator = p.generator;
                 pollToken = p.accessToken;
                 break;
             }
          }
        } else if (_profileManager != null && _profileManager!.profiles.isNotEmpty) {
          for (final profile in _profileManager!.profiles) {
            if (profile.status == ProfileStatus.connected && 
                profile.generator != null && 
                profile.accessToken != null) {
              pollGenerator = profile.generator;
              pollToken = profile.accessToken;
              break;
            }
          }
        }

        if (pollGenerator == null || pollToken == null) {
          LogService().error('[POLLER] No connected browser - skipping poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        LogService().mobile('[POLLER] Calling pollVideoStatusBatch with ${pollRequests.length} requests...');
        
        // Batch poll with error handling
        final results = await pollGenerator.pollVideoStatusBatch(pollRequests, pollToken);
        
        LogService().mobile('[POLLER] pollVideoStatusBatch returned! Type: ${results.runtimeType}');
        
        // LOG FULL RAW RESPONSE
        LogService().mobile('=== BATCH POLL RAW RESPONSE ===');
        LogService().mobile('Results count: ${results?.length ?? 0}');
        if (results != null) {
          for (var i = 0; i < results.length; i++) {
            LogService().mobile('Result[$i]: ${jsonEncode(results[i])}');
          }
        } else {
          LogService().error('Batch poll returned NULL');
        }
        LogService().mobile('=== END RAW RESPONSE ===');
        
        if (results == null || results.isEmpty) {
          print('[POLLER] No results from batch poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        // Process results - MATCH BY OPERATION NAME
        final completedIndices = <int>[];
        
        for (final result in results) {
          // Get operation name from response
          String? opName;
          if (result.containsKey('operation') && result['operation'] is Map) {
            opName = (result['operation'] as Map)['name'] as String?;
          }
          
          // Fallback: try sceneId we sent (if API echoes it back)
          final sceneIdValue = result['sceneId'];
          final resultSceneId = sceneIdValue?.toString();
          
          // Find matching pending poll by operation name OR sceneId
          int pollIndex = -1;
          if (opName != null) {
            pollIndex = _pendingPolls.indexWhere((p) => p.scene.operationName == opName);
          }
          if (pollIndex == -1 && resultSceneId != null) {
            pollIndex = _pendingPolls.indexWhere((p) => p.sceneUuid == resultSceneId);
          }
          
          if (pollIndex == -1) {
            LogService().mobile('Poll result for unknown operation: opName=$opName, sceneId=$resultSceneId');
            continue;
          }
          
          final poll = _pendingPolls[pollIndex];
          final scene = poll.scene;
          
          final status = result['status'] as String?;
          
          LogService().mobile('Poll result for scene ${scene.sceneId}: status=$status');

          
          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            // Video is SUCCESSFUL - free up slot immediately
            _activeGenerationsCount--;
            print('[SLOT] Video ready, freed slot - Active: $_activeGenerationsCount');
            
            // Extract video URL from metadata
            String? videoUrl;
            
            if (result.containsKey('operation')) {
              final op = result['operation'] as Map<String, dynamic>;
              final metadata = op['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] as String?;
            }

            if (videoUrl != null) {
              print('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
              _downloadVideo(scene, videoUrl);
            } else {
              LogService().error('Could not extract fifeUrl from operation.metadata.video');
              setState(() {
                scene.status = 'failed';
                scene.error = 'No video URL';
              });
            }

            completedIndices.add(pollIndex);
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
            // Extract error
            String errorMsg = 'Generation failed';
            if (result.containsKey('operation')) {
              final metadata = (result['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
              final errorDetails = metadata?['error'] as Map<String, dynamic>?;
              if (errorDetails != null) {
                errorMsg = '${errorDetails['message'] ?? 'No details'} (Code: ${errorDetails['code'] ?? 'Unknown'})';
              }
            }

            // Retry logic - push back to queue instead of failing (will use next available browser)
            scene.retryCount = (scene.retryCount ?? 0) + 1;
            _activeGenerationsCount--;
            
            if (scene.retryCount! < 10) {
              print('[RETRY] Scene ${scene.sceneId} poll failed (${scene.retryCount}/10) - pushing back for regeneration with next browser');
              setState(() {
                scene.status = 'queued';
                scene.operationName = null; // Clear old operation
                scene.error = 'Retrying (${scene.retryCount}/10): $errorMsg';
              });
              // Scene will be picked up by generation worker on next cycle (round-robin to next browser)
            } else {
              print('[POLLER] ✗ Scene ${scene.sceneId} failed after 10 retries: $errorMsg');
              setState(() {
                scene.status = 'failed';
                scene.error = 'Failed after 10 retries: $errorMsg';
              });
            }
            
            completedIndices.add(pollIndex);
          }
          // PENDING or ACTIVE - keep polling
        }

        // Remove completed items (reverse order to keep indices valid)
        for (final index in completedIndices.reversed) {
          _pendingPolls.removeAt(index);
        }
        
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('closed') || errorStr.contains('WebSocket')) {
          print('[POLLER] WebSocket closed (browser relogging?) - skipping poll');
        } else {
          print('[POLLER] Error during batch poll: $e');
        }
      }

      // Wait before next poll cycle
      if (_pendingPolls.isNotEmpty) {
        await Future.delayed(Duration(seconds: pollInterval));
      }
    }
    
    print('[POLLER] Poll worker finished');
  }

  /// Download video in background
  Future<void> _downloadVideo(SceneData scene, String videoUrl) async {
    try {
      setState(() {
        scene.status = 'downloading';
      });

      print('[DOWNLOAD] Scene ${scene.sceneId} STARTED');

      // Find a valid generator for download
      dynamic downloadGenerator = generator;
      
      if (Platform.isAndroid || Platform.isIOS) {
          final mService = MobileBrowserService();
          for (final p in mService.profiles) {
             if (p.generator != null) {
                downloadGenerator = p.generator;
                break;
             }
          }
      } else if (downloadGenerator == null && _profileManager != null) {
        for (final profile in _profileManager!.profiles) {
          if (profile.status == ProfileStatus.connected && profile.generator != null) {
            downloadGenerator = profile.generator;
            break;
          }
        }
      }
      
      if (downloadGenerator == null) {
        throw Exception('No connected browser available for download');
      }

      // Use projectService for consistent path generation
      final outputPath = await widget.projectService.getVideoOutputPath(
        null,
        scene.sceneId,
        isQuickGenerate: false,
      );
      final fileSize = await downloadGenerator.downloadVideo(videoUrl, outputPath);

      setState(() {
        scene.videoPath = outputPath;
        scene.downloadUrl = videoUrl;
        scene.fileSize = fileSize;
        scene.generatedAt = DateTime.now().toIso8601String();
        scene.status = 'completed';
      });
      
      // Save progress to project
      await _savePromptsToProject();

      print('[DOWNLOAD] ✓ Scene ${scene.sceneId} Complete (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      setState(() {
        scene.status = 'failed';
        scene.error = 'Download failed: $e';
      });
      print('[DOWNLOAD] ✗ Scene ${scene.sceneId} Failed: $e');
    }
  }

  void _scheduleAutoSave() {
    autoSaveTimer?.cancel();
    autoSaveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (projectManager != null && isRunning) {
        projectManager!.save(scenes);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final completed = scenes.where((s) => s.status == 'completed').length;
    final failed = scenes.where((s) => s.status == 'failed').length;
    final pending = scenes.where((s) => s.status == 'queued').length;
    final active = scenes.where((s) => ['generating', 'polling', 'downloading'].contains(s.status)).length;
    final isMobileScreen = MediaQuery.of(context).size.width < 900;

    return Stack(
      children: [
        LayoutBuilder(
      builder: (context, constraints) {
        // Breakpoint for mobile/tablet
        final isMobile = constraints.maxWidth < 900;
        
        return Scaffold(
          appBar: AppBar(
            title: isMobile
              ? Row(
                  children: [
                    const Icon(Icons.video_library, size: 20),
                    const SizedBox(width: 8),
                    const Text('VEO3', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 8),
                    if (widget.isActivated)
                      const Icon(Icons.star, size: 16, color: Color(0xFFFFD700)),
                  ],
                )
              : Row(
                  children: [
                    const Icon(Icons.video_library, size: 24),
                    const SizedBox(width: 8),
                    const Text('VEO3 Infinity'),
                    const SizedBox(width: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.folder, size: 16),
                          const SizedBox(width: 4),
                          Text(
                            widget.project.name,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // PREMIUM badge
                    if (widget.isActivated)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFFD700), Color(0xFFFFA500)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.amber.withOpacity(0.4),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.star, size: 14, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              'PREMIUM',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                letterSpacing: 1,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            actions: [
              if (isMobile && (Platform.isAndroid || Platform.isIOS))
                IconButton(
                  icon: const Icon(Icons.web),
                  tooltip: 'Browsers',
                  onPressed: () {
                    final dynamic state = _mobileBrowserManagerKey.currentState;
                    state?.show();
                  },
                ),
              if (!isMobile) ...[
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Open export folder',
                  onPressed: () {
                    Process.run('explorer', [outputFolder]);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  tooltip: 'About',
                  onPressed: _showAboutDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.swap_horiz),
                  tooltip: 'Change project',
                  onPressed: widget.onChangeProject,
                ),
              ],
            ],
          ),
          drawer: isMobile
              ? Drawer(
                  width: 280,
                  child: Column(
                    children: [
                      // Compact header
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                        ),
                        child: SafeArea(
                          bottom: false,
                          child: Row(
                            children: [
                              const Icon(Icons.movie_creation, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.project.name,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: _buildDrawerContent(),
                      ),
                    ],
                  ),
                )
              : null,
          body: SafeArea(
            child: isMobile && (Platform.isAndroid || Platform.isIOS)
              // MOBILE: Top tabs layout
              ? Column(
                  children: [
                    // TOP TAB BAR - Compact
                    Material(
                      color: Colors.white,
                      elevation: 1,
                      child: TabBar(
                        controller: _mobileTabController,
                        indicatorColor: Colors.blue,
                        indicatorWeight: 2,
                        labelColor: Colors.blue,
                        unselectedLabelColor: Colors.grey,
                        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        unselectedLabelStyle: const TextStyle(fontSize: 12),
                        tabs: const [
                          Tab(text: 'Queue', height: 32),
                          Tab(text: 'Browser', height: 32),
                        ],
                      ),
                    ),
                    // TAB CONTENT
                    Expanded(
                      child: TabBarView(
                        controller: _mobileTabController,
                        children: [
                          // TAB 1: QUEUE - Model, Aspect, Scenes
                          _buildMobileQueueTab(completed, failed, pending, active),
                          // TAB 2: BROWSER - Profiles, Auto Login, Connect
                          _buildMobileBrowserTab(),
                        ],
                      ),
                    ),
                  ],
                )
              // DESKTOP: Row layout with sidebar
              : Row(
              children: [
                // Desktop Sidebar
                Container(
                  width: 240,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    border: Border(right: BorderSide(color: Colors.grey.shade300)),
                  ),
                  child: _buildDrawerContent(),
                ),

              // Main Content Area
              Expanded(
                child: Column(
                  children: [
                    // Queue Controls & Stats Area
                    Card(
                      margin: EdgeInsets.all(isMobile ? 4 : 8),
                      child: isMobile
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Header for collapsing (Mobile Only) - Inline & Compact
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                                  color: Colors.grey.shade50,
                                  child: Row(
                                    children: [
                                      const Text(
                                        "Dashboard",
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey),
                                      ),
                                      const Spacer(),
                                      // Compact collapse button
                                      InkWell(
                                        onTap: () {
                                          setState(() {
                                            _isControlsCollapsed = !_isControlsCollapsed;
                                          });
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(4.0),
                                          child: Icon(
                                            _isControlsCollapsed ? Icons.expand_more : Icons.expand_less,
                                            size: 18,
                                            color: Colors.grey.shade600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Mobile Body - Controls (only when not collapsed)
                                if (!_isControlsCollapsed)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Queue Controls Row (compact)
                                        _buildQueueControls(),
                                        const SizedBox(height: 4),
                                        // Quick Generate + From/To combined row
                                        Row(
                                          children: [
                                            // Quick Generate
                                            Expanded(
                                              flex: 3,
                                              child: SizedBox(
                                                height: 32,
                                                child: TextField(
                                                  controller: _quickPromptController,
                                                  maxLines: 1,
                                                  style: const TextStyle(fontSize: 11),
                                                  decoration: const InputDecoration(
                                                    hintText: 'Quick prompt...',
                                                    isDense: true,
                                                    border: OutlineInputBorder(),
                                                    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            SizedBox(
                                              height: 32,
                                              child: ElevatedButton(
                                                onPressed: isRunning ? null : () {
                                                  final prompt = _quickPromptController.text.trim();
                                                  if (prompt.isNotEmpty) {
                                                    setState(() {
                                                      scenes.add(SceneData(
                                                        sceneId: DateTime.now().millisecondsSinceEpoch,
                                                        prompt: prompt,
                                                      ));
                                                      _quickPromptController.clear();
                                                      fromIndex = scenes.length;
                                                      toIndex = scenes.length;
                                                    });
                                                    _startGeneration();
                                                  }
                                                },
                                                style: ElevatedButton.styleFrom(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                                  backgroundColor: Colors.blue,
                                                  foregroundColor: Colors.white,
                                                ),
                                                child: const Text('Go', style: TextStyle(fontSize: 11)),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            // From/To
                                            const Text('F:', style: TextStyle(fontSize: 10)),
                                            SizedBox(
                                              width: 36,
                                              height: 32,
                                              child: TextField(
                                                controller: _fromIndexController,
                                                keyboardType: TextInputType.number,
                                                style: const TextStyle(fontSize: 10),
                                                decoration: const InputDecoration(
                                                  isDense: true,
                                                  border: OutlineInputBorder(),
                                                  contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                                ),
                                                onChanged: (value) {
                                                  final parsed = int.tryParse(value);
                                                  if (parsed != null && parsed > 0) {
                                                    setState(() => fromIndex = parsed);
                                                  }
                                                },
                                              ),
                                            ),
                                            const Text('-', style: TextStyle(fontSize: 10)),
                                            SizedBox(
                                              width: 36,
                                              height: 32,
                                              child: TextField(
                                                controller: _toIndexController,
                                                keyboardType: TextInputType.number,
                                                style: const TextStyle(fontSize: 10),
                                                decoration: const InputDecoration(
                                                  isDense: true,
                                                  border: OutlineInputBorder(),
                                                  contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                                ),
                                                onChanged: (value) {
                                                  final parsed = int.tryParse(value);
                                                  if (parsed != null && parsed > 0) {
                                                    setState(() => toIndex = parsed);
                                                  }
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        StatsDisplay(
                                          total: scenes.length,
                                          completed: completed,
                                          failed: failed,
                                          pending: pending,
                                          active: active,
                                          isCompact: true,
                                        ),
                                      ],
                                    ),
                                  ),
                                // Collapsed stats
                                if (_isControlsCollapsed)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    child: StatsDisplay(
                                      total: scenes.length,
                                      completed: completed,
                                      failed: failed,
                                      pending: pending,
                                      active: active,
                                      isCompact: true,
                                    ),
                                  ),
                              ],
                            )
                          // Desktop View (Original Style - Fixed)
                          : Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Column(
                                children: [
                                  // Collapse/Expand Toggle
                                  Row(
                                    children: [
                                      IconButton(
                                        icon: Icon(_isControlsCollapsed ? Icons.expand_more : Icons.expand_less),
                                        tooltip: _isControlsCollapsed ? 'Expand Controls' : 'Collapse Controls',
                                        onPressed: () {
                                          setState(() {
                                            _isControlsCollapsed = !_isControlsCollapsed;
                                          });
                                        },
                                      ),
                                      Text(
                                        _isControlsCollapsed ? 'Show Controls' : 'Hide Controls',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (!_isControlsCollapsed) ...[
                                    const Divider(),
                                    Row(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: _buildQueueControls(),
                                        ),
                                        Container(
                                          width: 1,
                                          height: 80,
                                          color: Colors.grey.shade300,
                                          margin: const EdgeInsets.symmetric(horizontal: 16),
                                        ),
                                        Expanded(
                                          flex: 2,
                                          child: StatsDisplay(
                                            total: scenes.length,
                                            completed: completed,
                                            failed: failed,
                                            pending: pending,
                                            active: active,
                                          ),
                                        ),
                                      ],
                                    ),
                                    // Quick Generate - Always Visible
                                    const Divider(),
                                    Row(
                                      children: [
                                        const Text(
                                          'Quick:',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: TextField(
                                            controller: _quickPromptController,
                                            maxLines: 1,
                                            decoration: const InputDecoration(
                                              hintText: 'Enter prompt for quick generation...',
                                              isDense: true,
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        ElevatedButton.icon(
                                          onPressed: isRunning ? null : () {
                                            final prompt = _quickPromptController.text.trim();
                                            if (prompt.isNotEmpty) {
                                              setState(() {
                                                scenes.add(SceneData(
                                                  sceneId: DateTime.now().millisecondsSinceEpoch,
                                                  prompt: prompt,
                                                ));
                                                _quickPromptController.clear();
                                                fromIndex = scenes.length;
                                                toIndex = scenes.length;
                                              });
                                              _startGeneration();
                                            }
                                          },
                                          icon: const Icon(Icons.play_arrow),
                                          label: const Text('Generate'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.blue,
                                            foregroundColor: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                    // From/To Scene Numbers (Compact)
                                    const Divider(),
                                    Row(
                                      children: [
                                        const Text('From:', style: TextStyle(fontSize: 12)),
                                        const SizedBox(width: 6),
                                        SizedBox(
                                          width: 60,
                                          child: TextField(
                                            controller: _fromIndexController,
                                            keyboardType: TextInputType.number,
                                            style: const TextStyle(fontSize: 12),
                                            decoration: const InputDecoration(
                                              isDense: true,
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                            ),
                                            onChanged: (value) {
                                              final parsed = int.tryParse(value);
                                              if (parsed != null && parsed > 0) {
                                                setState(() {
                                                  fromIndex = parsed;
                                                });
                                              }
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        const Text('To:', style: TextStyle(fontSize: 12)),
                                        const SizedBox(width: 6),
                                        SizedBox(
                                          width: 60,
                                          child: TextField(
                                            controller: _toIndexController,
                                            keyboardType: TextInputType.number,
                                            style: const TextStyle(fontSize: 12),
                                            decoration: const InputDecoration(
                                              isDense: true,
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                            ),
                                            onChanged: (value) {
                                              final parsed = int.tryParse(value);
                                              if (parsed != null && parsed > 0) {
                                                setState(() {
                                                  toIndex = parsed;
                                                });
                                              }
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                  ],
                                ],
                              ),
                            ),
                    ),

                    // Scene List Area - Grid Layout
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(4),
                        gridDelegate: isMobile 
                          ? const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2, // 2 cards per row on mobile
                              childAspectRatio: 0.50, // Taller cards
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                            )
                          : const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 300,
                              childAspectRatio: 1.10,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: scenes.length,
                        itemBuilder: (context, index) {
                          final scene = scenes[index];
                          return SceneCard(
                            key: ValueKey(scene.sceneId),
                            scene: scene,
                            onPromptChanged: (newPrompt) {
                              setState(() {
                                scene.prompt = newPrompt;
                              });
                            },
                            onPickImage: (frameType) => _pickImageForScene(scene, frameType),
                            onClearImage: (frameType) => _clearImageForScene(scene, frameType),
                            onGenerate: () {
                              // Use queue-based generation (CDP method) instead of old single generation
                              setState(() {
                                fromIndex = index + 1; // 1-indexed
                                toIndex = index + 1;
                              });
                              _startGeneration();
                            },
                            onOpen: () => _openVideo(scene),
                            onDelete: () {
                              setState(() {
                                scenes.removeAt(index);
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              ],
            ),
          ),
        );
      },
    ),
    if (Platform.isAndroid || Platform.isIOS)
      MobileBrowserManagerWidget(
        key: _mobileBrowserManagerKey,
        onVisibilityChanged: (_) => setState((){}),
      ),
    ],
  );
}

  Widget _buildQueueControls() {
    return QueueControls(
      fromIndex: fromIndex,
      toIndex: toIndex,
      rateLimit: rateLimit,
      selectedModel: selectedModel,
      selectedAspectRatio: selectedAspectRatio,
      selectedAccountType: selectedAccountType,
      isRunning: isRunning,
      isPaused: isPaused,
      onFromChanged: (value) => setState(() => fromIndex = value),
      onToChanged: (value) => setState(() => toIndex = value),
      onRateLimitChanged: (value) => setState(() => rateLimit = value),
      onModelChanged: (value) {
        setState(() => selectedModel = value);
        _savePreferences();
      },
      onAspectRatioChanged: (value) {
        setState(() => selectedAspectRatio = value);
        _savePreferences();
      },
      onAccountTypeChanged: (value) {
        setState(() => selectedAccountType = value);
        _savePreferences();
      },
      onStart: _startGeneration,
      onPause: _pauseGeneration,
      onStop: _stopGeneration,
      onRetryFailed: _retryFailed,
      selectedProfile: selectedProfile,
      profiles: profiles,
      onProfileChanged: (value) => setState(() => selectedProfile = value),
      onLaunchChrome: _launchChrome,
      onCreateProfile: _createNewProfile,
      onDeleteProfile: _deleteProfile,
      profileManager: _profileManager,
      onAutoLogin: _handleAutoLogin,
      onLoginAll: _handleLoginAll,
      onConnectOpened: _handleConnectOpened,
      onOpenWithoutLogin: _handleOpenWithoutLogin,
      initialEmail: _savedEmail,
      initialPassword: _savedPassword,
      onCredentialsChanged: (email, password) {
        setState(() {
          _savedEmail = email;
          _savedPassword = password;
        });
        _savePreferences();
      },
    );
  }

  // MOBILE TAB 1: Queue - EXACT same layout as original mobile view
  Widget _buildMobileQueueTab(int completed, int failed, int pending, int active) {
    return Column(
      children: [
        // Queue Controls & Stats Area - EXACT same as original mobile Card
        Card(
          margin: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Stats/Monitoring with overlay collapse button
              Stack(
                children: [
                  // Stats row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: StatsDisplay(
                      total: scenes.length,
                      completed: completed,
                      failed: failed,
                      pending: pending,
                      active: active,
                      isCompact: true,
                    ),
                  ),
                  // Overlay collapse button
                  Positioned(
                    right: 4,
                    top: 0,
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _isControlsCollapsed = !_isControlsCollapsed;
                        });
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          _isControlsCollapsed ? Icons.expand_more : Icons.expand_less,
                          size: 14,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // Mobile Body - Controls (only when not collapsed)
              if (!_isControlsCollapsed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Queue Controls Row (compact)
                      _buildQueueControls(),
                      const SizedBox(height: 4),
                      // From/To Range
                      Row(
                        children: [
                          const Text('Range:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500)),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 40,
                            height: 28,
                            child: TextField(
                              controller: _fromIndexController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 10),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                              ),
                              onChanged: (value) {
                                final parsed = int.tryParse(value);
                                if (parsed != null && parsed > 0) {
                                  setState(() => fromIndex = parsed);
                                }
                              },
                            ),
                          ),
                          const Text(' - ', style: TextStyle(fontSize: 10)),
                          SizedBox(
                            width: 40,
                            height: 28,
                            child: TextField(
                              controller: _toIndexController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 10),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                              ),
                              onChanged: (value) {
                                final parsed = int.tryParse(value);
                                if (parsed != null && parsed > 0) {
                                  setState(() => toIndex = parsed);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              // Quick Prompt Input - Always visible, outside collapsible area
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _quickPromptController,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 12),
                          decoration: const InputDecoration(
                            hintText: 'Quick prompt... (Enter to add & generate)',
                            hintStyle: TextStyle(fontSize: 11),
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          onSubmitted: (value) {
                            if (value.trim().isNotEmpty) {
                              setState(() {
                                scenes.add(SceneData(
                                  sceneId: DateTime.now().millisecondsSinceEpoch,
                                  prompt: value.trim(),
                                ));
                                _quickPromptController.clear();
                                fromIndex = scenes.length;
                                toIndex = scenes.length;
                              });
                              _startGeneration();
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      height: 36,
                      child: ElevatedButton(
                        onPressed: isRunning ? null : () {
                          final prompt = _quickPromptController.text.trim();
                          if (prompt.isNotEmpty) {
                            setState(() {
                              scenes.add(SceneData(
                                sceneId: DateTime.now().millisecondsSinceEpoch,
                                prompt: prompt,
                              ));
                              _quickPromptController.clear();
                              fromIndex = scenes.length;
                              toIndex = scenes.length;
                            });
                            _startGeneration();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Go', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Scene Grid - 2 per row
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.70,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: scenes.length,
            itemBuilder: (context, index) {
              final scene = scenes[index];
              return SceneCard(
                key: ValueKey(scene.sceneId),
                scene: scene,
                onPromptChanged: (p) => setState(() => scene.prompt = p),
                onPickImage: (f) => _pickImageForScene(scene, f),
                onClearImage: (f) => _clearImageForScene(scene, f),
                onGenerate: () { setState(() { fromIndex = index + 1; toIndex = index + 1; }); _startGeneration(); },
                onOpen: () => _openVideo(scene),
                onOpenFolder: () => _openVideoFolder(scene),
                onDelete: () => setState(() => scenes.removeAt(index)),
              );
            },
          ),
        ),
      ],
    );
  }

  // MOBILE TAB 2: Browser - Profiles, Auto Login, Connect + Console
  Widget _buildMobileBrowserTab() {
    final service = MobileBrowserService();
    
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Multi-Browser Controls - FIRST (moved to top)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Multi-Browser Login', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  CompactProfileManagerWidget(
                    profileManager: _profileManager,
                    onAutoLogin: _handleAutoLogin,
                    onLoginAll: _handleLoginAll,
                    onConnectOpened: _handleConnectOpened,
                    onOpenWithoutLogin: _handleOpenWithoutLogin,
                    initialEmail: _savedEmail,
                    initialPassword: _savedPassword,
                    onCredentialsChanged: (email, password) {
                      setState(() {
                        _savedEmail = email;
                        _savedPassword = password;
                      });
                      _savePreferences();
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          
          // Browser Status Card - Collapsible
          Card(
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              leading: const Icon(Icons.web, size: 20),
              title: Row(
                children: [
                  const Text('Mobile Browser Profiles', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(width: 8),
                  // Count badge
                  if (service.profiles.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: service.profiles.any((p) => p.status == MobileProfileStatus.ready) 
                            ? Colors.green.shade100 
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${service.profiles.where((p) => p.status == MobileProfileStatus.ready).length}/${service.profiles.length}',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => setState(() {}),
                tooltip: 'Refresh Status',
              ),
              children: [
                // Profile list with status - scrollable
                if (service.profiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No browser profiles loaded', style: TextStyle(color: Colors.grey)),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 250), // Limit height for scroll
                    child: SingleChildScrollView(
                      child: Column(
                        children: service.profiles.asMap().entries.map((entry) {
                          final index = entry.key;
                          final profile = entry.value;
                          final hasToken = profile.accessToken != null && profile.accessToken!.isNotEmpty;
                          final statusText = profile.status == MobileProfileStatus.ready 
                              ? 'Ready' 
                              : profile.status == MobileProfileStatus.connected 
                                  ? 'Connected' 
                                  : profile.status == MobileProfileStatus.loading
                                      ? 'Loading...'
                                      : 'Disconnected';
                          final statusColor = profile.status == MobileProfileStatus.ready 
                              ? Colors.green 
                              : profile.status == MobileProfileStatus.connected 
                                  ? Colors.orange 
                                  : profile.status == MobileProfileStatus.loading
                                      ? Colors.blue
                                      : Colors.grey;
                          
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 10, height: 10,
                                      decoration: BoxDecoration(
                                        color: statusColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text('Browser ${index + 1}', style: const TextStyle(fontWeight: FontWeight.w500)),
                                    const SizedBox(width: 8),
                                    Text(statusText, style: TextStyle(fontSize: 11, color: statusColor)),
                                    if (hasToken) ...[
                                      const Spacer(),
                                      IconButton(
                                        icon: const Icon(Icons.copy, size: 14),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          Clipboard.setData(ClipboardData(text: profile.accessToken!));
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Token ${index + 1} copied!')),
                                          );
                                        },
                                        tooltip: 'Copy Token',
                                      ),
                                    ],
                                  ],
                                ),
                                if (hasToken) ...[
                                  const SizedBox(height: 4),
                                  Container(
                                    width: double.infinity,
                                    constraints: const BoxConstraints(maxHeight: 60),
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: Colors.green.shade200),
                                    ),
                                    child: SingleChildScrollView(
                                      child: SelectableText(
                                        profile.accessToken!,
                                        style: TextStyle(fontSize: 9, color: Colors.green.shade800, fontFamily: 'monospace'),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          
          // Console Output - like PC console
          Expanded(
            child: Card(
              color: Colors.grey.shade900,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    color: Colors.grey.shade800,
                    child: Row(
                      children: [
                        const Icon(Icons.terminal, size: 14, color: Colors.greenAccent),
                        const SizedBox(width: 6),
                        const Text('Console', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.clear_all, size: 16, color: Colors.grey),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            LogService().clear();
                            setState(() {});
                          },
                          tooltip: 'Clear',
                        ),
                      ],
                    ),
                  ),
                  // Log output
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(6),
                      reverse: true,
                      itemCount: LogService().logs.length,
                      itemBuilder: (context, index) {
                        final logEntry = LogService().logs[LogService().logs.length - 1 - index];
                        final logText = logEntry.toString();
                        Color textColor = Colors.white70;
                        if (logText.contains('ERROR') || logText.contains('✗')) {
                          textColor = Colors.redAccent;
                        } else if (logText.contains('SUCCESS') || logText.contains('✓') || logText.contains('READY')) {
                          textColor = Colors.greenAccent;
                        } else if (logText.contains('WARNING') || logText.contains('⚠')) {
                          textColor = Colors.orangeAccent;
                        }
                        return Text(
                          logText,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 9,
                            fontFamily: 'monospace',
                            height: 1.2,
                          ),
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
    );
  }


  Widget _buildDrawerContent() {
    final isMobile = MediaQuery.of(context).size.width < 900;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // BULK REEL Feature Card - Prominent at top
                InkWell(
                  onTap: () {
                    Navigator.pop(context); // Close drawer
                    _openStoryAudio(goToReelTab: true);
                  },
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.deepPurple.shade600, Colors.orange.shade600],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.deepPurple.withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.local_fire_department, color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'BULK REEL',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Auto-generate story reels',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.85),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text(
                    'File Operations',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                _buildSidebarButton(
                  icon: Icons.folder_open,
                  label: 'Load JSON/TXT',
                  onPressed: _loadFile,
                ),
                _buildSidebarButton(
                  icon: Icons.content_paste,
                  label: 'Paste JSON',
                  onPressed: _pasteJson,
                ),
                _buildSidebarButton(
                  icon: Icons.save,
                  label: 'Save Project',
                  onPressed: _saveProject,
                ),
                _buildSidebarButton(
                  icon: Icons.folder,
                  label: 'Load Project',
                  onPressed: _loadProject,
                ),
                _buildSidebarButton(
                  icon: Icons.folder_special,
                  label: 'Set Output Folder',
                  onPressed: _setOutputFolder,
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text(
                    'Actions',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                if (Platform.isAndroid || Platform.isIOS) ...[
                  // Browser controls moved to Browser tab
                ],
                _buildSidebarButton(
                  icon: Icons.bolt,
                  label: 'Heavy Bulk Tasks',
                  onPressed: _openHeavyBulkTasks,
                  iconColor: Colors.amber.shade600,
                ),
                _buildSidebarButton(
                  icon: Icons.audiotrack,
                  label: 'Bulk REELS + Manual Audio',
                  onPressed: _openStoryAudio,
                  iconColor: Colors.purple.shade600,
                  badge: 'NEW',
                  badgeColor: Colors.orange,
                  isHighlighted: true,
                ),
                _buildSidebarButton(
                  icon: Icons.video_library,
                  label: 'Join Video Clips / Export',
                  onPressed: _concatenateVideos,
                ),
                _buildSidebarButton(
                  icon: Icons.terminal,
                  label: 'FFmpeg Info',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FFmpegInfoScreen()),
                    );
                  },
                  iconColor: Colors.deepPurple,
                ),
                
                // Collapsed Quick Generate (shows when bulk scenes are loaded)
                if (_isQuickInputCollapsed) ...[
                  const Divider(),
                  const Padding(
                    padding: EdgeInsets.all(12.0),
                    child: Text(
                      'Quick Generate',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _isQuickInputCollapsed = false;
                        });
                      },
                      icon: const Icon(Icons.flash_on, size: 18),
                      label: const Text('Expand', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        backgroundColor: Colors.amber.shade100,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        
        // About button at bottom
        const Divider(),
        _buildSidebarButton(
          icon: Icons.info_outline,
          label: 'About',
          onPressed: _showAboutDialog,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSidebarButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? iconColor,
    String? badge,
    Color? badgeColor,
    bool isHighlighted = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: isHighlighted ? 16 : 12,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: isHighlighted ? 13 : 12,
                  fontWeight: isHighlighted ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.visible,
                maxLines: 2,
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      badgeColor ?? Colors.green,
                      (badgeColor ?? Colors.green).withOpacity(0.7),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: (badgeColor ?? Colors.green).withOpacity(0.5),
                      blurRadius: 6,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileTokenDisplay() {
    if (!Platform.isAndroid && !Platform.isIOS) return const SizedBox.shrink();
    final service = MobileBrowserService();
    if (service.profiles.isEmpty) return const SizedBox.shrink();
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
           const Text('Mobile Sessions:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
           const SizedBox(height: 4),
           ...service.profiles.map((p) {
              final hasToken = p.accessToken != null && p.accessToken!.isNotEmpty;
              final tokenPreview = hasToken ? p.accessToken!.substring(0, min(8, p.accessToken!.length)) + '...' : 'No Token';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Row(
                  children: [
                    Icon(hasToken ? Icons.check_circle : Icons.cancel, size: 12, color: hasToken ? Colors.green : Colors.red),
                    const SizedBox(width: 6),
                    Text(
                      '${p.name}: $tokenPreview',
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: hasToken ? Colors.green.shade700 : Colors.red.shade700),
                    )
                  ],
                ),
              );
           }).toList()
        ],
      ),
    );
  }

  Future<void> _pickImageForScene(SceneData scene, String frameType) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        if (frameType == 'first') {
          scene.firstFramePath = result.files.single.path;
          scene.firstFrameMediaId = null;
        } else {
          scene.lastFramePath = result.files.single.path;
          scene.lastFrameMediaId = null;
        }
      });
    }
  }

  void _clearImageForScene(SceneData scene, String frameType) {
    setState(() {
      if (frameType == 'first') {
        scene.firstFramePath = null;
        scene.firstFrameMediaId = null;
      } else {
        scene.lastFramePath = null;
        scene.lastFrameMediaId = null;
      }
    });
  }

  Future<void> _runSingleGeneration(SceneData scene) async {
    if (!_checkActivation('Video Generation')) return;
    
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
       final service = MobileBrowserService();
       final profile = service.getProfile(0);
       
       if (profile != null && profile.status == MobileProfileStatus.ready) {
           _mobileRunSingle(scene, profile);
       } else {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mobile: Not logged in')));
       }
       return;
    }
    
    if (isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please stop bulk generation first')),
      );
      return;
    }

    try {
      setState(() {
        scene.status = 'generating';
        scene.error = null;
      });

      // Connect with retry logic
      print('[SINGLE] Connecting to Chrome...');
      int connectionAttempts = 0;
      const maxConnectionAttempts = 2;
      
      while (connectionAttempts < maxConnectionAttempts) {
        try {
          generator = BrowserVideoGenerator();
          await generator!.connect();
          print('[SINGLE] ✓ Connected');
          break;
        } catch (e) {
          connectionAttempts++;
          print('[SINGLE] Connection attempt $connectionAttempts failed');
          if (connectionAttempts >= maxConnectionAttempts) {
             print('[SINGLE] Launching chrome...');
             await _launchChrome();
             await Future.delayed(const Duration(seconds: 4));
             try { await generator!.connect(); break; } catch(z) { rethrow; }
          }
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      // Prepare Output parameters
      final fileName = 'scene_${scene.sceneId.toString().padLeft(3, '0')}.mp4';
      final outputPath = path.join(outputFolder, fileName);
      
      // Map params for Flow UI
      final flowAspectRatio = selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE' ? 'Landscape (16:9)' : 'Portrait (9:16)';
      
      print('[SINGLE] Generating via Flow UI...');
      final videoPath = await generator!.generateVideoCompleteFlow(
        prompt: scene.prompt,
        outputPath: outputPath,
        aspectRatio: flowAspectRatio,
        model: selectedModel,
        numberOfVideos: 1,
      );

      if (videoPath != null) {
        final file = File(videoPath);
        final fileSize = await file.length();
        setState(() {
          scene.videoPath = videoPath;
          scene.fileSize = fileSize;
          scene.generatedAt = DateTime.now().toIso8601String();
          scene.status = 'completed';
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scene ${scene.sceneId} completed!')));
        }
      } else {
        throw Exception('Flow UI generation failed.');
      }

    } catch (e) {
      print('[SINGLE] Error: $e');
      setState(() {
        scene.status = 'failed';
        scene.error = e.toString();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
       generator?.close();
    }
  }

  Future<void> _pollAndDownloadSingle(SceneData scene, String sceneUuid) async {
    while (scene.status == 'polling') {
      try {
        final operationData = await generator!.pollVideoStatus(
          scene.operationName!,
          sceneUuid,
          accessToken!,
        );

        if (operationData != null) {
          final status = operationData['status'] as String?;

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            String? videoUrl;
            if (operationData.containsKey('operation')) {
              final metadata = (operationData['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] as String?;
            }

            if (videoUrl != null) {
              print('[SINGLE] Scene ${scene.sceneId} READY -> Downloading...');
              setState(() {
                scene.status = 'downloading';
              });

              final outputPath = path.join(outputFolder, 'scene_${scene.sceneId.toString().padLeft(3, '0')}.mp4');
              final fileSize = await generator!.downloadVideo(videoUrl, outputPath);

              setState(() {
                scene.videoPath = outputPath;
                scene.downloadUrl = videoUrl;
                scene.fileSize = fileSize;
                scene.generatedAt = DateTime.now().toIso8601String();
                scene.status = 'completed';
              });

              print('[SINGLE] ✓ Scene ${scene.sceneId} Complete (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Scene ${scene.sceneId} completed!')),
                );
              }
            } else {
              throw Exception('No video URL in response');
            }
            break;
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
            throw Exception('Generation failed on server');
          }
        }

        await Future.delayed(const Duration(seconds: 10));
      } catch (e) {
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
        print('[SINGLE] ✗ Polling error: $e');
        break;
      }
    }
  }

  /// Quick generate a single video from home screen input
  Future<void> _quickGenerate() async {
    if (!_checkActivation('Quick Generate')) return;
    
    final prompt = _quickPromptController.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a prompt')),
      );
      return;
    }

    if (_isQuickGenerating) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Generation already in progress')),
      );
      return;
    }

    setState(() {
      _isQuickGenerating = true;
      _quickGeneratedScene = SceneData(
        sceneId: 0,
        prompt: prompt,
        status: 'generating',
      );
    });

    try {
      // Connect to browser
      print('[QUICK] Connecting to Chrome...');
      generator = BrowserVideoGenerator();
      await generator!.connect();

      // Check which generation method to use
      // All account types use Flow UI automation
        // ========== FLOW UI AUTOMATION METHOD ==========
        print('[QUICK] Using Flow UI Automation method');
        
        // Map aspect ratio to Flow UI format
        final flowAspectRatio = selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE'
            ? 'Landscape (16:9)'
            : 'Portrait (9:16)';
        
        // selectedModel is already in Flow UI format (e.g., 'Veo 3.1 - Fast [Lower Priority]')
        // No conversion needed
        final flowModel = selectedModel;
        
        print('[QUICK] Flow settings: $flowAspectRatio, $flowModel');
        
        // Generate output path
        final outputPath = await widget.projectService.getVideoOutputPath(
          _quickGeneratedScene!.prompt,
          _quickGeneratedScene!.sceneId,
          isQuickGenerate: true,
        );
        
        // Use Flow UI automation
        final videoPath = await generator!.generateVideoCompleteFlow(
          prompt: prompt,
          outputPath: outputPath,
          aspectRatio: flowAspectRatio,
          model: flowModel,
          numberOfVideos: 1,
        );
        
        if (videoPath != null) {
          // Video already downloaded by Flow UI method
          final file = File(videoPath);
          final fileSize = await file.length();
          
          setState(() {
            _quickGeneratedScene!.videoPath = videoPath;
            _quickGeneratedScene!.fileSize = fileSize;
            _quickGeneratedScene!.generatedAt = DateTime.now().toIso8601String();
            _quickGeneratedScene!.status = 'completed';
          });
          
          print('[QUICK] ✓ Video saved to: $videoPath');
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✓ Video generated! ${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          throw Exception('Flow UI generation failed or timed out');
        }
        
    } catch (e) {
      setState(() {
        if (_quickGeneratedScene != null) {
          _quickGeneratedScene!.status = 'failed';
          _quickGeneratedScene!.error = e.toString();
        }
      });
      print('[QUICK] ✗ Error: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Generation failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isQuickGenerating = false;
      });
    }
  }

  Future<void> _pollAndDownloadQuick(String sceneUuid) async {
    final scene = _quickGeneratedScene!;
    
    while (scene.status == 'polling') {
      try {
        final operationData = await generator!.pollVideoStatus(
          scene.operationName!,
          sceneUuid,
          accessToken!,
        );

        if (operationData != null) {
          final status = operationData['status'] as String?;

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' || 
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            // Get video URL
            String? videoUrl;
            if (operationData.containsKey('operation')) {
              final metadata = (operationData['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] as String?;
            }

            if (videoUrl != null) {
              setState(() {
                scene.status = 'downloading';
              });

              print('[QUICK] Downloading video...');
              // Use prompt-based filename for quick generate
              final outputPath = await widget.projectService.getVideoOutputPath(
                _quickPromptController.text,
                _quickGeneratedScene!.sceneId,
                isQuickGenerate: true,
              );
              final fileSize = await generator!.downloadVideo(videoUrl, outputPath);

              setState(() {
                scene.videoPath = outputPath;
                scene.downloadUrl = videoUrl;
                scene.fileSize = fileSize;
                scene.generatedAt = DateTime.now().toIso8601String();
                scene.status = 'completed';
              });

              print('[QUICK] ✓ Video saved to: $outputPath');
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('✓ Video generated! ${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } else {
              throw Exception('No video URL in response');
            }
            break;
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
            throw Exception('Generation failed on server');
          }
        }

        await Future.delayed(const Duration(seconds: 10));
      } catch (e) {
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
        print('[QUICK] ✗ Polling error: $e');
        break;
      }
    }
  }

  void _openVideo(SceneData scene) async {
    if (scene.videoPath == null || !File(scene.videoPath!).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video file not found')),
      );
      return;
    }
    
    if (Platform.isAndroid || Platform.isIOS) {
      // Use open_filex to open video with system player
      final result = await OpenFilex.open(scene.videoPath!);
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open video: ${result.message}')),
        );
      }
    } else if (Platform.isWindows) {
      Process.run('explorer', ['/select,', scene.videoPath!]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', scene.videoPath!]);
    }
  }
  
  void _openVideoFolder(SceneData scene) async {
    if (scene.videoPath == null) {
      // Share option for folder access
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Videos saved in: $outputFolder'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Copy Path',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: outputFolder));
            },
          ),
        ),
      );
      return;
    }
    
    if (Platform.isAndroid || Platform.isIOS) {
      // On mobile, show share dialog which allows opening in file manager
      await Share.shareXFiles(
        [XFile(scene.videoPath!)],
        text: 'Video from VEO3',
      );
    } else if (Platform.isWindows) {
      final folder = path.dirname(scene.videoPath!);
      Process.run('explorer', [folder]);
    } else if (Platform.isMacOS) {
      final folder = path.dirname(scene.videoPath!);
      Process.run('open', [folder]);
    }
  }

  /// Get status color for quick generate display
  Color _getQuickStatusColor() {
    if (_quickGeneratedScene == null) return Colors.grey;
    switch (_quickGeneratedScene!.status) {
      case 'generating':
        return Colors.blue;
      case 'polling':
        return Colors.cyan;
      case 'downloading':
        return Colors.orange;
      case 'completed':
        return Colors.green;
      case 'failed':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  /// Get status text for quick generate display
  String _getQuickStatusText() {
    if (_quickGeneratedScene == null) return '';
    switch (_quickGeneratedScene!.status) {
      case 'generating':
        return '⏳ Generating video...';
      case 'polling':
        return '🔄 Processing on server...';
      case 'downloading':
        return '⬇️ Downloading video...';
      case 'completed':
        return '✓ Video ready!';
      case 'failed':
        return '✗ Generation failed';
      default:
        return _quickGeneratedScene!.status;
    }
  }

  // ========== MULTI-PROFILE LOGIN HANDLERS ==========

  /// Handle auto login (single profile with automated Google OAuth)
  Future<void> _handleAutoLogin(String email, String password) async {
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
      print('[UI] Mobile Auto Login initiated');
      final service = MobileBrowserService();
      service.initialize(1);
      
      final dynamic state = _mobileBrowserManagerKey.currentState;
      state?.show(); // Ensure visible
      
      // Allow WebView to initialize
      await Future.delayed(const Duration(seconds: 1));
      
      final profile = service.getProfile(0);
      if (profile != null) {
        if (profile.generator != null) {
          final success = await profile.generator!.autoLogin(email, password);
          if (success) {
            profile.status = MobileProfileStatus.ready;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mobile Login Successful!'), backgroundColor: Colors.green));
            }
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mobile Login Finished (Check if 2FA needed)'), backgroundColor: Colors.orange));
            }
          }
        } else {
           print('[UI] Mobile generator not ready yet (WebView loading?)');
        }
      }
      setState(() {});
      return;
    }

    try {
      print('[UI] Auto login started...');
      
      // Initialize single profile if not already done
      if (_profileManager!.profiles.isEmpty) {
        await _profileManager!.initializeProfiles(1);
      }
      
      final profile = _profileManager!.profiles.first;
      
      // Launch if not running
      if (profile.status == ProfileStatus.disconnected) {
        await _profileManager!.launchProfile(profile);
      }
      
      // Auto login
      await _loginService!.autoLogin(
        profile: profile,
        email: email,
        password: password,
      );
      
      // Reload profiles dropdown to show newly created profiles
      await _loadProfiles();
      
      setState(() {});
      print('[UI] ✓ Auto login complete');
    } catch (e) {
      print('[UI] ✗ Auto login failed: $e');
      rethrow;
    }
  }

  /// Handle login all profiles (multi-profile with automated login)
  Future<void> _handleLoginAll(int count, String email, String password) async {
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
       print('[UI] Mobile Login All initiated for $count profiles');
       final service = MobileBrowserService();
       service.initialize(count);
       
       final dynamic state = _mobileBrowserManagerKey.currentState;
       state?.show();
       
       await Future.delayed(const Duration(seconds: 2));
       
       // CLEAR ALL COOKIES ONCE at the start for fresh login
       final cookieManager = CookieManager.instance();
       await cookieManager.deleteAllCookies();
       print('[UI] Cleared all cookies before login');
       
       int successCount = 0;
       
       // Login FIRST browser to establish session
       final firstProfile = service.getProfile(0);
       if (firstProfile != null && firstProfile.generator != null) {
          print('[UI] ========== Logging in first browser ==========');
          firstProfile.status = MobileProfileStatus.loading;
          setState(() {});
          
          final success = await firstProfile.generator!.autoLogin(email, password);
          
          if (success) {
            final token = await firstProfile.generator!.getAccessToken();
            if (token != null && token.isNotEmpty) {
              firstProfile.accessToken = token;
              firstProfile.status = MobileProfileStatus.ready;
              successCount++;
              print('[UI] ✓ First browser logged in with token');
              
              // Now fetch token from EACH other browser (they share the session)
              for (int i = 1; i < count; i++) {
                final profile = service.getProfile(i);
                if (profile != null && profile.generator != null) {
                  profile.status = MobileProfileStatus.loading;
                  setState(() {});
                  
                  // Each browser fetches its own token from the shared session
                  final browserToken = await profile.generator!.getAccessToken();
                  if (browserToken != null && browserToken.isNotEmpty) {
                    profile.accessToken = browserToken;
                    profile.status = MobileProfileStatus.ready;
                    successCount++;
                    print('[UI] ✓ Browser ${i + 1} fetched token');
                  } else {
                    profile.status = MobileProfileStatus.connected;
                    print('[UI] ✗ Browser ${i + 1} - no token');
                  }
                  setState(() {});
                }
              }
            } else {
              firstProfile.status = MobileProfileStatus.connected;
              print('[UI] ✗ First browser - no token');
            }
          } else {
            firstProfile.status = MobileProfileStatus.connected;
            print('[UI] ✗ First browser login failed');
          }
       }
       
       print('[UI] ========== Login All Complete: $successCount/$count ==========');
       setState(() {});
       
       if (successCount > 0) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('✓ $successCount/$count browsers connected')),
         );
       } else {
         ScaffoldMessenger.of(context).showSnackBar(
           const SnackBar(content: Text('✗ Login failed')),
         );
       }
       return;
    }

    try {
      print('[UI] Login all started for $count profiles...');
      
      await _loginService!.loginAllProfiles(count, email, password);
      
      // Reload profiles dropdown to show newly created profiles
      await _loadProfiles();
      
      setState(() {});
      print('[UI] ✓ Login all complete');
    } catch (e) {
      print('[UI] ✗ Login all failed: $e');
      rethrow;
    }
  }

  /// Handle connect to already-opened browsers
  Future<void> _handleConnectOpened(int count) async {
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
       final service = MobileBrowserService();
       service.initialize(count);
       
       // Show the browser manager to display webviews
       final dynamic state = _mobileBrowserManagerKey.currentState;
       state?.show();
       
       await Future.delayed(const Duration(seconds: 1));
       
       int connected = 0;
       
       for (int i = 0; i < count; i++) {
          final profile = service.getProfile(i);
          if (profile != null && profile.generator != null) {
              profile.status = MobileProfileStatus.loading;
              setState(() {});
              
              print('[CONNECT] Browser ${i + 1}: Navigating to Flow...');
              
              // Navigate to Flow and click "Create with Flow" (triggers Google login if needed)
              await profile.generator!.goToFlowAndTriggerLogin();
              
              // Wait a bit for any login redirect
              await Future.delayed(const Duration(seconds: 3));
              
              // Now check token with 10s interval, up to 5 times
              String? token;
              const int maxAttempts = 5;
              const int intervalSeconds = 10;
              
              for (int attempt = 1; attempt <= maxAttempts; attempt++) {
                  print('[CONNECT] Browser ${i + 1}: Token check attempt $attempt/$maxAttempts...');
                  
                  try {
                      // Use quick token fetch (no internal retry)
                      token = await profile.generator!.getAccessTokenQuick();
                      if (token != null && token.isNotEmpty) {
                          print('[CONNECT] ✓ Browser ${i + 1} got token on attempt $attempt');
                          break;
                      }
                  } catch (e) {
                      print('[CONNECT] Browser ${i + 1} attempt $attempt failed: $e');
                  }
                  
                  // Wait before next check (except on last attempt)
                  if (attempt < maxAttempts) {
                      await Future.delayed(Duration(seconds: intervalSeconds));
                  }
              }
              
              if (token != null && token.isNotEmpty) {
                  profile.accessToken = token;
                  profile.status = MobileProfileStatus.ready;
                  connected++;
              } else {
                  profile.status = MobileProfileStatus.connected;
                  print('[CONNECT] ✗ Browser ${i + 1} - no token after $maxAttempts attempts');
              }
              
              setState(() {});
          }
       }
       
       if (mounted) {
           if (connected > 0) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('✓ Connected $connected/$count browsers')));
           } else {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✗ No browsers connected. Login manually and try again.')));
           }
       }
       setState((){});
       return;
    }

    try {
      print('[UI] Connecting to $count opened browsers...');
      
      final connectedCount = await _profileManager!.connectToOpenProfiles(count);
      
      // Reload profiles dropdown to show newly created profiles
      await _loadProfiles();
      
      setState(() {});
      print('[UI] ✓ Connected to $connectedCount/$count browsers');
      
      if (connectedCount == 0) {
        throw Exception('No browsers found on debug ports. Please launch Chrome first.');
      }

      // Auto-login any profiles that don't have tokens
      if (_loginService != null && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty) {
        final profilesNeedingLogin = _profileManager!.profiles
            .where((p) => p.generator != null && p.accessToken == null)
            .toList();
        
        if (profilesNeedingLogin.isNotEmpty) {
          print('[UI] Auto-logging in ${profilesNeedingLogin.length} profile(s) without tokens...');
          
          for (final profile in profilesNeedingLogin) {
            print('[UI] Auto-login for ${profile.name}...');
            final success = await _loginService!.autoLogin(
              profile: profile,
              email: _savedEmail,
              password: _savedPassword,
            );
            
            if (success) {
              print('[UI] ✓ ${profile.name} logged in successfully');
            } else {
              print('[UI] ✗ ${profile.name} login failed');
            }
          }
          
          // Reload profiles again to update status
          await _loadProfiles();
          setState(() {});
        }
      }
    } catch (e) {
      print('[UI] ✗ Connect opened failed: $e');
      rethrow;
    }
  }

  /// Handle open browsers without auto-login
  Future<void> _handleOpenWithoutLogin(int count) async {
    try {
      print('[UI] Opening $count browsers without login...');
      
      final launchedCount = await _profileManager!.launchProfilesWithoutLogin(count);
      
      // Reload profiles dropdown to show newly created profiles
      await _loadProfiles();
      
      setState(() {});
      print('[UI] ✓ Opened $launchedCount/$count browsers (manual login required)');
    } catch (e) {
      print('[UI] ✗ Open without login failed: $e');
      rethrow;
    }
  }
}

/// Helper class for pending poll tracking
class _PendingPoll {
  final SceneData scene;
  final String sceneUuid;

  _PendingPoll(this.scene, this.sceneUuid);
}

/// Exception that can be retried on a different browser
class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);
  
  @override
  String toString() => message;
}
