import 'story_audio_part.dart';
import 'alignment_item.dart';

class ReelTemplate {
  final String id;
  final String name;
  final String systemPrompt;

  ReelTemplate({required this.id, required this.name, required this.systemPrompt});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'systemPrompt': systemPrompt};
  
  factory ReelTemplate.fromJson(Map<String, dynamic> json) => ReelTemplate(
    id: json['id'] ?? '', 
    name: json['name'] ?? 'Untitled', 
    systemPrompt: json['systemPrompt'] ?? ''
  );
}

class StoryAudioState {
  List<StoryAudioPart> parts;
  String storyScript;
  String actionPrompts;
  String splitMode;
  String customDelimiter;
  String globalVoiceModel;
  String globalVoiceStyle;
  List<AlignmentItem>? alignmentJson;
  List<String>? videosPaths;
  String reelTopic;
  String reelCharacter;
  String? reelLanguage; 
  List<Map<String, dynamic>>? reelProjects;
  List<ReelTemplate> reelTemplates;
  String? selectedReelTemplateId;
  
  // Bulk Export Settings
  String bulkExportMethod;
  String bulkExportResolution;
  bool bulkAutoExport;
  String bulkVoiceName;
  double exportPlaybackSpeed;
  double exportTtsVolume;
  double exportVideoVolume;
  String globalAudioStyleInstruction;

  StoryAudioState({
    this.parts = const [],
    this.storyScript = '',
    this.actionPrompts = '',
    this.splitMode = 'numbered',
    this.customDelimiter = '---',
    this.globalVoiceModel = 'Zephyr',
    this.globalVoiceStyle = 'friendly and engaging',
    this.alignmentJson,
    this.videosPaths,
    this.reelTopic = '',
    this.reelCharacter = 'Boy',
    this.reelLanguage = 'English', 
    this.reelProjects,
    this.reelTemplates = const [],
    this.selectedReelTemplateId,
    // Bulk Export Settings
    this.bulkExportMethod = 'precise',
    this.bulkExportResolution = 'original',
    this.bulkAutoExport = true,
    this.bulkVoiceName = 'Zephyr',
    this.exportPlaybackSpeed = 1.2,
    this.exportTtsVolume = 2.5,
    this.exportVideoVolume = 0.5,
    this.globalAudioStyleInstruction = '',
  });

  // Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'parts': parts.map((p) => p.toJson()).toList(),
      'storyScript': storyScript,
      'actionPrompts': actionPrompts,
      'splitMode': splitMode,
      'customDelimiter': customDelimiter,
      'globalVoiceModel': globalVoiceModel,
      'globalVoiceStyle': globalVoiceStyle,
      'alignmentJson': alignmentJson?.map((a) => a.toJson()).toList(),
      'videosPaths': videosPaths,
      'reelTopic': reelTopic,
      'reelCharacter': reelCharacter,
      'reelLanguage': reelLanguage,
      'reelProjects': reelProjects,
      'reelTemplates': reelTemplates.map((t) => t.toJson()).toList(),
      'selectedReelTemplateId': selectedReelTemplateId,
      // Bulk Export Settings
      'bulkExportMethod': bulkExportMethod,
      'bulkExportResolution': bulkExportResolution,
      'bulkAutoExport': bulkAutoExport,
      'bulkVoiceName': bulkVoiceName,
      'exportPlaybackSpeed': exportPlaybackSpeed,
      'exportTtsVolume': exportTtsVolume,
      'exportVideoVolume': exportVideoVolume,
      'globalAudioStyleInstruction': globalAudioStyleInstruction,
    };
  }

  // Create from JSON
  factory StoryAudioState.fromJson(Map<String, dynamic> json) {
    return StoryAudioState(
      parts: (json['parts'] as List?)
              ?.map((p) => StoryAudioPart.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [],
      storyScript: json['storyScript'] as String? ?? '',
      actionPrompts: json['actionPrompts'] as String? ?? '',
      splitMode: json['splitMode'] as String? ?? 'numbered',
      customDelimiter: json['customDelimiter'] as String? ?? '---',
      globalVoiceModel: json['globalVoiceModel'] as String? ?? 'Zephyr',
      globalVoiceStyle: json['globalVoiceStyle'] as String? ?? 'friendly and engaging',
      alignmentJson: (json['alignmentJson'] as List?)
          ?.map((a) => AlignmentItem.fromJson(a as Map<String, dynamic>))
          .toList(),
      videosPaths: (json['videosPaths'] as List?)?.cast<String>(),
      reelTopic: json['reelTopic'] as String? ?? '',
      reelCharacter: json['reelCharacter'] as String? ?? 'Boy',
      reelLanguage: json['reelLanguage'] as String? ?? 'English',
      reelProjects: (json['reelProjects'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
      reelTemplates: (json['reelTemplates'] as List?)?.map((t) => ReelTemplate.fromJson(t)).toList() ?? [],
      selectedReelTemplateId: json['selectedReelTemplateId'],
      // Bulk Export Settings
      bulkExportMethod: json['bulkExportMethod'] as String? ?? 'precise',
      bulkExportResolution: json['bulkExportResolution'] as String? ?? 'original',
      bulkAutoExport: json['bulkAutoExport'] as bool? ?? true,
      bulkVoiceName: json['bulkVoiceName'] as String? ?? 'Zephyr',
      exportPlaybackSpeed: (json['exportPlaybackSpeed'] as num?)?.toDouble() ?? 1.2,
      exportTtsVolume: (json['exportTtsVolume'] as num?)?.toDouble() ?? 2.5,
      exportVideoVolume: (json['exportVideoVolume'] as num?)?.toDouble() ?? 0.5,
      globalAudioStyleInstruction: json['globalAudioStyleInstruction'] as String? ?? '',
    );
  }

  // Create a copy with updated fields
  StoryAudioState copyWith({
    List<StoryAudioPart>? parts,
    String? storyScript,
    String? actionPrompts,
    String? splitMode,
    String? customDelimiter,
    String? globalVoiceModel,
    String? globalVoiceStyle,
    List<AlignmentItem>? alignmentJson,
    List<String>? videosPaths,
    String? reelTopic,
    String? reelCharacter,
    String? reelLanguage,
    List<Map<String, dynamic>>? reelProjects,
    List<ReelTemplate>? reelTemplates,
    Object? selectedReelTemplateId = const _Unset(), // Sentinel pattern for nullable field
    // Bulk Export Settings
    String? bulkExportMethod,
    String? bulkExportResolution,
    bool? bulkAutoExport,
    String? bulkVoiceName,
    double? exportPlaybackSpeed,
    double? exportTtsVolume,
    double? exportVideoVolume,
    String? globalAudioStyleInstruction,
  }) {
    return StoryAudioState(
      parts: parts ?? this.parts,
      storyScript: storyScript ?? this.storyScript,
      actionPrompts: actionPrompts ?? this.actionPrompts,
      splitMode: splitMode ?? this.splitMode,
      customDelimiter: customDelimiter ?? this.customDelimiter,
      globalVoiceModel: globalVoiceModel ?? this.globalVoiceModel,
      globalVoiceStyle: globalVoiceStyle ?? this.globalVoiceStyle,
      alignmentJson: alignmentJson ?? this.alignmentJson,
      videosPaths: videosPaths ?? this.videosPaths,
      reelTopic: reelTopic ?? this.reelTopic,
      reelCharacter: reelCharacter ?? this.reelCharacter,
      reelLanguage: reelLanguage ?? this.reelLanguage,
      reelProjects: reelProjects ?? this.reelProjects,
      reelTemplates: reelTemplates ?? this.reelTemplates,
      selectedReelTemplateId: selectedReelTemplateId is _Unset ? this.selectedReelTemplateId : selectedReelTemplateId as String?,
      // Bulk Export Settings
      bulkExportMethod: bulkExportMethod ?? this.bulkExportMethod,
      bulkExportResolution: bulkExportResolution ?? this.bulkExportResolution,
      bulkAutoExport: bulkAutoExport ?? this.bulkAutoExport,
      bulkVoiceName: bulkVoiceName ?? this.bulkVoiceName,
      exportPlaybackSpeed: exportPlaybackSpeed ?? this.exportPlaybackSpeed,
      exportTtsVolume: exportTtsVolume ?? this.exportTtsVolume,
      exportVideoVolume: exportVideoVolume ?? this.exportVideoVolume,
      globalAudioStyleInstruction: globalAudioStyleInstruction ?? this.globalAudioStyleInstruction,
    );
  }
}

// Sentinel class for copyWith nullable fields
class _Unset {
  const _Unset();
}
