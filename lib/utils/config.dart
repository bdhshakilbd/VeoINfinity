import 'dart:io';
import 'package:path/path.dart' as path;

/// Configuration constants
class AppConfig {
  static String profilesDir = _getProfilesDir();
  static String chromePath = _getChromePath();
  static String get ffmpegPath => _getFFmpegPath(); // Changed to getter
  static const int debugPort = 9222;

  /// Get profiles directory - uses 'profiles' folder in app directory
  static String _getProfilesDir() {
    // On Android/iOS, return a temporary path that will be overridden by main.dart
    // On Windows, use the executable directory
    if (Platform.isAndroid || Platform.isIOS) {
      // Return a safe default - this will be overridden in _initializeOutputFolder
      return '/data/local/tmp/profiles'; // Temporary, will be replaced
    }
    
    final exePath = Platform.resolvedExecutable;
    final exeDir = path.dirname(exePath);
    return path.join(exeDir, 'profiles');
  }

  static String _getChromePath() {
    const path1 = r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe';
    const path2 = r'C:\Program Files\Google\Chrome\Application\chrome.exe';
    
    if (File(path1).existsSync()) return path1;
    if (File(path2).existsSync()) return path2;
    return path2; // Default
  }
  
  /// Get FFmpeg path - relies on ffmpeg.exe being in the same directory or PATH
  static String _getFFmpegPath() {
    return 'ffmpeg.exe';
  }
  
  /// Test FFmpeg and get version
  static Future<String> testFFmpeg() async {
    final ffmpegPath = _getFFmpegPath();
    print('[FFMPEG TEST] Testing path: $ffmpegPath');
    
    try {
      final result = await Process.run(ffmpegPath, ['-version'], runInShell: true);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        // Extract version line
        final firstLine = output.split('\n').first;
        return 'OK: $firstLine\nPath: $ffmpegPath';
      } else {
        return 'ERROR: FFmpeg returned exit code ${result.exitCode}\n${result.stderr}';
      }
    } catch (e) {
      return 'ERROR: $e\nPath checked: $ffmpegPath';
    }
  }

  // Model options (API-based generation)
  static const Map<String, String> modelOptions = {
    'Veo 3.1 Fast (API)': 'veo_3_1_t2v_fast_ultra',
    'Veo 3.1 Quality (API)': 'veo_3_1_t2v_quality_ultra',
    'Veo 2 Fast (API)': 'veo_2_t2v_fast',
    'Veo 2 Quality (API)': 'veo_2_t2v_quality',
  };

  // Flow UI model options - ALL accounts can pick any model
  // Display Name -> Flow UI Display Name
  static const Map<String, String> flowModelOptions = {
    'Veo 3.1 - Fast (Beta Audio)': 'Veo 3.1 - Fast',
    'Veo 3.1 - Fast [Lower Priority]': 'Veo 3.1 - Fast [Lower Priority]',
    'Veo 3.1 - Quality (Beta Audio)': 'Veo 3.1 - Quality',
    'Veo 2 - Fast (No Audio)': 'Veo 2 - Fast',
    'Veo 2 - Quality (No Audio)': 'Veo 2 - Quality',
  };

  // Alias for backwards compatibility
  static const Map<String, String> flowModelOptionsUltra = flowModelOptions;

  // API Model Key Mappings (Flow UI Name -> API Model Key)
  // These convert the display name to the actual model key needed for API calls
  
  // For AI Ultra accounts
  static const Map<String, String> apiModelKeysUltra = {
    'Veo 3.1 - Fast': 'veo_3_1_t2v_fast_ultra',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_t2v_fast_ultra_relaxed', // Lower priority queue
    'Veo 3.1 - Quality': 'veo_3_1_t2v_quality_ultra',
    'Veo 2 - Fast': 'veo_2_t2v_fast',
    'Veo 2 - Quality': 'veo_2_t2v_quality',
  };

  // For AI Pro accounts
  static const Map<String, String> apiModelKeysPro = {
    'Veo 3.1 - Fast': 'veo_3_1_t2v_fast',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_t2v_fast_relaxed', // Lower priority queue
    'Veo 3.1 - Quality': 'veo_3_1_t2v_quality',
    'Veo 2 - Fast': 'veo_2_t2v_fast',
    'Veo 2 - Quality': 'veo_2_t2v_quality',
  };

  // For Free accounts
  static const Map<String, String> apiModelKeysFree = apiModelKeysPro; // Same as Pro

  /// Convert Flow UI display name to API model key based on account type
  static String getApiModelKey(String displayName, String accountType) {
    final Map<String, String> mapping;
    
    switch (accountType) {
      case 'ai_ultra':
        mapping = apiModelKeysUltra;
        break;
      case 'ai_pro':
        mapping = apiModelKeysPro;
        break;
      case 'free':
      default:
        mapping = apiModelKeysFree;
        break;
    }
    
    return mapping[displayName] ?? 'veo_3_1_t2v_fast_ultra'; // Default fallback
  }

  // Account type options (Flow UI automation)
  static const Map<String, String> accountTypeOptions = {
    'Free Flow (100 credits)': 'free',
    'AI Pro (1,000 credits)': 'ai_pro',
    'AI Ultra (25,000 credits)': 'ai_ultra',
  };

  // Aspect ratio options
  static const Map<String, String> aspectRatioOptions = {
    'Landscape (16:9)': 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    'Portrait (9:16)': 'VIDEO_ASPECT_RATIO_PORTRAIT',
  };

  // Flow UI aspect ratio options (for UI automation)
  static const Map<String, String> flowAspectRatioOptions = {
    'Landscape (16:9)': 'Landscape (16:9)',
    'Portrait (9:16)': 'Portrait (9:16)',
  };

  // Status colors
  static const Map<String, int> statusColors = {
    'queued': 0xFF9E9E9E,
    'generating': 0xFF2196F3,
    'polling': 0xFF00BCD4,
    'downloading': 0xFFFFC107,
    'completed': 0xFF4CAF50,
    'failed': 0xFFF44336,
  };
}

