"""
Generate video using media IDs directly
Bypasses UI upload by using pre-uploaded media IDs
"""

from pychrome import Browser
import time
import json

def generate_with_media_ids(first_media_id, last_media_id, prompt="animate this", seed=None):
    """
    Generate video using media IDs
    
    Args:
        first_media_id: Media ID for first frame (from your upload program)
        last_media_id: Media ID for last frame (from your upload program)
        prompt: Text prompt for generation
        seed: Optional seed (random if None)
    """
    
    print("\n" + "="*70)
    print("🎬 VEO3 DIRECT GENERATION - MEDIA ID METHOD")
    print("="*70)
    
    print(f"\n📝 Prompt: {prompt}")
    print(f"🎲 Seed: {seed or 'random'}")
    print(f"🖼️ First Frame ID: {first_media_id}")
    print(f"🖼️ Last Frame ID: {last_media_id}")
    
    # Connect to Chrome
    print("\n[1/3] Connecting to Chrome...")
    try:
        browser = Browser(url='http://127.0.0.1:9222')
        tabs = browser.list_tab()
    except Exception as e:
        print(f"❌ Connection failed: {e}")
        return False
    
    # Find Flow tab
    flow_tab = None
    for tab in tabs:
        if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
            url = tab.__dict__['_kwargs'].get('url', '')
            if 'labs.google/fx/tools/flow' in url:
                flow_tab = tab
                break
    
    if not flow_tab:
        print("❌ No Flow tab found")
        return False
    
    flow_tab.start()
    time.sleep(2)
    print("✅ Connected to Flow tab")
    
    # Get necessary context from the page
    print("\n[2/4] Extracting session context...")
    
    js_get_context = """
    (() => {
        // Extract from URL
        const url = window.location.href;
        const projectMatch = url.match(/project\\/([a-f0-9-]+)/);
        const projectId = projectMatch ? projectMatch[1] : null;
        
        // Session ID
        const sessionId = Date.now().toString();
        
        return {
            projectId: projectId,
            sessionId: sessionId,
            url: url
        };
    })();
    """
    
    result = flow_tab.call_method('Runtime.evaluate',
                                  expression=js_get_context,
                                  returnByValue=True)
    
    context = result.get('result', {}).get('value', {})
    project_id = context.get('projectId')
    session_id = context.get('sessionId')
    
    print(f"   Project ID: {project_id}")
    print(f"   Session ID: {session_id}")
    
    if not project_id:
        print("❌ Could not extract project ID")
        flow_tab.stop()
        return False
    
    # Enable Network domain to capture auth token
    print("\n[3/4] Capturing authorization token...")
    
    auth_token = None
    captured_token = {'token': None}
    
    def request_handler(request):
        """Capture auth token from network requests"""
        if 'aisandbox-pa.googleapis.com' in request.get('request', {}).get('url', ''):
            headers = request.get('request', {}).get('headers', {})
            if 'authorization' in headers:
                captured_token['token'] = headers['authorization']
    
    # Enable network monitoring
    flow_tab.call_method('Network.enable')
    flow_tab.set_listener('Network.requestWillBeSent', request_handler)
    
    # Trigger a request by interacting with the page
    js_trigger = """
    (async () => {
        // Try to trigger any API call to capture the token
        // For example, check generation status or fetch media
        try {
            // This might trigger an API call
            const response = await fetch('https://aisandbox-pa.googleapis.com/v1/media:list', {
                method: 'POST',
                headers: {
                    'Content-Type': 'text/plain;charset=UTF-8'
                },
                body: JSON.stringify({})
            });
            return 'TRIGGERED';
        } catch (e) {
            return 'ERROR: ' + e.message;
        }
    })();
    """
    
    try:
        flow_tab.call_method('Runtime.evaluate',
                            expression=js_trigger,
                            awaitPromise=True,
                            returnByValue=True,
                            timeout=5000)
    except:
        pass
    
    time.sleep(2)
    
    auth_token = captured_token['token']
    
    if auth_token:
        print(f"   ✅ Token captured: {auth_token[:50]}...")
    else:
        print("   ⚠️ Could not capture token, will try without auth")
    
    # Generate using direct API call via JavaScript
    print("\n[4/4] Generating video...")
    
    # Use random seed if not provided
    if seed is None:
        import random
        seed = random.randint(1, 99999)
    
    js_generate = f"""
    (async () => {{
        // Construct the request payload
        const payload = {{
            clientContext: {{
                recaptchaContext: {{
                    token: "", // Will be filled by the page
                    applicationType: "RECAPTCHA_APPLICATION_TYPE_WEB"
                }},
                sessionId: "{session_id}",
                projectId: "{project_id}",
                tool: "PINHOLE",
                userPaygateTier: "PAYGATE_TIER_TWO"
            }},
            requests: [{{
                aspectRatio: "VIDEO_ASPECT_RATIO_LANDSCAPE",
                seed: {seed},
                textInput: {{
                    prompt: {json.dumps(prompt)}
                }},
                videoModelKey: "veo_3_1_i2v_s_fast_ultra_fl",
                startImage: {{
                    mediaId: "{first_media_id}"
                }},
                endImage: {{
                    mediaId: "{last_media_id}"
                }},
                metadata: {{
                    sceneId: crypto.randomUUID()
                }}
            }}]
        }};
        
        // Try to find and use the existing API caller
        // This might be exposed as a global function
        
        // Method 1: Direct fetch
        try {{
            const headers = {{
                'Content-Type': 'text/plain;charset=UTF-8',
                'Accept': '*/*',
                'Origin': 'https://labs.google',
                'Referer': 'https://labs.google/'
            }};
            
            // Add auth token if available
            const authToken = "{auth_token or ''}";
            if (authToken) {{
                headers['Authorization'] = authToken;
            }}
            
            const response = await fetch('https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartAndEndImage', {{
                method: 'POST',
                headers: headers,
                body: JSON.stringify(payload)
            }});
            
            if (response.ok) {{
                const data = await response.json();
                return {{
                    success: true,
                    data: data,
                    sceneId: payload.requests[0].metadata.sceneId
                }};
            }} else {{
                return {{
                    success: false,
                    error: 'HTTP ' + response.status,
                    status: response.status
                }};
            }}
        }} catch (error) {{
            return {{
                success: false,
                error: error.message
            }};
        }}
    }})();
    """
    
    try:
        result = flow_tab.call_method('Runtime.evaluate',
                                      expression=js_generate,
                                      awaitPromise=True,
                                      returnByValue=True,
                                      timeout=30000)
        
        response = result.get('result', {}).get('value', {})
        
        if response.get('success'):
            print("✅ Video generation started!")
            print(f"\n📊 Response:")
            print(f"   Scene ID: {response.get('sceneId')}")
            print(f"   Data: {json.dumps(response.get('data', {}), indent=2)[:200]}...")
            
            # Save to file
            with open('generation_response.json', 'w') as f:
                json.dump(response, f, indent=2)
            print(f"\n💾 Full response saved to: generation_response.json")
            
        else:
            print(f"❌ Generation failed: {response.get('error')}")
            print(f"   Status: {response.get('status')}")
            
    except Exception as e:
        print(f"❌ Error: {e}")
    
    finally:
        flow_tab.stop()
    
    print("\n" + "="*70)
    print("✅ PROCESS COMPLETE")
    print("="*70 + "\n")
    
    return True


if __name__ == '__main__':
    # Example usage with media IDs
    # Replace these with actual media IDs from your upload program
    
    first_id = "CAMaJGZiMTI2NWQ1LTZiN2MtNGJlOS1iYTVkLTc5M2E5OGVhMDA5ZSIDQ0FFKiQ2ZTRjMDY4OC1kNzU5LTQ4NzAtYTY5YS04ZTBjMWZiMTNmMTA"
    last_id = "CAMaJDFiMDAwNDRmLTQ3OWYtNGQ3OS1iMDQzLTYzOTMxYWNhYzc5ZiIDQ0FFKiQ0OGE5YmEyYi02MmM1LTQ2N2YtYmFiZS03ZTM0NDNiMzc4ZmI"
    
    generate_with_media_ids(
        first_media_id=first_id,
        last_media_id=last_id,
        prompt="Smooth cinematic transition between frames",
        seed=21369
    )
