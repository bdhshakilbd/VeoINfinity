import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';

import 'package:veo3_another/utils/ffmpeg_utils.dart';

class FFmpegInfoScreen extends StatefulWidget {
  const FFmpegInfoScreen({super.key});

  @override
  State<FFmpegInfoScreen> createState() => _FFmpegInfoScreenState();
}

class _FFmpegInfoScreenState extends State<FFmpegInfoScreen> {
  String _ffmpegVersion = 'Loading...';
  String _ffprobeTest = 'Loading...';
  String _platformInfo = '';
  bool _ffmpegWorking = false;
  bool _ffprobeWorking = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFFmpegInfo();
  }

  Future<void> _loadFFmpegInfo() async {
    setState(() {
      _isLoading = true;
    });

    // Platform info
    _platformInfo = Platform.isAndroid ? 'Android' : 
                    Platform.isIOS ? 'iOS' : 
                    Platform.isWindows ? 'Windows' : 
                    Platform.isMacOS ? 'macOS' : 'Unknown';

    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: Use FFmpegKit
      await _testMobileFFmpeg();
    } else {
      // Desktop: Use Process
      await _testDesktopFFmpeg();
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _testMobileFFmpeg() async {
    // Test FFmpeg
    try {
      final session = await FFmpegKit.execute('-version');
      final output = await session.getOutput();
      final returnCode = await session.getReturnCode();
      
      if (returnCode?.isValueSuccess() == true && output != null) {
        _ffmpegVersion = output;
        _ffmpegWorking = true;
      } else {
        _ffmpegVersion = 'FFmpeg failed to execute\nReturn code: ${returnCode?.getValue()}';
        _ffmpegWorking = false;
      }
    } catch (e) {
      _ffmpegVersion = 'FFmpeg Error: $e';
      _ffmpegWorking = false;
    }

    // Test FFprobe
    try {
      final session = await FFprobeKit.execute('-version');
      final output = await session.getOutput();
      final returnCode = await session.getReturnCode();
      
      if (returnCode?.isValueSuccess() == true && output != null) {
        _ffprobeTest = output;
        _ffprobeWorking = true;
      } else {
        _ffprobeTest = 'FFprobe failed to execute\nReturn code: ${returnCode?.getValue()}';
        _ffprobeWorking = false;
      }
    } catch (e) {
      _ffprobeTest = 'FFprobe Error: $e';
      _ffprobeWorking = false;
    }
  }

  Future<void> _testDesktopFFmpeg() async {
    final ffmpegPath = await FFmpegUtils.getFFmpegPath();
    final ffprobePath = await FFmpegUtils.getFFprobePath();

    // Test FFmpeg
    try {
      final result = await Process.run(ffmpegPath, ['-version'], runInShell: true);
      if (result.exitCode == 0) {
        _ffmpegVersion = result.stdout.toString();
        _ffmpegWorking = true;
      } else {
        _ffmpegVersion = 'FFmpeg failed\nExit code: ${result.exitCode}\n${result.stderr}';
        _ffmpegWorking = false;
      }
    } catch (e) {
      _ffmpegVersion = 'FFmpeg not found or error: $e';
      _ffmpegWorking = false;
    }

    // Test FFprobe
    try {
      final result = await Process.run(ffprobePath, ['-version'], runInShell: true);
      if (result.exitCode == 0) {
        _ffprobeTest = result.stdout.toString();
        _ffprobeWorking = true;
      } else {
        _ffprobeTest = 'FFprobe failed\nExit code: ${result.exitCode}\n${result.stderr}';
        _ffprobeWorking = false;
      }
    } catch (e) {
      _ffprobeTest = 'FFprobe not found or error: $e';
      _ffprobeWorking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FFmpeg Info'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFFmpegInfo,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Platform Info Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            Platform.isAndroid ? Icons.android : 
                            Platform.isIOS ? Icons.apple :
                            Platform.isWindows ? Icons.window :
                            Icons.computer,
                            size: 40,
                            color: Colors.blue,
                          ),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Platform',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              Text(
                                _platformInfo,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // FFmpeg Status Card
                  _buildStatusCard(
                    title: 'FFmpeg',
                    isWorking: _ffmpegWorking,
                    icon: Icons.movie,
                  ),
                  const SizedBox(height: 8),

                  // FFmpeg Output
                  Card(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'FFmpeg Version Output:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade900,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SelectableText(
                              _ffmpegVersion,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: Colors.greenAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // FFprobe Status Card
                  _buildStatusCard(
                    title: 'FFprobe',
                    isWorking: _ffprobeWorking,
                    icon: Icons.search,
                  ),
                  const SizedBox(height: 8),

                  // FFprobe Output
                  Card(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'FFprobe Version Output:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade900,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SelectableText(
                              _ffprobeTest,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: Colors.cyanAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Usage Info
                  Card(
                    color: Colors.blue.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info, color: Colors.blue.shade700),
                              const SizedBox(width: 8),
                              Text(
                                'FFmpeg Kit Info',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: Colors.blue.shade700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            Platform.isAndroid || Platform.isIOS
                                ? '• Using ffmpeg_kit_flutter_new package\n'
                                  '• FFmpeg is bundled with the app\n'
                                  '• Supports video concatenation, encoding\n'
                                  '• FFprobe for media information'
                                : '• Using system FFmpeg installation\n'
                                  '• Ensure FFmpeg is in PATH or app directory\n'
                                  '• Required for video export features',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.blue.shade900,
                              height: 1.5,
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
  }

  Widget _buildStatusCard({
    required String title,
    required bool isWorking,
    required IconData icon,
  }) {
    return Card(
      color: isWorking ? Colors.green.shade50 : Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isWorking ? Colors.green : Colors.red,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        isWorking ? Icons.check_circle : Icons.error,
                        color: isWorking ? Colors.green : Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isWorking ? 'Working' : 'Not Working',
                        style: TextStyle(
                          color: isWorking ? Colors.green.shade700 : Colors.red.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
