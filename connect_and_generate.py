"""
Connect to existing Chrome and generate video
Works with Chrome already running with --remote-debugging-port
"""

import asyncio
import json
import websockets
import time
from pathlib import Path

async def send_cdp_command(ws, method, params=None):
    """Send a CDP command and wait for response"""
    command_id = int(time.time() * 1000000)
    message = {
        "id": command_id,
        "method": method,
        "params": params or {}
    }
    
    await ws.send(json.dumps(message))
    
    # Wait for response
    while True:
        response = await ws.recv()
        data = json.loads(response)
        
        if data.get("id") == command_id:
            if "error" in data:
                raise Exception(f"CDP Error: {data['error']}")
            return data.get("result", {})


async def generate_frames_on_existing_chrome(first_frame_path, last_frame_path, prompt, port=9222):
    """Generate video from frames on already-running Chrome"""
    
    print("="*60)
    print("🎞️ FRAME-TO-VIDEO - Connect to Existing Chrome")
    print("="*60)
    print(f"Port: {port}")
    print(f"First Frame: {first_frame_path}")
    print(f"Last Frame: {last_frame_path}")
    print(f"Prompt: {prompt}")
    print("="*60)
    print()
    
    # Check frames exist
    import base64
    
    first_frame = Path(first_frame_path)
    last_frame = Path(last_frame_path)
    
    if not first_frame.exists():
        print(f"❌ First frame not found: {first_frame_path}")
        return
    
    if not last_frame.exists():
        print(f"❌ Last frame not found: {last_frame_path}")
        return
    
    # Read frames as base64
    print("📸 Reading frames...")
    with open(first_frame, 'rb') as f:
        first_frame_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    with open(last_frame, 'rb') as f:
        last_frame_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    print("✅ Frames loaded")
    
    try:
        # Connect to Chrome
        print(f"\n🔌 Connecting to Chrome on port {port}...")
        
        import aiohttp
        async with aiohttp.ClientSession() as session:
            try:
                async with session.get(f"http://localhost:{port}/json/version") as resp:
                    version_data = await resp.json()
                    ws_url = version_data["webSocketDebuggerUrl"]
            except Exception as e:
                print(f"❌ Could not connect to Chrome on port {port}")
                print(f"   Error: {e}")
                print("\n💡 Make sure Chrome is running with:")
                print(f"   chrome.exe --remote-debugging-port={port}")
                return
        
        print(f"✅ Connected to Chrome")
        
        async with websockets.connect(ws_url) as ws:
            # Enable domains
            await send_cdp_command(ws, "Target.setDiscoverTargets", {"discover": True})
            
            # Find Flow tab
            print("\n🔍 Looking for Flow tab...")
            targets = await send_cdp_command(ws, "Target.getTargets")
            
            flow_tab_id = None
            for target in targets.get("targetInfos", []):
                if target.get("type") == "page" and "labs.google/fx/tools/flow" in target.get("url", ""):
                    flow_tab_id = target.get("targetId")
                    print(f"✅ Found Flow tab: {target.get('url')}")
                    break
            
            if not flow_tab_id:
                print("❌ No Flow tab found!")
                print("   Please open https://labs.google/fx/tools/flow/ in Chrome")
                return
            
            # Attach to Flow tab
            print("🔗 Attaching to Flow tab...")
            session_result = await send_cdp_command(ws, "Target.attachToTarget", {
                "targetId": flow_tab_id,
                "flatten": True
            })
            
            session_id = session_result["sessionId"]
            print("✅ Attached")
            
            # Upload frames and generate
            print("\n📤 Uploading frames and starting generation...")
            
            upload_frames_js = f"""
            (async () => {{
                console.log('🎞️ Starting frame upload process...');
                
                async function base64ToFile(base64, filename) {{
                    const response = await fetch(base64);
                    const blob = await response.blob();
                    return new File([blob], filename, {{ type: 'image/png' }});
                }}
                
                async function uploadToButton(button, file, label) {{
                    console.log(`📸 Uploading ${{label}}: ${{file.name}}`);
                    
                    button.click();
                    await new Promise(r => setTimeout(r, 1000));
                    
                    const fileInput = document.querySelector('input[type="file"]');
                    if (fileInput) {{
                        const dataTransfer = new DataTransfer();
                        dataTransfer.items.add(file);
                        fileInput.files = dataTransfer.files;
                        fileInput.dispatchEvent(new Event('change', {{ bubbles: true }}));
                        fileInput.dispatchEvent(new Event('input', {{ bubbles: true }}));
                        console.log('   📤 File set on input');
                        
                        await new Promise(r => setTimeout(r, 1500));
                        
                        const buttons = Array.from(document.querySelectorAll('button'));
                        for (const btn of buttons) {{
                            if (btn.textContent.includes('Crop and Save')) {{
                                console.log('   ✂️  Clicking Crop and Save...');
                                btn.click();
                                await new Promise(r => setTimeout(r, 3000));
                                return true;
                            }}
                        }}
                    }}
                    return false;
                }}
                
                try {{
                    // Step 1: Switch to Frames to Video mode
                    console.log('[1/4] Switching to Frames to Video mode...');
                    const modeDropdown = document.querySelector('select#mode');
                    if (modeDropdown) {{
                        modeDropdown.value = 'Frames to Video';
                        modeDropdown.dispatchEvent(new Event('change', {{ bubbles: true }}));
                        console.log('   ✅ Mode switched');
                        await new Promise(r => setTimeout(r, 2000));
                    }}
                    
                    // Step 2: Find frame buttons
                    console.log('[2/4] Finding frame buttons...');
                    let frameButtons = [];
                    let attempts = 0;
                    
                    while (frameButtons.length < 2 && attempts < 10) {{
                        frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));
                        console.log(`   Attempt ${{attempts + 1}}: Found ${{frameButtons.length}} buttons`);
                        
                        if (frameButtons.length < 2) {{
                            await new Promise(r => setTimeout(r, 500));
                            attempts++;
                        }}
                    }}
                    
                    if (frameButtons.length < 2) {{
                        throw new Error(`Need 2 buttons, found ${{frameButtons.length}}`);
                    }}
                    
                    console.log(`✅ Found ${{frameButtons.length}} frame buttons`);
                    
                    // Step 3: Upload frames
                    console.log('[3/4] Uploading frames...');
                    
                    const firstFile = await base64ToFile({json.dumps(first_frame_b64)}, 'first_frame.png');
                    await uploadToButton(frameButtons[0], firstFile, 'First Frame');
                    await new Promise(r => setTimeout(r, 2000));
                    
                    const lastFile = await base64ToFile({json.dumps(last_frame_b64)}, 'last_frame.png');
                    await uploadToButton(frameButtons[1], lastFile, 'Last Frame');
                    await new Promise(r => setTimeout(r, 5000));
                    
                    console.log('✅ Frames uploaded');
                    
                    // Step 4: Set prompt and generate
                    console.log('[4/4] Setting prompt and generating...');
                    const textarea = document.querySelector('textarea');
                    if (textarea) {{
                        textarea.value = {json.dumps(prompt)};
                        textarea.dispatchEvent(new Event('input', {{ bubbles: true }}));
                        console.log('   ✅ Prompt set');
                    }}
                    
                    await new Promise(r => setTimeout(r, 1000));
                    
                    // Click generate
                    const buttons = document.querySelectorAll('button');
                    for (const btn of buttons) {{
                        if (btn.innerHTML.includes('arrow_forward')) {{
                            btn.click();
                            console.log('   ✅ Generate clicked!');
                            break;
                        }}
                    }}
                    
                    console.log('✅ FRAME-TO-VIDEO GENERATION STARTED!');
                    return true;
                    
                }} catch (error) {{
                    console.error('❌ ERROR:', error.message);
                    return false;
                }}
            }})()
            """
            
            result = await send_cdp_command(ws, "Runtime.evaluate", {
                "expression": upload_frames_js,
                "awaitPromise": True,
                "returnByValue": True
            })
            
            if result.get("result", {}).get("value"):
                print("\n" + "="*60)
                print("✅ FRAME-TO-VIDEO GENERATION STARTED!")
                print("="*60)
                print("📹 Video is now generating on Google Flow")
                print("⏳ Check Chrome to see the progress")
                print("="*60)
            else:
                print("\n❌ Failed to start generation")
                print("   Check Chrome console (F12) for errors")
    
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()


async def main():
    """Main function"""
    import sys
    
    # Parse arguments
    if len(sys.argv) < 4:
        print("Usage: python connect_and_generate.py <first_frame> <last_frame> <prompt> [port]")
        print("Example: python connect_and_generate.py frame1.png frame2.png \"Beautiful sunset\" 9222")
        return
    
    first_frame = sys.argv[1]
    last_frame = sys.argv[2]
    prompt = sys.argv[3]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 9222
    
    # Try port 9222 first, then 9223
    for try_port in [port, 9223 if port == 9222 else 9222]:
        print(f"\n🔍 Trying port {try_port}...")
        try:
            await generate_frames_on_existing_chrome(first_frame, last_frame, prompt, try_port)
            break
        except Exception as e:
            print(f"   Port {try_port} failed: {e}")
            if try_port == 9223 or (port != 9222 and try_port != 9222):
                print("\n❌ Could not connect to Chrome")
                print("   Make sure Chrome is running with --remote-debugging-port=9222")


if __name__ == "__main__":
    asyncio.run(main())
