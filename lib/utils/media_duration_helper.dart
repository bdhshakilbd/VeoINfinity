/// Media Duration Helper
/// Uses media_kit (native APIs) to get video/audio duration without ffprobe
/// This is faster and doesn't require external executables

import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';

class MediaDurationHelper {
  /// Get video duration in seconds using media_kit (native, no ffprobe)
  /// This is much faster than spawning ffprobe processes
  static Future<double?> getVideoDuration(String filePath) async {
    if (!File(filePath).existsSync()) {
      print('[MediaDurationHelper] File not found: $filePath');
      return null;
    }
    
    Player? player;
    try {
      // Create a temporary player just to probe duration
      player = Player();
      
      // Completer to wait for duration
      final completer = Completer<double?>();
      bool completed = false;
      
      // Listen for duration changes
      final subscription = player.stream.duration.listen((duration) {
        if (!completed && duration.inMilliseconds > 0) {
          completed = true;
          completer.complete(duration.inMilliseconds / 1000.0);
        }
      });
      
      // Open the media file
      await player.open(Media(filePath), play: false);
      
      // Wait for duration with timeout
      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          print('[MediaDurationHelper] Timeout getting duration for: $filePath');
          return null;
        },
      );
      
      // Cleanup
      await subscription.cancel();
      await player.dispose();
      
      if (result != null && result > 0) {
        print('[MediaDurationHelper] Duration: ${result.toStringAsFixed(2)}s for $filePath');
      }
      
      return result;
    } catch (e) {
      print('[MediaDurationHelper] Error getting duration: $e');
      await player?.dispose();
      return null;
    }
  }
  
  /// Get durations for multiple files in parallel
  /// Much faster than sequential calls
  static Future<List<double?>> getVideoDurations(List<String> filePaths) async {
    final futures = filePaths.map((path) => getVideoDuration(path));
    return Future.wait(futures);
  }
  
  /// Get duration with fallback to a default value
  static Future<double> getVideoDurationOrDefault(String filePath, {double defaultDuration = 5.0}) async {
    final duration = await getVideoDuration(filePath);
    return duration ?? defaultDuration;
  }
}
