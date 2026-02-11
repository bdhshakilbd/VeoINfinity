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
                while (Date.now() - start < 300000) {
                    await utils.sleep(2000);
                    const video = document.querySelector('video[src^="http"], video[src^="blob:"]');
                    if (video && video.src) return { status: 'complete', videoUrl: video.src };
                    const progress = Math.min(95, Math.floor((Date.now() - start) / 60000 * 100));
                    chrome.runtime.sendMessage({ type: 'GENERATION_PROGRESS', requestId, progress }).catch(() => { });
                }
                throw new Error('Timeout');
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
    })();
}
