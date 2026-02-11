import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import '../services/image_api_service.dart';
import '../services/gempix_api_service.dart';
import '../services/session_service.dart';
import '../services/image_upload_service.dart';
import '../services/settings_service.dart';
import '../models/image_response.dart';
import '../widgets/batch_selection_dialog.dart';
import '../widgets/robust_image_display.dart';
import 'settings_screen.dart';

import '../widgets/processing_monitor.dart';
import '../models/story_models.dart';
import '../services/story_service.dart';
import '../widgets/story_import_panel.dart';
import '../services/prompt_import_service.dart';
import '../widgets/prompt_import_panel.dart';
import '../services/project_save_service.dart';

class UnifiedGeneratorScreen extends StatefulWidget {
  const UnifiedGeneratorScreen({super.key});

  @override
  State<UnifiedGeneratorScreen> createState() => _UnifiedGeneratorScreenState();
}

class _UnifiedGeneratorScreenState extends State<UnifiedGeneratorScreen> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _cookieController = TextEditingController();
  final TextEditingController _authTokenController = TextEditingController();
  final ImageApiService _apiService = ImageApiService();
  final GemPixApiService _gemPixService = GemPixApiService();
  final SessionService _sessionService = SessionService();
  final ImageUploadService _uploadService = ImageUploadService();
  final SettingsService _settingsService = SettingsService();
  final ProjectSaveService _projectSaveService = ProjectSaveService();
  
  // Text-to-Image Controllers (New)
  final TextEditingController _subjectGenController = TextEditingController();
  final TextEditingController _sceneGenController = TextEditingController();
  final TextEditingController _styleGenController = TextEditingController();
  
  bool _isLoading = false;
  bool _isCheckingSession = false;
  bool _isUploadingImages = false;
  String? _errorMessage;
  final ScrollController _scrollController = ScrollController();
  // History State
  List<HistoryItem> _generatedHistory = [];
  
  // Aspect Ratio State
  String _selectedAspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE';
  
  // View Toggle State
  bool _isListView = true;
  
  // Image Model State
  String _selectedImageModel = 'IMAGEN_3_5';
  
  // Grid Controller State
  int _gridColumns = 2;
  
  // Universal Worker Queue (max 2 concurrent)
  static const int _maxWorkers = 2;
  int _runningWorkers = 0;
  final List<String> _pendingQueue = []; // Item IDs waiting to be processed
  
  // Cleaned up legacy single-image state (keeping for safety during refactor, but unused in new UI)
  Uint8List? _generatedImageBytes;
  GeneratedImage? _currentImage;
  
  SessionResponse? _sessionStatus;
  
  // Image upload states - now supporting multiple images per category
  // Image upload states
  // Refactored Subject state to use MediaItem model
  List<MediaItem> _subjectItems = [];
  
  // Legacy lists for Scene/Style (kept simple for now)
  List<File> _sceneImages = [];
  List<File> _styleImages = [];
  List<String> _sceneMediaIds = [];
  List<String> _styleMediaIds = [];
  List<String> _sceneCaptions = [];
  List<String> _styleCaptions = [];
  
  // Track uploading status for Scene/Style
  // Map<Path, bool>
  final Map<String, bool> _uploadingMap = {};
  
  String _workflowId = '';
  String? _outputFolder; // Output Folder State

  // Story Import State
  final StoryService _storyService = StoryService();
  StoryProject? _storyProject;
  bool _isStoryGenerating = false;
  bool _isStoryPaused = false;
  int _storyRunningWorkers = 0;
  final List<int> _storyPendingQueue = [];  // Scene indices waiting to be processed
  static const int _storyMaxWorkers = 2;

  // Prompt Import State
  List<String>? _importedPrompts;
  bool _isPromptGenerating = false;
  int _promptGeneratedCount = 0;

  // Getter to check if any images are uploaded AND selected
  bool get _hasImages {
    return _subjectItems.any((item) => item.isSelected && item.mediaId != null) ||
           _sceneMediaIds.isNotEmpty ||
           _styleMediaIds.isNotEmpty;
  }

  // Determine where images are saved
  Future<String> _getExpectedFilePath(HistoryItem item) async {
    Directory saveDir;
    if (Platform.isAndroid) {
      final dir = await getExternalStorageDirectory();
      saveDir = Directory('${dir!.path}/Nanobana/downloaded_images');
    } else if (Platform.isWindows) {
      final downloadsDir = Directory('${Platform.environment['USERPROFILE']}\\Downloads\\Nanobana_Images');
      saveDir = downloadsDir;
    } else {
      final tempDir = await getTemporaryDirectory();
      saveDir = Directory('${tempDir.path}/downloaded_images');
    }
    
    // Unique filename using random suffix to prevent overwrites
    final timestamp = item.timestamp.millisecondsSinceEpoch;
    final random = Random().nextInt(900000000) + 100000000; // 9-digit random
    final filename = 'nanobana_${timestamp}_$random.jpg';
    return '${saveDir.path}/$filename';
  }

  void _forceUpdateItem(String id, File file) {
    if (!mounted) return;
    
    // Only update if currently loading or has no path
    final index = _generatedHistory.indexWhere((i) => i.id == id);
    if (index != -1) {
      // If already has path, don't overwrite blindly unless needed
      if (_generatedHistory[index].isLoading || _generatedHistory[index].imagePath == null) {
         print('   🚑 Monitor FORCE UPDATE for item $id');
         setState(() {
           _generatedHistory[index].isLoading = false;
           _generatedHistory[index].imagePath = file;
           // If we don't have bytes, we relies on RobustImageDisplay to load from file
         });
      }
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    _cookieController.dispose();
    _cookieController.dispose();
    _authTokenController.dispose();
    _subjectGenController.dispose();
    _sceneGenController.dispose();
    _styleGenController.dispose();
    super.dispose();
  }

  Future<void> _checkSession() async {
    if (_cookieController.text.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your cookie';
      });
      return;
    }

    setState(() {
      _isCheckingSession = true;
      _errorMessage = null;
    });

    try {
      final session = await _sessionService.checkSession(_cookieController.text.trim());
      setState(() {
        _sessionStatus = session;
        _isCheckingSession = false;
      });
      
      if (session.isActive) {
        _showSnackBar('Session is active! ${session.timeRemainingFormatted} remaining');
      } else {
        _showSnackBar('Session expired!', isError: true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error checking session: $e';
        _isCheckingSession = false;
      });
    }
  }
  
  void _showSessionDialog() {
    final session = _sessionStatus;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session Settings'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Paste your cookie here:'),
              const SizedBox(height: 12),
              TextField(
                controller: _cookieController,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Cookie string...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _checkSession();
                },
                icon: const Icon(Icons.check_circle),
                label: const Text('Check Session'),
              ),
              if (session != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: session.isActive
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            session.isActive
                                ? Icons.check_circle
                                : Icons.error,
                            color: session.isActive
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            session.isActive ? 'Active' : 'Expired',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: session.isActive
                                  ? Colors.green.shade700
                                  : Colors.red.shade700,
                            ),
                          ),
                        ],
                      ),
                      if (session.user != null) ...[
                        const SizedBox(height: 8),
                        Text(session.user!.name),
                        Text(
                          session.user!.email,
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        'Time remaining: ${session.timeRemainingFormatted}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }


  Future<void> _generateFromText(String type, String prompt) async {
    if (prompt.trim().isEmpty) {
      _showSnackBar('Please enter a prompt', isError: true);
      return;
    }
    
    // Clear controller
    if (type == 'subject') _subjectGenController.clear();
    if (type == 'scene') _sceneGenController.clear();
    if (type == 'style') _styleGenController.clear();

    setState(() => _isLoading = true); 

    try {
      // 1. Generate Image
      final response = await _apiService.generateImage(
        prompt,
        aspectRatio: _selectedAspectRatio,
        imageModel: _selectedImageModel,
        authToken: _authTokenController.text.trim().isNotEmpty ? _authTokenController.text.trim() : null,
      );

      if (response.imagePanels.isNotEmpty && response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final imageBytes = base64Decode(generatedImage.encodedImage);

        // 2. Save to Temp File
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/${type}_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await tempFile.writeAsBytes(imageBytes);

        // 3. Add to lists (UI update)
        setState(() {
          if (type == 'subject') {
            _subjectItems.add(MediaItem(tempFile)..isUploading = true);
          } else {
            if (type == 'scene') _sceneImages.add(tempFile);
            if (type == 'style') _styleImages.add(tempFile);
            _uploadingMap[tempFile.path] = true;
          }
          _isLoading = false;
        });

        // 4. Upload for Media ID
        await _uploadSingleImage(tempFile, type);
      } else {
        throw Exception('No image generated');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Generation failed: $e', isError: true);
    }
  }

  Future<void> _pickImage(String type) async {
    if (_cookieController.text.trim().isEmpty) {
      _showSnackBar('Please set your cookie in session settings first', isError: true);
      return;
    }

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true, // Allow multiple images
      );

      if (result != null && result.files.isNotEmpty) {
        for (var pickedFile in result.files) {
          if (pickedFile.path != null) {
            final file = File(pickedFile.path!);
            
            setState(() {
              if (type == 'subject') {
                _subjectItems.add(MediaItem(file));
                // Set uploading status immediately in the item
                _subjectItems.last.isUploading = true;
              } else {
                // Legacy
                if (type == 'scene') _sceneImages.add(file);
                if (type == 'style') _styleImages.add(file);
                // Track uploading
                _uploadingMap[file.path] = true;
              }
            });
            
            // Auto-upload immediately
            _uploadSingleImage(file, type);
          }
        }
      }
    } catch (e) {
      _showSnackBar('Error picking image: $e', isError: true);
    }
  }

  Future<void> _uploadSingleImage(File imageFile, String type) async {
    try {
      final mediaCategory = type == 'subject' 
          ? 'MEDIA_CATEGORY_SUBJECT'
          : type == 'scene'
          ? 'MEDIA_CATEGORY_SCENE'
          : 'MEDIA_CATEGORY_STYLE';

      final result = await _uploadService.uploadImage(
        imageFile: imageFile,
        cookie: _cookieController.text.trim(),
        workflowId: _workflowId,
        mediaCategory: mediaCategory,
      );

      setState(() {
        if (type == 'subject') {
          // Find the item
          final index = _subjectItems.indexWhere((item) => item.file.path == imageFile.path);
          if (index != -1) {
            _subjectItems[index].mediaId = result['mediaGenerationId'];
            _subjectItems[index].caption = result['caption'];
            _subjectItems[index].isUploading = false;
          }
        } else {
          // Legacy lists
          _uploadingMap[imageFile.path] = false;
          if (type == 'scene') {
             _sceneMediaIds.add(result['mediaGenerationId']);
             _sceneCaptions.add(result['caption']);
          } else if (type == 'style') {
             _styleMediaIds.add(result['mediaGenerationId']);
             _styleCaptions.add(result['caption']);
          }
        }
      });

      _showSnackBar('${type[0].toUpperCase()}${type.substring(1)} image uploaded!');
    } catch (e) {
      setState(() {
         // Clear uploading status on error
         if (type == 'subject') {
            final index = _subjectItems.indexWhere((item) => item.file.path == imageFile.path);
            if (index != -1) _subjectItems[index].isUploading = false;
         } else {
            _uploadingMap[imageFile.path] = false;
         }
      });
      _showSnackBar('Error uploading $type image: $e', isError: true);
    }
  }

  void _removeImage(String type, int index) {
    setState(() {
      if (type == 'subject') {
        if (index < _subjectItems.length) _subjectItems.removeAt(index);
      } else {
        // Legacy
        if (type == 'scene') {
          if (index < _sceneImages.length) _sceneImages.removeAt(index);
          if (index < _sceneMediaIds.length) _sceneMediaIds.removeAt(index);
          if (index < _sceneCaptions.length) _sceneCaptions.removeAt(index);
        } else if (type == 'style') {
          if (index < _styleImages.length) _styleImages.removeAt(index);
          if (index < _styleMediaIds.length) _styleMediaIds.removeAt(index);
          if (index < _styleCaptions.length) _styleCaptions.removeAt(index);
        }
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _workflowId = _generateUuid();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _settingsService.loadSettings();
      
      setState(() {
        if (settings['authToken'] != null) {
          _authTokenController.text = settings['authToken'];
        }
        if (settings['cookie'] != null) {
          _cookieController.text = settings['cookie'];
        }
        if (settings['aspectRatio'] != null) {
          _selectedAspectRatio = settings['aspectRatio'];
        }
        if (settings['imageModel'] != null) {
          _selectedImageModel = settings['imageModel'];
        }
        if (settings['workflowId'] != null) {
          _workflowId = settings['workflowId'];
        }
        if (settings['outputFolder'] != null) {
          _outputFolder = settings['outputFolder'];
        }
      });
      
      // If no credentials in settings, try to load from active profile
      if (_authTokenController.text.isEmpty || _cookieController.text.isEmpty) {
        final activeProfile = await _settingsService.getActiveProfile();
        if (activeProfile != null) {
          setState(() {
            // Use getAuthToken() which returns cached auto-token or manual token
            if (_authTokenController.text.isEmpty) {
              final token = activeProfile.getAuthToken();
              if (token.isNotEmpty) {
                _authTokenController.text = token;
              }
            }
            if (_cookieController.text.isEmpty && activeProfile.cookie.isNotEmpty) {
              _cookieController.text = activeProfile.cookie;
            }
          });
          print('✅ Loaded credentials from active profile: ${activeProfile.name}');
        }
      }
      
      print('✅ Settings loaded successfully');
    } catch (e) {
      print('⚠️ Could not load settings: $e');
    }
  }

  Future<void> _saveCurrentSettings() async {
    try {
      await _settingsService.saveSettings(
        authToken: _authTokenController.text.trim(),
        cookie: _cookieController.text.trim(),
        aspectRatio: _selectedAspectRatio,
        imageModel: _selectedImageModel,
        workflowId: _workflowId,
        outputFolder: _outputFolder,
      );
    } catch (e) {
      print('⚠️ Could not save settings: $e');
    }
  }

  void _openSettings() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          currentAuthToken: _authTokenController.text,
          currentCookie: _cookieController.text,
          currentAspectRatio: _selectedAspectRatio,
          onSave: (authToken, cookie, aspectRatio) {
            setState(() {
              _authTokenController.text = authToken;
              _cookieController.text = cookie;
              _selectedAspectRatio = aspectRatio;
            });
            _saveCurrentSettings();
          },
        ),
      ),
    );

    if (result == true) {
      _showSnackBar('Settings saved successfully!');
    }
  }

  // ============ PROJECT SAVE/LOAD METHODS ============

  /// Save current project state
  Future<void> _saveProject() async {
    // Ask for project name
    final nameController = TextEditingController(
      text: _storyProject?.title ?? 'My Project ${DateTime.now().millisecondsSinceEpoch}',
    );
    
    final projectName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Save Project', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Project Name',
            labelStyle: TextStyle(color: Colors.grey.shade400),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            filled: true,
            fillColor: Colors.grey.shade800,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.purple.shade700),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (projectName == null || projectName.isEmpty) return;

    setState(() => _isLoading = true);
    _showSnackBar('Saving project...');

    try {
      // Collect all image data
      final imageData = <String, Uint8List>{};

      // Save history images
      final savedHistory = <SavedHistoryItem>[];
      for (final item in _generatedHistory) {
        if (item.imageBytes != null) {
          final imageId = 'history_${item.id}';
          imageData[imageId] = item.imageBytes!;
          savedHistory.add(SavedHistoryItem(
            id: item.id,
            prompt: item.prompt,
            timestamp: item.timestamp,
            imagePath: imageId,
            error: item.error,
          ));
        } else if (item.imagePath != null && await item.imagePath!.exists()) {
          final imageId = 'history_${item.id}';
          imageData[imageId] = await item.imagePath!.readAsBytes();
          savedHistory.add(SavedHistoryItem(
            id: item.id,
            prompt: item.prompt,
            timestamp: item.timestamp,
            imagePath: imageId,
            error: item.error,
          ));
        }
      }

      // Save subjects
      final savedSubjects = <SavedMediaItem>[];
      for (int i = 0; i < _subjectItems.length; i++) {
        final item = _subjectItems[i];
        final imageId = 'subject_$i';
        if (await item.file.exists()) {
          imageData[imageId] = await item.file.readAsBytes();
          savedSubjects.add(SavedMediaItem(
            filePath: imageId,
            mediaId: item.mediaId,
            caption: item.caption,
            isSelected: item.isSelected,
          ));
        }
      }

      // Save scenes
      final savedScenes = <SavedMediaItem>[];
      for (int i = 0; i < _sceneImages.length; i++) {
        final file = _sceneImages[i];
        final imageId = 'scene_$i';
        if (await file.exists()) {
          imageData[imageId] = await file.readAsBytes();
          savedScenes.add(SavedMediaItem(
            filePath: imageId,
            mediaId: i < _sceneMediaIds.length ? _sceneMediaIds[i] : null,
            caption: i < _sceneCaptions.length ? _sceneCaptions[i] : null,
          ));
        }
      }

      // Save styles
      final savedStyles = <SavedMediaItem>[];
      for (int i = 0; i < _styleImages.length; i++) {
        final file = _styleImages[i];
        final imageId = 'style_$i';
        if (await file.exists()) {
          imageData[imageId] = await file.readAsBytes();
          savedStyles.add(SavedMediaItem(
            filePath: imageId,
            mediaId: i < _styleMediaIds.length ? _styleMediaIds[i] : null,
            caption: i < _styleCaptions.length ? _styleCaptions[i] : null,
          ));
        }
      }

      // Save story project
      SavedStoryProject? savedStoryProject;
      if (_storyProject != null) {
        final savedChars = <SavedCharacter>[];
        for (final char in _storyProject!.characters) {
          String? charImageId;
          if (char.imageBytes != null) {
            charImageId = 'char_${char.id}';
            imageData[charImageId] = char.imageBytes!;
          }
          savedChars.add(SavedCharacter(
            id: char.id,
            name: char.name,
            description: char.description,
            outfits: char.outfits,
            imageMediaId: char.imageMediaId,
            imagePath: charImageId,
            customPrompt: char.customPrompt,
            usedPrompt: char.usedPrompt,
          ));
        }

        final savedStoryScenes = <SavedScene>[];
        for (final scene in _storyProject!.scenes) {
          String? sceneImageId;
          if (scene.imageBytes != null) {
            sceneImageId = 'story_scene_${scene.sceneNumber}';
            imageData[sceneImageId] = scene.imageBytes!;
          }
          savedStoryScenes.add(SavedScene(
            sceneNumber: scene.sceneNumber,
            prompt: scene.prompt,
            characterIds: scene.characterIds,
            negativePrompt: scene.negativePrompt,
            isGenerated: scene.isGenerated,
            imagePath: sceneImageId,
          ));
        }

        savedStoryProject = SavedStoryProject(
          title: _storyProject!.title,
          style: _storyProject!.style,
          totalScenes: _storyProject!.totalScenes,
          characters: savedChars,
          scenes: savedStoryScenes,
        );
      }

      // Create project object
      final project = SavedProject(
        name: projectName,
        savedAt: DateTime.now(),
        workflowId: _workflowId,
        selectedAspectRatio: _selectedAspectRatio,
        selectedImageModel: _selectedImageModel,
        history: savedHistory,
        subjects: savedSubjects,
        scenes: savedScenes,
        styles: savedStyles,
        storyProject: savedStoryProject,
        importedPrompts: _importedPrompts,
      );

      // Save
      final savePath = await _projectSaveService.saveProject(project, imageData: imageData);
      
      setState(() => _isLoading = false);
      _showSnackBar('Project saved: $projectName');
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Error saving project: $e', isError: true);
    }
  }

  /// Load a saved project
  Future<void> _loadProject() async {
    try {
      // List available projects
      final projects = await _projectSaveService.listProjects();
      
      if (projects.isEmpty) {
        _showSnackBar('No saved projects found', isError: true);
        return;
      }

      // Show project picker dialog
      final selectedPath = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey.shade900,
          title: const Text('Load Project', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            height: 300,
            child: ListView.builder(
              itemCount: projects.length,
              itemBuilder: (context, index) {
                final proj = projects[index];
                final savedAt = DateTime.tryParse(proj['savedAt'] ?? '');
                return ListTile(
                  leading: Icon(Icons.folder, color: Colors.purple.shade300),
                  title: Text(proj['name'] ?? 'Untitled', style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    '${proj['historyCount'] ?? 0} images • ${savedAt != null ? _formatDate(savedAt) : 'Unknown date'}',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.delete, color: Colors.red.shade400, size: 20),
                    onPressed: () async {
                      await _projectSaveService.deleteProject(proj['path']);
                      Navigator.pop(context);
                      _loadProject(); // Refresh list
                    },
                  ),
                  onTap: () => Navigator.pop(context, proj['path']),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (selectedPath == null) return;

      setState(() => _isLoading = true);
      _showSnackBar('Loading project...');

      final project = await _projectSaveService.loadProject(selectedPath);
      if (project == null) {
        setState(() => _isLoading = false);
        _showSnackBar('Failed to load project', isError: true);
        return;
      }

      // Restore state
      _workflowId = project.workflowId;
      _selectedAspectRatio = project.selectedAspectRatio;
      _selectedImageModel = project.selectedImageModel;
      _importedPrompts = project.importedPrompts;

      // Clear current state
      _generatedHistory.clear();
      _subjectItems.clear();
      _sceneImages.clear();
      _styleImages.clear();
      _sceneMediaIds.clear();
      _styleMediaIds.clear();
      _sceneCaptions.clear();
      _styleCaptions.clear();

      // Restore history
      for (final saved in project.history) {
        final imageBytes = saved.imagePath != null 
            ? await _projectSaveService.loadProjectImage(selectedPath, saved.imagePath!)
            : null;
        _generatedHistory.add(HistoryItem(
          id: saved.id,
          prompt: saved.prompt,
          timestamp: saved.timestamp,
          imageBytes: imageBytes,
          error: saved.error,
        ));
      }

      // Restore story project
      if (project.storyProject != null) {
        final sp = project.storyProject!;
        final chars = <StoryCharacter>[];
        for (final saved in sp.characters) {
          final char = StoryCharacter(
            id: saved.id,
            name: saved.name,
            description: saved.description,
            outfits: saved.outfits,
          );
          char.imageMediaId = saved.imageMediaId;
          char.customPrompt = saved.customPrompt;
          char.usedPrompt = saved.usedPrompt;
          if (saved.imagePath != null) {
            char.imageBytes = await _projectSaveService.loadProjectImage(selectedPath, saved.imagePath!);
          }
          chars.add(char);
        }

        final scenes = <StoryScene>[];
        for (final saved in sp.scenes) {
          final scene = StoryScene(
            sceneNumber: saved.sceneNumber,
            prompt: saved.prompt,
            characterIds: saved.characterIds,
            clothingAppearance: {},
            negativePrompt: saved.negativePrompt,
          );
          scene.id = 'scene_${saved.sceneNumber}_restored';
          scene.isGenerated = saved.isGenerated;
          if (saved.imagePath != null) {
            scene.imageBytes = await _projectSaveService.loadProjectImage(selectedPath, saved.imagePath!);
          }
          scenes.add(scene);
        }

        _storyProject = StoryProject(
          title: sp.title,
          style: sp.style,
          totalScenes: sp.totalScenes,
          characters: chars,
          scenes: scenes,
        );
      }

      setState(() => _isLoading = false);
      _showSnackBar('Project loaded: ${project.name}');
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('Error loading project: $e', isError: true);
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  // ============ STORY IMPORT METHODS ============

  /// Import a story JSON file
  Future<void> _importStoryJson() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final project = await _storyService.parseStoryFile(file);
        
        // Assign unique IDs to each scene
        for (int i = 0; i < project.scenes.length; i++) {
          project.scenes[i].id = 'scene_${i}_${DateTime.now().millisecondsSinceEpoch}';
        }
        
        setState(() {
          _storyProject = project;
        });
        
        _showSnackBar('Imported "${project.title}" with ${project.characters.length} characters and ${project.scenes.length} scenes');
      }
    } catch (e) {
      _showSnackBar('Error importing story: $e', isError: true);
    }
  }

  /// Generate a reference image for a character
  Future<void> _generateCharacterImage(StoryCharacter character) async {
    if (character.isGenerating) return;
    
    setState(() {
      character.isGenerating = true;
      character.error = null;
    });

    try {
      // Use generationPrompt which respects customPrompt if set
      final prompt = character.generationPrompt;
      print('📸 Generating character image for ${character.id} with prompt: $prompt');
      
      final response = await _apiService.generateImage(
        prompt,
        aspectRatio: 'IMAGE_ASPECT_RATIO_PORTRAIT',
        imageModel: _selectedImageModel,
        authToken: _authTokenController.text.trim().isNotEmpty 
            ? _authTokenController.text.trim() 
            : null,
      );

      if (response.imagePanels.isNotEmpty && 
          response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final imageBytes = base64Decode(generatedImage.encodedImage);
        final caption = generatedImage.prompt; // Use the caption from generation
        
        setState(() {
          character.imageBytes = imageBytes;
          character.isGenerating = false;
          character.usedPrompt = prompt; // Store the prompt used for recipe caption later
        });
        
        _showSnackBar('Generated image for ${character.name}. Uploading...');
        
        // Upload the generated image with its caption to get mediaGenerationId
        final mediaId = await _uploadService.uploadImageWithCaption(
          imageBytes: imageBytes,
          caption: caption,
          cookie: _cookieController.text.trim(),
          workflowId: _workflowId,
          mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
        );
        
        setState(() {
          character.imageMediaId = mediaId;
        });
        
        print('✅ Character ${character.id} uploaded with mediaId: $mediaId');
        _showSnackBar('${character.name} ready for scene generation');
      } else {
        setState(() {
          character.error = 'No image generated';
          character.isGenerating = false;
        });
      }
    } catch (e) {
      setState(() {
        character.error = 'Error: $e';
        character.isGenerating = false;
      });
      _showSnackBar('Error generating ${character.name}: $e', isError: true);
    }
  }

  /// Upload a character's generated image as a subject for use in scenes
  /// This is now only used as a fallback - prefer using uploadImageWithCaption directly
  Future<void> _uploadCharacterAsSubject(StoryCharacter character) async {
    if (character.imageBytes == null) return;
    
    setState(() {
      character.isUploading = true;
    });

    try {
      // Save image to temp file for upload
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/char_${character.id}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await tempFile.writeAsBytes(character.imageBytes!);
      
      character.imagePath = tempFile;
      
      final result = await _uploadService.uploadImage(
        imageFile: tempFile,
        cookie: _cookieController.text.trim(),
        workflowId: _workflowId,
        mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
      );

      setState(() {
        character.imageMediaId = result['mediaGenerationId'];
        character.isUploading = false;
      });
      
      print('✅ Character ${character.id} uploaded with mediaId: ${character.imageMediaId}');
      _showSnackBar('${character.name} ready for scene generation');
    } catch (e) {
      setState(() {
        character.isUploading = false;
        character.error = 'Upload failed: $e';
      });
      _showSnackBar('Error uploading ${character.name}: $e', isError: true);
    }
  }

  /// Load a custom image file for a character (Caption -> Generate NEW -> Upload with caption)
  Future<void> _loadCustomCharacterImage(StoryCharacter character, File imageFile) async {
    setState(() {
      character.isGenerating = true;
      character.error = null;
    });

    try {
      // Step 1: Show uploaded image preview first
      final imageBytes = await imageFile.readAsBytes();
      setState(() {
        character.imageBytes = imageBytes; // Show uploaded image temporarily
        character.imagePath = imageFile;
      });
      
      _showSnackBar('Captioning uploaded image...');

      // Step 2: Caption the uploaded image
      final base64Image = 'data:image/jpeg;base64,${base64Encode(imageBytes)}';
      
      final caption = await _uploadService.captionImage(
        base64Image: base64Image,
        cookie: _cookieController.text.trim(),
        workflowId: _workflowId,
      );
      
      // INSTANTLY show caption and update character prompt
      setState(() {
        character.customPrompt = caption; // Replace prompt with caption
      });
      
      _showSnackBar('Caption: "$caption". Generating new image...');

      // Step 3: Generate NEW image based on Caption
      final response = await _apiService.generateImage(
        caption,
        aspectRatio: 'IMAGE_ASPECT_RATIO_PORTRAIT',
        imageModel: _selectedImageModel,
        authToken: _authTokenController.text.trim().isNotEmpty 
            ? _authTokenController.text.trim() 
            : null,
      );

      if (response.imagePanels.isNotEmpty && 
          response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final newImageBytes = base64Decode(generatedImage.encodedImage);
        final generatedCaption = generatedImage.prompt; // Use caption from generation
        
        // INSTANTLY show generated image
        setState(() {
          character.imageBytes = newImageBytes; // Show the NEW generated image
          character.imagePath = null;
          character.isGenerating = false;
          character.usedPrompt = caption; // Store the caption used for recipe later
        });
        
        _showSnackBar('Uploading generated image...');
        
        // Step 4: Upload the generated image with its caption to get mediaGenerationId
        final mediaId = await _uploadService.uploadImageWithCaption(
          imageBytes: newImageBytes,
          caption: generatedCaption,
          cookie: _cookieController.text.trim(),
          workflowId: _workflowId,
          mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
        );
        
        setState(() {
          character.imageMediaId = mediaId;
        });
        
        print('✅ Character ${character.id} using mediaId: $mediaId');
        _showSnackBar('${character.name} ready for scene generation');
      } else {
        // Generation failed but KEEP the caption so user can edit and retry
        setState(() {
          character.isGenerating = false;
          character.error = 'Image generation failed. Edit caption and try again.';
        });
        _showSnackBar('Generation failed. Caption saved - you can edit and retry.', isError: true);
      }

    } catch (e) {
      // Error occurred but caption is already saved in customPrompt
      setState(() {
        character.isGenerating = false;
        character.error = 'Error: $e';
      });
      _showSnackBar('Error: $e. Caption saved - you can edit and retry.', isError: true);
    }
  }

  /// Remove/clear character image and mediaGenerationId
  void _removeCharacterImage(StoryCharacter character) {
    setState(() {
      character.imageBytes = null;
      character.imagePath = null;
      character.imageMediaId = null;
      character.error = null;
    });
    _showSnackBar('Image removed for ${character.name}');
  }

  /// Edit character prompt and regenerate
  void _editCharacterPrompt(StoryCharacter character, String newPrompt) {
    setState(() {
      character.customPrompt = newPrompt;
    });
    
    // Generate with new prompt
    _generateCharacterImage(character);
  }

  /// Generate images for all characters that don't have one
  Future<void> _generateAllMissingCharacters() async {
    if (_storyProject == null) return;
    
    final missingChars = _storyProject!.characters.where((c) => !c.hasGeneratedImage && !c.isGenerating).toList();
    
    if (missingChars.isEmpty) {
      _showSnackBar('All characters already have images');
      return;
    }
    
    _showSnackBar('Generating ${missingChars.length} missing character images...');
    
    // Generate all missing characters (they will be processed concurrently via existing worker pattern)
    for (final char in missingChars) {
      // Fire and forget - they will process in parallel
      _generateCharacterImage(char);
    }
  }

  /// Start batch scene generation - now allows starting without all chars
  void _startStoryGeneration() {
    if (_storyProject == null) return;
    if (_isStoryGenerating) return;
    
    setState(() {
      _isStoryGenerating = true;
      _isStoryPaused = false;
    });

    // Queue all pending scenes
    final proj = _storyProject!;
    for (int i = 0; i < proj.scenes.length; i++) {
      final scene = proj.scenes[i];
      if (!scene.isGenerated && !scene.isGenerating && scene.error == null) {
        scene.isQueued = true;
        _storyPendingQueue.add(i);
      }
    }

    print('📋 Queued ${_storyPendingQueue.length} scenes for generation');
    _showSnackBar('Starting batch generation of ${_storyPendingQueue.length} scenes');
    
    // Start initial workers
    _processStoryQueue();
  }

  /// Pause scene generation (current workers will complete)
  void _pauseStoryGeneration() {
    setState(() {
      _isStoryPaused = true;
    });
    _showSnackBar('Paused - current scenes will complete');
  }

  /// Resume scene generation
  void _resumeStoryGeneration() {
    setState(() {
      _isStoryPaused = false;
    });
    _showSnackBar('Resuming generation...');
    _processStoryQueue();
  }

  /// Stop all scene generation and clear queue
  void _stopStoryGeneration() {
    setState(() {
      _isStoryPaused = true;
      _isStoryGenerating = false;
      
      // Mark queued scenes as not queued
      for (final idx in _storyPendingQueue) {
        if (idx < _storyProject!.scenes.length) {
          _storyProject!.scenes[idx].isQueued = false;
        }
      }
      _storyPendingQueue.clear();
    });
    
    _showSnackBar('Generation stopped');
  }

  /// Remove the current story project
  void _removeStory() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Remove Story?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will remove the current story project. Generated images will remain in history.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              _stopStoryGeneration();
              setState(() {
                _storyProject = null;
                _storyPendingQueue.clear();
                _isStoryGenerating = false;
                _isStoryPaused = false;
              });
              Navigator.pop(context);
              _showSnackBar('Story project removed');
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  /// Import prompts from TXT or JSON file
  Future<void> _importPromptFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final promptService = PromptImportService();
        
        final prompts = await promptService.importPromptsFromFile(file);
        
        setState(() {
          _importedPrompts = prompts;
          _promptGeneratedCount = 0;
        });
        
        _showSnackBar('Loaded ${prompts.length} prompts from file');
      }
    } catch (e) {
      _showSnackBar('Error importing prompts: $e', isError: true);
    }
  }

  /// Paste prompts directly from clipboard
  Future<void> _pastePrompts() async {
    final controller = TextEditingController();
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text('Paste Prompts', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 500,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paste prompts (one per line) or JSON array:',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  style: TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'Example:\nA beautiful sunset\nA cat on a windowsill\n\nOr JSON:\n["prompt 1", "prompt 2"]',
                    hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                    filled: true,
                    fillColor: Colors.grey.shade800,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.blue.shade700),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade700),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.blue.shade500, width: 2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey.shade400)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (result != null && result.trim().isNotEmpty) {
      try {
        List<String> prompts = [];
        
        // Try to parse as JSON first
        if (result.trim().startsWith('[')) {
          final jsonData = jsonDecode(result);
          if (jsonData is List) {
            for (final item in jsonData) {
              if (item is String) {
                prompts.add(item.trim());
              } else if (item is Map<String, dynamic>) {
                final prompt = item['prompt'] as String?;
                if (prompt != null) prompts.add(prompt.trim());
              }
            }
          }
        } else {
          // Parse as plain text (one prompt per line)
          prompts = result
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toList();
        }
        
        if (prompts.isEmpty) {
          _showSnackBar('No valid prompts found', isError: true);
          return;
        }

        // Show Selection Dialog
        final selection = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (context) => BatchSelectionDialog(prompts: prompts),
        );

        if (selection == null) return; // User cancelled

        final int start = selection['startIndex'] as int;
        final int end = selection['endIndex'] as int;
        final bool clearHistory = selection['clearHistory'] as bool;

        // Slice prompts
        final selectedPrompts = prompts.sublist(start - 1, end);
        
        setState(() {
          if (clearHistory) {
             _generatedHistory.clear();
          }
          
          for (final text in selectedPrompts) {
               final id = _generateUuid();
               _generatedHistory.add(HistoryItem(
                 id: id,
                 prompt: text,
                 timestamp: DateTime.now(),
                 isLoading: false, 
                 isQueued: false,
               ));
          }
        });
        
        _showSnackBar('Added ${selectedPrompts.length} prompts to list.');
      } catch (e) {
        _showSnackBar('Error parsing prompts: $e', isError: true);
      }
    }
  }

  // Batch prompt folder path
  String? _batchPromptFolder;

  /// Generate image from prompt and update existing history item
  Future<void> _generatePromptImage(String prompt, int index, int total) async {
    if (prompt.trim().isEmpty) return;

    // Find the history item for this prompt
    final historyId = 'prompt_batch_$index';
    final historyIndex = _generatedHistory.indexWhere((item) => item.id == historyId);
    
    if (historyIndex == -1) return;

    try {
      ImageResponse response;
      
      // Use same logic as _runGeneration - include subjects/scenes/styles if selected
      if (_hasImages) {
        List<RecipeMediaInput> recipeInputs = [];
        
        // Add selected subjects
        for (var item in _subjectItems) {
          if (item.isSelected && item.mediaId != null) {
            recipeInputs.add(RecipeMediaInput(
              caption: item.caption ?? 'Subject image',
              mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
              mediaGenerationId: item.mediaId!,
            ));
          }
        }
        
        // Add scene images
        for (int i = 0; i < _sceneMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _sceneCaptions.length ? _sceneCaptions[i] : 'Scene image',
            mediaCategory: 'MEDIA_CATEGORY_SCENE',
            mediaGenerationId: _sceneMediaIds[i],
          ));
        }
        
        // Add style images
        for (int i = 0; i < _styleMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _styleCaptions.length ? _styleCaptions[i] : 'Style image',
            mediaCategory: 'MEDIA_CATEGORY_STYLE',
            mediaGenerationId: _styleMediaIds[i],
          ));
        }

        if (recipeInputs.isEmpty) {
          throw Exception('No images selected');
        }

        print('🎯 BATCH PROMPT ${index + 1}/$total: $prompt (${recipeInputs.length} inputs)');

        // Generate with recipe
        response = await _apiService.runImageRecipe(
          userInstruction: prompt,
          recipeMediaInputs: recipeInputs,
          workflowId: _workflowId,
          aspectRatio: _selectedAspectRatio,
          imageModel: _selectedImageModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      } else {
        // Generate without recipe (text-only)
        response = await _apiService.generateImage(
          prompt,
          aspectRatio: _selectedAspectRatio,
          imageModel: _selectedImageModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      }

      if (response.imagePanels.isNotEmpty && 
          response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final imageBytes = base64Decode(generatedImage.encodedImage);

        // Save to batch folder with sequential naming
        final fileName = 'image_${(index + 1).toString().padLeft(3, '0')}.jpg';
        
        File? savedFile;
        if (_batchPromptFolder != null) {
          final outputFile = File('$_batchPromptFolder/$fileName');
          await outputFile.writeAsBytes(imageBytes);
          savedFile = outputFile;
        }

        // Update history item with generated image
        setState(() {
          _generatedHistory[historyIndex].imageBytes = imageBytes;
          _generatedHistory[historyIndex].imagePath = savedFile;
          _generatedHistory[historyIndex].isLoading = false;
          _generatedHistory[historyIndex].error = null;
        });

        print('✅ Generated prompt ${index + 1}/$total: $fileName');
      } else {
        throw Exception('No image generated');
      }
    } catch (e) {
      print('❌ Error generating prompt ${index + 1}/$total: $e');
      
      // Update history item with error
      setState(() {
        _generatedHistory[historyIndex].isLoading = false;
        _generatedHistory[historyIndex].error = 'Failed: $e';
      });
    }
  }

  /// Start generating images for all imported prompts (parallel batches of 5)
  Future<void> _startPromptGeneration() async {
    if (_importedPrompts == null || _importedPrompts!.isEmpty) return;
    
    setState(() {
      _isPromptGenerating = true;
      _promptGeneratedCount = 0;
    });

    // Create batch folder in Downloads/nanobana
    try {
      final downloadsDir = Directory('C:\\Users\\${Platform.environment['USERNAME']}\\Downloads');
      final nanobanaDir = Directory('${downloadsDir.path}\\Nanobana_Images');
      
      // Create nanobana folder if it doesn't exist
      if (!await nanobanaDir.exists()) {
        await nanobanaDir.create(recursive: true);
      }
      
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final batchFolder = Directory('${nanobanaDir.path}\\batch_prompts_$timestamp');
      await batchFolder.create(recursive: true);
      _batchPromptFolder = batchFolder.path;
      print('📁 Created batch folder: ${batchFolder.path}');
    } catch (e) {
      print('❌ Error creating batch folder: $e');
      _showSnackBar('Error creating batch folder: $e', isError: true);
      setState(() => _isPromptGenerating = false);
      return;
    }

    // Pre-create placeholder history items for all prompts in sequential order
    final placeholders = <HistoryItem>[];
    for (int i = 0; i < _importedPrompts!.length; i++) {
      final placeholder = HistoryItem(
        id: 'prompt_batch_$i',
        prompt: 'Prompt ${i + 1}/${_importedPrompts!.length}: ${_importedPrompts![i]}',
        timestamp: DateTime.now(),
        isLoading: true,
      );
      placeholders.add(placeholder);
    }
    
    // Add all placeholders to history at once (Prompt 1 first)
    setState(() {
      _generatedHistory.insertAll(0, placeholders);
    });

    const batchSize = 5; // Generate 5 images in parallel
    
    for (int batchStart = 0; batchStart < _importedPrompts!.length; batchStart += batchSize) {
      if (!_isPromptGenerating) break; // Stop if user cancelled
      
      final batchEnd = (batchStart + batchSize).clamp(0, _importedPrompts!.length);
      
      // Generate batch in parallel
      final futures = <Future>[];
      for (int i = batchStart; i < batchEnd; i++) {
        futures.add(_generatePromptImage(_importedPrompts![i], i, _importedPrompts!.length));
      }
      
      try {
        await Future.wait(futures, eagerError: false);
      } catch (e) {
        print('Batch error: $e');
      }
      
      setState(() {
        _promptGeneratedCount = batchEnd;
      });
      
      _showSnackBar('Generated ${batchEnd}/${_importedPrompts!.length}');
    }

    setState(() {
      _isPromptGenerating = false;
    });
    
    final successCount = _generatedHistory
        .where((item) => item.id.startsWith('prompt_batch_') && item.imageBytes != null)
        .length;
    final failedCount = _generatedHistory
        .where((item) => item.id.startsWith('prompt_batch_') && item.error != null)
        .length;
    
    _showSnackBar('Batch complete! Success: $successCount, Failed: $failedCount\nSaved to: $_batchPromptFolder');
  }

  /// Stop prompt generation
  void _stopPromptGeneration() {
    setState(() {
      _isPromptGenerating = false;
    });
    _showSnackBar('Prompt generation stopped');
  }

  /// Remove imported prompts
  void _removePrompts() {
    setState(() {
      _importedPrompts = null;
      _promptGeneratedCount = 0;
      _isPromptGenerating = false;
    });
  }

  /// Extract prompt number from prompt text (e.g., "Prompt 5/20: ..." -> "5")
  String? _extractPromptNumber(String prompt) {
    final match = RegExp(r'Prompt (\d+)/').firstMatch(prompt);
    return match?.group(1);
  }

  /// Process the story queue - start workers if available
  void _processStoryQueue() {
    if (_storyProject == null) return;
    if (_isStoryPaused) return;
    if (_storyPendingQueue.isEmpty) {
      if (_storyRunningWorkers == 0) {
        setState(() {
          _isStoryGenerating = false;
        });
        _showSnackBar('All scenes completed!');
      }
      return;
    }

    // Start workers up to max
    while (_storyRunningWorkers < _storyMaxWorkers && _storyPendingQueue.isNotEmpty && !_isStoryPaused) {
      final sceneIdx = _storyPendingQueue.removeAt(0);
      _startSceneWorker(sceneIdx);
    }
  }

  /// Start a worker for a scene
  void _startSceneWorker(int sceneIndex) {
    if (_storyProject == null) return;
    if (sceneIndex >= _storyProject!.scenes.length) return;
    
    final scene = _storyProject!.scenes[sceneIndex];
    
    setState(() {
      scene.isQueued = false;
      scene.isGenerating = true;
      _storyRunningWorkers++;
    });
    
    print('🎬 Scene worker started: Scene ${scene.sceneNumber}. Active: $_storyRunningWorkers/$_storyMaxWorkers');
    
    _runSceneGeneration(sceneIndex).then((_) {
      _storyRunningWorkers--;
      print('✅ Scene ${scene.sceneNumber} done. Active: $_storyRunningWorkers/$_storyMaxWorkers, Queue: ${_storyPendingQueue.length}');
      _processStoryQueue();
    });
  }

  /// Generate a single scene with retry logic (max 5 retries)
  Future<void> _runSceneGeneration(int sceneIndex) async {
    if (_storyProject == null) return;
    
    final scene = _storyProject!.scenes[sceneIndex];
    final characterMap = _storyProject!.characterMap;
    final maxRetries = 3;

    while (scene.retryCount < maxRetries) {
      // SMART RETRY STRATEGY: Switch model if GEM_PIX_2 fails
      String currentModel = _selectedImageModel;
      if (scene.retryCount > 0 && _selectedImageModel == 'GEM_PIX_2') {
         // If we are retrying and started with GEM_PIX_2, switch to Imagen 3.5
         currentModel = 'IMAGEN_3_5';
         print('🔄 Smart Retry: Switching from GEM_PIX_2 to IMAGEN_3_5 for retry');
      }

      try {
        // Build enhanced prompt with character details, previous context, and style
        final enhancedPrompt = _storyService.buildScenePrompt(
          scene, 
          characterMap,
          allScenes: _storyProject!.scenes,
          projectStyle: _storyProject!.style,
        );
        
        // Collect character subject references for this scene
        List<RecipeMediaInput> recipeInputs = [];
        
        for (final charId in scene.characterIds) {
          final char = characterMap[charId];
          if (char != null && char.imageMediaId != null) {
            // Caption is the prompt used to generate the character image (for proper reference)
            final caption = char.usedPrompt ?? char.generationPrompt;
            recipeInputs.add(RecipeMediaInput(
              caption: caption,
              mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
              mediaGenerationId: char.imageMediaId!,
            ));
          }
        }
        
        print('🎯 Scene ${scene.sceneNumber} [Model: $currentModel] (attempt ${scene.retryCount + 1}/$maxRetries): "${scene.prompt}" (${recipeInputs.length} char refs)');
        
        ImageResponse response;
        
        if (recipeInputs.isNotEmpty) {
          // Use recipe API with character subjects
          response = await _apiService.runImageRecipe(
            userInstruction: enhancedPrompt,
            recipeMediaInputs: recipeInputs,
            workflowId: _workflowId,
            aspectRatio: _selectedAspectRatio,
            imageModel: currentModel,
            authToken: _authTokenController.text.trim().isNotEmpty 
                ? _authTokenController.text.trim() 
                : null,
          );
        } else {
          // No characters - use simple text-to-image
          response = await _apiService.generateImage(
            enhancedPrompt,
            aspectRatio: _selectedAspectRatio,
            imageModel: currentModel,
            authToken: _authTokenController.text.trim().isNotEmpty 
                ? _authTokenController.text.trim() 
                : null,
          );
        }
        
        if (response.imagePanels.isNotEmpty && 
            response.imagePanels[0].generatedImages.isNotEmpty) {
          final generatedImage = response.imagePanels[0].generatedImages[0];
          final imageBytes = base64Decode(generatedImage.encodedImage);
          
          setState(() {
            scene.imageBytes = imageBytes;
            scene.isGenerated = true;
            scene.isGenerating = false;
            scene.error = null;
          });
          
          // Also add to main gallery history
          final historyItem = HistoryItem(
            id: scene.id ?? 'scene_$sceneIndex',
            prompt: 'Scene ${scene.sceneNumber}: ${scene.prompt}',
            timestamp: DateTime.now(),
            imageBytes: imageBytes,
          );
          
          setState(() {
            _generatedHistory.add(historyItem);
          });
          
          // Save in background
          _saveImageInBackground(historyItem.id, imageBytes);
          
          return; // Success - exit retry loop
          
        } else {
          // No image generated - retry
          scene.retryCount++;
          print('⚠️ Scene ${scene.sceneNumber}: No image, retry ${scene.retryCount}/$maxRetries');
          
          if (scene.retryCount >= maxRetries) {
            setState(() {
              scene.error = 'Failed after $maxRetries attempts: No image generated';
              scene.isGenerating = false;
            });
          }
        }
      } catch (e) {
        scene.retryCount++;
        String errorMsg = 'Error: $e';
        if (e.toString().contains('PUBLIC_ERROR_PROMINENT_PEOPLE_FILTER_FAILED')) {
          errorMsg = 'Blocked: Prominent person detected';
        }
        
        print('⚠️ Scene ${scene.sceneNumber} error (attempt ${scene.retryCount}/$maxRetries): $errorMsg');
        
        if (scene.retryCount >= maxRetries) {
          setState(() {
            scene.error = '$errorMsg (after $maxRetries attempts)';
            scene.isGenerating = false;
          });
          print('❌ Scene ${scene.sceneNumber} failed permanently after $maxRetries attempts');
          return;
        }
        
        // Wait a bit before retrying
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    }
  }

  String _generateUuid() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
      RegExp(r'[xy]'),
      (match) {
        final r = (random + (random * 16).toInt()) % 16;
        final v = match.group(0) == 'x' ? r : (r & 0x3 | 0x8);
        return v.toRadixString(16);
      },
    );
  }  // ============ UNIVERSAL WORKER PATTERN ============

  /// Single entry point for all generation requests
  Future<void> _generateImage() async {
    // Check for ongoing uploads
    bool isUploading = _subjectItems.any((i) => i.isUploading) || _uploadingMap.containsValue(true);
    if (isUploading) {
      _showSnackBar('Please wait for images to finish uploading', isError: true);
      return;
    }

    // Create item immediately (shows in UI right away)
    final String itemId = _generateUuid();
    final String prompt = _promptController.text.trim().isEmpty 
        ? 'Create an image combining these elements' 
        : _promptController.text.trim();
    
    final bool shouldQueue = _runningWorkers >= _maxWorkers;
    
    final newItem = HistoryItem(
      id: itemId,
      prompt: prompt,
      timestamp: DateTime.now(),
      isLoading: !shouldQueue,
      isQueued: shouldQueue,
    );

    setState(() {
      _errorMessage = null;
      _generatedHistory.add(newItem);
    });

    _promptController.clear();

    // Scroll to show new item
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    if (shouldQueue) {
      _pendingQueue.add(itemId);
      print('⏳ Queued: $itemId (${_pendingQueue.length} waiting)');
      _showSnackBar('Generation queued (${_pendingQueue.length} waiting)');
    } else {
      _startWorker(itemId, prompt);
    }
  }


  /// Start a worker to process an item
  void _startWorker(String itemId, String prompt) {
    _runningWorkers++;
    print('🚀 Worker started. Active: $_runningWorkers/$_maxWorkers');
    
    // Run generation in background
    _runGeneration(itemId, prompt).then((_) {
      _runningWorkers--;
      print('✅ Worker done. Active: $_runningWorkers/$_maxWorkers, Queue: ${_pendingQueue.length}');
      _processNextInQueue();
    });
  }

  /// Check queue and start next worker if available
  void _processNextInQueue() {
    if (_pendingQueue.isEmpty) return;
    if (_runningWorkers >= _maxWorkers) return;
    
    final nextItemId = _pendingQueue.removeAt(0);
    
    final index = _generatedHistory.indexWhere((i) => i.id == nextItemId);
    if (index == -1) {
      print('⚠️ Queued item not found, skipping: $nextItemId');
      _processNextInQueue();
      return;
    }
    
    final item = _generatedHistory[index];
    
    setState(() {
      item.isQueued = false;
      item.isLoading = true;
    });
    
    print('🔄 Processing from queue: $nextItemId');
    _startWorker(nextItemId, item.prompt);
  }

  /// The actual generation logic (used by all workers)
  Future<void> _runGeneration(String itemId, String prompt) async {
    try {
      ImageResponse response;
      
      // Check if using GEM_PIX_2 model (uses different API)
      if (_selectedImageModel == 'GEM_PIX_2') {
        if (prompt.isEmpty) {
          _updateHistoryItem(itemId, error: 'Please enter a prompt');
          return;
        }
        
        // Upload images if any are selected
        List<String> imageInputIds = [];
        
        if (_hasImages) {
          try {
            // Upload subject images
            for (var item in _subjectItems) {
              if (item.isSelected && await item.file.exists()) {
                final imageBytes = await item.file.readAsBytes();
                final mediaId = await _gemPixService.uploadImage(
                  imageBytes: imageBytes,
                  authToken: _authTokenController.text.trim().isNotEmpty 
                      ? _authTokenController.text.trim() 
                      : ImageApiService.authToken,
                  aspectRatio: _selectedAspectRatio,
                );
                imageInputIds.add(mediaId);
              }
            }
            
            // Upload scene images
            for (var sceneFile in _sceneImages) {
              if (await sceneFile.exists()) {
                final imageBytes = await sceneFile.readAsBytes();
                final mediaId = await _gemPixService.uploadImage(
                  imageBytes: imageBytes,
                  authToken: _authTokenController.text.trim().isNotEmpty 
                      ? _authTokenController.text.trim() 
                      : ImageApiService.authToken,
                  aspectRatio: _selectedAspectRatio,
                );
                imageInputIds.add(mediaId);
              }
            }
            
            // Upload style images
            for (var styleFile in _styleImages) {
              if (await styleFile.exists()) {
                final imageBytes = await styleFile.readAsBytes();
                final mediaId = await _gemPixService.uploadImage(
                  imageBytes: imageBytes,
                  authToken: _authTokenController.text.trim().isNotEmpty 
                      ? _authTokenController.text.trim() 
                      : ImageApiService.authToken,
                  aspectRatio: _selectedAspectRatio,
                );
                imageInputIds.add(mediaId);
              }
            }
          } catch (uploadError) {
            _updateHistoryItem(itemId, error: 'Failed to upload images: $uploadError');
            return;
          }
        }
        
        // Call GEM PIX 2 API with uploaded image IDs
        final gemPixResponse = await _gemPixService.generateImages(
          prompt: prompt,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : ImageApiService.authToken,
          aspectRatio: _selectedAspectRatio,
          imageInputIds: imageInputIds.isNotEmpty ? imageInputIds : null,
        );
        
        // Extract image from GEM PIX 2 response format
        if (gemPixResponse['media'] != null && 
            (gemPixResponse['media'] as List).isNotEmpty) {
          final firstMedia = (gemPixResponse['media'] as List)[0];
          if (firstMedia['image'] != null && 
              firstMedia['image']['generatedImage'] != null) {
            final generatedImage = firstMedia['image']['generatedImage'];
            final encodedImage = generatedImage['encodedImage'];
            
            if (encodedImage != null) {
              final imageBytes = base64Decode(encodedImage);
              
              // Create a GeneratedImage object compatible with existing code
              final gemPixGeneratedImage = GeneratedImage(
                encodedImage: encodedImage,
                seed: generatedImage['seed'] ?? 0,
                mediaGenerationId: generatedImage['mediaGenerationId'] ?? '',
                prompt: generatedImage['prompt'] ?? prompt,
                imageModel: 'GEM_PIX_2',
                workflowId: firstMedia['workflowId'] ?? '',
                mediaVisibility: generatedImage['mediaVisibility'] ?? 'PRIVATE',
                fingerprintLogRecordId: generatedImage['fingerprintLogRecordId'] ?? '',
                aspectRatio: generatedImage['aspectRatio'] ?? _selectedAspectRatio,
              );
              
              _updateHistoryItem(itemId, image: gemPixGeneratedImage, bytes: imageBytes);
              _showSnackBar('Image generated with GEM PIX 2!');
              return;
            }
          }
        }
        
        _updateHistoryItem(itemId, error: 'No image generated from GEM PIX 2');
        return;
      }
      
      // Original logic for IMAGEN_3_5 and GEM_PIX
      if (_hasImages) {
        List<RecipeMediaInput> recipeInputs = [];
        
        for (var item in _subjectItems) {
          if (item.isSelected && item.mediaId != null) {
            recipeInputs.add(RecipeMediaInput(
              caption: item.caption ?? 'Subject image',
              mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
              mediaGenerationId: item.mediaId!,
            ));
          }
        }
        
        for (int i = 0; i < _sceneMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _sceneCaptions.length ? _sceneCaptions[i] : 'Scene image',
            mediaCategory: 'MEDIA_CATEGORY_SCENE',
            mediaGenerationId: _sceneMediaIds[i],
          ));
        }
        
        for (int i = 0; i < _styleMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _styleCaptions.length ? _styleCaptions[i] : 'Style image',
            mediaCategory: 'MEDIA_CATEGORY_STYLE',
            mediaGenerationId: _styleMediaIds[i],
          ));
        }

        if (recipeInputs.isEmpty) {
          _updateHistoryItem(itemId, error: 'No images selected');
          return;
        }

        print('🎯 GENERATING: $prompt (${recipeInputs.length} inputs)');

        response = await _apiService.runImageRecipe(
          userInstruction: prompt,
          recipeMediaInputs: recipeInputs,
          workflowId: _workflowId,
          aspectRatio: _selectedAspectRatio,
          imageModel: _selectedImageModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      } else {
        if (prompt.isEmpty) {
          _updateHistoryItem(itemId, error: 'Please enter a prompt');
          return;
        }
        
        response = await _apiService.generateImage(
          prompt,
          aspectRatio: _selectedAspectRatio,
          imageModel: _selectedImageModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      }
      
      if (response.imagePanels.isNotEmpty && 
          response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final imageBytes = base64Decode(generatedImage.encodedImage);
        _updateHistoryItem(itemId, image: generatedImage, bytes: imageBytes);
        _showSnackBar('Image generated!');
      } else {
        _updateHistoryItem(itemId, error: 'No image generated');
      }
    } catch (e) {
      String errorMsg = 'Error: $e';
      if (e.toString().contains('PUBLIC_ERROR_PROMINENT_PEOPLE_FILTER_FAILED')) {
        errorMsg = 'Blocked: Prominent person detected';
      }
      _updateHistoryItem(itemId, error: errorMsg);
    }
  }



  Future<void> _generateImageWithPrompt(String customPrompt) async {
    // Check for ongoing uploads
    bool isUploading = _subjectItems.any((i) => i.isUploading) || _uploadingMap.containsValue(true);
    if (isUploading) {
      _showSnackBar('Please wait for images to finish uploading', isError: true);
      return;
    }

    // 1. Setup Placeholder - CREATE NEW CARD
    final String tempId = _generateUuid();
    
    final newItem = HistoryItem(
      id: tempId,
      prompt: customPrompt,
      timestamp: DateTime.now(),
      isLoading: true,
    );

    setState(() {
      _errorMessage = null;
      // Append to bottom - THIS CREATES A NEW CARD
      _generatedHistory.add(newItem);
    });

    // Scroll to bottom IMMEDIATELY to show the new loading card
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    // 2. Async Generation
    try {
      ImageResponse response;
      
      if (_hasImages) {
        // Collect valid inputs
        List<RecipeMediaInput> recipeInputs = [];
        
        // Subjects (Filtered by Selection)
        for (var item in _subjectItems) {
          if (item.isSelected && item.mediaId != null) {
            recipeInputs.add(RecipeMediaInput(
              caption: item.caption ?? 'Subject image',
              mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
              mediaGenerationId: item.mediaId!,
            ));
          }
        }
        
        // Scenes (Legacy)
        for (int i = 0; i < _sceneMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _sceneCaptions.length ? _sceneCaptions[i] : 'Scene image',
            mediaCategory: 'MEDIA_CATEGORY_SCENE',
            mediaGenerationId: _sceneMediaIds[i],
          ));
        }
        
        // Styles (Legacy)
        for (int i = 0; i < _styleMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _styleCaptions.length ? _styleCaptions[i] : 'Style image',
            mediaCategory: 'MEDIA_CATEGORY_STYLE',
            mediaGenerationId: _styleMediaIds[i],
          ));
        }

        if (recipeInputs.isEmpty) {
           _updateHistoryItem(tempId, error: 'No images selected or uploaded successfully');
           return;
        }

        print('🎯 GENERATING NEW: $customPrompt (${recipeInputs.length} inputs)');

        response = await _apiService.runImageRecipe(
          userInstruction: customPrompt,
          recipeMediaInputs: recipeInputs,
          workflowId: _workflowId,
          aspectRatio: _selectedAspectRatio,
          imageModel: _selectedImageModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      } else {
        // Use Text-to-Image API
        response = await _apiService.generateImage(
          customPrompt,
          aspectRatio: _selectedAspectRatio,
          imageModel: _selectedImageModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      }
      
      if (response.imagePanels.isNotEmpty && 
          response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final imageBytes = base64Decode(generatedImage.encodedImage);
        
        // Update the NEW item with success
        _updateHistoryItem(tempId, image: generatedImage, bytes: imageBytes);
        _showSnackBar('New image generated successfully!');

      } else {
        _updateHistoryItem(tempId, error: 'No image generated from API');
      }
    } catch (e) {
      String errorMsg = 'Error: $e';
      if (e.toString().contains('PUBLIC_ERROR_PROMINENT_PEOPLE_FILTER_FAILED')) {
        errorMsg = 'Request blocked: Prominent person detected. Please remove them.';
      }
      _updateHistoryItem(tempId, error: errorMsg);
    }
  }

  void _updateHistoryItem(String id, {GeneratedImage? image, Uint8List? bytes, String? error}) {
    print('📝 Updating history item: $id');
    
    // 1. IMMEDIATE UI UPDATE (Memory First)
    setState(() {
      final index = _generatedHistory.indexWhere((item) => item.id == id);
      print('   📍 Found at index: $index');
      if (index != -1) {
        _generatedHistory[index].isLoading = false;
        _generatedHistory[index].isQueued = false;  // Always clear queued status
        if (error != null) {
          _generatedHistory[index].error = error;
          print('   ❌ Error set: $error');
        } else if (image != null && bytes != null) {
          _generatedHistory[index].image = image;
          _generatedHistory[index].imageBytes = bytes;
          print('   ✅ imageBytes SET (${bytes.length} bytes) for item $id');
          // imagePath is null initially, RobustImageDisplay will use bytes
        }
      } else {
        print('   ⚠️ Item NOT FOUND in history!');
      }
    });

    // 2. BACKGROUND SAVE (Fire and Forget)
    if (bytes != null && error == null) {
      _saveImageInBackground(id, bytes);
    }
    
    // Force rebuild
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  // Separated background save logic
  Future<void> _saveImageInBackground(String id, Uint8List bytes) async {
    try {
        final historyItemIndex = _generatedHistory.indexWhere((i) => i.id == id);
        if (historyItemIndex == -1) return;
        final historyItem = _generatedHistory[historyItemIndex];

        final path = await _getExpectedFilePath(historyItem);
        final file = File(path);
        
        // Create dir if needed (should be done by helper or here)
        final dir = file.parent;
        if (!await dir.exists()) await dir.create(recursive: true);

        await file.writeAsBytes(bytes, flush: true);
        print('   💾 Background save complete: $path');
        
        // Update state with path silently
        if (mounted) {
          setState(() {
             final idx = _generatedHistory.indexWhere((i) => i.id == id);
             if (idx != -1) {
               _generatedHistory[idx].imagePath = file;
             }
          });
        }
    } catch (e) {
      print('   ⚠️ Background save failed: $e');
    }
  }

  Future<void> _handleNewProject() async {
    if (_cookieController.text.trim().isEmpty) {
      _showSnackBar('Please set your cookie first', isError: true);
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Generate new workflow ID first
      final newWorkflowId = _generateUuid();
      
      final result = await _apiService.createProject(
        currentCookie: _cookieController.text.trim(),
        newWorkflowId: newWorkflowId,
      );
      
      final newCookie = result['cookie'];
      final projectInfo = result['projectInfo'];

      if (newCookie != null && newCookie != _cookieController.text) {
         _cookieController.text = newCookie;
         print('✅ Updated session cookie');
      }

      setState(() {
        // Reset all Lists
        _subjectItems.clear();
        _sceneImages.clear();
        _styleImages.clear();
        _sceneMediaIds.clear();
        _styleMediaIds.clear();
        _sceneCaptions.clear();
        _styleCaptions.clear();
        _uploadingMap.clear();
        
        // Reset other state
        _promptController.clear();
        _generatedImageBytes = null;
        _currentImage = null;
        _errorMessage = null;
        
        // Set the workflow ID we just initialized
        _workflowId = newWorkflowId;
        _isLoading = false;
      });

      _showSnackBar('New Project Created! ($projectInfo)');
    } catch (e) {
      setState(() {
        _isLoading = false;
        // Even if API fails, we reset local state? 
        // Let's just show error but still allow user to continue manually if they want
        _errorMessage = 'Error creating project: $e';
      });
      _showSnackBar('Error creating project: $e', isError: true);
    }
  }

  Future<void> _retryGeneration(HistoryItem item) async {
    print('🔄 Retrying generation for: ${item.prompt}');
    
    // Reset the item to loading state
    setState(() {
      final index = _generatedHistory.indexWhere((i) => i.id == item.id);
      if (index != -1) {
        _generatedHistory[index].isLoading = true;
        _generatedHistory[index].error = null;
        _generatedHistory[index].imageBytes = null;
        _generatedHistory[index].image = null;
      }
    });

    // Regenerate with the same prompt
    try {
      ImageResponse response;
      
      // 1. Determine Effective Model
      final effectiveModel = item.selectedModel ?? _selectedImageModel;

      // 2. Determine Effective Prompt (with Style and Context)
      String effectivePrompt = item.prompt;
      
      // Style Injection
      if (item.selectedStyle != null && item.selectedStyle != 'None') {
         effectivePrompt = '$effectivePrompt, in ${item.selectedStyle} style';
      }

      // Context Injection
      if (item.includeContext ?? false) {
        final index = _generatedHistory.indexWhere((i) => i.id == item.id);
        if (index != -1) {
          List<String> contextPrompts = [];
          int count = 0;
          // Collect previous 5 prompts (older items have higher index)
          for (int i = index + 1; i < _generatedHistory.length && count < 5; i++) {
            contextPrompts.add(_generatedHistory[i].prompt);
            count++;
          }
          
          if (contextPrompts.isNotEmpty) {
             final reversedContext = contextPrompts.reversed.toList(); // Chronological order
             final contextString = reversedContext.map((p) => '- $p').join('\n');
             
             effectivePrompt = '''
Previous prompts for context:
$contextString

Current prompt to proceed to generate the current image:
$effectivePrompt
''';
             print('📝 Added context with ${contextPrompts.length} previous items.');
          }
        }
      }

      if (_hasImages) {
        // Collect valid inputs
        List<RecipeMediaInput> recipeInputs = [];
        
        // Subjects (Filtered by Selection)
        for (var subjectItem in _subjectItems) {
          if (subjectItem.isSelected && subjectItem.mediaId != null) {
            recipeInputs.add(RecipeMediaInput(
              caption: subjectItem.caption ?? 'Subject image',
              mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
              mediaGenerationId: subjectItem.mediaId!,
            ));
          }
        }
        
        // Scenes (Legacy)
        for (int i = 0; i < _sceneMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _sceneCaptions.length ? _sceneCaptions[i] : 'Scene image',
            mediaCategory: 'MEDIA_CATEGORY_SCENE',
            mediaGenerationId: _sceneMediaIds[i],
          ));
        }
        
        // Styles (Legacy)
        for (int i = 0; i < _styleMediaIds.length; i++) {
          recipeInputs.add(RecipeMediaInput(
            caption: i < _styleCaptions.length ? _styleCaptions[i] : 'Style image',
            mediaCategory: 'MEDIA_CATEGORY_STYLE',
            mediaGenerationId: _styleMediaIds[i],
          ));
        }

        if (recipeInputs.isEmpty) {
           _updateHistoryItem(item.id, error: 'No images selected or uploaded successfully');
           return;
        }

        response = await _apiService.runImageRecipe(
          userInstruction: effectivePrompt,
          recipeMediaInputs: recipeInputs,
          workflowId: _workflowId,
          aspectRatio: _selectedAspectRatio,
          imageModel: effectiveModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      } else {
        // Use Text-to-Image API
        response = await _apiService.generateImage(
          effectivePrompt,
          aspectRatio: _selectedAspectRatio,
          imageModel: effectiveModel,
          authToken: _authTokenController.text.trim().isNotEmpty 
              ? _authTokenController.text.trim() 
              : null,
        );
      }
      
      if (response.imagePanels.isNotEmpty && 
          response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final imageBytes = base64Decode(generatedImage.encodedImage);
        
        _updateHistoryItem(item.id, image: generatedImage, bytes: imageBytes);
        _showSnackBar('Image regenerated successfully!');
      } else {
        _updateHistoryItem(item.id, error: 'No image generated from API');
      }
    } catch (e) {
      String errorMsg = 'Error: $e';
      if (e.toString().contains('PUBLIC_ERROR_PROMINENT_PEOPLE_FILTER_FAILED')) {
        errorMsg = 'Request blocked: Prominent person detected. Please remove them.';
      }
      _updateHistoryItem(item.id, error: errorMsg);
    }
  }

  void _showImageDetailDialog(HistoryItem item) {
    final TextEditingController promptEditController = TextEditingController(text: item.prompt);
    
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 800,
            maxHeight: MediaQuery.of(context).size.height * 0.9,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withOpacity(0.1),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.image, color: Theme.of(context).primaryColor),
                        const SizedBox(width: 8),
                        Text(
                          'Image Details',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              
              // Image Preview
              Flexible(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: InteractiveViewer(
                      child: Image.memory(
                        item.imageBytes!,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
              
              // Prompt Editor
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.edit_note, size: 20, color: Colors.grey.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'Edit Prompt',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: promptEditController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Modify the prompt and regenerate...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Image Info
              if (item.image != null)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildInfoRow('Model', item.image!.imageModel),
                      _buildInfoRow('Seed', item.image!.seed.toString()),
                      _buildInfoRow('Aspect Ratio', _selectedAspectRatio.replaceAll('IMAGE_ASPECT_RATIO_', '')),
                    ],
                  ),
                ),
              
              // Action Buttons
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _saveImage(item.imageBytes!),
                        icon: const Icon(Icons.download),
                        label: const Text('Download'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _deleteImage(item.id);
                        },
                        icon: const Icon(Icons.delete, color: Colors.red),
                        label: const Text('Delete', style: TextStyle(color: Colors.red)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          final newPrompt = promptEditController.text.trim();
                          Navigator.pop(context);
                          
                          if (newPrompt.isNotEmpty) {
                            // Create a new generation with the modified prompt
                            _generateImageWithPrompt(newPrompt);
                          }
                        },
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Generate New Image'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      promptEditController.dispose();
    });
  }

  void _deleteImage(String id) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Image'),
        content: const Text('Are you sure you want to delete this image?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _generatedHistory.removeWhere((item) => item.id == id);
              });
              Navigator.pop(context);
              _showSnackBar('Image deleted');
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }


  Future<void> _saveImage(Uint8List imageBytes, {bool suppressSuccessMsg = false}) async {
    try {
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          _showSnackBar('Storage permission denied', isError: true);
          return;
        }
      }

      Directory? directory;
      if (Platform.isAndroid) {
        directory = Directory('/storage/emulated/0/Download');
        if (!await directory.exists()) {
          directory = await getExternalStorageDirectory();
        }
      } else if (Platform.isWindows) {
        final userProfile = Platform.environment['USERPROFILE'];
        directory = Directory('$userProfile\\Downloads');
      } else {
        directory = await getDownloadsDirectory();
      }

      // Use selected output folder if available
      if (_outputFolder != null) {
        final customDir = Directory(_outputFolder!);
        if (await customDir.exists()) {
          directory = customDir;
        }
      }

      if (directory == null) {
        _showSnackBar('Could not access downloads folder', isError: true);
        return;
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'nanobana_${timestamp}.jpg';
      final filePath = '${directory.path}/$filename';

      final file = File(filePath);
      await file.writeAsBytes(imageBytes);

      if (!suppressSuccessMsg) _showSnackBar('Image saved to: $filePath');
    } catch (e) {
      _showSnackBar('Error saving image: $e', isError: true);
    }
  }

  /// Pick a custom output folder for saving images
  Future<void> _pickOutputFolder() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      
      if (selectedDirectory != null) {
        setState(() {
          _outputFolder = selectedDirectory;
        });
        
        await _saveCurrentSettings();
        _showSnackBar('Output folder set to: $selectedDirectory');
      }
    } catch (e) {
      _showSnackBar('Error selecting folder: $e', isError: true);
    }
  }


  void _showSnackBar(String message, {bool isError = false}) {
    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: 80,
        right: 16,
        child: TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 300),
          tween: Tween(begin: 300.0, end: 0.0),
          curve: Curves.easeOutCubic,
          builder: (context, offset, child) {
            return Transform.translate(
              offset: Offset(offset, 0),
              child: Opacity(
                opacity: (300 - offset) / 300,
                child: child,
              ),
            );
          },
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400, minWidth: 250),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isError ? Colors.red.shade600 : Colors.green.shade600,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isError ? Icons.error_outline : Icons.check_circle_outline,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);

    // Auto-dismiss after 3 seconds with fade-out animation
    Future.delayed(const Duration(milliseconds: 2700), () {
      if (overlayEntry.mounted) {
        // Fade out animation
        overlayEntry.markNeedsBuild();
      }
    });

    Future.delayed(const Duration(seconds: 3), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nanobana Image Generator'),
        centerTitle: true,
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save Project',
            onPressed: () => _saveProject(),
          ),
          IconButton(
            icon: const Icon(Icons.folder_copy),
            tooltip: 'Load Project',
            onPressed: () => _loadProject(),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Select Output Folder',
            onPressed: () => _pickOutputFolder(),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _handleNewProject(),
            tooltip: 'Create New Project',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _openSettings(),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            // Left Panel (Sidebar)
            Container(
              width: 380,
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: Colors.grey.shade300)),
                color: Colors.grey.shade50,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // Story Import Panel
                    StoryImportPanel(
                      project: _storyProject,
                      isGenerating: _isStoryGenerating,
                      isPaused: _isStoryPaused,
                      onImport: _importStoryJson,
                      onGenerateCharacter: _generateCharacterImage,
                      onLoadCustomImage: _loadCustomCharacterImage,
                      onEditCharacterPrompt: _editCharacterPrompt,
                      onGenerateAllCharacters: _generateAllMissingCharacters,
                      onRemoveCharacterImage: _removeCharacterImage,
                      onStartGeneration: _startStoryGeneration,
                      onPauseGeneration: _pauseStoryGeneration,
                      onResumeGeneration: _resumeStoryGeneration,
                      onStopGeneration: _stopStoryGeneration,
                      onRemoveStory: _removeStory,
                    ),
                    const SizedBox(height: 16),
                    
                    // Prompt Import Panel
                    PromptImportPanel(
                      prompts: _importedPrompts,
                      isGenerating: _isPromptGenerating,
                      generatedCount: _promptGeneratedCount,
                      onImport: _importPromptFile,
                      onPastePrompts: _pastePrompts,
                      onStartGeneration: _startPromptGeneration,
                      onStopGeneration: _stopPromptGeneration,
                      onRemovePrompts: _removePrompts,
                    ),
                    const SizedBox(height: 16),
                    _buildSubjectManager(),
                    const SizedBox(height: 24),
                    _buildSceneStyleInputs(),
                    const SizedBox(height: 100), // Bottom padding for scrolling
                  ],
                ),
              ),
            ),
            
            // Main Panel (Gallery + Prompt)
            Expanded(
              child: Stack(
                children: [
                  // Gallery
                  Positioned.fill(
                    child: Container(
                      color: Colors.grey.shade100, // Light background for gallery
                      child: _buildGallery(),
                    ),
                  ),
                  
                  // Bottom Prompt Bar
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _buildPromptBar(),
                  ),
                  
                  // Error Overlay
                  if (_errorMessage != null)
                     Positioned(
                       top: 20,
                       left: 20,
                       right: 20,
                       child: Container(
                         padding: const EdgeInsets.all(12),
                         decoration: BoxDecoration(
                           color: Colors.red.shade50,
                           borderRadius: BorderRadius.circular(12),
                           border: Border.all(color: Colors.red.shade200),
                           boxShadow: [
                             BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10),
                           ],
                         ),
                         child: Row(children: [
                           Icon(Icons.error_outline, color: Colors.red.shade700),
                           const SizedBox(width: 12),
                           Expanded(child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade900))),
                           IconButton(
                             icon: Icon(Icons.close, size: 20, color: Colors.red.shade700),
                             onPressed: () => setState(() => _errorMessage = null),
                           )
                         ]),
                       ),
                     ),
                     
                  // Loading Overlay
                  if (_isLoading)
                    Container(
                      color: Colors.black.withOpacity(0.3),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Colors.white),
                            SizedBox(height: 16),
                            Text(
                              'Generating your masterpiece...',
                              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubjectManager() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Characters / Subjects (${_subjectItems.length})',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (_subjectItems.isNotEmpty)
              TextButton.icon(
                onPressed: () => _pickImage('subject'),
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text('Add'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 200),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(12),
            color: Colors.white,
          ),
          child: Column(
            children: [
              // Upper Portion: List or Upload
              Expanded(
                child: _subjectItems.isEmpty
                    ? InkWell(
                        onTap: () => _pickImage('subject'),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.upload_file, size: 40, color: Theme.of(context).primaryColor),
                              const SizedBox(height: 8),
                              Text('Upload Image', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(8),
                        shrinkWrap: true,
                        itemCount: _subjectItems.length,
                        separatorBuilder: (ctx, i) => const SizedBox(height: 8),
                        itemBuilder: (ctx, i) => _buildSubjectItem(i),
                      ),
              ),
              const Divider(thickness: 1, height: 1),
              // Lower Portion: Create (Persistent)
              Container(
                height: 50, // Fixed height for input area
                color: Colors.grey.shade50,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _subjectGenController,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Create subject...',
                          isDense: true,
                          border: InputBorder.none,
                          hintStyle: TextStyle(fontSize: 12),
                        ),
                        onSubmitted: (val) => _generateFromText('subject', val),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _generateFromText('subject', _subjectGenController.text),
                      icon: const Icon(Icons.auto_fix_high, size: 20),
                      color: Theme.of(context).primaryColor,
                      tooltip: 'Generate',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSceneStyleInputs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Scene / Background',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        _buildImageUploadCard(
          'Scene',
          'scene',
          _sceneImages,
          Icons.landscape,
        ),
        const SizedBox(height: 16),
        Text(
          'Art Style / LoRA',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        _buildImageUploadCard(
          'Style',
          'style',
          _styleImages,
          Icons.palette,
        ),
      ],
    );
  }

  Widget _buildGallery() {
    if (_generatedHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'Your generated images will appear here',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Generations (${_generatedHistory.length})',
                 style: TextStyle(color: Colors.purple.shade700, fontWeight: FontWeight.bold),
              ),
              Row(
                children: [
                // Grid Slider (Only in Grid View)
                if (!_isListView) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Cols:', style: TextStyle(color: Colors.purple.shade700, fontSize: 12, fontWeight: FontWeight.bold)),
                      SizedBox(
                        width: 120, 
                        child: Slider(
                          value: _gridColumns.toDouble(),
                          min: 1, max: 5, divisions: 4,
                          activeColor: Colors.purple.shade700,
                          inactiveColor: Colors.purple.shade100,
                          label: _gridColumns.toString(),
                          onChanged: (val) => setState(() => _gridColumns = val.toInt()),
                        ),
                      ),
                      Text('${_gridColumns}', style: TextStyle(color: Colors.purple.shade700, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 12),
                    ],
                  ),
                ],

                // View Toggle
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.purple.shade200),
                  ),
                    child: IconButton(
                      icon: Icon(_isListView ? Icons.grid_view : Icons.view_list),
                      tooltip: _isListView ? 'Switch to Grid View' : 'Switch to List View',
                      color: Colors.purple.shade700,
                      onPressed: () {
                        setState(() {
                          _isListView = !_isListView;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Download All Button
                  if (_generatedHistory.any((item) => item.imageBytes != null))
                    OutlinedButton.icon(
                      onPressed: _downloadAllImages,
                      icon: const Icon(Icons.download_for_offline),
                      label: const Text('Download All'),
                    ),
                  // Clear Gallery Button (keeps files on disk)
                  if (_generatedHistory.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: OutlinedButton.icon(
                        onPressed: _clearGallery,
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Clear'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _isListView ? _buildListView() : _buildGridView(),
        ),
      ],
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      controller: _scrollController,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: ((MediaQuery.of(context).size.width / 200).floor().clamp(2, 6)), // Responsive columns
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 1.0,
      ),
      itemCount: _generatedHistory.length,
      itemBuilder: (context, index) {
        final item = _generatedHistory[index];
        return Card(
           key: ValueKey('grid_card_${item.id}_${item.isQueued}_${item.isLoading}'),
           elevation: 2,
           shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
           clipBehavior: Clip.antiAlias,
           child: Stack(
             fit: StackFit.expand,
             children: [
               // Image or Placeholder
               if (item.imageBytes != null)
                 RobustImageDisplay(
                    id: item.id,
                    imageBytes: item.imageBytes!,
                    imageFile: item.imagePath,
                    fit: BoxFit.cover,
                 )
               else
                 Container(color: Colors.grey.shade200),
               
               // Loading / Status Overlay
               if (item.isLoading || item.isQueued)
                 Container(
                   color: Colors.black54,
                   child: Center(
                     child: CircularProgressIndicator(
                       color: item.isQueued ? Colors.orange : Colors.white,
                     ),
                   ),
                 ),

               // Info Footer Overlay
               Positioned(
                 left: 0, right: 0, bottom: 0,
                 child: Container(
                   padding: const EdgeInsets.all(8),
                   decoration: const BoxDecoration(
                     gradient: LinearGradient(
                       begin: Alignment.bottomCenter,
                       end: Alignment.topCenter,
                       colors: [Colors.black87, Colors.transparent],
                     ),
                   ),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     mainAxisSize: MainAxisSize.min,
                     children: [
                       Text(
                         item.prompt,
                         maxLines: 2,
                         overflow: TextOverflow.ellipsis,
                         style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                       ),
                       const SizedBox(height: 4),
                       Row(
                         mainAxisAlignment: MainAxisAlignment.end,
                         children: [
                            if (!item.isLoading)
                              InkWell(
                                onTap: () => _retryGeneration(item),
                                child: const Icon(Icons.refresh, color: Colors.white, size: 16),
                              ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () => _deleteImage(item.id),
                              child: const Icon(Icons.delete, color: Colors.white70, size: 16),
                            ),
                         ],
                       )
                     ],
                   ),
                 ),
               ),
               
               // Error Overlay
               if (item.error != null)
                  Positioned(
                    top: 8, left: 8, right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      color: Colors.red.withOpacity(0.9),
                      child: Text(
                        item.error!,
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                        maxLines: 3, 
                        overflow: TextOverflow.ellipsis
                      ),
                    ),
                  )
             ],
           ),
        );
      },
    );
  }

  Widget _buildListView() {
    return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
            controller: _scrollController,
            itemCount: _generatedHistory.length,
            itemBuilder: (context, index) {
              final item = _generatedHistory[index];
              final TextEditingController rowPromptController = TextEditingController(text: item.prompt);
              // Ensure cursor is at end if user focuses (optional, but good UX)
              
              return Card(
                key: ValueKey('card_${item.id}_${item.isQueued}_${item.isLoading}_${item.imageBytes?.length ?? 0}'),
                elevation: 4,
                margin: const EdgeInsets.only(bottom: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // LEFT: Editable Prompt
                      Expanded(
                        flex: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: rowPromptController,
                              maxLines: 4,
                              minLines: 2,
                              onChanged: (val) {
                                item.prompt = val; // Direct model update
                              },
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                labelText: 'Prompt ${index + 1}',
                                alignLabelWithHint: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Model and Style Selectors
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  // Model Picker
                                  Container(
                                    height: 36,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: Colors.grey.shade300),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: DropdownButton<String>(
                                      value: item.selectedModel ?? _selectedImageModel, // Use item override or global default
                                      underline: const SizedBox(),
                                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                                      items: const [
                                        DropdownMenuItem(value: 'GEM_PIX_2', child: Text('GEM PIX 2')),
                                        DropdownMenuItem(value: 'IMAGEN_3_5', child: Text('Imagen 3.5')),
                                      ],
                                      onChanged: (val) {
                                        if (val != null) {
                                          setState(() => item.selectedModel = val);
                                        }
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Style Picker
                                  Container(
                                    height: 36,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: Colors.grey.shade300),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: DropdownButton<String>(
                                      value: item.selectedStyle ?? 'None',
                                      underline: const SizedBox(),
                                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                                      items: const [
                                        DropdownMenuItem(value: 'None', child: Text('No Style')),
                                        DropdownMenuItem(value: 'Realistic', child: Text('Realistic')),
                                        DropdownMenuItem(value: 'Cartoon', child: Text('Cartoon')),
                                        DropdownMenuItem(value: '3D Render', child: Text('3D Render')),
                                        DropdownMenuItem(value: 'Oil Painting', child: Text('Oil Painting')),
                                        DropdownMenuItem(value: 'Sketch', child: Text('Sketch')),
                                        DropdownMenuItem(value: 'Anime', child: Text('Anime')),
                                      ],
                                      onChanged: (val) {
                                        if (val != null) {
                                          setState(() => item.selectedStyle = val);
                                        }
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Manual Style Entry (if desired, handled via prompt text for now)
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                if (!item.isLoading && !item.isQueued)
                                  ElevatedButton.icon(
                                    onPressed: () {
                                      // Force prompt update before regenerating
                                      item.prompt = rowPromptController.text;
                                      _retryGeneration(item); 
                                    },
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: Text(item.imageBytes == null ? 'Generate' : 'Regenerate'),
                                  ),
                                
                                // Context Toggle
                                Tooltip(
                                  message: 'Include previous 5 prompts for scene consistency',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Transform.scale(
                                        scale: 0.8,
                                        child: Switch(
                                          value: item.includeContext ?? false,
                                          onChanged: (val) => setState(() => item.includeContext = val),
                                          activeColor: Colors.blue,
                                        ),
                                      ),
                                      const Text('Context', style: TextStyle(fontSize: 12, color: Colors.black54)),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                             if (item.error != null)
                               Padding(
                                 padding: const EdgeInsets.only(top: 8),
                                 child: Row(
                                   children: [
                                     Icon(Icons.error_outline, color: Colors.red.shade700, size: 16),
                                     const SizedBox(width: 4),
                                     Expanded(
                                       child: Text(
                                         item.error!,
                                         style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                                       ),
                                     ),
                                   ],
                                 ),
                               ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(width: 16),
                      
                      // RIGHT: Image Display
                      Expanded(
                        flex: 1,
                        child: AspectRatio(
                          aspectRatio: 16/9, // Default landscape container
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: item.isLoading || item.isQueued
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        CircularProgressIndicator(
                                          color: item.isQueued ? Colors.orange : Theme.of(context).primaryColor,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          item.isQueued ? 'Queued (${_pendingQueue.indexOf(item.id) + 1})' : 'Generating...',
                                          style: TextStyle(
                                            color: item.isQueued ? Colors.orange : Theme.of(context).primaryColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : item.imageBytes != null 
                                    ? Stack(
                                        children: [
                                           ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: RobustImageDisplay(
                                              id: item.id,
                                              imageBytes: item.imageBytes!,
                                              imageFile: item.imagePath,
                                              fit: BoxFit.contain,
                                            ),
                                          ),
                                          Positioned(
                                            bottom: 4, right: 4,
                                            child: IconButton(
                                              icon: const Icon(Icons.download_rounded),
                                              style: IconButton.styleFrom(backgroundColor: Colors.white.withOpacity(0.8)),
                                              onPressed: () => _saveImage(item.imageBytes!),
                                            ),
                                          )
                                        ],
                                      )
                                    : const Center(
                                        child: Icon(Icons.image_not_supported, size: 48, color: Colors.grey),
                                      ),
                          ),
                        ),
                      ),
                      
                      // Delete Action
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.grey),
                        onPressed: () => _deleteImage(item.id),
                        tooltip: 'Remove',
                      ),
                    ],
                  ),
                ),
              );
            },
    );
  }

  Future<void> _downloadAllImages() async {
    // Get all images with bytes
    final imagesToSave = _generatedHistory.where((item) => item.imageBytes != null).toList();
    
    if (imagesToSave.isEmpty) {
      _showSnackBar('No images to download', isError: true);
      return;
    }
    
    try {
      // Create folder in Downloads/Nanobana_Images
      final downloadsDir = Directory('C:\\Users\\${Platform.environment['USERNAME']}\\Downloads');
      final nanobanaDir = Directory('${downloadsDir.path}\\Nanobana_Images');
      
      // Create nanobana folder if it doesn't exist
      if (!await nanobanaDir.exists()) {
        await nanobanaDir.create(recursive: true);
      }
      
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final chatFolder = Directory('${nanobanaDir.path}\\chat_images_$timestamp');
      await chatFolder.create(recursive: true);
      
      print('📁 Created folder: ${chatFolder.path}');
      
      int count = 0;
      for (int i = 0; i < imagesToSave.length; i++) {
        final item = imagesToSave[i];
        final fileName = 'prompt_${(i + 1).toString().padLeft(3, '0')}.jpg';
        final filePath = '${chatFolder.path}\\$fileName';
        
        final file = File(filePath);
        await file.writeAsBytes(item.imageBytes!);
        count++;
        print('✅ Saved: $fileName');
      }
      
      _showSnackBar('Downloaded $count images to:\\n${chatFolder.path}');
    } catch (e) {
      _showSnackBar('Error downloading images: $e', isError: true);
    }
  }

  void _clearGallery() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Gallery'),
        content: const Text('This will remove all images from the gallery view.\nFiles already saved on disk will NOT be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _generatedHistory.clear();
              });
              Navigator.pop(context);
              _showSnackBar('Gallery cleared');
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptBar() {
    return Container(
      width: 700,
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Aspect Ratio Selector
          Row(
            children: [
              _buildAspectRatioButton(
                Icons.crop_landscape,
                'IMAGE_ASPECT_RATIO_LANDSCAPE',
                'Landscape',
              ),
              const SizedBox(width: 4),
              _buildAspectRatioButton(
                Icons.crop_portrait,
                'IMAGE_ASPECT_RATIO_PORTRAIT',
                'Portrait',
              ),
              const SizedBox(width: 4),
              _buildAspectRatioButton(
                Icons.crop_square,
                'IMAGE_ASPECT_RATIO_SQUARE',
                'Square',
              ),
            ],
          ),
          const SizedBox(width: 8),
          // Image Model Selector
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).primaryColor.withOpacity(0.3)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedImageModel,
                isDense: true,
                icon: Icon(Icons.arrow_drop_down, color: Theme.of(context).primaryColor, size: 20),
                style: TextStyle(
                  color: Theme.of(context).primaryColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'IMAGEN_3_5',
                    child: Text('Imagen 3.5'),
                  ),
                  DropdownMenuItem(
                    value: 'GEM_PIX',
                    child: Text('GEM Pix'),
                  ),
                  DropdownMenuItem(
                    value: 'GEM_PIX_2',
                    child: Text('GEM PIX 2'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedImageModel = value;
                    });
                    _saveCurrentSettings();
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 1,
            height: 30,
            color: Colors.grey.shade300,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _promptController,
              decoration: const InputDecoration(
                hintText: 'Describe the image you want to generate...',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 16),
              ),
              onSubmitted: (_) => _generateImage(),
            ),
          ),
          const SizedBox(width: 8),
          FloatingActionButton.small(
            onPressed: _isLoading ? null : _generateImage,
            backgroundColor: _isLoading ? Colors.grey : Theme.of(context).primaryColor,
            child: _isLoading 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.send, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildAspectRatioButton(IconData icon, String value, String tooltip) {
    final isSelected = _selectedAspectRatio == value;
    
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedAspectRatio = value;
          });
          _saveCurrentSettings();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isSelected 
                ? Theme.of(context).primaryColor.withOpacity(0.1)
                : Colors.transparent,
            border: Border.all(
              color: isSelected 
                  ? Theme.of(context).primaryColor
                  : Colors.grey.shade300,
              width: isSelected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isSelected 
                ? Theme.of(context).primaryColor
                : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }


  Widget _buildSubjectItem(int index) {
    if (index >= _subjectItems.length) return const SizedBox.shrink();
    final item = _subjectItems[index];
    
    return Card(
      margin: EdgeInsets.zero,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          children: [
            Checkbox(
              value: item.isSelected,
              onChanged: (val) {
                setState(() {
                  item.isSelected = val ?? false;
                });
              },
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: GestureDetector(
                onTap: () => _showMediaDetailDialog(item.file, 'subject', item),
                child: Image.file(
                  item.file,
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.isUploading) ...[
                    Row(
                      children: const [
                         SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                         SizedBox(width: 8),
                         Text('Uploading...', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                      ],
                    ),
                  ] else if (item.mediaId != null) ...[
                    const Text('Ready', style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold)),
                    if (item.caption != null)
                      Tooltip(
                        message: item.caption!,
                        child: Text(
                          item.caption!,
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ] else ...[
                     const Text('Pending...', style: TextStyle(color: Colors.orange, fontSize: 12)),
                  ]
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.fullscreen), // Maximize icon
              onPressed: () => _showMediaDetailDialog(item.file, 'subject', item),
              tooltip: 'View Details',
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20, color: Colors.redAccent),
              onPressed: () => _removeImage('subject', index),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageUploadCard(String label, String type, List<File> images, IconData icon) {
    // Check if there are any images
    final hasImages = images.isNotEmpty;
    final isSubject = type == 'subject';
    
    // Height calculation:
    // If Subject type, use a taller fixed height of 350.
    // If others, use 100 if has images, or 130 if empty (to fit split create/upload UI).
    final double cardHeight = isSubject ? 250 : (hasImages ? 100 : 130);
    
    return Container(
      height: cardHeight,
      decoration: BoxDecoration(
        border: Border.all(
          color: hasImages
              ? Theme.of(context).colorScheme.primary 
              : Colors.grey.shade300,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(12),
        color: hasImages
            ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.05)
            : Colors.grey.shade50,
      ),
      child: Column(
        children: [
          Expanded(
            child: hasImages
                ? ListView.separated(
                    padding: const EdgeInsets.all(8),
                    scrollDirection: Axis.horizontal,
                    itemCount: images.length + 1, // +1 for the add button
                    separatorBuilder: (context, index) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      if (index == images.length) {
                        // Add button at the end
                        return InkWell(
                          onTap: () => _pickImage(type),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 100,
                            height: 100, 
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: const Icon(Icons.add, color: Colors.grey),
                          ),
                        );
                      }
                      
                      // Image thumbnail
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: GestureDetector(
                              onTap: () => _showMediaDetailDialog(
                                images[index], 
                                type,
                                null // Scene/Style items don't have MediaItem wrap yet, we should fix this later but for now we pass file
                              ),
                              child: Image.file(
                                images[index],
                                fit: BoxFit.cover,
                                width: 100,
                                height: 100,
                              ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: GestureDetector(
                              onTap: () => _removeImage(type, index),
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.close, color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: GestureDetector(
                              onTap: () => _showMediaDetailDialog(
                                images[index], 
                                type,
                                null 
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.fullscreen, color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  )
                : InkWell(
                    onTap: () => _pickImage(type),
                    child: Center(
                       child: Column(
                         mainAxisAlignment: MainAxisAlignment.center,
                         children: [
                           Icon(Icons.upload_file, size: 24, color: Theme.of(context).primaryColor),
                           Text('Upload $label', style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                         ],
                       ),
                    ),
                  ),
          ),
          const Divider(height: 1, thickness: 1),
          // Persistent Creation Area
          Container(
             height: 45, // Fixed height
             color: Colors.grey.shade50,
             padding: const EdgeInsets.symmetric(horizontal: 8),
             child: Row(
               children: [
                 Expanded(
                   child: TextField(
                     controller: type == 'scene' ? _sceneGenController : _styleGenController,
                     decoration: InputDecoration(
                       hintText: 'Create $label...',
                       isDense: true,
                       border: InputBorder.none,
                       hintStyle: const TextStyle(fontSize: 12),
                     ),
                     style: const TextStyle(fontSize: 12),
                     onSubmitted: (val) => _generateFromText(type, val),
                   ),
                 ),
                 IconButton(
                   icon: const Icon(Icons.auto_fix_high, size: 20),
                   color: Theme.of(context).primaryColor,
                   onPressed: () => _generateFromText(type, (type == 'scene' ? _sceneGenController : _styleGenController).text),
                 )
               ],
             ),
          ),
        ],
      ),
    );
  }


  void _showMediaDetailDialog(File initialImageFile, String type, MediaItem? item) {
    if (!initialImageFile.existsSync()) return;

    // Use existing caption/prompt if available, or fetch from item
    final TextEditingController promptController = TextEditingController(text: item?.caption ?? '');
    
    // If it's scene/style legacy list, we need to find caption from legacy lists
    String? currentPrompt = item?.caption;
    if (item == null) {
       if (type == 'scene') {
         final idx = _sceneImages.indexOf(initialImageFile);
         if (idx != -1 && idx < _sceneCaptions.length) currentPrompt = _sceneCaptions[idx];
       } else if (type == 'style') {
         final idx = _styleImages.indexOf(initialImageFile);
         if (idx != -1 && idx < _styleCaptions.length) currentPrompt = _styleCaptions[idx];
       }
       if (currentPrompt != null) promptController.text = currentPrompt;
    }

    showDialog(
      context: context,
      builder: (context) {
        File currentImage = initialImageFile;
        bool isRegenerating = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              contentPadding: EdgeInsets.zero,
              // User requested "dont show black padding", so we make dialog transparent or use a cleaner background
              backgroundColor: Colors.grey.shade900,
              content: SizedBox(
                width: 900,
                height: 700,
                child: Row(
                  children: [
                    // Large Image Area
                    Expanded(
                      flex: 3,
                      child: Container(
                        // Removed Colors.black to avoid black bars
                        color: Colors.transparent, 
                        padding: const EdgeInsets.all(4), // Minimal padding
                        child: isRegenerating
                            ? const Center(child: CircularProgressIndicator(color: Colors.white))
                            : Center(
                                child: Image.file(
                                  currentImage, 
                                  fit: BoxFit.contain, // Original aspect ratio
                                ),
                              ),
                      ),
                    ),
                    // Controls Area
                    Expanded(
                      flex: 1,
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        color: Colors.grey[850], // Fixed shade850 error
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                             Row(
                               mainAxisAlignment: MainAxisAlignment.spaceBetween,
                               children: [
                                 const Text('Details', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                                 IconButton(
                                   icon: const Icon(Icons.close, color: Colors.white54),
                                   onPressed: () => Navigator.pop(context),
                                 )
                               ],
                             ),
                             const SizedBox(height: 24),
                             Text('Caption / Prompt:', style: TextStyle(color: Colors.grey.shade400, fontSize: 13, fontWeight: FontWeight.w500)),
                             const SizedBox(height: 8),
                             Expanded(
                               child: TextField(
                                 controller: promptController,
                                 maxLines: 20,
                                 style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
                                 decoration: InputDecoration(
                                   filled: true,
                                   fillColor: Colors.grey.shade900,
                                   border: OutlineInputBorder(
                                     borderRadius: BorderRadius.circular(12),
                                     borderSide: BorderSide.none,
                                   ),
                                   contentPadding: const EdgeInsets.all(16),
                                   hintText: 'Enter prompt to regenerate...',
                                   hintStyle: TextStyle(color: Colors.grey.shade600),
                                 ),
                               ),
                             ),
                             const SizedBox(height: 24),
                             SizedBox(
                               width: double.infinity,
                               child: ElevatedButton.icon(
                                 onPressed: isRegenerating ? null : () async {
                                    setDialogState(() => isRegenerating = true);
                                    
                                    // Call regenerate and wait for result
                                    File? newFile = await _regenerateItem(currentImage, type, item, promptController.text);
                                    
                                    if (newFile != null) {
                                      setDialogState(() {
                                        currentImage = newFile;
                                        isRegenerating = false;
                                      });
                                    } else {
                                      setDialogState(() => isRegenerating = false);
                                    }
                                 },
                                 icon: const Icon(Icons.refresh, color: Colors.white),
                                 label: const Text('Regenerate Image', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                 style: ElevatedButton.styleFrom(
                                   backgroundColor: Theme.of(context).primaryColor, // Use theme color
                                   foregroundColor: Colors.white,
                                   padding: const EdgeInsets.symmetric(vertical: 20),
                                   shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                   disabledBackgroundColor: Colors.grey.shade700,
                                 ),
                               ),
                             ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<File?> _regenerateItem(File oldFile, String type, MediaItem? item, String newPrompt) async {
      // Remove old one FIRST to update UI immediately
      // Note: This modifies the underlying list, but the Dialog is holding its own 'currentImage' state
      setState(() {
          if (item != null) {
             _subjectItems.remove(item);
          } else {
             // Legacy lists removal
             if (type == 'scene') {
                final idx = _sceneImages.indexOf(oldFile);
                if (idx != -1) _removeImage(type, idx);
             } else if (type == 'style') {
                final idx = _styleImages.indexOf(oldFile);
                if (idx != -1) _removeImage(type, idx);
             }
          }
      });

      // Generate new item
      await _generateFromText(type, newPrompt);
      
      // Retrieve the newly created file to return it
      File? newFile;
      if (type == 'subject' && _subjectItems.isNotEmpty) {
        newFile = _subjectItems.last.file;
      } else if (type == 'scene' && _sceneImages.isNotEmpty) {
        newFile = _sceneImages.last;
      } else if (type == 'style' && _styleImages.isNotEmpty) {
        newFile = _styleImages.last;
      }
      
      return newFile;
  }
}

class MediaItem {
  final File file;
  String? mediaId;
  String? caption;
  bool isUploading = false;
  bool isSelected = true;
  bool isExpanded = false;

  MediaItem(this.file);
}


class HistoryItem {
  final String id;
  GeneratedImage? image;
  Uint8List? imageBytes;
  File? imagePath;  // Add file path for robust disk-based display
  String prompt;  // Removed 'final' to allow editing
  final DateTime timestamp;
  bool isLoading;
  bool isQueued;  // NEW: Track if item is waiting in queue
  String? error;
  String? selectedModel; // New field for per-item model selection
  String? selectedStyle; // New field for per-item style selection
  bool? includeContext; // New field for Including previous prompt context

  HistoryItem({
    required this.id,
    required this.prompt,
    required this.timestamp,
    this.image,
    this.imageBytes,
    this.imagePath,
    this.isLoading = false,
    this.isQueued = false,
    this.error,
    this.selectedModel,
    this.selectedStyle,
    this.includeContext = false,
  });


}
