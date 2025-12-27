/// Video generation configuration options for VideoFX Flow
class VideoGenerationConfig {
  final AspectRatio aspectRatio;
  final VeoModel model;
  final int numberOfVideos;

  VideoGenerationConfig({
    this.aspectRatio = AspectRatio.landscape,
    this.model = VeoModel.veo31Fast,
    this.numberOfVideos = 2,
  });

  Map<String, dynamic> toJson() => {
    'aspectRatio': aspectRatio.label,
    'model': model.label,
    'numberOfVideos': numberOfVideos,
  };
}

/// Aspect ratio options for video generation
enum AspectRatio {
  landscape('Landscape (16:9)', 'VIDEO_ASPECT_RATIO_LANDSCAPE'),
  portrait('Portrait (9:16)', 'VIDEO_ASPECT_RATIO_PORTRAIT');

  final String label;
  final String apiValue;
  const AspectRatio(this.label, this.apiValue);
}

/// Veo model options
enum VeoModel {
  veo31Fast('Veo 3.1 - Fast', 'veo_3_1_t2v_fast_ultra'),
  veo31Quality('Veo 3.1 - Quality', 'veo_3_1_t2v_quality_ultra'),
  veo2Fast('Veo 2 - Fast', 'veo_2_t2v_fast'),
  veo2Quality('Veo 2 - Quality', 'veo_2_t2v_quality');

  final String label;
  final String apiValue;
  const VeoModel(this.label, this.apiValue);

  /// Get portrait variant of the model if applicable
  String getPortraitVariant() {
    if (this == VeoModel.veo31Fast) {
      return 'veo_3_1_t2v_fast_portrait_ultra';
    }
    // Other models may not have portrait variants
    return apiValue;
  }

  /// Get i2v (image-to-video) variant of the model
  String getI2vVariant() {
    return apiValue.replaceAll('t2v', 'i2v_s');
  }
}
