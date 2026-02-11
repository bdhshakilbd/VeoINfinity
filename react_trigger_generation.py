import asyncio
from playwright.async_api import async_playwright

async def generate_via_react_trigger():
    """
    Trigger video generation by simulating React button click via props.
    This bypasses automation detection by using React's internal handlers.
    """
    print("🚀 Triggering video generation via React handlers...")
    
    async with async_playwright() as p:
        try:
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            # Find Flow page
            flow_page = None
            for context in browser.contexts:
                for page in context.pages:
                    if "labs.google/fx/tools/flow/project" in page.url:
                        flow_page = page
                        break
                if flow_page: break
            
            if not flow_page:
                print("✗ Flow page not found")
                await browser.close()
                return

            project_id = flow_page.url.split("/project/")[-1].split("?")[0]
            print(f"✓ Project ID: {project_id}")

            # JavaScript to trigger generation via React handlers
            js_code = """
            async () => {
                const prompt = "A majestic eagle soaring through mountain peaks at sunset.";
                
                // Step 1: Set prompt via React props (updates state)
                const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
                if (!textarea) return {success: false, error: 'Textarea not found'};
                
                const propsKey = Object.keys(textarea).find(k => k.startsWith('__reactProps$'));
                if (!propsKey) return {success: false, error: 'React props not found'};
                
                const props = textarea[propsKey];
                textarea.value = prompt;
                
                // Trigger onChange to update React state
                if (props.onChange) {
                    props.onChange({
                        target: textarea,
                        currentTarget: textarea,
                        nativeEvent: new Event('change', {bubbles: true})
                    });
                }
                
                // Wait for state update
                await new Promise(r => setTimeout(r, 500));
                
                // Step 2: Find and click Create button via React props
                const buttons = [...document.querySelectorAll('button')];
                const createBtn = buttons.find(b => 
                    b.textContent && 
                    (b.textContent.includes('Create') || b.textContent.includes('Generate'))
                );
                
                if (!createBtn) return {success: false, error: 'Create button not found'};
                
                const btnPropsKey = Object.keys(createBtn).find(k => k.startsWith('__reactProps$'));
                if (!btnPropsKey) return {success: false, error: 'Button props not found'};
                
                const btnProps = createBtn[btnPropsKey];
                
                // Trigger onClick handler directly (bypasses automation detection)
                if (btnProps.onClick) {
                    const clickEvent = {
                        target: createBtn,
                        currentTarget: createBtn,
                        type: 'click',
                        bubbles: true,
                        cancelable: true,
                        isTrusted: true,
                        preventDefault: () => {},
                        stopPropagation: () => {}
                    };
                    
                    btnProps.onClick(clickEvent);
                    
                    return {
                        success: true, 
                        message: 'Generation triggered via React onClick',
                        prompt: prompt
                    };
                } else {
                    return {success: false, error: 'onClick handler not found'};
                }
            }
            """

            print("⏳ Executing React-based generation trigger...")
            result = await flow_page.evaluate(js_code)
            
            print("\n" + "="*60)
            if result.get('success'):
                print("✅ SUCCESS - Video generation triggered!")
                print(f"   Prompt: {result.get('prompt')}")
                print(f"   Method: {result.get('message')}")
                print("\n🎬 Video is now generating in the browser.")
            else:
                print(f"❌ FAILED: {result.get('error')}")
            print("="*60)
            
            await browser.close()
            
        except Exception as e:
            print(f"✗ Error: {e}")

if __name__ == "__main__":
    asyncio.run(generate_via_react_trigger())
