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
    );
  }
}

// Sentinel class for copyWith nullable fields
class _Unset {
  const _Unset();
}
