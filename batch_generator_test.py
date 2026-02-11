"""
Batch Video Generator - Get 16 reCAPTCHA tokens, generate 4 videos CONCURRENTLY

Strategy:
1. Connect to browser ONCE
2. Get 16 reCAPTCHA tokens in batch
3. Get OAuth token
4. Close browser
5. Generate 4 videos CONCURRENTLY using async HTTP requests (httpx)
"""

import asyncio
import httpx
import json
import time
import uuid
from playwright.async_api import async_playwright

class BatchVideoGenerator:
    def __init__(self):
        self.access_token = None
        self.recaptcha_tokens = []
        self.project_id = ""
        
    async def batch_get_tokens(self, count=16):
        """Get multiple reCAPTCHA tokens in one browser session"""
        print(f"🔑 Getting {count} reCAPTCHA tokens from browser...")
        
        async with async_playwright() as p:
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            # Find Flow page
            flow_page = None
            for context in browser.contexts:
                for page in context.pages:
                    if "labs.google/fx/tools/flow" in page.url:
                        flow_page = page
                        break
                if flow_page: break
            
            if not flow_page:
                raise Exception("No Flow page found. Please open https://labs.google/fx/tools/flow")
            
            print(f"✓ Connected to: {flow_page.url}")
            
            # Get access token first
            print("⏳ Getting OAuth access token...")
            self.access_token = await flow_page.evaluate("""
                async () => {
                    const resp = await fetch('https://labs.google/fx/api/auth/session', {
                        credentials: 'include'
                    });
                    const data = await resp.json();
                    return data.access_token;
                }
            """)
            print(f"✓ Access token: {self.access_token[:50]}...")
            
            # Batch generate reCAPTCHA tokens
            tokens = []
            start_time = time.time()
            
            for i in range(count):
                token = await flow_page.evaluate("""
                    async () => {
                        const siteKey = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV";
                        return await grecaptcha.enterprise.execute(siteKey, {
                            action: 'VIDEO_GENERATION'
                        });
                    }
                """)
                tokens.append(token)
                print(f"  ✓ Token {i+1}/{count}: {token[:30]}...")
                
                # Small delay to avoid rate limiting
                if i < count - 1:
                    await asyncio.sleep(0.5)
            
            elapsed = time.time() - start_time
            print(f"✓ Got {count} tokens in {elapsed:.1f}s ({elapsed/count:.2f}s per token)")
            
            await browser.close()
            self.recaptcha_tokens = tokens
            return tokens
    
    async def generate_video_python_async(self, prompt, recaptcha_token, video_num):
        """Generate video using async HTTP requests (no browser)"""
        import httpx
        
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
                "seed": int(time.time() * 1000) % 10000,
                "textInput": {
                    "prompt": prompt
                },
                "videoModelKey": "veo_3_1_t2v_fast_ultra_relaxed",
                "metadata": {
                    "sceneId": scene_id
                }
            }]
        }
        
        headers = {
            'Authorization': f'Bearer {self.access_token}',
            'Content-Type': 'application/json'
        }
        
        print(f"  🚀 Video {video_num}: Sending request...")
        start_time = time.time()
        
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText',
                headers=headers,
                json=payload
            )
        
        elapsed = time.time() - start_time
        
        return {
            'video_num': video_num,
            'status_code': response.status_code,
            'response': response.json() if response.status_code == 200 else response.text,
            'scene_id': scene_id,
            'elapsed': elapsed,
            'prompt': prompt
        }
    
    async def batch_generate_videos(self, prompts):
        """
        Main method: Batch generate videos
        1. Get tokens from browser
        2. Generate 4 videos CONCURRENTLY using pure Python
        """
        print("\n" + "="*70)
        print("BATCH VIDEO GENERATION TEST (CONCURRENT)")
        print("="*70)
        
        # Step 1: Get 16 tokens at once
        await self.batch_get_tokens(count=16)
        
        print("\n" + "="*70)
        print("GENERATING 4 VIDEOS CONCURRENTLY (Pure Python - No Browser)")
        print("="*70)
        
        # Step 2: Generate 4 videos CONCURRENTLY
        print(f"\n🚀 Sending {len(prompts)} requests simultaneously...")
        
        # Create concurrent tasks
        tasks = []
        for i, prompt in enumerate(prompts):
            print(f"📝 Video {i+1}: {prompt[:60]}...")
            token = self.recaptcha_tokens[i]
            task = self.generate_video_python_async(prompt, token, i+1)
            tasks.append(task)
        
        # Send all 4 requests at once!
        print(f"\n⚡ Launching {len(tasks)} concurrent requests...")
        start_time = time.time()
        
        try:
            results = await asyncio.gather(*tasks, return_exceptions=True)
            total_elapsed = time.time() - start_time
            
            print(f"\n✅ All {len(tasks)} requests completed in {total_elapsed:.2f}s!")
            
            # Process results
            print("\n" + "="*70)
            print("RESULTS")
            print("="*70)
            
            successful = 0
            for result in results:
                if isinstance(result, Exception):
                    print(f"\n❌ Video {result}: ERROR - {result}")
                    continue
                
                video_num = result['video_num']
                status = result['status_code']
                elapsed = result['elapsed']
                
                if status == 200:
                    ops = result['response'].get('operations', [])
                    if ops:
                        op_name = ops[0].get('operation', {}).get('name')
                        op_status = ops[0].get('status')
                        print(f"\n✅ Video {video_num}: SUCCESS in {elapsed:.2f}s")
                        print(f"   Prompt: {result['prompt'][:60]}...")
                        print(f"   Operation: {op_name}")
                        print(f"   Status: {op_status}")
                        successful += 1
                    else:
                        print(f"\n✅ Video {video_num}: SUCCESS in {elapsed:.2f}s (no operation in response)")
                        successful += 1
                else:
                    print(f"\n❌ Video {video_num}: FAILED - HTTP {status}")
                    print(f"   Response: {result['response']}")
            
        except Exception as e:
            print(f"\n❌ Batch generation failed: {e}")
            return []
        
        # Summary
        print("\n" + "="*70)
        print("SUMMARY")
        print("="*70)
        print(f"✓ Total time: {total_elapsed:.2f}s")
        print(f"✓ Successful: {successful}/{len(prompts)}")
        print(f"✓ Tokens remaining: {len(self.recaptcha_tokens) - len(prompts)}/16")
        
        if successful > 0:
            avg_request_time = sum(r.get('elapsed', 0) for r in results if not isinstance(r, Exception) and r.get('status_code') == 200) / successful
            print(f"✓ Average request time: {avg_request_time:.2f}s")
            print(f"✓ Speedup: {(avg_request_time * len(prompts)) / total_elapsed:.1f}x faster than sequential")
        
        return results



async def main():
    generator = BatchVideoGenerator()
    
    # Test prompts
    prompts = [
        "A majestic dragon flying over snow-capped mountains at sunset, cinematic shot.",
        "A futuristic city with flying cars and neon lights, cyberpunk style.",
        "An underwater scene with colorful coral reefs and tropical fish, 4K quality.",
        "A medieval castle on a cliff during a thunderstorm, dramatic lighting."
    ]
    
    print("🚀 Starting Batch Video Generation Test")
    print(f"📝 Prompts: {len(prompts)}")
    print(f"🔑 Tokens to generate: 16")
    print(f"🎬 Videos to generate: {len(prompts)}")
    
    results = await generator.batch_generate_videos(prompts)
    
    print("\n" + "="*70)
    print("✅ TEST COMPLETE!")
    print("="*70)


if __name__ == "__main__":
    asyncio.run(main())
