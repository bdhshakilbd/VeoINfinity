"""
Veo3 Infinity - Simple Video Generation
Directly sends message to content script via side panel
"""

import time
from pychrome import Browser

print("\n" + "="*60)
print("🎬 VEO3 INFINITY - SIMPLE VIDEO GENERATION")
print("="*60)

# Connect
print("\n[1/2] Connecting to Chrome...")
browser = Browser(url='http://127.0.0.1:9222')
print("✅ Connected")

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
    exit(1)

sidepanel_tab.start()
time.sleep(1)

print("✅ Found side panel")
print("\n🚀 Starting video generation...")
print("⏳ Please wait 2-5 minutes...\n")

# Send generation command via side panel
js_code = """
(async () => {
    const options = {
        prompt: 'A majestic golden retriever running through a sunny meadow in slow motion',
        aspectRatio: '16:9',
        model: 'Veo 3.1 - Fast',
        outputCount: 1,
        mode: 'Text to Video',
        createNewProject: false
    };
    
    // Find Flow tab
    const tabs = await chrome.tabs.query({});
    const flowTab = tabs.find(t => t.url && t.url.includes('labs.google/fx/tools/flow'));
    
    if (!flowTab) {
        return 'NO_FLOW_TAB';
    }
    
    // Send generate message
    const requestId = 'python_' + Date.now();
    
    return new Promise((resolve) => {
        chrome.tabs.sendMessage(flowTab.id, {
            type: 'GENERATE_VIDEO',
            requestId: requestId,
            options: options
        }, (response) => {
            if (chrome.runtime.lastError) {
                resolve('ERROR: ' + chrome.runtime.lastError.message);
            } else {
                resolve('SUCCESS: ' + JSON.stringify(response));
            }
        });
    });
})();
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
        print("\n📹 Check your Flow page:")
        print("   • Settings should be applied")
        print("   • Prompt should be filled")
        print("   • Generation should start automatically")
        print("\n⏰ Wait 2-5 minutes for the video to complete")
    elif 'NO_FLOW_TAB' in str(response):
        print("\n❌ No Flow tab found!")
        print("   Please open https://labs.google/fx/tools/flow/ first")
    else:
        print(f"\n⚠️ Unexpected response: {response}")
        
except Exception as e:
    print(f"\n❌ Error: {e}")

finally:
    sidepanel_tab.stop()
    print("\n" + "="*60)
    print("Done")
    print("="*60 + "\n")
