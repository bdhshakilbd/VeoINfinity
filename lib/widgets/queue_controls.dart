import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'dart:io';
import '../utils/config.dart';
import '../services/profile_manager_service.dart';
import 'compact_profile_manager.dart';

class QueueControls extends StatelessWidget {
  final int fromIndex;
  final int toIndex;
  final double rateLimit;
  final String selectedModel;
  final String selectedAspectRatio;
  final String selectedAccountType; // 'free', 'ai_pro', 'ai_ultra'
  final bool isRunning;
  final bool isPaused;
  final bool use10xBoostMode; // NEW: 10x Boost Mode toggle
  final Function(int) onFromChanged;
  final Function(int) onToChanged;
  final Function(double) onRateLimitChanged;
  final Function(String) onModelChanged;
  final Function(String) onAspectRatioChanged;
  final Function(String) onAccountTypeChanged;
  final Function(bool) on10xBoostModeChanged; // NEW: Mode toggle callback
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onRetryFailed;
  
  // Profile management
  final String selectedProfile;
  final List<String> profiles;
  final Function(String) onProfileChanged;
  final VoidCallback onLaunchChrome;
  final VoidCallback onCreateProfile;
  final Function(String) onDeleteProfile; // Delete profile callback
  
  // Multi-profile management
  final ProfileManagerService? profileManager;
  final Function(int, String, String)? onLoginAll;
  final Function(int)? onConnectOpened;
  final Function(int)? onOpenWithoutLogin;
  final VoidCallback? onStopLogin;

  const QueueControls({
    super.key,
    required this.fromIndex,
    required this.toIndex,
    required this.rateLimit,
    required this.selectedModel,
    required this.selectedAspectRatio,
    required this.selectedAccountType,
    required this.isRunning,
    required this.isPaused,
    required this.use10xBoostMode, // NEW
    required this.onFromChanged,
    required this.onToChanged,
    required this.onRateLimitChanged,
    required this.onModelChanged,
    required this.onAspectRatioChanged,
    required this.onAccountTypeChanged,
    required this.on10xBoostModeChanged, // NEW
    required this.onStart,
    required this.onPause,
    required this.onStop,
    required this.onRetryFailed,
    required this.selectedProfile,
    required this.profiles,
    required this.onProfileChanged,
    required this.onLaunchChrome,
    required this.onCreateProfile,
    required this.onDeleteProfile,
    this.profileManager,
    this.onLoginAll,
    this.onConnectOpened,
    this.onOpenWithoutLogin,
    this.onStopLogin,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 850;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main Layout
            if (isMobile)
              // Mobile Layout (Ultra Compact - All in ONE ROW)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Controls Row - Compact
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Aspect Ratio - Smaller to fit row
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () => onAspectRatioChanged('VIDEO_ASPECT_RATIO_LANDSCAPE'),
                            child: Container(
                              width: 32, height: 20,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE' ? Colors.blue : Colors.grey.shade400,
                                  width: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE' ? 2 : 1,
                                ),
                                borderRadius: BorderRadius.circular(3),
                                color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE' ? Colors.blue.withOpacity(0.15) : Colors.white,
                              ),
                              child: Center(child: Text('16:9', style: TextStyle(fontSize: 7, fontWeight: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE' ? FontWeight.bold : FontWeight.normal))),
                            ),
                          ),
                          const SizedBox(width: 2),
                          GestureDetector(
                            onTap: () => onAspectRatioChanged('VIDEO_ASPECT_RATIO_PORTRAIT'),
                            child: Container(
                              width: 20, height: 32,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? Colors.blue : Colors.grey.shade400,
                                  width: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? 2 : 1,
                                ),
                                borderRadius: BorderRadius.circular(3),
                                color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? Colors.blue.withOpacity(0.15) : Colors.white,
                              ),
                              child: Center(child: Text('9:16', style: TextStyle(fontSize: 7, fontWeight: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? FontWeight.bold : FontWeight.normal))),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 6),
                      // Model Picker
                      Expanded(
                        flex: 3,
                        child: SizedBox(
                          height: 32,
                          child: DropdownButtonFormField<String>(
                            value: _getFlowModelDisplayName(selectedModel, selectedAccountType),
                            isDense: true,
                            isExpanded: true,
                            icon: const Icon(Icons.arrow_drop_down, size: 12),
                            style: const TextStyle(fontSize: 9, color: Colors.black),
                            menuMaxHeight: 200,
                            decoration: const InputDecoration(
                              labelText: 'Model',
                              labelStyle: TextStyle(fontSize: 8),
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            ),
                            items: _getModelOptionsForAccount(selectedAccountType).keys.map((name) {
                              return DropdownMenuItem(
                                value: name,
                                child: Text(name, style: const TextStyle(fontSize: 9), overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                final modelOptions = _getModelOptionsForAccount(selectedAccountType);
                                onModelChanged(modelOptions[value]!);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Account Picker
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 32,
                          child: DropdownButtonFormField<String>(
                            value: _getAccountDisplayName(selectedAccountType),
                            isDense: true,
                            isExpanded: true,
                            icon: const Icon(Icons.arrow_drop_down, size: 12),
                            style: const TextStyle(fontSize: 9, color: Colors.black),
                            menuMaxHeight: 150,
                            decoration: InputDecoration(
                              labelText: 'Acc',
                              labelStyle: const TextStyle(fontSize: 8),
                              border: const OutlineInputBorder(),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              fillColor: selectedAccountType == 'ai_ultra' ? Colors.purple.shade50 : selectedAccountType == 'ai_pro' ? Colors.blue.shade50 : Colors.green.shade50,
                              filled: true,
                            ),
                            items: AppConfig.accountTypeOptions.keys.map((name) {
                              return DropdownMenuItem(
                                value: name,
                                child: Text(name, style: const TextStyle(fontSize: 9), overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                onAccountTypeChanged(AppConfig.accountTypeOptions[value]!);
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Action Buttons Row - At Bottom
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 26,
                          child: ElevatedButton.icon(
                            onPressed: isRunning ? null : onStart,
                            icon: const Icon(Icons.play_arrow, size: 12),
                            label: const Text('Start', style: TextStyle(fontSize: 9)),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: SizedBox(
                          height: 26,
                          child: ElevatedButton.icon(
                            onPressed: isRunning ? onPause : null,
                            icon: Icon(isPaused ? Icons.play_arrow : Icons.pause, size: 12),
                            label: Text(isPaused ? 'Resume' : 'Pause', style: const TextStyle(fontSize: 9)),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: SizedBox(
                          height: 26,
                          child: ElevatedButton.icon(
                            onPressed: isRunning ? onStop : null,
                            icon: const Icon(Icons.stop, size: 12),
                            label: const Text('Stop', style: TextStyle(fontSize: 9)),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: SizedBox(
                          height: 26,
                          child: ElevatedButton.icon(
                            onPressed: onRetryFailed,
                            icon: const Icon(Icons.refresh, size: 12),
                            label: const Text('Retry', style: TextStyle(fontSize: 9)),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Multi-Browser removed from mobile - it's in the Browser tab
                ],
              )
            else
              // Desktop Layout (Horizontal Row)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left side: Generation controls
                  Flexible(
                    flex: 5,
                    child: _buildGenerationControls(),
                  ),

                  // Spacer to push profile to the right
                  const Spacer(),

                  // Vertical divider
                  Container(
                    width: 1,
                    height: 60,
                    color: Colors.grey.shade300,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                  ),

                  // Right side: Profile management button + Multi-Browser
                  SizedBox(
                    width: 220,
                    child: _buildProfileControls(context, isMobile: false),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _buildGenerationControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Row 1: From/To, Rate, Ratio, Model
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Aspect Ratio - Visual Selector
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Ratio:', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                // Landscape box
                GestureDetector(
                  onTap: () => onAspectRatioChanged('VIDEO_ASPECT_RATIO_LANDSCAPE'),
                  child: Container(
                    width: 40,
                    height: 26,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE'
                            ? Colors.blue
                            : Colors.grey.shade400,
                        width: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE' ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                      color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE'
                          ? Colors.blue.withOpacity(0.1)
                          : Colors.white,
                    ),
                    child: Center(
                      child: Text(
                        '16:9',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE'
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_LANDSCAPE'
                              ? Colors.blue
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Portrait box
                GestureDetector(
                  onTap: () => onAspectRatioChanged('VIDEO_ASPECT_RATIO_PORTRAIT'),
                  child: Container(
                    width: 26,
                    height: 40,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT'
                            ? Colors.blue
                            : Colors.grey.shade400,
                        width: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                      color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT'
                          ? Colors.blue.withOpacity(0.1)
                          : Colors.white,
                    ),
                    child: Center(
                      child: Text(
                        '9:16',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT'
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: selectedAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT'
                              ? Colors.blue
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            // Model (Flow UI models based on account type)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Model:', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<String>(
                    value: _getFlowModelDisplayName(selectedModel, selectedAccountType),
                    isDense: true,
                    isExpanded: true,
                    icon: const Icon(Icons.arrow_drop_down, size: 18),
                    style: const TextStyle(fontSize: 14, color: Colors.black, fontFamily: 'Arial'),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      fillColor: selectedAccountType == 'ai_ultra' 
                          ? Colors.purple.shade50 
                          : Colors.white,
                      filled: true,
                    ),
                    items: _getModelOptionsForAccount(selectedAccountType).keys.map((name) {
                      return DropdownMenuItem(
                        value: name,
                        child: Text(
                          name,
                          style: const TextStyle(fontSize: 13, fontFamily: 'Arial'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        final modelOptions = _getModelOptionsForAccount(selectedAccountType);
                        onModelChanged(modelOptions[value]!);
                      }
                    },
                  ),
                ),
              ],
            ),

            // Account Type Selector
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Account:', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<String>(
                    value: _getAccountDisplayName(selectedAccountType),
                    isDense: true,
                    isExpanded: true,
                    icon: const Icon(Icons.arrow_drop_down, size: 18),
                    style: const TextStyle(fontSize: 14, color: Colors.black, fontFamily: 'Arial'),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      fillColor: selectedAccountType == 'ai_ultra' 
                          ? Colors.purple.shade50 
                          : selectedAccountType == 'ai_pro'
                              ? Colors.blue.shade50
                              : Colors.green.shade50,
                      filled: true,
                    ),
                    items: AppConfig.accountTypeOptions.keys.map((name) {
                      final value = AppConfig.accountTypeOptions[name]!;
                      return DropdownMenuItem(
                        value: name,
                        child: Row(
                          children: [
                            Icon(
                              value == 'ai_ultra'
                                  ? Icons.star
                                  : value == 'ai_pro'
                                      ? Icons.workspace_premium
                                      : Icons.auto_awesome,
                              size: 14,
                              color: value == 'ai_ultra'
                                  ? Colors.purple
                                  : value == 'ai_pro'
                                      ? Colors.blue
                                      : Colors.green,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                name,
                                style: const TextStyle(fontSize: 14, fontFamily: 'Arial'),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        onAccountTypeChanged(AppConfig.accountTypeOptions[value]!);
                      }
                    },
                  ),
                ),
              ],
            ),
            
            // Generation Mode Toggle (Normal vs 10x Boost)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Speed:', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => on10xBoostModeChanged(!use10xBoostMode),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: use10xBoostMode
                          ? LinearGradient(
                              colors: [Colors.orange.shade400, Colors.deepOrange.shade500],
                            )
                          : null,
                      color: use10xBoostMode ? null : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: use10xBoostMode ? Colors.deepOrange.shade700 : Colors.grey.shade400,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          use10xBoostMode ? Icons.rocket_launch : Icons.speed,
                          size: 16,
                          color: use10xBoostMode ? Colors.white : Colors.grey.shade700,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          use10xBoostMode ? '10x Boost Mode' : 'Normal Mode',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: use10xBoostMode ? Colors.white : Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),

        // Row 2: Control buttons
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            ElevatedButton.icon(
              onPressed: isRunning ? null : onStart,
              icon: const Icon(Icons.play_arrow, size: 12),
              label: const Text('Start', style: TextStyle(fontSize: 14, fontFamily: 'Arial')),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                minimumSize: const Size(0, 26),
              ),
            ),
            ElevatedButton.icon(
              onPressed: isRunning ? onPause : null,
              icon: Icon(isPaused ? Icons.play_arrow : Icons.pause, size: 12),
              label: Text(isPaused ? 'Resume' : 'Pause', style: const TextStyle(fontSize: 14, fontFamily: 'Arial')),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                minimumSize: const Size(0, 26),
              ),
            ),
            ElevatedButton.icon(
              onPressed: isRunning ? onStop : null,
              icon: const Icon(Icons.stop, size: 12),
              label: const Text('Stop', style: TextStyle(fontSize: 14, fontFamily: 'Arial')),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                minimumSize: const Size(0, 26),
              ),
            ),
            ElevatedButton.icon(
              onPressed: onRetryFailed,
              icon: const Icon(Icons.refresh, size: 12),
              label: const Text('Retry', style: TextStyle(fontSize: 14, fontFamily: 'Arial')),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                minimumSize: const Size(0, 26),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProfileControls(BuildContext context, {required bool isMobile}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Multi-Browser Section with Manage Profiles on the right
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Multi-Browser', style: TextStyle(fontSize: 11, color: Colors.grey)),
            // Compact button for browser profile management
            InkWell(
              onTap: () => _showBrowserProfileDialog(context),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.computer, size: 12, color: Colors.blue.shade700),
                    const SizedBox(width: 4),
                    Text(
                      'Profiles',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Colors.blue.shade700),
                    ),
                    Icon(Icons.arrow_drop_down, size: 14, color: Colors.blue.shade400),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (profileManager != null)
          CompactProfileManagerWidget(
            profileManager: profileManager,
            onLoginAll: onLoginAll,
            onConnectOpened: onConnectOpened,
            onOpenWithoutLogin: onOpenWithoutLogin,
            onStop: onStopLogin,
          ),
      ],
    );
  }

  void _showBrowserProfileDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.computer, color: Colors.blue),
            const SizedBox(width: 8),
            const Text('Browser Profiles'),
          ],
        ),
        content: SizedBox(
          width: 350,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Profile Selection
              const Text('Select Profile', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 8),
              profiles.isEmpty
                ? Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('No profiles created yet', style: TextStyle(color: Colors.grey)),
                  )
                : DropdownButtonFormField<String>(
                    value: profiles.contains(selectedProfile) ? selectedProfile : profiles.first,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    items: profiles.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                    onChanged: (v) {
                      if (v != null) onProfileChanged(v);
                    },
                  ),
              const SizedBox(height: 16),
              
              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        onLaunchChrome();
                      },
                      icon: const Icon(Icons.rocket_launch, size: 16),
                      label: const Text('Launch'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        onCreateProfile();
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New Profile'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: profiles.isEmpty ? null : () {
                        Navigator.pop(ctx);
                        onDeleteProfile(selectedProfile);
                      },
                      icon: Icon(Icons.delete, size: 16, color: profiles.isEmpty ? Colors.grey : Colors.red),
                      label: Text('Delete', style: TextStyle(color: profiles.isEmpty ? Colors.grey : Colors.red)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: profiles.isEmpty ? Colors.grey : Colors.red.shade300),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _getModelDisplayName(String modelKey) {
    return AppConfig.modelOptions.entries
        .firstWhere((entry) => entry.value == modelKey, orElse: () => AppConfig.modelOptions.entries.first)
        .key;
  }

  String _getAspectRatioDisplayName(String arKey) {
    return AppConfig.aspectRatioOptions.entries
        .firstWhere((entry) => entry.value == arKey, orElse: () => AppConfig.aspectRatioOptions.entries.first)
        .key;
  }

  String _getAccountDisplayName(String accountKey) {
    return AppConfig.accountTypeOptions.entries
        .firstWhere((entry) => entry.value == accountKey, orElse: () => AppConfig.accountTypeOptions.entries.first)
        .key;
  }

  /// Get model options based on account type
  Map<String, String> _getModelOptionsForAccount(String accountType) {
    if (accountType == 'ai_ultra') {
      return AppConfig.flowModelOptionsUltra;
    }
    return AppConfig.flowModelOptions;
  }

  /// Get Flow model display name based on current model value and account type
  String _getFlowModelDisplayName(String modelValue, String accountType) {
    final options = _getModelOptionsForAccount(accountType);
    return options.entries
        .firstWhere((entry) => entry.value == modelValue, orElse: () => options.entries.first)
        .key;
  }
}
