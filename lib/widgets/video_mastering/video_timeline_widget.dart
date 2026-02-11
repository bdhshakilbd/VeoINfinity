/// Video Timeline Widget
/// Displays video clips on a horizontal timeline with drag/drop and trim handles

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'dart:io';
import 'dart:typed_data';
import '../../models/video_mastering/video_project.dart';

/// Timeline clip widget representing a single video clip
class TimelineClipWidget extends StatefulWidget {
  final VideoClip clip;
  final double pixelsPerSecond;
  final bool isSelected;
  final bool isMultiSelected; // For Ctrl+A multi-selection visual
  final VoidCallback? onTap;
  final Function(double)? onTrimStart;
  final Function(double)? onTrimEnd;
  final Function(double)? onMove;
  final VoidCallback? onSplit;
  final VoidCallback? onDelete;
  final VoidCallback? onCopy;

  const TimelineClipWidget({
    super.key,
    required this.clip,
    required this.pixelsPerSecond,
    this.isSelected = false,
    this.isMultiSelected = false,
    this.onTap,
    this.onTrimStart,
    this.onTrimEnd,
    this.onMove,
    this.onSplit,
    this.onDelete,
    this.onCopy,
  });

  @override
  State<TimelineClipWidget> createState() => _TimelineClipWidgetState();
}

class _TimelineClipWidgetState extends State<TimelineClipWidget> {
  bool _isDragging = false;
  bool _isDraggingTrimStart = false;
  bool _isDraggingTrimEnd = false;

  void _showClipContextMenu(BuildContext context, Offset globalPosition) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy, size: 18, color: Colors.blue),
              SizedBox(width: 8),
              Text('Copy Clip'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'copy') {
        widget.onCopy?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.clip.effectiveDuration * widget.pixelsPerSecond;
    final left = widget.clip.timelineStart * widget.pixelsPerSecond;

    return SizedBox( // Changed to SizedBox inside Positioned in parent
      width: width.clamp(20.0, double.infinity),
      height: 60,
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: (details) {
          // First select the clip
          widget.onTap?.call();
          // Then show context menu
          _showClipContextMenu(context, details.globalPosition);
        },
        onHorizontalDragStart: (_) => setState(() => _isDragging = true),
        onHorizontalDragUpdate: (details) {
          if (widget.onMove != null) {
            final delta = details.delta.dx / widget.pixelsPerSecond;
            widget.onMove!(delta);
          }
        },
        onHorizontalDragEnd: (_) => setState(() => _isDragging = false),
        child: Container(
          width: width.clamp(20.0, double.infinity),
          height: 60,
          decoration: BoxDecoration(
            color: widget.isSelected
                ? Colors.blue.shade600
                : Colors.blue.shade400,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: widget.isSelected ? Colors.white : Colors.blue.shade700,
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow: _isDragging
                ? [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.5),
                      blurRadius: 8,
                      spreadRadius: 2,
                    )
                  ]
                : null,
          ),
          child: Stack(
            children: [
              // Thumbnail background - disabled to test if causing freeze
              // if (widget.clip.thumbnailPath != null)
              //   Positioned.fill(
              //     child: ClipRRect(
              //       borderRadius: BorderRadius.circular(3),
              //       child: FutureBuilder<Uint8List?>(
              //         future: _loadThumbnailBytes(widget.clip.thumbnailPath!),
              //         builder: (context, snapshot) {
              //           if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
              //             return Image.memory(
              //               snapshot.data!,
              //               fit: BoxFit.cover,
              //               opacity: const AlwaysStoppedAnimation(0.6),
              //             );
              //           }
              //           return Container(); // Placeholder while loading
              //         },
              //       ),
              //     ),
              //   ),
              
              // Clip info overlay
              Positioned.fill(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _getClipName(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          shadows: [Shadow(color: Colors.black, blurRadius: 2)],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatDuration(widget.clip.effectiveDuration),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 9,
                          shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
                        ),
                      ),
                      if (widget.clip.speed != 1.0)
                        Text(
                          '${widget.clip.speed}x',
                          style: TextStyle(
                            color: Colors.amber.shade200,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              
              // Left trim handle
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  onHorizontalDragStart: (_) => setState(() => _isDraggingTrimStart = true),
                  onHorizontalDragUpdate: (details) {
                    if (widget.onTrimStart != null) {
                      final delta = details.delta.dx / widget.pixelsPerSecond;
                      widget.onTrimStart!(delta);
                    }
                  },
                  onHorizontalDragEnd: (_) => setState(() => _isDraggingTrimStart = false),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Container(
                      width: 8,
                      decoration: BoxDecoration(
                        color: _isDraggingTrimStart
                            ? Colors.orange
                            : Colors.white.withOpacity(0.3),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          bottomLeft: Radius.circular(4),
                        ),
                      ),
                      child: Center(
                        child: Container(
                          width: 2,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(1),
                          ),
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
                  onHorizontalDragStart: (_) => setState(() => _isDraggingTrimEnd = true),
                  onHorizontalDragUpdate: (details) {
                    if (widget.onTrimEnd != null) {
                      final delta = details.delta.dx / widget.pixelsPerSecond;
                      widget.onTrimEnd!(delta);
                    }
                  },
                  onHorizontalDragEnd: (_) => setState(() => _isDraggingTrimEnd = false),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Container(
                      width: 8,
                      decoration: BoxDecoration(
                        color: _isDraggingTrimEnd
                            ? Colors.orange
                            : Colors.white.withOpacity(0.3),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: Center(
                        child: Container(
                          width: 2,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              
              // Mute indicator
              if (widget.clip.isMuted)
                Positioned(
                  right: 12,
                  top: 4,
                  child: Icon(
                    Icons.volume_off,
                    size: 12,
                    color: Colors.red.shade200,
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
                        size: 24,
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

  String _getClipName() {
    final fileName = widget.clip.filePath.split(Platform.pathSeparator).last;
    return fileName.length > 15 ? '${fileName.substring(0, 12)}...' : fileName;
  }

  Future<Uint8List?> _loadThumbnailBytes(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e) {
      // Ignore errors, return null
    }
    return null;
  }

  String _formatDuration(double seconds) {
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
}

/// Main video timeline widget
class VideoTimelineWidget extends StatefulWidget {
  final List<VideoClip> clips;
  final double totalDuration;
  final double currentPosition;
  final int? selectedClipIndex;
  final Set<int> selectedClipIndices; // For Ctrl+A multi-selection
  final Function(int)? onClipSelected;
  final Function(int, VideoClip)? onClipUpdated;
  final Function(double)? onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;
  final Function(double)? onPlaySeek; // New callback for double-tap to play
  final Function(List<VideoClip>)? onClipsReordered;
  final Function(int, VideoClip, double)? onRippleTrimEnd; // Callback for ripple trim (index, updatedClip, durationChange)
  final Function(double)? onRippleDeleteGapAt; // Callback for ripple delete at position
  final Function(int)? onCopyClip; // Callback when user copies a clip
  final Function(double)? onPasteClip; // Callback when user pastes at position
  final Function(int, double)? onInsertClipAt; // Callback when user drags clip to junction (index, insertPosition)
  final bool hasClipboardContent; // Whether there's content to paste
  final double pixelsPerSecond;
  final ScrollController? scrollController;

  const VideoTimelineWidget({
    super.key,
    required this.clips,
    required this.totalDuration,
    this.currentPosition = 0,
    this.selectedClipIndex,
    this.selectedClipIndices = const {},
    this.onClipSelected,
    this.onClipUpdated,
    this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.onPlaySeek,
    this.onClipsReordered,
    this.onRippleTrimEnd,
    this.onRippleDeleteGapAt,
    this.onCopyClip,
    this.onPasteClip,
    this.onInsertClipAt,
    this.hasClipboardContent = false,
    this.pixelsPerSecond = 50.0,
    this.scrollController,
  });

  @override
  State<VideoTimelineWidget> createState() => _VideoTimelineWidgetState();
}

class _VideoTimelineWidgetState extends State<VideoTimelineWidget> {
  // Use external scroll controller if provided, otherwise none (parent handles scrolling)
  
  @override
  Widget build(BuildContext context) {
    final timelineWidth = (widget.totalDuration + 10) * widget.pixelsPerSecond;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Time ruler with scrubbing support
        MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            onTapDown: (details) {
              // Click on ruler moves playhead (no autoplay)
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
              // Scrub/drag on ruler moves playhead
              final tapX = details.localPosition.dx;
              final newPos = tapX / widget.pixelsPerSecond;
              widget.onSeek?.call(newPos.clamp(0, widget.totalDuration));
            },
            onPanEnd: (details) {
              widget.onSeekEnd?.call();
            },
            child: Container(
              height: 24,
              color: Colors.grey.shade900,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Time ruler markings
                  Positioned.fill(
                    child: CustomPaint(
                      painter: TimeRulerPainter(
                        pixelsPerSecond: widget.pixelsPerSecond,
                        totalDuration: widget.totalDuration + 10,
                      ),
                    ),
                  ),
                  // CapCut-style playhead handle on ruler (rounded rectangle)
                  Positioned(
                    left: widget.currentPosition * widget.pixelsPerSecond - 5,
                    top: 2,
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
                ],
              ),
            ),
          ),
        ),
        
        // Clips track
        Expanded(
          child: Container(
            color: kTimelineTrackBackground,
            child: Stack(
              children: [
                // Background grid WITH seek gesture and right-click menu
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                      onTapUp: (details) {
                        // Tap on empty space - move playhead AND deselect
                        widget.onClipSelected?.call(-1); // Signal deselection
                        widget.onSeekStart?.call();
                        final tapX = details.localPosition.dx;
                        final newPos = tapX / widget.pixelsPerSecond;
                        widget.onSeek?.call(newPos.clamp(0, widget.totalDuration));
                        widget.onSeekEnd?.call();
                      },
                      onSecondaryTapUp: (details) {
                      // Right-click context menu - pass local position for gap detection
                      final clickedTime = details.localPosition.dx / widget.pixelsPerSecond;
                      _showTimelineContextMenu(context, details.globalPosition, clickedTime);
                    },
                      onPanStart: (details) {
                        widget.onSeekStart?.call();
                        final tapX = details.localPosition.dx;
                        final newPos = tapX / widget.pixelsPerSecond;
                        widget.onSeek?.call(newPos.clamp(0, widget.totalDuration));
                      },
                      onPanUpdate: (details) {
                        final tapX = details.localPosition.dx;
                        final newPos = tapX / widget.pixelsPerSecond;
                        widget.onSeek?.call(newPos.clamp(0, widget.totalDuration));
                      },
                      onPanEnd: (details) {
                        widget.onSeekEnd?.call();
                      },
                    child: CustomPaint(
                      painter: TimelineGridPainter(
                        pixelsPerSecond: widget.pixelsPerSecond,
                      ),
                    ),
                  ),
                ),
                    
                    // Video clips - ON TOP, will intercept taps
                    ...(){
                      // Calculate track indices for overlapping clips
                      final trackIndices = List<int>.filled(widget.clips.length, 0);
                      int maxTrack = 0;
                      
                      // Sort by start time for consistent layout
                      final sortedIndices = List.generate(widget.clips.length, (i) => i);
                      sortedIndices.sort((a, b) => widget.clips[a].timelineStart.compareTo(widget.clips[b].timelineStart));
                      
                      for (int i = 0; i < sortedIndices.length; i++) {
                        final idx = sortedIndices[i];
                        final clip = widget.clips[idx];
                        int track = 0;
                        
                        while (true) {
                          bool collision = false;
                          for (int prev = 0; prev < i; prev++) {
                            final prevIdx = sortedIndices[prev];
                            final prevTrack = trackIndices[prevIdx];
                            
                            if (prevTrack == track) {
                               final prevClip = widget.clips[prevIdx];
                               final start1 = clip.timelineStart;
                               final end1 = clip.timelineStart + clip.effectiveDuration;
                               final start2 = prevClip.timelineStart;
                               final end2 = prevClip.timelineStart + prevClip.effectiveDuration;
                               
                               if (start1 < end2 && start2 < end1) {
                                 collision = true; 
                                 break;
                               }
                            }
                          }
                          if (!collision) break;
                          track++;
                        }
                        trackIndices[idx] = track;
                        if (track > maxTrack) maxTrack = track;
                      }

                      return widget.clips.asMap().entries.map((entry) {
                        final index = entry.key;
                        final clip = entry.value;
                        return Positioned(
                          left: clip.timelineStart * widget.pixelsPerSecond,
                          top: 4.0 + (trackIndices[index] * 64.0), // Stack vertically
                          child: TimelineClipWidget(
                            clip: clip,
                            pixelsPerSecond: widget.pixelsPerSecond,
                            isSelected: widget.selectedClipIndex == index,
                            isMultiSelected: widget.selectedClipIndices.contains(index),
                            onTap: () {
                              // Only select clip - DO NOT move playhead
                              widget.onClipSelected?.call(index);
                            },
                            onMove: (delta) => _handleClipMove(index, delta),
                            onTrimStart: (delta) => _handleTrimStart(index, delta),
                            onTrimEnd: (delta) => _handleTrimEnd(index, delta),
                            onCopy: () => widget.onCopyClip?.call(index),
                          ),
                        );
                      });
                    }().toList(),
                    
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
          ],
        );
      }

      void _showTimelineContextMenu(BuildContext context, Offset globalPosition, double clickedTime) {
        showMenu<String>(
          context: context,
          position: RelativeRect.fromLTRB(
            globalPosition.dx,
            globalPosition.dy,
            globalPosition.dx + 1,
            globalPosition.dy + 1,
          ),
          items: [
            if (widget.hasClipboardContent)
              PopupMenuItem<String>(
                value: 'paste',
                child: Row(
                  children: [
                    Icon(Icons.paste, size: 18, color: Colors.green),
                    SizedBox(width: 8),
                    Text('Paste Clip Here'),
                  ],
                ),
              ),
            PopupMenuItem<String>(
              value: 'ripple_delete',
              child: Row(
                children: [
                  Icon(Icons.compress, size: 18, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Ripple Delete This Gap'),
                ],
              ),
            ),
          ],
        ).then((value) {
          if (value == 'ripple_delete') {
            widget.onRippleDeleteGapAt?.call(clickedTime);
          } else if (value == 'paste') {
            widget.onPasteClip?.call(clickedTime);
          }
        });
      }

      void _handleClipMove(int index, double deltaSeconds) {
        final clip = widget.clips[index];
    double newStart = (clip.timelineStart + deltaSeconds).clamp(0.0, double.infinity);
    
    // Snapping logic
    // We snap if new pos is close to end/start of other clips
    if (widget.clips.length > 1) {
      const snapThreshold = 0.2; // 200ms threshold
      double? snapTarget;
      double minDiff = double.infinity;
      int? insertBetweenIndex; // Track if we should insert between clips
      
      for (int i = 0; i < widget.clips.length; i++) {
        if (i == index) continue;
        final other = widget.clips[i];
        final otherEnd = other.timelineStart + other.effectiveDuration;
        
        // Snap Start-to-End (My Left to Other Right) - Most common
        final diffStartEnd = (newStart - otherEnd).abs();
        if (diffStartEnd < snapThreshold && diffStartEnd < minDiff) {
          minDiff = diffStartEnd;
          snapTarget = otherEnd;
          
          // Check if there's another clip right after - this is a junction!
          for (int j = 0; j < widget.clips.length; j++) {
            if (j == index || j == i) continue;
            final nextClip = widget.clips[j];
            // If another clip starts very close to where we're dropping
            if ((nextClip.timelineStart - otherEnd).abs() < 0.5) {
              insertBetweenIndex = j; // We're dropping between i and j
              break;
            }
          }
        }
        
        // Snap End-to-Start (My Right to Other Left)
        final myEnd = newStart + clip.effectiveDuration;
        final diffEndStart = (myEnd - other.timelineStart).abs();
        if (diffEndStart < snapThreshold && diffEndStart < minDiff) {
          minDiff = diffEndStart;
          snapTarget = other.timelineStart - clip.effectiveDuration;
        }
      }
      
      if (snapTarget != null) {
        newStart = snapTarget;
        
        // If we detected a junction insertion, use the special callback
        if (insertBetweenIndex != null && widget.onInsertClipAt != null) {
          widget.onInsertClipAt!(index, snapTarget);
          return; // Don't do normal update, the callback handles it
        }
      }
    }

    final updatedClip = clip.copyWith(timelineStart: newStart);
    widget.onClipUpdated?.call(index, updatedClip);
  }

  void _handleTrimStart(int index, double deltaSeconds) {
    final clip = widget.clips[index];
    final maxTrim = clip.originalDuration - clip.trimEnd - 0.1;
    final newTrimStart = (clip.trimStart + deltaSeconds).clamp(0.0, maxTrim);
    
    // When performing a left trim, we must also shift the timelineStart
    // so that the right edge stays pinned visually (standard NLE behavior)
    final actualDelta = newTrimStart - clip.trimStart;
    final newTimelineStart = clip.timelineStart + actualDelta;
    
    final updatedClip = clip.copyWith(
      trimStart: newTrimStart,
      timelineStart: newTimelineStart,
    );
    widget.onClipUpdated?.call(index, updatedClip);
  }

  void _handleTrimEnd(int index, double deltaSeconds) {
    final clip = widget.clips[index];
    final maxTrim = clip.originalDuration - clip.trimStart - 0.1;
    final oldTrimEnd = clip.trimEnd;
    final newTrimEnd = (clip.trimEnd - deltaSeconds).clamp(0.0, maxTrim);
    final updatedClip = clip.copyWith(trimEnd: newTrimEnd);
    
    // Calculate how much the duration changed (negative = shortened, positive = extended)
    final durationChange = (oldTrimEnd - newTrimEnd); // How much we trimmed off the end
    
    // Use ripple callback if available, otherwise just update the single clip
    if (widget.onRippleTrimEnd != null) {
      widget.onRippleTrimEnd!(index, updatedClip, durationChange);
    } else {
      widget.onClipUpdated?.call(index, updatedClip);
    }
  }
}

/// Painter for time ruler
class TimeRulerPainter extends CustomPainter {
  final double pixelsPerSecond;
  final double totalDuration;

  TimeRulerPainter({
    required this.pixelsPerSecond,
    required this.totalDuration,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;

    final textStyle = TextStyle(
      color: Colors.white60,
      fontSize: 9,
    );

    // Determine interval based on zoom
    double interval = 1.0;
    if (pixelsPerSecond < 20) {
      interval = 10.0;
    } else if (pixelsPerSecond < 50) {
      interval = 5.0;
    } else if (pixelsPerSecond > 100) {
      interval = 0.5;
    }

    int labelCounter = 0;
    for (double t = 0; t <= totalDuration; t += interval) {
      final x = t * pixelsPerSecond;
      
      // Major tick
      canvas.drawLine(
        Offset(x, size.height - 8),
        Offset(x, size.height),
        paint,
      );

      // Time label - only every 5 ticks to reduce overhead
      if (labelCounter % 5 == 0) {
        final label = _formatTime(t);
        final textSpan = TextSpan(text: label, style: textStyle);
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(x + 2, 2));
      }
      labelCounter++;
    }
  }

  String _formatTime(double seconds) {
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    final frames = ((seconds % 1) * 30).floor();
    if (mins > 0) {
      return '$mins:${secs.toString().padLeft(2, '0')}';
    }
    return '${secs}s';
  }

  @override
  bool shouldRepaint(covariant TimeRulerPainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond ||
        oldDelegate.totalDuration != totalDuration;
  }
}

/// Painter for timeline grid
class TimelineGridPainter extends CustomPainter {
  final double pixelsPerSecond;

  TimelineGridPainter({required this.pixelsPerSecond});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;

    final interval = pixelsPerSecond >= 50 ? 1.0 : 5.0;
    final maxX = size.width;

    for (double x = 0; x < maxX; x += interval * pixelsPerSecond) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TimelineGridPainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond;
  }
}

/// Dark grey color for timeline background
const Color kTimelineTrackBackground = Color(0xFF2D2D2D);

/// Painter for playhead triangle
class _PlayheadTrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;
    
    final path = Path()
      ..moveTo(size.width / 2, size.height) // Bottom center point
      ..lineTo(0, 0) // Top left
      ..lineTo(size.width, 0) // Top right
      ..close();
    
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
