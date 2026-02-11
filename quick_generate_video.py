"""
Veo3 Infinity - Quick Video Generation Test
Assumes Chrome is already running with Flow page open and extension loaded
"""

import time
from pychrome import Browser

def generate_test_video():
    """Generate a test video using the extension"""
    print("\n" + "="*60)
    print("🎬 VEO3 INFINITY - QUICK VIDEO TEST")
    print("="*60)
    
    # Connect to Chrome
    print("\n[1/5] Connecting to Chrome...")
    try:
        browser = Browser(url='http://127.0.0.1:9222')
        print("✅ Connected")
    except Exception as e:
        print(f"❌ Failed: {e}")
        print("\n💡 Start Chrome with:")
        print('   chrome.exe --remote-debugging-port=9222')
        return
    
    # Find Flow tab
    print("\n[2/5] Finding Flow tab...")
    tabs = browser.list_tab()
    flow_tab = None
    
    for tab in tabs:
        # Access URL from _kwargs dictionary
        tab_url = ''
        if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
            tab_url = tab.__dict__['_kwargs'].get('url', '')
        
        if 'labs.google/fx/tools/flow' in tab_url:
            flow_tab = tab
            print(f"✅ Found: {tab_url[:60]}...")
            break
    
    if not flow_tab:
        print("❌ No Flow tab found!")
        print("   Please open https://labs.google/fx/tools/flow/ first")
        return
    
    # Connect to tab
    flow_tab.start()
    time.sleep(2)  # Wait for connection
    
    # Check extension with retries
    print("\n[3/5] Checking extension...")
    
    extension_loaded = False
    for attempt in range(3):
        try:
            result = flow_tab.call_method('Runtime.evaluate', 
                                           expression='typeof window.flowGenerator',
                                           returnByValue=True)
            
            if result.get('result', {}).get('value') == 'object':
                extension_loaded = True
                break
            else:
                if attempt < 2:
                    print(f"   Attempt {attempt+1}/3... waiting...")
                    time.sleep(2)
        except Exception as e:
            if attempt < 2:
                print(f"   Attempt {attempt+1}/3 failed... retrying...")
                time.sleep(2)
    
    if not extension_loaded:
        print("❌ Extension not loaded!")
        print("\n💡 Try:")
        print("   1. Refresh the Flow page (F5)")
        print("   2. Rerun this script")
        flow_tab.stop()
        return
    
    print("✅ Extension ready")
    
    # Configure generation
    print("\n[4/5] Configuring generation...")
    
    test_config = {
        'prompt': 'A majestic golden retriever running through a sunny meadow, slow motion',
        'aspectRatio': 'Landscape (16:9)',
        'model': 'Veo 3.1 - Fast',
        'outputCount': 1,
        'mode': 'Text to Video',
        'createNewProject': False
    }
    
    print(f"   Prompt: {test_config['prompt']}")
    print(f"   Model: {test_config['model']}")
    print(f"   Aspect: {test_config['aspectRatio']}")
    print(f"   Outputs: {test_config['outputCount']}")
    
    # Generate video
    print("\n[5/5] Starting generation...")
    print("⏳ This will take 2-5 minutes...")
    print()
    
    import json
    request_id = f"python_test_{int(time.time())}"
    
    js_code = f"""
    window.flowGenerator.generate(
        {json.dumps(test_config['prompt'])},
        {{
            aspectRatio: {json.dumps(test_config['aspectRatio'])},
            model: {json.dumps(test_config['model'])},
            outputCount: {test_config['outputCount']},
            mode: {json.dumps(test_config['mode'])},
            createNewProject: false,
            requestId: {json.dumps(request_id)}
        }}
    )
    """
    
    try:
        result = flow_tab.call_method('Runtime.evaluate',
                                      expression=js_code,
                                      awaitPromise=True,
                                      returnByValue=True,
                                      timeout=360000)  # 6 minutes
        
        response = result.get('result', {}).get('value', {})
        
        print("\n" + "="*60)
        if response.get('status') == 'complete':
            print("✅ VIDEO GENERATED SUCCESSFULLY!")
            print(f"📹 Video URL: {response.get('videoUrl', 'N/A')}")
        else:
            print("⚠️ GENERATION STATUS:")
            print(f"   {response}")
        print("="*60 + "\n")
        
    except Exception as e:
        print(f"\n❌ Error: {e}\n")
    
    finally:
        flow_tab.stop()
        print("Disconnected")


if __name__ == '__main__':
    generate_test_video()
