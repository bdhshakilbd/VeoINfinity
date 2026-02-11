/// Video Mastering Screen
/// Professional video editing interface with multi-track timeline,
/// live preview, effects controls, and export options

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/video_mastering/video_project.dart';
import '../services/video_mastering_service.dart';
import '../widgets/video_mastering/video_timeline_widget.dart';
import '../widgets/video_mastering/audio_track_widget.dart';
import '../widgets/video_mastering/overlay_track_widget.dart';
import '../services/project_service.dart';
import '../services/settings_service.dart';
import '../widgets/video_mastering/play_icon_painter.dart';
import '../widgets/video_mastering/volume_envelope_widget.dart';
import '../utils/video_export_helper.dart';
import '../utils/media_duration_helper.dart';
import '../widgets/video_mastering/mastering_console_widget.dart';

// Background music generator integration
import '../background_music_generator.dart';
import '../lyria_audio_utils.dart';
import '../lyria_music_service.dart';
import 'dart:typed_data';

// TTS Audio Generation
import '../services/story/gemini_tts_service.dart';
import '../services/gemini_key_service.dart';
import '../models/story/story_audio_part.dart';

class VideoMasteringScreen extends StatefulWidget {
  final ProjectService projectService;
  final bool isActivated;
  final VoidCallback? onBack;
  final bool embedded;
  final List<Map<String, dynamic>>? initialClips; // List of {filePath, duration, prompt}
  final String? bgMusicPrompt;
  final Map<String, dynamic>? fullProjectJson; // Full project JSON with prompts, scenes, character data
  final List<String>? initialVideoPaths; // Direct video file paths for T2V
  final String? initialProjectName; // Project name from T2V
  final List<Map<String, dynamic>>? bgMusicPrompts; // Multiple bgmusic prompts from T2V JSON

  const VideoMasteringScreen({
    super.key,
    required this.projectService,
    this.isActivated = true,
    this.onBack,
    this.embedded = false,
    this.initialClips,
    this.bgMusicPrompt,
    this.fullProjectJson,
    this.initialVideoPaths,
    this.initialProjectName,
    this.bgMusicPrompts,
  });

  @override
  State<VideoMasteringScreen> createState() => _VideoMasteringScreenState();
}

class _VideoMasteringScreenState extends State<VideoMasteringScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {

  // Track loaded audio files to avoid reopening
  final Map<int, String> _loadedAudioFiles = {};
  // Prevent repeated open() calls while an open is in-flight (avoids UI lockups)
  final Map<int, bool> _audioOpenInProgress = {};
  final Map<int, bool> _bgMusicOpenInProgress = {};

  // Prevent repeated open() calls for video players while an open is in-flight
  bool _videoOpenInProgressPrimary = false;
  bool _videoOpenInProgressAlt = false;

  /// Returns true if any track (video, audio, bgmusic) is currently playing at the playhead
  bool get _isAnyTrackPlaying {
    // Check video
    bool videoPlaying = _project.videoClips.any((clip) {
      final end = clip.timelineStart + clip.effectiveDuration;
      return _currentPosition >= clip.timelineStart && _currentPosition < end;
    });
    // Check audio
    bool audioPlaying = _project.audioClips.any((clip) {
      final end = clip.timelineStart + clip.effectiveDuration;
      return _currentPosition >= clip.timelineStart && _currentPosition < end;
    });
    // Check bgmusic
    bool bgmPlaying = _project.bgMusicClips.any((clip) {
      final end = clip.timelineStart + clip.effectiveDuration;
      return _currentPosition >= clip.timelineStart && _currentPosition < end;
    });
    return videoPlaying || audioPlaying || bgmPlaying;
  }

  /// Calculate the true total duration as the max end time of all tracks (video, audio, bgmusic)
  double get _trueTotalDuration {
    double maxEnd = 0.0;
    for (final clip in _project.videoClips) {
      final end = clip.timelineStart + clip.effectiveDuration;
      if (end > maxEnd) maxEnd = end;
    }
    for (final clip in _project.audioClips) {
      final end = clip.timelineStart + clip.effectiveDuration;
      if (end > maxEnd) maxEnd = end;
    }
    for (final clip in _project.bgMusicClips) {
      final end = clip.timelineStart + clip.effectiveDuration;
      if (end > maxEnd) maxEnd = end;
    }
    return maxEnd;
  }
  
  @override
  bool get wantKeepAlive => true; // Keep this tab alive when switching
  
  // Track if initial clips have been loaded to prevent reloading
  bool _hasLoadedInitialClips = false;
  
  // Project state
  VideoProject _project = VideoProject(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: 'Untitled Project',
  );

  // Services
  final VideoMasteringService _videoService = VideoMasteringService();

  // Video player for preview (Dual players for A/B roll buffering)
  late final Player _player;
  late final VideoController _videoController;
  Player? _playerAlt; // Nullable to handle hot-reload initialization
  VideoController? _videoControllerAlt;
  bool _usePrimaryPlayer = true; // true = _player is active, false = _playerAlt is active
  String? _loadedFilePrimary;
  String? _loadedFileAlt;

  bool _isPlayerInitialized = false;
  
  // Audio Preview Player
  late final Player _audioPreviewPlayer;

  // Focus node for logo panel keyboard navigation
  late FocusNode _logoPanelFocusNode;
  bool _isAudioPreviewPlaying = false;
  
  // Audio track players (for playing audio/bgmusic alongside video)
  final List<Player> _audioTrackPlayers = [];
  final List<Player> _bgMusicPlayers = [];
  
  // Live streaming AI Music
  String? _liveStreamingMusicFile;
  double _liveStreamingDuration = 0.0;
  bool _isLiveStreaming = false;

  // Timeline state
  double _currentPosition = 0;
  double _volume = 100.0;
  double _zoomFactor = 1.0; // 1.0 = fit to window, 2.0 = 2x zoom, etc.
  Timer? _playbackTimer;
  bool _isSyncing = false; // Prevent overlapping sync calls
  DateTime? _lastSyncTime;
  // Debounce timer to coalesce rapid seek events from dragging/scrubbing
  Timer? _seekDebounceTimer;
  // Throttle timer for UI updates during scrubbing
  Timer? _uiUpdateTimer;
  // Debounce timer for project saving (avoid disk I/O during drags)
  Timer? _saveDebounceTimer;
  // Whether the user is currently scrubbing the timeline (pan/drag)
  bool _isUserScrubbing = false;
  // Whether the video was playing when the user started scrubbing
  bool _wasPlayingBeforeScrub = false;
  
  // Track Visibility
  bool _isVideoVisible = true;
  bool _isAudioVisible = true;
  bool _isBgMusicVisible = true;
  bool _isOverlayVisible = true;
  bool _isTextVisible = true;
  
  // Track Mute - use _project.isVideoTrackMuted, _project.isAudioTrackMuted, _project.isBgMusicTrackMuted
  // (These are now stored in the project for persistence)
  
  // Track Heights (resizable)
  double _videoTrackHeight = 120.0;
  double _audioTrackHeight = 80.0;
  double _bgMusicTrackHeight = 80.0;
  double _overlayTrackHeight = 60.0;
  double _textTrackHeight = 60.0;
  
  // Horizontal timeline scroll controller (shared across all tracks)
  final ScrollController _horizontalTimelineScroll = ScrollController();
  // Ensure we only restore the timeline view once when it's ready
  bool _timelineViewRestored = false;
  
  // Live preview transition effect
  double _transitionOpacity = 1.0; // 1.0 = fully visible, fades during transitions

  // Selection state
  int? _selectedVideoClipIndex;
  int? _selectedAudioClipIndex;
  int? _selectedBgMusicClipIndex;
  int? _selectedOverlayIndex;
  int? _selectedTextIndex;
  
  // Multi-selection support
  Set<int> _selectedVideoClips = {};
  Set<int> _selectedAudioClips = {};
  Set<int> _selectedBgMusicClips = {};
  Set<int> _selectedOverlays = {};
  Set<int> _selectedTextOverlays = {};
  
  // Track which layer is currently active for Ctrl+A
  String _activeLayer = 'video'; // 'video', 'audio', 'bgMusic', 'overlay', 'text'

  // Clipboard for copy/paste
  VideoClip? _copiedVideoClip;
  
  // Undo/Redo History (stores JSON snapshots of project state)
  static const int _maxUndoHistory = 50;
  final List<String> _undoHistory = [];
  final List<String> _redoHistory = [];
  bool _isUndoRedoInProgress = false;

  // Focus node for keyboard shortcuts
  final FocusNode _focusNode = FocusNode();

  // Panel state
  bool _showPropertiesPanel = true;
  String _activePropertiesTab = 'clip'; // 'clip', 'color', 'audio', 'logo'

  // Export state
  bool _isExporting = false;
  double _exportProgress = 0;
  String _exportStatus = '';
  
  // Export tasks stream
  StreamSubscription? _tasksSubscription;
  List<dynamic> _activeTasks = []; // List<ExportTask>
  
  // Preview aspect ratio
  String _previewAspectRatio = '16:9'; // '16:9', '9:16', '4:3', '1:1'

  // BG Music generation state
  bool _isGeneratingBgMusic = false;
  final TextEditingController _bgMusicPromptController = TextEditingController(
    text: 'Upbeat electronic music with driving bass',
  );
  final TextEditingController _apiKeyController = TextEditingController();
  
  // Parsed project data from SceneBuilder
  Map<String, dynamic>? _parsedProjectJson;
  String? _bgMusicTimingInfo; // Extracted timing info for music generation

  // Tab controller for property panels
  late TabController _tabController;
  
  // TTS Audio Generation state
  final GeminiTtsService _ttsService = GeminiTtsService();
  String _selectedVoiceModel = 'Zephyr';
  String _voiceStyleInstruction = 'Speak in a friendly, natural tone with clear enunciation';
  double _speechRate = 1.0;
  Set<String> _favoriteVoices = {'Zephyr', 'Puck', 'Kore'};
  bool _isGeneratingTts = false;
  
  // Timeline scroll controller
  final ScrollController _timelineScrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    _logoPanelFocusNode = FocusNode();
    
    _tabController = TabController(length: 6, vsync: this);
    _initializePlayer();
    _loadSavedProject();
    _loadApiKey();
    _loadTtsSettings(); // Load saved TTS preferences

    // Restore timeline zoom & scroll after loading
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreTimelineView();
    });

    // Persist horizontal scroll when user scrolls timeline
    _horizontalTimelineScroll.addListener(_onHorizontalTimelineScroll);
    
    // Subscribe to export tasks stream
    _tasksSubscription = _videoService.tasksStream.listen((tasks) {
      setState(() {
        _activeTasks = tasks;
        // Update _isExporting based on active tasks
        _isExporting = tasks.any((task) => task.isRunning);
        if (_isExporting && tasks.isNotEmpty) {
          final runningTask = tasks.firstWhere((task) => task.isRunning, orElse: () => tasks.first);
          _exportProgress = runningTask.progress;
          _exportStatus = runningTask.status;
        }
      });
    });
    
    // Load initial clips if provided AND not already loaded
    if (widget.initialClips != null && widget.initialClips!.isNotEmpty && !_hasLoadedInitialClips) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadInitialClips();
      });
    } else if (_hasLoadedInitialClips) {
    } else {
    }
    
    // Parse full project JSON if provided
    if (widget.fullProjectJson != null) {
      _parsedProjectJson = widget.fullProjectJson;
      _parseProjectJsonForBgMusic();
    }
    
    // Set bg music prompt if provided
    if (widget.bgMusicPrompt != null && widget.bgMusicPrompt!.isNotEmpty) {
      _bgMusicPromptController.text = widget.bgMusicPrompt!;
    }
    
    // Request focus for keyboard shortcuts to work
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreTimelineView();
    });
  }

  Future<void> _restoreTimelineView() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keyZoom = 'vm_zoom_${_project.id}';
      final keyScroll = 'vm_scroll_${_project.id}';
      if (prefs.containsKey(keyZoom)) {
        final savedZoom = prefs.getDouble(keyZoom) ?? _zoomFactor;
        setState(() => _zoomFactor = savedZoom.clamp(0.5, 20.0));
      }
      if (prefs.containsKey(keyScroll)) {
        final savedOffset = prefs.getDouble(keyScroll) ?? 0.0;
        // Delay jump until scroll metrics are available
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_horizontalTimelineScroll.hasClients) {
            _horizontalTimelineScroll.jumpTo(savedOffset.clamp(0.0, _horizontalTimelineScroll.position.maxScrollExtent));
          } else {
            // Try again shortly if not yet attached
            Future.delayed(const Duration(milliseconds: 150), () {
              if (_horizontalTimelineScroll.hasClients) {
                _horizontalTimelineScroll.jumpTo(savedOffset.clamp(0.0, _horizontalTimelineScroll.position.maxScrollExtent));
              }
            });
          }
        });
      }
    } catch (e) {
    }
  }

  void _onHorizontalTimelineScroll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Save scroll offset and visible center ratio so we can restore the same visual region
      final keyOffset = 'vm_scroll_${_project.id}';
      await prefs.setDouble(keyOffset, _horizontalTimelineScroll.offset);

      if (_horizontalTimelineScroll.hasClients) {
        final viewportWidth = _horizontalTimelineScroll.position.viewportDimension;
        final timelineWidth = _horizontalTimelineScroll.position.maxScrollExtent + viewportWidth;
        final centerRatio = ( _horizontalTimelineScroll.offset + (viewportWidth / 2) ) / (timelineWidth <= 0 ? 1 : timelineWidth);
        final keyCenter = 'vm_center_${_project.id}';
        await prefs.setDouble(keyCenter, centerRatio.clamp(0.0, 1.0));
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _saveTimelineZoom() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'vm_zoom_${_project.id}';
      await prefs.setDouble(key, _zoomFactor);

      // Also persist the visible center ratio if scroll metrics are available
      if (_horizontalTimelineScroll.hasClients) {
        final viewportWidth = _horizontalTimelineScroll.position.viewportDimension;
        final timelineWidth = _horizontalTimelineScroll.position.maxScrollExtent + viewportWidth;
        final centerRatio = ( _horizontalTimelineScroll.offset + (viewportWidth / 2) ) / (timelineWidth <= 0 ? 1 : timelineWidth);
        final keyCenter = 'vm_center_${_project.id}';
        await prefs.setDouble(keyCenter, centerRatio.clamp(0.0, 1.0));
      }
    } catch (e) {
      // ignore
    }
  }

  @override
  void didUpdateWidget(VideoMasteringScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // If we just received new initial clips (widget was updated with clips), load them
    if (widget.initialClips != null && 
        widget.initialClips!.isNotEmpty && 
        (oldWidget.initialClips == null || oldWidget.initialClips!.isEmpty) &&
        !_hasLoadedInitialClips) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadInitialClips();
      });
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _loadSavedProject(); // Reload project to fix state on hot reload
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _tasksSubscription?.cancel();
    _seekDebounceTimer?.cancel();
    _uiUpdateTimer?.cancel();
    _saveDebounceTimer?.cancel();
    _player.dispose();
    _playerAlt?.dispose();
    _audioPreviewPlayer.dispose();
    
    // Dispose audio track players
    for (final player in _audioTrackPlayers) {
      player.dispose();
    }
    for (final player in _bgMusicPlayers) {
      player.dispose();
    }
    
    // Close live stream sink if open
    _liveStreamSink?.close();
    
    _tabController.dispose();
    _bgMusicPromptController.dispose();
    _apiKeyController.dispose();
    _timelineScrollController.dispose();
    // Save zoom and scroll before disposing
    _saveTimelineZoom();
    _horizontalTimelineScroll.removeListener(_onHorizontalTimelineScroll);
    _horizontalTimelineScroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _initializePlayer() {
    // Initialize Audio Preview Player (independent of video player)
    _audioPreviewPlayer = Player(configuration: const PlayerConfiguration(pitch: true));
    _audioPreviewPlayer.stream.completed.listen((completed) {
      if (completed) {
        setState(() => _isAudioPreviewPlaying = false);
      }
    });

    // Initialize Video Player
    _player = Player();
    _videoController = VideoController(_player);
    
    // We can't re-initialize _player here as it is late final and already set
    // But we can ensure _playerAlt is initialized (fixing hot reload crash)
    if (_playerAlt == null) {
      _playerAlt = Player();
      _videoControllerAlt = VideoController(_playerAlt!);
    }
    
    _isPlayerInitialized = true;
    // The Master Clock (_playbackTimer) drives the timeline
  }

  Future<void> _loadApiKey() async {
    try {
      // Try to get API key from global SettingsService
      final settings = SettingsService.instance;
      await settings.load();
      
      if (settings.getGeminiKeys().isNotEmpty) {
        // Use the first available API key from global settings
        _apiKeyController.text = settings.getGeminiKeys().first;
      } else {
        // Fallback: try legacy file-based key
        final appDir = await getApplicationDocumentsDirectory();
        final keyFile = File(path.join(appDir.path, 'gemini_api_key.txt'));
        if (await keyFile.exists()) {
          _apiKeyController.text = await keyFile.readAsString();
        }
      }
    } catch (e) {
    }
  }

  /// Load TTS settings from SharedPreferences
  Future<void> _loadTtsSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final favoritesList = prefs.getStringList('tts_favorite_voices');
      if (favoritesList != null && favoritesList.isNotEmpty) {
        _favoriteVoices = favoritesList.toSet();
      }
      _selectedVoiceModel = prefs.getString('tts_selected_voice') ?? 'Zephyr';
      _voiceStyleInstruction = prefs.getString('tts_voice_style') ?? 'Speak in a friendly, natural tone with clear enunciation';
      _speechRate = prefs.getDouble('tts_speech_rate') ?? 1.0;
    } catch (e) {
    }
  }

  /// Save TTS settings to SharedPreferences
  Future<void> _saveTtsSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('tts_favorite_voices', _favoriteVoices.toList());
      await prefs.setString('tts_selected_voice', _selectedVoiceModel);
      await prefs.setString('tts_voice_style', _voiceStyleInstruction);
      await prefs.setDouble('tts_speech_rate', _speechRate);
    } catch (e) {
    }
  }

  Future<void> _loadSavedProject() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final projectFile = File(path.join(appDir.path, 'video_mastering_project.json'));
      
      // CRITICAL: Skip loading saved project if we have initial clips to load AND haven't loaded them yet
      // This prevents the empty/old saved project from overwriting our incoming clips
      if (widget.initialClips != null && widget.initialClips!.isNotEmpty && !_hasLoadedInitialClips) {
        // Keep the empty project that was initialized
        return;
      }
      
      if (await projectFile.exists()) {
        final content = await projectFile.readAsString();
        final json = jsonDecode(content);
        setState(() {
          _project = VideoProject.fromJson(json);
        });
        // Allow timeline view to be restored for the newly loaded project
        _timelineViewRestored = false;
        // Restore timeline zoom & scroll for this loaded project
        await _restoreTimelineView();
        
        // Re-detect durations for all video clips IN PARALLEL for speed
        final existingClips = <int>[];
        final durationFutures = <Future<double?>>[];
        
        for (int i = 0; i < _project.videoClips.length; i++) {
          final clip = _project.videoClips[i];
          if (File(clip.filePath).existsSync()) {
            existingClips.add(i);
            durationFutures.add(MediaDurationHelper.getVideoDuration(clip.filePath).catchError((_) => null));
          }
        }
        
        // Wait for all probes in parallel
        final durations = await Future.wait(durationFutures);
        
        // Apply detected durations
        double cumulativeShift = 0.0;
        for (int idx = 0; idx < existingClips.length; idx++) {
          final i = existingClips[idx];
          final detectedDuration = durations[idx];
          if (detectedDuration != null && detectedDuration > 0) {
            final clip = _project.videoClips[i];
            final oldDuration = clip.originalDuration;
            if ((oldDuration - detectedDuration).abs() > 0.1) {
              // Update clip duration
              _project.videoClips[i] = VideoClip(
                id: clip.id,
                filePath: clip.filePath,
                thumbnailPath: clip.thumbnailPath,
                timelineStart: clip.timelineStart + cumulativeShift,
                originalDuration: detectedDuration,
                trimStart: clip.trimStart,
                trimEnd: clip.trimEnd,
                speed: clip.speed,
                volume: clip.volume,
                colorSettings: clip.colorSettings,
              );
              cumulativeShift += (detectedDuration - oldDuration);
            } else if (cumulativeShift != 0) {
              // Just shift timeline if previous clips changed
              _project.videoClips[i] = VideoClip(
                id: clip.id,
                filePath: clip.filePath,
                thumbnailPath: clip.thumbnailPath,
                timelineStart: clip.timelineStart + cumulativeShift,
                originalDuration: clip.originalDuration,
                trimStart: clip.trimStart,
                trimEnd: clip.trimEnd,
                speed: clip.speed,
                volume: clip.volume,
                colorSettings: clip.colorSettings,
              );
            }
          }
        }
        
        // Save project with corrected durations
        if (_project.videoClips.isNotEmpty && cumulativeShift != 0) {
          await _saveProject();
        }
        
        setState(() {
          // Trigger UI rebuild with corrected durations
        });
        
        // Migrate legacy logo settings to overlays
        if (_project.logoSettings != null && _project.logoSettings!.imagePath.isNotEmpty) {
          final logo = _project.logoSettings!;
          double x = 0.9, y = 0.9;
          if (logo.position == 'topLeft') { x=0.05; y=0.05; }
          else if (logo.position == 'topRight') { x=0.9; y=0.05; }
          else if (logo.position == 'bottomLeft') { x=0.05; y=0.9; }
          else if (logo.position == 'bottomRight') { x=0.9; y=0.9; }
          else if (logo.position == 'center') { x=0.5; y=0.5; }
          else if (logo.position == 'custom') { x=logo.customX??0.5; y=logo.customY??0.5; }

          setState(() {
            _project.overlays.add(OverlayItem(
              id: 'migrated_logo_${DateTime.now().millisecondsSinceEpoch}',
              type: 'image', // Treated as image overlay
              properties: {'imagePath': logo.imagePath},
              timelineStart: logo.startTime,
              duration: (logo.endTime != null && logo.endTime! > logo.startTime) ? (logo.endTime! - logo.startTime) : (_project.totalDuration > 0 ? _project.totalDuration : 5.0),
              x: x,
              y: y,
              scale: logo.scale,
              opacity: logo.transparency,
            ));
            
            _project.logoSettings = null;
          });
          await _saveProject();
        }
        
        // Sync intro/outro to timeline
        await _syncIntroOutroToTimeline();
        
        // Load first video into player
        if (_project.videoClips.isNotEmpty) {
          await _player.open(Media(_project.videoClips.first.filePath));
          await _player.pause();
        }
      }
    } catch (e) {
    }
  }

  Future<void> _loadInitialClips() async {
    MasteringConsole.info('Starting to load ${widget.initialClips?.length ?? 0} initial clips...');
    
    if (widget.initialClips == null || widget.initialClips!.isEmpty) {
      MasteringConsole.warning('No initial clips to load');
      return;
    }
    
    if (_hasLoadedInitialClips) {
      MasteringConsole.debug('Initial clips already loaded, skipping');
      return;
    }
    
    final totalClips = widget.initialClips!.length;
    MasteringConsole.info('Loading $totalClips videos from T2V...');
    
    // Show loading dialog with progress
    final progressNotifier = ValueNotifier<int>(0);
    final statusNotifier = ValueNotifier<String>('Preparing to load $totalClips videos...');
    
    if (mounted) {
      // Use unawaited showDialog to not block
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1E1E2E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            content: ValueListenableBuilder<int>(
              valueListenable: progressNotifier,
              builder: (_, progress, __) => ValueListenableBuilder<String>(
                valueListenable: statusNotifier,
                builder: (_, status, __) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.video_library, color: Colors.blueAccent, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      'Importing Videos',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      status,
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    // Progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: totalClips > 0 ? progress / totalClips : 0,
                        minHeight: 12,
                        backgroundColor: Colors.grey[800],
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$progress / $totalClips',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      
      // CRITICAL: Wait for dialog to render before starting heavy work
      await Future.delayed(const Duration(milliseconds: 50));
    }
    
    // Calculate starting time from existing clips
    double currentTime = 0.0;
    if (_project.videoClips.isNotEmpty) {
      final lastClip = _project.videoClips.last;
      currentTime = lastClip.timelineEnd;
    }
    
    int addedCount = 0;
    int skippedCount = 0;
    
    // STEP 1: Collect valid clips and prepare parallel duration probes
    statusNotifier.value = 'Checking files...';
    final validClips = <Map<String, dynamic>>[];
    final durationFutures = <Future<double?>>[];
    
    for (final clipData in widget.initialClips!) {
      final filePath = clipData['filePath'] as String?;
      final providedDuration = (clipData['duration'] as num?)?.toDouble() ?? 0.0;
      
      if (filePath == null || !File(filePath).existsSync()) {
        skippedCount++;
        continue;
      }
      
      validClips.add(clipData);
      
      // Queue duration probe (parallel) - only if not provided
      if (providedDuration <= 0) {
        durationFutures.add(MediaDurationHelper.getVideoDuration(filePath).catchError((_) => null));
      } else {
        durationFutures.add(Future.value(providedDuration));
      }
    }
    
    // STEP 2: Run all duration probes IN PARALLEL (fast!)
    statusNotifier.value = 'Detecting durations (${validClips.length} videos)...';
    progressNotifier.value = (totalClips * 0.1).round(); // Show 10% while probing
    MasteringConsole.info('Detecting durations for ${validClips.length} videos in parallel...');
    
    final durations = await Future.wait(durationFutures);
    MasteringConsole.success('Duration detection complete!');
    
    // STEP 3: Add clips to project quickly (no I/O here)
    statusNotifier.value = 'Adding to timeline...';
    MasteringConsole.info('Adding ${validClips.length} clips to timeline...');
    
    for (int i = 0; i < validClips.length; i++) {
      final clipData = validClips[i];
      final filePath = clipData['filePath'] as String;
      final actualDuration = durations[i] ?? 5.0;
      
      final clip = VideoClip(
        id: DateTime.now().millisecondsSinceEpoch.toString() + '_${_project.videoClips.length}',
        filePath: filePath,
        timelineStart: currentTime,
        originalDuration: actualDuration,
      );
      
      _project.videoClips.add(clip);
      addedCount++;
      currentTime += clip.effectiveDuration;
      
      // Update progress
      progressNotifier.value = ((i + 1) / validClips.length * 0.9 * totalClips + totalClips * 0.1).round();
      
      // Log every 5 clips or at the end
      if ((i + 1) % 5 == 0 || i == validClips.length - 1) {
        MasteringConsole.debug('Added ${i + 1}/${validClips.length} clips...');
      }
    }
    
    // Final progress update
    progressNotifier.value = totalClips;
    statusNotifier.value = 'Finalizing...';
    MasteringConsole.success('Import complete! Added $addedCount clips to timeline.');
    
    // Wait a moment so users can see the completed import
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Close dialog
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    
    // Force a complete rebuild with the new clips
    if (addedCount > 0) {
      setState(() {
        // This will trigger a complete rebuild of the timeline
      });
      
      // Load first video into player
      try {
        await _player.open(Media(_project.videoClips.first.filePath));
        await _player.pause();
      } catch (e) {
      }
      
      // Save the project with new clips
      await _saveProject();
      
      // Sync intro/outro to timeline
      await _syncIntroOutroToTimeline();
    }
    
    // Mark that we've loaded initial clips to prevent reloading on tab switch
    _hasLoadedInitialClips = true;
    
    // Force one more setState to ensure UI is fully updated
    if (addedCount > 0) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        setState(() {
        });
      }
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                addedCount > 0 ? Icons.check_circle : Icons.warning,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  addedCount > 0 
                    ? '✓ Added $addedCount clip${addedCount > 1 ? 's' : ''} to timeline (Total: ${_project.videoClips.length})'
                    : 'No clips were added${skippedCount > 0 ? ' ($skippedCount files not found)' : ''}',
                ),
              ),
            ],
          ),
          backgroundColor: addedCount > 0 ? Colors.green.shade700 : Colors.orange.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }
  
  void _parseProjectJsonForBgMusic() {
    if (_parsedProjectJson == null) return;
    
    try {
      // Extract BG music prompt from the JSON structure
      String musicPrompt = '';
      String timingInfo = '';
      
      // Try to get from prompts array
      if (_parsedProjectJson!.containsKey('prompts')) {
        final prompts = _parsedProjectJson!['prompts'];
        if (prompts is List && prompts.isNotEmpty) {
          final firstPrompt = prompts.first as Map<String, dynamic>?;
          if (firstPrompt != null && firstPrompt.containsKey('background_music')) {
            final bgMusic = firstPrompt['background_music'];
            if (bgMusic is Map) {
              musicPrompt = bgMusic['prompt'] as String? ?? '';
              
              // Extract timing information if available
              if (bgMusic.containsKey('duration')) {
                timingInfo += 'Duration: ${bgMusic['duration']}s\n';
              }
              if (bgMusic.containsKey('style')) {
                timingInfo += 'Style: ${bgMusic['style']}\n';
              }
              if (bgMusic.containsKey('mood')) {
                timingInfo += 'Mood: ${bgMusic['mood']}\n';
              }
            } else if (bgMusic is String) {
              musicPrompt = bgMusic;
            }
          }
          
          // Extract scene timing information for music pacing
          final sceneCount = prompts.length;
          final totalDuration = _project.videoClips.fold<double>(0.0, (sum, clip) => sum + clip.effectiveDuration);
          timingInfo += 'Total Scenes: $sceneCount\n';
          timingInfo += 'Total Duration: ${totalDuration.toStringAsFixed(1)}s\n';
        }
      }
      
      // Fallback to story input if no specific music prompt
      if (musicPrompt.isEmpty && _parsedProjectJson!.containsKey('story_input')) {
        final storyInput = _parsedProjectJson!['story_input'] as String?;
        if (storyInput != null && storyInput.isNotEmpty) {
          musicPrompt = 'Create background music for: $storyInput';
        }
      }
      
      // Update the UI with parsed data
      if (musicPrompt.isNotEmpty) {
        setState(() {
          _bgMusicPromptController.text = musicPrompt;
          _bgMusicTimingInfo = timingInfo.isNotEmpty ? timingInfo : null;
        });
      }
    } catch (e) {
    }
  }

  // Track last undo save time to debounce rapid saves
  DateTime? _lastUndoSaveTime;
  String? _lastUndoSnapshot;
  
  Future<void> _saveProject({bool saveUndo = true}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final projectFile = File(path.join(appDir.path, 'video_mastering_project.json'));
      final jsonData = jsonEncode(_project.toJson());
      
      // Save undo state if requested and not in undo/redo operation
      // Debounce: only save if 500ms have passed since last save OR content is different
      if (saveUndo && !_isUndoRedoInProgress) {
        final now = DateTime.now();
        final shouldSave = _lastUndoSaveTime == null || 
            now.difference(_lastUndoSaveTime!).inMilliseconds > 500 ||
            _lastUndoSnapshot != jsonData;
        
        if (shouldSave && jsonData != _lastUndoSnapshot) {
          // Save previous state (before this change)
          if (_lastUndoSnapshot != null) {
            _undoHistory.add(_lastUndoSnapshot!);
            while (_undoHistory.length > _maxUndoHistory) {
              _undoHistory.removeAt(0);
            }
            _redoHistory.clear();
          }
          _lastUndoSnapshot = jsonData;
          _lastUndoSaveTime = now;
        }
      }
      
      await projectFile.writeAsString(jsonData);
      // Silent save - no toast needed
    } catch (e) {
    }
  }
  
  /// Debounced save - used during drag operations to reduce disk I/O
  void _saveProjectDebounced() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _saveProject();
    });
  }

  Future<void> _addGeneratedMusicToTimeline(String filePath) async {
    try {
      final info = await _videoService.getAudioInfo(filePath);
      final duration = info?.duration ?? 30.0;
      
      final clip = AudioClip(
        id: 'generated_music_${DateTime.now().millisecondsSinceEpoch}',
        filePath: filePath,
        timelineStart: _currentPosition,
        duration: duration,
        isGenerated: true,
        generationPrompt: 'Generated via AI Music',
      );
      
      setState(() {
        _project.bgMusicClips.add(clip);
        _selectedBgMusicClipIndex = _project.bgMusicClips.length - 1;
        _selectedVideoClipIndex = null;
        _selectedAudioClipIndex = null;
        _selectedOverlayIndex = null;
        _tabController.animateTo(0); // Stay on AI Music tab
      });
      
      _saveProject();
      // Silent success - no toast needed
    } catch (e) {
    }
  }
  
  /// Add generated music to BG Music timeline at a specific start position
  Future<void> _addGeneratedMusicToTimelineAt(String filePath, double startTime, double actualDuration, double expectedDuration) async {
    try {
      final clip = AudioClip(
        id: 'generated_music_${DateTime.now().millisecondsSinceEpoch}',
        filePath: filePath,
        timelineStart: startTime, // Place at the specified start time from JSON
        duration: actualDuration, // Actual generated duration
        isGenerated: true,
        generationPrompt: 'Generated via AI Music (segment)',
        expectedDuration: expectedDuration, // Expected duration from JSON
      );
      
      setState(() {
        _project.bgMusicClips.add(clip);
        _selectedBgMusicClipIndex = _project.bgMusicClips.length - 1;
        _selectedVideoClipIndex = null;
        _selectedAudioClipIndex = null;
        _selectedOverlayIndex = null;
      });
      
      _saveProject();
    } catch (e) {
    }
  }

  /// Show dialog to generate TTS audio clips
  void _showGenerateAudioDialog() {
    final textController = TextEditingController();
    String selectedVoice = _selectedVoiceModel;
    String styleInstruction = _voiceStyleInstruction;
    double speechRate = _speechRate;
    String selectedPreset = 'Normal';
    
    // Voice presets for pace/tone/speed
    final presets = {
      'Normal': {'style': 'Speak in a natural, conversational tone', 'rate': 1.0},
      'Slow & Calm': {'style': 'Speak slowly and calmly, with a soothing tone', 'rate': 0.8},
      'Fast & Energetic': {'style': 'Speak quickly with high energy and enthusiasm', 'rate': 1.3},
      'Professional': {'style': 'Speak in a professional, authoritative tone', 'rate': 1.0},
      'Friendly': {'style': 'Speak in a warm, friendly tone like talking to a friend', 'rate': 1.0},
      'Dramatic': {'style': 'Speak with dramatic emphasis and emotional inflection', 'rate': 0.9},
      'Whisper': {'style': 'Speak softly, almost in a whisper', 'rate': 0.85},
      'Excited': {'style': 'Speak with excitement and enthusiasm', 'rate': 1.2},
    };
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Sort voices with favorites on top
          final sortedVoices = List<String>.from(VoiceModels.all);
          sortedVoices.sort((a, b) {
            final aFav = _favoriteVoices.contains(a);
            final bFav = _favoriteVoices.contains(b);
            if (aFav && !bFav) return -1;
            if (!aFav && bFav) return 1;
            return a.compareTo(b);
          });
          
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Container(
              width: 480,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.teal.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.record_voice_over, color: Colors.teal.shade700, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Generate Audio Clips',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade800,
                              ),
                            ),
                            Text(
                              'AI-powered text-to-speech using Gemini',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  
                  // Voice Model Dropdown with Star button
                  Text('Voice Model', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Star/Favorite toggle button
                      IconButton(
                        onPressed: () {
                          setDialogState(() {
                            if (_favoriteVoices.contains(selectedVoice)) {
                              _favoriteVoices.remove(selectedVoice);
                            } else {
                              _favoriteVoices.add(selectedVoice);
                            }
                          });
                          setState(() {}); // Update parent
                          _saveTtsSettings(); // Persist to storage
                        },
                        icon: Icon(
                          _favoriteVoices.contains(selectedVoice) ? Icons.star : Icons.star_border,
                          color: _favoriteVoices.contains(selectedVoice) ? Colors.amber : Colors.grey.shade400,
                        ),
                        tooltip: _favoriteVoices.contains(selectedVoice) ? 'Remove from favorites' : 'Add to favorites',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      ),
                      const SizedBox(width: 8),
                      // Dropdown
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: selectedVoice,
                              isExpanded: true,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              borderRadius: BorderRadius.circular(8),
                              items: sortedVoices.map((voice) {
                                final isFavorite = _favoriteVoices.contains(voice);
                                return DropdownMenuItem(
                                  value: voice,
                                  child: Row(
                                    children: [
                                      Icon(
                                        isFavorite ? Icons.star : Icons.star_border,
                                        size: 16,
                                        color: isFavorite ? Colors.amber : Colors.grey.shade300,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(voice),
                                      if (isFavorite)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 8),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.amber.shade100,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              'FAV',
                                              style: TextStyle(fontSize: 9, color: Colors.amber.shade800, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (v) => setDialogState(() => selectedVoice = v ?? selectedVoice),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  
                  // Preset Dropdown
                  Text('Pace/Tone Preset', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedPreset,
                        isExpanded: true,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        borderRadius: BorderRadius.circular(8),
                        items: presets.keys.map((preset) => DropdownMenuItem(
                          value: preset,
                          child: Text(preset),
                        )).toList(),
                        onChanged: (v) {
                          setDialogState(() {
                            selectedPreset = v ?? selectedPreset;
                            styleInstruction = presets[selectedPreset]!['style'] as String;
                            speechRate = presets[selectedPreset]!['rate'] as double;
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Style Instruction
                  Text('Style Instruction', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: TextEditingController(text: styleInstruction),
                    maxLines: 2,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'e.g., Speak in a friendly, natural tone...',
                      hintStyle: TextStyle(color: Colors.grey.shade400),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                    onChanged: (v) => styleInstruction = v,
                  ),
                  const SizedBox(height: 16),
                  
                  // Speed Slider
                  Row(
                    children: [
                      Text('Speed: ', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                      Text('${speechRate.toStringAsFixed(1)}x', style: TextStyle(color: Colors.teal.shade700, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: speechRate,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    activeColor: Colors.teal,
                    onChanged: (v) => setDialogState(() => speechRate = v),
                  ),
                  const SizedBox(height: 16),
                  
                  // Text to Speak
                  Text('Text to Speak', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: textController,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Enter the text you want to convert to speech...',
                      hintStyle: TextStyle(color: Colors.grey.shade400),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // Generate Button
                  SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      icon: _isGeneratingTts
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.play_arrow_rounded),
                      label: Text(_isGeneratingTts ? 'Generating...' : 'Generate Audio'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _isGeneratingTts ? null : () async {
                        if (textController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter text to generate audio')),
                          );
                          return;
                        }
                        
                        // Save selections
                        setState(() {
                          _selectedVoiceModel = selectedVoice;
                          _voiceStyleInstruction = styleInstruction;
                          _speechRate = speechRate;
                        });
                        _saveTtsSettings(); // Persist to storage
                        
                        Navigator.pop(ctx);
                        await _generateTtsAudio(textController.text, selectedVoice, styleInstruction, speechRate);
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Generate TTS audio and add to timeline
  Future<void> _generateTtsAudio(String text, String voiceModel, String styleInstruction, double speechRate) async {
    setState(() => _isGeneratingTts = true);
    
    try {
      // Load API keys if not loaded
      await _ttsService.loadApiKeys();
      
      // Generate output path
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${dir.path}/tts_audio_$timestamp.wav';
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              const SizedBox(width: 12),
              Text('Generating audio with $voiceModel voice...'),
            ],
          ),
          duration: const Duration(seconds: 10),
        ),
      );
      
      // Generate TTS
      final success = await _ttsService.generateTts(
        text: text,
        voiceModel: voiceModel,
        voiceStyle: styleInstruction,
        speechRate: speechRate,
        outputPath: outputPath,
      );
      
      if (success && await File(outputPath).exists()) {
        await _addGeneratedTtsToTimeline(outputPath, text, voiceModel);
        
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Text('Audio generated and added to timeline'),
              ],
            ),
            backgroundColor: Colors.green.shade600,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to generate audio. Please try again.'),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red.shade600,
        ),
      );
    } finally {
      setState(() => _isGeneratingTts = false);
    }
  }

  /// Add generated TTS audio to the audio timeline
  Future<void> _addGeneratedTtsToTimeline(String filePath, String text, String voiceModel) async {
    try {
      final duration = await _ttsService.getDuration(filePath) ?? 5.0;
      
      final clip = AudioClip(
        id: 'tts_${DateTime.now().millisecondsSinceEpoch}',
        filePath: filePath,
        timelineStart: _currentPosition,
        duration: duration,
        isGenerated: true,
        generationPrompt: 'TTS: $voiceModel - ${text.length > 50 ? text.substring(0, 50) + '...' : text}',
      );
      
      setState(() {
        _project.audioClips.add(clip);
        _selectedAudioClipIndex = _project.audioClips.length - 1;
        _selectedVideoClipIndex = null;
        _selectedBgMusicClipIndex = null;
        _selectedOverlayIndex = null;
        _activeLayer = 'audio';
      });
      
      _saveProject();
    } catch (e) {
    }
  }

  // Live streaming handlers
  List<Uint8List> _liveAudioBuffer = [];
  IOSink? _liveStreamSink;
  
  void _startLiveStreamRecording() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _liveStreamingMusicFile = '${dir.path}/live_ai_music_$timestamp.wav';
      _liveStreamingDuration = 0.0;
      _liveAudioBuffer.clear();
      _isLiveStreaming = true;
      
      // Create file with placeholder WAV header
      final file = File(_liveStreamingMusicFile!);
      _liveStreamSink = file.openWrite();
      _liveStreamSink!.add(Uint8List(44)); // Placeholder header
      
      // Add clip to timeline immediately
      final clip = AudioClip(
        id: 'live_ai_music_$timestamp',
        filePath: _liveStreamingMusicFile!,
        timelineStart: _currentPosition,
        duration: 0.1, // Start with small duration, will update
        isGenerated: true,
        generationPrompt: 'Live AI Music Stream',
      );
      
      setState(() {
        _project.bgMusicClips.add(clip);
        _selectedBgMusicClipIndex = _project.bgMusicClips.length - 1;
      });
    } catch (e) {
    }
  }
  
  void _handleLiveAudioChunk(Uint8List chunk, double totalDuration) {
    if (!_isLiveStreaming || _liveStreamSink == null) return;
    
    try {
      // Write chunk to file
      _liveStreamSink!.add(chunk);
      _liveAudioBuffer.add(chunk);
      _liveStreamingDuration = totalDuration;
      
      // Update clip duration in timeline
      if (_selectedBgMusicClipIndex != null && 
          _selectedBgMusicClipIndex! < _project.bgMusicClips.length) {
        final clip = _project.bgMusicClips[_selectedBgMusicClipIndex!];
        if (clip.filePath == _liveStreamingMusicFile) {
          setState(() {
            _project.bgMusicClips[_selectedBgMusicClipIndex!] = AudioClip(
              id: clip.id,
              filePath: clip.filePath,
              timelineStart: clip.timelineStart,
              duration: totalDuration,
              volume: clip.volume,
              speed: clip.speed,
              pitch: clip.pitch,
              trimStart: clip.trimStart,
              trimEnd: clip.trimEnd,
              isGenerated: true,
              generationPrompt: clip.generationPrompt,
            );
          });
        }
      }
    } catch (e) {
    }
  }
  
  void _stopLiveStreamRecording() async {
    if (!_isLiveStreaming) return;
    
    try {
      await _liveStreamSink?.flush();
      await _liveStreamSink?.close();
      _liveStreamSink = null;
      
      // Fix WAV header
      if (_liveStreamingMusicFile != null && _liveAudioBuffer.isNotEmpty) {
        int totalBytes = 0;
        for (var chunk in _liveAudioBuffer) totalBytes += chunk.length;
        
        final file = File(_liveStreamingMusicFile!);
        await LyriaAudioUtils.fixWavHeader(file, totalBytes);
      }
      
      _isLiveStreaming = false;
      _liveAudioBuffer.clear();
      _saveProject();
      // Silent save - visual feedback is on timeline
    } catch (e) {
    }
  }

  Future<void> _importVideos() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      bool wasEmpty = _project.videoClips.isEmpty;
      double currentEnd = 0.0;
      if (_project.videoClips.isNotEmpty) {
        currentEnd = _project.videoClips.last.timelineEnd;
      }

      int addedCount = 0;
      int failedCount = 0;

      for (final file in result.files) {
        if (file.path == null) {
          failedCount++;
          continue;
        }

        try {
          // Get video info using ffprobe (same folder as app)
          final info = await _videoService.getVideoInfo(file.path!);
          double duration = info?.duration ?? 5.0; // Default to 5s if ffprobe fails
          
          print('[VideoMastering] ${file.name}: duration=${duration.toStringAsFixed(2)}s');

          // Skip thumbnail extraction for faster loading - thumbnails disabled in timeline anyway
          final clip = VideoClip(
            id: DateTime.now().millisecondsSinceEpoch.toString() + '_$addedCount',
            filePath: file.path!,
            timelineStart: currentEnd,
            originalDuration: duration,
          );

          _project.videoClips.add(clip);
          addedCount++;
          currentEnd += duration;
          print('[VideoMastering] Added ${file.name} at ${clip.timelineStart.toStringAsFixed(2)}s');
        } catch (e) {
          print('[VideoMastering] Failed: ${file.name}: $e');
          failedCount++;
        }
      }

      // Rebuild UI
      if (addedCount > 0) {
        setState(() {});

        if (wasEmpty && _project.videoClips.isNotEmpty) {
          await _player.open(Media(_project.videoClips.first.filePath));
          await _player.pause();
        }

        await _saveProject();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ Added $addedCount video${addedCount > 1 ? 's' : ''} to timeline'),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else if (failedCount > 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to import $failedCount video${failedCount > 1 ? 's' : ''}'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
    } catch (e) {
      print('[VideoMastering] Import error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  Future<void> _importAudio() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      // FIX: Calculate end position from AUDIO clips only
      double currentEnd = 0.0;
      if (_project.audioClips.isNotEmpty) {
        currentEnd = _project.audioClips.last.timelineEnd;
      }

      for (final file in result.files) {
        if (file.path == null) continue;

        final info = await _videoService.getAudioInfo(file.path!);
        final duration = info?.duration ?? 10.0;

        final clip = AudioClip(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          filePath: file.path!,
          name: path.basenameWithoutExtension(file.path!),
          timelineStart: currentEnd,
          duration: duration,
        );

        setState(() {
          _project.audioClips.add(clip);
        });
        
        currentEnd += duration; // Next clip starts after this one
      }

      _saveProject();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to import audio: $e')),
      );
    }
  }

  Future<void> _importImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      final overlay = OverlayItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: 'image',
        timelineStart: _currentPosition,
        duration: 5,
        properties: {'imagePath': file.path},
      );

      setState(() {
        _project.overlays.add(overlay);
      });

      _saveProject();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to import image: $e')),
      );
    }
  }

  void _addTextOverlay() {
    final overlay = OverlayItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: 'text',
      timelineStart: _currentPosition,
      duration: 5,
      properties: {
        'text': 'Enter text here',
        'fontSize': 32,
        'textColor': 0xFFFFFFFF,
        'backgroundColor': 0x80000000,
      },
    );

    setState(() {
      _project.overlays.add(overlay);
      _selectedOverlayIndex = _project.overlays.length - 1;
    });

    _saveProject();
  }

  Future<void> _importLogo() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      // Add as OverlayItem on the timeline layer
      final overlay = OverlayItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: 'image', // Treating logo as an image overlay
        timelineStart: 0,
        // Default to checking full duration, fallback to 10s if empty project
        duration: _project.totalDuration > 0 ? _project.totalDuration : 10.0,
        properties: {'imagePath': result.files.first.path!},
        x: 0.08, // Default Top-Left
        y: 0.08,
        scale: 0.09, // Default 9% width relative to video
      );

      setState(() {
        _project.overlays.add(overlay);
      });
      _saveProject();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to import logo: $e')),
      );
    }
  }

  void _addText() {
    final textOverlay = OverlayItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: 'text',
      timelineStart: _currentPosition,
      duration: 5.0, // Default 5 seconds
      properties: {
        'text': 'Enter text here',
        'fontFamily': 'Arial',
        'fontSize': 32.0,
        'textColor': 0xFFFFFFFF, // White
        'backgroundColor': 0x80000000, // Semi-transparent black
        'fontWeight': 'normal', // normal, bold
        'fontStyle': 'normal', // normal, italic
      },
      x: 0.5, // Center
      y: 0.5,
      scale: 1.0,
      opacity: 1.0,
    );

    setState(() {
      _project.textOverlays.add(textOverlay);
      _selectedTextIndex = _project.textOverlays.length - 1;
      // Clear other selections
      _selectedVideoClipIndex = null;
      _selectedAudioClipIndex = null;
      _selectedBgMusicClipIndex = null;
      _selectedOverlayIndex = null;
    });
    _saveProject();
  }

  void _togglePlayback() {
    if (_playbackTimer != null) {
      // Pause
      _playbackTimer?.cancel();
      _playbackTimer = null;
      try {
        (_usePrimaryPlayer ? _player : _playerAlt)?.pause();
      } catch (_) {}
      // Pause audio/bgmusic players
      for (final p in _audioTrackPlayers) {
        try { p.pause(); } catch (_) {}
      }
      for (final p in _bgMusicPlayers) {
        try { p.pause(); } catch (_) {}
      }
      _loadedAudioFiles.clear();
      _loadedBgMusicFiles.clear();
      setState(() {}); // Update icon
    } else {
      // Check if there are any video clips - if not, show warning and don't play
      if (_project.videoClips.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No video clips! Add video clips to timeline first.'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      
      // Play - reset to start if at end
      if (_currentPosition >= _trueTotalDuration - 0.1) {
        _currentPosition = 0;
        _loadedFilePrimary = null;
        _loadedFileAlt = null;
        _loadedAudioFiles.clear();
        _loadedBgMusicFiles.clear();
      }
      _startMasterClock();
      _syncPlayerToTimeline();
      // Don't sync audio/bgmusic on play - user can preview from right panel
      setState(() {});
    }
  }
  
  /// Start audio and bgmusic players once when playback begins
  /// This is lighter than constant syncing - players run independently
  void _startAudioPlayersOnce() {
    // Start audio clips that overlap with current position
    for (int i = 0; i < _project.audioClips.length; i++) {
      final clip = _project.audioClips[i];
      final clipEnd = clip.timelineStart + clip.effectiveDuration;
      
      if (_currentPosition >= clip.timelineStart && _currentPosition < clipEnd && !_project.isAudioTrackMuted) {
        // Ensure player exists
        while (_audioTrackPlayers.length <= i) {
          _audioTrackPlayers.add(Player());
        }
        final player = _audioTrackPlayers[i];
        final localPos = (_currentPosition - clip.timelineStart) * clip.speed + clip.trimStart;
        
        // Start playback async
        Future(() async {
          try {
            await player.open(Media(clip.filePath), play: true);
            player.setVolume(clip.volume * _project.audioMasterVolume * 100);
            player.setRate(clip.speed);
            await player.seek(Duration(milliseconds: (localPos * 1000).round()));
          } catch (e) {}
        });
      }
    }
    
    // Start bgmusic clips that overlap with current position
    for (int i = 0; i < _project.bgMusicClips.length; i++) {
      final clip = _project.bgMusicClips[i];
      final clipEnd = clip.timelineStart + clip.effectiveDuration;
      
      if (_currentPosition >= clip.timelineStart && _currentPosition < clipEnd && !_project.isBgMusicTrackMuted) {
        while (_bgMusicPlayers.length <= i) {
          _bgMusicPlayers.add(Player());
        }
        final player = _bgMusicPlayers[i];
        final localPos = (_currentPosition - clip.timelineStart) * clip.speed + clip.trimStart;
        
        Future(() async {
          try {
            await player.open(Media(clip.filePath), play: true);
            player.setVolume(clip.volume * _project.bgMusicMasterVolume * 100);
            player.setRate(clip.speed);
            await player.seek(Duration(milliseconds: (localPos * 1000).round()));
          } catch (e) {}
        });
      }
    }
  }

  /// Update volumes of all playing tracks in real-time
  void _updatePlaybackVolumes() {
    // Update video player volume
    final currentP = _usePrimaryPlayer ? _player : _playerAlt;
    if (currentP != null && _playbackTimer != null) {
      final activeClip = _project.videoClips.where((c) {
        final clipEnd = c.timelineStart + c.effectiveDuration;
        return _currentPosition >= c.timelineStart && _currentPosition < clipEnd;
      }).firstOrNull;
      
      if (activeClip != null) {
        final effectiveVolume = (_project.isVideoTrackMuted || activeClip.isMuted || activeClip.volume <= 0) 
            ? 0.0 
            : (activeClip.volume * _project.videoMasterVolume * 100);
        try {
          currentP.setVolume(effectiveVolume);
        } catch (_) {}
      }
    }
    
    // Update audio track players
    for (int i = 0; i < _audioTrackPlayers.length && i < _project.audioClips.length; i++) {
      final player = _audioTrackPlayers[i];
      final clip = _project.audioClips[i];
      try {
        if (player.state.playing) {
          final volume = _project.isAudioTrackMuted || clip.isMuted
              ? 0.0
              : (clip.volume * _project.audioMasterVolume * 100);
          player.setVolume(volume);
        }
      } catch (_) {}
    }
    
    // Update bgmusic players
    for (int i = 0; i < _bgMusicPlayers.length && i < _project.bgMusicClips.length; i++) {
      final player = _bgMusicPlayers[i];
      final clip = _project.bgMusicClips[i];
      try {
        if (player.state.playing) {
          final volume = _project.isBgMusicTrackMuted || clip.isMuted
              ? 0.0
              : (clip.volume * _project.bgMusicMasterVolume * 100);
          player.setVolume(volume);
        }
      } catch (_) {}
    }
  }

  void _startMasterClock() {
    // User requested low CPU usage, updating at 1fps
    const tick = Duration(milliseconds: 1000); 
    _playbackTimer?.cancel();
    
    int frameCount = 0;
    _playbackTimer = Timer.periodic(tick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      _currentPosition += tick.inMilliseconds / 1000.0;
      
      if (_currentPosition > _trueTotalDuration) {
        _currentPosition = _trueTotalDuration;
        _togglePlayback(); // Stop at end
        return;
      }
      
      frameCount++;
      
      // Update UI
      setState(() {});
      
      // Sync VIDEO player only every 3 seconds
      // Audio/BGMusic are NOT synced here - user can preview from right panel
      if (frameCount % 3 == 0) {
        _syncPlayerToTimeline();
      }
    });
  }
  
  // Track which file is currently open in player to avoid reopening
  String? _currentLoadedFilePath;
  double? _currentPlayerSpeed;

  void _syncPlayerToTimeline() {
    VideoClip? activeClip;
    VideoClip? nextClip;
    
    // Sort clips to find sequential next clip reliably
    final sortedClips = List<VideoClip>.from(_project.videoClips)
      ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
    
    for (int i = 0; i < sortedClips.length; i++) {
        final clip = sortedClips[i];
        final clipEnd = clip.timelineStart + clip.effectiveDuration;
        if (_currentPosition >= clip.timelineStart && _currentPosition < clipEnd) {
            activeClip = clip;
            if (i + 1 < sortedClips.length) nextClip = sortedClips[i+1];
            break;
        }
    }

    // Guard against null _playerAlt
    if (_playerAlt == null) return;

    final activePlayer = _usePrimaryPlayer ? _player : _playerAlt!;
    final inactivePlayer = _usePrimaryPlayer ? _playerAlt! : _player;

    if (activeClip == null) {
      // Gap - pause players
      try { if (activePlayer.state.playing) activePlayer.pause(); } catch (_) {}
      try { if (inactivePlayer.state.playing) inactivePlayer.pause(); } catch (_) {}
      return;
    }

    // Check if we need to swap players (if inactive has the clip preloaded)
    final activeLoaded = _usePrimaryPlayer ? _loadedFilePrimary : _loadedFileAlt;
    final inactiveLoaded = _usePrimaryPlayer ? _loadedFileAlt : _loadedFilePrimary;

    if (activeLoaded != activeClip.filePath && inactiveLoaded == activeClip.filePath) {
      // Swap!
      _usePrimaryPlayer = !_usePrimaryPlayer;
    }
    
    // Re-evaluate active player after potential swap
    final currentP = _usePrimaryPlayer ? _player : _playerAlt!;
    final altP = _usePrimaryPlayer ? _playerAlt! : _player;
    final currentLoaded = _usePrimaryPlayer ? _loadedFilePrimary : _loadedFileAlt;
    
    // Load if needed
    if (currentLoaded != activeClip.filePath) {
       try {
         currentP.open(Media(activeClip.filePath), play: _playbackTimer != null);
       } catch (_) {}
       if (_usePrimaryPlayer) _loadedFilePrimary = activeClip.filePath; else _loadedFileAlt = activeClip.filePath;
    }

    // Set Rate
    try {
      if (currentP.state.rate != activeClip.speed) {
        currentP.setRate(activeClip.speed);
      }
    } catch (_) {}

    // Calculate local position
    final effectiveTime = _currentPosition - activeClip.timelineStart;
    final localPosition = (effectiveTime * activeClip.speed) + activeClip.trimStart;
    
    // Check trim end
    final maxLocalPosition = activeClip.originalDuration - activeClip.trimEnd;
    if (localPosition >= maxLocalPosition) {
       try { if (currentP.state.playing) currentP.pause(); } catch (_) {}
       return;
    }
    
    // Drift correction
    try {
      final playerPosition = currentP.state.position.inMilliseconds / 1000.0;
      final drift = (playerPosition - localPosition).abs();
      
      if (drift > 1.0) { 
        currentP.seek(Duration(milliseconds: (localPosition * 1000).round()));
      }
    } catch (_) {}
    
    // Preload next clip
    if (nextClip != null && nextClip.filePath != activeClip.filePath) {
       final altLoaded = _usePrimaryPlayer ? _loadedFileAlt : _loadedFilePrimary;
       if (altLoaded != nextClip.filePath) {
           try {
             altP.open(Media(nextClip.filePath), play: false);
             altP.seek(Duration(milliseconds: (nextClip.trimStart * 1000).round()));
           } catch (_) {}
           if (_usePrimaryPlayer) _loadedFileAlt = nextClip.filePath; else _loadedFilePrimary = nextClip.filePath;
       }
    }
    
    // Play control
    try {
      if (_playbackTimer != null) {
          if (!currentP.state.playing) currentP.play();
          if (altP.state.playing) altP.pause(); 
      } else {
          if (currentP.state.playing) currentP.pause();
          if (altP.state.playing) altP.pause();
      }
    } catch (_) {}
  }

  /// Synchronize audio clips to the timeline.
  /// Runs even in "no video" regions to ensure clips stop at their timeline end,
  /// start at the correct time, and seeking works without freezing the UI.
  void _syncAudioTracks() {
    // During scrubbing, do NOT open/start audio players (it can freeze UI).
    // Just pause any currently playing ones.
    if (_isUserScrubbing) {
      for (final p in _audioTrackPlayers) {
        try {
          if (p.state.playing) p.pause();
        } catch (_) {}
      }
      return;
    }
    
    // Quick check: is current position within ANY audio clip range?
    bool hasActiveClip = false;
    for (final clip in _project.audioClips) {
      if (_currentPosition >= clip.timelineStart && 
          _currentPosition < (clip.timelineStart + clip.effectiveDuration)) {
        hasActiveClip = true;
        break;
      }
    }
    
    // If no active audio clips at current position, pause all audio players
    if (!hasActiveClip) {
      for (final p in _audioTrackPlayers) {
        try {
          if (p.state.playing) p.pause();
        } catch (_) {}
      }
      _loadedAudioFiles.clear();
      for (int i = 0; i < _audioOpenInProgress.length; i++) {
        _audioOpenInProgress[i] = false;
      }
      return;
    }
    
    for (int i = 0; i < _project.audioClips.length; i++) {
      final clip = _project.audioClips[i];
      final clipEnd = clip.timelineStart + clip.effectiveDuration;

      final isInRange = _currentPosition >= clip.timelineStart && _currentPosition < clipEnd;
      final canPlay = _playbackTimer != null && !_project.isAudioTrackMuted && !clip.isMuted;

      if (isInRange) {
        // Lazily create player only when we need it (prevents big stalls with many clips)
        while (_audioTrackPlayers.length <= i) {
          _audioTrackPlayers.add(Player());
        }
        final player = _audioTrackPlayers[i];

        // Calculate local position within the clip
        final localPos = (_currentPosition - clip.timelineStart) * clip.speed + clip.trimStart;

        if (canPlay) {
          // Safely check if player is already playing
          bool isPlaying = false;
          try {
            isPlaying = player.state.playing;
          } catch (_) {}
          
          final shouldReload = !isPlaying || _loadedAudioFiles[i] != clip.filePath;
          if (shouldReload) {
            // Avoid scheduling multiple opens concurrently for the same player index.
            if (_audioOpenInProgress[i] == true) {
              continue;
            }
            _audioOpenInProgress[i] = true;

            _loadedAudioFiles[i] = clip.filePath;
            final localSeek = Duration(milliseconds: (localPos * 1000).round());

            // Use unawaited Future to prevent blocking UI
            Future.delayed(const Duration(milliseconds: 10), () async {
              try {
                await player.open(Media(clip.filePath), play: true);
                player.setVolume(clip.volume * _project.audioMasterVolume * 100);
                player.setRate(clip.speed);
                if (clip.pitch != 1.0) player.setPitch(clip.pitch);
                await player.seek(localSeek);
              } catch (_) {
                // Silent error
              } finally {
                _audioOpenInProgress[i] = false;
              }
            });
          } else {
            // Keep dynamic params in sync while playing
            try {
              player.setVolume(clip.volume * _project.audioMasterVolume * 100);
              if (player.state.rate != clip.speed) player.setRate(clip.speed);
              if (clip.pitch != 1.0) player.setPitch(clip.pitch);
            } catch (_) {}
          }
        } else {
          // Paused or muted - safely check and pause
          try {
            if (player.state.playing) player.pause();
          } catch (_) {}
        }
      } else {
        // Outside this clip - stop playback
        if (i < _audioTrackPlayers.length) {
          final player = _audioTrackPlayers[i];
          try {
            if (player.state.playing) player.pause();
          } catch (_) {}
        }
        _loadedAudioFiles.remove(i);
        _audioOpenInProgress[i] = false;
      }
    }
  }
  
  // Background music track synchronization
  // Track loaded bgmusic files to avoid reopening
  final Map<int, String> _loadedBgMusicFiles = {};
  
  void _syncBgMusicTracks() {
    // Early exit if no bgmusic clips
    if (_project.bgMusicClips.isEmpty) return;

    // During scrubbing, do NOT open/start bgmusic players (it can freeze UI).
    // Just pause any currently playing ones.
    if (_isUserScrubbing) {
      for (final p in _bgMusicPlayers) {
        try {
          if (p.state.playing) p.pause();
        } catch (_) {}
      }
      return;
    }
    
    // Quick check: is current position within ANY bgmusic clip range?
    bool hasActiveClip = false;
    for (final clip in _project.bgMusicClips) {
      if (_currentPosition >= clip.timelineStart && 
          _currentPosition < (clip.timelineStart + clip.effectiveDuration)) {
        hasActiveClip = true;
        break;
      }
    }
    
    // If no active bgmusic clips at current position, pause all bgmusic players
    // This applies both when paused AND when playing (e.g., playhead past all bgmusic clips)
    if (!hasActiveClip) {
      for (final p in _bgMusicPlayers) {
        try {
          if (p.state.playing) p.pause();
        } catch (_) {}
      }
      // Clear loaded files so they reload when we seek back into range
      _loadedBgMusicFiles.clear();
      for (int i = 0; i < _bgMusicOpenInProgress.length; i++) {
        _bgMusicOpenInProgress[i] = false;
      }
      return;
    }
    
    for (int i = 0; i < _project.bgMusicClips.length; i++) {
      final clip = _project.bgMusicClips[i];
      final clipEnd = clip.timelineStart + clip.effectiveDuration;
      
      // Skip live streaming clip (it's still being written)
      if (_isLiveStreaming && clip.filePath == _liveStreamingMusicFile) {
        continue;
      }
      
      // Check if current position is within this clip's range
      if (_currentPosition >= clip.timelineStart && _currentPosition < clipEnd) {
        // Lazily create player only when needed
        while (_bgMusicPlayers.length <= i) {
          _bgMusicPlayers.add(Player());
        }
        final player = _bgMusicPlayers[i];

        // Calculate local position within the clip
        final localPos = (_currentPosition - clip.timelineStart) * clip.speed + clip.trimStart;
        
        // Check if we need to load/play this clip (and track is not muted)
        if (_playbackTimer != null && !_project.isBgMusicTrackMuted && !clip.isMuted) {
          // Safely check if player is already playing
          bool isPlaying = false;
          try {
            isPlaying = player.state.playing;
          } catch (_) {}
          
          // We're playing - only open if not already playing this file
          if (!isPlaying || _loadedBgMusicFiles[i] != clip.filePath) {
            if (_bgMusicOpenInProgress[i] == true) {
              continue;
            }
            _bgMusicOpenInProgress[i] = true;

            _loadedBgMusicFiles[i] = clip.filePath;
            final localSeek = Duration(milliseconds: (localPos * 1000).round());
            // Use unawaited Future to prevent blocking
            Future(() async {
              try {
                await player.open(Media(clip.filePath), play: true);
                player.setVolume(clip.volume * _project.bgMusicMasterVolume * 100);
                player.setRate(clip.speed);
                if (clip.pitch != 1.0) player.setPitch(clip.pitch);
                await player.seek(localSeek);
              } catch (e) {
                // Silent error
              } finally {
                _bgMusicOpenInProgress[i] = false;
              }
            });
          } else {
            // Keep dynamic params in sync while playing
            try {
              player.setVolume(clip.volume * _project.bgMusicMasterVolume * 100);
              if (player.state.rate != clip.speed) player.setRate(clip.speed);
              if (clip.pitch != 1.0) player.setPitch(clip.pitch);
            } catch (_) {}
          }
        } else {
          // Paused or muted - safely check and pause
          try {
            if (player.state.playing) player.pause();
          } catch (_) {}
        }
      } else {
        // Position is outside this clip - stop playback
        if (i < _bgMusicPlayers.length) {
          final player = _bgMusicPlayers[i];
          try {
            if (player.state.playing) player.pause();
          } catch (_) {}
        }
        _loadedBgMusicFiles.remove(i);
        _bgMusicOpenInProgress[i] = false;
      }
    }
  }

  void _seekTo(double position) {
    // Always pause playback when user seeks/clicks on timeline
    if (_playbackTimer != null) {
      _playbackTimer?.cancel();
      _playbackTimer = null;
      try {
        (_usePrimaryPlayer ? _player : _playerAlt)?.pause();
      } catch (_) {}
      for (final p in _audioTrackPlayers) {
        try { p.pause(); } catch (_) {}
      }
      for (final p in _bgMusicPlayers) {
        try { p.pause(); } catch (_) {}
      }
    }
    
    // Just update position - don't sync player to avoid UI freeze
    // Video will sync when user clicks play
    setState(() {
      _currentPosition = position;
    });
  }

  void _onSeekStart() {
    _isUserScrubbing = true;
    
    // Always pause playback when scrubbing starts
    if (_playbackTimer != null) {
      _playbackTimer?.cancel();
      _playbackTimer = null;
      try {
        (_usePrimaryPlayer ? _player : _playerAlt)?.pause();
      } catch (_) {}
      for (final p in _audioTrackPlayers) {
        try { p.pause(); } catch (_) {}
      }
      for (final p in _bgMusicPlayers) {
        try { p.pause(); } catch (_) {}
      }
      setState(() {}); // Update play button icon
    }
  }

  void _onSeekEnd() {
    _isUserScrubbing = false;
    // Do NOT sync player here - it causes UI freeze
    // Video will sync when user clicks play
  }

  void _splitSelectedClip() {
    if (_selectedVideoClipIndex == null) return;

    final clip = _project.videoClips[_selectedVideoClipIndex!];
    final splitPoint = _currentPosition - clip.timelineStart;

    if (splitPoint <= 0 || splitPoint >= clip.effectiveDuration) {
      // Invalid split point - do nothing
      return;
    }

    // Create two clips from the split
    final clip1 = clip.copyWith(
      trimEnd: clip.originalDuration - clip.trimStart - splitPoint,
    );

    final clip2 = clip.copyWith(
      id: '${clip.id}_split',
      timelineStart: clip.timelineStart + splitPoint,
      trimStart: clip.trimStart + splitPoint,
      trimEnd: clip.trimEnd,
    );

    setState(() {
      _project.videoClips[_selectedVideoClipIndex!] = clip1;
      _project.videoClips.insert(_selectedVideoClipIndex! + 1, clip2);
    });

    _saveProject();
  }

  /// Split any clip under the playhead across all tracks (video, audio, bg music, overlays/text)
  void _splitAtPlayheadAllTracks() {
    final pos = _currentPosition;
    var changed = false;

    // Video clips
    for (int i = 0; i < _project.videoClips.length; i++) {
      final clip = _project.videoClips[i];
      final splitPoint = pos - clip.timelineStart;
      if (splitPoint > 0 && splitPoint < clip.effectiveDuration) {
        final clip1 = clip.copyWith(
          trimEnd: clip.originalDuration - clip.trimStart - splitPoint,
        );
        final clip2 = clip.copyWith(
          id: '${clip.id}_split',
          timelineStart: clip.timelineStart + splitPoint,
          trimStart: clip.trimStart + splitPoint,
          trimEnd: clip.trimEnd,
        );
        setState(() {
          _project.videoClips[i] = clip1;
          _project.videoClips.insert(i + 1, clip2);
        });
        changed = true;
        // Advance index to skip newly inserted clip
        i++;
      }
    }

    // Audio clips (manual)
    for (int i = 0; i < _project.audioClips.length; i++) {
      final clip = _project.audioClips[i];
      final splitPoint = pos - clip.timelineStart;
      if (splitPoint > 0 && splitPoint < clip.effectiveDuration) {
        final clip1 = clip.copyWith(
          trimEnd: clip.duration - clip.trimStart - splitPoint,
        );
        final clip2 = clip.copyWith(
          id: '${clip.id}_split',
          timelineStart: clip.timelineStart + splitPoint,
          trimStart: clip.trimStart + splitPoint,
          trimEnd: clip.trimEnd,
        );
        setState(() {
          _project.audioClips[i] = clip1;
          _project.audioClips.insert(i + 1, clip2);
        });
        changed = true;
        i++;
      }
    }

    // BG music clips
    for (int i = 0; i < _project.bgMusicClips.length; i++) {
      final clip = _project.bgMusicClips[i];
      final splitPoint = pos - clip.timelineStart;
      if (splitPoint > 0 && splitPoint < clip.effectiveDuration) {
        final clip1 = clip.copyWith(
          trimEnd: clip.duration - clip.trimStart - splitPoint,
        );
        final clip2 = clip.copyWith(
          id: '${clip.id}_split',
          timelineStart: clip.timelineStart + splitPoint,
          trimStart: clip.trimStart + splitPoint,
          trimEnd: clip.trimEnd,
        );
        setState(() {
          _project.bgMusicClips[i] = clip1;
          _project.bgMusicClips.insert(i + 1, clip2);
        });
        changed = true;
        i++;
      }
    }

    // Overlays and text overlays
    // For overlays we'll duplicate the item and split durations
    void _splitOverlayList(List<OverlayItem> list) {
      for (int i = 0; i < list.length; i++) {
        final o = list[i];
        final splitPoint = pos - o.timelineStart;
        if (splitPoint > 0 && splitPoint < o.duration) {
          final o1 = OverlayItem(
            id: o.id,
            type: o.type,
            timelineStart: o.timelineStart,
            duration: splitPoint,
            x: o.x,
            y: o.y,
            scale: o.scale,
            opacity: o.opacity,
            properties: Map<String, dynamic>.from(o.properties),
          );
          final o2 = OverlayItem(
            id: '${o.id}_split',
            type: o.type,
            timelineStart: o.timelineStart + splitPoint,
            duration: o.duration - splitPoint,
            x: o.x,
            y: o.y,
            scale: o.scale,
            opacity: o.opacity,
            properties: Map<String, dynamic>.from(o.properties),
          );
          setState(() {
            list[i] = o1;
            list.insert(i + 1, o2);
          });
          changed = true;
          i++;
        }
      }
    }

    _splitOverlayList(_project.overlays);
    _splitOverlayList(_project.textOverlays);

    if (changed) {
      _saveProject();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Split performed at playhead')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No clip under playhead to split')));
    }
  }

  void _deleteSelectedClip() {
    if (_selectedVideoClipIndex != null) {
      setState(() {
        _project.videoClips.removeAt(_selectedVideoClipIndex!);
        _selectedVideoClipIndex = null;
      });
      _saveProject();
    } else if (_selectedAudioClipIndex != null) {
      setState(() {
        _project.audioClips.removeAt(_selectedAudioClipIndex!);
        _selectedAudioClipIndex = null;
      });
      _saveProject();
    } else if (_selectedBgMusicClipIndex != null) {
      setState(() {
        _project.bgMusicClips.removeAt(_selectedBgMusicClipIndex!);
        _selectedBgMusicClipIndex = null;
      });
      _saveProject();
    } else if (_selectedOverlayIndex != null) {
      setState(() {
        _project.overlays.removeAt(_selectedOverlayIndex!);
        _selectedOverlayIndex = null;
      });
      _saveProject();
    }
  }
  
  /// Select all items in the currently active layer (Ctrl+A)
  void _selectAllInActiveLayer() {
    int count = 0;
    String layerName = '';
    
    setState(() {
      switch (_activeLayer) {
        case 'video':
          _selectedVideoClips = Set.from(List.generate(_project.videoClips.length, (i) => i));
          count = _selectedVideoClips.length;
          layerName = 'Video';
          break;
        case 'audio':
          _selectedAudioClips = Set.from(List.generate(_project.audioClips.length, (i) => i));
          count = _selectedAudioClips.length;
          layerName = 'Audio';
          break;
        case 'bgMusic':
          _selectedBgMusicClips = Set.from(List.generate(_project.bgMusicClips.length, (i) => i));
          count = _selectedBgMusicClips.length;
          layerName = 'BG Music';
          break;
        case 'overlay':
          _selectedOverlays = Set.from(List.generate(_project.overlays.length, (i) => i));
          count = _selectedOverlays.length;
          layerName = 'Overlay';
          break;
        case 'text':
          _selectedTextOverlays = Set.from(List.generate(_project.textOverlays.length, (i) => i));
          count = _selectedTextOverlays.length;
          layerName = 'Text';
          break;
      }
    });
    
    if (count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Selected $count $layerName clip${count > 1 ? 's' : ''} (Press Delete to remove)'),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.blue.shade700,
        ),
      );
    }
  }
  
  /// Delete all selected items or single selected item
  Future<void> _deleteSelectedItems() async {
    bool hasChanges = false;
    int deletedCount = 0;
    
    setState(() {
      // Delete multiple selected video clips
      if (_selectedVideoClips.isNotEmpty) {
        final indices = _selectedVideoClips.toList()..sort((a, b) => b.compareTo(a));
        for (final index in indices) {
          if (index < _project.videoClips.length) {
            _project.videoClips.removeAt(index);
            hasChanges = true;
            deletedCount++;
          }
        }
        _selectedVideoClips.clear();
        _selectedVideoClipIndex = null;
      }
      // Delete single selected video clip
      else if (_selectedVideoClipIndex != null) {
        _project.videoClips.removeAt(_selectedVideoClipIndex!);
        _selectedVideoClipIndex = null;
        hasChanges = true;
        deletedCount++;
      }
      
      // Delete multiple selected audio clips
      if (_selectedAudioClips.isNotEmpty) {
        final indices = _selectedAudioClips.toList()..sort((a, b) => b.compareTo(a));
        for (final index in indices) {
          if (index < _project.audioClips.length) {
            _project.audioClips.removeAt(index);
            hasChanges = true;
            deletedCount++;
          }
        }
        _selectedAudioClips.clear();
        _selectedAudioClipIndex = null;
      }
      // Delete single selected audio clip
      else if (_selectedAudioClipIndex != null) {
        _project.audioClips.removeAt(_selectedAudioClipIndex!);
        _selectedAudioClipIndex = null;
        hasChanges = true;
        deletedCount++;
      }
      
      // Delete multiple selected bg music clips
      if (_selectedBgMusicClips.isNotEmpty) {
        final indices = _selectedBgMusicClips.toList()..sort((a, b) => b.compareTo(a));
        for (final index in indices) {
          if (index < _project.bgMusicClips.length) {
            _project.bgMusicClips.removeAt(index);
            hasChanges = true;
            deletedCount++;
          }
        }
        _selectedBgMusicClips.clear();
        _selectedBgMusicClipIndex = null;
      }
      // Delete single selected bg music clip
      else if (_selectedBgMusicClipIndex != null) {
        _project.bgMusicClips.removeAt(_selectedBgMusicClipIndex!);
        _selectedBgMusicClipIndex = null;
        hasChanges = true;
        deletedCount++;
      }
      
      // Delete multiple selected overlays
      if (_selectedOverlays.isNotEmpty) {
        final indices = _selectedOverlays.toList()..sort((a, b) => b.compareTo(a));
        for (final index in indices) {
          if (index < _project.overlays.length) {
            _project.overlays.removeAt(index);
            hasChanges = true;
            deletedCount++;
          }
        }
        _selectedOverlays.clear();
        _selectedOverlayIndex = null;
      }
      // Delete single selected overlay
      else if (_selectedOverlayIndex != null) {
        _project.overlays.removeAt(_selectedOverlayIndex!);
        _selectedOverlayIndex = null;
        hasChanges = true;
        deletedCount++;
      }
      
      // Delete multiple selected text overlays
      if (_selectedTextOverlays.isNotEmpty) {
        final indices = _selectedTextOverlays.toList()..sort((a, b) => b.compareTo(a));
        for (final index in indices) {
          if (index < _project.textOverlays.length) {
            _project.textOverlays.removeAt(index);
            hasChanges = true;
            deletedCount++;
          }
        }
        _selectedTextOverlays.clear();
        _selectedTextIndex = null;
      }
      // Delete single selected text overlay
      else if (_selectedTextIndex != null) {
        _project.textOverlays.removeAt(_selectedTextIndex!);
        _selectedTextIndex = null;
        hasChanges = true;
        deletedCount++;
      }
    });
    
    if (hasChanges) {
      await _saveProject();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted $deletedCount item${deletedCount > 1 ? 's' : ''}'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }
  
  // ==============================================
  // UNDO / REDO SYSTEM
  // ==============================================
  
  /// Save current state to undo history (call before making changes)
  void _saveUndoState() {
    if (_isUndoRedoInProgress) return; // Don't save during undo/redo operations
    
    try {
      // Convert project to JSON string for snapshot
      final snapshot = jsonEncode(_project.toJson());
      
      // Add to history
      _undoHistory.add(snapshot);
      
      // Limit history size
      while (_undoHistory.length > _maxUndoHistory) {
        _undoHistory.removeAt(0);
      }
      
      // Clear redo history when new changes are made
      _redoHistory.clear();
    } catch (e) {
      // Silent error handling
    }
  }
  
  /// Undo last change (Ctrl+Z)
  void _undo() {
    if (_undoHistory.isEmpty) {
      return;
    }
    
    try {
      _isUndoRedoInProgress = true;
      
      // Save current state to redo history
      final currentSnapshot = jsonEncode(_project.toJson());
      _redoHistory.add(currentSnapshot);
      
      // Pop last state from undo history
      final previousSnapshot = _undoHistory.removeLast();
      
      // Restore project from snapshot
      final restoredData = jsonDecode(previousSnapshot) as Map<String, dynamic>;
      setState(() {
        _project = VideoProject.fromJson(restoredData);
        // Clear selections
        _selectedVideoClipIndex = null;
        _selectedAudioClipIndex = null;
        _selectedBgMusicClipIndex = null;
        _selectedOverlayIndex = null;
        _selectedTextIndex = null;
        _selectedVideoClips.clear();
        _selectedAudioClips.clear();
        _selectedBgMusicClips.clear();
        _selectedOverlays.clear();
        _selectedTextOverlays.clear();
      });
      
      // Save to disk (without adding to undo history)
      _saveProject(saveUndo: false);
    } catch (e) {
      // Silent error handling
    } finally {
      _isUndoRedoInProgress = false;
    }
  }
  
  /// Redo last undone change (Ctrl+Y)
  void _redo() {
    if (_redoHistory.isEmpty) {
      return;
    }
    
    try {
      _isUndoRedoInProgress = true;
      
      // Save current state to undo history
      final currentSnapshot = jsonEncode(_project.toJson());
      _undoHistory.add(currentSnapshot);
      
      // Pop last state from redo history
      final nextSnapshot = _redoHistory.removeLast();
      
      // Restore project from snapshot
      final restoredData = jsonDecode(nextSnapshot) as Map<String, dynamic>;
      setState(() {
        _project = VideoProject.fromJson(restoredData);
        // Clear selections
        _selectedVideoClipIndex = null;
        _selectedAudioClipIndex = null;
        _selectedBgMusicClipIndex = null;
        _selectedOverlayIndex = null;
        _selectedTextIndex = null;
        _selectedVideoClips.clear();
        _selectedAudioClips.clear();
        _selectedBgMusicClips.clear();
        _selectedOverlays.clear();
        _selectedTextOverlays.clear();
      });
      
      // Save to disk (without adding to undo history)
      _saveProject(saveUndo: false);
    } catch (e) {
      // Silent error handling
    } finally {
      _isUndoRedoInProgress = false;
    }
  }
  
  /// Auto Ripple Fill: Removes gaps between clips by shifting them to be contiguous
  /// Works on all tracks: Video, Audio, and BG Music
  void _autoRippleFill() {
    // Process Video clips
    if (_project.videoClips.isNotEmpty) {
      _project.videoClips.sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
      double currentEnd = 0;
      for (int i = 0; i < _project.videoClips.length; i++) {
        final clip = _project.videoClips[i];
        _project.videoClips[i] = clip.copyWith(timelineStart: currentEnd);
        currentEnd += clip.effectiveDuration;
      }
    }
    
    // Process Audio clips
    if (_project.audioClips.isNotEmpty) {
      _project.audioClips.sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
      double currentEnd = 0;
      for (int i = 0; i < _project.audioClips.length; i++) {
        final clip = _project.audioClips[i];
        _project.audioClips[i] = clip.copyWith(timelineStart: currentEnd);
        currentEnd += clip.effectiveDuration;
      }
    }
    
    // Process BG Music clips
    if (_project.bgMusicClips.isNotEmpty) {
      _project.bgMusicClips.sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
      double currentEnd = 0;
      for (int i = 0; i < _project.bgMusicClips.length; i++) {
        final clip = _project.bgMusicClips[i];
        _project.bgMusicClips[i] = clip.copyWith(timelineStart: currentEnd);
        currentEnd += clip.effectiveDuration;
      }
    }
    
    // Batch UI update after all processing
    setState(() {});
    
    // Use debounced save to prevent UI freeze
    _saveProjectDebounced();
    // Silent success - visual feedback is the updated timeline
  }
  
  /// Calculate pixels per second based on zoom factor and available width
  double _calculatePixelsPerSecond(double availableWidth) {
    if (_project.totalDuration <= 0) return 50.0;
    // At zoomFactor 1.0, the entire project fits in the available width
    return (availableWidth / _project.totalDuration) * _zoomFactor;
  }

  Future<void> _generateBgMusic() async {
    if (_apiKeyController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please set your Gemini API key in Settings first')),
      );
      return;
    }

    // If already generating, stop it
    if (_isGeneratingBgMusic) {
      await _stopBgMusicGeneration();
      return;
    }

    setState(() => _isGeneratingBgMusic = true);

    try {
      // Initialize Lyria Music Service
      final musicService = LyriaMusicService();
      
      // Start live stream recording to timeline
      _startLiveStreamRecording();
      
      // Listen to audio stream and send chunks to timeline
      musicService.audioStream.listen((data) {
        if (_isGeneratingBgMusic) {
          // Calculate chunk duration (48kHz, 16-bit stereo)
          final chunkDuration = data.length / (48000 * 2 * 2);
          _handleLiveAudioChunk(data, _liveStreamingDuration + chunkDuration);
        }
      });
      
      // Connect and start streaming
      await musicService.connect(_apiKeyController.text);
      await musicService.setPrompt(_bgMusicPromptController.text);
      await musicService.setConfig(LyriaConfig(bpm: 120, density: 0.5, brightness: 0.5));
      await musicService.play();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🎵 AI Music streaming to timeline...')),
      );
      
      // Store the service to stop later
      _activeMusicService = musicService;
      
    } catch (e) {
      setState(() => _isGeneratingBgMusic = false);
      _stopLiveStreamRecording();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to generate BG music: $e')),
      );
    }
  }
  
  Future<void> _stopBgMusicGeneration() async {
    try {
      _activeMusicService?.stop();
      _activeMusicService?.dispose();
      _activeMusicService = null;
    } catch (e) {
    }
    
    _stopLiveStreamRecording();
    
    setState(() => _isGeneratingBgMusic = false);
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('BG Music generation stopped and saved')),
    );
    
    _saveProject();
  }
  
  // Store active music service for stopping
  LyriaMusicService? _activeMusicService;

  // --- Audio Preview Logic ---

  Future<void> _toggleAudioPreview(AudioClip clip) async {
    if (_isAudioPreviewPlaying) {
      await _audioPreviewPlayer.stop();
      setState(() => _isAudioPreviewPlaying = false);
    } else {
      try {
        await _audioPreviewPlayer.open(Media(clip.filePath), play: false);
        
        // Apply Settings
        await _audioPreviewPlayer.setVolume(clip.volume * 100);
        await _audioPreviewPlayer.setRate(clip.speed);
        await _audioPreviewPlayer.setPitch(clip.pitch);
        
        // Handle Trim (Start)
        if (clip.trimStart > 0) {
          await _audioPreviewPlayer.seek(Duration(milliseconds: (clip.trimStart * 1000).toInt()));
        }

        // Play
        await _audioPreviewPlayer.play();
        setState(() => _isAudioPreviewPlaying = true);

        // Optional: Stop at trimEnd? 
        if (clip.trimEnd > 0) {
           if (clip.duration > 0) {
             final playTime = (clip.duration - clip.trimStart - clip.trimEnd) / clip.speed;
             if (playTime > 0) {
                Future.delayed(Duration(milliseconds: (playTime * 1000).toInt()), () {
                  if (_isAudioPreviewPlaying && mounted) {
                    _audioPreviewPlayer.stop();
                    setState(() => _isAudioPreviewPlaying = false);
                  }
                });
             }
           }
        }

      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play audio: $e')),
        );
      }
    }
  }

  Future<void> _exportVideo() async {
    if (_project.videoClips.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add some video clips first')),
      );
      return;
    }

    // Show export dialog
    final resolution = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export Video'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select output resolution:'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: ['720p', '1080p', '2k', '4k'].map((res) {
                return ChoiceChip(
                  label: Text(res),
                  selected: _project.exportSettings.resolution == res,
                  onSelected: (_) => Navigator.pop(ctx, res),
                );
              }).toList(),
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

    if (resolution == null) return;

    // Update export settings
    _project = _project.copyWith(
      exportSettings: _project.exportSettings.copyWith(resolution: resolution),
    );

    // Pick output location
    String? outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Exported Video',
      fileName: '${_project.name}_export.mp4',
      type: FileType.video,
    );

    if (outputPath == null) return;

    // Ensure output path has .mp4 extension (fix for FFmpeg format detection)
    if (!outputPath.toLowerCase().endsWith('.mp4')) {
      outputPath = '$outputPath.mp4';
    }

    setState(() {
      _isExporting = true;
      _exportProgress = 0;
      _exportStatus = 'Starting export...';
    });

    // Don't await - let the export run in background
    // The service is a singleton so it will continue even if screen is rebuilt
    _videoService.exportProject(
      _project,
      outputPath,
      isVideoTrackMuted: _project.isVideoTrackMuted,
      isAudioTrackMuted: _project.isAudioTrackMuted,
      isBgMusicTrackMuted: _project.isBgMusicTrackMuted,
      onProgress: (progress, step) {
        // Check if widget is still mounted before calling setState
        if (mounted) {
          setState(() {
            _exportProgress = progress;
            _exportStatus = step;
          });
        }
      },
    ).then((result) {
      // Check if widget is still mounted before updating UI
      if (mounted) {
        setState(() => _isExporting = false);

        if (result != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Export complete: $result'),
              duration: const Duration(seconds: 10),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () {
                  // Open the exported file
                  Process.run('explorer', ['/select,', result], runInShell: true);
                },
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Export failed')),
          );
        }
      }
    }).catchError((e) {
      if (mounted) {
        setState(() => _isExporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export error: $e')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    
    // Ensure Alt player is initialized (safety for hot reload)
    if (_playerAlt == null) {
       _playerAlt = Player();
       _videoControllerAlt = VideoController(_playerAlt!);
    }

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (KeyEvent event) {
        if (event is KeyDownEvent) {
          // Check if focus is on a text input field
          final primaryFocus = FocusManager.instance.primaryFocus;
          final isTextFieldFocused = primaryFocus?.context?.widget is EditableText ||
              primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>() != null ||
              primaryFocus?.context?.findAncestorWidgetOfExactType<TextFormField>() != null;
          
          // Ctrl+A - Select all in active layer
          if (event.logicalKey == LogicalKeyboardKey.keyA && 
              (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
            // Don't override Ctrl+A in text fields
            if (!isTextFieldFocused) {
              _selectAllInActiveLayer();
            }
          }
          // Ctrl+Z - Undo
          else if (event.logicalKey == LogicalKeyboardKey.keyZ && 
              (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
            if (!isTextFieldFocused) {
              _undo();
            }
          }
          // Ctrl+Y - Redo
          else if (event.logicalKey == LogicalKeyboardKey.keyY && 
              (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
            if (!isTextFieldFocused) {
              _redo();
            }
          }
          // Delete key only - removes selected items (works for individual or multi-selection)
          else if (event.logicalKey == LogicalKeyboardKey.delete && !isTextFieldFocused) {
            _saveUndoState(); // Save state before delete
            _deleteSelectedItems();
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8F9FC),
        appBar: _buildAppBar(),
        body: Column(
        children: [
          // Top section: Preview + Properties (takes ~60% of screen)
          Expanded(
            flex: 60,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left panel - Media browser (fixed width, scrollable)
                SizedBox(
                  width: 250,
                  child: _buildMediaBrowserPanel(),
                ),
                
                // Narrow column for Intro/Outro defaults
                SizedBox(
                  width: 80,
                  child: _buildDefaultsPanel(),
                ),
                
                // Center - Video preview with black bars
                // Center - Video preview + Controls
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: RepaintBoundary(child: _buildPreviewPanel()),
                      ),
                      _buildTransportControls(),
                    ],
                  ),
                ),
                
                // Right panel - Collapsible Properties (fixed width, scrollable)
                if (_showPropertiesPanel) 
                  SizedBox(
                    width: 400,
                    child: _buildPropertiesPanel(),
                  ),
              ],
            ),
          ),
          

          
          // Timeline section (takes ~40% of screen, full width)
          Expanded(
            flex: 40,
            child: RepaintBoundary(child: _buildTimelinePanel()),
          ),
          
          // Export progress bar
          if (_isExporting) _buildExportProgress(),
        ],
      ),
    ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.blue.shade700,
      foregroundColor: Colors.white,
      toolbarHeight: 36,
      leadingWidth: widget.embedded ? 16 : 40,
      leading: widget.embedded 
        ? const SizedBox(width: 16)
        : IconButton(
            icon: const Icon(Icons.arrow_back),
            iconSize: 18,
            padding: EdgeInsets.zero,
            onPressed: widget.onBack ?? () => Navigator.pop(context),
          ),
      title: Row(
        children: [
          const Icon(Icons.movie_filter, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            _project.name,
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 14),
            color: Colors.white,
            onPressed: _renameProject,
          ),
        ],
      ),
      actions: [
        // Reload UI button - forces rebuild when UI gets stuck
        IconButton(
          icon: const Icon(Icons.refresh, size: 18),
          color: Colors.white,
          tooltip: 'Reload UI',
          onPressed: () {
            // Stop all playback first
            _playbackTimer?.cancel();
            _playbackTimer = null;
            try {
              _player.pause();
              _playerAlt?.pause();
            } catch (_) {}
            for (final p in _audioTrackPlayers) {
              try { p.pause(); } catch (_) {}
            }
            for (final p in _bgMusicPlayers) {
              try { p.pause(); } catch (_) {}
            }
            _loadedAudioFiles.clear();
            _loadedBgMusicFiles.clear();
            _loadedFilePrimary = null;
            _loadedFileAlt = null;
            // Force rebuild
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('UI Reloaded'),
                duration: Duration(seconds: 1),
              ),
            );
          },
        ),
        
        // Console Log Button
        IconButton(
          icon: const Icon(Icons.terminal, size: 18),
          color: Colors.white,
          tooltip: 'View Console Logs',
          onPressed: _showConsoleLogDialog,
        ),
        
        // Save button
        TextButton.icon(
          icon: const Icon(Icons.save, size: 16),
          label: const Text('Save', style: TextStyle(color: Colors.white)),
          onPressed: _saveProject,
        ),
        const SizedBox(width: 8),
        
        // Export button
        SizedBox(
          height: 32,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.movie_creation, size: 14),
            label: const Text('Export', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: _isExporting ? null : _exportVideo,
          ),
        ),
        const SizedBox(width: 8),
        
        // Task Manager Button (ALWAYS VISIBLE)
        SizedBox(
          height: 32,
          child: OutlinedButton.icon(
            icon: Icon(
              _isExporting ? Icons.pending_actions : Icons.list_alt, 
              size: 14,
              color: _isExporting ? Colors.orange : Colors.grey.shade700,
            ),
            label: Text(
              _isExporting ? 'Exporting...' : 'Tasks',
              style: TextStyle(
                fontSize: 12,
                color: _isExporting ? Colors.orange : Colors.grey.shade700,
              ),
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: _isExporting ? Colors.orange.shade50 : Colors.white,
              side: BorderSide(
                color: _isExporting ? Colors.orange : Colors.grey.shade300,
                width: 1.5,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: _showExportTaskManager,
          ),
        ),
        const SizedBox(width: 8),
        
        // Toggle properties panel
        IconButton(
          icon: Icon(_showPropertiesPanel ? Icons.chevron_right : Icons.chevron_left),
          iconSize: 20,
          onPressed: () => setState(() => _showPropertiesPanel = !_showPropertiesPanel),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  void _showConsoleLogDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.terminal, color: Colors.blueAccent, size: 20),
            const SizedBox(width: 8),
            const Text(
              'Console Logs',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: Colors.grey, size: 18),
              tooltip: 'Clear Logs',
              onPressed: () {
                MasteringConsole.clear();
                setState(() {});
              },
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.grey, size: 18),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
        content: SizedBox(
          width: 700,
          height: 400,
          child: MasteringConsolePanel(
            height: 400,
            showHeader: false,
          ),
        ),
      ),
    );
  }

  void _showExportTaskManager() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StreamBuilder<List<dynamic>>(
        stream: _videoService.tasksStream,
        initialData: _activeTasks,
        builder: (context, snapshot) {
          final tasks = snapshot.data ?? [];
          final hasRunningTasks = tasks.any((task) => task.isRunning);
          
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.video_settings, color: Colors.orange),
                const SizedBox(width: 8),
                Text(hasRunningTasks ? 'Export Tasks (${tasks.length} Running)' : 'Export Tasks'),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            content: SizedBox(
              width: 600,
              child: tasks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline, size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 16),
                            Text(
                              'No active export tasks',
                              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: tasks.map((task) => Padding(
                          padding: const EdgeInsets.only(bottom: 12.0),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: task.isRunning ? Colors.blue.shade50 : 
                                     (task.errorMessage != null ? Colors.red.shade50 : Colors.green.shade50),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: task.isRunning ? Colors.blue.shade200 : 
                                       (task.errorMessage != null ? Colors.red.shade200 : Colors.green.shade200),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (task.isRunning)
                                      const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    else if (task.errorMessage != null)
                                      const Icon(Icons.error, color: Colors.red, size: 20)
                                    else
                                      const Icon(Icons.check_circle, color: Colors.green, size: 20),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            task.projectName,
                                            style: const TextStyle(fontWeight: FontWeight.bold),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            task.status,
                                            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                          ),
                                          if (task.errorMessage != null) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              'Error: ${task.errorMessage}',
                                              style: const TextStyle(fontSize: 11, color: Colors.red),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    Text(
                                      '${(task.progress * 100).round()}%',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: task.isRunning ? Colors.blue : 
                                               (task.errorMessage != null ? Colors.red : Colors.green),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                LinearProgressIndicator(
                                  value: task.progress,
                                  backgroundColor: Colors.grey.shade200,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    task.isRunning ? Colors.blue : 
                                    (task.errorMessage != null ? Colors.red : Colors.green),
                                  ),
                                ),
                                if (task.isRunning) ...[
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          icon: const Icon(Icons.stop, size: 16),
                                          label: const Text('Cancel Task'),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.red,
                                          ),
                                          onPressed: () async {
                                            await _videoService.cancelTask(task.taskId);
                                            if (ctx.mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(content: Text('Cancelled: ${task.projectName}')),
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )).toList(),
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMediaBrowserPanel() {
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header (fixed)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Text(
              'Media',
              style: TextStyle(
                color: Colors.blue.shade800,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          
          // UNIFIED SCROLL for all content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Import buttons in 2-column grid
                  Row(
                    children: [
                      Expanded(child: _buildCompactImportButton(Icons.video_library, 'Video', Colors.blue, _importVideos)),
                      const SizedBox(width: 4),
                      Expanded(child: _buildCompactImportButton(Icons.audiotrack, 'Audio', Colors.green, _importAudio)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(child: _buildCompactImportButton(Icons.image, 'Image', Colors.cyan, _importImage)),
                      const SizedBox(width: 4),
                      Expanded(child: _buildCompactImportButton(Icons.text_fields, 'Text', Colors.orange, _addText)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(child: _buildCompactImportButton(Icons.branding_watermark, 'Logo', Colors.amber, _importLogo)),
                      const SizedBox(width: 4),
                      const Expanded(child: SizedBox()), // Empty space for grid alignment
                    ],
                  ),
                  
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  
                  // BG Music Generator
                  Text(
                    'BG Music Generator',
                    style: TextStyle(
                      color: Colors.blue.shade800,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                TextField(
                  controller: _bgMusicPromptController,
                  style: TextStyle(color: Colors.grey.shade900, fontSize: 10),
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: 'Music style prompt...',
                    hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    contentPadding: const EdgeInsets.all(6),
                  ),
                ),
                const SizedBox(height: 4),
                Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 28,
                      child: ElevatedButton.icon(
                        icon: _isGeneratingBgMusic
                            ? const Icon(Icons.stop, size: 12)
                            : const Icon(Icons.music_note, size: 12),
                        label: Text(
                          _isGeneratingBgMusic ? 'Stop' : 'Generate',
                          style: const TextStyle(fontSize: 10),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isGeneratingBgMusic 
                              ? Colors.red.shade600 
                              : Colors.purple.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: _generateBgMusic,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      height: 28,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.auto_stories, size: 12),
                        label: const Text(
                          'Story AI Music',
                          style: TextStyle(fontSize: 10),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          elevation: 0,
                        ),
                        onPressed: () {
                          setState(() {
                            _tabController.index = 0; // Switch to AI Music tab
                            _showPropertiesPanel = true;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 6),
                
                // Voice Audio Generator
                Text(
                  'Voice Audio Generator',
                  style: TextStyle(
                    color: Colors.teal.shade800,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 30,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.record_voice_over, size: 14),
                    label: const Text(
                      'Generate Audio Clips',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: _showGenerateAudioDialog,
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

  /// Compact import button for 2-column grid layout
  Widget _buildCompactImportButton(IconData icon, String label, Color color, VoidCallback onPressed) {
    return SizedBox(
      height: 32,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withOpacity(0.9),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDefaultsPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(
          left: BorderSide(color: Colors.grey.shade300),
          right: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blue.shade700,
              border: Border(bottom: BorderSide(color: Colors.grey.shade400)),
            ),
            child: Center(
              child: Text(
                'Defaults',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  // Intro button with popup menu
                  _buildIntroOutroButton(
                    isIntro: true,
                    isSet: _project.defaultIntroPath != null,
                    onSet: () => _setDefaultIntroOutro(true),
                    onClear: () => _clearDefaultIntroOutro(true),
                  ),
                  
                  const SizedBox(height: 8),
                  
                  // Outro button with popup menu
                  _buildIntroOutroButton(
                    isIntro: false,
                    isSet: _project.defaultOutroPath != null,
                    onSet: () => _setDefaultIntroOutro(false),
                    onClear: () => _clearDefaultIntroOutro(false),
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // Auto Caption button (Coming Soon) - same size as Intro/Outro
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.shade600,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Stack(
                          alignment: Alignment.topRight,
                          children: [
                            Icon(Icons.closed_caption, size: 20, color: Colors.white),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade600,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: const Text('!', style: TextStyle(color: Colors.white, fontSize: 6, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        const Text('Caption', style: TextStyle(fontSize: 9, color: Colors.white)),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 8),
                  
                  // Transitions toggle with always visible duration input
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                    decoration: BoxDecoration(
                      color: _project.transitionsEnabled ? Colors.teal.shade600 : Colors.grey.shade500,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Controls row
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const ClampingScrollPhysics(),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                            // On/Off toggle
                            GestureDetector(
                              onTap: () {
                                setState(() => _project.transitionsEnabled = !_project.transitionsEnabled);
                                _saveProject();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _project.transitionsEnabled ? Colors.white : Colors.grey.shade700,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  _project.transitionsEnabled ? 'ON' : 'OFF',
                                  style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                    color: _project.transitionsEnabled ? Colors.teal.shade700 : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Duration input
                            SizedBox(
                              width: 28,
                              height: 18,
                              child: TextField(
                                controller: TextEditingController(text: _project.transitionDuration.toStringAsFixed(1)),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white, fontSize: 9),
                                decoration: InputDecoration(
                                  contentPadding: EdgeInsets.zero,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(3),
                                    borderSide: const BorderSide(color: Colors.white38),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(3),
                                    borderSide: const BorderSide(color: Colors.white38),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(3),
                                    borderSide: const BorderSide(color: Colors.white),
                                  ),
                                  filled: true,
                                  fillColor: Colors.black26,
                                ),
                                onSubmitted: (v) {
                                  final dur = double.tryParse(v) ?? 0.7;
                                  setState(() => _project.transitionDuration = dur.clamp(0.1, 3.0));
                                  _saveProject();
                                },
                              ),
                            ),
                            const Text('s', style: TextStyle(color: Colors.white70, fontSize: 8)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        // Label
                        const Text('Fade', style: TextStyle(fontSize: 9, color: Colors.white)),
                      ],
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
  
  Widget _buildIntroOutroButton({
    required bool isIntro,
    required bool isSet,
    required VoidCallback onSet,
    required VoidCallback onClear,
  }) {
    final label = isIntro ? 'Intro' : 'Outro';
    final icon = isIntro ? Icons.start : Icons.stop;
    
    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'set') {
          onSet();
        } else if (value == 'clear') {
          onClear();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'set',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 18, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Text(isSet ? 'Change $label Video' : 'Set $label Video'),
            ],
          ),
        ),
        if (isSet) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'clear',
            child: Row(
              children: [
                Icon(Icons.clear, size: 18, color: Colors.red.shade700),
                const SizedBox(width: 8),
                Text('Remove $label', style: TextStyle(color: Colors.red.shade700)),
              ],
            ),
          ),
        ],
      ],
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: isSet ? Colors.green.shade600 : Colors.blue.shade600,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(icon, size: 20, color: Colors.white),
            const SizedBox(height: 2),
            Text(
              isSet ? '$label ✓' : label,
              style: const TextStyle(fontSize: 9, color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
  
  void _clearDefaultIntroOutro(bool isIntro) {
    setState(() {
      if (isIntro) {
        _project.defaultIntroPath = null;
      } else {
        _project.defaultOutroPath = null;
      }
    });
    _saveProject();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${isIntro ? 'Intro' : 'Outro'} video removed')),
    );
  }

  Widget _buildImportButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: Icon(icon, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withOpacity(0.8),
          foregroundColor: Colors.grey.shade800,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          minimumSize: const Size(0, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildSmallButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return TextButton.icon(
      icon: Icon(icon, size: 14, color: Colors.grey.shade800),
      label: Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade800)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        backgroundColor: Colors.grey.shade200,
        shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(color: Colors.grey.shade300)
        ),
      ),
      onPressed: onPressed,
    );
  }

  Widget _buildPreviewPanel() {
    // Calculate aspect ratio value
    double aspectRatioValue = 16 / 9;
    switch (_previewAspectRatio) {
      case '16:9': aspectRatioValue = 16 / 9; break;
      case '9:16': aspectRatioValue = 9 / 16; break;
      case '4:3': aspectRatioValue = 4 / 3; break;
      case '1:1': aspectRatioValue = 1; break;
    }
    
    return Container(
      color: Colors.black,
      child: _project.videoClips.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                   Icon(Icons.movie_outlined, size: 64, color: Colors.grey.shade700),
                   const SizedBox(height: 16),
                   Text(
                     'Import videos to get started',
                     style: TextStyle(color: Colors.grey.shade600),
                   ),
                ],
              ),
            )
          : Center(
              child: AspectRatio(
                aspectRatio: aspectRatioValue,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: aspectRatioValue >= 1 ? 1920 : 1080,
                    height: aspectRatioValue >= 1 ? 1080 : 1920,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            // Video layer (Dual player stack for smooth transitions)
                            // OPTIMIZATION: Only render Video widgets if there's a clip at current position
                            // This prevents UI freeze during BGMusic-only playback
                            Builder(
                              builder: (context) {
                                // Check if any video clip is at current position
                                bool hasVideoAtPosition = _project.videoClips.any((clip) {
                                  final clipEnd = clip.timelineStart + clip.effectiveDuration;
                                  return _currentPosition >= clip.timelineStart && _currentPosition < clipEnd;
                                });
                                
                                // If no video at current position, show static black background
                                // Using const to prevent any video player widget from being built at all
                                if (!hasVideoAtPosition) {
                                  return const ColoredBox(color: Colors.black);
                                }
                                
                                // Otherwise render the video players
                                return RepaintBoundary(
                                  child: Opacity(
                                    opacity: _isVideoVisible ? _transitionOpacity : 0.0,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        // Primary Player
                                        Opacity(
                                          opacity: _usePrimaryPlayer ? 1.0 : 0.0,
                                          child: Video(
                                            controller: _videoController,
                                            controls: NoVideoControls,
                                          ),
                                        ),
                                        // Alt Player
                                        Opacity(
                                          opacity: !_usePrimaryPlayer ? 1.0 : 0.0,
                                          child: _videoControllerAlt != null 
                                            ? Video(
                                                controller: _videoControllerAlt!,
                                                controls: NoVideoControls,
                                              )
                                            : const ColoredBox(color: Colors.black),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                            
                            // Overlay layers (logo, images, text)
                            if (_isOverlayVisible)
                              ..._buildActiveOverlays(constraints),
                              
                            // Text layers (text track)
                            if (_isTextVisible)
                              ..._buildActiveTextOverlays(constraints),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  /// Build overlay widgets that are active at current position
  List<Widget> _buildActiveOverlays(BoxConstraints constraints) {
    final activeOverlays = <Widget>[];
    
    for (int i = 0; i < _project.overlays.length; i++) {
      final overlay = _project.overlays[i];
      final isSelected = _selectedOverlayIndex == i;
      
      // Show overlay if:
      // 1. It's currently selected (for editing) OR
      // 2. Playhead is within its time range
      final isInTimeRange = _currentPosition >= overlay.timelineStart &&
          _currentPosition < overlay.timelineEnd;
      
      if (isSelected || isInTimeRange) {
        activeOverlays.add(_buildOverlayWidget(overlay, constraints, isSelected, i));
      }
    }
    
    return activeOverlays;
  }

  Widget _buildOverlayWidget(OverlayItem overlay, BoxConstraints constraints, bool isSelected, int index) {
    // Position is relative (0-1), convert to pixels
    // FFmpeg export uses: x = (W-w) * overlay.x, y = (H-h) * overlay.y
    // This means: x=0 -> left edge, x=1 -> right edge (overlay stays fully visible)
    // We must use the SAME formula in preview for accurate WYSIWYG
    
    // Calculate size relative to container width (scale 1.0 = 100% of video width)
    // Export formula: targetWidth = exportWidth * scale
    // Preview formula: boxWidth = previewWidth * scale (identical ratio)
    final clampedScale = overlay.scale.clamp(0.05, 1.0);
    final boxWidth = (constraints.maxWidth * clampedScale).clamp(4.0, constraints.maxWidth);
    
    // For accurate aspect ratio, we need to load the actual image dimensions
    // For now, use a reasonable aspect ratio estimate (most logos are roughly square to 2:1)
    // The image itself will maintain its aspect ratio within the box via BoxFit.contain
    final boxHeight = boxWidth; 
    
    // Position Logic: Match FFmpeg's overlay=x=(W-w)*x:y=(H-h)*y formula
    // This keeps the overlay fully visible at all x/y values from 0-1
    // x=0 -> left edge, x=1 -> right edge (overlay aligned to right)
    // y=0 -> top edge, y=1 -> bottom edge (overlay aligned to bottom)
    final left = (constraints.maxWidth - boxWidth) * overlay.x;
    final top = (constraints.maxHeight - boxHeight) * overlay.y;
    
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: () {
          // Select this overlay when tapped
          setState(() {
            _selectedOverlayIndex = index;
            _selectedVideoClipIndex = null;
            _selectedAudioClipIndex = null;
            _selectedBgMusicClipIndex = null;
          });
        },
        onPanUpdate: (details) {
          // Drag to move overlay
          final deltaX = details.delta.dx;
          final deltaY = details.delta.dy;
          
          // Convert pixel delta to relative position change (0-1)
          // Since position = (container - overlay) * x, delta must be divided by (container - overlay)
          final effectiveWidth = constraints.maxWidth - boxWidth;
          final effectiveHeight = constraints.maxHeight - boxHeight;
          
          final newX = overlay.x + (effectiveWidth > 0 ? deltaX / effectiveWidth : 0);
          final newY = overlay.y + (effectiveHeight > 0 ? deltaY / effectiveHeight : 0);
          
          setState(() {
            _project.overlays[index] = overlay.copyWith(
              // Clamp to 0-1 for valid positions (fully visible)
              x: newX.clamp(0.0, 1.0),
              y: newY.clamp(0.0, 1.0),
            );
            _selectedOverlayIndex = index;
          });
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: Stack(
            children: [
              Opacity(
                opacity: overlay.opacity,
                child: SizedBox(
                  width: boxWidth,
                  height: boxHeight,
                  child: _buildOverlayContent(overlay),
                ),
              ),
              // Selection highlight as overlay, not border (no extra space)
              if (isSelected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.yellow, width: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverlayContent(OverlayItem overlay) {
    switch (overlay.type) {
      case 'text':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Color(overlay.backgroundColor),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            overlay.text.isEmpty ? 'Text' : overlay.text,
            style: TextStyle(
              color: Color(overlay.textColor),
              fontSize: overlay.fontSize,
              fontFamily: overlay.fontFamily,
            ),
          ),
        );
      
      case 'image':
      case 'logo':
        final imagePath = overlay.imagePath;
        if (imagePath.isEmpty) {
          return Container(
            color: Colors.grey.shade800,
            child: const Icon(Icons.image, color: Colors.white54, size: 32),
          );
        }
        final blendModeStr = overlay.properties['blendMode'] as String? ?? 'normal';
        final flutterBlend = _blendModeFromString(blendModeStr);
        final imageWidget = Image.file(
          File(imagePath),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            color: Colors.red.shade900,
            child: const Icon(Icons.broken_image, color: Colors.white),
          ),
        );
        if (flutterBlend != null && flutterBlend != BlendMode.srcOver) {
          // Approximate blend mode for live preview
          final intensity = (overlay.properties['blendIntensity'] as double?) ?? 1.0;
          Color approxColor;
          switch (blendModeStr) {
            case 'multiply':
              approxColor = const Color.fromRGBO(64, 64, 64, 1.0);
              break;
            case 'screen':
              approxColor = const Color.fromRGBO(192, 192, 192, 1.0);
              break;
            case 'overlay':
              approxColor = const Color.fromRGBO(96, 96, 96, 1.0);
              break;
            case 'darken':
              approxColor = const Color.fromRGBO(0, 0, 0, 1.0);
              break;
            case 'lighten':
              approxColor = const Color.fromRGBO(255, 255, 255, 1.0);
              break;
            case 'color_dodge':
              approxColor = const Color.fromRGBO(255, 255, 255, 1.0);
              break;
            case 'color_burn':
              approxColor = const Color.fromRGBO(0, 0, 0, 1.0);
              break;
            case 'hard_light':
              approxColor = const Color.fromRGBO(96, 96, 96, 1.0);
              break;
            case 'soft_light':
              approxColor = const Color.fromRGBO(96, 96, 96, 1.0);
              break;
            case 'difference':
              approxColor = const Color.fromRGBO(128, 128, 128, 1.0);
              break;
            case 'exclusion':
              approxColor = const Color.fromRGBO(128, 128, 128, 1.0);
              break;
            case 'hue':
              approxColor = const Color.fromRGBO(255, 255, 255, 1.0);
              break;
            case 'saturation':
              approxColor = const Color.fromRGBO(255, 255, 255, 1.0);
              break;
            case 'color':
              approxColor = const Color.fromRGBO(255, 255, 255, 1.0);
              break;
            case 'luminosity':
              approxColor = const Color.fromRGBO(255, 255, 255, 1.0);
              break;
            default:
              approxColor = const Color.fromRGBO(255, 255, 255, 1.0);
          }
          return ColorFiltered(
            colorFilter: ColorFilter.mode(approxColor.withOpacity(intensity), flutterBlend),
            child: imageWidget,
          );
        } else {
          return imageWidget;
        }
      
      default:
        return const SizedBox.shrink();
    }
  }



  Widget _buildTransportControls() {
    return Container(
      height: 40,
      color: Colors.grey.shade200,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Timecode - fixed width to prevent layout shifts
          Container(
            width: 70,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.grey.shade700,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _formatTimecode(_currentPosition),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          
          // Transport buttons
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 20),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            color: Colors.grey.shade700,
            onPressed: () => _seekTo(0),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.fast_rewind, size: 20),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            color: Colors.grey.shade700,
            onPressed: () => _seekTo((_currentPosition - 5).clamp(0, _project.totalDuration)),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _togglePlayback,
            child: Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
              child: _playbackTimer != null
                  ? const Icon(Icons.pause, color: Colors.white, size: 20)
                  : Center(
                      child: CustomPaint(
                        size: const Size(14, 14), 
                        painter: PlayIconPainter(),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.fast_forward, size: 20),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            color: Colors.grey.shade700,
            onPressed: () => _seekTo((_currentPosition + 5).clamp(0, _project.totalDuration)),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.skip_next, size: 20),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            color: Colors.grey.shade700,
            onPressed: () => _seekTo(_project.totalDuration),
          ),
          
          const SizedBox(width: 12),
          
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            color: Colors.red.shade600,
            tooltip: 'Delete selected',
            onPressed: _deleteSelectedClip,
          ),
          
          const SizedBox(width: 12),
          
          // Duration - fixed width
          SizedBox(
            width: 70,
            child: Text(
              '/ ${_formatTimecode(_project.totalDuration)}',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
            ),
          ),
          
          const SizedBox(width: 12),
          
          // Volume Control
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _volume == 0 ? Icons.volume_off : Icons.volume_up,
                size: 16,
                color: Colors.grey.shade700,
              ),
              SizedBox(
                width: 60,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    trackHeight: 2,
                  ),
                  child: Slider(
                    value: _volume,
                    min: 0,
                    max: 100,
                    onChanged: (value) {
                      setState(() {
                        _volume = value;
                      });
                      _player.setVolume(value);
                      _playerAlt?.setVolume(value);
                    },
                  ),
                ),
              ),
            ],
          ),
          
          const SizedBox(width: 8),
          
          // Aspect Ratio Selector
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _previewAspectRatio,
                isDense: true,
                style: TextStyle(color: Colors.grey.shade800, fontSize: 10),
                items: const [
                  DropdownMenuItem(value: '16:9', child: Text('16:9')),
                  DropdownMenuItem(value: '9:16', child: Text('9:16')),
                  DropdownMenuItem(value: '4:3', child: Text('4:3')),
                  DropdownMenuItem(value: '1:1', child: Text('1:1')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _previewAspectRatio = v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Show master volume adjustment popup
  void _showMasterVolumeDialog(String trackName, double currentVolume, Function(double) onVolumeChanged) {
    double tempVolume = currentVolume;
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.volume_up, color: Colors.blue),
              SizedBox(width: 8),
              Text('$trackName Master Volume'),
            ],
          ),
          content: Container(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Volume percentage display
                Text(
                  '${(tempVolume * 100).round()}%',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: tempVolume > 1.0 ? Colors.orange : Colors.blue,
                  ),
                ),
                SizedBox(height: 20),
                
                // Volume slider
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: tempVolume > 1.0 ? Colors.orange : Colors.blue,
                    inactiveTrackColor: Colors.grey.shade300,
                    thumbColor: tempVolume > 1.0 ? Colors.orange : Colors.blue,
                    overlayColor: (tempVolume > 1.0 ? Colors.orange : Colors.blue).withOpacity(0.2),
                    trackHeight: 4,
                  ),
                  child: Slider(
                    value: tempVolume,
                    min: 0.0,
                    max: 5.0,
                    divisions: 100,
                    label: '${(tempVolume * 100).round()}%',
                    onChanged: (value) {
                      setDialogState(() => tempVolume = value);
                      onVolumeChanged(value);
                      _updatePlaybackVolumes();
                    },
                  ),
                ),
                
                // Range labels
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0%', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text('100%', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text('500%', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                
                SizedBox(height: 16),
                
                // Quick preset buttons
                Wrap(
                  spacing: 8,
                  children: [
                    _buildPresetButton('Mute', 0.0, tempVolume, (v) {
                      setDialogState(() => tempVolume = v);
                      onVolumeChanged(v);
                      _updatePlaybackVolumes();
                    }),
                    _buildPresetButton('50%', 0.5, tempVolume, (v) {
                      setDialogState(() => tempVolume = v);
                      onVolumeChanged(v);
                      _updatePlaybackVolumes();
                    }),
                    _buildPresetButton('100%', 1.0, tempVolume, (v) {
                      setDialogState(() => tempVolume = v);
                      onVolumeChanged(v);
                      _updatePlaybackVolumes();
                    }),
                    _buildPresetButton('150%', 1.5, tempVolume, (v) {
                      setDialogState(() => tempVolume = v);
                      onVolumeChanged(v);
                      _updatePlaybackVolumes();
                    }),
                    _buildPresetButton('200%', 2.0, tempVolume, (v) {
                      setDialogState(() => tempVolume = v);
                      onVolumeChanged(v);
                      _updatePlaybackVolumes();
                    }),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _saveProject();
                Navigator.pop(context);
              },
              child: Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
  
  // Build preset button for quick volume adjustments
  Widget _buildPresetButton(String label, double value, double currentValue, Function(double) onPressed) {
    final isActive = (currentValue - value).abs() < 0.01;
    return ElevatedButton(
      onPressed: () => onPressed(value),
      style: ElevatedButton.styleFrom(
        backgroundColor: isActive ? Colors.blue : Colors.grey.shade200,
        foregroundColor: isActive ? Colors.white : Colors.black87,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size(0, 0),
      ),
      child: Text(label, style: TextStyle(fontSize: 12)),
    );
  }

  Widget _buildTrackHeader(
    String label, 
    IconData icon, 
    double height, 
    bool isVisible, 
    Function(bool) onChanged, 
    {
      bool? isMuted, 
      Function(bool)? onMuteChanged,
      double? masterVolume,
      Function()? onMasterVolumeClick,
    }
  ) {
    return Container(
      width: 50,
      height: height,
      color: Colors.grey.shade300,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Icon and label
          Icon(icon, size: 14, color: Colors.grey.shade800),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.grey.shade800),
            textAlign: TextAlign.center,
          ),
          
          const SizedBox(height: 4),
          
          // Visibility and mute controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: () => onChanged(!isVisible),
                child: Icon(
                  isVisible ? Icons.visibility : Icons.visibility_off,
                  size: 12,
                  color: isVisible ? Colors.blue.shade700 : Colors.grey.shade600,
                ),
              ),
              if (isMuted != null && onMuteChanged != null) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => onMuteChanged(!isMuted),
                  child: Icon(
                    isMuted ? Icons.volume_off : Icons.volume_up,
                    size: 12,
                    color: isMuted ? Colors.red.shade600 : Colors.green.shade700,
                  ),
                ),
              ],
            ],
          ),
          
          // Master Volume button
          if (masterVolume != null && onMasterVolumeClick != null) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: onMasterVolumeClick,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Colors.blue.shade300,
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.tune,
                      size: 12,
                      color: Colors.blue.shade700,
                    ),
                    SizedBox(height: 2),
                    Text(
                      '${(masterVolume * 100).round()}%',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        color: masterVolume > 1.0 ? Colors.orange.shade700 : Colors.blue.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResizeDivider(Function(double) onDrag) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          onDrag(details.delta.dy);
        },
        child: Container(
          height: 6,
          color: Colors.grey.shade400,
          child: Center(
            child: Container(
              width: 40,
              height: 3,
              decoration: BoxDecoration(
                color: Colors.grey.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimelinePanel() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate available width for timeline content (minus track header width)
        final trackHeaderWidth = 50.0;
        final availableWidth = constraints.maxWidth - trackHeaderWidth;
        
        // Calculate pixels per second based on zoom factor
        final pixelsPerSecond = _calculatePixelsPerSecond(availableWidth);
        
        // Total timeline width - ensure it's at least as wide as available space
        final contentWidth = (_project.totalDuration + 5) * pixelsPerSecond;
        final timelineWidth = contentWidth < availableWidth ? availableWidth : contentWidth;

        // Try to restore saved center/scroll once we know the timeline metrics
        if (!_timelineViewRestored) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              final prefs = await SharedPreferences.getInstance();
              final keyCenter = 'vm_center_${_project.id}';
              if (prefs.containsKey(keyCenter)) {
                final centerRatio = prefs.getDouble(keyCenter) ?? 0.5;
                final targetOffset = (centerRatio * timelineWidth) - (availableWidth / 2);
                if (_horizontalTimelineScroll.hasClients) {
                  final max = _horizontalTimelineScroll.position.maxScrollExtent;
                  _horizontalTimelineScroll.jumpTo(targetOffset.clamp(0.0, max));
                  _timelineViewRestored = true;
                } else {
                  Future.delayed(const Duration(milliseconds: 150), () {
                    if (_horizontalTimelineScroll.hasClients) {
                      final max = _horizontalTimelineScroll.position.maxScrollExtent;
                      _horizontalTimelineScroll.jumpTo(targetOffset.clamp(0.0, max));
                      _timelineViewRestored = true;
                    }
                  });
                }
              } else {
                final keyOffset = 'vm_scroll_${_project.id}';
                if (prefs.containsKey(keyOffset)) {
                  final savedOffset = prefs.getDouble(keyOffset) ?? 0.0;
                  if (_horizontalTimelineScroll.hasClients) {
                    final max = _horizontalTimelineScroll.position.maxScrollExtent;
                    _horizontalTimelineScroll.jumpTo(savedOffset.clamp(0.0, max));
                    _timelineViewRestored = true;
                  } else {
                    Future.delayed(const Duration(milliseconds: 150), () {
                      if (_horizontalTimelineScroll.hasClients) {
                        final max = _horizontalTimelineScroll.position.maxScrollExtent;
                        _horizontalTimelineScroll.jumpTo(savedOffset.clamp(0.0, max));
                        _timelineViewRestored = true;
                      }
                    });
                  }
                }
              }
            } catch (e) {
              // ignore
            }
          });
        }

        return Container(
          color: Colors.grey.shade200,
          child: Column(
            children: [
              // Zoom Control Bar
              Container(
                height: 36,
                color: Colors.grey.shade800,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    // Auto Ripple Fill button
                    Tooltip(
                      message: 'Remove gaps between clips',
                      child: TextButton.icon(
                        icon: const Icon(Icons.align_horizontal_left, size: 16, color: Colors.white70),
                        label: const Text('Ripple Fill', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: _autoRippleFill,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Split at playhead button placed next to Ripple Fill
                    Tooltip(
                      message: 'Split at playhead (all tracks)',
                      child: IconButton(
                        icon: const Icon(Icons.content_cut, size: 18, color: Colors.white70),
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        color: Colors.white70,
                        onPressed: _splitAtPlayheadAllTracks,
                      ),
                    ),
                    const Spacer(),
                    
                    // Fit to Window button
                    Tooltip(
                      message: 'Fit entire project in view',
                      child: IconButton(
                        icon: const Icon(Icons.fit_screen, size: 18, color: Colors.white70),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        onPressed: () {
                          setState(() => _zoomFactor = 1.0);
                          _saveTimelineZoom();
                        },
                      ),
                    ),
                    
                    // Zoom Out
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 18, color: Colors.white70),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () {
                        setState(() => _zoomFactor = (_zoomFactor / 1.5).clamp(0.5, 20.0));
                        _saveTimelineZoom();
                      },
                    ),
                    
                    // Zoom Slider
                    SizedBox(
                      width: 120,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                          trackHeight: 3,
                          activeTrackColor: Colors.blue,
                          inactiveTrackColor: Colors.grey.shade600,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: _zoomFactor.clamp(0.5, 20.0),
                          min: 0.5,
                          max: 20.0,
                          onChanged: (v) {
                            setState(() => _zoomFactor = v);
                            _saveTimelineZoom();
                          },
                        ),
                      ),
                    ),
                    
                    // Zoom In
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, size: 18, color: Colors.white70),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                      onPressed: () {
                                        setState(() => _zoomFactor = (_zoomFactor * 1.5).clamp(0.5, 20.0));
                                        _saveTimelineZoom();
                                      },
                    ),
                    
                    // Zoom percentage display
                    Container(
                      width: 50,
                      alignment: Alignment.center,
                      child: Text(
                        '${(_zoomFactor * 100).round()}%',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Timeline Content with both vertical and horizontal scrolling
              Expanded(
                child: Column(
                  children: [
                    // Main content area (scrolls vertically)
                    Expanded(
                      child: ScrollbarTheme(
                        data: ScrollbarThemeData(
                          thumbColor: WidgetStateProperty.all(Colors.grey.shade500),
                          trackColor: WidgetStateProperty.all(Colors.grey.shade800),
                          trackBorderColor: WidgetStateProperty.all(Colors.grey.shade700),
                          thickness: WidgetStateProperty.all(8.0),
                          radius: const Radius.circular(4),
                        ),
                        child: Scrollbar(
                          controller: _timelineScrollController,
                          thumbVisibility: true,
                          notificationPredicate: (notification) => notification.depth == 0,
                          child: SingleChildScrollView(
                          controller: _timelineScrollController,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Track headers column (scrolls vertically with content)
                              Column(
                                children: [
                                  _buildTrackHeader(
                                    'Video', 
                                    Icons.videocam, 
                                    _videoTrackHeight, 
                                    _isVideoVisible, 
                                    (v) => setState(() => _isVideoVisible = v), 
                                    isMuted: _project.isVideoTrackMuted, 
                                    onMuteChanged: (v) { 
                                      setState(() => _project.isVideoTrackMuted = v); 
                                      _saveProject(); 
                                      _updatePlaybackVolumes();
                                    },
                                    masterVolume: _project.videoMasterVolume,
                                    onMasterVolumeClick: () {
                                      _showMasterVolumeDialog('Video', _project.videoMasterVolume, (v) {
                                        setState(() => _project.videoMasterVolume = v);
                                      });
                                    },
                                  ),
                                  SizedBox(height: 4),
                                  _buildTrackHeader(
                                    'Audio', 
                                    Icons.audiotrack, 
                                    _audioTrackHeight, 
                                    _isAudioVisible, 
                                    (v) => setState(() => _isAudioVisible = v), 
                                    isMuted: _project.isAudioTrackMuted, 
                                    onMuteChanged: (v) { 
                                      setState(() => _project.isAudioTrackMuted = v); 
                                      _saveProject(); 
                                      _updatePlaybackVolumes();
                                    },
                                    masterVolume: _project.audioMasterVolume,
                                    onMasterVolumeClick: () {
                                      _showMasterVolumeDialog('Audio', _project.audioMasterVolume, (v) {
                                        setState(() => _project.audioMasterVolume = v);
                                      });
                                    },
                                  ),
                                  SizedBox(height: 4),
                                  _buildTrackHeader(
                                    'Music', 
                                    Icons.music_note, 
                                    _bgMusicTrackHeight, 
                                    _isBgMusicVisible, 
                                    (v) => setState(() => _isBgMusicVisible = v), 
                                    isMuted: _project.isBgMusicTrackMuted, 
                                    onMuteChanged: (v) { 
                                      setState(() => _project.isBgMusicTrackMuted = v); 
                                      _saveProject(); 
                                      _updatePlaybackVolumes();
                                    },
                                    masterVolume: _project.bgMusicMasterVolume,
                                    onMasterVolumeClick: () {
                                      _showMasterVolumeDialog('BG Music', _project.bgMusicMasterVolume, (v) {
                                        setState(() => _project.bgMusicMasterVolume = v);
                                      });
                                    },
                                  ),
                                  SizedBox(height: 4),
                                  _buildTrackHeader('Overlay', Icons.layers, _overlayTrackHeight, _isOverlayVisible, (v) => setState(() => _isOverlayVisible = v)),
                                  SizedBox(height: 4),
                                  _buildTrackHeader('Text', Icons.text_fields, _textTrackHeight, _isTextVisible, (v) => setState(() => _isTextVisible = v)),
                                ],
                              ),
                              
                              // Scrollable timeline content (horizontal) - no scrollbar here
                              Expanded(
                                child: SingleChildScrollView(
                                  controller: _horizontalTimelineScroll,
                                  scrollDirection: Axis.horizontal,
                                  child: SizedBox(
                                    width: timelineWidth,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // Video track with volume envelope overlay
                                        SizedBox(
                                          height: _videoTrackHeight,
                                          width: timelineWidth,
                                          child: Stack(
                                            children: [
                                              // The video clips timeline
                                              VideoTimelineWidget(
                                                clips: _project.videoClips,
                                                totalDuration: _project.totalDuration,
                                                currentPosition: _currentPosition,
                                                selectedClipIndex: _selectedVideoClipIndex,
                                                selectedClipIndices: _selectedVideoClips,
                                                pixelsPerSecond: pixelsPerSecond,
                                                onSeekStart: _onSeekStart,
                                                onSeekEnd: _onSeekEnd,
                                                onClipSelected: (index) {
                                                  setState(() {
                                                    _selectedVideoClipIndex = (index == -1) ? null : index;
                                                _selectedAudioClipIndex = null;
                                                _selectedBgMusicClipIndex = null;
                                                _selectedOverlayIndex = null;
                                                _activeLayer = 'video';
                                              });
                                            },
                                            onClipUpdated: (index, clip) {
                                              setState(() => _project.videoClips[index] = clip);
                                              _saveProject();
                                            },
                                            onRippleTrimEnd: (index, updatedClip, durationChange) {
                                              // Auto-ripple: shift all subsequent clips to snap to the trimmed clip
                                              setState(() {
                                                final originalClip = _project.videoClips[index];
                                                final originalEndTime = originalClip.timelineStart + originalClip.effectiveDuration;
                                                
                                                // Update the trimmed clip first
                                                _project.videoClips[index] = updatedClip;
                                                final newEndTime = updatedClip.timelineStart + updatedClip.effectiveDuration;
                                                
                                                // Sort clips by timeline position to find those after
                                                final sortedClips = List<MapEntry<int, VideoClip>>.from(
                                                  _project.videoClips.asMap().entries
                                                )..sort((a, b) => a.value.timelineStart.compareTo(b.value.timelineStart));
                                                
                                                // Find clips that were after the original end and shift them
                                                for (final entry in sortedClips) {
                                                  if (entry.key == index) continue;
                                                  final otherClip = entry.value;
                                                  // If clip starts at or very close to original end, snap to new end
                                                  if (otherClip.timelineStart >= originalEndTime - 0.1) {
                                                    final shiftAmount = originalEndTime - newEndTime;
                                                    _project.videoClips[entry.key] = otherClip.copyWith(
                                                      timelineStart: otherClip.timelineStart - shiftAmount,
                                                    );
                                                  }
                                                }
                                              });
                                              _saveProject();
                                            },
                                            onSeek: _seekTo,
                                            onPlaySeek: (position) {
                                              _seekTo(position);
                                              if (_playbackTimer == null) {
                                                _startMasterClock();
                                                Future.microtask(() => _syncPlayerToTimeline()); // Sync immediately to start playing fast
                                                setState(() {}); // Ensure icon updates
                                              }
                                            },
                                            onRippleDeleteGapAt: (clickedTime) {
                                              // Find the gap at the clicked position and close it
                                              setState(() {
                                                if (_project.videoClips.isEmpty) return;
                                                
                                                // Sort clips by timeline position
                                                final sortedClips = List<MapEntry<int, VideoClip>>.from(
                                                  _project.videoClips.asMap().entries
                                                )..sort((a, b) => a.value.timelineStart.compareTo(b.value.timelineStart));
                                                
                                                // Find which gap the click is in
                                                double? gapStart;
                                                double? gapEnd;
                                                
                                                // Check gap before first clip
                                                if (sortedClips.isNotEmpty && clickedTime < sortedClips.first.value.timelineStart) {
                                                  gapStart = 0;
                                                  gapEnd = sortedClips.first.value.timelineStart;
                                                } else {
                                                  // Check gaps between clips
                                                  for (int i = 0; i < sortedClips.length - 1; i++) {
                                                    final currentClip = sortedClips[i].value;
                                                    final nextClip = sortedClips[i + 1].value;
                                                    final currentEnd = currentClip.timelineStart + currentClip.effectiveDuration;
                                                    
                                                    if (clickedTime >= currentEnd && clickedTime < nextClip.timelineStart) {
                                                      gapStart = currentEnd;
                                                      gapEnd = nextClip.timelineStart;
                                                      break;
                                                    }
                                                  }
                                                }
                                                
                                                // If we found a gap, close it
                                                if (gapStart != null && gapEnd != null && gapEnd > gapStart) {
                                                  final gapSize = gapEnd - gapStart;
                                                  
                                                  // Shift all clips that start at or after gapEnd
                                                  for (final entry in sortedClips) {
                                                    if (entry.value.timelineStart >= gapEnd - 0.01) {
                                                      _project.videoClips[entry.key] = entry.value.copyWith(
                                                        timelineStart: entry.value.timelineStart - gapSize,
                                                      );
                                                    }
                                                  }
                                                }
                                              });
                                              _saveProject();
                                            },
                                            // Copy clip to clipboard
                                            onCopyClip: (index) {
                                              setState(() {
                                                _copiedVideoClip = _project.videoClips[index];
                                              });
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Clip copied to clipboard'),
                                                  duration: Duration(seconds: 1),
                                                ),
                                              );
                                            },
                                            // Paste clip at position
                                            onPasteClip: (position) {
                                              if (_copiedVideoClip == null) return;
                                              setState(() {
                                                final newClip = VideoClip(
                                                  id: '${DateTime.now().millisecondsSinceEpoch}_paste',
                                                  filePath: _copiedVideoClip!.filePath,
                                                  thumbnailPath: _copiedVideoClip!.thumbnailPath,
                                                  timelineStart: position,
                                                  originalDuration: _copiedVideoClip!.originalDuration,
                                                  trimStart: _copiedVideoClip!.trimStart,
                                                  trimEnd: _copiedVideoClip!.trimEnd,
                                                  speed: _copiedVideoClip!.speed,
                                                  volume: _copiedVideoClip!.volume,
                                                  colorSettings: _copiedVideoClip!.colorSettings,
                                                );
                                                _project.videoClips.add(newClip);
                                              });
                                              _saveProject();
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Clip pasted'),
                                                  duration: Duration(seconds: 1),
                                                ),
                                          );
                                        },
                                        // Insert clip at junction - shift other clips
                                        onInsertClipAt: (clipIndex, insertPosition) {
                                          setState(() {
                                            final movingClip = _project.videoClips[clipIndex];
                                            final clipDuration = movingClip.effectiveDuration;
                                            
                                            // Update the moving clip's position
                                            _project.videoClips[clipIndex] = movingClip.copyWith(
                                              timelineStart: insertPosition,
                                            );
                                            
                                            // Shift all clips that start at or after insertPosition (except the moving clip)
                                            for (int i = 0; i < _project.videoClips.length; i++) {
                                              if (i == clipIndex) continue;
                                              final clip = _project.videoClips[i];
                                              if (clip.timelineStart >= insertPosition - 0.01) {
                                                _project.videoClips[i] = clip.copyWith(
                                                  timelineStart: clip.timelineStart + clipDuration,
                                                );
                                              }
                                            }
                                          });
                                          _saveProject();
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Clip inserted - other clips shifted'),
                                              duration: Duration(seconds: 1),
                                            ),
                                          );
                                        },
                                        hasClipboardContent: _copiedVideoClip != null,
                                      ),
                                            ],
                                          ),
                                    ),
                                    SizedBox(height: 4),
                                    
                                    // Audio track
                                    SizedBox(
                                      height: _audioTrackHeight,
                                      width: timelineWidth,
                                      child: AudioTrackWidget(
                                        trackLabel: 'Audio',
                                        trackIcon: Icons.audiotrack,
                                        trackColor: Colors.green,
                                        clips: _project.audioClips,
                                        totalDuration: _project.totalDuration,
                                        pixelsPerSecond: pixelsPerSecond,
                                        currentPosition: _currentPosition,
                                        selectedClipIndex: _selectedAudioClipIndex,
                                        selectedClipIndices: _selectedAudioClips,
                                        onSeek: _seekTo,
                                        onSeekStart: _onSeekStart,
                                        onSeekEnd: _onSeekEnd,
                                        onClipSelected: (index) {
                                          setState(() {
                                            _selectedAudioClipIndex = (index == -1) ? null : index;
                                            _selectedVideoClipIndex = null;
                                            _selectedBgMusicClipIndex = null;
                                            _selectedOverlayIndex = null;
                                            _activeLayer = 'audio';
                                          });
                                        },
                                        onClipUpdated: (index, clip) {
                                          setState(() => _project.audioClips[index] = clip);
                                          _saveProjectDebounced(); // Debounced to prevent UI freeze during drag
                                        },
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    
                                    // BG Music track
                                    SizedBox(
                                      height: _bgMusicTrackHeight,
                                      width: timelineWidth,
                                      child: AudioTrackWidget(
                                        trackLabel: 'BG Music',
                                        trackIcon: Icons.music_note,
                                        trackColor: Colors.purple,
                                        clips: _project.bgMusicClips,
                                        totalDuration: _project.totalDuration,
                                        pixelsPerSecond: pixelsPerSecond,
                                        currentPosition: _currentPosition,
                                        selectedClipIndex: _selectedBgMusicClipIndex,
                                        selectedClipIndices: _selectedBgMusicClips,
                                        isBgMusicTrack: true,
                                        onSeek: _seekTo,
                                        onSeekStart: _onSeekStart,
                                        onSeekEnd: _onSeekEnd,
                                        onClipSelected: (index) {
                                          setState(() {
                                            _selectedBgMusicClipIndex = (index == -1) ? null : index;
                                            _selectedVideoClipIndex = null;
                                            _selectedAudioClipIndex = null;
                                            _selectedOverlayIndex = null;
                                            _activeLayer = 'bgMusic';
                                            // Auto-switch to Audio tab to show clip properties if selected
                                            if (index != -1) _tabController.animateTo(3); 
                                          });
                                        },
                                        onClipUpdated: (index, clip) {
                                          setState(() => _project.bgMusicClips[index] = clip);
                                          _saveProjectDebounced(); // Debounced to prevent UI freeze during drag
                                        },
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    
                                    // Overlay track
                                    SizedBox(
                                      height: _overlayTrackHeight,
                                      width: timelineWidth,
                                      child: OverlayTrackWidget(
                                        overlays: _project.overlays,
                                        totalDuration: _project.totalDuration,
                                        pixelsPerSecond: pixelsPerSecond,
                                        currentPosition: _currentPosition,
                                        selectedIndex: _selectedOverlayIndex,
                                        selectedIndices: _selectedOverlays,
                                        onSeek: _seekTo,
                                        onSeekStart: _onSeekStart,
                                        onSeekEnd: _onSeekEnd,
                                        onOverlaySelected: (index) {
                                          setState(() {
                                            _selectedOverlayIndex = (index == -1) ? null : index;
                                            _selectedVideoClipIndex = null;
                                            _selectedAudioClipIndex = null;
                                            _selectedBgMusicClipIndex = null;
                                            _activeLayer = 'overlay';
                                          });
                                        },
                                        onOverlayUpdated: (index, overlay) {
                                          setState(() => _project.overlays[index] = overlay);
                                          _saveProject();
                                        },
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    
                                    // Text track
                                    SizedBox(
                                      height: _textTrackHeight,
                                      width: timelineWidth,
                                      child: OverlayTrackWidget(
                                        overlays: _project.textOverlays,
                                        totalDuration: _project.totalDuration,
                                        pixelsPerSecond: pixelsPerSecond,
                                        currentPosition: _currentPosition,
                                        selectedIndex: _selectedTextIndex,
                                        selectedIndices: _selectedTextOverlays,
                                        onSeek: _seekTo,
                                        onOverlaySelected: (index) {
                                          setState(() {
                                            _selectedTextIndex = index;
                                            _selectedOverlayIndex = null;
                                            _selectedVideoClipIndex = null;
                                            _selectedAudioClipIndex = null;
                                            _selectedBgMusicClipIndex = null;
                                            _activeLayer = 'text';
                                          });
                                        },
                                        onOverlayUpdated: (index, overlay) {
                                          setState(() => _project.textOverlays[index] = overlay);
                                          _saveProject();
                                        },
                                      ),
                                    ),
                                    SizedBox(height: 20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ),
                    
                // Fixed horizontal scrollbar at bottom - always visible (narrow, gray theme)
                Container(
                  height: 8,
                  color: Colors.grey.shade800,
                  child: Row(
                    children: [
                      // Spacer for track header width
                      SizedBox(width: 50),
                      // Scrollbar area
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final scrollableWidth = timelineWidth - constraints.maxWidth;
                            final thumbWidth = scrollableWidth > 0 
                                ? (constraints.maxWidth / timelineWidth) * constraints.maxWidth 
                                : constraints.maxWidth;
                            final thumbWidthClamped = thumbWidth.clamp(30.0, constraints.maxWidth);
                            
                            return GestureDetector(
                              onTapDown: (details) {
                                // Click on track to jump to position
                                if (scrollableWidth > 0) {
                                  final clickFraction = details.localPosition.dx / constraints.maxWidth;
                                  final newOffset = clickFraction * scrollableWidth;
                                  _horizontalTimelineScroll.jumpTo(newOffset.clamp(0.0, scrollableWidth));
                                }
                              },
                              onHorizontalDragUpdate: (details) {
                                if (scrollableWidth > 0) {
                                  final scrollFraction = details.delta.dx / (constraints.maxWidth - thumbWidthClamped);
                                  final newOffset = _horizontalTimelineScroll.offset + (scrollFraction * scrollableWidth * 3.0);
                                  _horizontalTimelineScroll.jumpTo(newOffset.clamp(0.0, scrollableWidth));
                                }
                              },
                              child: Container(
                                color: Colors.grey.shade700,
                                child: AnimatedBuilder(
                                  animation: _horizontalTimelineScroll,
                                  builder: (context, child) {
                                    final maxScroll = _horizontalTimelineScroll.hasClients && _horizontalTimelineScroll.position.hasContentDimensions
                                        ? _horizontalTimelineScroll.position.maxScrollExtent 
                                        : 0.0;
                                    final currentScroll = _horizontalTimelineScroll.hasClients 
                                        ? _horizontalTimelineScroll.offset 
                                        : 0.0;
                                    final thumbPosition = maxScroll > 0 
                                        ? (currentScroll / maxScroll) * (constraints.maxWidth - thumbWidthClamped) 
                                        : 0.0;
                                    
                                    return Stack(
                                      children: [
                                        Positioned(
                                          left: thumbPosition.clamp(0.0, constraints.maxWidth - thumbWidthClamped),
                                          top: 1,
                                          child: GestureDetector(
                                            onHorizontalDragUpdate: (details) {
                                              if (maxScroll > 0) {
                                                final scrollFraction = details.delta.dx / (constraints.maxWidth - thumbWidthClamped);
                                                final newOffset = currentScroll + (scrollFraction * maxScroll * 3.0);
                                                _horizontalTimelineScroll.jumpTo(newOffset.clamp(0.0, maxScroll));
                                              }
                                            },
                                            child: Container(
                                              width: thumbWidthClamped,
                                              height: 6,
                                              decoration: BoxDecoration(
                                                color: Colors.grey.shade500,
                                                borderRadius: BorderRadius.circular(3),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                // Bottom padding to keep scrollbar above Windows taskbar
                Container(
                  height: 8,
                  color: Colors.grey.shade800,
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
  Widget _buildPropertiesPanel() {
    return Container(
      color: Colors.grey.shade50,
      child: Column(
        children: [
          // Tab bar
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              labelColor: Colors.blue.shade800,
              unselectedLabelColor: Colors.grey.shade600,
              indicatorColor: Colors.blue.shade800,
              tabs: const [
                Tab(text: 'AI Music'),
                Tab(text: 'Clip'),
                Tab(text: 'Color'),
                Tab(text: 'Audio'),
                Tab(text: 'Logo'),
                Tab(text: 'Text'),
              ],
            ),
          ),
          
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                BackgroundMusicPlayer(
                  apiKeyController: _apiKeyController,
                  multipleApiKeys: SettingsService.instance.getGeminiKeys(), // Use all available API keys
                  onFileSaved: (path) {
                    _addGeneratedMusicToTimeline(path);
                  },
                  onSegmentGenerated: (path, startTime, actualDuration, expectedDuration) {
                    _addGeneratedMusicToTimelineAt(path, startTime, actualDuration, expectedDuration);
                  },
                  onStreamStarted: () {
                    _startLiveStreamRecording();
                  },
                  onStreamStopped: () {
                    _stopLiveStreamRecording();
                  },
                  onLiveChunkReceived: (chunk, totalDuration) {
                    _handleLiveAudioChunk(chunk, totalDuration);
                  },
                ),
                _buildClipProperties(),
                _buildColorProperties(),
                _buildAudioProperties(),
                _buildLogoProperties(),
                _buildTextProperties(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipProperties() {
    if (_selectedVideoClipIndex == null) {
      return const Center(
        child: Text(
          'Select a video clip',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final clip = _project.videoClips[_selectedVideoClipIndex!];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Speed control (0.01x to 20x)
          _buildPropertyLabel('Speed'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: clip.speed.clamp(0.01, 20.0),
                  min: 0.01,
                  max: 20.0,
                  divisions: 199,
                  onChanged: (value) {
                    setState(() {
                      _project.videoClips[_selectedVideoClipIndex!] =
                          clip.copyWith(speed: double.parse(value.toStringAsFixed(2)));
                    });
                  },
                  onChangeEnd: (value) {
                    _saveProject(); // Save when slider stops
                  },
                ),
              ),
              SizedBox(
                width: 60,
                child: Text(
                  '${clip.speed.toStringAsFixed(2)}x',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
          // Quick speed presets
          Wrap(
            spacing: 4,
            children: [0.01, 0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 10.0, 20.0].map((s) => 
              TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size(0, 0),
                  backgroundColor: clip.speed == s ? Colors.blue : Colors.grey.shade700,
                ),
                onPressed: () {
                  setState(() {
                    _project.videoClips[_selectedVideoClipIndex!] =
                        clip.copyWith(speed: s);
                  });
                  _saveProject(); // Save after preset button
                },
                child: Text('${s}x', style: TextStyle(fontSize: 10, color: Colors.white)),
              )
            ).toList(),
          ),
          const SizedBox(height: 16),

          // Volume control
          _buildPropertyLabel('Volume'),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  clip.isMuted ? Icons.volume_off : Icons.volume_up,
                  color: clip.isMuted ? Colors.red : Colors.white,
                ),
                onPressed: () {
                  setState(() {
                    _project.videoClips[_selectedVideoClipIndex!] =
                        clip.copyWith(isMuted: !clip.isMuted);
                  });
                  _saveProject(); // Save after mute toggle
                },
              ),
              Expanded(
                child: Slider(
                  value: clip.volume,
                  min: 0,
                  max: 2.0,
                  onChanged: clip.isMuted
                      ? null
                      : (value) {
                          setState(() {
                            _project.videoClips[_selectedVideoClipIndex!] =
                                clip.copyWith(volume: value);
                          });
                        },
                  onChangeEnd: clip.isMuted
                      ? null
                      : (value) {
                          _saveProject(); // Save when volume slider stops
                        },
                ),
              ),
              Text(
                '${(clip.volume * 100).round()}%',
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Clip info
          _buildPropertyLabel('Info'),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.black12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Duration: ${_formatTimecode(clip.effectiveDuration)}',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
                ),
                Text(
                  'Original: ${_formatTimecode(clip.originalDuration)}',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
                ),
                Text(
                  'Trim: ${clip.trimStart.toStringAsFixed(1)}s - ${clip.trimEnd.toStringAsFixed(1)}s',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorProperties() {
    if (_selectedVideoClipIndex == null) {
      return const Center(
        child: Text(
          'Select a video clip',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final clip = _project.videoClips[_selectedVideoClipIndex!];
    final color = clip.colorSettings;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildColorSlider('Brightness', color.brightness, -1, 1, (v) {
            setState(() {
              _project.videoClips[_selectedVideoClipIndex!] =
                  clip.copyWith(colorSettings: color.copyWith(brightness: v));
            });
          }),
          _buildColorSlider('Contrast', color.contrast, 0, 2, (v) {
            setState(() {
              _project.videoClips[_selectedVideoClipIndex!] =
                  clip.copyWith(colorSettings: color.copyWith(contrast: v));
            });
          }),
          _buildColorSlider('Saturation', color.saturation, 0, 2, (v) {
            setState(() {
              _project.videoClips[_selectedVideoClipIndex!] =
                  clip.copyWith(colorSettings: color.copyWith(saturation: v));
            });
          }),
          _buildColorSlider('Hue', color.hue, -180, 180, (v) {
            setState(() {
              _project.videoClips[_selectedVideoClipIndex!] =
                  clip.copyWith(colorSettings: color.copyWith(hue: v));
            });
          }),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              setState(() {
                _project.videoClips[_selectedVideoClipIndex!] =
                    clip.copyWith(colorSettings: ColorSettings());
              });
            },
            child: const Text('Reset Colors'),
          ),
        ],
      ),
    );
  }

  Widget _buildColorSlider(
    String label,
    double value,
    double min,
    double max,
    Function(double) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPropertyLabel(label),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value,
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 45,
              child: Text(
                value.toStringAsFixed(1),
                style: TextStyle(color: Colors.grey.shade800),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAudioProperties() {
    final AudioClip? selectedClip;
    final bool isBgMusic;

    if (_selectedAudioClipIndex != null) {
      selectedClip = _project.audioClips[_selectedAudioClipIndex!];
      isBgMusic = false;
    } else if (_selectedBgMusicClipIndex != null) {
      selectedClip = _project.bgMusicClips[_selectedBgMusicClipIndex!];
      isBgMusic = true;
    } else {
      return const Center(
        child: Text(
          'Select an audio clip',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header showing clip type
          Container(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(
                  isBgMusic ? Icons.music_note : Icons.audiotrack,
                  color: isBgMusic ? Colors.purple : Colors.green,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isBgMusic ? 'BG Music Properties' : 'Audio Clip Properties',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: isBgMusic ? Colors.purple.shade700 : Colors.green.shade700,
                    ),
                  ),
                ),
                // File name
                Flexible(
                  child: Text(
                    selectedClip.filePath.split(Platform.pathSeparator).last,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          
          // AI Generation Info (for BG Music clips)
          if (isBgMusic && selectedClip.isGenerated) ...[
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.purple.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.purple.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 16, color: Colors.purple.shade700),
                      const SizedBox(width: 6),
                      Text(
                        'AI Generated Music',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: Colors.purple.shade800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  
                  // Generation Prompt
                  if (selectedClip.generationPrompt != null && selectedClip.generationPrompt!.isNotEmpty) ...[
                    Text(
                      'Prompt:',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.purple.shade100),
                      ),
                      child: Text(
                        selectedClip.generationPrompt!,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade800,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  
                  // Duration Information
                  Row(
                    children: [
                      Expanded(
                        child: _buildInfoRow(
                          'Expected',
                          selectedClip.expectedDuration != null
                              ? '${selectedClip.expectedDuration!.toStringAsFixed(1)}s'
                              : 'N/A',
                          Icons.schedule,
                          Colors.orange.shade600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildInfoRow(
                          'Actual',
                          '${selectedClip.duration.toStringAsFixed(1)}s',
                          Icons.timer,
                          Colors.green.shade600,
                        ),
                      ),
                    ],
                  ),
                  
                  // Duration match indicator
                  if (selectedClip.expectedDuration != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          selectedClip.duration >= selectedClip.expectedDuration!
                              ? Icons.check_circle
                              : Icons.warning,
                          size: 14,
                          color: selectedClip.duration >= selectedClip.expectedDuration!
                              ? Colors.green.shade600
                              : Colors.orange.shade600,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          selectedClip.duration >= selectedClip.expectedDuration!
                              ? 'Duration OK'
                              : 'Duration short by ${(selectedClip.expectedDuration! - selectedClip.duration).toStringAsFixed(1)}s',
                          style: TextStyle(
                            fontSize: 10,
                            color: selectedClip.duration >= selectedClip.expectedDuration!
                                ? Colors.green.shade700
                                : Colors.orange.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          
          Divider(color: Colors.grey.shade300),
          const SizedBox(height: 8),
          
          // Preview Controls
          Container(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () => _toggleAudioPreview(selectedClip!),
                  icon: Icon(_isAudioPreviewPlaying ? Icons.stop : Icons.play_arrow),
                  label: Text(_isAudioPreviewPlaying ? 'Stop Preview' : 'Play Clip'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isAudioPreviewPlaying ? Colors.red.shade400 : Colors.green.shade600,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _isAudioPreviewPlaying ? 'Playing...' : 'Preview with settings',
                  style: TextStyle(
                    color: _isAudioPreviewPlaying ? Colors.green : Colors.grey,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),

          // Volume
          _buildPropertyLabel('Volume'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: selectedClip.volume,
                  min: 0,
                  max: 2.0,
                  onChanged: (v) {
                    setState(() {
                      final updated = selectedClip!.copyWith(volume: v);
                      if (isBgMusic) {
                        _project.bgMusicClips[_selectedBgMusicClipIndex!] = updated;
                      } else {
                        _project.audioClips[_selectedAudioClipIndex!] = updated;
                      }
                    });
                  },
                  onChangeEnd: (v) => _saveProject(),
                ),
              ),
              Text(
                '${(selectedClip.volume * 100).round()}%',
                style: TextStyle(color: Colors.grey.shade800),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Speed
          _buildPropertyLabel('Speed'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: selectedClip.speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  onChanged: (v) {
                    setState(() {
                      final updated = selectedClip!.copyWith(speed: v);
                      if (isBgMusic) {
                        _project.bgMusicClips[_selectedBgMusicClipIndex!] = updated;
                      } else {
                        _project.audioClips[_selectedAudioClipIndex!] = updated;
                      }
                    });
                  },
                  onChangeEnd: (v) => _saveProject(),
                ),
              ),
              Text(
                '${selectedClip.speed}x',
                style: TextStyle(color: Colors.grey.shade800),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Pitch
          _buildPropertyLabel('Pitch'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: selectedClip.pitch,
                  min: 0.5,
                  max: 2.0,
                  divisions: 12,
                  onChanged: (v) {
                    setState(() {
                      final updated = selectedClip!.copyWith(pitch: v);
                      if (isBgMusic) {
                        _project.bgMusicClips[_selectedBgMusicClipIndex!] = updated;
                      } else {
                        _project.audioClips[_selectedAudioClipIndex!] = updated;
                      }
                    });
                  },
                  onChangeEnd: (v) => _saveProject(),
                ),
              ),
              Text(
                '${selectedClip.pitch.toStringAsFixed(1)}',
                style: TextStyle(color: Colors.grey.shade800),
              ),
            ],
          ),
          
          const SizedBox(height: 16),
          Divider(color: Colors.grey.shade300),
          const SizedBox(height: 8),
          
          // Clip Info
          _buildPropertyLabel('Clip Info'),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Duration:', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    Text('${selectedClip.duration.toStringAsFixed(2)}s', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Effective Duration:', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    Text('${selectedClip.effectiveDuration.toStringAsFixed(2)}s', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Timeline Position:', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    Text(_formatTimecode(selectedClip.timelineStart), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Trim Start
          _buildPropertyLabel('Trim Start'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: selectedClip.trimStart,
                  min: 0,
                  max: (selectedClip.duration - selectedClip.trimEnd - 0.1).clamp(0.0, selectedClip.duration),
                  onChanged: (v) {
                    setState(() {
                      final updated = selectedClip!.copyWith(trimStart: v);
                      if (isBgMusic) {
                        _project.bgMusicClips[_selectedBgMusicClipIndex!] = updated;
                      } else {
                        _project.audioClips[_selectedAudioClipIndex!] = updated;
                      }
                    });
                  },
                ),
              ),
              Text(
                '${selectedClip.trimStart.toStringAsFixed(1)}s',
                style: TextStyle(color: Colors.grey.shade800),
              ),
            ],
          ),
          
          // Trim End
          _buildPropertyLabel('Trim End'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: selectedClip.trimEnd,
                  min: 0,
                  max: (selectedClip.duration - selectedClip.trimStart - 0.1).clamp(0.0, selectedClip.duration),
                  onChanged: (v) {
                    setState(() {
                      final updated = selectedClip!.copyWith(trimEnd: v);
                      if (isBgMusic) {
                        _project.bgMusicClips[_selectedBgMusicClipIndex!] = updated;
                      } else {
                        _project.audioClips[_selectedAudioClipIndex!] = updated;
                      }
                    });
                  },
                ),
              ),
              Text(
                '${selectedClip.trimEnd.toStringAsFixed(1)}s',
                style: TextStyle(color: Colors.grey.shade800),
              ),
            ],
          ),

          if (selectedClip.isGenerated && selectedClip.generationPrompt != null) ...[
            const SizedBox(height: 16),
            _buildPropertyLabel('Generation Prompt'),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                selectedClip.generationPrompt!,
                style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLogoProperties() {
    // Find the first logo/image overlay, or use selected one
    OverlayItem? logoOverlay;
    int? logoIndex;
    
    // First check if selected overlay is a logo/image
    if (_selectedOverlayIndex != null && 
        _selectedOverlayIndex! < _project.overlays.length) {
      final selected = _project.overlays[_selectedOverlayIndex!];
      if (selected.type == 'image' || selected.type == 'logo') {
        logoOverlay = selected;
        logoIndex = _selectedOverlayIndex;
      }
    }
    
    // Otherwise find first logo/image overlay
    if (logoOverlay == null) {
      for (int i = 0; i < _project.overlays.length; i++) {
        if (_project.overlays[i].type == 'image' || 
            _project.overlays[i].type == 'logo') {
          logoOverlay = _project.overlays[i];
          logoIndex = i;
          break;
        }
      }
    }

    if (logoOverlay == null || logoIndex == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image_not_supported, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            const Text('No logo added', style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            SizedBox(
              height: 32,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Logo', style: TextStyle(fontSize: 12)),
                onPressed: _importLogo,
              ),
            ),
          ],
        ),
      );
    }

    final logo = logoOverlay;
    final idx = logoIndex;
    final modes = ['normal', 'multiply', 'screen', 'overlay', 'darken', 'lighten', 'difference'];

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1: Preview (square) + Blend controls
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Small square preview (60x60)
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade300),
                  gradient: LinearGradient(
                    colors: [Colors.blue.shade50, Colors.purple.shade50],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Stack(
                  children: [
                    if (logo.imagePath.isNotEmpty)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: Opacity(
                            opacity: logo.opacity.clamp(0.0, 1.0),
                            child: Image.file(
                              File(logo.imagePath),
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Icon(Icons.image, color: Colors.grey.shade400, size: 20),
                            ),
                          ),
                        ),
                      ),
                    // Delete button
                    Positioned(
                      right: 0,
                      top: 0,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _project.overlays.removeAt(idx!);
                            _selectedOverlayIndex = null;
                            _saveProject();
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.red.shade400,
                            borderRadius: const BorderRadius.only(topRight: Radius.circular(5), bottomLeft: Radius.circular(4)),
                          ),
                          child: const Icon(Icons.close, size: 10, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Blend Mode & Opacity & Size
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('Blend:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: SizedBox(
                            height: 24,
                            child: DropdownButton<String>(
                              value: (logo.properties['blendMode'] as String?) ?? 'normal',
                              isDense: true,
                              isExpanded: true,
                              style: const TextStyle(fontSize: 10, color: Colors.black),
                              items: modes.map((m) => DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 10)))).toList(),
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() {
                                  final props = Map<String, dynamic>.from(logo.properties);
                                  props['blendMode'] = v;
                                  _project.overlays[idx] = logo.copyWith(properties: props);
                                });
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text('Opacity:', style: TextStyle(fontSize: 10)),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                            child: Slider(value: logo.opacity, min: 0, max: 1, onChanged: (v) => setState(() => _project.overlays[idx] = logo.copyWith(opacity: v))),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text('Size:', style: TextStyle(fontSize: 10)),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                            child: Slider(value: logo.scale.clamp(0.05, 1.0), min: 0.05, max: 1.0, divisions: 95, onChanged: (v) => setState(() => _project.overlays[idx] = logo.copyWith(scale: v))),
                          ),
                        ),
                        Text('${(logo.scale * 100).round()}%', style: const TextStyle(fontSize: 9)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Two-column layout: Position buttons (left) | X/Y sliders (right)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left column: Position buttons (2-column grid)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Position:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    // Row 1: Top Left | gap | Top Right
                    Row(
                      children: [
                        Expanded(child: _buildMiniPosChip('Top Left', 0.08, 0.08, logo, idx)),
                        const SizedBox(width: 16),
                        Expanded(child: _buildMiniPosChip('Top Right', 0.92, 0.08, logo, idx)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Row 2: Center (centered)
                    Center(child: _buildMiniPosChip('Center', 0.5, 0.5, logo, idx)),
                    const SizedBox(height: 4),
                    // Row 3: Bottom Left | gap | Bottom Right
                    Row(
                      children: [
                        Expanded(child: _buildMiniPosChip('Bottom Left', 0.08, 0.88, logo, idx)),
                        const SizedBox(width: 16),
                        Expanded(child: _buildMiniPosChip('Bottom Right', 0.92, 0.88, logo, idx)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Right column: X/Y sliders
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16), // Align with position content
                    Row(children: [
                      const Text('X:', style: TextStyle(fontSize: 10)),
                      Expanded(child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                        child: Slider(value: logo.x.clamp(0.0, 1.0), min: 0, max: 1, onChanged: (v) => setState(() => _project.overlays[idx] = logo.copyWith(x: v))),
                      )),
                    ]),
                    Row(children: [
                      const Text('Y:', style: TextStyle(fontSize: 10)),
                      Expanded(child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                        child: Slider(value: logo.y.clamp(0.0, 1.0), min: 0, max: 1, onChanged: (v) => setState(() => _project.overlays[idx] = logo.copyWith(y: v))),
                      )),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniPosChip(String label, double x, double y, OverlayItem item, int index) {
    final isSelected = (item.x - x).abs() < 0.05 && (item.y - y).abs() < 0.05;
    return GestureDetector(
      onTap: () => setState(() => _project.overlays[index] = item.copyWith(x: x, y: y)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.shade100 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: isSelected ? Colors.blue : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected) const Icon(Icons.check, size: 10, color: Colors.blue),
            Text(label, style: TextStyle(fontSize: 9, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  Widget _buildPositionChip(String label, double x, double y, OverlayItem item, int index) {
    return ChoiceChip(
      label: FittedBox(child: Text(label, style: const TextStyle(fontSize: 9))), // FittedBox ensures it scales down
      labelPadding: const EdgeInsets.symmetric(horizontal: 0),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      selected: (item.x - x).abs() < 0.05 && (item.y - y).abs() < 0.05,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _project.overlays[index] = item.copyWith(x: x, y: y);
          });
        }
      },
    );
  }

  
  // Helpers for text overlays (separate from image/logo overlays)
  
  List<Widget> _buildActiveTextOverlays(BoxConstraints constraints) {
    final activeTextWidgets = <Widget>[];
    
    for (int i = 0; i < _project.textOverlays.length; i++) {
      final overlay = _project.textOverlays[i];
      final isSelected = _selectedTextIndex == i;
      
      final isInTimeRange = _currentPosition >= overlay.timelineStart &&
          _currentPosition < overlay.timelineEnd;
      
      if (isSelected || isInTimeRange) {
        activeTextWidgets.add(_buildTextOverlayWidget(overlay, constraints, isSelected, i));
      }
    }
    
    return activeTextWidgets;
  }

  Widget _buildTextOverlayWidget(OverlayItem overlay, BoxConstraints constraints, bool isSelected, int index) {
    // Similar to _buildOverlayWidget but targets textOverlays and _selectedTextIndex
    // Position Logic: Top-Left Anchor relative to Video Dimensions
    final left = constraints.maxWidth * overlay.x;
    final top = constraints.maxHeight * overlay.y;
    
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedTextIndex = index;
            _selectedOverlayIndex = null;
            _selectedVideoClipIndex = null;
            _selectedAudioClipIndex = null;
            _selectedBgMusicClipIndex = null;
          });
        },
        onPanUpdate: (details) {
          final deltaX = details.delta.dx;
          final deltaY = details.delta.dy;
          
          // Convert pixel delta to relative position change (0-1)
          final newX = overlay.x + (deltaX / constraints.maxWidth);
          final newY = overlay.y + (deltaY / constraints.maxHeight);
          
          setState(() {
            _project.textOverlays[index] = overlay.copyWith(
              // Allow some off-screen dragging but keep reachable
              x: newX.clamp(-0.5, 1.5),
              y: newY.clamp(-0.5, 1.5),
            );
            _selectedTextIndex = index;
          });
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: Stack(
            children: [
              Opacity(
                opacity: overlay.opacity,
                child: _buildOverlayContent(overlay), // Reuses existing content builder which handles 'text' type
              ),
              if (isSelected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.blueAccent, width: 2), // Blue border for text
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextProperties() {
    if (_selectedTextIndex == null || _selectedTextIndex! >= _project.textOverlays.length) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'No text selected',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add Text'),
              onPressed: _addText,
            ),
          ],
        ),
      );
    }
    
    final index = _selectedTextIndex!;
    final item = _project.textOverlays[index];
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Text Content
          _buildPropertyLabel('Content'),
          TextFormField(
            initialValue: item.properties['text'] ?? '',
            onChanged: (val) {
              final newProps = Map<String, dynamic>.from(item.properties);
              newProps['text'] = val;
              setState(() {
                _project.textOverlays[index] = item.copyWith(properties: newProps);
              });
            },
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          
          // Style: Size & Color
          _buildPropertyLabel('Style'),
          Row(
            children: [
              const Text('Size: ', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: (item.properties['fontSize'] as num?)?.toDouble() ?? 32.0,
                  min: 10,
                  max: 100,
                  onChanged: (val) {
                    final newProps = Map<String, dynamic>.from(item.properties);
                    newProps['fontSize'] = val;
                    setState(() {
                      _project.textOverlays[index] = item.copyWith(properties: newProps);
                    });
                  },
                ),
              ),
              Text('${(item.properties['fontSize'] as num?)?.toInt() ?? 32}'),
            ],
          ),
          
          // Basic Color Picker (simplified)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
               _buildColorPickButton(index, item, 0xFFFFFFFF), // White
               _buildColorPickButton(index, item, 0xFF000000), // Black
               _buildColorPickButton(index, item, 0xFFFF0000), // Red
               _buildColorPickButton(index, item, 0xFF00FF00), // Green
               _buildColorPickButton(index, item, 0xFF0000FF), // Blue
               _buildColorPickButton(index, item, 0xFFFFFF00), // Yellow
            ],
          ),
           const SizedBox(height: 16),
           
           // Opacity
           _buildPropertyLabel('Opacity'),
           Slider(
             value: item.opacity,
             min: 0, 
             max: 1,
             onChanged: (v) {
               setState(() {
                 _project.textOverlays[index] = item.copyWith(opacity: v);
               });
             },
           ),
           
           const SizedBox(height: 16),
          
          // Position
          _buildPropertyLabel('Position'),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _buildTextPositionChip('top L', 0.1, 0.1, item, index),
              _buildTextPositionChip('center', 0.5, 0.5, item, index),
              _buildTextPositionChip('bottom R', 0.9, 0.9, item, index),
            ],
          ),
          
          const SizedBox(height: 24),
          // Actions
          ElevatedButton.icon(
            icon: const Icon(Icons.delete, size: 16),
            label: const Text('Delete Text'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              setState(() {
                _project.textOverlays.removeAt(index);
                _selectedTextIndex = null;
              });
              _saveProject();
            },
          ),
        ],
      ),
    );
  }
  
  Widget _buildColorPickButton(int index, OverlayItem item, int colorValue) {
    final currentColor = item.properties['textColor'] as int? ?? 0xFFFFFFFF;
    final isSelected = currentColor == colorValue;
    return GestureDetector(
      onTap: () {
        final newProps = Map<String, dynamic>.from(item.properties);
        newProps['textColor'] = colorValue;
        setState(() {
          _project.textOverlays[index] = item.copyWith(properties: newProps);
        });
      },
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Color(colorValue),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey,
            width: isSelected ? 3 : 1,
          ),
          boxShadow: isSelected ? [BoxShadow(color: Colors.blue.withOpacity(0.3), blurRadius: 4, spreadRadius: 2)] : null,
        ),
      ),
    );
  }
  
  Widget _buildTextPositionChip(String label, double x, double y, OverlayItem item, int index) {
      return ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 10)),
        selected: (item.x - x).abs() < 0.05 && (item.y - y).abs() < 0.05,
        onSelected: (selected) {
          if (selected) {
            setState(() {
              _project.textOverlays[index] = item.copyWith(x: x, y: y);
            });
          }
        },
      );
    }

  Widget _buildPropertyLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.grey.shade700,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // Map FFmpeg-like blend mode strings to Flutter BlendMode where possible
  BlendMode? _blendModeFromString(String mode) {
    switch (mode) {
      case 'normal':
        return BlendMode.srcOver;
      case 'multiply':
        return BlendMode.multiply;
      case 'screen':
        return BlendMode.screen;
      case 'overlay':
        return BlendMode.overlay;
      case 'darken':
        return BlendMode.darken;
      case 'lighten':
        return BlendMode.lighten;
      case 'color_dodge':
        return BlendMode.colorDodge;
      case 'color_burn':
        return BlendMode.colorBurn;
      case 'hard_light':
        return BlendMode.hardLight;
      case 'soft_light':
        return BlendMode.softLight;
      case 'difference':
        return BlendMode.difference;
      case 'exclusion':
        return BlendMode.exclusion;
      case 'hue':
        return BlendMode.hue;
      case 'saturation':
        return BlendMode.saturation;
      case 'color':
        return BlendMode.color;
      case 'luminosity':
        return BlendMode.luminosity;
      default:
        return BlendMode.srcOver;
    }
  }

  Widget _buildExportProgress() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.blue.shade50,
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _exportStatus,
                  style: TextStyle(color: Colors.blue.shade900),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: _exportProgress),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(
            '${(_exportProgress * 100).round()}%',
            style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Future<void> _setDefaultIntroOutro(bool isIntro) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;

    setState(() {
      if (isIntro) {
        _project = _project.copyWith(defaultIntroPath: result.files.first.path);
      } else {
        _project = _project.copyWith(defaultOutroPath: result.files.first.path);
      }
    });

    await _saveProject();
    
    // Auto-add intro/outro to timeline
    await _syncIntroOutroToTimeline();
  }

  Future<void> _syncIntroOutroToTimeline() async {
    
    bool needsUpdate = false;
    
    // Check if intro already exists and get its duration
    final existingIntro = _project.videoClips.where((clip) => clip.id.startsWith('auto_intro_')).toList();
    double existingIntroDuration = 0.0;
    if (existingIntro.isNotEmpty) {
      existingIntroDuration = existingIntro.first.effectiveDuration;
    }
    
    // Check if outro already exists
    final existingOutro = _project.videoClips.where((clip) => clip.id.startsWith('auto_outro_')).toList();
    
    // Remove existing intro/outro clips (marked with special IDs)
    _project.videoClips.removeWhere((clip) => 
      clip.id.startsWith('auto_intro_') || clip.id.startsWith('auto_outro_'));
    
    // If we removed an intro, shift all clips back to their original positions
    if (existingIntroDuration > 0) {
      for (int i = 0; i < _project.videoClips.length; i++) {
        final clip = _project.videoClips[i];
        _project.videoClips[i] = VideoClip(
          id: clip.id,
          filePath: clip.filePath,
          thumbnailPath: clip.thumbnailPath,
          timelineStart: (clip.timelineStart - existingIntroDuration).clamp(0.0, double.infinity),
          originalDuration: clip.originalDuration,
          trimStart: clip.trimStart,
          trimEnd: clip.trimEnd,
          speed: clip.speed,
          volume: clip.volume,
          colorSettings: clip.colorSettings,
        );
      }
    }
    
    // Add intro at the beginning
    if (_project.defaultIntroPath != null && _project.defaultIntroPath!.isNotEmpty) {
      if (File(_project.defaultIntroPath!).existsSync()) {
        try {
          final introDuration = await MediaDurationHelper.getVideoDuration(_project.defaultIntroPath!) ?? 5.0;
          
          final introClip = VideoClip(
            id: 'auto_intro_${DateTime.now().millisecondsSinceEpoch}',
            filePath: _project.defaultIntroPath!,
            timelineStart: 0.0,
            originalDuration: introDuration,
          );
          
          // Shift all other clips forward by intro duration
          for (int i = 0; i < _project.videoClips.length; i++) {
            final clip = _project.videoClips[i];
            _project.videoClips[i] = VideoClip(
              id: clip.id,
              filePath: clip.filePath,
              thumbnailPath: clip.thumbnailPath,
              timelineStart: clip.timelineStart + introDuration,
              originalDuration: clip.originalDuration,
              trimStart: clip.trimStart,
              trimEnd: clip.trimEnd,
              speed: clip.speed,
              volume: clip.volume,
              colorSettings: clip.colorSettings,
            );
          }
          
          // Insert intro at the beginning
          _project.videoClips.insert(0, introClip);
          needsUpdate = true;
        } catch (e) {
        }
      }
    }
    
    // Add outro at the end
    if (_project.defaultOutroPath != null && _project.defaultOutroPath!.isNotEmpty) {
      if (File(_project.defaultOutroPath!).existsSync()) {
        try {
          final outroDuration = await MediaDurationHelper.getVideoDuration(_project.defaultOutroPath!) ?? 5.0;
          
          // Calculate position at the end
          double outroStart = 0.0;
          if (_project.videoClips.isNotEmpty) {
            final lastClip = _project.videoClips.last;
            outroStart = lastClip.timelineEnd;
          }
          
          final outroClip = VideoClip(
            id: 'auto_outro_${DateTime.now().millisecondsSinceEpoch}',
            filePath: _project.defaultOutroPath!,
            timelineStart: outroStart,
            originalDuration: outroDuration,
          );
          
          _project.videoClips.add(outroClip);
          needsUpdate = true;
        } catch (e) {
        }
      }
    }
    
    if (needsUpdate) {
      setState(() {
        // Trigger UI update
      });
      
      // Load first clip into player
      if (_project.videoClips.isNotEmpty) {
        try {
          await _player.open(Media(_project.videoClips.first.filePath));
          await _player.pause();
        } catch (e) {
        }
      }
      
      await _saveProject();
    }
  }

  void _renameProject() async {
    final controller = TextEditingController(text: _project.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Project name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() {
        _project = _project.copyWith(name: result);
      });
      _saveProject();
    }
  }

  /// Helper to build info row for BGMusic details
  Widget _buildInfoRow(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimecode(double seconds) {
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    final frames = ((seconds % 1) * 30).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}:${frames.toString().padLeft(2, '0')}';
  }
}

/// Extension for shade access
extension GrayShade on MaterialColor {
  Color get shade850 => const Color(0xFF2D2D2D);
}
