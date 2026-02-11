"""
CDP Extension Installer Test
Connects to Chrome via CDP, installs extension, and opens Flow URL
"""

import asyncio
import json
import websockets
import subprocess
import time
import os
from pathlib import Path

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
    
    raise FileNotFoundError("Chrome not found. Please install Google Chrome.")

CHROME_PATH = find_chrome_path()
EXTENSION_PATH = Path(__file__).parent / "flow_extension"
FLOW_URL = "https://labs.google/fx/tools/flow/"
DEBUG_PORT = 9222


async def send_cdp_command(ws, method, params=None, timeout=5):
    """Send a CDP command and wait for response"""
    command_id = int(time.time() * 1000)
    message = {
        "id": command_id,
        "method": method,
        "params": params or {}
    }
    
    await ws.send(json.dumps(message))
    
    # Wait for response with timeout
    try:
        start_time = time.time()
        while True:
            if time.time() - start_time > timeout:
                raise TimeoutError(f"CDP command {method} timed out after {timeout}s")
            
            response = await asyncio.wait_for(ws.recv(), timeout=1.0)
            data = json.loads(response)
            
            if data.get("id") == command_id:
                if "error" in data:
                    raise Exception(f"CDP Error: {data['error']}")
                return data.get("result", {})
    except asyncio.TimeoutError:
        # Continue waiting
        pass


async def install_extension_via_cdp():
    """Main function to install extension via CDP"""
    
    print("🚀 Starting Chrome with extension loaded...")
    
    # Convert extension path to absolute
    extension_abs_path = str(EXTENSION_PATH.absolute())
    
    # Start Chrome with remote debugging AND extension loaded
    chrome_args = [
        CHROME_PATH,
        f"--remote-debugging-port={DEBUG_PORT}",
        f"--load-extension={extension_abs_path}",  # Load extension directly
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={Path.home() / 'chrome_cdp_test'}",
    ]
    
    print(f"📦 Extension path: {extension_abs_path}")
    
    chrome_process = subprocess.Popen(
        chrome_args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    
    print(f"✅ Chrome started (PID: {chrome_process.pid})")
    print("⏳ Waiting for Chrome to be ready...")
    await asyncio.sleep(3)
    
    try:
        # Get WebSocket URL
        import aiohttp
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://localhost:{DEBUG_PORT}/json/version") as resp:
                version_data = await resp.json()
                ws_url = version_data["webSocketDebuggerUrl"]
        
        print(f"🔌 Connecting to Chrome DevTools: {ws_url}")
        
        async with websockets.connect(ws_url) as ws:
            print("✅ Connected to Chrome via CDP")
            
            # Enable necessary domains
            print("\n📋 Enabling CDP domains...")
            await send_cdp_command(ws, "Target.setDiscoverTargets", {"discover": True})
            await send_cdp_command(ws, "Page.enable")
            print("✅ CDP domains enabled")
            
            # Check if extension is loaded
            print("\n🔍 Checking for loaded extensions...")
            targets = await send_cdp_command(ws, "Target.getTargets")
            
            extension_found = False
            for target in targets.get("targetInfos", []):
                if target.get("type") == "service_worker" or "extension" in target.get("url", "").lower():
                    print(f"   ✅ Found extension: {target.get('title', 'Unknown')}")
                    print(f"      URL: {target.get('url', 'N/A')[:80]}...")
                    extension_found = True
            
            if not extension_found:
                print("   ⚠️  No extension detected!")
                print("   This might mean:")
                print("      1. Extension has errors in manifest.json")
                print("      2. Extension didn't load properly")
                print("      3. Check Chrome's error console")
            
            print(f"\n✅ Extension loading status: {'LOADED' if extension_found else 'NOT DETECTED'}")
            
            # Create a new tab with Flow URL
            print(f"\n🌐 Opening Flow URL: {FLOW_URL}")
            new_tab = await send_cdp_command(ws, "Target.createTarget", {
                "url": FLOW_URL
            })
            
            tab_id = new_tab["targetId"]
            print(f"✅ Flow tab created: {tab_id}")
            
            # Wait for page to load
            print("\n⏳ Waiting for page to load...")
            await asyncio.sleep(5)
            
            print("\n" + "="*60)
            print("✅ SETUP COMPLETE!")
            print("="*60)
            print(f"📍 Chrome is running with extension loaded")
            print(f"📍 Flow URL opened: {FLOW_URL}")
            print(f"📍 Debug port: {DEBUG_PORT}")
            print("\n💡 Extension should be visible:")
            print("   1. Click the extension icon (puzzle piece) in Chrome toolbar")
            print("   2. Click 'Veo3 Infinity' to open side panel")
            print("   3. Or check chrome://extensions/ to verify it's loaded")
            print("\n⏸️  Press Ctrl+C to stop Chrome...")
            
            # Keep the connection alive
            try:
                while True:
                    await asyncio.sleep(1)
            except KeyboardInterrupt:
                print("\n\n🛑 Stopping Chrome...")
    
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        # Cleanup
        chrome_process.terminate()
        try:
            chrome_process.wait(timeout=5)
        except:
            chrome_process.kill()
        print("✅ Chrome stopped")


if __name__ == "__main__":
    print("="*60)
    print("CDP Extension Installer Test")
    print("="*60)
    print(f"Extension path: {EXTENSION_PATH}")
    print(f"Flow URL: {FLOW_URL}")
    print("="*60)
    print()
    
    # Check if extension exists
    if not EXTENSION_PATH.exists():
        print(f"❌ Extension not found at: {EXTENSION_PATH}")
        print("   Please make sure the extension folder exists")
        exit(1)
    
    # Check manifest
    manifest_path = EXTENSION_PATH / "manifest.json"
    if not manifest_path.exists():
        print(f"❌ manifest.json not found at: {manifest_path}")
        exit(1)
    
    print("✅ Extension folder found")
    print()
    
    # Run the async function
    asyncio.run(install_extension_via_cdp())
