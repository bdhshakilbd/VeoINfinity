"""
Simple CDP Frame Generator - Just execute JavaScript
Connects to existing Chrome on port 9223
"""

import requests
import json
import base64
from pathlib import Path
import time

def execute_js_on_chrome(port, js_code):
    """Execute JavaScript on Chrome via CDP HTTP API"""
    
    # Get list of tabs
    tabs_url = f"http://localhost:{port}/json"
    response = requests.get(tabs_url)
    tabs = response.json()
    
    # Find Flow tab
    flow_tab = None
    for tab in tabs:
        if 'labs.google/fx/tools/flow' in tab.get('url', ''):
            flow_tab = tab
            break
    
    if not flow_tab:
        print("❌ No Flow tab found!")
        print("   Please open https://labs.google/fx/tools/flow/ in Chrome")
        return False
    
    print(f"✅ Found Flow tab: {flow_tab['title']}")
    
    # Execute JavaScript using the devtools URL
    ws_url = flow_tab['webSocketDebuggerUrl']
    
    # Use requests to send CDP command
    import websocket
    ws = websocket.create_connection(ws_url)
    
    # Send Runtime.evaluate command
    command = {
        "id": int(time.time() * 1000),
        "method": "Runtime.evaluate",
        "params": {
            "expression": js_code,
            "awaitPromise": True,
            "returnByValue": True
        }
    }
    
    ws.send(json.dumps(command))
    
    # Wait for response (with timeout)
    ws.settimeout(120)  # 2 minute timeout
    
    try:
        while True:
            response = ws.recv()
            data = json.loads(response)
            
            if data.get("id") == command["id"]:
                ws.close()
                
                if "error" in data:
                    print(f"❌ CDP Error: {data['error']}")
                    return False
                
                result = data.get("result", {}).get("result", {}).get("value")
                return result
    except Exception as e:
        print(f"❌ Error: {e}")
        ws.close()
        return False


def generate_frames(first_frame_path, last_frame_path, prompt, port=9223):
    """Generate video from frames"""
    
    print("="*60)
    print("🎞️ FRAME-TO-VIDEO GENERATOR (Simple CDP)")
    print("="*60)
    print(f"Port: {port}")
    print(f"First Frame: {first_frame_path}")
    print(f"Last Frame: {last_frame_path}")
    print(f"Prompt: {prompt}")
    print("="*60)
    print()
    
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
        first_frame_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    with open(last_frame, 'rb') as f:
        last_frame_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    print("✅ Frames loaded")
    
    # Check Chrome connection
    print(f"\n🔌 Connecting to Chrome on port {port}...")
    try:
        response = requests.get(f"http://localhost:{port}/json/version", timeout=2)
        if response.status_code == 200:
            print("✅ Connected to Chrome")
        else:
            print(f"❌ Chrome not responding on port {port}")
            return
    except:
        print(f"❌ Cannot connect to Chrome on port {port}")
        print("   Make sure Chrome is running with --remote-debugging-port=9223")
        return
    
    # Build JavaScript code
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
            const firstFile = await base64ToFile({json.dumps(first_frame_b64)}, 'first.png');
            await uploadToButton(frameButtons[0], firstFile, 'First');
            await new Promise(r => setTimeout(r, 2000));
            
            const lastFile = await base64ToFile({json.dumps(last_frame_b64)}, 'last.png');
            await uploadToButton(frameButtons[1], lastFile, 'Last');
            await new Promise(r => setTimeout(r, 5000));
            
            // Set prompt
            const textarea = document.querySelector('textarea');
            if (textarea) {{
                textarea.value = {json.dumps(prompt)};
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
    
    # Execute
    result = execute_js_on_chrome(port, js_code)
    
    if result and result.get('success'):
        print("\n" + "="*60)
        print("✅ VIDEO GENERATION STARTED!")
        print("="*60)
        print("📹 Check Chrome to see the progress")
        print("="*60)
    else:
        error = result.get('error') if result else 'Unknown error'
        print(f"\n❌ Failed: {error}")


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 4:
        print("Usage: python simple_frame_gen.py <first_frame> <last_frame> <prompt> [port]")
        print('Example: python simple_frame_gen.py frame1.png frame2.png "Beautiful sunset" 9223')
        exit(1)
    
    first = sys.argv[1]
    last = sys.argv[2]
    prompt = sys.argv[3]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 9223
    
    # Install websocket-client if needed
    try:
        import websocket
    except ImportError:
        print("Installing websocket-client...")
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "websocket-client"])
        import websocket
    
    generate_frames(first, last, prompt, port)
