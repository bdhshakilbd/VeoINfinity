"""
Direct API-based video generation using Google Vids Veo 3 API
This script calls the generation API directly without UI automation
Based on the network traffic analysis we captured
"""

import asyncio
import json
import requests
from playwright.async_api import async_playwright
from datetime import datetime
import hashlib

class VeoAPIGenerator:
    """Direct API client for Google Vids Veo 3 video generation"""
    
    def __init__(self):
        self.api_endpoint = "https://appsgenaiserver-pa.clients6.google.com/v1/genai/generate"
        self.api_key = None
        self.auth_token = None
        self.session_id = None
        
    async def extract_credentials_from_browser(self):
        """Extract API credentials from the browser session via CDP"""
        
        print("🔑 Extracting credentials from browser session...")
        
        async with async_playwright() as p:
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            context = browser.contexts[0]
            page = context.pages[0]
            
            # Get all cookies from the browser context
            all_cookies = await context.cookies()
            
            # Convert to cookie string
            cookie_dict = {}
            for cookie in all_cookies:
                cookie_dict[cookie['name']] = cookie['value']
            
            self.cookies = cookie_dict
            
            # Extract SAPISID for auth
            sapisid = cookie_dict.get('SAPISID') or cookie_dict.get('__Secure-1PAPISID')
            
            # Extract credentials via JavaScript
            credentials = await page.evaluate("""
                async () => {
                    // Get current timestamp
                    const timestamp = Math.floor(Date.now() / 1000);
                    
                    // Get origin
                    const origin = window.location.origin;
                    
                    // Try to find API key from existing requests
                    let apiKey = null;
                    
                    // Check if we can find it in the page
                    const scripts = Array.from(document.scripts);
                    for (const script of scripts) {
                        const match = script.textContent.match(/AIzaSy[a-zA-Z0-9_-]{33}/);
                        if (match) {
                            apiKey = match[0];
                            break;
                        }
                    }
                    
                    return {
                        timestamp: timestamp,
                        origin: origin,
                        apiKey: apiKey
                    };
                }
            """)
            
            await browser.close()
            
            if sapisid:
                # Generate SAPISIDHASH
                timestamp = credentials['timestamp']
                origin = credentials['origin']
                
                # Hash format: SHA1(timestamp + " " + origin + " " + SAPISID)
                hash_string = f"{timestamp} {origin} {sapisid}"
                hash_value = hashlib.sha1(hash_string.encode()).hexdigest()
                
                self.auth_token = f"SAPISIDHASH {timestamp}_{hash_value}"
                print(f"✓ Generated SAPISIDHASH token")
            
            if credentials['apiKey']:
                self.api_key = credentials['apiKey']
                print(f"✓ Extracted API key: {self.api_key[:20]}...")
            else:
                # Use the one we found in network analysis
                self.api_key = "AIzaSyA-njTXslyyMKk1VOogRfVP59F6fNGeNW8"
                print(f"⚠️ Using default API key from network analysis")
            
            print(f"✓ Extracted {len(self.cookies)} cookies")
            
            return credentials
    
    def build_request_payload(self, prompt: str, duration: int = 5, aspect_ratio: str = "landscape"):
        """
        Build the request payload in JSON+Protobuf format
        Based on the captured network traffic structure
        """
        
        # Generate a session ID (similar to what we saw: "goog_-563560218")
        import random
        session_id = f"goog_{random.randint(-999999999, -100000000)}"
        
        # Build the payload array structure
        # Format: [message_type, null, metadata, prompt, config, null, version]
        payload = [
            104,  # Message type identifier
            None,
            [
                9,           # Metadata type
                None,
                None,
                None,
                session_id,  # Session ID
                None,
                None,
                "en",        # Language
                None,
                None,
                None,
                None,
                None,
                None,
                None
            ],
            [
                None,
                None,
                prompt       # The actual prompt text
            ],
            [
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                [
                    0,        # Start time
                    duration, # Duration in seconds
                    1,        # Quality/type flag
                    0         # Additional flags
                ]
            ],
            None,
            1             # Version
        ]
        
        return payload
    
    async def generate_video(self, prompt: str, duration: int = 5):
        """
        Generate a video using direct API call
        
        Args:
            prompt: Text prompt for video generation
            duration: Video duration in seconds
        """
        
        print("\n" + "=" * 60)
        print("Direct API Video Generation")
        print("=" * 60)
        print(f"\n📝 Prompt: {prompt}")
        print(f"⏱️ Duration: {duration} seconds")
        
        # Extract credentials from browser
        await self.extract_credentials_from_browser()
        
        if not self.auth_token:
            print("\n❌ Failed to extract authentication token")
            print("   Make sure you're logged in to Google Vids in the browser")
            return None
        
        # Build the request
        payload = self.build_request_payload(prompt, duration)
        
        # Build cookie string
        cookie_string = "; ".join([f"{k}={v}" for k, v in self.cookies.items()])
        
        headers = {
            "Content-Type": "application/json+protobuf",
            "Authorization": self.auth_token,
            "X-Goog-AuthUser": "1",
            "Accept-Language": "en-GB",
            "Origin": "https://docs.google.com",
            "Referer": "https://docs.google.com/",
            "Cookie": cookie_string,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }
        
        url = f"{self.api_endpoint}?key={self.api_key}"
        
        print("\n🚀 Sending API request...")
        print(f"   Endpoint: {self.api_endpoint}")
        print(f"   Method: POST")
        print(f"   Auth: {self.auth_token[:30]}...")
        print(f"   Cookies: {len(self.cookies)} cookies attached")

        
        try:
            # Make the API request
            response = requests.post(
                url,
                json=payload,
                headers=headers,
                timeout=30
            )
            
            print(f"\n📡 Response Status: {response.status_code}")
            
            if response.status_code == 200:
                print("✅ Video generation request successful!")
                
                # Parse the response
                response_data = response.json()
                
                # Save the full response
                with open('api_response.json', 'w') as f:
                    json.dump(response_data, f, indent=2)
                print("📁 Full response saved to: api_response.json")
                
                # Try to extract video URL
                response_text = json.dumps(response_data)
                if 'usercontent.google.com' in response_text:
                    import re
                    urls = re.findall(r'https://contribution\.usercontent\.google\.com/[^\s"]+', 
                                    response_text)
                    if urls:
                        video_url = urls[0]
                        print(f"\n🎥 Video URL: {video_url}")
                        
                        # Download the video
                        print("\n⬇️ Downloading video...")
                        video_response = requests.get(video_url)
                        if video_response.status_code == 200:
                            video_path = f"generated_video_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
                            with open(video_path, 'wb') as f:
                                f.write(video_response.content)
                            print(f"✅ Video saved to: {video_path}")
                            return video_path
                
                return response_data
                
            else:
                print(f"❌ API request failed: {response.status_code}")
                print(f"   Response: {response.text[:500]}")
                return None
                
        except Exception as e:
            print(f"\n❌ Error making API request: {e}")
            import traceback
            traceback.print_exc()
            return None


async def main():
    """Main function to test direct API generation"""
    
    generator = VeoAPIGenerator()
    
    # Test prompts
    prompts = [
        "A golden retriever playing in a park on a sunny day",
        "A futuristic city with flying cars at sunset",
        "Ocean waves crashing on a beach at sunrise"
    ]
    
    # Generate video with first prompt
    result = await generator.generate_video(prompts[0], duration=5)
    
    if result:
        print("\n" + "=" * 60)
        print("✅ Video generation complete!")
        print("=" * 60)
    else:
        print("\n" + "=" * 60)
        print("❌ Video generation failed")
        print("=" * 60)


if __name__ == "__main__":
    print("\n🎬 Google Vids Veo 3 - Direct API Generator\n")
    print("This script calls the Veo API directly without UI automation")
    print("Make sure Chrome is running with: chrome.exe --remote-debugging-port=9222\n")
    
    asyncio.run(main())
