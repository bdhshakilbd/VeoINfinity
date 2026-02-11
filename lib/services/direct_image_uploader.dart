import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Fast direct API image uploader - bypasses CDP for faster uploads
class DirectImageUploader {
  static const String _uploadEndpoint = 'https://aisandbox-pa.googleapis.com/v1:uploadUserImage';
  
  /// Upload an image directly via HTTP POST (faster than CDP method)
  /// Returns mediaId on success, or error map on failure
  static Future<dynamic> uploadImage({
    required String imagePath,
    required String accessToken,
    String? aspectRatioOverride,
  }) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return {'error': true, 'message': 'File not found: $imagePath'};
      }
      
      // Read image bytes
      final imageBytes = await file.readAsBytes();
      final imageB64 = base64Encode(imageBytes);
      
      // Determine MIME type from extension
      final mimeType = _getMimeType(imagePath);
      
      // Auto-detect aspect ratio from image dimensions
      final aspectRatio = aspectRatioOverride ?? await _detectAspectRatio(imageBytes);
      
      // Create session ID
      final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
      
      // Build payload
      final payload = {
        'imageInput': {
          'rawImageBytes': imageB64,
          'mimeType': mimeType,
          'isUserUploaded': true,
          'aspectRatio': aspectRatio,
        },
        'clientContext': {
          'sessionId': sessionId,
          'tool': 'ASSET_MANAGER',
        },
      };
      
      final fileName = imagePath.split(Platform.pathSeparator).last;
      print('[DIRECT-UPLOAD] Uploading: $fileName (${imageBytes.length} bytes)');
      print('[DIRECT-UPLOAD] Aspect Ratio: $aspectRatio');
      
      // Make HTTP POST request with full browser headers
      final response = await http.post(
        Uri.parse(_uploadEndpoint),
        headers: {
          'Content-Type': 'text/plain;charset=UTF-8',
          'Authorization': 'Bearer $accessToken',
          'Accept': '*/*',
          'Accept-Encoding': 'gzip, deflate, br, zstd',
          'Accept-Language': 'en-US,en;q=0.9',
          'Origin': 'https://labs.google',
          'Referer': 'https://labs.google/',
          'Sec-Ch-Ua': '"Google Chrome";v="143", "Chromium";v="143", "Not A(Brand";v="24"',
          'Sec-Ch-Ua-Mobile': '?0',
          'Sec-Ch-Ua-Platform': '"Windows"',
          'Sec-Fetch-Dest': 'empty',
          'Sec-Fetch-Mode': 'cors',
          'Sec-Fetch-Site': 'cross-site',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36',
          'X-Browser-Channel': 'stable',
          'X-Browser-Year': '2025',
          'X-Browser-Copyright': 'Copyright 2025 Google LLC. All Rights reserved.',
          'X-Client-Data': 'CLrxygE=',
        },
        body: jsonEncode(payload),
      );
      
      print('[DIRECT-UPLOAD] Status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // Extract mediaId from response
        String? mediaId;
        if (data.containsKey('mediaGenerationId')) {
          final mediaGen = data['mediaGenerationId'];
          if (mediaGen is Map) {
            mediaId = mediaGen['mediaGenerationId'] as String?;
          } else {
            mediaId = mediaGen as String?;
          }
        } else if (data.containsKey('mediaId')) {
          mediaId = data['mediaId'] as String?;
        }
        
        if (mediaId != null) {
          print('[DIRECT-UPLOAD] ✓ Success! MediaId: $mediaId');
          return mediaId;
        } else {
          print('[DIRECT-UPLOAD] ✗ No mediaId in response');
          print('[DIRECT-UPLOAD] Response: ${response.body}');
          return {'error': true, 'message': 'No mediaId in response', 'data': data};
        }
      } else {
        // Parse error response
        Map<String, dynamic>? errorData;
        try {
          errorData = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {}
        
        String errorMessage = 'Upload failed with status ${response.statusCode}';
        
        if (errorData != null && errorData.containsKey('error')) {
          final errorInfo = errorData['error'] as Map<String, dynamic>? ?? {};
          errorMessage = errorInfo['message'] as String? ?? errorMessage;
          
          // Check for content policy violations
          final details = errorInfo['details'] as List? ?? [];
          for (var detail in details) {
            final reason = (detail as Map)['reason'] as String? ?? '';
            if (reason.contains('MINOR') || reason.contains('PUBLIC')) {
              errorMessage = "⚠️ IMAGE REJECTED: Google's content policy detected a minor, "
                  "public figure, or copyrighted content. Use a different image.";
              break;
            }
          }
        }
        
        print('[DIRECT-UPLOAD] ✗ Failed: $errorMessage');
        return {'error': true, 'message': errorMessage, 'status': response.statusCode};
      }
    } catch (e) {
      print('[DIRECT-UPLOAD] ✗ Exception: $e');
      return {'error': true, 'message': e.toString()};
    }
  }
  
  /// Detect aspect ratio from image dimensions
  /// Returns 'IMAGE_ASPECT_RATIO_LANDSCAPE' or 'IMAGE_ASPECT_RATIO_PORTRAIT'
  static Future<String> _detectAspectRatio(Uint8List imageBytes) async {
    try {
      // Decode image to get dimensions
      final image = img.decodeImage(imageBytes);
      if (image == null) {
        print('[ASPECT] Could not decode image, defaulting to LANDSCAPE');
        return 'IMAGE_ASPECT_RATIO_LANDSCAPE';
      }
      
      final width = image.width;
      final height = image.height;
      final ratio = width / height;
      
      // 16:9 = 1.78, 9:16 = 0.56
      // If ratio > 1, it's wider than tall (landscape)
      // If ratio < 1, it's taller than wide (portrait)
      // Use 1.0 as the threshold
      
      // More precise: 
      // If closer to 16/9 (1.78) -> LANDSCAPE
      // If closer to 9/16 (0.56) -> PORTRAIT
      
      if (ratio >= 1.0) {
        print('[ASPECT] Detected LANDSCAPE (${width}x${height}, ratio=$ratio)');
        return 'IMAGE_ASPECT_RATIO_LANDSCAPE';
      } else {
        print('[ASPECT] Detected PORTRAIT (${width}x${height}, ratio=$ratio)');
        return 'IMAGE_ASPECT_RATIO_PORTRAIT';
      }
    } catch (e) {
      print('[ASPECT] Error detecting aspect ratio: $e, defaulting to LANDSCAPE');
      return 'IMAGE_ASPECT_RATIO_LANDSCAPE';
    }
  }
  
  /// Get MIME type from file extension
  static String _getMimeType(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg'; // Default to JPEG
  }
  
  /// Batch upload multiple images with parallel execution
  /// Returns a map of filePath -> mediaId or error
  static Future<Map<String, dynamic>> uploadImages({
    required List<String> imagePaths,
    required String accessToken,
    int maxConcurrent = 5,
  }) async {
    final results = <String, dynamic>{};
    
    // Process in batches
    for (var i = 0; i < imagePaths.length; i += maxConcurrent) {
      final batch = imagePaths.sublist(
        i,
        (i + maxConcurrent > imagePaths.length) ? imagePaths.length : i + maxConcurrent,
      );
      
      // Upload batch concurrently
      final futures = batch.map((path) async {
        final result = await uploadImage(imagePath: path, accessToken: accessToken);
        return MapEntry(path, result);
      });
      
      final batchResults = await Future.wait(futures);
      for (final entry in batchResults) {
        results[entry.key] = entry.value;
      }
    }
    
    return results;
  }
}
