import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Full screen loading screen with abstract design and multi-stage progress
class AppLoadingScreen extends StatefulWidget {
  final VoidCallback? onComplete;
  
  const AppLoadingScreen({
    super.key,
    this.onComplete,
  });

  @override
  State<AppLoadingScreen> createState() => _AppLoadingScreenState();
}

class _AppLoadingScreenState extends State<AppLoadingScreen> with TickerProviderStateMixin {
  late AnimationController _rotationController;
  late AnimationController _fadeController;
  late AnimationController _scaleController;
  late AnimationController _orbFlightController;
  late AnimationController _wingFlapController;
  
  int _currentStage = 0;
  double _progress = 0.0;
  
  final List<String> _loadingStages = [
    'Initializing VEO3 Engine...',
    'Loading AI Models...',
    'Connecting to Services...',
    'Preparing Workspace...',
    'Verifying License...',
  ];

  @override
  void initState() {
    super.initState();
    
    // Rotation animation for abstract shapes
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
    
    // Fade animation
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    
    // Scale animation
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    
    // Orb flight animation - super smooth continuous motion
    _orbFlightController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();

    // Wing flapping animation for the bird
    _wingFlapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..repeat(reverse: true);
    
    _startLoadingSequence();
  }

  Future<void> _startLoadingSequence() async {
    for (int stage = 0; stage < _loadingStages.length; stage++) {
      setState(() => _currentStage = stage);
      
      // Simulate loading progress for each stage
      for (int i = 0; i <= 100; i += 2) {
        await Future.delayed(const Duration(milliseconds: 20));
        if (mounted) {
          setState(() {
            _progress = (stage * 100 + i) / (_loadingStages.length * 100);
          });
        }
      }
    }
    
    // Complete
    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted && widget.onComplete != null) {
      widget.onComplete!();
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _fadeController.dispose();
    _scaleController.dispose();
    _orbFlightController.dispose();
    _wingFlapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Abstract background shapes
          Positioned.fill(
            child: CustomPaint(
              painter: AbstractBackgroundPainter(
                rotationAnimation: _rotationController,
                fadeAnimation: _fadeController,
              ),
            ),
          ),
          
          // Flying bird - symbol of freedom and unlimited creation
          _buildFlyingBird(),
          
          // Main content
          Center(
            child: Container(
              padding: const EdgeInsets.all(40),
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Animated Logo
                  _buildAnimatedLogo(),
                  
                  const SizedBox(height: 48),
                  
                  // VEO3 Infinity Title
                  const Text(
                    'VEO3 Infinity',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E3A8A),
                      letterSpacing: 2,
                    ),
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // Slogan
                  const Text(
                    'Unlimited AI Video Generation',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6366F1),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'No bounds',
                    style: TextStyle(
                      fontSize: 16,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey[600],
                      letterSpacing: 1.2,
                    ),
                  ),
                  
                  const SizedBox(height: 60),
                  
                  // Loading Stage Text
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _loadingStages[_currentStage],
                      key: ValueKey(_currentStage),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey[700],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Progress Bar
                  _buildProgressBar(),
                  
                  const SizedBox(height: 16),
                  
                  // Percentage
                  Text(
                    '${(_progress * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[600],
                    ),
                  ),
                  
                  const SizedBox(height: 48),
                  
                  // Stage Indicators
                  _buildStageIndicators(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedLogo() {
    return AnimatedBuilder(
      animation: _scaleController,
      builder: (context, child) {
        return Transform.scale(
          scale: 1.0 + (_scaleController.value * 0.1),
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF6366F1),
                  Color(0xFF8B5CF6),
                  Color(0xFFEC4899),
                ],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6366F1).withOpacity(0.4),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: const Icon(
              Icons.play_circle_filled,
              size: 60,
              color: Colors.white,
            ),
          ),
        );
      },
    );
  }

  Widget _buildProgressBar() {
    return Container(
      width: double.infinity,
      height: 8,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          children: [
            // Background shimmer effect
            AnimatedBuilder(
              animation: _fadeController,
              builder: (context, child) {
                return Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.grey[200]!,
                        Colors.grey[300]!.withOpacity(_fadeController.value),
                        Colors.grey[200]!,
                      ],
                    ),
                  ),
                );
              },
            ),
            // Actual progress
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: _progress,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFF6366F1),
                      Color(0xFF8B5CF6),
                      Color(0xFFEC4899),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStageIndicators() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_loadingStages.length, (index) {
        final isActive = index == _currentStage;
        final isCompleted = index < _currentStage;
        
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: isActive ? 32 : 8,
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: isCompleted || isActive
                  ? const Color(0xFF6366F1)
                  : Colors.grey[300],
            ),
          ),
        );
      }),
    );
  }
  
  Widget _buildFlyingBird() {
    return AnimatedBuilder(
      animation: Listenable.merge([_orbFlightController, _wingFlapController]),
      builder: (context, child) {
        final size = MediaQuery.of(context).size;
        final t = _orbFlightController.value;
        final pos = _calculateBezierPath(t, size);
        
        // Compute forward direction for rotation
        final nextPos = _calculateBezierPath((t + 0.01) % 1.0, size);
        final angle = math.atan2(nextPos.dy - pos.dy, nextPos.dx - pos.dx);
        
        return Positioned(
          left: pos.dx - 35,
          top: pos.dy - 25,
          child: Transform.rotate(
            angle: angle,
            child: CustomPaint(
              size: const Size(70, 50),
              painter: BirdPainter(wingFlap: _wingFlapController.value),
            ),
          ),
        );
      },
    );
  }
  
  /// Calculate position on smooth bezier curve path
  Offset _calculateBezierPath(double t, Size size) {
    // Define control points for smooth bezier curve following your red line path:
    // Starts left → loops around left area → goes up around logo → exits right
    
    // Break the path into connected bezier segments for smooth continuous motion
    if (t < 0.3) {
      // First segment: Left side entry and loop (0.0 - 0.3)
      final segT = t / 0.3;
      return _cubicBezier(
        Offset(size.width * -0.05, size.height * 0.45),  // Start off-screen left
        Offset(size.width * 0.15, size.height * 0.20),   // Control 1 - curve up
        Offset(size.width * 0.25, size.height * 0.40),   // Control 2 - loop down
        Offset(size.width * 0.20, size.height * 0.25),   // End - after loop
        segT,
      );
    } else if (t < 0.6) {
      // Second segment: Around the top/logo area (0.3 - 0.6)
      final segT = (t - 0.3) / 0.3;
      return _cubicBezier(
        Offset(size.width * 0.20, size.height * 0.25),   // Start
        Offset(size.width * 0.35, size.height * 0.05),   // Control 1 - up high
        Offset(size.width * 0.65, size.height * 0.05),   // Control 2 - across top
        Offset(size.width * 0.75, size.height * 0.15),   // End - right side
        segT,
      );
    } else {
      // Third segment: Exit right (0.6 - 1.0)
      final segT = (t - 0.6) / 0.4;
      return _cubicBezier(
        Offset(size.width * 0.75, size.height * 0.15),   // Start
        Offset(size.width * 0.85, size.height * 0.25),   // Control 1
        Offset(size.width * 0.95, size.height * 0.35),   // Control 2
        Offset(size.width * 1.05, size.height * 0.40),   // End - off-screen right
        segT,
      );
    }
  }
  
  /// Cubic bezier interpolation for super smooth curves
  Offset _cubicBezier(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    final mt = 1 - t;
    final mt2 = mt * mt;
    final mt3 = mt2 * mt;
    
    return Offset(
      mt3 * p0.dx + 3 * mt2 * t * p1.dx + 3 * mt * t2 * p2.dx + t3 * p3.dx,
      mt3 * p0.dy + 3 * mt2 * t * p1.dy + 3 * mt * t2 * p2.dy + t3 * p3.dy,
    );
  }
}

/// Painter for elegant swooping bird silhouette
class BirdPainter extends CustomPainter {
  final double wingFlap;

  BirdPainter({required this.wingFlap});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    // Elegant gradient colors
    final primaryColor = const Color(0xFF6366F1);
    final secondaryColor = const Color(0xFF8B5CF6);
    final glowColor = const Color(0xFFA5B4FC);

    final cx = size.width * 0.5;
    final cy = size.height * 0.5;

    // Smooth eased wing angle for natural flapping
    final ease = math.sin(wingFlap * math.pi);
    final wingAngle = -0.25 + ease * 0.5;

    // Glow/shadow behind
    paint.color = glowColor.withOpacity(0.3);
    canvas.drawCircle(Offset(cx, cy), size.width * 0.08, paint);

    // Compact rounded body - proper bird proportion
    paint.color = primaryColor;
    final body = Path()
      ..moveTo(cx - size.width * 0.06, cy)
      ..quadraticBezierTo(cx - size.width * 0.02, cy - size.height * 0.12, cx + size.width * 0.08, cy - size.height * 0.04)
      ..quadraticBezierTo(cx + size.width * 0.12, cy, cx + size.width * 0.08, cy + size.height * 0.04)
      ..quadraticBezierTo(cx - size.width * 0.02, cy + size.height * 0.12, cx - size.width * 0.06, cy)
      ..close();
    canvas.drawPath(body, paint);

    // Small head bump
    paint.color = primaryColor;
    canvas.drawCircle(Offset(cx + size.width * 0.10, cy - size.height * 0.02), size.width * 0.05, paint);

    // Upper wing - graceful arc
    canvas.save();
    canvas.translate(cx - size.width * 0.05, cy - size.height * 0.04);
    canvas.rotate(wingAngle);
    
    // Wing gradient effect via layered paths
    paint.color = secondaryColor;
    final upperWing = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(-size.width * 0.15, -size.height * 0.55, -size.width * 0.50, -size.height * 0.35)
      ..quadraticBezierTo(-size.width * 0.38, -size.height * 0.15, -size.width * 0.18, -size.height * 0.02)
      ..quadraticBezierTo(-size.width * 0.08, 0, 0, 0)
      ..close();
    canvas.drawPath(upperWing, paint);

    // Wing highlight streak
    paint.color = glowColor.withOpacity(0.6);
    final wingStreak = Path()
      ..moveTo(-size.width * 0.08, -size.height * 0.04)
      ..quadraticBezierTo(-size.width * 0.20, -size.height * 0.28, -size.width * 0.38, -size.height * 0.22)
      ..quadraticBezierTo(-size.width * 0.22, -size.height * 0.10, -size.width * 0.08, -size.height * 0.04)
      ..close();
    canvas.drawPath(wingStreak, paint);
    canvas.restore();

    // Lower wing - smaller, trailing
    canvas.save();
    canvas.translate(cx - size.width * 0.05, cy + size.height * 0.04);
    canvas.rotate(-wingAngle * 0.6);
    paint.color = primaryColor.withOpacity(0.8);
    final lowerWing = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(-size.width * 0.12, size.height * 0.35, -size.width * 0.38, size.height * 0.22)
      ..quadraticBezierTo(-size.width * 0.25, size.height * 0.08, -size.width * 0.12, size.height * 0.02)
      ..quadraticBezierTo(-size.width * 0.05, 0, 0, 0)
      ..close();
    canvas.drawPath(lowerWing, paint);
    canvas.restore();

    // Tail feathers - elegant trailing lines
    paint.color = secondaryColor;
    final tail = Path()
      ..moveTo(cx - size.width * 0.20, cy)
      ..quadraticBezierTo(cx - size.width * 0.32, cy - size.height * 0.06, cx - size.width * 0.42, cy - size.height * 0.08)
      ..quadraticBezierTo(cx - size.width * 0.36, cy, cx - size.width * 0.42, cy + size.height * 0.08)
      ..quadraticBezierTo(cx - size.width * 0.32, cy + size.height * 0.06, cx - size.width * 0.20, cy)
      ..close();
    canvas.drawPath(tail, paint);
  }

  @override
  bool shouldRepaint(covariant BirdPainter oldDelegate) => oldDelegate.wingFlap != wingFlap;
}

/// Custom painter for abstract background shapes
class AbstractBackgroundPainter extends CustomPainter {
  final Animation<double> rotationAnimation;
  final Animation<double> fadeAnimation;
  
  AbstractBackgroundPainter({
    required this.rotationAnimation,
    required this.fadeAnimation,
  }) : super(repaint: Listenable.merge([rotationAnimation, fadeAnimation]));

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill;

    // Abstract circle 1 - Top right
    paint.color = const Color(0xFF6366F1).withOpacity(0.05 + fadeAnimation.value * 0.05);
    canvas.save();
    canvas.translate(size.width * 0.85, size.height * 0.15);
    canvas.rotate(rotationAnimation.value * 2 * math.pi);
    canvas.drawCircle(Offset.zero, 120, paint);
    canvas.restore();

    // Abstract circle 2 - Bottom left
    paint.color = const Color(0xFF8B5CF6).withOpacity(0.05 + fadeAnimation.value * 0.05);
    canvas.save();
    canvas.translate(size.width * 0.15, size.height * 0.85);
    canvas.rotate(-rotationAnimation.value * 2 * math.pi);
    canvas.drawCircle(Offset.zero, 150, paint);
    canvas.restore();

    // Abstract rectangle 1
    paint.color = const Color(0xFFEC4899).withOpacity(0.04);
    canvas.save();
    canvas.translate(size.width * 0.1, size.height * 0.3);
    canvas.rotate(rotationAnimation.value * 2 * math.pi * 0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-60, -60, 120, 120),
        const Radius.circular(20),
      ),
      paint,
    );
    canvas.restore();

    // Abstract rectangle 2
    paint.color = const Color(0xFF6366F1).withOpacity(0.04);
    canvas.save();
    canvas.translate(size.width * 0.9, size.height * 0.7);
    canvas.rotate(-rotationAnimation.value * 2 * math.pi * 0.3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-80, -80, 160, 160),
        const Radius.circular(30),
      ),
      paint,
    );
    canvas.restore();

    // Clip art style shapes - Lines
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 2;
    paint.color = const Color(0xFF8B5CF6).withOpacity(0.1);
    
    final path = Path();
    path.moveTo(size.width * 0.05, size.height * 0.5);
    path.quadraticBezierTo(
      size.width * 0.25,
      size.height * 0.3,
      size.width * 0.4,
      size.height * 0.5,
    );
    canvas.drawPath(path, paint);

    // Dotted pattern
    paint.style = PaintingStyle.fill;
    for (int i = 0; i < 5; i++) {
      for (int j = 0; j < 5; j++) {
        if ((i + j) % 2 == 0) {
          paint.color = const Color(0xFF6366F1).withOpacity(0.02);
          canvas.drawCircle(
            Offset(
              size.width * 0.7 + i * 30,
              size.height * 0.2 + j * 30,
            ),
            4,
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(AbstractBackgroundPainter oldDelegate) => true;
}
