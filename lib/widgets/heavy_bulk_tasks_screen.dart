import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../models/bulk_task.dart';
import '../models/scene_data.dart';
import '../utils/prompt_parser.dart';
import '../services/bulk_task_executor.dart';
import '../services/bulk_task_manager.dart';
import '../services/browser_video_generator.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';
import '../utils/config.dart';

class HeavyBulkTasksScreen extends StatefulWidget {
  final List<String> profiles;
  final Function(BulkTask) onTaskAdded;
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  final String email;
  final String password;
  
  const HeavyBulkTasksScreen({
    super.key,
    required this.profiles,
    required this.onTaskAdded,
    this.profileManager,
    this.loginService,
    this.email = '',
    this.password = '',
  });

  @override
  State<HeavyBulkTasksScreen> createState() => _HeavyBulkTasksScreenState();
}

class _HeavyBulkTasksScreenState extends State<HeavyBulkTasksScreen> {
  final TextEditingController _pasteController = TextEditingController();
  final _taskManager = BulkTaskManager();
  late BulkTaskExecutor _executor;
  Timer? _refreshTimer;
  
  @override
  void initState() {
    super.initState();
    
    // Configure multi-browser support
    _taskManager.setProfileManager(widget.profileManager);
    _taskManager.setLoginService(widget.loginService);
    _taskManager.setCredentials(widget.email, widget.password);
    
    _executor = _taskManager.getExecutor((task) {
      if (mounted) {
        setState(() {
          // Task updated, trigger rebuild and save
          _taskManager.updateTask(task);
        });
      }
    });
    
    // Restart scheduler for loaded tasks
    if (_taskManager.tasks.isNotEmpty) {
      _executor.startScheduler(_taskManager.tasks);
    }
    
    // Auto-refresh UI every 2 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }
  
  @override
  void dispose() {
    _refreshTimer?.cancel();
    _pasteController.dispose();
    // Don't dispose executor - it's managed by the singleton
    super.dispose();
  }

  Future<void> _loadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        for (var file in result.files) {
          if (file.path != null) {
            final content = await File(file.path!).readAsString();
            final scenes = parsePrompts(content);
            
            _showTaskConfigDialog(
              fileName: file.name,
              scenes: scenes,
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load file: $e')),
        );
      }
    }
  }

  Future<void> _pasteJson() async {
    final controller = TextEditingController();
    final promptCountNotifier = ValueNotifier<String>('Scenes detected: 0');

    void updatePromptCount(String content) {
      if (content.isEmpty) {
        promptCountNotifier.value = 'Scenes detected: 0';
        return;
      }

      try {
        final loadedScenes = parsePrompts(content);
        final isJson = content.contains('[') && content.contains(']');
        promptCountNotifier.value = 
            'Scenes detected: ${loadedScenes.length} (${isJson ? "JSON" : "Text"} format)';
      } catch (e) {
        promptCountNotifier.value = 'Invalid format';
      }
    }

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste Prompts'),
        content: SizedBox(
          width: 600,
          height: 400,
          child: Column(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste JSON array or text prompts (one per line)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: updatePromptCount,
                ),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: promptCountNotifier,
                builder: (context, value, child) => Text(
                  value,
                  style: TextStyle(
                    color: value.contains('Invalid') ? Colors.red : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        final scenes = parsePrompts(result);
        _showTaskConfigDialog(
          fileName: 'Pasted Content',
          scenes: scenes,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to parse content: $e')),
          );
        }
      }
    }
  }

  Future<void> _testToken() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('Testing browser connection...'),
          ],
        ),
      ),
    );

    try {
      print('[TEST] Creating browser generator...');
      final generator = BrowserVideoGenerator(debugPort: AppConfig.debugPort);
      
      print('[TEST] Connecting to Chrome...');
      await generator.connect();
      print('[TEST] ✓ Connected to Chrome');
      
      print('[TEST] Fetching access token...');
      final token = await generator.getAccessToken();
      
      generator.close();
      
      if (mounted) Navigator.pop(context); // Close loading dialog
      
      if (token != null) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 32),
                  SizedBox(width: 12),
                  Text('Connection Successful!'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('✓ Chrome connection: OK', style: TextStyle(color: Colors.green)),
                  const SizedBox(height: 8),
                  const Text('✓ Token retrieved: OK', style: TextStyle(color: Colors.green)),
                  const SizedBox(height: 16),
                  const Text('Token (first 50 chars):', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      token.substring(0, token.length > 50 ? 50 : token.length) + '...',
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      } else {
        throw Exception('Token is null');
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // Close loading dialog
      
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error, color: Colors.red, size: 32),
                SizedBox(width: 12),
                Text('Connection Failed'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Failed to connect to Chrome or retrieve token.'),
                const SizedBox(height: 16),
                const Text('Error:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(e.toString(), style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 16),
                const Text('Please ensure:', style: TextStyle(fontWeight: FontWeight.bold)),
                const Text('1. Chrome is running with debugging enabled'),
                const Text('2. You are logged into Google Labs'),
                const Text('3. The page is fully loaded'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _showTaskConfigDialog({
    required String fileName,
    required List<SceneData> scenes,
  }) async {
    String selectedProfile = widget.profiles.first;
    String selectedAccountType = 'ai_pro'; // 'free', 'ai_pro', 'ai_ultra'
    String selectedModel = 'Veo 3.1 - Fast'; // Flow UI model name
    String selectedAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE';
    TaskScheduleType scheduleType = TaskScheduleType.immediate;
    DateTime? scheduledTime;
    String? afterTaskId;
    String taskName = fileName.replaceAll(RegExp(r'\.(json|txt)$'), '');
    String outputFolder = '';

    // Helper to get model options based on account type
    Map<String, String> getModelOptions(String accountType) {
      if (accountType == 'ai_ultra') {
        return AppConfig.flowModelOptionsUltra;
      }
      return AppConfig.flowModelOptions;
    }

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Configure Bulk Task'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Task name
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Task Name',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: taskName),
                    onChanged: (value) => taskName = value,
                  ),
                  const SizedBox(height: 16),
                  
                  // Scenes count
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.video_library, color: Colors.blue),
                        const SizedBox(width: 8),
                        Text(
                          '${scenes.length} scenes detected',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Profile selection
                  DropdownButtonFormField<String>(
                    value: selectedProfile,
                    decoration: const InputDecoration(
                      labelText: 'Chrome Profile',
                      border: OutlineInputBorder(),
                    ),
                    items: widget.profiles.map((profile) {
                      return DropdownMenuItem(
                        value: profile,
                        child: Text(profile),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedProfile = value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  // Account Type selection
                  DropdownButtonFormField<String>(
                    value: selectedAccountType,
                    decoration: InputDecoration(
                      labelText: 'Account Type',
                      border: const OutlineInputBorder(),
                      fillColor: selectedAccountType == 'ai_ultra' 
                          ? Colors.purple.shade50 
                          : selectedAccountType == 'ai_pro'
                              ? Colors.blue.shade50
                              : Colors.green.shade50,
                      filled: true,
                    ),
                    items: AppConfig.accountTypeOptions.entries.map((entry) {
                      return DropdownMenuItem(
                        value: entry.value,
                        child: Row(
                          children: [
                            Icon(
                              entry.value == 'ai_ultra'
                                  ? Icons.star
                                  : entry.value == 'ai_pro'
                                      ? Icons.workspace_premium
                                      : Icons.auto_awesome,
                              size: 18,
                              color: entry.value == 'ai_ultra'
                                  ? Colors.purple
                                  : entry.value == 'ai_pro'
                                      ? Colors.blue
                                      : Colors.green,
                            ),
                            const SizedBox(width: 8),
                            Text(entry.key),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() {
                          selectedAccountType = value;
                          // Reset model to first available for new account type
                          final newOptions = getModelOptions(value);
                          selectedModel = newOptions.values.first;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  // Model selection (Flow UI models based on account type)
                  DropdownButtonFormField<String>(
                    value: selectedModel,
                    decoration: InputDecoration(
                      labelText: 'Model',
                      border: const OutlineInputBorder(),
                      fillColor: selectedAccountType == 'ai_ultra' 
                          ? Colors.purple.shade50 
                          : Colors.white,
                      filled: true,
                    ),
                    items: getModelOptions(selectedAccountType).entries.map((entry) {
                      return DropdownMenuItem(
                        value: entry.value,
                        child: Text(entry.key),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedModel = value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  // Aspect Ratio selection
                  DropdownButtonFormField<String>(
                    value: selectedAspectRatio,
                    decoration: const InputDecoration(
                      labelText: 'Aspect Ratio',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'VIDEO_ASPECT_RATIO_LANDSCAPE',
                        child: Text('Landscape (16:9)'),
                      ),
                      DropdownMenuItem(
                        value: 'VIDEO_ASPECT_RATIO_PORTRAIT',
                        child: Text('Portrait (9:16)'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedAspectRatio = value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  // Output folder
                  TextField(
                    decoration: InputDecoration(
                      labelText: 'Output Folder',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: () async {
                          final result = await FilePicker.platform.getDirectoryPath();
                          if (result != null) {
                            setDialogState(() => outputFolder = result);
                          }
                        },
                      ),
                    ),
                    controller: TextEditingController(text: outputFolder),
                    onChanged: (value) => outputFolder = value,
                  ),
                  const SizedBox(height: 16),
                  
                  // Schedule type
                  const Text(
                    'Schedule',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  RadioListTile<TaskScheduleType>(
                    title: const Text('Start Immediately'),
                    value: TaskScheduleType.immediate,
                    groupValue: scheduleType,
                    onChanged: (value) {
                      setDialogState(() => scheduleType = value!);
                    },
                  ),
                  RadioListTile<TaskScheduleType>(
                    title: const Text('Schedule at specific time'),
                    value: TaskScheduleType.scheduledTime,
                    groupValue: scheduleType,
                    onChanged: (value) {
                      setDialogState(() => scheduleType = value!);
                    },
                  ),
                  if (scheduleType == TaskScheduleType.scheduledTime)
                    Padding(
                      padding: const EdgeInsets.only(left: 32, top: 8),
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (date != null && context.mounted) {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay.now(),
                            );
                            if (time != null) {
                              setDialogState(() {
                                scheduledTime = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                  time.hour,
                                  time.minute,
                                );
                              });
                            }
                          }
                        },
                        icon: const Icon(Icons.calendar_today),
                        label: Text(
                          scheduledTime != null
                              ? 'Start at: ${scheduledTime!.toString().substring(0, 16)}'
                              : 'Select Date & Time',
                        ),
                      ),
                    ),
                  RadioListTile<TaskScheduleType>(
                    title: const Text('Start after another task finishes'),
                    value: TaskScheduleType.afterTask,
                    groupValue: scheduleType,
                    onChanged: (value) {
                      setDialogState(() => scheduleType = value!);
                    },
                  ),
                  if (scheduleType == TaskScheduleType.afterTask && _taskManager.tasks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 32, top: 8),
                      child: DropdownButtonFormField<String>(
                        value: afterTaskId,
                        decoration: const InputDecoration(
                          labelText: 'After Task',
                          border: OutlineInputBorder(),
                        ),
                        items: _taskManager.tasks.map((task) {
                          return DropdownMenuItem(
                            value: task.id,
                            child: Text('${task.name} (${task.totalScenes} scenes)'),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setDialogState(() => afterTaskId = value);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (taskName.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter a task name')),
                  );
                  return;
                }
                
                if (outputFolder.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please select an output folder')),
                  );
                  return;
                }

                final task = BulkTask(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: taskName,
                  scenes: scenes,
                  profile: selectedProfile,
                  outputFolder: outputFolder,
                  model: selectedModel,
                  aspectRatio: selectedAspectRatio,
                  scheduleType: scheduleType,
                  scheduledTime: scheduledTime,
                  afterTaskId: afterTaskId,
                  status: scheduleType == TaskScheduleType.immediate
                      ? TaskStatus.pending
                      : TaskStatus.scheduled,
                );

                setState(() {
                  _taskManager.addTask(task);
                });
                
                widget.onTaskAdded(task);
                Navigator.pop(context);
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Task "${task.name}" added')),
                );
              },
              child: const Text('Add Task'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.bolt, size: 24),
            SizedBox(width: 8),
            Text('Heavy Bulk Tasks'),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // Action buttons
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey.shade100,
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _pasteJson,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste JSON/Text'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _loadFile,
                  icon: const Icon(Icons.file_open),
                  label: const Text('Load Files'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _testToken,
                  icon: const Icon(Icons.verified_user),
                  label: const Text('Test Token'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade100,
                    foregroundColor: Colors.green.shade900,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_taskManager.tasks.length} tasks',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          
          // Tasks list
          Expanded(
            child: _taskManager.tasks.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bolt_outlined,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No bulk tasks yet',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Paste or load prompts to create bulk tasks',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _taskManager.tasks.length,
                    itemBuilder: (context, index) {
                      final task = _taskManager.tasks[index];
                      return _buildTaskCard(task);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(BulkTask task) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Profile: ${task.profile} • Model: ${task.model.contains('relaxed') ? 'Relaxed' : 'Fast'}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusChip(task.status),
              ],
            ),
            const SizedBox(height: 12),
            
            // Monitoring stats - main stats
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                children: [
                  // Main stats row
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatItem(
                          'Total',
                          task.totalScenes.toString(),
                          Icons.video_library,
                          Colors.blue,
                        ),
                      ),
                      Expanded(
                        child: _buildStatItem(
                          'Completed',
                          task.completedScenes.toString(),
                          Icons.check_circle,
                          Colors.green,
                        ),
                      ),
                      Expanded(
                        child: _buildStatItem(
                          'Failed',
                          task.failedScenes.toString(),
                          Icons.error,
                          Colors.red,
                        ),
                      ),
                      Expanded(
                        child: _buildStatItem(
                          'Queued',
                          task.scenes.where((s) => s.status == 'queued').length.toString(),
                          Icons.pending,
                          Colors.orange,
                        ),
                      ),
                    ],
                  ),
                  // Live activity row (polling, generating, downloading)
                  if (task.status == TaskStatus.running) ...[
                    const SizedBox(height: 8),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _buildStatItem(
                            'Generating',
                            task.scenes.where((s) => s.status == 'generating').length.toString(),
                            Icons.auto_awesome,
                            Colors.purple,
                          ),
                        ),
                        Expanded(
                          child: _buildStatItem(
                            'Polling',
                            task.scenes.where((s) => s.status == 'polling').length.toString(),
                            Icons.sync,
                            Colors.cyan,
                          ),
                        ),
                        Expanded(
                          child: _buildStatItem(
                            'Downloading',
                            task.scenes.where((s) => s.status == 'downloading').length.toString(),
                            Icons.download,
                            Colors.blue.shade700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            
            // Progress bar
            if (task.status == TaskStatus.running)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: task.progress,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${(task.progress * 100).toStringAsFixed(1)}% complete',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            
            // Schedule info
            if (task.scheduleType != TaskScheduleType.immediate)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.schedule, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 4),
                    Text(
                      task.scheduleType == TaskScheduleType.scheduledTime
                          ? 'Scheduled: ${task.scheduledTime?.toString().substring(0, 16)}'
                          : 'After task completes',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            
            // Actions
            const SizedBox(height: 12),
            Row(
              children: [
                if (task.status == TaskStatus.pending || task.status == TaskStatus.scheduled)
                  TextButton.icon(
                    onPressed: () {
                      _executor.startTask(task);
                    },
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Start'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green,
                    ),
                  ),
                if (task.status == TaskStatus.running) ...[
                  TextButton.icon(
                    onPressed: () {
                      // Pause - just mark as paused, don't stop processing
                      task.status = TaskStatus.pending;
                      setState(() {});
                      _taskManager.updateTask(task);
                    },
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('Pause'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      task.status = TaskStatus.pending;
                      setState(() {});
                      _taskManager.updateTask(task);
                    },
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Stop'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
                ],
                // Show retry button when there are ANY failed scenes (even if task is "Completed")
                if (task.failedScenes > 0)
                  TextButton.icon(
                    onPressed: () {
                      // Reset failed scenes to queued
                      for (var scene in task.scenes) {
                        if (scene.status == 'failed') {
                          scene.status = 'queued';
                          scene.error = null;
                          scene.retryCount = 0;
                        }
                      }
                      task.status = TaskStatus.pending;
                      setState(() {});
                      _executor.startTask(task);
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text('Retry ${task.failedScenes} Failed'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange,
                    ),
                  ),
                // Show "Continue" button for tasks with queued scenes
                if (task.status != TaskStatus.running && task.scenes.any((s) => s.status == 'queued'))
                  TextButton.icon(
                    onPressed: () {
                      task.status = TaskStatus.pending;
                      setState(() {});
                      _executor.startTask(task);
                    },
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Continue'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green,
                    ),
                  ),
                if (task.status == TaskStatus.pending || task.status == TaskStatus.completed)
                  TextButton.icon(
                    onPressed: () => _showRangeDialog(task),
                    icon: const Icon(Icons.filter_list, size: 18),
                    label: const Text('Range'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.blue,
                    ),
                  ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.open_in_full),
                  onPressed: () {
                    // Navigate to main screen with this task's scenes
                    Navigator.pop(context); // Go back to main screen
                    // Pass the task data to be loaded as a project
                    widget.onTaskAdded(task);
                  },
                  tooltip: 'Expand to main screen',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    setState(() {
                      _taskManager.removeTask(task);
                    });
                  },
                  tooltip: 'Delete task',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(TaskStatus status) {
    Color color;
    String label;
    IconData icon;

    switch (status) {
      case TaskStatus.pending:
        color = Colors.grey;
        label = 'Pending';
        icon = Icons.pending;
        break;
      case TaskStatus.running:
        color = Colors.blue;
        label = 'Running';
        icon = Icons.play_circle;
        break;
      case TaskStatus.paused:
        color = Colors.orange;
        label = 'Paused';
        icon = Icons.pause_circle;
        break;
      case TaskStatus.completed:
        color = Colors.green;
        label = 'Completed';
        icon = Icons.check_circle;
        break;
      case TaskStatus.failed:
        color = Colors.red;
        label = 'Failed';
        icon = Icons.error;
        break;
      case TaskStatus.scheduled:
        color = Colors.orange;
        label = 'Scheduled';
        icon = Icons.schedule;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildLiveStatusChip(String label, int count, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '$label: $count',
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Show dialog to select range of scenes to process
  Future<void> _showRangeDialog(BulkTask task) async {
    int fromIndex = 1;
    int toIndex = task.totalScenes;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Select Range'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Total scenes: ${task.totalScenes}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'From',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        controller: TextEditingController(text: fromIndex.toString()),
                        onChanged: (value) {
                          final val = int.tryParse(value);
                          if (val != null && val >= 1 && val <= task.totalScenes) {
                            fromIndex = val;
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'To',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        controller: TextEditingController(text: toIndex.toString()),
                        onChanged: (value) {
                          final val = int.tryParse(value);
                          if (val != null && val >= 1 && val <= task.totalScenes) {
                            toIndex = val;
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'This will reset scenes $fromIndex to $toIndex to "queued" status and start processing.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                // Reset scenes in range to queued
                for (int i = fromIndex - 1; i < toIndex && i < task.scenes.length; i++) {
                  final scene = task.scenes[i];
                  if (scene.status != 'completed') {
                    scene.status = 'queued';
                    scene.error = null;
                    scene.retryCount = 0;
                  }
                }
                task.status = TaskStatus.pending;
                setState(() {});
                _executor.startTask(task);
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Range'),
            ),
          ],
        ),
      ),
    );
  }
}
