import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../../models/story/alignment_item.dart';
import '../../models/story/story_audio_part.dart';

class StoryExportService {
  static const double maxAudioSpeedup = 1.50;
  static const double maxAudioSlowdown = 0.90;

  /// Get FFmpeg path - on Android use FFmpegKit, on Windows use local folder
  String _getFFmpegPath() {
    if (Platform.isAndroid) {
      return 'ffmpeg'; // Not used on Android - we use FFmpegKit
    }
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    return path.join(exeDir, 'ffmpeg.exe');
  }

  /// Get FFprobe path - same logic as FFmpeg
  String _getFFprobePath() {
    if (Platform.isAndroid) {
      return 'ffprobe'; // Not used on Android - we use FFprobeKit
    }
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    return path.join(exeDir, 'ffprobe.exe');
  }
  
  /// Run FFmpeg command - uses FFmpegKit on Android, Process.run on Windows
  Future<({int exitCode, String stdout, String stderr})> _runFFmpeg(List<String> args, {bool runInShell = true}) async {
    if (Platform.isAndroid) {
      final command = args.join(' ');
      print('[FFMPEG] Running: ffmpeg $command');
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      final output = await session.getOutput() ?? '';
      final logs = await session.getAllLogsAsString() ?? '';
      
      return (
        exitCode: ReturnCode.isSuccess(returnCode) ? 0 : (returnCode?.getValue() ?? -1),
        stdout: output,
        stderr: logs,
      );
    } else {
      final result = await Process.run(_getFFmpegPath(), args, runInShell: runInShell);
      return (
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      );
    }
  }

  /// Get media duration using ffprobe (FFprobeKit on Android)
  Future<double> getDuration(String filePath) async {
    print('[DURATION] Getting duration for: $filePath');
    print('[DURATION] Platform.isAndroid = ${Platform.isAndroid}');
    
    try {
      if (Platform.isAndroid) {
        print('[DURATION] Using FFprobeKit...');
        final session = await FFprobeKit.getMediaInformation(filePath);
        final info = session.getMediaInformation();
        if (info != null) {
          final durationStr = info.getDuration();
          print('[DURATION] FFprobeKit returned: $durationStr');
          if (durationStr != null) {
            return double.parse(durationStr);
          }
        }
        // Try to get duration from stream info if format info fails
        print('[DURATION] Format duration null, checking streams...');
        final streams = session.getMediaInformation()?.getStreams();
        if (streams != null && streams.isNotEmpty) {
          for (var stream in streams) {
            final streamDuration = stream.getAllProperties()?['duration'];
            if (streamDuration != null) {
              print('[DURATION] Got stream duration: $streamDuration');
              return double.parse(streamDuration.toString());
            }
          }
        }
        throw Exception('Could not get duration from FFprobeKit');
      }
      
      print('[DURATION] Using Process.run (Windows)...');
      final result = await Process.run(
        _getFFprobePath(),
        [
          '-v',
          'error',
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          filePath,
        ],
      );

      if (result.exitCode == 0) {
        final durationStr = result.stdout.toString().trim();
        return double.parse(durationStr);
      }

      throw Exception('ffprobe failed: ${result.stderr}');
    } catch (e) {
      print('[DURATION] Error: $e');
      throw Exception('Error getting duration: $e');
    }
  }

  /// Check if file has audio stream
  Future<bool> _hasAudioStream(String filePath) async {
    try {
      if (Platform.isAndroid) {
        final session = await FFprobeKit.getMediaInformation(filePath);
        final info = session.getMediaInformation();
        if (info != null) {
          final streams = info.getStreams();
          return streams.any((s) => s.getType() == 'audio');
        }
        return false;
      }
      
      final result = await Process.run(
        _getFFprobePath(),
        [
          '-v', 'error',
          '-select_streams', 'a',
          '-show_entries', 'stream=index',
          '-of', 'csv=p=0',
          filePath,
        ],
      );
      return result.stdout.toString().trim().isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Build atempo filter chain for any speed
  /// atempo only supports 0.5-2.0x range, so chain multiple filters if needed
  String buildAtempoFilter(double speed) {
    if (speed < 0.5 || speed > 100.0) {
      throw Exception('Speed must be between 0.5 and 100.0');
    }

    if (speed >= 0.5 && speed <= 2.0) {
      return 'atempo=$speed';
    }

    // Chain multiple atempo filters
    final filters = <String>[];
    var remainingSpeed = speed;

    while (remainingSpeed > 2.0) {
      filters.add('atempo=2.0');
      remainingSpeed /= 2.0;
    }

    while (remainingSpeed < 0.5) {
      filters.add('atempo=0.5');
      remainingSpeed /= 0.5;
    }

    if (remainingSpeed != 1.0) {
      filters.add('atempo=$remainingSpeed');
    }

    return filters.join(',');
  }

  /// Smart adjust for duration - limit speed adjustments and trim if needed
  Map<String, dynamic> smartAdjustForDuration({
    required double audioDuration,
    required double videoDuration,
    required int videoCount,
  }) {
    final speedFactor = audioDuration / videoDuration;

    // Limit speed adjustments
    double actualSpeed = speedFactor;
    double trimPerVideo = 0.0;

    if (speedFactor > maxAudioSpeedup) {
      actualSpeed = maxAudioSpeedup;
      final targetDuration = audioDuration / maxAudioSpeedup;
      trimPerVideo = (videoDuration - targetDuration) / videoCount;
    } else if (speedFactor < maxAudioSlowdown) {
      actualSpeed = maxAudioSlowdown;
      final targetDuration = audioDuration / maxAudioSlowdown;
      trimPerVideo = (videoDuration - targetDuration) / videoCount;
    }

    return {
      'speed': actualSpeed,
      'trimPerVideo': max(0.0, trimPerVideo),
    };
  }

  /// Concatenate videos without re-encoding
  Future<void> concatenateVideos({
    required List<String> videoPaths,
    required String outputPath,
  }) async {
    final tempDir = Directory(path.join(path.dirname(outputPath), 'temp_export'));
    await tempDir.create(recursive: true);

    final listFile = File(path.join(tempDir.path, 'concat_list.txt'));
    final listContent = StringBuffer();

    for (final videoPath in videoPaths) {
      // Escape single quotes for FFmpeg
      final escapedPath = videoPath.replaceAll("'", "'\\''\\'");
      listContent.writeln("file '$escapedPath'");
    }

    await listFile.writeAsString(listContent.toString());

    final result = await _runFFmpeg([
      '-y',
      '-f', 'concat',
      '-safe', '0',
      '-i', listFile.path,
      '-c', 'copy',
      outputPath,
    ]);

    if (result.exitCode != 0) {
      throw Exception('FFmpeg concatenation failed: ${result.stderr}');
    }
  }

  /// Export video using FAST method (adjust audio speed to match video duration)
  Future<void> exportVideoFast({
    required List<AlignmentItem> alignment,
    required List<StoryAudioPart> parts,
    required List<String> videoPaths,
    required String outputPath,
    required Function(int current, int total, String message) onProgress,
    double ttsVolume = 1.0,
    double videoVolume = 1.0,
  }) async {
    print('[EXPORT FAST] Starting export...');
    final tempDir = Directory(path.join(path.dirname(outputPath), 'temp_export'));
    await tempDir.create(recursive: true);

    final segments = <String>[];

    for (int i = 0; i < alignment.length; i++) {
      final item = alignment[i];
      onProgress(i + 1, alignment.length, 'Processing segment ${i + 1}/${alignment.length}');

      // Get audio file
      final part = parts.firstWhere((p) => p.index == item.audioPartIndex);
      if (part.audioPath == null || !await File(part.audioPath!).exists()) {
        throw Exception('Audio file not found for part ${part.index}');
      }

      // Get matching videos
      final matchingVideos = <String>[];
      for (final videoRef in item.matchingVideos) {
        // Extract index from id (e.g., "prompt1video" -> 0)
        final match = RegExp(r'prompt(\d+)video').firstMatch(videoRef.id);
        if (match != null) {
          final index = int.parse(match.group(1)!) - 1;
          if (index >= 0 && index < videoPaths.length) {
            matchingVideos.add(videoPaths[index]);
          }
        }
      }

      if (matchingVideos.isEmpty) {
        throw Exception('No matching videos for segment ${i + 1}');
      }

      // Compose segment
      final segmentPath = path.join(tempDir.path, 'segment_$i.mp4');
      await _composeSegmentFast(
        audioPath: part.audioPath!,
        videoPaths: matchingVideos,
        outputPath: segmentPath,
        tempDir: tempDir.path,
        ttsVolume: ttsVolume,
        videoVolume: videoVolume,
      );

      segments.add(segmentPath);
    }

    // Concatenate all segments
    onProgress(alignment.length, alignment.length, 'Concatenating segments...');
    await concatenateVideos(videoPaths: segments, outputPath: outputPath);

    // Cleanup
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}

    print('[EXPORT FAST] ✓ Complete: $outputPath');
  }

  /// Compose single segment using FAST method
  Future<void> _composeSegmentFast({
    required String audioPath,
    required List<String> videoPaths,
    required String outputPath,
    required String tempDir,
    required double ttsVolume,
    required double videoVolume,
  }) async {
    // ENSURE temp directory exists
    await Directory(tempDir).create(recursive: true);
    
    // Step 1: Concatenate videos
    final concatVideoPath = path.join(tempDir, 'concat_${path.basename(outputPath)}');
    await concatenateVideos(videoPaths: videoPaths, outputPath: concatVideoPath);

    // Step 2: Get durations
    final audioDuration = await getDuration(audioPath);
    final videoDuration = await getDuration(concatVideoPath);

    // Step 3: Smart adjust
    final adjustment = smartAdjustForDuration(
      audioDuration: audioDuration,
      videoDuration: videoDuration,
      videoCount: videoPaths.length,
    );

    final speed = adjustment['speed'] as double;
    final trimPerVideo = adjustment['trimPerVideo'] as double;

    // Step 4: Trim video if needed
    String videoToUse = concatVideoPath;
    if (trimPerVideo > 0) {
      final trimmedPath = path.join(tempDir, 'trimmed_${path.basename(outputPath)}');
      final targetDuration = videoDuration - (trimPerVideo * videoPaths.length);

      final result = await _runFFmpeg([
          '-y',
          '-i',
          concatVideoPath,
          '-t',
          targetDuration.toString(),
          '-c',
          'copy',
          trimmedPath,
        ]);

      if (result.exitCode == 0) {
        videoToUse = trimmedPath;
      }
    }

    // Step 5: Adjust audio speed (TTS)
    final adjustedAudioPath = path.join(tempDir, 'adjusted_audio_${path.basename(outputPath)}.aac');
    final atempoFilter = buildAtempoFilter(speed);

    var result = await _runFFmpeg([
        '-y',
        '-i',
        audioPath,
        '-filter:a',
        atempoFilter,
        '-vn',
        adjustedAudioPath,
      ]);

    if (result.exitCode != 0) {
      throw Exception('Audio speed adjustment failed: ${result.stderr}');
    }

    // Step 6: Combine video + adjusted audio (Mixed)
    final hasVideoAudio = await _hasAudioStream(videoToUse);
    final inputs = ['-y', '-i', videoToUse, '-i', adjustedAudioPath];
    final maps = ['-map', '0:v:0'];
    String? filterComplex;

    if (hasVideoAudio) {
      // Mix: [0:a] is video, [1:a] is TTS
      filterComplex = '[0:a]volume=$videoVolume[a1];[1:a]volume=$ttsVolume[a2];[a1][a2]amix=inputs=2:duration=first[outa]';
      maps.addAll(['-map', '[outa]']);
    } else {
      // Just TTS (apply volume)
      if (ttsVolume != 1.0) {
        filterComplex = '[1:a]volume=$ttsVolume[outa]';
        maps.addAll(['-map', '[outa]']);
      } else {
        maps.addAll(['-map', '1:a:0']);
      }
    }

    final args = [...inputs];
    if (filterComplex != null) {
      args.addAll(['-filter_complex', filterComplex]);
    }
    
    // Note: If using filter_complex with streams from input 0 and 1, we must re-encode audio. Video can be copied.
    args.addAll(['-c:v', 'copy', '-c:a', 'aac', ...maps, '-shortest', outputPath]);

    result = await _runFFmpeg(args);

    if (result.exitCode != 0) {
      throw Exception('Video/audio combination failed: ${result.stderr}');
    }
  }

  /// Export video using PRECISE method (adjust video speed to match audio duration)
  Future<void> exportVideoPrecise({
    required List<AlignmentItem> alignment,
    required List<StoryAudioPart> parts,
    required List<String> videoPaths,
    required String outputPath,
    required Function(int current, int total, String message) onProgress,
    double ttsVolume = 1.0,
    double videoVolume = 1.0,
  }) async {
    print('[EXPORT PRECISE] Starting export...');
    final tempDir = Directory(path.join(path.dirname(outputPath), 'temp_export'));
    await tempDir.create(recursive: true);

    final segments = <String>[];

    for (int i = 0; i < alignment.length; i++) {
      final item = alignment[i];
      onProgress(i + 1, alignment.length, 'Processing segment ${i + 1}/${alignment.length}');

      // Get audio file
      final part = parts.firstWhere((p) => p.index == item.audioPartIndex);
      if (part.audioPath == null || !await File(part.audioPath!).exists()) {
        throw Exception('Audio file not found for part ${part.index}');
      }

      // Get matching videos
      final matchingVideos = <String>[];
      for (final videoRef in item.matchingVideos) {
        final match = RegExp(r'prompt(\d+)video').firstMatch(videoRef.id);
        if (match != null) {
          final index = int.parse(match.group(1)!) - 1;
          if (index >= 0 && index < videoPaths.length) {
            matchingVideos.add(videoPaths[index]);
          }
        }
      }

      if (matchingVideos.isEmpty) {
        throw Exception('No matching videos for segment ${i + 1}');
      }

      // Compose segment
      final segmentPath = path.join(tempDir.path, 'segment_$i.mp4');
      await _composeSegmentPrecise(
        audioPath: part.audioPath!,
        videos: matchingVideos.map((p) => {'path': p, 'muted': false}).toList(), // Default unmuted for old method
        outputPath: segmentPath,
        tempDir: tempDir.path,
        ttsVolume: ttsVolume,
        videoVolume: videoVolume,
      );

      segments.add(segmentPath);
    }

    // Concatenate all segments
    onProgress(alignment.length, alignment.length, 'Concatenating segments...');
    await concatenateVideos(videoPaths: segments, outputPath: outputPath);

    // Cleanup
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}

    print('[EXPORT PRECISE] ✓ Complete: $outputPath');
  }

  /// Export Reel Project directly from scene data
  Future<void> exportReel({
    required List<dynamic> scenes,
    required String outputPath,
    required Function(int current, int total, String message) onProgress,
    double ttsVolume = 1.0,
    double videoVolume = 1.0,
    String method = 'precise', // 'fast' or 'precise'
    double playbackSpeed = 1.0,
  }) async {
    print('[EXPORT REEL] Starting export...');
    
    // ENSURE output directory exists
    await Directory(path.dirname(outputPath)).create(recursive: true);
    
    // Step 1: Verify all required files exist before starting export
    onProgress(0, 1, 'Verifying files...');
    final missingFiles = <String>[];
    
    for (int i = 0; i < scenes.length; i++) {
      final scene = scenes[i];
      if (scene['active'] == false && scene['visuals'] == null) continue;
      
      // Check audio files (if TTS not muted)
      final isTtsMuted = scene['tts_muted'] == true;
      if (!isTtsMuted) {
        final audioPath = scene['audio_path'] as String?;
        if (audioPath != null) {
          // Refresh file system check
          await Future.delayed(Duration(milliseconds: 100));
          if (!await File(audioPath).exists()) {
            missingFiles.add('Audio: $audioPath');
          }
        }
      }
      
      // Check video files
      if (scene['visuals'] != null) {
        final visuals = scene['visuals'] as List;
        for (var v in visuals) {
          if (v['active'] != false && v['video_path'] != null) {
            final videoPath = v['video_path'] as String;
            // Refresh file system check
            await Future.delayed(Duration(milliseconds: 100));
            if (!await File(videoPath).exists()) {
              missingFiles.add('Video: $videoPath');
            }
          }
        }
      } else {
        final videoPath = scene['video_path'] as String?;
        if (videoPath != null) {
          // Refresh file system check
          await Future.delayed(Duration(milliseconds: 100));
          if (!await File(videoPath).exists()) {
            missingFiles.add('Video: $videoPath');
          }
        }
      }
    }
    
    if (missingFiles.isNotEmpty) {
      final errorMsg = 'Missing files:\n${missingFiles.join('\n')}';
      print('[EXPORT REEL] ✗ $errorMsg');
      throw Exception(errorMsg);
    }
    
    print('[EXPORT REEL] ✓ All files verified');
    
    final tempDir = Directory(path.join(path.dirname(outputPath), 'temp_export_${DateTime.now().millisecondsSinceEpoch}'));
    await tempDir.create(recursive: true);

    final segments = <String>[];
    int activeCount = scenes.where((s) => s['active'] == true).length;
    int processedCount = 0;

    for (int i = 0; i < scenes.length; i++) {
      final scene = scenes[i];
      if (scene['active'] == false && scene['visuals'] == null) continue; // Check active only if flat, or check later for nested

      processedCount++;
      onProgress(processedCount, activeCount, 'Processing segment ${i + 1} ($processedCount/$activeCount)');

      String? audioPath = scene['audio_path'];
      List<Map<String, dynamic>> videoData = [];
      
      // Handle Nested Structure (Audio -> Multiple Visuals)
      if (scene['visuals'] != null) {
          final visuals = scene['visuals'] as List;
          for (var v in visuals) {
             if (v['active'] != false && v['video_path'] != null) {
                 if (await File(v['video_path']).exists()) {
                    videoData.add({
                       'path': v['video_path'],
                       'muted': v['is_muted'] ?? false,
                    });
                 }
             }
          }
      } else {
         // Handle Flat Structure (1:1)
         if (scene['video_path'] != null && await File(scene['video_path']).exists()) {
             videoData.add({
                'path': scene['video_path'],
                'muted': false, // Default unmuted for flat
             });
         }
      }
      
      // Check if TTS is muted for this segment
      final isTtsMuted = scene['tts_muted'] == true;
      
      if (!isTtsMuted && (audioPath == null || !await File(audioPath).exists())) {
         print('Skipping segment $i: Missing audio (TTS not muted).');
         continue;
      }
      
      if (videoData.isEmpty) {
         print('Skipping segment $i: No valid videos.');
         continue;
      }

      // Compose segment using selected method
      final segmentPath = path.join(tempDir.path, 'segment_$i.mp4');
      
      if (isTtsMuted) {
         // TTS Muted: Just concatenate videos with their original audio
         final videoPaths = videoData.map((v) => v['path'] as String).toList();
         if (videoPaths.length == 1) {
            // Single video: copy directly
            await File(videoPaths[0]).copy(segmentPath);
         } else {
            // Multiple videos: concatenate them
            await concatenateVideos(videoPaths: videoPaths, outputPath: segmentPath);
         }
         // Apply video volume if needed
         if (videoVolume != 1.0) {
            final adjustedPath = path.join(tempDir.path, 'vol_segment_$i.mp4');
            await _runFFmpeg(['-y', '-i', segmentPath, '-af', 'volume=$videoVolume', '-c:v', 'copy', adjustedPath]);
            await File(adjustedPath).rename(segmentPath);
         }
      } else if (method == 'fast') {
        // Fast: Adjust audio speed
        final videoPaths = videoData.map((v) => v['path'] as String).toList();
        await _composeSegmentFast(
          audioPath: audioPath!,
          videoPaths: videoPaths,
          outputPath: segmentPath,
          tempDir: tempDir.path,
          ttsVolume: ttsVolume,
          videoVolume: videoVolume,
        );
      } else {
        // Precise: Adjust video speed
        await _composeSegmentPrecise(
          audioPath: audioPath!,
          videos: videoData,
          outputPath: segmentPath,
          tempDir: tempDir.path,
          ttsVolume: ttsVolume,
          videoVolume: videoVolume,
        );
      }

      segments.add(segmentPath);
    }

    if (segments.isEmpty) {
      throw Exception('No valid segments to export.');
    }

    // Concatenate all segments
    onProgress(activeCount, activeCount, 'Concatenating segments...');
    await concatenateVideos(videoPaths: segments, outputPath: outputPath);
    
    // Apply Global Playback Speed if needed
    if ((playbackSpeed - 1.0).abs() > 0.01) {
       onProgress(activeCount, activeCount, 'Applying global speed ($playbackSpeed)...');
       
       final tempConcat = path.join(tempDir.path, 'temp_concat_full.mp4');
       if (await File(tempConcat).exists()) {
         await File(tempConcat).delete();
       }
       await File(outputPath).rename(tempConcat);
       
       final atempoFilter = buildAtempoFilter(playbackSpeed);
       
       final args = [
          '-y', '-i', tempConcat,
          '-filter_complex', '[0:v]setpts=PTS/$playbackSpeed[v];[0:a]$atempoFilter[a]',
          '-map', '[v]', '-map', '[a]',
          '-c:v', 'libx264', '-preset', 'fast', '-crf', '23',
          '-c:a', 'aac',
          outputPath
       ];
       
       final result = await Process.run(
         _getFFmpegPath(),
         args,
         runInShell: true,
       );
       
       if (result.exitCode != 0) {
         throw Exception('Global speed adjustment failed: ${result.stderr}');
       }
    }

    // Cleanup
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}

    print('[EXPORT REEL] ✓ Complete: $outputPath');
  }

  /// Compose single segment using PRECISE method
  Future<void> _composeSegmentPrecise({
    required String audioPath,
    required List<Map<String, dynamic>> videos,
    required String outputPath,
    required String tempDir,
    required double ttsVolume,
    required double videoVolume,
  }) async {
    // ENSURE temp directory exists
    await Directory(tempDir).create(recursive: true);
    
    // Step 1: Get audio duration
    final audioDuration = await getDuration(audioPath);
    final perVideoDuration = audioDuration / videos.length;

    // Step 2: Adjust each video's speed
    final adjustedVideos = <String>[];

    for (int i = 0; i < videos.length; i++) {
      final videoData = videos[i];
      final videoPath = videoData['path'] as String;
      final isMuted = videoData['muted'] as bool;
      
      
      final videoDuration = await getDuration(videoPath);
      
      // Validate durations
      if (perVideoDuration <= 0) {
        throw Exception('Invalid audio duration: $perVideoDuration (audio: $audioDuration, videos: ${videos.length})');
      }
      if (videoDuration <= 0) {
        throw Exception('Invalid video duration for: $videoPath');
      }
      
      final speedFactor = videoDuration / perVideoDuration;
      
      // Log extreme speeds but don't clamp - buildAtempoFilter will chain filters
      if (speedFactor < 0.5 || speedFactor > 2.0) {
        print('[EXPORT] Extreme speed factor: $speedFactor (video: ${videoDuration}s, target: ${perVideoDuration}s)');
        print('[EXPORT] Will use chained atempo filters to achieve this speed');
      }
      
      final hasAudio = await _hasAudioStream(videoPath);
      final useSilence = isMuted || !hasAudio;

      final adjustedPath = path.join(tempDir, 'adjusted_video_$i.mp4');
      final targetDuration = perVideoDuration; // Approximate, but sufficient for silence gen

      // Build filters
      final setptsFilter = '[0:v]setpts=${1 / speedFactor}*PTS[v]';
      
      final args = <String>['-y', '-i', videoPath];
      String? filterComplex;
      final maps = <String>[];

      if (useSilence) {
          // Generate silence
          args.addAll([
             '-f', 'lavfi', 
             '-t', targetDuration.toStringAsFixed(4),
             '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100',
          ]);
          filterComplex = setptsFilter; // Just video filter, audio is raw
          maps.addAll(['-map', '[v]', '-map', '1:a']);
      } else {
          // Use original audio - buildAtempoFilter will chain filters if needed
          final atempoFilter = buildAtempoFilter(speedFactor);
          filterComplex = '$setptsFilter;[0:a]$atempoFilter[a]';
          maps.addAll(['-map', '[v]', '-map', '[a]']);
      }

      args.addAll([
          '-filter_complex', filterComplex!,
          ...maps,
          '-c:v', 'libx264',
          '-preset', 'veryfast',
          '-crf', '28',
          '-c:a', 'aac',
          '-shortest', // Ensure match
          adjustedPath
      ]);

      final result = await _runFFmpeg(args);

      if (result.exitCode != 0) {
        throw Exception('Video speed adjustment/silence gen failed: ${result.stderr}');
      }

      adjustedVideos.add(adjustedPath);
    }

    // Step 3: Concatenate adjusted videos
    final concatVideoPath = path.join(tempDir, 'concat_${path.basename(outputPath)}');
    await concatenateVideos(videoPaths: adjustedVideos, outputPath: concatVideoPath);

    // Step 4: Combine with audio (Mixing logic)
    final hasVideoAudio = await _hasAudioStream(concatVideoPath);
    final inputs = ['-y', '-i', concatVideoPath, '-i', audioPath];
    final maps = ['-map', '0:v:0'];
    String? filterComplex;

    if (hasVideoAudio) {
      filterComplex = '[0:a]volume=$videoVolume[a1];[1:a]volume=$ttsVolume[a2];[a1][a2]amix=inputs=2:duration=first[outa]';
      maps.addAll(['-map', '[outa]']);
    } else {
      if (ttsVolume != 1.0) {
        filterComplex = '[1:a]volume=$ttsVolume[outa]';
        maps.addAll(['-map', '[outa]']);
      } else {
        maps.addAll(['-map', '1:a:0']);
      }
    }
    
    final args = [...inputs];
    if (filterComplex != null) {
      args.addAll(['-filter_complex', filterComplex]);
    }
    
    // Re-encode audio, copy video
    args.addAll(['-c:v', 'copy', '-c:a', 'aac', ...maps, '-shortest', outputPath]);

    // Use _runFFmpeg to properly handle Android (FFmpegKit) vs Desktop (Process.run)
    final result = await _runFFmpeg(args);

    if (result.exitCode != 0) {
      throw Exception('Video/audio combination failed: ${result.stderr}');
    }
  }
}
