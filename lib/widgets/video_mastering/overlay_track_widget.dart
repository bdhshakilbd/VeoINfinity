/// Overlay Track Widget
/// Displays text, image, and logo overlays on the timeline

import 'package:flutter/material.dart';
import '../../models/video_mastering/video_project.dart';

/// Overlay clip widget
class OverlayClipWidget extends StatefulWidget {
  final OverlayItem overlay;
  final double pixelsPerSecond;
  final bool isSelected;
  final bool isMultiSelected; // For Ctrl+A multi-selection visual
  final VoidCallback? onTap;
  final Function(double)? onMove;
  final Function(double)? onDurationChange;

  const OverlayClipWidget({
    super.key,
    required this.overlay,
    required this.pixelsPerSecond,
    this.isSelected = false,
    this.isMultiSelected = false,
    this.onTap,
    this.onMove,
    this.onDurationChange,
  });

  @override
  State<OverlayClipWidget> createState() => _OverlayClipWidgetState();
}

class _OverlayClipWidgetState extends State<OverlayClipWidget> {
  bool _isDragging = false;

  Color get _typeColor {
    switch (widget.overlay.type) {
      case 'text':
        return Colors.orange;
      case 'image':
        return Colors.cyan;
      case 'logo':
        return Colors.amber;
      default:
        return Colors.grey;
    }
  }

  IconData get _typeIcon {
    switch (widget.overlay.type) {
      case 'text':
        return Icons.text_fields;
      case 'image':
        return Icons.image;
      case 'logo':
        return Icons.branding_watermark;
      default:
        return Icons.layers;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.overlay.duration * widget.pixelsPerSecond;
    final left = widget.overlay.timelineStart * widget.pixelsPerSecond;

    return Positioned(
      left: left,
      top: 4,
      child: GestureDetector(
        onTap: widget.onTap,
        onHorizontalDragStart: (_) => setState(() => _isDragging = true),
        onHorizontalDragUpdate: (details) {
          widget.onMove?.call(details.delta.dx / widget.pixelsPerSecond);
        },
        onHorizontalDragEnd: (_) => setState(() => _isDragging = false),
        child: SizedBox(
          width: width.clamp(30.0, double.infinity),
          height: 32,
          child: Stack(
            children: [
              // Main container
              Container(
                decoration: BoxDecoration(
                  color: widget.isSelected ? _typeColor.shade700 : _typeColor.shade500,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: widget.isSelected ? Colors.white : _typeColor.shade800,
                    width: widget.isSelected ? 2 : 1,
                  ),
                  boxShadow: _isDragging
                      ? [BoxShadow(color: _typeColor.withOpacity(0.5), blurRadius: 6)]
                      : null,
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    Icon(_typeIcon, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _getLabel(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Resize handle
                    GestureDetector(
                      onHorizontalDragUpdate: (details) {
                        widget.onDurationChange?.call(details.delta.dx / widget.pixelsPerSecond);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeLeftRight,
                        child: Container(
                          width: 8,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(3),
                              bottomRight: Radius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
                    child: const Center(
                      child: Icon(
                        Icons.check_circle,
                        color: Colors.white,
                        size: 16,
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

  String _getLabel() {
    switch (widget.overlay.type) {
      case 'text':
        return widget.overlay.text.isNotEmpty 
            ? widget.overlay.text 
            : 'Text';
      case 'image':
        return 'Image';
      case 'logo':
        return 'Logo';
      default:
        return 'Overlay';
    }
  }
}

/// Overlay track widget
class OverlayTrackWidget extends StatefulWidget {
  final List<OverlayItem> overlays;
  final double totalDuration;
  final double pixelsPerSecond;
  final double currentPosition;
  final int? selectedIndex;
  final Set<int> selectedIndices; // For Ctrl+A multi-selection
  final Function(int)? onOverlaySelected;
  final Function(int, OverlayItem)? onOverlayUpdated;
  final Function(double)? onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;
  final ScrollController? scrollController;

  const OverlayTrackWidget({
    super.key,
    required this.overlays,
    required this.totalDuration,
    required this.pixelsPerSecond,
    this.currentPosition = 0,
    this.selectedIndex,
    this.selectedIndices = const {},
    this.onOverlaySelected,
    this.onOverlayUpdated,
    this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.scrollController,
  });

  @override
  State<OverlayTrackWidget> createState() => _OverlayTrackWidgetState();
}

class _OverlayTrackWidgetState extends State<OverlayTrackWidget> {
  // External scroll controller provided by parent

  @override
  Widget build(BuildContext context) {
    final timelineWidth = (widget.totalDuration + 10) * widget.pixelsPerSecond;

    return ClipRect(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Track header
          Container(
            height: 18,
            color: Colors.grey.shade800,
            child: Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.layers, size: 12, color: Colors.orange),
                const SizedBox(width: 4),
                const Text(
                  'Overlays',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.overlays.length}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          
          // Overlays area - fills remaining space
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (details) {
                // Click anywhere to move playhead AND deselect
                widget.onOverlaySelected?.call(-1);
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
                color: Colors.orange.withOpacity(0.05),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // Grid
                    Positioned.fill(
                      child: CustomPaint(
                        painter: OverlayGridPainter(
                          pixelsPerSecond: widget.pixelsPerSecond,
                        ),
                      ),
                    ),
                  
                  // Overlay items
                  ...widget.overlays.asMap().entries.map((entry) {
                    final index = entry.key;
                    final overlay = entry.value;
                    return OverlayClipWidget(
                      overlay: overlay,
                      pixelsPerSecond: widget.pixelsPerSecond,
                      isSelected: widget.selectedIndex == index,
                      isMultiSelected: widget.selectedIndices.contains(index),
                      onTap: () => widget.onOverlaySelected?.call(index),
                      onMove: (delta) => _handleMove(index, delta),
                      onDurationChange: (delta) => _handleDurationChange(index, delta),
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

  void _handleMove(int index, double delta) {
    final overlay = widget.overlays[index];
    final newStart = (overlay.timelineStart + delta).clamp(0.0, double.infinity);
    final updated = overlay.copyWith(timelineStart: newStart);
    widget.onOverlayUpdated?.call(index, updated);
  }

  void _handleDurationChange(int index, double delta) {
    final overlay = widget.overlays[index];
    final newDuration = (overlay.duration + delta).clamp(0.5, double.infinity);
    final updated = overlay.copyWith(duration: newDuration);
    widget.onOverlayUpdated?.call(index, updated);
  }
}

/// Grid painter for overlay track
class OverlayGridPainter extends CustomPainter {
  final double pixelsPerSecond;

  OverlayGridPainter({required this.pixelsPerSecond});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.orange.withOpacity(0.1)
      ..strokeWidth = 1;

    final interval = pixelsPerSecond >= 50 ? 1.0 : 5.0;
    
    for (double x = 0; x < size.width; x += interval * pixelsPerSecond) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant OverlayGridPainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond;
  }
}

/// Color extension for shade access
extension ColorShade on Color {
  Color get shade500 => this;
  Color get shade700 => HSLColor.fromColor(this).withLightness(0.35).toColor();
  Color get shade800 => HSLColor.fromColor(this).withLightness(0.25).toColor();
}
