"""
Open Extension Side Panel - Find Extension ID First
"""

import requests
from pychrome import Browser
import time

def open_sidepanel(port=9223):
    """Open the extension side panel"""
    
    print("=" * 60)
    print("🔧 VEO3 SIDE PANEL OPENER")
    print("=" * 60)
    
    # Get all tabs including extension pages
    print("\n🔍 Scanning all Chrome tabs...")
    try:
        response = requests.get(f"http://127.0.0.1:{port}/json", timeout=5)
        all_tabs = response.json()
        
        print(f"   Found {len(all_tabs)} tabs")
        
        # Look for extension tabs
        extension_ids = set()
        for tab in all_tabs:
            url = tab.get('url', '')
            title = tab.get('title', '')
            
            # Check for extension URLs
            if 'chrome-extension://' in url:
                parts = url.replace('chrome-extension://', '').split('/')
                if parts:
                    ext_id = parts[0]
                    extension_ids.add(ext_id)
                    print(f"   📦 Extension: {ext_id}")
                    print(f"      URL: {url[:60]}...")
            
            # Also print regular tabs for reference
            elif 'labs.google' in url:
                print(f"   🌐 Flow: {title[:40]}")
        
        if not extension_ids:
            print("\n⚠️  No extension tabs found!")
            print("   The extension might not have any open tabs.")
            
    except Exception as e:
        print(f"❌ Error: {e}")
        return False
    
    # Connect to browser
    print("\n🔌 Connecting to Chrome...")
    try:
        browser = Browser(url=f'http://127.0.0.1:{port}')
    except Exception as e:
        print(f"❌ Failed: {e}")
        return False
    
    # Try to open sidepanel.html for each found extension
    if extension_ids:
        print("\n🚀 Trying to open side panel...")
        for ext_id in extension_ids:
            sidepanel_url = f"chrome-extension://{ext_id}/sidepanel.html"
            print(f"   Opening: {sidepanel_url}")
            
            try:
                new_tab = browser.new_tab(sidepanel_url)
                print(f"✅ Opened side panel tab!")
                time.sleep(1)
                break
            except Exception as e:
                print(f"   ⚠️  Failed: {e}")
    else:
        # Provide manual instructions
        print("\n💡 TO FIND YOUR EXTENSION ID:")
        print("   1. Go to chrome://extensions")
        print("   2. Enable 'Developer mode' (top right)")
        print("   3. Find 'Veo3 Infinity'")
        print("   4. Copy the ID shown")
        print("")
        
        ext_id = input("Enter extension ID (or press Enter to skip): ").strip()
        
        if ext_id:
            sidepanel_url = f"chrome-extension://{ext_id}/sidepanel.html"
            print(f"\n🚀 Opening: {sidepanel_url}")
            try:
                browser.new_tab(sidepanel_url)
                print("✅ Opened!")
            except Exception as e:
                print(f"❌ Failed: {e}")
    
    print("\n" + "=" * 60)
    print("✅ DONE")
    print("=" * 60)
    
    return True


if __name__ == "__main__":
    open_sidepanel()
