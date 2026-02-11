import asyncio
from playwright.async_api import async_playwright

async def invisible_api_call():
    """
    Completely invisible API call - NO UI changes at all.
    No textarea interaction, no visible changes.
    """
    print("🚀 Invisible API call (zero UI interaction)...")
    
    async with async_playwright() as p:
        try:
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            # Find Flow page (any Flow page works)
            flow_page = None
            for context in browser.contexts:
                for page in context.pages:
                    if "labs.google/fx/tools/flow" in page.url:
                        flow_page = page
                        break
                if flow_page: break
            
            if not flow_page:
                print("✗ Flow page not found. Please open https://labs.google/fx/tools/flow")
                await browser.close()
                return

            print(f"✓ Found Flow page: {flow_page.url}")

            # Extract project ID if available (optional)
            project_id = None
            if "/project/" in flow_page.url:
                project_id = flow_page.url.split("/project/")[-1].split("?")[0]
                print(f"✓ Project ID: {project_id}")
            else:
                print("✓ No project ID (homepage) - will use empty string")
                project_id = ""  # Empty string works for API call

            # JavaScript for completely invisible API call
            js_code = f"""
            async () => {{
                const prompt = "A mystical forest with glowing mushrooms, fantasy art style, 4K.";
                
                try {{
                    // NO UI INTERACTION AT ALL
                    // Just pure API calls
                    
                    // STEP 1: Get access token
                    const sessionResp = await fetch('https://labs.google/fx/api/auth/session', {{
                        credentials: 'include'
                    }});
                    const sessionData = await sessionResp.json();
                    const accessToken = sessionData.access_token;
                    if (!accessToken) throw new Error('No access token');
                    
                    // STEP 2: Get reCAPTCHA token
                    const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
                    const recaptchaToken = await grecaptcha.enterprise.execute(siteKey, {{
                        action: 'VIDEO_GENERATION'
                    }});
                    if (!recaptchaToken) throw new Error('No reCAPTCHA token');
                    
                    // STEP 3: Prepare payload (no UI state needed)
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
                    
                    // STEP 4: Direct API call (no UI involvement)
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
                        method: 'Invisible (zero UI)',
                        uiChanged: false
                    }};
                    
                }} catch (err) {{
                    return {{
                        success: false,
                        error: err.message
                    }};
                }}
            }}
            """

            print("⏳ Executing invisible API call (no UI changes)...")
            result = await flow_page.evaluate(js_code)
            
            print("\n" + "="*60)
            print("INVISIBLE API CALL RESULT:")
            print("="*60)
            
            if result.get('success'):
                print(f"✅ SUCCESS - HTTP {result.get('status')}")
                print(f"   Method: {result.get('method')}")
                print(f"   UI Changed: {result.get('uiChanged')}")
                print(f"   Prompt: {result.get('prompt')}")
                print(f"   Scene ID: {result.get('sceneId')}")
                
                data = result.get('data', {})
                if 'operations' in data:
                    ops = data['operations'][0] if data['operations'] else {}
                    print(f"   Operation: {ops.get('operation', {}).get('name', 'N/A')}")
                    print(f"   Status: {ops.get('status', 'N/A')}")
                print(f"   Credits: {data.get('remainingCredits', 'N/A')}")
                print("\n💡 The browser UI should show NO changes!")
            else:
                print(f"❌ FAILED - HTTP {result.get('status', 'N/A')}")
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
    asyncio.run(invisible_api_call())
