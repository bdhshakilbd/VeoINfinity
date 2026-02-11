"""
Veo3 Infinity Extension - Python CDP Controller
Test script to generate videos using the Chrome extension via CDP
"""

import asyncio
import json
import time
from datetime import datetime
from pychrome import Browser

class Veo3ExtensionController:
    def __init__(self, chrome_url='http://127.0.0.1:9223'):
        """Initialize connection to Chrome via CDP"""
        self.chrome_url = chrome_url
        self.browser = None
        self.tab = None
        self.extension_id = None
        
    def connect(self):
        """Connect to Chrome browser"""
        print(f"[Veo3] Connecting to Chrome at {self.chrome_url}...")
        try:
            self.browser = Browser(url=self.chrome_url)
            print("[Veo3] ✅ Connected to Chrome")
            return True
        except Exception as e:
            print(f"[Veo3] ❌ Failed to connect: {e}")
            print("\n💡 Make sure Chrome is running with:")
            print('   chrome.exe --remote-debugging-port=9223')
            return False
    
    def find_flow_tab(self):
        """Find or create a Google Flow tab"""
        print("[Veo3] Looking for Google Flow tab...")
        
        # Get tabs using requests (simpler than pychrome's GenericAttr)
        import requests
        try:
            response = requests.get(f"{self.chrome_url}/json", timeout=5)
            tabs_json = response.json()
            
            print(f"[Veo3] Found {len(tabs_json)} total tabs")
            
            # Find Flow tab
            for i, tab_data in enumerate(tabs_json):
                tab_url = tab_data.get('url', '')
                tab_type = tab_data.get('type', '')
                print(f"[Veo3]   Tab {i} ({tab_type}): {tab_url[:80]}")
                
                if 'labs.google/fx/tools/flow' in tab_url:
                    print(f"[Veo3] ✅ Found existing Flow tab!")
                    # Now get the actual pychrome Tab object
                    tabs = self.browser.list_tab()
                    for tab in tabs:
                        # Match by ID
                        if hasattr(tab, 'id') and tab.id == tab_data.get('id'):
                            self.tab = tab
                            self.tab.start()
                            return True
        except Exception as e:
            print(f"[Veo3] Error querying tabs: {e}")
        
        # Create new Flow tab
        print("[Veo3] No Flow tab found, creating new one...")
        self.tab = self.browser.new_tab()
        self.tab.start()
        
        # Navigate to Flow
        self.tab.call_method('Page.navigate', url='https://labs.google/fx/tools/flow/')
        time.sleep(5)  # Wait for page to load
        
        print("[Veo3] ✅ Opened Google Flow")
        return True
    
    def test_extension_loaded(self):
        """Test if the Veo3 Infinity extension is loaded"""
        print("[Veo3] Testing if extension is loaded...")
        
        try:
            # Check for extension by looking for Veo3 console logs
            result = self.tab.call_method('Runtime.evaluate', 
                                         expression='document.querySelector("body") !== null')
            
            if result.get('result', {}).get('value'):
                # Try to send a test message and see if extension responds
                test_js = """
                new Promise((resolve) => {
                    const timeout = setTimeout(() => resolve(false), 2000);
                    
                    const handler = (event) => {
                        if (event.data.type === 'VEO3_RESPONSE') {
                            clearTimeout(timeout);
                            window.removeEventListener('message', handler);
                            resolve(true);
                        }
                    };
                    
                    window.addEventListener('message', handler);
                    window.postMessage({ type: 'VEO3_TEST', opts: {}, requestId: 'test' }, '*');
                })
                """
                
                result = self.tab.call_method('Runtime.evaluate',
                                             expression=test_js,
                                             awaitPromise=True,
                                             returnByValue=True,
                                             timeout=5000)
                
                if result.get('result', {}).get('value'):
                    print("[Veo3] ✅ Extension content script loaded!")
                    return True
                else:
                    print("[Veo3] ⚠️  Page loaded but extension not responding")
                    print("[Veo3] Extension may not be installed or needs page refresh")
                    return False
            
            return False
                
        except Exception as e:
            print(f"[Veo3] ❌ Error checking extension: {e}")
            return False
    
    def send_message(self, message_type, options=None):
        """Send a message to the extension content script using postMessage"""
        print(f"[Veo3] Sending message: {message_type}")
        
        # Build the JavaScript code to send message via postMessage
        options_json = json.dumps(options or {})
        request_id = f"req_{int(time.time() * 1000)}"
        
        js_code = f"""
        new Promise((resolve) => {{
            const timeout = setTimeout(() => resolve({{error: 'Timeout'}}), 30000);
            
            const handler = (event) => {{
                if (event.data.type === 'VEO3_RESPONSE' && event.data.requestId === '{request_id}') {{
                    clearTimeout(timeout);
                    window.removeEventListener('message', handler);
                    resolve(event.data.result || {{error: event.data.error}});
                }}
            }};
            
            window.addEventListener('message', handler);
            window.postMessage({{
                type: '{message_type}',
                opts: {options_json},
                requestId: '{request_id}'
            }}, '*');
        }});
        """
        
        try:
            result = self.tab.call_method('Runtime.evaluate', 
                                         expression=js_code,
                                         awaitPromise=True,
                                         returnByValue=True,
                                         timeout=35000)
            
            response = result.get('result', {}).get('value')
            print(f"[Veo3] Response: {response}")
            return response
            
        except Exception as e:
            print(f"[Veo3] ❌ Error sending message: {e}")
            return None
    
    def test_settings(self, prompt, aspect_ratio='16:9', model='Veo 3.1 - Fast', 
                     output_count=1, mode='Text to Video'):
        """Test the extension settings without generating"""
        print("\n" + "="*60)
        print("🧪 TESTING EXTENSION SETTINGS")
        print("="*60)
        
        options = {
            'prompt': prompt,
            'aspectRatio': f'Landscape ({aspect_ratio})' if aspect_ratio == '16:9' else f'Portrait ({aspect_ratio})',
            'model': model,
            'outputCount': output_count,
            'mode': mode,
            'testOnly': True
        }
        
        print(f"\n📋 Test Configuration:")
        print(f"   Prompt: {prompt}")
        print(f"   Aspect Ratio: {aspect_ratio}")
        print(f"   Model: {model}")
        print(f"   Output Count: {output_count}")
        print(f"   Mode: {mode}")
        
        # Send test message to extension
        response = self.send_message('VEO3_TEST', options)
        
        if response and response.get('status') == 'test_complete':
            print("\n✅ TEST PASSED!")
            print(f"   Generate button found: {response.get('generateButtonFound')}")
            return True
        else:
            print(f"\n❌ TEST FAILED: {response.get('error') if response else 'No response'}")
            return False
    
    def generate_video(self, prompt, aspect_ratio='16:9', model='Veo 3.1 - Fast', 
                      output_count=1, mode='Text to Video', create_new_project=False):
        """Generate a video using the extension"""
        print("\n" + "="*60)
        print("🎬 STARTING VIDEO GENERATION")
        print("="*60)
        
        options = {
            'prompt': prompt,
            'aspectRatio': f'Landscape ({aspect_ratio})' if aspect_ratio == '16:9' else f'Portrait ({aspect_ratio})',
            'model': model,
            'outputCount': output_count,
            'mode': mode,
            'createNewProject': create_new_project
        }
        
        print(f"\n📋 Generation Configuration:")
        print(f"   Prompt: {prompt}")
        print(f"   Aspect Ratio: {aspect_ratio}")
        print(f"   Model: {model}")
        print(f"   Output Count: {output_count}")
        print(f"   Mode: {mode}")
        print(f"   Create New Project: {create_new_project}")
        
        print(f"\n🚀 Triggering generation...")
        print("⏳ This may take 2-5 minutes...")
        
        # Send generate message to extension
        response = self.send_message('VEO3_GENERATE', options)
        
        if response and response.get('status') == 'complete':
            print("\n✅ VIDEO GENERATED SUCCESSFULLY!")
            print(f"   Video URL: {response.get('videoUrl', 'N/A')}")
            return response
        else:
            print(f"\n❌ GENERATION FAILED")
            print(f"   Response: {response}")
            return None
            return None
    
    def monitor_generation_status(self):
        """Monitor the generation status in real-time"""
        print("\n📊 Monitoring generation status...")
        
        for i in range(60):  # Monitor for up to 5 minutes
            try:
                js_code = "window.flowGenerator.getStatus()"
                result = self.tab.call_method('Runtime.evaluate', 
                                             expression=js_code,
                                             returnByValue=True)
                
                status = result.get('result', {}).get('value', {})
                
                if status.get('isGenerating'):
                    print(f"   ⏳ Generating... ({i*5}s)")
                else:
                    print("   ✅ Generation complete or idle")
                    break
                    
                time.sleep(5)
                
            except Exception as e:
                print(f"   ⚠️ Status check error: {e}")
                break
    
    def disconnect(self):
        """Disconnect from Chrome"""
        if self.tab:
            try:
                self.tab.stop()
            except:
                pass
        print("\n[Veo3] Disconnected")


def main():
    """Main test function"""
    print("\n" + "="*60)
    print("🎬 VEO3 INFINITY - PYTHON CDP CONTROLLER")
    print("="*60)
    
    # Initialize controller
    controller = Veo3ExtensionController()
    
    # Connect to Chrome
    if not controller.connect():
        return
    
    # Find or create Flow tab
    if not controller.find_flow_tab():
        return
    
    # Wait for page to fully load
    print("\n⏳ Waiting for page to load...")
    time.sleep(5)
    
    # Test if extension is loaded
    if not controller.test_extension_loaded():
        return
    
    # Test configuration
    test_prompt = "A majestic golden retriever running through a sunny meadow, slow motion"
    
    print("\n" + "-"*60)
    print("STEP 1: Testing Extension Settings")
    print("-"*60)
    
    if controller.test_settings(
        prompt=test_prompt,
        aspect_ratio='16:9',
        model='Veo 3.1 - Fast',
        output_count=1,
        mode='Text to Video'
    ):
        print("\n✅ Settings test passed! Ready to generate.")
        
        # Ask user if they want to proceed
        print("\n" + "-"*60)
        print("STEP 2: Generate Video")
        print("-"*60)
        
        proceed = input("\n⚠️  Proceed with actual video generation? (y/yes): ").strip().lower()
        
        if proceed in ['y', 'yes']:
            result = controller.generate_video(
                prompt=test_prompt,
                aspect_ratio='16:9',
                model='Veo 3.1 - Fast',
                output_count=1,
                mode='Text to Video',
                create_new_project=False
            )
            
            if result:
                print(f"\n🎉 SUCCESS!")
                print(f"📹 Video URL: {result.get('videoUrl')}")
        else:
            print("\n⏭️  Skipped generation")
    
    # Disconnect
    controller.disconnect()
    
    print("\n" + "="*60)
    print("✅ TEST COMPLETE")
    print("="*60 + "\n")


if __name__ == '__main__':
    main()
