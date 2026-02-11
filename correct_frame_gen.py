"""
Frame-to-Video Generator - Correct Flow
Follows exact extension workflow:
1. Create new project
2. Open settings
3. Select Frames to Video mode
4. Upload frames
5. Generate
"""

import time
import base64
import json
from pathlib import Path

try:
    from pychrome import Browser
except ImportError:
    print("Installing pychrome...")
    import subprocess
    import sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pychrome"])
    from pychrome import Browser


def generate_from_frames(first_frame_path, last_frame_path, prompt, port=9223):
    """Generate video from frames using correct workflow"""
    
    import sys
    
    print("="*60, flush=True)
    print("🎞️ FRAME-TO-VIDEO GENERATOR (Correct Flow)", flush=True)
    print("="*60, flush=True)
    print(f"Port: {port}", flush=True)
    print(f"First Frame: {first_frame_path}", flush=True)
    print(f"Last Frame: {last_frame_path}", flush=True)
    print(f"Prompt: {prompt}", flush=True)
    print("="*60, flush=True)
    print(flush=True)
    
    # Check frames
    first_frame = Path(first_frame_path)
    last_frame = Path(last_frame_path)
    
    if not first_frame.exists():
        print(f"❌ First frame not found", flush=True)
        return
    
    if not last_frame.exists():
        print(f"❌ Last frame not found", flush=True)
        return
    
    # Read frames as base64
    print("📸 Reading frames...", flush=True)
    with open(first_frame, 'rb') as f:
        first_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    with open(last_frame, 'rb') as f:
        last_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    print("✅ Frames loaded", flush=True)
    
    # Connect to Chrome
    print(f"\n🔌 Connecting to Chrome on port {port}...", flush=True)
    try:
        browser = Browser(url=f'http://127.0.0.1:{port}')
        print("✅ Connected to Chrome", flush=True)
    except Exception as e:
        print(f"❌ Failed to connect: {e}", flush=True)
        return
    
    # Find or create Flow tab
    print("\n🔍 Looking for Flow tab...", flush=True)
    tabs = browser.list_tab()
    
    flow_tab = None
    for tab in tabs:
        tab_url = str(tab.url) if hasattr(tab, 'url') else ''
        if 'labs.google/fx/tools/flow' in tab_url:
            print(f"✅ Found Flow tab", flush=True)
            flow_tab = tab
            break
    
    if not flow_tab:
        print("Creating new Flow tab...", flush=True)
        flow_tab = browser.new_tab()
        flow_tab.start()
        flow_tab.call_method('Page.navigate', url='https://labs.google/fx/tools/flow/')
        print("⏳ Waiting for page to load...", flush=True)
        time.sleep(5)
    else:
        flow_tab.start()
    
    print("\n🎬 Starting generation workflow...", flush=True)
    
    # Execute the complete workflow
    js_code = f"""
    (async () => {{
        console.log('🎬 Starting complete workflow...');
        
        // Helper functions
        async function base64ToFile(base64, filename) {{
            const response = await fetch(base64);
            const blob = await response.blob();
            return new File([blob], filename, {{ type: 'image/png' }});
        }}
        
        async function uploadToButton(button, file, label) {{
            console.log(`📸 Uploading ${{label}}`);
            button.click();
            await new Promise(r => setTimeout(r, 1000));
            
            const fileInput = document.querySelector('input[type="file"]');
            if (fileInput) {{
                const dataTransfer = new DataTransfer();
                dataTransfer.items.add(file);
                fileInput.files = dataTransfer.files;
                fileInput.dispatchEvent(new Event('change', {{ bubbles: true }}));
                await new Promise(r => setTimeout(r, 1500));
                
                const buttons = Array.from(document.querySelectorAll('button'));
                for (const btn of buttons) {{
                    if (btn.textContent.includes('Crop and Save')) {{
                        btn.click();
                        await new Promise(r => setTimeout(r, 3000));
                        return true;
                    }}
                }}
            }}
            return false;
        }}
        
        try {{
            // Step 1: Create new project if on home page
            if (!window.location.href.includes('/project/')) {{
                console.log('[1/5] Creating new project...');
                const newProjectBtn = Array.from(document.querySelectorAll('button')).find(btn => 
                    btn.textContent.includes('New project')
                );
                
                if (newProjectBtn) {{
                    newProjectBtn.click();
                    await new Promise(r => setTimeout(r, 3000));
                    console.log('   ✅ Project created');
                }} else {{
                    return {{ success: false, error: 'New project button not found' }};
                }}
            }} else {{
                console.log('[1/5] Already in project');
            }}
            
            // Step 2: Open settings panel
            console.log('[2/5] Opening settings...');
            const modelBtn = Array.from(document.querySelectorAll('button')).find(btn => 
                btn.textContent.includes('Veo 3.1') || btn.textContent.includes('Veo 2')
            );
            
            if (modelBtn) {{
                modelBtn.click();
                await new Promise(r => setTimeout(r, 1000));
                console.log('   ✅ Settings opened');
            }} else {{
                return {{ success: false, error: 'Model button not found' }};
            }}
            
            // Step 3: Select Frames to Video mode
            console.log('[3/5] Selecting Frames to Video mode...');
            const modeDropdown = document.querySelector('select#mode');
            if (modeDropdown) {{
                modeDropdown.value = 'Frames to Video';
                modeDropdown.dispatchEvent(new Event('change', {{ bubbles: true }}));
                await new Promise(r => setTimeout(r, 2000));
                console.log('   ✅ Mode selected');
            }} else {{
                return {{ success: false, error: 'Mode dropdown not found' }};
            }}
            
            // Step 4: Find and upload to frame buttons
            console.log('[4/5] Uploading frames...');
            let frameButtons = [];
            for (let i = 0; i < 10; i++) {{
                frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));
                if (frameButtons.length >= 2) break;
                await new Promise(r => setTimeout(r, 500));
            }}
            
            if (frameButtons.length < 2) {{
                return {{ success: false, error: `Only found ${{frameButtons.length}} frame buttons` }};
            }}
            
            const firstFile = await base64ToFile({json.dumps(first_b64)}, 'first.png');
            await uploadToButton(frameButtons[0], firstFile, 'First Frame');
            await new Promise(r => setTimeout(r, 2000));
            
            const lastFile = await base64ToFile({json.dumps(last_b64)}, 'last.png');
            await uploadToButton(frameButtons[1], lastFile, 'Last Frame');
            await new Promise(r => setTimeout(r, 5000));
            
            console.log('   ✅ Frames uploaded');
            
            // Step 5: Set prompt and generate
            console.log('[5/5] Setting prompt and generating...');
            const textarea = document.querySelector('textarea');
            if (textarea) {{
                textarea.value = {json.dumps(prompt)};
                textarea.dispatchEvent(new Event('input', {{ bubbles: true }}));
                console.log('   ✅ Prompt set');
            }}
            
            await new Promise(r => setTimeout(r, 1000));
            
            const buttons = document.querySelectorAll('button');
            for (const btn of buttons) {{
                if (btn.innerHTML.includes('arrow_forward')) {{
                    btn.click();
                    console.log('   ✅ Generate clicked!');
                    return {{ success: true }};
                }}
            }}
            
            return {{ success: false, error: 'Generate button not found' }};
            
        }} catch (error) {{
            return {{ success: false, error: error.message }};
        }}
    }})()
    """
    
    try:
        print("📤 Executing workflow...", flush=True)
        result = flow_tab.call_method('Runtime.evaluate',
                                     expression=js_code,
                                     awaitPromise=True,
                                     returnByValue=True,
                                     timeout=120)
        
        response = result.get('result', {}).get('value', {})
        
        if response.get('success'):
            print("\n" + "="*60, flush=True)
            print("✅ VIDEO GENERATION STARTED!", flush=True)
            print("="*60, flush=True)
            print("📹 Check Chrome to see the progress", flush=True)
            print("="*60, flush=True)
        else:
            error = response.get('error', 'Unknown error')
            print(f"\n❌ Failed: {error}", flush=True)
    
    except Exception as e:
        print(f"\n❌ Error: {e}", flush=True)
        import traceback
        traceback.print_exc()
    
    finally:
        flow_tab.stop()


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 4:
        print("Usage: python correct_frame_gen.py <first_frame> <last_frame> <prompt> [port]")
        print('Example: python correct_frame_gen.py frame1.png frame2.png "Beautiful sunset" 9223')
        exit(1)
    
    first = sys.argv[1]
    last = sys.argv[2]
    prompt = sys.argv[3]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 9223
    
    generate_from_frames(first, last, prompt, port)
