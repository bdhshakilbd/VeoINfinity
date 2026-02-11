import 'dart:io';
import 'dart:typed_data';

/// Represents a character from the story JSON
class StoryCharacter {
  final String id;
  final String name;
  final String description;
  final List<String> outfits;

  // Generated data - mutable
  String? imageMediaId;
  Uint8List? imageBytes;
  File? imagePath;
  bool isGenerating = false;
  bool isUploading = false;
  String? error;
  String? customPrompt; // User-editable custom prompt
  String? usedPrompt; // The actual prompt used when generating the image (for recipe caption)

  StoryCharacter({
    required this.id,
    required this.name,
    required this.description,
    required this.outfits,
  });

  factory StoryCharacter.fromJson(Map<String, dynamic> json) {
    return StoryCharacter(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      outfits: (json['outfit'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'outfit': outfits,
    };
  }

  /// Build a prompt to generate a reference image for this character
  String get generationPrompt {
    // Use custom prompt if set
    if (customPrompt != null && customPrompt!.isNotEmpty) {
      return customPrompt!;
    }
    // Default: just use the description value
    return description;
  }

  bool get hasGeneratedImage => imageBytes != null || imagePath != null;
  bool get isReady => imageMediaId != null;
}

/// Represents a scene from the story JSON
class StoryScene {
  final int sceneNumber;
  final String prompt;
  final List<String> characterIds;
  final Map<String, List<String>> clothingAppearance;
  final String negativePrompt;

  // Generation state - mutable
  String? id; // Unique ID for tracking
  bool isGenerated = false;
  bool isGenerating = false;
  bool isQueued = false;
  Uint8List? imageBytes;
  File? imagePath;
  String? error;
  int retryCount = 0; // Track retry attempts (max 5)

  StoryScene({
    required this.sceneNumber,
    required this.prompt,
    required this.characterIds,
    required this.clothingAppearance,
    required this.negativePrompt,
  });

  factory StoryScene.fromJson(Map<String, dynamic> json) {
    // Parse clothing_appearance map
    final clothingMap = <String, List<String>>{};
    if (json['clothing_appearance'] != null) {
      (json['clothing_appearance'] as Map<String, dynamic>).forEach((key, value) {
        clothingMap[key] = (value as List<dynamic>).map((e) => e.toString()).toList();
      });
    }

    return StoryScene(
      sceneNumber: json['scene_number'] ?? 0,
      prompt: json['prompt'] ?? '',
      characterIds: (json['characters_in_scene'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      clothingAppearance: clothingMap,
      negativePrompt: json['negative_prompt'] ?? '',
    );
  }

  /// Build enhanced prompt with character details
  String buildEnhancedPrompt(Map<String, StoryCharacter> characters) {
    if (characterIds.isEmpty) {
      return prompt;
    }

    // Inject character descriptions into prompt
    final charDescriptions = <String>[];
    for (final charId in characterIds) {
      final char = characters[charId];
      if (char != null) {
        final clothing = clothingAppearance[charId];
        final outfitStr = (clothing != null && clothing.isNotEmpty && 
            !clothing.first.contains('use previous'))
            ? clothing.join(', ')
            : char.outfits.join(', ');
        charDescriptions.add('$charId (${char.description}, wearing $outfitStr)');
      }
    }

    if (charDescriptions.isEmpty) {
      return prompt;
    }

    return '$prompt [Characters: ${charDescriptions.join('; ')}]';
  }
}

/// Represents the entire story project
class StoryProject {
  final String title;
  final String style;
  final int totalScenes;
  final List<StoryCharacter> characters;
  final List<StoryScene> scenes;

  // Progress tracking
  int currentSceneIndex = 0;
  bool isPaused = false;

  StoryProject({
    required this.title,
    required this.style,
    required this.totalScenes,
    required this.characters,
    required this.scenes,
  });

  factory StoryProject.fromJson(Map<String, dynamic> json) {
    // Parse characters
    final charList = (json['character_reference'] as List<dynamic>?)
            ?.map((e) => StoryCharacter.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    // Parse scenes from output_structure
    final outputStructure = json['output_structure'] as Map<String, dynamic>?;
    final sceneList = <StoryScene>[];
    
    if (outputStructure != null && outputStructure['scenes'] != null) {
      for (var scene in (outputStructure['scenes'] as List<dynamic>)) {
        sceneList.add(StoryScene.fromJson(scene as Map<String, dynamic>));
      }
    }

    return StoryProject(
      title: outputStructure?['story_title'] ?? 'Untitled Story',
      style: outputStructure?['style'] ?? '',
      totalScenes: outputStructure?['total_scenes'] ?? sceneList.length,
      characters: charList,
      scenes: sceneList,
    );
  }

  /// Get character map for quick lookup
  Map<String, StoryCharacter> get characterMap {
    return {for (var c in characters) c.id: c};
  }

  /// Count of characters with ready images (uploaded as subject)
  int get readyCharacterCount => characters.where((c) => c.isReady).length;

  /// Count of generated scenes
  int get generatedSceneCount => scenes.where((s) => s.isGenerated).length;

  /// Check if all characters have images ready
  bool get allCharactersReady => characters.every((c) => c.isReady);

  /// Get next scene to generate (not generated, not generating, not queued)
  StoryScene? get nextPendingScene {
    for (var scene in scenes) {
      if (!scene.isGenerated && !scene.isGenerating && !scene.isQueued && scene.error == null) {
        return scene;
      }
    }
    return null;
  }
}
