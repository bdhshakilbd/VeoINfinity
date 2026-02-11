"""
Connect to Chrome browser on port 9222 using CDP and navigate to Google Vids
"""

import asyncio
from playwright.async_api import async_playwright

async def connect_and_navigate():
    """Connect to Chrome via CDP and navigate to Google Vids"""
    
    async with async_playwright() as p:
        try:
            # Connect to Chrome via CDP on port 9222
            print("Connecting to Chrome on port 9222...")
            browser = await p.chromium.connect_over_cdp("http://localhost:9222")
            
            print(f"✓ Connected to Chrome via CDP")
            print(f"  Browser version: {browser.version}")
            
            # Get the default context
            contexts = browser.contexts
            if not contexts:
                print("✗ No browser contexts found")
                return
            
            context = contexts[0]
            print(f"✓ Using browser context with {len(context.pages)} page(s)")
            
            # Create a new page or use existing one
            if context.pages:
                page = context.pages[0]
                print(f"  Using existing page: {page.url}")
            else:
                page = await context.new_page()
                print("  Created new page")
            
            # Navigate to Google Vids
            print("\nNavigating to Google Vids...")
            await page.goto("https://docs.google.com/videos/", wait_until="networkidle")
            print(f"✓ Navigated to: {page.url}")
            
            # Wait a bit to see the page
            print("\nPage loaded successfully!")
            print("Title:", await page.title())
            
            # Get some info about the page
            print("\nPage information:")
            print(f"  URL: {page.url}")
            print(f"  Viewport: {page.viewport_size}")
            
            # Keep the script running to maintain connection
            print("\n✓ Connection active. Press Ctrl+C to disconnect.")
            print("  You can now interact with the browser manually or use automation scripts.")
            
            # Wait indefinitely (until user cancels)
            try:
                await asyncio.sleep(3600)  # Wait for 1 hour
            except KeyboardInterrupt:
                print("\nDisconnecting...")
            
            # Don't close the browser, just disconnect
            await browser.close()
            print("✓ Disconnected from browser")
            
        except Exception as e:
            print(f"✗ Error: {e}")
            print("\nTroubleshooting:")
            print("1. Make sure Chrome is running with: chrome.exe --remote-debugging-port=9222")
            print("2. Check if port 9222 is accessible: http://localhost:9222/json")
            print("3. Ensure no firewall is blocking the connection")

if __name__ == "__main__":
    asyncio.run(connect_and_navigate())
