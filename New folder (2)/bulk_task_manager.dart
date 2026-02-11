import '../models/bulk_task.dart';
import '../services/bulk_task_executor.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';

/// Singleton service to manage bulk tasks across the app
class BulkTaskManager {
  static final BulkTaskManager _instance = BulkTaskManager._internal();
  factory BulkTaskManager() => _instance;
  BulkTaskManager._internal() {
    _loadTasks();
  }

  final List<BulkTask> tasks = [];
  BulkTaskExecutor? _executor;

  // Multi-browser configuration
  ProfileManagerService? _profileManager;
  MultiProfileLoginService? _loginService;
  String _email = '';
  String _password = '';

  /// Configure multi-browser support
  void setProfileManager(ProfileManagerService? manager) {
    _profileManager = manager;
    _executor?.setProfileManager(manager);
  }

  /// Configure login service for re-login on 403
  void setLoginService(MultiProfileLoginService? service) {
    _loginService = service;
    _executor?.setLoginService(service);
  }

  /// Configure credentials for re-login
  void setCredentials(String email, String password) {
    _email = email;
    _password = password;
    _executor?.setCredentials(email, password);
  }

  BulkTaskExecutor getExecutor(Function(BulkTask)? onTaskStatusChanged) {
    _executor ??= BulkTaskExecutor(onTaskStatusChanged: onTaskStatusChanged);
    
    // Apply multi-browser configuration
    _executor!.setProfileManager(_profileManager);
    _executor!.setLoginService(_loginService);
    _executor!.setCredentials(_email, _password);
    
    return _executor!;
  }

  void addTask(BulkTask task) {
    tasks.add(task);
    _saveTasks();
    if (_executor != null) {
      _executor!.startScheduler(tasks);
      // If task is set to immediate, start it right away
      if (task.scheduleType == TaskScheduleType.immediate) {
        _executor!.startTask(task);
      }
    }
  }

  void removeTask(BulkTask task) {
    tasks.remove(task);
    _saveTasks();
  }

  void updateTask(BulkTask task) {
    _saveTasks();
    // If a task just completed, check for dependent scheduled tasks
    if ((task.status == TaskStatus.completed || task.status == TaskStatus.failed) && _executor != null) {
      _executor!.checkScheduledTasksNow(tasks);
    }
  }

  Future<String> _getTasksFilePath() async {
    final appDir = await getApplicationDocumentsDirectory();
    final tasksDir = Directory('${appDir.path}/VEO3_Infinity/bulk_tasks');
    await tasksDir.create(recursive: true);
    return '${tasksDir.path}/tasks.json';
  }

  Future<void> _saveTasks() async {
    try {
      final filePath = await _getTasksFilePath();
      final file = File(filePath);
      final tasksJson = tasks.map((t) => t.toJson()).toList();
      await file.writeAsString(jsonEncode(tasksJson));
      print('[TASKS] Saved ${tasks.length} tasks to $filePath');
    } catch (e) {
      print('[TASKS] Error saving tasks: $e');
    }
  }

  Future<void> _loadTasks() async {
    try {
      final filePath = await _getTasksFilePath();
      final file = File(filePath);
      
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> tasksJson = jsonDecode(content);
        tasks.clear();
        tasks.addAll(tasksJson.map((json) => BulkTask.fromJson(json)));
        print('[TASKS] Loaded ${tasks.length} tasks from $filePath');
      } else {
        print('[TASKS] No saved tasks file found');
      }
    } catch (e) {
      print('[TASKS] Error loading tasks: $e');
    }
  }

  void dispose() {
    _executor?.dispose();
    _executor = null;
    tasks.clear();
  }
}
