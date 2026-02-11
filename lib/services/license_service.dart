import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

/// License validation result
class LicenseResult {
  final bool valid;
  final String? error;
  final String? message;
  final String? licenseId;
  final DateTime? expiresAt;
  final int? daysRemaining;
  final int? maxDevices;
  final String? customerName;
  final bool isOfflineValidation;

  LicenseResult({
    required this.valid,
    this.error,
    this.message,
    this.licenseId,
    this.expiresAt,
    this.daysRemaining,
    this.maxDevices,
    this.customerName,
    this.isOfflineValidation = false,
  });

  factory LicenseResult.fromJson(Map<String, dynamic> json) {
    return LicenseResult(
      valid: json['valid'] ?? false,
      error: json['error'],
      message: json['message'],
      licenseId: json['license_id'],
      expiresAt: json['expires_at'] != null ? DateTime.parse(json['expires_at']) : null,
      daysRemaining: json['days_remaining'],
      maxDevices: json['max_devices'],
      customerName: json['customer_name'],
    );
  }

  Map<String, dynamic> toJson() => {
    'valid': valid,
    'error': error,
    'message': message,
    'license_id': licenseId,
    'expires_at': expiresAt?.toIso8601String(),
    'days_remaining': daysRemaining,
    'max_devices': maxDevices,
    'customer_name': customerName,
  };
}

/// License Service for VEO3 Infinity
class LicenseService {
  // ============================================
  // CONFIGURATION - UPDATE THESE VALUES
  // ============================================
  static const String _supabaseUrl = 'https://qtftpfzcmiwxleehlmmr.supabase.co';
  static const String _supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF0ZnRwZnpjbWl3eGxlZWhsbW1yIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjgyMTQzNTIsImV4cCI6MjA4Mzc5MDM1Mn0.N4wO0-9FiQNPf7fF7CCf1GNQ55xxXDJGDz-tJ8QenhE';
  static const int _offlineGraceDays = 0; // Days allowed offline before requiring revalidation (0 = always check online)
  static const int _checkIntervalHours = 1; // How often to revalidate online (1 hour for stricter control)
  
  // ============================================
  // PRIVATE VARIABLES
  // ============================================
  static LicenseService? _instance;
  String? _deviceId;
  String? _deviceName;
  String? _platform;
  String? _appVersion;
  LicenseResult? _cachedResult;
  DateTime? _lastValidation;
  String? _storedLicenseKey;
  
  // Callbacks
  Function(LicenseResult)? onLicenseValidated;
  Function(String)? onLicenseError;
  
  LicenseService._();
  
  static LicenseService get instance {
    _instance ??= LicenseService._();
    return _instance!;
  }
  
  /// Initialize the license service
  Future<void> initialize() async {
    await _loadDeviceInfo();
    await _loadCachedLicense();
  }
  
  /// Get unique device ID
  Future<String> getDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    await _loadDeviceInfo();
    return _deviceId!;
  }
  
  /// Load device information
  Future<void> _loadDeviceInfo() async {
    final deviceInfo = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();
    _appVersion = packageInfo.version;
    
    try {
      if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        // Create a unique ID from multiple hardware identifiers
        final rawId = '${windowsInfo.computerName}-${windowsInfo.systemMemoryInMegabytes}-${windowsInfo.numberOfCores}';
        _deviceId = _hashString(rawId);
        _deviceName = windowsInfo.computerName;
        _platform = 'windows';
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // Use Android ID (persists across app reinstalls but changes on factory reset)
        final rawId = androidInfo.id;
        _deviceId = _hashString(rawId);
        _deviceName = '${androidInfo.brand} ${androidInfo.model}';
        _platform = 'android';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        final rawId = iosInfo.identifierForVendor ?? iosInfo.name;
        _deviceId = _hashString(rawId);
        _deviceName = iosInfo.name;
        _platform = 'ios';
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        final rawId = '${macInfo.computerName}-${macInfo.systemGUID ?? macInfo.hostName}';
        _deviceId = _hashString(rawId);
        _deviceName = macInfo.computerName;
        _platform = 'macos';
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        final rawId = linuxInfo.machineId ?? linuxInfo.id;
        _deviceId = _hashString(rawId);
        _deviceName = linuxInfo.prettyName;
        _platform = 'linux';
      } else {
        // Fallback for web or unknown platforms
        _deviceId = _hashString('unknown-${DateTime.now().millisecondsSinceEpoch}');
        _deviceName = 'Unknown Device';
        _platform = 'unknown';
      }
    } catch (e) {
      debugPrint('Error getting device info: $e');
      // Fallback device ID
      _deviceId = _hashString('fallback-${DateTime.now().millisecondsSinceEpoch}');
      _deviceName = 'Unknown Device';
      _platform = 'unknown';
    }
  }
  
  /// Hash a string using SHA256
  String _hashString(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 32); // Take first 32 chars
  }
  
  /// Load cached license from local storage
  Future<void> _loadCachedLicense() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _storedLicenseKey = prefs.getString('license_key');
      
      final cachedJson = prefs.getString('license_cache');
      if (cachedJson != null) {
        final data = jsonDecode(cachedJson);
        _cachedResult = LicenseResult.fromJson(data['result']);
        _lastValidation = DateTime.parse(data['validated_at']);
      }
    } catch (e) {
      debugPrint('Error loading cached license: $e');
    }
  }
  
  /// Save license cache to local storage
  Future<void> _saveLicenseCache(LicenseResult result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('license_cache', jsonEncode({
        'result': result.toJson(),
        'validated_at': DateTime.now().toIso8601String(),
      }));
      _cachedResult = result;
      _lastValidation = DateTime.now();
    } catch (e) {
      debugPrint('Error saving license cache: $e');
    }
  }
  
  /// Save license key
  Future<void> saveLicenseKey(String licenseKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('license_key', licenseKey.trim().toUpperCase());
    _storedLicenseKey = licenseKey.trim().toUpperCase();
  }
  
  /// Get stored license key
  String? get storedLicenseKey => _storedLicenseKey;
  
  /// Clear license data (for logout/reset)
  Future<void> clearLicense() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('license_key');
    await prefs.remove('license_cache');
    _storedLicenseKey = null;
    _cachedResult = null;
    _lastValidation = null;
  }
  
  /// Check if license needs revalidation
  bool _needsRevalidation() {
    if (_lastValidation == null) return true;
    final hoursSinceValidation = DateTime.now().difference(_lastValidation!).inHours;
    return hoursSinceValidation >= _checkIntervalHours;
  }
  
  /// Check if offline cache is still valid
  bool _isOfflineCacheValid() {
    if (_cachedResult == null || _lastValidation == null) return false;
    if (!_cachedResult!.valid) return false;
    
    // Check if within offline grace period
    final daysSinceValidation = DateTime.now().difference(_lastValidation!).inDays;
    if (daysSinceValidation > _offlineGraceDays) return false;
    
    // Check if license hasn't expired
    if (_cachedResult!.expiresAt != null && _cachedResult!.expiresAt!.isBefore(DateTime.now())) {
      return false;
    }
    
    return true;
  }
  
  /// Validate license (main entry point)
  /// Returns cached result if valid and not stale, otherwise validates online
  Future<LicenseResult> validateLicense({String? licenseKey, bool forceOnline = false}) async {
    final key = licenseKey?.trim().toUpperCase() ?? _storedLicenseKey;
    
    if (key == null || key.isEmpty) {
      return LicenseResult(
        valid: false,
        error: 'NO_LICENSE_KEY',
        message: 'Please enter a license key',
      );
    }
    
    // Save the license key
    if (licenseKey != null) {
      await saveLicenseKey(key);
    }
    
    // Always try online validation first for immediate license status updates
    // (deactivation, expiration, etc.)
    try {
      final result = await _validateOnline(key);
      await _saveLicenseCache(result);
      onLicenseValidated?.call(result);
      return result;
    } catch (e) {
      debugPrint('Online validation failed: $e');
      
      // Check if offline cache is valid
      if (_isOfflineCacheValid()) {
        final offlineResult = LicenseResult(
          valid: true,
          message: 'Validated offline (last check: ${_lastValidation?.toLocal()})',
          licenseId: _cachedResult!.licenseId,
          expiresAt: _cachedResult!.expiresAt,
          daysRemaining: _cachedResult!.daysRemaining,
          maxDevices: _cachedResult!.maxDevices,
          customerName: _cachedResult!.customerName,
          isOfflineValidation: true,
        );
        return offlineResult;
      }
      
      // No valid cache - return error
      final errorResult = LicenseResult(
        valid: false,
        error: 'NETWORK_ERROR',
        message: 'Unable to validate license. Please check your internet connection.',
      );
      onLicenseError?.call(e.toString());
      return errorResult;
    }
  }
  
  /// Validate license online
  Future<LicenseResult> _validateOnline(String licenseKey) async {
    await _loadDeviceInfo();
    
    debugPrint('[LICENSE] Validating license: $licenseKey');
    debugPrint('[LICENSE] Device ID: $_deviceId');
    debugPrint('[LICENSE] Supabase URL: $_supabaseUrl');
    
    try {
      final response = await http.post(
        Uri.parse('$_supabaseUrl/rest/v1/rpc/validate_license'),
        headers: {
          'Content-Type': 'application/json',
          'apikey': _supabaseAnonKey,
          'Authorization': 'Bearer $_supabaseAnonKey',
          'Prefer': 'return=representation',
        },
        body: jsonEncode({
          'p_license_key': licenseKey,
          'p_device_id': _deviceId,
          'p_device_name': _deviceName,
          'p_platform': _platform,
          'p_app_version': _appVersion,
        }),
      ).timeout(const Duration(seconds: 15));
      
      debugPrint('[LICENSE] Response status: ${response.statusCode}');
      debugPrint('[LICENSE] Response body: ${response.body}');
      
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return LicenseResult.fromJson(json);
      } else {
        debugPrint('[LICENSE] Server error response: ${response.body}');
        throw Exception('Server error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('[LICENSE] Exception during validation: $e');
      rethrow;
    }
  }
  
  /// Quick check if license is valid (uses cache, non-blocking)
  bool get isLicenseValid {
    if (_cachedResult == null) return false;
    if (!_cachedResult!.valid) return false;
    if (_cachedResult!.expiresAt != null && _cachedResult!.expiresAt!.isBefore(DateTime.now())) {
      return false;
    }
    return true;
  }
  
  /// Get license info for display
  Map<String, dynamic> get licenseInfo => {
    'valid': isLicenseValid,
    'license_key': _storedLicenseKey,
    'customer_name': _cachedResult?.customerName,
    'expires_at': _cachedResult?.expiresAt?.toIso8601String(),
    'days_remaining': _cachedResult?.daysRemaining,
    'max_devices': _cachedResult?.maxDevices,
    'device_id': _deviceId,
    'device_name': _deviceName,
    'platform': _platform,
    'last_validation': _lastValidation?.toIso8601String(),
    'is_offline': _cachedResult?.isOfflineValidation ?? false,
  };
  
  /// Export license file (for backup)
  Future<String?> exportLicenseFile() async {
    if (_storedLicenseKey == null) return null;
    
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/veo3_license.json');
      
      await file.writeAsString(jsonEncode({
        'license_key': _storedLicenseKey,
        'exported_at': DateTime.now().toIso8601String(),
        'device_id': _deviceId,
      }));
      
      return file.path;
    } catch (e) {
      debugPrint('Error exporting license: $e');
      return null;
    }
  }
  
  /// Import license from file
  Future<bool> importLicenseFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      
      final content = await file.readAsString();
      final json = jsonDecode(content);
      
      if (json['license_key'] != null) {
        await saveLicenseKey(json['license_key']);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error importing license: $e');
      return false;
    }
  }
}
