"""
Connect to Chrome browser on port 9222 using CDP (Chrome DevTools Protocol)
This script demonstrates how to connect to an existing Chrome instance
"""

import asyncio
import json
from playwright.async_api import async_playwright

async def connect_to_chrome_cdp():
    """Connect to Chrome browser running with remote debugging on port 9222"""
    
    async with async_playwright() as p:
        try:
            # Connect to Chrome via CDP on port 9222
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            print(f"✓ Connected to Chrome via CDP")
            print(f"  Browser version: {browser.version}")
            
            # Get all contexts and pages
            contexts = browser.contexts
            print(f"  Active contexts: {len(contexts)}")
            
            for i, context in enumerate(contexts):
                pages = context.pages
                print(f"  Context {i}: {len(pages)} page(s)")
                for j, page in enumerate(pages):
                    print(f"    Page {j}: {page.url}")
            
            # Keep connection alive
            print("\n✓ CDP connection established successfully")
            print("  You can now use browser subagent to interact with this browser")
            
            await browser.close()
            
        except Exception as e:
            print(f"✗ Error connecting to Chrome: {e}")
            print("\nMake sure Chrome is running with remote debugging enabled:")
            print('  chrome.exe --remote-debugging-port=9222')

if __name__ == "__main__":
    asyncio.run(connect_to_chrome_cdp())
