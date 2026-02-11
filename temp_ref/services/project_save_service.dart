import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../models/story_models.dart';

/// Represents a saved project with all state
class SavedProject {
  final String name;
  final DateTime savedAt;
  final String workflowId;
  final String selectedAspectRatio;
  final String selectedImageModel;
  
  // Generated history
  final List<SavedHistoryItem> history;
  
  // Subjects
  final List<SavedMediaItem> subjects;
  
  // Scene/Style (legacy lists)
  final List<SavedMediaItem> scenes;
  final List<SavedMediaItem> styles;
  
  // Story project (if imported)
  final SavedStoryProject? storyProject;
  
  // Imported prompts
  final List<String>? importedPrompts;
  
  SavedProject({
    required this.name,
    required this.savedAt,
    required this.workflowId,
    required this.selectedAspectRatio,
    required this.selectedImageModel,
    required this.history,
    required this.subjects,
    required this.scenes,
    required this.styles,
    this.storyProject,
    this.importedPrompts,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'savedAt': savedAt.toIso8601String(),
    'workflowId': workflowId,
    'selectedAspectRatio': selectedAspectRatio,
    'selectedImageModel': selectedImageModel,
    'history': history.map((h) => h.toJson()).toList(),
    'subjects': subjects.map((s) => s.toJson()).toList(),
    'scenes': scenes.map((s) => s.toJson()).toList(),
    'styles': styles.map((s) => s.toJson()).toList(),
    'storyProject': storyProject?.toJson(),
    'importedPrompts': importedPrompts,
  };

  factory SavedProject.fromJson(Map<String, dynamic> json) {
    return SavedProject(
      name: json['name'] ?? 'Untitled Project',
      savedAt: DateTime.tryParse(json['savedAt'] ?? '') ?? DateTime.now(),
      workflowId: json['workflowId'] ?? '',
      selectedAspectRatio: json['selectedAspectRatio'] ?? 'IMAGE_ASPECT_RATIO_LANDSCAPE',
      selectedImageModel: json['selectedImageModel'] ?? 'IMAGEN_3_5',
      history: (json['history'] as List<dynamic>?)
          ?.map((h) => SavedHistoryItem.fromJson(h))
          .toList() ?? [],
      subjects: (json['subjects'] as List<dynamic>?)
          ?.map((s) => SavedMediaItem.fromJson(s))
          .toList() ?? [],
      scenes: (json['scenes'] as List<dynamic>?)
          ?.map((s) => SavedMediaItem.fromJson(s))
          .toList() ?? [],
      styles: (json['styles'] as List<dynamic>?)
          ?.map((s) => SavedMediaItem.fromJson(s))
          .toList() ?? [],
      storyProject: json['storyProject'] != null 
          ? SavedStoryProject.fromJson(json['storyProject'])
          : null,
      importedPrompts: (json['importedPrompts'] as List<dynamic>?)
          ?.map((p) => p.toString())
          .toList(),
    );
  }
}

/// Saved history item
class SavedHistoryItem {
  final String id;
  final String prompt;
  final DateTime timestamp;
  final String? imagePath; // Relative path to saved image
  final String? error;

  SavedHistoryItem({
    required this.id,
    required this.prompt,
    required this.timestamp,
    this.imagePath,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'prompt': prompt,
    'timestamp': timestamp.toIso8601String(),
    'imagePath': imagePath,
    'error': error,
  };

  factory SavedHistoryItem.fromJson(Map<String, dynamic> json) {
    return SavedHistoryItem(
      id: json['id'] ?? '',
      prompt: json['prompt'] ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
      imagePath: json['imagePath'],
      error: json['error'],
    );
  }
}

/// Saved media item (subject/scene/style)
class SavedMediaItem {
  final String filePath; // Relative path
  final String? mediaId;
  final String? caption;
  final bool isSelected;

  SavedMediaItem({
    required this.filePath,
    this.mediaId,
    this.caption,
    this.isSelected = true,
  });

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'mediaId': mediaId,
    'caption': caption,
    'isSelected': isSelected,
  };

  factory SavedMediaItem.fromJson(Map<String, dynamic> json) {
    return SavedMediaItem(
      filePath: json['filePath'] ?? '',
      mediaId: json['mediaId'],
      caption: json['caption'],
      isSelected: json['isSelected'] ?? true,
    );
  }
}

/// Saved story project
class SavedStoryProject {
  final String title;
  final String style;
  final int totalScenes;
  final List<SavedCharacter> characters;
  final List<SavedScene> scenes;

  SavedStoryProject({
    required this.title,
    required this.style,
    required this.totalScenes,
    required this.characters,
    required this.scenes,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'style': style,
    'totalScenes': totalScenes,
    'characters': characters.map((c) => c.toJson()).toList(),
    'scenes': scenes.map((s) => s.toJson()).toList(),
  };

  factory SavedStoryProject.fromJson(Map<String, dynamic> json) {
    return SavedStoryProject(
      title: json['title'] ?? '',
      style: json['style'] ?? '',
      totalScenes: json['totalScenes'] ?? 0,
      characters: (json['characters'] as List<dynamic>?)
          ?.map((c) => SavedCharacter.fromJson(c))
          .toList() ?? [],
      scenes: (json['scenes'] as List<dynamic>?)
          ?.map((s) => SavedScene.fromJson(s))
          .toList() ?? [],
    );
  }
}

/// Saved character
class SavedCharacter {
  final String id;
  final String name;
  final String description;
  final List<String> outfits;
  final String? imageMediaId;
  final String? imagePath; // Relative path to saved image
  final String? customPrompt;
  final String? usedPrompt; // The prompt used to generate the image (for recipe caption)

  SavedCharacter({
    required this.id,
    required this.name,
    required this.description,
    required this.outfits,
    this.imageMediaId,
    this.imagePath,
    this.customPrompt,
    this.usedPrompt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'outfits': outfits,
    'imageMediaId': imageMediaId,
    'imagePath': imagePath,
    'customPrompt': customPrompt,
    'usedPrompt': usedPrompt,
  };

  factory SavedCharacter.fromJson(Map<String, dynamic> json) {
    return SavedCharacter(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      outfits: (json['outfits'] as List<dynamic>?)
          ?.map((o) => o.toString())
          .toList() ?? [],
      imageMediaId: json['imageMediaId'],
      imagePath: json['imagePath'],
      customPrompt: json['customPrompt'],
      usedPrompt: json['usedPrompt'],
    );
  }
}

/// Saved scene
class SavedScene {
  final int sceneNumber;
  final String prompt;
  final List<String> characterIds;
  final String negativePrompt;
  final bool isGenerated;
  final String? imagePath; // Relative path

  SavedScene({
    required this.sceneNumber,
    required this.prompt,
    required this.characterIds,
    required this.negativePrompt,
    this.isGenerated = false,
    this.imagePath,
  });

  Map<String, dynamic> toJson() => {
    'sceneNumber': sceneNumber,
    'prompt': prompt,
    'characterIds': characterIds,
    'negativePrompt': negativePrompt,
    'isGenerated': isGenerated,
    'imagePath': imagePath,
  };

  factory SavedScene.fromJson(Map<String, dynamic> json) {
    return SavedScene(
      sceneNumber: json['sceneNumber'] ?? 0,
      prompt: json['prompt'] ?? '',
      characterIds: (json['characterIds'] as List<dynamic>?)
          ?.map((c) => c.toString())
          .toList() ?? [],
      negativePrompt: json['negativePrompt'] ?? '',
      isGenerated: json['isGenerated'] ?? false,
      imagePath: json['imagePath'],
    );
  }
}

/// Service for saving and loading projects
class ProjectSaveService {
  static const String _projectsFolderName = 'NanobanaSavedProjects';

  /// Get the projects folder
  Future<Directory> _getProjectsFolder() async {
    final directory = await getApplicationDocumentsDirectory();
    final projectsDir = Directory('${directory.path}/$_projectsFolderName');
    
    if (!await projectsDir.exists()) {
      await projectsDir.create(recursive: true);
    }
    
    return projectsDir;
  }

  /// Get project folder for a specific project
  Future<Directory> _getProjectFolder(String projectName) async {
    final projectsDir = await _getProjectsFolder();
    // Sanitize project name for folder
    final safeName = projectName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final projectDir = Directory('${projectsDir.path}/$safeName');
    
    if (!await projectDir.exists()) {
      await projectDir.create(recursive: true);
    }
    
    return projectDir;
  }

  /// Save a project
  Future<String> saveProject(SavedProject project, {
    required Map<String, Uint8List> imageData, // id -> bytes
  }) async {
    final projectDir = await _getProjectFolder(project.name);
    final imagesDir = Directory('${projectDir.path}/images');
    
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    
    // Save all images
    for (final entry in imageData.entries) {
      final imagePath = '${imagesDir.path}/${entry.key}.jpg';
      await File(imagePath).writeAsBytes(entry.value);
    }
    
    // Save project JSON
    final projectFile = File('${projectDir.path}/project.json');
    await projectFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
    );
    
    print('✅ Project saved to: ${projectDir.path}');
    return projectDir.path;
  }

  /// Load a project
  Future<SavedProject?> loadProject(String projectPath) async {
    try {
      final projectFile = File('$projectPath/project.json');
      
      if (!await projectFile.exists()) {
        print('❌ Project file not found: $projectPath');
        return null;
      }
      
      final content = await projectFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return SavedProject.fromJson(json);
    } catch (e) {
      print('❌ Error loading project: $e');
      return null;
    }
  }

  /// Load image bytes from project
  Future<Uint8List?> loadProjectImage(String projectPath, String imageId) async {
    try {
      final imagePath = '$projectPath/images/$imageId.jpg';
      final file = File(imagePath);
      
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e) {
      print('❌ Error loading image $imageId: $e');
    }
    return null;
  }

  /// List all saved projects
  Future<List<Map<String, dynamic>>> listProjects() async {
    final projectsDir = await _getProjectsFolder();
    final projects = <Map<String, dynamic>>[];
    
    if (!await projectsDir.exists()) {
      return projects;
    }
    
    await for (final entity in projectsDir.list()) {
      if (entity is Directory) {
        final projectFile = File('${entity.path}/project.json');
        if (await projectFile.exists()) {
          try {
            final content = await projectFile.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            projects.add({
              'path': entity.path,
              'name': json['name'] ?? 'Untitled',
              'savedAt': json['savedAt'],
              'historyCount': (json['history'] as List?)?.length ?? 0,
            });
          } catch (e) {
            print('Error reading project at ${entity.path}: $e');
          }
        }
      }
    }
    
    // Sort by saved date (newest first)
    projects.sort((a, b) => (b['savedAt'] ?? '').compareTo(a['savedAt'] ?? ''));
    
    return projects;
  }

  /// Delete a project
  Future<bool> deleteProject(String projectPath) async {
    try {
      final dir = Directory(projectPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        print('✅ Project deleted: $projectPath');
        return true;
      }
    } catch (e) {
      print('❌ Error deleting project: $e');
    }
    return false;
  }

  /// Pick a location to save project (for export)
  Future<String?> pickSaveLocation(String defaultName) async {
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Project',
      fileName: '$defaultName.nanobana',
      type: FileType.custom,
      allowedExtensions: ['nanobana'],
    );
    return result;
  }

  /// Pick a project file to load (for import)
  Future<String?> pickLoadLocation() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Load Project',
      type: FileType.custom,
      allowedExtensions: ['nanobana', 'json'],
    );
    return result?.files.single.path;
  }
}
