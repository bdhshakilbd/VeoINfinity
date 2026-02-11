import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/image_api_service.dart';
import '../models/image_response.dart';

class ImageRecipeScreen extends StatefulWidget {
  const ImageRecipeScreen({super.key});

  @override
  State<ImageRecipeScreen> createState() => _ImageRecipeScreenState();
}

class _ImageRecipeScreenState extends State<ImageRecipeScreen> {
  final TextEditingController _userInstructionController = TextEditingController();
  final List<ImagePromptData> _imagePrompts = [];
  final ImageApiService _apiService = ImageApiService();
  
  bool _isLoading = false;
  String? _errorMessage;
  Uint8List? _generatedImageBytes;
  GeneratedImage? _currentImage;

  @override
  void initState() {
    super.initState();
    // Add two default prompts
    _addImagePrompt();
    _addImagePrompt();
  }

  @override
  void dispose() {
    _userInstructionController.dispose();
    for (var prompt in _imagePrompts) {
      prompt.captionController.dispose();
      prompt.mediaGenerationIdController.dispose();
    }
    super.dispose();
  }

  void _addImagePrompt() {
    setState(() {
      _imagePrompts.add(ImagePromptData(
        captionController: TextEditingController(),
        mediaGenerationIdController: TextEditingController(),
        mediaCategory: 'MEDIA_CATEGORY_SUBJECT',
      ));
    });
  }

  void _removeImagePrompt(int index) {
    if (_imagePrompts.length > 1) {
      setState(() {
        _imagePrompts[index].captionController.dispose();
        _imagePrompts[index].mediaGenerationIdController.dispose();
        _imagePrompts.removeAt(index);
      });
    }
  }

  Future<void> _generateImage() async {
    if (_userInstructionController.text.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a user instruction';
      });
      return;
    }

    // Validate that at least one prompt has data
    bool hasValidPrompt = false;
    for (var prompt in _imagePrompts) {
      if (prompt.captionController.text.trim().isNotEmpty &&
          prompt.mediaGenerationIdController.text.trim().isNotEmpty) {
        hasValidPrompt = true;
        break;
      }
    }

    if (!hasValidPrompt) {
      setState(() {
        _errorMessage = 'Please add at least one complete image prompt';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _generatedImageBytes = null;
      _currentImage = null;
    });

    try {
      // Build recipe media inputs from the prompts
      final recipeInputs = _imagePrompts
          .where((prompt) =>
              prompt.captionController.text.trim().isNotEmpty &&
              prompt.mediaGenerationIdController.text.trim().isNotEmpty)
          .map((prompt) => RecipeMediaInput(
                caption: prompt.captionController.text.trim(),
                mediaCategory: prompt.mediaCategory,
                mediaGenerationId: prompt.mediaGenerationIdController.text.trim(),
              ))
          .toList();

      final response = await _apiService.runImageRecipe(
        userInstruction: _userInstructionController.text.trim(),
        recipeMediaInputs: recipeInputs,
      );
      
      if (response.imagePanels.isNotEmpty && 
          response.imagePanels[0].generatedImages.isNotEmpty) {
        final generatedImage = response.imagePanels[0].generatedImages[0];
        final imageBytes = base64Decode(generatedImage.encodedImage);
        
        setState(() {
          _generatedImageBytes = imageBytes;
          _currentImage = generatedImage;
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'No image generated';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveImage() async {
    if (_generatedImageBytes == null || _currentImage == null) {
      _showSnackBar('No image to save', isError: true);
      return;
    }

    try {
      // Request storage permission
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          _showSnackBar('Storage permission denied', isError: true);
          return;
        }
      }

      // Get the downloads directory
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

      if (directory == null) {
        _showSnackBar('Could not access downloads folder', isError: true);
        return;
      }

      // Create filename with timestamp
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'nanobana_recipe_${timestamp}.jpg';
      final filePath = '${directory.path}/$filename';

      // Save the file
      final file = File(filePath);
      await file.writeAsBytes(_generatedImageBytes!);

      _showSnackBar('Image saved to: $filePath');
    } catch (e) {
      _showSnackBar('Error saving image: $e', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
              // User Instruction Section
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'What do you want? (User Instruction)',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _userInstructionController,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: 'e.g., they both eating tea on park',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Image Prompts Section
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Image Prompts',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: _addImagePrompt,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ..._imagePrompts.asMap().entries.map((entry) {
                        final index = entry.key;
                        final prompt = entry.value;
                        return _buildImagePromptCard(index, prompt);
                      }).toList(),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Generate Button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _generateImage,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(
                    _isLoading ? 'Generating...' : 'Generate Image',
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Error Message
              if (_errorMessage != null)
                Card(
                  color: Colors.red.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.red.shade700),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(color: Colors.red.shade700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Image Preview Section
              if (_generatedImageBytes != null)
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Generated Image',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              onPressed: _saveImage,
                              icon: const Icon(Icons.download),
                              tooltip: 'Save Image',
                              style: IconButton.styleFrom(
                                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            _generatedImageBytes!,
                            fit: BoxFit.contain,
                            width: double.infinity,
                          ),
                        ),
                        if (_currentImage != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildInfoRow('Generated Prompt', _currentImage!.prompt),
                                _buildInfoRow('Model', _currentImage!.imageModel),
                                _buildInfoRow('Seed', _currentImage!.seed.toString()),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: _saveImage,
                              icon: const Icon(Icons.save),
                              label: const Text(
                                'Save to Downloads',
                                style: TextStyle(fontSize: 16),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context).colorScheme.secondary,
                                foregroundColor: Theme.of(context).colorScheme.onSecondary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePromptCard(int index, ImagePromptData prompt) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Image ${index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (_imagePrompts.length > 1)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _removeImagePrompt(index),
                    color: Colors.red,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: prompt.captionController,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Caption (Image Description)',
                hintText: 'Describe the subject you want in the image...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: prompt.mediaGenerationIdController,
              decoration: InputDecoration(
                labelText: 'Media Generation ID',
                hintText: 'Paste the media generation ID...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: prompt.mediaCategory,
              decoration: InputDecoration(
                labelText: 'Media Category',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
              ),
              items: const [
                DropdownMenuItem(
                  value: 'MEDIA_CATEGORY_SUBJECT',
                  child: Text('Subject'),
                ),
                DropdownMenuItem(
                  value: 'MEDIA_CATEGORY_STYLE',
                  child: Text('Style'),
                ),
                DropdownMenuItem(
                  value: 'MEDIA_CATEGORY_SCENE',
                  child: Text('Scene'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    prompt.mediaCategory = value;
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }
}

class ImagePromptData {
  final TextEditingController captionController;
  final TextEditingController mediaGenerationIdController;
  String mediaCategory;

  ImagePromptData({
    required this.captionController,
    required this.mediaGenerationIdController,
    required this.mediaCategory,
  });
}
