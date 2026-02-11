import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/image_api_service.dart';
import '../services/session_service.dart';
import '../models/image_response.dart';

class ImageGeneratorScreen extends StatefulWidget {
  const ImageGeneratorScreen({super.key});

  @override
  State<ImageGeneratorScreen> createState() => _ImageGeneratorScreenState();
}

class _ImageGeneratorScreenState extends State<ImageGeneratorScreen> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _cookieController = TextEditingController();
  final ImageApiService _apiService = ImageApiService();
  final SessionService _sessionService = SessionService();
  
  bool _isLoading = false;
  bool _isCheckingSession = false;
  String? _errorMessage;
  Uint8List? _generatedImageBytes;
  GeneratedImage? _currentImage;
  SessionResponse? _sessionStatus;

  @override
  void dispose() {
    _promptController.dispose();
    _cookieController.dispose();
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

  Future<void> _generateImage() async {
    if (_promptController.text.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a prompt';
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
      final response = await _apiService.generateImage(_promptController.text.trim());
      
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
      final filename = 'nanobana_${timestamp}.jpg';
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
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              // Left Panel - Input & Session
              Expanded(
                flex: 1,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Session Status Card
                      Card(
                        elevation: 3,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.security, size: 18, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Session Status',
                                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _cookieController,
                                maxLines: 2,
                                style: const TextStyle(fontSize: 12),
                                decoration: InputDecoration(
                                  hintText: 'Paste your cookie here...',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  contentPadding: const EdgeInsets.all(8),
                                  isDense: true,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                height: 36,
                                child: ElevatedButton.icon(
                                  onPressed: _isCheckingSession ? null : _checkSession,
                                  icon: _isCheckingSession
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.check_circle, size: 16),
                                  label: Text(
                                    _isCheckingSession ? 'Checking...' : 'Check Session',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ),
                              if (_sessionStatus != null) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: _sessionStatus!.isActive
                                        ? Colors.green.shade50
                                        : Colors.red.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            _sessionStatus!.isActive
                                                ? Icons.check_circle
                                                : Icons.error,
                                            size: 16,
                                            color: _sessionStatus!.isActive
                                                ? Colors.green.shade700
                                                : Colors.red.shade700,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            _sessionStatus!.isActive ? 'Active' : 'Expired',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: _sessionStatus!.isActive
                                                  ? Colors.green.shade700
                                                  : Colors.red.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (_sessionStatus!.user != null) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          _sessionStatus!.user!.name,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          _sessionStatus!.user!.email,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey.shade600,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Icon(Icons.timer, size: 12, color: Colors.grey.shade600),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Remaining: ${_sessionStatus!.timeRemainingFormatted}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey.shade700,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Prompt Input Card
                      Card(
                        elevation: 3,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Enter Your Prompt',
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _promptController,
                                maxLines: 3,
                                style: const TextStyle(fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: 'e.g., generate a cow',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  contentPadding: const EdgeInsets.all(8),
                                  isDense: true,
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                height: 40,
                                child: ElevatedButton.icon(
                                  onPressed: _isLoading ? null : _generateImage,
                                  icon: _isLoading
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.auto_awesome, size: 18),
                                  label: Text(
                                    _isLoading ? 'Generating...' : 'Generate',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context).colorScheme.primary,
                                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Error Message
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 12),
                        Card(
                          color: Colors.red.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(10.0),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline, color: Colors.red.shade700, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _errorMessage!,
                                    style: TextStyle(color: Colors.red.shade700, fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Right Panel - Image Preview
              Expanded(
                flex: 1,
                child: Card(
                  elevation: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Generated Image',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (_generatedImageBytes != null)
                              IconButton(
                                onPressed: _saveImage,
                                icon: const Icon(Icons.download, size: 18),
                                tooltip: 'Save Image',
                                style: IconButton.styleFrom(
                                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                  padding: const EdgeInsets.all(8),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _generatedImageBytes != null
                              ? SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.memory(
                                          _generatedImageBytes!,
                                          fit: BoxFit.contain,
                                          width: double.infinity,
                                        ),
                                      ),
                                      if (_currentImage != null) ...[
                                        const SizedBox(height: 12),
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              _buildCompactInfoRow('Seed', _currentImage!.seed.toString()),
                                              _buildCompactInfoRow('Model', _currentImage!.imageModel),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        SizedBox(
                                          width: double.infinity,
                                          height: 36,
                                          child: ElevatedButton.icon(
                                            onPressed: _saveImage,
                                            icon: const Icon(Icons.save, size: 16),
                                            label: const Text(
                                              'Save to Downloads',
                                              style: TextStyle(fontSize: 13),
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Theme.of(context).colorScheme.secondary,
                                              foregroundColor: Theme.of(context).colorScheme.onSecondary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                )
                              : Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.image_outlined,
                                        size: 64,
                                        color: Colors.grey.shade400,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'No image generated yet',
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 50,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 11)),
          ),
        ],
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
            width: 100,
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
