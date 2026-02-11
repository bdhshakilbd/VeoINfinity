import 'dart:io';
import 'package:path/path.dart' as path;

class FFmpegUtils {
  static String? _cachedFFmpegPath;
  static String? _cachedFFprobePath;

  /// Get the path to the FFmpeg executable
  static Future<String> getFFmpegPath() async {
    if (_cachedFFmpegPath != null) return _cachedFFmpegPath!;

    String binaryName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    
    // 1. Check local directory (App dir or Current dir)
    final localPaths = [
      path.join(path.dirname(Platform.resolvedExecutable), binaryName),
      path.join(Directory.current.path, binaryName),
    ];

    for (final p in localPaths) {
      if (await File(p).exists()) {
        _cachedFFmpegPath = p;
        return p;
      }
    }

    // 2. Check standard macOS locations
    if (Platform.isMacOS) {
      final macPaths = [
        '/opt/homebrew/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
        '/usr/bin/ffmpeg',
      ];
      for (final p in macPaths) {
        if (await File(p).exists()) {
          _cachedFFmpegPath = p;
          return p;
        }
      }
    }

    // 3. Fallback to system PATH
    // On macOS, Process.run('ffmpeg') might fail if PATH isn't inherited fully,
    // but it's the best we can do if we haven't found it elsewhere.
    _cachedFFmpegPath = binaryName;
    return binaryName;
  }

  /// Get the path to the FFprobe executable
  static Future<String> getFFprobePath() async {
    if (_cachedFFprobePath != null) return _cachedFFprobePath!;

    String binaryName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    
    // 1. Check local directory
    final localPaths = [
      path.join(path.dirname(Platform.resolvedExecutable), binaryName),
      path.join(Directory.current.path, binaryName),
    ];

    for (final p in localPaths) {
      if (await File(p).exists()) {
        _cachedFFprobePath = p;
        return p;
      }
    }

    // 2. Check standard macOS locations
    if (Platform.isMacOS) {
      final macPaths = [
        '/opt/homebrew/bin/ffprobe',
        '/usr/local/bin/ffprobe',
        '/usr/bin/ffprobe',
      ];
      for (final p in macPaths) {
        if (await File(p).exists()) {
          _cachedFFprobePath = p;
          return p;
        }
      }
    }

    // 3. Fallback to system PATH
    _cachedFFprobePath = binaryName;
    return binaryName;
  }
}
