/// Model for character data in Character Studio
class CharacterData {
  String id;
  String name;
  String description;
  List<String> keyPath;
  List<String> images;

  CharacterData({
    required this.id,
    required this.name,
    this.description = '',
    this.keyPath = const [],
    this.images = const [],
  });

  factory CharacterData.fromJson(Map<String, dynamic> json) {
    return CharacterData(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String? ?? json['visual_description'] as String? ?? '',
      keyPath: (json['key_path'] as List<dynamic>?)?.cast<String>() ?? [],
      images: (json['images'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'key_path': keyPath,
    'images': images,
  };
}
