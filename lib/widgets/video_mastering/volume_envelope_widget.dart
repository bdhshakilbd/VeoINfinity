import 'package:flutter/material.dart';

/// Professional volume envelope control - horizontal line with water fill effect
/// Similar to DAW (Digital Audio Workstation) volume automation
class VolumeEnvelopeWidget extends StatelessWidget {
  final double volume; // 0.0 to 5.0 (0% to 500%)
  final double width;
  final double height;
  final Function(double) onVolumeChanged;
  final Color color;
  final bool isMuted;

  const VolumeEnvelopeWidget({
    super.key,
    required this.volume,
    required this.width,
    required this.height,
    required this.onVolumeChanged,
    this.color = Colors.blue,
    this.isMuted = false,
  });

  @override
  Widget build(BuildContext context) {
    // Calculate the vertical position of the volume line (0.0 = bottom, 1.0 = top of 500%)
    final normalizedVolume = (volume / 5.0).clamp(0.0, 1.0);
    final lineY = height * (1.0 - normalizedVolume); // Inverted: higher volume = higher line

    return SizedBox(
      width: width,
      height: height,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          // Only handle events near the volume line (±15px)
          behavior: HitTestBehavior.translucent,
          onVerticalDragUpdate: (details) {
            // Only respond if near the line
            if ((details.localPosition.dy - lineY).abs() < 15) {
              final newY = (lineY + details.delta.dy).clamp(0.0, height);
              final newNormalizedVolume = 1.0 - (newY / height);
              final newVolume = (newNormalizedVolume * 5.0).clamp(0.0, 5.0);
              onVolumeChanged(newVolume);
            }
          },
          onTapDown: (details) {
            // Only respond if near the line
            final tapY = details.localPosition.dy;
            if ((tapY - lineY).abs() < 15) {
              final newNormalizedVolume = 1.0 - (tapY / height);
              final newVolume = (newNormalizedVolume * 5.0).clamp(0.0, 5.0);
              onVolumeChanged(newVolume);
            }
          },
          child: CustomPaint(
            size: Size(width, height),
            painter: _VolumeEnvelopePainter(
              volume: volume,
              lineY: lineY,
              color: isMuted ? Colors.grey : color,
              isMuted: isMuted,
              height: height,
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumeEnvelopePainter extends CustomPainter {
  final double volume;
  final double lineY;
  final Color color;
  final bool isMuted;
  final double height;

  const _VolumeEnvelopePainter({
    required this.volume,
    required this.lineY,
    required this.color,
    required this.isMuted,
    required this.height,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw water fill (filled area below the line) - very subtle
    final fillPaint = Paint()
      ..color = color.withOpacity(isMuted ? 0.05 : 0.15)
      ..style = PaintingStyle.fill;

    final fillRect = Rect.fromLTRB(0, lineY, size.width, size.height);
    canvas.drawRect(fillRect, fillPaint);

    // Draw volume level reference lines (0%, 100%, 200%, etc.) - very subtle
    final referencePaint = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..strokeWidth = 0.5;

    for (int i = 0; i <= 5; i++) {
      final refY = height * (1.0 - (i / 5.0));
      canvas.drawLine(
        Offset(0, refY),
        Offset(size.width, refY),
        referencePaint,
      );
    }

    // Draw the main volume envelope line - more visible
    final linePaint = Paint()
      ..color = isMuted ? Colors.grey : (volume > 1.0 ? Colors.orange : color)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(0, lineY),
      Offset(size.width, lineY),
      linePaint,
    );

    // Draw draggable handle in the center - make it stand out
    final handlePaint = Paint()
      ..color = isMuted ? Colors.grey : (volume > 1.0 ? Colors.orange : Colors.white)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      Offset(size.width / 2, lineY),
      5, // Slightly larger handle
      handlePaint,
    );
    
    // Add a border to the handle for better visibility
    final handleBorderPaint = Paint()
      ..color = Colors.black.withOpacity(0.3)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    
    canvas.drawCircle(
      Offset(size.width / 2, lineY),
      5,
      handleBorderPaint,
    );

    // Draw volume percentage text
    final textSpan = TextSpan(
      text: '${(volume * 100).round()}%',
      style: TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.bold,
        shadows: [
          Shadow(
            color: Colors.black.withOpacity(0.8),
            offset: const Offset(1, 1),
            blurRadius: 2,
          ),
        ],
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();

    // Position text near the handle
    final textX = (size.width / 2) + 10;
    final textY = lineY - (textPainter.height / 2);

    textPainter.paint(canvas, Offset(textX, textY));
  }

  @override
  bool shouldRepaint(_VolumeEnvelopePainter oldDelegate) {
    return oldDelegate.volume != volume ||
        oldDelegate.lineY != lineY ||
        oldDelegate.isMuted != isMuted;
  }
}
