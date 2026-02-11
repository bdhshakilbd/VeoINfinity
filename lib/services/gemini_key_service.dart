import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'settings_service.dart';

class GeminiKeyService {
  static const _fileName = 'gemini_keys.json';

  static Future<File> _getStorageFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(path.join(dir.path, _fileName));
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsString('[]');
    }
    return file;
  }

  static Future<List<String>> loadKeys() async {
    // Prefer keys provided in SettingsService (SharedPreferences) if available
    try {
      final fromSettings = SettingsService.instance.getGeminiKeys();
      if (fromSettings.isNotEmpty) return fromSettings;
    } catch (_) {}

    try {
      final file = await _getStorageFile();
      final contents = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(contents) as List<dynamic>;
      final keys = jsonList.map((e) => e.toString()).toList();
      return keys;
    } catch (e) {
      return [];
    }
  }

  static Future<void> saveKeys(List<String> keys) async {
    final file = await _getStorageFile();
    final unique = keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toSet().toList();
    await file.writeAsString(jsonEncode(unique));
  }

  static Future<void> addKeys(List<String> newKeys) async {
    final existing = (await loadKeys()).toSet();
    for (var k in newKeys) {
      final kk = k.trim();
      if (kk.isNotEmpty) existing.add(kk);
    }
    await saveKeys(existing.toList());
  }

  static Future<void> removeKey(String key) async {
    final existing = (await loadKeys()).toSet();
    existing.remove(key);
    await saveKeys(existing.toList());
  }
}
