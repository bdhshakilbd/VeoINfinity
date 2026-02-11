import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:webdriver/sync_core.dart';
import 'package:http/http.dart' as http;

/// Selenium-based Video Generator for Flow UI automation
class SeleniumVideoGenerator {
  WebDriver? driver;
  final Random _random = Random();

  /// Human-like delay with randomization
  Future<void> _humanDelay({int minMs = 500, int maxMs = 1500}) async {
    final delay = minMs + _random.nextInt(maxMs - minMs);
    await Future.delayed(Duration(milliseconds: delay));
  }

  /// Connect to Chrome with existing profile
  Future<void> connect({
    required String chromeDriverPath,
    required String userDataDir,
    String profileName = 'Default',
  }) async {
    print('[SELENIUM] Connecting to Chrome with profile...');
    
    final capabilities = Capabilities.chrome([
      '--user-data-dir=$userDataDir',
      '--profile-directory=$profileName',
      '--disable-blink-features=AutomationControlled', // Hide automation
      '--disable-dev-shm-usage',
      '--no-sandbox',
    ]);

    driver = await createDriver(
      uri: Uri.parse('http://localhost:9515'), // ChromeDriver default port
      desired: capabilities,
    );

    print('[SELENIUM] Connected successfully');
  }

  /// Navigate to Flow
  Future<void> navigateToFlow() async {
    if (driver == null) throw Exception('Not connected');
    await driver!.get('https://labs.google/fx/tools/flow');
    await _humanDelay(minMs: 2000, maxMs: 3000);
  }

  /// Type text with human-like delays
  Future<void> typeText(WebElement element, String text) async {
    print('[SELENIUM] Typing text character-by-character...');
    
    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      await element.sendKeys(char);
      
      // Random delay between characters (30-80ms)
      await _humanDelay(minMs: 30, maxMs: 80);
    }
  }

  /// Click element with mouse movement simulation
  Future<void> clickElement(WebElement element) async {
    // Move to element (simulates mouse movement)
    await driver!.mouse.moveTo(element: element);
    await _humanDelay(minMs: 100, maxMs: 300);
    
    // Click
    await element.click();
  }

  /// Generate video via Flow UI
  Future<String?> generateVideo({
    required String prompt,
    required String outputPath,
  }) async {
    try {
      print('[SELENIUM] Starting video generation...');
      
      // Wait for and find text area
      print('[SELENIUM] Waiting for prompt textarea...');
      final textarea = await _waitForElement(
        By.id('PINHOLE_TEXT_AREA_ELEMENT_ID'),
        timeout: Duration(seconds: 10),
      );
      
      if (textarea == null) {
        throw Exception('Prompt textarea not found');
      }

      // Clear and type prompt
      await textarea.clear();
      await typeText(textarea, prompt);
      
      print('[SELENIUM] Prompt entered');
      
      // Wait before pressing Enter
      await _humanDelay(minMs: 1500, maxMs: 2500);
      
      // Press Enter
      print('[SELENIUM] Pressing Enter...');
      await textarea.sendKeys(Keys.enter);
      
      print('[SELENIUM] Generation triggered');
      
      // Wait for video completion
      final videoUrl = await _waitForVideoCompletion();
      
      if (videoUrl != null) {
        // Download video
        print('[SELENIUM] Downloading video...');
        await _downloadVideo(videoUrl, outputPath);
        return outputPath;
      }
      
      return null;
      
    } catch (e) {
      print('[SELENIUM] Error: $e');
      return null;
    }
  }

  /// Wait for element with timeout
  Future<WebElement?> _waitForElement(By by, {Duration timeout = const Duration(seconds: 10)}) async {
    final endTime = DateTime.now().add(timeout);
    
    while (DateTime.now().isBefore(endTime)) {
      try {
        final element = await driver!.findElement(by);
        if (element != null) return element;
      } catch (e) {
        // Element not found yet
      }
      await Future.delayed(Duration(milliseconds: 500));
    }
    
    return null;
  }

  /// Wait for video completion
  Future<String?> _waitForVideoCompletion({int maxWaitSeconds = 300}) async {
    print('[SELENIUM] Waiting for video completion...');
    
    final startTime = DateTime.now();
    
    while (DateTime.now().difference(startTime).inSeconds < maxWaitSeconds) {
      try {
        // Find video elements
        final videos = await driver!.findElements(By.tagName('video'));
        
        if (videos.isNotEmpty) {
          final lastVideo = videos.last;
          final src = await lastVideo.getAttribute('src');
          
          if (src != null && src.contains('storage.googleapis.com')) {
            print('[SELENIUM] Video URL found: $src');
            return src;
          }
        }
      } catch (e) {
        // Continue waiting
      }
      
      await Future.delayed(Duration(seconds: 2));
    }
    
    print('[SELENIUM] Timeout waiting for video');
    return null;
  }

  /// Download video from URL
  Future<void> _downloadVideo(String url, String outputPath) async {
    final response = await http.get(Uri.parse(url));
    
    if (response.statusCode == 200) {
      final file = File(outputPath);
      await file.writeAsBytes(response.bodyBytes);
      print('[SELENIUM] Downloaded ${response.bodyBytes.length} bytes to: $outputPath');
    } else {
      throw Exception('Failed to download video: ${response.statusCode}');
    }
  }

  /// Close driver
  Future<void> close() async {
    if (driver != null) {
      await driver!.quit();
      driver = null;
      print('[SELENIUM] Driver closed');
    }
  }
}
