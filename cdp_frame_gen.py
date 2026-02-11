"""
Frame-to-Video Generator - Direct CDP Script Execution
Injects JavaScript directly into Flow page to upload frames
"""

import base64
import requests
import json
from pathlib import Path
import websocket
import time

def generate_from_frames(first_frame_path, last_frame_path, prompt, port=9223):
    """Direct CDP: inject JS into Flow page to upload frames"""
    
    print("="*60)
    print("🎞️ FRAME-TO-VIDEO (Direct CDP)")
    print("="*60)
    print(f"Prompt: {prompt[:50]}...")
    print("="*60)
    print()
    
    # Read frames as base64
    print("📸 Reading frames...")
    with open(first_frame_path, 'rb') as f:
        first_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    with open(last_frame_path, 'rb') as f:
        last_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    print("✅ Frames loaded")
    
    # Connect to Chrome
    print(f"\n🔌 Connecting to Chrome on port {port}...")
    try:
        response = requests.get(f"http://localhost:{port}/json", timeout=5)
        tabs = response.json()
    except Exception as e:
        print(f"❌ Cannot connect to Chrome: {e}")
        return
    print("✅ Connected")
    
    # Find Flow project tab
    flow_tab = None
    for tab in tabs:
        url = tab.get('url', '')
        if 'labs.google/fx/tools/flow' in url and '/project/' in url:
            flow_tab = tab
            break
    
    if not flow_tab:
        print("❌ No Flow PROJECT tab found!")
        print("   Please:")
        print("   1. Open https://labs.google/fx/tools/flow/")
        print("   2. Click '+ New project'")
        print("   3. Select 'Frames to Video' mode")
        print("   4. Then run this script")
        return
    
    print(f"✅ Found project: {flow_tab['title']}")
    
    # Connect to tab
    print("\n📤 Injecting upload script...")
    ws = websocket.create_connection(flow_tab['webSocketDebuggerUrl'])
    
    # Build frames array
    frames_data = json.dumps([
        {"data": first_b64, "name": "First Frame"},
        {"data": last_b64, "name": "Last Frame"}
    ])
    
    # This is the EXACT JavaScript from the extension
    js_code = f"""
(async () => {{
    const frames = {frames_data};
    const promptText = {json.dumps(prompt)};
    
    console.log('🎞️ Frame Upload & Generate - ' + frames.length + ' frame(s)');
    
    const uploadedMedia = [];
    const originalFetch = window.fetch;
    
    window.fetch = async function (...args) {{
        const response = await originalFetch.apply(this, args);
        const url = args[0];
        
        if (url && url.toString().includes('uploadUserImage')) {{
            try {{
                const clonedResponse = response.clone();
                const data = await clonedResponse.json();
                if (data.mediaGenerationId) {{
                    uploadedMedia.push(data.mediaGenerationId.mediaGenerationId);
                    console.log('📡 Upload detected: ' + uploadedMedia.length + '/' + frames.length);
                }}
            }} catch (e) {{}}
        }}
        return response;
    }};
    
    async function base64ToFile(base64, filename) {{
        const response = await originalFetch(base64);
        const blob = await response.blob();
        return new File([blob], filename, {{ type: 'image/png' }});
    }}
    
    async function uploadToButton(button, file, label) {{
        console.log('📸 Uploading ' + label);
        button.click();
        await new Promise(r => setTimeout(r, 1000));
        
        const fileInput = document.querySelector('input[type="file"]');
        if (fileInput) {{
            const dt = new DataTransfer();
            dt.items.add(file);
            fileInput.files = dt.files;
            fileInput.dispatchEvent(new Event('change', {{bubbles: true}}));
            await new Promise(r => setTimeout(r, 1500));
            
            for (const btn of document.querySelectorAll('button')) {{
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
        // Find frame buttons
        let frameButtons = [];
        for (let i = 0; i < 10; i++) {{
            frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));
            if (frameButtons.length >= 2) break;
            await new Promise(r => setTimeout(r, 500));
        }}
        
        if (frameButtons.length < 2) {{
            console.error('❌ Frame buttons not found. Make sure "Frames to Video" mode is selected.');
            return {{success: false, error: 'Frame buttons not found'}};
        }}
        
        console.log('✅ Found ' + frameButtons.length + ' frame buttons');
        
        // Upload frames
        for (let i = 0; i < frames.length; i++) {{
            const file = await base64ToFile(frames[i].data, 'frame_' + (i+1) + '.png');
            await uploadToButton(frameButtons[i], file, frames[i].name);
            await new Promise(r => setTimeout(r, 2000));
        }}
        
        // Wait for uploads
        let waitCount = 0;
        while (uploadedMedia.length < frames.length && waitCount < 20) {{
            await new Promise(r => setTimeout(r, 1000));
            waitCount++;
        }}
        console.log('✅ Uploads verified: ' + uploadedMedia.length);
        
        // Wait before prompt
        await new Promise(r => setTimeout(r, 5000));
        
        // Set prompt
        const textarea = document.querySelector('textarea');
        if (textarea) {{
            textarea.value = promptText;
            textarea.dispatchEvent(new Event('input', {{bubbles: true}}));
            console.log('✅ Prompt set');
        }}
        
        await new Promise(r => setTimeout(r, 1000));
        
        // Click generate
        for (const btn of document.querySelectorAll('button')) {{
            if (btn.innerHTML.includes('arrow_forward')) {{
                btn.click();
                console.log('✅ Generate clicked!');
                break;
            }}
        }}
        
        console.log('✅ COMPLETE! Video generating...');
        window.fetch = originalFetch;
        return {{success: true}};
        
    }} catch (error) {{
        window.fetch = originalFetch;
        console.error('❌', error.message);
        return {{success: false, error: error.message}};
    }}
}})()
"""
    
    # Send command
    command = {
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {
            "expression": js_code,
            "awaitPromise": True,
            "returnByValue": True,
            "timeout": 180000
        }
    }
    
    ws.send(json.dumps(command))
    ws.settimeout(180)
    
    try:
        while True:
            response = ws.recv()
            data = json.loads(response)
            if data.get("id") == 1:
                result = data.get("result", {}).get("result", {}).get("value", {})
                if result.get("success"):
                    print("\n" + "="*60)
                    print("✅ VIDEO GENERATION STARTED!")
                    print("="*60)
                    print("📹 Check Chrome to see the progress")
                else:
                    print(f"\n❌ Failed: {result.get('error')}")
                break
    except Exception as e:
        print(f"\n❌ Error: {e}")
    finally:
        ws.close()


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 4:
        print("Usage: python cdp_frame_gen.py <first_frame> <last_frame> <prompt> [port]")
        print("\nIMPORTANT: First do this in Chrome:")
        print("  1. Open https://labs.google/fx/tools/flow/")
        print("  2. Click '+ New project'")
        print("  3. Select 'Frames to Video' mode from dropdown")
        print("  4. Then run this script")
        exit(1)
    
    first = sys.argv[1]
    last = sys.argv[2]
    prompt = sys.argv[3]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 9223
    
    generate_from_frames(first, last, prompt, port)
