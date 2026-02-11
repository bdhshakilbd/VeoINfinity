/**
 * Veo3 Infinity - Side Panel Script with Frame-to-Video
 */

document.addEventListener('DOMContentLoaded', () => {
    const elements = {
        statusDot: document.getElementById('statusDot'),
        statusText: document.getElementById('statusText'),
        prompt: document.getElementById('prompt'),
        aspectRatio: document.getElementById('aspectRatio'),
        model: document.getElementById('model'),
        outputCount: document.getElementById('outputCount'),
        mode: document.getElementById('mode'),
        generateBtn: document.getElementById('generateBtn'),
        testBtn: document.getElementById('testBtn'),
        progressContainer: document.getElementById('progressContainer'),
        progressFill: document.getElementById('progressFill'),
        progressText: document.getElementById('progressText'),
        resultBox: document.getElementById('resultBox'),
        openFlowBtn: document.getElementById('openFlowBtn'),
        generationList: document.getElementById('generationList'),
        useExisting: document.getElementById('useExisting'),
        createNew: document.getElementById('createNew'),
        firstFrame: document.getElementById('firstFrame'),
        lastFrame: document.getElementById('lastFrame'),
        testFrameUploadBtn: document.getElementById('testFrameUploadBtn')
    };

    let projectMode = 'existing';

    // Toggle handlers
    elements.useExisting.addEventListener('click', () => {
        projectMode = 'existing';
        elements.useExisting.classList.add('active');
        elements.createNew.classList.remove('active');
    });

    elements.createNew.addEventListener('click', () => {
        projectMode = 'new';
        elements.createNew.classList.add('active');
        elements.useExisting.classList.remove('active');
    });

    // Show/hide frame upload section based on mode
    function updateFrameUploadVisibility() {
        const frameSection = document.querySelector('.frame-upload-section');
        if (frameSection) {
            if (elements.mode.value === 'Frames to Video') {
                frameSection.style.display = 'block';
            } else {
                frameSection.style.display = 'none';
            }
        }
    }

    // Listen for mode changes
    elements.mode.addEventListener('change', updateFrameUploadVisibility);

    // Set initial visibility
    updateFrameUploadVisibility();

    // Listen for external frame generation requests
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (message.type === 'PROCESS_FRAME_GENERATION') {
            console.log('[Veo3] Processing external frame generation request');
            processPendingFrameGeneration();
            sendResponse({ received: true });
        }
        return true;
    });

    // Check for pending frame generation on load
    async function processPendingFrameGeneration() {
        try {
            const data = await chrome.storage.local.get('pendingFrameGeneration');
            if (data.pendingFrameGeneration) {
                const pending = data.pendingFrameGeneration;
                console.log('[Veo3] Found pending frame generation:', pending.prompt?.substring(0, 50));

                // Store frames
                storedFrames.first = pending.firstFrame;
                storedFrames.last = pending.lastFrame;

                // Set prompt
                if (pending.prompt) {
                    elements.prompt.value = pending.prompt;
                }

                // Set mode to Frames to Video
                elements.mode.value = 'Frames to Video';
                updateFrameUploadVisibility();

                // Clear pending
                await chrome.storage.local.remove('pendingFrameGeneration');

                // Trigger upload
                console.log('[Veo3] Auto-triggering frame upload...');
                setTimeout(() => {
                    elements.testFrameUploadBtn?.click();
                }, 1000);
            }
        } catch (e) {
            console.error('[Veo3] Error processing pending frames:', e);
        }
    }

    // Check on load
    setTimeout(processPendingFrameGeneration, 500);

    async function checkStatus() {
        try {
            const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
            let flowTab = null;

            if (tabs.length > 0 && tabs[0].url && tabs[0].url.includes('labs.google/fx/tools/flow')) {
                flowTab = tabs[0];
            }

            if (!flowTab) {
                const allTabs = await chrome.tabs.query({});
                for (const tab of allTabs) {
                    if (tab.url && tab.url.includes('labs.google/fx/tools/flow')) {
                        flowTab = tab;
                        break;
                    }
                }
            }

            if (flowTab) {
                console.log('[Veo3] Found Flow tab:', flowTab.id, flowTab.url);
                setStatus('connected', 'Ready');
            } else {
                console.log('[Veo3] No Flow tab found');
                setStatus('disconnected', 'Open Flow');
            }
        } catch (e) {
            console.error('[Veo3] checkStatus error:', e);
            setStatus('disconnected', 'Error');
        }
    }

    function setStatus(state, text) {
        elements.statusDot.className = 'status-dot';
        if (state === 'disconnected') elements.statusDot.classList.add('disconnected');
        else if (state === 'generating') elements.statusDot.classList.add('generating');
        elements.statusText.textContent = text;
    }

    function getOptions() {
        return {
            prompt: elements.prompt.value.trim(),
            aspectRatio: elements.aspectRatio.value,
            model: elements.model.value,
            outputCount: parseInt(elements.outputCount.value) || 1,
            mode: elements.mode.value,
            createNewProject: projectMode === 'new'
        };
    }

    function showResult(message, isError = false) {
        elements.resultBox.textContent = message;
        elements.resultBox.className = 'result-box active' + (isError ? ' error' : '');
        setTimeout(() => {
            elements.resultBox.classList.remove('active');
        }, 5000);
    }

    async function findFlowTab() {
        const activeTabs = await chrome.tabs.query({ active: true, currentWindow: true });
        if (activeTabs.length > 0 && activeTabs[0].url && activeTabs[0].url.includes('labs.google/fx/tools/flow')) {
            return activeTabs[0];
        }
        const allTabs = await chrome.tabs.query({});
        for (const tab of allTabs) {
            if (tab.url && tab.url.includes('labs.google/fx/tools/flow')) {
                return tab;
            }
        }
        return null;
    }

    async function testSettings() {
        const options = getOptions();
        if (!options.prompt) options.prompt = 'TEST - Sample prompt for testing';

        console.log('[Veo3] Testing settings:', options);
        elements.testBtn.disabled = true;
        elements.testBtn.textContent = '🔄 Testing...';
        setStatus('generating', 'Testing...');

        try {
            const flowTab = await findFlowTab();
            if (!flowTab) throw new Error('Open Google Flow first');

            // Set zoom to 50% for better visibility
            await chrome.tabs.setZoom(flowTab.id, 0.5);

            chrome.tabs.sendMessage(flowTab.id, {
                type: 'TEST_SETTINGS',
                options: { ...options, testOnly: true }
            }, (response) => {
                elements.testBtn.disabled = false;
                elements.testBtn.textContent = '🧪 Test Settings';

                if (chrome.runtime.lastError) {
                    showResult('Error: ' + chrome.runtime.lastError.message, true);
                    setStatus('disconnected', 'Error');
                    return;
                }

                if (response?.status === 'test_complete') {
                    showResult('✅ Test complete! Settings applied, ready to generate.');
                    setStatus('connected', 'Test OK');
                } else {
                    showResult('⚠️ Test: ' + (response?.error || 'Unknown result'), true);
                    setStatus('disconnected', 'Test failed');
                }
            });

        } catch (error) {
            elements.testBtn.disabled = false;
            elements.testBtn.textContent = '🧪 Test Settings';
            showResult('Error: ' + error.message, true);
            setStatus('disconnected', 'Error');
        }
    }

    async function generateVideo() {
        const options = getOptions();
        if (!options.prompt) {
            showResult('Enter a prompt first', true);
            return;
        }

        console.log('[Veo3] Generating:', options);

        try {
            elements.generateBtn.disabled = true;
            elements.progressContainer.classList.add('active');
            elements.progressFill.style.width = '0%';
            elements.progressText.textContent = 'Starting...';
            setStatus('generating', 'Starting...');

            const flowTab = await findFlowTab();
            if (!flowTab) throw new Error('Open Google Flow first');

            // Set zoom to 50% for better visibility
            await chrome.tabs.setZoom(flowTab.id, 0.5);

            const requestId = `panel_${Date.now()}`;

            chrome.tabs.sendMessage(flowTab.id, {
                type: 'GENERATE_VIDEO',
                requestId,
                options
            }, (response) => {
                if (chrome.runtime.lastError) {
                    handleError(chrome.runtime.lastError.message);
                }
            });

            let progress = 0;
            window.progressInterval = setInterval(() => {
                progress = Math.min(95, progress + Math.random() * 8);
                elements.progressFill.style.width = `${progress}%`;
                elements.progressText.textContent = `${Math.round(progress)}%`;
            }, 2000);

        } catch (error) {
            handleError(error.message);
        }
    }

    function handleError(msg) {
        clearInterval(window.progressInterval);
        setStatus('disconnected', 'Error');
        showResult('Error: ' + msg, true);
        elements.generateBtn.disabled = false;
        elements.progressContainer.classList.remove('active');
    }

    function handleComplete(result) {
        clearInterval(window.progressInterval);
        elements.progressFill.style.width = '100%';
        elements.progressText.textContent = 'Done!';
        setStatus('connected', 'Complete!');
        showResult('✅ Video generated successfully!');
        elements.generateBtn.disabled = false;
        setTimeout(() => elements.progressContainer.classList.remove('active'), 2000);

        chrome.storage.local.get(['generations'], (r) => {
            const gens = r.generations || [];
            gens.unshift({ prompt: elements.prompt.value, model: elements.model.value, status: 'success', timestamp: new Date().toISOString() });
            if (gens.length > 20) gens.pop();
            chrome.storage.local.set({ generations: gens });
            updateGenerationList();
        });
    }

    function updateGenerationList() {
        chrome.storage.local.get(['generations'], (result) => {
            const gens = result.generations || [];
            if (gens.length > 0) {
                elements.generationList.innerHTML = gens.slice(0, 5).map(g => `
          <div class="generation-item">
            <div class="prompt">${escapeHtml(g.prompt?.substring(0, 35) || '?')}...</div>
          </div>
        `).join('');
            }
        });
    }

    function escapeHtml(t) {
        const d = document.createElement('div');
        d.textContent = t;
        return d.innerHTML;
    }

    // Frame-to-Video Generation
    let storedFrames = { first: null, last: null };

    // Store frames as base64 when selected
    elements.firstFrame.addEventListener('change', async (e) => {
        if (e.target.files[0]) {
            storedFrames.first = await fileToDataUrl(e.target.files[0]);
            console.log('[Frame] First frame stored');
        }
    });

    elements.lastFrame.addEventListener('change', async (e) => {
        if (e.target.files[0]) {
            storedFrames.last = await fileToDataUrl(e.target.files[0]);
            console.log('[Frame] Last frame stored');
        }
    });

    async function testFrameUpload() {
        const prompt = elements.prompt.value.trim();

        if (!storedFrames.first && !storedFrames.last) {
            showResult('Please select at least one frame', true);
            return;
        }

        if (!prompt) {
            showResult('Please enter a prompt', true);
            return;
        }

        console.log('[Frame Upload] Starting frame upload and generation');
        elements.testFrameUploadBtn.disabled = true;
        elements.testFrameUploadBtn.textContent = '⏳ Setting Mode...';
        elements.progressContainer.classList.add('active');
        elements.progressFill.style.width = '0%';
        setStatus('generating', 'Preparing...');

        try {
            const flowTab = await findFlowTab();
            if (!flowTab) throw new Error('Open Google Flow first');

            // Set zoom to 50% for better visibility
            console.log('[Frame Upload] Setting zoom to 50%...');
            await chrome.tabs.setZoom(flowTab.id, 0.5);
            await new Promise(r => setTimeout(r, 500));

            // First, apply settings to switch to "Frames to Video" mode
            console.log('[Frame Upload] Step 1: Switching to Frames to Video mode...');
            elements.testFrameUploadBtn.textContent = '⏳ Switching Mode...';

            const options = getOptions();
            options.mode = 'Frames to Video'; // Exact text from dropdown

            await new Promise((resolve, reject) => {
                chrome.tabs.sendMessage(flowTab.id, {
                    type: 'TEST_SETTINGS',
                    options: { ...options, testOnly: true }
                }, (response) => {
                    if (chrome.runtime.lastError) {
                        reject(new Error('Failed to apply settings: ' + chrome.runtime.lastError.message));
                        return;
                    }
                    if (response?.status === 'test_complete') {
                        console.log('[Frame Upload] ✅ Mode switched to Frames to Video');
                        resolve();
                    } else {
                        reject(new Error('Settings application failed'));
                    }
                });
            });

            // Wait for UI to update
            await new Promise(r => setTimeout(r, 3000));

            const framesToUpload = [];
            if (storedFrames.first) framesToUpload.push({ data: storedFrames.first, name: 'First Frame' });
            if (storedFrames.last) framesToUpload.push({ data: storedFrames.last, name: 'Last Frame' });

            console.log(`[Frame Upload] Step 2: Uploading ${framesToUpload.length} frame(s)`);
            elements.testFrameUploadBtn.textContent = '⏳ Uploading Frames...';

            // Inject upload and generation script
            await chrome.scripting.executeScript({
                target: { tabId: flowTab.id },
                world: 'MAIN',
                args: [framesToUpload, prompt],
                func: async (frames, promptText) => {
                    console.log(`🎞️ Frame Upload & Generate - ${frames.length} frame(s)`);

                    // Track uploaded media IDs
                    const uploadedMedia = [];
                    const originalFetch = window.fetch;

                    // Intercept fetch to monitor uploads
                    window.fetch = async function (...args) {
                        const response = await originalFetch.apply(this, args);
                        const url = args[0];

                        if (url && url.toString().includes('uploadUserImage')) {
                            try {
                                const clonedResponse = response.clone();
                                const data = await clonedResponse.json();

                                if (data.mediaGenerationId) {
                                    uploadedMedia.push({
                                        id: data.mediaGenerationId.mediaGenerationId,
                                        width: data.width,
                                        height: data.height
                                    });
                                    console.log('📡 UPLOAD DETECTED:');
                                    console.log(`   Media ID: ${data.mediaGenerationId.mediaGenerationId.substring(0, 50)}...`);
                                    console.log(`   Total uploads: ${uploadedMedia.length}/${frames.length}`);
                                }
                            } catch (e) { }
                        }

                        return response;
                    };

                    async function base64ToFile(base64, filename) {
                        const response = await originalFetch(base64);
                        const blob = await response.blob();
                        return new File([blob], filename, { type: 'image/png' });
                    }

                    async function uploadToButton(button, file, label) {
                        console.log(`📸 Uploading ${label}: ${file.name}`);

                        button.click();
                        await new Promise(r => setTimeout(r, 1000));

                        const fileInput = document.querySelector('input[type="file"]');
                        if (fileInput) {
                            const dataTransfer = new DataTransfer();
                            dataTransfer.items.add(file);
                            fileInput.files = dataTransfer.files;
                            fileInput.dispatchEvent(new Event('change', { bubbles: true }));
                            fileInput.dispatchEvent(new Event('input', { bubbles: true }));
                            console.log('   📤 File set on input');

                            await new Promise(r => setTimeout(r, 1500));

                            const buttons = Array.from(document.querySelectorAll('button'));
                            for (const btn of buttons) {
                                if (btn.textContent.includes('Crop and Save')) {
                                    console.log('   ✂️  Clicking Crop and Save...');
                                    btn.click();
                                    await new Promise(r => setTimeout(r, 3000));
                                    return true;
                                }
                            }
                        }
                        return false;
                    }

                    try {
                        // Find frame buttons
                        console.log('[1/4] Finding frame buttons...');
                        let frameButtons = [];
                        let attempts = 0;

                        while (frameButtons.length < 2 && attempts < 10) {
                            frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));
                            console.log(`   Attempt ${attempts + 1}: Found ${frameButtons.length} buttons`);

                            if (frameButtons.length < 2) {
                                await new Promise(r => setTimeout(r, 500));
                                attempts++;
                            }
                        }

                        if (frameButtons.length < frames.length) {
                            throw new Error(`Need ${frames.length} button(s), found ${frameButtons.length}`);
                        }

                        console.log(`✅ Found ${frameButtons.length} frame buttons`);

                        // Upload each frame
                        console.log('[2/4] Uploading frames...');
                        for (let i = 0; i < frames.length; i++) {
                            const file = await base64ToFile(frames[i].data, `frame_${i + 1}.png`);
                            console.log(`   [${i + 1}/${frames.length}] Uploading ${frames[i].name}...`);
                            await uploadToButton(frameButtons[i], file, frames[i].name);
                            await new Promise(r => setTimeout(r, 2000));
                        }

                        // Wait for all uploads to complete
                        console.log('[3/4] Verifying uploads...');
                        console.log(`   Waiting for ${frames.length} upload(s) to complete...`);

                        let waitAttempts = 0;
                        while (uploadedMedia.length < frames.length && waitAttempts < 20) {
                            console.log(`   Upload status: ${uploadedMedia.length}/${frames.length} (attempt ${waitAttempts + 1}/20)`);
                            await new Promise(r => setTimeout(r, 1000));
                            waitAttempts++;
                        }

                        if (uploadedMedia.length < frames.length) {
                            console.warn(`   ⚠️  Only ${uploadedMedia.length}/${frames.length} uploads detected`);
                        } else {
                            console.log('   ✅ All frames uploaded successfully!');
                            uploadedMedia.forEach((m, i) => {
                                console.log(`   ${i + 1}. ${m.id.substring(0, 60)}...`);
                            });
                        }

                        // Wait 5 seconds before setting prompt
                        console.log('   ⏳ Waiting 5 seconds...');
                        await new Promise(r => setTimeout(r, 5000));

                        // Set prompt and generate
                        console.log('[4/4] Setting prompt and generating video...');
                        const textarea = document.querySelector('textarea');
                        if (textarea) {
                            textarea.value = promptText;
                            textarea.dispatchEvent(new Event('input', { bubbles: true }));
                            console.log('   ✅ Prompt set:', promptText.substring(0, 50) + '...');
                        }

                        // Wait 1 second
                        console.log('   ⏳ Waiting 1 second before clicking generate...');
                        await new Promise(r => setTimeout(r, 1000));

                        // Click generate button
                        const buttons = document.querySelectorAll('button');
                        for (const btn of buttons) {
                            if (btn.innerHTML.includes('arrow_forward')) {
                                btn.click();
                                console.log('   ✅ Generate button clicked!');
                                break;
                            }
                        }

                        console.log('✅ PROCESS COMPLETE!');
                        console.log('📹 Video generation should start shortly...');

                        // Store for later use
                        window.flowUploadedMedia = uploadedMedia;

                    } catch (error) {
                        console.error('❌ ERROR:', error.message);
                    } finally {
                        // Restore original fetch
                        window.fetch = originalFetch;
                    }
                }
            });

            elements.testFrameUploadBtn.disabled = false;
            elements.testFrameUploadBtn.textContent = '🎞️ Upload Frames & Generate';
            elements.progressFill.style.width = '100%';
            showResult(`✅ Frames uploaded and generation started!`);
            setStatus('connected', 'Generating');
            setTimeout(() => elements.progressContainer.classList.remove('active'), 3000);

        } catch (error) {
            console.error('[Frame Upload] Error:', error);
            elements.testFrameUploadBtn.disabled = false;
            elements.testFrameUploadBtn.textContent = '🎞️ Upload Frames & Generate';
            elements.progressContainer.classList.remove('active');
            showResult('Error: ' + error.message, true);
            setStatus('disconnected', 'Error');
        }
    }

    function fileToDataUrl(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = reject;
            reader.readAsDataURL(file);
        });
    }

    // Listeners
    chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
        if (msg.type === 'GENERATION_COMPLETE') handleComplete(msg);
        else if (msg.type === 'GENERATION_ERROR') handleError(msg.error);
        else if (msg.type === 'GENERATION_PROGRESS') {
            elements.progressFill.style.width = `${msg.progress}%`;
            elements.progressText.textContent = `${msg.progress}%`;
        }
        sendResponse({ ok: true });
        return true;
    });

    elements.generateBtn.addEventListener('click', generateVideo);
    elements.testBtn.addEventListener('click', testSettings);
    elements.openFlowBtn.addEventListener('click', () => {
        chrome.tabs.create({ url: 'https://labs.google/fx/tools/flow/' });
    });
    elements.testFrameUploadBtn.addEventListener('click', testFrameUpload);

    checkStatus();
    updateGenerationList();
    setInterval(checkStatus, 3000);
});
