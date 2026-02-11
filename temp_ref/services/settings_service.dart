import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import '../models/account_profile.dart';

class SettingsService {
  static const String _settingsFileName = 'nanobana_settings.json';
  static const String _profilesFileName = 'nanobana_profiles.json';
  
  // Get the settings file path
  Future<File> _getSettingsFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final settingsDir = Directory('${directory.path}/NanobanaImageGenerator');
    
    // Create directory if it doesn't exist
    if (!await settingsDir.exists()) {
      await settingsDir.create(recursive: true);
    }
    
    return File('${settingsDir.path}/$_settingsFileName');
  }

  // Get the profiles file path
  Future<File> _getProfilesFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final settingsDir = Directory('${directory.path}/NanobanaImageGenerator');
    
    if (!await settingsDir.exists()) {
      await settingsDir.create(recursive: true);
    }
    
    return File('${settingsDir.path}/$_profilesFileName');
  }
  
  // Save settings
  Future<void> saveSettings({
    String? authToken,
    String? cookie,
    String? workflowId,
    String? aspectRatio,
    String? imageModel,
    String? outputFolder,
  }) async {
    try {
      final file = await _getSettingsFile();
      
      // Read existing settings
      Map<String, dynamic> settings = {};
      if (await file.exists()) {
        final content = await file.readAsString();
        settings = jsonDecode(content);
      }
      
      // Update only provided values
      if (authToken != null) settings['authToken'] = authToken;
      if (cookie != null) settings['cookie'] = cookie;
      if (workflowId != null) settings['workflowId'] = workflowId;
      if (aspectRatio != null) settings['aspectRatio'] = aspectRatio;
      if (imageModel != null) settings['imageModel'] = imageModel;
      if (outputFolder != null) settings['outputFolder'] = outputFolder;
      
      // Add timestamp
      settings['lastUpdated'] = DateTime.now().toIso8601String();
      
      // Write to file
      await file.writeAsString(jsonEncode(settings));
      
      print('✅ Settings saved to: ${file.path}');
    } catch (e) {
      print('❌ Error saving settings: $e');
      rethrow;
    }
  }
  
  // Load settings
  Future<Map<String, dynamic>> loadSettings() async {
    try {
      final file = await _getSettingsFile();
      
      if (await file.exists()) {
        final content = await file.readAsString();
        final settings = jsonDecode(content);
        print('✅ Settings loaded from: ${file.path}');
        return Map<String, dynamic>.from(settings);
      } else {
        print('ℹ️ No settings file found, using defaults');
        return {};
      }
    } catch (e) {
      print('❌ Error loading settings: $e');
      return {};
    }
  }
  
  // Get specific setting
  Future<String?> getSetting(String key) async {
    final settings = await loadSettings();
    return settings[key];
  }
  
  // Clear all settings
  Future<void> clearSettings() async {
    try {
      final file = await _getSettingsFile();
      if (await file.exists()) {
        await file.delete();
        print('✅ Settings cleared');
      }
    } catch (e) {
      print('❌ Error clearing settings: $e');
      rethrow;
    }
  }
  
  // Get settings file path for display
  Future<String> getSettingsPath() async {
    final file = await _getSettingsFile();
    return file.path;
  }

  // ================== PROFILE MANAGEMENT ==================

  /// Load all saved profiles
  Future<List<AccountProfile>> loadProfiles() async {
    try {
      final file = await _getProfilesFile();
      
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        final profiles = jsonList.map((json) => AccountProfile.fromJson(json)).toList();
        print('✅ Loaded ${profiles.length} profiles');
        return profiles;
      } else {
        print('ℹ️ No profiles file found');
        return [];
      }
    } catch (e) {
      print('❌ Error loading profiles: $e');
      return [];
    }
  }

  /// Save all profiles
  Future<void> saveProfiles(List<AccountProfile> profiles) async {
    try {
      final file = await _getProfilesFile();
      final jsonList = profiles.map((p) => p.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
      print('✅ Saved ${profiles.length} profiles');
    } catch (e) {
      print('❌ Error saving profiles: $e');
      rethrow;
    }
  }

  /// Get the currently active profile
  Future<AccountProfile?> getActiveProfile() async {
    final profiles = await loadProfiles();
    try {
      return profiles.firstWhere((p) => p.isActive);
    } catch (_) {
      // No active profile found, return first one if exists
      if (profiles.isNotEmpty) {
        profiles[0].isActive = true;
        await saveProfiles(profiles);
        return profiles[0];
      }
      return null;
    }
  }

  /// Set a profile as active
  Future<void> setActiveProfile(String profileId) async {
    final profiles = await loadProfiles();
    for (var profile in profiles) {
      profile.isActive = (profile.id == profileId);
    }
    await saveProfiles(profiles);
    
    // Also update the main settings with active profile credentials
    final active = profiles.firstWhere((p) => p.isActive);
    await saveSettings(
      authToken: active.authToken,
      cookie: active.cookie,
    );
  }

  /// Add a new profile
  Future<void> addProfile(AccountProfile profile) async {
    final profiles = await loadProfiles();
    
    // If this is the first profile, make it active
    if (profiles.isEmpty) {
      profile.isActive = true;
    }
    
    profiles.add(profile);
    await saveProfiles(profiles);
  }

  /// Delete a profile by ID
  Future<bool> deleteProfile(String profileId) async {
    final profiles = await loadProfiles();
    
    // Don't allow deleting the last profile
    if (profiles.length <= 1) {
      return false;
    }
    
    final wasActive = profiles.firstWhere((p) => p.id == profileId).isActive;
    profiles.removeWhere((p) => p.id == profileId);
    
    // If deleted profile was active, activate the first remaining one
    if (wasActive && profiles.isNotEmpty) {
      profiles[0].isActive = true;
    }
    
    await saveProfiles(profiles);
    return true;
  }

  /// Update a profile
  Future<void> updateProfile(AccountProfile updatedProfile) async {
    final profiles = await loadProfiles();
    final index = profiles.indexWhere((p) => p.id == updatedProfile.id);
    
    if (index >= 0) {
      profiles[index] = updatedProfile;
      await saveProfiles(profiles);
      
      // If this is the active profile, also update main settings
      if (updatedProfile.isActive) {
        await saveSettings(
          authToken: updatedProfile.authToken,
          cookie: updatedProfile.cookie,
        );
      }
    }
  }
}
