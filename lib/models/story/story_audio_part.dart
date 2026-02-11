class StoryAudioPart {
  int index;
  String text;
  String status; // idle, generating, success, error
  String voiceModel;
  String voiceStyle;
  String? audioPath;
  double? duration;
  String? error;

  StoryAudioPart({
    required this.index,
    required this.text,
    this.status = 'idle',
    this.voiceModel = 'Zephyr',
    this.voiceStyle = 'friendly and engaging',
    this.audioPath,
    this.duration,
    this.error,
  });

  // Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'text': text,
      'status': status,
      'voiceModel': voiceModel,
      'voiceStyle': voiceStyle,
      'audioPath': audioPath,
      'duration': duration,
      'error': error,
    };
  }

  // Create from JSON
  factory StoryAudioPart.fromJson(Map<String, dynamic> json) {
    return StoryAudioPart(
      index: json['index'] as int,
      text: json['text'] as String,
      status: json['status'] as String? ?? 'idle',
      voiceModel: json['voiceModel'] as String? ?? 'Zephyr',
      voiceStyle: json['voiceStyle'] as String? ?? 'friendly and engaging',
      audioPath: json['audioPath'] as String?,
      duration: json['duration'] as double?,
      error: json['error'] as String?,
    );
  }

  // Create a copy with updated fields
  StoryAudioPart copyWith({
    int? index,
    String? text,
    String? status,
    String? voiceModel,
    String? voiceStyle,
    String? audioPath,
    double? duration,
    String? error,
  }) {
    return StoryAudioPart(
      index: index ?? this.index,
      text: text ?? this.text,
      status: status ?? this.status,
      voiceModel: voiceModel ?? this.voiceModel,
      voiceStyle: voiceStyle ?? this.voiceStyle,
      audioPath: audioPath ?? this.audioPath,
      duration: duration ?? this.duration,
      error: error ?? this.error,
    );
  }
}

// Available voice models from Gemini TTS
class VoiceModels {
  static const List<String> all = [
    'Zephyr',
    'Puck',
    'Charon',
    'Kore',
    'Fenrir',
    'Leda',
    'Orus',
    'Aoede',
    'Callirrhoe',
    'Autonoe',
    'Enceladus',
    'Iapetus',
    'Umbriel',
    'Algieba',
    'Despina',
    'Erinome',
    'Algenib',
    'Rasalgethi',
    'Laomedeia',
    'Achernar',
    'Alnilam',
    'Schedar',
    'Gacrux',
    'Pulcherrima',
    'Achird',
    'Zubenelgenubi',
    'Vindemiatrix',
    'Sadachbia',
    'Sadaltager',
    'Sulafat',
  ];
}
