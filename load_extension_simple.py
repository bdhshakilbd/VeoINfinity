"""
Simple Extension Loader - Just start Chrome with extension
"""

import subprocess
import time
from pathlib import Path

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

# Configuration
EXTENSION_PATH = Path(__file__).parent / "flow_extension"
FLOW_URL = "https://labs.google/fx/tools/flow/"

print("="*60)
print("Simple Chrome Extension Loader")
print("="*60)
print(f"Extension: {EXTENSION_PATH}")
print(f"Flow URL: {FLOW_URL}")
print("="*60)
print()

# Check extension exists
if not EXTENSION_PATH.exists():
    print(f"❌ Extension not found at: {EXTENSION_PATH}")
    exit(1)

if not (EXTENSION_PATH / "manifest.json").exists():
    print(f"❌ manifest.json not found")
    exit(1)

print("✅ Extension folder found")

# Find Chrome
try:
    chrome_path = find_chrome_path()
    print(f"✅ Chrome found: {chrome_path}")
except FileNotFoundError as e:
    print(f"❌ {e}")
    exit(1)

# Start Chrome with extension
extension_abs = str(EXTENSION_PATH.absolute())

print(f"\n🚀 Starting Chrome with extension...")
print(f"📦 Extension path: {extension_abs}")

chrome_args = [
    chrome_path,
    f"--load-extension={extension_abs}",
    "--no-first-run",
    "--no-default-browser-check",
    FLOW_URL  # Open Flow URL directly
]

print(f"🌐 Opening: {FLOW_URL}")
print()

# Start Chrome
process = subprocess.Popen(chrome_args)

print("="*60)
print("✅ Chrome started!")
print("="*60)
print(f"PID: {process.pid}")
print()
print("💡 To verify extension is loaded:")
print("   1. Look for 'Veo3 Infinity' in Chrome toolbar")
print("   2. Click the puzzle piece icon → Pin 'Veo3 Infinity'")
print("   3. Click 'Veo3 Infinity' icon to open side panel")
print("   4. Or visit chrome://extensions/ to see it listed")
print()
print("⏸️  Chrome is running. Close Chrome window to exit.")
print()

# Wait for Chrome to exit
try:
    process.wait()
    print("\n✅ Chrome closed")
except KeyboardInterrupt:
    print("\n\n🛑 Stopping...")
    process.terminate()
    process.wait()
    print("✅ Chrome stopped")
