"""
Frame-to-Video Generator using PyChrome
Based on test_veo3_extension.py approach
"""

import time
import base64
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
    """Generate video from frames using pychrome"""
    
    import sys
    
    print("="*60, flush=True)
    print("🎞️ FRAME-TO-VIDEO GENERATOR (PyChrome)", flush=True)
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
        print(f"❌ First frame not found")
        return
    
    if not last_frame.exists():
        print(f"❌ Last frame not found")
        return
    
    # Read frames as base64
    print("📸 Reading frames...")
    with open(first_frame, 'rb') as f:
        first_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    with open(last_frame, 'rb') as f:
        last_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    print("✅ Frames loaded")
    
    # Connect to Chrome
    print(f"\n🔌 Connecting to Chrome on port {port}...")
    try:
        browser = Browser(url=f'http://127.0.0.1:{port}')
        print("✅ Connected to Chrome")
    except Exception as e:
        print(f"❌ Failed to connect: {e}")
        print(f"\n💡 Make sure Chrome is running with:")
        print(f"   chrome.exe --remote-debugging-port={port}")
        return
    
    # Find Flow tab
    print("\n🔍 Looking for Flow tab...")
    tabs = browser.list_tab()
    
    flow_tab = None
    for tab in tabs:
        tab_url = str(tab.url) if hasattr(tab, 'url') else ''
        if 'labs.google/fx/tools/flow' in tab_url:
            print(f"✅ Found Flow tab: {tab_url}")
            flow_tab = tab
            break
    
    if not flow_tab:
        print("❌ No Flow tab found!")
        print("   Creating new Flow tab...")
        flow_tab = browser.new_tab()
        flow_tab.start()
        flow_tab.call_method('Page.navigate', url='https://labs.google/fx/tools/flow/')
        print("⏳ Waiting for page to load...")
        time.sleep(8)
        print("✅ Flow page opened")
    else:
        # Start existing tab
        flow_tab.start()
    
    # Execute frame upload script
    print("\n📤 Uploading frames and generating...")
    
    js_code = f"""
    (async () => {{
        console.log('🎞️ Starting frame upload...');
        
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
            // Switch mode
            const modeDropdown = document.querySelector('select#mode');
            if (modeDropdown) {{
                modeDropdown.value = 'Frames to Video';
                modeDropdown.dispatchEvent(new Event('change', {{ bubbles: true }}));
                await new Promise(r => setTimeout(r, 2000));
            }}
            
            // Find buttons
            let frameButtons = [];
            for (let i = 0; i < 10; i++) {{
                frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));
                if (frameButtons.length >= 2) break;
                await new Promise(r => setTimeout(r, 500));
            }}
            
            if (frameButtons.length < 2) {{
                return {{ success: false, error: 'Frame buttons not found' }};
            }}
            
            // Upload frames
            const firstFile = await base64ToFile('{first_b64}', 'first.png');
            await uploadToButton(frameButtons[0], firstFile, 'First');
            await new Promise(r => setTimeout(r, 2000));
            
            const lastFile = await base64ToFile('{last_b64}', 'last.png');
            await uploadToButton(frameButtons[1], lastFile, 'Last');
            await new Promise(r => setTimeout(r, 5000));
            
            // Set prompt
            const textarea = document.querySelector('textarea');
            if (textarea) {{
                textarea.value = '{prompt}';
                textarea.dispatchEvent(new Event('input', {{ bubbles: true }}));
            }}
            
            await new Promise(r => setTimeout(r, 1000));
            
            // Click generate
            const buttons = document.querySelectorAll('button');
            for (const btn of buttons) {{
                if (btn.innerHTML.includes('arrow_forward')) {{
                    btn.click();
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
        result = flow_tab.call_method('Runtime.evaluate',
                                     expression=js_code,
                                     awaitPromise=True,
                                     returnByValue=True,
                                     timeout=120)
        
        response = result.get('result', {}).get('value', {})
        
        if response.get('success'):
            print("\n" + "="*60)
            print("✅ VIDEO GENERATION STARTED!")
            print("="*60)
            print("📹 Check Chrome to see the progress")
            print("="*60)
        else:
            error = response.get('error', 'Unknown error')
            print(f"\n❌ Failed: {error}")
    
    except Exception as e:
        print(f"\n❌ Error: {e}")
    
    finally:
        flow_tab.stop()


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 4:
        print("Usage: python pychrome_frame_gen.py <first_frame> <last_frame> <prompt> [port]")
        print('Example: python pychrome_frame_gen.py frame1.png frame2.png "Beautiful sunset" 9223')
        exit(1)
    
    first = sys.argv[1]
    last = sys.argv[2]
    prompt = sys.argv[3]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 9223
    
    generate_from_frames(first, last, prompt, port)
