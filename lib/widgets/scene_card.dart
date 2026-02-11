import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path/path.dart' as path;
import '../models/scene_data.dart';
import '../utils/config.dart';

class SceneCard extends StatefulWidget {
  final SceneData scene;
  final Function(String) onPromptChanged;
  final Function(String) onPickImage;
  final Function(String) onClearImage;
  final VoidCallback onGenerate;
  final VoidCallback? onStopGenerate; // Stop generation for this scene
  final VoidCallback onOpen;
  final VoidCallback? onOpenFolder;
  final VoidCallback? onDelete;
  final Function(String resolution)? onUpscale; // Now takes resolution: '1080p' or '4K'
  final VoidCallback? onStopUpscale; // Stop single scene upscale
  final bool showThumbnails;

  const SceneCard({
    super.key,
    required this.scene,
    required this.onPromptChanged,
    required this.onPickImage,
    required this.onClearImage,
    required this.onGenerate,
    this.onStopGenerate,
    required this.onOpen,
    this.showThumbnails = true,
    this.onOpenFolder,
    this.onDelete,
    this.onUpscale,
    this.onStopUpscale,
  });

  @override
  State<SceneCard> createState() => _SceneCardState();
}

class _SceneCardState extends State<SceneCard> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _isEditingPrompt = false;
  
  // Thumbnail
  Uint8List? _thumbnailData;
  bool _thumbnailLoading = false;
  String? _thumbnailVideoPath;

  // Theme colors
  static const Color _primaryBlue = Color(0xFF1E88E5);
  static const Color _lightBlue = Color(0xFF42A5F5);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.scene.prompt);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
    // Only load if enabled
    if (widget.showThumbnails) {
      _loadThumbnail();
    }
  }

  @override
  void didUpdateWidget(SceneCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scene.prompt != oldWidget.scene.prompt) {
      if (!_focusNode.hasFocus && _controller.text != widget.scene.prompt) {
        _controller.text = widget.scene.prompt;
      }
    }
    
    // Check thumbnail visibility toggle
    if (widget.showThumbnails != oldWidget.showThumbnails) {
       if (widget.showThumbnails) {
         _loadThumbnail();
       } else {
         setState(() {
           _thumbnailData = null;
           _thumbnailVideoPath = null;
         });
       }
    }

    // Reload thumbnail if video path changed OR status changed to completed
    // Force reload by clearing cached path when video path changes
    if (widget.showThumbnails) {
      final videoPathChanged = widget.scene.videoPath != oldWidget.scene.videoPath;
      final justCompleted = widget.scene.status == 'completed' && oldWidget.scene.status != 'completed';
      
      if (videoPathChanged || justCompleted) {
        // Clear cached thumbnail to force reload of NEW video
        _thumbnailVideoPath = null;
        _thumbnailData = null;
        _loadThumbnail();
      }
    }
  }

  Future<void> _loadThumbnail() async {
    final videoPath = widget.scene.videoPath;
    if (videoPath == null) {
      setState(() {
        _thumbnailData = null;
        _thumbnailVideoPath = null;
      });
      return;
    }
    
    // For freshly downloaded videos, the file might not be ready yet
    // Wait up to 2 seconds for the file to appear
    int retries = 0;
    while (!File(videoPath).existsSync() && retries < 4) {
      await Future.delayed(const Duration(milliseconds: 500));
      retries++;
    }
    
    if (!File(videoPath).existsSync()) {
      print('[SceneCard] Video file not found after waiting: $videoPath');
      setState(() {
        _thumbnailData = null;
        _thumbnailVideoPath = null;
      });
      return;
    }
    
    // Check if we need to reload (force reload if data is null but we enabled it)
    if (_thumbnailVideoPath == videoPath && _thumbnailData != null) {
      return;
    }
    
    // Check for cached thumbnail first (saved alongside video)
    final cachedThumbPath = _getCachedThumbPath(videoPath);
    if (File(cachedThumbPath).existsSync()) {
      try {
        final bytes = await File(cachedThumbPath).readAsBytes();
        if (mounted) {
          setState(() {
            _thumbnailData = bytes;
            _thumbnailVideoPath = videoPath;
            _thumbnailLoading = false;
          });
        }
        return;
      } catch (e) {
        print('[SceneCard] Failed to load cached thumbnail: $e');
      }
    }
    
    setState(() => _thumbnailLoading = true);
    
    try {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        // Use FFmpeg from current directory for desktop
        await _extractAndCacheThumbnail(videoPath, cachedThumbPath);
      } else {
        // Use video_thumbnail for mobile platforms
        final thumbnail = await VideoThumbnail.thumbnailData(
          video: videoPath,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 300,
          quality: 75,
          timeMs: 2000,
        );
        print('[SceneCard] Mobile thumbnail extracted: ${thumbnail?.length} bytes');
        
        if (mounted && thumbnail != null) {
          // Save to cache
          try {
            await File(cachedThumbPath).writeAsBytes(thumbnail);
          } catch (_) {}
          
          setState(() {
            _thumbnailData = thumbnail;
            _thumbnailVideoPath = videoPath;
            _thumbnailLoading = false;
          });
        } else {
          if (mounted) setState(() => _thumbnailLoading = false);
        }
      }
    } catch (e) {
      print('[SceneCard] Thumbnail error: $e');
      if (mounted) setState(() => _thumbnailLoading = false);
    }
  }

  /// Get cached thumbnail path (in thumbnails subfolder)
  String _getCachedThumbPath(String videoPath) {
    final videoDir = path.dirname(videoPath);
    final thumbDir = path.join(videoDir, 'thumbnails');
    final name = path.basenameWithoutExtension(videoPath);
    return path.join(thumbDir, '$name.thumb.jpg');
  }

  Future<void> _extractAndCacheThumbnail(String videoPath, String cachePath) async {
    try {
      // Ensure thumbnails directory exists
      await Directory(path.dirname(cachePath)).create(recursive: true);
      
      // Extract frame at 0.5 seconds directly to cache location
      // ffmpeg.exe should be in same folder as app executable
      final result = await Process.run('ffmpeg.exe', [
        '-y',
        '-i', videoPath,
        '-ss', '0.5',
        '-vframes', '1',
        '-q:v', '2',
        '-vf', 'scale=300:-1',
        cachePath,
      ]);
      
      if (result.exitCode == 0 && File(cachePath).existsSync()) {
        final bytes = await File(cachePath).readAsBytes();
        if (mounted) {
          setState(() {
            _thumbnailData = bytes;
            _thumbnailVideoPath = videoPath;
            _thumbnailLoading = false;
          });
        }
        print('[SceneCard] Thumbnail cached: $cachePath');
      } else {
        print('[SceneCard] FFmpeg thumbnail failed: ${result.stderr}');
        if (mounted) setState(() => _thumbnailLoading = false);
      }
    } catch (e) {
      print('[SceneCard] FFmpeg thumbnail error: $e');
      if (mounted) setState(() => _thumbnailLoading = false);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      if (_controller.text != widget.scene.prompt) {
        widget.onPromptChanged(_controller.text);
      }
      setState(() => _isEditingPrompt = false);
    }
  }

  Color _getStatusColor() {
    return Color(AppConfig.statusColors[widget.scene.status] ?? 0xFF000000);
  }
  
  Color _getUpscaleStatusColor() {
    switch (widget.scene.upscaleStatus) {
      case 'upscaling': return Colors.orange;
      case 'polling': return Colors.purple; // More visible than blue
      case 'downloading': return Colors.teal;
      case 'upscaled': return Colors.green;
      case 'completed': return Colors.green;
      case 'failed': return Colors.red;
      default: return Colors.grey;
    }
  }
  
  IconData _getUpscaleStatusIcon() {
    switch (widget.scene.upscaleStatus) {
      case 'upscaling': return Icons.upload;
      case 'polling': return Icons.hourglass_top;
      case 'downloading': return Icons.download;
      case 'upscaled': return Icons.hd;
      case 'completed': return Icons.hd;
      case 'failed': return Icons.error;
      default: return Icons.help;
    }
  }
  
  String _getUpscaleStatusText() {
    switch (widget.scene.upscaleStatus) {
      case 'upscaling': return 'Stop (Sending...)';
      case 'polling': return 'Stop (Polling...)';
      case 'downloading': return 'Stop (DL...)';
      case 'upscaled': return 'Upscaled ✓';
      case 'completed': return 'Upscaled ✓';
      case 'failed': return 'Retry Upscale';
      default: return 'Upscale to 1080p';
    }
  }

  bool get _hasVideo => widget.scene.videoPath != null && widget.scene.status == 'completed';

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(2),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          _buildHeader(),
          
          // Main content area
          Expanded(
            child: _hasVideo && !_isEditingPrompt
                ? _buildVideoPreview()
                : _buildPromptEditor(),
          ),
          
          // Bottom section
          if (!_hasVideo || _isEditingPrompt) ...[
            // Frames to Video section
            _buildFramesSection(),
          ],
          
          // Action buttons
          _buildActionButtons(),
          
          // Error message with retry count
          if (widget.scene.error != null)
            Container(
              margin: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red.shade200),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Error header with retry count
                  Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 4, top: 2),
                        child: Icon(Icons.error_outline, size: 10, color: Colors.red),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            widget.scene.error!,
                            style: const TextStyle(color: Colors.red, fontSize: 8, fontWeight: FontWeight.w500),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      // Retry count badge
                      if (widget.scene.retryCount > 0)
                        Container(
                          margin: const EdgeInsets.only(right: 4, top: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.orange,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Retry: ${widget.scene.retryCount}',
                            style: const TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.bold),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      color: _hasVideo ? _primaryBlue : Colors.grey.shade100,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Scene ${widget.scene.sceneId}',
              style: TextStyle(
                fontWeight: FontWeight.bold, 
                fontSize: 11,
                color: _hasVideo ? Colors.white : Colors.black87,
              ),
            ),
          ),
          // Upscale status badge (if has upscale status)
          if (widget.scene.upscaleStatus != null && widget.scene.upscaleStatus!.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: _getUpscaleStatusColor(),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _getUpscaleStatusIcon(),
                    size: 10,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    _getUpscaleStatusText(),
                    style: const TextStyle(color: Colors.white, fontSize: 8),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: _hasVideo ? Colors.white24 : _getStatusColor(),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              widget.scene.status,
              style: TextStyle(
                color: _hasVideo ? Colors.white : Colors.white, 
                fontSize: 9,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPreview() {
    return GestureDetector(
      onTap: widget.onOpen,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video thumbnail - actual frame from video
          if (_thumbnailData != null)
            Image.memory(
              _thumbnailData!,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            )
          else if (_thumbnailLoading)
            Container(
              color: Colors.grey.shade900,
              child: const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white54,
                  ),
                ),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.grey.shade800, Colors.grey.shade900],
                ),
              ),
              child: Center(
                child: Icon(Icons.movie, size: 40, color: Colors.grey.shade600),
              ),
            ),
          
          // Play button overlay (center)
          Center(
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _lightBlue.withOpacity(0.4),
                    blurRadius: 15,
                    spreadRadius: 3,
                  ),
                ],
              ),
              child: Material(
                color: _primaryBlue.withOpacity(0.8),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: widget.onOpen,
                  customBorder: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          // Edit prompt button (top right)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                onTap: () => setState(() => _isEditingPrompt = true),
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit, size: 10, color: Colors.white),
                      SizedBox(width: 2),
                      Text('Edit', style: TextStyle(fontSize: 8, color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          
          // Prompt preview (bottom)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Text(
                widget.scene.prompt,
                style: const TextStyle(color: Colors.white70, fontSize: 8),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptEditor() {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(4),
          color: Colors.white,
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          style: const TextStyle(fontSize: 10, color: Colors.black, height: 1.15),
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: (widget.scene.firstFramePath != null || widget.scene.lastFramePath != null)
                ? 'Enter prompt or leave empty for default (Animate this)'
                : 'Enter prompt...',
            hintStyle: const TextStyle(fontSize: 10, color: Colors.grey),
            contentPadding: const EdgeInsets.only(top: 4, bottom: 4),
          ),
          onTap: () => setState(() => _isEditingPrompt = true),
        ),
      ),
    );
  }

  Widget _buildFramesSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(3),
          color: Colors.grey.shade50,
        ),
        child: Row(
          children: [
            const Icon(Icons.video_library, size: 9, color: Colors.grey),
            const SizedBox(width: 2),
            const Text('I2V:', style: TextStyle(fontSize: 8, color: Colors.grey)),
            const SizedBox(width: 4),
            Expanded(child: _buildFrameSelector('1st', widget.scene.firstFramePath, 'first')),
            const SizedBox(width: 2),
            Expanded(child: _buildFrameSelector('End', widget.scene.lastFramePath, 'last')),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            // Generate/Stop buttons (show when no video or editing)
            if (!_hasVideo || _isEditingPrompt) ...[
              // When generating/polling/downloading - show compact Stop on right
              if (widget.scene.status == 'generating' || 
                  widget.scene.status == 'polling' || 
                  widget.scene.status == 'downloading') ...[
                const Spacer(),
                // Compact Soft Red Stop button
                GestureDetector(
                  onTap: () => widget.onStopGenerate?.call(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.stop, size: 10, color: Colors.red.shade700),
                        const SizedBox(width: 3),
                        Text('STOP', style: TextStyle(fontSize: 8, color: Colors.red.shade700, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ] else
                // Normal Gen/Retry button
                Expanded(
                  child: ElevatedButton(
                    onPressed: widget.onGenerate,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 24),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: widget.scene.status == 'failed' ? Colors.red : null,
                      foregroundColor: widget.scene.status == 'failed' ? Colors.white : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          widget.scene.status == 'failed' ? Icons.refresh : Icons.play_arrow,
                          size: 12,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          widget.scene.status == 'failed' ? 'Retry' : 'Gen',
                          style: const TextStyle(fontSize: 9),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            
            // Video action buttons
            if (_hasVideo && !_isEditingPrompt) ...[
              // Play
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: widget.onOpen,
                  icon: const Icon(Icons.play_arrow, size: 14),
                  label: const Text('Play', style: TextStyle(fontSize: 9)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 24),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Folder
              if (widget.onOpenFolder != null)
                SizedBox(
                  width: 28,
                  child: IconButton(
                    icon: const Icon(Icons.folder_open, size: 16, color: Colors.blue),
                    tooltip: 'Open in Folder',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: widget.onOpenFolder,
                  ),
                ),
              // Regenerate
              SizedBox(
                width: 28,
                child: IconButton(
                  icon: const Icon(Icons.refresh, size: 16, color: Colors.orange),
                  tooltip: 'Regenerate',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: widget.onGenerate,
                ),
              ),
              // Upscale to 1080p/4K popup menu (or Stop button when in progress)
              if (widget.onUpscale != null)
                SizedBox(
                  width: 28,
                  child: (widget.scene.upscaleStatus == 'upscaling' || 
                         widget.scene.upscaleStatus == 'polling' ||
                         widget.scene.upscaleStatus == 'downloading')
                      // Show stop button when upscaling
                      ? IconButton(
                          icon: Icon(
                            Icons.stop_circle,
                            size: 16,
                            color: _getUpscaleStatusColor(),
                          ),
                          tooltip: _getUpscaleStatusText(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: widget.onStopUpscale,
                        )
                      // Show popup menu with 1080p/4K options
                      : PopupMenuButton<String>(
                          icon: Icon(
                            Icons.hd,
                            size: 16,
                            color: _getUpscaleStatusColor(),
                          ),
                          tooltip: 'Upscale Video',
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          onSelected: (resolution) {
                            widget.onUpscale?.call(resolution);
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem<String>(
                              value: '1080p',
                              child: Row(
                                children: [
                                  Icon(Icons.hd, size: 16, color: Colors.blue),
                                  SizedBox(width: 8),
                                  Text('1080p HD'),
                                ],
                              ),
                            ),
                            const PopupMenuItem<String>(
                              value: '4K',
                              child: Row(
                                children: [
                                  Icon(Icons.four_k, size: 16, color: Colors.purple),
                                  SizedBox(width: 8),
                                  Text('4K Ultra HD'),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
            ],
            
            // Delete button
            if (widget.onDelete != null)
              SizedBox(
                width: 28,
                child: IconButton(
                  icon: const Icon(Icons.delete, size: 14, color: Colors.red),
                  tooltip: 'Delete',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: widget.onDelete,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrameSelector(String label, String? imagePath, String frameType) {
    // Get upload status based on frame type
    final uploadStatus = frameType == 'first' 
        ? widget.scene.firstFrameUploadStatus 
        : widget.scene.lastFrameUploadStatus;
    final mediaId = frameType == 'first'
        ? widget.scene.firstFrameMediaId
        : widget.scene.lastFrameMediaId;

    return GestureDetector(
      onTap: () => widget.onPickImage(frameType),
      child: Container(
        height: 26,
        decoration: BoxDecoration(
          border: Border.all(
            color: uploadStatus == 'failed' 
                ? Colors.red 
                : (mediaId != null ? Colors.green : Colors.grey.shade400),
            width: mediaId != null ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(3),
          color: Colors.grey.shade100,
        ),
        child: imagePath != null
            ? Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Image.file(
                      File(imagePath),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  // Upload status overlay
                  if (uploadStatus == 'uploading')
                    Positioned.fill(
                      child: Container(
                        color: Colors.black45,
                        child: const Center(
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Uploaded checkmark
                  if (mediaId != null && uploadStatus != 'uploading')
                    Positioned(
                      bottom: 0,
                      left: 0,
                      child: Container(
                        padding: const EdgeInsets.all(1),
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomLeft: Radius.circular(3),
                          ),
                        ),
                        child: const Icon(Icons.check, size: 8, color: Colors.white),
                      ),
                    ),
                  // Failed icon
                  if (uploadStatus == 'failed')
                    Positioned(
                      bottom: 0,
                      left: 0,
                      child: Container(
                        padding: const EdgeInsets.all(1),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomLeft: Radius.circular(3),
                          ),
                        ),
                        child: const Icon(Icons.error, size: 8, color: Colors.white),
                      ),
                    ),
                  // Close button
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => widget.onClearImage(frameType),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomLeft: Radius.circular(3),
                          ),
                        ),
                        child: const Icon(Icons.close, size: 10, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_photo_alternate, size: 12, color: Colors.grey),
                  const SizedBox(width: 2),
                  Text(label, style: const TextStyle(fontSize: 8, color: Colors.grey)),
                ],
              ),
      ),
    );
  }
}
