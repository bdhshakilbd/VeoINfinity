# SceneBuilder Character Detection & Management Feature

## User Requirements
Add character detection and management to the SceneBuilder (template_page.dart):

### UI Changes:
1. **Two Buttons** (instead of just "Parse"):
   - "Parse" (current functionality)
   - "Analyze Story & Detect Characters" (new)

2. **Right Column Panel** for character management:
   - Shows detected characters with full descriptions
   - Character ID format like Character Studio (e.g., `char_john_suit_001`)
   - Generate character reference images
   - Track which characters appear in each scene

3. **Scene Generation**:
   - Auto-upload character reference images during video generation
   - Link characters to their reference images

## Implementation Plan

### Step 1: Add Character Detection Model
```dart
class DetectedCharacter {
  final String id;           // e.g., "char_john_suit_001"
  final String name;          // e.g., "John"
  final String outfit;        // e.g., "blue suit"
  final String fullDescription;  // Full AI-generated description
  String? referenceImagePath;    // Path to generated character image
  List<int> appearsInScenes;     // Scene indices where this character appears
  
  DetectedCharacter({
    required this.id,
    required this.name,
    required this.outfit,
    required this.fullDescription,
    this.referenceImagePath,
    this.appearsInScenes = const [],
  });
}
```

### Step 2: Add Gemini Analysis Function
```dart
Future<Map<String, dynamic>> analyzeStoryAndDetectCharacters(String storyPrompts) async {
  // Call Gemini API with system prompt:
  final systemPrompt = '''
Analyze the following story prompts and extract all characters.

For each character:
1. Create a unique ID in format: charactername_outfit_###
2. Provide full detailed description (appearance, clothing, features)
3. List all scenes where this character appears

Return JSON:
{
  "characters": [
    {
      "id": "char_john_suit_001",
      "name": "John",
      "outfit": "blue suit",
      "description": "A tall man in his 30s with short brown hair, wearing a tailored blue suit...",
      "scenes": [1, 3, 5, 7]
    }
  ],
  "scene_character_map": {
    "1": ["char_john_suit_001", "char_mary_dress_001"],
    "2": ["char_john_suit_001"],
    ...
  }
}
''';

  // Call Gemini and return parsed result
}
```

### Step 3: UI Layout Changes

```dart
// Add state variables
List<DetectedCharacter> _detectedCharacters = [];
bool _showCharacterPanel = false;
bool _isAnalyzingCharacters = false;

// Update button row
Row(
  children: [
    ElevatedButton(
      onPressed: _parseJSON,
      child: Text('Parse'),
    ),
    SizedBox(width: 8),
    ElevatedButton(
      onPressed: _analyzeAndDetectCharacters,
      child: Text('Analyze Story & Detect Characters'),
    ),
  ],
)

// Add character panel
if (_showCharacterPanel)
  Container(
    width: 350,
    child: CharacterManagementPanel(
      characters: _detectedCharacters,
      onGenerateImage: _generateCharacterImage,
      onCharacterUpdated: (char) => setState(() {}),
    ),
  )
```

### Step 4: Character Panel Widget

```dart
class CharacterManagementPanel extends StatelessWidget {
  final List<DetectedCharacter> characters;
  final Function(DetectedCharacter) onGenerateImage;
  
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('Detected Characters', style: TextStyle(fontSize: 18)),
        Expanded(
          child: ListView.builder(
            itemCount: characters.length,
            itemBuilder: (context, index) {
              final char = characters[index];
              return Card(
                child: Column(
                  children: [
                    Text(char.name, style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('ID: ${char.id}'),
                    Text(char.fullDescription, maxLines: 3),
                    if (char.referenceImagePath != null)
                      Image.file(File(char.referenceImagePath!), height: 100),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: () => onGenerateImage(char),
                          child: Text(char.referenceImagePath == null 
                            ? 'Generate Image' 
                            : 'Regenerate'),
                        ),
                        Text('Appears in ${char.appearsInScenes.length} scenes'),
                      ],
                    ),
                    Wrap(
                      children: char.appearsInScenes.map((sceneIdx) => 
                        Chip(label: Text('Scene $sceneIdx'))
                      ).toList(),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
```

### Step 5: Video Generation Integration

```dart
Future<void> _generateScenesWithCharacters() async {
  for (var scene in scenes) {
    // Find characters in this scene
    final sceneCharacters = _detectedCharacters
      .where((char) => char.appearsInScenes.contains(scene.index))
      .toList();
    
    // Upload character reference images
    for (var char in sceneCharacters) {
      if (char.referenceImagePath != null) {
        final refImageId = await uploadCharacterReference(char.referenceImagePath!);
        scene.characterReferences[char.id] = refImageId;
      }
    }
    
    // Generate video with character references
    await generateVideoWithReferences(scene);
  }
}
```

## Files to Modify

1. **lib/screens/template_page.dart**:
   - Add DetectedCharacter model
   - Add character analysis function
   - Add character management UI
   - Integrate with video generation

2. **lib/services/gemini_api_service.dart** (if needed):
   - Add character analysis method

## Testing Plan

1. Paste story prompts with multiple characters
2. Click "Analyze Story & Detect Characters"
3. Verify character extraction with proper IDs
4. Generate character reference images
5. Verify characters appear in correct scenes
6. Generate videos and verify character references are uploaded

## Next Steps

1. Implement DetectedCharacter model
2. Add Gemini analysis function
3. Create character panel UI
4. Integrate with video generation
