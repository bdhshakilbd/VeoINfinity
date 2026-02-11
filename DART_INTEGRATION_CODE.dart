// VEO3 React Handler Method - For Flutter/Dart Integration
// Add these JavaScript functions to your main.dart file

// ============================================================================
// 1. SETUP NETWORK MONITOR (Call once when page loads)
// ============================================================================

const String setupNetworkMonitor = '''
(() => {
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
        
        // Monitor generation start
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
                    
                    // Initial response is PENDING
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
        
        // Monitor status checks
        if (url.includes('batchCheckAsyncVideoGenerationStatus')) {
            try {
                const clone = response.clone();
                const data = await clone.json();
                
                if (data.operations && data.operations.length > 0) {
                    const op = data.operations[0];
                    const opName = op.operation?.name;
                    const status = op.status;
                    
                    // Only process OUR operation
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

// ============================================================================
// 2. TRIGGER SINGLE VIDEO GENERATION (React Handler Method)
// ============================================================================

String triggerSingleGeneration(String prompt) {
  return '''
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
    textarea.value = "$prompt";
    
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
}

// ============================================================================
// 3. GET MONITOR STATUS (Poll this every 5 seconds)
// ============================================================================

const String getMonitorStatus = '''
(() => {
    return window.__veo3_monitor || {status: 'not_initialized'};
})();
''';

// ============================================================================
// 4. RESET MONITOR (Call before each new generation)
// ============================================================================

const String resetMonitor = '''
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

// ============================================================================
// 5. ENSURE PROJECT IS OPEN (Call before generation)
// ============================================================================

const String ensureProjectOpen = '''
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

// ============================================================================
// USAGE IN DART
// ============================================================================

/*

// 1. Setup (call once when page loads)
await webViewController.evaluateJavascript(setupNetworkMonitor);

// 2. Before each generation, ensure project is open
final projectResult = await webViewController.evaluateJavascript(ensureProjectOpen);
if (projectResult['wasHomepage'] == true) {
  await Future.delayed(Duration(seconds: 2));
}

// 3. Reset monitor before new generation
await webViewController.evaluateJavascript(resetMonitor);

// 4. Trigger generation
final result = await webViewController.evaluateJavascript(
  triggerSingleGeneration("A beautiful sunset over mountains")
);

if (result['success'] == true) {
  print('Generation triggered!');
  
  // 5. Poll for status every 5 seconds
  Timer.periodic(Duration(seconds: 5), (timer) async {
    final status = await webViewController.evaluateJavascript(getMonitorStatus);
    
    print('Status: \${status['status']}');
    
    if (status['status'] == 'pending') {
      print('Operation: \${status['operationName']}');
      print('Credits: \${status['credits']}');
    } else if (status['status'] == 'active') {
      print('Generating...');
    } else if (status['status'] == 'complete') {
      print('Video URL: \${status['videoUrl']}');
      timer.cancel();
      
      // Download video
      await downloadVideo(status['videoUrl']);
      
    } else if (status['status'] == 'failed') {
      print('Failed: \${status['error']}');
      timer.cancel();
    } else if (status['status'] == 'auth_error') {
      print('Auth error: \${status['apiError']}');
      timer.cancel();
    }
  });
}

*/

// ============================================================================
// BATCH GENERATION EXAMPLE
// ============================================================================

/*

Future<void> batchGenerate(List<String> prompts) async {
  for (int i = 0; i < prompts.length; i++) {
    print('Generating \${i + 1}/\${prompts.length}: \${prompts[i]}');
    
    // Reset monitor
    await webViewController.evaluateJavascript(resetMonitor);
    
    // Trigger generation
    final result = await webViewController.evaluateJavascript(
      triggerSingleGeneration(prompts[i])
    );
    
    if (result['success'] != true) {
      print('Failed to trigger: \${result['error']}');
      continue;
    }
    
    // Wait for completion
    bool completed = false;
    while (!completed) {
      await Future.delayed(Duration(seconds: 5));
      
      final status = await webViewController.evaluateJavascript(getMonitorStatus);
      
      if (status['status'] == 'complete') {
        print('Video \${i + 1} complete: \${status['videoUrl']}');
        await downloadVideo(status['videoUrl'], 'video_\${i + 1}.mp4');
        completed = true;
      } else if (status['status'] == 'failed' || status['status'] == 'auth_error') {
        print('Video \${i + 1} failed');
        completed = true;
      }
    }
    
    // Wait before next generation
    await Future.delayed(Duration(seconds: 2));
  }
}

*/

// ============================================================================
// STATUS FLOW
// ============================================================================

/*

Status transitions:
  idle → pending → active → complete
                          ↓
                       failed

Status meanings:
  - idle: No generation in progress
  - pending: Generation queued (initial API response)
  - active: Video is being generated
  - complete: Video ready, videoUrl available
  - failed: Generation failed
  - auth_error: 403 error (no credits/permissions)

*/
