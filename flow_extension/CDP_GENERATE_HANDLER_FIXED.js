// Add this to content.js in the message listener section
// Replace the existing CDP_GENERATE handler with this

if (msg.type === 'CDP_GENERATE') {
    // Inject script into MAIN page context where grecaptcha is available
    const script = document.createElement('script');
    script.textContent = `
    (async function() {
        try {
            const opts = ${JSON.stringify(msg.options)};
            
            // Step 1: Get access token
            console.log('[CDP] Getting access token...');
            const sessionResp = await fetch('https://labs.google/fx/api/auth/session', {
                credentials: 'include'
            });
            const sessionData = await sessionResp.json();
            const accessToken = sessionData.access_token;
            
            if (!accessToken) {
                throw new Error('No access token found');
            }
            
            console.log('[CDP] Token acquired');
            
            // Step 2: Build request
            const sceneId = crypto.randomUUID();
            const seed = Date.now() % 50000;
            const prompt = opts.prompt;
            const aspectRatio = opts.aspectRatio === 'Portrait (9:16)' 
                ? 'VIDEO_ASPECT_RATIO_PORTRAIT' 
                : 'VIDEO_ASPECT_RATIO_LANDSCAPE';
            
            // Model mapping
            let modelKey = 'veo_3_1_t2v_fast_ultra';
            const modelSel = opts.model;
            if (modelSel.includes('Veo 3.1 - Fast [Lower Priority]')) {
                modelKey = 'veo_3_1_t2v_fast_ultra_relaxed';
            } else if (modelSel.includes('Veo 3.1 - Quality')) {
                modelKey = 'veo_3_1_t2v_quality_ultra';
            } else if (modelSel.includes('Veo 2 - Fast')) {
                modelKey = 'veo_2_t2v_fast';
            } else if (modelSel.includes('Veo 2 - Quality')) {
                modelKey = 'veo_2_t2v_quality';
            }
            
            // Adjust for portrait
            if (aspectRatio === 'VIDEO_ASPECT_RATIO_PORTRAIT' && !modelKey.includes('_portrait')) {
                if (modelKey.includes('fast')) {
                    modelKey = modelKey.replace('fast', 'fast_portrait');
                } else if (modelKey.includes('quality')) {
                    modelKey = modelKey.replace('quality', 'quality_portrait');
                }
            }
            
            console.log('[CDP] Model:', modelKey);
            
            const requestObj = {
                aspectRatio: aspectRatio,
                seed: seed,
                textInput: { prompt: prompt },
                videoModelKey: modelKey,
                metadata: { sceneId: sceneId }
            };
            
            // Step 3: Get reCAPTCHA token
            console.log('[CDP] Getting reCAPTCHA token...');
            console.log('[CDP] grecaptcha available:', typeof window.grecaptcha);
            
            // grecaptcha is in main page context, directly accessible!
            const recaptchaToken = await window.grecaptcha.enterprise.execute(
                '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
                { action: 'FLOW_GENERATION' }
            );
            
            console.log('[CDP] reCAPTCHA token acquired');
            
            // Step 4: Build payload
            const projectId = crypto.randomUUID();
            const payload = {
                clientContext: {
                    recaptchaContext: {
                        token: recaptchaToken,
                        applicationType: 'RECAPTCHA_APPLICATION_TYPE_WEB'
                    },
                    sessionId: ';' + Date.now(),
                    projectId: projectId,
                    tool: 'PINHOLE',
                    userPaygateTier: 'PAYGATE_TIER_TWO'
                },
                requests: [requestObj]
            };
            
            // Step 5: Send analytics
            try {
                await fetch(\`https://www.google-analytics.com/privacy-sandbox/register-conversion?en=pinhole_generate_video&tid=G-X2GNH8R5NS&dl=\${encodeURIComponent(window.location.href)}\`, {
                    method: 'GET',
                    credentials: 'include'
                });
                console.log('[CDP] Analytics sent');
            } catch (e) {
                console.log('[CDP] Analytics failed (non-critical)');
            }
            
            // Step 6: Call API
            const endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';
            console.log('[CDP] Calling API:', endpoint);
            
            const response = await fetch(endpoint, {
                method: 'POST',
                headers: {
                    'Content-Type': 'text/plain;charset=UTF-8',
                    'authorization': 'Bearer ' + accessToken
                },
                body: JSON.stringify(payload),
                credentials: 'include'
            });
            
            const text = await response.text();
            let data = null;
            try { data = JSON.parse(text); } catch (e) { data = text; }
            
            console.log('[CDP] Response status:', response.status);
            console.log('[CDP] Response data:', data);
            
            // Send result back via custom event
            window.dispatchEvent(new CustomEvent('CDP_RESULT', {
                detail: {
                    success: response.ok,
                    status: response.status,
                    statusText: response.statusText,
                    data: data,
                    sceneId: sceneId
                }
            }));
            
        } catch (error) {
            console.error('[CDP] Error:', error);
            window.dispatchEvent(new CustomEvent('CDP_RESULT', {
                detail: {
                    success: false,
                    error: error.message
                }
            }));
        }
    })();
    `;

    // Listen for result from injected script
    const resultHandler = (event) => {
        window.removeEventListener('CDP_RESULT', resultHandler);
        script.remove();
        sendResponse(event.detail);
    };
    window.addEventListener('CDP_RESULT', resultHandler);

    // Inject script into page
    (document.head || document.documentElement).appendChild(script);

    return true; // Keep channel open for async response
}
