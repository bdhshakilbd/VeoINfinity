"""
CDP Test using window.postMessage API
Works with CSP restrictions
"""

from pychrome import Browser

print("="*60)
print("🎬 CDP VIDEO GENERATION TEST (postMessage)")
print("="*60)

# Connect
browser = Browser(url='http://127.0.0.1:9223')
print("✅ Connected")

# Find any tab
tabs = browser.list_tab()
if not tabs:
    print("❌ No tabs found")
    exit(1)

# Use first tab
tab = tabs[0]
tab.start()

print("\n🧪 Testing extension via postMessage...")

# Test code using postMessage
test_js = """
new Promise((resolve) => {
    const requestId = 'test_' + Date.now();
    
    const handler = (event) => {
        if (event.data.type === 'VEO3_RESPONSE' && event.data.requestId === requestId) {
            window.removeEventListener('message', handler);
            resolve(event.data);
        }
    };
    
    window.addEventListener('message', handler);
    
    window.postMessage({
        type: 'VEO3_GENERATE',
        requestId: requestId,
        prompt: "A golden retriever running through a sunny meadow",
        opts: {
            aspectRatio: "Landscape (16:9)",
            model: "Veo 3.1 - Fast",
            outputCount: 1,
            mode: "Text to Video",
            createNewProject: false
        }
    }, '*');
    
    setTimeout(() => resolve({error: 'Timeout'}), 360000);
})
"""

print("🚀 Starting generation...")
result = tab.call_method('Runtime.evaluate',
                        expression=test_js,
                        awaitPromise=True,
                        returnByValue=True,
                        timeout=360000)

response = result.get('result', {}).get('value', {})

if response.get('result', {}).get('status') == 'complete':
    print("\n✅ VIDEO GENERATED!")
    print(f"Video URL: {response['result'].get('videoUrl')}")
elif response.get('error'):
    print(f"\n❌ Error: {response['error']}")
else:
    print(f"\n⚠️  Response: {response}")

tab.stop()
print("\n✅ Test complete")
