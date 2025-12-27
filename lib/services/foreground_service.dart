import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Foreground service to keep the app running on Android
class ForegroundServiceHelper {
  static bool _isInitialized = false;
  static bool _isRunning = false;
  
  /// Initialize the foreground task (call once at app startup)
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (_isInitialized) return;
    
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'veo3_generation',
        channelName: 'VEO3 Video Generation',
        channelDescription: 'Keeps the app running during video generation',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    
    _isInitialized = true;
  }
  
  /// Start foreground service when generation begins
  static Future<void> startService({String? status}) async {
    if (!Platform.isAndroid) return;
    if (_isRunning) return;
    
    // Keep screen awake
    await WakelockPlus.enable();
    
    // Start foreground task
    await FlutterForegroundTask.startService(
      notificationTitle: 'VEO3 Generation Active',
      notificationText: status ?? 'Generating videos...',
    );
    
    _isRunning = true;
    print('[FOREGROUND] Service started');
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
}
