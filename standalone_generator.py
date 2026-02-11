"""
Standalone Video Generation - Minimal Browser Dependency

This script uses the browser ONLY to get reCAPTCHA tokens.
All API calls are made directly from Python using requests.
"""

import asyncio
import requests
import json
import time
import uuid
from playwright.async_api import async_playwright

class StandaloneVideoGenerator:
    def __init__(self):
        self.access_token = None
        self.cookies = None
        self.project_id = ""
        
    async def get_recaptcha_token(self):
        """Get reCAPTCHA token from browser (only browser interaction needed)"""
        async with async_playwright() as p:
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            # Find any Flow page
            flow_page = None
            for context in browser.contexts:
                for page in context.pages:
                    if "labs.google/fx/tools/flow" in page.url:
                        flow_page = page
                        break
                if flow_page: break
            
            if not flow_page:
                raise Exception("No Flow page found. Please open https://labs.google/fx/tools/flow")
            
            # Get reCAPTCHA token via JavaScript
            token = await flow_page.evaluate("""
                async () => {
                    const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
                    return await grecaptcha.enterprise.execute(siteKey, {
                        action: 'VIDEO_GENERATION'
                    });
                }
            """)
            
            await browser.close()
            return token
    
    async def get_access_token_from_browser(self):
        """Get OAuth access token from browser session"""
        async with async_playwright() as p:
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            flow_page = None
            for context in browser.contexts:
                for page in context.pages:
                    if "labs.google/fx/tools/flow" in page.url:
                        flow_page = page
                        break
                if flow_page: break
            
            if not flow_page:
                raise Exception("No Flow page found")
            
            # Get access token
            result = await flow_page.evaluate("""
                async () => {
                    const resp = await fetch('https://labs.google/fx/api/auth/session', {
                        credentials: 'include'
                    });
                    const data = await resp.json();
                    return data.access_token;
                }
            """)
            
            await browser.close()
            return result
    
    def generate_video_pure_python(self, prompt, recaptcha_token, access_token):
        """
        Make API call using pure Python requests (no browser needed for this part)
        """
        # Build payload
        session_id = ";" + str(int(time.time() * 1000))
        scene_id = str(uuid.uuid4())
        
        payload = {
            "clientContext": {
                "recaptchaContext": {
                    "token": recaptcha_token,
                    "applicationType": "RECAPTCHA_APPLICATION_TYPE_WEB"
                },
                "sessionId": session_id,
                "projectId": self.project_id,
                "tool": "PINHOLE",
                "userPaygateTier": "PAYGATE_TIER_TWO"
            },
            "requests": [{
                "aspectRatio": "VIDEO_ASPECT_RATIO_LANDSCAPE",
                "seed": int(time.time()) % 10000,
                "textInput": {
                    "prompt": prompt
                },
                "videoModelKey": "veo_3_1_t2v_fast_ultra_relaxed",
                "metadata": {
                    "sceneId": scene_id
                }
            }]
        }
        
        # Make API call using requests
        headers = {
            'Authorization': f'Bearer {access_token}',
            'Content-Type': 'application/json'
        }
        
        response = requests.post(
            'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText',
            headers=headers,
            json=payload
        )
        
        return {
            'status_code': response.status_code,
            'response': response.json(),
            'scene_id': scene_id
        }
    
    async def generate(self, prompt):
        """
        Main method: Generate video with minimal browser interaction
        """
        print(f"🎬 Generating video: {prompt[:50]}...")
        
        # Step 1: Get reCAPTCHA token (requires browser)
        print("⏳ Getting reCAPTCHA token from browser...")
        recaptcha_token = await self.get_recaptcha_token()
        print(f"✓ reCAPTCHA token: {recaptcha_token[:50]}...")
        
        # Step 2: Get access token (requires browser)
        print("⏳ Getting OAuth access token from browser...")
        access_token = await self.get_access_token_from_browser()
        print(f"✓ Access token: {access_token[:50]}...")
        
        # Step 3: Make API call using pure Python (NO browser needed!)
        print("⏳ Making API call via Python requests...")
        result = self.generate_video_pure_python(prompt, recaptcha_token, access_token)
        
        print("\n" + "="*60)
        print("RESULT:")
        print("="*60)
        print(f"Status Code: {result['status_code']}")
        print(f"Response: {json.dumps(result['response'], indent=2)}")
        print("="*60)
        
        return result


async def main():
    generator = StandaloneVideoGenerator()
    
    # Generate a video
    result = await generator.generate(
        "A cyberpunk city at night with neon lights, flying cars, cinematic shot."
    )
    
    if result['status_code'] == 200:
        ops = result['response'].get('operations', [])
        if ops:
            op_name = ops[0].get('operation', {}).get('name')
            print(f"\n✅ SUCCESS! Operation: {op_name}")
        else:
            print("\n✅ SUCCESS! (No operation name in response)")
    else:
        print(f"\n❌ FAILED with status {result['status_code']}")


if __name__ == "__main__":
    asyncio.run(main())
