"""
Veo3 Infinity - Video Generator with Network Monitoring
Monitors network traffic to track video generation status and get download URLs
"""

import sys
import time
import json
from pychrome import Browser

class VideoGenerationMonitor:
    def __init__(self):
        self.browser = None
        self.flow_tab = None
        self.sidepanel_tab = None
        self.scene_id = None
        self.requests = []
        self.responses = []
        
    def connect(self):
        """Connect to Chrome"""
        print("\n🔌 Connecting to Chrome...")
        try:
            self.browser = Browser(url='http://127.0.0.1:9222')
            print("✅ Connected")
            return True
        except Exception as e:
            print(f"❌ Failed: {e}")
            return False
    
    def find_tabs(self):
        """Find Flow and side panel tabs"""
        print("\n🔍 Finding tabs...")
        tabs = self.browser.list_tab()
        
        for tab in tabs:
            if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
                tab_url = tab.__dict__['_kwargs'].get('url', '')
                
                if 'labs.google/fx/tools/flow' in tab_url:
                    self.flow_tab = tab
                    print(f"✅ Found Flow tab: {tab_url[:50]}...")
                
                if 'sidepanel.html' in tab_url:
                    self.sidepanel_tab = tab
                    print(f"✅ Found side panel")
        
        return self.flow_tab and self.sidepanel_tab
    
    def setup_network_monitoring(self):
        """Enable network monitoring on Flow tab"""
        print("\n📡 Setting up network monitoring...")
        
        self.flow_tab.start()
        time.sleep(1)
        
        # Enable Network domain
        self.flow_tab.call_method('Network.enable')
        
        # Set up event listeners
        def on_response_received(**params):
            """Handle network responses - accepts all parameters"""
            response_data = params.get('response', {})
            url = response_data.get('url', '')
            status = response_data.get('status', 0)
            request_id = params.get('requestId', '')
            
            # Look for Flow API requests
            if 'googleapis.com' in url or 'labs.google' in url:
                
                # Handle initial video generation request
                if 'batchAsyncGenerateVideoText' in url:
                    print(f"\n📤 Video Generation Request: {status}")
                    try:
                        body_result = self.flow_tab.call_method(
                            'Network.getResponseBody',
                            requestId=request_id
                        )
                        
                        if body_result.get('body'):
                            try:
                                body_data = json.loads(body_result['body'])
                                operations = body_data.get('operations', [])
                                
                                for op in operations:
                                    scene_id = op.get('sceneId')
                                    status_val = op.get('status', '')
                                    operation_name = op.get('operation', {}).get('name', '')
                                    
                                    if scene_id:
                                        self.scene_id = scene_id
                                        print(f"✅ VIDEO GENERATION SUBMITTED!")
                                        print(f"🎬 Scene ID: {scene_id}")
                                        print(f"🔑 Operation: {operation_name}")
                                        print(f"📊 Status: {status_val}")
                                        
                                        if status == 200:
                                            print(f"✅ HTTP 200 OK - Request accepted")
                                        
                                        # Show remaining credits
                                        remaining = body_data.get('remainingCredits')
                                        if remaining is not None:
                                            print(f"💰 Remaining Credits: {remaining:,}")
                                        
                                        # Log the submission
                                        with open('video_submissions.txt', 'a', encoding='utf-8') as f:
                                            f.write(f"\n{time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                                            f.write(f"Scene ID: {scene_id}\n")
                                            f.write(f"Operation: {operation_name}\n")
                                            f.write(f"Status: {status_val}\n")
                                            f.write(f"HTTP Code: {status}\n")
                                            f.write("-" * 60 + "\n")
                                
                            except json.JSONDecodeError:
                                pass
                    except Exception as e:
                        pass
                
                # Handle batchCheckAsyncVideoGenerationStatus endpoint
                if 'batchCheckAsyncVideoGenerationStatus' in url:
                    try:
                        body_result = self.flow_tab.call_method(
                            'Network.getResponseBody',
                            requestId=request_id
                        )
                        
                        if body_result.get('body'):
                            try:
                                body_data = json.loads(body_result['body'])
                                
                                # Extract operations array
                                operations = body_data.get('operations', [])
                                
                                for op in operations:
                                    scene_id = op.get('sceneId')
                                    status_val = op.get('status', '')
                                    media_gen_id = op.get('mediaGenerationId', '')
                                    
                                    if scene_id and not self.scene_id:
                                        self.scene_id = scene_id
                                        print(f"\n🎬 SCENE ID CAPTURED: {scene_id}")
                                        print(f"📊 HTTP Status: {status}")
                                        print(f"🆔 Media Gen ID: {media_gen_id[:50]}...")
                                    
                                    if status_val:
                                        status_emoji = "⏳" if "ACTIVE" in status_val else "✅" if "SUCCESSFUL" in status_val else "📊"
                                        print(f"\n{status_emoji} Status: {status_val}")
                                    
                                    # Check if generation is complete
                                    if status_val == 'MEDIA_GENERATION_STATUS_SUCCESSFUL':
                                        operation_data = op.get('operation', {})
                                        metadata = operation_data.get('metadata', {})
                                        video_data = metadata.get('video', {})
                                        
                                        # Extract video URL (fifeUrl)
                                        fife_url = video_data.get('fifeUrl', '')
                                        serving_uri = video_data.get('servingBaseUri', '')
                                        prompt = video_data.get('prompt', '')
                                        model = video_data.get('model', '')
                                        seed = video_data.get('seed', '')
                                        
                                        if fife_url:
                                            print(f"\n🎉 VIDEO GENERATION SUCCESSFUL!")
                                            print(f"📝 Prompt: {prompt}")
                                            print(f"🎨 Model: {model}")
                                            print(f"🌱 Seed: {seed}")
                                            print(f"📥 Video URL: {fife_url[:100]}...")
                                            print(f"\n💾 Saving to file...")
                                            
                                            # Save to file with all details
                                            with open('video_download_url.txt', 'a', encoding='utf-8') as f:
                                                f.write(f"\n{'='*70}\n")
                                                f.write(f"Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                                                f.write(f"Scene ID: {scene_id}\n")
                                                f.write(f"Media Generation ID: {media_gen_id}\n")
                                                f.write(f"Prompt: {prompt}\n")
                                                f.write(f"Model: {model}\n")
                                                f.write(f"Seed: {seed}\n")
                                                f.write(f"Video URL (fifeUrl): {fife_url}\n")
                                                if serving_uri:
                                                    f.write(f"Thumbnail URL: {serving_uri}\n")
                                                f.write(f"{'='*70}\n")
                                            
                                            print("✅ Details saved to video_download_url.txt")
                                            
                                            # Also save just the URL for easy access
                                            with open(f'video_{scene_id[:8]}.txt', 'w', encoding='utf-8') as f:
                                                f.write(fife_url)
                                            
                                            print(f"✅ URL saved to video_{scene_id[:8]}.txt")
                                
                                # Show remaining credits
                                remaining = body_data.get('remainingCredits')
                                if remaining is not None:
                                    print(f"💰 Remaining Credits: {remaining:,}")
                                
                            except json.JSONDecodeError as e:
                                pass
                                
                    except Exception as e:
                        pass
                
                # Handle other scene creation/update endpoints
                elif 'createScene' in url or 'scenes' in url or 'updateScene' in url:
                    print(f"📨 {status} - {url[:80]}...")
                    try:
                        body_result = self.flow_tab.call_method(
                            'Network.getResponseBody',
                            requestId=request_id
                        )
                        
                        if body_result.get('body'):
                            try:
                                body_data = json.loads(body_result['body'])
                                scene_id = body_data.get('sceneId') or body_data.get('name')
                                
                                if scene_id and not self.scene_id:
                                    self.scene_id = scene_id
                                    print(f"🎬 Scene created: {scene_id}")
                                
                            except json.JSONDecodeError:
                                pass
                                
                    except Exception as e:
                        pass
        
        # Register the listener
        self.flow_tab.set_listener('Network.responseReceived', on_response_received)
        
        print("✅ Network monitoring active")
        return True
    
    def generate_video(self, prompt, aspect_ratio='16:9', model='Veo 3.1 - Fast', outputs=1):
        """Trigger video generation"""
        print("\n🚀 Starting video generation...")
        print(f"📋 Prompt: {prompt}")
        print(f"📐 Aspect: {aspect_ratio}")
        print(f"🎨 Model: {model}")
        print(f"🔢 Outputs: {outputs}\n")
        
        self.sidepanel_tab.start()
        time.sleep(1)
        
        aspect_str = f"Landscape ({aspect_ratio})" if aspect_ratio == '16:9' else f"Portrait ({aspect_ratio})"
        
        js_code = f"""
        (async () => {{
            const options = {{
                prompt: {repr(prompt)},
                aspectRatio: {repr(aspect_str)},
                model: {repr(model)},
                outputCount: {outputs},
                mode: 'Text to Video',
                createNewProject: false
            }};
            
            const tabs = await chrome.tabs.query({{}});
            const flowTab = tabs.find(t => t.url && t.url.includes('labs.google/fx/tools/flow'));
            
            if (!flowTab) return 'NO_FLOW_TAB';
            
            const requestId = 'python_' + Date.now();
            
            return new Promise((resolve) => {{
                chrome.tabs.sendMessage(flowTab.id, {{
                    type: 'GENERATE_VIDEO',
                    requestId: requestId,
                    options: options
                }}, (response) => {{
                    if (chrome.runtime.lastError) {{
                        resolve('ERROR: ' + chrome.runtime.lastError.message);
                    }} else {{
                        resolve('SUCCESS: ' + JSON.stringify(response));
                    }}
                }});
            }});
        }})();
        """
        
        try:
            result = self.sidepanel_tab.call_method('Runtime.evaluate',
                                                   expression=js_code,
                                                   awaitPromise=True,
                                                   returnByValue=True,
                                                   timeout=10000)
            
            response = result.get('result', {}).get('value', '')
            
            if 'SUCCESS' in str(response):
                print("✅ Generation request sent!")
                print("\n⏳ Monitoring network traffic...")
                print("   Waiting for scene creation response...")
                return True
            else:
                print(f"❌ Failed: {response}")
                return False
                
        except Exception as e:
            print(f"❌ Error: {e}")
            return False
    
    def monitor(self, duration=300):
        """Monitor for specified duration (seconds)"""
        print(f"\n👀 Monitoring for {duration} seconds...")
        print("   Press Ctrl+C to stop early\n")
        
        start_time = time.time()
        
        try:
            while time.time() - start_time < duration:
                time.sleep(1)
                
                # Show progress every 10 seconds
                elapsed = int(time.time() - start_time)
                if elapsed % 10 == 0 and elapsed > 0:
                    print(f"⏱️  {elapsed}s elapsed... ", end='', flush=True)
                    if self.scene_id:
                        print(f"(Scene ID: {self.scene_id[:20]}...)", flush=True)
                    else:
                        print("(Waiting for scene ID...)", flush=True)
                        
        except KeyboardInterrupt:
            print("\n\n⚠️  Monitoring stopped by user")
    
    def cleanup(self):
        """Stop monitoring and disconnect"""
        print("\n🧹 Cleaning up...")
        
        if self.flow_tab:
            try:
                self.flow_tab.call_method('Network.disable')
                self.flow_tab.stop()
            except:
                pass
        
        if self.sidepanel_tab:
            try:
                self.sidepanel_tab.stop()
            except:
                pass
        
        print("✅ Disconnected")


def main():
    print("\n" + "="*70)
    print("🎬 VEO3 INFINITY - VIDEO GENERATOR WITH NETWORK MONITORING")
    print("="*70)
    
    # Get prompt
    if len(sys.argv) > 1:
        prompt = ' '.join(sys.argv[1:])
    else:
        prompt = input("\n📝 Enter your prompt: ").strip()
        if not prompt:
            prompt = "A serene sunset over a calm ocean with gentle waves"
    
    # Create monitor
    monitor = VideoGenerationMonitor()
    
    # Connect
    if not monitor.connect():
        return
    
    # Find tabs
    if not monitor.find_tabs():
        print("\n❌ Required tabs not found!")
        print("   Make sure Flow page and side panel are open")
        return
    
    # Setup network monitoring
    if not monitor.setup_network_monitoring():
        return
    
    # Generate video
    if not monitor.generate_video(prompt):
        monitor.cleanup()
        return
    
    # Monitor for completion
    try:
        monitor.monitor(duration=300)  # 5 minutes
    except Exception as e:
        print(f"\n❌ Monitoring error: {e}")
    
    # Cleanup
    monitor.cleanup()
    
    print("\n" + "="*70)
    print("✅ MONITORING COMPLETE")
    if monitor.scene_id:
        print(f"🎬 Scene ID: {monitor.scene_id}")
        print("💾 Check video_download_url.txt for download links")
    print("="*70 + "\n")


if __name__ == '__main__':
    main()
