"""
Simple Frame-to-Video Generator using Playwright
More reliable than raw CDP
"""

import asyncio
import base64
from pathlib import Path

async def generate_video_from_frames(first_frame_path, last_frame_path, prompt):
    """Generate video from frames using Playwright"""
    
    print("="*60)
    print("🎞️ FRAME-TO-VIDEO GENERATOR (Playwright)")
    print("="*60)
    print(f"First Frame: {first_frame_path}")
    print(f"Last Frame: {last_frame_path}")
    print(f"Prompt: {prompt}")
    print("="*60)
    print()
    
    # Check frames
    first_frame = Path(first_frame_path)
    last_frame = Path(last_frame_path)
    
    if not first_frame.exists():
        print(f"❌ First frame not found: {first_frame_path}")
        return
    
    if not last_frame.exists():
        print(f"❌ Last frame not found: {last_frame_path}")
        return
    
    # Read frames as base64
    print("📸 Reading frames...")
    with open(first_frame, 'rb') as f:
        first_frame_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    with open(last_frame, 'rb') as f:
        last_frame_b64 = 'data:image/png;base64,' + base64.b64encode(f.read()).decode()
    
    print("✅ Frames loaded")
    
    try:
        from playwright.async_api import async_playwright
    except ImportError:
        print("\n❌ Playwright not installed!")
        print("   Install with: pip install playwright")
        print("   Then run: playwright install chromium")
        return
    
    print("\n🚀 Starting browser...")
    
    async with async_playwright() as p:
        # Launch browser with extension
        extension_path = Path(__file__).parent / "flow_extension"
        
        browser = await p.chromium.launch_persistent_context(
            user_data_dir=str(Path.home() / "chrome_veo3_playwright"),
            headless=False,
            args=[
                f"--load-extension={extension_path.absolute()}",
                "--disable-extensions-except=" + str(extension_path.absolute()),
            ]
        )
        
        print("✅ Browser started")
        
        # Open Flow
        print("🌐 Opening Flow...")
        page = await browser.new_page()
        await page.goto("https://labs.google/fx/tools/flow/")
        
        print("⏳ Waiting for page to load...")
        await page.wait_for_timeout(8000)
        
        # Set zoom
        print("🔍 Setting zoom to 50%...")
        await page.evaluate("document.body.style.zoom = '0.5'")
        
        # Upload frames and generate
        print("\n📤 Uploading frames and generating...")
        
        result = await page.evaluate(f"""
        (async () => {{
            console.log('🎞️ Starting frame upload...');
            
            async function base64ToFile(base64, filename) {{
                const response = await fetch(base64);
                const blob = await response.blob();
                return new File([blob], filename, {{ type: 'image/png' }});
            }}
            
            async function uploadToButton(button, file, label) {{
                console.log(`📸 Uploading ${{label}}`);
                button.click();
                await new Promise(r => setTimeout(r, 1000));
                
                const fileInput = document.querySelector('input[type="file"]');
                if (fileInput) {{
                    const dataTransfer = new DataTransfer();
                    dataTransfer.items.add(file);
                    fileInput.files = dataTransfer.files;
                    fileInput.dispatchEvent(new Event('change', {{ bubbles: true }}));
                    await new Promise(r => setTimeout(r, 1500));
                    
                    const buttons = Array.from(document.querySelectorAll('button'));
                    for (const btn of buttons) {{
                        if (btn.textContent.includes('Crop and Save')) {{
                            btn.click();
                            await new Promise(r => setTimeout(r, 3000));
                            return true;
                        }}
                    }}
                }}
                return false;
            }}
            
            try {{
                // Switch mode
                const modeDropdown = document.querySelector('select#mode');
                if (modeDropdown) {{
                    modeDropdown.value = 'Frames to Video';
                    modeDropdown.dispatchEvent(new Event('change', {{ bubbles: true }}));
                    await new Promise(r => setTimeout(r, 2000));
                }}
                
                // Find buttons
                let frameButtons = [];
                for (let i = 0; i < 10; i++) {{
                    frameButtons = Array.from(document.querySelectorAll('button.sc-d02e9a37-1.hvUQuN'));
                    if (frameButtons.length >= 2) break;
                    await new Promise(r => setTimeout(r, 500));
                }}
                
                if (frameButtons.length < 2) {{
                    return {{ success: false, error: 'Frame buttons not found' }};
                }}
                
                // Upload frames
                const firstFile = await base64ToFile('{first_frame_b64}', 'first.png');
                await uploadToButton(frameButtons[0], firstFile, 'First');
                await new Promise(r => setTimeout(r, 2000));
                
                const lastFile = await base64ToFile('{last_frame_b64}', 'last.png');
                await uploadToButton(frameButtons[1], lastFile, 'Last');
                await new Promise(r => setTimeout(r, 5000));
                
                // Set prompt
                const textarea = document.querySelector('textarea');
                if (textarea) {{
                    textarea.value = '{prompt}';
                    textarea.dispatchEvent(new Event('input', {{ bubbles: true }}));
                }}
                
                await new Promise(r => setTimeout(r, 1000));
                
                // Click generate
                const buttons = document.querySelectorAll('button');
                for (const btn of buttons) {{
                    if (btn.innerHTML.includes('arrow_forward')) {{
                        btn.click();
                        return {{ success: true }};
                    }}
                }}
                
                return {{ success: false, error: 'Generate button not found' }};
                
            }} catch (error) {{
                return {{ success: false, error: error.message }};
            }}
        }})()
        """)
        
        if result.get('success'):
            print("\n" + "="*60)
            print("✅ VIDEO GENERATION STARTED!")
            print("="*60)
            print("📹 Check the browser to see progress")
            print("\n⏸️  Browser will stay open. Close manually when done.")
            
            # Keep browser open
            await asyncio.sleep(999999)
        else:
            print(f"\n❌ Failed: {result.get('error')}")
            await browser.close()


async def main():
    import sys
    
    if len(sys.argv) < 4:
        print("Usage: python playwright_frame_gen.py <first_frame> <last_frame> <prompt>")
        return
    
    await generate_video_from_frames(sys.argv[1], sys.argv[2], sys.argv[3])


if __name__ == "__main__":
    asyncio.run(main())
