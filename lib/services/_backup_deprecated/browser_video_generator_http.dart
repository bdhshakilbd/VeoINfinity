  /// Generate video using pure HTTP (Dart) - NO BROWSER FETCH!
  /// Uses prefetched reCAPTCHA token for faster generation
  /// This is the Python-style approach
  Future<Map<String, dynamic>?> generateVideoHTTP({
    required String prompt,
    required String accessToken,
    required String recaptchaToken,
    String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    String model = 'veo_3_1_t2v_fast_ultra',
    String? startImageMediaId,
    String? endImageMediaId,
  }) async {
    final sceneId = _generateUuid();
    final seed = (DateTime.now().millisecondsSinceEpoch % 50000);
    final projectId = _generateUuid();

    // Adjust model key for Portrait if needed
    var adjustedModel = model;
    if (aspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' && !model.contains('_portrait')) {
      bool isRelaxed = model.contains('_relaxed');
      var baseModel = model.replaceAll('_relaxed', '');
      
      if (baseModel.contains('fast')) {
        adjustedModel = baseModel.replaceFirst('fast', 'fast_portrait');
      } else if (baseModel.contains('quality')) {
        adjustedModel = baseModel.replaceFirst('quality', 'quality_portrait');
      }
      
      if (isRelaxed) {
        adjustedModel += '_relaxed';
      }
      
      print('[HTTP] Model Adjusted: $model -> $adjustedModel (Portrait Mode)');
    }

    // Determine if this is image-to-video
    final hasStartImage = startImageMediaId != null;
    final hasEndImage = endImageMediaId != null;
    final isI2v = hasStartImage || hasEndImage;

    if (isI2v) {
      if (hasEndImage && !hasStartImage) {
        print('[HTTP] WARNING: End-only image mode is NOT supported!');
      } else {
        if (adjustedModel.contains('t2v')) {
          adjustedModel = adjustedModel.replaceAll('t2v', 'i2v_s');
        } else if (!adjustedModel.contains('i2v')) {
          if (adjustedModel.contains('veo_2_')) {
            adjustedModel = adjustedModel.replaceFirst('veo_2_', 'veo_2_i2v_s_');
          } else if (adjustedModel.contains('veo_3_1_')) {
            adjustedModel = adjustedModel.replaceFirst('veo_3_1_', 'veo_3_1_i2v_s_');
          }
        }
        
        if (hasStartImage && hasEndImage) {
          if (adjustedModel.contains('_fast')) {
            adjustedModel = adjustedModel.replaceFirst('_fast', '_fast_fl');
            adjustedModel = adjustedModel.replaceAll('__', '_');
          } else if (adjustedModel.contains('_quality')) {
            adjustedModel = adjustedModel.replaceFirst('_quality', '_quality_fl');
            adjustedModel = adjustedModel.replaceAll('__', '_');
          }
        }
      }
    }

    // Build request object
    Map<String, dynamic> requestObj;
    
    if (isI2v) {
      requestObj = {
        'aspectRatio': aspectRatio,
        'seed': seed,
        'textInput': {'prompt': prompt},
        'videoModelKey': adjustedModel,
        'metadata': {'sceneId': sceneId},
      };
      
      if (startImageMediaId != null) {
        requestObj['startImage'] = {'mediaId': startImageMediaId};
      }
      if (endImageMediaId != null) {
        requestObj['endImage'] = {'mediaId': endImageMediaId};
      }
    } else {
      requestObj = {
        'aspectRatio': aspectRatio,
        'seed': seed,
        'textInput': {'prompt': prompt},
        'videoModelKey': adjustedModel,
        'metadata': {'sceneId': sceneId},
      };
    }

    // Determine endpoint
    String endpoint;
    if (hasStartImage && hasEndImage) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartAndEndImage';
      print('[HTTP] Using Start+End Image endpoint');
    } else if (hasStartImage) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage';
      print('[HTTP] Using Start Image endpoint');
    } else {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';
      print('[HTTP] Using Text-to-Video endpoint');
    }

    // Build payload (Python structure)
    final payload = {
      'clientContext': {
        'recaptchaContext': {
          'token': recaptchaToken,
          'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB'
        },
        'sessionId': ';${DateTime.now().millisecondsSinceEpoch}',
        'projectId': projectId,
        'tool': 'PINHOLE',
        'userPaygateTier': 'PAYGATE_TIER_TWO'
      },
      'requests': [requestObj]
    };

    print('[HTTP] 🌐 Using PURE HTTP (Dart http package)');
    print('[HTTP] Mode: ${isI2v ? "I2V" : "T2V"}');
    print('[HTTP] Model: $adjustedModel');
    print('[HTTP] Endpoint: $endpoint');

    try {
      // Pure Dart HTTP POST - NO BROWSER!
      final response = await http.post(
        Uri.parse(endpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(payload),
      );

      print('\n${'=' * 20} HTTP RESPONSE [${isI2v ? "I2V" : "T2V"}] ${'=' * 20}');
      print('Status: ${response.statusCode} ${response.reasonPhrase}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('Body: ${jsonEncode(data)}');
        print('=' * 60 + '\n');

        return {
          'success': true,
          'status': response.statusCode,
          'statusText': response.reasonPhrase,
          'data': data,
          'sceneId': sceneId,
        };
      } else {
        print('Error Body: ${response.body}');
        print('=' * 60 + '\n');

        return {
          'success': false,
          'status': response.statusCode,
          'statusText': response.reasonPhrase,
          'data': response.body,
          'error': 'HTTP ${response.statusCode}: ${response.reasonPhrase}',
        };
      }
    } catch (e) {
      print('[HTTP] ✗ Request failed: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }
