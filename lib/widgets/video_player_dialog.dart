import 'package:flutter/material.dart';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Internal video player dialog for desktop (Windows/macOS/Linux)
/// Blue and white themed compact preview card with fullscreen option
class VideoPlayerDialog extends StatefulWidget {
  final String videoPath;
  final String? title;
  final bool startFullscreen;

  const VideoPlayerDialog({
    super.key,
    required this.videoPath,
    this.title,
    this.startFullscreen = false,
  });

  /// Show the video player dialog
  static Future<void> show(BuildContext context, String videoPath, {String? title}) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (context) => VideoPlayerDialog(
        videoPath: videoPath,
        title: title,
      ),
    );
  }

  @override
  State<VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<VideoPlayerDialog> {
  Player? _player;
  VideoController? _controller;
  bool _isInitialized = false;
  bool _aspectRatioDetected = false;
  bool _isFullscreen = false;
  bool _isPlaying = true; // Track if video is playing
  bool _isCompleted = false; // Track if video finished
  String? _error;
  double _aspectRatio = 16 / 9; // Default, will be updated from video
  
  // Drag position
  Offset _dragOffset = Offset.zero;

  // Theme colors - Blue and White
  static const Color _primaryBlue = Color(0xFF1E88E5);
  static const Color _darkBlue = Color(0xFF1565C0);
  static const Color _lightBlue = Color(0xFF42A5F5);
  static const Color _headerBg = Color(0xFF0D47A1);
  static const Color _cardBg = Color(0xFFF5F9FF);
  static const Color _textDark = Color(0xFF1A237E);

  @override
  void initState() {
    super.initState();
    _isFullscreen = widget.startFullscreen;
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      // Ensure MediaKit is initialized
      MediaKit.ensureInitialized();
      
      // Create player
      _player = Player();
      _controller = VideoController(_player!);
      
      // Listen for video size changes to get aspect ratio
      _player!.stream.width.listen((width) {
        if (width != null && width > 0) {
          _updateAspectRatio();
        }
      });
      
      // Listen for playing state changes
      _player!.stream.playing.listen((playing) {
        if (mounted) {
          setState(() {
            _isPlaying = playing;
            if (playing) _isCompleted = false;
          });
        }
      });
      
      // Listen for video completion
      _player!.stream.completed.listen((completed) {
        if (mounted && completed) {
          setState(() {
            _isCompleted = true;
            _isPlaying = false;
          });
        }
      });
      
      // Open the video file
      await _player!.open(Media(widget.videoPath));
      
      // Wait a bit for video dimensions to be detected
      await Future.delayed(const Duration(milliseconds: 300));
      _updateAspectRatio();
      
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load video: $e';
        });
      }
    }
  }

  void _updateAspectRatio() {
    final width = _player?.state.width;
    final height = _player?.state.height;
    if (width != null && height != null && width > 0 && height > 0) {
      if (mounted) {
        setState(() {
          _aspectRatio = width / height;
          _aspectRatioDetected = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    
    // Show loading until aspect ratio is detected
    if (!_aspectRatioDetected && _error == null) {
      return Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 200,
          height: 150,
          decoration: BoxDecoration(
            color: _cardBg,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _primaryBlue.withOpacity(0.3),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: _primaryBlue),
              const SizedBox(height: 16),
              Text(
                'Loading video...',
                style: TextStyle(color: _textDark, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }
    
    if (_isFullscreen) {
      return _buildFullscreenPlayer(screenSize);
    } else {
      return _buildCompactPlayer(screenSize);
    }
  }

  /// Compact card player - respects video aspect ratio
  Widget _buildCompactPlayer(Size screenSize) {
    final isPortrait = _aspectRatio < 1;
    
    double videoWidth;
    double videoHeight;
    
    if (isPortrait) {
      // Portrait video - limit by height
      videoHeight = (screenSize.height * 0.6).clamp(250.0, 500.0);
      videoWidth = videoHeight * _aspectRatio;
    } else {
      // Landscape video - limit by width
      videoWidth = (screenSize.width * 0.45).clamp(350.0, 600.0);
      videoHeight = videoWidth / _aspectRatio;
    }
    
    final headerHeight = 50.0;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero, // Allow full screen movement
      child: Stack(
        children: [
          // Positioned card that can be dragged
          Positioned(
            left: (MediaQuery.of(context).size.width - videoWidth) / 2 + _dragOffset.dx,
            top: (MediaQuery.of(context).size.height - videoHeight - headerHeight) / 2 + _dragOffset.dy,
            child: GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  _dragOffset += details.delta;
                });
              },
              child: Container(
                width: videoWidth,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header - Blue gradient with exact width (draggable handle)
                      MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: SizedBox(
                          width: videoWidth,
                          child: _buildHeader(compact: true),
                        ),
                      ),
                      
                      // Video area - fills exact space with no gaps
                      SizedBox(
                        width: videoWidth,
                        height: videoHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Video fills entire space
                            _buildVideoArea(),
                            // Glowing Play button - center, only when stopped
                            if (!_isPlaying || _isCompleted)
                              Center(
                                child: _buildGlowingPlayButton(),
                              ),
                            // Fullscreen button overlay - bottom right
                            Positioned(
                              right: 10,
                              bottom: 10,
                              child: _buildFullscreenButton(),
                            ),
                          ],
                        ),
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

  /// Fullscreen player
  Widget _buildFullscreenPlayer(Size screenSize) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Container(
        width: screenSize.width,
        height: screenSize.height,
        color: Colors.black,
        child: Stack(
          children: [
            // Video fills the screen with aspect ratio
            Center(
              child: AspectRatio(
                aspectRatio: _aspectRatio,
                child: _buildVideoArea(),
              ),
            ),
            
            // Top bar with gradient
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_headerBg.withOpacity(0.95), Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.play_circle, color: Colors.white, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.title ?? _getFileName(widget.videoPath),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _buildIconButton(
                      Icons.fullscreen_exit,
                      'Exit Fullscreen',
                      _toggleFullscreen,
                      Colors.white70,
                    ),
                    _buildIconButton(
                      Icons.close,
                      'Close',
                      () => Navigator.of(context).pop(),
                      Colors.white70,
                    ),
                  ],
                ),
              ),
            ),
            
            // Bottom bar
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [_headerBg.withOpacity(0.9), Colors.transparent],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        widget.videoPath,
                        style: TextStyle(color: Colors.white60, fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _buildIconButton(
                      Icons.folder_open,
                      'Open in folder',
                      _openInFolder,
                      _lightBlue,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader({bool compact = false}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 16, 
        vertical: compact ? 10 : 12,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_headerBg, _darkBlue],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        // No border radius here since outer ClipRRect handles it
      ),
      child: Row(
        children: [
          Icon(Icons.play_circle, color: Colors.white, size: compact ? 22 : 26),
          SizedBox(width: compact ? 10 : 12),
          Expanded(
            child: Text(
              widget.title ?? _getFileName(widget.videoPath),
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 14 : 16,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (compact) ...[
            _buildIconButton(
              Icons.folder_open,
              'Open in folder',
              _openInFolder,
              _lightBlue,
              size: 20,
            ),
          ],
          _buildIconButton(
            Icons.close,
            'Close',
            () => Navigator.of(context).pop(),
            Colors.white70,
            size: compact ? 20 : 24,
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton(IconData icon, String tooltip, VoidCallback onPressed, Color color, {double size = 24}) {
    return IconButton(
      icon: Icon(icon, color: color, size: size),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }

  Widget _buildFullscreenButton() {
    return Material(
      color: _primaryBlue.withOpacity(0.8),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: _toggleFullscreen,
        borderRadius: BorderRadius.circular(6),
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(
            Icons.fullscreen,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _buildGlowingPlayButton() {
    return AnimatedOpacity(
      opacity: (!_isPlaying || _isCompleted) ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            // Subtle glow
            BoxShadow(
              color: _lightBlue.withOpacity(0.5),
              blurRadius: 15,
              spreadRadius: 3,
            ),
            BoxShadow(
              color: _primaryBlue.withOpacity(0.3),
              blurRadius: 25,
              spreadRadius: 5,
            ),
          ],
        ),
        child: Material(
          color: _primaryBlue.withOpacity(0.75), // Translucent blue
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            onTap: () {
              // Play video from current position (or beginning if completed)
              if (_isCompleted) {
                _player?.seek(Duration.zero);
              }
              _player?.play();
            },
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(
                Icons.play_arrow,
                color: Colors.white.withOpacity(0.9),
                size: 32,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    if (_error != null) {
      return Container(
        color: _cardBg,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade400, size: 48),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialized) {
      return Container(
        color: _cardBg,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: _primaryBlue),
              const SizedBox(height: 12),
              Text(
                'Loading...',
                style: TextStyle(color: _textDark, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return Video(
      controller: _controller!,
      controls: MaterialVideoControls,
    );
  }

  String _getFileName(String path) {
    return path.split(Platform.pathSeparator).last;
  }

  void _openInFolder() {
    if (Platform.isWindows) {
      Process.run('explorer', ['/select,', widget.videoPath]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', widget.videoPath]);
    } else if (Platform.isLinux) {
      final folder = widget.videoPath.substring(0, widget.videoPath.lastIndexOf(Platform.pathSeparator));
      Process.run('xdg-open', [folder]);
    }
  }
}
