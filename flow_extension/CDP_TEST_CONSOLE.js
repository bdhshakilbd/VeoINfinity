// CDP TEST SCRIPT - Paste this in the Flow page console to test
// This should work since it runs directly in the page context

(async function () {
    const opts = {
        prompt: 'a beautiful sunset over mountains',
        aspectRatio: 'Landscape (16:9)',
        model: 'Veo 3.1 - Fast [Lower Priority]'
    };

    try {
        console.log('[CDP TEST] Starting...');
        console.log('[CDP TEST] grecaptcha available:', typeof window.grecaptcha);

        // Step 1: Get access token
        const sessionResp = await fetch('https://labs.google/fx/api/auth/session', {
            credentials: 'include'
        });
        const sessionData = await sessionResp.json();
        const accessToken = sessionData.access_token;

        if (!accessToken) throw new Error('No access token found');
        console.log('[CDP TEST] Token acquired');

        // Step 2: Build request
        const sceneId = crypto.randomUUID();
        const seed = Date.now() % 50000;
        const aspectRatio = opts.aspectRatio === 'Portrait (9:16)'
            ? 'VIDEO_ASPECT_RATIO_PORTRAIT'
            : 'VIDEO_ASPECT_RATIO_LANDSCAPE';

        let modelKey = 'veo_3_1_t2v_fast_ultra_relaxed';
        console.log('[CDP TEST] Model:', modelKey);

        // Step 3: Get reCAPTCHA token
        console.log('[CDP TEST] Getting reCAPTCHA...');
        const recaptchaToken = await window.grecaptcha.enterprise.execute(
            '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
            { action: 'FLOW_GENERATION' }
        );
        console.log('[CDP TEST] reCAPTCHA acquired');

        // Step 4: Build payload
        const payload = {
            clientContext: {
                recaptchaContext: { token: recaptchaToken, applicationType: 'RECAPTCHA_APPLICATION_TYPE_WEB' },
                sessionId: ';' + Date.now(),
                projectId: crypto.randomUUID(),
                tool: 'PINHOLE',
                userPaygateTier: 'PAYGATE_TIER_TWO'
            },
            requests: [{
                aspectRatio: aspectRatio,
                seed: seed,
                textInput: { prompt: opts.prompt },
                videoModelKey: modelKey,
                metadata: { sceneId: sceneId }
            }]
        };

        console.log('[CDP TEST] Payload:', JSON.stringify(payload, null, 2));

        // Step 5: Call API
        console.log('[CDP TEST] Calling API...');
        const response = await fetch('https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText', {
            method: 'POST',
            headers: { 'Content-Type': 'text/plain;charset=UTF-8', 'authorization': 'Bearer ' + accessToken },
            body: JSON.stringify(payload),
            credentials: 'include'
        });

        const text = await response.text();
        let data = null;
        try { data = JSON.parse(text); } catch (e) { data = text; }

        console.log('[CDP TEST] Response:', response.status, data);

        if (response.ok) {
            console.log('[CDP TEST] ✅ SUCCESS! Scene ID:', sceneId);
        } else {
            console.log('[CDP TEST] ❌ FAILED');
        }

        return { success: response.ok, status: response.status, data: data, sceneId: sceneId };

    } catch (error) {
        console.error('[CDP TEST] Error:', error);
        return { success: false, error: error.message };
    }
})();
