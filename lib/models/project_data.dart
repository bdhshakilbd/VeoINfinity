import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'scene_data.dart';

/// Project data model for managing story projects
class ProjectData {
  final String id;
  String name;
  String? description;
  DateTime createdAt;
  DateTime updatedAt;
  
  // Story/Prompts data
  String? jsonPath;
  List<Map<String, dynamic>> scenes;
  Map<String, dynamic>? fullJsonData; // Complete JSON structure (includes character_reference, etc.)
  List<Map<String, dynamic>> characterData; // Character information with images
  
  // Generated images
  List<String> generatedImagePaths;
  
  // Video generation states (image path -> scene data)
  Map<String, Map<String, dynamic>> videoSceneStates;
  
  // Settings
  String aspectRatio;
  String videoModel;
  String videoAspectRatio;
  
  ProjectData({
    required this.id,
    required this.name,
    this.description,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.jsonPath,
    List<Map<String, dynamic>>? scenes,
    this.fullJsonData,
    List<Map<String, dynamic>>? characterData,
    List<String>? generatedImagePaths,
    Map<String, Map<String, dynamic>>? videoSceneStates,
    this.aspectRatio = '16:9',
    this.videoModel = 'Veo 3.1 - Fast [Lower Priority]',
    this.videoAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        scenes = scenes ?? [],
        characterData = characterData ?? [],
        generatedImagePaths = generatedImagePaths ?? [],
        videoSceneStates = videoSceneStates ?? {};

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'jsonPath': jsonPath,
      'scenes': scenes,
      'fullJsonData': fullJsonData,
      'characterData': characterData,
      'generatedImagePaths': generatedImagePaths,
      'videoSceneStates': videoSceneStates,
      'aspectRatio': aspectRatio,
      'videoModel': videoModel,
      'videoAspectRatio': videoAspectRatio,
    };
  }

  factory ProjectData.fromJson(Map<String, dynamic> json) {
    return ProjectData(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      jsonPath: json['jsonPath'] as String?,
      scenes: (json['scenes'] as List?)?.cast<Map<String, dynamic>>() ?? [],
      fullJsonData: json['fullJsonData'] as Map<String, dynamic>?,
      characterData: (json['characterData'] as List?)?.cast<Map<String, dynamic>>() ?? [],
      generatedImagePaths: (json['generatedImagePaths'] as List?)?.cast<String>() ?? [],
      videoSceneStates: (json['videoSceneStates'] as Map<String, dynamic>?)?.map(
        (key, value) => MapEntry(key, value as Map<String, dynamic>)
      ) ?? {},
      aspectRatio: json['aspectRatio'] as String? ?? '16:9',
      videoModel: json['videoModel'] as String? ?? 'Veo 3.1 - Fast [Lower Priority]',
      videoAspectRatio: json['videoAspectRatio'] as String? ?? 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    );
  }

  ProjectData copyWith({
    String? name,
    String? description,
    String? jsonPath,
    List<Map<String, dynamic>>? scenes,
    Map<String, dynamic>? fullJsonData,
    List<Map<String, dynamic>>? characterData,
    List<String>? generatedImagePaths,
    Map<String, Map<String, dynamic>>? videoSceneStates,
    String? aspectRatio,
    String? videoModel,
    String? videoAspectRatio,
  }) {
    return ProjectData(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      jsonPath: jsonPath ?? this.jsonPath,
      scenes: scenes ?? this.scenes,
      fullJsonData: fullJsonData ?? this.fullJsonData,
      characterData: characterData ?? this.characterData,
      generatedImagePaths: generatedImagePaths ?? this.generatedImagePaths,
      videoSceneStates: videoSceneStates ?? this.videoSceneStates,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      videoModel: videoModel ?? this.videoModel,
      videoAspectRatio: videoAspectRatio ?? this.videoAspectRatio,
    );
  }
}

/// Manages all projects
class ProjectManager {
  final String projectsDirectory;
  List<ProjectData> projects = [];
  ProjectData? currentProject;

  ProjectManager(this.projectsDirectory);

  /// Initialize and load all projects
  Future<void> initialize() async {
    final dir = Directory(projectsDirectory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await loadAllProjects();
  }

  /// Load all projects from disk
  Future<void> loadAllProjects() async {
    projects.clear();
    final dir = Directory(projectsDirectory);
    
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            projects.add(ProjectData.fromJson(json));
          } catch (e) {
            print('Failed to load project ${entity.path}: $e');
          }
        }
      }
    }
    
    // Sort by updated date (newest first)
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// Create a new project
  Future<ProjectData> createProject(String name, {String? description}) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final project = ProjectData(
      id: id,
      name: name,
      description: description,
    );
    
    projects.insert(0, project);
    await saveProject(project);
    currentProject = project;
    
    return project;
  }

  /// Save a project to disk
  Future<void> saveProject(ProjectData project) async {
    project.updatedAt = DateTime.now();
    final filePath = path.join(projectsDirectory, '${project.id}.json');
    final file = File(filePath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
    );
  }

  /// Delete a project
  Future<void> deleteProject(String projectId) async {
    final filePath = path.join(projectsDirectory, '$projectId.json');
    final file = File(filePath);
    
    if (await file.exists()) {
      await file.delete();
    }
    
    projects.removeWhere((p) => p.id == projectId);
    
    if (currentProject?.id == projectId) {
      currentProject = projects.isNotEmpty ? projects.first : null;
    }
  }

  /// Load a specific project
  Future<void> loadProject(String projectId) async {
    final project = projects.firstWhere((p) => p.id == projectId);
    currentProject = project;
  }

  /// Auto-save current project
  Future<void> autoSave() async {
    if (currentProject != null) {
      await saveProject(currentProject!);
    }
  }
  
  // ====================== LEGACY API SUPPORT ======================
  // These methods provide backward compatibility with the old ProjectManager API
  
  /// Legacy: Access to project data
  Map<String, dynamic> get projectData {
    if (currentProject == null) {
      return {
        'project_name': 'Untitled',
        'created': DateTime.now().toIso8601String(),
        'output_folder': '',
        'scenes': [],
        'stats': {'total': 0, 'completed': 0, 'failed': 0, 'pending': 0},
      };
    }
    
    return {
      'project_name': currentProject!.name,
      'created': currentProject!.createdAt.toIso8601String(),
      'output_folder': projectsDirectory,
      'scenes': currentProject!.videoSceneStates.values.toList(),
      'stats': {
        'total': currentProject!.videoSceneStates.length,
        'completed': currentProject!.videoSceneStates.values.where((s) => s['status'] == 'completed').length,
        'failed': currentProject!.videoSceneStates.values.where((s) => s['status'] == 'failed').length,
        'pending': currentProject!.videoSceneStates.values.where((s) => s['status'] == 'queued').length,
      },
    };
  }
  
  /// Legacy: Save project state with scenes
  Future<void> save(List<SceneData> scenes) async {
    if (currentProject == null) return;
    
    // Convert scenes to video scene states
    final videoStates = <String, Map<String, dynamic>>{};
    for (final scene in scenes) {
      if (scene.firstFramePath != null) {
        videoStates[scene.firstFramePath!] = scene.toJson();
      }
    }
    
    currentProject = currentProject!.copyWith(
      videoSceneStates: videoStates,
    );
    
    await saveProject(currentProject!);
  }
  
  /// Legacy: Load project from file path
  static Future<ProjectLoadResult> load(String projectPath) async {
    final file = File(projectPath);
    
    if (!await file.exists()) {
      throw Exception('Project file not found: $projectPath');
    }
    
    final content = await file.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;
    
    // Check if it's a new-style project or old-style
    if (data.containsKey('id') && data.containsKey('videoSceneStates')) {
      // New-style project
      final project = ProjectData.fromJson(data);
      final scenes = project.videoSceneStates.entries
          .map((e) => SceneData.fromJson(e.value))
          .toList();
      final outputFolder = path.dirname(projectPath);
      
      return ProjectLoadResult(scenes: scenes, outputFolder: outputFolder);
    } else {
      // Old-style project (legacy format)
      final scenes = (data['scenes'] as List?)
          ?.map((s) => SceneData.fromJson(s as Map<String, dynamic>))
          .toList() ?? [];
      final outputFolder = data['output_folder'] as String? ?? path.dirname(projectPath);
      
      return ProjectLoadResult(scenes: scenes, outputFolder: outputFolder);
    }
  }
}

/// Legacy support for old ProjectManager
class ProjectLoadResult {
  final List<SceneData> scenes;
  final String outputFolder;

  ProjectLoadResult({required this.scenes, required this.outputFolder});
}
