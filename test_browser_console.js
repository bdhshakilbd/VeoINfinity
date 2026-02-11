// VEO3 Programmatic Video Generation Test
// Paste this in browser console at https://labs.google/fx/tools/flow

(async function () {
    try {
        console.log('🎬 Starting VEO3 programmatic generation test...');

        // 1. Get Project ID from URL
        const urlMatch = window.location.href.match(/project\/([^\/?]+)/);
        const projectId = urlMatch ? urlMatch[1] : 'test-project-id';
        console.log('📋 Project ID:', projectId);

        // 2. Get fresh access token
        console.log('🔑 Fetching access token...');
        const sessionRes = await fetch('https://labs.google/fx/api/auth/session', { credentials: 'include' });
        const sessionData = await sessionRes.json();
        const accessToken = sessionData.access_token;
        console.log('✅ Access token obtained:', accessToken.substring(0, 20) + '...');

        // 3. Get reCAPTCHA token
        console.log('🔐 Getting reCAPTCHA token...');
        const recaptchaToken = await grecaptcha.enterprise.execute(
            '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
            { action: 'FLOW_GENERATION' }
        );
        console.log('✅ reCAPTCHA token obtained:', recaptchaToken.substring(0, 30) + '...');

        // 4. Build payload
        const sceneId = 'test-' + Date.now();
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
            requests: [{
                aspectRatio: 'VIDEO_ASPECT_RATIO_LANDSCAPE',
                seed: Math.floor(Math.random() * 50000),
                textInput: { prompt: 'A cute duck swimming in a pond' },
                videoModelKey: 'veo_3_1_t2v_fast_ultra_relaxed',
                metadata: { sceneId: sceneId }
            }]
        };

        console.log('📦 Payload:', JSON.stringify(payload, null, 2));

        // 5. Send API request
        console.log('🚀 Sending API request...');
        const response = await fetch(
            'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText',
            {
                method: 'POST',
                headers: {
                    'Content-Type': 'text/plain;charset=UTF-8',
                    'authorization': 'Bearer ' + accessToken,
                    'x-browser-channel': 'stable',
                    'x-browser-year': '2026',
                    'x-browser-validation': 'iB7C9P2Z85vwN6w2umx6Y90enzY=',
                    'x-browser-copyright': 'Copyright 2026 Google LLC. All Rights reserved.'
                },
                body: JSON.stringify(payload),
                credentials: 'include'
            }
        );

        console.log('📊 Response status:', response.status, response.statusText);

        const responseText = await response.text();
        let responseData;
        try {
            responseData = JSON.parse(responseText);
        } catch (e) {
            responseData = responseText;
        }

        console.log('📄 Response data:', responseData);

        if (response.ok) {
            console.log('✅ SUCCESS! Video generation started');
            const operations = responseData.operations || [];
            if (operations.length > 0) {
                const operationName = operations[0].operation?.name;
                console.log('🎯 Operation name:', operationName);
                console.log('🆔 Scene ID:', sceneId);
            }
        } else {
            console.error('❌ FAILED:', responseData);
        }

        return {
            success: response.ok,
            status: response.status,
            data: responseData
        };

    } catch (error) {
        console.error('💥 Error:', error);
        return {
            success: false,
            error: error.message
        };
    }
})();
