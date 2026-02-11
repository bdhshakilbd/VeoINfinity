# Character Detection Implementation Progress

## ✅ Completed

### 1. Model & State (DONE)
- ✅ Added `DetectedCharacter` model class (line 487-533)
- ✅ Added state variables to `_CreateStoryTabState`:
  - `_detectedCharacters`, `_showCharacterPanel`, `_isAnalyzingCharacters`
  - `_characterAnalysisStatus`, `_sceneCharacterMap`

### 2. Backend Functions (DONE)
- ✅ Added `_analyzeAndDetectCharacters()` function (line 1636-1772)
  - Calls Gemini API with character extraction prompt
  - Parses response and creates DetectedCharacter objects
  - Maps characters to scenes
  
- ✅ Added `_generateCharacterImage()` function (line 2322-2379)
  - Generates character portrait using Whisk API
  - Saves image to disk
  - Uploads to Whisk to get media ID for reference

## 🔨 TODO: UI Updates

### 1. Add Buttons to UI
Need to find the Parse button and add "Analyze Story & Detect Characters" button next to it.

**Location to search:** In the `build()` method around line 2322+

**Code to add:**
```dart
Row(
  children: [
    // Existing Parse button
    ElevatedButton(
      onPressed: _parseJson,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF10B981),
      ),
      child: const Text('Parse'),
    ),
    const SizedBox(width: 8),
    // NEW: Analyze button
    ElevatedButton(
      onPressed: _isAnalyzingCharacters ? null : _analyzeAndDetectCharacters,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF8B5CF6),
      ),
      child: _isAnalyzingCharacters
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Analyze Story & Detect Characters'),
    ),
  ],
)
```

### 2. Add Character Panel (Right Side)
Add a conditional panel that appears when `_showCharacterPanel` is true.

**Should be added in build() after main content:**
```dart
if (_showCharacterPanel)
  Container(
    width: 350,
    margin: const EdgeInsets.only(left: 8),
    decoration: BoxDecoration(
      color: Colors.grey[900],
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.grey[700]!),
    ),
    child: Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[850],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Detected Characters',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => setState(() => _showCharacterPanel = false),
              ),
            ],
          ),
        ),
        
        // Character list
        Expanded(
          child: _detectedCharacters.isEmpty
              ? Center(
                  child: Text(
                    _isAnalyzingCharacters 
                        ? _characterAnalysisStatus
                        : 'No characters detected yet',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _detectedCharacters.length,
                  itemBuilder: (context, index) {
                    final char = _detectedCharacters[index];
                    return Card(
                      color: Colors.grey[850],
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Character name and ID
                            Text(
                              char.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'ID: ${char.id}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[500],
                              ),
                            ),
                            Text(
                              'Outfit: ${char.outfit}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[400],
                              ),
                            ),
                            const SizedBox(height: 8),
                            
                            // Description
                            Text(
                              char.fullDescription,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[300],
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            
                            // Reference image
                            if (char.referenceImagePath != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.file(
                                  File(char.referenceImagePath!),
                                  height: 120,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            const SizedBox(height: 8),
                            
                            // Generate/Regenerate button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: char.isGeneratingImage
                                    ? null
                                    : () => _generateCharacterImage(char),
                                icon: char.isGeneratingImage
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : Icon(
                                        char.referenceImagePath == null
                                            ? Icons.image
                                            : Icons.refresh,
                                        size: 16,
                                      ),
                                label: Text(
                                  char.isGeneratingImage
                                      ? 'Generating...'
                                      : char.referenceImagePath == null
                                          ? 'Generate Image'
                                          : 'Regenerate',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF10B981),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            
                            // Scenes where character appears
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: char.appearsInScenes.map((sceneIdx) {
                                return Chip(
                                  label: Text(
                                    'Scene $sceneIdx',
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  backgroundColor: const Color(0xFF3B82F6).withOpacity(0.3),
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  ),
```

### 3. Update Layout to Support Side Panel
The main build() needs to use a Row to place content and character panel side by side.

**Wrap existing content in:**
```dart
Row(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Expanded(
      child: /* existing content */,
    ),
    if (_showCharacterPanel) /* character panel */,
  ],
)
```

## 📝 Next Steps

1. **Find Parse button location** in build() method
2. **Add "Analyze" button** next to Parse
3. **Restructure layout** to support side panel (Row with Expanded)
4. **Add character panel widget** as shown above
5. **Test** the feature:
   - Parse story prompts
   - Click "Analyze Story & Detect Characters"
   - Verify characters are extracted
   - Generate character images
   - Check scene mapping

## 🔄 Future Enhancements

- Auto-use character references when generating scene videos
- Edit character descriptions
- Manual character addition
- Character reference upload (not just generation)
- Batch generate all character images
