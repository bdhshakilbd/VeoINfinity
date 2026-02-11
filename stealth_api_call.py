import asyncio
from playwright.async_api import async_playwright

async def stealth_direct_api():
    """
    Make direct API call WITHOUT pasting text in textarea.
    Just prepare minimal context and call API directly.
    """
    print("🚀 Stealth API call (no textarea interaction)...")
    
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

            # JavaScript for stealth API call
            js_code = f"""
            async () => {{
                const prompt = "A phoenix rising from flames, mythical creature, cinematic lighting.";
                
                try {{
                    // STEP 1: Simulate minimal user activity (mouse movement)
                    // This creates a "human presence" signal
                    const moveEvent = new MouseEvent('mousemove', {{
                        bubbles: true,
                        cancelable: true,
                        view: window,
                        clientX: Math.random() * 100,
                        clientY: Math.random() * 100
                    }});
                    document.dispatchEvent(moveEvent);
                    
                    // Small delay to let event propagate
                    await new Promise(r => setTimeout(r, 200));
                    
                    // STEP 2: Get access token
                    const sessionResp = await fetch('https://labs.google/fx/api/auth/session', {{
                        credentials: 'include'
                    }});
                    const sessionData = await sessionResp.json();
                    const accessToken = sessionData.access_token;
                    if (!accessToken) throw new Error('No access token');
                    
                    // STEP 3: Get reCAPTCHA token
                    const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
                    const recaptchaToken = await grecaptcha.enterprise.execute(siteKey, {{
                        action: 'VIDEO_GENERATION'
                    }});
                    if (!recaptchaToken) throw new Error('No reCAPTCHA token');
                    
                    // STEP 4: Prepare payload
                    const sessionId = ";" + Date.now();
                    const sceneId = crypto.randomUUID();
                    
                    const payload = {{
                        "clientContext": {{
                            "recaptchaContext": {{
                                "token": recaptchaToken,
                                "applicationType": "RECAPTCHA_APPLICATION_TYPE_WEB"
                            }},
                            "sessionId": sessionId,
                            "projectId": "{project_id}",
                            "tool": "PINHOLE",
                            "userPaygateTier": "PAYGATE_TIER_TWO"
                        }},
                        "requests": [{{
                            "aspectRatio": "VIDEO_ASPECT_RATIO_LANDSCAPE",
                            "seed": Math.floor(Math.random() * 10000),
                            "textInput": {{
                                "prompt": prompt
                            }},
                            "videoModelKey": "veo_3_1_t2v_fast_ultra_relaxed",
                            "metadata": {{
                                "sceneId": sceneId
                            }}
                        }}]
                    }};
                    
                    // STEP 5: Make API call
                    const apiResp = await fetch('https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText', {{
                        method: 'POST',
                        headers: {{
                            'Authorization': 'Bearer ' + accessToken,
                            'Content-Type': 'application/json'
                        }},
                        body: JSON.stringify(payload)
                    }});
                    
                    const apiData = await apiResp.json();
                    
                    return {{
                        success: apiResp.ok,
                        status: apiResp.status,
                        data: apiData,
                        prompt: prompt,
                        sceneId: sceneId,
                        method: 'Stealth (no textarea)'
                    }};
                    
                }} catch (err) {{
                    return {{
                        success: false,
                        error: err.message,
                        stack: err.stack
                    }};
                }}
            }}
            """

            print("⏳ Executing stealth API call...")
            result = await flow_page.evaluate(js_code)
            
            print("\n" + "="*60)
            print("STEALTH API CALL RESULT:")
            print("="*60)
            
            if result.get('success'):
                print(f"✅ SUCCESS - HTTP {result.get('status')}")
                print(f"   Method: {result.get('method')}")
                print(f"   Prompt: {result.get('prompt')}")
                print(f"   Scene ID: {result.get('sceneId')}")
                
                data = result.get('data', {})
                if 'operations' in data:
                    ops = data['operations'][0] if data['operations'] else {}
                    print(f"   Operation: {ops.get('operation', {}).get('name', 'N/A')}")
                    print(f"   Status: {ops.get('status', 'N/A')}")
                print(f"   Credits: {data.get('remainingCredits', 'N/A')}")
            else:
                print(f"❌ FAILED")
                print(f"   Error: {result.get('error')}")
                if result.get('data'):
                    print(f"   Response: {result.get('data')}")
            
            print("="*60)
            
            await browser.close()
            
        except Exception as e:
            print(f"✗ Error: {e}")
            import traceback
            traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(stealth_direct_api())
