import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class ImageUploadService {
  static const String baseUrl = 'https://labs.google';
  
  Future<Map<String, dynamic>> uploadImage({
    required File imageFile,
    required String cookie,
    required String workflowId,
    required String mediaCategory,
  }) async {
    try {
      print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('🚀 STARTING IMAGE UPLOAD WORKFLOW');
      print('Category: $mediaCategory');
      print('Workflow ID: $workflowId');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
      
      // Step 1: Check user acknowledgement
      print('📋 Step 1/4: Checking user acknowledgement...');
      await _fetchUserAcknowledgement(cookie);
      print('✅ Acknowledgement OK\n');
      
      // Step 2: Read and encode image
      print('📸 Step 2/4: Encoding image...');
      final imageBytes = await imageFile.readAsBytes();
      final base64Image = 'data:image/jpeg;base64,${base64Encode(imageBytes)}';
      print('✅ Image encoded (${imageBytes.length} bytes)\n');
      
      // Step 3: Caption the image
      print('✍️ Step 3/4: Generating caption...');
      final caption = await captionImage(
        base64Image: base64Image,
        cookie: cookie,
        workflowId: workflowId,
      );
      print('✅ Caption generated: ${caption.substring(0, 100)}...\n');
      
      // Step 4: Upload the image
      print('📤 Step 4/4: Uploading image to server...');
      final mediaGenerationId = await _uploadImage(
        base64Image: base64Image,
        caption: caption,
        cookie: cookie,
        workflowId: workflowId,
        mediaCategory: mediaCategory,
      );
      print('✅ Upload complete! Media ID: $mediaGenerationId\n');
      
      // Step 5: Submit batch log
      print('📊 Step 5/5: Submitting analytics...');
      await _submitBatchLog(
        cookie: cookie,
        workflowId: workflowId,
      );
      print('✅ Analytics submitted\n');
      
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('✨ UPLOAD WORKFLOW COMPLETED SUCCESSFULLY');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
      
      return {
        'mediaGenerationId': mediaGenerationId,
        'caption': caption,
      };
    } catch (e) {
      print('\n❌ ERROR IN UPLOAD WORKFLOW:');
      print('Error: $e\n');
      throw Exception('Error uploading image: $e');
    }
  }

  /// Upload image bytes with a provided caption (e.g., from generation) to get mediaGenerationId
  Future<String> uploadImageWithCaption({
    required Uint8List imageBytes,
    required String caption,
    required String cookie,
    required String workflowId,
    required String mediaCategory,
  }) async {
    print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('📤 UPLOAD WITH PROVIDED CAPTION');
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('Caption: $caption');
    print('Image size: ${imageBytes.length} bytes');
    
    try {
      // Step 1: Encode image
      final base64Image = base64Encode(imageBytes);
      print('✅ Step 1/2: Image encoded');
      
      // Step 2: Upload with caption to get mediaGenerationId
      print('\n📤 Step 2/2: Uploading image with caption...');
      final mediaGenerationId = await _uploadImage(
        base64Image: base64Image,
        caption: caption,
        cookie: cookie,
        workflowId: workflowId,
        mediaCategory: mediaCategory,
      );
      
      print('✅ Media Generation ID: $mediaGenerationId');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('✨ UPLOAD COMPLETED SUCCESSFULLY');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
      
      return mediaGenerationId;
    } catch (e) {
      print('\n❌ ERROR IN UPLOAD WITH CAPTION:');
      print('Error: $e\n');
      throw Exception('Error uploading image with caption: $e');
    }
  }
  
  Future<void> _fetchUserAcknowledgement(String cookie) async {
    final url = '$baseUrl/fx/api/trpc/general.fetchUserAcknowledgement?input=%7B%22json%22%3A%7B%22acknowledgementVersion%22%3A%22WHISK_IMAGE_UPLOAD_TOS%22%7D%7D';
    
    print('  → Request: GET $url');
    
    final response = await http.get(
      Uri.parse(url),
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
    
    print('  ← Response: ${response.statusCode}');
    print('  ← Body: ${response.body}');
    
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch acknowledgement: ${response.statusCode} - ${response.body}');
    }
  }
  
  Future<String> captionImage({
    required String base64Image,
    required String cookie,
    required String workflowId,
  }) async {
    final url = '$baseUrl/fx/api/trpc/backbone.captionImage';
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    
    // Truncate base64 for logging
    final base64Preview = base64Image.length > 100 
        ? '${base64Image.substring(0, 100)}...[${base64Image.length} chars total]'
        : base64Image;
    
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
    
    print('  → Request: POST $url');
    print('  → Session ID: $sessionId');
    print('  → Image data: $base64Preview');
    
    final response = await http.post(
      Uri.parse(url),
      headers: {
        'host': 'labs.google',
        'sec-ch-ua-platform': '"Windows"',
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
        'sec-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
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
        'cookie': cookie,
      },
      body: jsonEncode(requestBody),
    );
    
    print('  ← Response: ${response.statusCode}');
    print('  ← Body: ${response.body}');
    
    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      final caption = jsonResponse['result']['data']['json']['result']['candidates'][0]['output'];
      return caption;
    } else {
      throw Exception('Failed to caption image: ${response.statusCode} - ${response.body}');
    }
  }
  
  Future<String> _uploadImage({
    required String base64Image,
    required String caption,
    required String cookie,
    required String workflowId,
    required String mediaCategory,
  }) async {
    final url = '$baseUrl/fx/api/trpc/backbone.uploadImage';
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    
    final base64Preview = base64Image.length > 100 
        ? '${base64Image.substring(0, 100)}...[${base64Image.length} chars total]'
        : base64Image;
    
    final requestBody = {
      "json": {
        "clientContext": {
          "workflowId": workflowId,
          "sessionId": sessionId,
        },
        "uploadMediaInput": {
          "mediaCategory": mediaCategory,
          "rawBytes": base64Image,
          "caption": caption,
        }
      }
    };
    
    print('  → Request: POST $url');
    print('  → Media Category: $mediaCategory');
    print('  → Image data: $base64Preview');
    print('  → Caption: ${caption.substring(0, min(caption.length, 100))}...');
    
    final response = await http.post(
      Uri.parse(url),
      headers: {
        'host': 'labs.google',
        'sec-ch-ua-platform': '"Windows"',
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
        'sech-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
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
        'cookie': cookie,
      },
      body: jsonEncode(requestBody),
    );
    
    print('  ← Response: ${response.statusCode}');
   print('  ← Body: ${response.body}');
    
    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      final mediaGenerationId = jsonResponse['result']['data']['json']['result']['uploadMediaGenerationId'];
      return mediaGenerationId;
    } else {
      throw Exception('Failed to upload image: ${response.statusCode} - ${response.body}');
    }
  }
  
  Future<void> _submitBatchLog({
    required String cookie,
    required String workflowId,
  }) async {
    final url = '$baseUrl/fx/api/trpc/general.submitBatchLog';
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    final eventTime = DateTime.now().toUtc().toIso8601String();
    
    final requestBody = {
      "json": {
        "appEvents": [
          {
            "event": "BACKBONE_DND_ASSETS_EXTERNAL",
            "eventProperties": [
              {"key": "TOOL_NAME", "stringValue": "BACKBONE"},
              {"key": "BACKBONE_MODE", "stringValue": "CREATE"},
              {"key": "BACKBONE_IMAGE_ID", "stringValue": "image-${_generateUuid()}"},
              {
                "key": "USER_AGENT",
                "stringValue": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
              },
              {"key": "IS_DESKTOP"}
            ],
            "activeExperiments": [],
            "eventMetadata": {"sessionId": sessionId},
            "eventTime": eventTime
          }
        ]
      }
    };
    
    await http.post(
      Uri.parse(url),
      headers: {
        'host': 'labs.google',
        'sec-ch-ua-platform': '"Windows"',
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
        'sec-ch-ua': '"Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"',
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
        'cookie': cookie,
      },
      body: jsonEncode(requestBody),
    );
  }
  
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
}
