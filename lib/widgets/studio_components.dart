import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

/// Premium Color Scheme based on the reference design
class StudioColors {
  static const Color primary = Color(0xFF1E40AF); // Premium Royal Blue
  static const Color primaryHover = Color(0xFF1E3A8A);
  static const Color backgroundLight = Color(0xFFF7F9FC); // Ivory
  static const Color backgroundDark = Color(0xFF0F172A); // Dark Slate
  static const Color cardLight = Colors.white;
  static const Color cardDark = Color(0xFF1E293B);
  static const Color borderLight = Color(0xFFE2E8F0);
  static const Color borderDark = Color(0xFF334155);
  static const Color textPrimary = Color(0xFF1E293B);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color success = Color(0xFF10B981);
  static const Color danger = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);
}

/// Character panel item widget
class CharacterListItem extends StatelessWidget {
  final String name;
  final String? imagePath;
  final bool isActive;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  const CharacterListItem({
    super.key,
    required this.name,
    this.imagePath,
    this.isActive = false,
    this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? StudioColors.primary.withOpacity(0.3) : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // Avatar
                Stack(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: StudioColors.primary, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: StudioColors.primary.withOpacity(0.2),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: imagePath != null && File(imagePath!).existsSync()
                            ? Image.file(File(imagePath!), fit: BoxFit.cover)
                            : Container(
                                color: StudioColors.primary.withOpacity(0.1),
                                child: Icon(Icons.person, color: StudioColors.primary.withOpacity(0.5)),
                              ),
                      ),
                    ),
                    if (isActive)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: StudioColors.success,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: StudioColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isActive 
                              ? const Color(0xFFEFF6FF)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isActive ? 'Active' : 'Idle',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isActive 
                                ? StudioColors.primary
                                : StudioColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // More button
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  color: StudioColors.textSecondary,
                  onPressed: onMore,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Generated image card widget
class GeneratedImageCard extends StatelessWidget {
  final String imagePath;
  final String? prompt;
  final String? sceneNumber;
  final String? duration;
  final Function(String)? onRegenerate;
  final VoidCallback? onView;

  const GeneratedImageCard({
    super.key,
    required this.imagePath,
    this.prompt,
    this.sceneNumber,
    this.duration,
    this.onRegenerate,
    this.onView,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Main Image
            AspectRatio(
              aspectRatio: 16 / 9,
              child: File(imagePath).existsSync()
                  ? Image.file(File(imagePath), fit: BoxFit.cover)
                  : Container(
                      color: const Color(0xFFF1F5F9),
                      child: const Icon(Icons.image, size: 48, color: Color(0xFFCBD5E1)),
                    ),
            ),
            
            // Premium Scene Number Overlay
            if (sceneNumber != null)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E40AF), Color(0xFF7C3AED)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    'Scene $sceneNumber',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),

            // Top-Right Action Buttons
            Positioned(
              top: 8,
              right: 8,
              child: _buildIconButton(Icons.refresh, () => _showPromptPopup(context)),
            ),

            // Subtle Status Indicator (bottom-right)
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  duration ?? 'Done',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPromptPopup(BuildContext context) {
    final TextEditingController promptController = TextEditingController(text: prompt);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.edit_note, color: Color(0xFF1E40AF)),
            const SizedBox(width: 8),
            Text('Edit & Regenerate Scene $sceneNumber', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PROMPT (EDITABLE):', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: TextField(
                controller: promptController,
                maxLines: 5,
                style: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF334155)),
                decoration: InputDecoration(
                  hintText: 'Enter scene prompt...',
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(12),
                  hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.info_outline, size: 14, color: Color(0xFF64748B)),
                const SizedBox(width: 4),
                Text(
                  'Original Ref: ${duration ?? '0.0s'}',
                  style: const TextStyle(fontSize: 15, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B), fontSize: 14)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              final newPrompt = promptController.text.trim();
              if (newPrompt.isNotEmpty) {
                Navigator.pop(context);
                onRegenerate?.call(newPrompt);
              }
            },
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('REGENERATE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E40AF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton(IconData icon, VoidCallback? onPressed) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: IconButton(
        icon: Icon(icon, size: 14, color: Colors.white),
        onPressed: onPressed,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Premium toolbar button - Light font style matching reference
class ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;

  const ToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isPrimary) {
      return Container(
        decoration: BoxDecoration(
          color: StudioColors.primary,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Light outlined button matching reference design - no bold/uppercase
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: const Color(0xFF64748B)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF374151),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact number input
class CompactNumberInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final double width;

  const CompactNumberInput({
    super.key,
    required this.label,
    required this.controller,
    this.width = 40,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: StudioColors.textSecondary,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          width: width,
          height: 28,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(6),
            color: Colors.white,
          ),
          child: TextField(
            controller: controller,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              isDense: true,
            ),
            keyboardType: TextInputType.number,
          ),
        ),
      ],
    );
  }
}

/// Terminal/Log panel widget
class TerminalPanel extends StatefulWidget {
  final List<LogEntry> entries;
  final ScrollController? scrollController;
  final VoidCallback? onClose;

  const TerminalPanel({
    super.key,
    required this.entries,
    this.scrollController,
    this.onClose,
  });

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  bool _isFullscreen = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        border: Border(top: BorderSide(color: Color(0xFF334155))),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF1E293B),
              border: Border(bottom: BorderSide(color: Color(0xFF334155))),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 14, color: Color(0xFF94A3B8)),
                const SizedBox(width: 8),
                const Text(
                  'Terminal / Logs',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
                const Spacer(),
                // Connection status
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: const Row(
                    children: [
                      CircleAvatar(radius: 4, backgroundColor: StudioColors.success),
                      SizedBox(width: 6),
                      Text(
                        'Connected',
                        style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                      ),
                    ],
                  ),
                ),
                // Fullscreen toggle
                IconButton(
                  icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen, size: 16),
                  color: const Color(0xFF94A3B8),
                  onPressed: () => setState(() => _isFullscreen = !_isFullscreen),
                  visualDensity: VisualDensity.compact,
                  tooltip: _isFullscreen ? 'Exit Fullscreen' : 'Fullscreen',
                ),
                // Minimize (same as close)
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  color: const Color(0xFF94A3B8),
                  onPressed: widget.onClose,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Minimize',
                ),
              ],
            ),
          ),
          // Log entries
          Expanded(
            flex: _isFullscreen ? 100 : 1, // Expand more when fullscreen
            child: Focus(
              autofocus: false,
              onKey: (node, event) {
                final controller = widget.scrollController;
                if (controller != null && event is RawKeyDownEvent) {
                  const double scrollAmount = 40.0;
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    final newOffset = (controller.offset - scrollAmount).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    final newOffset = (controller.offset + scrollAmount).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
                    final newOffset = (controller.offset - 200).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
                    final newOffset = (controller.offset + 200).clamp(0.0, controller.position.maxScrollExtent);
                    controller.jumpTo(newOffset);
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: Scrollbar(
                controller: widget.scrollController,
                thumbVisibility: true,
                trackVisibility: true,
                thickness: 10,
                radius: const Radius.circular(5),
                child: SingleChildScrollView(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.all(12),
                  child: SelectableText.rich(
                    TextSpan(
                      children: widget.entries.map((entry) {
                        return TextSpan(
                          children: [
                            TextSpan(
                              text: '[${entry.time}] ',
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                                color: Color(0xFF64748B),
                              ),
                            ),
                            TextSpan(
                              text: '${entry.level} ',
                              style: TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w600,
                                color: _getLevelColor(entry.level),
                              ),
                            ),
                            TextSpan(
                              text: '${entry.message}\n',
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                                color: Color(0xFFCBD5E1),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: Color(0xFFCBD5E1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getLevelColor(String level) {
    switch (level.toUpperCase()) {
      case 'INFO':
        return const Color(0xFF60A5FA);
      case 'SUCCESS':
        return const Color(0xFF34D399);
      case 'ERROR':
        return const Color(0xFFF87171);
      case 'GEN':
        return const Color(0xFFA78BFA);
      case 'WARN':
        return const Color(0xFFFBBF24);
      default:
        return const Color(0xFF94A3B8);
    }
  }
}

class LogEntry {
  final String time;
  final String level;
  final String message;

  LogEntry({required this.time, required this.level, required this.message});
}

/// Scene control header widget
class ScenesControlHeader extends StatelessWidget {
  final int currentScene;
  final int totalScenes;
  final List<String> activeCharacters;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onCopy;

  const ScenesControlHeader({
    super.key,
    required this.currentScene,
    required this.totalScenes,
    required this.activeCharacters,
    this.onPrevious,
    this.onNext,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFFFAFAFC),
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1: Scene control and copy button
          Row(
            children: [
              const Text(
                'Scenes Control',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: StudioColors.textPrimary,
                ),
              ),
              const SizedBox(width: 12),
              // Scene navigator
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left, size: 18),
                      onPressed: onPrevious,
                      visualDensity: VisualDensity.compact,
                      color: StudioColors.textSecondary,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: const BoxDecoration(
                        border: Border.symmetric(
                          vertical: BorderSide(color: Color(0xFFE2E8F0)),
                        ),
                      ),
                      child: Text(
                        '$currentScene / $totalScenes',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, size: 18),
                      onPressed: onNext,
                      visualDensity: VisualDensity.compact,
                      color: StudioColors.textSecondary,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.content_copy, size: 16),
                onPressed: onCopy,
                tooltip: 'Copy Prompt',
                color: StudioColors.textSecondary,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Row 2: Active tags (more space)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFBFDBFE)),
            ),
            child: Row(
              children: [
                const Icon(Icons.label_outline, size: 12, color: Color(0xFF1E40AF)),
                const SizedBox(width: 6),
                const Text(
                  'Active Tags:',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1E40AF),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    activeCharacters.isEmpty ? 'None' : activeCharacters.join(', '),
                    style: TextStyle(
                      fontSize: 11,
                      color: const Color(0xFF1E40AF).withOpacity(0.8),
                      fontWeight: FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
