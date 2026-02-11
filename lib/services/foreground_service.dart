import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Foreground service to keep the app running on Android
/// - Keeps CPU awake even when screen is off
/// - Prevents Android from killing the app in background
/// - Works during lock screen
class ForegroundServiceHelper {
  static bool _isInitialized = false;
  static bool _isRunning = false;
  
  /// Initialize the foreground task (call once at app startup)
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (_isInitialized) return;
    
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'veo3_bg_silent', // Changed channel ID to create new silent channel
        channelName: 'VEO3 Background',
        channelDescription: 'Keeps the app running during video generation',
        channelImportance: NotificationChannelImportance.LOW, // LOW = silent, no pop-up
        priority: NotificationPriority.LOW, // LOW = no heads-up
        playSound: false, // No sound
        enableVibration: false, // No vibration
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false, // Don't show on iOS
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,  // CRITICAL: Keep CPU awake
        allowWifiLock: true,  // Keep WiFi active
      ),
    );
    
    _isInitialized = true;
    print('[FOREGROUND] Service initialized');
  }
  
  /// Request to ignore battery optimizations (call once, shows system dialog)
  static Future<bool> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return true;
    
    final isIgnoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!isIgnoring) {
      print('[FOREGROUND] Requesting battery optimization exemption...');
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return true;
  }
  
  /// Start foreground service when generation begins
  /// This keeps the app running even when:
  /// - App is in background
  /// - Screen is off
  /// - Phone is locked
  static Future<void> startService({String? status}) async {
    if (!Platform.isAndroid) return;
    
    // Initialize if needed
    if (!_isInitialized) {
      await init();
    }
    
    if (_isRunning) {
      // Just update the notification
      await updateStatus(status ?? 'Generating videos...');
      return;
    }
    
    // Keep screen awake (optional, remove if you want screen to turn off)
    await WakelockPlus.enable();
    
    // Start foreground task - this is CRITICAL for background execution
    await FlutterForegroundTask.startService(
      notificationTitle: 'VEO3 Generation Active',
      notificationText: status ?? 'Generating videos...',
    );
    
    _isRunning = true;
    print('[FOREGROUND] ✓ Service started - app will run in background');
  }
  
  /// Update notification status
  static Future<void> updateStatus(String status) async {
    if (!Platform.isAndroid || !_isRunning) return;
    
    await FlutterForegroundTask.updateService(
      notificationTitle: 'VEO3 Generation Active',
      notificationText: status,
    );
  }
  
  /// Stop foreground service when generation ends
  static Future<void> stopService() async {
    if (!Platform.isAndroid) return;
    if (!_isRunning) return;
    
    // Allow screen to sleep
    await WakelockPlus.disable();
    
    // Stop foreground task
    await FlutterForegroundTask.stopService();
    
    _isRunning = false;
    print('[FOREGROUND] Service stopped');
  }
  
  /// Check if service is running
  static bool get isRunning => _isRunning;
  
  /// Check if app is in foreground
  static Future<bool> isAppInForeground() async {
    if (!Platform.isAndroid) return true;
    return await FlutterForegroundTask.isAppOnForeground;
  }
  
  /// Minimize app (useful for testing background mode)
  static void minimizeApp() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.minimizeApp();
  }
  
  /// Wake up locked screen (if permission granted)
  static void wakeUpScreen() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.wakeUpScreen();
  }
}
