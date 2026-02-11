import 'dart:convert';
import '../models/scene_data.dart';

/// Parse JSON prompts from text - handles multiple formats:
/// 1. Direct array of scene objects: [{"scene_number": 1, "prompt": "..."}]
/// 2. Object with output_structure.scenes: {"output_structure": {"scenes": [...]}}
/// 3. Object with scenes at root: {"scenes": [...]}
List<SceneData> parseJsonPrompts(String content) {
  // Clean content - remove markdown code blocks if present
  String cleanContent = content.trim();
  if (cleanContent.contains('```')) {
    final match = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', multiLine: true).firstMatch(cleanContent);
    if (match != null) {
      cleanContent = match.group(1)!.trim();
    }
  }
  
  // Try to parse as JSON
  dynamic jsonData;
  try {
    jsonData = jsonDecode(cleanContent);
  } catch (e) {
    // Try to extract JSON array from content
    final arrayMatch = RegExp(r'\[(.*)\]', dotAll: true).firstMatch(cleanContent);
    if (arrayMatch != null) {
      jsonData = jsonDecode('[${arrayMatch.group(1)}]');
    } else {
      throw Exception('No valid JSON found in content');
    }
  }
  
  // Extract scenes array from various formats
  List<dynamic> scenesArray = [];
  
  if (jsonData is List) {
    // Format 1: Direct array of scenes
    scenesArray = jsonData;
  } else if (jsonData is Map<String, dynamic>) {
    // Format 2: Check for output_structure.scenes
    if (jsonData.containsKey('output_structure') && jsonData['output_structure'] is Map) {
      final outputStructure = jsonData['output_structure'] as Map;
      if (outputStructure.containsKey('scenes') && outputStructure['scenes'] is List) {
        scenesArray = outputStructure['scenes'] as List;
      }
    }
    // Format 3: Check for scenes at root level
    else if (jsonData.containsKey('scenes') && jsonData['scenes'] is List) {
      scenesArray = jsonData['scenes'] as List;
    }
    // Fallback: If it's a single scene object with prompt
    else if (jsonData.containsKey('prompt') || jsonData.containsKey('scene_number')) {
      scenesArray = [jsonData];
    }
  }
  
  if (scenesArray.isEmpty) {
    throw Exception('No scenes found in JSON. Expected: array, or object with output_structure.scenes or scenes field.');
  }
  
  // Parse scenes into SceneData objects
  final prompts = <SceneData>[];
  for (var i = 0; i < scenesArray.length; i++) {
    final item = scenesArray[i];
    if (item is! Map) continue;
    
    final sceneMap = Map<String, dynamic>.from(item);
    
    // Extract scene ID (try multiple field names)
    final sceneId = sceneMap['scene_number'] as int? ?? 
                    sceneMap['scene_id'] as int? ?? 
                    sceneMap['sceneId'] as int? ?? 
                    (i + 1);
    
    // Extract prompt - prefer video_action_prompt for video generation, fallback to prompt
    String prompt = '';
    if (sceneMap.containsKey('video_action_prompt') && 
        sceneMap['video_action_prompt'] != null && 
        sceneMap['video_action_prompt'].toString().isNotEmpty) {
      // Use video_action_prompt for video generation
      prompt = sceneMap['video_action_prompt'].toString();
    } else if (sceneMap.containsKey('prompt') && sceneMap['prompt'] != null) {
      prompt = sceneMap['prompt'].toString();
    } else {
      // Fallback: convert entire object to JSON string
      prompt = const JsonEncoder.withIndent('  ').convert(sceneMap);
    }
    
    // Skip empty prompts
    if (prompt.isEmpty) continue;
    
    prompts.add(SceneData(
      sceneId: sceneId,
      prompt: prompt,
    ));
  }
  
  if (prompts.isEmpty) {
    throw Exception('No valid scenes with prompts found');
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
  // First try JSON parsing (handles all structured formats)
  try {
    return parseJsonPrompts(content);
  } catch (jsonError) {
    // Fallback to line-by-line text parsing
    try {
      final txtResult = parseTxtPrompts(content);
      if (txtResult.isNotEmpty) {
        return txtResult;
      }
    } catch (_) {}
    
    // Re-throw JSON error if text parsing also failed
    throw jsonError;
  }
}
