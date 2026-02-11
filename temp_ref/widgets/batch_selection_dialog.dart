import 'package:flutter/material.dart';

class BatchSelectionDialog extends StatefulWidget {
  final List<String> prompts;

  const BatchSelectionDialog({Key? key, required this.prompts}) : super(key: key);

  @override
  State<BatchSelectionDialog> createState() => _BatchSelectionDialogState();
}

class _BatchSelectionDialogState extends State<BatchSelectionDialog> {
  late TextEditingController _startController;
  late TextEditingController _endController;
  bool _clearHistory = false;
  int _startIndex = 1;
  int _endIndex = 0;

  @override
  void initState() {
    super.initState();
    _endIndex = widget.prompts.length;
    _startController = TextEditingController(text: '1');
    _endController = TextEditingController(text: '${widget.prompts.length}');
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  void _onImport() {
    final start = int.tryParse(_startController.text) ?? 1;
    final end = int.tryParse(_endController.text) ?? widget.prompts.length;

    // Validate
    if (start < 1 || end > widget.prompts.length || start > end) {
       ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('Invalid range selected'), backgroundColor: Colors.red),
       );
       return;
    }

    final selectionData = {
      'startIndex': start,
      'endIndex': end,
      'clearHistory': _clearHistory,
    };
    Navigator.pop(context, selectionData);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.grey.shade900,
      title: const Text('Select Prompts to Import', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Found ${widget.prompts.length} prompts.',
            style: TextStyle(color: Colors.grey.shade300, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'From',
                    labelStyle: TextStyle(color: Colors.grey.shade500),
                    filled: true,
                    fillColor: Colors.grey.shade800,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _endController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'To',
                    labelStyle: TextStyle(color: Colors.grey.shade500),
                    filled: true,
                    fillColor: Colors.grey.shade800,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Checkbox(
                value: _clearHistory,
                activeColor: Colors.blue.shade600,
                onChanged: (val) => setState(() => _clearHistory = val ?? false),
              ),
              const Text('Start Over (Clear current history)', style: TextStyle(color: Colors.white)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: Colors.grey.shade400)),
        ),
        ElevatedButton(
          onPressed: _onImport,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade600, foregroundColor: Colors.white),
          child: const Text('Import Selected'),
        ),
      ],
    );
  }
}
