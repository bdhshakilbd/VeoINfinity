import 'dart:convert';
import 'dart:io';
import '../models/story_models.dart';

/// Service for parsing and managing story JSON files
class StoryService {
  /// Parse a story JSON file into a StoryProject
  Future<StoryProject> parseStoryFile(File file) async {
    final content = await file.readAsString();
    return parseStoryJson(content);
  }

  /// Parse story JSON string into a StoryProject
  StoryProject parseStoryJson(String jsonContent) {
    final json = jsonDecode(jsonContent) as Map<String, dynamic>;
    return StoryProject.fromJson(json);
  }

  /// Build a generation prompt for a character reference image
  String buildCharacterPrompt(StoryCharacter character) {
    return character.generationPrompt;
  }

  /// Build scene prompt with outfit info and negative prompt
  /// Characters in scene are only used to select subject reference images
  String buildScenePrompt(
    StoryScene scene, 
    Map<String, StoryCharacter> characters, {
    List<StoryScene>? allScenes,
    String? projectStyle,
  }) {
    final buffer = StringBuffer();
    
    // Add style prefix if project has a style defined
    if (projectStyle != null && projectStyle.isNotEmpty) {
      buffer.write('Style: $projectStyle. ');
    }
    
    // Add the scene's prompt
    buffer.write(scene.prompt);
    
    // Add outfit/clothing appearance for each character in scene
    if (scene.characterIds.isNotEmpty && scene.clothingAppearance.isNotEmpty) {
      final outfitParts = <String>[];
      for (final charId in scene.characterIds) {
        final clothing = scene.clothingAppearance[charId];
        if (clothing != null && clothing.isNotEmpty && 
            !clothing.first.toLowerCase().contains('use previous')) {
          outfitParts.add('$charId wearing: ${clothing.join(', ')}');
        }
      }
      if (outfitParts.isNotEmpty) {
        buffer.write(' [${outfitParts.join('; ')}]');
      }
    }
    
    // Add negative prompt if defined
    if (scene.negativePrompt.isNotEmpty) {
      buffer.write(' [Negative: ${scene.negativePrompt}]');
    }
    
    return buffer.toString();
  }

  /// Get characters that appear in a specific scene
  List<StoryCharacter> getSceneCharacters(
    StoryScene scene,
    Map<String, StoryCharacter> characterMap,
  ) {
    return scene.characterIds
        .where((id) => characterMap.containsKey(id))
        .map((id) => characterMap[id]!)
        .toList();
  }

  /// Get characters that have generated images ready for use as subjects
  List<StoryCharacter> getReadyCharacters(List<StoryCharacter> characters) {
    return characters.where((c) => c.isReady).toList();
  }

  /// Get characters that still need images generated
  List<StoryCharacter> getPendingCharacters(List<StoryCharacter> characters) {
    return characters.where((c) => !c.hasGeneratedImage && !c.isGenerating).toList();
  }

  /// Get scenes that haven't been generated yet
  List<StoryScene> getPendingScenes(List<StoryScene> scenes) {
    return scenes.where((s) => !s.isGenerated && !s.isGenerating && !s.isQueued).toList();
  }

  /// Check if all required character images are ready for a scene
  bool isSceneReady(StoryScene scene, Map<String, StoryCharacter> characterMap) {
    if (scene.characterIds.isEmpty) return true;
    
    for (final charId in scene.characterIds) {
      final char = characterMap[charId];
      if (char == null || !char.isReady) {
        return false;
      }
    }
    return true;
  }

  /// Generate unique ID for tracking
  String generateId() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return 'story_${random}_${random % 10000}';
  }
}
