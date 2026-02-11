"""
Veo3 Infinity Extension - CDP Video Generator
Uses CDP to control the extension and generate videos programmatically
"""

import asyncio
import json
import websockets
import subprocess
import time
from pathlib import Path

# Configuration
def find_chrome_path():
    """Find Chrome executable path"""
    possible_paths = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        Path.home() / r"AppData\Local\Google\Chrome\Application\chrome.exe",
    ]
    
    for path in possible_paths:
        if Path(path).exists():
            return str(path)
    
    raise FileNotFoundError("Chrome not found")

CHROME_PATH = find_chrome_path()
EXTENSION_PATH = Path(__file__).parent / "flow_extension"
FLOW_URL = "https://labs.google/fx/tools/flow/"
DEBUG_PORT = 9222


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


async def generate_video_via_extension(prompt, aspect_ratio="16:9", model="Veo 3.1 - Fast", 
                                      output_count=1, mode="Text to Video"):
    """Generate a video using the extension via CDP"""
    
    print("="*60)
    print("🎬 VEO3 INFINITY - CDP VIDEO GENERATOR")
    print("="*60)
    print(f"Prompt: {prompt}")
    print(f"Model: {model}")
    print(f"Aspect Ratio: {aspect_ratio}")
    print("="*60)
    print()
    
    # Start Chrome with extension
    print("🚀 Starting Chrome with extension...")
    extension_abs = str(EXTENSION_PATH.absolute())
    
    chrome_args = [
        CHROME_PATH,
        f"--remote-debugging-port={DEBUG_PORT}",
        f"--load-extension={extension_abs}",
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={Path.home() / 'chrome_veo3_cdp'}",
    ]
    
    chrome_process = subprocess.Popen(
        chrome_args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    
    print(f"✅ Chrome started (PID: {chrome_process.pid})")
    print("⏳ Waiting for Chrome to be ready...")
    await asyncio.sleep(4)
    
    try:
        # Get WebSocket URL
        import aiohttp
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://localhost:{DEBUG_PORT}/json/version") as resp:
                version_data = await resp.json()
                ws_url = version_data["webSocketDebuggerUrl"]
        
        print(f"🔌 Connected to Chrome DevTools")
        
        async with websockets.connect(ws_url) as ws:
            # Enable domains
            await send_cdp_command(ws, "Target.setDiscoverTargets", {"discover": True})
            
            # Create Flow tab
            print(f"🌐 Opening Flow URL...")
            new_tab = await send_cdp_command(ws, "Target.createTarget", {
                "url": FLOW_URL
            })
            
            tab_id = new_tab["targetId"]
            print(f"✅ Flow tab created")
            
            # Wait for page to load
            print("⏳ Waiting for page to load...")
            await asyncio.sleep(8)
            
            # Attach to tab to execute scripts
            print("🔗 Attaching to tab...")
            session_result = await send_cdp_command(ws, "Target.attachToTarget", {
                "targetId": tab_id,
                "flatten": True
            })
            
            session_id = session_result["sessionId"]
            
            # Set zoom to 50%
            print("🔍 Setting zoom to 50%...")
            await send_cdp_command(ws, "Emulation.setPageScaleFactor", {
                "pageScaleFactor": 0.5
            })
            
            # Fill in the form via DOM manipulation
            print("\n📝 Filling in generation form...")
            
            # Set prompt
            set_prompt_js = f"""
            (async () => {{
                const textarea = document.querySelector('textarea');
                if (textarea) {{
                    textarea.value = {json.dumps(prompt)};
                    textarea.dispatchEvent(new Event('input', {{ bubbles: true }}));
                    console.log('✅ Prompt set');
                    return true;
                }}
                return false;
            }})()
            """
            
            result = await send_cdp_command(ws, "Runtime.evaluate", {
                "expression": set_prompt_js,
                "awaitPromise": True,
                "returnByValue": True
            })
            
            if result.get("result", {}).get("value"):
                print("   ✅ Prompt set")
            else:
                print("   ⚠️  Could not set prompt")
            
            await asyncio.sleep(2)
            
            # Click generate button
            print("🚀 Clicking generate button...")
            click_generate_js = """
            (async () => {
                const buttons = document.querySelectorAll('button');
                for (const btn of buttons) {
                    if (btn.innerHTML.includes('arrow_forward')) {
                        btn.click();
                        console.log('✅ Generate button clicked');
                        return true;
                    }
                }
                return false;
            })()
            """
            
            result = await send_cdp_command(ws, "Runtime.evaluate", {
                "expression": click_generate_js,
                "awaitPromise": True,
                "returnByValue": True
            })
            
            if result.get("result", {}).get("value"):
                print("   ✅ Generate button clicked!")
            else:
                print("   ⚠️  Could not find generate button")
            
            print("\n" + "="*60)
            print("✅ VIDEO GENERATION STARTED!")
            print("="*60)
            print("📹 Video is now generating on Google Flow")
            print("⏳ This typically takes 2-5 minutes")
            print("\n💡 Chrome will stay open. You can:")
            print("   1. Watch the generation progress in Chrome")
            print("   2. Close this script (Chrome will keep running)")
            print("   3. Press Ctrl+C to stop Chrome")
            print("\n⏸️  Press Ctrl+C to stop...")
            
            # Keep running
            try:
                while True:
                    await asyncio.sleep(1)
            except KeyboardInterrupt:
                print("\n\n🛑 Stopping...")
    
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        # Cleanup
        print("\n🛑 Stopping Chrome...")
        chrome_process.terminate()
        try:
            chrome_process.wait(timeout=5)
        except:
            chrome_process.kill()
        print("✅ Chrome stopped")


async def generate_from_frames(first_frame_path, last_frame_path, prompt, 
                               aspect_ratio="16:9", model="Veo 3.1 - Fast"):
    """Generate a video from first and last frames using the extension"""
    
    print("="*60)
    print("🎞️ VEO3 INFINITY - FRAME-TO-VIDEO GENERATOR")
    print("="*60)
    print(f"First Frame: {first_frame_path}")
    print(f"Last Frame: {last_frame_path}")
    print(f"Prompt: {prompt}")
    print(f"Model: {model}")
    print("="*60)
    print()
    
    # Check if frame files exist
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
    
    # Start Chrome with extension
    print("\n🚀 Starting Chrome with extension...")
    extension_abs = str(EXTENSION_PATH.absolute())
    
    chrome_args = [
        CHROME_PATH,
        f"--remote-debugging-port={DEBUG_PORT}",
        f"--load-extension={extension_abs}",
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={Path.home() / 'chrome_veo3_cdp'}",
    ]
    
    chrome_process = subprocess.Popen(
        chrome_args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    
    print(f"✅ Chrome started (PID: {chrome_process.pid})")
    print("⏳ Waiting for Chrome to be ready...")
    await asyncio.sleep(4)
    
    try:
        # Get WebSocket URL
        import aiohttp
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://localhost:{DEBUG_PORT}/json/version") as resp:
                version_data = await resp.json()
                ws_url = version_data["webSocketDebuggerUrl"]
        
        print(f"🔌 Connected to Chrome DevTools")
        
        async with websockets.connect(ws_url) as ws:
            # Enable domains
            await send_cdp_command(ws, "Target.setDiscoverTargets", {"discover": True})
            
            # Create Flow tab
            print(f"🌐 Opening Flow URL...")
            new_tab = await send_cdp_command(ws, "Target.createTarget", {
                "url": FLOW_URL
            })
            
            tab_id = new_tab["targetId"]
            print(f"✅ Flow tab created")
            
            # Wait for page to load
            print("⏳ Waiting for page to load...")
            await asyncio.sleep(8)
            
            # Attach to tab
            print("🔗 Attaching to tab...")
            session_result = await send_cdp_command(ws, "Target.attachToTarget", {
                "targetId": tab_id,
                "flatten": True
            })
            
            session_id = session_result["sessionId"]
            
            # Set zoom to 50%
            print("🔍 Setting zoom to 50%...")
            await send_cdp_command(ws, "Emulation.setPageScaleFactor", {
                "pageScaleFactor": 0.5
            })
            
            # Switch to Frames to Video mode and upload frames
            print("\n📝 Switching to Frames to Video mode...")
            
            # This is the exact logic from your working console script
            upload_frames_js = f"""
            (async () => {{
                console.log('🎞️ Starting frame upload process...');
                
                // Helper function to convert base64 to File
                async function base64ToFile(base64, filename) {{
                    const response = await fetch(base64);
                    const blob = await response.blob();
                    return new File([blob], filename, {{ type: 'image/png' }});
                }}
                
                // Helper function to upload to a button
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
                    // Step 1: Find mode dropdown and select "Frames to Video"
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
            
            print("📤 Uploading frames and starting generation...")
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
                print("⏳ This typically takes 2-5 minutes")
                print("\n💡 Chrome will stay open. You can:")
                print("   1. Watch the generation progress in Chrome")
                print("   2. Close this script (Chrome will keep running)")
                print("   3. Press Ctrl+C to stop Chrome")
                print("\n⏸️  Press Ctrl+C to stop...")
            else:
                print("\n❌ Failed to start generation")
            
            # Keep running
            try:
                while True:
                    await asyncio.sleep(1)
            except KeyboardInterrupt:
                print("\n\n🛑 Stopping...")
    
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        # Cleanup
        print("\n🛑 Stopping Chrome...")
        chrome_process.terminate()
        try:
            chrome_process.wait(timeout=5)
        except:
            chrome_process.kill()
        print("✅ Chrome stopped")


async def main():
    """Main function"""
    
    import sys
    
    if len(sys.argv) > 1 and sys.argv[1] == 'frames':
        # Frame-to-video mode
        if len(sys.argv) < 5:
            print("Usage: python generate_video_cdp.py frames <first_frame> <last_frame> <prompt>")
            print("Example: python generate_video_cdp.py frames frame1.png frame2.png \"A beautiful sunset\"")
            return
        
        first_frame = sys.argv[2]
        last_frame = sys.argv[3]
        prompt = sys.argv[4]
        
        await generate_from_frames(first_frame, last_frame, prompt)
    else:
        # Text-to-video mode
        await generate_video_via_extension(
            prompt="A majestic golden retriever running through a sunny meadow in slow motion, cinematic lighting",
            aspect_ratio="16:9",
            model="Veo 3.1 - Fast",
            output_count=1,
            mode="Text to Video"
        )


if __name__ == "__main__":
    print("\n" + "="*60)
    print("VEO3 INFINITY - CDP VIDEO GENERATOR")
    print("="*60)
    print()
    
    # Check extension exists
    if not EXTENSION_PATH.exists():
        print(f"❌ Extension not found at: {EXTENSION_PATH}")
        exit(1)
    
    print("✅ Extension found")
    print()
    
    # Run
    asyncio.run(main())
