class AlignmentItem {
  int audioPartIndex;
  String text;
  List<VideoReference> matchingVideos;

  AlignmentItem({
    required this.audioPartIndex,
    required this.text,
    required this.matchingVideos,
  });

  // Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'audio_part_index': audioPartIndex,
      'text': text,
      'matching_videos': matchingVideos.map((v) => v.toJson()).toList(),
    };
  }

  // Create from JSON
  factory AlignmentItem.fromJson(Map<String, dynamic> json) {
    return AlignmentItem(
      audioPartIndex: json['audio_part_index'] as int,
      text: json['text'] as String,
      matchingVideos: (json['matching_videos'] as List)
          .map((v) => VideoReference.fromJson(v as Map<String, dynamic>))
          .toList(),
    );
  }
}

class VideoReference {
  String id;

  VideoReference({
    required this.id,
  });

  // Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
    };
  }

  // Create from JSON
  factory VideoReference.fromJson(Map<String, dynamic> json) {
    return VideoReference(
      id: json['id'] as String,
    );
  }
}
