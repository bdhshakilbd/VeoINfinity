import 'dart:convert';
import 'dart:io';

/// Service for importing and parsing prompt files
class PromptImportService {
  /// Import prompts from a TXT or JSON file
  Future<List<String>> importPromptsFromFile(File file) async {
    final extension = file.path.toLowerCase().split('.').last;
    
    if (extension == 'txt') {
      return await _importFromTxt(file);
    } else if (extension == 'json') {
      return await _importFromJson(file);
    } else {
      throw Exception('Unsupported file format. Please use .txt or .json files.');
    }
  }
  
  /// Parse TXT file - each line is a prompt
  Future<List<String>> _importFromTxt(File file) async {
    final content = await file.readAsString();
    final lines = content.split('\n');
    
    // Filter out empty lines and trim whitespace
    final prompts = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    
    if (prompts.isEmpty) {
      throw Exception('No prompts found in TXT file');
    }
    
    return prompts;
  }
  
  /// Parse JSON file - array of strings or objects with "prompt" field
  Future<List<String>> _importFromJson(File file) async {
    final content = await file.readAsString();
    final dynamic jsonData = jsonDecode(content);
    
    if (jsonData is! List) {
      throw Exception('JSON file must contain an array of prompts');
    }
    
    final prompts = <String>[];
    
    for (final item in jsonData) {
      if (item is String) {
        // Direct string prompt
        prompts.add(item.trim());
      } else if (item is Map<String, dynamic>) {
        // Object with "prompt" field
        final prompt = item['prompt'] as String?;
        if (prompt != null && prompt.trim().isNotEmpty) {
          prompts.add(prompt.trim());
        }
      }
    }
    
    if (prompts.isEmpty) {
      throw Exception('No valid prompts found in JSON file');
    }
    
    return prompts;
  }
}
