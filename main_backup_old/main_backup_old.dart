import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
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
import 'screens/reel_special_screen.dart';
import 'screens/character_studio_screen.dart';
import 'services/mobile/mobile_browser_service.dart';
import 'services/mobile/mobile_log_manager.dart';
import 'widgets/mobile_browser_manager_widget.dart';
import 'widgets/compact_profile_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'services/foreground_service.dart';
import 'screens/ffmpeg_info_screen.dart';
import 'widgets/video_player_dialog.dart';
import 'screens/video_mastering_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'services/direct_image_uploader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize MediaKit for desktop video playback
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    MediaKit.ensureInitialized();
  }
  
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
    // Crucial: Load the project into the service so that output paths are correct
    _projectService.loadProject(project);
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
  bool isUpscaling = false; // Track bulk upscale state
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
  
  // Concurrent generation settings (user configurable)
  int maxConcurrentRelaxed = 5;  // Default for relaxed/lower priority models
  int maxConcurrentFast = 20;    // Default for fast models
  
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
  
  // Story Audio screen state (using callback approach instead of Navigator)
  bool _showStoryAudioScreen = false;
  int _storyAudioTabIndex = 0;
  
  // Reel Special dedicated screen state
  bool _showReelSpecialScreen = false;
  
  // Mobile: Thumbnails toggle for RAM saving
  bool _showVideoThumbnails = true;
  
  // Mobile Service Instance (for stopping login)
  MobileBrowserService? _mobileService;
  
  // Upload progress tracking
  bool _isUploading = false;
  int _uploadCurrent = 0;
  int _uploadTotal = 0;
  String _uploadFrameType = 'first'; // 'first' or 'last'


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
    
    // Request battery optimization exemption (shows system dialog on first run)
    // This is CRITICAL for background execution to work properly
    if (Platform.isAndroid) {
      await ForegroundServiceHelper.requestBatteryOptimizationExemption();
    }
    
    // First initialize output folder and profiles directory
    await _initializeOutputFolder();
    
    // Now that paths are set, ensure profiles dir exists
    await _ensureProfilesDir();
    
    // Ensure project is loaded into service for correct path generation
    await widget.projectService.loadProject(widget.project);
    
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
      
      // Use /storage/emulated/0/veo3/
      const externalPath = '/storage/emulated/0';
      // Do NOT overwrite outputFolder here as it is set in initState from project
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
    
    print('[Permission] Requesting storage permissions...');
    
    // Request basic storage permission (Android 10 and below)
    final storageStatus = await Permission.storage.request();
    print('[Permission] Storage: $storageStatus');
    
    // Request media permissions (Android 13+)
    final photosStatus = await Permission.photos.request();
    print('[Permission] Photos: $photosStatus');
    
    final videosStatus = await Permission.videos.request();
    print('[Permission] Videos: $videosStatus');
    
    // For Android 11+, request MANAGE_EXTERNAL_STORAGE
    final manageStatus = await Permission.manageExternalStorage.status;
    print('[Permission] Manage External Storage status: $manageStatus');
    
    if (!manageStatus.isGranted) {
      // Show dialog immediately
      if (mounted) {
        final shouldOpenSettings = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Storage Permission Required'),
            content: const Text(
              'This app needs "All files access" permission to save generated videos to your device.\n\n'
              'Please tap "Allow" and enable "Allow access to manage all files" in the settings.'
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Skip'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Allow'),
              ),
            ],
          ),
        );
        
        if (shouldOpenSettings == true) {
          // Request permission (this will open system dialog on older Android)
          final status = await Permission.manageExternalStorage.request();
          print('[Permission] Manage External Storage after request: $status');
          
          if (!status.isGranted) {
            // If still not granted, open app settings
            await openAppSettings();
          }
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
            firstFramePath: p['firstFramePath'] as String?,
            lastFramePath: p['lastFramePath'] as String?,
            firstFrameMediaId: p['firstFrameMediaId'] as String?,
            lastFrameMediaId: p['lastFrameMediaId'] as String?,
            videoPath: p['videoPath'] as String?,
            downloadUrl: p['downloadUrl'] as String?,
            fileSize: p['fileSize'] as int?,
            generatedAt: p['generatedAt'] as String?,
            operationName: p['operationName'] as String?,
            error: p['error'] as String?,
            retryCount: (p['retryCount'] as int?) ?? 0,
            // Save/restore these for resume polling
            videoMediaId: p['videoMediaId'] as String?,
            aspectRatio: p['aspectRatio'] as String?,
            upscaleStatus: p['upscaleStatus'] as String?,
            upscaleOperationName: p['upscaleOperationName'] as String?,
            upscaleVideoPath: p['upscaleVideoPath'] as String?,
            upscaleDownloadUrl: p['upscaleDownloadUrl'] as String?,
          )).toList();
          toIndex = scenes.length;
          _fromIndexController.text = '1';
          _toIndexController.text = toIndex.toString();
        });
        print('[PROJECT] Loaded ${scenes.length} scenes from project');
        
        // Count stats
        final completed = scenes.where((s) => s.status == 'completed').length;
        final failed = scenes.where((s) => s.status == 'failed').length;
        final pending = scenes.where((s) => s.status == 'queued').length;
        final polling = scenes.where((s) => s.status == 'polling').length;
        print('[PROJECT] Stats: $completed completed, $failed failed, $pending pending, $polling polling');
        
        // Check for scenes that were polling when app was closed
        if (polling > 0) {
          print('[PROJECT] Found $polling scenes in polling state - ready for resume');
        }
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
        'firstFrameMediaId': s.firstFrameMediaId,
        'lastFrameMediaId': s.lastFrameMediaId,
        'videoPath': s.videoPath,
        'downloadUrl': s.downloadUrl,
        'fileSize': s.fileSize,
        'generatedAt': s.generatedAt,
        'operationName': s.operationName,
        'error': s.error,
        'retryCount': s.retryCount,
        // Save these for resume polling
        'videoMediaId': s.videoMediaId,
        'aspectRatio': s.aspectRatio,
        'upscaleStatus': s.upscaleStatus,
        'upscaleOperationName': s.upscaleOperationName,
        'upscaleVideoPath': s.upscaleVideoPath,
        'upscaleDownloadUrl': s.upscaleDownloadUrl,
      }).toList();
      await widget.projectService.savePrompts(promptsData);
      print('[PROJECT] Saved ${scenes.length} scenes to project');
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
            
            // Load concurrent settings
            if (prefs['maxConcurrentRelaxed'] != null) {
              maxConcurrentRelaxed = prefs['maxConcurrentRelaxed'] as int;
            }
            if (prefs['maxConcurrentFast'] != null) {
              maxConcurrentFast = prefs['maxConcurrentFast'] as int;
            }
          });
          print('[PREFS] Loaded: account=$selectedAccountType, model=$selectedModel, concurrent=$maxConcurrentRelaxed/$maxConcurrentFast');
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
        'maxConcurrentRelaxed': maxConcurrentRelaxed,
        'maxConcurrentFast': maxConcurrentFast,
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

    // Dispose notifier after dialog is closed
    controller.dispose();
    promptCountNotifier.dispose();

    print('[PASTE] Dialog closed, result: ${result != null ? "${result.length} chars" : "null"}');
    
    if (result != null && result.isNotEmpty) {
      try {
        print('[PASTE] Parsing prompts...');
        final loadedScenes = parsePrompts(result);
        print('[PASTE] Parsed ${loadedScenes.length} scenes');
        
        if (!mounted) {
          print('[PASTE] Widget not mounted, aborting');
          return;
        }
        
        // Use Future.microtask to prevent UI blocking for large lists
        await Future.microtask(() {
          if (!mounted) return;
          
          setState(() {
            // MERGE prompts with existing scenes to preserve imported images
            if (scenes.isNotEmpty) {
              // Create a map of existing scenes by sceneId for quick lookup
              final existingMap = <int, SceneData>{};
              for (final scene in scenes) {
                existingMap[scene.sceneId] = scene;
              }
              
              int updatedCount = 0;
              int addedCount = 0;
              
              for (final loadedScene in loadedScenes) {
                if (existingMap.containsKey(loadedScene.sceneId)) {
                  // Update existing scene - preserve images and status
                  final existing = existingMap[loadedScene.sceneId]!;
                  existing.prompt = loadedScene.prompt;
                  // Keep: firstFramePath, lastFramePath, status, etc.
                  updatedCount++;
                } else {
                  // Add new scene
                  scenes.add(loadedScene);
                  addedCount++;
                }
              }
              
              // Sort scenes by sceneId after merge
              scenes.sort((a, b) => a.sceneId.compareTo(b.sceneId));
              
              print('[PASTE] Merged: $updatedCount updated, $addedCount added, ${scenes.length} total');
            } else {
              // No existing scenes, just use loaded ones
              scenes = loadedScenes;
            }
            
            fromIndex = 1;
            toIndex = scenes.length;
            _fromIndexController.text = fromIndex.toString();
            _toIndexController.text = toIndex.toString();
            _isQuickInputCollapsed = true; // Collapse quick input when bulk scenes loaded
          });
        });
        
        print('[PASTE] setState complete');
        
        // Small delay to let UI update before saving
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        // Auto-save prompts to project
        try {
          await _savePromptsToProject();
          print('[PASTE] Saved to project');
        } catch (saveError) {
          print('[PASTE] Save error (non-fatal): $saveError');
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Loaded ${loadedScenes.length} prompts (merged with existing scenes)')),
          );
        }
      } catch (e, stack) {
        print('[PASTE] ERROR: $e');
        print('[PASTE] Stack: $stack');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to parse content: $e'), backgroundColor: Colors.red),
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
    String selectedPreset = 'ultrafast';  // New: preset selection
    
    // Calculate total input size
    final totalInputSize = files.fold<int>(0, (sum, f) => sum + f.size);
    
    // Helper to estimate output size based on resolution and preset
    int estimateOutputSize(String resolution, String preset) {
      // Base multiplier for resolution
      double resMultiplier = 1.0;
      switch (resolution) {
        case '1080p': resMultiplier = 1.0; break;
        case '2k': resMultiplier = 1.8; break;  // ~1.8x larger than 1080p
        case '4k': resMultiplier = 3.5; break;  // ~3.5x larger than 1080p
        default: resMultiplier = 1.0;
      }
      
      // Preset affects file size (ultrafast = larger, fast = smaller but slower)
      double presetMultiplier = 1.0;
      switch (preset) {
        case 'fast': presetMultiplier = 0.7; break;       // Smallest file (slowest)
        case 'veryfast': presetMultiplier = 0.85; break;  // Medium
        case 'ultrafast': presetMultiplier = 1.0; break;  // Largest (fastest encoding)
      }
      
      // Base estimate: assume H.264 at CRF 23 is roughly 70% of original for 1080p
      // This is a rough estimate - actual size depends on content
      double estimatedSize = totalInputSize * 0.7 * resMultiplier * presetMultiplier;
      
      return estimatedSize.round();
    }

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
                    
                    // Preset selector (only shown when re-encoding)
                    if (selectedResolution != 'original' || selectedAspectRatio != 'original') ...[
                      const SizedBox(height: 16),
                      const Text('Encoding Preset:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          ChoiceChip(
                            label: const Text('Fast'),
                            selected: selectedPreset == 'fast',
                            onSelected: (selected) {
                              if (selected) setState(() => selectedPreset = 'fast');
                            },
                            tooltip: 'Slowest encoding, smallest file',
                          ),
                          ChoiceChip(
                            label: const Text('Very Fast'),
                            selected: selectedPreset == 'veryfast',
                            onSelected: (selected) {
                              if (selected) setState(() => selectedPreset = 'veryfast');
                            },
                            tooltip: 'Balanced speed and size',
                          ),
                          ChoiceChip(
                            label: const Text('Ultra Fast'),
                            selected: selectedPreset == 'ultrafast',
                            onSelected: (selected) {
                              if (selected) setState(() => selectedPreset = 'ultrafast');
                            },
                            tooltip: 'Fastest encoding, largest file',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Estimated output size
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.folder_zip, color: Colors.green.shade700, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Estimated Output Size', 
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                                  const SizedBox(height: 2),
                                  Text(
                                    _formatFileSize(estimateOutputSize(selectedResolution, selectedPreset)),
                                    style: TextStyle(
                                      fontSize: 16, 
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'Input: ${_formatFileSize(totalInputSize)}',
                                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                ),
                                Text(
                                  selectedPreset == 'ultrafast' ? '⚡ Fastest' 
                                    : selectedPreset == 'veryfast' ? '⏱️ Balanced' 
                                    : '📦 Smallest',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    
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
                      'preset': selectedPreset,
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
      final preset = settings['preset'] as String? ?? 'ultrafast';

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
          preset: preset,
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

    // PC: Check if browsers are connected, if not try to connect first
    final connectedCount = _profileManager?.countConnectedProfiles() ?? 0;
    if (connectedCount == 0) {
      print('[START] No browsers connected! Trying to connect to opened browsers...');
      
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connecting to opened browsers...')),
      );
      
      // Try to connect to opened browsers (default 2)
      if (_profileManager != null) {
        final connected = await _profileManager!.connectToOpenProfiles(2);
        
        if (connected == 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No browsers found! Please open Chrome with remote debugging enabled, or use "Login All" to launch browsers.'),
                duration: Duration(seconds: 5),
              ),
            );
          }
          return;
        }
        
        print('[START] ✓ Connected to $connected browser(s)');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile manager not initialized. Please use "Login All" to launch browsers.')),
        );
        return;
      }
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
      isUpscaling = false; // Also stop upscaling
    });
    print('[STOP] Generation and upscaling stopped by user');
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
    
    setState(() {
      _showStoryAudioScreen = true;
      _storyAudioTabIndex = goToReelTab ? 1 : 0;
    });
  }

  void _openReelSpecial() {
    if (!_checkActivation('Reel Special')) return;
    
    setState(() {
      _showReelSpecialScreen = true;
    });
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
      
      print('[ERROR] $statusCode $errorType - Attempt ${scene.retryCount}/10');
      
      // On 403 error, refresh the browser to help recover
      if (statusCode == 403 && generator != null) {
        print('[RECOVERY] 403 detected - Refreshing browser to recover...');
        try {
          await generator!.refreshPage();
        } catch (e) {
          print('[RECOVERY] Browser refresh failed: $e');
        }
      }
      
      // If 10 retries failed, skip this scene
      if (scene.retryCount! >= 10) {
        print('[ERROR] Max retries (10) reached for scene ${scene.sceneId} - Skipping');
        setState(() {
          scene.status = 'failed';
          scene.error = '$errorType after 10 retries';
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
        scene.error = 'Retrying in 45s (attempt ${scene.retryCount}/10)';
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
    
    // MobileBrowserService is a singleton, so get the instance directly
    // This ensures we use the same profiles that are displayed in the UI
    _mobileService = MobileBrowserService();
    final service = _mobileService!;
    
    // Start foreground service to prevent Android from killing the app
    await ForegroundServiceHelper.startService(status: 'Starting video generation...');
    
    // Check for healthy profiles (ready + working token)
    final healthyCount = service.countHealthy();
    final connectedCount = service.countConnected();
    
    print('[MOBILE] Profiles - Connected: $connectedCount, Healthy: $healthyCount');
    
    if (healthyCount == 0) {
      if (connectedCount > 0) {
        // Has connected profiles but none are healthy - may need relogin
        print('[MOBILE] No healthy profiles, trying to recover...');
        
        // Check if any profiles need relogin (403 threshold reached)
        final needsRelogin = service.getProfilesNeedingRelogin();
        if (needsRelogin.isNotEmpty && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty) {
          print('[MOBILE] ${needsRelogin.length} browsers need relogin, triggering...');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Auto-relogging ${needsRelogin.length} browser(s)...')),
            );
          }
          
          await service.reloginAllNeeded(
            email: _savedEmail,
            password: _savedPassword,
            onAnySuccess: () {
              print('[MOBILE] Browser recovered!');
            },
          );
          
          // Wait a bit for relogin to complete
          await Future.delayed(const Duration(seconds: 5));
        }
        
        // Recheck healthy count after relogin attempt
        final newHealthyCount = service.countHealthy();
        if (newHealthyCount == 0) {
          print('[MOBILE] Still no healthy profiles after relogin attempt');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No active browsers. Please login again or check browser status.')),
            );
          }
          await ForegroundServiceHelper.stopService();
          setState(() { isRunning = false; });
          return;
        }
      } else {
        // No profiles at all
        print('[MOBILE] No profiles loaded');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No browser profiles connected. Login first.')),
          );
        }
        await ForegroundServiceHelper.stopService();
        setState(() { isRunning = false; });
        return;
      }
    }
    
    print('[MOBILE] Ready to generate with ${service.countHealthy()} healthy profiles');
    
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
      
      // Delay slightly before starting worker logic to avoid UI race on some devices
      await Future.delayed(const Duration(seconds: 1));
      
      // Sync processing state - only reset if truly starting fresh
      if (_pendingPolls.isEmpty) {
        _activeGenerationsCount = 0;
      }
      _generationComplete = false;
      
      // Determine concurrency limit based on model (uses user-configurable settings)
      final isRelaxedModel = selectedModel.toLowerCase().contains('relaxed') ||
                             selectedModel.toLowerCase().contains('lower priority');
      final maxConcurrent = isRelaxedModel ? maxConcurrentRelaxed : maxConcurrentFast;
      print('[MOBILE] Max concurrent: $maxConcurrent (Model: $selectedModel, Relaxed: $isRelaxedModel)');
      mobileLog('[GEN] Max concurrent: $maxConcurrent');
      
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
      
      // Get healthy profile (checks 403 count, not just ready status)
      final profile = service.getNextAvailableProfile();
      
      if (profile == null) {
        print('[MOBILE] No healthy profile available');
        
        // Check if we need to trigger relogin
        final needsRelogin = service.getProfilesNeedingRelogin();
        if (needsRelogin.isNotEmpty) {
          print('[MOBILE] ${needsRelogin.length} browsers need relogin, triggering...');
          await service.reloginAllNeeded(
            email: _savedEmail,
            password: _savedPassword,
            onAnySuccess: () {
              print('[MOBILE] Browser recovered!');
            },
          );
        }
        
        // Wait for at least one browser to become healthy
        int waitCount = 0;
        while (service.countHealthy() == 0 && waitCount < 60 && isRunning) {
          await Future.delayed(const Duration(seconds: 5));
          waitCount++;
          print('[MOBILE] Waiting for relogin... (${waitCount * 5}s, Healthy: ${service.countHealthy()})');
        }
        
        if (!isRunning) break;
        i--; // Retry this scene
        continue;
      }
      
      final scene = scenesToProcess[i];
      
      try {
        // Random delay between API requests (1.5-3 seconds)
        final delayMs = 1500 + Random().nextInt(1500); // 1500-3000ms
        print('[DELAY] Waiting ${delayMs}ms before request');
        await Future.delayed(Duration(milliseconds: delayMs));
        
        // Generate using this profile
        await _generateWithMobileProfile(scene, profile, i + 1, scenesToProcess.length);
        
      } on _RetryableException catch (e) {
        // Retryable error (403, API errors) - push back to queue for retry
        scene.retryCount = (scene.retryCount ?? 0) + 1;
        
        if (scene.retryCount! < 10) {
          print('[MOBILE RETRY] Scene ${scene.sceneId} retry ${scene.retryCount}/10 - inserting for IMMEDIATE retry');
          setState(() {
            scene.status = 'queued';
            scene.error = 'Retrying (${scene.retryCount}/10): ${e.message}';
          });
          // Insert at position i+1 for IMMEDIATE retry (not at end of queue)
          scenesToProcess.insert(i + 1, scene);
        } else {
          print('[MOBILE] ✗ Scene ${scene.sceneId} failed after 10 retries');
          setState(() {
            scene.status = 'failed';
            scene.error = 'Failed after 10 retries: ${e.message}';
          });
          // Save failure state to project
          _savePromptsToProject();
        }
      } catch (e) {
        // Non-retryable error
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
        // Save failure state to project
        _savePromptsToProject();
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
    
    // Generate video (with 60s safety timeout to prevent slot leakage)
    final result = await profile.generator!.generateVideo(
      prompt: scene.prompt,
      accessToken: profile.accessToken!,
      aspectRatio: selectedAspectRatio,
      model: apiModelKey,
    ).timeout(const Duration(seconds: 60), onTimeout: () {
      print('[MOBILE SLOT] ! TIMEOUT releasing slot !');
      _activeGenerationsCount--;
      throw Exception('Generation request timed out (60s)');
    });
    
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
        
        // Trigger auto-relogin for THIS browser only if threshold reached
        if (profile.consecutive403Count >= 3 && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty) {
          print('[MOBILE 403] ${profile.name} - Triggering relogin for THIS browser only...');
          
          // Use autoReloginProfile for individual browser relogin
          _mobileService?.autoReloginProfile(
            profile,
            email: _savedEmail, 
            password: _savedPassword,
            onSuccess: () {
              print('[MOBILE 403] ${profile.name} relogin SUCCESS');
              setState(() {});
            }
          ).then((success) {
            if (!success) {
              print('[MOBILE 403] ${profile.name} relogin FAILED');
            }
            setState(() {});
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
    scene.aspectRatio = selectedAspectRatio; // Store for upscaling
    setState(() {
      scene.status = 'polling';
    });
    
    // Add to pending polls for batch polling worker
    _pendingPolls.add(_PendingPoll(scene, sceneUuid, DateTime.now()));
    
    print('[MOBILE] ✓ Scene ${scene.sceneId} queued for polling');
  }

  // Mobile Single Run - INLINE POLLING with 403 handling and retry
  Future<void> _mobileRunSingle(SceneData scene, MobileProfile profile) async {
    final service = MobileBrowserService();
    int retryCount = 0;
    const maxRetries = 5;
    
    // Check for empty prompt - Veo3 API requires a text prompt even for I2V
    final hasImage = scene.firstFramePath != null || scene.lastFramePath != null;
    if (scene.prompt.trim().isEmpty) {
      if (hasImage) {
        scene.prompt = 'Animate this image with natural, fluid motion';
        print('[MOBILE] Using default I2V prompt for scene ${scene.sceneId}');
      } else {
        print('[MOBILE] Skipping scene ${scene.sceneId} - no prompt or image');
        setState(() {
          scene.status = 'failed';
          scene.error = 'No prompt or image provided';
        });
        return;
      }
    }
    
    while (retryCount < maxRetries) {
      // Get healthy profile for this attempt
      MobileProfile? currentProfile = retryCount == 0 ? profile : service.getNextAvailableProfile();
      
      if (currentProfile == null) {
        // No healthy browser - try to recover
        print('[SINGLE] No healthy browser, checking if relogin needed...');
        
        final needsRelogin = service.getProfilesNeedingRelogin();
        if (needsRelogin.isNotEmpty && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty) {
          print('[SINGLE] Triggering relogin for ${needsRelogin.length} browser(s)...');
          setState(() { scene.status = 'generating'; scene.error = 'Relogging browser...'; });
          
          await service.reloginAllNeeded(
            email: _savedEmail,
            password: _savedPassword,
            onAnySuccess: () => print('[SINGLE] Browser recovered!'),
          );
          
          // Wait for relogin
          int waitCount = 0;
          while (service.countHealthy() == 0 && waitCount < 30) {
            await Future.delayed(const Duration(seconds: 5));
            waitCount++;
            print('[SINGLE] Waiting for relogin... (${waitCount * 5}s)');
          }
          
          currentProfile = service.getNextAvailableProfile();
        }
        
        if (currentProfile == null) {
          print('[SINGLE] Still no healthy browser after relogin attempt');
          setState(() { scene.status = 'failed'; scene.error = 'No active browser available'; });
          return;
        }
      }
      
      setState(() { scene.status = 'generating'; scene.error = null; });
      print('[SINGLE] Attempt ${retryCount + 1}/$maxRetries for scene ${scene.sceneId}');
      
      try {
        final generator = currentProfile.generator!;
        final token = currentProfile.accessToken!;
        
        // Uploads (if needed)
        String? startMediaId = scene.firstFrameMediaId;
        String? endMediaId = scene.lastFrameMediaId;
        
        if (scene.firstFramePath != null && startMediaId == null) {
           print('[SINGLE] Uploading start image...');
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
        print('[SINGLE] Generating scene ${scene.sceneId} (Model: $actualModelKey)...');
        final res = await generator.generateVideo(
           prompt: scene.prompt, accessToken: token,
           aspectRatio: selectedAspectRatio, model: actualModelKey,
           startImageMediaId: startMediaId, endImageMediaId: endMediaId
        );
        
        // Check for 403 error
        if (res != null && res['status'] == 403) {
          currentProfile.consecutive403Count++;
          print('[SINGLE] 403 error! ${currentProfile.name} count: ${currentProfile.consecutive403Count}/3');
          
          if (currentProfile.consecutive403Count >= 3) {
            print('[SINGLE] Browser hit 403 threshold, triggering relogin...');
            // Trigger relogin in background
            service.autoReloginProfile(currentProfile, email: _savedEmail, password: _savedPassword);
          }
          
          retryCount++;
          // Delay before retry (3-5 seconds)
          final delay = 3 + Random().nextInt(3);
          print('[SINGLE] Retrying in ${delay}s...');
          await Future.delayed(Duration(seconds: delay));
          continue;
        }
        
        if (res == null || res['data'] == null) {
            print('[SINGLE] Generate returned null or no data');
            throw Exception('API Error or Rate Limit');
        }
        
        // Reset 403 count on success
        currentProfile.consecutive403Count = 0;
        
        final data = res['data'];
        final ops = data['operations'];
        if (ops == null || (ops is List && ops.isEmpty)) {
            print('[SINGLE] No operations in response: ${jsonEncode(data)}');
            throw Exception('No operation returned');
        }
        
        // Get operation name
        final firstOp = (ops as List)[0] as Map<String, dynamic>;
        String? opName = firstOp['name'] as String?;
        if (opName == null && firstOp['operation'] is Map) {
          opName = (firstOp['operation'] as Map)['name'] as String?;
        }
        
        if (opName == null) {
          print('[SINGLE] No operation name found in: $firstOp');
          throw Exception('No operation name in response');
        }
        
        final sceneUuid = firstOp['sceneId']?.toString() ?? res['sceneId']?.toString() ?? opName; 
        
        scene.operationName = opName;
        scene.aspectRatio = selectedAspectRatio; // Store for upscaling
        setState(() { scene.status = 'polling'; });
        print('[SINGLE] Scene ${scene.sceneId} polling started. Op: $opName');
        
        // INLINE POLLING
        bool done = false;
        int pollCount = 0;
        
        while(!done && scene.status == 'polling' && pollCount < 120) {
           await Future.delayed(const Duration(seconds: 5));
           pollCount++;
           
           // Get fresh healthy profile for polling
           final pollProfile = service.getNextAvailableProfile() ?? currentProfile;
           final pollToken = pollProfile.accessToken ?? token;
           final pollGenerator = pollProfile.generator ?? generator;
           
           print('[SINGLE] Poll #$pollCount for scene ${scene.sceneId}...');
           
           final poll = await pollGenerator.pollVideoStatus(opName, opName, pollToken);
           
           if (poll != null) {
              final status = poll['status'] as String?;
              print('[SINGLE] Poll result: status=$status');
              
              if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' || 
                  status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
                   
                   // Extract video URL and mediaId
                   String? videoUrl;
                   String? videoMediaId;
                   if (poll.containsKey('operation')) {
                       final op = poll['operation'] as Map<String, dynamic>;
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
                      print('[SINGLE] Video URL found! Downloading...');
                      if (videoMediaId != null) {
                        print('[SINGLE] Video MediaId: $videoMediaId (saved for upscaling)');
                      }
                      setState(() { scene.status = 'downloading'; });
                      
                      final fileName = 'mob_${scene.sceneId}.mp4';
                      final savePath = path.join(outputFolder, fileName);
                      
                      await pollGenerator.downloadVideo(videoUrl, savePath);
                      
                      setState(() {
                          scene.videoPath = savePath;
                          scene.videoMediaId = videoMediaId; // Store for upscaling
                          scene.downloadUrl = videoUrl; // Store URL as backup
                          scene.status = 'completed';
                      });
                      done = true;
                      print('[SINGLE] Scene ${scene.sceneId} COMPLETED!');
                  } else {
                     throw Exception('No fifeUrl in success response');
                  }
              } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
                  throw Exception('Generation failed on server');
              }
           } else {
              print('[SINGLE] Poll returned null, continuing...');
           }
        }
        
        if (!done && pollCount >= 120) {
           throw Exception('Polling timeout (10 minutes)');
        }
        
        // Success - exit retry loop
        return;
        
      } catch(e) {
        retryCount++;
        print('[SINGLE] Scene ${scene.sceneId} Error (attempt $retryCount): $e');
        
        if (retryCount >= maxRetries) {
          setState(() { scene.status = 'failed'; scene.error = 'Failed after $maxRetries attempts: $e'; });
          return;
        }
        
        // Delay before retry
        final delay = 3 + Random().nextInt(3);
        print('[SINGLE] Retrying in ${delay}s...');
        setState(() { scene.error = 'Retry $retryCount/$maxRetries: $e'; });
        await Future.delayed(Duration(seconds: delay));
      }
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
        // Check for empty prompt - Veo3 API requires a text prompt even for I2V
        final hasImage = scene.firstFramePath != null || scene.lastFramePath != null;
        if (scene.prompt.trim().isEmpty) {
          if (hasImage) {
            scene.prompt = 'Animate this image with natural, fluid motion';
            print('[GENERATE] Using default I2V prompt for scene ${scene.sceneId}');
          } else {
            print('[GENERATE] Skipping scene ${scene.sceneId} - no prompt or image');
            setState(() {
              scene.status = 'failed';
              scene.error = 'No prompt or image provided';
            });
            continue;
          }
        }

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
        print('[GENERATE] Start Image MediaId: ${startMediaId ?? "null"}');
        print('[GENERATE] End Image MediaId: ${endMediaId ?? "null"}');
        print('[GENERATE] Scene has firstFramePath: ${scene.firstFramePath != null}, firstFrameMediaId: ${scene.firstFrameMediaId}');

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
        scene.aspectRatio = selectedAspectRatio; // Store for upscaling
        setState(() {
          scene.status = 'polling';
        });

        // Add to pending polls for the poll worker
        _activeGenerationsCount++;
        _pendingPolls.add(_PendingPoll(scene, sceneUuid ?? operationName, DateTime.now()));

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
      final allScenesInRange = scenes
          .skip(fromIndex - 1)
          .take(toIndex - fromIndex + 1)
          .toList();
      
      // Debug: Log all scene statuses
      print('\n[DEBUG] All scenes in range ($fromIndex to $toIndex):');
      for (var s in allScenesInRange) {
        print('  Scene ${s.sceneId}: status=${s.status}, prompt="${s.prompt.length > 20 ? s.prompt.substring(0, 20) + "..." : s.prompt}", hasImage=${s.firstFrameMediaId != null || s.lastFrameMediaId != null}');
      }
      
      final scenesToProcess = allScenesInRange
          .where((s) => s.status == 'queued' || s.status == 'failed')
          .toList();
      
      // Reset failed scenes to queued for retry
      for (var scene in scenesToProcess) {
        if (scene.status == 'failed') {
          scene.status = 'queued';
          scene.error = null;
          print('[QUEUE] Reset failed scene ${scene.sceneId} to queued for retry');
        }
      }

      print('\n[QUEUE] Processing ${scenesToProcess.length} scenes (from $fromIndex to $toIndex)');
      print('[QUEUE] Model: $selectedModel');
      
      if (scenesToProcess.isEmpty) {
        print('[QUEUE] No scenes with status "queued" found!');
        print('[QUEUE] Scene statuses: ${allScenesInRange.map((s) => s.status).toList()}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No queued scenes to process. Check scene statuses.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        setState(() {
          isRunning = false;
        });
        return;
      }

      // Reset concurrent processing state
      _activeGenerationsCount = 0;
      _pendingPolls.clear();
      _generationComplete = false;

      // Start Polling Worker (runs in parallel)
      _pollWorker();

      // Determine concurrency limit based on model (uses user-configurable settings)
      final isRelaxedModel = selectedModel.toLowerCase().contains('lower priority') || 
                             selectedModel.toLowerCase().contains('relaxed');
      final maxConcurrent = isRelaxedModel ? maxConcurrentRelaxed : maxConcurrentFast;
      print('[CONCURRENT] Model: $selectedModel');
      print('[CONCURRENT] IsRelaxed: $isRelaxedModel');
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
        
        if (scene.retryCount! < 10) {
          print('[RETRY] Scene ${scene.sceneId} retry ${scene.retryCount}/10 - inserting for IMMEDIATE retry');
          setState(() {
            scene.status = 'queued';
            scene.error = 'Retrying (${scene.retryCount}/10): ${e.message}';
          });
          // Insert at position i+1 for IMMEDIATE retry (not at end of queue)
          scenesToProcess.insert(i + 1, scene);
        } else {
          print('[GENERATE] ✗ Scene ${scene.sceneId} failed after 10 retries: ${e.message}');
          setState(() {
            scene.status = 'failed';
            scene.error = 'Failed after 10 retries: ${e.message}';
          });
          // Save failure state to project
          _savePromptsToProject();
        }
      } catch (e) {
        // Non-retryable error
        setState(() {
          scene.status = 'failed';
          scene.error = e.toString();
        });
        // Save failure state to project
        _savePromptsToProject();
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

    // Upload images first if we have paths but no mediaIds
    String? startImageMediaId = scene.firstFrameMediaId;
    String? endImageMediaId = scene.lastFrameMediaId;
    
    // Upload first frame if needed
    if (scene.firstFramePath != null && startImageMediaId == null) {
      print('[GENERATE] Uploading first frame image...');
      try {
        final result = await profile.generator!.uploadImage(
          scene.firstFramePath!,
          profile.accessToken!,
        );
        if (result is String) {
          startImageMediaId = result;
          scene.firstFrameMediaId = result;
          print('[GENERATE] ✓ First frame uploaded: $result');
        } else if (result is Map && result['error'] == true) {
          print('[GENERATE] ✗ First frame upload failed: ${result['message']}');
          _activeGenerationsCount--;
          throw _RetryableException('Image upload failed: ${result['message']}');
        }
      } catch (e) {
        print('[GENERATE] ✗ First frame upload error: $e');
        _activeGenerationsCount--;
        throw _RetryableException('Image upload error: $e');
      }
    }
    
    // Upload last frame if needed
    if (scene.lastFramePath != null && endImageMediaId == null) {
      print('[GENERATE] Uploading last frame image...');
      try {
        final result = await profile.generator!.uploadImage(
          scene.lastFramePath!,
          profile.accessToken!,
        );
        if (result is String) {
          endImageMediaId = result;
          scene.lastFrameMediaId = result;
          print('[GENERATE] ✓ Last frame uploaded: $result');
        } else if (result is Map && result['error'] == true) {
          print('[GENERATE] ✗ Last frame upload failed: ${result['message']}');
        }
      } catch (e) {
        print('[GENERATE] ✗ Last frame upload error: $e');
      }
    }
    
    final hasImage = startImageMediaId != null || endImageMediaId != null ||
                     scene.firstFramePath != null || scene.lastFramePath != null;
    
    // Apply default prompt if empty but has image
    if (scene.prompt.trim().isEmpty) {
      if (hasImage) {
        scene.prompt = 'Animate this image with natural, fluid motion';
        print('[GENERATE] Using default I2V prompt');
      } else {
        _activeGenerationsCount--;
        print('[SLOT] Released slot (no prompt or image) - Active: $_activeGenerationsCount');
        setState(() {
          scene.status = 'failed';
          scene.error = 'No prompt or image provided';
        });
        return;
      }
    }

    final isI2V = startImageMediaId != null || endImageMediaId != null;
    print('\n[GENERATE $currentIndex/$totalScenes] Scene ${scene.sceneId}');
    print('[GENERATE] Browser: ${profile.name} (Port: ${profile.debugPort})');
    print('[GENERATE] Using Direct API Method (batchAsyncGenerateVideoText)');
    print('[GENERATE] Mode: ${isI2V ? "I2V" : "T2V"}');
    print('[GENERATE] startImageMediaId: $startImageMediaId');
    print('[GENERATE] endImageMediaId: $endImageMediaId');

    // Ensure browser connection is alive before making API call
    if (profile.generator == null || !profile.generator!.isConnected) {
      print('[GENERATE] Reconnecting browser ${profile.name}...');
      try {
        profile.generator?.close();
        profile.generator = BrowserVideoGenerator(debugPort: profile.debugPort);
        await profile.generator!.connect();
        profile.accessToken = await profile.generator!.getAccessToken();
        print('[GENERATE] ✓ Reconnected ${profile.name}');
      } catch (e) {
        _activeGenerationsCount--;
        print('[SLOT] Released slot (reconnect failed) - Active: $_activeGenerationsCount');
        throw _RetryableException('Failed to reconnect browser: $e');
      }
    }

    // Convert Flow UI model display name to API model key
    final apiModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
    
    // Generate video via API with retry logic for timeouts
    Map<String, dynamic>? result;
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 5);
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        result = await profile.generator!.generateVideo(
          prompt: scene.prompt,
          accessToken: profile.accessToken!,
          aspectRatio: selectedAspectRatio,
          model: apiModelKey,
          startImageMediaId: startImageMediaId,
          endImageMediaId: endImageMediaId,
        ).timeout(const Duration(seconds: 60), onTimeout: () {
          throw TimeoutException('PC Generation request timed out (60s)');
        });
        
        // Success - break out of retry loop
        if (result != null) break;
        
      } on TimeoutException catch (e) {
        print('[TIMEOUT] Attempt $attempt/$maxRetries failed: ${e.message}');
        
        if (attempt < maxRetries) {
          print('[RETRY] Waiting ${retryDelay.inSeconds}s before retry...');
          setState(() {
            scene.error = 'Timeout - Retrying ($attempt/$maxRetries)...';
          });
          await Future.delayed(retryDelay);
          
          // Reconnect browser after timeout (connection might be stale)
          print('[RETRY] Reconnecting browser ${profile.name} after timeout...');
          try {
            profile.generator?.close();
            profile.generator = BrowserVideoGenerator(debugPort: profile.debugPort);
            await profile.generator!.connect();
            profile.accessToken = await profile.generator!.getAccessToken();
            print('[RETRY] ✓ Reconnected ${profile.name}');
          } catch (reconnectError) {
            print('[RETRY] ✗ Reconnect failed: $reconnectError - continuing with existing connection');
          }
        } else {
          // Final attempt failed
          _activeGenerationsCount--;
          print('[SLOT] Released slot (timeout after $maxRetries retries) - Active: $_activeGenerationsCount');
          throw Exception('PC Generation timed out after $maxRetries retries');
        }
      }
    }
    
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
        
        // Trigger relogin for THIS browser only if threshold reached
        if (profile.consecutive403Count >= 3 && _savedEmail.isNotEmpty && _savedPassword.isNotEmpty) {
          print('[403] ${profile.name} - Triggering relogin for THIS browser only...');
          if (Platform.isAndroid || Platform.isIOS) {
            _mobileService?.autoReloginProfile(
              profile as MobileProfile,
              email: _savedEmail,
              password: _savedPassword,
            );
          } else {
            _loginService!.reloginProfile(profile, _savedEmail, _savedPassword);
          }
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
    scene.aspectRatio = selectedAspectRatio; // Store for upscaling
    setState(() {
      scene.status = 'polling';
    });

    // Add to pending polls for the poll worker (slot already taken at start)
    _pendingPolls.add(_PendingPoll(scene, sceneUuid ?? operationName, DateTime.now()));

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
          // Mobile Mode: use existing _mobileService, not a new instance
          if (_mobileService != null) {
            // Get healthy profile (not just ready)
            final healthyProfile = _mobileService!.getNextAvailableProfile();
            if (healthyProfile != null) {
              pollGenerator = healthyProfile.generator;
              pollToken = healthyProfile.accessToken;
            } else {
              // No healthy browsers - wait for relogin
              print('[POLLER] No healthy browser available, waiting...');
              
              // Wait for at least one browser to become healthy
              int waitCount = 0;
              while (_mobileService!.countHealthy() == 0 && waitCount < 60 && isRunning) {
                await Future.delayed(const Duration(seconds: 5));
                waitCount++;
                print('[POLLER] Waiting for browser relogin... (${waitCount * 5}s, Healthy: ${_mobileService!.countHealthy()})');
              }
              
              // Try again to get a healthy profile
              final retryProfile = _mobileService!.getNextAvailableProfile();
              if (retryProfile != null) {
                pollGenerator = retryProfile.generator;
                pollToken = retryProfile.accessToken;
                print('[POLLER] Got healthy browser after wait');
              } else {
                print('[POLLER] Still no healthy browser after wait');
                continue;
              }
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
              print('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
              if (videoMediaId != null) {
                print('[POLLER] Video MediaId: $videoMediaId (saved for upscaling)');
                scene.videoMediaId = videoMediaId;
                scene.downloadUrl = videoUrl;
              }
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
              // Save failure state to project
              _savePromptsToProject();
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
        // Safety check: Release slots for scenes that have been polling for WAY too long (15 mins)
        // This prevents the 'Active: 4/4' hang if the API stops returning certain operations.
        final now = DateTime.now();
        final toRemove = <int>[];
        for (int i = 0; i < _pendingPolls.length; i++) {
           final p = _pendingPolls[i];
           if (p.scene.status == 'polling' && 
               now.difference(p.startTime).inMinutes > 15) {
             print('[POLLER] Safety release for scene ${p.scene.sceneId} (Stuck in polling)');
             _activeGenerationsCount--;
             p.scene.status = 'failed';
             p.scene.error = 'Polling timeout (API stopped responding for this operation)';
             toRemove.add(i);
           }
        }
        for (final idx in toRemove.reversed) {
          _pendingPolls.removeAt(idx);
        }

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
      
      // Save failure state to project
      await _savePromptsToProject();
      
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
    final upscaling = scenes.where((s) => ['upscaling', 'polling', 'downloading'].contains(s.upscaleStatus)).length;
    final upscaled = scenes.where((s) => s.upscaleStatus == 'upscaled' || s.upscaleStatus == 'completed').length;
    final isMobileScreen = MediaQuery.of(context).size.width < 900;



    // If Story Audio screen is active, show it instead of main content
    if (_showStoryAudioScreen) {
      return StoryAudioScreen(
        projectService: widget.projectService,
        isActivated: widget.isActivated,
        profileManager: _profileManager,
        loginService: _loginService,
        email: _savedEmail,
        password: _savedPassword,
        selectedModel: selectedModel,
        selectedAccountType: selectedAccountType,
        storyAudioOnlyMode: true, // Hide the Reel tab
        onBack: () {
          setState(() {
            _showStoryAudioScreen = false;
          });
        },
      );
    }

    // If Reel Special screen is active, show dedicated reel screen
    if (_showReelSpecialScreen) {
      return ReelSpecialScreen(
        projectService: widget.projectService,
        isActivated: widget.isActivated,
        profileManager: _profileManager,
        loginService: _loginService,
        email: _savedEmail,
        password: _savedPassword,
        selectedModel: selectedModel,
        selectedAccountType: selectedAccountType,
        onBack: () {
          setState(() {
            _showReelSpecialScreen = false;
          });
        },
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
      builder: (context, constraints) {
        // Breakpoint for mobile/tablet
        final isMobile = constraints.maxWidth < 900;
        
        return Scaffold(
          backgroundColor: Colors.grey.shade100,
          appBar: AppBar(
            leadingWidth: isMobile ? null : 0,
            titleSpacing: isMobile ? null : 8,
            title: isMobile
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.video_library, size: 18),
                      const SizedBox(width: 4),
                      const Text('VEO3', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      if (widget.isActivated)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.star, size: 14, color: Color(0xFFFFD700)),
                        ),
                      const SizedBox(width: 8),
                      Container(width: 1, height: 20, color: Colors.grey.shade400),
                      const SizedBox(width: 4),
                      // Compact file operation buttons for mobile
                      _buildMobileAppBarButton('Paste', Icons.content_paste, _pasteJson),
                      _buildMobileAppBarButton('Load', Icons.file_upload_outlined, _loadFile),
                      _buildMobileAppBarButton('Save', Icons.save, _saveProject),
                      _buildMobileAppBarButton('Output', Icons.folder_open, _setOutputFolder),
                    ],
                  ),
                )
              : Row(
                  children: [
                    // App title first (top-left)
                    const Icon(Icons.video_library, size: 22),
                    const SizedBox(width: 6),
                    const Text('VEO3 Infinity', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    Container(width: 1, height: 24, color: Colors.grey.shade400),
                    const SizedBox(width: 8),
                    // File Operations - Text buttons right after title
                    _buildAppBarTextButton('Load Prompts', Icons.file_upload_outlined, _loadFile),
                    _buildAppBarTextButton('Paste Prompts', Icons.content_paste, _pasteJson),
                    _buildAppBarTextButton('Save', Icons.save, _saveProject),
                    _buildAppBarTextButton('Open', Icons.folder_open, _loadProject),
                    _buildAppBarTextButton('Output', Icons.create_new_folder, _setOutputFolder),
                    const Spacer(),
                    // Project badge on right
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade700,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.project.name,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white),
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
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.star, size: 12, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              'PREMIUM',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
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
            child: isMobile
              // MOBILE: Top tabs layout (any platform with narrow screen)
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
                          _buildMobileQueueTab(completed, failed, pending, active, upscaling, upscaled),
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
                                        
                                        // Mobile RAM Saving Toggle
                                        if (isMobile)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 4),
                                            child: Row(
                                              children: [
                                                SizedBox(
                                                  height: 24,
                                                  child: Switch(
                                                    value: _showVideoThumbnails,
                                                    onChanged: (val) => setState(() => _showVideoThumbnails = val),
                                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                const Text('Show Video Thumbs', style: TextStyle(fontSize: 11)),
                                                const Spacer(),
                                              ],
                                            ),
                                          ),

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
                                          upscaling: upscaling,
                                          upscaled: upscaled,
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
                                      upscaling: upscaling,
                                      upscaled: upscaled,
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
                                  if (!_isControlsCollapsed) ...[
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // Collapse toggle on the left
                                        InkWell(
                                          onTap: () {
                                            setState(() {
                                              _isControlsCollapsed = !_isControlsCollapsed;
                                            });
                                          },
                                          borderRadius: BorderRadius.circular(4),
                                          child: Padding(
                                            padding: const EdgeInsets.all(4),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.expand_less, size: 18, color: Colors.grey.shade600),
                                                Text(
                                                  'Hide',
                                                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        Container(
                                          width: 1,
                                          height: 60,
                                          color: Colors.grey.shade300,
                                          margin: const EdgeInsets.symmetric(horizontal: 8),
                                        ),
                                        // Controls
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
                                        // Stats
                                        Expanded(
                                          flex: 2,
                                          child: StatsDisplay(
                                            total: scenes.length,
                                            completed: completed,
                                            failed: failed,
                                            pending: pending,
                                            active: active,
                                            upscaling: upscaling,
                                            upscaled: upscaled,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ] else ...[
                                    // When collapsed, show compact row with Show button and stats
                                    Row(
                                      children: [
                                        InkWell(
                                          onTap: () {
                                            setState(() {
                                              _isControlsCollapsed = !_isControlsCollapsed;
                                            });
                                          },
                                          borderRadius: BorderRadius.circular(4),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.blue.shade50,
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: Colors.blue.shade200),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.expand_more, size: 16, color: Colors.blue.shade700),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'Show Controls',
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.blue.shade700),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: StatsDisplay(
                                            total: scenes.length,
                                            completed: completed,
                                            failed: failed,
                                            pending: pending,
                                            active: active,
                                            upscaling: upscaling,
                                            upscaled: upscaled,
                                            isCompact: true,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  // Quick Generate - Only visible when NOT collapsed
                                  if (!_isControlsCollapsed) ...[
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
                                            onSubmitted: (value) {
                                              final prompt = value.trim();
                                              if (prompt.isNotEmpty) {
                                                final newSceneIndex = scenes.length + 1; // 1-indexed
                                                setState(() {
                                                  scenes.add(SceneData(
                                                    sceneId: DateTime.now().millisecondsSinceEpoch,
                                                    prompt: prompt,
                                                  ));
                                                  _quickPromptController.clear();
                                                  toIndex = scenes.length;
                                                  if (!isRunning) {
                                                    fromIndex = newSceneIndex;
                                                  }
                                                });
                                                // Always try to start if not running
                                                if (!isRunning) {
                                                  _startGeneration();
                                                }
                                              }
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        ElevatedButton.icon(
                                          onPressed: () {
                                            final prompt = _quickPromptController.text.trim();
                                            if (prompt.isNotEmpty) {
                                              final newSceneIndex = scenes.length + 1; // 1-indexed
                                              setState(() {
                                                scenes.add(SceneData(
                                                  sceneId: DateTime.now().millisecondsSinceEpoch,
                                                  prompt: prompt,
                                                ));
                                                _quickPromptController.clear();
                                                // Always expand toIndex to include new scene
                                                toIndex = scenes.length;
                                                // If not running, set fromIndex to this scene
                                                if (!isRunning) {
                                                  fromIndex = newSceneIndex;
                                                }
                                              });
                                              // Always try to start - _startGeneration handles browser checks
                                              if (!isRunning) {
                                                _startGeneration();
                                              }
                                            }
                                          },
                                          icon: Icon(isRunning ? Icons.add : Icons.play_arrow),
                                          label: Text(isRunning ? 'Add to Queue' : 'Generate'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: isRunning ? Colors.green : Colors.blue,
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
                                    const SizedBox(height: 8),
                                    // Bulk Import Buttons for I2V
                                    Row(
                                      children: [
                                        const Text('I2V:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: _importBulkFirstFrames,
                                            icon: const Icon(Icons.image, size: 14),
                                            label: const Text('First Frames', style: TextStyle(fontSize: 11)),
                                            style: OutlinedButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              minimumSize: const Size(0, 28),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: _importBulkLastFrames,
                                            icon: const Icon(Icons.image_outlined, size: 14),
                                            label: const Text('Last Frames', style: TextStyle(fontSize: 11)),
                                            style: OutlinedButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              minimumSize: const Size(0, 28),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    // Clear All Scenes and Bulk Upscale buttons in a row
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        // Clear All on left
                                        TextButton.icon(
                                          onPressed: _confirmClearAllScenes,
                                          icon: Icon(Icons.delete_sweep, size: 18, color: Colors.red.shade400),
                                          label: Text('Clear All Scenes', style: TextStyle(fontSize: 13, color: Colors.red.shade400)),
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          ),
                                        ),
                                        // Bulk Upscale on right
                                        if (!isUpscaling)
                                          TextButton.icon(
                                            onPressed: () {
                                              print('[UI] Desktop Upscale button clicked!');
                                              _bulkUpscale();
                                            },
                                            icon: Icon(Icons.hd, size: 18, color: Colors.purple.shade600),
                                            label: Text('Bulk Upscale 1080p', style: TextStyle(fontSize: 13, color: Colors.purple.shade600)),
                                            style: TextButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              minimumSize: Size.zero,
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                          ),
                                        // Stop Upscale button - shown when upscaling
                                        if (isUpscaling)
                                          TextButton.icon(
                                            onPressed: _stopUpscale,
                                            icon: const Icon(Icons.stop_circle, size: 18, color: Colors.red),
                                            label: const Text('Stop Upscale', style: TextStyle(fontSize: 13, color: Colors.red)),
                                            style: TextButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              minimumSize: Size.zero,
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                          ),
                                      ],
                                    ),
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
                            key: ValueKey('${scene.sceneId}_${scene.status}_${scene.videoPath ?? ""}'),
                            scene: scene,
                            onPromptChanged: (newPrompt) {
                              setState(() {
                                scene.prompt = newPrompt;
                              });
                            },
                            onPickImage: (frameType) => _pickImageForScene(scene, frameType),
                            onClearImage: (frameType) => _clearImageForScene(scene, frameType),
                            onGenerate: () {
                              _runSingleGeneration(scene);
                            },
                            onOpen: () => _openVideo(scene),
                            // PC only: Show folder icon
                            onOpenFolder: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
                                ? () => _openVideoFolder(scene)
                                : null,
                            onDelete: () {
                              setState(() {
                                scenes.removeAt(index);
                              });
                            },
                            onUpscale: scene.status == 'completed' ? () {
                              // Toggle between upscale and stop
                              if (scene.upscaleStatus == 'upscaling' || 
                                  scene.upscaleStatus == 'polling' ||
                                  scene.upscaleStatus == 'downloading') {
                                // Stop the upscale
                                print('[UI] Stop upscale clicked: ${scene.sceneId}');
                                setState(() {
                                  scene.upscaleStatus = 'failed';
                                  scene.error = 'Stopped by user';
                                });
                              } else {
                                // Start the upscale
                                print('[UI] Desktop single upscale: ${scene.sceneId}');
                                _upscaleScene(scene);
                              }
                            } : null,
                            showThumbnails: _showVideoThumbnails,
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
  Widget _buildMobileQueueTab(int completed, int failed, int pending, int active, int upscaling, int upscaled) {
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
                      upscaling: upscaling,
                      upscaled: upscaled,
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

                      // From/To Range & Thumbs Toggle
                      Row(
                        children: [
                          const Text('Range:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500)),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 36,
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
                          const Text('-', style: TextStyle(fontSize: 10)),
                          SizedBox(
                            width: 36,
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
                          const Spacer(),
                          // Compact Thumbs Toggle
                          const Text('Thumbs:', style: TextStyle(fontSize: 10)),
                          Transform.scale(
                            scale: 0.7,
                            child: Switch(
                              value: _showVideoThumbnails,
                              onChanged: (val) => setState(() => _showVideoThumbnails = val),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
        // Clear All and Bulk Upscale buttons for mobile
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Clear All on left
              TextButton.icon(
                onPressed: _confirmClearAllScenes,
                icon: Icon(Icons.delete_sweep, size: 16, color: Colors.red.shade400),
                label: Text('Clear All', style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              // Bulk Upscale / Stop on right
              if (!isUpscaling)
                TextButton.icon(
                  onPressed: () {
                    print('[UI] Upscale button clicked!');
                    mobileLog('[UI] Upscale button clicked');
                    _bulkUpscale();
                  },
                  icon: Icon(Icons.hd, size: 16, color: Colors.purple.shade600),
                  label: Text('Upscale 1080p', style: TextStyle(fontSize: 12, color: Colors.purple.shade600)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              // Stop Upscale button - shown when upscaling
              if (isUpscaling)
                TextButton.icon(
                  onPressed: _stopUpscale,
                  icon: const Icon(Icons.stop_circle, size: 16, color: Colors.red),
                  label: const Text('Stop', style: TextStyle(fontSize: 12, color: Colors.red)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
        ),
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
                key: ValueKey('${scene.sceneId}_${scene.status}_${scene.videoPath ?? ""}'),
                scene: scene,
                onPromptChanged: (p) => setState(() => scene.prompt = p),
                onPickImage: (f) => _pickImageForScene(scene, f),
                onClearImage: (f) => _clearImageForScene(scene, f),
                onGenerate: () { 
                  _runSingleGeneration(scene); 
                },
                onOpen: () => _openVideo(scene),
                onOpenFolder: () => _openVideoFolder(scene),
                onDelete: () => setState(() => scenes.removeAt(index)),
                onUpscale: scene.status == 'completed' ? () {
                  // Toggle between upscale and stop
                  if (scene.upscaleStatus == 'upscaling' || 
                      scene.upscaleStatus == 'polling' ||
                      scene.upscaleStatus == 'downloading') {
                    // Stop the upscale
                    print('[UI] Stop upscale clicked: ${scene.sceneId}');
                    mobileLog('[UI] Stop upscale ${scene.sceneId}');
                    setState(() {
                      scene.upscaleStatus = 'failed';
                      scene.error = 'Stopped by user';
                    });
                  } else {
                    // Start the upscale
                    print('[UI] Single scene upscale clicked: ${scene.sceneId}');
                    mobileLog('[UI] Upscale scene ${scene.sceneId}');
                    _upscaleScene(scene);
                  }
                } : null,
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
                    onStop: _handleStopLogin,
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
                  // Count badge - shows active browsers
                  if (service.profiles.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: service.countHealthy() > 0 
                            ? Colors.green.shade100 
                            : Colors.red.shade100,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${service.countHealthy()}/${service.profiles.length} active',
                        style: TextStyle(
                          fontSize: 10, 
                          fontWeight: FontWeight.bold,
                          color: service.countHealthy() > 0 ? Colors.green.shade800 : Colors.red.shade800,
                        ),
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
                          final isActive = hasToken && profile.consecutive403Count < 3 && !profile.isReloginInProgress;
                          final statusText = isActive ? 'Active' : 'Inactive';
                          final statusColor = isActive ? Colors.green : Colors.red;
                          
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
                    // Close the drawer first
                    if (Navigator.canPop(context)) {
                      Navigator.pop(context);
                    }
                    // Then open dedicated Reel Special screen
                    Future.delayed(const Duration(milliseconds: 100), () {
                      _openReelSpecial();
                    });
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
                // File Operations Section (Mobile only)
                const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text(
                    'File Operations',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                _buildSidebarButton(
                  icon: Icons.file_upload_outlined,
                  label: 'Load Prompts',
                  onPressed: () {
                    Navigator.pop(context); // Close drawer
                    _loadFile();
                  },
                ),
                _buildSidebarButton(
                  icon: Icons.content_paste,
                  label: 'Paste Prompts',
                  onPressed: () {
                    Navigator.pop(context); // Close drawer
                    _pasteJson();
                  },
                ),
                _buildSidebarButton(
                  icon: Icons.save,
                  label: 'Save Project',
                  onPressed: () {
                    Navigator.pop(context); // Close drawer
                    _saveProject();
                  },
                ),
                _buildSidebarButton(
                  icon: Icons.folder_open,
                  label: 'Open Output Folder',
                  onPressed: () {
                    Navigator.pop(context); // Close drawer
                    _setOutputFolder();
                  },
                ),
                const Divider(),
                // I2V Section
                const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text(
                    'I2V (Image-to-Video)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                _buildSidebarButton(
                  icon: Icons.image,
                  label: 'Import First Frames',
                  onPressed: _importBulkFirstFrames,
                ),
                _buildSidebarButton(
                  icon: Icons.image_outlined,
                  label: 'Import Last Frames',
                  onPressed: _importBulkLastFrames,
                ),
                // Upload Progress Indicator
                if (_isUploading)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.withOpacity(0.3)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Uploading $_uploadFrameType frames...',
                                  style: const TextStyle(fontWeight: FontWeight.w500),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _uploadTotal > 0 ? _uploadCurrent / _uploadTotal : 0,
                            backgroundColor: Colors.grey[300],
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$_uploadCurrent / $_uploadTotal',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Retry Failed Uploads Button
                if (!_isUploading && _getFailedUploadCount() > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ElevatedButton.icon(
                      onPressed: _retryFailedUploads,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text('Retry Failed (${_getFailedUploadCount()})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 40),
                      ),
                    ),
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
                  icon: Icons.auto_awesome,
                  label: 'SceneBuilder',
                  onPressed: () async {
                    // Close drawer
                    if (Navigator.canPop(context)) Navigator.pop(context);
                    // Navigate to Screen and wait for result
                    final result = await Navigator.push<Map<String, dynamic>>(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CharacterStudioScreen(
                          projectService: widget.projectService,
                          isActivated: widget.isActivated,
                        ),
                      ),
                    );
                    
                    // Handle result if returning with video generation data
                    if (result != null && result['action'] == 'add_to_video_gen') {
                      final sceneId = result['sceneId'] as int? ?? (scenes.length + 1);
                      final imagePath = result['imagePath'] as String?;
                      final prompt = result['prompt'] as String? ?? '';
                      final imageFileName = result['imageFileName'] as String? ?? '';
                      
                      if (imagePath != null && prompt.isNotEmpty) {
                        // Add new scene for video generation with the image as first frame
                        setState(() {
                          scenes.add(SceneData(
                            sceneId: sceneId,
                            prompt: prompt,
                            status: 'queued',
                            firstFramePath: imagePath,
                          ));
                          toIndex = scenes.length;
                          _toIndexController.text = toIndex.toString();
                        });
                        
                        // Save to project
                        await _savePromptsToProject();
                        
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Added Scene $sceneId to Video Queue with image: $imageFileName'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      }
                    }
                  },
                  iconColor: Colors.deepPurple,
                ),
                _buildSidebarButton(
                  icon: Icons.audiotrack,
                  label: 'Manual Audio with Video',
                  onPressed: _openStoryAudio,
                  iconColor: Colors.purple.shade600,
                  badge: 'NEW',
                  badgeColor: Colors.orange,
                  isHighlighted: true,
                ),
                _buildSidebarButton(
                  icon: Icons.movie_creation,
                  label: 'Reel Special',
                  onPressed: _openReelSpecial,
                  iconColor: Colors.deepPurple.shade600,
                ),
                _buildSidebarButton(
                  icon: Icons.movie_filter,
                  label: 'Video Mastering',
                  onPressed: () {
                    // Close drawer
                    if (Navigator.canPop(context)) Navigator.pop(context);
                    // Navigate to Video Mastering Screen
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => VideoMasteringScreen(
                          projectService: widget.projectService,
                          isActivated: widget.isActivated,
                        ),
                      ),
                    );
                  },
                  iconColor: Colors.teal.shade600,
                  badge: 'NEW',
                  badgeColor: Colors.teal,
                  isHighlighted: true,
                ),
                _buildSidebarButton(
                  icon: Icons.video_library,
                  label: 'Join Video Clips / Export',
                  onPressed: _concatenateVideos,
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

  /// Build a compact text button for the AppBar
  Widget _buildAppBarTextButton(String label, IconData icon, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
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

  /// Compact button for mobile AppBar
  Widget _buildMobileAppBarButton(String label, IconData icon, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.grey.shade800),
              const SizedBox(width: 3),
              Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade800)),
            ],
          ),
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

  /// Upscale a single video to 1080p
  Future<void> _upscaleScene(SceneData scene) async {
    print('[UPSCALE SINGLE] ========== STARTING ==========');
    print('[UPSCALE SINGLE] Scene ${scene.sceneId}');
    print('[UPSCALE SINGLE] videoMediaId: ${scene.videoMediaId}');
    print('[UPSCALE SINGLE] operationName: ${scene.operationName}');
    print('[UPSCALE SINGLE] downloadUrl: ${scene.downloadUrl}');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[UPSCALE] Starting single scene ${scene.sceneId}');
    }
    
    // Check if we have a video identifier (operationName = mediaId from generation)
    if (scene.videoMediaId == null && scene.operationName == null && scene.downloadUrl == null) {
      print('[UPSCALE SINGLE] ✗ No video identifier found');
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[UPSCALE] ✗ No video to upscale');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No video to upscale'), backgroundColor: Colors.orange),
      );
      return;
    }
    
    // Get a connected browser/generator
    dynamic uploadGenerator;
    String? uploadToken;
    
    if (Platform.isAndroid || Platform.isIOS) {
      print('[UPSCALE SINGLE] Getting mobile browser profile...');
      final service = MobileBrowserService();
      print('[UPSCALE SINGLE] Profile count: ${service.profiles.length}');
      print('[UPSCALE SINGLE] Healthy count: ${service.countHealthy()}');
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[UPSCALE] Profiles: ${service.profiles.length}, Healthy: ${service.countHealthy()}');
      }
      
      final profile = service.getNextAvailableProfile();
      if (profile != null) {
        print('[UPSCALE SINGLE] Got profile: ${profile.name}, generator: ${profile.generator != null}, token: ${profile.accessToken != null}');
        if (profile.generator != null && profile.accessToken != null) {
          uploadGenerator = profile.generator;
          uploadToken = profile.accessToken;
          if (Platform.isAndroid || Platform.isIOS) {
            mobileLog('[UPSCALE] ✓ Using profile: ${profile.name}');
          }
        }
      } else {
        print('[UPSCALE SINGLE] ✗ No profile available');
        if (Platform.isAndroid || Platform.isIOS) {
          mobileLog('[UPSCALE] ✗ No profile available');
        }
      }
    } else {
      if (_profileManager != null && _profileManager!.countConnectedProfiles() > 0) {
        for (final p in _profileManager!.profiles) {
          if (p.generator != null && p.accessToken != null) {
            uploadGenerator = p.generator;
            uploadToken = p.accessToken;
            break;
          }
        }
      } else if (generator != null && accessToken != null) {
        uploadGenerator = generator;
        uploadToken = accessToken;
      }
    }
    
    if (uploadGenerator == null || uploadToken == null) {
      print('[UPSCALE SINGLE] ✗ No generator or token available');
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[UPSCALE] ✗ No browser connected');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No browser connected. Please login first.'), backgroundColor: Colors.red),
      );
      return;
    }
    
    // We need the video mediaId (mediaGenerationId saved during video generation)
    // NOTE: operationName is NOT the same as mediaId - don't use it!
    // The mediaId is extracted from operation.metadata.video.mediaGenerationId when video completes
    String? videoMediaId = scene.videoMediaId;
    
    // Log what we have
    print('[UPSCALE] Checking scene ${scene.sceneId}:');
    print('[UPSCALE]   videoMediaId: $videoMediaId');
    print('[UPSCALE]   operationName: ${scene.operationName}');
    print('[UPSCALE]   downloadUrl: ${scene.downloadUrl != null ? "present" : "null"}');
    
    if (videoMediaId == null) {
      // Cannot upscale without proper mediaId
      print('[UPSCALE] ✗ No mediaId saved for this video. Video must complete and have mediaGenerationId extracted.');
      mobileLog('[UPSCALE] ✗ No mediaId for scene ${scene.sceneId}');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot upscale: No media ID saved for this video. Re-generate the video.'), backgroundColor: Colors.red),
      );
      return;
    }
    
    setState(() {
      scene.upscaleStatus = 'upscaling';
    });
    
    print('[UPSCALE] Starting upscale for scene ${scene.sceneId}');
    print('[UPSCALE] videoMediaId: $videoMediaId');
    print('[UPSCALE] videoMediaId length: ${videoMediaId.length}');
    mobileLog('[UPSCALE] Starting scene ${scene.sceneId}...');
    mobileLog('[UPSCALE] MediaId: ${videoMediaId.length > 30 ? videoMediaId.substring(0, 30) + '...' : videoMediaId}');
    mobileLog('[UPSCALE] Sending request...');
    
    try {
      // Use the scene's aspect ratio if stored, otherwise use global
      // Videos generated in portrait mode need portrait aspect ratio for upscaling
      final videoAspectRatio = scene.aspectRatio ?? selectedAspectRatio;
      print('[UPSCALE] Using aspect ratio: $videoAspectRatio (scene stored: ${scene.aspectRatio}, global: $selectedAspectRatio)');
      mobileLog('[UPSCALE] AspectRatio: $videoAspectRatio');
      
      final result = await uploadGenerator.upscaleVideo(
        videoMediaId: videoMediaId,
        accessToken: uploadToken,
        aspectRatio: videoAspectRatio,
      );
      
      if (result != null && result['success'] == true) {
        final data = result['data'];
        final alreadyExists = result['alreadyExists'] == true;
        
        print('[UPSCALE] Success! AlreadyExists: $alreadyExists');
        mobileLog('[UPSCALE] ✓ ${alreadyExists ? "Already upscaling" : "Request accepted"}');
        
        // If 409 (already exists) and we have a previous operation name, use it
        if (alreadyExists && scene.upscaleOperationName != null) {
          print('[UPSCALE] Using existing operation: ${scene.upscaleOperationName}');
          mobileLog('[UPSCALE] Using existing poll...');
          
          setState(() {
            scene.upscaleStatus = 'polling';
          });
          
          // Start polling with existing operation name
          await _pollUpscaleCompletion(scene, scene.upscaleOperationName!, scene.upscaleOperationName!, uploadGenerator, uploadToken!);
          return;
        }
        
        // Extract operation name from response
        String? opName;
        if (data != null && data['operations'] != null && (data['operations'] as List).isNotEmpty) {
          final op = data['operations'][0] as Map<String, dynamic>?;
          print('[UPSCALE] First operation: $op');
          
          if (op != null) {
            // Try different paths to find operation name
            final operation = op['operation'] as Map<String, dynamic>?;
            opName = operation?['name'] as String? ?? op['operationName'] as String? ?? op['name'] as String?;
          }
          
          if (opName != null) {
            final sceneUuid = op?['sceneId'] as String? ?? result['sceneId'] as String? ?? opName;
            
            print('[UPSCALE] Operation name: $opName');
            mobileLog('[UPSCALE] Op: ${opName.length > 30 ? opName.substring(0, 30) + "..." : opName}');
            
            setState(() {
              scene.upscaleOperationName = opName;
              scene.upscaleStatus = 'polling';
            });
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Upscale started for scene ${scene.sceneId}. Polling...'), backgroundColor: Colors.blue),
            );
            
            // Start polling for upscale completion
            await _pollUpscaleCompletion(scene, opName, sceneUuid, uploadGenerator, uploadToken!);
          } else {
            print('[UPSCALE] ⚠ No operation name found in response');
            print('[UPSCALE] Data: $data');
            mobileLog('[UPSCALE] ⚠ No opName in response');
            throw Exception('No operation name found in response');
          }
        } else {
          print('[UPSCALE] ⚠ No operations in response. Data: $data');
          mobileLog('[UPSCALE] ⚠ Empty operations');
          throw Exception('No operations in upscale response');
        }
      } else {
        // Log full error details
        print('[UPSCALE] ✗ Request failed!');
        print('[UPSCALE] Response success: ${result?['success']}');
        print('[UPSCALE] Response status: ${result?['status']}');
        print('[UPSCALE] Response error: ${result?['error']}');
        print('[UPSCALE] Response data: ${result?['data']}');
        mobileLog('[UPSCALE] ✗ ${result?['status']}: ${result?['error'] ?? result?['data']}');
        setState(() {
          scene.upscaleStatus = 'failed';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upscale failed (${result?['status']}): ${result?['error'] ?? 'Unknown error'}'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      mobileLog('[UPSCALE] ✗ Error: $e');
      setState(() {
        scene.upscaleStatus = 'failed';
      });
      print('[UPSCALE] Error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upscale error: $e'), backgroundColor: Colors.red),
      );
    }
  }
  
  /// Poll for upscale completion and download the upscaled video
  Future<void> _pollUpscaleCompletion(
    SceneData scene,
    String operationName,
    String sceneUuid,
    dynamic generator,
    String accessToken,
  ) async {
    print('[UPSCALE POLL] Starting poll for scene ${scene.sceneId}, operation: $operationName');
    mobileLog('[UPSCALE] Polling started for scene ${scene.sceneId}');
    
    // Set status to polling 
    setState(() {
      scene.upscaleStatus = 'polling';
    });
    
    const maxPolls = 120; // 10 minutes max
    int pollCount = 0;
    
    // Loop while status is polling (not failed or completed)
    while (pollCount < maxPolls && scene.upscaleStatus == 'polling') {
      pollCount++;
      
      // Wait 5-8 seconds between polls
      final delay = 5 + (DateTime.now().millisecondsSinceEpoch % 3);
      print('[UPSCALE POLL] Waiting ${delay}s before poll #$pollCount...');
      await Future.delayed(Duration(seconds: delay));
      
      try {
        // Log each polling attempt
        print('[UPSCALE POLL] === Poll #$pollCount for scene ${scene.sceneId} ===');
        mobileLog('[UPSCALE] Poll #$pollCount for ${scene.sceneId}...');
        
        final poll = await generator.pollVideoStatus(operationName, sceneUuid, accessToken);
        
        print('[UPSCALE POLL] Got response: ${poll != null}');
        if (poll != null) {
          print('[UPSCALE POLL] Response keys: ${poll.keys.toList()}');
        }
        
        if (poll != null) {
          final status = poll['status'] as String?;
          print('[UPSCALE POLL] Scene ${scene.sceneId}: $status');
          
          // Show status in UI console
          final shortStatus = status?.replaceAll('MEDIA_GENERATION_STATUS_', '') ?? 'UNKNOWN';
          mobileLog('[UPSCALE] ${scene.sceneId}: $shortStatus');
          
          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            mobileLog('[UPSCALE] ✓ ${scene.sceneId} ready! Downloading...');
            
            // Extract upscaled video URL - handle different response structures
            String? videoUrl;
            
            // Structure 1: poll has 'operation' key directly
            if (poll.containsKey('operation')) {
              final op = poll['operation'] as Map<String, dynamic>?;
              final metadata = op?['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] as String?;
              print('[UPSCALE POLL] Found fifeUrl in operation.metadata.video: $videoUrl');
            }
            
            // Structure 2: poll has nested 'operations' array (batch response)
            if (videoUrl == null && poll.containsKey('operations')) {
              final operations = poll['operations'] as List?;
              if (operations != null && operations.isNotEmpty) {
                final firstOp = operations[0] as Map<String, dynamic>?;
                final op = firstOp?['operation'] as Map<String, dynamic>?;
                final metadata = op?['metadata'] as Map<String, dynamic>?;
                final video = metadata?['video'] as Map<String, dynamic>?;
                videoUrl = video?['fifeUrl'] as String?;
                print('[UPSCALE POLL] Found fifeUrl in operations[0]: $videoUrl');
              }
            }
            
            if (videoUrl != null) {
              print('[UPSCALE] ✓ Upscale complete! Downloading...');
              
              // Download to "upscaled" subfolder in output directory
              final originalPath = scene.videoPath ?? '';
              final originalDir = path.dirname(originalPath);
              final originalFilename = path.basename(originalPath);
              
              // Create upscaled folder
              final upscaledDir = path.join(originalDir, 'upscaled');
              await Directory(upscaledDir).create(recursive: true);
              
              // Save with same filename in upscaled folder
              final upscaledPath = path.join(upscaledDir, originalFilename.replaceAll('.mp4', '_1080p.mp4'));
              
              print('[UPSCALE] Saving to: $upscaledPath');
              mobileLog('[UPSCALE] Saving ${scene.sceneId} to 1080p...');
              await generator.downloadVideo(videoUrl, upscaledPath);
              
              setState(() {
                scene.upscaleVideoPath = upscaledPath;
                scene.upscaleDownloadUrl = videoUrl;
                scene.upscaleStatus = 'completed';
              });
              
              mobileLog('[UPSCALE] ✓ ${scene.sceneId} upscaled to 1080p!');
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✓ Scene ${scene.sceneId} upscaled to 1080p! Saved to upscaled/'), backgroundColor: Colors.green),
                );
              }
              return;
            } else {
              throw Exception('No video URL in upscale response');
            }
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
            mobileLog('[UPSCALE] ✗ ${scene.sceneId} failed on server');
            throw Exception('Upscale failed on server');
          }
          // Otherwise continue polling (still processing)
        }
      } catch (e) {
        print('[UPSCALE POLL] Error: $e');
        mobileLog('[UPSCALE] ✗ ${scene.sceneId} error: $e');
        setState(() {
          scene.upscaleStatus = 'failed';
          scene.error = 'Upscale poll error: $e';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Upscale failed: $e'), backgroundColor: Colors.red),
          );
        }
        return;
      }
    }
    
    // Timeout
    if (scene.upscaleStatus == 'upscaling') {
      mobileLog('[UPSCALE] ⚠ ${scene.sceneId} timeout (10min)');
      setState(() {
        scene.upscaleStatus = 'failed';
        scene.error = 'Upscale timeout (10 minutes)';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upscale timeout'), backgroundColor: Colors.orange),
        );
      }
    }
  }
  
  /// Stop the upscale process
  void _stopUpscale() {
    if (!isUpscaling) return;
    
    setState(() {
      isUpscaling = false;
    });
    
    // Log to console
    print('[UPSCALE] ⏹ Stopping upscale process...');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[UPSCALE] ⏹ Stopped by user');
    }
    
    // Reset any upscaling scenes back to their previous status
    for (final scene in scenes) {
      if (scene.upscaleStatus == 'upscaling' || scene.upscaleStatus == 'polling') {
        setState(() {
          scene.upscaleStatus = null; // Reset to not started
        });
      }
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Upscale process stopped'),
        backgroundColor: Colors.orange,
      ),
    );
  }
  
  /// Bulk upscale all completed videos
  Future<void> _bulkUpscale() async {
    print('[BULK UPSCALE] ========== STARTING ==========');
    print('[BULK UPSCALE] Total scenes: ${scenes.length}');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[BULK UPSCALE] Starting...');
      mobileLog('[BULK UPSCALE] Total scenes: ${scenes.length}');
    }
    
    // List all scene statuses for debugging
    for (int i = 0; i < scenes.length; i++) {
      final s = scenes[i];
      print('[BULK UPSCALE] Scene $i: status=${s.status}, upscaleStatus=${s.upscaleStatus}, videoPath=${s.videoPath != null}');
    }
    
    final completedScenes = scenes.where((s) => s.status == 'completed' && s.upscaleStatus != 'completed').toList();
    
    print('[BULK UPSCALE] Completed scenes to upscale: ${completedScenes.length}');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[BULK UPSCALE] Found ${completedScenes.length} to upscale');
    }
    
    if (completedScenes.isEmpty) {
      print('[BULK UPSCALE] No completed videos to upscale - returning');
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[BULK UPSCALE] ⚠ No videos to upscale');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No completed videos to upscale'), backgroundColor: Colors.orange),
      );
      return;
    }
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bulk Upscale'),
        content: Text('Upscale ${completedScenes.length} completed videos to 1080p?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
            child: const Text('Start Upscale', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    
    print('[BULK UPSCALE] Confirmed: $confirmed');
    if (confirmed != true) {
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[BULK UPSCALE] Cancelled by user');
      }
      return;
    }
    
    // Set upscaling flag
    setState(() => isUpscaling = true);
    
    print('[BULK UPSCALE] isUpscaling set to true');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[BULK UPSCALE] ✓ Started!');
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Starting upscale for ${completedScenes.length} videos...'), backgroundColor: Colors.blue),
    );
    
    // Determine concurrency based on model
    final isRelaxedModel = selectedModel.contains('Lower Priority') || 
                            selectedModel.contains('relaxed') ||
                            selectedModel.contains('Relaxed');
    final maxConcurrent = isRelaxedModel ? 4 : 20;
    print('[BULK UPSCALE] Max concurrent: $maxConcurrent (Relaxed: $isRelaxedModel)');
    mobileLog('[BULK UPSCALE] Starting ${completedScenes.length} videos, max concurrent: $maxConcurrent');
    
    // Pending upscale polls list
    final pendingUpscalePolls = <_UpscalePoll>[];
    int activeUpscales = 0;
    bool upscaleComplete = false;
    
    // Retry tracking for each scene (sceneId -> retryCount)
    final upscaleRetryCount = <int, int>{};
    const maxUpscaleRetries = 10;
    
    // Start upscale poll worker
    Future<void> upscalePollWorker() async {
      print('[UPSCALE POLL WORKER] Started');
      mobileLog('[UPSCALE] Poll worker started');
      
      while (isUpscaling && (!upscaleComplete || pendingUpscalePolls.isNotEmpty)) {
        if (pendingUpscalePolls.isEmpty) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        
        // Get generator for polling
        dynamic pollGenerator;
        String? pollToken;
        
        if (Platform.isAndroid || Platform.isIOS) {
          final service = MobileBrowserService();
          final profile = service.getNextAvailableProfile();
          if (profile != null) {
            pollGenerator = profile.generator;
            pollToken = profile.accessToken;
            print('[UPSCALE POLL] Got profile: ${profile.name}');
          } else {
            // No healthy profile - wait for relogin
            final healthyCount = service.countHealthy();
            print('[UPSCALE POLL] No profile available, healthy: $healthyCount');
            if (healthyCount == 0) {
              print('[UPSCALE POLL] ⏸ No healthy browsers - waiting for relogin...');
              mobileLog('[UPSCALE] ⏸ Waiting for browser...');
              int waitCount = 0;
              while (service.countHealthy() == 0 && waitCount < 30 && (!upscaleComplete || pendingUpscalePolls.isNotEmpty)) {
                await Future.delayed(const Duration(seconds: 2));
                waitCount++;
              }
              continue;
            }
          }
        } else if (_profileManager != null) {
          for (final p in _profileManager!.profiles) {
            if (p.generator != null && p.accessToken != null) {
              pollGenerator = p.generator;
              pollToken = p.accessToken;
              break;
            }
          }
        }
        
        if (pollGenerator == null || pollToken == null) {
          print('[UPSCALE POLL] Waiting for available browser...');
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        
        // Build batch poll requests
        print('[UPSCALE POLL] Building batch for ${pendingUpscalePolls.length} polls');
        mobileLog('[UPSCALE POLL] Polling ${pendingUpscalePolls.length} videos...');
        
        final pollRequests = pendingUpscalePolls.map((p) => 
          PollRequest(p.operationName, p.sceneUuid)).toList();
        
        try {
          print('[UPSCALE POLL] Calling pollVideoStatusBatch...');
          final results = await pollGenerator.pollVideoStatusBatch(pollRequests, pollToken);
          
          print('[UPSCALE POLL] Got results: ${results != null}, count: ${results?.length ?? 0}');
          if (results != null && results.isNotEmpty) {
            final completedIndices = <int>[];
            
            for (var i = 0; i < results.length && i < pendingUpscalePolls.length; i++) {
              final result = results[i];
              final poll = pendingUpscalePolls[i];
              final scene = poll.scene;
              final status = result['status'] as String?;
              
              // Log status for visibility
              print('[UPSCALE POLL] Scene ${scene.sceneId}: $status');
              if (Platform.isAndroid || Platform.isIOS) {
                final shortStatus = status?.replaceAll('MEDIA_GENERATION_STATUS_', '') ?? '?';
                mobileLog('[POLL] ${scene.sceneId}: $shortStatus');
              }
              
              if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
                  status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
                // Extract video URL
                String? videoUrl;
                if (result.containsKey('operation')) {
                  final op = result['operation'] as Map<String, dynamic>?;
                  final metadata = op?['metadata'] as Map<String, dynamic>?;
                  final video = metadata?['video'] as Map<String, dynamic>?;
                  videoUrl = video?['fifeUrl'] as String?;
                }
                
                if (videoUrl != null) {
                  // Set downloading status
                  setState(() {
                    scene.upscaleStatus = 'downloading';
                  });
                  if (Platform.isAndroid || Platform.isIOS) {
                    mobileLog('[UPSCALE] Downloading 1080p for scene ${scene.sceneId}');
                  }
                  print('[UPSCALE] Downloading upscaled video for scene ${scene.sceneId}...');
                  
                  // Download upscaled video
                  final originalPath = scene.videoPath ?? '';
                  final originalDir = path.dirname(originalPath);
                  final originalFilename = path.basename(originalPath);
                  final upscaledDir = path.join(originalDir, 'upscaled');
                  await Directory(upscaledDir).create(recursive: true);
                  final upscaledPath = path.join(upscaledDir, originalFilename.replaceAll('.mp4', '_1080p.mp4'));
                  
                  await pollGenerator.downloadVideo(videoUrl, upscaledPath);
                  
                  setState(() {
                    scene.upscaleVideoPath = upscaledPath;
                    scene.upscaleDownloadUrl = videoUrl;
                    scene.upscaleStatus = 'upscaled';
                  });
                  if (Platform.isAndroid || Platform.isIOS) {
                    mobileLog('[UPSCALE] ✓ Scene ${scene.sceneId} upscaled to 1080p');
                  }
                  print('[UPSCALE] ✓ Scene ${scene.sceneId} upscaled and downloaded');
                }
                
                activeUpscales--;
                completedIndices.add(i);
              } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
                setState(() {
                  scene.upscaleStatus = 'failed';
                  scene.error = 'Upscale failed on server';
                });
                activeUpscales--;
                completedIndices.add(i);
                if (Platform.isAndroid || Platform.isIOS) {
                  mobileLog('[UPSCALE] ✗ Scene ${scene.sceneId} failed on server');
                }
                print('[UPSCALE] ✗ Scene ${scene.sceneId} failed');
              }
            }
            
            // Remove completed from pending
            for (final idx in completedIndices.reversed) {
              pendingUpscalePolls.removeAt(idx);
            }
            
            if (completedIndices.isNotEmpty) {
              print('[UPSCALE POLL] Completed ${completedIndices.length} scenes, remaining: ${pendingUpscalePolls.length}');
              mobileLog('[POLL] Done ${completedIndices.length}, remaining ${pendingUpscalePolls.length}');
            }
          }
        } catch (e) {
          print('[UPSCALE POLL] Error: $e');
          if (Platform.isAndroid || Platform.isIOS) {
            mobileLog('[POLL] ✗ Error: $e');
          }
        }
        
        // Wait before next poll cycle
        await Future.delayed(const Duration(seconds: 5));
      }
      
      print('[UPSCALE POLL WORKER] Finished');
    }
    
    // Start poll worker
    unawaited(upscalePollWorker());
    
    // Process upscale queue
    for (var i = 0; i < completedScenes.length; i++) {
      // Check for stop
      if (!isUpscaling) {
        print('[UPSCALE] ⏹ Stopped by user');
        break;
      }
      
      final scene = completedScenes[i];
      
      // Wait for available slot (also check stop)
      while (activeUpscales >= maxConcurrent && isUpscaling) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!isUpscaling) break;
      
      // Get video mediaId - must be the proper mediaGenerationId, NOT operationName
      // operationName has format "operations/xxx" which is NOT valid for upscaling
      String? videoMediaId = scene.videoMediaId;
      
      if (videoMediaId == null) {
        print('[UPSCALE] ✗ Scene ${scene.sceneId} - no mediaId saved');
        mobileLog('[UPSCALE] ✗ ${scene.sceneId}: no mediaId');
        continue;
      }
      
      // Get available browser (skip relogging ones)
      dynamic upscaleProfile;
      if (Platform.isAndroid || Platform.isIOS) {
        upscaleProfile = MobileBrowserService().getNextAvailableProfile();
        
        // If no healthy profiles, wait for relogin
        if (upscaleProfile == null) {
          final service = MobileBrowserService();
          final healthyCount = service.countHealthy();
          final needsRelogin = service.getProfilesNeedingRelogin();
          
          if (needsRelogin.isNotEmpty) {
            print('[UPSCALE] ⏸ Waiting for ${needsRelogin.length} browsers to relogin...');
            service.reloginAllNeeded(
              email: _savedEmail,
              password: _savedPassword,
              onAnySuccess: () => print('[UPSCALE] ✓ A browser recovered!'),
            );
          }
          
          if (healthyCount == 0) {
            // Wait for at least one browser to recover
            int waitCount = 0;
            while (service.countHealthy() == 0 && waitCount < 60) {
              await Future.delayed(const Duration(seconds: 5));
              waitCount++;
              print('[UPSCALE] Waiting for relogin... (${waitCount * 5}s)');
            }
          }
          
          i--;
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
      } else if (_profileManager != null) {
        upscaleProfile = _profileManager!.getNextAvailableProfile();
      }
      
      if (upscaleProfile == null) {
        i--;
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      
      setState(() {
        scene.upscaleStatus = 'upscaling';
      });
      
      // Log to mobile UI
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[UPSCALE] Starting scene ${scene.sceneId}');
      }
      
      try {
        // Use scene's aspect ratio if stored, fallback to global
        final videoAspectRatio = scene.aspectRatio ?? selectedAspectRatio;
        
        print('[UPSCALE] Calling upscaleVideo for scene ${scene.sceneId}');
        print('[UPSCALE] Profile: ${upscaleProfile.name}, Generator: ${upscaleProfile.generator != null}');
        print('[UPSCALE] MediaId: $videoMediaId');
        print('[UPSCALE] AspectRatio: $videoAspectRatio (scene: ${scene.aspectRatio}, global: $selectedAspectRatio)');
        if (Platform.isAndroid || Platform.isIOS) {
          mobileLog('[UPSCALE] Sending request...');
        }
        
        final result = await upscaleProfile.generator!.upscaleVideo(
          videoMediaId: videoMediaId,
          accessToken: upscaleProfile.accessToken!,
          aspectRatio: videoAspectRatio,
        );
        
        print('[UPSCALE] Got result: ${result != null}');
        if (result != null) {
          print('[UPSCALE] Success: ${result['success']}, Status: ${result['status']}');
        }
        if (Platform.isAndroid || Platform.isIOS) {
          mobileLog('[UPSCALE] Response: ${result?['success'] == true ? "✓" : "✗"}');
        }
        
        if (result != null && result['success'] == true) {
          final data = result['data'];
          print('[UPSCALE] Response data keys: ${data?.keys?.toList()}');
          
          if (data != null && data['operations'] != null && (data['operations'] as List).isNotEmpty) {
            final op = data['operations'][0] as Map<String, dynamic>?;
            print('[UPSCALE] First operation: $op');
            
            // Robust operation name extraction - try multiple paths
            String? opName;
            if (op != null) {
              // Path 1: op['operation']['name']
              final operation = op['operation'] as Map<String, dynamic>?;
              opName = operation?['name'] as String?;
              
              // Path 2: op['operationName']
              if (opName == null) {
                opName = op['operationName'] as String?;
              }
              
              // Path 3: op['name']
              if (opName == null) {
                opName = op['name'] as String?;
              }
              
              print('[UPSCALE] Extracted opName: $opName');
              mobileLog('[UPSCALE] Op: ${opName ?? "NULL"}');
            }
            final sceneUuid = op?['sceneId'] as String? ?? result['sceneId'] as String? ?? opName;
            
            if (opName != null) {
              scene.upscaleOperationName = opName;
              pendingUpscalePolls.add(_UpscalePoll(scene, opName, sceneUuid ?? opName));
              activeUpscales++;
              upscaleProfile.consecutive403Count = 0; // Reset on success
              
              // Update status to polling
              setState(() {
                scene.upscaleStatus = 'polling';
              });
              
              if (Platform.isAndroid || Platform.isIOS) {
                mobileLog('[UPSCALE] ${scene.sceneId} → polling');
              }
              print('[UPSCALE] ✓ Scene ${scene.sceneId} started polling (op: $opName)');
            } else {
              print('[UPSCALE] ⚠ No operation name found! Full response: $data');
              mobileLog('[UPSCALE] ⚠ No opName in response');
              setState(() {
                scene.upscaleStatus = 'failed';
                scene.error = 'No operation name in response';
              });
            }
          } else {
            print('[UPSCALE] ⚠ No operations in response! Data: $data');
            mobileLog('[UPSCALE] ⚠ Empty operations');
            setState(() {
              scene.upscaleStatus = 'failed';
              scene.error = 'No operations in response';
            });
          }
        } else {
          // Check for 403 - trigger relogin after 3 consecutive
          final statusCode = result?['status'] as int?;
          if (statusCode == 403) {
            upscaleProfile.consecutive403Count++;
            print('[UPSCALE] 403 error - ${upscaleProfile.name} count: ${upscaleProfile.consecutive403Count}/3');
            
            if (upscaleProfile.consecutive403Count >= 3) {
              print('[UPSCALE] ⚠ Threshold reached - triggering relogin for ${upscaleProfile.name}');
              
              if (Platform.isAndroid || Platform.isIOS) {
                final service = MobileBrowserService();
                service.autoReloginProfile(
                  upscaleProfile,
                  email: _savedEmail,
                  password: _savedPassword,
                  onSuccess: () {
                    print('[UPSCALE] ✓ ${upscaleProfile.name} relogin success');
                    upscaleProfile.consecutive403Count = 0;
                  },
                );
              } else if (_loginService != null) {
                _loginService!.reloginProfile(upscaleProfile, _savedEmail, _savedPassword);
              }
            }
            
            // Track retry count for this scene
            upscaleRetryCount[scene.sceneId] = (upscaleRetryCount[scene.sceneId] ?? 0) + 1;
            final retries = upscaleRetryCount[scene.sceneId]!;
            print('[UPSCALE] Retry ${retries}/$maxUpscaleRetries for scene ${scene.sceneId}');
            if (Platform.isAndroid || Platform.isIOS) {
              mobileLog('[UPSCALE] ${scene.sceneId} 403 retry $retries');
            }
            
            if (retries >= maxUpscaleRetries) {
              // Max retries reached - mark as failed
              print('[UPSCALE] ✗ Scene ${scene.sceneId} failed after $maxUpscaleRetries retries');
              if (Platform.isAndroid || Platform.isIOS) {
                mobileLog('[UPSCALE] ✗ ${scene.sceneId} failed (max retries)');
              }
              setState(() {
                scene.upscaleStatus = 'failed';
                scene.error = 'Upscale failed after $maxUpscaleRetries retries (403)';
              });
            } else {
              // Retry this scene with different browser
              i--;
              await Future.delayed(const Duration(seconds: 3));
            }
          } else {
            if (Platform.isAndroid || Platform.isIOS) {
              mobileLog('[UPSCALE] ✗ ${scene.sceneId} failed: ${result?['error']}');
            }
            setState(() {
              scene.upscaleStatus = 'failed';
              scene.error = 'Upscale failed: ${result?['error']}';
            });
          }
        }
      } catch (e) {
        // Track retry on exception too
        upscaleRetryCount[scene.sceneId] = (upscaleRetryCount[scene.sceneId] ?? 0) + 1;
        final retries = upscaleRetryCount[scene.sceneId]!;
        
        if (retries >= maxUpscaleRetries) {
          print('[UPSCALE] ✗ Scene ${scene.sceneId} failed after $maxUpscaleRetries retries: $e');
          setState(() {
            scene.upscaleStatus = 'failed';
            scene.error = 'Upscale error after $maxUpscaleRetries retries: $e';
          });
        } else {
          print('[UPSCALE] Error (retry ${retries}/$maxUpscaleRetries): $e');
          i--;
          await Future.delayed(const Duration(seconds: 3));
        }
      }
      
      // Small delay between requests
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    // Mark upscale queue as complete
    upscaleComplete = true;
    
    // Wait for all polls to finish (or stop)
    while (pendingUpscalePolls.isNotEmpty && isUpscaling) {
      await Future.delayed(const Duration(seconds: 1));
    }
    
    // Reset upscaling flag
    setState(() => isUpscaling = false);
    
    if (mounted) {
      final completed = completedScenes.where((s) => s.upscaleStatus == 'completed').length;
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[UPSCALE] ✓ Bulk complete: $completed/${completedScenes.length}');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Bulk upscale complete! $completed/${completedScenes.length} videos upscaled.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
  
  // Helper class for upscale polling

  /// Show confirmation dialog before clearing all scenes
  Future<void> _confirmClearAllScenes() async {
    if (scenes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No scenes to clear')),
      );
      return;
    }
    
    // Close drawer first if open (mobile)
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Clear All Scenes?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will remove all ${scenes.length} scene(s) from the queue.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            Text(
              'Completed videos will NOT be deleted from disk.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      setState(() {
        scenes.clear();
      });
      
      // Save empty state to project
      await _savePromptsToProject();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ All scenes cleared'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  // Helper to format file size in human readable format
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _pickImageForScene(SceneData scene, String frameType) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );

    if (result != null && result.files.single.path != null) {
      final filePath = result.files.single.path!;
      
      setState(() {
        if (frameType == 'first') {
          scene.firstFramePath = filePath;
          scene.firstFrameMediaId = null;
          scene.firstFrameUploadStatus = 'uploading';
        } else {
          scene.lastFramePath = filePath;
          scene.lastFrameMediaId = null;
          scene.lastFrameUploadStatus = 'uploading';
        }
      });

      // Auto-upload the image
      await _uploadSingleImage(scene, frameType, filePath);
    }
  }

  /// Upload a single image for a scene using fast direct HTTP method
  Future<void> _uploadSingleImage(SceneData scene, String frameType, String imagePath) async {
    final fileName = imagePath.split(Platform.pathSeparator).last;
    print('[UPLOAD] METHOD: DIRECT-HTTP | Single upload: $fileName');

    // Get token from browser (only need token, not the full CDP upload)
    String? uploadToken;

    if (Platform.isAndroid || Platform.isIOS) {
      final service = MobileBrowserService();
      final profile = service.getNextAvailableProfile();
      if (profile != null && profile.accessToken != null) {
        uploadToken = profile.accessToken;
      }
    } else {
      // Desktop: get token from connected browser
      try {
        if (generator == null || !generator!.isConnected) {
          generator?.close();
          generator = BrowserVideoGenerator();
          await generator!.connect();
          accessToken = await generator!.getAccessToken();
        }
        uploadToken = accessToken;
      } catch (e) {
        print('[UPLOAD] ✗ Failed to get token: $e');
        setState(() {
          if (frameType == 'first') {
            scene.firstFrameUploadStatus = 'failed';
          } else {
            scene.lastFrameUploadStatus = 'failed';
          }
          scene.error = 'Cannot upload: Browser not connected';
        });
        return;
      }
    }

    if (uploadToken == null) {
      setState(() {
        if (frameType == 'first') {
          scene.firstFrameUploadStatus = 'failed';
        } else {
          scene.lastFrameUploadStatus = 'failed';
        }
        scene.error = 'Cannot upload: No access token available';
      });
      return;
    }

    try {
      // Use fast direct HTTP uploader instead of slow CDP method
      final result = await DirectImageUploader.uploadImage(
        imagePath: imagePath,
        accessToken: uploadToken,
      );

      if (result is String) {
        setState(() {
          if (frameType == 'first') {
            scene.firstFrameMediaId = result;
            scene.firstFrameUploadStatus = 'uploaded';
          } else {
            scene.lastFrameMediaId = result;
            scene.lastFrameUploadStatus = 'uploaded';
          }
          scene.error = null;
        });
        print('[UPLOAD] ✓ $fileName -> $result');
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ Image uploaded'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (result is Map && result['error'] == true) {
        final errorMsg = result['message'] ?? 'Unknown error';
        setState(() {
          if (frameType == 'first') {
            scene.firstFrameUploadStatus = 'failed';
          } else {
            scene.lastFrameUploadStatus = 'failed';
          }
          scene.error = 'Upload failed: $errorMsg';
        });
        print('[UPLOAD] ✗ $fileName: $errorMsg');
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Upload failed: $errorMsg'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } else {
        setState(() {
          if (frameType == 'first') {
            scene.firstFrameUploadStatus = 'failed';
          } else {
            scene.lastFrameUploadStatus = 'failed';
          }
        });
      }
    } catch (e) {
      print('[UPLOAD] ✗ $fileName: $e');
      setState(() {
        if (frameType == 'first') {
          scene.firstFrameUploadStatus = 'failed';
        } else {
          scene.lastFrameUploadStatus = 'failed';
        }
        scene.error = 'Upload error: $e';
      });
    }
  }

  void _clearImageForScene(SceneData scene, String frameType) {
    setState(() {
      if (frameType == 'first') {
        scene.firstFramePath = null;
        scene.firstFrameMediaId = null;
        scene.firstFrameUploadStatus = null;
      } else {
        scene.lastFramePath = null;
        scene.lastFrameMediaId = null;
        scene.lastFrameUploadStatus = null;
      }
    });
  }

  /// Show source picker dialog for mobile
  Future<List<String>?> _pickImagesWithSource() async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Show dialog to choose source
      final source = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Select Images From'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.blue),
                title: const Text('Gallery'),
                subtitle: const Text('Pick from photo gallery'),
                onTap: () => Navigator.pop(ctx, 'gallery'),
              ),
              ListTile(
                leading: const Icon(Icons.folder, color: Colors.orange),
                title: const Text('File Manager'),
                subtitle: const Text('Browse all files'),
                onTap: () => Navigator.pop(ctx, 'files'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (source == null) return null;

      if (source == 'gallery') {
        // Use image_picker for gallery - supports multi-pick
        final picker = ImagePicker();
        final images = await picker.pickMultiImage();
        if (images.isEmpty) return null;
        return images.map((img) => img.path).toList();
      } else {
        // Use file_picker for file manager
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: true,
        );
        if (result == null || result.files.isEmpty) return null;
        return result.files.where((f) => f.path != null).map((f) => f.path!).toList();
      }
    } else {
      // Desktop - use file_picker directly
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return null;
      return result.files.where((f) => f.path != null).map((f) => f.path!).toList();
    }
  }

  /// Import multiple first frame images - creates scenes and uploads immediately
  Future<void> _importBulkFirstFrames() async {
    final imagePaths = await _pickImagesWithSource();
    if (imagePaths == null || imagePaths.isEmpty) return;

    // Create/update scenes first
    setState(() {
      for (int i = 0; i < imagePaths.length; i++) {
        final filePath = imagePaths[i];

        if (i < scenes.length) {
          scenes[i].firstFramePath = filePath;
          scenes[i].firstFrameMediaId = null;
        } else {
          scenes.add(SceneData(
            sceneId: DateTime.now().millisecondsSinceEpoch + i,
            prompt: '',
            firstFramePath: filePath,
          ));
        }
      }
      // Auto-update range to include all scenes
      toIndex = scenes.length;
      _toIndexController.text = toIndex.toString();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported ${imagePaths.length} first frame(s). Uploading...')),
      );
    }

    // Start parallel upload
    await _uploadBulkImages('first');
    await _savePromptsToProject();
  }

  /// Import multiple last frame images - creates scenes and uploads immediately
  Future<void> _importBulkLastFrames() async {
    final imagePaths = await _pickImagesWithSource();
    if (imagePaths == null || imagePaths.isEmpty) return;

    setState(() {
      for (int i = 0; i < imagePaths.length; i++) {
        final filePath = imagePaths[i];

        if (i < scenes.length) {
          scenes[i].lastFramePath = filePath;
          scenes[i].lastFrameMediaId = null;
        } else {
          scenes.add(SceneData(
            sceneId: DateTime.now().millisecondsSinceEpoch + i,
            prompt: '',
            lastFramePath: filePath,
          ));
        }
      }
      // Auto-update range to include all scenes
      toIndex = scenes.length;
      _toIndexController.text = toIndex.toString();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported ${imagePaths.length} last frame(s). Uploading...')),
      );
    }

    // Start parallel upload
    await _uploadBulkImages('last');
    await _savePromptsToProject();
  }

  /// Upload all pending images in parallel using fast DIRECT-HTTP method
  /// With progress tracking and auto-retry (up to 2 times per image)
  Future<void> _uploadBulkImages(String frameType) async {
    // Get scenes that need upload
    final scenesToUpload = scenes.where((s) {
      if (frameType == 'first') {
        return s.firstFramePath != null && s.firstFrameMediaId == null;
      } else {
        return s.lastFramePath != null && s.lastFrameMediaId == null;
      }
    }).toList();

    if (scenesToUpload.isEmpty) return;

    // Initialize progress tracking
    setState(() {
      _isUploading = true;
      _uploadCurrent = 0;
      _uploadTotal = scenesToUpload.length;
      _uploadFrameType = frameType;
    });

    print('[UPLOAD] ========================================');
    print('[UPLOAD] METHOD: DIRECT-HTTP (Fast Parallel)');
    print('[UPLOAD] Starting bulk upload of ${scenesToUpload.length} ${frameType} frame(s)');
    print('[UPLOAD] Batch size: 3 images per batch');
    print('[UPLOAD] Auto-retry: Up to 2 attempts per image');
    print('[UPLOAD] ========================================');

    int uploaded = 0;
    int failed = 0;
    final errors = <String>[];

    // Get token from browser (only need token, not full CDP)
    String? uploadToken;

    if (Platform.isAndroid || Platform.isIOS) {
      final service = MobileBrowserService();
      final profile = service.getNextAvailableProfile();
      if (profile != null && profile.accessToken != null) {
        uploadToken = profile.accessToken;
      }
    } else {
      // Desktop: get fresh token
      print('[UPLOAD] Getting token from browser...');
      try {
        if (generator == null || !generator!.isConnected) {
          generator?.close();
          generator = BrowserVideoGenerator();
          await generator!.connect();
          accessToken = await generator!.getAccessToken();
        }
        uploadToken = accessToken;
        print('[UPLOAD] ✓ Token acquired');
      } catch (e) {
        print('[UPLOAD] ✗ Failed to get token: $e');
        
        // Try from profile manager as fallback
        if (_profileManager != null) {
          for (final profile in _profileManager!.profiles) {
            if (profile.status == ProfileStatus.connected && profile.accessToken != null) {
              uploadToken = profile.accessToken;
              print('[UPLOAD] Using token from profile: ${profile.name}');
              break;
            }
          }
        }
        
        if (uploadToken == null) {
          setState(() {
            _isUploading = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cannot upload: Failed to get token. $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      }
    }

    if (uploadToken == null) {
      setState(() {
        _isUploading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot upload: No access token. Please login first.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Upload in parallel batches of 3 with auto-retry
    const batchSize = 3;
    const maxRetries = 2;
    
    for (int batchStart = 0; batchStart < scenesToUpload.length; batchStart += batchSize) {
      final batchEnd = (batchStart + batchSize > scenesToUpload.length) 
          ? scenesToUpload.length 
          : batchStart + batchSize;
      final batch = scenesToUpload.sublist(batchStart, batchEnd);
      
      final batchNum = (batchStart ~/ batchSize) + 1;
      final totalBatches = (scenesToUpload.length / batchSize).ceil();
      print('[UPLOAD] Batch $batchNum/$totalBatches: Uploading ${batch.length} images in parallel...');

      // Set all batch scenes to uploading
      setState(() {
        for (final scene in batch) {
          if (frameType == 'first') {
            scene.firstFrameUploadStatus = 'uploading';
          } else {
            scene.lastFrameUploadStatus = 'uploading';
          }
        }
      });

      // Upload batch in parallel using DirectImageUploader with retry
      final futures = batch.map((scene) async {
        final imagePath = frameType == 'first' ? scene.firstFramePath! : scene.lastFramePath!;
        final fileName = imagePath.split(Platform.pathSeparator).last;

        // Try up to maxRetries times
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
          try {
            final result = await DirectImageUploader.uploadImage(
              imagePath: imagePath,
              accessToken: uploadToken!,
            );

            if (result is String) {
              // Success - got mediaId
              if (frameType == 'first') {
                scene.firstFrameMediaId = result;
                scene.firstFrameUploadStatus = 'uploaded';
              } else {
                scene.lastFrameMediaId = result;
                scene.lastFrameUploadStatus = 'uploaded';
              }
              scene.error = null;
              print('[UPLOAD] ✓ $fileName -> ${result.length > 20 ? result.substring(0, 20) : result}...');
              return true;
            } else if (result is Map && result['error'] == true) {
              final errorMsg = result['message'] ?? 'Unknown error';
              if (attempt < maxRetries) {
                print('[UPLOAD] ⚠ $fileName: $errorMsg (Retry ${attempt + 1}/$maxRetries)');
                await Future.delayed(const Duration(milliseconds: 500));
                continue;
              }
              errors.add('$fileName: $errorMsg');
              print('[UPLOAD] ✗ $fileName: $errorMsg (All retries failed)');
              if (frameType == 'first') {
                scene.firstFrameUploadStatus = 'failed';
              } else {
                scene.lastFrameUploadStatus = 'failed';
              }
              scene.error = 'Upload failed: $errorMsg';
              return false;
            } else {
              if (attempt < maxRetries) {
                print('[UPLOAD] ⚠ $fileName: null result (Retry ${attempt + 1}/$maxRetries)');
                await Future.delayed(const Duration(milliseconds: 500));
                continue;
              }
              errors.add('$fileName: Upload returned null');
              if (frameType == 'first') {
                scene.firstFrameUploadStatus = 'failed';
              } else {
                scene.lastFrameUploadStatus = 'failed';
              }
              return false;
            }
          } catch (e) {
            if (attempt < maxRetries) {
              print('[UPLOAD] ⚠ $fileName: $e (Retry ${attempt + 1}/$maxRetries)');
              await Future.delayed(const Duration(milliseconds: 500));
              continue;
            }
            errors.add('$fileName: $e');
            print('[UPLOAD] ✗ $fileName: $e (All retries failed)');
            if (frameType == 'first') {
              scene.firstFrameUploadStatus = 'failed';
            } else {
              scene.lastFrameUploadStatus = 'failed';
            }
            return false;
          }
        }
        return false;
      });

      // Wait for all batch uploads to complete
      final results = await Future.wait(futures);
      
      // Count results and update progress
      for (final success in results) {
        if (success) {
          uploaded++;
        } else {
          failed++;
        }
      }

      // Update progress
      setState(() {
        _uploadCurrent = batchEnd;
      });

      // Small delay between batches to avoid rate limiting
      if (batchEnd < scenesToUpload.length) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    // Upload complete
    setState(() {
      _isUploading = false;
    });

    print('[UPLOAD] ========================================');
    print('[UPLOAD] Complete: $uploaded uploaded, $failed failed');
    print('[UPLOAD] ========================================');

    // Show result
    if (mounted) {
      if (failed == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Uploaded $uploaded ${frameType} frame(s) successfully'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploaded: $uploaded, Failed: $failed. Check scene cards for errors.'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
        
        // Show detailed errors in dialog if any
        if (errors.isNotEmpty) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Upload Errors'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: errors.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('• $e', style: const TextStyle(fontSize: 12)),
                  )).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      }
    }

    print('[UPLOAD] Bulk upload complete. Success: $uploaded, Failed: $failed');
  }

  /// Get count of failed uploads
  int _getFailedUploadCount() {
    int count = 0;
    for (final scene in scenes) {
      if (scene.firstFramePath != null && scene.firstFrameUploadStatus == 'failed') {
        count++;
      }
      if (scene.lastFramePath != null && scene.lastFrameUploadStatus == 'failed') {
        count++;
      }
    }
    return count;
  }

  /// Retry all failed uploads
  Future<void> _retryFailedUploads() async {
    // Reset failed first frames
    for (final scene in scenes) {
      if (scene.firstFramePath != null && scene.firstFrameUploadStatus == 'failed') {
        scene.firstFrameUploadStatus = null;
        scene.firstFrameMediaId = null;
        scene.error = null;
      }
    }
    
    // Upload first frames
    await _uploadBulkImages('first');
    
    // Reset failed last frames
    for (final scene in scenes) {
      if (scene.lastFramePath != null && scene.lastFrameUploadStatus == 'failed') {
        scene.lastFrameUploadStatus = null;
        scene.lastFrameMediaId = null;
        scene.error = null;
      }
    }
    
    // Upload last frames
    await _uploadBulkImages('last');
    
    // Check remaining failures
    final remaining = _getFailedUploadCount();
    if (remaining > 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$remaining image(s) still failed. Check connection and retry.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ All images uploaded successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _runSingleGeneration(SceneData scene) async {
    if (!_checkActivation('Video Generation')) return;
    
    // Check for empty prompt - Veo3 API requires a text prompt even for I2V
    final hasImage = scene.firstFramePath != null || scene.lastFramePath != null;
    if (scene.prompt.trim().isEmpty) {
      if (hasImage) {
        // Use default prompt for I2V if no prompt provided
        scene.prompt = 'Animate this image with natural, fluid motion';
        print('[SINGLE] Using default I2V prompt: "${scene.prompt}"');
      } else {
        // No prompt and no image - can't generate
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please add a prompt or image to generate video'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
    }
    
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
       final service = MobileBrowserService();
       final profile = service.getNextAvailableProfile();
       
       if (profile != null) {
           mobileLog('[SINGLE] Manual trigger for scene ${scene.sceneId} using ${profile.name}');
           _mobileRunSingle(scene, profile);
       } else {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mobile: No ready browsers found. Check logs.')));
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

      // Get access token
      print('[SINGLE] Getting access token...');
      accessToken = await generator!.getAccessToken();
      if (accessToken == null) {
        throw Exception('Failed to get access token');
      }
      print('[SINGLE] ✓ Token acquired');

      // Upload images if needed
      String? startMediaId = scene.firstFrameMediaId;
      String? endMediaId = scene.lastFrameMediaId;
      
      if (scene.firstFramePath != null && startMediaId == null) {
        print('[SINGLE] Uploading first frame image...');
        final result = await generator!.uploadImage(scene.firstFramePath!, accessToken!);
        if (result is String) {
          startMediaId = result;
          scene.firstFrameMediaId = result;
          print('[SINGLE] ✓ First frame uploaded: $result');
        } else if (result is Map && result['error'] == true) {
          throw Exception('First frame upload failed: ${result['message']}');
        }
      }
      
      if (scene.lastFramePath != null && endMediaId == null) {
        print('[SINGLE] Uploading last frame image...');
        final result = await generator!.uploadImage(scene.lastFramePath!, accessToken!);
        if (result is String) {
          endMediaId = result;
          scene.lastFrameMediaId = result;
          print('[SINGLE] ✓ Last frame uploaded: $result');
        } else if (result is Map && result['error'] == true) {
          throw Exception('Last frame upload failed: ${result['message']}');
        }
      }

      // Get API model key
      final apiModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
      final mode = (startMediaId != null || endMediaId != null) ? 'I2V' : 'T2V';
      print('[SINGLE] Generating via Direct API ($mode)...');
      print('[SINGLE] Model: $apiModelKey');
      print('[SINGLE] Start Image MediaId: ${startMediaId ?? "null"}');
      print('[SINGLE] End Image MediaId: ${endMediaId ?? "null"}');
      print('[SINGLE] Scene has firstFramePath: ${scene.firstFramePath != null}');
      print('[SINGLE] Scene has firstFrameMediaId: ${scene.firstFrameMediaId != null}');
      
      // Generate video via Direct API
      final result = await generator!.generateVideo(
        prompt: scene.prompt,
        accessToken: accessToken!,
        aspectRatio: selectedAspectRatio,
        model: apiModelKey,
        startImageMediaId: startMediaId,
        endImageMediaId: endMediaId,
      );

      if (result == null || result['success'] != true) {
        final error = result?['error'] ?? 'Generation failed';
        throw Exception(error);
      }

      // Extract operation name
      final responseData = result['data'] as Map<String, dynamic>;
      final operations = responseData['operations'] as List?;
      if (operations == null || operations.isEmpty) {
        throw Exception('No operations in response');
      }
      
      final operationWrapper = operations[0] as Map<String, dynamic>;
      final operation = operationWrapper['operation'] as Map<String, dynamic>?;
      final operationName = operation?['name'] as String?;
      
      if (operationName == null) {
        throw Exception('No operation name');
      }
      
      scene.operationName = operationName;
      final sceneUuid = operationWrapper['sceneId'] as String? ?? operationName;
      
      setState(() { scene.status = 'polling'; });
      print('[SINGLE] ✓ Generation started, polling...');
      
      // Poll for completion
      await _pollAndDownloadSingle(scene, sceneUuid);

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
    int pollErrors = 0;
    const maxPollErrors = 5;
    
    while (scene.status == 'polling') {
      try {
        final operationData = await generator!.pollVideoStatus(
          scene.operationName!,
          sceneUuid,
          accessToken!,
        );

        // Reset error counter on successful poll
        pollErrors = 0;

        if (operationData != null) {
          final status = operationData['status'] as String?;
          
          print('[SINGLE] Poll status: $status');

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            String? videoUrl;
            String? videoMediaId;
            if (operationData.containsKey('operation')) {
              final metadata = (operationData['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
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
              print('[SINGLE] Scene ${scene.sceneId} READY -> Downloading...');
              if (videoMediaId != null) {
                print('[SINGLE] Video MediaId: $videoMediaId (saved for upscaling)');
              }
              setState(() {
                scene.status = 'downloading';
              });

              final outputPath = await widget.projectService.getVideoOutputPath(null, scene.sceneId);
              final fileSize = await generator!.downloadVideo(videoUrl, outputPath);

              setState(() {
                scene.videoPath = outputPath;
                scene.downloadUrl = videoUrl;
                scene.videoMediaId = videoMediaId; // Store for upscaling
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
            // Extract actual error message from server response
            String errorMsg = 'Generation failed on server';
            
            // Try to get error from operation.error or operation.metadata.error
            if (operationData.containsKey('operation')) {
              final op = operationData['operation'] as Map<String, dynamic>;
              if (op.containsKey('error')) {
                final error = op['error'];
                if (error is Map) {
                  errorMsg = error['message'] ?? error['code'] ?? jsonEncode(error);
                } else {
                  errorMsg = error.toString();
                }
              } else if (op.containsKey('metadata')) {
                final metadata = op['metadata'] as Map<String, dynamic>?;
                if (metadata?.containsKey('error') == true) {
                  errorMsg = metadata!['error'].toString();
                } else if (metadata?.containsKey('failureReason') == true) {
                  errorMsg = metadata!['failureReason'].toString();
                }
              }
            }
            
            // Also check top-level error
            if (operationData.containsKey('error')) {
              errorMsg = operationData['error'].toString();
            }
            
            print('[SINGLE] ✗ Server Error: $errorMsg');
            print('[SINGLE] Full Response: ${jsonEncode(operationData)}');
            
            throw Exception('Server: $errorMsg');
          }
        }

        await Future.delayed(const Duration(seconds: 10));
      } catch (e) {
        pollErrors++;
        final errorStr = e.toString();
        
        // Determine error type for better messaging
        String errorType = 'Unknown';
        if (errorStr.contains('timeout') || errorStr.contains('Timeout')) {
          errorType = 'Timeout';
        } else if (errorStr.contains('connection') || errorStr.contains('Connection')) {
          errorType = 'Connection';
        } else if (errorStr.contains('Server:')) {
          errorType = 'Server';
        }
        
        print('[SINGLE] ✗ Poll error ($pollErrors/$maxPollErrors): [$errorType] $errorStr');
        
        if (errorType == 'Server' || pollErrors >= maxPollErrors) {
          // Server errors or max retries - fail immediately
          setState(() {
            scene.status = 'failed';
            scene.error = errorStr;
          });
          print('[SINGLE] ✗ Failed after $pollErrors poll attempts');
          break;
        } else {
          // Transient error - retry after delay
          print('[SINGLE] Retrying poll in 5s...');
          setState(() {
            scene.error = 'Poll retry $pollErrors/$maxPollErrors: $errorType';
          });
          await Future.delayed(const Duration(seconds: 5));
        }
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
            String? videoMediaId;
            if (operationData.containsKey('operation')) {
              final metadata = (operationData['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
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
              setState(() {
                scene.status = 'downloading';
              });

              print('[QUICK] Downloading video...');
              if (videoMediaId != null) {
                print('[QUICK] Video MediaId: $videoMediaId (saved for upscaling)');
              }
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
                scene.videoMediaId = videoMediaId; // Store for upscaling
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
    } else {
      // Desktop: Use internal video player
      VideoPlayerDialog.show(
        context, 
        scene.videoPath!,
        title: 'Scene ${scene.sceneId}',
      );
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
      // Use /select, to highlight the specific file in Explorer
      Process.run('explorer', ['/select,', scene.videoPath!]);
    } else if (Platform.isMacOS) {
      // Use -R to reveal and highlight file in Finder
      Process.run('open', ['-R', scene.videoPath!]);
    } else if (Platform.isLinux) {
      final folder = path.dirname(scene.videoPath!);
      Process.run('xdg-open', [folder]);
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
            profile.consecutive403Count = 0; // Reset 403 count on successful login
            profile.isReloginInProgress = false;
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

  /// Stop login process (Mobile only)
  void _handleStopLogin() {
    print('[UI] Stop Login requested');
    _mobileService?.stopLogin();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Stopping login process...')),
    );
  }

  /// Handle login all profiles (multi-profile with automated login)
  Future<void> _handleLoginAll(int count, String email, String password) async {
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
       print('[UI] Mobile Login All initiated for $count profiles');
       
       // Use state variable so we can stop it
       _mobileService = MobileBrowserService();
       _mobileService!.initialize(count);
       
       final dynamic state = _mobileBrowserManagerKey.currentState;
       state?.show();
       
       await Future.delayed(const Duration(seconds: 1));
       
       // CLEAR EVERYTHING FIRST (Global Logout)
       print('[UI] Clearing global session data...');
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cleaning sessions...')));

       // Clear global cookies/storage once
       await CookieManager.instance().deleteAllCookies();
       // Also clear storage via first available generator if possible (to catch LocalStorage)
       final p0 = _mobileService!.getProfile(0);
       if (p0 != null && p0.generator != null) {
          await p0.generator?.clearLocalStorageOnly(); 
       }
       
       // Reset all statuses
       for (int i = 0; i < count; i++) {
         final p = _mobileService!.getProfile(i);
         if (p != null) {
           p.accessToken = null;
           p.status = MobileProfileStatus.loading; // Show loading while we prep
         }
       }
       setState(() {});

       await Future.delayed(const Duration(seconds: 1));

       print('[UI] Clean complete. Starting fresh login sequence.');
       
       int successCount = 0;
       
       // Login FIRST browser ONLY to establish session
       // Use local ref for safety in loop, but it's the same object
       final service = _mobileService!; 

       final firstProfile = service.getProfile(0);
       if (firstProfile != null && firstProfile.generator != null) {
          print('[UI] ========== Logging in FIRST browser (Master) ==========');
          firstProfile.status = MobileProfileStatus.loading;
          setState(() {});
          
          // Perform full login flow
          final success = await firstProfile.generator!.autoLogin(email, password);
          
          if (success) {
            // Verify token on master
            final token = await firstProfile.generator!.getAccessToken(); // Retries allowed here
            if (token != null && token.isNotEmpty) {
              firstProfile.accessToken = token;
              firstProfile.status = MobileProfileStatus.ready;
              firstProfile.consecutive403Count = 0; // Reset 403 count
              firstProfile.isReloginInProgress = false;
              successCount++;
              print('[UI] ✓ Master browser ready. Propagating session...');
              
              // WAITING before other browsers to let session settle and avoid 429
              print('[UI] Waiting 5s for session to settle...');
              await Future.delayed(const Duration(seconds: 5));

              // Now for OTHER browsers: Load Flow URL (session is shared via cookies)
              for (int i = 1; i < count; i++) {
                final profile = service.getProfile(i);
                if (profile == null) {
                  print('[UI] Browser ${i + 1}: Profile not found');
                  continue;
                }
                
                // Wait for WebView to be created if needed
                int waitAttempts = 0;
                while (profile.controller == null && waitAttempts < 10) {
                  print('[UI] Browser ${i + 1}: Waiting for WebView to initialize...');
                  await Future.delayed(const Duration(seconds: 1));
                  waitAttempts++;
                }
                
                if (profile.controller == null) {
                  print('[UI] Browser ${i + 1}: WebView not initialized, skipping');
                  continue;
                }
                
                // Stagger to avoid resource spike
                await Future.delayed(const Duration(seconds: 2));
                
                print('[UI] Browser ${i + 1}: Loading Flow URL (shared session)...');
                profile.status = MobileProfileStatus.loading;
                setState(() {});
                
                try {
                  // Just load flow page - cookies are shared, so it should be logged in
                  await profile.controller!.loadUrl(
                    urlRequest: URLRequest(url: WebUri('https://labs.google/fx/tools/flow'))
                  );
                  
                  // Wait for page to load
                  await Future.delayed(const Duration(seconds: 5));
                  
                  // Check for token
                  final browserToken = await profile.generator?.getAccessTokenQuick();
                  
                  if (browserToken != null && browserToken.isNotEmpty) {
                     profile.accessToken = browserToken;
                     profile.status = MobileProfileStatus.ready;
                     profile.consecutive403Count = 0; // Reset 403 count
                     profile.isReloginInProgress = false;
                     successCount++;
                     print('[UI] ✓ Browser ${i + 1} connected via shared session');
                  } else {
                     // Session cookies should still work, mark as connected
                     profile.status = MobileProfileStatus.connected; 
                     print('[UI] ~ Browser ${i + 1} loaded (token pending, session shared)');
                  }
                  setState(() {});
                } catch (e) {
                  print('[UI] Error on Browser ${i + 1}: $e');
                }
              }
            } else {
               firstProfile.status = MobileProfileStatus.connected;
               print('[UI] ✗ First browser login success but no token?');
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
           const SnackBar(content: Text('✗ Login failed or stopped')),
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
       _mobileService = MobileBrowserService();
       _mobileService!.initialize(count);
       final service = _mobileService!;
       
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
                  profile.consecutive403Count = 0; // Reset 403 count
                  profile.isReloginInProgress = false;
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
  final DateTime startTime;

  _PendingPoll(this.scene, this.sceneUuid, this.startTime);
}

/// Helper class for upscale poll tracking
class _UpscalePoll {
  final SceneData scene;
  final String operationName;
  final String sceneUuid;

  _UpscalePoll(this.scene, this.operationName, this.sceneUuid);
}

/// Exception that can be retried on a different browser
class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);
  
  @override
  String toString() => message;
}
