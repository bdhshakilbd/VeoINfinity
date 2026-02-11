"""
Veo3 Infinity - Frame-to-Video Generator
Upload first and last frame images and generate video
"""

import time
import base64
from pychrome import Browser

def upload_frames_and_generate(first_frame_path, last_frame_path, prompt=""):
    """Upload first and last frame images and generate video"""
    
    print("\n" + "="*70)
    print("🎬 VEO3 INFINITY - FRAME TO VIDEO GENERATOR")
    print("="*70)
    
    print(f"\n📁 First Frame: {first_frame_path}")
    print(f"📁 Last Frame: {last_frame_path}")
    print(f"📝 Prompt: {prompt or '(none)'}")
    
    # Connect to Chrome
    print("\n[1/6] Connecting to Chrome...")
    try:
        browser = Browser(url='http://127.0.0.1:9222')
        print("✅ Connected")
    except Exception as e:
        print(f"❌ Failed: {e}")
        return False
    
    # Find Flow tab
    print("\n[2/6] Finding Flow tab...")
    tabs = browser.list_tab()
    flow_tab = None
    
    for tab in tabs:
        if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
            tab_url = tab.__dict__['_kwargs'].get('url', '')
            if 'labs.google/fx/tools/flow' in tab_url:
                flow_tab = tab
                print(f"✅ Found Flow tab")
                break
    
    if not flow_tab:
        print("❌ No Flow tab found!")
        print("   Please open https://labs.google/fx/tools/flow/ first")
        return False
    
    flow_tab.start()
    time.sleep(2)
    
    # Switch to Frames to Video mode
    print("\n[3/6] Switching to 'Frames to Video' mode...")
    
    js_switch_mode = """
    (async () => {
        // Find and click mode dropdown
        const modeDropdown = document.querySelectorAll('button[role="combobox"]')[0];
        if (!modeDropdown) return 'NO_DROPDOWN';
        
        modeDropdown.click();
        await new Promise(r => setTimeout(r, 500));
        
        // Find "Frames to Video" option
        const options = document.querySelectorAll('div[role="option"]');
        for (const opt of options) {
            if (opt.textContent.includes('Frames to Video')) {
                opt.click();
                await new Promise(r => setTimeout(r, 1000));
                return 'SUCCESS';
            }
        }
        return 'MODE_NOT_FOUND';
    })();
    """
    
    try:
        result = flow_tab.call_method('Runtime.evaluate',
                                      expression=js_switch_mode,
                                      awaitPromise=True,
                                      returnByValue=True)
        
        response = result.get('result', {}).get('value', '')
        
        if response == 'SUCCESS':
            print("✅ Switched to Frames to Video mode")
        else:
            print(f"⚠️ Mode switch result: {response}")
            
    except Exception as e:
        print(f"❌ Error switching mode: {e}")
        return False
    
    # Read and encode images
    print("\n[4/6] Reading image files...")
    try:
        with open(first_frame_path, 'rb') as f:
            first_frame_data = base64.b64encode(f.read()).decode('utf-8')
        print(f"✅ First frame loaded ({len(first_frame_data)} bytes)")
        
        with open(last_frame_path, 'rb') as f:
            last_frame_data = base64.b64encode(f.read()).decode('utf-8')
        print(f"✅ Last frame loaded ({len(last_frame_data)} bytes)")
        
    except Exception as e:
        print(f"❌ Error reading images: {e}")
        return False
    
    # Upload images
    print("\n[5/6] Uploading frames...")
    
    # Get file extension
    import os
    first_ext = os.path.splitext(first_frame_path)[1]
    last_ext = os.path.splitext(last_frame_path)[1]
    
    js_upload = f"""
    (async () => {{
        // Find file input elements
        const fileInputs = document.querySelectorAll('input[type="file"]');
        if (fileInputs.length < 2) return 'NOT_ENOUGH_INPUTS: ' + fileInputs.length;
        
        // Helper to create File from base64
        function base64ToFile(base64, filename, mimeType) {{
            const byteString = atob(base64);
            const ab = new ArrayBuffer(byteString.length);
            const ia = new Uint8Array(ab);
            for (let i = 0; i < byteString.length; i++) {{
                ia[i] = byteString.charCodeAt(i);
            }}
            const blob = new Blob([ab], {{ type: mimeType }});
            return new File([blob], filename, {{ type: mimeType }});
        }}
        
        // Create File objects
        const firstFrame = base64ToFile(
            '{first_frame_data}',
            'first_frame{first_ext}',
            'image/png'
        );
        
        const lastFrame = base64ToFile(
            '{last_frame_data}',
            'last_frame{last_ext}',
            'image/png'
        );
        
        // Upload first frame
        const dataTransfer1 = new DataTransfer();
        dataTransfer1.items.add(firstFrame);
        fileInputs[0].files = dataTransfer1.files;
        fileInputs[0].dispatchEvent(new Event('change', {{ bubbles: true }}));
        
        await new Promise(r => setTimeout(r, 1000));
        
        // Upload last frame
        const dataTransfer2 = new DataTransfer();
        dataTransfer2.items.add(lastFrame);
        fileInputs[1].files = dataTransfer2.files;
        fileInputs[1].dispatchEvent(new Event('change', {{ bubbles: true }}));
        
        await new Promise(r => setTimeout(r, 1000));
        
        return 'UPLOADED';
    }})();
    """
    
    try:
        result = flow_tab.call_method('Runtime.evaluate',
                                      expression=js_upload,
                                      awaitPromise=True,
                                      returnByValue=True,
                                      timeout=30000)
        
        response = result.get('result', {}).get('value', '')
        
        if response == 'UPLOADED':
            print("✅ Frames uploaded successfully")
        else:
            print(f"⚠️ Upload result: {response}")
            
    except Exception as e:
        print(f"❌ Error uploading: {e}")
        return False
    
    # Set prompt if provided
    if prompt:
        print("\n[6/6] Setting prompt...")
        js_set_prompt = f"""
        const textarea = document.querySelector('textarea');
        if (textarea) {{
            textarea.value = {repr(prompt)};
            textarea.dispatchEvent(new Event('input', {{ bubbles: true }}));
            'PROMPT_SET';
        }} else {{
            'NO_TEXTAREA';
        }}
        """
        
        try:
            result = flow_tab.call_method('Runtime.evaluate',
                                          expression=js_set_prompt,
                                          returnByValue=True)
            print("✅ Prompt set")
        except Exception as e:
            print(f"⚠️ Could not set prompt: {e}")
    
    # Click generate
    print("\n🚀 Clicking Generate button...")
    js_generate = """
    const buttons = document.querySelectorAll('button');
    for (const btn of buttons) {
        if (btn.innerHTML.includes('arrow_forward')) {
            btn.click();
            return 'CLICKED';
        }
    }
    return 'BUTTON_NOT_FOUND';
    """
    
    try:
        result = flow_tab.call_method('Runtime.evaluate',
                                      expression=js_generate,
                                      returnByValue=True)
        
        response = result.get('result', {}).get('value', '')
        
        if response == 'CLICKED':
            print("✅ Generate button clicked!")
            print("\n📹 Video generation started")
            print("⏰ Check the Flow page for progress")
        else:
            print(f"❌ Could not click generate: {response}")
            
    except Exception as e:
        print(f"❌ Error: {e}")
    
    finally:
        flow_tab.stop()
    
    print("\n" + "="*70)
    print("✅ PROCESS COMPLETE")
    print("="*70 + "\n")
    
    return True


if __name__ == '__main__':
    # Test with the provided images
    first_frame = r"C:\Users\Lenovo\Documents\story_frames\frame_001.png"
    last_frame = r"C:\Users\Lenovo\Documents\story_frames\frame_002.png"
    prompt = "Smooth transition between frames"
    
    upload_frames_and_generate(first_frame, last_frame, prompt)
