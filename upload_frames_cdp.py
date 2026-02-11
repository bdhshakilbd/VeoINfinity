"""
Upload frames and generate video using CDP
Works with Chrome on port 9222
"""

from pychrome import Browser
import time
import os

def upload_and_generate():
    print("\n" + "="*70)
    print("🎬 FRAME TO VIDEO - CDP UPLOAD")
    print("="*70)
    
    # Image paths
    first_frame = r"C:\Users\Lenovo\Documents\story_frames\frame_001.png"
    last_frame = r"C:\Users\Lenovo\Documents\story_frames\frame_002.png"
    
    print(f"\n📁 First: {first_frame}")
    print(f"📁 Last: {last_frame}")
    
    # Check files exist
    if not os.path.exists(first_frame):
        print(f"❌ First frame not found!")
        return
    if not os.path.exists(last_frame):
        print(f"❌ Last frame not found!")
        return
    
    # Connect
    print("\n[1/5] Connecting to Chrome...")
    browser = Browser(url='http://127.0.0.1:9222')
    tabs = browser.list_tab()
    
    flow_tab = None
    for tab in tabs:
        if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
            url = tab.__dict__['_kwargs'].get('url', '')
            if 'labs.google/fx/tools/flow' in url:
                flow_tab = tab
                break
    
    if not flow_tab:
        print("❌ No Flow tab found")
        return
    
    flow_tab.start()
    time.sleep(2)
    print("✅ Connected to Flow tab")
    
    # Inspect upload buttons
    print("\n[2/5] Finding upload buttons...")
    
    js_inspect = """
    (() => {
        // Look for buttons with "add" icon or upload functionality
        const buttons = Array.from(document.querySelectorAll('button'));
        const addButtons = buttons.filter(b => 
            b.innerHTML.includes('add') || 
            b.innerHTML.includes('upload') ||
            b.getAttribute('aria-label')?.includes('add')
        );
        
        // Get their positions
        const positions = addButtons.map(btn => {
            const rect = btn.getBoundingClientRect();
            return {
                text: btn.textContent.trim(),
                html: btn.innerHTML.substring(0, 50),
                x: Math.round(rect.left + rect.width/2),
                y: Math.round(rect.top + rect.height/2),
                width: rect.width,
                height: rect.height
            };
        });
        
        return {
            addButtonCount: addButtons.length,
            positions: positions,
            fileInputs: document.querySelectorAll('input[type="file"]').length
        };
    })();
    """
    
    result = flow_tab.call_method('Runtime.evaluate',
                                  expression=js_inspect,
                                  returnByValue=True)
    
    data = result.get('result', {}).get('value', {})
    print(f"✅ Found {data.get('addButtonCount', 0)} add buttons")
    print(f"   File inputs: {data.get('fileInputs', 0)}")
    
    for i, pos in enumerate(data.get('positions', [])[:2]):
        print(f"   Button {i+1}: ({pos['x']}, {pos['y']}) - {pos['html'][:30]}")
    
    # Click first upload button
    print("\n[3/5] Clicking first upload area...")
    
    positions = data.get('positions', [])
    if len(positions) < 2:
        print("❌ Not enough upload buttons found")
        flow_tab.stop()
        return
    
    # Click first button to trigger file input
    js_click_first = f"""
    (() => {{
        const buttons = Array.from(document.querySelectorAll('button'));
        const addButtons = buttons.filter(b => 
            b.innerHTML.includes('add') || 
            b.innerHTML.includes('upload')
        );
        
        if (addButtons.length > 0) {{
            addButtons[0].click();
            return 'CLICKED_FIRST';
        }}
        return 'NO_BUTTON';
    }})();
    """
    
    result = flow_tab.call_method('Runtime.evaluate',
                                  expression=js_click_first,
                                  returnByValue=True)
    
    print(f"   Result: {result.get('result', {}).get('value', '')}")
    time.sleep(1)
    
    # Set file on input
    print("\n[4/5] Uploading files...")
    
    js_upload = f"""
    (() => {{
        const fileInputs = document.querySelectorAll('input[type="file"]');
        
        if (fileInputs.length === 0) {{
            return 'NO_INPUTS';
        }}
        
        // We need to trigger the file inputs programmatically
        // This requires the Input.setFileInputFiles CDP method
        return {{
            inputCount: fileInputs.length,
            message: 'USE_CDP_METHOD'
        }};
    }})();
    """
    
    result = flow_tab.call_method('Runtime.evaluate',
                                  expression=js_upload,
                                  returnByValue=True)
    
    response = result.get('result', {}).get('value', {})
    print(f"   {response}")
    
    # Use CDP to set files
    print("\n[5/5] Using CDP to upload files...")
    
    # Get file input elements
    js_get_inputs = """
    (() => {
        const inputs = Array.from(document.querySelectorAll('input[type="file"]'));
        return inputs.map((input, i) => ({
            index: i,
            id: input.id,
            name: input.name,
            accept: input.accept
        }));
    })();
    """
    
    result = flow_tab.call_method('Runtime.evaluate',
                                  expression=js_get_inputs,
                                  returnByValue=True)
    
    inputs = result.get('result', {}).get('value', [])
    print(f"   Found {len(inputs)} file inputs")
    
    if len(inputs) >= 2:
        # Get node IDs for the inputs
        js_get_node = """
        document.querySelectorAll('input[type="file"]')[0]
        """
        
        result = flow_tab.call_method('Runtime.evaluate',
                                      expression=js_get_node)
        
        object_id = result.get('result', {}).get('objectId')
        
        if object_id:
            # Try to set files using CDP
            try:
                # This might not work due to security restrictions
                flow_tab.call_method('DOM.setFileInputFiles',
                                    files=[first_frame],
                                    objectId=object_id)
                print(f"✅ Uploaded first frame")
            except Exception as e:
                print(f"⚠️ CDP upload failed: {e}")
                print("\n💡 Manual upload required:")
                print("   1. Click the first upload area")
                print(f"   2. Select: {first_frame}")
                print("   3. Click the second upload area")  
                print(f"   4. Select: {last_frame}")
    
    flow_tab.stop()
    
    print("\n" + "="*70)
    print("✅ INSPECTION COMPLETE")
    print("="*70 + "\n")


if __name__ == '__main__':
    upload_and_generate()
