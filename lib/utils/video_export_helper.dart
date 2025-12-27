import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/foundation.dart';

class ExportStatus {
  static final ValueNotifier<bool> isExporting = ValueNotifier(false);
  static final ValueNotifier<double?> progress = ValueNotifier(null);
  static final ValueNotifier<String> message = ValueNotifier('');
  
  static VoidCallback? _cancelCallback;
  
  static void registerCancelCallback(VoidCallback callback) {
    _cancelCallback = callback;
  }
  
  static void cancel() {
    if (isExporting.value) {
       message.value = 'Cancelling...';
       _cancelCallback?.call();
    }
  }

  static void start(String msg) {
    _cancelCallback = null;
    isExporting.value = true;
    message.value = msg;
    progress.value = 0.0;
  }
  
  static void update(String msg, double? prog) {
    message.value = msg;
    if (prog != null) progress.value = prog;
  }
  
  static void finish() {
    isExporting.value = false;
    message.value = '';
    progress.value = null;
  }
}

class VideoExportHelper {
  /// Fast copy mode (no re-encoding)
  static Future<void> concatenateFastCopy(
    List<PlatformFile> files,
    String outputPath,
    String ffmpegPath,
    String tempDir,
    {Function(String message, double? progress)? onProgress}
  ) async {
    // Create file list for FFmpeg
    final listFile = File(path.join(tempDir, 'concat_list.txt'));
    final listContent = StringBuffer();
    
    for (final file in files) {
      if (file.path != null) {
        final escapedPath = file.path!.replaceAll("'", "'\\''");
        listContent.writeln("file '$escapedPath'");
      }
    }
    
    await listFile.writeAsString(listContent.toString());

    onProgress?.call('Fast copy mode (no re-encoding)...', null);

    if (Platform.isAndroid || Platform.isIOS) {
      // Use FFmpegKit on mobile
      final command = '-y -f concat -safe 0 -i "${listFile.path}" -c copy "$outputPath"';
      
      print('[FFMPEG KIT] Running: $command');
      
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      
      // Clean up
      try { await listFile.delete(); } catch (_) {}
      
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        print('[FFMPEG KIT] Error: $logs');
        throw Exception('FFmpeg error - check console for details');
      }
    } else {
      // Use Process on desktop
      final process = await Process.start(
        ffmpegPath,
        [
          '-y',
          '-f', 'concat',
          '-safe', '0',
          '-i', listFile.path,
          '-c', 'copy',
          outputPath,
        ],
        runInShell: true,
      );

      process.stderr.transform(utf8.decoder).listen((data) {
        print('[FFMPEG] $data');
      });

      final exitCode = await process.exitCode;

      // Clean up
      try { await listFile.delete(); } catch (_) {}

      if (exitCode != 0) {
        throw Exception('FFmpeg error - check console for details');
      }
    }
  }

  /// Re-encode using filter_complex to normalize resolution and frame rate
  /// This fixes AV sync issues and supports mixing different resolutions
  static Future<void> concatenateWithReEncode(
    List<PlatformFile> files,
    String outputPath,
    String ffmpegPath,
    String tempDir,
    String resolution,
    double speed,
    {Function(String message, double? progress)? onProgress,
     String aspectRatio = 'original'}
  ) async {
    // 0. Pre-calculate total duration for progress tracking
    double totalDuration = 0;
    int probedCount = 0;
    
    // Only probe if reasonable number of files (avoid long wait for 100+ files)
    if (files.length < 50) {
      for (final file in files) {
         probedCount++;
         onProgress?.call('Analyzing videos ($probedCount/${files.length})...', 0.0);
         try {
           if (file.path != null) {
             final d = await getVideoDuration(file.path!);
             if (d != null) totalDuration += d;
           }
         } catch (_) {}
      }
      
      // Adjust expected total duration by speed
      if (speed > 0) totalDuration = totalDuration / speed;
      
    } else {
       onProgress?.call('Skipping analysis (too many files)...', 0.0);
    }

    // 1. Determine Target Dimensions
    int targetWidth = 1920;
    int targetHeight = 1080;
    
    bool detectedDimensions = false;

    if (resolution == 'original' && aspectRatio == 'original') {
      onProgress?.call('Establishing resolution...', 0.0);
      try {
        if (files.isNotEmpty && files.first.path != null) {
           final dims = await getVideoDimensions(files.first.path!);
           if (dims != null) {
             targetWidth = dims['width']!;
             targetHeight = dims['height']!;
             // Ensure even dimensions
             if (targetWidth % 2 != 0) targetWidth++;
             if (targetHeight % 2 != 0) targetHeight++;
             detectedDimensions = true;
           }
        }
      } catch (e) {
        print('Error probing first file: $e');
      }
    } 
    
    if (!detectedDimensions) {
       // Logic for explicit resolution or fallback
       int longEdge = 1920;
       switch (resolution) {
         case '2k': longEdge = 2560; break;
         case '4k': longEdge = 3840; break;
         default: longEdge = 1920;
       }
       
       if (aspectRatio == '16:9') {
         targetWidth = longEdge;
         targetHeight = (longEdge * 9 / 16).round();
       } else if (aspectRatio == '9:16') {
         targetWidth = (longEdge * 9 / 16).round();
         targetHeight = longEdge;
       } else if (aspectRatio == '1:1') {
         targetWidth = (longEdge * 9 / 16).round(); 
         targetHeight = targetWidth; // square uses shorter side of HD? No, let's use 1080x1080
         if (longEdge == 1920) { targetWidth=1080; targetHeight=1080; }
         else { targetWidth=(longEdge/1.77).round(); targetHeight=targetWidth;}
       } else if (aspectRatio == '4:5') {
         targetHeight = longEdge; // e.g. 1920
         targetWidth = (longEdge * 4 / 5).round(); 
         if (longEdge == 1920) { targetHeight=1350; targetWidth=1080; } // Instagram standard 1080x1350
       } else {
         // Default generic
         targetWidth = longEdge;
         targetHeight = (longEdge * 9 / 16).round();
       }
       
       // Ensure even
       targetWidth = (targetWidth ~/ 2) * 2;
       targetHeight = (targetHeight ~/ 2) * 2;
    }

    onProgress?.call('Building export command...', 0.0);

    // 2. Build Complex Filter Command
    final complexFilter = StringBuffer();
    final commandParts = <String>['-y'];
    
    // Inputs
    for (var i = 0; i < files.length; i++) {
      if (files[i].path == null) continue;
      commandParts.addAll(['-i', files[i].path!]);
    }
    
    // Normalization Filter Chain
    // Normalize every input to the target resolution, fps, and format
    for (var i = 0; i < files.length; i++) {
        // [i:v]scale=W:H:force_original_aspect_ratio=decrease,pad=W:H:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v_i]
        complexFilter.write('[$i:v]scale=$targetWidth:$targetHeight:force_original_aspect_ratio=decrease,pad=$targetWidth:$targetHeight:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v$i];');
        
        // Audio normalization: specific sample rate and layout
        complexFilter.write('[$i:a]aformat=sample_rates=44100:channel_layouts=stereo[a$i];');
    }
    
    // Concat Filter
    for (var i = 0; i < files.length; i++) {
      complexFilter.write('[v$i][a$i]');
    }
    complexFilter.write('concat=n=${files.length}:v=1:a=1[v_concat][a_concat]');

    // Speed Filter (applied to concatenated stream)
    String vOutMap = '[v_concat]';
    String aOutMap = '[a_concat]';
    
    if ((speed - 1.0).abs() > 0.01) {
       complexFilter.write(';'); // Separator
       
       // Video Speed
       final pts = (1.0/speed).toStringAsFixed(6);
       complexFilter.write('[v_concat]setpts=$pts*PTS[v_speed];');
       vOutMap = '[v_speed]';
       
       // Audio Speed
       final atempoFilters = <String>[];
       var remainingSpeed = speed;
       while (remainingSpeed > 2.0) { atempoFilters.add('atempo=2.0'); remainingSpeed /= 2.0; }
       while (remainingSpeed < 0.5) { atempoFilters.add('atempo=0.5'); remainingSpeed *= 2.0; }
       if ((remainingSpeed - 1.0).abs() > 0.01) { atempoFilters.add('atempo=${remainingSpeed.toStringAsFixed(6)}'); }
       
       if (atempoFilters.isNotEmpty) {
          complexFilter.write('[a_concat]${atempoFilters.join(',')}[a_speed]');
          aOutMap = '[a_speed]';
       } else {
          // No remaining change needed (e.g. speed was 1.0)
          aOutMap = '[a_concat]';
       }
    }
    
    commandParts.addAll(['-filter_complex', complexFilter.toString()]);
    commandParts.addAll(['-map', vOutMap, '-map', aOutMap]);
    
    // Encoding options
    commandParts.addAll([
        '-c:v', 'libx264',
        '-preset', 'fast',
        '-crf', '23',
        '-c:a', 'aac',
        '-b:a', '192k',
        outputPath
    ]);

    // Execute
    final commandString = commandParts.join(' '); // For logging
    print('[FFMPEG] Running complex filter export...');
    
    DateTime startTime = DateTime.now();
    
    if (Platform.isAndroid || Platform.isIOS) {
       // Register cancel callback for Mobile
       ExportStatus.registerCancelCallback(() {
          FFmpegKit.cancel();
       });

       // FFmpegKit
       
       // RE-construct command string carefully
       final sb = StringBuffer();
       sb.write('-y ');
       for (var i=0; i<files.length; i++) {
          if (files[i].path != null) {
            sb.write('-i "${files[i].path}" ');
          }
       }
       sb.write('-filter_complex "${complexFilter.toString()}" ');
       sb.write('-map "$vOutMap" -map "$aOutMap" ');
       sb.write('-c:v libx264 -preset fast -crf 23 -c:a aac -b:a 192k ');
       sb.write('"$outputPath"');
       
       final fullCmd = sb.toString();
       print('[FFMPEG KIT] CMD: $fullCmd');
       
       FFmpegKitConfig.enableStatisticsCallback((statistics) {
          final time = statistics.getTime(); // ms
          if (time > 0) {
            final secondsProcessed = time / 1000.0;
            
            String msg = 'Processed ${secondsProcessed.toStringAsFixed(1)}s';
            double? pct;
            
            if (totalDuration > 0) {
              pct = (secondsProcessed / totalDuration).clamp(0.0, 1.0);
              final pctStr = (pct * 100).toStringAsFixed(1);
              
              // ETA calculation
              final elapsed = DateTime.now().difference(startTime).inSeconds;
              if (pct > 0.05 && elapsed > 2) {
                 final totalEst = elapsed / pct;
                 final remaining = (totalEst - elapsed).round();
                 final remDuration = Duration(seconds: remaining);
                 msg = '$pctStr% - ETA: ${_formatDuration(remDuration)}';
              } else {
                 msg = '$pctStr% processed';
              }
            }
            
            onProgress?.call(msg, pct);
          }
       });
       
       final session = await FFmpegKit.execute(fullCmd);
       if (!ReturnCode.isSuccess(await session.getReturnCode())) {
           final logs = await session.getAllLogsAsString();
           print('Error: $logs');
           throw Exception('Export failed');
       }
    } else {
       // Desktop Process.start
       final process = await Process.start(ffmpegPath, commandParts, runInShell: true);
       // ... monitor stdout/stderr similar to before ...
       // Simplify monitoring for now to save SLOC, just wait for exit
       process.stderr.transform(utf8.decoder).listen((data) => print(data));
       
       // We can implement progress parsing here if needed
       // reusing previous logic if possible, or simplified
         process.stdout.transform(utf8.decoder).listen((data) {
           if (data.contains('time=')) {
              // rough parsing
              onProgress?.call('Processing...', null);
           }
         });

       if (await process.exitCode != 0) {
          throw Exception('Export failed');
       }
    }
    
    onProgress?.call('Export complete!', 1.0);
  }
  
  /// Concatenate video files (simple wrapper)
  static Future<void> concatenateVideos(
    List<String> videoPaths,
    String outputPath,
    String tempDir,
    {Function(String message, double? progress)? onProgress}
  ) async {
    // Create file list
    final listFile = File(path.join(tempDir, 'concat_list.txt'));
    final listContent = StringBuffer();
    
    for (final videoPath in videoPaths) {
      final escapedPath = videoPath.replaceAll("'", "'\\''");
      listContent.writeln("file '$escapedPath'");
    }
    
    await listFile.writeAsString(listContent.toString());

    onProgress?.call('Concatenating ${videoPaths.length} videos...', null);

    if (Platform.isAndroid || Platform.isIOS) {
      final command = '-y -f concat -safe 0 -i "${listFile.path}" -c copy "$outputPath"';
      
      print('[FFMPEG KIT] Running: $command');
      
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      
      try { await listFile.delete(); } catch (_) {}
      
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString();
        print('[FFMPEG KIT] Error: $logs');
        throw Exception('FFmpeg concatenation error');
      }
    } else {
      // Find FFmpeg on desktop
      String ffmpegPath = 'ffmpeg';
      if (Platform.isWindows) {
        // Check common locations
        final possiblePaths = [
          'ffmpeg.exe',
          'bin/ffmpeg.exe',
          'C:/ffmpeg/bin/ffmpeg.exe',
          'C:/Program Files/ffmpeg/bin/ffmpeg.exe',
        ];
        for (final p in possiblePaths) {
          if (await File(p).exists()) {
            ffmpegPath = p;
            break;
          }
        }
      }
      
      final process = await Process.start(
        ffmpegPath,
        ['-y', '-f', 'concat', '-safe', '0', '-i', listFile.path, '-c', 'copy', outputPath],
        runInShell: true,
      );

      process.stderr.transform(utf8.decoder).listen((data) {
        print('[FFMPEG] $data');
      });

      final exitCode = await process.exitCode;
      
      try { await listFile.delete(); } catch (_) {}

      if (exitCode != 0) {
        throw Exception('FFmpeg concatenation error');
      }
    }
    
    onProgress?.call('Concatenation complete!', 1.0);
  }
  
  /// Get media duration in seconds using FFprobe
  /// Works on both mobile (FFmpegKit) and desktop (ffprobe process)
  static Future<double?> getMediaDuration(String filePath, {String? ffprobePath}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Use FFprobeKit on mobile
      try {
        final session = await FFprobeKit.getMediaInformation(filePath);
        final info = session.getMediaInformation();
        
        if (info != null) {
          final durationStr = info.getDuration();
          if (durationStr != null) {
            return double.tryParse(durationStr);
          }
        }
      } catch (e) {
        print('[FFPROBE KIT] Error getting duration: $e');
      }
      return null;
    } else {
      // Use ffprobe process on desktop
      try {
        final probePath = ffprobePath ?? (Platform.isWindows ? 'ffprobe.exe' : 'ffprobe');
        
        final result = await Process.run(
          probePath,
          [
            '-v', 'error',
            '-show_entries', 'format=duration',
            '-of', 'default=noprint_wrappers=1:nokey=1',
            filePath,
          ],
          runInShell: true,
        );
        
        if (result.exitCode == 0) {
          final output = result.stdout.toString().trim();
          return double.tryParse(output);
        }
      } catch (e) {
        print('[FFPROBE] Error getting duration: $e');
      }
      return null;
    }
  }
  
  /// Get audio duration in seconds (wrapper for getMediaDuration)
  static Future<double?> getAudioDuration(String audioPath, {String? ffprobePath}) async {
    return getMediaDuration(audioPath, ffprobePath: ffprobePath);
  }
  
  /// Get video duration in seconds (wrapper for getMediaDuration)
  static Future<double?> getVideoDuration(String videoPath, {String? ffprobePath}) async {
    return getMediaDuration(videoPath, ffprobePath: ffprobePath);
  }

  static String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Get video dimensions (width, height)
  static Future<Map<String, int>?> getVideoDimensions(String filePath, {String? ffprobePath}) async {
    if (Platform.isAndroid || Platform.isIOS) {
       try {
         final session = await FFprobeKit.getMediaInformation(filePath);
         final info = session.getMediaInformation();
         if (info != null) {
            final streams = info.getStreams();
            // Check streams is meant to be a Javascript array style or Java list?
            // In Flutter ffmpeg_kit, getStreams returns List<StreamInformation>
            for (final stream in streams) {
               if (stream.getType() == 'video') {
                  final w = stream.getWidth();
                  final h = stream.getHeight();
                  if (w != null && h != null) return {'width': w.toInt(), 'height': h.toInt()};
               }
            }
         }
       } catch (e) {
         print('[FFPROBE KIT] Error getting dimensions: $e');
       }
    } else {
       // Desktop
       try {
        final probePath = ffprobePath ?? (Platform.isWindows ? 'ffprobe.exe' : 'ffprobe');
        final result = await Process.run(probePath, [
           '-v', 'error',
           '-select_streams', 'v:0',
           '-show_entries', 'stream=width,height',
           '-of', 'csv=s=x:p=0',
           filePath
        ], runInShell: true);
        if (result.exitCode == 0) {
           final parts = result.stdout.toString().trim().split('x');
           if (parts.length == 2) {
              return {
                 'width': int.parse(parts[0]),
                 'height': int.parse(parts[1])
              };
           }
        }
       } catch (e) {
          print('[FFPROBE] Error: $e');
       }
    }
    return null;
  }
}
