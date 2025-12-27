import 'dart:convert';
import '../models/scene_data.dart';

/// Parse JSON prompts from text
List<SceneData> parseJsonPrompts(String text) {
  // Find content between [ and ]
  final match = RegExp(r'\[(.*)\]', dotAll: true).firstMatch(text);
  if (match == null) {
    throw Exception('No JSON array found in text (looking for [...] brackets)');
  }

  final jsonStr = '[${match.group(1)}]';
  final data = jsonDecode(jsonStr) as List;

  // Send entire JSON object as prompt
  final prompts = <SceneData>[];
  for (var i = 0; i < data.length; i++) {
    final item = data[i] as Map<String, dynamic>;
    final sceneId = item['scene_id'] as int? ?? (i + 1);
    // Convert entire JSON object to formatted string
    final prompt = const JsonEncoder.withIndent('  ').convert(item);
    prompts.add(SceneData(sceneId: sceneId, prompt: prompt));
  }

  return prompts;
}

/// Parse line-separated prompts
List<SceneData> parseTxtPrompts(String text) {
  final lines = text.split('\n').where((line) => line.trim().isNotEmpty).toList();
  return lines
      .asMap()
      .entries
      .map((entry) => SceneData(sceneId: entry.key + 1, prompt: entry.value.trim()))
      .toList();
}

/// Try to parse content as JSON or TXT
List<SceneData> parsePrompts(String content) {
  try {
    return parseJsonPrompts(content);
  } catch (e) {
    return parseTxtPrompts(content);
  }
}
