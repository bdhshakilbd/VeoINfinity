/// Video Mastering Service
/// FFmpeg-based video processing for editing operations and export

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'dart:ui'; // For Color
import '../models/video_mastering/video_project.dart';
import '../widgets/video_mastering/mastering_console_widget.dart';
import 'package:veo3_another/utils/ffmpeg_utils.dart'; // Centralized FFmpeg path resolution

// Mobile FFmpeg imports (conditionally used)
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';

/// Export task information
class ExportTask {
  final String taskId;
  final String projectName;
  final String outputPath;
  final DateTime startTime;
  double progress;
  String status;
  String? errorMessage;
  Process? process;
  bool isRunning;

  ExportTask({
    required this.taskId,
    required this.projectName,
    required this.outputPath,
    required this.startTime,
    this.progress = 0.0,
    this.status = 'Starting...',
    this.errorMessage,
    this.process,
    this.isRunning = true,
  });
}

/// Video information extracted from file
class VideoInfo {
  final double duration;
  final int width;
  final int height;
  final double fps;
  final String codec;
  final int bitrate;
  final bool hasAudio;

  VideoInfo({
    required this.duration,
    required this.width,
    required this.height,
    required this.fps,
    required this.codec,
    required this.bitrate,
    required this.hasAudio,
  });
}

/// Audio information
class AudioInfo {
  final double duration;
  final int sampleRate;
  final int channels;
  final String codec;

  AudioInfo({
    required this.duration,
    required this.sampleRate,
    required this.channels,
    required this.codec,
  });
}

/// Video Mastering Service - Handles all FFmpeg operations
class VideoMasteringService {
  // Singleton pattern
  static final VideoMasteringService _instance = VideoMasteringService._internal();
  factory VideoMasteringService() => _instance;
  VideoMasteringService._internal();

  // Active export tasks
  final Map<String, ExportTask> _activeTasks = {};
  final StreamController<List<ExportTask>> _tasksController = StreamController<List<ExportTask>>.broadcast();

  // Log file for debugging
  File? _logFile;
  IOSink? _logSink;

  /// Stream of active export tasks
  Stream<List<ExportTask>> get tasksStream => _tasksController.stream;

  /// Get current active tasks
  List<ExportTask> get activeTasks => _activeTasks.values.toList();

  /// Write to log file
  Future<void> _log(String message) async {
    final timestamp = DateTime.now().toIso8601String();
    final logMessage = '[$timestamp] $message';
    print(logMessage); // Also print to console
    
    try {
      if (_logFile == null) {
        final tempDir = await _getTempDir();
        _logFile = File(path.join(tempDir.path, 'export_debug.log'));
        _logSink = _logFile!.openWrite(mode: FileMode.append);
      }
      _logSink?.writeln(logMessage);
      await _logSink?.flush();
    } catch (e) {
      print('[LOG ERROR] Failed to write to log file: $e');
    }
  }

  /// Cancel export task
  Future<void> cancelTask(String taskId) async {
    final task = _activeTasks[taskId];
    if (task != null && task.process != null) {
      print('[VideoMasteringService] Cancelling task: $taskId');
      task.process!.kill();
      task.isRunning = false;
      task.status = 'Cancelled';
      _activeTasks.remove(taskId);
      _tasksController.add(activeTasks);
    }
  }

  /// Update task progress
  void _updateTaskProgress(String taskId, double progress, String status) {
    final task = _activeTasks[taskId];
    if (task != null) {
      task.progress = progress;
      task.status = status;
      _tasksController.add(activeTasks);
    }
  }

  /// Complete task
  void _completeTask(String taskId, {String? error}) {
    final task = _activeTasks[taskId];
    if (task != null) {
      task.isRunning = false;
      task.progress = error != null ? task.progress : 1.0;
      task.status = error != null ? 'Failed' : 'Completed';
      task.errorMessage = error;
      _tasksController.add(activeTasks);
      
      // Remove completed task after 5 seconds
      Future.delayed(const Duration(seconds: 5), () {
        _activeTasks.remove(taskId);
        _tasksController.add(activeTasks);
      });
    }
  }

  /// Get FFmpeg path - robust lookup via FFmpegUtils
  Future<String> _getFFmpegPath() async {
    if (Platform.isAndroid || Platform.isIOS) return 'ffmpeg';
    return await FFmpegUtils.getFFmpegPath();
  }

  /// Get FFprobe path - robust lookup via FFmpegUtils
  Future<String> _getFFprobePath() async {
    if (Platform.isAndroid || Platform.isIOS) return 'ffprobe';
    return await FFmpegUtils.getFFprobePath();
  }

  /// Get encoding preset based on resolution
  /// Uses ultrafast for 4K/2K, veryfast for 1080p/720p
  String _getEncodingPreset(int width, int height) {
    // 4K: 3840x2160 or higher
    // 2K: 2560x1440 or similar (1440p)
    if (width >= 2560 || height >= 1440) {
      return 'ultrafast';
    }
    // 1080p and 720p use veryfast for faster encoding
    return 'veryfast';
  }

  /// Get temporary directory for processing
  Future<Directory> _getTempDir() async {
    final appDir = await getTemporaryDirectory();
    final tempDir = Directory(path.join(appDir.path, 'video_mastering_temp'));
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    return tempDir;
  }

  /// Run FFmpeg command (handles both mobile and desktop)
  /// [expectedDuration] - Optional: the expected output duration in seconds for accurate progress calculation
  Future<bool> _runFFmpeg(List<String> args, {Function(double time, {double? percent, double? fps, double? speed, String? eta})? onProgress, String? taskId, double? expectedDuration}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Use FFmpegKit for mobile
      // Auto-quote arguments with spaces or special chars if they aren't already quoted
      final command = args.map((a) {
        if ((a.contains(' ') || a.contains(';') || a.contains('[') || a.contains(']')) && 
            !a.startsWith('"') && !a.startsWith("'")) {
          return '"$a"';
        }
        return a;
      }).join(' ');
      
      print('[FFMPEG] Running: $command');
      
      if (onProgress != null) {
        FFmpegKitConfig.enableStatisticsCallback((statistics) {
          final time = statistics.getTime();
          if (time > 0) {
            onProgress(time / 1000.0);
          }
        });
      }
      
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        return true;
      } else {
        final output = await session.getOutput();
        print('[FFMPEG] Error: $output');
        return false;
      }
    } else {
      // Desktop: Use Process.start for real-time progress monitoring
      final ffmpegPath = await _getFFmpegPath();
      // Build a fully-quoted command string for easy copy/paste into CMD
      final quotedArgs = args.map((a) {
        // If already quoted, leave as-is
        if ((a.startsWith('"') && a.endsWith('"')) || (a.startsWith("'") && a.endsWith("'"))) return a;
        // Quote args that contain spaces or special chars
        if (a.contains(' ') || a.contains(';') || a.contains('[') || a.contains(']')) return '"$a"';
        return a;
      }).join(' ');
      final commandLine = '"$ffmpegPath" $quotedArgs';
      
      await _log('========== FFMPEG COMMAND START ==========');
      await _log('Command: $commandLine');
      print('[FFMPEG] Command: $commandLine');

      // Also persist the command to a temporary log for inspection
      try {
        final tempDir = await _getTempDir();
        final cmdLog = File(path.join(tempDir.path, 'last_ffmpeg_command.txt'));
        await cmdLog.writeAsString(commandLine);
      } catch (e) {
        // ignore write failures
      }

      final process = await Process.start(ffmpegPath, args, runInShell: false);
      final startTime = DateTime.now();
      
      // Store process in task if taskId provided
      if (taskId != null) {
        final task = _activeTasks[taskId];
        if (task != null) {
          task.process = process;
        }
      }
      
      String errorOutput = '';
      // Use expectedDuration if provided, otherwise try to parse from FFmpeg output
      double? duration = expectedDuration;
      
      // Parse stderr for progress (FFmpeg outputs progress to stderr)
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        errorOutput += '$line\n';
        // Stream all FFmpeg log lines to the main terminal, log file, and console widget
        print('[FFMPEG] $line');
        MasteringConsole.ffmpeg(line);
        _log('FFMPEG: $line'); // Log to file (don't await to avoid blocking)

        // Parse Duration from initial output: Duration: 00:01:23.45, (note: FFmpeg includes comma after duration)
        // Only parse if we don't have an expectedDuration provided
        if (duration == null && line.contains('Duration:') && !line.contains('Duration: N/A')) {
          // Improved regex that handles optional comma and whitespace after the duration
          final durationMatch = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(line);
          if (durationMatch != null) {
            final hours = int.parse(durationMatch.group(1)!);
            final minutes = int.parse(durationMatch.group(2)!);
            final seconds = double.parse(durationMatch.group(3)!);
            duration = hours * 3600 + minutes * 60 + seconds;
            print('[FFMPEG] Parsed total duration: \u001b[36m${duration!.toStringAsFixed(2)}s\u001b[0m');
          }
        }

        // Parse progress: frame=  123 fps= 30 q=28.0 size=    1024kB time=00:00:05.00 bitrate=1234.5kbits/s speed=1.5x
        if (line.contains('time=') && onProgress != null) {
          // Improved time regex to handle various formats
          final timeMatch = RegExp(r'time=\s*(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(line);
          final fpsMatch = RegExp(r'fps=\s*(\d+(?:\.\d+)?)').firstMatch(line);
          // Improved speed regex to handle 0.xxx format, negative values, and N/A
          final speedMatch = RegExp(r'speed=\s*(-?\d*\.?\d+)x').firstMatch(line);
          final frameMatch = RegExp(r'frame=\s*(\d+)').firstMatch(line);

          if (timeMatch != null) {
            final hours = int.parse(timeMatch.group(1)!);
            final minutes = int.parse(timeMatch.group(2)!);
            final seconds = double.parse(timeMatch.group(3)!);
            final currentTime = hours * 3600 + minutes * 60 + seconds;

            final fps = fpsMatch != null ? double.tryParse(fpsMatch.group(1)!) : null;
            // Only use speed if it's a valid positive number
            double? speed;
            if (speedMatch != null) {
              final parsedSpeed = double.tryParse(speedMatch.group(1)!);
              if (parsedSpeed != null && parsedSpeed > 0) {
                speed = parsedSpeed;
              }
            }
            final frame = frameMatch != null ? int.tryParse(frameMatch.group(1)!) : null;

            // Calculate percentage and ETA
            double? percent;
            String? etaStr;

            // Use duration for progress calculation (either provided or parsed)
            final effectiveDuration = duration ?? expectedDuration;
            if (effectiveDuration != null && effectiveDuration > 0) {
              percent = (currentTime / effectiveDuration).clamp(0.0, 1.0);
            }

            // Calculate ETA based on speed (most reliable method)
            if (effectiveDuration != null && effectiveDuration > 0) {
              if (speed != null && speed > 0) {
                // Speed-based ETA: remaining time / encoding speed
                final remaining = effectiveDuration - currentTime;
                if (remaining > 0) {
                  final eta = remaining / speed;
                  final etaMinutes = (eta / 60).floor();
                  final etaSeconds = (eta % 60).floor();
                  if (etaMinutes > 0) {
                    etaStr = '${etaMinutes}m ${etaSeconds}s';
                  } else if (etaSeconds > 0) {
                    etaStr = '${etaSeconds}s';
                  }
                }
              } else if (fps != null && fps > 0 && frame != null) {
                // Frame-based ETA as fallback
                final totalFrames = (effectiveDuration * fps).round();
                final remainingFrames = (totalFrames - frame).clamp(0, totalFrames);
                if (remainingFrames > 0) {
                  final etaSeconds = remainingFrames / fps;
                  final etaMinutes = (etaSeconds / 60).floor();
                  final etaRemSeconds = (etaSeconds % 60).floor();
                  if (etaMinutes > 0) {
                    etaStr = '${etaMinutes}m ${etaRemSeconds}s';
                  } else if (etaRemSeconds > 0) {
                    etaStr = '${etaRemSeconds}s';
                  }
                }
              }
            }
            
            // Fallback: use elapsed time proportion method
            if (etaStr == null && percent != null && percent > 0.01) {
              final elapsedSeconds = DateTime.now().difference(startTime).inSeconds;
              if (elapsedSeconds > 2) {  // Need at least 2 seconds of data
                final estimatedTotal = elapsedSeconds / percent;
                final remainingSeconds = (estimatedTotal - elapsedSeconds).round();
                if (remainingSeconds > 0) {
                  final etaMinutes = remainingSeconds ~/ 60;
                  final etaRemSeconds = remainingSeconds % 60;
                  if (etaMinutes > 0) {
                    etaStr = '~${etaMinutes}m ${etaRemSeconds}s';
                  } else {
                    etaStr = '~${etaRemSeconds}s';
                  }
                }
              }
            }

            print('[FFMPEG] Progress: ${currentTime.toStringAsFixed(1)}s / ${effectiveDuration?.toStringAsFixed(1) ?? '?'}s | ${percent != null ? '${(percent * 100).toStringAsFixed(1)}%' : '?'} | FPS: ${fps?.toStringAsFixed(1) ?? '?'} | Frame: ${frame ?? '?'} | Speed: ${speed?.toStringAsFixed(2) ?? '?'}x${etaStr != null ? ' | ETA: $etaStr' : ''}');
            onProgress(currentTime, percent: percent, fps: fps, speed: speed, eta: etaStr);
          }
        }
      });
      
      // Consume stdout to prevent blocking
      process.stdout.listen((_) {});
      
      final exitCode = await process.exitCode;
      
      await _log('FFMPEG Exit Code: $exitCode');
      
      if (exitCode == 0) {
        await _log('========== FFMPEG COMMAND SUCCESS ==========');
        return true;
      } else {
        await _log('========== FFMPEG COMMAND FAILED ==========');
        await _log('Error Output:\n$errorOutput');
        print('[FFMPEG] Error: $errorOutput');
        return false;
      }
    }
  }

  /// Get video information
  Future<VideoInfo?> getVideoInfo(String videoPath) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final session = await FFprobeKit.getMediaInformation(videoPath);
        final info = session.getMediaInformation();
        
        if (info == null) return null;
        
        final streams = info.getStreams();
        Map<String, dynamic>? videoStream;
        bool hasAudio = false;
        
        for (var stream in streams) {
          final props = stream.getAllProperties();
          if (props?['codec_type'] == 'video' && videoStream == null) {
            videoStream = Map<String, dynamic>.from(props!);
          }
          if (props?['codec_type'] == 'audio') {
            hasAudio = true;
          }
        }
        
        if (videoStream == null) return null;
        
        final durationStr = info.getDuration() ?? '0';
        final duration = double.tryParse(durationStr) ?? 0;
        
        return VideoInfo(
          duration: duration,
          width: videoStream['width'] ?? 0,
          height: videoStream['height'] ?? 0,
          fps: _parseFps(videoStream['r_frame_rate'] ?? '30/1'),
          codec: videoStream['codec_name'] ?? 'unknown',
          bitrate: int.tryParse(info.getBitrate() ?? '0') ?? 0,
          hasAudio: hasAudio,
        );
      } else {
        // Desktop: Use ffprobe
        final ffprobePath = await _getFFprobePath();
        final result = await Process.run(ffprobePath, [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_format',
          '-show_streams',
          videoPath,
        ], runInShell: true);
        
        if (result.exitCode != 0) return null;
        
        final json = jsonDecode(result.stdout);
        final format = json['format'] ?? {};
        final streams = json['streams'] as List? ?? [];
        
        Map<String, dynamic>? videoStream;
        bool hasAudio = false;
        
        for (var stream in streams) {
          if (stream['codec_type'] == 'video' && videoStream == null) {
            videoStream = stream;
          }
          if (stream['codec_type'] == 'audio') {
            hasAudio = true;
          }
        }
        
        if (videoStream == null) return null;
        
        return VideoInfo(
          duration: double.tryParse(format['duration'] ?? '0') ?? 0,
          width: videoStream['width'] ?? 0,
          height: videoStream['height'] ?? 0,
          fps: _parseFps(videoStream['r_frame_rate'] ?? '30/1'),
          codec: videoStream['codec_name'] ?? 'unknown',
          bitrate: int.tryParse(format['bit_rate'] ?? '0') ?? 0,
          hasAudio: hasAudio,
        );
      }
    } catch (e) {
      print('[VideoMasteringService] getVideoInfo error: $e');
      return null;
    }
  }

  /// Get audio information
  Future<AudioInfo?> getAudioInfo(String audioPath) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final session = await FFprobeKit.getMediaInformation(audioPath);
        final info = session.getMediaInformation();
        
        if (info == null) return null;
        
        final streams = info.getStreams();
        Map<String, dynamic>? audioStream;
        
        for (var stream in streams) {
          final props = stream.getAllProperties();
          if (props?['codec_type'] == 'audio') {
            audioStream = Map<String, dynamic>.from(props!);
            break;
          }
        }
        
        if (audioStream == null) return null;
        
        return AudioInfo(
          duration: double.tryParse(info.getDuration() ?? '0') ?? 0,
          sampleRate: audioStream['sample_rate'] ?? 44100,
          channels: audioStream['channels'] ?? 2,
          codec: audioStream['codec_name'] ?? 'unknown',
        );
      } else {
        final ffprobePath = await _getFFprobePath();
        final result = await Process.run(ffprobePath, [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_format',
          '-show_streams',
          audioPath,
        ], runInShell: true);
        
        if (result.exitCode != 0) return null;
        
        final json = jsonDecode(result.stdout);
        final format = json['format'] ?? {};
        final streams = json['streams'] as List? ?? [];
        
        Map<String, dynamic>? audioStream;
        for (var stream in streams) {
          if (stream['codec_type'] == 'audio') {
            audioStream = stream;
            break;
          }
        }
        
        if (audioStream == null) return null;
        
        return AudioInfo(
          duration: double.tryParse(format['duration'] ?? '0') ?? 0,
          sampleRate: int.tryParse(audioStream['sample_rate'] ?? '44100') ?? 44100,
          channels: audioStream['channels'] ?? 2,
          codec: audioStream['codec_name'] ?? 'unknown',
        );
      }
    } catch (e) {
      print('[VideoMasteringService] getAudioInfo error: $e');
      return null;
    }
  }

  /// Extract thumbnail from video at specific timestamp
  Future<String?> extractThumbnail(String videoPath, double timestamp, {String? outputPath}) async {
    try {
      final tempDir = await _getTempDir();
      final output = outputPath ?? 
          path.join(tempDir.path, 'thumb_${DateTime.now().millisecondsSinceEpoch}.jpg');
      
      final success = await _runFFmpeg([
        '-ss', timestamp.toStringAsFixed(3),
        '-i', videoPath,
        '-vframes', '1',
        '-q:v', '2',
        '-y',
        output,
      ]);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] extractThumbnail error: $e');
      return null;
    }
  }

  /// Cut a clip from video
  Future<String?> cutClip(String inputPath, double startTime, double endTime, {String? outputPath}) async {
    try {
      final tempDir = await _getTempDir();
      final ext = path.extension(inputPath);
      final output = outputPath ?? 
          path.join(tempDir.path, 'cut_${DateTime.now().millisecondsSinceEpoch}$ext');
      
      final duration = endTime - startTime;
      
      final success = await _runFFmpeg([
        '-ss', startTime.toStringAsFixed(3),
        '-i', inputPath,
        '-t', duration.toStringAsFixed(3),
        '-c', 'copy',
        '-avoid_negative_ts', 'make_zero',
        '-y',
        output,
      ]);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] cutClip error: $e');
      return null;
    }
  }

  /// Split a clip at a specific point
  Future<List<String>?> splitClip(String inputPath, double splitPoint) async {
    try {
      final info = await getVideoInfo(inputPath);
      if (info == null) return null;
      
      final part1 = await cutClip(inputPath, 0, splitPoint);
      final part2 = await cutClip(inputPath, splitPoint, info.duration);
      
      if (part1 != null && part2 != null) {
        return [part1, part2];
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] splitClip error: $e');
      return null;
    }
  }

  /// Join multiple video clips with precise A/V sync
  /// Uses -c copy for fast joining when possible, falls back to re-encoding if needed
  Future<String?> joinClips(List<String> inputPaths, {String? outputPath}) async {
    try {
      if (inputPaths.isEmpty) return null;
      if (inputPaths.length == 1) return inputPaths.first;
      
      final tempDir = await _getTempDir();
      final output = outputPath ?? 
          path.join(tempDir.path, 'joined_${DateTime.now().millisecondsSinceEpoch}.mp4');
      
      // Try fast copy mode first (no re-encoding) - works when all videos have same codec/resolution
      print('[VideoMasteringService] Attempting fast copy concat for ${inputPaths.length} clips...');
      
      // Create concat list file
      final listFile = File(path.join(tempDir.path, 'concat_list_${DateTime.now().millisecondsSinceEpoch}.txt'));
      final listContent = StringBuffer();
      for (final filePath in inputPaths) {
        final escapedPath = filePath.replaceAll("'", "'\\''");
        listContent.writeln("file '$escapedPath'");
      }
      await listFile.writeAsString(listContent.toString());
      
      // Try fast copy concat
      final fastSuccess = await _runFFmpeg([
        '-f', 'concat',
        '-safe', '0',
        '-i', listFile.path,
        '-c', 'copy', // No re-encoding!
        '-y',
        output,
      ]);
      
      // Clean up list file
      try { await listFile.delete(); } catch (_) {}
      
      if (fastSuccess && await File(output).exists()) {
        print('[VideoMasteringService] Fast copy concat succeeded!');
        return output;
      }
      
      // Fast copy failed - fall back to re-encoding
      print('[VideoMasteringService] Fast copy failed, falling back to re-encode...');
      
      // Use filter_complex concat for precise timing
      final args = <String>[];
      
      // Add all inputs
      for (final p in inputPaths) {
        args.addAll(['-i', p]);
      }
      
      // Build filter: scale to same res, then concat
      final firstInfo = await getVideoInfo(inputPaths.first);
      final targetW = firstInfo?.width ?? 1920;
      final targetH = firstInfo?.height ?? 1080;
      
      final filters = <String>[];
      
      // Scale and normalize all inputs (same resolution, same fps, reset timestamps)
      for (int i = 0; i < inputPaths.length; i++) {
        filters.add('[$i:v]scale=$targetW:$targetH:force_original_aspect_ratio=decrease,pad=$targetW:$targetH:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,setpts=PTS-STARTPTS[v$i]');
        filters.add('[$i:a]aresample=48000,asetpts=PTS-STARTPTS[a$i]');
      }
      
      // Concat all streams
      final interleavedStreams = List.generate(inputPaths.length, (i) => '[v$i][a$i]').join('');
      filters.add('${interleavedStreams}concat=n=${inputPaths.length}:v=1:a=1[vout][aout]');
      
      // Choose preset: use veryfast when overlays are embedded for faster processing

      args.addAll([
        '-filter_complex', filters.join(';'),
        '-map', '[vout]',
        '-map', '[aout]',
        '-c:v', 'libx264',
        '-preset', 'veryfast', // Fast export when transitions are off
        '-crf', '18',
        '-c:a', 'aac',
        '-b:a', '192k',
        '-ar', '48000',
        '-async', '1',
        '-vsync', 'cfr',
        '-y',
        output,
      ]);
      
      print('[VideoMasteringService] Joining ${inputPaths.length} clips with re-encode (veryfast)');
      final success = await _runFFmpeg(args);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] joinClips error: $e');
      return null;
    }
  }

  /// Join multiple video clips with smooth crossfade transitions
  /// All clips must be scaled to the same resolution for xfade to work
  Future<String?> joinClipsWithTransition(
    List<String> inputPaths, {
    double transitionDuration = 1.0,
    String transitionType = 'fade', // FFmpeg xfade: fade = smooth linear crossfade
    String? outputPath,
    int targetWidth = 1920,
    int targetHeight = 1080,
  }) async {
    try {
      if (inputPaths.isEmpty) return null;
      if (inputPaths.length == 1) return inputPaths.first;
      
      final tempDir = await _getTempDir();
      final output = outputPath ?? 
          path.join(tempDir.path, 'joined_trans_${DateTime.now().millisecondsSinceEpoch}.mp4');
      
      // Build inputs
      final args = <String>[];
      for (final p in inputPaths) {
        args.addAll(['-i', p]);
      }
      
      // Get durations for offset calculation
      final durations = <double>[];
      for (final p in inputPaths) {
        final info = await getVideoInfo(p);
        durations.add(info?.duration ?? 5.0);
      }
      
      // Build filter chain
      // Step 1: Scale all inputs to same resolution (required for xfade)
      // Step 2: Apply xfade transitions between scaled clips
      final filters = <String>[];
      
      // First, scale all video inputs to target resolution
      for (int i = 0; i < inputPaths.length; i++) {
        filters.add('[$i:v]scale=$targetWidth:$targetHeight:force_original_aspect_ratio=decrease,pad=$targetWidth:$targetHeight:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v${i}scaled]');
      }
      
      // Now apply xfade between scaled clips
      String lastStream = '[v0scaled]';
      String lastAStream = '[0:a]';
      
      double cumulativeDuration = durations[0];
      
      for (int i = 1; i < inputPaths.length; i++) {
        final offset = (cumulativeDuration - transitionDuration).clamp(0.0, double.infinity);
        final nextV = '[v$i]';
        final nextA = '[a$i]';
        
        // Video xfade (using scaled streams)
        filters.add('${lastStream}[v${i}scaled]xfade=transition=$transitionType:duration=$transitionDuration:offset=${offset.toStringAsFixed(3)}$nextV');
        
        // Audio crossfade
        filters.add('${lastAStream}[$i:a]acrossfade=d=$transitionDuration:c1=tri:c2=tri$nextA');
        
        lastStream = nextV;
        lastAStream = nextA;
        cumulativeDuration += durations[i] - transitionDuration;
      }
      
      // Build command
      args.addAll([
        '-filter_complex', filters.join(';'),
        '-map', lastStream,
        '-map', lastAStream,
        '-c:v', 'libx264',
        '-preset', 'fast',
        '-crf', '18',
        '-c:a', 'aac',
        '-y',
        output,
      ]);
      
      print('[VideoMasteringService] Joining ${inputPaths.length} clips with $transitionType transition at ${targetWidth}x$targetHeight');
      final success = await _runFFmpeg(args);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] joinClipsWithTransition error: $e');
      return null;
    }
  }

  /// Apply speed change to video (and optionally audio)
  /// Supports extreme speeds from 0.01x to 20x using chained atempo filters
  Future<String?> applySpeed(String inputPath, double speed, {bool adjustAudio = true, String? outputPath}) async {
    try {
      final tempDir = await _getTempDir();
      final ext = path.extension(inputPath);
      final output = outputPath ?? 
          path.join(tempDir.path, 'speed_${DateTime.now().millisecondsSinceEpoch}$ext');
      
      // Video speed filter (setpts) - works for any speed
      final videoSpeed = 1.0 / speed;
      
      // Build atempo chain for audio (FFmpeg atempo only supports 0.5-2.0 per filter)
      // For extreme speeds, we chain multiple atempo filters
      String buildAtempoChain(double targetSpeed) {
        final filters = <String>[];
        var remaining = targetSpeed;
        
        while (remaining > 2.0) {
          filters.add('atempo=2.0');
          remaining /= 2.0;
        }
        while (remaining < 0.5) {
          filters.add('atempo=0.5');
          remaining /= 0.5;
        }
        // Add final atempo for remaining speed
        if ((remaining - 1.0).abs() > 0.001) {
          filters.add('atempo=${remaining.toStringAsFixed(4)}');
        }
        
        return filters.isEmpty ? 'atempo=1.0' : filters.join(',');
      }
      
      List<String> args = [
        '-i', inputPath,
        '-filter_complex',
      ];
      
      if (adjustAudio) {
        final atempoChain = buildAtempoChain(speed);
        args.add('[0:v]setpts=${videoSpeed.toStringAsFixed(4)}*PTS[v];[0:a]$atempoChain[a]');
        args.addAll(['-map', '[v]', '-map', '[a]']);
      } else {
        args.add('[0:v]setpts=${videoSpeed.toStringAsFixed(4)}*PTS[v]');
        args.addAll(['-map', '[v]', '-an']);
      }
      
      args.addAll(['-y', output]);
      
      final success = await _runFFmpeg(args);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] applySpeed error: $e');
      return null;
    }
  }

  /// Apply volume adjustment or mute to video clip
  Future<String?> applyVolumeAndMute(String inputPath, double volume, bool isMuted, {String? outputPath}) async {
    try {
      // If volume is 1.0 and not muted, no changes needed
      if (!isMuted && (volume - 1.0).abs() < 0.01) return inputPath;
      
      final tempDir = await _getTempDir();
      final ext = path.extension(inputPath);
      final output = outputPath ?? 
          path.join(tempDir.path, 'vol_${DateTime.now().millisecondsSinceEpoch}$ext');
      
      List<String> args = ['-i', inputPath];
      
      if (isMuted || volume <= 0) {
        // Remove audio completely
        args.addAll(['-c:v', 'copy', '-an', '-y', output]);
      } else {
        // Apply volume filter
        args.addAll(['-c:v', 'copy', '-af', 'volume=${volume.toStringAsFixed(2)}', '-y', output]);
      }
      
      final success = await _runFFmpeg(args);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] applyVolumeAndMute error: $e');
      return null;
    }
  }

  /// Apply color adjustments to video
  Future<String?> applyColorFilter(String inputPath, ColorSettings settings, {String? outputPath}) async {
    try {
      if (settings.isDefault) return inputPath; // No changes needed
      
      final tempDir = await _getTempDir();
      final ext = path.extension(inputPath);
      final output = outputPath ?? 
          path.join(tempDir.path, 'color_${DateTime.now().millisecondsSinceEpoch}$ext');
      
      // Build eq filter
      final filters = <String>[];
      
      if (settings.brightness != 0) {
        filters.add('brightness=${settings.brightness}');
      }
      if (settings.contrast != 1) {
        filters.add('contrast=${settings.contrast}');
      }
      if (settings.saturation != 1) {
        filters.add('saturation=${settings.saturation}');
      }
      
      String filterStr = 'eq=${filters.join(':')}';
      
      // Add hue if needed
      if (settings.hue != 0) {
        filterStr += ',hue=h=${settings.hue}';
      }
      
      final success = await _runFFmpeg([
        '-i', inputPath,
        '-vf', filterStr,
        '-c:a', 'copy',
        '-y',
        output,
      ]);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] applyColorFilter error: $e');
      return null;
    }
  }

  /// Add logo overlay to video
  Future<String?> addLogoOverlay(String videoPath, LogoSettings logo, {String? outputPath, double? videoDuration}) async {
    try {
      final tempDir = await _getTempDir();
      final output = outputPath ?? 
          path.join(tempDir.path, 'logo_${DateTime.now().millisecondsSinceEpoch}.mp4');
      
      // Calculate position based on setting
      String overlayPosition;
      switch (logo.position) {
        case 'topLeft':
          overlayPosition = 'x=10:y=10';
          break;
        case 'topRight':
          overlayPosition = 'x=W-w-10:y=10';
          break;
        case 'bottomLeft':
          overlayPosition = 'x=10:y=H-h-10';
          break;
        case 'bottomRight':
          overlayPosition = 'x=W-w-10:y=H-h-10';
          break;
        case 'center':
          overlayPosition = 'x=(W-w)/2:y=(H-h)/2';
          break;
        case 'custom':
          final x = (logo.customX ?? 0.5);
          final y = (logo.customY ?? 0.5);
          overlayPosition = 'x=W*$x-w/2:y=H*$y-h/2';
          break;
        default:
          overlayPosition = 'x=W-w-10:y=H-h-10';
      }
      
      // Build filter with scale and opacity
      final scaleFilter = 'scale=iw*${logo.scale}:ih*${logo.scale}';
      final opacityFilter = logo.transparency < 1 
          ? ',format=rgba,colorchannelmixer=aa=${logo.transparency}' 
          : '';
      
      // Time filter if needed
      String enableFilter = '';
      if (logo.startTime > 0 || logo.endTime != null) {
        final startCond = logo.startTime > 0 ? "gte(t\\,${logo.startTime})" : "1";
        final endCond = logo.endTime != null ? "lte(t\\,${logo.endTime})" : "1";
        enableFilter = ":enable='$startCond*$endCond'";
      }
      
      final filterComplex = 
          "[1:v]$scaleFilter$opacityFilter[logo];"
          "[0:v][logo]overlay=$overlayPosition$enableFilter[out]";
      
      final success = await _runFFmpeg([
        '-i', '"$videoPath"',
        '-i', '"${logo.imagePath}"',
        '-filter_complex', '"$filterComplex"',
        '-map', '[out]',
        '-map', '0:a?',
        '-c:a', 'copy',
        '-y',
        '"$output"',
      ]);
      
      if (success && await File(output).exists()) {
        return output;
      }
      return null;
    } catch (e) {
      print('[VideoMasteringService] addLogoOverlay error: $e');
      return null;
    }
  }

  /// Export full project
  Future<String?> exportProject(
    VideoProject project,
    String outputPath, {
    Function(double progress, String step)? onProgress,
    bool isVideoTrackMuted = false,
    bool isAudioTrackMuted = false,
    bool isBgMusicTrackMuted = false,
  }) async {
    // Create unique task ID
    final taskId = 'export_${DateTime.now().millisecondsSinceEpoch}';
    
    await _log('========================================');
    await _log('EXPORT PROJECT START');
    await _log('Project: ${project.name}');
    await _log('Output: $outputPath');
    await _log('Video Clips: ${project.videoClips.length}');
    await _log('Audio Clips: ${project.audioClips.length}');
    await _log('BG Music Clips: ${project.bgMusicClips.length}');
    await _log('Resolution: ${project.exportSettings.resolution}');
    await _log('Video Muted: $isVideoTrackMuted');
    await _log('Audio Muted: $isAudioTrackMuted');
    await _log('BG Music Muted: $isBgMusicTrackMuted');
    await _log('========================================');
    
    // Create export task
    final task = ExportTask(
      taskId: taskId,
      projectName: project.name,
      outputPath: outputPath,
      startTime: DateTime.now(),
    );
    _activeTasks[taskId] = task;
    _tasksController.add(activeTasks);
    
    try {
      _updateTaskProgress(taskId, 0.0, 'Preparing export...');
      onProgress?.call(0.0, 'Preparing export...');
      
      if (project.videoClips.isEmpty) {
        await _log('ERROR: No video clips to export');
        print('[VideoMasteringService] No video clips to export');
        _completeTask(taskId, error: 'No video clips to export');
        return null;
      }
      
      // Check if any input file is the same as the output file
      final outputPathNormalized = path.normalize(outputPath.toLowerCase());
      for (final clip in project.videoClips) {
        final clipPathNormalized = path.normalize(clip.filePath.toLowerCase());
        if (clipPathNormalized == outputPathNormalized) {
          final errorMsg = 'Cannot export: Input file "${clip.filePath}" is the same as output file "$outputPath". FFmpeg cannot overwrite input files. Please choose a different output filename or remove this clip from the timeline.';
          await _log('ERROR: $errorMsg');
          print('[VideoMasteringService] $errorMsg');
          _completeTask(taskId, error: errorMsg);
          return null;
        }
      }
      
      final tempDir = await _getTempDir();
      final settings = project.exportSettings;
      
      // SINGLE-PASS APPROACH: Build one FFmpeg command that does everything
      // This is MUCH faster than multi-step processing
      _updateTaskProgress(taskId, 0.05, 'Building export pipeline...');
      onProgress?.call(0.05, 'Building export pipeline...');
      
      final args = <String>[];
      final videoFilters = <String>[];
      final audioFilters = <String>[];
      
      // Add all video clip inputs
      for (final clip in project.videoClips) {
        args.addAll(['-i', clip.filePath]);
      }
      
      // Add audio/bgmusic inputs
      final audioClips = <AudioClip>[];
      if (!isAudioTrackMuted) {
        audioClips.addAll(project.audioClips.where((c) => c.filePath.isNotEmpty && !c.isMuted));
      }
      if (!isBgMusicTrackMuted) {
        audioClips.addAll(project.bgMusicClips.where((c) => c.filePath.isNotEmpty && !c.isMuted));
      }
      
      final audioInputOffset = project.videoClips.length;
      for (final audioClip in audioClips) {
        args.addAll(['-i', audioClip.filePath]);
      }
      
      // Build video filter chain for each clip: trim, speed, color, scale
      final targetW = settings.width;
      final targetH = settings.height;
      
      for (int i = 0; i < project.videoClips.length; i++) {
        final clip = project.videoClips[i];
        final effectiveMute = clip.isMuted || isVideoTrackMuted;
        
        // Video filter: trim -> speed -> color -> scale
        final vFilters = <String>[];
        
        // Trim
        if (clip.trimStart > 0 || clip.trimEnd > 0) {
          final startPts = clip.trimStart;
          final endPts = clip.originalDuration - clip.trimEnd;
          vFilters.add('trim=start=$startPts:end=$endPts,setpts=PTS-STARTPTS');
        }
        
        // Speed
        if (clip.speed != 1.0) {
          final pts = 1.0 / clip.speed;
          vFilters.add('setpts=${pts.toStringAsFixed(4)}*PTS');
        }
        
        // Color
        if (!clip.colorSettings.isDefault) {
          final eqParts = <String>[];
          if (clip.colorSettings.brightness != 0) eqParts.add('brightness=${clip.colorSettings.brightness}');
          if (clip.colorSettings.contrast != 1) eqParts.add('contrast=${clip.colorSettings.contrast}');
          if (clip.colorSettings.saturation != 1) eqParts.add('saturation=${clip.colorSettings.saturation}');
          if (eqParts.isNotEmpty) vFilters.add('eq=${eqParts.join(":")}');
        }
        
        // Scale and normalize
        vFilters.add('scale=$targetW:$targetH:force_original_aspect_ratio=decrease');
        vFilters.add('pad=$targetW:$targetH:(ow-iw)/2:(oh-ih)/2');
        vFilters.add('setsar=1,fps=30,format=yuv420p');
        
        videoFilters.add('[$i:v]${vFilters.join(",")}[v$i]');
        
        // Audio filter: trim, speed, volume
        final aFilters = <String>[];
        
        if (clip.trimStart > 0 || clip.trimEnd > 0) {
          final startPts = clip.trimStart;
          final endPts = clip.originalDuration - clip.trimEnd;
          aFilters.add('atrim=start=$startPts:end=$endPts,asetpts=PTS-STARTPTS');
        }
        
        if (clip.speed != 1.0) {
          // Build atempo chain for extreme speeds
          var remaining = clip.speed;
          while (remaining > 2.0) { aFilters.add('atempo=2.0'); remaining /= 2.0; }
          while (remaining < 0.5) { aFilters.add('atempo=0.5'); remaining *= 2.0; }
          if ((remaining - 1.0).abs() > 0.001) aFilters.add('atempo=${remaining.toStringAsFixed(4)}');
        }
        
        if (effectiveMute) {
          aFilters.add('volume=0');
        } else {
          // Apply both clip volume AND master volume
          final finalVolume = clip.volume * project.videoMasterVolume;
          if (finalVolume != 1.0) {
            aFilters.add('volume=${finalVolume.toStringAsFixed(2)}');
          }
        }
        
        aFilters.add('aformat=sample_rates=48000:channel_layouts=stereo');
        
        audioFilters.add('[$i:a]${aFilters.join(",")}[a$i]');
      }
      
      // Concat filters need to come AFTER both video and audio clip filters are defined
      // because concat references [v$i] and [a$i] labels
      final concatFilters = <String>[];
      
      // Concat all video streams
      final int clipCount = project.videoClips.length;
      if (project.transitionsEnabled && clipCount > 1) {
        // With transitions - chain xfade filters
        String lastV = '[v0]';
        double cumulativeDuration = project.videoClips[0].effectiveDuration;
        
        for (int i = 1; i < clipCount; i++) {
          final offset = (cumulativeDuration - project.transitionDuration).clamp(0.0, double.infinity);
          final nextLabel = i < clipCount - 1 ? '[vtrans$i]' : '[vconcat]';
          concatFilters.add('$lastV[v$i]xfade=transition=${project.transitionType}:duration=${project.transitionDuration}:offset=${offset.toStringAsFixed(3)}$nextLabel');
          lastV = nextLabel;
          cumulativeDuration += project.videoClips[i].effectiveDuration - project.transitionDuration;
        }
        
        // Audio crossfade
        String lastA = '[a0]';
        for (int i = 1; i < clipCount; i++) {
          final nextLabel = i < clipCount - 1 ? '[atrans$i]' : '[aconcat]';
          concatFilters.add('$lastA[a$i]acrossfade=d=${project.transitionDuration}:c1=tri:c2=tri$nextLabel');
          lastA = nextLabel;
        }
      } else {
        // Simple concat - no transitions
        final vStreams = List.generate(clipCount, (i) => '[v$i][a$i]').join('');
        concatFilters.add('${vStreams}concat=n=$clipCount:v=1:a=1[vconcat][aconcat]');
      }
      
      // Mix in additional audio/bgmusic if any
      // NOTE: The amix filter uses [aconcat] which is created by concat, so it must come AFTER concatFilters
      String finalAudio = '[aconcat]';
      final audioMixFilters = <String>[];
      if (audioClips.isNotEmpty) {
        // Build audio mix filter
        final audioMixInputs = <String>['[aconcat]'];
        
        // Track which clips are audio vs bgMusic for master volume application
        int audioClipCount = 0;
        int bgMusicClipCount = 0;
        if (!isAudioTrackMuted) {
          audioClipCount = project.audioClips.where((c) => c.filePath.isNotEmpty && !c.isMuted).length;
        }
        if (!isBgMusicTrackMuted) {
          bgMusicClipCount = project.bgMusicClips.where((c) => c.filePath.isNotEmpty && !c.isMuted).length;
        }
        
        for (int i = 0; i < audioClips.length; i++) {
          final clip = audioClips[i];
          final inputIdx = audioInputOffset + i;
          
          // Determine if this is an audio clip or bgMusic clip
          final isAudioClip = i < audioClipCount;
          final masterVolume = isAudioClip ? project.audioMasterVolume : project.bgMusicMasterVolume;
          
          // Apply delay, volume (with master volume), speed to each audio input
          final aFilters = <String>[];
          if (clip.timelineStart > 0) {
            aFilters.add('adelay=${(clip.timelineStart * 1000).toInt()}|${(clip.timelineStart * 1000).toInt()}');
          }
          if (clip.speed != 1.0) {
            var remaining = clip.speed;
            while (remaining > 2.0) { aFilters.add('atempo=2.0'); remaining /= 2.0; }
            while (remaining < 0.5) { aFilters.add('atempo=0.5'); remaining *= 2.0; }
            if ((remaining - 1.0).abs() > 0.001) aFilters.add('atempo=${remaining.toStringAsFixed(4)}');
          }
          // Apply both clip volume AND master volume
          final finalVolume = clip.volume * masterVolume;
          if (finalVolume != 1.0) {
            aFilters.add('volume=${finalVolume.toStringAsFixed(2)}');
          }
          aFilters.add('aformat=sample_rates=48000:channel_layouts=stereo');
          
          // These go to audioFilters (before concat) - just the input processing
          audioFilters.add('[$inputIdx:a]${aFilters.join(",")}[amix$i]');
          audioMixInputs.add('[amix$i]');
        }
        
        // Mix all audio streams - this uses [aconcat] so it must come AFTER concat
        audioMixFilters.add('${audioMixInputs.join("")}amix=inputs=${audioMixInputs.length}:normalize=0[afinal]');
        finalAudio = '[afinal]';
      }
      
      // Combine all filters in correct order:
      // 1. videoFilters (defines [v$i] labels)
      // 2. audioFilters (defines [a$i] labels and [amix$i] labels for extra audio)
      // 3. concatFilters (uses [v$i] and [a$i] to create [vconcat] and [aconcat])
      // 4. audioMixFilters (uses [aconcat] and [amix$i] to create [afinal])
      // 5. overlay filters (optional, applied after concat)
      bool overlaysEmbedded = false;
      final allFiltersList = <String>[];
      allFiltersList.addAll(videoFilters);
      allFiltersList.addAll(audioFilters);
      allFiltersList.addAll(concatFilters);
      allFiltersList.addAll(audioMixFilters);

      // Track the final video stream name (starts as [vconcat], may be updated by overlays)
      String lastStream = '[vconcat]';

      // If there are overlays (image/logo/text), add their inputs and append overlay/drawtext filters that operate on [vconcat]
      final imageOverlays = project.overlays.where((o) => o.type == 'image' || o.type == 'logo').toList();
      final textOverlays = project.overlays.where((o) => o.type == 'text').toList();
      if (imageOverlays.isNotEmpty || textOverlays.isNotEmpty) {
        overlaysEmbedded = true;
        // Add image inputs after existing inputs (video + audio inputs already added)
        for (final img in imageOverlays) {
          args.addAll(['-i', img.imagePath]);
        }

        // Build overlay filters chaining from [vconcat]
        final overlayStartIndex = project.videoClips.length + audioClips.length; // index of first overlay input
        for (int i = 0; i < imageOverlays.length; i++) {
          final o = imageOverlays[i];
          final imgInputIdx = overlayStartIndex + i;
          final imgLabel = 'img_scaled_$i';
          // compute target width based on export resolution
          final targetWidth = (settings.width * o.scale.clamp(0.05, 1.0)).round().clamp(4, settings.width);
          // scale image and keep alpha
          allFiltersList.add('[$imgInputIdx:v]scale=$targetWidth:-1,format=rgba[$imgLabel]');

          final xCmd = '(W-w)*${o.x}';
          final yCmd = '(H-h)*${o.y}';
          final enable = "between(t,${o.timelineStart},${o.timelineEnd})";
          final nextStream = 'v_overlay_$i';

          allFiltersList.add('$lastStream' + '[$imgLabel]overlay=x=$xCmd:y=$yCmd:enable=\'$enable\'[$nextStream]');
          lastStream = '[$nextStream]';
        }

        // STEP: Append text overlays (drawtext) chained on top of lastStream
        if (textOverlays.isNotEmpty) {
          // Build drawtext filters list
          String fontPath = 'Arial';
          if (Platform.isWindows) fontPath = 'C\\:/Windows/Fonts/arial.ttf';

          final textFilters = <String>[];
          for (int ti = 0; ti < textOverlays.length; ti++) {
            final o = textOverlays[ti];
            final color = Color(o.textColor);
            final hexColor = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
            final alpha = color.opacity;

            final bgColor = Color(o.backgroundColor);
            final bgHex = '#${bgColor.value.toRadixString(16).padLeft(8, '0').substring(2)}';
            final bgAlpha = bgColor.opacity;

            final escapedText = (o.text ?? '').replaceAll(":", "\\:").replaceAll("'", "\\'");
            final xCmd = '(w-text_w)*${o.x}';
            final yCmd = '(h-text_h)*${o.y}';
            final enable = "between(t,${o.timelineStart},${o.timelineEnd})";

            String drawText = "drawtext=fontfile='$fontPath':text='$escapedText':fontsize=${o.fontSize}";
            drawText += ":fontcolor=$hexColor:alpha=$alpha";
            if (bgAlpha > 0) {
              drawText += ":box=1:boxcolor=$bgHex@$bgAlpha:boxborderw=5";
            }
            drawText += ":x=$xCmd:y=$yCmd:enable='$enable'";

            textFilters.add(drawText);
          }

          if (textFilters.isNotEmpty) {
            final allDrawText = textFilters.join(',');
            final nextTextStream = 'v_text';
            // lastStream currently holds the bracketed label like '[v_overlay_n]' or '[vconcat]'
            // Remove surrounding brackets for the input label and create filter
            final inputLabel = lastStream.replaceAll('[', '').replaceAll(']', '');
            allFiltersList.add('[$inputLabel]$allDrawText[$nextTextStream]');
            lastStream = '[$nextTextStream]';
          }
        }

        // append to combined filters
      }

      final allFilters = allFiltersList.join(';');

      // Build final args mapping; if overlays were embedded, map the final overlay stream instead of [vconcat]
      // Determine preset based on whether overlays were embedded
      final presetToUse = overlaysEmbedded ? 'veryfast' : _getEncodingPreset(targetW, targetH);
      
      // Determine final video stream to map
      // If overlays are embedded, use lastStream (which tracks the final output after all overlays)
      // Otherwise use [vconcat]
      final finalVideoStream = overlaysEmbedded ? lastStream : '[vconcat]';

      args.addAll([
        '-filter_complex', allFilters,
        '-map', finalVideoStream,
        '-map', finalAudio,
        '-c:v', 'libx264',
        '-preset', presetToUse,
        '-crf', '18',
        '-b:v', '${settings.videoBitrate}k',
        '-c:a', 'aac',
        '-b:a', '${settings.audioBitrate}k',
        '-ar', '48000',
        '-shortest',
        '-y',
        outputPath,
      ]);
      
      print('[VideoMasteringService] Running single-pass export with ${project.videoClips.length} clips + ${audioClips.length} audio tracks');
      
      _updateTaskProgress(taskId, 0.05, 'Encoding (single-pass)...');
      onProgress?.call(0.05, 'Encoding (single-pass)...');

      final totalEstimate = (project.totalDuration > 0) ? project.totalDuration : 1.0;

      // Progress bar uses full 0-100% range for encoding
      final success = await _runFFmpeg(args, taskId: taskId, expectedDuration: totalEstimate, onProgress: (time, {percent, fps, speed, eta}) {
        final double frac = (percent ?? (time / totalEstimate)).clamp(0.0, 1.0);
        // Use full 0-100% range for encoding progress
        final prog = frac.clamp(0.0, 0.99); // Cap at 99% until fully complete
        String pctText = '${(frac * 100).toStringAsFixed(0)}%';
        // Improved ETA: never show "0m 0s", "0s", or empty
        String etaText;
        if (eta == null || eta.trim().isEmpty) {
          etaText = ' | ETA: Calculating...';
        } else {
          final etaClean = eta.trim().toLowerCase();
          if (etaClean == '0m 0s' || etaClean == '0s' || etaClean == '0m' || etaClean == '0') {
            etaText = ' | ETA: Calculating...';
          } else if (RegExp(r'^0+m? ?0+s?$').hasMatch(etaClean)) {
            etaText = ' | ETA: Calculating...';
          } else {
            etaText = ' | ETA: $eta';
          }
        }
        final status = 'Encoding: $pctText$etaText';
        _updateTaskProgress(taskId, prog, status);
        onProgress?.call(prog, status);
      });
      
      if (success && await File(outputPath).exists()) {
        _updateTaskProgress(taskId, 1.0, 'Export complete!');
        onProgress?.call(1.0, 'Export complete!');
        _completeTask(taskId);
        return outputPath;
      }
      
      _completeTask(taskId, error: 'Export failed - file not created');
      return null;
    } catch (e) {
      print('[VideoMasteringService] exportProject error: $e');
      _completeTask(taskId, error: e.toString());
      return null;
    }
  }

  /// Apply all overlays (Text, Image) in one pass
  Future<String?> applyOverlays(String inputPath, List<OverlayItem> overlays, {String? outputPath}) async {
    if (overlays.isEmpty) return inputPath;
    
    try {
      final tempDir = await _getTempDir();
      final output = outputPath ?? 
          path.join(tempDir.path, 'overlays_${DateTime.now().millisecondsSinceEpoch}.mp4');
      
      final args = <String>[];
      args.addAll(['-i', inputPath]);
      
      // Collect image inputs
      final imageOverlays = overlays.where((o) => o.type == 'image' || o.type == 'logo').toList();
      for (var img in imageOverlays) {
        args.addAll(['-i', img.imagePath]);
      }
      
      // Build filter complex
      final filters = <String>[];
      String lastStream = '0:v';
      int imgInputIdx = 1;
      
      // Get video dimensions first for explicit scaling
      final videoInfo = await getVideoInfo(inputPath);
      final videoWidth = videoInfo?.width ?? 1920;
      final videoHeight = videoInfo?.height ?? 1080;
      
      // 1. Process Image Overlays
      for (int i = 0; i < imageOverlays.length; i++) {
        final o = imageOverlays[i];
        final imgIn = '$imgInputIdx:v';
        final scaledImg = 'img_scaled_$i';
        
        // Calculate target width in pixels based on SOURCE video dimensions.
        // This ensures the logo maintains the same relative size as seen in preview.
        final targetWidth = (videoWidth * o.scale.clamp(0.05, 1.0)).round().clamp(4, videoWidth);
        
        // Scale image to target width, maintain aspect ratio
        String scaleCmd = '[$imgIn]scale=$targetWidth:-1,format=rgba';
        
        // Apply Opacity if needed
        if (o.opacity < 1.0) {
          scaleCmd += ',colorchannelmixer=aa=${o.opacity}';
        }
        scaleCmd += '[$scaledImg]';
        filters.add(scaleCmd);

        // Overlay or blend command
        // Calculate explicit pixel positions (relative expressions for FFmpeg overlay)
        final xCmd = '(W-w)*${o.x}';
        final yCmd = '(H-h)*${o.y}';

        final enable = "between(t,${o.timelineStart},${o.timelineEnd})";
        final nextStream = 'v_overlay_$i';

        final blendMode = (o.properties['blendMode'] as String?) ?? 'normal';
        if (blendMode != 'normal') {
          // Create a transparent canvas sized to the video, place the scaled image onto it
          // at the requested relative x/y, then blend with the main stream using FFmpeg's blend filter.
          final blank = 'blank_$i';
          final logoFull = 'logo_full_$i';

          filters.add('color=color=0x00000000:size=${videoWidth}x${videoHeight}[$blank]');
          filters.add('[$blank][$scaledImg]overlay=x=$xCmd:y=$yCmd:enable=1[$logoFull]');

          // Use blend filter; all_opacity controls transparency
          filters.add("[$lastStream][$logoFull]blend=all_mode='${blendMode}':all_opacity=${o.opacity}[$nextStream]");
        } else {
          filters.add("[$lastStream][$scaledImg]overlay=x=$xCmd:y=$yCmd:enable='${enable}'[$nextStream]");
        }
        lastStream = nextStream;
        imgInputIdx++;
      }
      
      // 2. Process Text Overlays (using drawtext)
      final textOverlays = overlays.where((o) => o.type == 'text').toList();
      if (textOverlays.isNotEmpty) {
        // We'll chain drawtext filters on the lastStream
        // Note: drawtext requires fontfile. We might need a default font path.
        // For Windows, C:/Windows/Fonts/arial.ttf is safe.
        // For simplicity, we assume Windows or provide a safe fallback.
        String fontPath = 'Arial'; 
        if (Platform.isWindows) fontPath = 'C\\:/Windows/Fonts/arial.ttf';
        // macOS/Linux adjustments needed in production
        
        final textFilters = <String>[];
        for (var o in textOverlays) {
          // Color format: 0xAARRGGBB -> #RRGGBB@opacity
          // FFmpeg expects hex color or name. 
          // Extract RGB and Alpha
          final color = Color(o.textColor);
          final hexColor = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
          final alpha = color.opacity;
          
          final bgColor = Color(o.backgroundColor);
          final bgHex = '#${bgColor.value.toRadixString(16).padLeft(8, '0').substring(2)}';
          final bgAlpha = bgColor.opacity;
          
          // Escape text for FFmpeg
          final escapedText = o.text.replaceAll(":", "\\:").replaceAll("'", "\\'");
          
          final xCmd = '(w-text_w)*${o.x}'; // Center anchor logic is complex in drawtext without specialized x/y
          // Simplifying to direct mapping: 0=left, 1=right.
          // Correct centering: x = (W-tw)*percent ? No.
          // If x=0.5, we want center. x=(W-tw)/2.
          // Generic formula: x = (W-tw) * x_prop? 
          // Let's use: x=(W-tw)*${o.x}
          
          final yCmd = '(h-text_h)*${o.y}';
          
          final enable = "between(t,${o.timelineStart},${o.timelineEnd})";
          
          String drawText = "drawtext=fontfile='$fontPath':text='$escapedText':fontsize=${o.fontSize}";
          drawText += ":fontcolor=$hexColor:alpha=$alpha";
          if (bgAlpha > 0) {
             drawText += ":box=1:boxcolor=$bgHex@$bgAlpha:boxborderw=5";
          }
          drawText += ":x=$xCmd:y=$yCmd:enable='$enable'";
          
          textFilters.add(drawText);
        }
        
        // Chain them
        // [in]drawtext=...:x=...[out]
        // But invalid syntax to chain multiple drawtexts without comma?
        // Actually, "vf" takes a chain separated by comma.
        // We are in filter_complex.
        // We can just append to the last filter chain?
        // e.g. [prev]drawtext=...,drawtext=...[next]
        
        if (textFilters.isNotEmpty) {
             final allDrawText = textFilters.join(',');
             final nextStream = 'v_text';
             filters.add('[$lastStream]$allDrawText[$nextStream]');
             lastStream = nextStream;
        }
      }
      
      args.add('-filter_complex');
      args.add(filters.join(';'));
      
      // Ensure output has correct pixel format for compatibility
      args.addAll([
        '-map', '[$lastStream]', 
        '-map', '0:a?', 
        '-c:v', 'libx264', 
        '-pix_fmt', 'yuv420p', 
        '-c:a', 'copy', 
        '-y', 
        output
      ]);
      
      final success = await _runFFmpeg(args);
      if (success && await File(output).exists()) return output;
      return null;
      
    } catch (e) {
      print('[VideoMasteringService] applyOverlays error: $e');
      return null;
    }
  }

  /// Parse FPS string like "30/1" or "29.97"
  double _parseFps(String fpsStr) {
    if (fpsStr.contains('/')) {
      final parts = fpsStr.split('/');
      if (parts.length == 2) {
        final num = double.tryParse(parts[0]) ?? 30;
        final den = double.tryParse(parts[1]) ?? 1;
        return den > 0 ? num / den : 30;
      }
    }
    return double.tryParse(fpsStr) ?? 30;
  }

  /// ONE-PASS EXPORT: Apply overlays + scale + encode in single FFmpeg command (much faster!)
  Future<bool> _exportWithOverlaysOnePass(
    String inputPath,
    List<OverlayItem> overlays,
    String outputPath,
    ExportSettings settings,
    double totalDuration,
    Function(double progress, String step)? onProgress, {
    String? taskId,
    String? bgMusicMixPath,
  }) async {
    try {
      print('[VideoMasteringService] ONE-PASS export with ${overlays.length} overlays');
      
      final args = <String>[];
      args.addAll(['-i', inputPath]);
      
      // Collect image inputs
      final imageOverlays = overlays.where((o) => o.type == 'image' || o.type == 'logo').toList();
      for (var img in imageOverlays) {
        args.addAll(['-i', img.imagePath]);
      }
      // If a bg music mix was created, add it as an input (after image overlays)
      if (bgMusicMixPath != null && bgMusicMixPath.isNotEmpty) {
        args.addAll(['-i', bgMusicMixPath]);
      }
      
      // Build filter complex
      final filters = <String>[];
      int imgInputIdx = 1;
      
      // Get source video dimensions (for reference only)
      final videoInfo = await getVideoInfo(inputPath);
      final sourceWidth = videoInfo?.width ?? 1920;
      final sourceHeight = videoInfo?.height ?? 1080;
      
      // STEP 1: Scale video to export resolution FIRST
      // This ensures all overlays are applied at the final resolution
      final scaledStream = 'v_scaled';
      filters.add('[0:v]scale=${settings.width}:${settings.height}:force_original_aspect_ratio=decrease,pad=${settings.width}:${settings.height}:(ow-iw)/2:(oh-ih)/2[$scaledStream]');
      String lastStream = scaledStream;
      
      // STEP 2: Process Image Overlays (on the scaled video)
      for (int i = 0; i < imageOverlays.length; i++) {
        final o = imageOverlays[i];
        final imgIn = '$imgInputIdx:v';
        final scaledImg = 'img_scaled_$i';
        
        // Compute target width based on EXPORT resolution.
        // Logo at 9% will be 9% of the export resolution width.
        final targetWidth = (settings.width * o.scale.clamp(0.05, 1.0)).round().clamp(4, settings.width);
        
        String scaleCmd = '[$imgIn]scale=$targetWidth:-1,format=rgba';
        if (o.opacity < 1.0) {
          scaleCmd += ',colorchannelmixer=aa=${o.opacity}';
        }
        scaleCmd += '[$scaledImg]';
        filters.add(scaleCmd);
        
        final xCmd = '(W-w)*${o.x}';
        final yCmd = '(H-h)*${o.y}';
        final enable = "between(t,${o.timelineStart},${o.timelineEnd})";
        final nextStream = 'v_overlay_$i';
        
        filters.add("[$lastStream][$scaledImg]overlay=x=$xCmd:y=$yCmd:enable='${enable}'[$nextStream]");
        lastStream = nextStream;
        imgInputIdx++;
      }
      
      // STEP 3: Process Text Overlays (on the scaled video)
      final textOverlays = overlays.where((o) => o.type == 'text').toList();
      if (textOverlays.isNotEmpty) {
        String fontPath = 'Arial';
        if (Platform.isWindows) fontPath = 'C\\:/Windows/Fonts/arial.ttf';
        
        final textFilters = <String>[];
        for (var o in textOverlays) {
          final color = Color(o.textColor);
          final hexColor = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';
          final alpha = color.opacity;
          
          final bgColor = Color(o.backgroundColor);
          final bgHex = '#${bgColor.value.toRadixString(16).padLeft(8, '0').substring(2)}';
          final bgAlpha = bgColor.opacity;
          
          final escapedText = o.text.replaceAll(":", "\\:").replaceAll("'", "\\'");
          final xCmd = '(w-text_w)*${o.x}';
          final yCmd = '(h-text_h)*${o.y}';
          final enable = "between(t,${o.timelineStart},${o.timelineEnd})";
          
          String drawText = "drawtext=fontfile='$fontPath':text='$escapedText':fontsize=${o.fontSize}";
          drawText += ":fontcolor=$hexColor:alpha=$alpha";
          if (bgAlpha > 0) {
            drawText += ":box=1:boxcolor=$bgHex@$bgAlpha:boxborderw=5";
          }
          drawText += ":x=$xCmd:y=$yCmd:enable='$enable'";
          
          textFilters.add(drawText);
        }
        
        if (textFilters.isNotEmpty) {
          final allDrawText = textFilters.join(',');
          final nextStream = 'v_text';
          filters.add('[$lastStream]$allDrawText[$nextStream]');
          lastStream = nextStream;
        }
      }
      
      // STEP 4: Final format conversion for compatibility
      final finalStream = 'v_final';
      filters.add('[$lastStream]format=yuv420p[$finalStream]');
      
      // Build final command
      if (bgMusicMixPath != null && bgMusicMixPath.isNotEmpty) {
        // bg mix is last input: index = 1 + imageOverlays.length
        final bgInputIdx = 1 + imageOverlays.length;
        // Mix main audio (0:a) with bg mix audio (bgInputIdx:a)
        filters.add('[0:a][${bgInputIdx}:a]amix=inputs=2:duration=longest:dropout_transition=0[aout]');
        args.add('-filter_complex');
        args.add(filters.join(';'));
        args.addAll([
          '-map', '[$finalStream]',
          '-map', '[aout]',
          '-c:v', 'libx264',
          '-preset', _getEncodingPreset(settings.width, settings.height),
          '-crf', '18',
          '-b:v', '${settings.videoBitrate}k',
          '-c:a', 'aac',
          '-b:a', '${settings.audioBitrate}k',
          '-r', settings.fps.toString(),
          '-y',
          outputPath,
        ]);
      } else {
        args.add('-filter_complex');
        args.add(filters.join(';'));
        args.addAll([
          '-map', '[$finalStream]',
          '-map', '0:a?',
          '-c:v', 'libx264',
          '-preset', _getEncodingPreset(settings.width, settings.height),
          '-crf', '18',
          '-b:v', '${settings.videoBitrate}k',
          '-c:a', 'aac',
          '-b:a', '${settings.audioBitrate}k',
          '-r', settings.fps.toString(),
          '-y',
          outputPath,
        ]);
      }
      
      print('[VideoMasteringService] ONE-PASS: Overlays + Scale + Encode combined');
      final success = await _runFFmpeg(args, taskId: taskId, onProgress: (time, {percent, fps, speed, eta}) {
        onProgress?.call(0.25 + 0.75 * (percent ?? (time / totalDuration).clamp(0, 1)), 
            'Encoding: ${(percent != null ? (percent * 100).toStringAsFixed(0) : '?')}%${eta != null ? ' | ETA: $eta' : ''}${fps != null ? ' | ${fps.toStringAsFixed(0)} FPS' : ''}${speed != null ? ' | ${speed.toStringAsFixed(1)}x' : ''}');
      });
      
      return success;
    } catch (e) {
      print('[VideoMasteringService] _exportWithOverlaysOnePass error: $e');
      return false;
    }
  }
}
