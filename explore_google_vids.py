#!/usr/bin/env python3
"""
Explore Google Vids (docs.google.com/videos) via CDP
Connect to Chrome on port 9222 and extract API DNA
"""

import asyncio
import websockets
import requests
import json
import time

CDP_PORT = 9222

async def explore_google_vids():
    """Connect to Chrome and explore Google Vids"""
    
    print("=" * 70)
    print("Google Vids API DNA Extraction")
    print("=" * 70)
    
    # Step 1: Connect to Chrome
    print("\n[1] Connecting to Chrome on port 9222...")
    try:
        resp = requests.get(f"http://localhost:{CDP_PORT}/json")
        tabs = resp.json()
    except Exception as e:
        print(f"    ✗ Failed: {e}")
        print(f"    Make sure Chrome is running with --remote-debugging-port={CDP_PORT}")
        return
    
    print(f"    ✓ Found {len(tabs)} tabs")
    
    # Step 2: Create new tab or use existing one
    print("\n[2] Opening Google Vids...")
    
    # Check if Google Vids is already open
    vids_tab = None
    for tab in tabs:
        if 'docs.google.com/videos' in tab.get('url', ''):
            vids_tab = tab
            print(f"    ✓ Found existing Google Vids tab")
            break
    
    if not vids_tab:
        # Create new tab
        try:
            new_tab_resp = requests.put(f"http://localhost:{CDP_PORT}/json/new?https://docs.google.com/videos/")
            vids_tab = new_tab_resp.json()
            print(f"    ✓ Created new tab")
            await asyncio.sleep(3)  # Wait for page to load
        except Exception as e:
            print(f"    ✗ Failed to create tab: {e}")
            return
    
    ws_url = vids_tab['webSocketDebuggerUrl']
    
    # Step 3: Connect via WebSocket
    print("\n[3] Connecting via WebSocket...")
    async with websockets.connect(ws_url) as ws:
        msg_id = 0
        
        async def send_command(method, params=None):
            nonlocal msg_id
            msg_id += 1
            await ws.send(json.dumps({
                'id': msg_id,
                'method': method,
                'params': params or {}
            }))
            while True:
                response = json.loads(await ws.recv())
                if response.get('id') == msg_id:
                    return response.get('result', {})
        
        async def execute_js(code):
            result = await send_command('Runtime.evaluate', {
                'expression': code,
                'returnByValue': True,
                'awaitPromise': True
            })
            if 'result' in result and 'value' in result['result']:
                return result['result']['value']
            return None
        
        print("    ✓ Connected")
        
        # Step 4: Wait for page to load
        print("\n[4] Waiting for page to load...")
        await asyncio.sleep(2)
        
        # Step 5: Extract basic page info
        print("\n[5] Extracting page information...")
        
        page_info = await execute_js('''
        (function() {
            return {
                title: document.title,
                url: window.location.href,
                readyState: document.readyState
            };
        })()
        ''')
        
        if page_info:
            print(f"    Title: {page_info.get('title')}")
            print(f"    URL: {page_info.get('url')}")
            print(f"    Ready State: {page_info.get('readyState')}")
        
        # Step 6: Extract API DNA
        print("\n[6] Extracting API DNA...")
        
        api_dna = await execute_js('''
        (function() {
            const dna = {
                videoAPIs: [],
                vidsAPIs: [],
                veoAPIs: [],
                googleAPIs: [],
                hasRecaptcha: false,
                recaptchaKeys: [],
                buttons: [],
                scripts: [],
                endpoints: []
            };
            
            // Check for video-related APIs in window
            Object.keys(window).forEach(k => {
                if (k.toLowerCase().includes('video')) dna.videoAPIs.push(k);
                if (k.toLowerCase().includes('vids')) dna.vidsAPIs.push(k);
                if (k.toLowerCase().includes('veo')) dna.veoAPIs.push(k);
                if (k.toLowerCase().includes('google')) dna.googleAPIs.push(k);
            });
            
            // Check for grecaptcha
            if (window.grecaptcha) {
                dna.hasRecaptcha = true;
                if (window.grecaptcha.enterprise) {
                    dna.recaptchaKeys.push('enterprise');
                }
            }
            
            // Find all buttons
            const buttons = document.querySelectorAll('button, [role="button"]');
            buttons.forEach(btn => {
                const text = btn.textContent.trim();
                if (text && text.length < 100) {
                    dna.buttons.push(text);
                }
            });
            
            // Check scripts for API endpoints
            const scripts = document.querySelectorAll('script');
            scripts.forEach(s => {
                const src = s.src || '';
                const content = s.textContent || '';
                
                if (src.includes('api') || src.includes('vids')) {
                    dna.scripts.push(src);
                }
                
                // Look for API endpoints in inline scripts
                if (content.includes('googleapis.com')) {
                    const matches = content.match(/https:\/\/[a-z0-9.-]+\.googleapis\.com[^\s"']+/g);
                    if (matches) {
                        matches.forEach(m => {
                            if (!dna.endpoints.includes(m)) {
                                dna.endpoints.push(m);
                            }
                        });
                    }
                }
            });
            
            return dna;
        })()
        ''')
        
        if api_dna:
            print("\n    📊 API DNA Results:")
            print(f"    Video APIs: {api_dna.get('videoAPIs', [])}")
            print(f"    Vids APIs: {api_dna.get('vidsAPIs', [])}")
            print(f"    Veo APIs: {api_dna.get('veoAPIs', [])}")
            print(f"    Google APIs: {len(api_dna.get('googleAPIs', []))} found")
            print(f"    Has reCAPTCHA: {api_dna.get('hasRecaptcha')}")
            print(f"    Buttons: {len(api_dna.get('buttons', []))} found")
            
            buttons = api_dna.get('buttons', [])
            if buttons:
                print("\n    🔘 Key Buttons:")
                for btn in buttons[:10]:  # Show first 10
                    print(f"       - {btn[:60]}")
            
            endpoints = api_dna.get('endpoints', [])
            if endpoints:
                print("\n    🌐 API Endpoints Found:")
                for ep in endpoints[:10]:  # Show first 10
                    print(f"       - {ep}")
        
        # Step 7: Look for video generation elements
        print("\n[7] Looking for video generation elements...")
        
        generation_info = await execute_js('''
        (function() {
            const info = {
                hasCreateButton: false,
                hasPromptInput: false,
                hasVideoPlayer: false,
                createButtons: [],
                inputFields: []
            };
            
            // Look for create/generate buttons
            const buttons = document.querySelectorAll('button, [role="button"]');
            buttons.forEach(btn => {
                const text = btn.textContent.toLowerCase();
                if (text.includes('create') || text.includes('new') || text.includes('generate')) {
                    info.hasCreateButton = true;
                    info.createButtons.push(btn.textContent.trim());
                }
            });
            
            // Look for input fields
            const inputs = document.querySelectorAll('input, textarea');
            inputs.forEach(inp => {
                const placeholder = inp.placeholder || '';
                const id = inp.id || '';
                if (placeholder || id) {
                    info.hasPromptInput = true;
                    info.inputFields.push({
                        type: inp.tagName,
                        id: id,
                        placeholder: placeholder.substring(0, 50)
                    });
                }
            });
            
            // Look for video elements
            const videos = document.querySelectorAll('video');
            info.hasVideoPlayer = videos.length > 0;
            
            return info;
        })()
        ''')
        
        if generation_info:
            print(f"    Has Create Button: {generation_info.get('hasCreateButton')}")
            print(f"    Has Prompt Input: {generation_info.get('hasPromptInput')}")
            print(f"    Has Video Player: {generation_info.get('hasVideoPlayer')}")
            
            create_btns = generation_info.get('createButtons', [])
            if create_btns:
                print("\n    🎬 Create/Generate Buttons:")
                for btn in create_btns[:5]:
                    print(f"       - {btn[:60]}")
            
            inputs = generation_info.get('inputFields', [])
            if inputs:
                print("\n    📝 Input Fields:")
                for inp in inputs[:5]:
                    print(f"       - {inp.get('type')}: {inp.get('id')} - {inp.get('placeholder')}")
        
        # Step 8: Check if this is the same as VideoFX
        print("\n[8] Comparing with VideoFX...")
        
        comparison = await execute_js('''
        (function() {
            const comp = {
                isVideoFX: window.location.href.includes('labs.google'),
                isGoogleVids: window.location.href.includes('docs.google.com/videos'),
                hasPinholeTextArea: !!document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID'),
                hasVeo3References: false
            };
            
            // Check for Veo 3 references in page text
            const bodyText = document.body.textContent.toLowerCase();
            comp.hasVeo3References = bodyText.includes('veo 3') || bodyText.includes('veo3');
            
            return comp;
        })()
        ''')
        
        if comparison:
            print(f"    Is VideoFX (labs.google): {comparison.get('isVideoFX')}")
            print(f"    Is Google Vids: {comparison.get('isGoogleVids')}")
            print(f"    Has Pinhole TextArea: {comparison.get('hasPinholeTextArea')}")
            print(f"    Has Veo 3 References: {comparison.get('hasVeo3References')}")
        
        # Step 9: Save full report
        print("\n[9] Saving full report...")
        
        report = {
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
            'page_info': page_info,
            'api_dna': api_dna,
            'generation_info': generation_info,
            'comparison': comparison
        }
        
        with open('google_vids_dna_report.json', 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2)
        
        print("    ✓ Report saved to: google_vids_dna_report.json")
        
        print("\n" + "=" * 70)
        print("✓ Extraction Complete!")
        print("=" * 70)

if __name__ == '__main__':
    print("""
╔══════════════════════════════════════════════════════════════════╗
║              Google Vids API DNA Extractor                       ║
║                                                                  ║
║  This script connects to Chrome on port 9222 and analyzes       ║
║  the Google Vids page to understand how video generation works  ║
╚══════════════════════════════════════════════════════════════════╝
    """)
    
    asyncio.run(explore_google_vids())
