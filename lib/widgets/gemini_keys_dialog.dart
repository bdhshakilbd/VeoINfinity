import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/gemini_key_service.dart';

class GeminiKeysDialog extends StatefulWidget {
  const GeminiKeysDialog({super.key});

  @override
  State<GeminiKeysDialog> createState() => _GeminiKeysDialogState();
}

class _GeminiKeysDialogState extends State<GeminiKeysDialog> {
  List<String> _keys = [];
  final TextEditingController _pasteController = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    final k = await GeminiKeyService.loadKeys();
    setState(() {
      _keys = k;
      _loading = false;
    });
  }

  List<String> _parseKeys(String input) {
    // Split by whitespace, commas, semicolons, or newlines and remove empties
    final parts = input.split(RegExp(r'[\s,;]+')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    return parts;
  }

  Future<void> _addPasted() async {
    final text = _pasteController.text;
    if (text.trim().isEmpty) return;
    final parsed = _parseKeys(text);
    if (parsed.isEmpty) return;
    await GeminiKeyService.addKeys(parsed);
    _pasteController.clear();
    await _loadKeys();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && data!.text!.isNotEmpty) {
      _pasteController.text = data.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Gemini API Keys'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Add one or more Gemini API keys (paste multiple separated by newline/comma).'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pasteController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Paste Gemini keys here...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.paste),
                      label: const Text('Paste'),
                      onPressed: _pasteFromClipboard,
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                      onPressed: _addPasted,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            _loading
                ? const Center(child: CircularProgressIndicator())
                : Expanded(
                    child: _keys.isEmpty
                        ? const Center(child: Text('No keys saved'))
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: _keys.length,
                            itemBuilder: (context, idx) {
                              final k = _keys[idx];
                              return ListTile(
                                title: Text(k, style: const TextStyle(fontSize: 12)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () async {
                                    await GeminiKeyService.removeKey(k);
                                    await _loadKeys();
                                  },
                                ),
                              );
                            },
                          ),
                  ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
