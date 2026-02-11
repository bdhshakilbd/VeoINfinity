"""
Generate a video in Google Vids using CDP - Direct Generation
Assumes you're already in the Google Vids editor page
"""

import asyncio
import json
from playwright.async_api import async_playwright

async def generate_video_direct(prompt: str):
    """
    Generate a video directly from the current Google Vids editor page
    
    Args:
        prompt: Text prompt for video generation
    """
    
    async with async_playwright() as p:
        try:
            print(f"🔌 Connecting to Chrome on port 9222...")
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            print(f"✓ Connected to Chrome (version: {browser.version})")
            
            # Get the default context and page
            context = browser.contexts[0]
            page = context.pages[0]
            
            print(f"📄 Current page: {page.url}")
            
            # Enable network monitoring
            print("\n📡 Enabling network monitoring...")
            await page.evaluate("""
                () => {
                    window.networkLogs = [];
                    
                    const originalFetch = window.fetch;
                    window.fetch = async (...args) => {
                        const url = args[0];
                        const options = args[1] || {};
                        const logEntry = {
                            type: 'fetch',
                            url: url instanceof URL ? url.toString() : url,
                            method: options.method || 'GET',
                            headers: options.headers,
                            body: options.body,
                            timestamp: new Date().toISOString()
                        };
                        
                        try {
                            const response = await originalFetch(...args);
                            const clonedResponse = response.clone();
                            logEntry.status = response.status;
                            logEntry.responseHeaders = Object.fromEntries(response.headers.entries());
                            try {
                                logEntry.responseText = await clonedResponse.text();
                            } catch (e) {
                                logEntry.responseText = '[Error reading response]';
                            }
                            window.networkLogs.push(logEntry);
                            return response;
                        } catch (error) {
                            logEntry.error = error.message;
                            window.networkLogs.push(logEntry);
                            throw error;
                        }
                    };
                    
                    console.log('✓ Network monitoring enabled');
                }
            """)
            
            # Wait a moment for page to be ready
            await asyncio.sleep(2)
            
            # Look for Veo section in the sidebar
            print(f"\n🎥 Looking for Veo section...")
            try:
                # Click on Veo button in sidebar
                veo_button = page.locator('button:has-text("Veo"), div[aria-label*="Veo"]').first
                await veo_button.click()
                await asyncio.sleep(2)
                print("✓ Veo section opened")
            except Exception as e:
                print(f"⚠️ Veo button not found, checking if already in Veo section...")
            
            # Find and fill the prompt textarea
            print(f"\n✍️ Entering prompt: '{prompt}'")
            try:
                # Wait for textarea - try multiple selectors
                await asyncio.sleep(1)
                
                # Try to find the textarea
                textarea_found = False
                selectors = [
                    'textarea[placeholder*="video"]',
                    'textarea[aria-label*="prompt"]',
                    'textarea[placeholder*="describe"]',
                    'textarea',
                    'div[contenteditable="true"]'
                ]
                
                for selector in selectors:
                    try:
                        textarea = page.locator(selector).first
                        await textarea.wait_for(state="visible", timeout=2000)
                        await textarea.click()
                        await asyncio.sleep(0.5)
                        
                        # Clear existing text
                        await page.keyboard.press('Control+A')
                        await page.keyboard.press('Backspace')
                        
                        # Type the prompt
                        await textarea.fill(prompt)
                        await asyncio.sleep(1)
                        print(f"✓ Prompt entered using selector: {selector}")
                        textarea_found = True
                        break
                    except:
                        continue
                
                if not textarea_found:
                    print("⚠️ Could not find textarea, trying keyboard input...")
                    await page.keyboard.type(prompt)
                    
            except Exception as e:
                print(f"⚠️ Error entering prompt: {e}")
            
            # Click Generate button
            print("\n🎬 Clicking Generate button...")
            try:
                # Try multiple button selectors
                button_selectors = [
                    'button:has-text("Generate")',
                    'button:has-text("Create")',
                    'button[aria-label*="Generate"]',
                    'button[aria-label*="Create"]'
                ]
                
                button_clicked = False
                for selector in button_selectors:
                    try:
                        generate_button = page.locator(selector).first
                        await generate_button.wait_for(state="visible", timeout=2000)
                        await generate_button.click()
                        print(f"✓ Generate button clicked: {selector}")
                        button_clicked = True
                        break
                    except:
                        continue
                
                if not button_clicked:
                    print("⚠️ Could not find Generate button")
                    
            except Exception as e:
                print(f"⚠️ Error clicking Generate: {e}")
            
            # Wait for generation to complete
            print("\n⏳ Waiting for video generation (15 seconds)...")
            await asyncio.sleep(15)
            
            # Extract network logs
            print("\n📊 Extracting network traffic...")
            network_logs = await page.evaluate("""
                () => {
                    if (!window.networkLogs || window.networkLogs.length === 0) {
                        return { error: 'No network logs captured' };
                    }
                    
                    const genRequest = window.networkLogs.find(log => 
                        log.url && (log.url.includes('genai') || log.url.includes('generate'))
                    );
                    
                    if (!genRequest) {
                        return { 
                            error: 'No generation request found',
                            total_requests: window.networkLogs.length,
                            sample_urls: window.networkLogs.slice(0, 5).map(l => l.url)
                        };
                    }
                    
                    return {
                        url: genRequest.url,
                        method: genRequest.method,
                        status: genRequest.status,
                        body: genRequest.body,
                        response_preview: genRequest.responseText ? 
                            genRequest.responseText.substring(0, 500) : null
                    };
                }
            """)
            
            print("\n" + "=" * 60)
            if network_logs.get('error'):
                print(f"⚠️ {network_logs['error']}")
                if 'total_requests' in network_logs:
                    print(f"   Total requests captured: {network_logs['total_requests']}")
                    if 'sample_urls' in network_logs:
                        print("   Sample URLs:")
                        for url in network_logs['sample_urls']:
                            print(f"     - {url[:80]}...")
            else:
                print("✅ Network Traffic Captured:")
                print(f"   API: {network_logs['url'][:80]}...")
                print(f"   Method: {network_logs['method']}")
                print(f"   Status: {network_logs['status']}")
                
                # Check for video URL
                if network_logs.get('response_preview'):
                    if 'usercontent.google.com' in network_logs['response_preview']:
                        print("   ✓ Video URL found in response")
                        
                        # Try to extract the URL
                        import re
                        urls = re.findall(r'https://contribution\.usercontent\.google\.com/[^\s"]+', 
                                        network_logs['response_preview'])
                        if urls:
                            print(f"\n   📹 Video URL: {urls[0][:100]}...")
            
            # Save full logs to file
            log_file = 'c:/Users/Lenovo/Music/veo3_another/network_logs.json'
            with open(log_file, 'w') as f:
                json.dump(network_logs, f, indent=2)
            print(f"\n📁 Full logs saved to: {log_file}")
            print("=" * 60)
            
            # Take a screenshot
            screenshot_path = "c:/Users/Lenovo/Music/veo3_another/generated_video_result.png"
            await page.screenshot(path=screenshot_path, full_page=False)
            print(f"\n📸 Screenshot saved: {screenshot_path}")
            
            print("\n✅ Video generation process complete!")
            print("   Check the Google Vids sidebar for the generated video")
            
            await browser.close()
            print("\n🔌 Disconnected from browser")
            
        except Exception as e:
            print(f"\n❌ Error: {e}")
            import traceback
            traceback.print_exc()


async def main():
    """Main function"""
    
    prompt = "A golden retriever playing in a park on a sunny day"
    
    print("=" * 60)
    print("Google Vids Direct Video Generator (CDP)")
    print("=" * 60)
    print(f"\n📝 Prompt: {prompt}")
    print(f"\n{'=' * 60}\n")
    
    await generate_video_direct(prompt)


if __name__ == "__main__":
    print("\n🚀 Starting Direct Video Generator...\n")
    asyncio.run(main())
