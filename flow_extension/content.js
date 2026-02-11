/**
 * Veo3 Infinity - Content Script v1.0.3
 * Only runs on Google Flow pages
 */

// Only run on Google Flow pages
if (!window.location.href.includes('labs.google')) {
    console.log('[Veo3] Not a Google Flow page, skipping...');
} else {
    console.log('[Veo3 Infinity] Content script loading on Flow page...');

    (function () {
        'use strict';

        const state = {
            currentRequestId: null,
            isGenerating: false,
            generations: []
        };

        const SELECTORS = {
            // Find dropdown by checking the button's own text content
            findDropdownByText: (searchText) => {
                const allComboboxes = document.querySelectorAll('button[role="combobox"]');
                for (const btn of allComboboxes) {
                    const btnText = btn.textContent || '';
                    if (btnText.includes(searchText)) {
                        console.log('[Veo3] Found dropdown for "' + searchText + '":', btnText.substring(0, 40));
                        return btn;
                    }
                }
                return null;
            },

            // Get all comboboxes in order
            getAllComboboxes: () => document.querySelectorAll('button[role="combobox"]'),

            // Mode dropdown (index 0)
            modeDropdownButton: () => {
                const combos = SELECTORS.getAllComboboxes();
                return combos[0] || null;
            },

            // Aspect ratio dropdown - find by text or use index 1
            aspectRatioDropdown: () => {
                return SELECTORS.findDropdownByText('Aspect Ratio') ||
                    SELECTORS.findDropdownByText('Landscape') ||
                    SELECTORS.findDropdownByText('Portrait') ||
                    SELECTORS.getAllComboboxes()[1] || null;
            },

            // Outputs dropdown - find by text "Outputs per prompt" or use index 2
            outputsDropdown: () => {
                return SELECTORS.findDropdownByText('Outputs per prompt') ||
                    SELECTORS.getAllComboboxes()[2] || null;
            },

            // Model dropdown - find by text or use index 3
            modelDropdown: () => {
                return SELECTORS.findDropdownByText('ModelVeo') ||
                    SELECTORS.findDropdownByText('Veo 3.1') ||
                    SELECTORS.findDropdownByText('Veo 2') ||
                    SELECTORS.getAllComboboxes()[3] || null;
            },

            dropdownOptions: () => document.querySelectorAll('div[role="option"]'),
            textarea: () => document.querySelector('textarea#PINHOLE_TEXT_AREA_ELEMENT_ID') || document.querySelector('textarea'),
            generateButton: () => {
                const buttons = document.querySelectorAll('button');
                for (const btn of buttons) {
                    if (btn.innerHTML.includes('arrow_forward')) return btn;
                }
                return null;
            },
            settingsButton: () => {
                const buttons = document.querySelectorAll('button');
                for (const btn of buttons) {
                    if (btn.innerHTML.includes('tune')) return btn;
                }
                return null;
            },
            modelNameButton: () => {
                const buttons = document.querySelectorAll('button');
                for (const btn of buttons) {
                    const text = btn.textContent || '';
                    if (text.includes('Veo 3.1') || text.includes('Veo 2')) return btn;
                }
                return null;
            },
            newProjectButton: () => {
                const buttons = document.querySelectorAll('button');
                for (const btn of buttons) {
                    if (btn.textContent && btn.textContent.includes('New project')) return btn;
                }
                return null;
            }
        };

        const utils = {
            sleep: (ms) => new Promise(resolve => setTimeout(resolve, ms)),
            generateId: () => `veo_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,

            async setTextareaValue(textarea, text) {
                if (!textarea) throw new Error('Textarea not found');
                const nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
                textarea.focus();
                await utils.sleep(100);
                nativeSetter.call(textarea, '');
                textarea.dispatchEvent(new Event('input', { bubbles: true }));
                await utils.sleep(50);
                nativeSetter.call(textarea, text);
                textarea.dispatchEvent(new Event('input', { bubbles: true }));
                textarea.dispatchEvent(new Event('change', { bubbles: true }));
                await utils.sleep(100);
                return textarea.value === text;
            },

            async clickAndWait(element, waitMs = 300) {
                if (!element) {
                    console.log('[Veo3] Element not found');
                    return false;
                }
                element.scrollIntoView({ behavior: 'instant', block: 'center' });
                await utils.sleep(50);
                element.click();
                await utils.sleep(waitMs);
                return true;
            },

            async selectOption(optionText) {
                await utils.sleep(200);
                const options = SELECTORS.dropdownOptions();
                console.log(`[Veo3] Found ${options.length} options, looking for: ${optionText}`);
                for (const option of options) {
                    const text = option.textContent || '';
                    if (text.includes(optionText)) {
                        console.log(`[Veo3] Selecting option: ${text}`);
                        await utils.clickAndWait(option, 300);
                        return true;
                    }
                }
                console.log('[Veo3] Option not found:', optionText);
                return false;
            }
        };

        const generator = {
            isOnHomePage() {
                return !window.location.href.includes('/project/');
            },

            async createNewProject() {
                console.log('[Veo3] Creating new project...');
                if (!this.isOnHomePage()) {
                    window.location.href = 'https://labs.google/fx/tools/flow/';
                    await utils.sleep(3000);
                }
                await utils.sleep(1000);
                for (let i = 0; i < 10; i++) {
                    const btn = SELECTORS.newProjectButton();
                    if (btn) {
                        await utils.clickAndWait(btn, 2000);
                        await utils.sleep(2000);
                        if (window.location.href.includes('/project/')) {
                            return true;
                        }
                    }
                    await utils.sleep(500);
                }
                throw new Error('Could not create new project');
            },

            async openSettingsPanel() {
                const modelBtn = SELECTORS.modelNameButton();
                if (modelBtn) {
                    console.log('[Veo3] Opening settings via model button');
                    await utils.clickAndWait(modelBtn, 500);
                    return true;
                }
                const settingsBtn = SELECTORS.settingsButton();
                if (settingsBtn) {
                    console.log('[Veo3] Opening settings via tune button');
                    await utils.clickAndWait(settingsBtn, 500);
                    return true;
                }
                console.log('[Veo3] Could not find settings button');
                return false;
            },

            async selectMode(mode) {
                console.log('[Veo3] Selecting mode:', mode);
                const modeBtn = SELECTORS.modeDropdownButton();
                if (!modeBtn) {
                    console.log('[Veo3] Mode button not found');
                    return false;
                }
                await utils.clickAndWait(modeBtn, 300);
                const selected = await utils.selectOption(mode);
                if (!selected) document.body.click();
                await utils.sleep(200);
                return selected;
            },

            async configureSettings(options) {
                const { aspectRatio, model, outputCount, mode } = options;
                console.log('[Veo3] Configuring settings:', options);

                if (mode) {
                    await this.selectMode(mode);
                    await utils.sleep(300);
                }

                const panelOpened = await this.openSettingsPanel();
                if (!panelOpened) {
                    console.log('[Veo3] Settings panel did not open');
                    return false;
                }
                await utils.sleep(500);

                if (aspectRatio) {
                    console.log('[Veo3] Setting aspect ratio:', aspectRatio);
                    const btn = SELECTORS.aspectRatioDropdown();
                    console.log('[Veo3] Aspect ratio button found:', !!btn);
                    if (btn) {
                        await utils.clickAndWait(btn, 300);
                        await utils.selectOption(aspectRatio);
                        await utils.sleep(300);
                    }
                }

                if (outputCount) {
                    console.log('[Veo3] Setting output count:', outputCount);
                    const btn = SELECTORS.outputsDropdown();
                    console.log('[Veo3] Outputs button found:', !!btn, btn ? btn.textContent.substring(0, 30) : 'null');
                    if (btn) {
                        await utils.clickAndWait(btn, 300);
                        const selected = await utils.selectOption(String(outputCount));
                        console.log('[Veo3] Output selection result:', selected);
                        await utils.sleep(300);
                    } else {
                        console.log('[Veo3] ERROR: Outputs dropdown not found!');
                    }
                }

                if (model) {
                    console.log('[Veo3] Setting model:', model);
                    const btn = SELECTORS.modelDropdown();
                    console.log('[Veo3] Model button found:', !!btn);
                    if (btn) {
                        await utils.clickAndWait(btn, 300);
                        await utils.selectOption(model);
                        await utils.sleep(300);
                    }
                }

                document.body.click();
                await utils.sleep(300);
                return true;
            },

            async testConfiguration(options) {
                const { prompt, aspectRatio, model, outputCount, mode, createNewProject } = options;
                console.log('[Veo3] TEST MODE - Options:', options);
                try {
                    if (createNewProject) await this.createNewProject();
                    await this.configureSettings({ aspectRatio, model, outputCount, mode });
                    const textarea = SELECTORS.textarea();
                    if (textarea) await utils.setTextareaValue(textarea, prompt || 'TEST');
                    return { status: 'test_complete', generateButtonFound: !!SELECTORS.generateButton() };
                } catch (e) {
                    console.error('[Veo3] Test error:', e);
                    return { status: 'test_error', error: e.message };
                }
            },

            async generate(options) {
                const { prompt, aspectRatio, model, outputCount, mode, requestId, createNewProject, testOnly } = options;
                if (testOnly) return this.testConfiguration(options);

                try {
                    state.isGenerating = true;
                    state.currentRequestId = requestId;
                    if (createNewProject) await this.createNewProject();
                    await this.configureSettings({ aspectRatio, model, outputCount, mode });

                    const textarea = SELECTORS.textarea();
                    if (!textarea) throw new Error('Textarea not found');
                    await utils.setTextareaValue(textarea, prompt);
                    await utils.sleep(500);

                    const btn = SELECTORS.generateButton();
                    if (!btn) throw new Error('Generate button not found');
                    await utils.clickAndWait(btn, 1000);

                    const result = await this.waitForGeneration(requestId);
                    state.isGenerating = false;
                    state.generations.push({ requestId, prompt, model, result, timestamp: new Date().toISOString() });
                    return result;
                } catch (e) {
                    state.isGenerating = false;
                    throw e;
                }
            },

            async waitForGeneration(requestId) {
                const start = Date.now();
                const MAX_WAIT = 360000; // 6 minutes

                console.log('[VEO3] Waiting for generation to complete...');

                while (Date.now() - start < MAX_WAIT) {
                    await utils.sleep(2000);

                    // Check if we got the URL from API status (ONLY use this, not DOM)
                    if (window.__veo3_videoUrl && window.__veo3_operationName) {
                        const url = window.__veo3_videoUrl;
                        const opName = window.__veo3_operationName;

                        console.log(`[VEO3] ✅ Got URL from API for operation: ${opName}`);
                        console.log(`[VEO3] 🎬 URL: ${url.substring(0, 80)}...`);

                        // Clean up
                        delete window.__veo3_videoUrl;
                        delete window.__veo3_operationName;

                        return { status: 'complete', videoUrl: url, operationName: opName };
                    }

                    // Log progress
                    const elapsed = Math.floor((Date.now() - start) / 1000);
                    const progress = window.__veo3_progress || 0;
                    console.log(`[VEO3] ⏳ Waiting... ${elapsed}s (${progress}%)`);
                }

                throw new Error('Timeout waiting for video');
            }
        };

        // Message listener
        chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
            console.log('[Veo3] Message:', msg.type);

            if (msg.type === 'PING') {
                console.log('[Veo3] Responding to PING');
                sendResponse({ pong: true, loaded: true, url: window.location.href });
                return;
            }

            if (msg.type === 'GENERATE_VIDEO') {
                generator.generate(msg.options)
                    .then(r => { chrome.runtime.sendMessage({ type: 'GENERATION_COMPLETE', requestId: msg.requestId, ...r }).catch(() => { }); sendResponse({ status: 'started' }); })
                    .catch(e => { chrome.runtime.sendMessage({ type: 'GENERATION_ERROR', requestId: msg.requestId, error: e.message }).catch(() => { }); sendResponse({ status: 'error', error: e.message }); });
                return true;
            }
            if (msg.type === 'TEST_SETTINGS') {
                generator.testConfiguration(msg.options).then(r => sendResponse(r)).catch(e => sendResponse({ status: 'error', error: e.message }));
                return true;
            }

            if (msg.type === 'CDP_GENERATE') {
                // Inject script tag into DOM - browser executes it, not extension!
                const requestId = 'cdp_' + Date.now();
                const script = document.createElement('script');
                script.textContent = `
                (async function() {
                    const reqId = '${requestId}';
                    try {
                        const opts = ${JSON.stringify(msg.options)};
                        
                        console.log('[CDP] Starting in page context (NOT extension!)...');
                        
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
                        
                        // Step 3: Get reCAPTCHA token (directly from main page context!)
                        console.log('[CDP] Getting reCAPTCHA token...');
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
                        
                        // Store result in localStorage
                        localStorage.setItem('CDP_RES_' + reqId, JSON.stringify({
                            success: response.ok,
                            status: response.status,
                            data: data,
                            sceneId: sceneId
                        }));
                        
                    } catch (error) {
                        console.error('[CDP] Error:', error);
                        localStorage.setItem('CDP_RES_' + reqId, JSON.stringify({
                            success: false,
                            error: error.message
                        }));
                    }
                })();
                `;

                // Listen for result from injected script via postMessage
                const messageHandler = (event) => {
                    if (event.data && event.data.type === 'CDP_RESULT') {
                        window.removeEventListener('message', messageHandler);
                        script.remove();
                        sendResponse(event.data);
                    }
                };
                window.addEventListener('message', messageHandler);

                // Inject script into page
                (document.head || document.documentElement).appendChild(script);

                return true; // Keep channel open for async response
            }


            // Frame-to-Video Upload Handlers
            if (msg.type === 'UPLOAD_FRAMES') {
                console.log('[Frame Upload] Preparing to upload frames');
                // Initialize upload tracking
                if (!window.flowFrameUpload) {
                    window.flowFrameUpload = { mediaIds: [] };
                }
                sendResponse({ status: 'ready' });
                return true;
            }

            if (msg.type === 'UPLOAD_FRAME_DATA') {
                console.log('[Frame Upload] Uploading frame data');

                // Intercept fetch to capture media IDs
                const originalFetch = window.fetch;
                window.flowFrameUpload = window.flowFrameUpload || { mediaIds: [] };

                window.fetch = async function (...args) {
                    const response = await originalFetch.apply(this, args);
                    const url = args[0];

                    if (url && url.toString().includes('uploadUserImage')) {
                        try {
                            const clonedResponse = response.clone();
                            const data = await clonedResponse.json();

                            if (data.mediaGenerationId) {
                                const mediaId = data.mediaGenerationId.mediaGenerationId;
                                window.flowFrameUpload.mediaIds.push(mediaId);
                                console.log('[Frame Upload] Captured media ID:', mediaId.substring(0, 50) + '...');
                            }
                        } catch (e) {
                            console.error('[Frame Upload] Error capturing media ID:', e);
                        }
                    }

                    return response;
                };

                // Upload frames
                (async () => {
                    try {
                        // Find frame buttons
                        const frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));

                        if (frameButtons.length < 2) {
                            throw new Error('Frame buttons not found. Are you in Frames to Video mode?');
                        }

                        // Helper to upload a frame
                        const uploadFrame = async (button, dataUrl, label) => {
                            console.log(`[Frame Upload] Uploading ${label}...`);

                            // Convert data URL to File using originalFetch
                            const response = await originalFetch(dataUrl);
                            const blob = await response.blob();
                            const file = new File([blob], `${label}.png`, { type: 'image/png' });

                            // Click button
                            console.log(`[Frame Upload] Clicking ${label} button...`);
                            button.click();
                            await new Promise(r => setTimeout(r, 1000));

                            // Find file input
                            const fileInput = document.querySelector('input[type="file"]');
                            console.log(`[Frame Upload] File input found:`, !!fileInput);

                            if (fileInput) {
                                const dataTransfer = new DataTransfer();
                                dataTransfer.items.add(file);
                                fileInput.files = dataTransfer.files;
                                console.log(`[Frame Upload] File set on input:`, fileInput.files[0]?.name);

                                fileInput.dispatchEvent(new Event('change', { bubbles: true }));
                                fileInput.dispatchEvent(new Event('input', { bubbles: true }));

                                await new Promise(r => setTimeout(r, 1500));

                                // Click Crop and Save
                                const buttons = Array.from(document.querySelectorAll('button'));
                                let cropBtnFound = false;
                                for (const btn of buttons) {
                                    if (btn.textContent.includes('Crop and Save')) {
                                        console.log(`[Frame Upload] Clicking Crop and Save for ${label}...`);
                                        btn.click();
                                        cropBtnFound = true;
                                        await new Promise(r => setTimeout(r, 3000));
                                        break;
                                    }
                                }
                                if (!cropBtnFound) {
                                    console.warn(`[Frame Upload] Crop and Save button not found for ${label}`);
                                }
                            } else {
                                console.error(`[Frame Upload] No file input found for ${label}`);
                            }
                        };

                        await uploadFrame(frameButtons[0], msg.firstFrame, 'First Frame');
                        await uploadFrame(frameButtons[1], msg.lastFrame, 'Last Frame');

                        // Restore original fetch
                        window.fetch = originalFetch;

                        console.log('[Frame Upload] Upload complete');
                    } catch (error) {
                        console.error('[Frame Upload] Error:', error);
                        window.fetch = originalFetch;
                    }
                })();

                sendResponse({ success: true });
                return true;
            }

            if (msg.type === 'CHECK_MEDIA_IDS') {
                const mediaIds = window.flowFrameUpload?.mediaIds || [];
                console.log(`[Frame Upload] Check media IDs: ${mediaIds.length} found`);
                sendResponse({ mediaIds: mediaIds });
                return true;
            }


            if (msg.type === 'GENERATE_WITH_FRAMES') {
                console.log('[Frame Upload] Starting generation with frames');

                (async () => {
                    // Set prompt
                    const textarea = document.querySelector('textarea');
                    if (textarea) {
                        textarea.value = msg.prompt;
                        textarea.dispatchEvent(new Event('input', { bubbles: true }));
                    }

                    await new Promise(r => setTimeout(r, 500));

                    // Click generate button
                    const buttons = document.querySelectorAll('button');
                    for (const btn of buttons) {
                        if (btn.innerHTML.includes('arrow_forward')) {
                            btn.click();
                            console.log('[Frame Upload] Generate button clicked');
                            break;
                        }
                    }
                })();

                sendResponse({ success: true });
                return true;
            }


            if (msg.type === 'GET_STATUS') {
                sendResponse({ isGenerating: state.isGenerating, generationCount: state.generations.length });
                return;
            }
            sendResponse({ status: 'ok' });
            return true;
        });

        // Expose global API for debugging
        window.flowGenerator = {
            generate: (prompt, opts) => generator.generate({ prompt, ...opts, requestId: utils.generateId() }),
            test: (opts) => generator.testConfiguration(opts),
            createNewProject: () => generator.createNewProject(),
            configureSettings: (opts) => generator.configureSettings(opts),
            getStatus: () => ({ isGenerating: state.isGenerating }),
            selectors: SELECTORS,
            debugDropdowns: () => {
                const all = SELECTORS.getAllComboboxes();
                console.log('[Veo3] Total comboboxes:', all.length);
                all.forEach((btn, i) => {
                    console.log(`[Veo3] Dropdown ${i}:`, btn.textContent.substring(0, 50));
                });
            }
        };

        console.log('[Veo3 Infinity] ✅ Loaded! Test: window.flowGenerator.debugDropdowns()');

        // Also expose via window.postMessage for CDP access (CSP-safe)
        window.addEventListener('message', async (event) => {
            if (event.source !== window) return;

            // Handle VEO3_STATUS - Check if extension is ready
            if (event.data.type === 'VEO3_STATUS') {
                console.log('[Veo3] Status check received');
                window.postMessage({
                    type: 'VEO3_STATUS_RESPONSE',
                    ready: true,
                    version: '1.0.3',
                    requestId: event.data.requestId
                }, '*');
                return;
            }

            // Handle OPEN_SIDEPANEL request from CDP
            if (event.data.type === 'OPEN_SIDEPANEL') {
                console.log('[Veo3] Opening side panel...');
                try {
                    chrome.runtime.sendMessage({ type: 'OPEN_SIDEPANEL' }, (response) => {
                        console.log('[Veo3] Side panel response:', response);
                    });
                } catch (e) {
                    console.error('[Veo3] Failed to open side panel:', e);
                }
                return;
            }

            if (event.data.type === 'VEO3_GENERATE') {
                try {
                    const requestId = event.data.requestId;

                    console.log('[VEO3] Starting generation (network monitoring handled by CDP)');

                    // Start generation - Python will monitor network via CDP
                    const generatePromise = generator.generate({
                        prompt: event.data.prompt,
                        ...event.data.opts,
                        requestId: utils.generateId()
                    });

                    // Wait for generation to complete
                    const result = await generatePromise;

                    // Send final success response
                    window.postMessage({
                        type: 'VEO3_RESPONSE',
                        requestId: requestId,
                        result
                    }, '*');

                } catch (error) {
                    window.postMessage({
                        type: 'VEO3_RESPONSE',
                        requestId: event.data.requestId,
                        error: error.message
                    }, '*');
                }
            } else if (event.data.type === 'VEO3_TEST') {
                try {
                    const result = await generator.testConfiguration(event.data.opts);
                    window.postMessage({
                        type: 'VEO3_RESPONSE',
                        requestId: event.data.requestId,
                        result
                    }, '*');
                } catch (error) {
                    window.postMessage({
                        type: 'VEO3_RESPONSE',
                        requestId: event.data.requestId,
                        error: error.message
                    }, '*');
                }
            }
        });
    })();
}
