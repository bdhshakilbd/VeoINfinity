import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/story_models.dart';

/// Widget for displaying and managing story import
class StoryImportPanel extends StatelessWidget {
  final StoryProject? project;
  final bool isGenerating;
  final bool isPaused;
  final VoidCallback onImport;
  final Future<void> Function(StoryCharacter) onGenerateCharacter;
  final Future<void> Function(StoryCharacter, File) onLoadCustomImage;
  final Function(StoryCharacter, String) onEditCharacterPrompt;
  final VoidCallback onGenerateAllCharacters;
  final void Function(StoryCharacter)? onRemoveCharacterImage; // Optional
  final VoidCallback onStartGeneration;
  final VoidCallback onPauseGeneration;
  final VoidCallback onResumeGeneration;

  final VoidCallback onStopGeneration;
  final VoidCallback onRemoveStory;

  const StoryImportPanel({
    super.key,
    required this.project,
    required this.isGenerating,
    required this.isPaused,
    required this.onImport,
    required this.onGenerateCharacter,
    required this.onLoadCustomImage,
    required this.onEditCharacterPrompt,
    required this.onGenerateAllCharacters,
    this.onRemoveCharacterImage, // Optional
    required this.onStartGeneration,
    required this.onPauseGeneration,
    required this.onResumeGeneration,
    required this.onStopGeneration,
    required this.onRemoveStory,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.shade700, width: 1),
      ),
      child: ExpansionTile(
        initiallyExpanded: project != null,
        leading: Icon(Icons.auto_stories, color: Colors.purple.shade300),
        title: Text(
          'Story Import',
          style: TextStyle(
            color: Colors.purple.shade200,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: project != null
            ? Text(
                '${project!.characters.length} chars, ${project!.scenes.length} scenes',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: project == null
                ? _buildImportButton(context)
                : _buildProjectView(context),
          ),
        ],
      ),
    );
  }

  Widget _buildImportButton(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onImport,
      icon: const Icon(Icons.file_upload),
      label: const Text('Import Story JSON'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.purple.shade700,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    );
  }

  Widget _buildProjectView(BuildContext context) {
    final proj = project!;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Project title
        // Project title row with remove button
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    proj.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onRemoveStory,
              icon: Icon(Icons.delete_outline, size: 20, color: Colors.red.shade400),
              tooltip: 'Remove Story',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Characters section with manage button
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Characters: ${proj.readyCharacterCount}/${proj.characters.length} ready',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
            TextButton.icon(
              onPressed: () => _showCharacterDialog(context),
              icon: Icon(Icons.people, size: 16, color: Colors.purple.shade300),
              label: Text('Manage', style: TextStyle(color: Colors.purple.shade300, fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        
        // Mini character preview (first 5)
        _buildCharacterPreview(context),
        const SizedBox(height: 16),

        // Scenes section
        Text(
          'Scenes: ${proj.generatedSceneCount}/${proj.scenes.length} generated',
          style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
        ),
        const SizedBox(height: 8),
        _buildSceneProgress(),
        const SizedBox(height: 12),
        _buildSceneControls(context),
      ],
    );
  }

  Widget _buildCharacterPreview(BuildContext context) {
    final chars = project!.characters;
    final displayCount = chars.length > 5 ? 5 : chars.length;
    final remaining = chars.length - displayCount;
    
    return Row(
      children: [
        ...chars.take(displayCount).map((char) => _buildMiniCharCard(context, char)),
        if (remaining > 0)
          GestureDetector(
            onTap: () => _showCharacterDialog(context),
            child: Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: Colors.grey.shade700,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: Text(
                  '+$remaining',
                  style: TextStyle(color: Colors.grey.shade300, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMiniCharCard(BuildContext context, StoryCharacter char) {
    final hasImage = char.hasGeneratedImage;
    final isReady = char.isReady;
    
    return GestureDetector(
      onTap: () => _showCharacterDialog(context),
      child: Container(
        width: 40,
        height: 40,
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: Colors.grey.shade800,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isReady ? Colors.green.shade600 : hasImage ? Colors.orange.shade600 : Colors.grey.shade700,
            width: 2,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: hasImage && char.imageBytes != null
              ? Image.memory(char.imageBytes!, fit: BoxFit.cover)
              : char.isGenerating
                  ? Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purple.shade300)))
                  : Icon(Icons.person, color: Colors.grey.shade600, size: 20),
        ),
      ),
    );
  }

  void _showCharacterDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => CharacterManagementDialog(
        project: project!,
        onGenerateCharacter: onGenerateCharacter,
        onLoadCustomImage: onLoadCustomImage,
        onEditCharacterPrompt: onEditCharacterPrompt,
        onGenerateAllCharacters: onGenerateAllCharacters,
        onRemoveCharacterImage: onRemoveCharacterImage,
      ),
    );
  }

  Widget _buildSceneProgress() {
    final proj = project!;
    final progress = proj.scenes.isEmpty 
        ? 0.0 
        : proj.generatedSceneCount / proj.scenes.length;
    
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.grey.shade700,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.purple.shade400),
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${proj.generatedSceneCount} / ${proj.scenes.length}',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
            ),
            Text(
              '${(progress * 100).toStringAsFixed(1)}%',
              style: TextStyle(color: Colors.purple.shade300, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSceneControls(BuildContext context) {
    final hasScenes = project!.scenes.isNotEmpty;
    // Allow starting even without all characters - will auto-generate missing
    final canStart = hasScenes && !isGenerating;
    
    return Row(
      children: [
        if (!isGenerating)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: canStart ? onStartGeneration : null,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Start', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade700,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          )
        else ...[
          Expanded(
            child: ElevatedButton.icon(
              onPressed: isPaused ? onResumeGeneration : onPauseGeneration,
              icon: Icon(isPaused ? Icons.play_arrow : Icons.pause, size: 18),
              label: Text(isPaused ? 'Resume' : 'Pause', style: const TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: isPaused ? Colors.green.shade700 : Colors.orange.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: onStopGeneration,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('Stop', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ],
    );
  }
}

/// Full-screen dialog for character management
class CharacterManagementDialog extends StatefulWidget {
  final StoryProject project;
  final Future<void> Function(StoryCharacter) onGenerateCharacter;
  final Future<void> Function(StoryCharacter, File) onLoadCustomImage;
  final Function(StoryCharacter, String) onEditCharacterPrompt;
  final VoidCallback onGenerateAllCharacters;
  final void Function(StoryCharacter)? onRemoveCharacterImage; // Optional

  const CharacterManagementDialog({
    super.key,
    required this.project,
    required this.onGenerateCharacter,
    required this.onLoadCustomImage,
    required this.onEditCharacterPrompt,
    required this.onGenerateAllCharacters,
    this.onRemoveCharacterImage, // Optional
  });

  @override
  State<CharacterManagementDialog> createState() => _CharacterManagementDialogState();
}

class _CharacterManagementDialogState extends State<CharacterManagementDialog> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.grey.shade900,
      child: Container(
        width: 900,
        height: 650,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Character Management',
                  style: TextStyle(
                    color: Colors.purple.shade200,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        // Don't close dialog - let user see real-time updates
                        widget.onGenerateAllCharacters();
                      },
                      icon: const Icon(Icons.auto_fix_high, size: 16),
                      label: const Text('Generate All Missing'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _downloadAllCharacters,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Download All'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(Icons.close, color: Colors.grey.shade400),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.project.readyCharacterCount}/${widget.project.characters.length} characters ready',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
            const SizedBox(height: 16),
            
            // Character grid
            Expanded(
              child: RawScrollbar(
                controller: _scrollController,
                thumbColor: Colors.purple.shade400,
                radius: const Radius.circular(6),
                thickness: 8,
                thumbVisibility: true,
                child: GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(right: 12), // Padding for scrollbar
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 0.7,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: widget.project.characters.length,
                  itemBuilder: (context, index) {
                    return _buildCharacterCard(widget.project.characters[index]);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharacterCard(StoryCharacter char) {
    bool hasImage = char.imageBytes != null;
    bool isReady = char.isReady;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isReady 
            ? BorderSide(color: Colors.green.shade400, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: () => _showCharacterDetails(char),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image area
            Expanded(
              flex: 3,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (char.isGenerating)
                      Container(
                        color: Colors.grey.shade700,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(strokeWidth: 2, color: Colors.purple.shade300),
                              const SizedBox(height: 8),
                              Text('Generating...', style: TextStyle(color: Colors.grey.shade400, fontSize: 10)),
                            ],
                          ),
                        ),
                      )
                    else if (hasImage && char.imageBytes != null)
                      Container(
                        color: Colors.grey.shade900,
                        child: Image.memory(char.imageBytes!, fit: BoxFit.contain),
                      )
                    else if (char.error != null)
                      Container(
                        color: Colors.red.shade900.withOpacity(0.3),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.error, color: Colors.red.shade400, size: 24),
                              const SizedBox(height: 4),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  char.error!,
                                  style: TextStyle(color: Colors.red.shade300, fontSize: 9),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Container(
                        color: Colors.grey.shade700,
                        child: Icon(Icons.person, color: Colors.grey.shade500, size: 48),
                      ),
                    
                    // Status badge
                    if (isReady)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.check, size: 12, color: Colors.white),
                        ),
                      ),
                    
                    // Remove icon (top-left, only if image exists)
                    if (char.imageBytes != null)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: InkWell(
                          onTap: () {
                            widget.onRemoveCharacterImage?.call(char);
                            setState(() {}); // Force rebuild of dialog
                          },
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.red.shade600,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.delete_outline, size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            
            // Info area - reduced flex to prevent overflow
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      char.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      char.description,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    
                    // Editable caption area (if caption exists)
                    if (char.customPrompt != null && char.customPrompt!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade800,
                          border: Border.all(color: Colors.blue.shade700, width: 1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          char.customPrompt!,
                          style: TextStyle(color: Colors.blue.shade300, fontSize: 8, fontStyle: FontStyle.italic),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    
                    const Spacer(),
                    // Buttons in ROW for horizontal layout with labels
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 28,
                                child: ElevatedButton(
                                  onPressed: char.isGenerating 
                                      ? null 
                                      : () async {
                                          await widget.onGenerateCharacter(char);
                                          if (mounted) setState(() {});
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: char.isGenerating ? Colors.grey.shade600 : Colors.purple.shade600,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    minimumSize: const Size(double.infinity, 0),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: char.isGenerating
                                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Icon(Icons.auto_fix_high, size: 16),
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text('GEN', style: TextStyle(fontSize: 7, color: Colors.grey.shade500)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 28,
                                child: ElevatedButton(
                                  onPressed: () async {
                                    await _pickCustomImage(char);
                                    if (mounted) setState(() {});
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue.shade600,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    minimumSize: const Size(double.infinity, 0),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Icon(Icons.upload_file, size: 16),
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text('LOAD', style: TextStyle(fontSize: 7, color: Colors.grey.shade500)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 28,
                                child: ElevatedButton(
                                  onPressed: char.imageBytes != null
                                      ? () async {
                                          await _downloadCharacter(char);
                                          if (mounted) setState(() {});
                                        }
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: char.imageBytes != null ? Colors.green.shade600 : Colors.grey.shade600,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    minimumSize: const Size(double.infinity, 0),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Icon(Icons.download, size: 16),
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text('SAVE', style: TextStyle(fontSize: 7, color: Colors.grey.shade500)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCharacterDetails(StoryCharacter char) {
    _showEditPromptDialog(char);
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    required MaterialColor color,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: onTap == null ? Colors.grey.shade700 : color.shade800,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          children: [
            Icon(icon, size: 14, color: onTap == null ? Colors.grey.shade500 : color.shade200),
            Text(label, style: TextStyle(fontSize: 8, color: onTap == null ? Colors.grey.shade500 : color.shade200)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCustomImage(StoryCharacter char) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        await widget.onLoadCustomImage(char, file);
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  void _showEditPromptDialog(StoryCharacter char) {
    final controller = TextEditingController(text: char.customPrompt ?? char.generationPrompt);
    bool isGenerating = false;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Colors.grey.shade900,
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Edit Prompt for ${char.name}', 
                    style: TextStyle(color: Colors.purple.shade200),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!isGenerating)
                  IconButton(
                    icon: Icon(Icons.close, color: Colors.grey.shade400, size: 20),
                    onPressed: () => Navigator.pop(dialogContext),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Image preview area
                    Container(
                      height: 250,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade800,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade700),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: isGenerating || char.isGenerating
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(color: Colors.purple.shade300),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Generating image...',
                                      style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                                    ),
                                  ],
                                ),
                              )
                            : char.imageBytes != null
                                ? Image.memory(char.imageBytes!, fit: BoxFit.contain)
                                : Center(
                                    child: Icon(Icons.person, color: Colors.grey.shade600, size: 64),
                                  ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Prompt input
                    Text('Prompt:', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      maxLines: 5,
                      enabled: !isGenerating,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: InputDecoration(
                        hintText: 'Enter custom prompt...',
                        hintStyle: TextStyle(color: Colors.grey.shade500),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        filled: true,
                        fillColor: Colors.grey.shade800,
                      ),
                    ),
                    
                    // Status message
                    if (char.error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade900.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          char.error!,
                          style: TextStyle(color: Colors.red.shade300, fontSize: 11),
                        ),
                      ),
                    ],
                    
                    if (char.isReady) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.shade900.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.green.shade400, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              'Ready for scene generation',
                              style: TextStyle(color: Colors.green.shade300, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isGenerating ? null : () => Navigator.pop(dialogContext),
                child: Text('Close', style: TextStyle(color: Colors.grey.shade400)),
              ),
              ElevatedButton.icon(
                onPressed: isGenerating
                    ? null
                    : () async {
                        // Save the edited prompt to customPrompt
                        char.customPrompt = controller.text;
                        
                        setDialogState(() {
                          isGenerating = true;
                        });
                        
                        // Generate using the callback
                        await widget.onGenerateCharacter(char);
                        
                        // Update dialog state after generation
                        if (context.mounted) {
                          setDialogState(() {
                            isGenerating = false;
                          });
                        }
                        
                        // Also update main dialog grid
                        if (mounted) {
                          setState(() {});
                        }
                      },
                icon: isGenerating 
                    ? SizedBox(
                        width: 16, 
                        height: 16, 
                        child: CircularProgressIndicator(
                          strokeWidth: 2, 
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.auto_fix_high, size: 16),
                label: Text(isGenerating ? 'Generating...' : 'Save & Generate'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isGenerating ? Colors.grey.shade600 : Colors.purple.shade700,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Download all characters with images
  Future<void> _downloadAllCharacters() async {
    try {
      // Count characters with images
      final charsWithImages = widget.project.characters
          .where((char) => char.imageBytes != null)
          .toList();
      
      if (charsWithImages.isEmpty) {
        _showMessage('No character images to download');
        return;
      }

      // Create characters folder
      final directory = Directory('characters');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      int savedCount = 0;
      for (final char in charsWithImages) {
        try {
          // Sanitize filename
          final cleanName = char.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
          final file = File('characters/$cleanName.png');
          await file.writeAsBytes(char.imageBytes!);
          savedCount++;
        } catch (e) {
          debugPrint('Error saving ${char.name}: $e');
        }
      }

      _showMessage('Downloaded $savedCount/${charsWithImages.length} characters to "characters" folder');
    } catch (e) {
      _showMessage('Error downloading characters: $e');
    }
  }

  /// Download individual character
  Future<void> _downloadCharacter(StoryCharacter char) async {
    if (char.imageBytes == null) {
      _showMessage('No image to download for ${char.name}');
      return;
    }

    try {
      // Create characters folder
      final directory = Directory('characters');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      // Sanitize filename
      final cleanName = char.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final file = File('characters/$cleanName.png');
      await file.writeAsBytes(char.imageBytes!);

      _showMessage('Downloaded ${char.name} to "characters" folder');
    } catch (e) {
      _showMessage('Error downloading ${char.name}: $e');
    }
  }

  /// Show snackbar message
  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.grey.shade800,
      ),
    );
  }
}
