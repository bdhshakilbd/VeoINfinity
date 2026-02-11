import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Google AI Image Generation API Service
/// Supports Imagen 3.5 (Flow Image) and GemPix (Flow Image Precise)
class GoogleImageApiService {
  String? _authToken;
  String? _cookie;
  DateTime? _sessionExpiry;
  
  /// Session response model
  SessionResponse? _session;
  
  /// Check if the service is authenticated
  bool get isAuthenticated => _authToken != null;
  
  /// Check if session is still valid (not expired)
  bool get isSessionValid {
    if (_authToken == null || _sessionExpiry == null) return false;
    // Consider session valid if it has more than 5 minutes left
    return _sessionExpiry!.isAfter(DateTime.now().add(const Duration(minutes: 5)));
  }
  
  /// Get stored cookie
  String? get cookie => _cookie;
  
  /// Get session expiry time
  DateTime? get sessionExpiry => _sessionExpiry;
  
  /// Save credentials to local file
  Future<void> saveCredentials() async {
    if (_cookie == null || _sessionExpiry == null) return;
    
    try {
      final configDir = Directory.current.path;
      final credFile = File('$configDir/whisk_credentials.json');
      await credFile.writeAsString(jsonEncode({
        'cookie': _cookie,
        'expiry': _sessionExpiry!.toIso8601String(),
        'authToken': _authToken,
      }));
    } catch (e) {
      print('Failed to save credentials: $e');
    }
  }
  
  /// Load credentials from local file
  Future<bool> loadCredentials() async {
    try {
      final configDir = Directory.current.path;
      final credFile = File('$configDir/whisk_credentials.json');
      
      if (!await credFile.exists()) return false;
      
      final content = await credFile.readAsString();
      final json = jsonDecode(content);
      
      final expiryStr = json['expiry'] as String?;
      if (expiryStr == null) return false;
      
      final expiry = DateTime.parse(expiryStr);
      
      // Check if still valid (more than 5 minutes left)
      if (expiry.isBefore(DateTime.now().add(const Duration(minutes: 5)))) {
        print('Stored credentials expired');
        return false;
      }
      
      _cookie = json['cookie'];
      _authToken = json['authToken'];
      _sessionExpiry = expiry;
      
      print('Loaded stored credentials (expires: ${expiry.toLocal()})');
      return true;
    } catch (e) {
      print('Failed to load credentials: $e');
      return false;
    }
  }
  
  /// Check session and extract access token
  Future<SessionResponse> checkSession(String cookie) async {
    final response = await http.get(
      Uri.parse('https://labs.google/fx/api/auth/session'),
      headers: {
        'host': 'labs.google',
        'sec-ch-ua-platform': '"Windows"',
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
        'sec-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
        'content-type': 'application/json',
        'sec-ch-ua-mobile': '?0',
        'accept': '*/*',
        'sec-fetch-site': 'same-origin',
        'sec-fetch-mode': 'cors',
        'sec-fetch-dest': 'empty',
        'referer': 'https://labs.google/',
        'accept-encoding': 'gzip, deflate, br, zstd',
        'accept-language': 'en-US,en;q=0.9',
        'priority': 'u=1, i',
        'cookie': cookie,
      },
    );

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      _session = SessionResponse.fromJson(jsonResponse);
      _authToken = _session!.accessToken;
      _cookie = cookie;
      _sessionExpiry = _session!.expires;
      
      // Save credentials for later use
      await saveCredentials();
      
      return _session!;
    } else {
      throw Exception('Session check failed: ${response.statusCode}');
    }
  }
  
  /// Generate image using Imagen 3.5 or GemPix (text-to-image)
  /// Optionally pass reference images as base64 encoded strings
  Future<ImageGenerationResponse> generateImage({
    required String prompt,
    String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE',
    String imageModel = 'IMAGEN_3_5', // IMAGEN_3_5 or GEM_PIX
    List<String>? referenceImages, // Base64 encoded images
  }) async {
    if (_authToken == null) {
      throw Exception('Not authenticated. Call checkSession first.');
    }
    
    final seed = DateTime.now().millisecondsSinceEpoch % 1000000;
    final workflowId = _generateUuid();
    
    final requestBody = <String, dynamic>{
      "clientContext": {
        "workflowId": workflowId,
        "tool": "BACKBONE",
        "sessionId": ";${DateTime.now().millisecondsSinceEpoch}"
      },
      "imageModelSettings": {
        "imageModel": imageModel,
        "aspectRatio": aspectRatio
      },
      "seed": seed,
      "prompt": prompt,
      "mediaCategory": "MEDIA_CATEGORY_BOARD"
    };
    
    // Add reference images if provided
    if (referenceImages != null && referenceImages.isNotEmpty) {
      final imageInputs = referenceImages.map((base64Img) {
        String cleanBase64 = base64Img;
        if (base64Img.contains(',')) {
          cleanBase64 = base64Img.split(',').last;
        }
        return {
          "encodedImage": cleanBase64,
          "imageType": "IMAGE_TYPE_SUBJECT"
        };
      }).toList();
      requestBody["imageInputs"] = imageInputs;
    }

    final response = await http.post(
      Uri.parse('https://aisandbox-pa.googleapis.com/v1/whisk:generateImage'),
      headers: _getApiHeaders(),
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      return ImageGenerationResponse.fromJson(jsonResponse);
    } else {
      throw Exception('Failed to generate image: ${response.statusCode}\n${response.body}');
    }
  }
  
  /// Generate images using GemPix 2 (Flow Image) - text-to-image
  Future<FlowImageResponse> generateFlowImages({
    required String prompt,
    String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE',
    int numImages = 2,
  }) async {
    if (_authToken == null) {
      throw Exception('Not authenticated. Call checkSession first.');
    }
    
    final seed1 = DateTime.now().millisecondsSinceEpoch % 1000000;
    final seed2 = (DateTime.now().millisecondsSinceEpoch + 1) % 1000000;
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    
    final requestBody = {
      "requests": [
        {
          "clientContext": {
            "sessionId": sessionId,
            "projectId": "a1fd6363-64ba-41d6-a15b-ecb51603f58f",
            "tool": "PINHOLE"
          },
          "seed": seed1,
          "imageModelName": "GEM_PIX_2",
          "imageAspectRatio": aspectRatio,
          "prompt": prompt,
        },
        {
          "clientContext": {
            "sessionId": sessionId,
            "projectId": "a1fd6363-64ba-41d6-a15b-ecb51603f58f",
            "tool": "PINHOLE"
          },
          "seed": seed2,
          "imageModelName": "GEM_PIX_2",
          "imageAspectRatio": aspectRatio,
          "prompt": prompt,
        }
      ]
    };

    final response = await http.post(
      Uri.parse('https://aisandbox-pa.googleapis.com/v1/projects/a1fd6363-64ba-41d6-a15b-ecb51603f58f/flowMedia:batchGenerateImages'),
      headers: _getApiHeaders(),
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      return FlowImageResponse.fromJson(jsonResponse);
    } else {
      throw Exception('Failed to generate flow images: ${response.statusCode}\n${response.body}');
    }
  }
  
  /// Get API headers
  Map<String, String> _getApiHeaders() {
    return {
      'host': 'aisandbox-pa.googleapis.com',
      'sec-ch-ua-platform': '"Windows"',
      'authorization': 'Bearer $_authToken',
      'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
      'sec-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
      'content-type': 'text/plain;charset=UTF-8',
      'sec-ch-ua-mobile': '?0',
      'accept': '*/*',
      'origin': 'https://labs.google',
      'x-browser-channel': 'stable',
      'x-browser-year': '2025',
      'x-browser-validation': 'Aj9fzfu+SaGLBY9Oqr3S7RokOtM=',
      'x-browser-copyright': 'Copyright 2025 Google LLC. All Rights reserved.',
      'x-client-data': 'CJW2yQEIprbJAQipncoBCK6UywEIk6HLAQiFoM0BCMGbzwE=',
      'sec-fetch-site': 'cross-site',
      'sec-fetch-mode': 'cors',
      'sec-fetch-dest': 'empty',
      'referer': 'https://labs.google/',
      'accept-encoding': 'gzip, deflate, br, zstd',
      'accept-language': 'en-US,en;q=0.9',
      'priority': 'u=1, i',
    };
  }
  
  /// Get headers for labs.google API (requires cookie)
  Map<String, String> _getLabsHeaders() {
    return {
      'host': 'labs.google',
      'sec-ch-ua-platform': '"Windows"',
      'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
      'sec-ch-ua': '"Chromium";"v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
      'content-type': 'application/json',
      'sec-ch-ua-mobile': '?0',
      'accept': '*/*',
      'origin': 'https://labs.google',
      'sec-fetch-site': 'same-origin',
      'sec-fetch-mode': 'cors',
      'sec-fetch-dest': 'empty',
      'referer': 'https://labs.google/',
      'accept-encoding': 'gzip, deflate, br, zstd',
      'accept-language': 'en-US,en;q=0.9',
      'priority': 'u=1, i',
      'cookie': _cookie ?? '',
    };
  }
  
  /// Caption an image using AI
  Future<String> captionImage({
    required String base64Image,
    required String workflowId,
  }) async {
    if (_cookie == null) throw Exception('Not authenticated');
    
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    
    final requestBody = {
      "json": {
        "clientContext": {
          "sessionId": sessionId,
          "workflowId": workflowId,
        },
        "captionInput": {
          "candidatesCount": 1,
          "mediaInput": {
            "mediaCategory": "MEDIA_CATEGORY_SUBJECT",
            "rawBytes": base64Image,
          }
        }
      }
    };
    
    final response = await http.post(
      Uri.parse('https://labs.google/fx/api/trpc/backbone.captionImage'),
      headers: _getLabsHeaders(),
      body: jsonEncode(requestBody),
    );
    
    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      return jsonResponse['result']['data']['json']['result']['candidates'][0]['output'];
    } else {
      throw Exception('Failed to caption image: ${response.statusCode}');
    }
  }
  
  /// Upload a reference image and get mediaGenerationId
  Future<String> uploadImage({
    required String base64Image,
    required String caption,
    required String workflowId,
    String mediaCategory = 'MEDIA_CATEGORY_SUBJECT',
  }) async {
    if (_cookie == null) throw Exception('Not authenticated');
    
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    
    // Remove data URL prefix if present
    String cleanBase64 = base64Image;
    if (base64Image.contains(',')) {
      cleanBase64 = base64Image.split(',').last;
    }
    
    final requestBody = {
      "json": {
        "clientContext": {
          "workflowId": workflowId,
          "sessionId": sessionId,
        },
        "uploadMediaInput": {
          "mediaCategory": mediaCategory,
          "rawBytes": cleanBase64,
          "caption": caption,
        }
      }
    };
    
    final response = await http.post(
      Uri.parse('https://labs.google/fx/api/trpc/backbone.uploadImage'),
      headers: _getLabsHeaders(),
      body: jsonEncode(requestBody),
    );
    
    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      return jsonResponse['result']['data']['json']['result']['uploadMediaGenerationId'];
    } else {
      throw Exception('Failed to upload image: ${response.statusCode}');
    }
  }
  
  /// Upload image with auto-captioning
  Future<UploadedMedia> uploadImageWithCaption({
    required String base64Image,
    required String workflowId,
    String mediaCategory = 'MEDIA_CATEGORY_SUBJECT',
  }) async {
    // First caption the image
    final caption = await captionImage(
      base64Image: base64Image,
      workflowId: workflowId,
    );
    
    // Then upload with caption
    final mediaGenerationId = await uploadImage(
      base64Image: base64Image,
      caption: caption,
      workflowId: workflowId,
      mediaCategory: mediaCategory,
    );
    
    return UploadedMedia(
      mediaGenerationId: mediaGenerationId,
      caption: caption,
    );
  }
  
  /// Generate image with reference images using runImageRecipe
  Future<ImageGenerationResponse> runImageRecipe({
    required String userInstruction,
    required List<RecipeMediaInput> recipeMediaInputs,
    required String workflowId,
    String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE',
    String imageModel = 'IMAGEN_3_5',
  }) async {
    if (_authToken == null) throw Exception('Not authenticated');
    
    final seed = DateTime.now().millisecondsSinceEpoch % 1000000;
    
    final requestBody = {
      "clientContext": {
        "workflowId": workflowId,
        "tool": "BACKBONE",
        "sessionId": ";${DateTime.now().millisecondsSinceEpoch}"
      },
      "seed": seed,
      "imageModelSettings": {
        "imageModel": imageModel,
        "aspectRatio": aspectRatio
      },
      "userInstruction": userInstruction,
      "recipeMediaInputs": recipeMediaInputs.map((input) => input.toJson()).toList(),
    };
    
    final response = await http.post(
      Uri.parse('https://aisandbox-pa.googleapis.com/v1/whisk:runImageRecipe'),
      headers: _getApiHeaders(),
      body: jsonEncode(requestBody),
    );
    
    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      return ImageGenerationResponse.fromJson(jsonResponse);
    } else {
      throw Exception('Failed to run image recipe: ${response.statusCode}\n${response.body}');
    }
  }
  
  /// Generate UUID v4
  String _generateUuid() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
      RegExp(r'[xy]'),
      (match) {
        final r = (random + (random * 16).toInt()) % 16;
        final v = match.group(0) == 'x' ? r : (r & 0x3 | 0x8);
        return v.toRadixString(16);
      },
    );
  }
  
  /// Get a new workflow ID
  String getNewWorkflowId() => _generateUuid();
  
  /// Convert aspect ratio string to API format
  static String convertAspectRatio(String ratio) {
    switch (ratio) {
      case '16:9':
        return 'IMAGE_ASPECT_RATIO_LANDSCAPE';
      case '9:16':
        return 'IMAGE_ASPECT_RATIO_PORTRAIT';
      case '1:1':
        return 'IMAGE_ASPECT_RATIO_SQUARE';
      case '4:3':
        return 'IMAGE_ASPECT_RATIO_LANDSCAPE';
      case '3:4':
        return 'IMAGE_ASPECT_RATIO_PORTRAIT';
      default:
        return 'IMAGE_ASPECT_RATIO_LANDSCAPE';
    }
  }
}

/// Helper class for uploaded media
class UploadedMedia {
  final String mediaGenerationId;
  final String caption;
  
  UploadedMedia({required this.mediaGenerationId, required this.caption});
}

/// Recipe media input for runImageRecipe
class RecipeMediaInput {
  final String caption;
  final String mediaCategory;
  final String mediaGenerationId;

  RecipeMediaInput({
    required this.caption,
    required this.mediaCategory,
    required this.mediaGenerationId,
  });

  Map<String, dynamic> toJson() {
    return {
      "caption": caption,
      "mediaInput": {
        "mediaCategory": mediaCategory,
        "mediaGenerationId": mediaGenerationId,
      }
    };
  }
}


/// Session response model
class SessionResponse {
  final UserInfo? user;
  final DateTime? expires;
  final String? accessToken;

  SessionResponse({this.user, this.expires, this.accessToken});

  factory SessionResponse.fromJson(Map<String, dynamic> json) {
    return SessionResponse(
      user: json['user'] != null ? UserInfo.fromJson(json['user']) : null,
      expires: json['expires'] != null ? DateTime.parse(json['expires']) : null,
      accessToken: json['access_token'],
    );
  }

  bool get isActive {
    if (expires == null) return false;
    return DateTime.now().isBefore(expires!);
  }

  Duration? get timeRemaining {
    if (expires == null) return null;
    final remaining = expires!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String get timeRemainingFormatted {
    final remaining = timeRemaining;
    if (remaining == null) return 'Unknown';
    if (remaining == Duration.zero) return 'Expired';
    
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    return '${hours}h ${minutes}m';
  }
}

class UserInfo {
  final String name;
  final String email;
  final String image;

  UserInfo({required this.name, required this.email, required this.image});

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      image: json['image'] ?? '',
    );
  }
}

/// Image generation response for Imagen 3.5 / GemPix
class ImageGenerationResponse {
  final List<ImagePanel> imagePanels;

  ImageGenerationResponse({required this.imagePanels});

  factory ImageGenerationResponse.fromJson(Map<String, dynamic> json) {
    final panels = (json['imagePanels'] as List?)
        ?.map((panel) => ImagePanel.fromJson(panel))
        .toList() ?? [];
    return ImageGenerationResponse(imagePanels: panels);
  }
}

class ImagePanel {
  final List<GeneratedImage> generatedImages;

  ImagePanel({required this.generatedImages});

  factory ImagePanel.fromJson(Map<String, dynamic> json) {
    final images = (json['generatedImages'] as List?)
        ?.map((img) => GeneratedImage.fromJson(img))
        .toList() ?? [];
    return ImagePanel(generatedImages: images);
  }
}

class GeneratedImage {
  final String encodedImage;
  final String? mediaGenerationId;

  GeneratedImage({required this.encodedImage, this.mediaGenerationId});

  factory GeneratedImage.fromJson(Map<String, dynamic> json) {
    // mediaGenerationId can be either a String directly or an object with mediaGenerationId inside
    String? mediaId;
    final rawMediaId = json['mediaGenerationId'];
    if (rawMediaId is String) {
      mediaId = rawMediaId;
    } else if (rawMediaId is Map) {
      mediaId = rawMediaId['mediaGenerationId']?.toString();
    }
    
    return GeneratedImage(
      encodedImage: json['encodedImage'] ?? '',
      mediaGenerationId: mediaId,
    );
  }
  
  /// Decode base64 image to bytes
  Uint8List get imageBytes => base64Decode(encodedImage);
}

/// Flow image response for GemPix 2
class FlowImageResponse {
  final List<FlowMedia> media;

  FlowImageResponse({required this.media});

  factory FlowImageResponse.fromJson(Map<String, dynamic> json) {
    final mediaList = (json['media'] as List?)
        ?.map((m) => FlowMedia.fromJson(m))
        .toList() ?? [];
    return FlowImageResponse(media: mediaList);
  }
}

class FlowMedia {
  final FlowImage image;

  FlowMedia({required this.image});

  factory FlowMedia.fromJson(Map<String, dynamic> json) {
    return FlowMedia(
      image: FlowImage.fromJson(json['image']),
    );
  }
}

class FlowImage {
  final FlowGeneratedImage generatedImage;

  FlowImage({required this.generatedImage});

  factory FlowImage.fromJson(Map<String, dynamic> json) {
    return FlowImage(
      generatedImage: FlowGeneratedImage.fromJson(json['generatedImage']),
    );
  }
}

class FlowGeneratedImage {
  final String encodedImage;
  final String? mediaGenerationId;

  FlowGeneratedImage({required this.encodedImage, this.mediaGenerationId});

  factory FlowGeneratedImage.fromJson(Map<String, dynamic> json) {
    // mediaGenerationId can be either a String directly or an object with mediaGenerationId inside
    String? mediaId;
    final rawMediaId = json['mediaGenerationId'];
    if (rawMediaId is String) {
      mediaId = rawMediaId;
    } else if (rawMediaId is Map) {
      mediaId = rawMediaId['mediaGenerationId']?.toString();
    }
    
    return FlowGeneratedImage(
      encodedImage: json['encodedImage'] ?? '',
      mediaGenerationId: mediaId,
    );
  }
  
  /// Decode base64 image to bytes
  Uint8List get imageBytes => base64Decode(encodedImage);
}
