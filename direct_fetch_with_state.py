import asyncio
from playwright.async_api import async_playwright

async def direct_fetch_with_state_prep():
    """
    Prepare React state properly, then make direct fetch call.
    This should bypass automation detection by having proper state context.
    """
    print("🚀 Preparing React state and making direct API call...")
    
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

            # JavaScript to prepare state and make direct fetch
            js_code = f"""
            async () => {{
                const prompt = "A dragon flying over a medieval castle, epic cinematic shot.";
                
                // STEP 1: Prepare React state by updating textarea
                console.log('Step 1: Preparing React state...');
                const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
                if (!textarea) return {{success: false, error: 'Textarea not found'}};
                
                const propsKey = Object.keys(textarea).find(k => k.startsWith('__reactProps$'));
                if (!propsKey) return {{success: false, error: 'React props not found'}};
                
                const props = textarea[propsKey];
                textarea.value = prompt;
                
                // Trigger onChange to update React state
                if (props.onChange) {{
                    props.onChange({{
                        target: textarea,
                        currentTarget: textarea,
                        nativeEvent: new Event('change', {{bubbles: true}})
                    }});
                }}
                
                // Wait for state to propagate
                await new Promise(r => setTimeout(r, 1000));
                console.log('✓ React state updated');
                
                // STEP 2: Get access token
                console.log('Step 2: Getting access token...');
                const sessionResp = await fetch('https://labs.google/fx/api/auth/session');
                const sessionData = await sessionResp.json();
                const accessToken = sessionData.access_token;
                if (!accessToken) return {{success: false, error: 'No access token'}};
                console.log('✓ Access token obtained');

                // STEP 3: Get reCAPTCHA token (with proper action)
                console.log('Step 3: Getting reCAPTCHA token...');
                const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
                const recaptchaToken = await grecaptcha.enterprise.execute(siteKey, {{action: 'VIDEO_GENERATION'}});
                if (!recaptchaToken) return {{success: false, error: 'No reCAPTCHA token'}};
                console.log('✓ reCAPTCHA token obtained');

                // STEP 4: Prepare payload (matching official format)
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
                    "requests": [
                        {{
                            "aspectRatio": "VIDEO_ASPECT_RATIO_LANDSCAPE",
                            "seed": Math.floor(Math.random() * 10000),
                            "textInput": {{
                                "prompt": prompt
                            }},
                            "videoModelKey": "veo_3_1_t2v_fast_ultra_relaxed",
                            "metadata": {{
                                "sceneId": sceneId
                            }}
                        }}
                    ]
                }};
                
                // STEP 5: Make direct fetch call
                console.log('Step 4: Making direct API call...');
                const apiResp = await fetch('https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText', {{
                    method: 'POST',
                    headers: {{
                        'Authorization': 'Bearer ' + accessToken,
                        'Content-Type': 'application/json'
                    }},
                    body: JSON.stringify(payload)
                }});
                
                const apiData = await apiResp.json();
                console.log('API Response:', apiData);
                
                return {{
                    success: apiResp.ok,
                    status: apiResp.status,
                    statusText: apiResp.statusText,
                    data: apiData,
                    prompt: prompt,
                    sceneId: sceneId
                }};
            }}
            """

            print("⏳ Executing state preparation + direct API call...")
            result = await flow_page.evaluate(js_code)
            
            print("\n" + "="*60)
            print("DIRECT FETCH RESULT (with state prep):")
            print("="*60)
            
            if result.get('success'):
                print(f"✅ SUCCESS - HTTP {result.get('status')}")
                print(f"   Prompt: {result.get('prompt')}")
                print(f"   Scene ID: {result.get('sceneId')}")
                print(f"   Response: {result.get('data')}")
            else:
                print(f"❌ FAILED - HTTP {result.get('status')}")
                print(f"   Error: {result.get('data')}")
            
            print("="*60)
            
            await browser.close()
            
        except Exception as e:
            print(f"✗ Error: {e}")

if __name__ == "__main__":
    asyncio.run(direct_fetch_with_state_prep())
