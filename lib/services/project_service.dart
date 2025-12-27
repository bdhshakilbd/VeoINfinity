import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Project configuration and metadata
class Project {
  final String name;
  final String projectPath;
  final String exportPath;
  final DateTime createdAt;
  DateTime? lastModified;
  
  Project({
    required this.name,
    required this.projectPath,
    required this.exportPath,
    required this.createdAt,
    this.lastModified,
  });
  
  Map<String, dynamic> toJson() => {
    'name': name,
    'projectPath': projectPath,
    'exportPath': exportPath,
    'createdAt': createdAt.toIso8601String(),
    'lastModified': lastModified?.toIso8601String(),
  };
  
  factory Project.fromJson(Map<String, dynamic> json) => Project(
    name: json['name'] as String,
    projectPath: json['projectPath'] as String,
    exportPath: json['exportPath'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastModified: json['lastModified'] != null 
        ? DateTime.parse(json['lastModified'] as String) 
        : null,
  );
}

/// Generation record for tracking and resume
class GenerationRecord {
  final int sceneId;
  final String prompt;
  final String? operationName;
  final String? sceneUuid;
  final String? mediaId;
  final String model;
  final String aspectRatio;
  String status;
  String? error;
  String? videoPath;
  String? downloadUrl;
  int? fileSize;
  DateTime? generatedAt;
  DateTime createdAt;
  
  GenerationRecord({
    required this.sceneId,
    required this.prompt,
    this.operationName,
    this.sceneUuid,
    this.mediaId,
    required this.model,
    required this.aspectRatio,
    required this.status,
    this.error,
    this.videoPath,
    this.downloadUrl,
    this.fileSize,
    this.generatedAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
  
  Map<String, dynamic> toJson() => {
    'sceneId': sceneId,
    'prompt': prompt,
    'operationName': operationName,
    'sceneUuid': sceneUuid,
    'mediaId': mediaId,
    'model': model,
    'aspectRatio': aspectRatio,
    'status': status,
    'error': error,
    'videoPath': videoPath,
    'downloadUrl': downloadUrl,
    'fileSize': fileSize,
    'generatedAt': generatedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
  };
  
  factory GenerationRecord.fromJson(Map<String, dynamic> json) => GenerationRecord(
    sceneId: json['sceneId'] as int,
    prompt: json['prompt'] as String,
    operationName: json['operationName'] as String?,
    sceneUuid: json['sceneUuid'] as String?,
    mediaId: json['mediaId'] as String?,
    model: json['model'] as String? ?? 'unknown',
    aspectRatio: json['aspectRatio'] as String? ?? 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    status: json['status'] as String,
    error: json['error'] as String?,
    videoPath: json['videoPath'] as String?,
    downloadUrl: json['downloadUrl'] as String?,
    fileSize: json['fileSize'] as int?,
    generatedAt: json['generatedAt'] != null 
        ? DateTime.parse(json['generatedAt'] as String) 
        : null,
    createdAt: json['createdAt'] != null 
        ? DateTime.parse(json['createdAt'] as String) 
        : null,
  );
  
  /// Check if this generation can be resumed (has operation data but not completed)
  bool get canResume => 
      operationName != null && 
      sceneUuid != null && 
      status != 'completed' && 
      status != 'failed';
}

/// Service for managing projects and generation records
class ProjectService {
  static String? _cachedProjectsBasePath;
  static String? _cachedDefaultExportPath;
  
  static Future<String> get projectsBasePath async {
    if (_cachedProjectsBasePath != null) return _cachedProjectsBasePath!;
    
    if (Platform.isAndroid) {
      // Use public external storage: /storage/emulated/0/veo3/projects
      _cachedProjectsBasePath = '/storage/emulated/0/veo3/projects';
    } else if (Platform.isIOS) {
      // iOS: Use documents directory
      final dir = await getApplicationDocumentsDirectory();
      _cachedProjectsBasePath = path.join(dir.path, 'veo3_projects');
    } else {
      _cachedProjectsBasePath = r'C:\ProgramData\veo3_generator\projects';
    }
    return _cachedProjectsBasePath!;
  }
  
  static Future<String> get defaultExportPath async {
    if (_cachedDefaultExportPath != null) return _cachedDefaultExportPath!;
    
    if (Platform.isAndroid) {
      // Use public external storage: /storage/emulated/0/veo3/videos
      _cachedDefaultExportPath = '/storage/emulated/0/veo3/videos';
    } else if (Platform.isIOS) {
      // iOS: Use documents directory
      final dir = await getApplicationDocumentsDirectory();
      _cachedDefaultExportPath = path.join(dir.path, 'veo3_videos');
    } else {
      _cachedDefaultExportPath = r'C:\Users\Public\Documents\veo3_generation';
    }
    return _cachedDefaultExportPath!;
  }
  
  Project? _currentProject;
  List<GenerationRecord> _generations = [];
  
  Project? get currentProject => _currentProject;
  List<GenerationRecord> get generations => _generations;
  
  /// Initialize the projects directory
  static Future<void> ensureDirectories() async {
    final projectsPath = await projectsBasePath;
    final exportPath = await defaultExportPath;
    await Directory(projectsPath).create(recursive: true);
    await Directory(exportPath).create(recursive: true);
  }
  
  /// List all available projects
  static Future<List<Project>> listProjects() async {
    final projectsPath = await projectsBasePath;
    final projectsDir = Directory(projectsPath);
    if (!await projectsDir.exists()) {
      await projectsDir.create(recursive: true);
      return [];
    }
    
    final projects = <Project>[];
    await for (final entity in projectsDir.list()) {
      if (entity is Directory) {
        final configFile = File(path.join(entity.path, 'project.json'));
        if (await configFile.exists()) {
          try {
            final json = jsonDecode(await configFile.readAsString());
            projects.add(Project.fromJson(json as Map<String, dynamic>));
          } catch (e) {
            print('Error loading project: ${entity.path}: $e');
          }
        }
      }
    }
    
    // Sort by last modified
    projects.sort((a, b) => 
        (b.lastModified ?? b.createdAt).compareTo(a.lastModified ?? a.createdAt));
    
    return projects;
  }
  
  /// Create a new project
  Future<Project> createProject(String name, {String? customExportPath}) async {
    final safeName = _sanitizeFileName(name);
    final projectsPath = await projectsBasePath;
    final defaultExport = await defaultExportPath;
    final projectPath = path.join(projectsPath, safeName);
    final exportPath = customExportPath ?? path.join(defaultExport, safeName);
    
    // Create directories
    await Directory(projectPath).create(recursive: true);
    await Directory(exportPath).create(recursive: true);
    
    final project = Project(
      name: name,
      projectPath: projectPath,
      exportPath: exportPath,
      createdAt: DateTime.now(),
    );
    
    // Save project config
    final configFile = File(path.join(projectPath, 'project.json'));
    await configFile.writeAsString(jsonEncode(project.toJson()));
    
    return project;
  }
  
  /// Load a project
  Future<void> loadProject(Project project) async {
    _currentProject = project;
    await _loadGenerations();
    
    // Update last modified
    _currentProject = Project(
      name: project.name,
      projectPath: project.projectPath,
      exportPath: project.exportPath,
      createdAt: project.createdAt,
      lastModified: DateTime.now(),
    );
    await _saveProjectConfig();
  }
  
  /// Save prompts/scenes to project
  Future<void> savePrompts(List<Map<String, dynamic>> prompts) async {
    if (_currentProject == null) return;
    
    // Ensure project directory exists
    final projectDir = Directory(_currentProject!.projectPath);
    if (!await projectDir.exists()) {
      await projectDir.create(recursive: true);
    }
    
    final promptsFile = File(path.join(_currentProject!.projectPath, 'prompts.json'));
    await promptsFile.writeAsString(jsonEncode(prompts));
    await _updateLastModified();
  }
  
  /// Load prompts from project
  Future<List<Map<String, dynamic>>> loadPrompts() async {
    if (_currentProject == null) return [];
    
    final promptsFile = File(path.join(_currentProject!.projectPath, 'prompts.json'));
    if (!await promptsFile.exists()) return [];
    
    try {
      final json = jsonDecode(await promptsFile.readAsString());
      return (json as List).cast<Map<String, dynamic>>();
    } catch (e) {
      print('Error loading prompts: $e');
      return [];
    }
  }
  
  /// Save a generation record immediately when generation starts
  Future<void> saveGeneration(GenerationRecord record) async {
    if (_currentProject == null) return;
    
    // Update or add record
    final existingIndex = _generations.indexWhere((g) => g.sceneId == record.sceneId);
    if (existingIndex >= 0) {
      _generations[existingIndex] = record;
    } else {
      _generations.add(record);
    }
    
    await _saveGenerations();
  }
  
  /// Update generation status
  Future<void> updateGenerationStatus(int sceneId, {
    String? status,
    String? operationName,
    String? sceneUuid,
    String? mediaId,
    String? error,
    String? videoPath,
    String? downloadUrl,
    int? fileSize,
  }) async {
    final record = _generations.firstWhere(
      (g) => g.sceneId == sceneId,
      orElse: () => throw Exception('Generation not found'),
    );
    
    if (status != null) record.status = status;
    if (operationName != null) record.operationName;
    if (error != null) record.error = error;
    if (videoPath != null) record.videoPath = videoPath;
    if (downloadUrl != null) record.downloadUrl = downloadUrl;
    if (fileSize != null) record.fileSize = fileSize;
    if (status == 'completed') record.generatedAt = DateTime.now();
    
    await _saveGenerations();
  }
  
  /// Get pending generations (can be resumed)
  List<GenerationRecord> getPendingGenerations() {
    return _generations.where((g) => g.canResume).toList();
  }
  
  /// Get video output path for a scene
  Future<String> getVideoOutputPath(String? title, int? sceneId, {bool isQuickGenerate = false}) async {
    if (_currentProject == null) {
      final defaultExport = await defaultExportPath;
      return path.join(defaultExport, 'unnamed', _generateVideoFileName(title, sceneId, isQuickGenerate));
    }
    
    return path.join(
      _currentProject!.exportPath, 
      _generateVideoFileName(title, sceneId, isQuickGenerate),
    );
  }
  
  String _generateVideoFileName(String? title, int? sceneId, bool isQuickGenerate) {
    if (isQuickGenerate && title != null && title.isNotEmpty) {
      // Use prompt-based name for quick generate
      final safeName = _sanitizeFileName(title);
      
      // Ensure the name is not empty after sanitization
      if (safeName.isEmpty) {
        return 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
      }
      
      // Truncate to reasonable length (40 chars max for the name part)
      final truncated = safeName.length > 40 ? safeName.substring(0, 40) : safeName;
      // Add short timestamp suffix to prevent overwrites
      final timestamp = DateTime.now().millisecondsSinceEpoch % 100000;
      return '${truncated}_$timestamp.mp4';
    } else if (sceneId != null) {
      // Use scene ID for bulk generation
      return 'scene_${sceneId.toString().padLeft(3, '0')}.mp4';
    } else {
      // Fallback with timestamp
      return 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    }
  }
  
  String _sanitizeFileName(String name) {
    // Remove emojis and special unicode characters
    // Keep only alphanumeric, spaces, underscores, hyphens
    final cleaned = name
        // Remove emojis and most special unicode (keep basic latin, some extended)
        .replaceAll(RegExp(r'[^\x00-\x7F\u00C0-\u00FF\u0100-\u017F]'), '')
        // Remove Windows-invalid filename characters
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        // Replace multiple spaces/special chars with single underscore
        .replaceAll(RegExp(r'[\s\-\.]+'), '_')
        // Remove multiple underscores
        .replaceAll(RegExp(r'_+'), '_')
        // Remove leading/trailing underscores
        .replaceAll(RegExp(r'^_+|_+$'), '')
        .trim();
    
    // If nothing left after cleaning, generate a simple name
    if (cleaned.isEmpty) {
      return 'generated';
    }
    
    return cleaned;
  }
  
  Future<void> _loadGenerations() async {
    if (_currentProject == null) return;
    
    final generationsFile = File(path.join(_currentProject!.projectPath, 'generations.json'));
    if (!await generationsFile.exists()) {
      _generations = [];
      return;
    }
    
    try {
      final json = jsonDecode(await generationsFile.readAsString());
      _generations = (json as List)
          .map((g) => GenerationRecord.fromJson(g as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error loading generations: $e');
      _generations = [];
    }
  }
  
  Future<void> _saveGenerations() async {
    if (_currentProject == null) return;
    
    // Ensure project directory exists
    final projectDir = Directory(_currentProject!.projectPath);
    if (!await projectDir.exists()) {
      await projectDir.create(recursive: true);
    }
    
    final generationsFile = File(path.join(_currentProject!.projectPath, 'generations.json'));
    await generationsFile.writeAsString(
      jsonEncode(_generations.map((g) => g.toJson()).toList()),
    );
    await _updateLastModified();
  }
  
  Future<void> _saveProjectConfig() async {
    if (_currentProject == null) return;
    
    // Ensure project directory exists
    final projectDir = Directory(_currentProject!.projectPath);
    if (!await projectDir.exists()) {
      await projectDir.create(recursive: true);
    }
    
    final configFile = File(path.join(_currentProject!.projectPath, 'project.json'));
    await configFile.writeAsString(jsonEncode(_currentProject!.toJson()));
  }
  
  Future<void> _updateLastModified() async {
    if (_currentProject == null) return;
    
    _currentProject = Project(
      name: _currentProject!.name,
      projectPath: _currentProject!.projectPath,
      exportPath: _currentProject!.exportPath,
      createdAt: _currentProject!.createdAt,
      lastModified: DateTime.now(),
    );
    await _saveProjectConfig();
  }
}
