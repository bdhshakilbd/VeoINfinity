import 'dart:convert';
import 'dart:io';
import 'scene_data.dart';

/// Manages project state and auto-save
class ProjectManager {
  final String projectPath;
  Map<String, dynamic> projectData;

  ProjectManager(this.projectPath)
      : projectData = {
          'project_name': projectPath.split(Platform.pathSeparator).last.replaceAll('.json', ''),
          'created': DateTime.now().toIso8601String(),
          'output_folder': projectPath.substring(0, projectPath.lastIndexOf(Platform.pathSeparator)),
          'scenes': [],
          'stats': {'total': 0, 'completed': 0, 'failed': 0, 'pending': 0},
        };

  /// Save project state
  Future<void> save(List<SceneData> scenes) async {
    projectData['scenes'] = scenes.map((s) => s.toJson()).toList();
    projectData['stats'] = {
      'total': scenes.length,
      'completed': scenes.where((s) => s.status == 'completed').length,
      'failed': scenes.where((s) => s.status == 'failed').length,
      'pending': scenes.where((s) => s.status == 'queued').length,
    };

    final file = File(projectPath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(projectData),
    );
  }

  /// Load project state
  static Future<ProjectLoadResult> load(String projectPath) async {
    final file = File(projectPath);
    final content = await file.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

    final scenes = (data['scenes'] as List)
        .map((s) => SceneData.fromJson(s as Map<String, dynamic>))
        .toList();
    final outputFolder = data['output_folder'] as String;

    return ProjectLoadResult(scenes: scenes, outputFolder: outputFolder);
  }
}

class ProjectLoadResult {
  final List<SceneData> scenes;
  final String outputFolder;

  ProjectLoadResult({required this.scenes, required this.outputFolder});
}
