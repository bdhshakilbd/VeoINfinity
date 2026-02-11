import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  SettingsService._private();
  static final SettingsService instance = SettingsService._private();

  List<String> _geminiKeys = [];
  List<Map<String, dynamic>> _browserProfiles = [];
  List<Map<String, dynamic>> _googleAccounts = [];
  
  // Runtime generation settings (not persisted)
  String? currentModel;
  String? currentAspectRatio;
  int? currentOutputCount;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final g = prefs.getString('settings_gemini_api') ?? '';
    _geminiKeys = g
        .split(RegExp(r"\r?\n"))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final profilesJson = prefs.getString('settings_browser_profiles') ?? '[]';
    try {
      final list = jsonDecode(profilesJson) as List;
      _browserProfiles = list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      _browserProfiles = [];
    }

    final accountsJson = prefs.getString('settings_google_accounts') ?? '[]';
    try {
      final list = jsonDecode(accountsJson) as List;
      _googleAccounts = list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      _googleAccounts = [];
    }
  }

  List<String> getGeminiKeys() => List.unmodifiable(_geminiKeys);
  List<Map<String, dynamic>> getBrowserProfiles() => List.unmodifiable(_browserProfiles);
  List<Map<String, dynamic>> getGoogleAccounts() => List.unmodifiable(_googleAccounts);

  /// Returns first account assigned to [profileId] or null.
  Map<String, dynamic>? getAssignedAccountForProfile(String profileId) {
    for (final acct in _googleAccounts) {
      final assigned = (acct['assignedProfiles'] as List?)?.map((e) => e.toString()).toList() ?? [];
      if (assigned.contains(profileId)) return acct;
    }
    return null;
  }

  /// Find account by runtime profile name (matches stored profile `name`)
  /// Returns null if no account is assigned - NO FALLBACK
  Map<String, dynamic>? getAssignedAccountForProfileName(String profileName) {
    try {
      print('[SettingsService] Looking for profile: "$profileName"');
      print('[SettingsService] Available profiles: ${_browserProfiles.map((p) => p['name']).toList()}');
      
      final profile = _browserProfiles.firstWhere((p) => (p['name'] ?? '').toString() == profileName, orElse: () => {});
      final pid = profile['id']?.toString();
      if (pid == null || pid.isEmpty) {
        print('[SettingsService] No matching profile found for "$profileName"');
        return null;
      }
      print('[SettingsService] Found profile id: $pid');
      final acct = getAssignedAccountForProfile(pid);
      if (acct != null) {
        print('[SettingsService] Found assigned account: ${acct['username']}');
      } else {
        print('[SettingsService] No account assigned to profile "$profileName" (id: $pid)');
      }
      return acct;
    } catch (e) {
      print('[SettingsService] Error looking up profile "$profileName": $e');
      return null;
    }
  }

  /// Convenience: reload from prefs
  Future<void> reload() => load();

  /// Accounts getter for mobile Settings tab
  List<Map<String, dynamic>> get accounts => _googleAccounts;

  /// Add a new Google account
  void addAccount(String email, String password) {
    // Check if account already exists
    final existingIndex = _googleAccounts.indexWhere((a) => a['email'] == email || a['username'] == email);
    if (existingIndex >= 0) {
      // Update existing account
      _googleAccounts[existingIndex] = {
        ..._googleAccounts[existingIndex],
        'email': email,
        'username': email,
        'password': password,
      };
    } else {
      // Add new account
      _googleAccounts.add({
        'email': email,
        'username': email,
        'password': password,
        'assignedProfiles': [],
      });
    }
  }

  /// Remove account by index
  void removeAccount(int index) {
    if (index >= 0 && index < _googleAccounts.length) {
      _googleAccounts.removeAt(index);
    }
  }

  /// Save settings to SharedPreferences
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Save Gemini keys
    await prefs.setString('settings_gemini_api', _geminiKeys.join('\n'));
    
    // Save browser profiles
    await prefs.setString('settings_browser_profiles', jsonEncode(_browserProfiles));
    
    // Save Google accounts
    await prefs.setString('settings_google_accounts', jsonEncode(_googleAccounts));
  }
}
