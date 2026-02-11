import 'package:flutter/material.dart';
import '../screens/story_audio_screen.dart';
import '../services/project_service.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';

/// Floating window wrapper for Story Audio Screen
/// Provides minimize/close buttons and draggable window behavior
class FloatingStoryAudioWindow extends StatefulWidget {
  final ProjectService projectService;
  final bool isActivated;
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  final String email;
  final String password;
  final String selectedModel;
  final String selectedAccountType;
  final int initialTabIndex;
  final VoidCallback onClose;

  const FloatingStoryAudioWindow({
    super.key,
    required this.projectService,
    required this.isActivated,
    this.profileManager,
    this.loginService,
    required this.email,
    required this.password,
    required this.selectedModel,
    required this.selectedAccountType,
    this.initialTabIndex = 0,
    required this.onClose,
  });

  @override
  State<FloatingStoryAudioWindow> createState() => _FloatingStoryAudioWindowState();
}

class _FloatingStoryAudioWindowState extends State<FloatingStoryAudioWindow> {
  bool _isMinimized = false;
  Offset _position = const Offset(50, 50);
  Size _size = const Size(1200, 800);

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    // Calculate window dimensions
    final windowWidth = _isMinimized ? 300.0 : _size.width;
    final windowHeight = _isMinimized ? 60.0 : _size.height;

    // Ensure window stays within screen bounds
    // Use max to ensure the upper bound is always >= lower bound (0)
    final maxX = (screenSize.width - windowWidth).clamp(0.0, double.infinity);
    final maxY = (screenSize.height - windowHeight).clamp(0.0, double.infinity);
    
    _position = Offset(
      _position.dx.clamp(0.0, maxX),
      _position.dy.clamp(0.0, maxY),
    );

    return Stack(
      children: [
        // Semi-transparent backdrop
        if (!_isMinimized)
          GestureDetector(
            onTap: () {}, // Prevent clicks from going through
            child: Container(
              color: Colors.black.withOpacity(0.3),
            ),
          ),

        // Floating window
        Positioned(
          left: _position.dx,
          top: _position.dy,
          child: Material(
            elevation: 24,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: _isMinimized ? 300 : _size.width,
              height: _isMinimized ? 60 : _size.height,
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.blue.withOpacity(0.5),
                  width: 2,
                ),
              ),
              child: Column(
                children: [
                  // Title bar with drag, minimize, close
                  _buildTitleBar(),

                  // Content (hidden when minimized)
                  if (!_isMinimized)
                    Expanded(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(10),
                          bottomRight: Radius.circular(10),
                        ),
                        child: StoryAudioScreen(
                          projectService: widget.projectService,
                          isActivated: widget.isActivated,
                          profileManager: widget.profileManager,
                          loginService: widget.loginService,
                          email: widget.email,
                          password: widget.password,
                          selectedModel: widget.selectedModel,
                          selectedAccountType: widget.selectedAccountType,
                          initialTabIndex: widget.initialTabIndex,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTitleBar() {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _position += details.delta;
        });
      },
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.blue.shade700,
              Colors.purple.shade700,
            ],
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10),
            topRight: Radius.circular(10),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Drag handle icon
              const Icon(
                Icons.drag_indicator,
                color: Colors.white70,
                size: 20,
              ),
              const SizedBox(width: 12),

              // Title
              const Icon(
                Icons.movie_creation,
                color: Colors.white,
                size: 24,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Bulk REELS + Manual Audio',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              // Minimize button
              IconButton(
                onPressed: () {
                  setState(() {
                    _isMinimized = !_isMinimized;
                  });
                },
                icon: Icon(
                  _isMinimized ? Icons.maximize : Icons.minimize,
                  color: Colors.white,
                ),
                tooltip: _isMinimized ? 'Maximize' : 'Minimize',
                splashRadius: 20,
              ),

              const SizedBox(width: 4),

              // Close button
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(
                  Icons.close,
                  color: Colors.white,
                ),
                tooltip: 'Close',
                splashRadius: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
