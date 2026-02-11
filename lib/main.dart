import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'models/scene_data.dart';
import 'models/project_data.dart';
import 'models/poll_request.dart';
import 'services/video_generation_service.dart';
import 'services/project_service.dart';
import 'services/settings_service.dart';
import 'services/profile_manager_service.dart';
import 'services/multi_profile_login_service.dart';
import 'utils/prompt_parser.dart';
import 'utils/config.dart';
import 'utils/ffmpeg_utils.dart'; // Added import
import 'utils/video_export_helper.dart';
import 'services/story/story_export_service.dart';
import 'widgets/scene_card.dart';
import 'services/log_service.dart';
import 'widgets/profile_manager_widget.dart';
import 'widgets/queue_controls.dart';
import 'package:window_manager/window_manager.dart';
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
import 'screens/settings_screen.dart';
import 'screens/ai_voice_screen.dart';
import 'screens/templates_screen.dart';
import 'screens/clone_youtube_screen.dart';
import 'services/settings_service.dart';
import 'package:media_kit/media_kit.dart';
import 'services/direct_image_uploader.dart';
import 'services/operation_storage_service.dart';
import 'widgets/app_loading_screen.dart';
import 'widgets/license_guard.dart';
import 'services/update_service.dart';
import 'widgets/update_dialog.dart';
import 'widgets/update_notifier.dart';
import 'services/gemini_key_service.dart';
import 'widgets/gemini_keys_dialog.dart';
import 'widgets/log_viewer_widget.dart';
import 'utils/app_logger.dart';

void main(List<String> args) async {
  // Capture ALL print output and route to LogService
  runZoned(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      
      // Initialize MediaKit for desktop video playback
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        MediaKit.ensureInitialized();
      }
      
      print('[Main] Args received: $args');
      
      // Check for mastering mode via command line OR temp file flag
      bool isMasteringMode = args.contains('--mastering');
      String? dataFilePath;
      
      // Also check for file-based mastering flag (more reliable on Windows)
      final masteringFlagFile = File(path.join(Directory.systemTemp.path, 'veo3_mastering_mode.flag'));
      if (await masteringFlagFile.exists()) {
        print('[Main] Found mastering flag file');
        isMasteringMode = true;
        
        // Read data file path from flag file
        try {
          dataFilePath = await masteringFlagFile.readAsString();
          dataFilePath = dataFilePath.trim();
          if (dataFilePath.isEmpty) dataFilePath = null;
        } catch (_) {}
        
        // Delete the flag file
        await masteringFlagFile.delete();
        print('[Main] Data file from flag: $dataFilePath');
      }
      
      // Also check command line for data path
      if (dataFilePath == null) {
        for (int i = 0; i < args.length; i++) {
          if (args[i] == '--data' && i + 1 < args.length) {
            dataFilePath = args[i + 1];
            break;
          }
        }
      }
      
      // Check for logs mode via command line OR temp file flag
      bool isLogsMode = args.contains('--logs');
      print('[Main] Checking logs mode - args contains --logs: $isLogsMode');
      
      final logsFlagFile = File(path.join(Directory.systemTemp.path, 'veo3_logs_mode.flag'));
      print('[Main] Checking for logs flag file: ${logsFlagFile.path}');
      print('[Main] Logs flag file exists: ${await logsFlagFile.exists()}');
      
      if (await logsFlagFile.exists()) {
        print('[Main] Found logs flag file - enabling logs mode');
        isLogsMode = true;
        try {
          await logsFlagFile.delete();
          print('[Main] Deleted logs flag file');
        } catch (e) {
          print('[Main] Error deleting logs flag file: $e');
        }
      }
      
      print('[Main] isMasteringMode: $isMasteringMode, isLogsMode: $isLogsMode');
      
      if (isMasteringMode) {
        print('[Main] Starting Mastering-only mode');
        runApp(MasteringOnlyApp(dataFilePath: dataFilePath));
      } else if (isLogsMode) {
        print('[Main] Starting Logs-only mode');
        runApp(const LogsOnlyApp());
      } else {
        print('[Main] Starting normal app mode');
        runApp(const BulkVideoGeneratorApp());
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        // Call original print
        parent.print(zone, line);
        // Also add to LogService for in-app display
        LogService().add(line, type: _detectLogType(line));
      },
    ),
  );
}

/// Detect log type from message content for color coding
String _detectLogType(String message) {
  final upper = message.toUpperCase();
  if (upper.contains('ERROR') || upper.contains('FAILED') || upper.contains('✗')) return 'ERROR';
  if (upper.contains('[PRODUCER]') || upper.contains('[POLLER]')) return 'GEN';
  if (upper.contains('[NORMAL MODE]')) return 'NORMAL';
  if (upper.contains('[GENERATE]') || upper.contains('[VGEN]')) return 'VGEN';
  if (upper.contains('[PROFILEMANAGER]') || upper.contains('[PROFILE]')) return 'PROFILE';
  if (upper.contains('403') || upper.contains('429') || upper.contains('HTTP')) return 'NET';
  if (upper.contains('[MOBILE]')) return 'MOBILE';
  if (upper.contains('✓') || upper.contains('✅')) return 'SUCCESS';
  return 'INFO';
}

/// Standalone Mastering App - runs as separate process (NO license check, NO loading animation)
class MasteringOnlyApp extends StatelessWidget {
  final String? dataFilePath;
  
  const MasteringOnlyApp({super.key, this.dataFilePath});
  
  @override
  Widget build(BuildContext context) {
    print('[Mastering] MasteringOnlyApp build, dataFile: $dataFilePath');
    return MaterialApp(
      title: 'VEO3 Infinity - Mastering',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(),
      ),
      home: _MasteringLoader(dataFilePath: dataFilePath),
    );
  }
}

class _MasteringLoader extends StatefulWidget {
  final String? dataFilePath;
  
  const _MasteringLoader({this.dataFilePath});
  
  @override
  State<_MasteringLoader> createState() => _MasteringLoaderState();
}

class _MasteringLoaderState extends State<_MasteringLoader> {
  List<String>? _videoPaths;
  String? _projectName;
  List<Map<String, dynamic>>? _bgMusicPrompts;
  bool _loading = true;
  String? _error;
  
  // Marker file to indicate mastering is running
  late File _runningMarkerFile;
  
  @override
  void initState() {
    super.initState();
    print('[Mastering] _MasteringLoader initState');
    
    // Create marker file to indicate mastering is running
    _runningMarkerFile = File(path.join(Directory.systemTemp.path, 'veo3_mastering_running.marker'));
    _runningMarkerFile.writeAsStringSync(DateTime.now().toIso8601String());
    print('[Mastering] Created running marker: ${_runningMarkerFile.path}');
    
    _loadData();
  }
  
  @override
  void dispose() {
    // Delete marker file when mastering closes
    try {
      if (_runningMarkerFile.existsSync()) {
        _runningMarkerFile.deleteSync();
        print('[Mastering] Deleted running marker');
      }
    } catch (e) {
      print('[Mastering] Error deleting marker: $e');
    }
    super.dispose();
  }
  
  Future<void> _loadData() async {
    try {
      print('[Mastering] Loading data...');
      // Load settings for API keys etc
      await SettingsService.instance.load();
      
      if (widget.dataFilePath != null) {
        print('[Mastering] Reading data file: ${widget.dataFilePath}');
        final file = File(widget.dataFilePath!);
        if (await file.exists()) {
          final content = await file.readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          
          _videoPaths = (data['videoPaths'] as List?)?.cast<String>();
          _projectName = data['projectName'] as String?;
          _bgMusicPrompts = (data['bgMusicPrompts'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          
          print('[Mastering] Loaded ${_videoPaths?.length ?? 0} videos');
          
          // Clean up temp file
          await file.delete();
        }
      }
      
      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      print('[Mastering] Error loading data: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // Simple dark loading - doesn't look like main app
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
              const SizedBox(height: 16),
              Text(
                'Opening Mastering...',
                style: GoogleFonts.inter(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    
    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        body: Center(
          child: Text('Error: $_error', style: const TextStyle(color: Colors.red)),
        ),
      );
    }
    
    return VideoMasteringScreen(
      projectService: ProjectService(),
      isActivated: true,
      embedded: false,
      initialVideoPaths: _videoPaths,
      initialProjectName: _projectName ?? 'Mastering Project',
      bgMusicPrompts: _bgMusicPrompts,
    );
  }
}

/// Standalone Logs Viewer App - runs as separate process
class LogsOnlyApp extends StatelessWidget {
  const LogsOnlyApp({super.key});
  
  @override
  Widget build(BuildContext context) {
    print('[Logs] LogsOnlyApp build');
    return MaterialApp(
      title: 'VEO3 Infinity - Application Logs',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green, brightness: Brightness.dark),
        useMaterial3: true,
        textTheme: GoogleFonts.jetBrainsMonoTextTheme(),
      ),
      home: const _LogsViewer(),
    );
  }
}

class _LogsViewer extends StatefulWidget {
  const _LogsViewer();
  
  @override
  State<_LogsViewer> createState() => _LogsViewerState();
}

class _LogsViewerState extends State<_LogsViewer> {
  final LogService _logService = LogService();
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  bool _alwaysOnTop = true;
  
  @override
  void initState() {
    super.initState();
    
    // Configure window size and properties
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          await windowManager.ensureInitialized();
          
          // Set window size and position
          await windowManager.setSize(const Size(1000, 600));
          await windowManager.center();
          await windowManager.setTitle('VEO3 Infinity - Application Logs');
          await windowManager.setResizable(true);
          await windowManager.setMinimumSize(const Size(600, 400));
          await windowManager.setAlwaysOnTop(_alwaysOnTop);
          
          print('[Logs] Window configured: 1000x600, centered, always-on-top: $_alwaysOnTop');
        }
      } catch (e) {
        print('[Logs] Could not configure window: $e');
      }
    });
    
    // Start watching the shared log file for updates from main app
    _logService.startWatchingFile();
    print('[Logs] Started watching log file');
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    _logService.stopWatchingFile();
    super.dispose();
  }
  
  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: [
            Icon(Icons.terminal, size: 20, color: Colors.green.shade400),
            const SizedBox(width: 8),
            Text(
              'VEO3 Infinity - Application Logs',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          // Auto-scroll toggle
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.arrow_downward : Icons.pause,
              color: _autoScroll ? Colors.green.shade400 : Colors.grey.shade400,
            ),
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
            onPressed: () {
              setState(() => _autoScroll = !_autoScroll);
            },
          ),
          // Always on top toggle
          IconButton(
            icon: Icon(
              _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
              color: _alwaysOnTop ? Colors.amber.shade400 : Colors.grey.shade400,
            ),
            tooltip: _alwaysOnTop ? 'Always on top ON' : 'Always on top OFF',
            onPressed: () async {
              setState(() => _alwaysOnTop = !_alwaysOnTop);
              
              // Actually set window always on top
              try {
                await windowManager.setAlwaysOnTop(_alwaysOnTop);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(_alwaysOnTop ? 'Window is now always on top' : 'Window no longer always on top'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              } catch (e) {
                print('[Logs] Error setting always on top: $e');
              }
            },
          ),
          // Clear logs button
          IconButton(
            icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
            tooltip: 'Clear logs',
            onPressed: () {
              _logService.clear();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs cleared'), duration: Duration(seconds: 1)),
              );
            },
          ),
          // Copy all logs button
          IconButton(
            icon: Icon(Icons.copy, color: Colors.blue.shade400),
            tooltip: 'Copy all logs',
            onPressed: () {
              final allLogs = _logService.logs.map((e) => e.toString()).join('\n');
              Clipboard.setData(ClipboardData(text: allLogs));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied to clipboard'), duration: Duration(seconds: 1)),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<LogEntry>>(
        stream: _logService.stream,
        initialData: _logService.logs,
        builder: (context, snapshot) {
          final logs = snapshot.data ?? [];
          
          // Auto-scroll when new logs arrive
          if (_autoScroll && logs.isNotEmpty) {
            _scrollToBottom();
          }
          
          if (logs.isEmpty) {
            return Center(
              child: Text(
                'No logs yet... Waiting for main app...',
                style: GoogleFonts.jetBrainsMono(
                  color: Colors.grey.shade600,
                  fontSize: 14,
                ),
              ),
            );
          }
          
          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final log = logs[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: SelectableText.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '[${log.type}] ',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _getLogColor(log.type),
                        ),
                      ),
                      TextSpan(
                        text: log.message,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          color: Colors.grey.shade300,
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
    );
  }
  
  Color _getLogColor(String type) {
    switch (type.toUpperCase()) {
      case 'ERROR':
        return Colors.red.shade300;
      case 'NET':
      case 'NETWORK':
        return Colors.blue.shade300;
      case 'MOBILE':
        return Colors.purple.shade300;
      case 'NORMAL':
      case 'NORMAL MODE':
        return Colors.green.shade300;
      case 'GEN':
      case 'PRODUCER':
      case 'POLLER':
        return Colors.orange.shade300;
      case 'VGEN':
      case 'GENERATE':
        return Colors.cyan.shade300;
      case 'PROFILE':
        return Colors.amber.shade300;
      case 'SUCCESS':
        return Colors.greenAccent.shade200;
      default:
        return Colors.grey.shade400;
    }
  }
}


class BulkVideoGeneratorApp extends StatefulWidget {
  const BulkVideoGeneratorApp({super.key});

  @override
  State<BulkVideoGeneratorApp> createState() => _BulkVideoGeneratorAppState();
}

class _BulkVideoGeneratorAppState extends State<BulkVideoGeneratorApp> {
  Project? _currentProject;
  final ProjectService _projectService = ProjectService();
  
  // App loading state
  bool _isAppLoading = true;
  
  // Update checker - MUST be singleton to work with UpdateAwareBuilder
  final UpdateNotifier _updateNotifier = UpdateNotifier();
  bool _updateAvailable = false;

  @override
  void initState() {
    super.initState();
    // Load settings (gemini keys, profiles, accounts) early so other services can use them
    SettingsService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    _initializeUpdateChecker();
  }
  
  Future<void> _initializeUpdateChecker() async {
    final updateService = UpdateService.instance;
    
    AppLogger.i('[UPDATE] Initializing update checker...');
    
    // Set up callback for when update is available
    updateService.onUpdateAvailable = (updateInfo) {
      AppLogger.i('[UPDATE] Update available! Latest: ${updateInfo.latestVersion}, Current: ${updateInfo.currentVersion}');
      _updateNotifier.setUpdateAvailable(updateInfo);
      
      if (mounted) {
        setState(() {
          _updateAvailable = true;
        });
        
        // Show update dialog on startup
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isAppLoading) {
            AppLogger.i('[UPDATE] Showing update dialog...');
            UpdateDialog.show(context, updateInfo);
          }
        });
      }
    };
    
    // Initialize and check for updates
    await updateService.initialize();
    AppLogger.i('[UPDATE] Update service initialized. Update available: ${updateService.updateAvailable}');
    
    // Check immediately if update is available (in case it was cached)
    if (updateService.updateAvailable && updateService.updateInfo != null) {
      AppLogger.i('[UPDATE] Update found in cache: ${updateService.updateInfo}');
      _updateNotifier.setUpdateAvailable(updateService.updateInfo!);
      setState(() {
        _updateAvailable = true;
      });
    }
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
  
  void _onLoadingComplete() {
    setState(() {
      _isAppLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VEO3 Infinity',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(),
        fontFamily: GoogleFonts.inter().fontFamily,
      ),
      // Wrap with LicenseGuard to enforce licensing
      home: LicenseGuard(
        enableLicensing: true, // Set to true for production, false to bypass
        child: _isAppLoading
            ? AppLoadingScreen(onComplete: _onLoadingComplete)
            : (_currentProject == null
                ? ProjectSelectionScreen(
                    onProjectSelected: _onProjectSelected,
                    isActivated: true, // Always true now - LicenseGuard handles it
                    isCheckingLicense: false,
                    licenseError: '',
                    deviceId: '',
                    onRetryLicense: () {}, // No longer needed
                  )
                : BulkVideoGeneratorPage(
                    project: _currentProject!,
                    projectService: _projectService,
                    onChangeProject: _changeProject,
                    isActivated: true, // Always true now - LicenseGuard handles it
                    licenseError: '',
                    deviceId: '',
                    onRetryLicense: () {}, // No longer needed
                    updateAvailable: _updateAvailable,
                    updateNotifier: _updateNotifier,
                  )),
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
  final bool updateAvailable;
  final UpdateNotifier updateNotifier;
  
  const BulkVideoGeneratorPage({
    super.key,
    required this.project,
    required this.projectService,
    required this.onChangeProject,
    required this.isActivated,
    required this.licenseError,
    required this.deviceId,
    required this.onRetryLicense,
    this.updateAvailable = false,
    required this.updateNotifier,
  });

  @override
  State<BulkVideoGeneratorPage> createState() => _BulkVideoGeneratorPageState();
}

class _BulkVideoGeneratorPageState extends State<BulkVideoGeneratorPage> with TickerProviderStateMixin {
  List<SceneData> scenes = [];
  ProjectManager? projectManager;
  late String outputFolder;
  
  // Mobile tab controller
  late TabController _mobileTabController;
  
  // Multi-profile services
  ProfileManagerService? _profileManager;
  MultiProfileLoginService? _loginService;
  
  // Project service for creating/loading projects
  final ProjectService _projectService = ProjectService();
  
  bool isRunning = false;
  bool isPaused = false;
  bool use10xBoostMode = false; // Default to Normal Mode (sequential, more stable)
  bool showLogViewer = false; // Toggle for log viewer window
  bool isUpscaling = false; // Track bulk upscale state
  bool _isControlPanelExpanded = true; // Track control panel collapse state
  int _currentNavIndex = 0; // Track current navigation tab
  bool _isPageLoading = false; // Track page loading state
  bool _showNavBarOnMastering = false; // Show nav bar on hover in mastering screen
  bool _isMasteringLaunching = false; // Track if mastering is currently launching
  bool _isMasteringOpen = false; // Track if mastering window is already open
  String _appVersion = ''; // App version from pubspec.yaml
  
  // Mastering tab state - clips and prompts passed from SceneBuilder
  List<Map<String, dynamic>>? _masteringInitialClips;
  String? _masteringBgMusicPrompt;
  Map<String, dynamic>? _masteringFullProjectJson;
  
  int currentIndex = 0;
  double rateLimit = 1.0;
  String? accessToken;
  DesktopGenerator? generator;
  
  String selectedProfile = 'Default';
  List<String> profiles = ['Default'];
  String selectedModel = 'Veo 3.1 - Fast [Lower Priority]'; // Default to lower priority for stability
  String selectedAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE';
  String selectedAccountType = 'ai_ultra'; // 'free', 'ai_pro', 'ai_ultra'
  int selectedOutputCount = 1; // Outputs per prompt (1, 2, or 4)
  int fromIndex = 1;
  int toIndex = 999;
  
  // Concurrent generation settings (user configurable)
  int maxConcurrentRelaxed = 4;  // Default for relaxed/lower priority models
  int maxConcurrentFast = 4;     // Default for fast models (4 per browser recommended)
  
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
  bool _is429Cooldown = false;
  DateTime? _cooldownEndTime;
  
  // Quick Generate state
  final TextEditingController _quickPromptController = TextEditingController();
  final TextEditingController _fromIndexController = TextEditingController();
  final TextEditingController _toIndexController = TextEditingController();
  bool _isQuickGenerating = false;
  SceneData? _quickGeneratedScene;
  bool _isQuickInputCollapsed = false;
  bool _isControlsCollapsed = false;
  
  // Account Management (for mobile Settings tab)
  final TextEditingController _accountEmailController = TextEditingController();
  final TextEditingController _accountPasswordController = TextEditingController();
  int _selectedSettingsTab = 2; // Default to Accounts tab (0=API, 1=Browsers, 2=Accounts)
  
  // Mobile Browser Service for embedded InAppWebView login (NOT external Chrome)
  final MobileBrowserService _mobileBrowserService = MobileBrowserService();
  
  // Story Audio screen state (using callback approach instead of Navigator)
  bool _showStoryAudioScreen = false;
  int _storyAudioTabIndex = 0;
  
  // Reel Special dedicated screen state
  bool _showReelSpecialScreen = false;
  
  // Settings screen state (inline display like other tabs)
  bool _showSettingsScreen = false;
  
  // Mobile: Thumbnails toggle for RAM saving
  bool _showVideoThumbnails = true;
  
  // Track if we're showing mobile layout (can be true on PC when window is narrow)
  bool _isShowingMobileLayout = false;
  
  // Mobile Service Instance (for stopping login)
  MobileBrowserService? _mobileService;
  
  // Video generation service status subscription
  StreamSubscription<String>? _generationStatusSubscription;
  
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
    
    // Mobile tab controller (3 tabs: Queue, Browser, Settings)
    _mobileTabController = TabController(length: 3, vsync: this);
    
    // Chain async initialization properly
    _initializeApp();
    
    // Initialize From/To controllers
    _fromIndexController.text = fromIndex.toString();
    _toIndexController.text = toIndex.toString();
    
    // Unified Video Generator Listener - Update UI when generation status changes
    _generationStatusSubscription = VideoGenerationService().statusStream.listen((event) {
      if (mounted) {
        // Trigger rebuild when status updates (generating, polling, downloading, completed, failed)
        setState(() {});
      }
    });

    // Auto-refresh scene cards for live status updates
    _sceneRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
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
    await _loadAppVersion();
    
    // Initialize operation storage for recovery
    await OperationStorageService().init();
    
    // Initialize multi-profile services (now that paths are correct)
    _profileManager = ProfileManagerService(
      profilesDirectory: AppConfig.profilesDir,
      baseDebugPort: AppConfig.debugPort,
    );
    _loginService = MultiProfileLoginService(profileManager: _profileManager!);
    
    // Unified Video Generator initialization
    // Get first Google account credentials for mobile auto-login
    final accounts = SettingsService.instance.getGoogleAccounts();
    final firstAccount = accounts.isNotEmpty ? accounts.first : null;
    
    print('[MAIN] 🔐 Retrieved ${accounts.length} Google accounts from settings');
    if (firstAccount != null) {
      final email = firstAccount['email'] ?? firstAccount['username'];
      final password = firstAccount['password'];
      print('[MAIN] 🔑 Using account: $email (password: ${password != null ? "***set***" : "NULL"})');
    } else {
      print('[MAIN] ⚠️ No Google accounts found in settings - auto-login will not work!');
    }
    
    VideoGenerationService().initialize(
      profileManager: _profileManager,
      mobileService: _mobileBrowserService,
      loginService: _loginService,
      accountType: selectedAccountType,
      email: firstAccount?['email'] ?? firstAccount?['username'],
      password: firstAccount?['password'],
    );
    
    // Load SettingsService for mobile settings tab
    await SettingsService.instance.load();
  }

  @override
  void dispose() {
    autoSaveTimer?.cancel();
    _sceneRefreshTimer?.cancel();
    _generationStatusSubscription?.cancel(); // Clean up generation status listener
    generator?.close();
    _scrollController.dispose();
    _quickPromptController.dispose();
    _fromIndexController.dispose();
    _toIndexController.dispose();
    
    // Clean up profile manager if available
    _profileManager = null;
    
    super.dispose();
    
    // Force exit on desktop to prevent zombie process
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      Future.delayed(const Duration(milliseconds: 500), () {
        exit(0);
      });
    }
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
      AppLogger.i('[Storage] Created output folder: $outputFolder');
    }
    
    // Create profiles directory
    final profilesDir = Directory(AppConfig.profilesDir);
    if (!await profilesDir.exists()) {
      await profilesDir.create(recursive: true);
      AppLogger.i('[Storage] Created profiles folder: ${AppConfig.profilesDir}');
    }
  }
  
  Future<void> _requestStoragePermissions() async {
    if (!Platform.isAndroid) return;
    
    AppLogger.i('[Permission] Requesting storage permissions...');
    
    // Request basic storage permission (Android 10 and below)
    final storageStatus = await Permission.storage.request();
    AppLogger.i('[Permission] Storage: $storageStatus');
    
    // Request media permissions (Android 13+)
    final photosStatus = await Permission.photos.request();
    AppLogger.i('[Permission] Photos: $photosStatus');
    
    final videosStatus = await Permission.videos.request();
    AppLogger.i('[Permission] Videos: $videosStatus');
    
    // For Android 11+, request MANAGE_EXTERNAL_STORAGE
    final manageStatus = await Permission.manageExternalStorage.status;
    AppLogger.i('[Permission] Manage External Storage status: $manageStatus');
    
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
          AppLogger.i('[Permission] Manage External Storage after request: $status');
          
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
        AppLogger.i('[PROJECT] Loaded ${scenes.length} scenes from project');
        
        // Count stats
        final completed = scenes.where((s) => s.status == 'completed').length;
        final failed = scenes.where((s) => s.status == 'failed').length;
        final pending = scenes.where((s) => s.status == 'queued').length;
        final polling = scenes.where((s) => s.status == 'polling').length;
        AppLogger.i('[PROJECT] Stats: $completed completed, $failed failed, $pending pending, $polling polling');
        
        // Check for scenes that were polling when app was closed
        if (polling > 0) {
          AppLogger.i('[PROJECT] Found $polling scenes in polling state - ready for resume');
        }
      }
    } catch (e) {
      AppLogger.e('Error loading project data: $e');
    }
  }
  
  /// Load app version from package_info_plus
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() {
        _appVersion = info.version;
      });
      AppLogger.i('[APP] Version: ${info.version}+${info.buildNumber}');
    } catch (e) {
      AppLogger.e('Error loading app version: $e');
      setState(() {
        _appVersion = '2.7.0'; // Fallback
      });
    }
  }
  
  /// Show Refer & Earn popup dialog
  void _showReferralDialog() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 420,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFF1a1a2e), Color(0xFF16213e)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with gradient
              Container(
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFFF59E0B)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.card_giftcard, color: Colors.white, size: 36),
                        SizedBox(width: 12),
                        Text('REFER & EARN', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 1)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('Invite friends & earn rewards!', style: TextStyle(color: Colors.white70, fontSize: 14)),
                  ],
                ),
              ),
              
              // Content
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    // Earnings display
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.green.shade400.withOpacity(0.2), Colors.teal.shade400.withOpacity(0.2)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.green.shade400.withOpacity(0.5)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.monetization_on, color: Colors.amber.shade400, size: 32),
                              const SizedBox(width: 12),
                              const Text('৳500 BDT', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                              const Text(' / ', style: TextStyle(color: Colors.white54, fontSize: 20)),
                              const Text('\$5 USD', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('PER SUCCESSFUL REFERRAL', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1)),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 20),
                    
                    // Features
                    _buildReferralFeature(Icons.group_add, 'Unlimited Referrals', 'No limit on how many friends you can refer'),
                    const SizedBox(height: 12),
                    _buildReferralFeature(Icons.flash_on, 'Instant Rewards', 'Get paid when your friend activates'),
                    const SizedBox(height: 12),
                    _buildReferralFeature(Icons.trending_up, 'Track Earnings', 'See all your referrals and earnings'),
                    
                    const SizedBox(height: 24),
                    
                    // How it works
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('How it works:', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
                          SizedBox(height: 8),
                          Text('1. Share your referral code with friends', style: TextStyle(color: Colors.white54, fontSize: 12)),
                          Text('2. Friend purchases VEO3 Infinity license', style: TextStyle(color: Colors.white54, fontSize: 12)),
                          Text('3. You get ৳500 / \$5 credited instantly!', style: TextStyle(color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 20),
                    
                    // Contact button
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        // TODO: Open referral signup or contact
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Contact support to join the referral program!'),
                            backgroundColor: Colors.purple,
                          ),
                        );
                      },
                      icon: const Icon(Icons.rocket_launch),
                      label: const Text('Join Referral Program'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildReferralFeature(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.purple.shade400.withOpacity(0.3), Colors.pink.shade400.withOpacity(0.3)]),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.purple.shade200, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
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
      AppLogger.i('[PROJECT] Saved ${scenes.length} scenes to project');
    } catch (e) {
      AppLogger.e('Error saving prompts to project: $e');
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
            
            // Load concurrent settings
            if (prefs['maxConcurrentRelaxed'] != null) {
              maxConcurrentRelaxed = prefs['maxConcurrentRelaxed'] as int;
              // Fix: Cap at 4 as user requested if saved value is higher
              if (maxConcurrentRelaxed > 4) maxConcurrentRelaxed = 4;
            }
            if (prefs['maxConcurrentFast'] != null) {
              maxConcurrentFast = prefs['maxConcurrentFast'] as int;
            }
            
            // Load output count
            if (prefs['outputCount'] != null) {
              final saved = prefs['outputCount'] as int;
              if ([1, 2, 4].contains(saved)) {
                selectedOutputCount = saved;
              }
            }
          });
          AppLogger.i('[PREFS] Loaded: account=$selectedAccountType, model=$selectedModel, concurrent=$maxConcurrentRelaxed/$maxConcurrentFast');
        }
      }
    } catch (e) {
      AppLogger.e('[PREFS] Error loading preferences: $e');
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
        'outputCount': selectedOutputCount,
        'maxConcurrentRelaxed': maxConcurrentRelaxed,
        'maxConcurrentFast': maxConcurrentFast,
        'savedAt': DateTime.now().toIso8601String(),
      };
      
      await prefsFile.writeAsString(jsonEncode(prefs));
      print('[PREFS] Saved: account=$selectedAccountType, model=$selectedModel');
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

  // Create new project with dialog
  Future<void> _createNewProject() async {
    final nameController = TextEditingController();
    
    final projectName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Project'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter project name...',
            labelText: 'Project Name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(nameController.text),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    
    if (projectName == null || projectName.trim().isEmpty) return;
    
    try {
      // Create project using ProjectService
      final project = await _projectService.createProject(projectName.trim());
      
      // Load the project (sets it as current and updates VideoGenerationService)
      await _projectService.loadProject(project);
      
      // Update output folder to project's path
      setState(() {
        outputFolder = project.projectPath;
        scenes.clear(); // Start with empty scenes for new project
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Project "${project.name}" created and opened!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create project: $e'), backgroundColor: Colors.red),
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
      final ffmpegPath = await FFmpegUtils.getFFmpegPath();
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
            'Checked path: ${await FFmpegUtils.getFFmpegPath()}\n'
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

  Future<void> _startGeneration() async {
    if (isRunning) return;
    if (scenes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please load scenes first')));
      return;
    }

    setState(() {
      isRunning = true;
      isPaused = false;
    });

    final scenesToProcess = scenes
        .skip(fromIndex - 1)
        .take(toIndex - fromIndex + 1)
        .where((s) => s.status == 'queued' || s.status == 'failed')
        .toList();

    if (scenesToProcess.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No queued scenes in range')));
      setState(() => isRunning = false);
      return;
    }

    try {
      await VideoGenerationService().startBatch(
        scenesToProcess,
        model: selectedModel,
        aspectRatio: selectedAspectRatio,
        use10xBoostMode: use10xBoostMode,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => isRunning = false);
    }
  }

  /// Start generation for a single scene using the unified VideoGenerationService
  Future<void> _startSingleSceneGeneration(SceneData scene) async {
    if (scene == null) return;
    
    // Clear permanent failure status (allows retry of UNSAFE scenes)
    VideoGenerationService().clearPermanentFailure(scene.sceneId);
    
    // Reset scene error if retrying
    scene.error = null;
    
    final scenesToRun = [scene];
    try {
      setState(() { scene.status = 'queued'; });
      await VideoGenerationService().startBatch(scenesToRun, model: selectedModel, aspectRatio: selectedAspectRatio, use10xBoostMode: use10xBoostMode);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Generate error: $e')));
    }
  }


  void _pauseGeneration() {
    setState(() {
      isPaused = !isPaused;
    });
  }

  void _stopGeneration() {
    // Stop the actual video generation service
    VideoGenerationService().stop();
    
    setState(() {
      isRunning = false;
      isUpscaling = false; // Also stop upscaling
      _isControlPanelExpanded = true; // Auto-expand control panel when generation stops
    });
    print('[STOP] Generation and upscaling stopped by user');
  }

  Future<void> _resumePolling() async {
    if (VideoGenerationService().hasPendingPolls) {
      setState(() {
        isRunning = true;
      });
      print('[RESUME] Resuming polling for ${VideoGenerationService().pendingPollsCount} videos');
      
      try {
        await VideoGenerationService().resumePolling();
      } finally {
        setState(() {
          isRunning = false;
        });
        print('[RESUME] Polling completed');
      }
    }
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('VEO3 Infinity', style: TextStyle(fontSize: 20)),
                Text('v${UpdateService.instance.currentVersion ?? "2.5.0"}', 
                     style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
          email: '',
          password: '',
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
      
      // NOTE: Page refresh on 403 disabled - not needed with HTTP-based approach
      // The reCAPTCHA token is generated fresh each time
      
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

  // Workers removed - moved to VideoGenerationService
  // Platform-specific workers removed - all generation now handled by VideoGenerationService singleton
  
  
  /// Process mobile queue with concurrency control
  Future<void> _processMobileQueue(List<SceneData> scenesToProcess, int maxConcurrent, MobileBrowserService service) async {
    int profileIndex = 0;
    
    // SMART STRATEGY: Prefetch 4 tokens initially
    print('\n[MOBILE RECAPTCHA] Prefetching initial batch of 1 token...');
    final healthyProfiles = service.profiles.where((p) => p.isReady).toList();
    for (final profile in healthyProfiles) {
      if (profile.generator != null) {
        profile.generator!.prefetchRecaptchaTokens(1); // Async, don't wait here
      }
    }

    for (var i = 0; i < scenesToProcess.length; i++) {
      if (!isRunning) break;

      while (isPaused) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // SMART BATCHING: Prefetch 4 more tokens every 4 videos
        if (i > 0 && i % 4 == 0) {
        print('\n[MOBILE PREFETCH] Getting next token (after $i videos)...');
        for (final profile in healthyProfiles) {
          if (profile.generator != null) {
            profile.generator!.prefetchRecaptchaTokens(1);
          }
        }
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
            email: '',
            password: '',
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
        // CONCURRENT OPTIMIZATION: Use small delay for concurrent mode, larger for sequential
        final isSequentialMode = maxConcurrent == 1;
        final delayMs = isSequentialMode ? (1500 + Random().nextInt(1500)) : 200;
        print('[MOBILE DELAY] Waiting ${delayMs}ms before request');
        await Future.delayed(Duration(milliseconds: delayMs));
        
        if (isSequentialMode) {
          // SEQUENTIAL: Wait for completion
          await _generateWithMobileProfile(scene, profile, i + 1, scenesToProcess.length);
        } else {
          // CONCURRENT: Fire and forget
          _generateWithMobileProfile(scene, profile, i + 1, scenesToProcess.length)
            .catchError((e) {
              print('[MOBILE ASYNC FAILURE] Scene ${scene.sceneId} failed: $e');
              
              // Handle retries for async failures
              final isRetryable = e.toString().contains('RetryableException') || 
                                 e.toString().contains('403') || 
                                 e.toString().contains('timeout');
                                 
              if (isRetryable) {
                scene.retryCount = (scene.retryCount ?? 0) + 1;
                if (scene.retryCount! < 10) {
                  setState(() {
                    scene.status = 'queued';
                    scene.error = 'Retrying (${scene.retryCount}): $e';
                  });
                } else {
                  setState(() {
                    scene.status = 'failed';
                    scene.error = 'Failed after 10 retries: $e';
                  });
                }
              } else {
                setState(() {
                  scene.status = 'failed';
                  scene.error = e.toString();
                });
              }
            });
        }
        
      } catch (e) {
        // Synchronous errors
        print('[MOBILE SYNC ERROR] $e');
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
    
    // Get prefetched reCAPTCHA token if available
    final recaptchaToken = profile.generator!.getNextPrefetchedToken();
    if (recaptchaToken != null) {
      print('[MOBILE] Using prefetched reCAPTCHA token');
    }

    // Get API model key
    final apiModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
    print('[MOBILE] Model: $apiModelKey');

    // Generate video using direct API call
    final result = await profile.generator!.generateVideo(
      prompt: scene.prompt,
      aspectRatio: selectedAspectRatio,
      model: apiModelKey, // Use API model key
      accessToken: profile.accessToken!,
      recaptchaToken: recaptchaToken, // Pass prefetched token
    ).timeout(const Duration(seconds: 370), onTimeout: () {
      print('[MOBILE SLOT] ! TIMEOUT releasing slot !');
      _activeGenerationsCount--;
      throw Exception('Generation request timed out (370s)');
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
        print('[MOBILE 403] ${profile.name} 403 count: ${profile.consecutive403Count}/7');
        
        // Trigger auto-relogin for THIS browser only if threshold reached
        if (profile.consecutive403Count >= 7) {
          print('[MOBILE 403] ${profile.name} - Triggering relogin for THIS browser only...');
          
          // Use autoReloginProfile for individual browser relogin
          _mobileService?.autoReloginProfile(
            profile,
            email: '', 
            password: '',
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
    _pendingPolls.add(_PendingPoll(scene, sceneUuid, DateTime.now(), profile.accessToken!));
    
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
        if (needsRelogin.isNotEmpty) {
          print('[SINGLE] Triggering relogin for ${needsRelogin.length} browser(s)...');
          setState(() { scene.status = 'generating'; scene.error = 'Relogging browser...'; });
          
          await service.reloginAllNeeded(
            email: '',
            password: '',
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
          print('[SINGLE] 403 error! ${currentProfile.name} count: ${currentProfile.consecutive403Count}/7');
          
          if (currentProfile.consecutive403Count >= 7) {
            print('[SINGLE] Browser hit 403 threshold, triggering relogin...');
            // Trigger relogin in background
            service.autoReloginProfile(currentProfile, email: '', password: '');
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

        // Check if concurrent mode is applicable (4 slots for relaxed model)
        final isRelaxed = selectedModel.contains('relaxed');
        final maxSlots = isRelaxed ? 4 : 1;
        
        // SMART BATCHING: Prefetch 4 tokens every 4 videos if in concurrent mode
        if (isRelaxed && i % 4 == 0 && generator != null) {
          print('\n[PREFETCH] Getting next reCAPTCHA token...');
          try {
            await generator!.prefetchRecaptchaTokens(1);
            print('[PREFETCH] ✓ Got a fresh token');
          } catch (e) {
            print('[PREFETCH] ✗ Failed: $e');
          }
        }

        // Concurrency limit for Relaxed/Free model (4 slots)
        while (isRunning) {
          if (_activeGenerationsCount < maxSlots) {
            break;
          }
          print('\r[LIMIT] Waiting for slots (Active: $_activeGenerationsCount/$maxSlots)...');
          await Future.delayed(const Duration(seconds: 1));
        }

        if (!isRunning) break;

        // Anti-flooding: Small delay in concurrent mode, jitter in sequential
        final delayMs = isRelaxed ? 200 : (1000 + Random().nextInt(1000));
        await Future.delayed(Duration(milliseconds: delayMs));

        // Define the generation task
        Future<void> runGeneration() async {
          _activeGenerationsCount++;
          setState(() => scene.status = 'generating');
          
          try {
            // Upload images and generate...
            // (Moving the existing generation logic into this async task)
            String? startMid = scene.firstFrameMediaId;
            String? endMid = scene.lastFrameMediaId;
            
            // Upload first frame if needed
            if (scene.firstFramePath != null && startMid == null) {
              final res = await generator!.uploadImage(scene.firstFramePath!, accessToken!);
              if (res is String) startMid = res;
            }
            
            // Upload last frame if needed
            if (scene.lastFramePath != null && endMid == null) {
              final res = await generator!.uploadImage(scene.lastFramePath!, accessToken!);
              if (res is String) endMid = res;
            }
            
            final apiModelKey = AppConfig.getApiModelKey(selectedModel, selectedAccountType);
            
            // Get prefetched token if available (favors concurrent mode)
            final prefetchedToken = isRelaxed ? generator!.getNextPrefetchedToken() : null;

            final result = await generator!.generateVideo(
              prompt: scene.prompt,
              accessToken: accessToken!,
              aspectRatio: selectedAspectRatio,
              model: apiModelKey,
              startImageMediaId: startMid,
              endImageMediaId: endMid,
              recaptchaToken: prefetchedToken, // Use prefetched token if available
            );

            if (result == null || result['success'] != true) {
              throw Exception(result?['error'] ?? 'API error');
            }

            final data = result['data'] as Map<String, dynamic>;
            final ops = data['operations'] as List;
            final op = (ops[0] as Map<String, dynamic>)['operation'] as Map<String, dynamic>;
            final opName = op['name'] as String;
            final sceneUuid = (ops[0] as Map)['sceneId']?.toString() ?? opName;

            scene.operationName = opName;
            scene.aspectRatio = selectedAspectRatio;
            
            setState(() => scene.status = 'polling');
            
            // Add to polling worker
            _pendingPolls.add(_PendingPoll(scene, sceneUuid, DateTime.now(), accessToken!));
            _consecutiveFailures = 0;
            
          } catch (e) {
            _activeGenerationsCount--;
            print('[GEN FAILURE] Scene ${scene.sceneId}: $e');
            setState(() {
              scene.status = 'failed';
              scene.error = e.toString();
            });
          }
        }


        if (isRelaxed) {
          // CONCURRENT: Fire and forget
          runGeneration();
        } else {
          // SEQUENTIAL: Wait for completion
          await runGeneration();
        }
      } catch (e) {
        print('[QUEUE ERROR] $e');
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
      
      // Safe fallback for connected count
      final safeConnectedCount = connectedCount > 0 ? connectedCount : 1;
      
      // SMART STRATEGY: Sequential for fast models (1), limited concurrent for relaxed (4)
      final baseSlots = isRelaxedModel ? 4 : 1; // Relaxed: 4 concurrent, Fast: 1 (sequential)
      final maxConcurrent = safeConnectedCount * baseSlots;
      print('[CONCURRENT] Model: $selectedModel');
      print('[CONCURRENT] IsRelaxed: $isRelaxedModel');
      print('[CONCURRENT] Strategy: ${isRelaxedModel ? "4 concurrent per browser" : "Sequential (1 at a time)"}');
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
    print('[CONFIG] Applying settings for batch execution:');
    print('[CONFIG] Model: $selectedModel');
    print('[CONFIG] Account: $selectedAccountType');
    print('[CONFIG] Ratio: $selectedAspectRatio');
    print('[CONFIG] Max Concurrent: $maxConcurrent');

    // SMART STRATEGY: Prefetch 1 token initially (just-in-time)
    print('\n[RECAPTCHA] Prefetching initial token...');
    if (_profileManager != null) {
      final List<Future> prefetchFutures = [];
      for (final profile in _profileManager!.profiles) {
        if (profile.status == ProfileStatus.connected && profile.generator != null) {
          print('[RECAPTCHA] - Prefetching for ${profile.name}...');
          prefetchFutures.add(profile.generator!.prefetchRecaptchaTokens(1));
        }
      }
      if (prefetchFutures.isNotEmpty) {
        await Future.wait(prefetchFutures).timeout(
          const Duration(minutes: 2),
          onTimeout: () => [],
        );
        print('[RECAPTCHA] ✓ Initial prefetch complete\n');
      }
    }

    for (var i = 0; i < scenesToProcess.length; i++) {
      if (!isRunning) {
        print('\n[STOP] Generation stopped by user');
        break;
      }

      while (isPaused) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // SMART BATCHING: Prefetch 1 new token every 4 videos (just-in-time)
      if (i > 0 && i % 4 == 0) {
        print('\n[SMART PREFETCH] Prefetching next token (after $i videos)...');
        if (_profileManager != null) {
          for (final profile in _profileManager!.profiles) {
            if (profile.status == ProfileStatus.connected && profile.generator != null) {
              try {
                await profile.generator!.prefetchRecaptchaTokens(1);
                print('[SMART PREFETCH] ✓ ${profile.name} - Got a fresh token');
              } catch (e) {
                print('[SMART PREFETCH] ${profile.name} - Failed: $e');
              }
            }
          }
        }
      }

      // Check for 429 Cooldown
      if (_is429Cooldown) {
          if (_cooldownEndTime != null && DateTime.now().isBefore(_cooldownEndTime!)) {
              final remaining = _cooldownEndTime!.difference(DateTime.now()).inSeconds;
              print('\r[429] Cooldown active: ${remaining}s remaining...');
              await Future.delayed(const Duration(seconds: 5));
              i--; // Re-process same index
              continue;
          } else {
              print('[429] Cooldown ended. Resuming...');
              _is429Cooldown = false;
          }
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
        // Check if sequential mode (fast models with maxConcurrent=1)
        final isSequentialMode = maxConcurrent == 1;

        // Anti-flooding: Delay between concurrent starts to prevent UI lockups
        if (i > 0) {
          // CONCURRENT OPTIMIZATION: If we are in concurrent mode (relaxed model), 
          // use a very small delay (200ms) to allow UI updates without blocking the batch.
          // This matches the Python app's behavior of sending everything at once.
          final delayMs = isSequentialMode ? (3000 + Random().nextInt(2000)) : 200;
          print('\n[DELAY] Waiting ${delayMs}ms before next video...');
          await Future.delayed(Duration(milliseconds: delayMs));
        }

        // Generate video using selected profile
        // For fast models (maxConcurrent=1): effectively sequential via slot limiting
        // For relaxed models (maxConcurrent=4): concurrent via fire-and-forget
        
        // Track active task for this specific profile
        if (profile is ChromeProfile) {
            profile.activeTasks++;
        }
        
        if (isSequentialMode) {
          // SEQUENTIAL: Wait for completion before next video
          try {
            await _generateWithProfile(scene, profile, i + 1, scenesToProcess.length);
            if (profile is ChromeProfile) {
              profile.activeTasks--;
            }
            _consecutiveFailures = 0;
          } catch (e) {
            if (profile is ChromeProfile) {
              profile.activeTasks--;
            }
            print('[SEQUENTIAL ERROR] Scene ${scene.sceneId}: $e');
            // Error handling continues below
            rethrow;
          }
        } else {
          // CONCURRENT: Fire and forget for relaxed models
          _generateWithProfile(scene, profile, i + 1, scenesToProcess.length)
          .then((_) {
               if (profile is ChromeProfile) {
                   profile.activeTasks--;
               }
               _consecutiveFailures = 0; // Reset consecutive failures on success
          })
          .catchError((e) async {
             if (profile is ChromeProfile) {
                 profile.activeTasks--;
             }
             
             print('[ASYNC FAILURE] Scene ${scene.sceneId} failed: $e');
           
           // Check if retryable
           final is403 = e.toString().contains('403');
           final isRetryable = e.toString().contains('RetryableException') || 
                               is403 || 
                               e.toString().contains('timeout') ||
                               e.toString().contains('Button still disabled');

           if (is403) {
               // Handle 403 Relogin here in case _generateWithProfile aborted early
               profile.consecutive403Count++;
               print('[403] ${profile.name} CONSECUTIVE 403s: ${profile.consecutive403Count}/4');
               if (profile.consecutive403Count >= 4) {
                   
                   // GRACEFUL SHUTDOWN: Wait for other active tasks to finish
                   if (profile is ChromeProfile && profile.activeTasks > 0) {
                      print('[403] ${profile.name} has ${profile.activeTasks} active tasks. Waiting for completion before relogin...');
                      // Simple safety timeout of 200s (enough for video gen)
                      int waitSeconds = 0;
                      while (profile.activeTasks > 0 && waitSeconds < 200) {
                         await Future.delayed(const Duration(seconds: 5));
                         waitSeconds += 5;
                         print('[403] Still waiting for ${profile.activeTasks} tasks on ${profile.name}... (${waitSeconds}s)');
                      }
                      if (profile.activeTasks > 0) {
                          print('[403] Timeout waiting for active tasks. Forcing relogin.');
                      } else {
                          print('[403] All active tasks finished. Proceeding with relogin.');
                      }
                   }
                   
                   // CRITICAL: Mark profile as relogging IMMEDIATELY to prevent new tasks
                   if (profile is ChromeProfile) {
                       // Check if already relogging to prevent duplicate relogins
                       if (profile.status == ProfileStatus.relogging) {
                           print('[403] ${profile.name} - Already relogging, skipping duplicate relogin');
                           return; // Exit early, don't trigger another relogin
                       }
                       
                       profile.status = ProfileStatus.relogging;
                       print('[403] ${profile.name} - Status changed to RELOGGING (queue will pause)');
                   }
                   
                   print('[403] ${profile.name} - Clearing data & Triggering relogin (Async Handler)...');
                   if (profile.generator != null) {
                       // profile.generator!.clearBrowserData().catchError((err) => print('Propagated error: $err'));
                   }
                   if (Platform.isAndroid || Platform.isIOS) {
                       _mobileService?.autoReloginProfile(profile as MobileProfile);
                   } else {
                       _loginService!.reloginProfile(profile, '', '');
                   }
                }
           }

           if (!isRetryable) {
              // Only increment failure count for NON-RETRYABLE errors
              _consecutiveFailures++;
              if (_consecutiveFailures > 3) {
                  print('[CRITICAL] 🛑 Too many consecutive FATAL failures ($_consecutiveFailures > 3). Stopping generation.');
                  if (mounted) setState(() => isRunning = false);
              }
           } else {
             // For retryable errors, we don't increment failure count
             // This allows the browser to recover (relogin) without killing the batch
             _consecutiveFailures = 0; // Reset consecutive FATAL failures as we are retrying
           }

           // Handle retries by setting status back to 'queued' - the outer loop will pick it up
           if (isRetryable) {
              scene.retryCount = (scene.retryCount ?? 0) + 1;
              if (scene.retryCount! < 10) {
                 if (mounted) {
                    setState(() {
                       scene.status = 'queued';
                       scene.error = 'Retrying (${scene.retryCount}): $e';
                    });
                 }
              } else {
                 if (mounted) {
                    setState(() {
                       scene.status = 'failed';
                       scene.error = 'Failed after retries: $e';
                    });
                 }
              }
           } else {
              // Non-retryable
              if (mounted) {
                 setState(() {
                    scene.status = 'failed';
                    scene.error = e.toString();
                 });
              }
           }
        }); // End of catchError
        } // End of else (concurrent mode)

      } catch (e) {
          // Synchronous errors
          print('[SYNC ERROR] $e');
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
    print('[GENERATION METHOD] ✅ PURE HTTP (Dart http package)');
    print('[GENERATION METHOD] Using prefetched reCAPTCHA token');
    print('[GENERATE] Mode: ${isI2V ? "I2V" : "T2V"}');
    print('[GENERATE] startImageMediaId: $startImageMediaId');
    print('[GENERATE] endImageMediaId: $endImageMediaId');

    // Ensure browser connection is alive before making API call
    if (profile.generator == null || !profile.generator!.isConnected) {
      print('[GENERATE] Reconnecting browser ${profile.name}...');
      try {
        profile.generator?.close();
        profile.generator = DesktopGenerator(debugPort: profile.debugPort);
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
    
    // Get prefetched reCAPTCHA token
    final recaptchaToken = profile.generator!.getNextPrefetchedToken();
    if (recaptchaToken == null) {
      _activeGenerationsCount--;
      print('[SLOT] Released slot (no token) - Active: $_activeGenerationsCount');
      throw _RetryableException('No prefetched reCAPTCHA token available');
    }
    
    print('[TOKEN] Using prefetched token #${profile.generator!.tokensUsed + 1}');
    
    // Generate video via PURE HTTP with retry logic
    Map<String, dynamic>? result;
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 5);
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        result = await profile.generator!.generateVideoHTTP(
          prompt: scene.prompt,
          aspectRatio: selectedAspectRatio,
          model: apiModelKey,
          accessToken: profile.accessToken!,
          recaptchaToken: recaptchaToken,
          startImageMediaId: startImageMediaId,
          endImageMediaId: endImageMediaId,
        ).timeout(const Duration(minutes: 10), onTimeout: () {
          throw TimeoutException('Generation request timed out');
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
          
          // Reconnect browser after timeout
          print('[RETRY] Reconnecting browser ${profile.name} after timeout...');
          try {
            profile.generator?.close();
            profile.generator = DesktopGenerator(debugPort: profile.debugPort);
            await profile.generator!.connect();
            profile.accessToken = await profile.generator!.getAccessToken();
            print('[RETRY] ✓ Reconnected ${profile.name}');
          } catch (reconnectError) {
            print('[RETRY] ✗ Reconnect failed: $reconnectError');
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

    // Direct API response handling
    // Check for HTTP error status
    if (result['status'] != null && result['status'] != 200) {
      final statusCode = result['status'] as int;
      final errorMsg = result['error'] ?? result['statusText'] ?? 'API error';
      
      _activeGenerationsCount--;
      print('[SLOT] Released slot (API error $statusCode) - Active: $_activeGenerationsCount');
      
      // Handle 403 errors
      if (statusCode == 403) {
        profile.consecutive403Count++;
        print('[403] ${profile.name} - 403 count: ${profile.consecutive403Count}/7');
        
        if (profile.consecutive403Count >= 7) {
          print('[403] ${profile.name} - Triggering relogin...');
          
          if (Platform.isAndroid || Platform.isIOS) {
            _mobileService?.autoReloginProfile(profile as MobileProfile);
          } else {
            _loginService!.reloginProfile(profile, '', '');
          }
        }
      }

      // Handle 429 error - trigger global cooldown
      if (statusCode == 429) {
        print('[429] 🛑 Global Rate Limit Hit (429 Resource Exhausted)');
        _is429Cooldown = true;
        _cooldownEndTime = DateTime.now().add(const Duration(seconds: 45));
        print('[429] Producer will pause for 45 seconds...');
        
        // Slot already released above
        throw _RetryableException('Rate limit hit (429). Pausing for 45s.');
      }
      
      // For other errors, throw RetryableException to trigger retry
      // Slot already released above
      throw _RetryableException('API error $statusCode: $errorMsg');
    }

    // Check for success flag  
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
    // CRITICAL: Save the access token from the browser that generated this video
    // Multi-browser setup requires each video to be polled with its generator's token
    _pendingPolls.add(_PendingPoll(scene, sceneUuid ?? operationName, DateTime.now(), profile.accessToken!));

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
        
        // GROUP VIDEOS BY ACCESS TOKEN
        // Multiple browsers = different tokens. Each video must be polled with its generator's token!
        final Map<String, List<dynamic>> pollsByToken = {};
        for (final poll in validPolls) {
          if (!pollsByToken.containsKey(poll.accessToken)) {
            pollsByToken[poll.accessToken] = [];
          }
          pollsByToken[poll.accessToken]!.add(poll);
        }
        
        LogService().mobile('[POLLER] Grouped ${validPolls.length} videos into ${pollsByToken.length} token groups');

        // Find a generator to use for polling
        dynamic pollGenerator = generator;
        
        if (pollGenerator == null) {
          if (Platform.isAndroid || Platform.isIOS) {
            if (_mobileService != null) {
              final healthyProfile = _mobileService!.getNextAvailableProfile();
              if (healthyProfile != null) {
                pollGenerator = healthyProfile.generator;
              }
            }
          } else if (_profileManager != null && _profileManager!.profiles.isNotEmpty) {
            for (final profile in _profileManager!.profiles) {
              if (profile.generator != null) {
                pollGenerator = profile.generator;
                break;
              }
            }
          }
        }
        
        // Ensure we have a generator instance (even if browser disconnected)
        if (pollGenerator == null) {
          // Create temporary generator just for HTTP polling
          pollGenerator = DesktopGenerator(debugPort: 9222);
        }

        // POLL EACH TOKEN GROUP SEPARATELY
        for (final entry in pollsByToken.entries) {
          final groupToken = entry.key;
          final groupPolls = entry.value;
          
          // Build batch poll request for this token group
          final pollRequests = groupPolls.map((poll) => 
            PollRequest(poll.scene.operationName!, poll.sceneUuid)
          ).toList();
          
          LogService().mobile('[HTTP POLL] Polling ${pollRequests.length} videos with token ${groupToken.substring(0, 20)}...');
          
          // HTTP-based polling (Python strategy - continues working after relogin)
          final results = await pollGenerator.pollVideoStatusBatchHTTP(pollRequests, groupToken);
          
          LogService().mobile('[POLLER] pollVideoStatusBatch returned! Type: ${results.runtimeType}');
          
          if (results == null || results.isEmpty) {
            LogService().error('[POLLER] No results from batch poll for token ${groupToken.substring(0, 20)}...');
            continue;
          }
          
          // LOG FULL RAW RESPONSE
          LogService().mobile('=== BATCH POLL RAW RESPONSE (Token: ${groupToken.substring(0, 20)}...) ===');
          LogService().mobile('Results count: ${results.length}');
          for (var i = 0; i < results.length; i++) {
            LogService().mobile('Result[$i]: ${jsonEncode(results[i])}');
          }
          LogService().mobile('=== END RAW RESPONSE ===');

          // Process results - MATCH ONLY WITHIN THIS TOKEN GROUP
          for (var i = 0; i < results.length; i++) {
            final result = results[i];
            final poll = groupPolls[i]; // Match by index within this group
            final scene = poll.scene;
            
            final status = result['status'] as String?;
            LogService().mobile('Poll result for scene ${scene.sceneId}: status=$status');

            if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
                status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
              // Video is SUCCESSFUL - free up slot
              _activeGenerationsCount--;
              print('[SLOT] Video ready, freed slot - Active: $_activeGenerationsCount');
              
              // Extract video URL
              String? videoUrl;
              String? videoMediaId;
              
              if (result.containsKey('operation')) {
                final op = result['operation'] as Map<String, dynamic>;
                final metadata = op['metadata'] as Map<String, dynamic>?;
                final video = metadata?['video'] as Map<String, dynamic>?;
                videoUrl = video?['fifeUrl'] as String?;
                
                final mediaGenId = video?['mediaGenerationId'];
                if (mediaGenId != null) {
                  videoMediaId = (mediaGenId is Map) 
                    ? mediaGenId['mediaGenerationId'] as String?
                    : mediaGenId as String;
                }
              }

              if (videoUrl != null) {
                print('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
                if (videoMediaId != null) {
                  scene.videoMediaId = videoMediaId;
                  scene.downloadUrl = videoUrl;
                }
                _downloadVideo(scene, videoUrl);
                
                // Remove from pending polls
                _pendingPolls.removeWhere((p) => p.scene.sceneId == scene.sceneId);
              } else {
                setState(() {
                  scene.status = 'failed';
                  scene.error = 'No video URL';
                });
                _pendingPolls.removeWhere((p) => p.scene.sceneId == scene.sceneId);
              }
              
            } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
              String errorMsg = 'Generation failed';
              if (result.containsKey('operation')) {
                final metadata = (result['operation'] as Map<String, dynamic>)['metadata'] as Map<String, dynamic>?;
                final errorDetails = metadata?['error'] as Map<String, dynamic>?;
                if (errorDetails != null) {
                  errorMsg = '${errorDetails['message'] ?? 'No details'}';
                }
              }

              scene.retryCount = (scene.retryCount ?? 0) + 1;
              _activeGenerationsCount--;
              
              if (scene.retryCount! < 10) {
                print('[RETRY] Scene ${scene.sceneId} poll failed (${scene.retryCount}/10)');
                setState(() {
                  scene.status = 'queued';
                  scene.operationName = null;
                  scene.error = 'Retrying (${scene.retryCount}/10): $errorMsg';
                });
              } else {
                print('[POLLER] ✗ Scene ${scene.sceneId} failed after 10 retries');
                setState(() {
                  scene.status = 'failed';
                  scene.error = 'Failed after 10 retries: $errorMsg';
                });
                _savePromptsToProject();
              }
              
              _pendingPolls.removeWhere((p) => p.scene.sceneId == scene.sceneId);
            }
            // PENDING or ACTIVE - keep polling
          }
        } // End token group loop

        // Poll interval delay
        await Future.delayed(Duration(seconds: pollInterval));
      } catch (e) {
        if (e.toString().contains('WebSocket')) {
          print('[POLLER] WebSocket error (browser may be relogging): $e');
        } else {
          LogService().error('[POLLER] Error: $e');
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
        // HTTP download only needs generator instance, not connected browser!
        for (final profile in _profileManager!.profiles) {
          if (profile.generator != null) {
            downloadGenerator = profile.generator;
            break;
          }
        }
      }
      
      // Create temporary generator for HTTP download if needed
      if (downloadGenerator == null) {
        print('[DOWNLOAD] Creating temporary generator for HTTP download...');
        downloadGenerator = DesktopGenerator(debugPort: 9222);
      }

      // Use projectService for consistent path generation
    final outputPath = await widget.projectService.getVideoOutputPath(
      null,
      scene.sceneId,
      isQuickGenerate: false,
    );
    
    // HTTP download (Python strategy - no browser needed)
    print('[HTTP DOWNLOAD] Downloading via HTTP...');
    final fileSize = await downloadGenerator.downloadVideoHTTP(videoUrl, outputPath);

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

  // Account Management Methods
  void _saveAccount() {
    final email = _accountEmailController.text.trim();
    final password = _accountPasswordController.text.trim();
    
    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Please enter both email and password'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Save to SettingsService
    SettingsService.instance.addAccount(email, password);
    SettingsService.instance.save();
    
    // Clear fields
    _accountEmailController.clear();
    _accountPasswordController.clear();
    
    // Show success
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 8),
            Text('✅ Account saved: $email'),
          ],
        ),
        backgroundColor: Colors.green,
      ),
    );
    
    setState(() {});
  }
  
  void _deleteAccount(int index) {
    final email = SettingsService.instance.accounts[index]['email'];
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: Text('Are you sure you want to delete $email?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              SettingsService.instance.removeAccount(index);
              SettingsService.instance.save();
              Navigator.pop(context);
              setState(() {});
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✅ Deleted: $email'),
                  backgroundColor: Colors.red,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
  
  void _editAccount(int index, String email, String password) {
    final TextEditingController editEmailController = TextEditingController(text: email);
    final TextEditingController editPasswordController = TextEditingController(text: password);
    final account = SettingsService.instance.accounts[index];
    final assignedProfiles = List<String>.from(account['assignedProfiles'] ?? []);
    
    // Get available browser profiles
    final browserProfiles = SettingsService.instance.getBrowserProfiles();
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.edit, color: Colors.blue),
              const SizedBox(width: 8),
              const Text('Edit Account'),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Email field
                  TextField(
                    controller: editEmailController,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      hintText: 'your.email@gmail.com',
                      prefixIcon: const Icon(Icons.email, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  
                  // Password field
                  TextField(
                    controller: editPasswordController,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      hintText: '••••••••',
                      prefixIcon: const Icon(Icons.lock, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      isDense: true,
                    ),
                    obscureText: true,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  
                  // Profile Assignment Section
                  Text('Assigned Profiles', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                  const SizedBox(height: 8),
                  
                  if (browserProfiles.isEmpty)
                    Card(
                      color: Colors.orange.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 18, color: Colors.orange.shade700),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'No browser profiles available. Create profiles in Browser tab first.',
                                style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          // Select All / Deselect All
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(8),
                                topRight: Radius.circular(8),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${assignedProfiles.length} of ${browserProfiles.length} selected',
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    setDialogState(() {
                                      if (assignedProfiles.length == browserProfiles.length) {
                                        assignedProfiles.clear();
                                      } else {
                                        assignedProfiles.clear();
                                        assignedProfiles.addAll(browserProfiles.map((p) => p['id'].toString()));
                                      }
                                    });
                                  },
                                  child: Text(
                                    assignedProfiles.length == browserProfiles.length ? 'Deselect All' : 'Select All',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Profile list
                          Container(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: browserProfiles.length,
                              itemBuilder: (context, i) {
                                final profile = browserProfiles[i];
                                final profileId = profile['id'].toString();
                                final profileName = profile['name'].toString();
                                final isSelected = assignedProfiles.contains(profileId);
                                
                                return CheckboxListTile(
                                  dense: true,
                                  value: isSelected,
                                  onChanged: (checked) {
                                    setDialogState(() {
                                      if (checked == true) {
                                        assignedProfiles.add(profileId);
                                      } else {
                                        assignedProfiles.remove(profileId);
                                      }
                                    });
                                  },
                                  title: Text(profileName, style: const TextStyle(fontSize: 12)),
                                  subtitle: Text('ID: $profileId', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                                  secondary: CircleAvatar(
                                    radius: 14,
                                    backgroundColor: isSelected ? Colors.blue.shade100 : Colors.grey.shade200,
                                    child: Icon(
                                      isSelected ? Icons.check : Icons.person_outline,
                                      size: 14,
                                      color: isSelected ? Colors.blue.shade700 : Colors.grey.shade600,
                                    ),
                                  ),
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
          ),
          actions: [
            TextButton(
              onPressed: () {
                editEmailController.dispose();
                editPasswordController.dispose();
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                final newEmail = editEmailController.text.trim();
                final newPassword = editPasswordController.text.trim();
                
                if (newEmail.isEmpty || newPassword.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('⚠️ Email and password cannot be empty'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                
                // Update account
                SettingsService.instance.accounts[index] = {
                  'email': newEmail,
                  'username': newEmail,
                  'password': newPassword,
                  'assignedProfiles': assignedProfiles,
                };
                SettingsService.instance.save();
                
                editEmailController.dispose();
                editPasswordController.dispose();
                Navigator.pop(context);
                setState(() {});
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.white),
                        const SizedBox(width: 8),
                        Text('✅ Updated: $newEmail'),
                      ],
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              },
              icon: const Icon(Icons.save, size: 16),
              label: const Text('Save Changes'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
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
    // Ensure selectedModel is valid (fixes Hot Reload issues with stale state)
    if (!AppConfig.flowModelOptions.values.contains(selectedModel)) {
      if (AppConfig.flowModelOptions.values.isNotEmpty) {
        selectedModel = AppConfig.flowModelOptions.values.first;
      }
    }

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
        email: '',
        password: '',
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
        email: '',
        password: '',
        selectedModel: selectedModel,
        selectedAccountType: selectedAccountType,
        onBack: () {
          setState(() {
            _showReelSpecialScreen = false;
          });
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Breakpoint for mobile/tablet
        final isMobile = constraints.maxWidth < 900;
        
        return Stack(
          children: [
            Scaffold(
              backgroundColor: Colors.grey.shade100,
              appBar: isMobile ? AppBar(
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
                        // File Operations - Scrollable to prevent overlap
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildAppBarTextButton('Load', Icons.file_upload_outlined, _loadFile),
                                _buildAppBarTextButton('Paste', Icons.content_paste, _pasteJson),
                                _buildAppBarTextButton('Save', Icons.save, _saveProject),
                                _buildAppBarTextButton('Open', Icons.folder_open, _loadProject),
                                _buildAppBarTextButton('Output', Icons.create_new_folder, _setOutputFolder),
                              ],
                            ),
                          ),
                        ),
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
                  if (isMobile)
                    IconButton(
                      icon: const Icon(Icons.web),
                      tooltip: 'Browsers',
                      onPressed: () {
                        final dynamic state = _mobileBrowserManagerKey.currentState;
                        state?.show();
                      },
                    ),
                  if (!isMobile) ...[
                    // Check Update Button - Always visible
                    AnimatedBuilder(
                      animation: widget.updateNotifier,
                      builder: (context, child) {
                        final hasUpdate = widget.updateNotifier.updateAvailable;
                        final updateInfo = widget.updateNotifier.updateInfo;
                        
                        return TextButton.icon(
                          onPressed: () async {
                            // Force check for updates
                            final updateService = UpdateService.instance;
                            await updateService.checkForUpdates();
                            
                            if (updateService.updateAvailable && updateService.updateInfo != null) {
                              UpdateDialog.show(context, updateService.updateInfo!);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('✅ You have the latest version!'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                          icon: Icon(
                            hasUpdate ? Icons.system_update : Icons.system_update_outlined,
                            color: hasUpdate ? Colors.red : Colors.grey,
                            size: 20,
                          ),
                          label: Text(
                            hasUpdate ? 'Update Available!' : 'Check Update',
                            style: TextStyle(
                              color: hasUpdate ? Colors.red : Colors.grey[700],
                              fontWeight: hasUpdate ? FontWeight.bold : FontWeight.normal,
                              fontSize: 12,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            backgroundColor: hasUpdate ? Colors.red.withOpacity(0.1) : Colors.transparent,
                          ),
                        );
                      },
                    ),
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
              ) : null,
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
                              Tab(text: 'Settings', height: 32),
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
                              // TAB 3: SETTINGS - Account Management
                              _buildMobileSettingsTab(),
                            ],
                          ),
                        ),
                      ],
                    )
                  // DESKTOP: New Redesigned Layout
                  : _buildRedesignedDesktopLayout(completed, failed, pending, active, upscaling, upscaled),
              ),
            ),
            if (isMobile)
              MobileBrowserManagerWidget(
                key: _mobileBrowserManagerKey,
                onVisibilityChanged: (_) => setState((){}),
              ),
            // Floating Log Viewer
            if (showLogViewer)
              Positioned(
                right: 20,
                bottom: 20,
                child: LogViewerWidget(),
              ),
          ],
        );
      },
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
      use10xBoostMode: use10xBoostMode,
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
      on10xBoostModeChanged: (value) {
        setState(() => use10xBoostMode = value);
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
      onLoginAll: _handleLoginAll,
      onConnectOpened: _handleConnectOpened,
      onOpenWithoutLogin: _handleOpenWithoutLogin,
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
              // Bulk Upscale 1080p button
              if (!isUpscaling)
                TextButton.icon(
                  onPressed: () {
                    print('[UI] Upscale 1080p button clicked!');
                    mobileLog('[UI] Upscale 1080p button clicked');
                    _bulkUpscale(resolution: '1080p');
                  },
                  icon: Icon(Icons.hd, size: 16, color: Colors.blue.shade600),
                  label: Text('Upscale 1080p', style: TextStyle(fontSize: 12, color: Colors.blue.shade600)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Colors.blue.shade50,
                  ),
                ),
              const SizedBox(width: 4),
              // Bulk Upscale 4K button
              if (!isUpscaling)
                TextButton.icon(
                  onPressed: () {
                    print('[UI] Upscale 4K button clicked!');
                    mobileLog('[UI] Upscale 4K button clicked');
                    _bulkUpscale(resolution: '4K');
                  },
                  icon: Icon(Icons.four_k, size: 16, color: Colors.purple.shade600),
                  label: Text('Upscale 4K', style: TextStyle(fontSize: 12, color: Colors.purple.shade600)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Colors.purple.shade50,
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
                  _startSingleSceneGeneration(scene);
                },
                onOpen: () => _openVideo(scene),
                onOpenFolder: () => _openVideoFolder(scene),
                onDelete: () => setState(() => scenes.removeAt(index)),
                onUpscale: scene.status == 'completed' ? (resolution) {
                  // Start the upscale with selected resolution
                  print('[UI] Single scene upscale clicked: ${scene.sceneId} at $resolution');
                  mobileLog('[UI] Upscale scene ${scene.sceneId} to $resolution');
                  _upscaleScene(scene, resolution: resolution);
                } : null,
                onStopUpscale: scene.status == 'completed' ? () {
                  // Stop the upscale
                  print('[UI] Stop upscale clicked: ${scene.sceneId}');
                  mobileLog('[UI] Stop upscale ${scene.sceneId}');
                  setState(() {
                    scene.upscaleStatus = 'failed';
                    scene.error = 'Stopped by user';
                  });
                } : null,
              );
            },
          ),
        ),
      ],
    );
  }

  /// Export all completed videos (Concatenate)
  Future<void> _exportAllVideos() async {
    final completedScenes = scenes.where((s) => s.status == 'completed' && s.videoPath != null && File(s.videoPath!).existsSync()).toList();
    
    if (completedScenes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No completed videos to export')),
      );
      return;
    }

    final exportService = StoryExportService();
    
    // Sort by ID to ensure correct order
    completedScenes.sort((a, b) => a.sceneId.compareTo(b.sceneId));

    final videoPaths = completedScenes.map((s) => s.videoPath!).toList();

    // Show dialog to configure export
    if (!mounted) return;
    
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export All Videos'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${completedScenes.length} videos ready to export.'),
            const SizedBox(height: 8),
            const Text('This will merge all completed videos into a single file.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext); // Close config dialog
              
              // Select output file
              String? outputFile = await FilePicker.platform.saveFile(
                dialogTitle: 'Save Exported Video',
                fileName: 'veo_export_${DateTime.now().millisecondsSinceEpoch}.mp4',
                allowedExtensions: ['mp4'],
                type: FileType.custom,
              );

              if (outputFile != null) {
                if (!outputFile.toLowerCase().endsWith('.mp4')) {
                  outputFile = '$outputFile.mp4';
                }

                // Show progress dialog
                if (!mounted) return;
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('Exporting videos...'),
                          ],
                        ),
                      ),
                    ),
                  ),
                );

                try {
                  print('[Export] Concatenating ${videoPaths.length} videos to $outputFile');
                  await exportService.concatenateVideos(
                    videoPaths: videoPaths,
                    outputPath: outputFile!,
                  );
                  
                  if (mounted) {
                    Navigator.pop(context); // Close progress
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export successful: ${path.basename(outputFile!)}')),
                    );
                    
                    // Open folder
                    if (Platform.isWindows) {
                       Process.run('explorer', ['/select,', outputFile]);
                    }
                  }
                } catch (e) {
                  print('[Export] Failed: $e');
                  if (mounted) {
                    Navigator.pop(context); // Close progress
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
                    );
                  }
                }
              }
            },
            icon: const Icon(Icons.download),
            label: const Text('Export'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  // MOBILE TAB 2: Browser - Profiles, Auto Login, Connect + Console
  Widget _buildMobileBrowserTab() {
    final service = MobileBrowserService();
    
    // Set flag so login handlers know to use embedded webview
    _isShowingMobileLayout = true;
    
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
                    mobileBrowserService: _mobileBrowserService,  // Pass mobile service for status display
                    onLogin: _handleLoginSingle,
                    onLoginAll: _handleLoginAll,
                    onConnectOpened: _handleConnectOpened,
                    onOpenWithoutLogin: _handleOpenWithoutLogin,
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

  /// Mobile Settings Tab - PC-Style with 3 Tabs
  Widget _buildMobileSettingsTab() {
    return DefaultTabController(
      length: 3,
      initialIndex: _selectedSettingsTab,
      child: Builder(
        builder: (context) {
          // Listen to tab changes
          final tabController = DefaultTabController.of(context);
          tabController.addListener(() {
            if (!tabController.indexIsChanging) {
              setState(() {
                _selectedSettingsTab = tabController.index;
              });
            }
          });
          
          return Column(
            children: [
              // Tab Bar
              Material(
                color: Colors.white,
                elevation: 1,
                child: TabBar(
                  indicatorColor: Colors.blue,
                  labelColor: Colors.blue,
                  unselectedLabelColor: Colors.grey,
                  labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  tabs: const [
                    Tab(icon: Icon(Icons.api, size: 18), text: 'Gemini API'),
                    Tab(icon: Icon(Icons.web, size: 18), text: 'Profiles'),
                    Tab(icon: Icon(Icons.account_circle, size: 18), text: 'Accounts'),
                  ],
                ),
              ),
              // Tab Content
              Expanded(
                child: TabBarView(
                  children: [
                    _buildMobileGeminiAPITab(),
                    _buildMobileBrowserProfilesTab(),
                    _buildMobileGoogleAccountsTab(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Gemini API Tab (Mobile)
  Widget _buildMobileGeminiAPITab() {
    // Get current keys from SettingsService
    final keys = SettingsService.instance.getGeminiKeys();
    final keyText = keys.join('\n');
    final keyCount = keys.length;
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.api, size: 20, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Gemini API Keys', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue.shade700)),
                    Text('One key per line', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                  ],
                ),
              ),
              // Key count badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: keyCount > 0 ? Colors.green.shade100 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$keyCount key${keyCount != 1 ? 's' : ''}',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: keyCount > 0 ? Colors.green.shade700 : Colors.grey.shade600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // API Keys Card
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: TextEditingController(text: keyText),
                    decoration: InputDecoration(
                      hintText: 'AIzaSy...\nAIzaSy...',
                      hintStyle: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.all(12),
                      isDense: true,
                    ),
                    maxLines: 6,
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    onChanged: (value) async {
                      // Save immediately on change
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('settings_gemini_api', value);
                      await SettingsService.instance.reload();
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: () async {
                      // Save and show feedback
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            children: [
                              const Icon(Icons.check_circle, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Text('✅ Saved $keyCount key${keyCount != 1 ? 's' : ''}'),
                            ],
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('Save Keys'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
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

  /// Browser Profiles Tab (Mobile)
  Widget _buildMobileBrowserProfilesTab() {
    final profiles = SettingsService.instance.getBrowserProfiles();
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.web, size: 20, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Browser Profiles', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue.shade700)),
                    Text('For multi-account login', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Add Profile Button
          ElevatedButton.icon(
            onPressed: () => _addMobileBrowserProfile(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Profile'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          
          // Profile List
          if (profiles.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.web, size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text('No profiles yet', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  ],
                ),
              ),
            )
          else
            ...profiles.map((profile) {
              final profileId = profile['id'].toString();
              final profileName = profile['name'].toString();
              
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blue.shade100,
                    child: const Icon(Icons.person, size: 18, color: Colors.blue),
                  ),
                  title: Text(profileName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  subtitle: Text('ID: $profileId', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                    onPressed: () => _deleteMobileBrowserProfile(profileId, profileName),
                  ),
                ),
              );
            }).toList(),
        ],
      ),
    );
  }

  /// Google Accounts Tab (Mobile)
  Widget _buildMobileGoogleAccountsTab() {
    final accounts = SettingsService.instance.accounts;
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.account_circle, size: 20, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Google Accounts', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue.shade700)),
                    Text('Assign to browser profiles', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Add Account Button
          ElevatedButton.icon(
            onPressed: () => _addMobileGoogleAccount(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Account'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          
          // Debug: Show account count
          if (accounts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${accounts.length} account(s) loaded',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
            ),
          
          // Account List
          if (accounts.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(Icons.account_circle, size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text('No accounts yet', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  ],
                ),
              ),
            )
          else
            ...accounts.asMap().entries.map((entry) {
              final index = entry.key;
              final account = entry.value;
              // Check both 'email' and 'username' fields for compatibility
              final email = account['email']?.toString() ?? account['username']?.toString() ?? 'No email';
              final password = account['password']?.toString() ?? '';
              final assignedProfiles = (account['assignedProfiles'] as List?)?.length ?? 0;
              
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blue.shade100,
                    child: Text('${index + 1}', style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  title: Text(
                    email,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    assignedProfiles > 0 ? '$assignedProfiles profile(s) assigned' : 'No profiles assigned',
                    style: TextStyle(fontSize: 10, color: assignedProfiles > 0 ? Colors.green.shade600 : Colors.grey.shade600),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue, size: 18),
                        onPressed: () => _editAccount(index, email, password),
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                        onPressed: () => _deleteAccount(index),
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
        ],
      ),
    );
  }

  // Helper methods for mobile settings
  
  void _addMobileBrowserProfile() async {
    final nameController = TextEditingController();
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Browser Profile'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Profile Name',
            hintText: 'e.g., Work, Personal',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    
    if (result == true && nameController.text.trim().isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final profiles = SettingsService.instance.getBrowserProfiles();
      profiles.add({
        'id': 'profile_${DateTime.now().millisecondsSinceEpoch}',
        'name': nameController.text.trim(),
      });
      await prefs.setString('settings_browser_profiles', jsonEncode(profiles));
      await SettingsService.instance.reload();
      setState(() {});
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Profile "${nameController.text.trim()}" added'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
    
    nameController.dispose();
  }
  
  void _deleteMobileBrowserProfile(String profileId, String profileName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Profile'),
        content: Text('Delete "$profileName"?\n\nThis will unassign any accounts linked to this profile.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      final prefs = await SharedPreferences.getInstance();
      final profiles = SettingsService.instance.getBrowserProfiles();
      profiles.removeWhere((p) => p['id'] == profileId);
      
      // Remove from accounts
      final accounts = SettingsService.instance.accounts;
      for (var account in accounts) {
        final assignedList = account['assignedProfiles'] as List?;
        assignedList?.remove(profileId);
      }
      
      await prefs.setString('settings_browser_profiles', jsonEncode(profiles));
      await prefs.setString('settings_google_accounts', jsonEncode(accounts));
      await SettingsService.instance.reload();
      setState(() {});
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Deleted: $profileName'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  void _addMobileGoogleAccount() async {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          bool obscurePassword = true;
          
          return AlertDialog(
            title: const Text('Add Google Account'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email, size: 18),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autofocus: true,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock, size: 18),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(obscurePassword ? Icons.visibility_off : Icons.visibility, size: 18),
                        onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                      ),
                    ),
                    obscureText: obscurePassword,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
    
    if (result == true) {
      final email = emailController.text.trim();
      final password = passwordController.text.trim();
      
      if (email.isNotEmpty && password.isNotEmpty) {
        SettingsService.instance.addAccount(email, password);
        await SettingsService.instance.save();
        setState(() {});
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Account added: $email'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    }
    
    emailController.dispose();
    passwordController.dispose();
  }

  // Login Handler Methods for Mobile Browser (Uses EMBEDDED InAppWebView, NOT external Chrome)
  
  Future<void> _handleLoginSingle(int profileIndex) async {
    final accounts = SettingsService.instance.accounts;
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ No accounts configured!'), backgroundColor: Colors.orange),
      );
      return;
    }
    
    // Ensure the browser service is initialized with enough profiles
    if (_mobileBrowserService.profiles.isEmpty || _mobileBrowserService.profiles.length < profileIndex) {
      _mobileBrowserService.initialize(profileIndex);
    }
    
    // Get account for this profile index
    final accountIndex = (profileIndex - 1) % accounts.length;
    final account = accounts[accountIndex];
    final email = account['email']?.toString() ?? account['username']?.toString() ?? '';
    final password = account['password']?.toString() ?? '';
    
    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ Invalid account!'), backgroundColor: Colors.red),
      );
      return;
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🔐 Clearing & logging in Browser $profileIndex...'), duration: const Duration(seconds: 2)),
    );
    
    // Use embedded MobileBrowserService to login with FULL clear
    try {
      final profile = _mobileBrowserService.getProfile(profileIndex - 1);
      if (profile?.generator != null && profile?.controller != null) {
        // CLEAR EVERYTHING FIRST (cookies + JS storage)
        print('[LOGIN] Clearing cookies for single browser login...');
        await CookieManager.instance().deleteAllCookies();
        
        // Clear localStorage and sessionStorage via JavaScript
        await profile!.controller!.evaluateJavascript(source: '''
          try {
            localStorage.clear();
            sessionStorage.clear();
            if (window.indexedDB && window.indexedDB.databases) {
              window.indexedDB.databases().then(dbs => {
                dbs.forEach(db => window.indexedDB.deleteDatabase(db.name));
              });
            }
          } catch(e) {}
        ''');
        
        profile.accessToken = null;
        profile.status = MobileProfileStatus.loading;
        setState(() {});
        
        await Future.delayed(const Duration(seconds: 1));
        
        // Now do full login
        final success = await profile.generator!.autoLogin(email, password);
        
        if (success) {
          // Get token after login
          final token = await profile.generator!.getAccessToken();
          if (token != null) {
            profile.accessToken = token;
            profile.status = MobileProfileStatus.ready;
            profile.consecutive403Count = 0;
          }
        }
        
        setState(() {});
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(success ? '✅ Login successful!' : '❌ Login failed'),
              backgroundColor: success ? Colors.green : Colors.red,
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ Browser not ready. Open Browser tab first.'), backgroundColor: Colors.orange),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
  
  /// Build main content row (sidebar + page content) - extracted for reuse
  Widget _buildMainContentRow(int completed, int failed, int pending, int active, int upscaling, int upscaled) {
    return Row(
      children: [
        // LEFT SIDEBAR - Only show on HOME tab
        if (_currentNavIndex == 0)
          Container(
            width: 256,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(right: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // REFER & EARN Button
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _showReferralDialog,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFFF59E0B)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [BoxShadow(color: const Color(0xFF8B5CF6).withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4))],
                        ),
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: const [
                                Icon(Icons.card_giftcard, color: Colors.white, size: 26),
                                SizedBox(width: 8),
                                Text('REFER & EARN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 0.3)),
                                Spacer(),
                                Icon(Icons.chevron_right, color: Colors.white70, size: 20),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: const [
                                Text('৳', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22)),
                                Text('500', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 32, height: 1)),
                                SizedBox(width: 8),
                                Text('/ \$5', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 16)),
                                Spacer(),
                                Text('per referral', style: TextStyle(color: Colors.white60, fontSize: 11)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // FILE OPERATIONS
                _buildSidebarSection('FILE OPERATIONS', [
                  _buildSidebarItemHighlighted(Icons.add_box, 'Create New Project', _createNewProject, Colors.blue),
                  _buildSidebarItem(Icons.file_upload, 'Load Prompts', _loadFile),
                  _buildSidebarItem(Icons.content_paste_rounded, 'Paste Prompts', _pasteJson),
                  _buildSidebarItem(Icons.save_alt, 'Save Project', _saveProject),
                  _buildSidebarItem(Icons.folder_open, 'Open Output', () => Process.run('explorer', [outputFolder])),
                ]),
                const SizedBox(height: 8),
                // I2V OPERATIONS
                _buildSidebarSection('I2V OPERATIONS', [
                  _buildSidebarItem(Icons.image_search, 'Import First Frames', _importBulkFirstFrames),
                  _buildSidebarItem(Icons.image_aspect_ratio, 'Import Last Frames', _importBulkLastFrames),
                ]),
                const SizedBox(height: 8),
                // ACTIONS
                _buildSidebarSection('ACTIONS', [
                  _buildSidebarItemHighlighted(Icons.rocket_launch, 'Heavy Bulk Tasks', _openHeavyBulkTasks, Colors.amber),
                ]),
                const Spacer(),
                // About at bottom
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: Colors.grey.shade200)),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _showAboutDialog,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 20, color: Colors.grey.shade600),
                            const SizedBox(width: 12),
                            Text('About Version $_appVersion', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        
        // RIGHT CONTENT AREA
        Expanded(
          child: _buildPageContent(),
        ),
      ],
    );
  }

  /// Redesigned Desktop Layout matching the new modern UI design
  Widget _buildRedesignedDesktopLayout(int completed, int failed, int pending, int active, int upscaling, int upscaled) {
    // Build the header bar widget
    Widget headerBar = Container(
      height: 80,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 2, offset: const Offset(0, 1))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Stack(
          children: [
            // Left side - Logo and Title
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF4F46E5)]),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Center(child: Text('V', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
                  ),
                  const SizedBox(width: 12),
                  const Text('VEO3 Infinity', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
                ],
              ),
            ),
            
            // Center - Navigation Tabs (absolutely centered)
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildNavTab('HOME', Icons.home, 0, _currentNavIndex == 0),
                  _buildNavTab('Character Studio', Icons.dashboard, 1, _currentNavIndex == 1),
                  _buildNavTab('SceneBuilder', Icons.auto_stories, 9, _currentNavIndex == 9),
                  _buildNavTab('Clone YouTube', Icons.video_library, 10, _currentNavIndex == 10),
                  _buildNavTab('MASTERING', Icons.auto_fix_high, 2, _currentNavIndex == 2),
                  _buildNavTab('REELS', Icons.movie, 3, _currentNavIndex == 3),
                  _buildNavTab('AV Match', Icons.music_note, 4, _currentNavIndex == 4),
                  _buildNavTab('SETTINGS', Icons.settings, 6, _currentNavIndex == 6),
                  _buildNavTab('EXPORT', Icons.download, 5, _currentNavIndex == 5),
                  _buildNavTab('AI Voice', Icons.record_voice_over, 7, _currentNavIndex == 7),
                  _buildNavTab('More Tools', Icons.build, 8, _currentNavIndex == 8),
                ],
              ),
            ),
            
            // Right side actions
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Row(
                children: [
                  // Check Update Button - Always visible
                  AnimatedBuilder(
                    animation: widget.updateNotifier,
                    builder: (context, child) {
                      final hasUpdate = widget.updateNotifier.updateAvailable;
                      final updateInfo = widget.updateNotifier.updateInfo;
                      
                      return TextButton.icon(
                        onPressed: () async {
                          final updateService = UpdateService.instance;
                          await updateService.checkForUpdates();
                          
                          if (updateService.updateAvailable && updateService.updateInfo != null) {
                            UpdateDialog.show(context, updateService.updateInfo!);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('✅ You have the latest version!'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        icon: Icon(
                          hasUpdate ? Icons.system_update : Icons.system_update_outlined,
                          color: hasUpdate ? Colors.red : Colors.grey[600],
                          size: 18,
                        ),
                        label: Text(
                          hasUpdate ? 'Update Available!' : 'Check Update',
                          style: TextStyle(
                            color: hasUpdate ? Colors.red : Colors.grey[700],
                            fontWeight: hasUpdate ? FontWeight.bold : FontWeight.normal,
                            fontSize: 11,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          backgroundColor: hasUpdate ? Colors.red.withOpacity(0.1) : Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.terminal, size: 20),
                    onPressed: _launchLogsProcess,
                    tooltip: 'Open Logs Window',
                    color: Colors.green.shade600,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    
    // All screens use the same Column layout with header bar
    return Column(
      children: [
        // TOP HEADER BAR
        headerBar,
        // MAIN CONTENT ROW
        Expanded(
          child: _buildMainContentRow(completed, failed, pending, active, upscaling, upscaled),
        ),
      ],
    );
  }

  Widget _buildHomeContent() {
    final completed = scenes.where((s) => s.status == 'completed').length;
    final active = scenes.where((s) => 
      ['generating', 'polling', 'downloading'].contains(s.status) ||
      ['upscaling', 'polling', 'downloading'].contains(s.upscaleStatus)
    ).length;
    final failed = scenes.where((s) => s.status == 'failed').length;
    
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        children: [
          // TOP BAR: Control Panel + Stats
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // LEFT: COLLAPSIBLE CONTROL PANEL
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      // COLLAPSED HEADER (always visible)
                      InkWell(
                        onTap: () => setState(() => _isControlPanelExpanded = !_isControlPanelExpanded),
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: _isControlPanelExpanded ? 12 : 8),
                          child: Row(
                            children: [
                              // When EXPANDED: Show full Ratio/Model/Account controls
                              if (_isControlPanelExpanded) ...[
                                Text('Ratio:', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                                const SizedBox(width: 12),
                                Container(
                                  decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildRatioToggle('16:9', selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE', () { setState(() => selectedAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE'); _savePreferences(); }),
                                      _buildRatioToggle('9:16', selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT', () { setState(() => selectedAspectRatio = 'VIDEO_ASPECT_RATIO_PORTRAIT'); _savePreferences(); }),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Text('Model:', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: selectedModel,
                                      isDense: true,
                                      style: GoogleFonts.inter(fontSize: 14, color: Colors.black87, fontWeight: FontWeight.w400),
                                      items: AppConfig.flowModelOptions.entries.map((e) => DropdownMenuItem(value: e.value, child: Text(e.value, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w400)))).toList(),
                                      onChanged: (val) { if (val != null) { setState(() => selectedModel = val); _savePreferences(); } },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: Colors.purple.shade50, border: Border.all(color: Colors.purple.shade200), borderRadius: BorderRadius.circular(6)),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.star, size: 12, color: Colors.purple.shade400),
                                      const SizedBox(width: 4),
                                      DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          value: selectedAccountType,
                                          isDense: true,
                                          style: GoogleFonts.inter(fontSize: 12, color: Colors.purple.shade700, fontWeight: FontWeight.w400),
                                          items: [
                                            DropdownMenuItem(value: 'free', child: Text('Free', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400))),
                                            DropdownMenuItem(value: 'ai_pro', child: Text('AI Pro', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400))),
                                            DropdownMenuItem(value: 'ai_ultra', child: Text('AI Ultra (25,000 cr)', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400))),
                                          ],
                                          onChanged: (val) { if (val != null) { setState(() => selectedAccountType = val); _savePreferences(); } },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              // When COLLAPSED: Show inline status counters
                              if (!_isControlPanelExpanded) ...[
                                // Compact status counters in one row
                                _buildCompactStatus(scenes.length, 'TOTAL', Colors.blue),
                                const SizedBox(width: 12),
                                _buildCompactStatus(completed, 'DONE', Colors.green),
                                const SizedBox(width: 12),
                                _buildCompactStatus(active, 'ACTIVE', Colors.orange),
                                const SizedBox(width: 12),
                                _buildCompactStatus(failed, 'FAILED', Colors.red),
                              ],
                              const Spacer(),
                              // Collapse/Expand button (horizontal style like before)
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_isControlPanelExpanded ? 'Collapse' : 'Expand', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                                    const SizedBox(width: 4),
                                    Icon(_isControlPanelExpanded ? Icons.expand_less : Icons.expand_more, size: 18, color: Colors.grey.shade600),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // EXPANDED CONTENT
                      if (_isControlPanelExpanded)
                        Container(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          child: Column(
                            children: [
                              // Settings Row
                              IntrinsicHeight(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    // LEFT: Ratio, Model, Account
                                    Expanded(
                                      flex: 6,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              _buildCompactI2VButton('First Frames', Icons.image_outlined, _importBulkFirstFrames),
                                              const SizedBox(width: 12),
                                              _buildCompactI2VButton('Last Frames', Icons.image, _importBulkLastFrames),
                                              const SizedBox(width: 16),
                                              if (isUpscaling)
                                                TextButton.icon(onPressed: _stopUpscale, icon: const Icon(Icons.stop_circle, size: 14, color: Colors.red), label: const Text('Stop Upscale', style: TextStyle(color: Colors.red, fontSize: 11)))
                                              else
                                                // Upscale buttons group
                                                Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    // Label
                                                    Text('Upscale:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.grey.shade700)),
                                                    const SizedBox(width: 6),
                                                    // 1080p Button
                                                    InkWell(
                                                      onTap: () => _bulkUpscale(resolution: '1080p'),
                                                      borderRadius: BorderRadius.circular(6),
                                                      child: Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                                        decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.blue.shade400, Colors.blue.shade600]), borderRadius: BorderRadius.circular(6)),
                                                        child: const Text('1080p', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 4),
                                                    // 4K Button
                                                    InkWell(
                                                      onTap: () => _bulkUpscale(resolution: '4K'),
                                                      borderRadius: BorderRadius.circular(6),
                                                      child: Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                                        decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.purple.shade400, Colors.purple.shade600]), borderRadius: BorderRadius.circular(6)),
                                                        child: const Text('4K', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              _buildControlBtn(Icons.play_arrow, 'Start', Colors.blue, !isRunning ? _startGeneration : null),
                                              const SizedBox(width: 6),
                                              _buildControlBtn(Icons.pause, 'Pause', Colors.grey, isRunning && !isPaused ? _pauseGeneration : null),
                                              const SizedBox(width: 6),
                                              _buildControlBtn(Icons.stop, 'Stop', Colors.red, isRunning ? _stopGeneration : null),
                                              const SizedBox(width: 6),
                                              _buildControlBtn(Icons.refresh, 'Retry', Colors.orange, _retryFailed),
                                              const SizedBox(width: 6),
                                              // Resume Polling button - always visible, enabled when there are pending polls
                                              _buildControlBtn(
                                                Icons.sync, 
                                                VideoGenerationService().hasPendingPolls 
                                                  ? 'Resume (${VideoGenerationService().pendingPollsCount})' 
                                                  : 'Resume', 
                                                Colors.purple, 
                                                (!isRunning && VideoGenerationService().hasPendingPolls) ? _resumePolling : null
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(6)),
                                                child: DropdownButtonHideUnderline(
                                                  child: DropdownButton<int>(
                                                    value: selectedOutputCount,
                                                    isDense: true,
                                                    style: GoogleFonts.inter(fontSize: 12, color: Colors.black87, fontWeight: FontWeight.w400),
                                                    items: [1, 2, 4].map((count) => DropdownMenuItem(value: count, child: Text('$count', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400)))).toList(),
                                                    onChanged: (val) { if (val != null) { setState(() => selectedOutputCount = val); _savePreferences(); } },
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              Text('From:', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                              const SizedBox(width: 6),
                                              SizedBox(
                                                width: 50,
                                                child: TextField(
                                                  controller: _fromIndexController,
                                                  keyboardType: TextInputType.number,
                                                  style: const TextStyle(fontSize: 12),
                                                  decoration: InputDecoration(isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)), contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                                                  onChanged: (v) { final p = int.tryParse(v); if (p != null && p > 0) setState(() => fromIndex = p); },
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text('To:', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                              const SizedBox(width: 6),
                                              SizedBox(
                                                width: 50,
                                                child: TextField(
                                                  controller: _toIndexController,
                                                  keyboardType: TextInputType.number,
                                                  style: const TextStyle(fontSize: 12),
                                                  decoration: InputDecoration(isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)), contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                                                  onChanged: (v) { final p = int.tryParse(v); if (p != null && p > 0) setState(() => toIndex = p); },
                                                ),
                                              ),
                                              const SizedBox(width: 16),
                                              // Generation Mode Toggle (Normal vs 10x Boost)
                                              // Generation Mode Toggle (Smart Switch)
                                              MouseRegion(
                                                cursor: SystemMouseCursors.click,
                                                child: GestureDetector(
                                                  onTap: () {
                                                    setState(() => use10xBoostMode = !use10xBoostMode);
                                                    _savePreferences();
                                                  },
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        '10x Boost',
                                                        style: GoogleFonts.inter(
                                                          fontSize: 12, 
                                                          fontWeight: FontWeight.w600,
                                                          color: use10xBoostMode ? Colors.deepOrange.shade600 : Colors.grey.shade600,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      AnimatedContainer(
                                                        duration: const Duration(milliseconds: 300),
                                                        curve: Curves.easeInOut,
                                                        width: 46,
                                                        height: 24,
                                                        padding: const EdgeInsets.all(2),
                                                        decoration: BoxDecoration(
                                                          borderRadius: BorderRadius.circular(20),
                                                          gradient: use10xBoostMode
                                                              ? LinearGradient(
                                                                  colors: [Colors.orange.shade400, Colors.deepOrange.shade600],
                                                                  begin: Alignment.topLeft,
                                                                  end: Alignment.bottomRight,
                                                                )
                                                              : null,
                                                          color: use10xBoostMode ? null : Colors.grey.shade300,
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: (use10xBoostMode ? Colors.orange : Colors.grey).withOpacity(0.3),
                                                              blurRadius: 4,
                                                              offset: const Offset(0, 2),
                                                            ),
                                                          ],
                                                        ),
                                                        child: AnimatedAlign(
                                                          duration: const Duration(milliseconds: 300),
                                                          curve: Curves.elasticOut,
                                                          alignment: use10xBoostMode ? Alignment.centerRight : Alignment.centerLeft,
                                                          child: Container(
                                                            width: 20,
                                                            height: 20,
                                                            decoration: BoxDecoration(
                                                              shape: BoxShape.circle,
                                                              color: Colors.white,
                                                              boxShadow: [
                                                                BoxShadow(
                                                                  color: Colors.black.withOpacity(0.15),
                                                                  blurRadius: 3,
                                                                  offset: const Offset(0, 1),
                                                                ),
                                                              ],
                                                            ),
                                                            child: Center(
                                                              child: AnimatedSwitcher(
                                                                duration: const Duration(milliseconds: 200),
                                                                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                                                                child: Icon(
                                                                  use10xBoostMode ? Icons.rocket_launch_rounded : Icons.circle_outlined,
                                                                  key: ValueKey(use10xBoostMode),
                                                                  size: 12,
                                                                  color: use10xBoostMode ? Colors.deepOrange.shade500 : Colors.grey.shade500,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(width: 1, color: Colors.grey.shade200, margin: const EdgeInsets.symmetric(horizontal: 16)),
                                    // MIDDLE: Multi-Browser Section
                                    Expanded(
                                      flex: 4,
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade200)),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text('MULTI-BROWSER', style: TextStyle(fontSize: 10, color: Colors.grey.shade500, letterSpacing: 0.5, fontWeight: FontWeight.bold)),
                                                const Spacer(),
                                                if (_profileManager != null && _profileManager!.countConnectedProfiles() > 0)
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                    decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(10)),
                                                    child: Text('${_profileManager!.countConnectedProfiles()} active', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.green.shade800)),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Expanded(
                                              child: CompactProfileManagerWidget(
                                                profileManager: _profileManager,
                                                onLogin: _handleLogin,
                                                onLoginAll: _handleLoginAll,
                                                onConnectOpened: _handleConnectOpened,
                                                onOpenWithoutLogin: _handleOpenWithoutLogin,
                                                onStop: _handleStopLogin,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),

                                    // In-App Browser section removed from desktop view
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              // QUICK GENERATION ROW
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _quickPromptController,
                                      decoration: InputDecoration(
                                        hintText: 'Quick prompt... e.g. A cyberpunk city in rain',
                                        hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
                                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                        isDense: true,
                                      ),
                                      onSubmitted: (value) => _handleQuickGenerate(),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton.icon(
                                    onPressed: _handleQuickGenerate,
                                    icon: const Icon(Icons.auto_awesome, size: 16),
                                    label: const Text('Generate'),
                                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF22C55E), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                                  ),
                                  const SizedBox(width: 12),
                                  TextButton.icon(onPressed: _confirmClearAllScenes, icon: Icon(Icons.delete_outline, size: 14, color: Colors.red.shade400), label: Text('Clear', style: TextStyle(color: Colors.red.shade400, fontSize: 11))),
                                  const SizedBox(width: 8),
                                  TextButton.icon(
                                    onPressed: _exportAllVideos,
                                    icon: const Icon(Icons.download, size: 14, color: Colors.blue),
                                    label: const Text('Export', style: TextStyle(color: Colors.blue, fontSize: 11)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // RIGHT: STATUS SECTION (only when expanded)
                if (_isControlPanelExpanded)
                  Container(
                    width: 140,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.grey.shade50, border: Border(left: BorderSide(color: Colors.grey.shade200))),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text('STATUS', style: TextStyle(fontSize: 10, color: Colors.grey.shade500, letterSpacing: 0.5, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [_buildStatItem('TOTAL', scenes.length, Colors.blue), _buildStatItem('DONE', completed, Colors.green)]),
                        const SizedBox(height: 8),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [_buildStatItem('ACTIVE', active, Colors.orange), _buildStatItem('FAILED', failed, Colors.red)]),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // SCENE CARDS GRID
          Expanded(
            child: scenes.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.video_library_outlined, size: 64, color: Colors.grey.shade300), const SizedBox(height: 16), Text('Generated scenes will appear here', style: TextStyle(color: Colors.grey.shade500))]))
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 300, childAspectRatio: 1.10, crossAxisSpacing: 12, mainAxisSpacing: 12),
                  itemCount: scenes.length,
                  itemBuilder: (context, index) {
                    final scene = scenes[index];
                    return SceneCard(
                      key: ValueKey('${scene.sceneId}_${scene.status}_${scene.videoPath ?? ""}'),
                      scene: scene,
                      onPromptChanged: (newPrompt) => setState(() => scene.prompt = newPrompt),
                      onPickImage: (frameType) => _pickImageForScene(scene, frameType),
                      onClearImage: (frameType) => _clearImageForScene(scene, frameType),
                      onGenerate: () => _startSingleSceneGeneration(scene),
                      onOpen: () => _openVideo(scene),
                      onOpenFolder: (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ? () => _openVideoFolder(scene) : null,
                      onDelete: () => setState(() => scenes.removeAt(index)),
                      onUpscale: scene.status == 'completed' ? (resolution) { _upscaleScene(scene, resolution: resolution); } : null,
                      onStopUpscale: scene.status == 'completed' ? () { if (['upscaling', 'polling', 'downloading'].contains(scene.upscaleStatus)) { setState(() { scene.upscaleStatus = 'failed'; scene.error = 'Stopped by user'; }); } } : null,
                      showThumbnails: _showVideoThumbnails,
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }

  // Helper widgets for redesigned layout
  Widget _buildNavTab(String label, IconData icon, int index, bool isActive) {
    Color accentColor = Colors.blue;
    if (index == 2) accentColor = const Color(0xFF0D9488); // teal for MASTERING
    if (index == 3) accentColor = const Color(0xFF8B5CF6); // purple for REELS
    if (index == 4) accentColor = const Color(0xFFF59E0B); // orange for AUDIO
    if (index == 5) accentColor = const Color(0xFF10B981); // green for EXPORT
    if (index == 10) accentColor = Colors.pink; // pink for CLONE YOUTUBE
    
    final isCurrentTab = _currentNavIndex == index;
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => _navigateToTab(index),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isCurrentTab ? accentColor.withOpacity(0.1) : Colors.transparent,
                  border: Border.all(color: isCurrentTab ? Colors.transparent : Colors.grey.shade300, width: 1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 20, color: isCurrentTab ? accentColor : Colors.grey.shade600),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isCurrentTab ? FontWeight.w600 : FontWeight.w500,
                  color: isCurrentTab ? accentColor : Colors.grey.shade600,
                  letterSpacing: 0.3,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigateToTab(int index) async {
    if (_currentNavIndex == index) return; // Already on this tab
    
    // Special handling for Mastering tab (index 2) - launch as separate process
    if (index == 2) {
      // Check if mastering is actually running by checking marker file
      final masteringRunningFile = File(path.join(Directory.systemTemp.path, 'veo3_mastering_running.marker'));
      if (await masteringRunningFile.exists()) {
        // Check if marker is stale (older than 5 minutes = likely from a crash)
        try {
          final stat = await masteringRunningFile.stat();
          final age = DateTime.now().difference(stat.modified);
          if (age.inMinutes > 5) {
            // Stale marker file - delete it and proceed
            await masteringRunningFile.delete();
            print('[Main] Deleted stale mastering marker file (age: ${age.inMinutes} min)');
          } else {
            _showMasteringAlreadyOpenDialog();
            return;
          }
        } catch (e) {
          // If we can't check, just proceed
          print('[Main] Error checking marker file: $e');
        }
      }
      
      // Show launching dialog
      _showMasteringLaunchingDialog();
      return;
    }
    
    setState(() {
      _isPageLoading = true;
      _currentNavIndex = index;
    });
    
    // Simulate loading delay for smooth transition
    await Future.delayed(const Duration(milliseconds: 300));
    
    if (mounted) {
      setState(() {
        _isPageLoading = false;
      });
    }
  }
  
  /// Show notification while mastering is launching
  void _showMasteringLaunchingDialog() async {
    // Show a snackbar that auto-dismisses
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 16),
            Text('Opening Mastering in new window...', style: GoogleFonts.inter()),
          ],
        ),
        backgroundColor: Colors.blue.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
    
    // Launch mastering
    await _launchMasteringProcess();
  }
  
  /// Show dialog when mastering is already open
  void _showMasteringAlreadyOpenDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.video_settings, color: Colors.blue.shade600),
            const SizedBox(width: 8),
            const Text('Mastering Already Open'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('The Mastering screen is already open in a separate window.'),
            SizedBox(height: 12),
            Text(
              'Check your taskbar for the Mastering window.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // Delete the marker file
              try {
                final masteringRunningFile = File(path.join(Directory.systemTemp.path, 'veo3_mastering_running.marker'));
                if (await masteringRunningFile.exists()) {
                  await masteringRunningFile.delete();
                }
              } catch (_) {}
              // Reset state and launch new window
              setState(() => _isMasteringOpen = false);
              _showMasteringLaunchingDialog();
            },
            child: const Text('Open New Window'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
  
  /// Launch Video Mastering as a separate process/window
  Future<void> _launchMasteringProcess() async {
    try {
      final exePath = Platform.resolvedExecutable;
      print('[Main] Launching mastering from: $exePath');
      
      // Write a flag file that the new process will detect
      final masteringFlagFile = File(path.join(Directory.systemTemp.path, 'veo3_mastering_mode.flag'));
      await masteringFlagFile.writeAsString(''); // Empty = no data file
      print('[Main] Created mastering flag file: ${masteringFlagFile.path}');
      
      // Launch the app (it will detect the flag file and open in mastering mode)
      if (Platform.isWindows) {
        // Use PowerShell Start-Process for better path handling with spaces
        final result = await Process.run(
          'powershell',
          ['-Command', 'Start-Process', '-FilePath', '"$exePath"'],
          runInShell: true,
        );
        print('[Main] Mastering launched via PowerShell Start-Process (exit: ${result.exitCode})');
      } else {
        await Process.start(
          exePath,
          [],
          mode: ProcessStartMode.detached,
        );
      }
      
      if (mounted) {
        setState(() => _isMasteringOpen = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mastering opened in new window'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[Main] Failed to launch mastering: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not launch mastering: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Launch Application Logs as a separate process/window
  Future<void> _launchLogsProcess() async {
    try {
      final exePath = Platform.resolvedExecutable;
      print('[Main] Launching logs viewer from: $exePath');
      
      // Write a flag file that the new process will detect
      final logsFlagFile = File(path.join(Directory.systemTemp.path, 'veo3_logs_mode.flag'));
      
      // Ensure the file is created and flushed
      logsFlagFile.writeAsStringSync('logs'); // Write something to ensure file exists
      print('[Main] Created logs flag file: ${logsFlagFile.path}');
      print('[Main] Flag file exists: ${logsFlagFile.existsSync()}');
      
      // Small delay to ensure file system flush
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Launch the app (it will detect the flag file and open in logs mode)
      if (Platform.isWindows) {
        // Use PowerShell Start-Process for better path handling with spaces
        final result = await Process.run(
          'powershell',
          ['-Command', 'Start-Process', '-FilePath', '"$exePath"'],
          runInShell: true,
        );
        print('[Main] Logs viewer launched via PowerShell Start-Process (exit: ${result.exitCode})');
        if (result.exitCode != 0) {
          print('[Main] PowerShell stderr: ${result.stderr}');
          print('[Main] PowerShell stdout: ${result.stdout}');
        }
      } else {
        await Process.start(
          exePath,
          [],
          mode: ProcessStartMode.detached,
        );
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Logs opened in new window'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[Main] Failed to launch logs viewer: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not launch logs viewer: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }



  /// Get shimmer loading based on current tab
  Widget _buildShimmerLoading() {
    switch (_currentNavIndex) {
      case 0: return _buildHomeShimmer();
      case 1: return _buildSceneBuilderShimmer();
      case 2: return _buildMasteringShimmer();
      case 3: return _buildReelsShimmer();
      case 4: return _buildAudioVisualShimmer();
      case 5: return _buildExportShimmer();
      default: return _buildHomeShimmer();
    }
  }

  /// HOME: Grid of video cards
  Widget _buildHomeShimmer() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            color: Colors.white,
            child: Row(
              children: [
                _buildShimmerBox(120, 36),
                const SizedBox(width: 16),
                _buildShimmerBox(120, 36),
                const Spacer(),
                _buildShimmerBox(150, 36),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 300,
                  childAspectRatio: 1.1,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: 6,
                itemBuilder: (context, index) => _buildShimmerCard(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// SCENEBUILDER: Sidebar + Character cards + Form
  Widget _buildSceneBuilderShimmer() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Row(
        children: [
          // Left sidebar shimmer
          Container(
            width: 72,
            color: Colors.white,
            child: Column(
              children: [
                const SizedBox(height: 20),
                for (int i = 0; i < 4; i++) ...[_buildShimmerBox(48, 48), const SizedBox(height: 16)],
              ],
            ),
          ),
          // Main content
          Expanded(
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.white,
                  child: Row(
                    children: [
                      _buildShimmerBox(200, 32),
                      const Spacer(),
                      _buildShimmerBox(100, 36),
                      const SizedBox(width: 8),
                      _buildShimmerBox(100, 36),
                    ],
                  ),
                ),
                // Character cards row
                Container(
                  height: 120,
                  padding: const EdgeInsets.all(16),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: 5,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _buildShimmerBox(100, 100),
                    ),
                  ),
                ),
                // Form area
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildShimmerBox(double.infinity, 120),
                        const SizedBox(height: 16),
                        _buildShimmerBox(double.infinity, 80),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(child: _buildShimmerBox(double.infinity, 48)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildShimmerBox(double.infinity, 48)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// MASTERING: Timeline editor layout
  Widget _buildMasteringShimmer() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        children: [
          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF1E40AF),
            child: Row(
              children: [
                _buildShimmerBox(150, 28),
                const Spacer(),
                for (int i = 0; i < 4; i++) ...[_buildShimmerBox(36, 36), const SizedBox(width: 8)],
              ],
            ),
          ),
          // Preview + Properties
          Expanded(
            flex: 60,
            child: Row(
              children: [
                // Media browser
                Container(
                  width: 250,
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildShimmerBox(100, 20),
                      const SizedBox(height: 12),
                      for (int i = 0; i < 6; i++) ...[_buildShimmerBox(double.infinity, 60), const SizedBox(height: 8)],
                    ],
                  ),
                ),
                // Video preview - expanded shimmer to fill the area
                Expanded(
                  child: Container(
                    color: Colors.black87,
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: _buildShimmerBox(double.infinity, double.infinity),
                      ),
                    ),
                  ),
                ),
                // Properties panel
                Container(
                  width: 300,
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildShimmerBox(80, 20),
                      const SizedBox(height: 16),
                      _buildShimmerBox(double.infinity, 40),
                      const SizedBox(height: 12),
                      _buildShimmerBox(double.infinity, 40),
                      const SizedBox(height: 12),
                      _buildShimmerBox(double.infinity, 40),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Timeline
          Expanded(
            flex: 40,
            child: Container(
              color: const Color(0xFF1F2937),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildShimmerBox(100, 24),
                      const Spacer(),
                      _buildShimmerBox(60, 24),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(child: _buildShimmerBox(double.infinity, double.infinity)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// REELS: Reel creation interface
  Widget _buildReelsShimmer() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        children: [
          // AppBar shimmer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Theme.of(context).colorScheme.inversePrimary,
            child: Row(
              children: [
                _buildShimmerBox(200, 28),
                const Spacer(),
                _buildShimmerBox(36, 36),
              ],
            ),
          ),
          // Content
          Expanded(
            child: Row(
              children: [
                // Left panel - Audio list
                Container(
                  width: 300,
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildShimmerBox(150, 24),
                      const SizedBox(height: 16),
                      for (int i = 0; i < 5; i++) ...[_buildShimmerBox(double.infinity, 72), const SizedBox(height: 8)],
                    ],
                  ),
                ),
                // Center - Video preview
                Expanded(
                  child: Container(
                    color: Colors.grey.shade200,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildShimmerBox(280, 500),
                          const SizedBox(height: 16),
                          _buildShimmerBox(200, 40),
                        ],
                      ),
                    ),
                  ),
                ),
                // Right panel - Settings
                Container(
                  width: 280,
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildShimmerBox(120, 24),
                      const SizedBox(height: 16),
                      _buildShimmerBox(double.infinity, 48),
                      const SizedBox(height: 12),
                      _buildShimmerBox(double.infinity, 48),
                      const SizedBox(height: 24),
                      _buildShimmerBox(double.infinity, 44),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// AUDIO VISUAL: Audio matching interface
  Widget _buildAudioVisualShimmer() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        children: [
          // AppBar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Theme.of(context).colorScheme.inversePrimary,
            child: Row(
              children: [
                _buildShimmerBox(180, 28),
                const Spacer(),
                _buildShimmerBox(36, 36),
              ],
            ),
          ),
          // Content - Two column layout
          Expanded(
            child: Row(
              children: [
                // Left - Video list
                Expanded(
                  child: Container(
                    color: Colors.white,
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildShimmerBox(120, 24),
                        const SizedBox(height: 16),
                        Expanded(
                          child: GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              childAspectRatio: 16/9,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: 6,
                            itemBuilder: (_, i) => _buildShimmerBox(double.infinity, double.infinity),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Right - Audio controls
                Container(
                  width: 350,
                  color: Colors.white,
                  margin: const EdgeInsets.only(top: 16, right: 16, bottom: 16),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildShimmerBox(100, 24),
                      const SizedBox(height: 16),
                      _buildShimmerBox(double.infinity, 60),
                      const SizedBox(height: 16),
                      _buildShimmerBox(double.infinity, 100),
                      const Spacer(),
                      _buildShimmerBox(double.infinity, 48),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// EXPORT: Clips manager layout
  Widget _buildExportShimmer() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        children: [
          // Header with actions
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Row(
              children: [
                _buildShimmerBox(150, 32),
                const Spacer(),
                _buildShimmerBox(120, 40),
                const SizedBox(width: 8),
                _buildShimmerBox(120, 40),
                const SizedBox(width: 8),
                _buildShimmerBox(100, 40),
              ],
            ),
          ),
          // Clips list
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (int i = 0; i < 5; i++) ...[  
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          _buildShimmerBox(80, 45),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildShimmerBox(200, 16),
                                const SizedBox(height: 4),
                                _buildShimmerBox(100, 14),
                              ],
                            ),
                          ),
                          _buildShimmerBox(60, 24),
                          const SizedBox(width: 8),
                          _buildShimmerBox(32, 32),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          // Bottom export button
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _buildShimmerBox(150, 48),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmerBox(double width, double height) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + value * 2, 0),
              end: Alignment(1.0 + value * 2, 0),
              colors: [
                Colors.grey.shade200,
                Colors.grey.shade100,
                Colors.grey.shade200,
              ],
            ),
          ),
        );
      },
      onEnd: () {},
    );
  }

  Widget _buildShimmerCard() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 1000),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Image placeholder
              Container(
                height: 100,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  gradient: LinearGradient(
                    begin: Alignment(-1.0 + value * 2, 0),
                    end: Alignment(1.0 + value * 2, 0),
                    colors: [
                      Colors.grey.shade200,
                      Colors.grey.shade100,
                      Colors.grey.shade200,
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(
                          begin: Alignment(-1.0 + value * 2, 0),
                          end: Alignment(1.0 + value * 2, 0),
                          colors: [
                            Colors.grey.shade200,
                            Colors.grey.shade100,
                            Colors.grey.shade200,
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 14,
                      width: 100,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(
                          begin: Alignment(-1.0 + value * 2, 0),
                          end: Alignment(1.0 + value * 2, 0),
                          colors: [
                            Colors.grey.shade200,
                            Colors.grey.shade100,
                            Colors.grey.shade200,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPageContent() {
    if (_isPageLoading) {
      return _buildShimmerLoading();
    }
    
    // Use IndexedStack to keep all tabs alive and preserve their state
    // This prevents widgets from being destroyed/recreated when switching tabs
    return IndexedStack(
      index: _currentNavIndex,
      children: [
        // Index 0: Home
        _buildHomeContent(),
        
        // Index 1: Character Studio (SceneBuilder)
        CharacterStudioScreen(
          projectService: widget.projectService,
          isActivated: widget.isActivated,
          profileManager: _profileManager,
          loginService: _loginService,
          embedded: true,
          onAddToVideoGen: (result) {
            if (result['action'] == 'add_to_video_gen') {
              final sceneId = result['sceneId'] as int? ?? (scenes.length + 1);
              final imagePath = result['imagePath'] as String?;
              final prompt = result['prompt'] as String? ?? '';
              if (imagePath != null && prompt.isNotEmpty) {
                setState(() {
                  scenes.add(SceneData(sceneId: sceneId, prompt: prompt, status: 'queued', firstFramePath: imagePath));
                  toIndex = scenes.length;
                  _toIndexController.text = toIndex.toString();
                  _currentNavIndex = 0; // Go back to home after adding
                });
                _savePromptsToProject();
              }
            } else if (result['action'] == 'add_to_mastering') {
              // Navigate to Mastering tab with clips and full JSON
              final clips = result['clips'] as List<Map<String, dynamic>>?;
              final bgMusicPrompt = result['bgMusicPrompt'] as String?;
              final fullJson = result['fullJson'] as Map<String, dynamic>?;
              
              print('[Main] Received add_to_mastering action with ${clips?.length ?? 0} clips');
              
              // Set the clips for ONE-TIME loading, then navigate
              // After the mastering screen loads them, they'll be persisted in the saved project
              setState(() {
                _masteringInitialClips = clips;
                _masteringBgMusicPrompt = bgMusicPrompt;
                _masteringFullProjectJson = fullJson;
                _currentNavIndex = 2; // Navigate to Mastering tab
              });
              
              print('[Main] State updated - navigating to index 2 (Mastering)');
              
              // Clear the initial clips after a short delay to prevent reloading on tab switch
              // The clips will persist via the saved project file
              Future.delayed(const Duration(milliseconds: 1500), () {
                if (mounted) {
                  setState(() {
                    _masteringInitialClips = null;
                    _masteringBgMusicPrompt = null;
                    _masteringFullProjectJson = null;
                  });
                  print('[Main] Cleared initial clips state - clips now persisted in saved project');
                }
              });
            }
          },
        ),
        
        // Index 2: Video Mastering - Shows launching animation
        // This is briefly shown while mastering window is launching
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1E1E2E),
                Colors.blue.shade900,
              ],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _isMasteringLaunching 
                      ? 'Opening Mastering in new window...'
                      : 'Mastering opens in separate window',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'This keeps your main app running smoothly',
                  style: GoogleFonts.inter(
                    color: Colors.white54,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Index 3: Reel Special
        ReelSpecialScreen(
          projectService: widget.projectService,
          isActivated: widget.isActivated,
          profileManager: _profileManager,
          loginService: _loginService,
          email: '',
          password: '',
          selectedModel: selectedModel,
          selectedAccountType: selectedAccountType,
          embedded: true,
          onBack: () => setState(() => _currentNavIndex = 0),
        ),
        
        // Index 4: Story Audio
        StoryAudioScreen(
          projectService: widget.projectService,
          isActivated: widget.isActivated,
          profileManager: _profileManager,
          loginService: _loginService,
          email: '',
          password: '',
          selectedModel: selectedModel,
          selectedAccountType: selectedAccountType,
          storyAudioOnlyMode: true,
          embedded: true,
          onBack: () => setState(() => _currentNavIndex = 0),
        ),
        
        // Index 5: Export
        _buildExportPageContent(),
        
        // Index 6: Settings
        SettingsScreen(
          onBack: () => setState(() => _currentNavIndex = 0),
        ),
        
        // Index 7: AI Voice (Coming Soon)
        _buildAIVoicePage(),
        
        // Index 8: More Tools
        _buildMoreToolsPage(),
        
        // Index 9: Templates (Story Prompt Processor)
        TemplatesScreen(
          profileManager: _profileManager,
          loginService: _loginService,
        ),
        
        // Index 10: Clone YouTube
        const CloneYouTubeScreen(),
      ],
    );
  }
  
  Widget _buildAIVoicePage() {
    return const AIVoiceScreen();
  }
  
  Widget _buildMoreToolsPage() {
    return Container(
      color: const Color(0xFFF8F9FC),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.build, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('More Tools', style: GoogleFonts.inter(fontSize: 24, fontWeight: FontWeight.bold)),
                    Text('Powerful tools to supercharge your workflow', style: TextStyle(color: Colors.grey.shade500)),
                  ],
                ),
              ],
            ),
          ),
          // Grid - centered 80% width
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: FractionallySizedBox(
                widthFactor: 0.8,
                child: Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: GridView.count(
                    crossAxisCount: 4,
                    crossAxisSpacing: 20,
                    mainAxisSpacing: 20,
                    childAspectRatio: 1.0,
                    shrinkWrap: true,
                    children: [
                      // Voice Clone - HOT
                      _buildImageToolCard(
                        name: 'Voice Clone',
                        desc: 'Clone any voice with AI technology',
                        imagePath: 'assets/voice_clone_icon.png',
                        tag: 'HOT',
                        tagColor: Colors.red,
                        gradientColors: [Colors.purple.shade600, Colors.blue.shade600],
                      ),
                      // Boring Story Videos
                      _buildImageToolCard(
                        name: 'Boring Story Videos',
                        desc: 'Auto-generate story format videos',
                        imagePath: 'assets/story_video_icon.png',
                        tag: null,
                        tagColor: null,
                        gradientColors: [Colors.orange.shade600, Colors.amber.shade600],
                      ),
                      // Bulk Reel Uploader
                      _buildImageToolCard(
                        name: 'Bulk Reel Uploader',
                        desc: 'Upload to YouTube, TikTok, Facebook',
                        imagePath: 'assets/bulk_uploader_icon.png',
                        tag: 'NEW',
                        tagColor: Colors.green,
                        gradientColors: [Colors.teal.shade600, Colors.green.shade600],
                      ),
                      // Bulk Video Downloader
                      _buildImageToolCard(
                        name: 'Bulk Video Downloader',
                        desc: 'Download from TikTok, YouTube, Facebook',
                        imagePath: 'assets/video_downloader_icon.png',
                        tag: null,
                        tagColor: null,
                        gradientColors: [Colors.red.shade600, Colors.blue.shade600],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildImageToolCard({
    required String name,
    required String desc,
    required String imagePath,
    String? tag,
    Color? tagColor,
    required List<Color> gradientColors,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$name - Coming Soon!'), duration: const Duration(seconds: 1)),
          );
        },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [gradientColors[0].withOpacity(0.9), gradientColors[1].withOpacity(0.9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(color: gradientColors[0].withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8)),
            ],
          ),
          child: Stack(
            children: [
              // Background pattern
              Positioned(
                right: -20,
                bottom: -20,
                child: Opacity(
                  opacity: 0.1,
                  child: Icon(Icons.auto_awesome, size: 120, color: Colors.white),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Image
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 4))],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          imagePath,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: Colors.white24,
                            child: const Icon(Icons.image, color: Colors.white54, size: 40),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(name, style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 6),
                    Text(desc, style: TextStyle(fontSize: 12, color: Colors.white70)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Coming Soon', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 12)),
                          SizedBox(width: 4),
                          Icon(Icons.arrow_forward, size: 14, color: Colors.white),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (tag != null)
                Positioned(
                  top: 16,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: tagColor ?? Colors.grey,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 6)],
                    ),
                    child: Text(tag, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReelsPageContent() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.movie, size: 64, color: Color(0xFF8B5CF6)),
          ),
          const SizedBox(height: 24),
          const Text('Reels Studio', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Create engaging short-form content', style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _openReelSpecial,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open Reels Editor'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioPageContent() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.music_note, size: 64, color: Color(0xFFF59E0B)),
          ),
          const SizedBox(height: 24),
          const Text('Audio Studio', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Generate music and voiceovers', style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _openStoryAudio,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open Audio Editor'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExportPageContent() {
    // Embed VideoClipsManager directly for seamless experience
    return Container(
      color: const Color(0xFFF8F9FC),
      child: VideoClipsManager(
        initialFiles: const [],
        exportFolder: outputFolder,
        embedded: true,
        onExport: (files) async {
          // Show export settings dialog directly
          await _showExportSettings(files);
        },
      ),
    );
  }

  Widget _buildSidebarSection(String title, List<Widget> items) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade500,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ...items,
        ],
      ),
    );
  }

  Widget _buildSidebarItem(IconData icon, String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: Colors.grey.shade600),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarItemHighlighted(IconData icon, String label, VoidCallback? onTap, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: const Color(0xFFA16207)),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFA16207),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRatioToggle(String label, bool isSelected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: isSelected ? Colors.white : Colors.grey.shade700)),
      ),
    );
  }

  Widget _buildControlBtn(IconData icon, String label, Color color, VoidCallback? onTap) {
    // Special handling for Start button - make it green
    final bool isStartButton = label == 'Start';
    final Color buttonColor = isStartButton ? Colors.green : color;
    
    // Change Start button appearance when running
    final bool isRunningState = isStartButton && isRunning;
    final IconData displayIcon = isRunningState ? Icons.play_circle : icon;
    final Color displayColor = isRunningState ? Colors.green.shade700 : buttonColor;
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: onTap != null ? displayColor.withOpacity(0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(displayIcon, size: 16, color: onTap != null ? displayColor : Colors.grey),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: onTap != null ? displayColor : Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, int value, Color color) {
    return Column(
      children: [
        Text(value.toString(), style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
      ],
    );
  }

  // Compact status item for collapsed control panel
  Widget _buildCompactStatus(int value, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildMiniStat(String label, int value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$value', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 10, color: color.withOpacity(0.8))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCompactI2VButton(String title, IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.blue.shade200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.blue.shade600),
            const SizedBox(width: 6),
            Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.blue.shade700)),
          ],
        ),
      ),
    );
  }

  Widget _buildI2VCard(String title, IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200, style: BorderStyle.solid),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text(title, style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
            Text('Drag & drop or click to upload', style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
          ],
        ),
      ),
    );
  }

  void _handleQuickGenerate() {
    final prompt = _quickPromptController.text.trim();
    if (prompt.isNotEmpty) {
      final newSceneIndex = scenes.length + 1;
      setState(() {
        scenes.add(SceneData(sceneId: DateTime.now().millisecondsSinceEpoch, prompt: prompt));
        _quickPromptController.clear();
        toIndex = scenes.length;
        if (!isRunning) fromIndex = newSceneIndex;
      });
      if (!isRunning) _startGeneration();
    }
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
                          profileManager: _profileManager,
                          loginService: _loginService,
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

  /// Upscale a single video to 1080p or 4K
  /// resolution: '1080p' or '4K'
  Future<void> _upscaleScene(SceneData scene, {String resolution = '1080p', int retryCount = 0}) async {
    print('[UPSCALE SINGLE] ========== STARTING ==========');
    print('[UPSCALE SINGLE] Scene ${scene.sceneId}');
    print('[UPSCALE SINGLE] Resolution: $resolution');
    print('[UPSCALE SINGLE] videoMediaId: ${scene.videoMediaId}');
    print('[UPSCALE SINGLE] operationName: ${scene.operationName}');
    print('[UPSCALE SINGLE] downloadUrl: ${scene.downloadUrl}');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[UPSCALE] Starting single scene ${scene.sceneId} at $resolution');
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
    
    print('[UPSCALE] Starting upscale for scene ${scene.sceneId} at $resolution');
    print('[UPSCALE] videoMediaId: $videoMediaId');
    print('[UPSCALE] videoMediaId length: ${videoMediaId.length}');
    mobileLog('[UPSCALE] Starting scene ${scene.sceneId} at $resolution...');
    mobileLog('[UPSCALE] MediaId: ${videoMediaId.length > 30 ? videoMediaId.substring(0, 30) + '...' : videoMediaId}');
    mobileLog('[UPSCALE] Sending request...');
    
    try {
      // Use the scene's aspect ratio if stored, otherwise use global
      // Videos generated in portrait mode need portrait aspect ratio for upscaling
      final videoAspectRatio = scene.aspectRatio ?? selectedAspectRatio;
      
      // Convert resolution string to API format
      final apiResolution = resolution == '4K' ? 'VIDEO_RESOLUTION_4K' : 'VIDEO_RESOLUTION_1080P';
      
      print('[UPSCALE] Using aspect ratio: $videoAspectRatio (scene stored: ${scene.aspectRatio}, global: $selectedAspectRatio)');
      print('[UPSCALE] Using resolution: $apiResolution');
      mobileLog('[UPSCALE] AspectRatio: $videoAspectRatio, Resolution: $resolution');
      
      // Add 2-second delay before request (like video generation)
      await Future.delayed(const Duration(seconds: 2));
      
      final result = await uploadGenerator.upscaleVideo(
        videoMediaId: videoMediaId,
        accessToken: uploadToken,
        aspectRatio: videoAspectRatio,
        resolution: apiResolution,
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
          await _pollUpscaleCompletion(scene, scene.upscaleOperationName!, scene.upscaleOperationName!, uploadGenerator, uploadToken!, resolution: resolution);
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
              scene.consecutive403Count = 0; // Reset on success
            });
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Upscale started for scene ${scene.sceneId}. Polling...'), backgroundColor: Colors.blue),
            );
            
            // Start polling for upscale completion
            await _pollUpscaleCompletion(scene, opName, sceneUuid, uploadGenerator, uploadToken!, resolution: resolution);
          } else {
            print('[UPSCALE] ⚠ No operation name found in response');
            print('[UPSCALE] Operations count: ${(data['operations'] as List).length}');
            mobileLog('[UPSCALE] ⚠ No opName in response');
            throw Exception('No operation name found in response');
          }
        } else {
          print('[UPSCALE] ⚠ No operations in response');
          mobileLog('[UPSCALE] ⚠ Empty operations');
          throw Exception('No operations in upscale response');
        }
      } else {
        // Check status code from result
        final statusCode = result?['status'] as int?;
        final errorMsg = result?['error']?.toString() ?? 'Unknown error';
        
        // Check for 429 error (rate limit)
        if (statusCode == 429 || errorMsg.contains('429') || errorMsg.toLowerCase().contains('rate limit')) {
          if (retryCount < 5) {
            print('[UPSCALE] ⚠ Rate limit (429) - waiting 30s before retry ${retryCount + 1}/5...');
            mobileLog('[UPSCALE] ⚠ Rate limit - retry ${retryCount + 1}/5 in 30s...');
            
            // Actually wait 30 seconds
            await Future.delayed(const Duration(seconds: 30));
            
            // Retry with incremented counter
            print('[UPSCALE] Retrying after rate limit cooldown (attempt ${retryCount + 1})...');
            mobileLog('[UPSCALE] Retry ${retryCount + 1}/5...');
            return _upscaleScene(scene, resolution: resolution, retryCount: retryCount + 1);
          } else {
            print('[UPSCALE] ✗ Max retries (5) exceeded for 429 error');
            mobileLog('[UPSCALE] ✗ Max retries exceeded');
            setState(() {
              scene.upscaleStatus = 'failed';
              scene.error = 'Rate limit - max retries exceeded';
            });
            return;
          }
        }
        
        // Check for 403 error (authentication issue)
        if (statusCode == 403) {
          if (retryCount < 5) {
            // Count consecutive 403 errors
            final consecutive403s = (scene.consecutive403Count ?? 0) + 1;
            scene.consecutive403Count = consecutive403s;
            
            print('[UPSCALE] ⚠ 403 error #$consecutive403s for scene ${scene.sceneId} (retry ${retryCount + 1}/5)');
            mobileLog('[UPSCALE] ⚠ 403 error #$consecutive403s');
            
            // Trigger relogin after 3 consecutive 403s
            if (consecutive403s >= 3) {
              print('[UPSCALE] ⚠ 3 consecutive 403s - triggering auto-relogin...');
              mobileLog('[UPSCALE] ⚠ Auto-relogin triggered');
              
              // Trigger relogin based on platform
              if (Platform.isAndroid || Platform.isIOS) {
                final service = MobileBrowserService();
                final profile = service.profiles.firstWhere(
                  (p) => p.generator == uploadGenerator,
                  orElse: () => service.profiles.first,
                );
                
                print('[UPSCALE] Auto-relogging ${profile.name}...');
                await service.autoReloginProfile(
                  profile,
                  email: '',
                  password: '',
                  onSuccess: () {
                    print('[UPSCALE] ✓ Relogin successful');
                    scene.consecutive403Count = 0; // Reset on successful relogin
                  },
                );
                
                // Wait 5 seconds for relogin to complete
                await Future.delayed(const Duration(seconds: 5));
                
              } else if (_profileManager != null) {
                // Desktop multi-profile relogin
                print('[UPSCALE] Triggering desktop relogin...');
                // Relogin will happen in background
                await Future.delayed(const Duration(seconds: 5));
                scene.consecutive403Count = 0;
              }
            }
            
            // Always retry (even if no relogin triggered yet)
            print('[UPSCALE] Retrying with attempt ${retryCount + 1}/5...');
            mobileLog('[UPSCALE] Retry ${retryCount + 1}/5...');
            
            // Small delay before retry
            await Future.delayed(const Duration(seconds: 2));
            
            return _upscaleScene(scene, resolution: resolution, retryCount: retryCount + 1);
          } else {
            print('[UPSCALE] ✗ Max retries (5) exceeded for 403 error');
            mobileLog('[UPSCALE] ✗ Max retries (403) exceeded');
            setState(() {
              scene.upscaleStatus = 'failed';
              scene.error = '403 error - max retries exceeded';
              scene.consecutive403Count = 0; // Reset for next attempt
            });
            return;
          }
        }
        
        // Other errors
        print('[UPSCALE] ✗ Request failed (status: $statusCode): $errorMsg');
        mobileLog('[UPSCALE] ✗ Failed: $errorMsg');
        setState(() {
          scene.upscaleStatus = 'failed';
          scene.error = errorMsg;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upscale failed: $errorMsg'), backgroundColor: Colors.red),
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
  /// resolution: '1080p' or '4K'
  Future<void> _pollUpscaleCompletion(
    SceneData scene,
    String operationName,
    String sceneUuid,
    dynamic generator,
    String accessToken, {
    String resolution = '1080p',
  }) async {
    print('[UPSCALE POLL] Starting poll for scene ${scene.sceneId}, operation: $operationName, resolution: $resolution');
    mobileLog('[UPSCALE] Polling started for scene ${scene.sceneId} at $resolution');
    
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
              
              // Download to "upscaled" subfolder in original video directory
              final originalPath = scene.videoPath ?? '';
              final originalDir = path.dirname(originalPath);
              final originalFilename = path.basenameWithoutExtension(originalPath);
              
              // Create upscaled folder
              final upscaledDir = path.join(originalDir, 'upscaled');
              await Directory(upscaledDir).create(recursive: true);
              
              // Save with resolution suffix in upscaled folder
              final resSuffix = resolution == '4K' ? '4K' : '1080p';
              final upscaledPath = path.join(upscaledDir, '${originalFilename}_$resSuffix.mp4');
              
              print('[UPSCALE] Saving to: $upscaledPath');
              mobileLog('[UPSCALE] Saving ${scene.sceneId} to $resSuffix...');
              await generator.downloadVideo(videoUrl, upscaledPath);
              
              setState(() {
                scene.upscaleVideoPath = upscaledPath;
                scene.upscaleDownloadUrl = videoUrl;
                scene.upscaleStatus = 'completed';
              });
              
              mobileLog('[UPSCALE] ✓ ${scene.sceneId} upscaled to $resSuffix!');
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✓ Scene ${scene.sceneId} upscaled to $resSuffix!'), backgroundColor: Colors.green),
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
  /// resolution: '1080p' or '4K'
  Future<void> _bulkUpscale({String resolution = '1080p'}) async {
    print('[BULK UPSCALE] ========== STARTING ==========');
    print('[BULK UPSCALE] Resolution: $resolution');
    print('[BULK UPSCALE] Total scenes: ${scenes.length}');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[BULK UPSCALE] Starting at $resolution...');
      mobileLog('[BULK UPSCALE] Total scenes: ${scenes.length}');
    }
    
    // List all scene statuses for debugging
    for (int i = 0; i < scenes.length; i++) {
      final s = scenes[i];
      print('[BULK UPSCALE] Scene $i: status=${s.status}, upscaleStatus=${s.upscaleStatus}, videoPath=${s.videoPath != null}');
    }
    
    // Filter scenes by from/to range
    final int startIdx = (fromIndex ?? 1) - 1; // Convert to 0-indexed
    final int endIdx = (toIndex ?? scenes.length) - 1;
    
    print('[BULK UPSCALE] Range: from ${startIdx + 1} to ${endIdx + 1}');
    
    // Filter: completed videos in range that haven't been upscaled to target resolution
    final completedScenes = scenes.asMap().entries.where((entry) {
      final idx = entry.key;
      final scene = entry.value;
      
      // Must be in range
      if (idx < startIdx || idx > endIdx) return false;
      
      // Must be completed
      if (scene.status != 'completed') return false;
      
      // Check if already upscaled to this resolution
      final resSuffix = resolution == '4K' ? '4K' : '1080p';
      final hasUpscaled = scene.upscaleVideoPath != null && 
                         scene.upscaleVideoPath!.contains('_$resSuffix.mp4');
      
      print('[BULK UPSCALE] Scene ${scene.sceneId}: hasUpscaled=$hasUpscaled, path=${scene.upscaleVideoPath}');
      
      return !hasUpscaled; // Skip already upscaled
    }).map((e) => e.value).toList();
    
    print('[BULK UPSCALE] Completed scenes to upscale: ${completedScenes.length}');
    if (Platform.isAndroid || Platform.isIOS) {
      mobileLog('[BULK UPSCALE] Found ${completedScenes.length} to upscale');
    }
    
    if (completedScenes.isEmpty) {
      print('[BULK UPSCALE] No videos need upscaling - returning');
      if (Platform.isAndroid || Platform.isIOS) {
        mobileLog('[BULK UPSCALE] ⚠ No videos to upscale');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No videos need upscaling (all already upscaled or out of range)'), backgroundColor: Colors.orange),
      );
      return;
    }
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Bulk Upscale to $resolution'),
        content: Text('Upscale ${completedScenes.length} completed videos to $resolution?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: resolution == '4K' ? Colors.purple : Colors.blue),
            child: Text('Start $resolution Upscale', style: const TextStyle(color: Colors.white)),
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
    
    // No concurrent limit for upscaling - process all videos at once
    final maxConcurrent = 999;
    print('[BULK UPSCALE] Max concurrent: unlimited');
    mobileLog('[BULK UPSCALE] Starting ${completedScenes.length} videos, no concurrent limit');
    
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
                  
                  // Get resolution suffix from poll
                  final resSuffix = poll.resolution == '4K' ? '4K' : '1080p';
                  
                  if (Platform.isAndroid || Platform.isIOS) {
                    mobileLog('[UPSCALE] Downloading $resSuffix for scene ${scene.sceneId}');
                  }
                  print('[UPSCALE] Downloading $resSuffix video for scene ${scene.sceneId}...');
                  
                  // Download upscaled video to "upscaled" subfolder
                  final originalPath = scene.videoPath ?? '';
                  final originalDir = path.dirname(originalPath);
                  final originalFilename = path.basenameWithoutExtension(originalPath);
                  final upscaledDir = path.join(originalDir, 'upscaled');
                  await Directory(upscaledDir).create(recursive: true);
                  final upscaledPath = path.join(upscaledDir, '${originalFilename}_$resSuffix.mp4');
                  
                  await pollGenerator.downloadVideo(videoUrl, upscaledPath);
                  
                  setState(() {
                    scene.upscaleVideoPath = upscaledPath;
                    scene.upscaleDownloadUrl = videoUrl;
                    scene.upscaleStatus = 'upscaled';
                  });
                  if (Platform.isAndroid || Platform.isIOS) {
                    mobileLog('[UPSCALE] ✓ Scene ${scene.sceneId} upscaled to $resSuffix');
                  }
                  print('[UPSCALE] ✓ Scene ${scene.sceneId} upscaled to $resSuffix and downloaded');
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
      
      // Get video mediaId - try videoMediaId first, fallback to operationName
      String? videoMediaId = scene.videoMediaId;
      
      if (videoMediaId == null || videoMediaId.isEmpty) {
        // Fallback to operationName for videos generated before mediaId saving was added
        videoMediaId = scene.operationName;
        if (videoMediaId != null && videoMediaId.isNotEmpty) {
          print('[UPSCALE] Scene ${scene.sceneId} - using operationName as mediaId');
          // Save it for future use
          scene.videoMediaId = videoMediaId;
        }
      }
      
      if (videoMediaId == null || videoMediaId.isEmpty) {
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
              email: '',
              password: '',
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
        
        // Convert resolution string to API format
        final apiResolution = resolution == '4K' ? 'VIDEO_RESOLUTION_4K' : 'VIDEO_RESOLUTION_1080P';
        print('[UPSCALE] Resolution: $apiResolution (requested: $resolution)');
        
        if (Platform.isAndroid || Platform.isIOS) {
          mobileLog('[UPSCALE] Sending request at $resolution...');
        }
        
        final result = await upscaleProfile.generator!.upscaleVideo(
          videoMediaId: videoMediaId,
          accessToken: upscaleProfile.accessToken!,
          aspectRatio: videoAspectRatio,
          resolution: apiResolution,
        );
        
        // Check result without excessive logging
        if (result != null && result['success'] == true) {
          final data = result['data'];
          
          if (data != null && data['operations'] != null && (data['operations'] as List).isNotEmpty) {
            final op = data['operations'][0] as Map<String, dynamic>?;
            // Don't print full operation - contains large base64 data
            
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
              pendingUpscalePolls.add(_UpscalePoll(scene, opName, sceneUuid ?? opName, resolution));
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
              print('[UPSCALE] ⚠ No operation name found in response');
              mobileLog('[UPSCALE] ⚠ No opName in response');
              setState(() {
                scene.upscaleStatus = 'failed';
                scene.error = 'No operation name in response';
              });
            }
          } else {
            print('[UPSCALE] ⚠ No operations in response');
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
            print('[UPSCALE] 403 error - ${upscaleProfile.name} count: ${upscaleProfile.consecutive403Count}/7');
            
            if (upscaleProfile.consecutive403Count >= 7) {
              print('[UPSCALE] ⚠ Threshold reached - triggering relogin for ${upscaleProfile.name}');
              
              if (Platform.isAndroid || Platform.isIOS) {
                final service = MobileBrowserService();
                service.autoReloginProfile(
                  upscaleProfile,
                  email: '',
                  password: '',
                  onSuccess: () {
                    print('[UPSCALE] ✓ ${upscaleProfile.name} relogin success');
                    upscaleProfile.consecutive403Count = 0;
                  },
                );
              } else if (_loginService != null) {
                _loginService!.reloginProfile(upscaleProfile, '', '');
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
          scene.firstFrameUploadStatus = 'queued';
        } else {
          scene.lastFramePath = filePath;
          scene.lastFrameMediaId = null;
          scene.lastFrameUploadStatus = 'queued';
        }
      });

      // Defer upload to generation phase
      // await _uploadSingleImage(scene, frameType, filePath);
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
          generator = DesktopGenerator();
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
        SnackBar(content: Text('Imported ${imagePaths.length} first frame(s). Will upload during generation.')),
      );
    }

    // Start parallel upload - DEFERRED to generation
    // await _uploadBulkImages('first');
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
        SnackBar(content: Text('Imported ${imagePaths.length} last frame(s). Will upload during generation.')),
      );
    }

    // Start parallel upload - DEFERRED to generation
    // await _uploadBulkImages('last');
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
          generator = DesktopGenerator();
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
            content: Text('Uploaded $uploaded, $failed failed. ${errors.isNotEmpty ? errors.first : ""}'),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
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
          generator = DesktopGenerator();
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
      print('[SINGLE] Generating via API ($mode)...');
      print('[SINGLE] Model: $apiModelKey (API key)');
      print('[SINGLE] Start Image MediaId: ${startMediaId ?? "null"}');
      print('[SINGLE] End Image MediaId: ${endMediaId ?? "null"}');
      print('[SINGLE] Scene has firstFramePath: ${scene.firstFramePath != null}');
      print('[SINGLE] Scene has firstFrameMediaId: ${scene.firstFrameMediaId != null}');
      
      // Generate video via direct API call
      final result = await generator!.generateVideo(
        prompt: scene.prompt,
        aspectRatio: selectedAspectRatio,
        model: apiModelKey,
        accessToken: accessToken!,
        startImageMediaId: startMediaId,
        endImageMediaId: endMediaId,
      );

      if (result == null) {
        throw Exception('No result from API');
      }

      // Check for API errors
      if (result['status'] != null && result['status'] != 200) {
        throw Exception('API error: ${result['error'] ?? result['statusText']}');
      }
      
      // Extract operation name for polling
      final operations = result['data']?['operations'] as List?;
      if (operations == null || operations.isEmpty) {
        throw Exception('No operations in response');
      }
      
      final operation = operations[0] as Map<String, dynamic>;
      final operationName = operation['operation']?['name'] as String?;
      if (operationName == null) {
        throw Exception('No operation name in response');
      }

      print('[SINGLE] ✓ Operation started: $operationName');
      
      // Store operation name and set to polling status
      scene.operationName = operationName;
      scene.status = 'polling';
      
      print('[SINGLE] Scene set to polling status. Use the poll worker to complete.');

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


  Future<void> _quickGenerate() async {
    final prompt = _quickPromptController.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _isQuickGenerating = true;
      _quickGeneratedScene = SceneData(sceneId: 0, prompt: prompt, status: 'generating');
    });

    try {
      await VideoGenerationService().startBatch(
        [_quickGeneratedScene!],
        model: selectedModel,
        aspectRatio: selectedAspectRatio,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isQuickGenerating = false);
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

  /// Stop login process (Mobile and Desktop)
  void _handleStopLogin() {
    print('[UI] ⛔ Stop Login requested - stopping immediately...');
    
    // Stop mobile service
    _mobileService?.stopLogin();
    
    // Stop desktop login service
    _loginService?.stopLogin();
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('⛔ Stopping login process...'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Handle login SINGLE browser at specified position (count) 
  /// e.g., count=4 means login ONLY Browser 4
  Future<void> _handleLogin(int browserIndex) async {
    // Mobile Support
    if (Platform.isAndroid || Platform.isIOS) {
      print('[UI] Mobile Login for browser $browserIndex');
      final service = MobileBrowserService();
      service.initialize(browserIndex); // Initialize up to this index
      
      final dynamic state = _mobileBrowserManagerKey.currentState;
      state?.show();
      
      await Future.delayed(const Duration(seconds: 1));
      
      // Login only the profile at index (browserIndex - 1 for 0-based)
      final profile = service.getProfile(browserIndex - 1);
      if (profile != null && profile.generator != null) {
        print('[UI] Logging in browser $browserIndex...');
        profile.status = MobileProfileStatus.loading;
        setState(() {});
        
        final success = await profile.generator!.autoLogin('', '');
        if (success) {
          final token = await profile.generator!.getAccessToken();
          if (token != null) {
            profile.accessToken = token;
            profile.status = MobileProfileStatus.ready;
            print('[UI] ✓ Browser $browserIndex logged in');
          }
        }
        setState(() {});
      }
      return;
    }
    // Desktop: Login single browser at specified index
    // Reset cancellation flag for new login attempt
    _loginService?.resetCancellation();
    try {
      print('[UI] Login browser $browserIndex started...');
      
      // Initialize profiles up to the specified index
      if (_profileManager!.profiles.length < browserIndex) {
        await _profileManager!.initializeProfiles(browserIndex);
      }
      
      // Get the profile at index (browserIndex - 1 for 0-based array)
      if (browserIndex > _profileManager!.profiles.length) {
        print('[UI] ✗ Browser $browserIndex does not exist');
        return;
      }
      
      final profile = _profileManager!.profiles[browserIndex - 1];
      
      // Launch if not running
      if (profile.status == ProfileStatus.disconnected) {
        await _profileManager!.launchProfile(profile);
        await _profileManager!.connectToProfileWithoutToken(profile);
      }
      
      // Auto login
      await _loginService!.autoLogin(
        profile: profile,
        email: '', // Will be looked up from settings
        password: '',
      );
      
      // Reload profiles dropdown
      await _loadProfiles();
      
      setState(() {});
      print('[UI] ✓ Browser $browserIndex login complete');
    } catch (e) {
      print('[UI] ✗ Browser $browserIndex login failed: $e');
      rethrow;
    }
  }

  /// Handle login all profiles (multi-profile with automated login)
  Future<void> _handleLoginAll(int count, String email, String password) async {
    // Get accounts from SettingsService
    final accounts = SettingsService.instance.accounts;
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ No accounts configured in Settings!'), backgroundColor: Colors.orange),
      );
      return;
    }
    
    // Use first account credentials if none provided
    final firstAccount = accounts.first;
    final loginEmail = email.isNotEmpty ? email : (firstAccount['email']?.toString() ?? firstAccount['username']?.toString() ?? '');
    final loginPassword = password.isNotEmpty ? password : (firstAccount['password']?.toString() ?? '');
    
    // Mobile Layout Support - Use embedded webview when in mobile layout (even on PC)
    if (_isShowingMobileLayout || Platform.isAndroid || Platform.isIOS) {
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
       
       // Clear storage via JavaScript (avoid clearCache plugin error)
       final p0 = _mobileService!.getProfile(0);
       if (p0 != null && p0.controller != null) {
          await p0.controller!.evaluateJavascript(source: '''
            try {
              localStorage.clear();
              sessionStorage.clear();
              if (window.indexedDB && window.indexedDB.databases) {
                window.indexedDB.databases().then(dbs => {
                  dbs.forEach(db => window.indexedDB.deleteDatabase(db.name));
                });
              }
            } catch(e) {}
          ''');
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
          
          // Perform full login flow using credentials from SettingsService
          final success = await firstProfile.generator!.autoLogin(loginEmail, loginPassword);
          
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

      // Use configured accounts from SettingsService when credentials are empty
      await _loginService!.loginAllProfiles(count, '', '');
      
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
      if (_loginService != null) {
        final profilesNeedingLogin = _profileManager!.profiles
            .where((p) => p.generator != null && p.accessToken == null)
            .toList();
        
        if (profilesNeedingLogin.isNotEmpty) {
          print('[UI] Auto-logging in ${profilesNeedingLogin.length} profile(s) without tokens...');
          
          for (final profile in profilesNeedingLogin) {
            print('[UI] Auto-login for ${profile.name}...');
            final success = await _loginService!.autoLogin(
              profile: profile,
              email: '',
              password: '',
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

  /// Test Apply Settings Logic
  Future<void> _testSettingsApplication() async {
    if (_profileManager == null) return;
    
    // Check for connected profile
    // Use ChromeProfile type
    var profiles = _profileManager!.profiles.where((p) => p.generator != null).toList();
    
    if (profiles.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No connected browser/profile found!')));
        return;
    }
    
    final profile = profiles.first;
    
    try {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings will be applied via API parameters')));
        
        // Settings are applied via API parameters, not UI automation
        // await profile.generator!.applySettings(selectedModel, selectedAspectRatio, outputCount: selectedOutputCount);
        
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings configured for API calls')));
    } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

/// Helper class for pending poll tracking
class _PendingPoll {
  final SceneData scene;
  final String sceneUuid;
  final DateTime startTime;
  final String accessToken; // Track which browser's token to use for polling

  _PendingPoll(this.scene, this.sceneUuid, this.startTime, this.accessToken);
}

/// Helper class for upscale poll tracking
class _UpscalePoll {
  final SceneData scene;
  final String operationName;
  final String sceneUuid;
  final String resolution; // '1080p' or '4K'

  _UpscalePoll(this.scene, this.operationName, this.sceneUuid, this.resolution);
}

/// Exception that can be retried on a different browser
class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);
  
  @override
  String toString() => message;
}
