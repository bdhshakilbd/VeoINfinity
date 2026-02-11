"""
Test if window.flowGenerator exists in Flow page
Run this in Chrome DevTools Console(F12) on the Flow page
"""

# Test 1: Check if extension API exists
console.log('Testing window.flowGenerator...');
console.log('Type:', typeof window.flowGenerator);

if (typeof window.flowGenerator === 'object') {
    console.log('✅ Extension loaded!');
    console.log('Available methods:', Object.keys(window.flowGenerator));
    
    # Test 2: Test the API
    console.log('\n🧪 Testing generate function...');

    window.flowGenerator.generate(
        "A golden retriever running through a sunny meadow",
        {
            aspectRatio: "Landscape (16:9)",
            model: "Veo 3.1 - Fast",
            outputCount: 1,
            mode: "Text to Video",
            createNewProject: false,
            requestId: "console_test_" + Date.now()
        }
    ).then(result => {
        console.log('✅ Generation result:', result);
    }).catch(err => {
        console.error('❌ Generation error:', err);
    });

} else {
    console.error('❌ Extension not loaded!');
    console.log('Make sure:');
    console.log('1. Veo3 Infinity extension is installed');
    console.log('2. You refreshed this page after installing');
}
