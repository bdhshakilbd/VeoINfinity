import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../lib/services/video_generation_service.dart';

Future<void> main(List<String> args) async {
  final generator = DesktopGenerator(debugPort: 9222);

  print('Connecting to desktop browser (CDP) on port 9222...');
  try {
    await generator.connect();
  } catch (e) {
    print('Failed to connect: $e');
    exit(1);
  }

  print('Fetching access token...');
  final accessToken = await generator.getAccessToken();
  if (accessToken == null) {
    print('Could not retrieve access token. Ensure you are logged in at https://labs.google/fx/tools/flow');
    exit(1);
  }
  print('Access token: ${accessToken.substring(0, 20)}...');

  // Prefetch recaptcha tokens
  const int tokenCount = 16;
  print('Prefetching $tokenCount reCAPTCHA tokens...');
  try {
    await generator.prefetchRecaptchaTokens(tokenCount);
  } catch (e) {
    print('prefetchRecaptchaTokens failed: $e');
  }

  // Collect tokens
  final tokens = <String>[];
  for (int i = 0; i < tokenCount; i++) {
    final t = generator.getNextPrefetchedToken();
    if (t != null) tokens.add(t);
  }
  print('Collected ${tokens.length} tokens');

  // Prompts to generate
  final prompts = [
    'A majestic dragon flying over snow-capped mountains at sunset, cinematic shot.',
    'A futuristic city with flying cars and neon lights, cyberpunk style.',
    'An underwater scene with colorful coral reefs and tropical fish, 4K quality.',
    'A medieval castle on a cliff during a thunderstorm, dramatic lighting.'
  ];

  // Launch concurrent HTTP generation requests
  final start = DateTime.now();
  final futures = <Future<Map<String, dynamic>>>[];
  for (int i = 0; i < prompts.length; i++) {
    final prompt = prompts[i];
    final token = i < tokens.length ? tokens[i] : '';
    futures.add(_sendGenerateRequest(prompt, accessToken, token, i + 1));
  }

  final results = await Future.wait(futures);
  final total = DateTime.now().difference(start).inMilliseconds / 1000.0;

  print('\nAll requests completed in ${total}s');
  for (final r in results) {
    final idx = r['video_num'];
    final code = r['status_code'];
    print('\nVideo $idx -> HTTP $code');
    if (code == 200) {
      final ops = r['response']['operations'] as List<dynamic>?;
      if (ops != null && ops.isNotEmpty) {
        final op = ops[0] as Map<String, dynamic>;
        print('  operation: ${op['operation']?['name']}');
        print('  status: ${op['status']}');
      } else {
        print('  No operations in response');
      }
    } else {
      print('  Response: ${r['response']}');
    }
  }

  // Close websocket
  generator.close();
  print('Done.');
}

Future<Map<String, dynamic>> _sendGenerateRequest(String prompt, String accessToken, String recaptchaToken, int videoNum) async {
  final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
  final sceneId = DateTime.now().millisecondsSinceEpoch.toString() + '_$videoNum';

  final requestObj = {
    'aspectRatio': 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    'seed': DateTime.now().millisecondsSinceEpoch % 50000,
    'textInput': {'prompt': prompt},
    'videoModelKey': 'veo_3_1_t2v_fast_ultra_relaxed',
    'metadata': {'sceneId': sceneId}
  };

  final payload = {
    'clientContext': {
      'recaptchaContext': {'token': recaptchaToken ?? '', 'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB'},
      'sessionId': sessionId,
      'tool': 'PINHOLE'
    },
    'requests': [requestObj]
  };

  final uri = Uri.parse('https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText');
  try {
    final res = await http.post(uri, headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json'
    }, body: jsonEncode(payload));

    dynamic body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      body = res.body;
    }

    return {
      'video_num': videoNum,
      'status_code': res.statusCode,
      'response': body,
      'scene_id': sceneId,
    };
  } catch (e) {
    return {
      'video_num': videoNum,
      'status_code': 0,
      'response': e.toString(),
      'scene_id': sceneId,
    };
  }
}
