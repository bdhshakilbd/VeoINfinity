import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

/// Widget for displaying and managing imported prompts
class PromptImportPanel extends StatelessWidget {
  final List<String>? prompts;
  final bool isGenerating;
  final int generatedCount;
  final VoidCallback onImport;
  final VoidCallback onPastePrompts;
  final VoidCallback onStartGeneration;
  final VoidCallback onStopGeneration;
  final VoidCallback onRemovePrompts;

  const PromptImportPanel({
    super.key,
    required this.prompts,
    required this.isGenerating,
    required this.generatedCount,
    required this.onImport,
    required this.onPastePrompts,
    required this.onStartGeneration,
    required this.onStopGeneration,
    required this.onRemovePrompts,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade700, width: 1),
      ),
      child: ExpansionTile(
        initiallyExpanded: prompts != null,
        leading: Icon(Icons.list_alt, color: Colors.blue.shade300),
        title: Text(
          prompts == null ? 'Import Prompts' : '${prompts!.length} Prompts Loaded',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        subtitle: prompts != null
            ? Text('Generated: $generatedCount/${prompts!.length}', style: TextStyle(color: Colors.grey.shade400))
            : Text('Import file or paste prompts', style: TextStyle(color: Colors.grey.shade400)),
        children: [
          if (prompts == null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  ElevatedButton.icon(
                    onPressed: onImport,
                    icon: const Icon(Icons.file_upload),
                    label: const Text('Import File (TXT/JSON)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade600,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: onPastePrompts,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Paste Prompts'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Progress bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: prompts!.isEmpty ? 0 : generatedCount / prompts!.length,
                      backgroundColor: Colors.grey.shade800,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade400),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Prompt list preview
                  Container(
                    height: 150,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    child: ListView.builder(
                      itemCount: prompts!.length,
                      itemBuilder: (context, index) {
                        final isGenerated = index < generatedCount;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            isGenerated ? Icons.check_circle : Icons.circle_outlined,
                            color: isGenerated ? Colors.green : Colors.grey,
                            size: 16,
                          ),
                          title: Text(
                            prompts![index],
                            style: TextStyle(
                              fontSize: 12,
                              color: isGenerated ? Colors.grey.shade500 : Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: isGenerating ? onStopGeneration : onStartGeneration,
                          icon: Icon(isGenerating ? Icons.stop : Icons.play_arrow),
                          label: Text(isGenerating ? 'Stop' : 'Generate All'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isGenerating ? Colors.red.shade600 : Colors.green.shade600,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 40),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: isGenerating ? null : onRemovePrompts,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Clear'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey.shade700,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 40),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
