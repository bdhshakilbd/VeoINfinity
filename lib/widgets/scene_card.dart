import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../models/scene_data.dart';
import '../utils/config.dart';

class SceneCard extends StatefulWidget {
  final SceneData scene;
  final Function(String) onPromptChanged;
  final Function(String) onPickImage;
  final Function(String) onClearImage;
  final VoidCallback onGenerate;
  final VoidCallback onOpen;
  final VoidCallback? onOpenFolder;
  final VoidCallback? onDelete;

  const SceneCard({
    super.key,
    required this.scene,
    required this.onPromptChanged,
    required this.onPickImage,
    required this.onClearImage,
    required this.onGenerate,
    required this.onOpen,
    this.onOpenFolder,
    this.onDelete,
  });

  @override
  State<SceneCard> createState() => _SceneCardState();
}

class _SceneCardState extends State<SceneCard> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.scene.prompt);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(SceneCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update controller if the scene prompt changes externally and we are not editing
    if (widget.scene.prompt != oldWidget.scene.prompt) {
      if (!_focusNode.hasFocus && _controller.text != widget.scene.prompt) {
        _controller.text = widget.scene.prompt;
      }
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    // Save when focus is lost
    if (!_focusNode.hasFocus) {
      if (_controller.text != widget.scene.prompt) {
        widget.onPromptChanged(_controller.text);
      }
    }
  }

  Color _getStatusColor() {
    return Color(AppConfig.statusColors[widget.scene.status] ?? 0xFF000000);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(2), // Reduced margin
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4), // Reduced padding
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Scene ${widget.scene.sceneId}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: _getStatusColor(),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.scene.status,
                    style: const TextStyle(color: Colors.white, fontSize: 9),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2), // Reduced gap

            // Direct Text Editing Area
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.white,
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.black,
                    height: 1.15,
                  ),
                  maxLines: null, // Expands
                  expands: true, // Fills the container
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Enter prompt...',
                    hintStyle: TextStyle(fontSize: 10, color: Colors.grey),
                    contentPadding: EdgeInsets.only(top: 4, bottom: 4),
                  ),
                  // We save on focus lost, but we can also add a small delay save?
                  // For now, focus lost is safe and efficient.
                ),
              ),
            ),
            const SizedBox(height: 2), // Reduced gap

            // Frames to Video section (Ultra Compact)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade200),
                borderRadius: BorderRadius.circular(3),
                color: Colors.grey.shade50,
              ),
              child: Row(
                children: [
                  const Icon(Icons.video_library, size: 9, color: Colors.grey),
                  const SizedBox(width: 2),
                  const Text('I2V:', style: TextStyle(fontSize: 8, color: Colors.grey)),
                  const SizedBox(width: 4),
                  Expanded(child: _buildFrameSelector('1st', widget.scene.firstFramePath, 'first')),
                  const SizedBox(width: 2),
                  Expanded(child: _buildFrameSelector('End', widget.scene.lastFramePath, 'last')),
                ],
              ),
            ),
            const SizedBox(height: 2), // Reduced gap

            // Action buttons - compact row
            SizedBox(
              height: 26,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Regenerate button
                  Expanded(
                    child: ElevatedButton(
                      onPressed: widget.onGenerate,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(0, 24),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: widget.scene.status == 'failed' ? Colors.red : null,
                        foregroundColor: widget.scene.status == 'failed' ? Colors.white : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(widget.scene.status == 'failed' ? Icons.refresh : Icons.play_arrow, size: 12),
                          const SizedBox(width: 2),
                          Text(widget.scene.status == 'failed' ? 'Retry' : 'Gen', style: const TextStyle(fontSize: 9)),
                        ],
                      ),
                    ),
                  ),
                  // Show Open and Folder buttons only when completed
                  if (widget.scene.videoPath != null && widget.scene.status == 'completed') ...[
                    const SizedBox(width: 4),
                    // Play video
                    SizedBox(
                      width: 28,
                      child: IconButton(
                        icon: const Icon(Icons.play_circle_filled, size: 18, color: Colors.green),
                        tooltip: 'Play Video',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: widget.onOpen,
                      ),
                    ),
                    // Open Folder
                    if (widget.onOpenFolder != null)
                      SizedBox(
                        width: 28,
                        child: IconButton(
                          icon: const Icon(Icons.folder_open, size: 16, color: Colors.blue),
                          tooltip: 'Open Folder',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: widget.onOpenFolder,
                        ),
                      ),
                  ],
                  // Delete button
                  if (widget.onDelete != null)
                    SizedBox(
                      width: 28,
                      child: IconButton(
                        icon: const Icon(Icons.delete, size: 14, color: Colors.red),
                        tooltip: 'Delete',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: widget.onDelete,
                      ),
                    ),
                ],
              ),
            ),

            // Error message
            if (widget.scene.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.scene.error!,
                  style: const TextStyle(color: Colors.red, fontSize: 8),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrameSelector(String label, String? imagePath, String frameType) {
    return GestureDetector(
      onTap: () => widget.onPickImage(frameType),
      child: Container(
        height: 26, // Compact height
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(3),
          color: Colors.grey.shade100,
        ),
        child: imagePath != null
            ? Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Image.file(
                      File(imagePath),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => widget.onClearImage(frameType),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomLeft: Radius.circular(3),
                          ),
                        ),
                        child: const Icon(Icons.close, size: 10, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_photo_alternate, size: 12, color: Colors.grey),
                  const SizedBox(width: 2),
                  Text(label, style: const TextStyle(fontSize: 8, color: Colors.grey)),
                ],
              ),
      ),
    );
  }
}
