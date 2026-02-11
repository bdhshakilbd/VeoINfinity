// ============================================================
// VEO3 COMPLETE MONITORING SCRIPT
// ============================================================
// INSTRUCTIONS:
// 1. Paste this in browser console at https://labs.google/fx/tools/flow
// 2. Manually type your prompt in the textarea
// 3. Click the Create button (arrow_forward)
// 4. After video generation starts, run: window.VEO3Monitor.getReport()
// ============================================================

(function () {
    console.log('🔍 VEO3 Monitor: Initializing...');

    // Storage for all captured data
    window.VEO3Monitor = {
        networkRequests: [],
        clickEvents: [],
        keyboardEvents: [],
        inputEvents: [],
        domChanges: [],
        recaptchaCalls: [],
        startTime: Date.now(),

        // Get full report
        getReport: function () {
            const report = {
                duration: Date.now() - this.startTime,
                networkRequests: this.networkRequests,
                clickEvents: this.clickEvents,
                keyboardEvents: this.keyboardEvents,
                inputEvents: this.inputEvents,
                recaptchaCalls: this.recaptchaCalls,
                summary: {
                    totalNetworkRequests: this.networkRequests.length,
                    totalClicks: this.clickEvents.length,
                    totalKeystrokes: this.keyboardEvents.length,
                    totalInputEvents: this.inputEvents.length,
                    totalRecaptchaCalls: this.recaptchaCalls.length
                }
            };

            console.log('📊 VEO3 Monitor Report:');
            console.log(JSON.stringify(report, null, 2));

            // Also log key requests
            console.log('\n🔑 KEY API REQUESTS:');
            this.networkRequests.forEach((req, i) => {
                if (req.url.includes('googleapis.com')) {
                    console.log(`\n--- Request ${i + 1} ---`);
                    console.log('URL:', req.url);
                    console.log('Method:', req.method);
                    console.log('Headers:', req.headers);
                    console.log('Body:', req.body);
                    console.log('Response Status:', req.responseStatus);
                }
            });

            return report;
        },

        // Clear data
        clear: function () {
            this.networkRequests = [];
            this.clickEvents = [];
            this.keyboardEvents = [];
            this.inputEvents = [];
            this.domChanges = [];
            this.recaptchaCalls = [];
            this.startTime = Date.now();
            console.log('🗑️ VEO3 Monitor: Data cleared');
        }
    };

    // ========== INTERCEPT FETCH ==========
    const originalFetch = window.fetch;
    window.fetch = async function (...args) {
        const [resource, config] = args;
        const url = typeof resource === 'string' ? resource : resource?.url;
        const method = config?.method || 'GET';
        const headers = config?.headers || {};
        const body = config?.body;

        const entry = {
            timestamp: Date.now(),
            timeSinceStart: Date.now() - window.VEO3Monitor.startTime,
            type: 'fetch',
            url: url,
            method: method,
            headers: headers,
            body: typeof body === 'string' ? body : (body ? '[Binary/Complex]' : null),
            responseStatus: null,
            responseBody: null
        };

        if (url && (url.includes('googleapis.com') || url.includes('google.com'))) {
            console.log(`📡 [FETCH] ${method} ${url.substring(0, 80)}...`);
        }

        try {
            const response = await originalFetch.apply(this, args);
            entry.responseStatus = response.status;

            // Clone response to read body without consuming it
            const clone = response.clone();
            try {
                const text = await clone.text();
                entry.responseBody = text.substring(0, 2000); // First 2000 chars
            } catch (e) {
                entry.responseBody = '[Could not read response]';
            }

            window.VEO3Monitor.networkRequests.push(entry);
            return response;
        } catch (error) {
            entry.error = error.message;
            window.VEO3Monitor.networkRequests.push(entry);
            throw error;
        }
    };

    // ========== INTERCEPT XMLHttpRequest ==========
    const originalXHROpen = XMLHttpRequest.prototype.open;
    const originalXHRSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function (method, url) {
        this._monitorData = { method, url, headers: {} };
        return originalXHROpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        if (this._monitorData) {
            this._monitorData.headers[name] = value;
        }
        return XMLHttpRequest.prototype.setRequestHeader.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function (body) {
        if (this._monitorData) {
            const entry = {
                timestamp: Date.now(),
                timeSinceStart: Date.now() - window.VEO3Monitor.startTime,
                type: 'xhr',
                url: this._monitorData.url,
                method: this._monitorData.method,
                headers: this._monitorData.headers,
                body: body
            };

            this.addEventListener('load', function () {
                entry.responseStatus = this.status;
                entry.responseBody = this.responseText?.substring(0, 2000);
                window.VEO3Monitor.networkRequests.push(entry);
            });

            if (this._monitorData.url?.includes('googleapis.com')) {
                console.log(`📡 [XHR] ${this._monitorData.method} ${this._monitorData.url.substring(0, 80)}...`);
            }
        }
        return originalXHRSend.apply(this, arguments);
    };

    // ========== INTERCEPT reCAPTCHA ==========
    if (window.grecaptcha && window.grecaptcha.enterprise) {
        const originalExecute = window.grecaptcha.enterprise.execute;
        window.grecaptcha.enterprise.execute = async function (...args) {
            console.log('🔐 [reCAPTCHA] grecaptcha.enterprise.execute called');
            console.log('   Site Key:', args[0]);
            console.log('   Options:', args[1]);

            const entry = {
                timestamp: Date.now(),
                timeSinceStart: Date.now() - window.VEO3Monitor.startTime,
                siteKey: args[0],
                options: args[1],
                token: null
            };

            try {
                const token = await originalExecute.apply(this, args);
                entry.token = token.substring(0, 50) + '... [truncated]';
                entry.tokenLength = token.length;
                console.log('🔐 [reCAPTCHA] Token received, length:', token.length);
                window.VEO3Monitor.recaptchaCalls.push(entry);
                return token;
            } catch (error) {
                entry.error = error.message;
                window.VEO3Monitor.recaptchaCalls.push(entry);
                throw error;
            }
        };
    }

    // ========== CAPTURE CLICK EVENTS ==========
    document.addEventListener('click', function (e) {
        const target = e.target;
        const entry = {
            timestamp: Date.now(),
            timeSinceStart: Date.now() - window.VEO3Monitor.startTime,
            tagName: target.tagName,
            id: target.id,
            className: target.className,
            textContent: target.textContent?.substring(0, 50),
            x: e.clientX,
            y: e.clientY,
            path: getEventPath(e)
        };

        window.VEO3Monitor.clickEvents.push(entry);

        // Log button clicks
        if (target.tagName === 'BUTTON' || target.closest('button')) {
            console.log(`🖱️ [CLICK] Button clicked:`, target.textContent?.substring(0, 30) || target.id);
        }
    }, true);

    // ========== CAPTURE KEYBOARD EVENTS ==========
    document.addEventListener('keydown', function (e) {
        const entry = {
            timestamp: Date.now(),
            timeSinceStart: Date.now() - window.VEO3Monitor.startTime,
            type: 'keydown',
            key: e.key,
            code: e.code,
            keyCode: e.keyCode,
            ctrlKey: e.ctrlKey,
            shiftKey: e.shiftKey,
            altKey: e.altKey,
            target: {
                tagName: e.target.tagName,
                id: e.target.id
            }
        };

        window.VEO3Monitor.keyboardEvents.push(entry);

        // Log Enter key
        if (e.key === 'Enter') {
            console.log(`⌨️ [ENTER] Enter key pressed`);
        }
    }, true);

    // ========== CAPTURE INPUT EVENTS ==========
    document.addEventListener('input', function (e) {
        const entry = {
            timestamp: Date.now(),
            timeSinceStart: Date.now() - window.VEO3Monitor.startTime,
            tagName: e.target.tagName,
            id: e.target.id,
            value: e.target.value?.substring(0, 100) + (e.target.value?.length > 100 ? '...' : ''),
            valueLength: e.target.value?.length
        };

        window.VEO3Monitor.inputEvents.push(entry);
    }, true);

    // Helper function to get event path
    function getEventPath(e) {
        const path = [];
        let el = e.target;
        for (let i = 0; i < 5 && el; i++) {
            path.push({
                tagName: el.tagName,
                id: el.id,
                className: el.className?.toString().substring(0, 30)
            });
            el = el.parentElement;
        }
        return path;
    }

    console.log('✅ VEO3 Monitor: Ready!');
    console.log('');
    console.log('📋 INSTRUCTIONS:');
    console.log('   1. Type your prompt in the textarea');
    console.log('   2. Click the Create button');
    console.log('   3. Wait for generation to start');
    console.log('   4. Run: window.VEO3Monitor.getReport()');
    console.log('');
    console.log('🛠️ COMMANDS:');
    console.log('   window.VEO3Monitor.getReport() - Get full report');
    console.log('   window.VEO3Monitor.clear() - Clear captured data');
    console.log('   window.VEO3Monitor.networkRequests - View network requests');
    console.log('   window.VEO3Monitor.clickEvents - View click events');
    console.log('   window.VEO3Monitor.keyboardEvents - View keyboard events');
    console.log('');
})();
