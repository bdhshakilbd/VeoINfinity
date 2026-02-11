"""
EXACT copy of extension's frame upload logic
Uses pychrome to inject the exact same JavaScript
"""

import time
import base64
import json
from pathlib import Path

try:
    from pychrome import Browser
except ImportError:
    print("Installing pychrome...")
    import subprocess
    import sys
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pychrome"])
    from pychrome import Browser


def generate_from_frames(first_frame_path, last_frame_path, prompt, port=9223):
    """Generate video using EXACT extension code"""
    
    import sys
    
    print("="*60, flush=True)
    print("🎞️ FRAME-TO-VIDEO (Extension Code)", flush=True)
    print("="*60, flush=True)
    print(f"Port: {port}", flush=True)
    print(f"Prompt: {prompt[:50]}...", flush=True)
    print("="*60, flush=True)
    print(flush=True)
    
    # Read frames
    print("📸 Reading frames...", flush=True)
    with open(first_frame_path, 'rb') as f:
        first_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    with open(last_frame_path, 'rb') as f:
        last_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    frames_json = json.dumps([
        {"data": first_b64, "name": "First Frame"},
        {"data": last_b64, "name": "Last Frame"}
    ])
    
    print("✅ Frames loaded", flush=True)
    
    # Connect
    print(f"\n🔌 Connecting to Chrome on port {port}...", flush=True)
    try:
        browser = Browser(url=f'http://127.0.0.1:{port}')
        print("✅ Connected", flush=True)
    except Exception as e:
        print(f"❌ Failed: {e}", flush=True)
        return
    
    # Find Flow tab
    print("\n🔍 Finding Flow tab...", flush=True)
    tabs = browser.list_tab()
    
    flow_tab = None
    for tab in tabs:
        tab_url = str(tab.url) if hasattr(tab, 'url') else ''
        if 'labs.google/fx/tools/flow' in tab_url and '/project/' in tab_url:
            print(f"✅ Found project tab", flush=True)
            flow_tab = tab
            break
    
    if not flow_tab:
        print("❌ No Flow project tab found!", flush=True)
        print("   Please open a project in Flow first", flush=True)
        print("   (Click '+ New project' on Flow homepage)", flush=True)
        return
    
    flow_tab.start()
    
    # This is the EXACT JavaScript from sidepanel.js lines 358-515
    js_code = f"""
(async (frames, promptText) => {{
    console.log(`🎞️ Frame Upload & Generate - ${{frames.length}} frame(s)`);
    
    // Track uploaded media IDs
    const uploadedMedia = [];
    const originalFetch = window.fetch;
    
    // Intercept fetch to monitor uploads
    window.fetch = async function (...args) {{
        const response = await originalFetch.apply(this, args);
        const url = args[0];
        
        if (url && url.toString().includes('uploadUserImage')) {{
            try {{
                const clonedResponse = response.clone();
                const data = await clonedResponse.json();
                
                if (data.mediaGenerationId) {{
                    uploadedMedia.push({{
                        id: data.mediaGenerationId.mediaGenerationId,
                        width: data.width,
                        height: data.height
                    }});
                    console.log('📡 UPLOAD DETECTED:');
                    console.log(`   Media ID: ${{data.mediaGenerationId.mediaGenerationId.substring(0, 50)}}...`);
                    console.log(`   Total uploads: ${{uploadedMedia.length}}/${{frames.length}}`);
                }}
            }} catch (e) {{}}
        }}
        
        return response;
    }};
    
    async function base64ToFile(base64, filename) {{
        const response = await originalFetch(base64);
        const blob = await response.blob();
        return new File([blob], filename, {{ type: 'image/png' }});
    }}

    async function uploadToButton(button, file, label) {{
        console.log(`📸 Uploading ${{label}}: ${{file.name}}`);
        
        button.click();
        await new Promise(r => setTimeout(r, 1000));
        
        const fileInput = document.querySelector('input[type="file"]');
        if (fileInput) {{
            const dataTransfer = new DataTransfer();
            dataTransfer.items.add(file);
            fileInput.files = dataTransfer.files;
            fileInput.dispatchEvent(new Event('change', {{ bubbles: true }}));
            fileInput.dispatchEvent(new Event('input', {{ bubbles: true }}));
            console.log('   📤 File set on input');
            
            await new Promise(r => setTimeout(r, 1500));
            
            const buttons = Array.from(document.querySelectorAll('button'));
            for (const btn of buttons) {{
                if (btn.textContent.includes('Crop and Save')) {{
                    console.log('   ✂️  Clicking Crop and Save...');
                    btn.click();
                    await new Promise(r => setTimeout(r, 3000));
                    return true;
                }}
            }}
        }}
        return false;
    }}

    try {{
        // Find frame buttons
        console.log('[1/4] Finding frame buttons...');
        let frameButtons = [];
        let attempts = 0;
        
        while (frameButtons.length < 2 && attempts < 10) {{
            frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));
            console.log(`   Attempt ${{attempts + 1}}: Found ${{frameButtons.length}} buttons`);
            
            if (frameButtons.length < 2) {{
                await new Promise(r => setTimeout(r, 500));
                attempts++;
            }}
        }}
        
        if (frameButtons.length < frames.length) {{
            throw new Error(`Need ${{frames.length}} button(s), found ${{frameButtons.length}}`);
        }}
        
        console.log(`✅ Found ${{frameButtons.length}} frame buttons`);
        
        // Upload each frame
        console.log('[2/4] Uploading frames...');
        for (let i = 0; i < frames.length; i++) {{
            const file = await base64ToFile(frames[i].data, `frame_${{i + 1}}.png`);
            console.log(`   [${{i + 1}}/${{frames.length}}] Uploading ${{frames[i].name}}...`);
            await uploadToButton(frameButtons[i], file, frames[i].name);
            await new Promise(r => setTimeout(r, 2000));
        }}
        
        // Wait for all uploads to complete
        console.log('[3/4] Verifying uploads...');
        console.log(`   Waiting for ${{frames.length}} upload(s) to complete...`);
        
        let waitAttempts = 0;
        while (uploadedMedia.length < frames.length && waitAttempts < 20) {{
            console.log(`   Upload status: ${{uploadedMedia.length}}/${{frames.length}} (attempt ${{waitAttempts + 1}}/20)`);
            await new Promise(r => setTimeout(r, 1000));
            waitAttempts++;
        }}
        
        if (uploadedMedia.length < frames.length) {{
            console.warn(`   ⚠️  Only ${{uploadedMedia.length}}/${{frames.length}} uploads detected`);
        }} else {{
            console.log('   ✅ All frames uploaded successfully!');
            uploadedMedia.forEach((m, i) => {{
                console.log(`   ${{i + 1}}. ${{m.id.substring(0, 60)}}...`);
            }});
        }}
        
        // Wait 5 seconds before setting prompt
        console.log('   ⏳ Waiting 5 seconds...');
        await new Promise(r => setTimeout(r, 5000));
        
        // Set prompt and generate
        console.log('[4/4] Setting prompt and generating video...');
        const textarea = document.querySelector('textarea');
        if (textarea) {{
            textarea.value = promptText;
            textarea.dispatchEvent(new Event('input', {{ bubbles: true }}));
            console.log('   ✅ Prompt set:', promptText.substring(0, 50) + '...');
        }}
        
        // Wait 1 second
        console.log('   ⏳ Waiting 1 second before clicking generate...');
        await new Promise(r => setTimeout(r, 1000));
        
        // Click generate button
        const buttons = document.querySelectorAll('button');
        for (const btn of buttons) {{
            if (btn.innerHTML.includes('arrow_forward')) {{
                btn.click();
                console.log('   ✅ Generate button clicked!');
                break;
            }}
        }}
        
        console.log('✅ PROCESS COMPLETE!');
        console.log('📹 Video generation should start shortly...');
        
        // Store for later use
        window.flowUploadedMedia = uploadedMedia;
        
        return {{ success: true }};
        
    }} catch (error) {{
        console.error('❌ ERROR:', error.message);
        return {{ success: false, error: error.message }};
    }} finally {{
        // Restore original fetch
        window.fetch = originalFetch;
    }}
}})({frames_json}, {json.dumps(prompt)})
"""
    
    try:
        print("\n📤 Executing extension code...", flush=True)
        result = flow_tab.call_method('Runtime.evaluate',
                                     expression=js_code,
                                     awaitPromise=True,
                                     returnByValue=True,
                                     timeout=180)
        
        response = result.get('result', {}).get('value', {})
        
        if response.get('success'):
            print("\n" + "="*60, flush=True)
            print("✅ VIDEO GENERATION STARTED!", flush=True)
            print("="*60, flush=True)
            print("📹 Check Chrome to see progress", flush=True)
            print("="*60, flush=True)
        else:
            error = response.get('error', 'Unknown error')
            print(f"\n❌ Failed: {error}", flush=True)
    
    except Exception as e:
        print(f"\n❌ Error: {e}", flush=True)
        import traceback
        traceback.print_exc()
    
    finally:
        flow_tab.stop()


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 4:
        print("Usage: python final_frame_gen.py <first_frame> <last_frame> <prompt> [port]")
        print('Example: python final_frame_gen.py frame1.png frame2.png "Beautiful sunset" 9223')
        print()
        print("IMPORTANT: Open a Flow project first!")
        print("  1. Go to https://labs.google/fx/tools/flow/")
        print("  2. Click '+ New project'")
        print("  3. Select 'Frames to Video' mode")
        print("  4. Then run this script")
        exit(1)
    
    first = sys.argv[1]
    last = sys.argv[2]
    prompt = sys.argv[3]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 9223
    
    generate_from_frames(first, last, prompt, port)
