/// Data structure for a single scene
class SceneData {
  final int sceneId;
  String prompt;
  String status; // queued, generating, polling, downloading, completed, failed
  String? operationName;
  String? videoPath;
  String? downloadUrl;
  String? error;
  String? generatedAt;
  int? fileSize;
  int retryCount;
  
  // Image-to-video support
  String? firstFramePath;
  String? lastFramePath;
  String? firstFrameMediaId;
  String? lastFrameMediaId;
  
  // Upload status for UI (not persisted)
  String? firstFrameUploadStatus; // null, 'uploading', 'uploaded', 'failed'
  String? lastFrameUploadStatus;  // null, 'uploading', 'uploaded', 'failed'
  
  // Upscale support
  String? videoMediaId;           // The mediaId of the original video (for upscaling)
  String? upscaleStatus;          // null, 'upscaling', 'completed', 'failed'
  String? upscaleOperationName;   // For polling upscale status
  String? upscaleVideoPath;       // Path to upscaled video
  String? upscaleDownloadUrl;     // URL to download upscaled video
  int? consecutive403Count;       // Track consecutive 403 errors for auto-relogin
  
  // Generation settings (for upscaling to use correct settings)
  String? aspectRatio;            // The aspect ratio used for generation

  SceneData({
    required this.sceneId,
    required this.prompt,
    this.status = 'queued',
    this.operationName,
    this.videoPath,
    this.downloadUrl,
    this.error,
    this.generatedAt,
    this.fileSize,
    this.retryCount = 0,
    this.firstFramePath,
    this.lastFramePath,
    this.firstFrameMediaId,
    this.lastFrameMediaId,
    this.firstFrameUploadStatus,
    this.lastFrameUploadStatus,
    this.videoMediaId,
    this.upscaleStatus,
    this.upscaleOperationName,
    this.upscaleVideoPath,
    this.upscaleDownloadUrl,
    this.consecutive403Count,
    this.aspectRatio,
  });

  Map<String, dynamic> toJson() {
    return {
      'scene_id': sceneId,
      'prompt': prompt,
      'status': status,
      'operation_name': operationName,
      'video_path': videoPath,
      'download_url': downloadUrl,
      'error': error,
      'generated_at': generatedAt,
      'file_size': fileSize,
      'retry_count': retryCount,
      'first_frame_path': firstFramePath,
      'last_frame_path': lastFramePath,
      'first_frame_media_id': firstFrameMediaId,
      'last_frame_media_id': lastFrameMediaId,
      'video_media_id': videoMediaId,
      'upscale_status': upscaleStatus,
      'upscale_operation_name': upscaleOperationName,
      'upscale_video_path': upscaleVideoPath,
      'upscale_download_url': upscaleDownloadUrl,
      'aspect_ratio': aspectRatio,
    };
  }

  factory SceneData.fromJson(Map<String, dynamic> json) {
    return SceneData(
      sceneId: json['scene_id'] as int,
      prompt: json['prompt'] as String,
      status: json['status'] as String? ?? 'queued',
      operationName: json['operation_name'] as String?,
      videoPath: json['video_path'] as String?,
      downloadUrl: json['download_url'] as String?,
      error: json['error'] as String?,
      generatedAt: json['generated_at'] as String?,
      fileSize: json['file_size'] as int?,
      retryCount: json['retry_count'] as int? ?? 0,
      firstFramePath: json['first_frame_path'] as String?,
      lastFramePath: json['last_frame_path'] as String?,
      firstFrameMediaId: json['first_frame_media_id'] as String?,
      lastFrameMediaId: json['last_frame_media_id'] as String?,
      videoMediaId: json['video_media_id'] as String?,
      upscaleStatus: json['upscale_status'] as String?,
      upscaleOperationName: json['upscale_operation_name'] as String?,
      upscaleVideoPath: json['upscale_video_path'] as String?,
      upscaleDownloadUrl: json['upscale_download_url'] as String?,
      aspectRatio: json['aspect_ratio'] as String?,
    );
  }

  SceneData copyWith({
    int? sceneId,
    String? prompt,
    String? status,
    String? operationName,
    String? videoPath,
    String? downloadUrl,
    String? error,
    String? generatedAt,
    int? fileSize,
    int? retryCount,
    String? firstFramePath,
    String? lastFramePath,
    String? firstFrameMediaId,
    String? lastFrameMediaId,
    String? videoMediaId,
    String? upscaleStatus,
    String? upscaleOperationName,
    String? upscaleVideoPath,
    String? upscaleDownloadUrl,
    String? aspectRatio,
  }) {
    return SceneData(
      sceneId: sceneId ?? this.sceneId,
      prompt: prompt ?? this.prompt,
      status: status ?? this.status,
      operationName: operationName ?? this.operationName,
      videoPath: videoPath ?? this.videoPath,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      error: error ?? this.error,
      generatedAt: generatedAt ?? this.generatedAt,
      fileSize: fileSize ?? this.fileSize,
      retryCount: retryCount ?? this.retryCount,
      firstFramePath: firstFramePath ?? this.firstFramePath,
      lastFramePath: lastFramePath ?? this.lastFramePath,
      firstFrameMediaId: firstFrameMediaId ?? this.firstFrameMediaId,
      lastFrameMediaId: lastFrameMediaId ?? this.lastFrameMediaId,
      videoMediaId: videoMediaId ?? this.videoMediaId,
      upscaleStatus: upscaleStatus ?? this.upscaleStatus,
      upscaleOperationName: upscaleOperationName ?? this.upscaleOperationName,
      upscaleVideoPath: upscaleVideoPath ?? this.upscaleVideoPath,
      upscaleDownloadUrl: upscaleDownloadUrl ?? this.upscaleDownloadUrl,
      aspectRatio: aspectRatio ?? this.aspectRatio,
    );
  }
}
