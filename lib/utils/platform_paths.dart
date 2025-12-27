import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

/// Cross-platform path utility for handling file storage across all platforms
/// 
/// Android: /storage/emulated/0/veo3/
/// iOS: /var/mobile/Containers/Data/Application/{UUID}/Documents/veo3/
/// Windows: C:/Users/{username}/Documents/veo3/
class PlatformPaths {
  static String? _cachedBasePath;
  static String? _cachedProjectsPath;
  static String? _cachedVideosPath;
  static String? _cachedReelsPath;

  /// Get the base veo3 directory path
  /// 
  /// Android: /storage/emulated/0/veo3
  /// iOS: {Documents}/veo3 (app-sandboxed)
  /// macOS: ~/Documents/veo3 (user-accessible)
  /// Windows: {Documents}/veo3
  static Future<String> getBasePath() async {
    if (_cachedBasePath != null) return _cachedBasePath!;

    if (Platform.isAndroid) {
      // Android: Use public external storage
      _cachedBasePath = '/storage/emulated/0/veo3';
    } else if (Platform.isIOS) {
      // iOS: Use app's Documents directory (private, backed up to iCloud)
      final docDir = await getApplicationDocumentsDirectory();
      _cachedBasePath = path.join(docDir.path, 'veo3');
    } else if (Platform.isMacOS) {
      // macOS: Use user's Documents folder (public, user-accessible)
      // On macOS, getApplicationDocumentsDirectory returns ~/Library/Containers/{bundle}/Data/Documents
      // We want ~/Documents instead for user accessibility
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null) {
        _cachedBasePath = path.join(home, 'Documents', 'veo3');
      } else {
        // Fallback to app documents if HOME not found
        final docDir = await getApplicationDocumentsDirectory();
        _cachedBasePath = path.join(docDir.path, 'veo3');
      }
    } else if (Platform.isWindows) {
      // Windows: Use user's Documents folder
      final docDir = await getApplicationDocumentsDirectory();
      _cachedBasePath = path.join(docDir.path, 'veo3');
    } else {
      // Fallback for Linux or other platforms
      final docDir = await getApplicationDocumentsDirectory();
      _cachedBasePath = path.join(docDir.path, 'veo3');
    }

    // Ensure directory exists
    final dir = Directory(_cachedBasePath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return _cachedBasePath!;
  }

  /// Get projects directory path
  /// 
  /// Android: /storage/emulated/0/veo3/projects
  /// iOS: {Documents}/veo3/projects
  static Future<String> getProjectsPath() async {
    if (_cachedProjectsPath != null) return _cachedProjectsPath!;

    final basePath = await getBasePath();
    _cachedProjectsPath = path.join(basePath, 'projects');

    final dir = Directory(_cachedProjectsPath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return _cachedProjectsPath!;
  }

  /// Get videos export directory path
  /// 
  /// Android: /storage/emulated/0/veo3/videos
  /// iOS: {Documents}/veo3/videos
  static Future<String> getVideosPath() async {
    if (_cachedVideosPath != null) return _cachedVideosPath!;

    final basePath = await getBasePath();
    _cachedVideosPath = path.join(basePath, 'videos');

    final dir = Directory(_cachedVideosPath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return _cachedVideosPath!;
  }

  /// Get reels output directory path
  /// 
  /// Android: /storage/emulated/0/veo3/reels_output
  /// iOS: {Documents}/veo3/reels_output
  static Future<String> getReelsPath() async {
    if (_cachedReelsPath != null) return _cachedReelsPath!;

    final basePath = await getBasePath();
    _cachedReelsPath = path.join(basePath, 'reels_output');

    final dir = Directory(_cachedReelsPath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return _cachedReelsPath!;
  }

  /// Get generations directory path (for video downloads)
  /// 
  /// Android: /storage/emulated/0/veo3_generations
  /// iOS: {Documents}/veo3_generations
  /// macOS: ~/Documents/veo3_generations
  /// Windows: {Documents}/veo3_generations
  static Future<String> getGenerationsPath() async {
    if (Platform.isAndroid) {
      const generationsPath = '/storage/emulated/0/veo3_generations';
      final dir = Directory(generationsPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return generationsPath;
    } else if (Platform.isIOS) {
      final docDir = await getApplicationDocumentsDirectory();
      final generationsPath = path.join(docDir.path, 'veo3_generations');
      final dir = Directory(generationsPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return generationsPath;
    } else if (Platform.isMacOS) {
      // macOS: Use ~/Documents for user accessibility
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null) {
        final generationsPath = path.join(home, 'Documents', 'veo3_generations');
        final dir = Directory(generationsPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return generationsPath;
      } else {
        // Fallback
        final docDir = await getApplicationDocumentsDirectory();
        final generationsPath = path.join(docDir.path, 'veo3_generations');
        final dir = Directory(generationsPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return generationsPath;
      }
    } else {
      // Windows and others
      final docDir = await getApplicationDocumentsDirectory();
      final generationsPath = path.join(docDir.path, 'veo3_generations');
      final dir = Directory(generationsPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return generationsPath;
    }
  }

  /// Get temporary directory for processing
  /// 
  /// Uses system temp directory on all platforms
  static Future<String> getTempPath() async {
    final tempDir = await getTemporaryDirectory();
    final veoTempPath = path.join(tempDir.path, 'veo3_temp');
    
    final dir = Directory(veoTempPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    
    return veoTempPath;
  }

  /// Clear all cached paths (call this if user changes storage location)
  static void clearCache() {
    _cachedBasePath = null;
    _cachedProjectsPath = null;
    _cachedVideosPath = null;
    _cachedReelsPath = null;
  }

  /// Get platform-specific info for debugging
  static Future<Map<String, String>> getPathInfo() async {
    return {
      'platform': Platform.operatingSystem,
      'basePath': await getBasePath(),
      'projectsPath': await getProjectsPath(),
      'videosPath': await getVideosPath(),
      'reelsPath': await getReelsPath(),
      'generationsPath': await getGenerationsPath(),
      'tempPath': await getTempPath(),
    };
  }
}
