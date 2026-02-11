import 'package:flutter/material.dart';

class PlayIconPainter extends CustomPainter {
  final Color color;
  
  PlayIconPainter({this.color = Colors.white});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    
    // Calculate triangle vertices for perfect centering
    // Center is (size.width / 2, size.height / 2)
    // Side length s
    // Height h = s * sqrt(3) / 2
    // Centroid divides height in 2:1 ratio
    
    final cx = size.width / 2;
    final cy = size.height / 2;
    
    // Let's use a size proportional to the canvas
    final radius = size.width * 0.4; // 40% of size (e.g. 24 * 0.4 = 9.6)
    
    // Triangle pointing right:
    // Tip at (cx + r, cy) ?? No, that's not centroid centered.
    // Centroid of equilateral triangle is at geometric center.
    // Tip: (cx + 2/3 * h, cy)
    // Base x: (cx - 1/3 * h)
    
    // We want the visual mass to be centered.
    // The "radius" r describes the circumcircle.
    
    // Point 1 (Tip): 0 degrees. (cx + r, cy)
    // Point 2: 120 degrees.
    // Point 3: 240 degrees.
    
    path.moveTo(cx + radius, cy); // Tip
    path.lineTo(cx - radius * 0.5, cy - radius * 0.866); // Top left
    path.lineTo(cx - radius * 0.5, cy + radius * 0.866); // Bottom left
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
