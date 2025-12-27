import 'scene_data.dart';

enum TaskScheduleType {
  immediate,
  scheduledTime,
  afterTask,
}

enum TaskStatus {
  pending,
  running,
  paused,
  completed,
  failed,
  scheduled,
}

class BulkTask {
  final String id;
  final String name;
  final List<SceneData> scenes;
  final String profile;
  final String outputFolder;
  final String model;
  final String aspectRatio;
  
  TaskScheduleType scheduleType;
  DateTime? scheduledTime;
  String? afterTaskId;
  
  TaskStatus status;
  DateTime? startedAt;
  DateTime? completedAt;
  String? error;
  
  int get totalScenes => scenes.length;
  int get completedScenes => scenes.where((s) => s.status == 'completed').length;
  int get failedScenes => scenes.where((s) => s.status == 'failed').length;
  double get progress => totalScenes > 0 ? completedScenes / totalScenes : 0.0;

  BulkTask({
    required this.id,
    required this.name,
    required this.scenes,
    required this.profile,
    required this.outputFolder,
    this.model = 'veo_3_1_t2v_fast_ultra',
    this.aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    this.scheduleType = TaskScheduleType.immediate,
    this.scheduledTime,
    this.afterTaskId,
    this.status = TaskStatus.pending,
    this.startedAt,
    this.completedAt,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'scenes': scenes.map((s) => s.toJson()).toList(),
    'profile': profile,
    'outputFolder': outputFolder,
    'model': model,
    'aspectRatio': aspectRatio,
    'scheduleType': scheduleType.toString(),
    'scheduledTime': scheduledTime?.toIso8601String(),
    'afterTaskId': afterTaskId,
    'status': status.toString(),
    'startedAt': startedAt?.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'error': error,
  };

  factory BulkTask.fromJson(Map<String, dynamic> json) => BulkTask(
    id: json['id'] as String,
    name: json['name'] as String,
    scenes: (json['scenes'] as List).map((s) => SceneData.fromJson(s)).toList(),
    profile: json['profile'] as String,
    outputFolder: json['outputFolder'] as String,
    model: json['model'] as String? ?? 'veo_3_1_t2v_fast_ultra',
    aspectRatio: json['aspectRatio'] as String? ?? 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    scheduleType: TaskScheduleType.values.firstWhere(
      (e) => e.toString() == json['scheduleType'],
      orElse: () => TaskScheduleType.immediate,
    ),
    scheduledTime: json['scheduledTime'] != null 
        ? DateTime.parse(json['scheduledTime']) 
        : null,
    afterTaskId: json['afterTaskId'] as String?,
    status: TaskStatus.values.firstWhere(
      (e) => e.toString() == json['status'],
      orElse: () => TaskStatus.pending,
    ),
    startedAt: json['startedAt'] != null 
        ? DateTime.parse(json['startedAt']) 
        : null,
    completedAt: json['completedAt'] != null 
        ? DateTime.parse(json['completedAt']) 
        : null,
    error: json['error'] as String?,
  );
}
