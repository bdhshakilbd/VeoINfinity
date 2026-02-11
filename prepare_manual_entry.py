import asyncio
from playwright.async_api import async_playwright

async def prepare_for_manual_entry():
    prompt = "A futuristic city with floating neon structures, cinematic aerial view, hyper-detailed."
    print(f"🚀 Preparing browser for manual entry...")
    print(f"📝 Prompt: {prompt}")

    async with async_playwright() as p:
        try:
            # Connect to Chrome via CDP on port 9222
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            flow_page = None
            for context in browser.contexts:
                for page in context.pages:
                    if "labs.google/fx/tools/flow/project" in page.url:
                        flow_page = page
                        break
                if flow_page: break
            
            if not flow_page:
                print("✗ Flow project page not found. Please open a project first.")
                await browser.close()
                return

            print(f"✓ Found Flow page: {flow_page.url}")

            # Using the "React Props" method to set the value so the "Create" button enables
            js_script = f"""
            (() => {{
                const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
                if (!textarea) {{
                    console.error('Textarea not found');
                    return false;
                }}
                
                // Get React props
                const propsKey = Object.keys(textarea).find(k => k.startsWith('__reactProps$'));
                const props = textarea[propsKey];
                
                // Set value
                textarea.value = `{prompt}`;
                
                // Trigger React onChange
                if (props && props.onChange) {{
                    props.onChange({{
                        target: textarea,
                        currentTarget: textarea,
                        nativeEvent: new Event('change', {{ bubbles: true }})
                    }});
                }}
                
                textarea.focus();
                console.log('✓ Prompt pasted via React props. Ready for manual Enter.');
                return true;
            }})()
            """

            success = await flow_page.evaluate(js_script)
            if success:
                print("\n✅ Prompt has been pasted and textarea is focused.")
                print("👉 YOU CAN NOW MANUALLY PRESS 'ENTER' OR CLICK 'CREATE' IN THE BROWSER.")
            else:
                print("❌ Failed to paste prompt.")

            await browser.close()
            
        except Exception as e:
            print(f"✗ Error: {e}")

if __name__ == "__main__":
    asyncio.run(prepare_for_manual_entry())
