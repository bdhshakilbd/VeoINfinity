/**
 * Veo3 Infinity - Background Service Worker
 * Handles side panel and coordinates video generation
 */

// Store for pending generation requests
const pendingRequests = new Map();

// Set side panel behavior on install
chrome.runtime.onInstalled.addListener(() => {
    console.log('[Veo3] Extension installed/updated');
    chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true })
        .then(() => console.log('[Veo3] Side panel behavior set'))
        .catch((err) => console.error('[Veo3] Failed to set panel behavior:', err));
});

// Set side panel behavior on startup
chrome.runtime.onStartup.addListener(() => {
    console.log('[Veo3] Extension started');
    chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true })
        .catch((err) => console.error('[Veo3] Startup panel behavior failed:', err));
});

// Handle action click - open side panel
chrome.action.onClicked.addListener(async (tab) => {
    console.log('[Veo3] Action clicked');
    try {
        await chrome.sidePanel.open({ windowId: tab.windowId });
    } catch (err) {
        console.error('[Veo3] Failed to open side panel:', err);
        try {
            await chrome.sidePanel.open({ tabId: tab.id });
        } catch (err2) {
            console.error('[Veo3] Fallback open failed:', err2);
        }
    }
});

// Initialize panel behavior
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true })
    .catch((err) => console.log('[Veo3] Initial panel behavior:', err.message));

// Listen for OPEN_SIDEPANEL message from content script (for CDP trigger)
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'OPEN_SIDEPANEL') {
        console.log('[Veo3] Opening side panel via message');

        chrome.tabs.query({ active: true, currentWindow: true }, async (tabs) => {
            if (tabs && tabs.length > 0) {
                try {
                    await chrome.sidePanel.open({ windowId: tabs[0].windowId });
                    console.log('[Veo3] Side panel opened!');
                    sendResponse({ success: true });
                } catch (err) {
                    console.error('[Veo3] Failed to open:', err);
                    sendResponse({ success: false, error: err.message });
                }
            }
        });

        return true; // Keep channel open for async response
    }
});

// API for CDP access
const API = {
    async generateVideo(options) {
        const { prompt, aspectRatio = '16:9', model = 'Veo 3.1 - Fast', outputCount = 1 } = options;
        const requestId = 'gen_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);

        return new Promise((resolve, reject) => {
            pendingRequests.set(requestId, { resolve, reject, options });

            chrome.tabs.query({}, (tabs) => {
                const flowTab = tabs.find(t => t.url && t.url.includes('labs.google/fx/tools/flow'));
                if (!flowTab) {
                    reject(new Error('No Flow tab open'));
                    pendingRequests.delete(requestId);
                    return;
                }

                chrome.tabs.sendMessage(flowTab.id, {
                    type: 'GENERATE_VIDEO',
                    requestId,
                    options: { prompt, aspectRatio, model, outputCount }
                }, (response) => {
                    if (chrome.runtime.lastError) {
                        reject(new Error(chrome.runtime.lastError.message));
                        pendingRequests.delete(requestId);
                    }
                });
            });

            setTimeout(() => {
                if (pendingRequests.has(requestId)) {
                    reject(new Error('Timeout after 5 minutes'));
                    pendingRequests.delete(requestId);
                }
            }, 300000);
        });
    },

    async getStatus(requestId) {
        return new Promise((resolve) => {
            chrome.tabs.query({}, (tabs) => {
                const flowTab = tabs.find(t => t.url && t.url.includes('labs.google/fx/tools/flow'));
                if (!flowTab) {
                    resolve({ status: 'error', message: 'No Flow tab' });
                    return;
                }
                chrome.tabs.sendMessage(flowTab.id, { type: 'GET_STATUS', requestId }, resolve);
            });
        });
    },

    async openFlow() {
        return new Promise((resolve) => {
            chrome.tabs.create({ url: 'https://labs.google/fx/tools/flow/' }, (tab) => {
                resolve({ tabId: tab.id });
            });
        });
    },

    // Generate video from frames
    async generateFromFrames(options) {
        const { firstFrame, lastFrame, prompt } = options;

        console.log('[Veo3] generateFromFrames called');

        // Store in chrome.storage for sidepanel to pick up
        await chrome.storage.local.set({
            pendingFrameGeneration: {
                firstFrame,
                lastFrame,
                prompt,
                timestamp: Date.now()
            }
        });

        // Open sidepanel and tell it to process
        return new Promise((resolve, reject) => {
            chrome.tabs.query({ url: '*://labs.google/*' }, async (tabs) => {
                const flowTab = tabs.find(t => t.url && t.url.includes('labs.google/fx/tools/flow'));

                if (flowTab) {
                    try {
                        await chrome.sidePanel.open({ tabId: flowTab.id });
                        // Give sidepanel time to open
                        setTimeout(() => {
                            chrome.runtime.sendMessage({
                                type: 'PROCESS_FRAME_GENERATION'
                            }).catch(() => { });
                            resolve({ status: 'processing', message: 'Frame generation started' });
                        }, 1000);
                    } catch (e) {
                        resolve({ status: 'stored', message: 'Frames stored. Open sidepanel to generate.' });
                    }
                } else {
                    resolve({ status: 'stored', message: 'Frames stored. Open Flow and sidepanel to generate.' });
                }
            });
        });
    }
};

// Message handler
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log('[Veo3] Message:', message.type);

    if (message.type === 'GENERATION_COMPLETE') {
        const req = pendingRequests.get(message.requestId);
        if (req) {
            req.resolve({ status: 'complete', videoUrl: message.videoUrl });
            pendingRequests.delete(message.requestId);
        }
        chrome.runtime.sendMessage(message).catch(() => { });
    } else if (message.type === 'GENERATION_ERROR') {
        const req = pendingRequests.get(message.requestId);
        if (req) {
            req.reject(new Error(message.error));
            pendingRequests.delete(message.requestId);
        }
        chrome.runtime.sendMessage(message).catch(() => { });
    } else if (message.type === 'GENERATION_PROGRESS') {
        chrome.runtime.sendMessage(message).catch(() => { });
    }

    sendResponse({ received: true });
    return true;
});

// External message handler (for CDP)
chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
    console.log('[Veo3] External:', message.action);

    if (message.action === 'generateVideo') {
        API.generateVideo(message.options)
            .then(result => sendResponse({ success: true, result }))
            .catch(err => sendResponse({ success: false, error: err.message }));
        return true;
    } else if (message.action === 'getStatus') {
        API.getStatus(message.requestId)
            .then(result => sendResponse({ success: true, result }))
            .catch(err => sendResponse({ success: false, error: err.message }));
        return true;
    } else if (message.action === 'openFlow') {
        API.openFlow()
            .then(result => sendResponse({ success: true, result }))
            .catch(err => sendResponse({ success: false, error: err.message }));
        return true;
    } else if (message.action === 'generateFromFrames') {
        API.generateFromFrames(message.options)
            .then(result => sendResponse({ success: true, result }))
            .catch(err => sendResponse({ success: false, error: err.message }));
        return true;
    }
});

self.flowGeneratorAPI = API;
console.log('[Veo3] Background service worker loaded');
