// Reel Special Screen - Dedicated page for Reel Special functionality
// Uses StoryAudioScreen in reelOnlyMode to show only the Reel tab content
// This provides a clean, dedicated experience without the tab bar

import 'package:flutter/material.dart';
import '../services/project_service.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';
import 'story_audio_screen.dart';

/// A dedicated screen for the Reel Special functionality.
/// 
/// This screen uses StoryAudioScreen in reelOnlyMode, which:
/// - Shows only the "Reel Special" tab content
/// - Removes the tab bar completely
/// - Uses a dedicated "Reel Special" title in the AppBar
/// - Shares all the same state and functionality as the original
/// 
/// This approach ensures:
/// - No code duplication (all 3000+ lines of reel logic are reused)
/// - Full functionality (all features work exactly the same)
/// - Clean UI (no tab bar, dedicated title)
class ReelSpecialScreen extends StatelessWidget {
  final ProjectService projectService;
  final bool isActivated;
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  final String email;
  final String password;
  final String selectedModel;
  final String selectedAccountType;
  final VoidCallback? onBack;
  final bool embedded;

  const ReelSpecialScreen({
    super.key,
    required this.projectService,
    required this.isActivated,
    this.profileManager,
    this.loginService,
    this.email = '',
    this.password = '',
    this.selectedModel = 'Veo 3.1 - Fast',
    this.selectedAccountType = 'ai_pro',
    this.onBack,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    // Use StoryAudioScreen in reelOnlyMode for full functionality without tabs
    return StoryAudioScreen(
      projectService: projectService,
      isActivated: isActivated,
      profileManager: profileManager,
      loginService: loginService,
      email: email,
      password: password,
      selectedModel: selectedModel,
      selectedAccountType: selectedAccountType,
      reelOnlyMode: true, // This removes the tab bar and shows only Reel content
      onBack: onBack,
      embedded: embedded,
    );
  }
}
