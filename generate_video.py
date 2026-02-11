"""
VEO3 Video Generator - Direct React Handler Invocation
Uses React properties to trigger generation without UI interaction
Usage: python generate_video.py "Your prompt here"
"""

import sys
import time
import json
import requests
from pychrome import Browser
import os


def ensure_project_open(tab):
    """Check if on homepage and create new project"""
    js_code = """
    (async () => {
        const buttons = [...document.querySelectorAll('button')];
        const newProjBtn = buttons.find(b => b.textContent.includes('New project'));
        
        if (newProjBtn) {
            newProjBtn.click();
            await new Promise(r => setTimeout(r, 3000));
            return {wasHomepage: true};
        }
        return {wasHomepage: false, hasProject: true};
    })();
    """
    
    try:
        result = tab.call_method('Runtime.evaluate',
                                expression=js_code,
                                awaitPromise=True,
                                returnByValue=True,
                                timeout=10000)
        return result.get('result', {}).get('value', {})
    except:
        return {}



def setup_network_monitor(tab):
    """Inject JavaScript to monitor fetch responses"""
    
    js_code = """
    (() => {
        window.__veo3_monitor = {
            startTime: Date.now(),
            operationName: null,
            videoUrl: null,
            status: 'idle',
            credits: null,
            lastUpdate: null,
            error: null,
            apiError: null
        };
        
        const originalFetch = window.fetch;
        window.fetch = async function(...args) {
            const response = await originalFetch.apply(this, args);
            const url = args[0]?.toString() || '';
            
            if (url.includes('batchAsyncGenerateVideoText') || 
                url.includes('batchAsyncGenerateVideoStartImage') ||
                url.includes('batchAsyncGenerateVideoStartAndEndImage')) {
                try {
                    const clone = response.clone();
                    const data = await clone.json();
                    
                    if (response.status === 200 && data.operations && data.operations.length > 0) {
                        const op = data.operations[0];
                        window.__veo3_monitor.operationName = op.operation?.name;
                        window.__veo3_monitor.credits = data.remainingCredits;
                        
                        // Initial response is PENDING, which means generation started
                        if (op.status === 'MEDIA_GENERATION_STATUS_PENDING') {
                            window.__veo3_monitor.status = 'pending';
                        } else {
                            window.__veo3_monitor.status = 'started';
                        }
                        
                        window.__veo3_monitor.lastUpdate = Date.now();
                        console.log('[Monitor] Started:', window.__veo3_monitor.operationName);
                        console.log('[Monitor] Initial status:', op.status);
                    } else if (response.status === 403) {
                        window.__veo3_monitor.status = 'auth_error';
                        window.__veo3_monitor.apiError = '403 Forbidden';
                    } else {
                        window.__veo3_monitor.status = 'api_error';
                        window.__veo3_monitor.apiError = `HTTP ${response.status}`;
                    }
                } catch (e) {
                    console.error('[Monitor] Parse error:', e);
                }
            }
            
            if (url.includes('batchCheckAsyncVideoGenerationStatus')) {
                try {
                    const clone = response.clone();
                    const data = await clone.json();
                    
                    if (data.operations && data.operations.length > 0) {
                        const op = data.operations[0];
                        const opName = op.operation?.name;
                        const status = op.status;
                        
                        if (window.__veo3_monitor.operationName && opName !== window.__veo3_monitor.operationName) {
                            return response;
                        }
                        
                        window.__veo3_monitor.lastUpdate = Date.now();
                        
                        if (status === 'MEDIA_GENERATION_STATUS_PENDING') {
                            window.__veo3_monitor.status = 'pending';
                        } else if (status === 'MEDIA_GENERATION_STATUS_ACTIVE') {
                            window.__veo3_monitor.status = 'active';
                        } else if (status === 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
                            const videoUrl = op.operation?.metadata?.video?.fifeUrl;
                            if (videoUrl) {
                                window.__veo3_monitor.videoUrl = videoUrl;
                                window.__veo3_monitor.status = 'complete';
                            }
                        } else if (status.includes('FAIL') || status.includes('ERROR')) {
                            window.__veo3_monitor.status = 'failed';
                            window.__veo3_monitor.error = status;
                        }
                    }
                } catch (e) {
                    console.error('[Monitor] Status error:', e);
                }
            }
            
            return response;
        };
        
        console.log('[Monitor] Installed');
        return {success: true};
    })();
    """
    
    try:
        result = tab.call_method('Runtime.evaluate',
                                expression=js_code,
                                returnByValue=True,
                                timeout=5000)
        return result.get('result', {}).get('value', {})
    except Exception as e:
        return {'success': False, 'error': str(e)}


def trigger_generation(tab, prompt):
    """Trigger generation using React handlers to update state properly"""
    js_code = f"""
    (async () => {{
        const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
        if (!textarea) {{
            return {{success: false, error: 'Textarea not found'}};
        }}
        
        // Get React props for textarea
        const textareaPropsKey = Object.keys(textarea).find(key => key.startsWith('__reactProps$'));
        if (!textareaPropsKey) {{
            return {{success: false, error: 'React props not found on textarea'}};
        }}
        
        const textareaProps = textarea[textareaPropsKey];
        
        // Set the value
        textarea.value = {json.dumps(prompt)};
        
        // Call React onChange handler to update state
        if (textareaProps.onChange) {{
            textareaProps.onChange({{
                target: textarea,
                currentTarget: textarea,
                nativeEvent: new Event('change')
            }});
        }}
        
        // Also dispatch standard events as backup
        textarea.dispatchEvent(new Event('input', {{bubbles: true}}));
        textarea.dispatchEvent(new Event('change', {{bubbles: true}}));
        
        // Wait for React to update
        await new Promise(r => setTimeout(r, 1000));
        
        // Find the Create button
        const buttons = Array.from(document.querySelectorAll('button'));
        const createButton = buttons.find(b => b.innerText.includes('Create') || b.innerHTML.includes('arrow_forward'));
        
        if (!createButton) {{
            return {{success: false, error: 'Create button not found'}};
        }}
        
        // Check if button is still disabled
        if (createButton.disabled) {{
            return {{success: false, error: 'Button still disabled - prompt may not have been set'}};
        }}
        
        // Find React props key for button
        const reactPropsKey = Object.keys(createButton).find(key => key.startsWith('__reactProps$'));
        if (!reactPropsKey) {{
            return {{success: false, error: 'React props key not found on button'}};
        }}
        
        const props = createButton[reactPropsKey];
        if (!props || !props.onClick) {{
            return {{success: false, error: 'onClick handler not found'}};
        }}
        
        // Call the React onClick handler directly
        try {{
            props.onClick({{
                preventDefault: () => {{}},
                stopPropagation: () => {{}},
                nativeEvent: new MouseEvent('click', {{bubbles: true, cancelable: true}})
            }});
            return {{success: true, method: 'react_handler', promptSet: true}};
        }} catch (e) {{
            return {{success: false, error: e.message}};
        }}
    }})();
    """
    
    try:
        result = tab.call_method('Runtime.evaluate',
                                expression=js_code,
                                awaitPromise=True,
                                returnByValue=True,
                                timeout=15000)
        return result.get('result', {}).get('value', {})
    except Exception as e:
        return {'success': False, 'error': str(e)}


def get_monitor_state(tab):
    """Get monitor state"""
    js_code = "(() => { return window.__veo3_monitor || {status: 'not_initialized'}; })();"
    
    try:
        result = tab.call_method('Runtime.evaluate',
                                expression=js_code,
                                returnByValue=True,
                                timeout=5000)
        return result.get('result', {}).get('value', {})
    except:
        return {'status': 'error'}


def poll_for_completion(tab, max_wait=360):
    """Poll for completion"""
    
    start_time = time.time()
    last_status = None
    
    print("\n📊 Monitoring generation (polling every 5s)...")
    
    while time.time() - start_time < max_wait:
        state = get_monitor_state(tab)
        status = state.get('status', 'unknown')
        elapsed = int(time.time() - start_time)
        
        if status != last_status:
            if status == 'pending':
                op_name = state.get('operationName', 'unknown')
                credits = state.get('credits', '?')
                print(f"\n   [{elapsed}s] 🎯 Operation: {op_name[:25]}...")
                print(f"   [{elapsed}s] 💰 Credits: {credits}")
                print(f"   [{elapsed}s] ⏳ Status: PENDING - Generation queued")
            elif status == 'started':
                op_name = state.get('operationName', 'unknown')
                credits = state.get('credits', '?')
                print(f"\n   [{elapsed}s] 🎯 Operation: {op_name[:25]}...")
                print(f"   [{elapsed}s] 💰 Credits: {credits}")
                print(f"   [{elapsed}s] 🚀 Status: STARTED")
            elif status == 'active':
                print(f"\n   [{elapsed}s] 🔄 Status: ACTIVE - Generating...")
            elif status == 'complete':
                print(f"\n   [{elapsed}s] ✅ Status: SUCCESSFUL!")
                return state
            elif status == 'failed':
                print(f"\n   [{elapsed}s] ❌ Status: FAILED - {state.get('error')}")
                return state
            elif status == 'auth_error':
                print(f"\n   [{elapsed}s] ❌ AUTH ERROR: {state.get('apiError')}")
                return state
            elif status == 'api_error':
                print(f"\n   [{elapsed}s] ❌ API ERROR: {state.get('apiError')}")
                return state
            
            last_status = status
        else:
            print(f"\r   [{elapsed}s] 🔍 Polling... ({status})", end='', flush=True)
        
        time.sleep(5)
    
    print("\n   ⏰ Timeout!")
    return {'status': 'timeout'}


def download_video(video_url, output_dir='output'):
    """Download video"""
    
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
    
    filename = f"video_{int(time.time())}.mp4"
    filepath = os.path.join(output_dir, filename)
    
    print(f"\n📥 Downloading video...")
    
    try:
        response = requests.get(video_url, stream=True, timeout=60)
        response.raise_for_status()
        
        total_size = int(response.headers.get('content-length', 0))
        downloaded = 0
        
        with open(filepath, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                f.write(chunk)
                downloaded += len(chunk)
                if total_size:
                    pct = int(downloaded * 100 / total_size)
                    print(f"\r   Progress: {pct}% ({downloaded/1024/1024:.1f} MB)", end='')
        
        file_size = os.path.getsize(filepath)
        print(f"\n   ✅ Saved: {filepath} ({file_size/1024/1024:.1f} MB)")
        return filepath
        
    except Exception as e:
        print(f"\n   ❌ Download failed: {e}")
        return None


def generate_video(prompt, port=9223):
    """Generate video"""
    
    print("=" * 60)
    print("🎬 VEO3 VIDEO GENERATOR")
    print("=" * 60)
    print(f"Prompt: {prompt}")
    print("=" * 60)
    
    print("\n🔌 Connecting to Chrome...")
    try:
        browser = Browser(url=f'http://127.0.0.1:{port}')
    except Exception as e:
        print(f"❌ Failed: {e}")
        return None
    
    print("🔍 Finding Flow tab...")
    try:
        response = requests.get(f"http://127.0.0.1:{port}/json", timeout=5)
        tabs_json = response.json()
        
        flow_tab = None
        for tab_data in tabs_json:
            if 'labs.google/fx/tools/flow' in tab_data.get('url', ''):
                tabs = browser.list_tab()
                for tab in tabs:
                    if hasattr(tab, 'id') and tab.id == tab_data.get('id'):
                        flow_tab = tab
                        break
                break
        
        if not flow_tab:
            print("❌ No Flow tab found")
            return None
        
        print("✅ Found Flow tab")
        flow_tab.start()
        
    except Exception as e:
        print(f"❌ Error: {e}")
        return None
    
    try:
        # Check for homepage and create project if needed
        print("\n📂 Checking for active project...")
        project_status = ensure_project_open(flow_tab)
        
        if project_status.get('wasHomepage'):
            print("🆕 Created new project")
            time.sleep(2)
        else:
            print("✅ Already in a project")
        
        print("\n📡 Installing network monitor...")
        monitor_result = setup_network_monitor(flow_tab)
        if not monitor_result.get('success'):
            print(f"❌ Failed")
            return None
        print("✅ Monitor active")
        
        print("\n🚀 Triggering generation...")
        result = trigger_generation(flow_tab, prompt)
        
        if not result.get('success'):
            print(f"❌ Failed: {result.get('error')}")
            return None
        
        print("✅ Generation triggered!")
        
        final_state = poll_for_completion(flow_tab)
        
        if final_state.get('status') == 'complete':
            video_url = final_state.get('videoUrl')
            
            if video_url:
                print(f"\n{'=' * 60}")
                print("✅ VIDEO GENERATED!")
                print("=" * 60)
                
                filepath = download_video(video_url)
                
                if filepath:
                    print(f"\n🎉 Success! Video saved to: {filepath}")
                    return {'success': True, 'videoUrl': video_url, 'filepath': filepath}
        else:
            print(f"\n❌ Generation failed: {final_state.get('status')}")
            return None
            
    except Exception as e:
        print(f"\n❌ Error: {e}")
        return None
    finally:
        flow_tab.stop()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python generate_video.py \"Your video prompt\"")
        sys.exit(1)
    
    prompt = sys.argv[1]
    generate_video(prompt)
