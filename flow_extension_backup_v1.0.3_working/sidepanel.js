/**
 * Veo3 Infinity - Side Panel Script
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
        createNew: document.getElementById('createNew')
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

    async function checkStatus() {
        try {
            // Try multiple URL patterns to find Flow tabs
            const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
            let flowTab = null;

            // Check if current tab is a Flow page
            if (tabs.length > 0 && tabs[0].url && tabs[0].url.includes('labs.google/fx/tools/flow')) {
                flowTab = tabs[0];
            }

            // If not, search all tabs for Flow pages
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
                chrome.tabs.sendMessage(flowTab.id, { type: 'PING' }, (response) => {
                    if (chrome.runtime.lastError) {
                        console.log('[Veo3] Content script not responding:', chrome.runtime.lastError.message);
                        setStatus('disconnected', 'Refresh page');
                        return;
                    }
                    console.log('[Veo3] Content script responded:', response);
                    if (response?.pong) {
                        chrome.tabs.sendMessage(flowTab.id, { type: 'GET_STATUS' }, (statusResponse) => {
                            if (chrome.runtime.lastError) {
                                setStatus('disconnected', 'Refresh page');
                                return;
                            }
                            setStatus(statusResponse?.isGenerating ? 'generating' : 'connected',
                                statusResponse?.isGenerating ? 'Generating...' : 'Ready');
                        });
                    } else {
                        setStatus('disconnected', 'Refresh page');
                    }
                });
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

    // Helper function to find a Flow tab
    async function findFlowTab() {
        // First check if current tab is a Flow page
        const activeTabs = await chrome.tabs.query({ active: true, currentWindow: true });
        if (activeTabs.length > 0 && activeTabs[0].url && activeTabs[0].url.includes('labs.google/fx/tools/flow')) {
            return activeTabs[0];
        }
        // Search all tabs for Flow pages
        const allTabs = await chrome.tabs.query({});
        for (const tab of allTabs) {
            if (tab.url && tab.url.includes('labs.google/fx/tools/flow')) {
                return tab;
            }
        }
        return null;
    }

    // TEST button - applies settings without generating
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

    // GENERATE button
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

    checkStatus();
    updateGenerationList();
    setInterval(checkStatus, 3000);
});
