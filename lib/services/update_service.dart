import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App Update Service - Checks for new versions
class UpdateService {
  // ============================================
  // CONFIGURATION
  // ============================================
  static const String _supabaseUrl = 'https://qtftpfzcmiwxleehlmmr.supabase.co';
  static const String _supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF0ZnRwZnpjbWl3eGxlZWhsbW1yIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjgyMTQzNTIsImV4cCI6MjA4Mzc5MDM1Mn0.N4wO0-9FiQNPf7fF7CCf1GNQ55xxXDJGDz-tJ8QenhE';
  
  // Alternatively, use GitHub releases (free, no backend needed):
  // static const String _githubRepo = 'username/repo';
  
  static UpdateService? _instance;
  
  String? _currentVersion;
  String? _latestVersion;
  String? _downloadUrl;
  String? _releaseNotes;
  bool _updateAvailable = false;
  DateTime? _lastCheck;
  
  // Callbacks
  Function(UpdateInfo)? onUpdateAvailable;
  
  UpdateService._();
  
  static UpdateService get instance {
    _instance ??= UpdateService._();
    return _instance!;
  }
  
  /// Initialize and check for updates
  Future<void> initialize() async {
    final packageInfo = await PackageInfo.fromPlatform();
    _currentVersion = packageInfo.version;
    
    // Check on startup (but not too frequently)
    final prefs = await SharedPreferences.getInstance();
    final lastCheckStr = prefs.getString('last_update_check');
    
    if (lastCheckStr != null) {
      _lastCheck = DateTime.parse(lastCheckStr);
      // Only check once per day
      if (DateTime.now().difference(_lastCheck!).inHours < 24) {
        return;
      }
    }
    
    await checkForUpdates();
  }
  
  /// Check for updates from Supabase app_settings
  Future<bool> checkForUpdates() async {
    try {
      debugPrint('[UPDATE] Checking for updates... Current version: $_currentVersion');
      
      final response = await http.get(
        Uri.parse('$_supabaseUrl/rest/v1/app_settings?key=eq.latest_version'),
        headers: {
          'apikey': _supabaseAnonKey,
          'Authorization': 'Bearer $_supabaseAnonKey',
        },
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        if (data.isNotEmpty) {
          _latestVersion = data[0]['value'];
          
          // Get download URL and release notes
          final urlResponse = await http.get(
            Uri.parse('$_supabaseUrl/rest/v1/app_settings?key=eq.download_url'),
            headers: {
              'apikey': _supabaseAnonKey,
              'Authorization': 'Bearer $_supabaseAnonKey',
            },
          ).timeout(const Duration(seconds: 10));
          
          if (urlResponse.statusCode == 200) {
            final urlData = jsonDecode(urlResponse.body);
            if (urlData.isNotEmpty) {
              _downloadUrl = urlData[0]['value'];
            }
          }
          
          final notesResponse = await http.get(
            Uri.parse('$_supabaseUrl/rest/v1/app_settings?key=eq.release_notes'),
            headers: {
              'apikey': _supabaseAnonKey,
              'Authorization': 'Bearer $_supabaseAnonKey',
            },
          ).timeout(const Duration(seconds: 10));
          
          if (notesResponse.statusCode == 200) {
            final notesData = jsonDecode(notesResponse.body);
            if (notesData.isNotEmpty) {
              _releaseNotes = notesData[0]['value'];
            }
          }
          
          // Compare versions
          _updateAvailable = _isNewerVersion(_latestVersion!, _currentVersion!);
          
          debugPrint('[UPDATE] Latest version: $_latestVersion, Update available: $_updateAvailable');
          
          // Save check time
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_update_check', DateTime.now().toIso8601String());
          _lastCheck = DateTime.now();
          
          if (_updateAvailable) {
            final info = UpdateInfo(
              currentVersion: _currentVersion!,
              latestVersion: _latestVersion!,
              downloadUrl: _downloadUrl,
              releaseNotes: _releaseNotes ?? 'New version available',
            );
            onUpdateAvailable?.call(info);
          }
          
          return _updateAvailable;
        }
      }
    } catch (e) {
      debugPrint('[UPDATE] Error checking for updates: $e');
    }
    
    return false;
  }
  
  /// Alternative: Check GitHub releases (free, no backend needed)
  Future<bool> checkForUpdatesFromGitHub(String repo) async {
    try {
      debugPrint('[UPDATE] Checking GitHub releases for $repo');
      
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _latestVersion = data['tag_name'].toString().replaceAll('v', '');
        _downloadUrl = data['html_url'];
        _releaseNotes = data['body'] ?? 'New version available';
        
        _updateAvailable = _isNewerVersion(_latestVersion!, _currentVersion!);
        
        if (_updateAvailable) {
          final info = UpdateInfo(
            currentVersion: _currentVersion!,
            latestVersion: _latestVersion!,
            downloadUrl: _downloadUrl,
            releaseNotes: _releaseNotes!,
          );
          onUpdateAvailable?.call(info);
        }
        
        return _updateAvailable;
      }
    } catch (e) {
      debugPrint('[UPDATE] Error checking GitHub releases: $e');
    }
    
    return false;
  }
  
  /// Compare version strings (e.g., "1.2.3" vs "1.3.0")
  bool _isNewerVersion(String latest, String current) {
    try {
      final latestParts = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final currentParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      
      // Pad shorter version with zeros
      while (latestParts.length < 3) latestParts.add(0);
      while (currentParts.length < 3) currentParts.add(0);
      
      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
      
      return false; // Versions are equal
    } catch (e) {
      debugPrint('[UPDATE] Error comparing versions: $e');
      return false;
    }
  }
  
  /// Getters
  bool get updateAvailable => _updateAvailable;
  String? get latestVersion => _latestVersion;
  String? get currentVersion => _currentVersion;
  String? get downloadUrl => _downloadUrl;
  String? get releaseNotes => _releaseNotes;
  
  UpdateInfo? get updateInfo {
    if (!_updateAvailable) return null;
    return UpdateInfo(
      currentVersion: _currentVersion!,
      latestVersion: _latestVersion!,
      downloadUrl: _downloadUrl,
      releaseNotes: _releaseNotes ?? 'New version available',
    );
  }
}

/// Update information model
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String? downloadUrl;
  final String releaseNotes;
  
  UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    this.downloadUrl,
    required this.releaseNotes,
  });
}
