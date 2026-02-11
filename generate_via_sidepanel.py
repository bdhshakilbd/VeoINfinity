"""
Veo3 Infinity - Generate via Side Panel Button Click
Uses CDP to click the Generate button in the side panel
"""

import time
from pychrome import Browser

def click_generate_button():
    """Click the Generate button in the side panel"""
    print("\n" + "="*60)
    print("🎬 VEO3 INFINITY - GENERATE VIA SIDE PANEL")
    print("="*60)
    
    # Connect to Chrome
    print("\n[1/4] Connecting to Chrome...")
    try:
        browser = Browser(url='http://127.0.0.1:9222')
        print("✅ Connected")
    except Exception as e:
        print(f"❌ Failed: {e}")
        return
    
    # Find side panel tab
    print("\n[2/4] Finding Veo3 Infinity side panel...")
    tabs = browser.list_tab()
    sidepanel_tab = None
    
    for tab in tabs:
        tab_url = ''
        if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
            tab_url = tab.__dict__['_kwargs'].get('url', '')
            tab_title = tab.__dict__['_kwargs'].get('title', '')
        
        if 'chrome-extension://' in tab_url and 'sidepanel.html' in tab_url:
            sidepanel_tab = tab
            print(f"✅ Found side panel")
            break
    
    if not sidepanel_tab:
        print("❌ Side panel not found!")
        print("   Please open the Veo3 Infinity side panel first")
        return
    
    # Connect to side panel
    sidepanel_tab.start()
    time.sleep(1)
    
    # Fill in prompt if needed
    print("\n[3/4] Setting up prompt...")
    
    js_fill_prompt = """
    const promptField = document.getElementById('prompt');
    if (promptField && !promptField.value) {
        promptField.value = 'A majestic golden retriever running through a sunny meadow, slow motion';
        promptField.dispatchEvent(new Event('input', { bubbles: true }));
    }
    """
    
    try:
        sidepanel_tab.call_method('Runtime.evaluate', expression=js_fill_prompt)
        print("✅ Prompt set")
    except Exception as e:
        print(f"⚠️ Could not set prompt: {e}")
    
    # Click Generate button
    print("\n[4/4] Clicking Generate button...")
    print("⏳ This will take 2-5 minutes for the video to generate...")
    print()
    
    js_click_generate = """
    const generateBtn = document.getElementById('generateBtn');
    if (generateBtn) {
        generateBtn.click();
        'CLICKED';
    } else {
        'BUTTON_NOT_FOUND';
    }
    """
    
    try:
        result = sidepanel_tab.call_method('Runtime.evaluate', 
                                          expression=js_click_generate,
                                          returnByValue=True)
        
        response = result.get('result', {}).get('value', '')
        
        if response == 'CLICKED':
            print("✅ Generate button clicked!")
            print("\n📋 Next steps:")
            print("   1. Watch the Flow page - it should start configuring")
            print("   2. The settings will be applied automatically")
            print("   3. Video generation will begin")
            print("   4. Wait 2-5 minutes for completion")
            print("\n💡 You can monitor progress in the side panel")
        else:
            print(f"❌ Could not click button: {response}")
        
    except Exception as e:
        print(f"❌ Error: {e}")
    
    finally:
        time.sleep(2)
        sidepanel_tab.stop()
        print("\nDisconnected")


if __name__ == '__main__':
    click_generate_button()
