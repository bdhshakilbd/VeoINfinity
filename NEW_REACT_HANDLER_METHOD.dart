/// NEW METHOD: Generate video using React Handler (Avoids Automation Detection)
/// 
/// This method directly calls React's onChange and onClick handlers to trigger
/// video generation, which avoids being detected as automation and prevents 403 errors.
/// 
/// Usage:
/// ```dart
/// final result = await generator.generateVideoReactHandler(
///   prompt: "A beautiful sunset",
///   onProgress: (progress, status) {
///     print('Progress: $progress% - $status');
///   },
/// );
/// ```
Future<Map<String, dynamic>?> generateVideoReactHandler({
  required String prompt,
  String aspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE',
  String model = 'Veo 3.1 - Fast',
  String? startImageMediaId,
  String? endImageMediaId,
  Function(int progress, String status)? onProgress,
}) async {
  print('[REACT] Generating video via React handlers...');
  print('[REACT] Prompt: ${prompt.length > 50 ? "${prompt.substring(0, 50)}..." : prompt}');
  
  try {
    // Step 1: Setup network monitor (if not already done)
    await _setupNetworkMonitor();
    
    // Step 2: Ensure project is open
    await _ensureProjectOpen();
    
    // Step 3: Reset monitor for new generation
    await _resetMonitor();
    
    // Step 4: Trigger generation using React handlers
    final triggerResult = await _triggerGenerationReact(prompt);
    
    if (triggerResult['success'] != true) {
      print('[REACT] ✗ Failed to trigger: ${triggerResult['error']}');
      return {'error': triggerResult['error']};
    }
    
    print('[REACT] ✓ Generation triggered!');
    
    // Step 5: Poll for status
    return await _pollForCompletion(onProgress: onProgress);
    
  } catch (e) {
    print('[REACT] ✗ Exception: $e');
    return {'error': e.toString()};
  }
}

/// Setup network monitor (call once)
Future<void> _setupNetworkMonitor() async {
  final jsCode = '''
(() => {
    if (window.__veo3_monitor) {
        return {success: true, alreadyInstalled: true};
    }
    
    window.__veo3_monitor = {
        startTime: Date.now(),
        operationName: null,
        videoUrl: null,
        status: 'idle',
        credits: null,
        lastUpdate: null,
        error: null,
        apiError: null
    };
    
    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        const url = args[0]?.toString() || '';
        
        if (url.includes('batchAsyncGenerateVideoText') || 
            url.includes('batchAsyncGenerateVideoStartImage') ||
            url.includes('batchAsyncGenerateVideoStartAndEndImage')) {
            try {
                const clone = response.clone();
                const data = await clone.json();
                
                if (response.status === 200 && data.operations && data.operations.length > 0) {
                    const op = data.operations[0];
                    window.__veo3_monitor.operationName = op.operation?.name;
                    window.__veo3_monitor.credits = data.remainingCredits;
                    
                    if (op.status === 'MEDIA_GENERATION_STATUS_PENDING') {
                        window.__veo3_monitor.status = 'pending';
                    } else {
                        window.__veo3_monitor.status = 'started';
                    }
                    
                    window.__veo3_monitor.lastUpdate = Date.now();
                    console.log('[Monitor] Started:', window.__veo3_monitor.operationName);
                } else if (response.status === 403) {
                    window.__veo3_monitor.status = 'auth_error';
                    window.__veo3_monitor.apiError = '403 Forbidden';
                }
            } catch (e) {
                console.error('[Monitor] Parse error:', e);
            }
        }
        
        if (url.includes('batchCheckAsyncVideoGenerationStatus')) {
            try {
                const clone = response.clone();
                const data = await clone.json();
                
                if (data.operations && data.operations.length > 0) {
                    const op = data.operations[0];
                    const opName = op.operation?.name;
                    const status = op.status;
                    
                    if (window.__veo3_monitor.operationName && opName !== window.__veo3_monitor.operationName) {
                        return response;
                    }
                    
                    window.__veo3_monitor.lastUpdate = Date.now();
                    
                    if (status === 'MEDIA_GENERATION_STATUS_PENDING') {
                        window.__veo3_monitor.status = 'pending';
                    } else if (status === 'MEDIA_GENERATION_STATUS_ACTIVE') {
                        window.__veo3_monitor.status = 'active';
                    } else if (status === 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
                        const videoUrl = op.operation?.metadata?.video?.fifeUrl;
                        if (videoUrl) {
                            window.__veo3_monitor.videoUrl = videoUrl;
                            window.__veo3_monitor.status = 'complete';
                        }
                    } else if (status.includes('FAIL') || status.includes('ERROR')) {
                        window.__veo3_monitor.status = 'failed';
                        window.__veo3_monitor.error = status;
                    }
                }
            } catch (e) {
                console.error('[Monitor] Status error:', e);
            }
        }
        
        return response;
    };
    
    console.log('[Monitor] Installed');
    return {success: true};
})();
''';

  final result = await executeJs(jsCode);
  if (result is Map && result['alreadyInstalled'] == true) {
    print('[REACT] Network monitor already installed');
  } else {
    print('[REACT] Network monitor installed');
  }
}

/// Ensure project is open (create if on homepage)
Future<void> _ensureProjectOpen() async {
  final jsCode = '''
(async () => {
    const buttons = [...document.querySelectorAll('button')];
    const newProjBtn = buttons.find(b => b.textContent.includes('New project'));
    
    if (newProjBtn) {
        newProjBtn.click();
        await new Promise(r => setTimeout(r, 3000));
        return {wasHomepage: true};
    }
    return {wasHomepage: false, hasProject: true};
})();
''';

  final result = await executeJs(jsCode);
  if (result is Map && result['wasHomepage'] == true) {
    print('[REACT] Created new project');
    await Future.delayed(const Duration(seconds: 2));
  } else {
    print('[REACT] Already in a project');
  }
}

/// Reset monitor before new generation
Future<void> _resetMonitor() async {
  final jsCode = '''
(() => {
    if (window.__veo3_monitor) {
        window.__veo3_monitor.operationName = null;
        window.__veo3_monitor.videoUrl = null;
        window.__veo3_monitor.status = 'idle';
        window.__veo3_monitor.error = null;
        window.__veo3_monitor.apiError = null;
        window.__veo3_monitor.startTime = Date.now();
    }
    return {success: true};
})();
''';

  await executeJs(jsCode);
}

/// Trigger generation using React handlers
Future<Map<String, dynamic>> _triggerGenerationReact(String prompt) async {
  final jsCode = '''
(async () => {
    const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
    if (!textarea) {
        return {success: false, error: 'Textarea not found'};
    }
    
    // Get React props for textarea
    const textareaPropsKey = Object.keys(textarea).find(key => key.startsWith('__reactProps\$'));
    if (!textareaPropsKey) {
        return {success: false, error: 'React props not found on textarea'};
    }
    
    const textareaProps = textarea[textareaPropsKey];
    
    // Set the value
    textarea.value = ${jsonEncode(prompt)};
    
    // Call React onChange handler to update state
    if (textareaProps.onChange) {
        textareaProps.onChange({
            target: textarea,
            currentTarget: textarea,
            nativeEvent: new Event('change')
        });
    }
    
    // Also dispatch standard events as backup
    textarea.dispatchEvent(new Event('input', {bubbles: true}));
    textarea.dispatchEvent(new Event('change', {bubbles: true}));
    
    // Wait for React to update
    await new Promise(r => setTimeout(r, 1000));
    
    // Find the Create button
    const buttons = Array.from(document.querySelectorAll('button'));
    const createButton = buttons.find(b => b.innerText.includes('Create') || b.innerHTML.includes('arrow_forward'));
    
    if (!createButton) {
        return {success: false, error: 'Create button not found'};
    }
    
    // Check if button is still disabled
    if (createButton.disabled) {
        return {success: false, error: 'Button still disabled - prompt may not have been set'};
    }
    
    // Find React props key for button
    const reactPropsKey = Object.keys(createButton).find(key => key.startsWith('__reactProps\$'));
    if (!reactPropsKey) {
        return {success: false, error: 'React props key not found on button'};
    }
    
    const props = createButton[reactPropsKey];
    if (!props || !props.onClick) {
        return {success: false, error: 'onClick handler not found'};
    }
    
    // Call the React onClick handler directly
    try {
        props.onClick({
            preventDefault: () => {},
            stopPropagation: () => {},
            nativeEvent: new MouseEvent('click', {bubbles: true, cancelable: true})
        });
        return {success: true, method: 'react_handler', promptSet: true};
    } catch (e) {
        return {success: false, error: e.message};
    }
})();
''';

  final result = await executeJs(jsCode, timeout: const Duration(seconds: 15));
  if (result is Map) {
    return Map<String, dynamic>.from(result);
  }
  return {'success': false, error': 'Invalid response'};
}

/// Poll for completion
Future<Map<String, dynamic>?> _pollForCompletion({
  Function(int progress, String status)? onProgress,
  int maxWaitSeconds = 360,
}) async {
  final startTime = DateTime.now();
  String? lastStatus;
  
  while (DateTime.now().difference(startTime).inSeconds < maxWaitSeconds) {
    await Future.delayed(const Duration(seconds: 5));
    
    // Get monitor status
    final statusResult = await executeJs('window.__veo3_monitor || {status: "not_initialized"}');
    
    if (statusResult is! Map) continue;
    
    final status = statusResult['status'] as String?;
    final operationName = statusResult['operationName'] as String?;
    final credits = statusResult['credits'];
    final videoUrl = statusResult['videoUrl'] as String?;
    final error = statusResult['error'] as String?;
    final apiError = statusResult['apiError'] as String?;
    
    // Show status updates
    if (status != lastStatus) {
      if (status == 'pending') {
        print('[REACT] Operation: ${operationName?.substring(0, 25)}...');
        print('[REACT] Credits: $credits');
        print('[REACT] Status: PENDING - Generation queued');
        onProgress?.call(5, 'Queued');
      } else if (status == 'active') {
        print('[REACT] Status: ACTIVE - Generating...');
        onProgress?.call(50, 'Generating');
      } else if (status == 'complete') {
        print('[REACT] Status: SUCCESSFUL!');
        print('[REACT] Video URL: ${videoUrl?.substring(0, 60)}...');
        onProgress?.call(100, 'Complete');
        
        return {
          'status': 'complete',
          'videoUrl': videoUrl,
          'operationName': operationName,
        };
      } else if (status == 'failed') {
        print('[REACT] Status: FAILED - $error');
        onProgress?.call(0, 'Failed');
        return {'error': error ?? 'Generation failed'};
      } else if (status == 'auth_error') {
        print('[REACT] AUTH ERROR: $apiError');
        onProgress?.call(0, 'Auth Error');
        return {'error': apiError ?? '403 Forbidden'};
      }
      
      lastStatus = status;
    }
  }
  
  print('[REACT] Timeout!');
  return {'error': 'Timeout waiting for video'};
}
