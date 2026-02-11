"""
Pack Chrome Extension to CRX
Creates a .crx file from the extension folder
"""

import subprocess
import os
from pathlib import Path

EXTENSION_PATH = Path(__file__).parent / "flow_extension"
OUTPUT_CRX = Path(__file__).parent / "veo3_infinity.crx"
OUTPUT_PEM = Path(__file__).parent / "veo3_infinity.pem"

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

def pack_extension():
    """Pack extension to CRX using Chrome"""
    
    print("="*60)
    print("Chrome Extension Packer")
    print("="*60)
    print(f"Extension folder: {EXTENSION_PATH}")
    print(f"Output CRX: {OUTPUT_CRX}")
    print(f"Output PEM: {OUTPUT_PEM}")
    print("="*60)
    print()
    
    # Check if extension exists
    if not EXTENSION_PATH.exists():
        print(f"❌ Extension not found at: {EXTENSION_PATH}")
        return False
    
    # Check manifest
    manifest_path = EXTENSION_PATH / "manifest.json"
    if not manifest_path.exists():
        print(f"❌ manifest.json not found")
        return False
    
    print("✅ Extension folder found")
    
    # Find Chrome
    try:
        chrome_path = find_chrome_path()
        print(f"✅ Chrome found: {chrome_path}")
    except FileNotFoundError as e:
        print(f"❌ {e}")
        return False
    
    # Pack extension
    print("\n📦 Packing extension...")
    
    extension_abs = str(EXTENSION_PATH.absolute())
    pem_abs = str(OUTPUT_PEM.absolute())
    
    # Chrome command to pack extension
    cmd = [
        chrome_path,
        "--pack-extension=" + extension_abs,
    ]
    
    # Add PEM key if it exists (for updates)
    if OUTPUT_PEM.exists():
        cmd.append("--pack-extension-key=" + pem_abs)
        print(f"   Using existing PEM key: {OUTPUT_PEM.name}")
    else:
        print(f"   Creating new PEM key: {OUTPUT_PEM.name}")
    
    try:
        # Run Chrome to pack
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=10
        )
        
        # Chrome creates the CRX in the parent directory with .crx extension
        default_crx = EXTENSION_PATH.parent / (EXTENSION_PATH.name + ".crx")
        default_pem = EXTENSION_PATH.parent / (EXTENSION_PATH.name + ".pem")
        
        # Move to desired location
        if default_crx.exists():
            if OUTPUT_CRX.exists():
                OUTPUT_CRX.unlink()
            default_crx.rename(OUTPUT_CRX)
            print(f"✅ CRX created: {OUTPUT_CRX}")
            print(f"   Size: {OUTPUT_CRX.stat().st_size / 1024:.2f} KB")
        
        if default_pem.exists() and not OUTPUT_PEM.exists():
            default_pem.rename(OUTPUT_PEM)
            print(f"✅ PEM key created: {OUTPUT_PEM}")
            print(f"   ⚠️  KEEP THIS KEY PRIVATE! Needed for updates.")
        
        print("\n" + "="*60)
        print("✅ PACKING COMPLETE!")
        print("="*60)
        print(f"\n📦 Your extension CRX: {OUTPUT_CRX}")
        print(f"🔑 Your private key: {OUTPUT_PEM}")
        print("\n💡 To distribute:")
        print("   1. Share ONLY the .crx file")
        print("   2. KEEP the .pem file secret (for updates)")
        print("   3. Users can install by dragging .crx to chrome://extensions/")
        print("\n💡 To use with CDP:")
        print(f"   --load-extension={OUTPUT_CRX}")
        
        return True
        
    except subprocess.TimeoutExpired:
        print("❌ Packing timed out")
        return False
    except Exception as e:
        print(f"❌ Error packing: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    pack_extension()
