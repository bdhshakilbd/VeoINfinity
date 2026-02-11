/// New GenerateVideosTab using VideoGenerationService
/// This replaces the old Veo3VideoService-based implementation

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import '../services/video_generation_service.dart';
import '../services/profile_manager_service.dart';
import '../services/mobile_browser_service.dart';
import '../services/multi_profile_login_service.dart';
import '../models/scene_data.dart';

// Import models from template_page
import 'template_page.dart' show StoryProject, VideoClip, StoryFrame;

class GenerateVideosTabNew extends StatefulWidget {
  final StoryProject? project;
  final String outputDir;
  final ProfileManagerService? profileManager;
  final MobileBrowserService? mobileService;
  final MultiProfileLoginService? loginService;

  const GenerateVideosTabNew({
    super.key,
    this.project,
    required this.outputDir,
    this.profileManager,
    this.mobileService,
    this.loginService,
  });

  @override
  State<GenerateVideosTabNew> createState() => _GenerateVideosTabNewState();
}

class _GenerateVideosTabNewState extends State<GenerateVideosTabNew> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isGenerating = false;
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();
  
  // Scene tracking
  final List<SceneData> _videoScenes = [];
  final Map<String, SceneData> _videoSceneStates = {};
  
  // Video generation service subscription
  StreamSubscription<String>? _videoStatusSubscription;
  
  String _selectedModel = 'veo_3_1_t2v_fast_ultra';
  String _selectedAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE';

  @override
  void initState() {
    super.initState();
    _initializeVideoGeneration();
  }

  Future<void> _initializeVideoGeneration() async {
    // Initialize VideoGenerationService
    await VideoGenerationService().initialize(
      profileManager: widget.profileManager,
      mobileService: widget.mobileService,
      loginService: widget.loginService,
    );

    // Listen to status updates
    _videoStatusSubscription = VideoGenerationService().statusStream.listen((msg) {
      _log(msg);
      
      // Update scene states from VideoGenerationService
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _videoStatusSubscription?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  void _log(String message) {
    print(message);
    if (mounted) {
      setState(() {
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
  }

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

  Future<void> _generateAllVideos() async {
    if (widget.project == null) {
      _log('❌ No project loaded');
      return;
    }

    final clips = widget.project!.videoClips;
    if (clips.isEmpty) {
      _log('❌ No video clips to generate');
      return;
    }

    setState(() {
      _isGenerating = true;
      _videoScenes.clear();
      _videoSceneStates.clear();
    });

    _log('🎬 Preparing ${clips.length} clips for generation...');

    // Convert VideoClips to SceneData
    for (int i = 0; i < clips.length; i++) {
      final clip = clips[i];
      
      // Get first frame image path
      final firstFrame = widget.project!.getFrameById(clip.firstFrame);
      final firstFramePath = await _getImagePath(firstFrame);
      
      if (firstFramePath == null) {
        _log('⚠️ Skipping ${clip.clipId}: missing first frame image');
        continue;
      }

      // Build prompt
      String fullPrompt = clip.veo3Prompt;
      if (clip.audioDescription.isNotEmpty) {
        fullPrompt += '\n\nAudio: ${clip.audioDescription}';
      }

      final scene = SceneData(
        sceneId: i + 1,
        prompt: fullPrompt,
        firstFramePath: firstFramePath,
        status: 'queued',
        aspectRatio: _selectedAspectRatio,
      );

      _videoScenes.add(scene);
      _videoSceneStates[firstFramePath] = scene;
    }

    _log('✅ Prepared ${_videoScenes.length} scenes');

    try {
      await VideoGenerationService().startBatch(
        _videoScenes,
        model: _selectedModel,
        aspectRatio: _selectedAspectRatio,
        maxConcurrentOverride: 4,
      );
      
      _log('✅ Batch generation started');
    } catch (e) {
      _log('❌ Start failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isGenerating = VideoGenerationService().isRunning);
      }
    }
  }

  void _stopGeneration() {
    VideoGenerationService().stop();
    setState(() => _isGenerating = false);
    _log(

'⏹️ Generation stopped');
  }

  Future<void> _openOutputFolder() async {
    final outputDocs = path.join((await getApplicationDocumentsDirectory()).path, 'veo3_videos');
    if (await Directory(outputDocs).exists()) {
      final uri = Uri.file(outputDocs.replaceAll('/', '\\'));
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    }
  }

  int get _completedCount => _videoScenes.where((s) => s.status == 'completed').length;
  int get _failedCount => _videoScenes.where((s) => s.status == 'failed').length;
  int get _activeCount => _videoScenes.where((s) => s.status == 'generating' || s.status == 'uploading' || s.status == 'polling').length;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    final clips = widget.project?.videoClips ?? [];

    return Row(
      children: [
        // Left Panel - Controls
        Container(
          width: 380,
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.movie_creation, color: Colors.deepPurple.shade700),
                    const SizedBox(width: 8),
                    const Text('VEO3 Video Generator', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 16),

                // Model Selection
                DropdownButtonFormField<String>(
                  value: _selectedModel,
                  decoration: const InputDecoration(labelText: 'VEO3 Model', border: OutlineInputBorder(), isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'veo_3_1_t2v_fast_ultra', child: Text('VEO 3.1 Fast (Unlimited)')),
                    DropdownMenuItem(value: 'veo_3_1_t2v_quality_ultra', child: Text('VEO 3.1 Quality (Unlimited)')),
                    DropdownMenuItem(value: 'veo_3_1_t2v_fast_ultra_relaxed', child: Text('VEO 3.1 Fast Relaxed')),
                    DropdownMenuItem(value: 'veo_2_t2v_fast', child: Text('VEO 2 Fast')),
                  ],
                  onChanged: (v) => setState(() => _selectedModel = v!),
                ),
                
                const SizedBox(height: 12),

                // Stats
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Project: ${widget.project?.title ?? 'None'}', style: const TextStyle(fontWeight: FontWeight.w500)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _buildStat('Total', clips.length, Colors.blue),
                          _buildStat('Done', _completedCount, Colors.green),
                          _buildStat('Failed', _failedCount, Colors.red),
                          _buildStat('Active', _activeCount, Colors.orange),
                        ],
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),

                // Buttons
                if (_isGenerating) ...[
                  LinearProgressIndicator(value: clips.isNotEmpty ? _completedCount / clips.length : 0),
                  const SizedBox(height: 8),
                  Text('Complete: $_completedCount/${clips.length}', textAlign: TextAlign.center),
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
                ],
                
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _openOutputFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open Videos Folder'),
                ),
              ],
            ),
          ),
        ),

        // Right Panel - Logs
        Expanded(
          child: Container(
            color: Colors.grey.shade900,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Generation Log', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Scrollbar(
                      controller: _logScrollController,
                      child: ListView.builder(
                        controller: _logScrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _logs[index],
                            style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontFamily: 'monospace'),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStat(String label, int value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
        child: Column(
          children: [
            Text('$value', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: color)),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
    );
  }
}
