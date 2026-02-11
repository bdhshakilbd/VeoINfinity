import 'dart:io';
import 'package:path/path.dart' as path;

import 'package:veo3_another/utils/ffmpeg_utils.dart';

/// Configuration constants
class AppConfig {
  static String profilesDir = _getProfilesDir();
  static String chromePath = _getChromePath();
  // static Future<String> get ffmpegPath => _getFFmpegPath(); // Unused, commented out
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

  /// Get FFmpeg path - robust lookup via FFmpegUtils
  static Future<String> _getFFmpegPath() async {
    return await FFmpegUtils.getFFmpegPath();
  }
  
  /// Test FFmpeg and get version
  static Future<String> testFFmpeg() async {
    final ffmpegPath = await _getFFmpegPath();
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
    'Veo 3.1 - Fast': 'Veo 3.1 - Fast',
    'Veo 3.1 - Fast [Lower Priority]': 'Veo 3.1 - Fast [Lower Priority]',
    'Veo 3.1 - Quality': 'Veo 3.1 - Quality',
    'Veo 2 - Fast': 'Veo 2 - Fast',
    'Veo 2 - Quality': 'Veo 2 - Quality',
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
  
  // Image-to-Video model keys for AI Ultra accounts
  static const Map<String, String> apiModelKeysUltraI2V = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_ultra',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_ultra_relaxed', // Lower priority queue
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_quality_ultra',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality',
  };

  // For AI Pro accounts
  static const Map<String, String> apiModelKeysPro = {
    'Veo 3.1 - Fast': 'veo_3_1_t2v_fast',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_t2v_fast_relaxed', // Lower priority queue
    'Veo 3.1 - Quality': 'veo_3_1_t2v_quality',
    'Veo 2 - Fast': 'veo_2_t2v_fast',
    'Veo 2 - Quality': 'veo_2_t2v_quality',
  };
  
  // Image-to-Video model keys for AI Pro accounts
  static const Map<String, String> apiModelKeysProI2V = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_relaxed', // Lower priority queue
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_quality',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality',
  };

  // For Free accounts
  static const Map<String, String> apiModelKeysFree = apiModelKeysPro; // Same as Pro
  static const Map<String, String> apiModelKeysFreeI2V = apiModelKeysProI2V; // Same as Pro

  /// Convert Flow UI display name to API model key based on account type
  /// If hasImages is true, returns i2v model keys instead of t2v
  static String getApiModelKey(String displayName, String accountType, {bool hasImages = false}) {
    final Map<String, String> mapping;
    
    switch (accountType) {
      case 'ai_ultra':
        mapping = hasImages ? apiModelKeysUltraI2V : apiModelKeysUltra;
        break;
      case 'ai_pro':
        mapping = hasImages ? apiModelKeysProI2V : apiModelKeysPro;
        break;
      case 'free':
      default:
        mapping = hasImages ? apiModelKeysFreeI2V : apiModelKeysFree;
        break;
    }
    
    return mapping[displayName] ?? (hasImages ? 'veo_3_1_i2v_s_fast_ultra' : 'veo_3_1_t2v_fast_ultra'); // Default fallback
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

