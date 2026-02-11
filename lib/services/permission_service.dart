import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

/// Helper service for managing storage permissions on Android
class PermissionService {
  /// Request storage permissions for Android
  static Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) {
      return true; // No permission needed on other platforms
    }

    try {
      // Try MANAGE_EXTERNAL_STORAGE first (for Android 11+)
      var status = await Permission.manageExternalStorage.request();
      
      if (status.isGranted) {
        return true;
      }
      
      // Fallback to regular storage permission
      status = await Permission.storage.request();
      return status.isGranted;
    } catch (e) {
      print('[PERMISSION] Error requesting permission: $e');
      // Fallback: try basic storage permission
      try {
        final status = await Permission.storage.request();
        return status.isGranted;
      } catch (e2) {
        print('[PERMISSION] Fallback also failed: $e2');
        return false;
      }
    }
  }

  /// Check if storage permission is already granted
  static Future<bool> hasStoragePermission() async {
    if (!Platform.isAndroid) {
      return true;
    }

    try {
      // Check MANAGE_EXTERNAL_STORAGE first
      if (await Permission.manageExternalStorage.isGranted) {
        return true;
      }
      
      // Check regular storage permission
      return await Permission.storage.isGranted;
    } catch (e) {
      print('[PERMISSION] Error checking permission: $e');
      return false;
    }
  }

  /// Open app settings if permission is permanently denied
  static Future<void> openSettings() async {
    await openAppSettings();
  }
}
