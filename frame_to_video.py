"""
Complete Frame-to-Video Generator
Starts Chrome with extension OR connects to existing Chrome
"""

import asyncio
import subprocess
import sys
from pathlib import Path
from connect_and_generate import generate_frames_on_existing_chrome

def find_chrome_path():
    """Find Chrome executable"""
    possible_paths = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        Path.home() / r"AppData\Local\Google\Chrome\Application\chrome.exe",
    ]
    
    for path in possible_paths:
        if Path(path).exists():
            return str(path)
    
    raise FileNotFoundError("Chrome not found")

async def main():
    """Main function"""
    
    if len(sys.argv) < 4:
        print("="*60)
        print("🎞️ VEO3 FRAME-TO-VIDEO GENERATOR")
        print("="*60)
        print("\nUsage:")
        print("  python frame_to_video.py <first_frame> <last_frame> <prompt>")
        print("\nExample:")
        print('  python frame_to_video.py frame1.png frame2.png "Beautiful sunset"')
        print("="*60)
        return
    
    first_frame = sys.argv[1]
    last_frame = sys.argv[2]
    prompt = sys.argv[3]
    
    print("="*60)
    print("🎞️ VEO3 FRAME-TO-VIDEO GENERATOR")
    print("="*60)
    print(f"First Frame: {first_frame}")
    print(f"Last Frame: {last_frame}")
    print(f"Prompt: {prompt}")
    print("="*60)
    print()
    
    # Try to connect to existing Chrome first
    print("🔍 Checking for existing Chrome with debugging...")
    
    import aiohttp
    chrome_running = False
    port = 9222
    
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://localhost:{port}/json/version", timeout=aiohttp.ClientTimeout(total=2)) as resp:
                if resp.status == 200:
                    chrome_running = True
                    print(f"✅ Found Chrome on port {port}")
    except:
        pass
    
    if not chrome_running:
        # Try port 9223
        port = 9223
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(f"http://localhost:{port}/json/version", timeout=aiohttp.ClientTimeout(total=2)) as resp:
                    if resp.status == 200:
                        chrome_running = True
                        print(f"✅ Found Chrome on port {port}")
        except:
            pass
    
    if chrome_running:
        print(f"🔌 Connecting to existing Chrome on port {port}...")
        await generate_frames_on_existing_chrome(first_frame, last_frame, prompt, port)
    else:
        print("❌ No Chrome with debugging found")
        print("\n💡 Starting new Chrome with extension...")
        
        # Start Chrome with extension
        chrome_path = find_chrome_path()
        extension_path = Path(__file__).parent / "flow_extension"
        
        if not extension_path.exists():
            print(f"❌ Extension not found at: {extension_path}")
            return
        
        chrome_args = [
            chrome_path,
            "--remote-debugging-port=9222",
            f"--load-extension={extension_path.absolute()}",
            "--no-first-run",
            "--no-default-browser-check",
            f"--user-data-dir={Path.home() / 'chrome_veo3'}",
            "https://labs.google/fx/tools/flow/"
        ]
        
        print("🚀 Starting Chrome...")
        process = subprocess.Popen(chrome_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"✅ Chrome started (PID: {process.pid})")
        print("⏳ Waiting for Chrome to be ready...")
        
        await asyncio.sleep(8)
        
        # Now connect and generate
        print("🔌 Connecting to Chrome...")
        await generate_frames_on_existing_chrome(first_frame, last_frame, prompt, 9222)
        
        print("\n💡 Chrome is still running. Close it manually when done.")

if __name__ == "__main__":
    asyncio.run(main())
