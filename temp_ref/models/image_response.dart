class ImageResponse {
  final List<ImagePanel> imagePanels;
  final String workflowId;

  ImageResponse({
    required this.imagePanels,
    required this.workflowId,
  });

  factory ImageResponse.fromJson(Map<String, dynamic> json) {
    return ImageResponse(
      imagePanels: (json['imagePanels'] as List)
          .map((panel) => ImagePanel.fromJson(panel))
          .toList(),
      workflowId: json['workflowId'] ?? '',
    );
  }
}

class ImagePanel {
  final String prompt;
  final List<GeneratedImage> generatedImages;

  ImagePanel({
    required this.prompt,
    required this.generatedImages,
  });

  factory ImagePanel.fromJson(Map<String, dynamic> json) {
    return ImagePanel(
      prompt: json['prompt'] ?? '',
      generatedImages: (json['generatedImages'] as List)
          .map((image) => GeneratedImage.fromJson(image))
          .toList(),
    );
  }
}

class GeneratedImage {
  final String encodedImage;
  final int seed;
  final String mediaGenerationId;
  final String prompt;
  final String imageModel;
  final String workflowId;
  final String mediaVisibility;
  final String fingerprintLogRecordId;
  final String aspectRatio;

  GeneratedImage({
    required this.encodedImage,
    required this.seed,
    required this.mediaGenerationId,
    required this.prompt,
    required this.imageModel,
    required this.workflowId,
    required this.mediaVisibility,
    required this.fingerprintLogRecordId,
    required this.aspectRatio,
  });

  factory GeneratedImage.fromJson(Map<String, dynamic> json) {
    return GeneratedImage(
      encodedImage: json['encodedImage'] ?? '',
      seed: json['seed'] ?? 0,
      mediaGenerationId: json['mediaGenerationId'] ?? '',
      prompt: json['prompt'] ?? '',
      imageModel: json['imageModel'] ?? '',
      workflowId: json['workflowId'] ?? '',
      mediaVisibility: json['mediaVisibility'] ?? '',
      fingerprintLogRecordId: json['fingerprintLogRecordId'] ?? '',
      aspectRatio: json['aspectRatio'] ?? '',
    );
  }
}
