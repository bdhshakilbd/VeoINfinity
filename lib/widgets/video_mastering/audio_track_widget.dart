/// Audio Track Widget
/// Displays audio clips (manual audio or BG music) on a timeline

import 'package:flutter/material.dart';
import 'dart:io';
import '../../models/video_mastering/video_project.dart';

/// Audio clip widget for timeline
class AudioClipWidget extends StatefulWidget {
  final AudioClip clip;
  final double pixelsPerSecond;
  final bool isSelected;
  final bool isMultiSelected; // For Ctrl+A multi-selection visual
  final bool isBgMusic;
  final VoidCallback? onTap;
  final Function(double)? onMove;
  final Function(double)? onTrimStart;
  final Function(double)? onTrimEnd;
  final Function(double)? onVolumeChange;

  const AudioClipWidget({
    super.key,
    required this.clip,
    required this.pixelsPerSecond,
    this.isSelected = false,
    this.isMultiSelected = false,
    this.isBgMusic = false,
    this.onTap,
    this.onMove,
    this.onTrimStart,
    this.onTrimEnd,
    this.onVolumeChange,
  });

  @override
  State<AudioClipWidget> createState() => _AudioClipWidgetState();
}

class _AudioClipWidgetState extends State<AudioClipWidget> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final width = widget.clip.effectiveDuration * widget.pixelsPerSecond;
    final left = widget.clip.timelineStart * widget.pixelsPerSecond;
    final bgColor = widget.isBgMusic ? Colors.purple : Colors.green;

    return Positioned(
      left: left,
      top: 4,
      child: RepaintBoundary(
        child: GestureDetector(
          onTap: widget.onTap,
          onHorizontalDragStart: (_) {
            // Don't call setState here - reduces UI rebuilds during drag
            _isDragging = true;
          },
          onHorizontalDragUpdate: (details) {
            if (widget.onMove != null) {
              final delta = details.delta.dx / widget.pixelsPerSecond;
              widget.onMove!(delta);
            }
          },
          onHorizontalDragEnd: (_) {
            _isDragging = false;
            // Only rebuild when drag ends to update shadow
            if (mounted) setState(() {});
          },
          child: Container(
            width: width.clamp(20.0, double.infinity),
            height: 44,
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? bgColor.shade600
                  : bgColor.shade400,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: widget.isSelected ? Colors.white : bgColor.shade700,
                width: widget.isSelected ? 2 : 1,
              ),
              boxShadow: _isDragging
                  ? [BoxShadow(color: bgColor.withOpacity(0.5), blurRadius: 8)]
                  : null,
            ),
            child: Stack(
              children: [
                // Waveform representation (simplified)
                Positioned.fill(
                  child: CustomPaint(
                    painter: SimpleWaveformPainter(
                      color: Colors.white.withOpacity(0.4),
                    ),
                  ),
                ),
                
                // Clip info
                Positioned(
                  left: 6,
                  top: 4,
                  right: 6,
                  child: Row(
                    children: [
                      Icon(
                        widget.isBgMusic ? Icons.music_note : Icons.audiotrack,
                        size: 12,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.clip.name ?? _getFileName(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.clip.isMuted)
                        const Icon(Icons.volume_off, size: 10, color: Colors.red),
                    ],
                  ),
                ),
                
                // Volume indicator
                Positioned(
                  left: 6,
                  bottom: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.volume_up, size: 10, color: Colors.white70),
                            const SizedBox(width: 2),
                            Text(
                              '${(widget.clip.volume * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 8,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Show expected vs actual duration for AI-generated clips
                      if (widget.clip.isGenerated && widget.clip.expectedDuration != null) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: widget.clip.duration < (widget.clip.expectedDuration! - 1.0)
                                ? Colors.red.shade900.withOpacity(0.8) // Red if significantly shorter
                                : Colors.black38,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.timer, size: 10, color: Colors.white70),
                              const SizedBox(width: 2),
                              Text(
                                '${widget.clip.duration.toStringAsFixed(1)}s / ${widget.clip.expectedDuration!.toStringAsFixed(1)}s',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 8,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                
                // Speed/pitch indicator
                if (widget.clip.speed != 1.0 || widget.clip.pitch != 1.0)
                  Positioned(
                    right: 6,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade700,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(
                        '${widget.clip.speed}x',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                
                // Generation prompt indicator (for BG music)
                if (widget.clip.isGenerated && widget.clip.generationPrompt != null)
                  Positioned(
                    right: 6,
                    top: 4,
                    child: Tooltip(
                      message: widget.clip.generationPrompt!,
                      child: Icon(
                        Icons.auto_awesome,
                        size: 12,
                        color: Colors.amber.shade200,
                      ),
                    ),
                  ),
                
                // Left trim handle
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      widget.onTrimStart?.call(details.delta.dx / widget.pixelsPerSecond);
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      child: Container(
                        width: 6,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            bottomLeft: Radius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                
                // Right trim handle
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      widget.onTrimEnd?.call(details.delta.dx / widget.pixelsPerSecond);
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      child: Container(
                        width: 6,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                
                // Multi-selection overlay (Ctrl+A visual)
                if (widget.isMultiSelected)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.cyan.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.cyan, width: 2),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.check_circle,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getFileName() {
    return widget.clip.filePath.split(Platform.pathSeparator).last;
  }
}

/// Audio track timeline widget
class AudioTrackWidget extends StatefulWidget {
  final String trackLabel;
  final IconData trackIcon;
  final Color trackColor;
  final List<AudioClip> clips;
  final double totalDuration;
  final double pixelsPerSecond;
  final double currentPosition;
  final int? selectedClipIndex;
  final Set<int> selectedClipIndices; // For Ctrl+A multi-selection
  final bool isBgMusicTrack;
  final Function(int)? onClipSelected;
  final Function(int, AudioClip)? onClipUpdated;
  final Function(double)? onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;
  final ScrollController? scrollController;

  const AudioTrackWidget({
    super.key,
    required this.trackLabel,
    required this.trackIcon,
    required this.trackColor,
    required this.clips,
    required this.totalDuration,
    required this.pixelsPerSecond,
    this.currentPosition = 0,
    this.selectedClipIndex,
    this.selectedClipIndices = const {},
    this.isBgMusicTrack = false,
    this.onClipSelected,
    this.onClipUpdated,
    this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.scrollController,
  });

  @override
  State<AudioTrackWidget> createState() => _AudioTrackWidgetState();
}

class _AudioTrackWidgetState extends State<AudioTrackWidget> {
  // External scroll controller provided by parent
  DateTime? _lastDragUpdateTime;
  
  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timelineWidth = (widget.totalDuration + 10) * widget.pixelsPerSecond;

    return ClipRect(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Track header
          Container(
            height: 20,
            color: Colors.grey.shade800,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Icon(widget.trackIcon, size: 12, color: widget.trackColor),
                const SizedBox(width: 4),
                Text(
                  widget.trackLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.clips.length} clip${widget.clips.length != 1 ? 's' : ''}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          
          // Clips area - fills remaining space
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (details) {
                // Click anywhere to move playhead AND deselect
                widget.onClipSelected?.call(-1);
                widget.onSeekStart?.call();
                final tapX = details.localPosition.dx;
                final newPos = tapX / widget.pixelsPerSecond;
                widget.onSeek?.call(newPos.clamp(0, widget.totalDuration));
                widget.onSeekEnd?.call();
              },
              onPanStart: (details) {
                widget.onSeekStart?.call();
                final tapX = details.localPosition.dx;
                final newPos = tapX / widget.pixelsPerSecond;
                widget.onSeek?.call(newPos.clamp(0, widget.totalDuration));
              },
              onPanUpdate: (details) {
                // Scrub/drag to move playhead
                final tapX = details.localPosition.dx;
                final newPos = tapX / widget.pixelsPerSecond;
                widget.onSeek?.call(newPos.clamp(0, widget.totalDuration));
              },
              onPanEnd: (details) {
                widget.onSeekEnd?.call();
              },
              child: Container(
                color: widget.trackColor.withOpacity(0.1),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // Grid lines
                    Positioned.fill(
                      child: CustomPaint(
                        painter: AudioGridPainter(
                          pixelsPerSecond: widget.pixelsPerSecond,
                          color: widget.trackColor.withOpacity(0.1),
                        ),
                      ),
                    ),
                      
                      // Audio clips
                      ...widget.clips.asMap().entries.map((entry) {
                        final index = entry.key;
                        final clip = entry.value;
                        return AudioClipWidget(
                          clip: clip,
                          pixelsPerSecond: widget.pixelsPerSecond,
                          isSelected: widget.selectedClipIndex == index,
                          isMultiSelected: widget.selectedClipIndices.contains(index),
                          isBgMusic: widget.isBgMusicTrack,
                          onTap: () => widget.onClipSelected?.call(index),
                          onMove: (delta) => _handleClipMove(index, delta),
                          onTrimStart: (delta) => _handleTrimStart(index, delta),
                          onTrimEnd: (delta) => _handleTrimEnd(index, delta),
                        );
                      }),
                      
                      // CapCut-style Playhead - white line with rounded handle at top
                      Positioned(
                        left: widget.currentPosition * widget.pixelsPerSecond - 8,
                        top: -24, // Extend into ruler area
                        bottom: 0,
                        child: IgnorePointer(
                          child: SizedBox(
                            width: 16,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Playhead handle (rounded rectangle at top)
                                Positioned(
                                  left: 3,
                                  top: 0,
                                  child: Container(
                                    width: 10,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(3),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.5),
                                          blurRadius: 3,
                                          offset: const Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // Thin vertical line extending down
                                Positioned(
                                  left: 7.5,
                                  top: 20,
                                  bottom: 0,
                                  child: Container(
                                    width: 1,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.5),
                                          blurRadius: 2,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
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

        ],
      ),
    );
  }

  void _handleClipMove(int index, double deltaSeconds) {
    // Throttle updates to max 60fps (16ms) to reduce parent rebuilds
    final now = DateTime.now();
    if (_lastDragUpdateTime != null && 
        now.difference(_lastDragUpdateTime!).inMilliseconds < 16) {
      return; // Skip this update
    }
    _lastDragUpdateTime = now;
    
    final clip = widget.clips[index];
    final newStart = (clip.timelineStart + deltaSeconds).clamp(0.0, double.infinity);
    final updatedClip = clip.copyWith(timelineStart: newStart);
    widget.onClipUpdated?.call(index, updatedClip);
  }

  void _handleTrimStart(int index, double deltaSeconds) {
    final clip = widget.clips[index];
    final maxTrim = clip.duration - clip.trimEnd - 0.1;
    final newTrimStart = (clip.trimStart + deltaSeconds).clamp(0.0, maxTrim);
    final updatedClip = clip.copyWith(trimStart: newTrimStart);
    widget.onClipUpdated?.call(index, updatedClip);
  }

  void _handleTrimEnd(int index, double deltaSeconds) {
    final clip = widget.clips[index];
    final maxTrim = clip.duration - clip.trimStart - 0.1;
    final newTrimEnd = (clip.trimEnd - deltaSeconds).clamp(0.0, maxTrim);
    final updatedClip = clip.copyWith(trimEnd: newTrimEnd);
    widget.onClipUpdated?.call(index, updatedClip);
  }
}

/// Simple waveform painter (visual representation)
class SimpleWaveformPainter extends CustomPainter {
  final Color color;

  SimpleWaveformPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final path = Path();
    final random = [0.3, 0.6, 0.4, 0.8, 0.5, 0.7, 0.3, 0.9, 0.4, 0.6];
    final centerY = size.height / 2;
    final maxHeight = size.height * 0.4;

    path.moveTo(0, centerY);
    
    final stepWidth = size.width / (random.length * 4);
    double x = 0;
    int idx = 0;
    
    while (x < size.width) {
      final amplitude = random[idx % random.length] * maxHeight;
      path.lineTo(x, centerY - amplitude);
      x += stepWidth;
      path.lineTo(x, centerY + amplitude);
      x += stepWidth;
      idx++;
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Audio grid painter
class AudioGridPainter extends CustomPainter {
  final double pixelsPerSecond;
  final Color color;

  AudioGridPainter({required this.pixelsPerSecond, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    final interval = pixelsPerSecond >= 50 ? 1.0 : 5.0;
    
    for (double x = 0; x < size.width; x += interval * pixelsPerSecond) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant AudioGridPainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond;
  }
}
