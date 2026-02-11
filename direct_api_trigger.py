import asyncio
import json
from playwright.async_api import async_playwright

async def trigger_direct_api():
    print("🚀 Starting Direct API Generation Test...")
    async with async_playwright() as p:
        try:
            # Connect to Chrome via CDP on port 9222
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            print("✓ Connected to Chrome")
            
            # Find the Flow page
            flow_page = None
            for context in browser.contexts:
                for page in context.pages:
                    if "labs.google/fx/tools/flow/project" in page.url:
                        flow_page = page
                        break
                if flow_page: break
            
            if not flow_page:
                print("✗ Flow project page not found. Please open it first.")
                await browser.close()
                return

            print(f"✓ Found Flow page: {flow_page.url}")
            
            # Extract Project ID from URL
            project_id = flow_page.url.split("/project/")[-1].split("?")[0]
            print(f"✓ Project ID: {project_id}")

            # Define the JS injected script
            js_script = """
            async () => {
                try {
                    console.log('--- Direct API Call Started ---');
                    
                    // 1. Get Access Token
                    const sessionResp = await fetch('https://labs.google/fx/api/auth/session');
                    const sessionData = await sessionResp.json();
                    const accessToken = sessionData.access_token;
                    if (!accessToken) throw new Error('Failed to get access token');
                    console.log('✓ Access Token obtained');

                    // 2. Get reCAPTCHA Token
                    const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
                    const recaptchaToken = await grecaptcha.enterprise.execute(siteKey, {action: 'VIDEO_GENERATION'});
                    if (!recaptchaToken) throw new Error('Failed to get reCAPTCHA token');
                    console.log('✓ reCAPTCHA Token obtained');

                    // 3. Prepare Payload
                    const prompt = "A futuristic city with floating neon structures, cinematic aerial view, hyper-detailed.";
                    const sessionId = ";" + Date.now();
                    const sceneId = crypto.randomUUID();
                    
                    const payload = {
                        "clientContext": {
                            "recaptchaContext": {
                                "token": recaptchaToken,
                                "applicationType": "RECAPTCHA_APPLICATION_TYPE_WEB"
                            },
                            "sessionId": sessionId,
                            "projectId": "PROJECT_ID_PLACEHOLDER",
                            "tool": "PINHOLE",
                            "userPaygateTier": "PAYGATE_TIER_TWO"
                        },
                        "requests": [
                            {
                                "aspectRatio": "VIDEO_ASPECT_RATIO_LANDSCAPE",
                                "seed": Math.floor(Math.random() * 10000),
                                "textInput": {
                                    "prompt": prompt
                                },
                                "videoModelKey": "veo_3_1_t2v_fast_ultra_relaxed",
                                "metadata": {
                                    "sceneId": sceneId
                                }
                            }
                        ]
                    };
                    
                    // Replace Placeholder
                    payload.clientContext.projectId = "PROJECT_ID_PLACEHOLDER";

                    // 4. Perform API Call
                    const apiResp = await fetch('https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText', {
                        method: 'POST',
                        headers: {
                            'Authorization': 'Bearer ' + accessToken,
                            'Content-Type': 'application/json'
                        },
                        body: JSON.stringify(payload)
                    });
                    
                    const apiData = await apiResp.json();
                    console.log('--- Direct API Call Finished ---');
                    return {
                        success: apiResp.ok,
                        status: apiResp.status,
                        data: apiData
                    };
                } catch (err) {
                    console.error('✗ Error in direct API call:', err);
                    return { success: false, error: err.message };
                }
            }
            """.replace("PROJECT_ID_PLACEHOLDER", project_id)

            # Execute the script
            print("⏳ Executing direct API call in browser context...")
            result = await flow_page.evaluate(js_script)
            
            print("\n" + "="*50)
            print("DIRECT API CALL RESULT:")
            print("="*50)
            print(json.dumps(result, indent=2))
            print("="*50)
            
            await browser.close()
            
        except Exception as e:
            print(f"✗ Unexpected Error: {e}")

if __name__ == "__main__":
    asyncio.run(trigger_direct_api())
