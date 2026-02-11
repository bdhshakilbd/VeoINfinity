/// Background Music Generator
/// 
/// Integrates Lyria Music Service to generate AI background music.
library background_music_generator;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Clipboard
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';

import 'package:http/http.dart' as http;
import 'lyria_music_service.dart';
import 'lyria_audio_utils.dart';
import 'utils/app_logger.dart';

class BackgroundMusicPlayer extends StatefulWidget {
  final TextEditingController apiKeyController;
  final List<String>? multipleApiKeys; // Multiple API keys for parallel generation
  final Function(String filePath)? onFileSaved;
  final Function(String filePath, double startTime, double actualDuration, double expectedDuration)? onSegmentGenerated; // Called for each segment with timeline position and durations
  final Function(Uint8List chunk, double duration)? onLiveChunkReceived; // Live streaming callback
  final Function()? onStreamStarted; // Called when streaming starts
  final Function()? onStreamStopped; // Called when streaming stops
  
  const BackgroundMusicPlayer({
    super.key,
    required this.apiKeyController,
    this.multipleApiKeys,
    this.onFileSaved,
    this.onSegmentGenerated,
    this.onLiveChunkReceived,
    this.onStreamStarted,
    this.onStreamStopped,
  });

  @override
  State<BackgroundMusicPlayer> createState() => _BackgroundMusicPlayerState();
}

class _BackgroundMusicPlayerState extends State<BackgroundMusicPlayer> {
  // Story Prompt Support
  final TextEditingController _storyPromptController = TextEditingController();
  double _durationPerPrompt = 8.0;
  bool _isAnalyzingStory = false;
  String _analysisModel = 'gemini-2.5-flash';
  String _promptStyle = 'Classic'; // 'Classic' or 'Advanced'
  
  final LyriaMusicService _musicService = LyriaMusicService();
  final TextEditingController _promptController = TextEditingController(
    text: 'Upbeat synthwave with driving bassline',
  );
  final TextEditingController _jsonController = TextEditingController();
  
  bool _isConnected = false;
  bool _isRecording = false;
  bool _isExpanded = true;
  bool _showJsonInput = false;
  String _status = 'Ready';
  
  // Configuration
  int _bpm = 120;
  double _density = 0.5;
  double _brightness = 0.5;
  
  // Recording
  final List<Uint8List> _audioBuffer = [];
  String? _lastRecordedFile;
  String? _liveStreamingFile; // Current file being streamed to
  double _liveStreamDuration = 0.0; // Track duration of live stream
  int _chunkCount = 0;

  @override
  void initState() {
    super.initState();
    // Listen to audio stream for live updates
    _musicService.audioStream.listen((data) {
      if (_isRecording) {
        _audioBuffer.add(data);
      }
      
      // Live streaming - send each chunk immediately
      if (_isConnected && widget.onLiveChunkReceived != null) {
        // Estimate chunk duration (assuming 48kHz, 16-bit stereo = ~0.17s per 32KB chunk)
        final chunkDuration = data.length / (48000 * 2 * 2); // bytes / (sampleRate * bytesPerSample * channels)
        _liveStreamDuration += chunkDuration;
        _chunkCount++;
        widget.onLiveChunkReceived!(data, _liveStreamDuration);
      }
    });
  }

  @override
  void dispose() {
    _musicService.dispose();
    _promptController.dispose();
    _jsonController.dispose();
    _autoStopTimer?.cancel();
    super.dispose();
  }

  // BG Music segments from story JSON
  List<Map<String, dynamic>> _bgMusicSegments = [];
  bool _isGeneratingAllSegments = false;
  bool _shouldStopGeneration = false; // Flag to stop batch generation
  int _segmentsCompleted = 0;
  
  // Per-segment progress tracking
  List<Map<String, dynamic>> _segmentProgress = []; // [{status, progress, prompt, duration, error}]
  bool _showProgressOverlay = false;
  
  // Auto-stop at duration
  double? _totalDuration; // in seconds, parsed from JSON
  Timer? _autoStopTimer;
  double _elapsedTime = 0;
  
  /// Parse time string like "32s" or "1:30" to seconds
  double _parseTime(String timeStr) {
    timeStr = timeStr.trim().toLowerCase();
    if (timeStr.endsWith('s')) {
      return double.tryParse(timeStr.replaceAll('s', '')) ?? 0;
    }
    if (timeStr.contains(':')) {
      final parts = timeStr.split(':');
      if (parts.length == 2) {
        final mins = int.tryParse(parts[0]) ?? 0;
        final secs = double.tryParse(parts[1]) ?? 0;
        return mins * 60 + secs;
      }
    }
    return double.tryParse(timeStr) ?? 0;
  }
  
  /// Generate all segments in batches with retry logic - NON-BLOCKING
  Future<void> _generateAllSegments() async {
    if (_bgMusicSegments.isEmpty) return;
    
    // Get all available API keys
    final List<String> apiKeys = [];
    
    // Add keys from multipleApiKeys if provided
    if (widget.multipleApiKeys != null && widget.multipleApiKeys!.isNotEmpty) {
      apiKeys.addAll(widget.multipleApiKeys!.where((k) => k.trim().isNotEmpty));
    }
    
    // Add key from controller if not already in list
    final controllerKey = widget.apiKeyController.text.trim();
    if (controllerKey.isNotEmpty && !apiKeys.contains(controllerKey)) {
      apiKeys.insert(0, controllerKey);
    }
    
    if (apiKeys.isEmpty) {
      _showSnack('Please enter at least one API Key');
      return;
    }
    
    // Initialize progress tracking for each segment
    _segmentProgress = _bgMusicSegments.asMap().entries.map((entry) {
      final seg = entry.value;
      final startTime = _parseTime(seg['start_time']?.toString() ?? '0s');
      final endTime = _parseTime(seg['end_time']?.toString() ?? '30s');
      return {
        'index': entry.key,
        'status': 'pending', // pending, generating, success, failed
        'progress': 0.0,
        'prompt': seg['prompt']?.toString() ?? 'Background music',
        'duration': endTime - startTime,
        'collectedDuration': 0.0,
        'error': null,
        'retries': 0,
      };
    }).toList();
    
    // Show progress overlay
    setState(() {
      _showProgressOverlay = true;
      _isGeneratingAllSegments = true;
      _segmentsCompleted = 0;
      _shouldStopGeneration = false;
    });
    
    // START GENERATION IN BACKGROUND (non-blocking)
    _runBackgroundGeneration(apiKeys);
  }
  
  /// Run generation completely in background
  Future<void> _runBackgroundGeneration(List<String> apiKeys) async {
    final maxConcurrent = apiKeys.length.clamp(1, 5);
    
    try {
      // Process all segments with max concurrency
      final semaphore = _Semaphore(maxConcurrent);
      final futures = <Future>[];
      
      for (int i = 0; i < _segmentProgress.length; i++) {
        if (_shouldStopGeneration) break;
        
        futures.add(semaphore.run(() async {
          if (_shouldStopGeneration) return;
          await _generateSingleSegment(i, apiKeys);
        }));
      }
      
      await Future.wait(futures);
      
      _showSnack('Generation complete! ${_segmentsCompleted}/${_bgMusicSegments.length} segments');
    } catch (e) {
      _showSnack('Error: $e');
    } finally {
      if (mounted) {
        setState(() => _isGeneratingAllSegments = false);
      }
    }
  }
  
  /// Generate single segment with retry logic
  Future<void> _generateSingleSegment(int segmentIndex, List<String> apiKeys) async {
    const maxRetries = 7; // Increased for better reliability
    
    final segment = _bgMusicSegments[segmentIndex];
    final startTime = _parseTime(segment['start_time']?.toString() ?? '0s');
    final endTime = _parseTime(segment['end_time']?.toString() ?? '30s');
    final duration = endTime - startTime;
    final prompt = segment['prompt']?.toString() ?? 'Background music';
    
    // Update status to generating
    if (mounted) {
      setState(() {
        _segmentProgress[segmentIndex]['status'] = 'generating';
        _segmentProgress[segmentIndex]['progress'] = 0.0;
      });
    }
    
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      if (_shouldStopGeneration) return;
      
      // Rotate through API keys
      final keyIndex = (segmentIndex + attempt) % apiKeys.length;
      final apiKey = apiKeys[keyIndex];
      
      try {
        if (mounted) {
          setState(() {
            _segmentProgress[segmentIndex]['retries'] = attempt;
          });
        }
        
        // Create service and connect
        final service = LyriaMusicService();
        await service.connect(apiKey);
        await service.setPrompt(prompt);
        await service.setConfig(LyriaConfig(bpm: _bpm, density: _density, brightness: _brightness));
        await service.play();
        
        // Collect audio with progress updates
        final audioBuffer = <Uint8List>[];
        final targetDuration = duration.clamp(5.0, 120.0);
        final bufferDuration = targetDuration * 1.1;
        
        double collectedDuration = 0;
        const bytesPerSecond = 48000 * 2 * 2;
        
        await for (final chunk in service.audioStream) {
          if (_shouldStopGeneration) break;
          
          audioBuffer.add(chunk);
          collectedDuration += chunk.length / bytesPerSecond;
          
          // Update progress
          final progress = (collectedDuration / targetDuration).clamp(0.0, 1.0);
          if (mounted) {
            setState(() {
              _segmentProgress[segmentIndex]['progress'] = progress;
              _segmentProgress[segmentIndex]['collectedDuration'] = collectedDuration;
            });
          }
          
          if (collectedDuration >= bufferDuration) break;
        }
        
        await service.stop();
        service.dispose();
        
        // Save to file with EXACT duration trimming
        if (audioBuffer.isNotEmpty && !_shouldStopGeneration) {
          // Trim audio to EXACT target duration
          const bytesPerSecond = 48000 * 2 * 2; // 48kHz, 16-bit, stereo
          final targetBytes = (targetDuration * bytesPerSecond).round();
          
          // Combine all chunks
          int totalBytes = 0;
          for (var chunk in audioBuffer) totalBytes += chunk.length;
          
          // Calculate how many bytes to actually save (trim excess)
          final bytesToSave = totalBytes > targetBytes ? targetBytes : totalBytes;
          final actualDuration = bytesToSave / bytesPerSecond;
          
          final dir = await getApplicationDocumentsDirectory();
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filePath = '${dir.path}/bgmusic_seg${segmentIndex + 1}_$timestamp.wav';
          final file = File(filePath);
          
          final sink = file.openWrite();
          sink.add(Uint8List(44)); // WAV header placeholder
          
          // Write only the exact amount of bytes needed
          int bytesWritten = 0;
          for (var chunk in audioBuffer) {
            if (bytesWritten >= bytesToSave) break;
            
            final bytesRemaining = bytesToSave - bytesWritten;
            if (chunk.length <= bytesRemaining) {
              // Write entire chunk
              sink.add(chunk);
              bytesWritten += chunk.length;
            } else {
              // Write partial chunk (trim excess)
              sink.add(chunk.sublist(0, bytesRemaining));
              bytesWritten += bytesRemaining;
              break;
            }
          }
          
          await sink.flush();
          await sink.close();
          
          await LyriaAudioUtils.fixWavHeader(file, bytesWritten);
          
          // Notify parent with EXACT duration
          widget.onSegmentGenerated?.call(filePath, startTime, actualDuration, duration);
          
          // Update status to success
          if (mounted) {
            setState(() {
              _segmentProgress[segmentIndex]['status'] = 'success';
              _segmentProgress[segmentIndex]['progress'] = 1.0;
              _segmentProgress[segmentIndex]['collectedDuration'] = actualDuration;
              _segmentsCompleted++;
            });
          }
          return; // Success - exit retry loop
        }
        
        throw Exception('No audio data collected');
      } catch (e) {
        if (attempt >= maxRetries - 1) {
          // Final failure
          if (mounted) {
            setState(() {
              _segmentProgress[segmentIndex]['status'] = 'failed';
              _segmentProgress[segmentIndex]['error'] = e.toString();
              _segmentsCompleted++;
            });
          }
        } else {
          // Retry with delay
          await Future.delayed(Duration(seconds: attempt + 1));
        }
      }
    }
  }
  
  /// Build progress overlay widget (shown in the panel, not blocking)
  Widget _buildProgressOverlay() {
    if (!_showProgressOverlay || _segmentProgress.isEmpty) {
      return const SizedBox.shrink();
    }
    
    // Calculate total duration
    final totalDuration = _segmentProgress.fold<double>(
      0.0,
      (sum, seg) => sum + (seg['duration'] as double? ?? 0.0),
    );
    
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.purple.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with hide/stop buttons
          Row(
            children: [
              Icon(
                _isGeneratingAllSegments ? Icons.auto_awesome : Icons.check_circle,
                color: _isGeneratingAllSegments ? Colors.purple.shade700 : Colors.green.shade700,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isGeneratingAllSegments 
                          ? 'Generating: $_segmentsCompleted/${_segmentProgress.length}'
                          : 'Complete: $_segmentsCompleted/${_segmentProgress.length}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: Colors.purple.shade800,
                      ),
                    ),
                    Text(
                      'Total Duration: ${totalDuration.toStringAsFixed(0)}s',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.purple.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isGeneratingAllSegments)
                TextButton(
                  onPressed: () => setState(() => _shouldStopGeneration = true),
                  child: const Text('Stop', style: TextStyle(fontSize: 10)),
                ),
              TextButton(
                onPressed: () => setState(() => _showProgressOverlay = false),
                child: const Text('Hide', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Overall progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _segmentsCompleted / _segmentProgress.length,
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.purple.shade600),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          
          // Segment list with progress
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _segmentProgress.length,
              itemBuilder: (context, index) {
                final seg = _segmentProgress[index];
                final status = seg['status'] as String;
                final progress = seg['progress'] as double;
                final prompt = seg['prompt'] as String;
                final duration = seg['duration'] as double;
                final collectedDuration = seg['collectedDuration'] as double? ?? 0.0;
                
                Color statusColor;
                IconData statusIcon;
                switch (status) {
                  case 'success':
                    statusColor = Colors.green;
                    statusIcon = Icons.check_circle;
                    break;
                  case 'failed':
                    statusColor = Colors.red;
                    statusIcon = Icons.error;
                    break;
                  case 'generating':
                    statusColor = Colors.orange;
                    statusIcon = Icons.sync;
                    break;
                  default:
                    statusColor = Colors.grey;
                    statusIcon = Icons.pending;
                }
                
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: statusColor.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Segment header
                      Row(
                        children: [
                          Icon(statusIcon, size: 14, color: statusColor),
                          const SizedBox(width: 6),
                          Text(
                            '#${index + 1}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                              color: statusColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              prompt,
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${duration.toStringAsFixed(0)}s',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                          ),
                          
                          // Manual retry button for failed or pending segments
                          if (status == 'failed' || status == 'pending') ...[
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () async {
                                // Get API keys
                                final List<String> apiKeys = [];
                                if (widget.multipleApiKeys != null && widget.multipleApiKeys!.isNotEmpty) {
                                  apiKeys.addAll(widget.multipleApiKeys!.where((k) => k.trim().isNotEmpty));
                                }
                                final controllerKey = widget.apiKeyController.text.trim();
                                if (controllerKey.isNotEmpty && !apiKeys.contains(controllerKey)) {
                                  apiKeys.insert(0, controllerKey);
                                }
                                
                                if (apiKeys.isEmpty) {
                                  _showSnack('Please enter at least one API Key');
                                  return;
                                }
                                
                                // Reset segment state and retry
                                setState(() {
                                  _segmentProgress[index]['status'] = 'pending';
                                  _segmentProgress[index]['progress'] = 0.0;
                                  _segmentProgress[index]['retries'] = 0;
                                  _segmentProgress[index]['error'] = null;
                                });
                                
                                // Start generation for this segment
                                await _generateSingleSegment(index, apiKeys);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(color: Colors.orange.shade300, width: 1),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.refresh, size: 10, color: Colors.orange.shade700),
                                    const SizedBox(width: 2),
                                    Text(
                                      'Retry',
                                      style: TextStyle(
                                        fontSize: 8,
                                        color: Colors.orange.shade700,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      
                      // Show retry count for failed or generating segments
                      if ((status == 'failed' || status == 'generating') && (seg['retries'] as int? ?? 0) > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          status == 'failed' 
                              ? 'Failed after ${seg['retries']} retries'
                              : 'Retry ${seg['retries']}/7',
                          style: TextStyle(
                            fontSize: 8,
                            color: status == 'failed' ? Colors.red.shade600 : Colors.orange.shade600,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                      
                      // Progress bar for generating segments
                      if (status == 'generating') ...[ 
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  backgroundColor: Colors.grey.shade200,
                                  valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                                  minHeight: 4,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${collectedDuration.toStringAsFixed(1)}s',
                              style: TextStyle(fontSize: 9, color: statusColor),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  
  /// Helper to build stat widget
  Widget _buildStat(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
      ],
    );
  }
  
  /// Run generation in background (continues even when switching tabs)
  Future<void> _runGenerationInBackground(
    List<String> apiKeys,
    Function(String) addLog,
    Function() onCompleted,
    Function(int) onFailed,
    Function() onAllComplete,
  ) async {
    setState(() {
      _isGeneratingAllSegments = true;
      _segmentsCompleted = 0;
    });
    
    final maxConcurrent = apiKeys.length.clamp(1, 5);
    _shouldStopGeneration = false;
    
    try {
      final segments = List<Map<String, dynamic>>.from(_bgMusicSegments);
      
      // Process in batches of maxConcurrent
      for (int batchStart = 0; batchStart < segments.length; batchStart += maxConcurrent) {
        if (_shouldStopGeneration) {
          addLog('⏹️ Generation stopped by user');
          break;
        }
        
        final batchEnd = (batchStart + maxConcurrent).clamp(0, segments.length);
        final batch = segments.sublist(batchStart, batchEnd);
        
        addLog('📦 Processing batch ${(batchStart / maxConcurrent).floor() + 1}...');
        
        // Process this batch in parallel
        await Future.wait(batch.asMap().entries.map((entry) async {
          final localIndex = entry.key;
          final globalIndex = batchStart + localIndex;
          final segment = entry.value;
          
          await _generateSegmentWithRetry(
            globalIndex,
            segment,
            apiKeys,
            localIndex,
            addLog,
            onCompleted,
            onFailed,
          );
        }));
      }
      
      addLog('═' * 50);
      addLog('🎉 All segments processed!');
    } catch (e) {
      addLog('❌ Error: $e');
    } finally {
      setState(() => _isGeneratingAllSegments = false);
      onAllComplete();
    }
  }
  
  /// Generate single segment with retry logic (up to 3 attempts, rotating API keys)
  Future<void> _generateSegmentWithRetry(
    int segmentIndex,
    Map<String, dynamic> segment,
    List<String> apiKeys,
    int preferredKeyIndex,
    Function(String) addLog,
    Function() onSuccess,
    Function(int) onFailed,
  ) async {
    const maxRetries = 3;
    int attempt = 0;
    
    final startTime = _parseTime(segment['start_time']?.toString() ?? '0s');
    final endTime = _parseTime(segment['end_time']?.toString() ?? '30s');
    final duration = endTime - startTime;
    final prompt = segment['prompt']?.toString() ?? 'Background music';
    
    addLog('🎵 Segment ${segmentIndex + 1}: ${segment['start_time']} - ${segment['end_time']}');
    
    while (attempt < maxRetries) {
      // Rotate through API keys on each retry
      final keyIndex = (preferredKeyIndex + attempt) % apiKeys.length;
      final apiKey = apiKeys[keyIndex];
      final keyLabel = apiKey.substring(0, 10);
      
      try {
        if (attempt > 0) {
          addLog('  🔄 Retry ${attempt}/${maxRetries - 1} with key ...${keyLabel}');
        } else {
          addLog('  ⚡ Using API key ...${keyLabel}');
        }
        
        // Create service and connect
        final service = LyriaMusicService();
        await service.connect(apiKey);
        await service.setPrompt(prompt);
        await service.setConfig(LyriaConfig(bpm: _bpm, density: _density, brightness: _brightness));
        await service.play();
        
        // Collect audio
        final audioBuffer = <Uint8List>[];
        final targetDuration = duration.clamp(5, 120);
        final bufferDuration = targetDuration * 1.1;
        
        double collectedDuration = 0;
        const bytesPerSecond = 48000 * 2 * 2;
        
        await for (final chunk in service.audioStream) {
          audioBuffer.add(chunk);
          collectedDuration += chunk.length / bytesPerSecond;
          if (collectedDuration >= bufferDuration) break;
        }
        
        await service.stop();
        service.dispose();
        
        // Save to file
        if (audioBuffer.isNotEmpty) {
          final dir = await getApplicationDocumentsDirectory();
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final filePath = '${dir.path}/bgmusic_seg${segmentIndex + 1}_$timestamp.wav';
          final file = File(filePath);
          
          int totalBytes = 0;
          for (var chunk in audioBuffer) totalBytes += chunk.length;
          
          final sink = file.openWrite();
          sink.add(Uint8List(44));
          for (var chunk in audioBuffer) sink.add(chunk);
          await sink.flush();
          await sink.close();
          
          await LyriaAudioUtils.fixWavHeader(file, totalBytes);
          
          // Notify parent
          widget.onSegmentGenerated?.call(filePath, startTime, collectedDuration, duration);
          
          addLog('  ✅ Success! Generated ${collectedDuration.toStringAsFixed(1)}s');
          setState(() => _segmentsCompleted++);
          onSuccess();
          return; // Success - exit retry loop
        }
        
        throw Exception('No audio data collected');
      } catch (e) {
        attempt++;
        onFailed(keyIndex);
        
        if (attempt >= maxRetries) {
          addLog('  ❌ Failed after $maxRetries attempts: $e');
          setState(() => _segmentsCompleted++);
        } else {
          addLog('  ⚠️ Attempt $attempt failed: $e');
          await Future.delayed(Duration(seconds: attempt)); // Backoff delay
        }
      }
    }
  }
  
  /// Import JSON file from file picker
  Future<void> _importJsonFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );
      
      if (result != null && result.files.isNotEmpty) {
        final filePath = result.files.first.path;
        if (filePath != null) {
          final file = File(filePath);
          final jsonText = await file.readAsString();
          
          // Set to controller and parse
          _jsonController.text = jsonText;
          _parseAndApplyJsonText(jsonText);
          
          _showSnack('Imported: ${result.files.first.name}');
        }
      }
    } catch (e) {
      _showSnack('Error importing file: $e');
    }
  }
  
  /// Parse JSON text (reusable for both paste and import)
  void _parseAndApplyJsonText(String jsonText) {
    try {
      final parsed = jsonDecode(jsonText) as Map<String, dynamic>;
      
      // Check for story JSON format with output_structure.bgmusic array
      if (parsed.containsKey('output_structure')) {
        final outputStructure = parsed['output_structure'] as Map<String, dynamic>?;
        if (outputStructure != null && outputStructure.containsKey('bgmusic')) {
          final bgmusicList = outputStructure['bgmusic'] as List?;
          if (bgmusicList != null && bgmusicList.isNotEmpty) {
            _bgMusicSegments = bgmusicList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            
            // Extract total duration from output_structure.duration
            if (outputStructure.containsKey('duration')) {
              _totalDuration = _parseTime(outputStructure['duration'].toString());
            } else {
              // Calculate from last segment's end_time
              final lastSegment = _bgMusicSegments.last;
              _totalDuration = _parseTime(lastSegment['end_time']?.toString() ?? '60s');
            }
            
            // Use first segment's prompt as default
            final firstSegment = _bgMusicSegments.first;
            _promptController.text = firstSegment['prompt']?.toString() ?? 'Background music';
            
            setState(() => _showJsonInput = false);
            _showSnack('Found ${_bgMusicSegments.length} segments (${_totalDuration?.toInt()}s total)');
            return;
          }
        }
      }
      
      // Fallback: Simple config format
      setState(() {
        if (parsed.containsKey('prompt')) {
          _promptController.text = parsed['prompt'].toString();
        }
        if (parsed.containsKey('bpm')) {
          _bpm = (parsed['bpm'] as num).toInt().clamp(60, 200);
        }
        if (parsed.containsKey('density')) {
          _density = (parsed['density'] as num).toDouble().clamp(0.0, 1.0);
        }
        if (parsed.containsKey('brightness')) {
          _brightness = (parsed['brightness'] as num).toDouble().clamp(0.0, 1.0);
        }
        _showJsonInput = false;
        _bgMusicSegments = [];
      });
      
      _showSnack('Config applied from JSON');
      
      if (_isConnected) {
        _updateParams();
      }
    } catch (e) {
      _showSnack('Invalid JSON: $e');
    }
  }
  
  void _parseAndApplyJson() {
    final jsonText = _jsonController.text.trim();
    if (jsonText.isEmpty) {
      _showSnack('Please paste JSON config');
      return;
    }
    _parseAndApplyJsonText(jsonText);
  }
  
  Map<String, dynamic> _parseJson(String text) {
    // Simple JSON parser for our config format
    final result = <String, dynamic>{};
    
    // Remove outer braces and whitespace
    var content = text.trim();
    if (content.startsWith('{')) content = content.substring(1);
    if (content.endsWith('}')) content = content.substring(0, content.length - 1);
    
    // Split by commas (simple approach)
    final regex = RegExp(r'"(\w+)":\s*("([^"]*)"|([\d.]+))');
    for (final match in regex.allMatches(content)) {
      final key = match.group(1)!;
      final strValue = match.group(3); // String value
      final numValue = match.group(4); // Number value
      
      if (strValue != null) {
        result[key] = strValue;
      } else if (numValue != null) {
        result[key] = num.parse(numValue);
      }
    }
    
    return result;
  }

  Future<void> _connectAndPlay() async {
    final apiKey = widget.apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _showSnack('Please enter a Google API Key');
      return;
    }

    setState(() => _status = 'Connecting...');

    try {
      await _musicService.connect(apiKey);
      
      setState(() => _status = 'Setting up...');
      await _musicService.setPrompt(_promptController.text);
      await _musicService.setConfig(LyriaConfig(
        bpm: _bpm,
        density: _density,
        brightness: _brightness,
      ));
      
      await _musicService.play();
      
      // Reset live stream tracking
      _liveStreamDuration = 0.0;
      _chunkCount = 0;
      
      setState(() {
        _isConnected = true;
        _status = 'Streaming Live';
      });
      
      // Notify parent that streaming started
      widget.onStreamStarted?.call();
      
    } catch (e) {
      setState(() {
        _isConnected = false;
        _status = 'Error';
      });
      _showSnack('Connection failed: $e');
    }
  }

  Future<void> _stopAndDisconnect() async {
    try {
      if (_isRecording) {
        await _saveRecording();
      }
      await _musicService.stop();
      // We don't necessarily need to dispose, just stop playback
      // But user might expect disconnect
      // _musicService.dispose(); // Re-connecting requires new socket usually
      // Actually LyriaMusicService.connect checks isConnected
      // Let's just say we stop playback. The service doesn't have a 'disconnect' 
      // other than dispose.
      
      // For full reset:
      _musicService.dispose();
      
      // Notify parent that streaming stopped
      widget.onStreamStopped?.call();
      
    } catch (e) {
      AppLogger.e('Disconnect error: $e');
    } finally {
       setState(() {
        _isConnected = false;
        _isRecording = false;
        _status = 'Ready';
        _liveStreamDuration = 0.0;
        _chunkCount = 0;
      });
    }
  }

  Future<void> _restart() async {
    await _stopAndDisconnect();
    await Future.delayed(const Duration(milliseconds: 500));
    await _connectAndPlay();
  }

  void _toggleRecording() {
    if (_isRecording) {
      _saveRecording();
    } else {
      _startRecording();
    }
  }

  void _startRecording() {
    _audioBuffer.clear();
    setState(() => _isRecording = true);
    _showSnack('Recording started...');
  }

  Future<void> _saveRecording() async {
    setState(() => _isRecording = false);
    
    if (_audioBuffer.isEmpty) {
      _showSnack('No audio captured to save.');
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${dir.path}/lyria_gen_$timestamp.wav';
      final file = File(filePath);
      
      // Calculate total size
      int totalBytes = 0;
      for (var chunk in _audioBuffer) totalBytes += chunk.length;
      
      // Write data (append mode efficiently?)
      // Actually better to openWrite
      final sink = file.openWrite();
      // Leave space for header (44 bytes)
      // We can write a dummy header or just write data then fix it
      // LyriaAudioUtils.fixWavHeader expects just the file with header space?
      // Let's look at utils: it uses RandomAccessFile to write header at pos 0.
      // So we should write 44 bytes of zeros, then data.
      
      sink.add(Uint8List(44)); // Placeholder
      for (var chunk in _audioBuffer) sink.add(chunk);
      await sink.flush();
      await sink.close();
      
      // Fix Header
      await LyriaAudioUtils.fixWavHeader(file, totalBytes);
      
      _lastRecordedFile = filePath;
      widget.onFileSaved?.call(filePath);
      
      _showSnack('Saved: ${path.basename(filePath)}', action: SnackBarAction(
        label: 'Open',
        onPressed: () => launchUrl(Uri.file(filePath)),
      ));
      
    } catch (e) {
      _showSnack('Failed to save recording: $e');
    }
  }

  // --- Parameter Updates ---

  void _updateParams() {
    if (!_isConnected) return;
    // Debounce/Throttle could be good, but direct update for now
    _musicService.setConfig(LyriaConfig(
      bpm: _bpm,
      density: _density,
      brightness: _brightness,
    ));
    _musicService.setPrompt(_promptController.text);
    _showSnack('Parameters updated');
  }

  void _showStoryPromptDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              title: Row(
                children: [
                  Icon(Icons.auto_awesome, color: Colors.blue.shade700, size: 24),
                  const SizedBox(width: 12),
                  const Text('AI Story Music Genius'),
                ],
              ),
              content: SizedBox(
                width: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Paste your story prompts or scene JSON below. Gemini will analyze the flow and create a musical schedule.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _storyPromptController,
                      maxLines: 8,
                      style: GoogleFonts.inter(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Prompt 1: A calm forest...\nPrompt 2: Suddenly a dragon appears!',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text('Duration per Prompt: ', style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        DropdownButton<double>(
                          value: [5.0, 8.0, 10.0, 12.0, 15.0].contains(_durationPerPrompt) ? _durationPerPrompt : 8.0,
                          items: [5.0, 8.0, 10.0, 12.0, 15.0].map((d) => DropdownMenuItem(
                            value: d,
                            child: Text('${d.toInt()}s'),
                          )).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() => _durationPerPrompt = val);
                            }
                          },
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextField(
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Custom Seconds',
                              isDense: true,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onChanged: (val) {
                              final d = double.tryParse(val);
                              if (d != null) {
                                setDialogState(() => _durationPerPrompt = d);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Select AI Model: ', style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: DropdownButton<String>(
                              value: _analysisModel,
                              isExpanded: true,
                              underline: const SizedBox(),
                              items: ['gemini-2.5-flash', 'gemini-3-flash-preview'].map((m) => DropdownMenuItem(
                                value: m,
                                child: Text(m, style: const TextStyle(fontSize: 13)),
                              )).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() => _analysisModel = val);
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Prompt Style: ', style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: DropdownButton<String>(
                              value: _promptStyle,
                              isExpanded: true,
                              underline: const SizedBox(),
                              items: ['Classic', 'Advanced'].map((m) => DropdownMenuItem(
                                value: m,
                                child: Text(m, style: const TextStyle(fontSize: 13)),
                              )).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() => _promptStyle = val);
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _promptStyle == 'Classic' 
                          ? '📝 Classic: Simple prompts describing mood and genre'
                          : '🎵 Advanced: Enhanced prompts with detailed musical elements',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
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
                    final story = _storyPromptController.text.trim();
                    if (story.isEmpty) return;
                    Navigator.pop(context);
                    _analyzeStoryPrompt(story);
                  },
                  icon: const Icon(Icons.psychology, size: 18),
                  label: const Text('Analyze Story'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _analyzeStoryPrompt(String story) async {
    final apiKey = widget.apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      _showSnack('Please enter a Gemini API Key first');
      return;
    }

    setState(() => _isAnalyzingStory = true);
    _showSnack('Thinking... Analyzing musical vibes');

    try {
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$_analysisModel:generateContent?key=$apiKey',
      );

      // Classic prompt (simpler, generic)
      final classicPrompt = """
You are an AI music supervisor. Analyze the following story prompts and generate a background music plan in JSON format.
Each distinct line or object in the input represents exactly $_durationPerPrompt seconds of video time.
Total video duration is (number_of_prompts * $_durationPerPrompt) seconds.

The output MUST be exactly a JSON object with this structure:
{
  "output_structure": {
    "duration": "TOTAL_DURATIONs",
    "bgmusic": [
      {
        "start_time": "0s",
        "end_time": "30s",
        "prompt": "detailed musical description based on scene vibe, complexity, and mood"
      },
      ...
    ]
  }
}

Guidelines:
1. Detect changes in mood, location, or intensity from the story prompts.
2. Segment the music intelligently:
   - If the mood is consistent, one segment can cover up to 60s.
   - If the mood changes, start a new segment at the appropriate timestamp (e.g., "16s").
   - Max segment duration is 60s.
3. Each distinct visual prompt provided represents exactly $_durationPerPrompt seconds.
4. "end_time" of one segment MUST be the "start_time" of the next.
5. Total duration MUST match the total sum of durations of all story prompts (\$story_duration).
6. Provide high-quality prompts for music generation (BPM, instruments, genre, mood).
""";

      // Lyria Optimized prompt (uses official Lyria keywords)
      final lyriaOptimizedPrompt = """
You are an expert AI music supervisor for Lyria RealTime music generation. Analyze the story prompts and generate a background music plan in JSON format.

Each distinct line or object in the input represents exactly $_durationPerPrompt seconds of video time.
Total video duration is (number_of_prompts * $_durationPerPrompt) seconds.

The output MUST be exactly a JSON object with this structure:
{
  "output_structure": {
    "duration": "TOTAL_DURATIONs",
    "bgmusic": [
      {
        "start_time": "0s",
        "end_time": "30s",
        "prompt": "detailed Lyria-optimized musical description"
      },
      ...
    ]
  }
}

##CRITICAL: LYRIA PROMPT OPTIMIZATION##

Each prompt MUST combine keywords from these categories for optimal music quality:

**INSTRUMENTS (choose 2-4 that match the scene)**:
808 Hip Hop Beat, Accordion, Alto Saxophone, Banjo, Bass Clarinet, Bongos, Boomy Bass, Cello, Charango, Clavichord, Conga Drums, Didgeridoo, Dirty Synths, Djembe, Drumline, Dulcimer, Fiddle, Flamenco Guitar, Funk Drums, Glockenspiel, Guitar, Hang Drum, Harmonica, Harp, Harpsichord, Hurdy-gurdy, Kalimba, Koto, Lyre, Mandolin, Marimba, Mbira, Mellotron, Metallic Twang, Moog Oscillations, Ocarina, Pipa, Precision Bass, Ragtime Piano, Rhodes Piano, Shamisen, Shredding Guitar, Sitar, Slide Guitar, Smooth Pianos, Spacey Synths, Steel Drum, Synth Pads, Tabla, TR-909 Drum Machine, Trumpet, Tuba, Vibraphone, Viola Ensemble, Warm Acoustic Guitar, Woodwinds

**GENRES (choose 1-2 that match the mood)**:
Acid Jazz, Afrobeat, Alternative Country, Baroque, Bluegrass, Blues Rock, Bossa Nova, Breakbeat, Celtic Folk, Chillout, Classic Rock, Contemporary R&B, Cumbia, Deep House, Disco Funk, Drum & Bass, Dubstep, EDM, Electro Swing, Funk Metal, Garage Rock, Glitch Hop, Hyperpop, Indian Classical, Indie Electronic, Indie Folk, Indie Pop, Irish Folk, Jam Band, Jamaican Dub, Jazz Fusion, Latin Jazz, Lo-Fi Hip Hop, Marching Band, Minimal Techno, Neo-Soul, Orchestral Score, Piano Ballad, Post-Punk, Psytrance, R&B, Reggae, Reggaeton, Salsa, Shoegaze, Ska, Surf Rock, Synthpop, Techno, Trance, Trap Beat, Trip Hop, Vaporwave

**MOOD/DESCRIPTION (choose 2-4 that match the scene emotion)**:
Acoustic Instruments, Ambient, Bright Tones, Chill, Crunchy Distortion, Danceable, Dreamy, Echo, Emotional, Ethereal Ambience, Experimental, Fat Beats, Funky, Glitchy Effects, Huge Drop, Live Performance, Lo-fi, Ominous Drone, Psychedelic, Rich Orchestration, Saturated Tones, Subdued Melody, Sustained Chords, Swirling Phasers, Tight Groove, Unsettling, Upbeat, Virtuoso, Weird Noises

##PROMPT STRUCTURE##
Each prompt should follow this format:
"[Genre(s)], [Instrument(s)], [Mood/Description keywords], [any specific scene context]"

Examples of GOOD prompts:
- "Orchestral Score, Cello, Viola Ensemble, Emotional, Rich Orchestration, Sustained Chords, epic cinematic moment"
- "Lo-Fi Hip Hop, Rhodes Piano, Smooth Pianos, Chill, Dreamy, Lo-fi, relaxed afternoon vibes"
- "Deep House, TR-909 Drum Machine, Synth Pads, Danceable, Tight Groove, Fat Beats, club scene"
- "Celtic Folk, Fiddle, Mandolin, Acoustic Instruments, Upbeat, Live Performance, festive celebration"
- "Minimal Techno, Moog Oscillations, Dirty Synths, Ominous Drone, Unsettling, dark tension building"
- "Jazz Fusion, Alto Saxophone, Rhodes Piano, Funk Drums, Virtuoso, Funky, sophisticated night scene"
- "Indie Electronic, Spacey Synths, Glitchy Effects, Ethereal Ambience, Dreamy, futuristic atmosphere"
- "Trap Beat, 808 Hip Hop Beat, Boomy Bass, Fat Beats, Crunchy Distortion, intense action sequence"

##Guidelines##:
1. Detect changes in mood, location, or intensity from the story prompts.
2. Segment the music intelligently:
   - If the mood is consistent, one segment can cover up to 60s.
   - If the mood changes dramatically, start a new segment at the appropriate timestamp.
   - Max segment duration is 60s.
3. Each distinct visual prompt represents exactly $_durationPerPrompt seconds.
4. "end_time" of one segment MUST be the "start_time" of the next.
5. Total duration MUST match \$story_duration.
6. ALWAYS use at least 3 Lyria keywords (instrument, genre, mood) per prompt for best quality.
7. Add scene context at the end for better AI understanding.
""";
      
      // Select prompt based on user preference
      final systemPrompt = _promptStyle == 'Classic' ? classicPrompt : lyriaOptimizedPrompt;

      // Calculate approximate duration for Gemini instruction
      int promptCount = story.split('\n').where((l) => l.trim().length > 5).length;
      try {
        final maybeJson = jsonDecode(story);
        if (maybeJson is List) {
          promptCount = maybeJson.length;
        } else if (maybeJson is Map && maybeJson.containsKey('prompts')) {
           promptCount = (maybeJson['prompts'] as List).length;
        } else if (maybeJson is Map && maybeJson.containsKey('output_structure')) {
           // If it's already a story JSON, count bgmusic segments or duration
           final output = maybeJson['output_structure'];
           if (output is Map && output.containsKey('bgmusic')) {
             promptCount = (output['bgmusic'] as List).length;
           }
        }
      } catch (_) {}
      final totalSecs = (promptCount * _durationPerPrompt).toInt();

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': '${systemPrompt.replaceAll('\$story_duration', '${totalSecs}s')}\n\n#### STORY INPUT\n$story'}
              ]
            }
          ],
          'generationConfig': {
             'responseMimeType': 'application/json',
          }
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final candidates = data['candidates'] as List?;
        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List?;
          if (parts != null && parts.isNotEmpty) {
            final resultText = parts[0]['text'] as String?;
            if (resultText != null) {
              _parseAndApplyJsonText(resultText);
              _jsonController.text = resultText;
            }
          }
        }
      } else {
        throw Exception('Gemini API Error: ${response.statusCode}');
      }
    } catch (e) {
      _showSnack('Analysis failed: $e');
    } finally {
      setState(() => _isAnalyzingStory = false);
    }
  }

  void _showSnack(String msg, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
      action: action,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      child: Column(
        children: [
          // Header Bar
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                children: [
                  // Expand Icon
                  Icon(
                    _isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: Colors.blue.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 10),

                  // Start/Stop Button
                  ElevatedButton(
                    onPressed: _isConnected ? _stopAndDisconnect : _connectAndPlay,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isConnected ? Colors.red.shade400 : Colors.blue.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_isConnected ? Icons.stop : Icons.play_arrow, size: 16),
                        const SizedBox(width: 4),
                        Text(_isConnected ? 'Stop' : 'Start', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Restart Button
                  if (_isConnected)
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: _restart,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      color: Colors.blue.shade600,
                      tooltip: 'Restart Stream',
                    ),
                  
                  const Spacer(),
                  
                  // Title & Status
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'AI Music',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.blue.shade900,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: _isConnected ? Colors.green : Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _status,
                              style: TextStyle(fontSize: 10, color: Colors.blue.shade700),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Expanded Controls - Scrollable
          if (_isExpanded)
            Flexible(
              child: SingleChildScrollView(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  color: Colors.blue.shade50.withOpacity(0.3),
                  child: Column(
                children: [
                  // Show progress overlay at TOP when generating
                  _buildProgressOverlay(),
                  
                  // Primary Action: Story Prompt
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ElevatedButton.icon(
                      onPressed: _isAnalyzingStory ? null : _showStoryPromptDialog,
                      icon: _isAnalyzingStory 
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.auto_stories, size: 20),
                      label: Text(_isAnalyzingStory ? 'Analyzing Story...' : 'Generate from Story Prompt'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 2,
                      ),
                    ),
                  ),

                  // Secondary Options
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () => setState(() => _showJsonInput = !_showJsonInput),
                        icon: Icon(_showJsonInput ? Icons.close : Icons.code, size: 16),
                        label: Text(_showJsonInput ? 'Hide JSON' : 'Paste JSON'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.blue.shade700,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _importJsonFile,
                        icon: const Icon(Icons.file_upload, size: 16),
                        label: const Text('Import JSON'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.purple.shade700,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      if (!_showJsonInput && _bgMusicSegments.isEmpty)
                        Text(
                          'Or configure manually',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                        ),
                    ],
                  ),
                  
                  // JSON Input Area
                  if (_showJsonInput) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _jsonController,
                      maxLines: 4,
                      style: GoogleFonts.firaCode(fontSize: 11, color: Colors.blue.shade900),
                      decoration: InputDecoration(
                        labelText: 'Paste JSON Config',
                        hintText: '{"prompt": "...", "bpm": 120, "density": 0.5, "brightness": 0.5}',
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _parseAndApplyJson,
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text('Apply JSON'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade600,
                            foregroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () {
                            _jsonController.clear();
                            setState(() => _showJsonInput = false);
                          },
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('Cancel'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Divider(color: Colors.grey.shade300),
                  ],
                  
                  const SizedBox(height: 8),
                  
                  // Prompt Input
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _promptController,
                          style: GoogleFonts.inter(color: Colors.blue.shade900, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: 'Music Prompt',
                            hintText: 'Describe output...',
                            isDense: true,
                            prefixIcon: const Icon(Icons.edit, size: 16),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          onSubmitted: (_) => _updateParams(),
                        ),
                      ),
                      if (_isConnected)
                        IconButton(
                          icon: const Icon(Icons.send, size: 18),
                          onPressed: _updateParams,
                          tooltip: 'Update Prompt',
                          color: Colors.blue.shade600,
                        ),
                    ],
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Sliders Row
                  Row(
                    children: [
                      Expanded(child: _buildSlider('BPM', _bpm.toDouble(), 60, 200, 140, (v) {
                        setState(() => _bpm = v.toInt());
                      })),
                      const SizedBox(width: 8),
                      Expanded(child: _buildSlider('Density', _density, 0, 1, 10, (v) {
                        setState(() => _density = v);
                      })),
                      const SizedBox(width: 8),
                      Expanded(child: _buildSlider('Bright', _brightness, 0, 1, 10, (v) {
                        setState(() => _brightness = v);
                      })),
                    ],
                  ),
                  
                  if (_isConnected)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                         child: OutlinedButton(
                           onPressed: _updateParams,
                           style: OutlinedButton.styleFrom(
                             visualDensity: VisualDensity.compact,
                             side: BorderSide(color: Colors.blue.shade200),
                           ),
                           child: const Text('Apply Settings', style: TextStyle(fontSize: 11)),
                         )
                      ),
                    ),

                  const SizedBox(height: 16),
                  
                  // Recording Controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isConnected ? _toggleRecording : null,
                        icon: Icon(_isRecording ? Icons.stop_circle : Icons.fiber_manual_record, size: 16),
                        label: Text(_isRecording ? 'Stop Recording (Save)' : 'Record to Timeline'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isRecording ? Colors.red : Colors.green.shade600,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  
                  // Show Generate All Segments button if segments are detected
                  if (_bgMusicSegments.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.purple.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.purple.shade200),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(Icons.music_note, size: 18, color: Colors.purple.shade700),
                              const SizedBox(width: 8),
                              Text(
                                '${_bgMusicSegments.length} Music Segments Detected',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.purple.shade800,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Show segments list
                          ...(_bgMusicSegments.take(3).map((seg) => Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Text(
                                  '${seg['start_time']} - ${seg['end_time']}',
                                  style: TextStyle(fontSize: 10, color: Colors.purple.shade600, fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    seg['prompt']?.toString() ?? '',
                                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ))),
                          if (_bgMusicSegments.length > 3)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '... and ${_bgMusicSegments.length - 3} more',
                                style: TextStyle(fontSize: 10, color: Colors.grey.shade500, fontStyle: FontStyle.italic),
                              ),
                            ),
                          const SizedBox(height: 8),
                          // Copy JSON Button
                          OutlinedButton.icon(
                            onPressed: () async {
                              if (_jsonController.text.isNotEmpty) {
                                await Clipboard.setData(ClipboardData(text: _jsonController.text));
                                _showSnack('JSON copied to clipboard!');
                              }
                            },
                            icon: Icon(Icons.copy, size: 14, color: Colors.purple.shade700),
                            label: Text('Copy JSON', style: TextStyle(fontSize: 11, color: Colors.purple.shade700)),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: Colors.purple.shade300),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              minimumSize: Size.zero,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _isGeneratingAllSegments ? null : _generateAllSegments,
                            icon: _isGeneratingAllSegments 
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.auto_awesome, size: 16),
                            label: Text(_isGeneratingAllSegments 
                                ? 'Generating... ($_segmentsCompleted/${_bgMusicSegments.length})'
                                : 'Generate All Segments'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purple.shade600,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          if (_isGeneratingAllSegments) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  setState(() => _shouldStopGeneration = true);
                                  _showSnack('Stopping after current batch...');
                                },
                                icon: const Icon(Icons.stop, size: 16),
                                label: const Text('Stop Generation'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red.shade600,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        ],
      ),
    );
  }

  Widget _buildSlider(String label, double val, double min, double max, int div, ValueChanged<double> onChanged) {
    return Column(
      children: [
        Text('$label: ${label == 'BPM' ? val.toInt() : val.toStringAsFixed(1)}', 
             style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
            ),
            child: Slider(
              value: val,
              min: min,
              max: max,
              divisions: div,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// Semaphore for controlling concurrent tasks
class _Semaphore {
  final int maxConcurrent;
  int _currentCount = 0;
  final List<Completer<void>> _waiters = [];
  
  _Semaphore(this.maxConcurrent);
  
  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }
  
  Future<void> _acquire() async {
    if (_currentCount < maxConcurrent) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }
  
  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _currentCount--;
    }
  }
}
