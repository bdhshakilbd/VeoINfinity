/// Video Mastering Data Models
/// Models for video project, clips, audio, overlays, and settings

import 'dart:convert';

/// Main Video Project containing all tracks and settings
class VideoProject {
  final String id;
  String name;
  List<VideoClip> videoClips;
  List<AudioClip> audioClips;
  List<AudioClip> bgMusicClips;
  List<OverlayItem> overlays;
  List<OverlayItem> textOverlays = []; // Separate list for text overlays
  String? defaultIntroPath;
  String? defaultOutroPath;
  LogoSettings? logoSettings;
  ExportSettings exportSettings;
  DateTime createdAt;
  DateTime updatedAt;
  
  // Track mute states
  bool isVideoTrackMuted;
  bool isAudioTrackMuted;
  bool isBgMusicTrackMuted;
  
  // Master volume controls (0.0 - 5.0, where 1.0 = 100%, 5.0 = 500%)
  double videoMasterVolume;
  double audioMasterVolume;
  double bgMusicMasterVolume;
  
  // Transition settings (dissolve between clips)
  bool transitionsEnabled; // Default: true
  double transitionDuration; // Default: 1.0 seconds
  String transitionType; // Default: 'dissolve' (xfade in FFmpeg)

  VideoProject({
    required this.id,
    required this.name,
    List<VideoClip>? videoClips,
    List<AudioClip>? audioClips,
    List<AudioClip>? bgMusicClips,
    List<OverlayItem>? overlays,
    List<OverlayItem>? textOverlays,
    this.defaultIntroPath,
    this.defaultOutroPath,
    this.logoSettings,
    ExportSettings? exportSettings,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isVideoTrackMuted = false,
    this.isAudioTrackMuted = false,
    this.isBgMusicTrackMuted = false,
    this.videoMasterVolume = 1.0,
    this.audioMasterVolume = 1.0,
    this.bgMusicMasterVolume = 1.0,
    this.transitionsEnabled = false, // Default: false for faster exports
    this.transitionDuration = 0.7,
    this.transitionType = 'fade', // smooth linear crossfade
  })  : videoClips = videoClips ?? [],
        audioClips = audioClips ?? [],
        bgMusicClips = bgMusicClips ?? [],
        overlays = overlays ?? [],
        textOverlays = textOverlays ?? [],
        exportSettings = exportSettings ?? ExportSettings(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Get total project duration based on all clips
  double get totalDuration {
    double maxDuration = 0;
    for (var clip in videoClips) {
      final end = clip.timelineStart + clip.effectiveDuration;
      if (end > maxDuration) maxDuration = end;
    }
    for (var clip in audioClips) {
      final end = clip.timelineStart + clip.effectiveDuration;
      if (end > maxDuration) maxDuration = end;
    }
    for (var clip in bgMusicClips) {
      final end = clip.timelineStart + clip.effectiveDuration;
      if (end > maxDuration) maxDuration = end;
    }
    return maxDuration;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'videoClips': videoClips.map((c) => c.toJson()).toList(),
        'audioClips': audioClips.map((c) => c.toJson()).toList(),
        'bgMusicClips': bgMusicClips.map((c) => c.toJson()).toList(),
        'overlays': overlays.map((o) => o.toJson()).toList(),
        'textOverlays': textOverlays.map((o) => o.toJson()).toList(),
        'defaultIntroPath': defaultIntroPath,
        'defaultOutroPath': defaultOutroPath,
        'logoSettings': logoSettings?.toJson(),
        'exportSettings': exportSettings.toJson(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'isVideoTrackMuted': isVideoTrackMuted,
        'isAudioTrackMuted': isAudioTrackMuted,
        'isBgMusicTrackMuted': isBgMusicTrackMuted,
        'videoMasterVolume': videoMasterVolume,
        'audioMasterVolume': audioMasterVolume,
        'bgMusicMasterVolume': bgMusicMasterVolume,
        'transitionsEnabled': transitionsEnabled,
        'transitionDuration': transitionDuration,
        'transitionType': transitionType,
      };

  factory VideoProject.fromJson(Map<String, dynamic> json) => VideoProject(
        id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: json['name'] ?? 'Untitled Project',
        videoClips: (json['videoClips'] as List?)
                ?.map((c) => VideoClip.fromJson(c))
                .toList() ??
            [],
        audioClips: (json['audioClips'] as List?)
                ?.map((c) => AudioClip.fromJson(c))
                .toList() ??
            [],
        bgMusicClips: (json['bgMusicClips'] as List?)
                ?.map((c) => AudioClip.fromJson(c))
                .toList() ??
            [],
        overlays: (json['overlays'] as List?)
                ?.map((o) => OverlayItem.fromJson(o))
                .toList() ??
            [],
        textOverlays: (json['textOverlays'] as List?)
                ?.map((o) => OverlayItem.fromJson(o))
                .toList() ??
            [],
        defaultIntroPath: json['defaultIntroPath'],
        defaultOutroPath: json['defaultOutroPath'],
        logoSettings: json['logoSettings'] != null
            ? LogoSettings.fromJson(json['logoSettings'])
            : null,
        exportSettings: json['exportSettings'] != null
            ? ExportSettings.fromJson(json['exportSettings'])
            : ExportSettings(),
        createdAt: json['createdAt'] != null
            ? DateTime.parse(json['createdAt'])
            : DateTime.now(),
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'])
            : DateTime.now(),
        isVideoTrackMuted: json['isVideoTrackMuted'] ?? false,
        isAudioTrackMuted: json['isAudioTrackMuted'] ?? false,
        isBgMusicTrackMuted: json['isBgMusicTrackMuted'] ?? false,
        videoMasterVolume: (json['videoMasterVolume'] ?? 1.0).toDouble(),
        audioMasterVolume: (json['audioMasterVolume'] ?? 1.0).toDouble(),
        bgMusicMasterVolume: (json['bgMusicMasterVolume'] ?? 1.0).toDouble(),
        transitionsEnabled: json['transitionsEnabled'] ?? false,
        transitionDuration: (json['transitionDuration'] ?? 0.7).toDouble(),
        // Migrate old 'dissolve' to 'fade' for smoother transitions
        transitionType: (json['transitionType'] == 'dissolve' || json['transitionType'] == null) ? 'fade' : json['transitionType'],
      );

  VideoProject copyWith({
    String? id,
    String? name,
    List<VideoClip>? videoClips,
    List<AudioClip>? audioClips,
    List<AudioClip>? bgMusicClips,
    List<OverlayItem>? overlays,
    List<OverlayItem>? textOverlays,
    String? defaultIntroPath,
    String? defaultOutroPath,
    LogoSettings? logoSettings,
    ExportSettings? exportSettings,
    bool? isVideoTrackMuted,
    bool? isAudioTrackMuted,
    bool? isBgMusicTrackMuted,
    double? videoMasterVolume,
    double? audioMasterVolume,
    double? bgMusicMasterVolume,
    bool? transitionsEnabled,
    double? transitionDuration,
    String? transitionType,
  }) {
    return VideoProject(
      id: id ?? this.id,
      name: name ?? this.name,
      videoClips: videoClips ?? this.videoClips,
      audioClips: audioClips ?? this.audioClips,
      bgMusicClips: bgMusicClips ?? this.bgMusicClips,
      overlays: overlays ?? this.overlays,
      textOverlays: textOverlays ?? this.textOverlays,
      defaultIntroPath: defaultIntroPath ?? this.defaultIntroPath,
      defaultOutroPath: defaultOutroPath ?? this.defaultOutroPath,
      logoSettings: logoSettings ?? this.logoSettings,
      exportSettings: exportSettings ?? this.exportSettings,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      isVideoTrackMuted: isVideoTrackMuted ?? this.isVideoTrackMuted,
      isAudioTrackMuted: isAudioTrackMuted ?? this.isAudioTrackMuted,
      isBgMusicTrackMuted: isBgMusicTrackMuted ?? this.isBgMusicTrackMuted,
      videoMasterVolume: videoMasterVolume ?? this.videoMasterVolume,
      audioMasterVolume: audioMasterVolume ?? this.audioMasterVolume,
      bgMusicMasterVolume: bgMusicMasterVolume ?? this.bgMusicMasterVolume,
      transitionsEnabled: transitionsEnabled ?? this.transitionsEnabled,
      transitionDuration: transitionDuration ?? this.transitionDuration,
      transitionType: transitionType ?? this.transitionType,
    );
  }
}

/// Video clip on the timeline
class VideoClip {
  final String id;
  String filePath;
  String? thumbnailPath;
  double timelineStart; // Position on timeline in seconds
  double originalDuration; // Original video duration
  double trimStart; // Trim from start (seconds)
  double trimEnd; // Trim from end (seconds)
  double speed; // Playback speed (1.0 = normal)
  double volume; // Audio volume (0.0 - 2.0)
  ColorSettings colorSettings;
  bool isMuted;

  VideoClip({
    required this.id,
    required this.filePath,
    this.thumbnailPath,
    this.timelineStart = 0,
    this.originalDuration = 0,
    this.trimStart = 0,
    this.trimEnd = 0,
    this.speed = 1.0,
    this.volume = 1.0,
    ColorSettings? colorSettings,
    this.isMuted = false,
  }) : colorSettings = colorSettings ?? ColorSettings();

  /// Effective duration after trim and speed adjustments
  double get effectiveDuration =>
      ((originalDuration - trimStart - trimEnd) / speed).clamp(0.0, double.infinity);

  /// Timeline end position
  double get timelineEnd => timelineStart + effectiveDuration;

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'thumbnailPath': thumbnailPath,
        'timelineStart': timelineStart,
        'originalDuration': originalDuration,
        'trimStart': trimStart,
        'trimEnd': trimEnd,
        'speed': speed,
        'volume': volume,
        'colorSettings': colorSettings.toJson(),
        'isMuted': isMuted,
      };

  factory VideoClip.fromJson(Map<String, dynamic> json) => VideoClip(
        id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        filePath: json['filePath'] ?? '',
        thumbnailPath: json['thumbnailPath'],
        timelineStart: (json['timelineStart'] ?? 0).toDouble(),
        originalDuration: (json['originalDuration'] ?? 0).toDouble(),
        trimStart: (json['trimStart'] ?? 0).toDouble(),
        trimEnd: (json['trimEnd'] ?? 0).toDouble(),
        speed: (json['speed'] ?? 1.0).toDouble(),
        volume: (json['volume'] ?? 1.0).toDouble(),
        colorSettings: json['colorSettings'] != null
            ? ColorSettings.fromJson(json['colorSettings'])
            : ColorSettings(),
        isMuted: json['isMuted'] ?? false,
      );

  VideoClip copyWith({
    String? id,
    String? filePath,
    String? thumbnailPath,
    double? timelineStart,
    double? originalDuration,
    double? trimStart,
    double? trimEnd,
    double? speed,
    double? volume,
    ColorSettings? colorSettings,
    bool? isMuted,
  }) {
    return VideoClip(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      timelineStart: timelineStart ?? this.timelineStart,
      originalDuration: originalDuration ?? this.originalDuration,
      trimStart: trimStart ?? this.trimStart,
      trimEnd: trimEnd ?? this.trimEnd,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      colorSettings: colorSettings ?? this.colorSettings,
      isMuted: isMuted ?? this.isMuted,
    );
  }
}

/// Audio clip (manual audio or BG music)
class AudioClip {
  final String id;
  String filePath;
  String? name;
  double timelineStart;
  double duration;
  double trimStart;
  double trimEnd;
  double volume;
  double speed;
  double pitch; // 0.5 - 2.0, 1.0 = normal
  bool isMuted;
  bool isGenerated; // True if AI-generated BG music
  String? generationPrompt; // Prompt used to generate (for BG music)
  double? expectedDuration; // Expected duration from JSON (for AI-generated clips)

  AudioClip({
    required this.id,
    required this.filePath,
    this.name,
    this.timelineStart = 0,
    this.duration = 0,
    this.trimStart = 0,
    this.trimEnd = 0,
    this.volume = 1.0,
    this.speed = 1.0,
    this.pitch = 1.0,
    this.isMuted = false,
    this.isGenerated = false,
    this.generationPrompt,
    this.expectedDuration,
  });

  /// Effective duration after trim and speed
  double get effectiveDuration =>
      ((duration - trimStart - trimEnd) / speed).clamp(0.0, double.infinity);

  double get timelineEnd => timelineStart + effectiveDuration;

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'name': name,
        'timelineStart': timelineStart,
        'duration': duration,
        'trimStart': trimStart,
        'trimEnd': trimEnd,
        'volume': volume,
        'speed': speed,
        'pitch': pitch,
        'isMuted': isMuted,
        'isGenerated': isGenerated,
        'generationPrompt': generationPrompt,
        'expectedDuration': expectedDuration,
      };

  factory AudioClip.fromJson(Map<String, dynamic> json) => AudioClip(
        id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        filePath: json['filePath'] ?? '',
        name: json['name'],
        timelineStart: (json['timelineStart'] ?? 0).toDouble(),
        duration: (json['duration'] ?? 0).toDouble(),
        trimStart: (json['trimStart'] ?? 0).toDouble(),
        trimEnd: (json['trimEnd'] ?? 0).toDouble(),
        volume: (json['volume'] ?? 1.0).toDouble(),
        speed: (json['speed'] ?? 1.0).toDouble(),
        pitch: (json['pitch'] ?? 1.0).toDouble(),
        isMuted: json['isMuted'] ?? false,
        isGenerated: json['isGenerated'] ?? false,
        generationPrompt: json['generationPrompt'],
        expectedDuration: json['expectedDuration']?.toDouble(),
      );

  AudioClip copyWith({
    String? id,
    String? filePath,
    String? name,
    double? timelineStart,
    double? duration,
    double? trimStart,
    double? trimEnd,
    double? volume,
    double? speed,
    double? pitch,
    bool? isMuted,
    bool? isGenerated,
    String? generationPrompt,
    double? expectedDuration,
  }) {
    return AudioClip(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      name: name ?? this.name,
      timelineStart: timelineStart ?? this.timelineStart,
      duration: duration ?? this.duration,
      trimStart: trimStart ?? this.trimStart,
      trimEnd: trimEnd ?? this.trimEnd,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
      isMuted: isMuted ?? this.isMuted,
      isGenerated: isGenerated ?? this.isGenerated,
      generationPrompt: generationPrompt ?? this.generationPrompt,
      expectedDuration: expectedDuration ?? this.expectedDuration,
    );
  }
}

/// Overlay item (text, image, or logo)
class OverlayItem {
  final String id;
  String type; // 'text', 'image', 'logo'
  double timelineStart;
  double duration;
  double x; // Position X (0-1 relative)
  double y; // Position Y (0-1 relative)
  double scale; // Scale factor
  double opacity; // 0-1
  Map<String, dynamic> properties; // Type-specific properties

  OverlayItem({
    required this.id,
    required this.type,
    this.timelineStart = 0,
    this.duration = 5,
    this.x = 0.5,
    this.y = 0.5,
    this.scale = 1.0,
    this.opacity = 1.0,
    Map<String, dynamic>? properties,
  }) : properties = properties ?? {};

  double get timelineEnd => timelineStart + duration;

  // Image-specific helpers
  String get imagePath => properties['imagePath'] ?? '';
  set imagePath(String value) => properties['imagePath'] = value;

  // Text-specific helpers
  String get text => properties['text'] ?? '';
  set text(String value) => properties['text'] = value;

  double get fontSize => (properties['fontSize'] is num) ? (properties['fontSize'] as num).toDouble() : 32.0;
  set fontSize(double value) => properties['fontSize'] = value;

  int get textColor => (properties['textColor'] is num) ? (properties['textColor'] as num).toInt() : 0xFFFFFFFF;
  set textColor(int value) => properties['textColor'] = value;
  
  int get backgroundColor => (properties['backgroundColor'] is num) ? (properties['backgroundColor'] as num).toInt() : 0x00000000;
  set backgroundColor(int value) => properties['backgroundColor'] = value;

  String get fontFamily => properties['fontFamily'] ?? 'Arial';
  set fontFamily(String value) => properties['fontFamily'] = value;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'timelineStart': timelineStart,
        'duration': duration,
        'x': x,
        'y': y,
        'scale': scale,
        'opacity': opacity,
        'properties': properties,
      };

  factory OverlayItem.fromJson(Map<String, dynamic> json) => OverlayItem(
        id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        type: json['type'] ?? 'text',
        timelineStart: (json['timelineStart'] ?? 0).toDouble(),
        duration: (json['duration'] ?? 5).toDouble(),
        x: (json['x'] ?? 0.5).toDouble(),
        y: (json['y'] ?? 0.5).toDouble(),
        scale: (json['scale'] ?? 1.0).toDouble(),
        opacity: (json['opacity'] ?? 1.0).toDouble(),
        properties: Map<String, dynamic>.from(json['properties'] ?? {}),
      );

  OverlayItem copyWith({
    String? id,
    String? type,
    double? timelineStart,
    double? duration,
    double? x,
    double? y,
    double? scale,
    double? opacity,
    Map<String, dynamic>? properties,
  }) {
    return OverlayItem(
      id: id ?? this.id,
      type: type ?? this.type,
      timelineStart: timelineStart ?? this.timelineStart,
      duration: duration ?? this.duration,
      x: x ?? this.x,
      y: y ?? this.y,
      scale: scale ?? this.scale,
      opacity: opacity ?? this.opacity,
      properties: properties ?? Map<String, dynamic>.from(this.properties),
    );
  }
}

/// Color adjustment settings
class ColorSettings {
  double brightness; // -1 to 1, 0 = normal
  double contrast; // 0 to 2, 1 = normal
  double saturation; // 0 to 2, 1 = normal
  double hue; // -180 to 180 degrees

  ColorSettings({
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.hue = 0,
  });

  bool get isDefault =>
      brightness == 0 && contrast == 1 && saturation == 1 && hue == 0;

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'hue': hue,
      };

  factory ColorSettings.fromJson(Map<String, dynamic> json) => ColorSettings(
        brightness: (json['brightness'] ?? 0).toDouble(),
        contrast: (json['contrast'] ?? 1).toDouble(),
        saturation: (json['saturation'] ?? 1).toDouble(),
        hue: (json['hue'] ?? 0).toDouble(),
      );

  ColorSettings copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  }) {
    return ColorSettings(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      hue: hue ?? this.hue,
    );
  }
}

/// Logo overlay settings
class LogoSettings {
  String imagePath;
  double transparency; // 0-1 (0 = invisible, 1 = fully opaque)
  double scale; // Scale factor
  String position; // 'topLeft', 'topRight', 'bottomLeft', 'bottomRight', 'center', 'custom'
  double? customX; // For custom position (0-1)
  double? customY; // For custom position (0-1)
  double startTime; // When logo appears (seconds)
  double? endTime; // When logo disappears (null = entire video)

  LogoSettings({
    required this.imagePath,
    this.transparency = 1.0,
    this.scale = 0.15,
    this.position = 'bottomRight',
    this.customX,
    this.customY,
    this.startTime = 0,
    this.endTime,
  });

  Map<String, dynamic> toJson() => {
        'imagePath': imagePath,
        'transparency': transparency,
        'scale': scale,
        'position': position,
        'customX': customX,
        'customY': customY,
        'startTime': startTime,
        'endTime': endTime,
      };

  factory LogoSettings.fromJson(Map<String, dynamic> json) => LogoSettings(
        imagePath: json['imagePath'] ?? '',
        transparency: (json['transparency'] ?? 1.0).toDouble(),
        scale: (json['scale'] ?? 0.15).toDouble(),
        position: json['position'] ?? 'bottomRight',
        customX: json['customX']?.toDouble(),
        customY: json['customY']?.toDouble(),
        startTime: (json['startTime'] ?? 0).toDouble(),
        endTime: json['endTime']?.toDouble(),
      );

  LogoSettings copyWith({
    String? imagePath,
    double? transparency,
    double? scale,
    String? position,
    double? customX,
    double? customY,
    double? startTime,
    double? endTime,
  }) {
    return LogoSettings(
      imagePath: imagePath ?? this.imagePath,
      transparency: transparency ?? this.transparency,
      scale: scale ?? this.scale,
      position: position ?? this.position,
      customX: customX ?? this.customX,
      customY: customY ?? this.customY,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }
}

/// Export settings
class ExportSettings {
  String resolution; // '720p', '1080p', '2k', '4k'
  int videoBitrate; // kbps
  int audioBitrate; // kbps
  String format; // 'mp4', 'mov', 'webm'
  double fps; // Frame rate
  String codec; // 'h264', 'h265', 'vp9'

  ExportSettings({
    this.resolution = '1080p',
    this.videoBitrate = 8000,
    this.audioBitrate = 192,
    this.format = 'mp4',
    this.fps = 30,
    this.codec = 'h264',
  });

  /// Get width/height for resolution
  int get width {
    switch (resolution) {
      case '720p':
        return 1280;
      case '1080p':
        return 1920;
      case '2k':
        return 2560;
      case '4k':
        return 3840;
      default:
        return 1920;
    }
  }

  int get height {
    switch (resolution) {
      case '720p':
        return 720;
      case '1080p':
        return 1080;
      case '2k':
        return 1440;
      case '4k':
        return 2160;
      default:
        return 1080;
    }
  }

  Map<String, dynamic> toJson() => {
        'resolution': resolution,
        'videoBitrate': videoBitrate,
        'audioBitrate': audioBitrate,
        'format': format,
        'fps': fps,
        'codec': codec,
      };

  factory ExportSettings.fromJson(Map<String, dynamic> json) => ExportSettings(
        resolution: json['resolution'] ?? '1080p',
        videoBitrate: json['videoBitrate'] ?? 8000,
        audioBitrate: json['audioBitrate'] ?? 192,
        format: json['format'] ?? 'mp4',
        fps: (json['fps'] ?? 30).toDouble(),
        codec: json['codec'] ?? 'h264',
      );

  ExportSettings copyWith({
    String? resolution,
    int? videoBitrate,
    int? audioBitrate,
    String? format,
    double? fps,
    String? codec,
  }) {
    return ExportSettings(
      resolution: resolution ?? this.resolution,
      videoBitrate: videoBitrate ?? this.videoBitrate,
      audioBitrate: audioBitrate ?? this.audioBitrate,
      format: format ?? this.format,
      fps: fps ?? this.fps,
      codec: codec ?? this.codec,
    );
  }
}
