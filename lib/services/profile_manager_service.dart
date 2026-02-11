import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'video_generation_service.dart';
import 'settings_service.dart';
import '../utils/browser_utils.dart';

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
  DesktopGenerator? generator;
  String? accessToken;
  int consecutive403Count;
  Process? chromeProcess;
  
  // Track if browser has been refreshed this session (to prevent infinite refresh loops)
  bool browserRefreshedThisSession = false;

  ChromeProfile({
    required this.name,
    required this.profilePath,
    required this.debugPort,
    this.status = ProfileStatus.disconnected,
    this.consecutive403Count = 0,
    this.activeTasks = 0,
  });

  int activeTasks;

  bool get isConnected => status == ProfileStatus.connected;
  bool get isAvailable => status == ProfileStatus.connected && accessToken != null && status != ProfileStatus.relogging;

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
  /// Applies AMD Ryzen optimizations automatically
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

      // AMD Ryzen optimization: Prevent CPU throttling before launching browsers
      // This is done once per launch session to set the power plan appropriately
      await BrowserUtils.preventCpuThrottling();

      // Launch Chrome with remote debugging (includes AMD Ryzen optimized args)
      final args = BrowserUtils.getChromeArgs(
        debugPort: profile.debugPort,
        profilePath: profile.profilePath,
        url: url,
      );

      profile.chromeProcess = await Process.start(chromePath, args);
      print('[ProfileManager] ✓ Chrome launched for ${profile.name}');

      // Position windows (not always-on-top to avoid interference)
      if (Platform.isWindows) {
        final profileIndex = profile.debugPort - baseDebugPort;
        await BrowserUtils.forceAlwaysOnTop(
          profile.chromeProcess!.pid,
          width: 800,
          height: 600,
          offsetIndex: profileIndex,
        );
        
        // AMD Ryzen optimization: Set high performance affinity for Chrome process
        await BrowserUtils.setHighPerformanceAffinity(profile.chromeProcess!.pid);
      }

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
  /// Uses async yields to prevent UI freezing
  Future<bool> connectToProfile(ChromeProfile profile) async {
    try {
      print('[ProfileManager] Connecting to ${profile.name} on port ${profile.debugPort}...');
      
      // Yield to UI thread before potentially blocking operations
      await Future.delayed(Duration.zero);

      // Check if Chrome is running on this port
      final isRunning = await _isChromeRunning(profile.debugPort);
      if (!isRunning) {
        print('[ProfileManager] ✗ No Chrome instance on port ${profile.debugPort}');
        profile.status = ProfileStatus.disconnected;
        return false;
      }
      
      // Yield to UI thread again
      await Future.delayed(Duration.zero);

      // Create generator and connect
      final generator = DesktopGenerator(debugPort: profile.debugPort);
      await generator.connect();
      
      // Yield to UI thread
      await Future.delayed(Duration.zero);
      
      // Apply mobile emulation for better rate limits from Google Flow
      await BrowserUtils.applyMobileEmulation(profile.debugPort);

      // Try to get access token with retries (with UI yields)
      String? token;
      int attempts = 0;
      const int maxAttempts = 6;
      
      while (token == null && attempts < maxAttempts) {
        // Yield to UI thread at the start of each attempt
        await Future.delayed(Duration.zero);
        
        if (attempts > 0) {
           print('[ProfileManager] Waiting for token in ${profile.name} (Attempt ${attempts + 1}/$maxAttempts)... [15s wait]');
           // Break up the 15 second wait into smaller chunks to keep UI responsive
           for (int i = 0; i < 15; i++) {
             await Future.delayed(const Duration(seconds: 1));
           }
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
  /// Uses async yields to prevent UI freezing
  Future<bool> connectToProfileWithoutToken(ChromeProfile profile) async {
    try {
      print('[ProfileManager] Connecting to ${profile.name} on port ${profile.debugPort}...');
      
      // Yield to UI thread before potentially blocking operations
      await Future.delayed(Duration.zero);

      // Check if Chrome is running on this port
      final isRunning = await _isChromeRunning(profile.debugPort);
      if (!isRunning) {
        print('[ProfileManager] ✗ No Chrome instance on port ${profile.debugPort}');
        profile.status = ProfileStatus.disconnected;
        return false;
      }
      
      // Yield to UI thread
      await Future.delayed(Duration.zero);

      // Create generator and connect (no token check)
      final generator = DesktopGenerator(debugPort: profile.debugPort);
      await generator.connect();
      
      // Yield to UI thread
      await Future.delayed(Duration.zero);
      
      // Apply mobile emulation for better rate limits from Google Flow
      await BrowserUtils.applyMobileEmulation(profile.debugPort);

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

      // CRITICAL: Skip profiles that are relogging
      if (profile.status == ProfileStatus.relogging) {
        continue; // Don't use this profile - it's being relogged
      }

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
  /// Uses profile names from Settings when available
  Future<void> initializeProfiles(int count) async {
    profiles.clear();
    _currentBrowserIndex = 0;

    // Get profile names from Settings
    final settingsProfiles = SettingsService.instance.getBrowserProfiles();
    print('[ProfileManager] Settings has ${settingsProfiles.length} configured profiles');

    for (var i = 0; i < count; i++) {
      // Use name from Settings if available, otherwise use default naming
      String name;
      if (i < settingsProfiles.length) {
        name = (settingsProfiles[i]['name'] ?? 'Browser_${i + 1}').toString();
        print('[ProfileManager] Browser ${i + 1} using Settings profile: "$name"');
      } else {
        name = 'Browser_${i + 1}';
        print('[ProfileManager] Browser ${i + 1} using default name: "$name" (no Settings profile at index $i)');
      }
      
      final profilePath = path.join(profilesDirectory, 'Browser_${i + 1}'); // Keep folder names consistent
      final debugPort = baseDebugPort + i;

      final profile = ChromeProfile(
        name: name,
        profilePath: profilePath,
        debugPort: debugPort,
      );

      profiles.add(profile);

      // Create profile directory if it doesn't exist
      await createProfile('Browser_${i + 1}');
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
        profile.generator?.close();
        profile.chromeProcess?.kill();
      } catch (e) {
        print('[ProfileManager] Warning: Error disposing ${profile.name}: $e');
      }
    }
    profiles.clear();
    print('[ProfileManager] ✓ Disposed all profiles');
  }

  /// Calculate window position for vertical stacking on left side
  String _calculateWindowPosition(ChromeProfile profile) {
    // Calculate profile index from debug port
    final profileIndex = profile.debugPort - baseDebugPort;
    
    // Stack vertically: x=0 (left edge), y = index * 650 (window height)
    final xPos = 0;
    final yPos = profileIndex * 650;
    
    return '$xPos,$yPos';
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
  /// Uses short timeout and async-friendly http package to prevent UI blocking
  Future<bool> _isChromeRunning(int port) async {
    try {
      // Use http package with explicit timeout instead of blocking HttpClient
      final response = await http.get(
        Uri.parse('http://localhost:$port/json'),
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () => http.Response('', 408), // Return timeout status
      );

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Apply mobile-like emulation via CDP to enforce small window dimensions
  Future<void> _applyMobileEmulation(int port) async {
    try {
      print('[ProfileManager] Applying mobile emulation (500x650, 40% zoom)...');
      
      // Get the first available tab
      final response = await HttpClient()
          .getUrl(Uri.parse('http://localhost:$port/json'))
          .then((request) => request.close())
          .then((response) => response.transform(utf8.decoder).join());
      
      final tabs = json.decode(response) as List;
      if (tabs.isEmpty) {
        print('[ProfileManager] ✗ No tabs found for emulation');
        return;
      }
      
      final webSocketUrl = tabs[0]['webSocketDebuggerUrl'] as String;
      final ws = await WebSocket.connect(webSocketUrl);
      
      // Set device metrics override (500x650 viewport, 40% scale)
      ws.add(json.encode({
        'id': 1,
        'method': 'Emulation.setDeviceMetricsOverride',
        'params': {
          'width': 1250,          // Logical width (will be scaled to 500px by deviceScaleFactor)
          'height': 1625,         // Logical height (will be scaled to 650px)
          'deviceScaleFactor': 0.4, // 40% zoom
          'mobile': true,
          'screenOrientation': {'type': 'portraitPrimary', 'angle': 0},
        }
      }));
      
      await Future.delayed(Duration(milliseconds: 500));
      await ws.close();
      
      print('[ProfileManager] ✓ Mobile emulation applied');
    } catch (e) {
      print('[ProfileManager] Warning: Could not apply mobile emulation: $e');
    }
  }
}
