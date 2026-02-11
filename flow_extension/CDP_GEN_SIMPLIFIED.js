// CDP GENERATION - Use content script to avoid extension headers
async function cdpGenerate() {
    const options = getOptions();
    if (!options.prompt) {
        showResult('Enter a prompt first', true);
        return;
    }

    console.log('[CDP] Starting CDP generation via content script');
    const cdpBtn = document.getElementById('cdpGenBtn');
    cdpBtn.disabled = true;
    cdpBtn.textContent = '⏳ CDP Generating...';
    elements.progressContainer.classList.add('active');
    elements.progressFill.style.width = '0%';
    setStatus('generating', 'CDP Gen...');

    try {
        const flowTab = await findFlowTab();
        if (!flowTab) throw new Error('Open Google Flow first');

        // Send CDP_GENERATE message to content script
        chrome.tabs.sendMessage(flowTab.id, {
            type: 'CDP_GENERATE',
            options: options
        }, (response) => {
            cdpBtn.disabled = false;
            cdpBtn.textContent = '⚡ Test CDP Gen';
            elements.progressContainer.classList.remove('active');

            if (chrome.runtime.lastError) {
                console.error('[CDP] Error:', chrome.runtime.lastError);
                showResult('CDP Error: ' + chrome.runtime.lastError.message, true);
                setStatus('disconnected', 'Error');
                return;
            }

            if (response && response.success) {
                console.log('[CDP] Success! Scene ID:', response.sceneId);
                showResult(`✅ CDP Gen Success! Scene: ${response.sceneId.substring(0, 8)}...`);
                setStatus('connected', 'CDP Success');
            } else {
                console.error('[CDP] Failed:', response);
                showResult(`❌ CDP Error: ${response?.error || response?.statusText || 'Unknown'}`, true);
                setStatus('disconnected', 'CDP Failed');
            }
        });

    } catch (error) {
        console.error('[CDP] Exception:', error);
        cdpBtn.disabled = false;
        cdpBtn.textContent = '⚡ Test CDP Gen';
        elements.progressContainer.classList.remove('active');
        showResult('CDP Error: ' + error.message, true);
        setStatus('disconnected', 'Error');
    }
}

//REPLACE THE cdpGenerate function in sidepanel.js with this simpler version
