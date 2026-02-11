# Story Prompt Analyzer Feature Implementation

## Overview
Add a new feature to Character Studio that allows users to paste/import existing story prompts (JSON or text), then analyze them to detect characters and enhance each scene prompt with character attributes.

## User Flow
1. User clicks **"Enter your story prompt"** button (next to "Use Template")
2. Dialog opens to paste/enter JSON or text story prompts
3. User clicks **"Analyze"**
4. System:
   - Keeps the same prompts from the input
   - Detects character IDs in each scene
   - Creates character IDs and descriptions by analyzing all prompts
   - Improves each scene prompt by adding character attributes
   - Shows detected characters on screen
   - Allows auto-generation of character images or import

## Implementation Steps

### 1. Add State Variables
Add to `_CharacterStudioScreenState`:

```dart
// Story Prompt Analyzer
bool _analyzeStoryMode = false;  // Toggle between template mode and analyze mode
final TextEditingController _storyPromptsInputController = TextEditingController();
bool _analyzingStory = false;
```

### 2. Create Story Prompts Input Dialog
Add new method:

```dart
Future<void> _showStoryPromptsDialog() async {
  final controller = TextEditingController();
  
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Enter Your Story Prompts'),
      content: SizedBox(
        width: 600,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste your story prompts in JSON or plain text format:',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: 'Paste your story prompts here...\n\n'
                      'Supported formats:\n'
                      '- JSON array of scenes\n'
                      '- Plain text (one scene per line)\n'
                      '- Full story paragraph',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.pop(context, controller.text);
          },
          icon: const Icon(Icons.analytics),
          label: const Text('Analyze'),
        ),
      ],
    ),
  ).then((result) {
    if (result != null && result.toString().isNotEmpty) {
      _analyzeStoryPrompts(result.toString());
    }
  });
}
```

### 3. Create Story Analysis Function
Add new method to analyze the story and extract characters:

```dart
Future<void> _analyzeStoryPrompts(String inputText) async {
  if (_geminiApi == null || _geminiApi!.keyCount == 0) {
    _log('⚠️ No Gemini API keys available');
    return;
  }
  
  setState(() {
    _analyzingStory = true;
    _storyGenerating = true;  // Reuse existing UI state
  });
  
  try {
    _log('🔍 Analyzing story prompts for characters...');
    
    // Build analysis prompt
    final analysisSystem = '''You are a story analyzer. Your task is to:

1. Parse the input story prompts (JSON or text)
2. Detect all characters mentioned across all scenes
3. Create unique character IDs for each character
4. Generate comprehensive descriptions for each character
5. Enhance each scene prompt by adding character attributes
6. Preserve the original scene content and flow

Character Detection Rules:
- If same person appears with different outfits, create separate IDs (e.g., anna_outfit_001, anna_outfit_002)
- Extract physical appearance, personality, and outfit details from context
- Each character ID must have a complete standalone description

Output the enhanced story with:
- character_reference: Array of detected characters with id, name, description
- output_structure.scenes: Enhanced scene prompts with character attributes added
- output_structure.characters.included_characters: List of all character IDs used
''';

    final schema = _promptTemplates['char_consistent']!['schema'];
    
    // Call Gemini API
    final result = await _geminiApi!.generateContent(
      model: _selectedStoryModel,
      systemInstruction: analysisSystem,
      prompt: 'Analyze and enhance this story:\n\n$inputText',
      responseSchema: schema,
    );
    
    if (result['error'] != null) {
      _log('❌ Analysis failed: ${result['error']}');
      return;
    }
    
    // Parse result
    final rawResponse = result['response'];
    _rawResponse = jsonEncode(rawResponse);
    
    Map<String, dynamic> output;
    if (rawResponse is String) {
      output = jsonDecode(rawResponse);
    } else {
      output = rawResponse as Map<String, dynamic>;
    }
    
    // Extract data
    _generatedFullOutput = output;
    final charRef = output['character_reference'] as List?;
    final outStruct = output['output_structure'] as Map<String, dynamic>?;
    final scenes = (outStruct?['scenes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    
    setState(() {
      _generatedPrompts = scenes;
      
      // Extract and create character data
      _characters.clear();
      if (charRef != null) {
        for (final char in charRef) {
          final charData = CharacterData(
            id: char['id'] ?? '',
            name: char['name'] ?? '',
            description: char['description'] ?? '',
            images: [],  // User can generate or import later
          );
          _characters.add(charData);
          _log('✅ Detected character: ${charData.id} - ${charData.name}');
        }
      }
      
      _analyzingStory = false;
      _storyGenerating = false;
    });
    
    _log('✅ Story analysis complete! Found ${_characters.length} characters and ${scenes.length} scenes');
    _log('💡 You can now generate character images or import reference images');
    
  } catch (e) {
    _log('❌ Story analysis failed: $e');
    setState(() {
      _analyzingStory = false;
      _storyGenerating = false;
    });
  }
}
```

### 4. Update UI - Add Button
In the Prompts tab UI (wherever "Use Template" checkbox is), add new button:

```dart
// Find the existing "Use Template" checkbox area and add:
Row(
  children: [
    // Existing "Use Template" checkbox
    Checkbox(
      value: _useTemplate,
      onChanged: (v) => setState(() => _useTemplate = v ?? false),
    ),
    const Text('Use Template'),
    
    const SizedBox(width: 16),
    
    // NEW: Enter your story prompt button
    ElevatedButton.icon(
      onPressed: _showStoryPromptsDialog,
      icon: const Icon(Icons.input, size: 16),
      label: const Text('Enter your story prompt'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.deepPurple.shade50,
        foregroundColor: Colors.deepPurple,
      ),
    ),
  ],
),
```

### 5. Dispose Controllers
Add to dispose method:

```dart
@override
void dispose() {
  // ... existing code ...
  _storyPromptsInputController.dispose();
  super.dispose();
}
```

## Features Summary

✅ **Enter story prompt**: Paste JSON or text prompts
✅ **Auto-detect characters**: Analyzes all scenes to find characters
✅ **Extract character IDs**: Creates unique IDs for each character/outfit
✅ **Generate descriptions**: Builds complete character descriptions from context
✅ **Enhance prompts**: Adds character attributes to scene prompts while keeping original content
✅ **Display characters**: Shows detected characters on screen
✅ **Image generation ready**: Users can generate or import character images after analysis

## Benefits

1. **No manual character creation**: System extracts from your existing story
2. **Preserves your prompts**: Keeps the exact prompts you wrote, just enhances them
3. **Smart character detection**: Handles multiple outfits/looks of same person
4. **Flexible input**: Accepts JSON, plain text, or paragraph format
5. **Integration**: Works with existing character studio workflow

## Next Steps

After implementation:
1. Test with JSON story prompts
2. Test with plain text prompts  
3. Test with story paragraphs
4. Verify character detection accuracy
5. Test character image generation flow
