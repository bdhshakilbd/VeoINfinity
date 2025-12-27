import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'browser_video_generator.dart';

/// Status of a Chrome profile/browser instance
enum ProfileStatus {
  disconnected,
  launching,
  connected,
  relogging,
  error,
}

/// Represents a Chrome profile/browser instance for multi-profile video generation
class ChromeProfile {
  final String name;
  final String profilePath;
  final int debugPort;

  ProfileStatus status;
  BrowserVideoGenerator? generator;
  String? accessToken;
  int consecutive403Count;
  Process? chromeProcess;

  ChromeProfile({
    required this.name,
    required this.profilePath,
    required this.debugPort,
    this.status = ProfileStatus.disconnected,
    this.consecutive403Count = 0,
  });

  bool get isConnected => status == ProfileStatus.connected;
  bool get isAvailable => status == ProfileStatus.connected && accessToken != null;

  @override
  String toString() => 'ChromeProfile($name, port: $debugPort, status: $status, 403: $consecutive403Count/3)';
}

/// Manages multiple Chrome profiles for concurrent video generation
class ProfileManagerService {
  final List<ChromeProfile> profiles = [];
  final String profilesDirectory;
  final int baseDebugPort;
  int _currentBrowserIndex = 0;

  ProfileManagerService({
    required this.profilesDirectory,
    this.baseDebugPort = 9222,
  }) {
    // Ensure profiles directory exists
    final dir = Directory(profilesDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// Create a new Chrome profile directory
  Future<bool> createProfile(String name) async {
    try {
      final profilePath = path.join(profilesDirectory, name);
      final dir = Directory(profilePath);

      if (dir.existsSync()) {
        print('[ProfileManager] Profile "$name" already exists');
        return false;
      }

      dir.createSync(recursive: true);
      print('[ProfileManager] ✓ Created profile: $name at $profilePath');
      return true;
    } catch (e) {
      print('[ProfileManager] ✗ Error creating profile "$name": $e');
      return false;
    }
  }

  /// Launch Chrome with the specified profile
  Future<bool> launchProfile(
    ChromeProfile profile, {
    String url = 'https://labs.google/fx/tools/flow',
  }) async {
    try {
      profile.status = ProfileStatus.launching;
      print('[ProfileManager] Launching ${profile.name} on port ${profile.debugPort}...');

      // Ensure profile directory exists
      final dir = Directory(profile.profilePath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      // Find Chrome executable
      final chromePath = await _findChromeExecutable();
      if (chromePath == null) {
        print('[ProfileManager] ✗ Chrome executable not found');
        profile.status = ProfileStatus.error;
        return false;
      }

      // Launch Chrome with remote debugging
      final args = [
        '--remote-debugging-port=${profile.debugPort}',
        '--remote-allow-origins=*',
        '--user-data-dir=${profile.profilePath}',
        '--profile-directory=Default',
        url,
      ];

      profile.chromeProcess = await Process.start(chromePath, args);
      print('[ProfileManager] ✓ Chrome launched for ${profile.name}');

      // Wait for Chrome to be ready
      await Future.delayed(Duration(seconds: 3));

      // Verify Chrome is responding
      final isReady = await _waitForChromeReady(profile.debugPort);
      if (!isReady) {
        print('[ProfileManager] ✗ Chrome not responding on port ${profile.debugPort}');
        profile.status = ProfileStatus.error;
        return false;
      }

      print('[ProfileManager] ✓ Chrome ready for ${profile.name}');
      profile.status = ProfileStatus.connected;
      return true;
    } catch (e) {
      print('[ProfileManager] ✗ Error launching ${profile.name}: $e');
      profile.status = ProfileStatus.error;
      return false;
    }
  }

  /// Connect to an already-running Chrome instance
  Future<bool> connectToProfile(ChromeProfile profile) async {
    try {
      print('[ProfileManager] Connecting to ${profile.name} on port ${profile.debugPort}...');

      // Check if Chrome is running on this port
      final isRunning = await _isChromeRunning(profile.debugPort);
      if (!isRunning) {
        print('[ProfileManager] ✗ No Chrome instance on port ${profile.debugPort}');
        profile.status = ProfileStatus.disconnected;
        return false;
      }

      // Create generator and connect
      final generator = BrowserVideoGenerator(debugPort: profile.debugPort);
      await generator.connect();

      // Try to get access token with retries
      String? token;
      int attempts = 0;
      const int maxAttempts = 6;
      
      while (token == null && attempts < maxAttempts) {
        if (attempts > 0) {
           print('[ProfileManager] Waiting for token in ${profile.name} (Attempt ${attempts + 1}/$maxAttempts)... [15s wait]');
           await Future.delayed(const Duration(seconds: 15));
        }
        
        try {
          token = await generator.getAccessToken();
        } catch (e) {
          print('[ProfileManager] Error checking token: $e');
        }
        attempts++;
      }

      profile.generator = generator;
      profile.accessToken = token;
      profile.status = token != null ? ProfileStatus.connected : ProfileStatus.disconnected;

      if (token != null) {
        print('[ProfileManager] ✓ Connected to ${profile.name} with token: ${token.substring(0, 30)}...');
        return true;
      } else {
        print('[ProfileManager] ✗ Connected to ${profile.name} but no token found after $attempts attempts.');
        return false;
      }
    } catch (e) {
      print('[ProfileManager] ✗ Error connecting to ${profile.name}: $e');
      profile.status = ProfileStatus.error;
      return false;
    }
  }

  /// Connect to a profile's Chrome instance WITHOUT waiting for token
  /// Used for auto-login where token will be obtained after login
  Future<bool> connectToProfileWithoutToken(ChromeProfile profile) async {
    try {
      print('[ProfileManager] Connecting to ${profile.name} on port ${profile.debugPort}...');

      // Check if Chrome is running on this port
      final isRunning = await _isChromeRunning(profile.debugPort);
      if (!isRunning) {
        print('[ProfileManager] ✗ No Chrome instance on port ${profile.debugPort}');
        profile.status = ProfileStatus.disconnected;
        return false;
      }

      // Create generator and connect (no token check)
      final generator = BrowserVideoGenerator(debugPort: profile.debugPort);
      await generator.connect();

      profile.generator = generator;
      profile.status = ProfileStatus.disconnected; // Will be updated after login
      print('[ProfileManager] ✓ Connected to ${profile.name} (ready for auto-login)');
      return true;
    } catch (e) {
      print('[ProfileManager] ✗ Error connecting to ${profile.name}: $e');
      profile.status = ProfileStatus.error;
      return false;
    }
  }

  /// Get next available profile using round-robin selection
  ChromeProfile? getNextAvailableProfile() {
    if (profiles.isEmpty) return null;

    // Try to find a connected profile starting from current index
    for (var i = 0; i < profiles.length; i++) {
      final idx = (_currentBrowserIndex + i) % profiles.length;
      final profile = profiles[idx];

      if (profile.isAvailable) {
        _currentBrowserIndex = (idx + 1) % profiles.length;
        return profile;
      }
    }

    return null; // No available profiles
  }

  /// Check if any profile is connected and available
  bool hasAnyConnectedProfile() {
    return profiles.any((p) => p.isAvailable);
  }

  /// Count connected profiles
  int countConnectedProfiles() {
    return profiles.where((p) => p.isConnected).length;
  }

  /// Get all profiles with a specific status
  List<ChromeProfile> getProfilesByStatus(ProfileStatus status) {
    return profiles.where((p) => p.status == status).toList();
  }

  /// Initialize multiple profiles
  Future<void> initializeProfiles(int count) async {
    profiles.clear();
    _currentBrowserIndex = 0;

    for (var i = 0; i < count; i++) {
      final name = 'Browser_${i + 1}';
      final profilePath = path.join(profilesDirectory, name);
      final debugPort = baseDebugPort + i;

      final profile = ChromeProfile(
        name: name,
        profilePath: profilePath,
        debugPort: debugPort,
      );

      profiles.add(profile);

      // Create profile directory if it doesn't exist
      await createProfile(name);
    }

    print('[ProfileManager] ✓ Initialized $count profiles');
  }

  /// Connect to already-opened browser instances (assumes already logged in)
  Future<int> connectToOpenProfiles(int count) async {
    await initializeProfiles(count);
    
    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Connecting to $count opened browsers');
    print('[ProfileManager] ========================================');
    
    int connectedCount = 0;

    for (var i = 0; i < profiles.length; i++) {
      final profile = profiles[i];
      
      print('\n[ProfileManager] [${i + 1}/$count] Checking port ${profile.debugPort}...');
      
      // Check if Chrome is running on this port
      final isRunning = await _isChromeRunning(profile.debugPort);
      if (!isRunning) {
        print('[ProfileManager] [${i + 1}/$count] ✗ No browser on port ${profile.debugPort}');
        continue;
      }
      // Connect to browser (fast - no token check)
      final connected = await connectToProfileWithoutToken(profile);
      
      if (connected) {
        connectedCount++;
        
        // After connecting, quickly check if token exists (no waiting)
        try {
          final token = await profile.generator!.getAccessToken();
          if (token != null) {
            profile.accessToken = token;
            profile.status = ProfileStatus.connected;
            print('[ProfileManager] [${i + 1}/$count] \u2713 Connected with token');
          } else {
            print('[ProfileManager] [${i + 1}/$count] \u2713 Connected (ready for manual login)');
          }
        } catch (e) {
          print('[ProfileManager] [${i + 1}/$count] \u2713 Connected (ready for manual login)');
        }
      }
    }

    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Connected to $connectedCount/$count browsers');
    print('[ProfileManager] ========================================');
    
    return connectedCount;
  }

  /// Launch browsers without auto-login (user must login manually)
  Future<int> launchProfilesWithoutLogin(int count) async {
    await initializeProfiles(count);
    
    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Opening $count browsers (NO LOGIN)');
    print('[ProfileManager] ========================================');
    
    int launchedCount = 0;

    for (var i = 0; i < profiles.length; i++) {
      final profile = profiles[i];
      
      print('\n[ProfileManager] [${i + 1}/$count] Launching ${profile.name}...');
      
      final launched = await launchProfile(profile);
      if (launched) {
        launchedCount++;
        
        // Connect without waiting for token (manual login required)
        await connectToProfileWithoutToken(profile);
      }
    }

    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Launched $launchedCount/$count browsers');
    print('[ProfileManager] (Manual login required to get access tokens)');
    print('[ProfileManager] ========================================');
    
    return launchedCount;
  }

  /// Close all connections and cleanup
  Future<void> dispose() async {
    for (final profile in profiles) {
      try {
        await profile.generator?.close();
        profile.chromeProcess?.kill();
      } catch (e) {
        print('[ProfileManager] Warning: Error disposing ${profile.name}: $e');
      }
    }
    profiles.clear();
    print('[ProfileManager] ✓ Disposed all profiles');
  }

  /// Find Chrome executable path
  Future<String?> _findChromeExecutable() async {
    if (Platform.isWindows) {
      final paths = [
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      ];

      for (final path in paths) {
        if (File(path).existsSync()) {
          return path;
        }
      }
    } else if (Platform.isMacOS) {
      return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    } else if (Platform.isLinux) {
      return 'google-chrome';
    }

    return null;
  }

  /// Wait for Chrome to be ready on the specified port
  Future<bool> _waitForChromeReady(int port, {int maxAttempts = 5}) async {
    for (var i = 0; i < maxAttempts; i++) {
      if (await _isChromeRunning(port)) {
        return true;
      }
      await Future.delayed(Duration(seconds: 2));
    }
    return false;
  }

  /// Check if Chrome is running on the specified port
  Future<bool> _isChromeRunning(int port) async {
    try {
      final response = await HttpClient()
          .getUrl(Uri.parse('http://localhost:$port/json'))
          .timeout(Duration(seconds: 2))
          .then((request) => request.close());

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}
