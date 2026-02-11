import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class GemPixApiService {
  static const String _generateUrl = 'https://aisandbox-pa.googleapis.com/v1/projects/a1fd6363-64ba-41d6-a15b-ecb51603f58f/flowMedia:batchGenerateImages';
  static const String _uploadUrl = 'https://aisandbox-pa.googleapis.com/v1:uploadUserImage';
  
  /// Upload an image and get mediaGenerationId
  Future<String> uploadImage({
    required Uint8List imageBytes,
    required String authToken,
    String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE',
  }) async {
    try {
      // Encode image to base64
      final base64Image = base64Encode(imageBytes);
      
      // Generate session ID
      final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
      
      final requestBody = {
        "imageInput": {
          "rawImageBytes": base64Image,
          "mimeType": "image/jpeg",
          "isUserUploaded": true,
          "aspectRatio": aspectRatio
        },
        "clientContext": {
          "sessionId": sessionId,
          "tool": "ASSET_MANAGER"
        }
      };

      print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('📤 UPLOADING IMAGE TO GEM PIX 2');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('  → URL: $_uploadUrl');
      print('  → Image Size: ${imageBytes.length} bytes');
      print('  → Aspect Ratio: $aspectRatio');

      final response = await http.post(
        Uri.parse(_uploadUrl),
        headers: {
          'host': 'aisandbox-pa.googleapis.com',
          'sec-ch-ua-platform': '"Windows"',
          'authorization': 'Bearer $authToken',
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
        },
        body: jsonEncode(requestBody),
      );

      print('  ← Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        final mediaGenerationId = jsonResponse['mediaGenerationId']['mediaGenerationId'];
        print('  ✅ Upload Success!');
        print('  ← Media ID: $mediaGenerationId');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        return mediaGenerationId;
      } else {
        print('  ❌ Upload Failed!');
        print('  ← Response: ${response.body}');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        throw Exception('Failed to upload image: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('\n❌ ERROR IN IMAGE UPLOAD:');
      print('Error: $e\n');
      rethrow;
    }
  }
  
  /// Generate images with optional image inputs
  Future<Map<String, dynamic>> generateImages({
    required String prompt,
    required String authToken,
    String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE',
    List<String>? imageInputIds,
    int numImages = 2,
  }) async {
    try {
      // Generate random seeds for each image
      final seed1 = DateTime.now().millisecondsSinceEpoch % 1000000;
      final seed2 = (DateTime.now().millisecondsSinceEpoch + 1) % 1000000;
      
      // Generate session ID
      final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
      
      // Build image inputs array or null if empty
      final imageInputs = imageInputIds != null && imageInputIds.isNotEmpty
          ? imageInputIds.map((id) => {
                "name": id,
                "imageInputType": "IMAGE_INPUT_TYPE_REFERENCE"
              }).toList()
          : null;
      
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
            if (imageInputs != null) "imageInputs": imageInputs
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
            if (imageInputs != null) "imageInputs": imageInputs
          }
        ]
      };

      print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('🔥 SENDING GEM PIX 2 REQUEST');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('  → URL: $_generateUrl');
      print('  → Prompt: $prompt');
      print('  → Aspect Ratio: $aspectRatio');
      print('  → Seeds: $seed1, $seed2');
      print('  → Image Inputs: ${imageInputs?.length ?? 0}');
      print('\n📦 Request Body:');
      print(const JsonEncoder.withIndent('  ').convert(requestBody));
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

      final response = await http.post(
        Uri.parse(_generateUrl),
        headers: {
          'host': 'aisandbox-pa.googleapis.com',
          'sec-ch-ua-platform': '"Windows"',
          'authorization': 'Bearer $authToken',
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
        },
        body: jsonEncode(requestBody),
      );

      print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('📥 GEM PIX 2 RESPONSE');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('  ← Status: ${response.statusCode}');
      print('  ← Body Length: ${response.body.length} chars');

      if (response.statusCode == 200) {
        print('  ✅ Success!');
        final jsonResponse = jsonDecode(response.body);
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        return jsonResponse;
      } else {
        print('  ❌ Failed!');
        print('  ← Full Response: ${response.body}');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        throw Exception('Failed to generate images: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('\n❌ ERROR IN GEM PIX 2 GENERATION:');
      print('Error: $e\n');
      rethrow;
    }
  }
}
