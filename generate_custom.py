"""
Veo3 Infinity - Video Generator with Custom Prompt
Usage: python generate_custom.py "your prompt here"
"""

import sys
import time
from pychrome import Browser

def generate_video(prompt, aspect_ratio='16:9', model='Veo 3.1 - Fast', outputs=1):
    """Generate a video with custom parameters"""
    
    print("\n" + "="*60)
    print("🎬 VEO3 INFINITY - VIDEO GENERATOR")
    print("="*60)
    
    print(f"\n📋 Configuration:")
    print(f"   Prompt: {prompt}")
    print(f"   Aspect Ratio: {aspect_ratio}")
    print(f"   Model: {model}")
    print(f"   Outputs: {outputs}")
    
    # Connect
    print("\n[1/2] Connecting to Chrome...")
    try:
        browser = Browser(url='http://127.0.0.1:9222')
        print("✅ Connected")
    except Exception as e:
        print(f"❌ Failed: {e}")
        return False
    
    # Find side panel
    print("\n[2/2] Finding side panel...")
    tabs = browser.list_tab()
    sidepanel_tab = None
    
    for tab in tabs:
        if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
            tab_url = tab.__dict__['_kwargs'].get('url', '')
            if 'sidepanel.html' in tab_url:
                sidepanel_tab = tab
                break
    
    if not sidepanel_tab:
        print("❌ Side panel not found! Please open it first.")
        return False
    
    sidepanel_tab.start()
    time.sleep(1)
    
    print("✅ Found side panel")
    print("\n🚀 Starting video generation...")
    print("⏳ Please wait 2-5 minutes...\n")
    
    # Prepare aspect ratio string
    aspect_str = f"Landscape ({aspect_ratio})" if aspect_ratio == '16:9' else f"Portrait ({aspect_ratio})"
    
    # Build JavaScript code
    js_code = f"""
    (async () => {{
        const options = {{
            prompt: {repr(prompt)},
            aspectRatio: {repr(aspect_str)},
            model: {repr(model)},
            outputCount: {outputs},
            mode: 'Text to Video',
            createNewProject: false
        }};
        
        // Find Flow tab
        const tabs = await chrome.tabs.query({{}});
        const flowTab = tabs.find(t => t.url && t.url.includes('labs.google/fx/tools/flow'));
        
        if (!flowTab) {{
            return 'NO_FLOW_TAB';
        }}
        
        // Send generate message
        const requestId = 'python_' + Date.now();
        
        return new Promise((resolve) => {{
            chrome.tabs.sendMessage(flowTab.id, {{
                type: 'GENERATE_VIDEO',
                requestId: requestId,
                options: options
            }}, (response) => {{
                if (chrome.runtime.lastError) {{
                    resolve('ERROR: ' + chrome.runtime.lastError.message);
                }} else {{
                    resolve('SUCCESS: ' + JSON.stringify(response));
                }}
            }});
        }});
    }})();
    """
    
    try:
        result = sidepanel_tab.call_method('Runtime.evaluate',
                                           expression=js_code,
                                           awaitPromise=True,
                                           returnByValue=True,
                                           timeout=10000)
        
        response = result.get('result', {}).get('value', '')
        
        print(f"📋 Response: {response}")
        
        if 'SUCCESS' in str(response):
            print("\n✅ VIDEO GENERATION STARTED!")
            print("\n📹 Check your Flow page for progress")
            print("⏰ Estimated time: 2-5 minutes\n")
            return True
        elif 'NO_FLOW_TAB' in str(response):
            print("\n❌ No Flow tab found!")
            print("   Please open https://labs.google/fx/tools/flow/ first\n")
            return False
        else:
            print(f"\n⚠️ Unexpected response: {response}\n")
            return False
            
    except Exception as e:
        print(f"\n❌ Error: {e}\n")
        return False
    
    finally:
        sidepanel_tab.stop()


if __name__ == '__main__':
    # Get prompt from command line or use default
    if len(sys.argv) > 1:
        prompt = ' '.join(sys.argv[1:])
    else:
        # Default test prompts
        test_prompts = [
            "A serene sunset over a calm ocean with waves gently lapping the shore",
            "A futuristic city at night with neon lights and flying cars",
            "An astronaut floating in space with Earth in the background",
            "A cat playing with a ball of yarn in slow motion"
        ]
        
        print("\n" + "="*60)
        print("TEST PROMPTS - Choose one:")
        print("="*60)
        for i, p in enumerate(test_prompts, 1):
            print(f"{i}. {p}")
        
        try:
            choice = input("\nEnter number (1-4) or press Enter for #1: ").strip()
            if choice == '':
                choice = '1'
            idx = int(choice) - 1
            prompt = test_prompts[idx]
        except:
            prompt = test_prompts[0]
    
    # Generate the video
    success = generate_video(prompt)
    
    print("="*60)
    if success:
        print("✅ GENERATION STARTED")
    else:
        print("❌ GENERATION FAILED")
    print("="*60 + "\n")
