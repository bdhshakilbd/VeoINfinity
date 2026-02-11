/**
 * Flow Video Generator - Popup Script
 * Handles popup UI interactions
 */

document.addEventListener('DOMContentLoaded', () => {
    const elements = {
        statusDot: document.getElementById('statusDot'),
        statusText: document.getElementById('statusText'),
        prompt: document.getElementById('prompt'),
        aspectRatio: document.getElementById('aspectRatio'),
        model: document.getElementById('model'),
        generateBtn: document.getElementById('generateBtn'),
        progressBar: document.getElementById('progressBar'),
        progressFill: document.getElementById('progressFill'),
        openFlowBtn: document.getElementById('openFlowBtn'),
        generationList: document.getElementById('generationList'),
        cdpInfo: document.getElementById('cdpInfo')
    };

    let isGenerating = false;

    // Check connection status
    async function checkStatus() {
        try {
            const tabs = await chrome.tabs.query({ url: 'https://labs.google/fx/tools/flow/*' });

            if (tabs.length > 0) {
                chrome.tabs.sendMessage(tabs[0].id, { type: 'GET_STATUS' }, (response) => {
                    if (chrome.runtime.lastError) {
                        setStatus('disconnected', 'Extension not ready');
                        return;
                    }

                    if (response?.isGenerating) {
                        setStatus('generating', 'Generating video...');
                        isGenerating = true;
                    } else {
                        setStatus('connected', 'Ready to generate');
                        isGenerating = false;
                    }
                });
            } else {
                setStatus('disconnected', 'Open Google Flow first');
            }
        } catch (e) {
            setStatus('disconnected', 'Error checking status');
        }
    }

    function setStatus(state, text) {
        elements.statusDot.className = 'status-dot';
        if (state === 'disconnected') {
            elements.statusDot.classList.add('disconnected');
        } else if (state === 'generating') {
            elements.statusDot.classList.add('generating');
        }
        elements.statusText.textContent = text;
    }

    // Generate video
    async function generateVideo() {
        const prompt = elements.prompt.value.trim();
        if (!prompt) {
            alert('Please enter a prompt');
            return;
        }

        const options = {
            prompt,
            aspectRatio: elements.aspectRatio.value,
            model: elements.model.value,
            outputCount: 1
        };

        try {
            elements.generateBtn.disabled = true;
            elements.progressBar.classList.add('active');
            setStatus('generating', 'Starting generation...');

            const tabs = await chrome.tabs.query({ url: 'https://labs.google/fx/tools/flow/*' });

            if (tabs.length === 0) {
                throw new Error('Please open Google Flow first');
            }

            chrome.tabs.sendMessage(tabs[0].id, {
                type: 'GENERATE_VIDEO',
                requestId: `popup_${Date.now()}`,
                options
            }, (response) => {
                if (chrome.runtime.lastError) {
                    throw new Error(chrome.runtime.lastError.message);
                }
                console.log('Generation started:', response);
            });

            // Poll for completion
            let progress = 0;
            const pollInterval = setInterval(async () => {
                progress = Math.min(95, progress + 5);
                elements.progressFill.style.width = `${progress}%`;
                setStatus('generating', `Generating... ${progress}%`);
            }, 2000);

            // Listen for completion
            chrome.runtime.onMessage.addListener(function listener(message) {
                if (message.type === 'GENERATION_COMPLETE') {
                    clearInterval(pollInterval);
                    elements.progressFill.style.width = '100%';
                    setStatus('connected', 'Generation complete!');
                    elements.generateBtn.disabled = false;

                    setTimeout(() => {
                        elements.progressBar.classList.remove('active');
                        elements.progressFill.style.width = '0%';
                    }, 2000);

                    updateGenerationList();
                    chrome.runtime.onMessage.removeListener(listener);
                } else if (message.type === 'GENERATION_ERROR') {
                    clearInterval(pollInterval);
                    setStatus('disconnected', `Error: ${message.error}`);
                    elements.generateBtn.disabled = false;
                    elements.progressBar.classList.remove('active');
                    chrome.runtime.onMessage.removeListener(listener);
                }
            });

        } catch (error) {
            setStatus('disconnected', error.message);
            elements.generateBtn.disabled = false;
            elements.progressBar.classList.remove('active');
        }
    }

    // Open Google Flow
    function openFlow() {
        chrome.tabs.create({ url: 'https://labs.google/fx/tools/flow/' });
    }

    // Update generation list
    async function updateGenerationList() {
        try {
            const tabs = await chrome.tabs.query({ url: 'https://labs.google/fx/tools/flow/*' });

            if (tabs.length > 0) {
                chrome.tabs.sendMessage(tabs[0].id, { type: 'LIST_GENERATIONS' }, (response) => {
                    if (response?.generations?.length > 0) {
                        elements.generationList.innerHTML = response.generations
                            .slice(-5)
                            .reverse()
                            .map(gen => `
                <div class="generation-item">
                  <div class="prompt">${gen.prompt.substring(0, 50)}${gen.prompt.length > 50 ? '...' : ''}</div>
                  <div class="meta">${new Date(gen.timestamp).toLocaleString()}</div>
                </div>
              `).join('');
                    }
                });
            }
        } catch (e) {
            console.error('Error updating generation list:', e);
        }
    }

    // Show CDP info
    function showCdpInfo() {
        alert(`CDP API Usage:

1. Connect to Chrome with --remote-debugging-port=9222

2. Execute in page context:
   await window.flowGenerator.generate("your prompt")

3. Or use chrome.runtime.sendMessage with extension ID

See documentation for full API reference.`);
    }

    // Event listeners
    elements.generateBtn.addEventListener('click', generateVideo);
    elements.openFlowBtn.addEventListener('click', openFlow);
    elements.cdpInfo.addEventListener('click', (e) => {
        e.preventDefault();
        showCdpInfo();
    });

    // Initial status check
    checkStatus();
    updateGenerationList();

    // Periodic status check
    setInterval(checkStatus, 3000);
});
