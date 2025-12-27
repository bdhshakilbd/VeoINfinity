"""
Advanced Bulk Video Generator with Project Management

Features:
- JSON/TXT file import with bracket extraction
- Bulk generation with rate limiting
- Individual scene tracking with status
- Project save/load with auto-save
- Error recovery and retry
- Download management
"""
import json
import time
import requests
import random
import os
from websocket import create_connection
import uuid
import tkinter as tk
from tkinter import ttk, scrolledtext, messagebox, filedialog
import threading
from pathlib import Path
import re
from datetime import datetime
from typing import List, Dict, Optional
import queue


# Configuration - Use current directory for profiles
PROFILES_DIR = str(Path.cwd() / "profiles")
os.makedirs(PROFILES_DIR, exist_ok=True)  # Create if doesn't exist

CHROME_PATH = r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
if not os.path.exists(CHROME_PATH):
    CHROME_PATH = r"C:\Program Files\Google\Chrome\Application\chrome.exe"

class SceneData:
    """Data structure for a single scene"""
    def __init__(self, scene_id: int, prompt: str):
        self.scene_id = scene_id
        self.prompt = prompt
        self.status = "queued"  # queued, generating, polling, downloading, completed, failed
        self.operation_name: Optional[str] = None
        self.video_path: Optional[str] = None
        self.download_url: Optional[str] = None
        self.error: Optional[str] = None
        self.generated_at: Optional[str] = None
        self.file_size: Optional[int] = None
        self.retry_count: int = 0
        # Image-to-video support
        self.first_frame_path: Optional[str] = None
        self.last_frame_path: Optional[str] = None
        self.first_frame_media_id: Optional[str] = None
        self.last_frame_media_id: Optional[str] = None
        
    def to_dict(self) -> Dict:
        return {
            'scene_id': self.scene_id,
            'prompt': self.prompt,
            'status': self.status,
            'operation_name': self.operation_name,
            'video_path': self.video_path,
            'download_url': self.download_url,
            'error': self.error,
            'generated_at': self.generated_at,
            'file_size': self.file_size,
            'retry_count': self.retry_count,
            'first_frame_path': self.first_frame_path,
            'last_frame_path': self.last_frame_path,
            'first_frame_media_id': self.first_frame_media_id,
            'last_frame_media_id': self.last_frame_media_id
        }
    
    @staticmethod
    def from_dict(data: Dict) -> 'SceneData':
        scene = SceneData(data['scene_id'], data['prompt'])
        scene.status = data.get('status', 'queued')
        scene.operation_name = data.get('operation_name')
        scene.video_path = data.get('video_path')
        scene.download_url = data.get('download_url')
        scene.error = data.get('error')
        scene.generated_at = data.get('generated_at')
        scene.file_size = data.get('file_size')
        scene.retry_count = data.get('retry_count', 0)
        scene.first_frame_path = data.get('first_frame_path')
        scene.last_frame_path = data.get('last_frame_path')
        scene.first_frame_media_id = data.get('first_frame_media_id')
        scene.last_frame_media_id = data.get('last_frame_media_id')
        return scene


class BrowserVideoGenerator:
    def __init__(self, debug_port=9222):
        self.debug_port = debug_port
        self.ws = None
        self.msg_id = 0
        self.lock = threading.Lock()
        
    def connect(self):
        """Connect to Chrome DevTools"""
        response = requests.get(f'http://localhost:{self.debug_port}/json')
        tabs = response.json()
        
        target_tab = None
        for tab in tabs:
            if 'labs.google' in tab.get('url', ''):
                target_tab = tab
                break
        
        if not target_tab:
            raise Exception("No labs.google tab found! Please open https://labs.google in Chrome")
        
        ws_url = target_tab['webSocketDebuggerUrl']
        self.ws = create_connection(ws_url)
        return self
    
    def send_command(self, method, params=None):
        """Send a CDP command and get response"""
        with self.lock:
            self.msg_id += 1
            msg = {'id': self.msg_id, 'method': method, 'params': params or {}}
            self.ws.send(json.dumps(msg))
            
            while True:
                response = json.loads(self.ws.recv())
                if response.get('id') == self.msg_id:
                    return response
    
    def execute_js(self, expression):
        """Execute JavaScript in the page context"""
        result = self.send_command('Runtime.evaluate', {
            'expression': expression,
            'returnByValue': True,
            'awaitPromise': True
        })
        return result.get('result', {}).get('result', {}).get('value')
    
    def get_access_token(self):
        """Fetch access token from browser session"""
        js_code = '''
        (async function() {
            try {
                const response = await fetch('https://labs.google/fx/api/auth/session', {
                    credentials: 'include'
                });
                const data = await response.json();
                return JSON.stringify({
                    success: response.ok,
                    token: data.access_token
                });
            } catch (error) {
                return JSON.stringify({
                    success: false,
                    error: error.message
                });
            }
        })()
        '''  
        
        result = self.execute_js(js_code)
        if result:
            parsed = json.loads(result)
            if parsed.get('success'):
                return parsed.get('token')
        return None
    
    def simulate_human_activity(self):
        """Simulate mouse movement and scrolling to avoid bot detection"""
        try:
            js_code = '''
            (function() {
                // Simulate random mouse movement
                const x = Math.floor(Math.random() * window.innerWidth);
                const y = Math.floor(Math.random() * window.innerHeight);
                const event = new MouseEvent('mousemove', {
                    clientX: x, clientY: y,
                    bubbles: true, cancelable: true
                });
                document.dispatchEvent(event);
                
                // Simulate random scroll
                window.scrollBy(0, Math.floor(Math.random() * 100) - 50);
                
                return 'OK';
            })()
            '''
            self.execute_js(js_code)
        except:
            pass
    
    def type_into_element(self, element_id, text, typing_speed='human'):
        """Type text into element with realistic human-like delays"""
        # Determine typing speed parameters
        if typing_speed == 'human':
            base_delay = (50, 150)  # ms
            punctuation_delay = (200, 500)
            thinking_pause_chance = 0.1
            thinking_pause_duration = (500, 1500)
        elif typing_speed == 'fast':
            base_delay = (20, 50)
            punctuation_delay = (50, 100)
            thinking_pause_chance = 0.05
            thinking_pause_duration = (200, 500)
        else:  # slow
            base_delay = (100, 200)
            punctuation_delay = (300, 700)
            thinking_pause_chance = 0.15
            thinking_pause_duration = (800, 2000)
        
        # Escape text for JavaScript
        text_escaped = text.replace('`', '\\`').replace('$', '\\$')
        
        js_code = f'''
        (async function() {{
            try {{
                const element = document.getElementById('{element_id}');
                if (!element) return {{ success: false, error: 'Element not found' }};
                
                // Focus and clear
                element.focus();
                element.value = '';
                element.dispatchEvent(new Event('input', {{ bubbles: true }}));
                
                const text = `{text_escaped}`;
                
                for (let i = 0; i < text.length; i++) {{
                    const char = text[i];
                    
                    // Random typing delay
                    const delay = {base_delay[0]} + Math.random() * {base_delay[1] - base_delay[0]};
                    await new Promise(r => setTimeout(r, delay));
                    
                    // Type character
                    element.value += char;
                    element.dispatchEvent(new Event('input', {{ bubbles: true }}));
                    element.dispatchEvent(new Event('change', {{ bubbles: true }}));
                    
                    // Pause longer at punctuation
                    if (['.', ',', '!', '?', '\\n'].includes(char)) {{
                        const pDelay = {punctuation_delay[0]} + Math.random() * {punctuation_delay[1] - punctuation_delay[0]};
                        await new Promise(r => setTimeout(r, pDelay));
                    }}
                    
                    // Random thinking pauses
                    if (Math.random() < {thinking_pause_chance}) {{
                        const tDelay = {thinking_pause_duration[0]} + Math.random() * {thinking_pause_duration[1] - thinking_pause_duration[0]};
                        await new Promise(r => setTimeout(r, tDelay));
                    }}
                }}
                
                return {{ success: true }};
            }} catch (error) {{
                return {{ success: false, error: error.message }};
            }}
        }})()
        '''
        
        result = self.execute_js(js_code)
        return result if result else {'success': False, 'error': 'No response'}
    
    def click_element(self, selector, click_type='normal'):
        """Click element with realistic mouse simulation"""
        js_code = f'''
        (async function() {{
            try {{
                const element = document.querySelector('{selector}');
                if (!element) return {{ success: false, error: 'Element not found' }};
                
                // Get element position
                const rect = element.getBoundingClientRect();
                const x = rect.left + rect.width / 2 + (Math.random() * 10 - 5);
                const y = rect.top + rect.height / 2 + (Math.random() * 10 - 5);
                
                // Simulate mouse movement and hover
                element.dispatchEvent(new MouseEvent('mouseover', {{ bubbles: true, clientX: x, clientY: y }}));
                await new Promise(r => setTimeout(r, 100 + Math.random() * 200));
                
                // Mouse down
                element.dispatchEvent(new MouseEvent('mousedown', {{ bubbles: true, clientX: x, clientY: y }}));
                await new Promise(r => setTimeout(r, 50 + Math.random() * 100));
                
                // Mouse up and click
                element.dispatchEvent(new MouseEvent('mouseup', {{ bubbles: true, clientX: x, clientY: y }}));
                element.click();
                
                return {{ success: true }};
            }} catch (error) {{
                return {{ success: false, error: error.message }};
            }}
        }})()
        '''
        
        result = self.execute_js(js_code)
        return result if result else {'success': False, 'error': 'No response'}
    
    def wait_for_video_url(self, timeout=300):
        """Wait for video generation to complete and extract URL from UI"""
        js_code = f'''
        (async function() {{
            const maxWait = {timeout * 1000};
            const startTime = Date.now();
            
            while (Date.now() - startTime < maxWait) {{
                // Method 1: Look for download button
                const downloadBtn = document.querySelector('a[download], button[aria-label*="Download"], a[href*=".mp4"]');
                if (downloadBtn) {{
                    const url = downloadBtn.href || downloadBtn.getAttribute('data-url');
                    if (url && url.includes('http')) {{
                        return {{ success: true, url: url, method: 'download_button' }};
                    }}
                }}
                
                // Method 2: Look for video element
                const video = document.querySelector('video[src]');
                if (video && video.src && video.src.includes('http')) {{
                    return {{ success: true, url: video.src, method: 'video_element' }};
                }}
                
                // Method 3: Check for error state
                const error = document.querySelector('[role="alert"], .error-message');
                if (error && error.textContent.trim()) {{
                    return {{ success: false, error: error.textContent.trim() }};
                }}
                
                // Wait before next check
                await new Promise(r => setTimeout(r, 1000));
            }}
            
            return {{ success: false, error: 'Timeout waiting for video' }};
        }})()
        '''
        
        result = self.execute_js(js_code)
        return result if result else {'success': False, 'error': 'No response'}
    
    def upload_image(self, image_path, access_token, aspect_ratio='IMAGE_ASPECT_RATIO_LANDSCAPE'):
        """Upload an image and get mediaId for image-to-video generation"""
        import base64
        
        try:
            # Read and encode image
            with open(image_path, 'rb') as f:
                image_bytes = f.read()
            
            # Convert to base64
            image_b64 = base64.b64encode(image_bytes).decode('utf-8')
            
            # Determine MIME type
            mime_type = 'image/jpeg'
            if image_path.lower().endswith('.png'):
                mime_type = 'image/png'
            elif image_path.lower().endswith('.webp'):
                mime_type = 'image/webp'
            
            print(f"[UPLOAD] Uploading image: {Path(image_path).name} ({len(image_bytes)} bytes)")
            
            # Split base64 into chunks to avoid JavaScript string length issues
            chunk_size = 50000
            chunks = [image_b64[i:i+chunk_size] for i in range(0, len(image_b64), chunk_size)]
            
            # Build base64 string in JavaScript to avoid escaping issues
            chunks_js = json.dumps(chunks)
            
            js_code = f'''
            (async function() {{
                try {{
                    // Reconstruct base64 from chunks
                    const chunks = {chunks_js};
                    const rawImageBytes = chunks.join('');
                    
                    const payload = {{
                        imageInput: {{
                            rawImageBytes: rawImageBytes,
                            mimeType: "{mime_type}",
                            isUserUploaded: true,
                            aspectRatio: "{aspect_ratio}"
                        }},
                        clientContext: {{
                            sessionId: ';' + Date.now(),
                            tool: 'ASSET_MANAGER'
                        }}
                    }};
                    
                    const response = await fetch(
                        'https://aisandbox-pa.googleapis.com/v1:uploadUserImage',
                        {{
                            method: 'POST',
                            headers: {{ 
                                'Content-Type': 'text/plain;charset=UTF-8',
                                'authorization': 'Bearer {access_token}'
                            }},
                            body: JSON.stringify(payload),
                            credentials: 'include'
                        }}
                    );
                    
                    const text = await response.text();
                    let data = null;
                    try {{ data = JSON.parse(text); }} catch (e) {{ data = text; }}
                    
                    return JSON.stringify({{
                        success: response.ok,
                        status: response.status,
                        statusText: response.statusText,
                        data: data
                    }});
                }} catch (error) {{
                    return JSON.stringify({{
                        success: false,
                        error: error.message,
                        stack: error.stack
                    }});
                }}
            }})()
            '''
            
            result_str = self.execute_js(js_code)
            if result_str:
                result = json.loads(result_str)
                
                print(f"[UPLOAD] Status: {result.get('status')}")
                
                if result.get('success'):
                    data = result.get('data', {})
                    
                    # Extract mediaId from nested structure
                    media_id = None
                    if 'mediaGenerationId' in data:
                        media_gen = data['mediaGenerationId']
                        if isinstance(media_gen, dict):
                            media_id = media_gen.get('mediaGenerationId')
                        else:
                            media_id = media_gen
                    elif 'mediaId' in data:
                        media_id = data['mediaId']
                    
                    if media_id:
                        print(f"[UPLOAD] ✓ Success! MediaId: {media_id}")
                        return media_id
                    else:
                        print(f"[UPLOAD] ✗ No mediaId in response:")
                        print(f"[UPLOAD] Response data: {json.dumps(data, indent=2)}")
                else:
                    # Check for specific error reasons
                    error_data = result.get('data', {})
                    error_info = error_data.get('error', {})
                    error_message = error_info.get('message', 'Unknown error')
                    error_details = error_info.get('details', [])
                    
                    # Check for content policy violations
                    user_friendly_msg = None
                    for detail in error_details:
                        reason = detail.get('reason', '')
                        if 'MINOR' in reason or 'PUBLIC' in reason:
                            user_friendly_msg = (
                                "⚠️ IMAGE REJECTED: Google's content policy detected a minor, "
                                "public figure, or copyrighted content in your image. "
                                "Please use a different image without people or recognizable figures."
                            )
                            break
                    
                    print(f"[UPLOAD] ✗ Failed!")
                    if user_friendly_msg:
                        print(f"[UPLOAD] {user_friendly_msg}")
                    else:
                        print(f"[UPLOAD] Error: {error_message}")
                    print(f"[UPLOAD] Response body: {json.dumps(error_data, indent=2)}")
                    
                    # Return error info for GUI display
                    return {'error': True, 'message': user_friendly_msg or error_message, 'details': error_data}
                    
                    
            return None
            
        except Exception as e:
            print(f"[UPLOAD] ✗ Exception: {e}")
            return None
    
    def generate_video(self, prompt, access_token, aspect_ratio='VIDEO_ASPECT_RATIO_LANDSCAPE', 
                       model='veo_3_1_t2v_fast_ultra', start_image_media_id=None, end_image_media_id=None):
        """Generate a video with the given prompt and optional start/end images"""
        scene_id = str(uuid.uuid4())
        seed = int(time.time() * 1000) % 50000
        
        # Adjust model key for Portrait if needed
        if aspect_ratio == 'VIDEO_ASPECT_RATIO_PORTRAIT' and '_portrait' not in model:
             model = model.replace('fast_ultra', 'fast_portrait_ultra')
             print(f"[API] Switched to Portrait Model: {model}")
        
        # Determine if this is image-to-video
        is_i2v = start_image_media_id is not None or end_image_media_id is not None
        
        if is_i2v:
            # Use i2v model variant
            if 't2v' in model:
                model = model.replace('t2v', 'i2v_s')
                print(f"[API] Switched to I2V Model: {model}")
        
        # Simulate human activity before each request
        self.simulate_human_activity()
        
        # Escape prompt for JavaScript
        prompt_escaped = prompt.replace('\\', '\\\\').replace('`', '\\`').replace('$', '\\$')
        
        # Build request object
        request_obj = {
            'aspectRatio': aspect_ratio,
            'seed': seed,
            'textInput': {'prompt': prompt},
            'videoModelKey': model,
            'metadata': {'sceneId': scene_id}
        }
        
        # Add start/end images if provided
        # For I2V, use simple mediaId structure (not nested mediaGenerationId)
        if start_image_media_id:
            request_obj['startImage'] = {'mediaId': start_image_media_id}
            print(f"[API] Using start image: {start_image_media_id}")
        
        if end_image_media_id:
            request_obj['endImage'] = {'mediaId': end_image_media_id}
            print(f"[API] Using end image: {end_image_media_id}")
        
        request_json = json.dumps(request_obj)
        
        # Use different endpoint for I2V
        if is_i2v:
            endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage'
        else:
            endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText'
        
        js_code = f'''
        (async function() {{
            try {{
                // Add small random delay before reCAPTCHA (human-like)
                await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1000) + 500));
                
                const token = await grecaptcha.enterprise.execute(
                    '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV',
                    {{ action: 'FLOW_GENERATION' }}
                );
                
                const payload = {{
                    clientContext: {{
                        recaptchaToken: token,
                        sessionId: ';' + Date.now(),
                        projectId: '{str(uuid.uuid4())}',
                        tool: 'PINHOLE',
                        userPaygateTier: 'PAYGATE_TIER_TWO'
                    }},
                    requests: [{request_json}]
                }};
                
                const response = await fetch(
                    '{endpoint}',
                    {{
                        method: 'POST',
                        headers: {{ 
                            'Content-Type': 'text/plain;charset=UTF-8',
                            'authorization': 'Bearer {access_token}'
                        }},
                        body: JSON.stringify(payload),
                        credentials: 'include'
                    }}
                );
                
                const text = await response.text();
                let data = null;
                try {{ data = JSON.parse(text); }} catch (e) {{ data = text; }}
                
                return JSON.stringify({{
                    success: response.ok,
                    status: response.status,
                    statusText: response.statusText,
                    headers: Object.fromEntries(response.headers),
                    data: data,
                    sceneId: '{scene_id}'
                }});
            }} catch (error) {{
                return JSON.stringify({{
                    success: false,
                    error: error.message
                }});
            }}
        }})()
        '''
        
        result_str = self.execute_js(js_code)
        if result_str:
            result = json.loads(result_str)
            
            # Detailed Logging
            mode = 'I2V' if is_i2v else 'T2V'
            print(f"\n{'='*20} API RESPONSE [{mode}] {'='*20}")
            print(f"Status: {result.get('status')} {result.get('statusText', '')}")
            if not result.get('success'):
                print(f"Error: {result.get('error')}")
                print(f"Body: {result.get('data')}")
            else:
                # Truncate success body to avoid spam, but show structure
                body_str = json.dumps(result.get('data'), indent=2)
                if len(body_str) > 1000:
                    print(f"Body: {body_str[:1000]}... (truncated)")
                else:
                    print(f"Body: {body_str}")
            print('='*60 + '\n')
            
            return result
        return None
    
    def generate_video_ui(self, prompt, model='veo_3_1_t2v_fast_ultra'):
        """Generate video using UI automation (type + click) instead of API calls"""
        try:
            print(f"[UI-AUTO] Starting UI-based generation...")
            
            # Step 1: Simulate human activity
            self.simulate_human_activity()
            time.sleep(random.uniform(0.5, 1.5))
            
            # Step 2: Type prompt into textarea
            print(f"[UI-AUTO] Typing prompt ({len(prompt)} chars)...")
            type_result = self.type_into_element('PINHOLE_TEXT_AREA_ELEMENT_ID', prompt, typing_speed='human')
            
            if not type_result.get('success'):
                print(f"[UI-AUTO] ✗ Failed to type prompt: {type_result.get('error')}")
                return {'success': False, 'error': f"Typing failed: {type_result.get('error')}"}
            
            print(f"[UI-AUTO] ✓ Prompt typed successfully")
            
            # Step 3: Human pause before clicking (thinking time)
            thinking_pause = random.uniform(1.0, 3.0)
            print(f"[UI-AUTO] Pausing {thinking_pause:.1f}s (human thinking)...")
            time.sleep(thinking_pause)
            
            # Step 4: Click the Create button
            print(f"[UI-AUTO] Clicking Create button...")
            # Try multiple possible selectors for the Create button
            button_selectors = [
                'button.kmBnUa',  # From inspection
                'button:has-text("Create")',
                'button[type="submit"]',
                'button.sc-c177465c-1'
            ]
            
            click_success = False
            for selector in button_selectors:
                click_result = self.click_element(selector)
                if click_result.get('success'):
                    print(f"[UI-AUTO] ✓ Button clicked (selector: {selector})")
                    click_success = True
                    break
            
            if not click_success:
                print(f"[UI-AUTO] ✗ Failed to click Create button")
                return {'success': False, 'error': 'Could not find or click Create button'}
            
            # Step 5: Wait for generation to start (UI feedback)
            print(f"[UI-AUTO] Waiting for generation to start...")
            time.sleep(3)
            
            # Step 6: Wait for video URL to appear in UI
            print(f"[UI-AUTO] Monitoring UI for video completion (timeout: 300s)...")
            url_result = self.wait_for_video_url(timeout=300)
            
            if url_result.get('success'):
                video_url = url_result.get('url')
                print(f"[UI-AUTO] ✓ Video ready! URL extracted via {url_result.get('method')}")
                return {
                    'success': True,
                    'video_url': video_url,
                    'prompt': prompt,
                    'method': 'ui_automation'
                }
            else:
                error = url_result.get('error', 'Unknown error')
                print(f"[UI-AUTO] ✗ Failed: {error}")
                return {
                    'success': False,
                    'error': error
                }
                
        except Exception as e:
            print(f"[UI-AUTO] ✗ Exception: {e}")
            return {
                'success': False,
                'error': str(e)
            }
    
    def poll_video_status(self, operation_name, scene_id, access_token):
        """Poll once for video generation status (single operation - legacy method)"""
        payload = {
            'operations': [{
                'operation': {'name': operation_name},
                'sceneId': scene_id,
                'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
            }]
        }
        
        js_code = f'''
        (async function() {{
            try {{
                const response = await fetch(
                    'https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus',
                    {{
                        method: 'POST',
                        headers: {{ 
                            'Content-Type': 'text/plain;charset=UTF-8',
                            'authorization': 'Bearer {access_token}'
                        }},
                        body: JSON.stringify({json.dumps(payload)}),
                        credentials: 'include'
                    }}
                );
                
                const text = await response.text();
                let data = null;
                try {{ data = JSON.parse(text); }} catch (e) {{ data = text; }}
                
                return JSON.stringify({{
                    success: response.ok,
                    status: response.status,
                    statusText: response.statusText,
                    data: data
                }});
            }} catch (error) {{
                return JSON.stringify({{
                    success: false,
                    error: error.message
                }});
            }}
        }})()
        '''
        
        result_str = self.execute_js(js_code)
        if result_str:
            result = json.loads(result_str)
            parsed = result # Alias for compatibility
            
            # Log only on error or non-200 for polling to reduce spam
            if not result.get('success') or result.get('status') != 200:
                print(f"\n[POLL API] Status: {result.get('status')} {result.get('statusText', '')}")
                print(f"Body: {result.get('data')}")
            
            if parsed.get('success'):
                response_data = parsed.get('data', {})
                if 'operations' in response_data and len(response_data['operations']) > 0:
                    return response_data['operations'][0]
        return None
    
    def poll_video_status_batch(self, operations_list, access_token):
        """Poll multiple video generation statuses in a single batch request
        
        Args:
            operations_list: List of tuples (operation_name, scene_id)
            access_token: Auth token
            
        Returns:
            List of operation data dictionaries, or None on error
        """
        # Build batch payload with all operations marked as ACTIVE
        payload = {
            'operations': [
                {
                    'operation': {'name': op_name},
                    'sceneId': scene_id,
                    'status': 'MEDIA_GENERATION_STATUS_ACTIVE'
                }
                for op_name, scene_id in operations_list
            ]
        }
        
        js_code = f'''
        (async function() {{
            try {{
                const response = await fetch(
                    'https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus',
                    {{
                        method: 'POST',
                        headers: {{ 
                            'Content-Type': 'text/plain;charset=UTF-8',
                            'authorization': 'Bearer {access_token}'
                        }},
                        body: JSON.stringify({json.dumps(payload)}),
                        credentials: 'include'
                    }}
                );
                
                const text = await response.text();
                let data = null;
                try {{ data = JSON.parse(text); }} catch (e) {{ data = text; }}
                
                return JSON.stringify({{
                    success: response.ok,
                    status: response.status,
                    statusText: response.statusText,
                    data: data
                }});
            }} catch (error) {{
                return JSON.stringify({{
                    success: false,
                    error: error.message
                }});
            }}
        }})()
        '''
        
        result_str = self.execute_js(js_code)
        if result_str:
            result = json.loads(result_str)
            
            # Log only on error or non-200
            if not result.get('success') or result.get('status') != 200:
                print(f"\n[BATCH POLL API] Status: {result.get('status')} {result.get('statusText', '')}")
                print(f"Body: {result.get('data')}")
            
            if result.get('success'):
                response_data = result.get('data', {})
                if 'operations' in response_data:
                    return response_data['operations']
        return None
    
    def download_video(self, video_url, output_path):
        """Download video from URL"""
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept': '*/*',
        }
        
        try:
            response = requests.get(video_url, headers=headers, stream=True, timeout=60)
            
            if response.status_code == 200:
                total_bytes = 0
                with open(output_path, 'wb') as f:
                    for chunk in response.iter_content(chunk_size=8192):
                        if chunk:
                            f.write(chunk)
                            total_bytes += len(chunk)
                return total_bytes
            return 0
        except Exception as e:
            raise Exception(f"Download error: {e}")
    
    def close(self):
        if self.ws:
            self.ws.close()


class SimpleAutoLogin:
    """Automated Google login for Flow UI - Simple working version"""
    def __init__(self, email, password, debug_port=9222):
        self.email = email
        self.password = password
        self.debug_port = debug_port
        self.ws = None
        self.msg_id = 0
        
    def connect(self):
        try:
            response = requests.get(f'http://localhost:{self.debug_port}/json')
            tabs = response.json()
        except:
            print(f"[LOGIN] Could not connect to Chrome on port {self.debug_port}")
            return False
            
        target_tab = tabs[0] if tabs else None
        if not target_tab:
            return False
            
        self.ws = create_connection(target_tab['webSocketDebuggerUrl'])
        return True
        
    def send_command(self, method, params=None):
        self.msg_id += 1
        msg = {'id': self.msg_id, 'method': method, 'params': params or {}}
        self.ws.send(json.dumps(msg))
        while True:
            resp = json.loads(self.ws.recv())
            if resp.get('id') == self.msg_id:
                return resp
                
    def execute_js(self, expression):
        res = self.send_command('Runtime.evaluate', {
            'expression': expression, 
            'returnByValue': True,
            'awaitPromise': True
        })
        return res.get('result', {}).get('result', {}).get('value')
    
    def clear_data(self):
        """Clear cookies and cache"""
        print("[LOGIN] Clearing cookies and cache...")
        try:
            self.send_command('Network.enable')
            self.send_command('Network.clearBrowserCache')
            self.send_command('Network.clearBrowserCookies')
            print("[LOGIN] ✓ Data cleared")
        except Exception as e:
            print(f"[LOGIN] Warning: {e}")
    
    def run(self):
        if not self.connect():
            print("[LOGIN] Failed to connect")
            return False
        
        # Step 1: Clear ALL browser data
        print("[LOGIN] Clearing ALL browser data...")
        try:
            self.send_command('Network.enable')
            self.send_command('Storage.enable')
            self.send_command('Network.clearBrowserCache')
            self.send_command('Network.clearBrowserCookies')
            
            # Clear all storage
            self.send_command('Storage.clearDataForOrigin', {
                'origin': '*',
                'storageTypes': 'all'
            })
            
            # Clear via JS too
            self.execute_js("""
            (function() {
                try {
                    localStorage.clear();
                    sessionStorage.clear();
                } catch(e) {}
            })();
            """)
            print("[LOGIN] ✓ All data cleared")
        except Exception as e:
            print(f"[LOGIN] Warning: {e}")
        
        time.sleep(2)
        
        # Step 2: Check if already on Flow page, if not navigate
        current_url = self.execute_js("return window.location.href")
        if current_url and 'labs.google' in str(current_url):
            print("[LOGIN] Already on Flow page - refreshing...")
            self.execute_js("window.location.reload()")
        else:
            print("[LOGIN] Navigating to Flow...")
            self.execute_js("window.location.href = 'https://labs.google/fx/tools/flow'")
        time.sleep(5)
        
        # Step 3: Click "Create with Flow" button (triggers OAuth redirect)
        print("[LOGIN] Looking for 'Create with Flow' button...")
        button_found = False
        for i in range(15):
            clicked = self.execute_js("""
            (function() {
                const buttons = Array.from(document.querySelectorAll('button, div[role="button"], a'));
                const createBtn = buttons.find(b => 
                    b.innerText && b.innerText.includes('Create with Flow')
                );
                if (createBtn) {
                    createBtn.click();
                    return true;
                }
                return false;
            })()
            """)
            
            if clicked:
                print("[LOGIN] ✓ Clicked 'Create with Flow' - redirecting to Google OAuth...")
                button_found = True
                break
            else:
                print(f"[LOGIN] Waiting for button... ({i+1}/15)")
                time.sleep(2)
        
        if not button_found:
            print("[LOGIN] ✗ 'Create with Flow' button not found")
            return False
        
        time.sleep(3)
        
        # Step 4: Wait for Google OAuth page to load
        print("[LOGIN] Waiting for Google login page...")
        google_ready = False
        for i in range(15):
            url = self.execute_js("return window.location.href")
            if url and 'accounts.google.com' in str(url):
                google_ready = True
                print("[LOGIN] ✓ Google login page loaded")
                break
            time.sleep(1)
        
        if not google_ready:
            print("[LOGIN] ⚠ Not on Google login page - may already be logged in")
            # Check if we're back on Flow
            time.sleep(3)
            url = self.execute_js("return window.location.href")
            if url and 'labs.google' in str(url):
                print("[LOGIN] Already logged in - on Flow page")
                return True
        
        time.sleep(2)
        
        # Step 5: Enter email
        print("[LOGIN] Entering email...")
        self.execute_js(f"""
        (function() {{
            const input = document.getElementById('identifierId');
            if (input) {{
                input.focus();
                input.value = '{self.email}';
                input.dispatchEvent(new Event('input', {{ bubbles: true }}));
            }}
        }})()
        """)
        time.sleep(2)
        
        print("[LOGIN] Clicking Next (email)...")
        self.execute_js("""
        (function() {
            const btn = document.getElementById('identifierNext');
            if (btn) btn.click();
        })()
        """)
        time.sleep(5)
        
        # Step 6: Enter password
        print("[LOGIN] Entering password...")
        self.execute_js("""
        (function() {
            const input = document.querySelector('input[name="Passwd"]');
            if (input) input.focus();
        })()
        """)
        time.sleep(1)
        
        self.execute_js(f"""
        (function() {{
            const input = document.querySelector('input[name="Passwd"]');
            if (input) {{
                input.value = '{self.password}';
                input.dispatchEvent(new Event('input', {{ bubbles: true }}));
            }}
        }})()
        """)
        time.sleep(2)
        
        print("[LOGIN] Clicking Next (password)...")
        self.execute_js("""
        (function() {
            const btn = document.querySelector('#passwordNext');
            if (btn) btn.click();
        })()
        """)
        
        # Step 7: Wait for redirect back to Flow (it auto-redirects to generation page)
        print("[LOGIN] Waiting for redirect back to Flow...")
        for i in range(20):
            url = self.execute_js("return window.location.href")
            if url and 'labs.google' in str(url):
                print("[LOGIN] ✓ Redirected to Flow generation page")
                break
            time.sleep(1)
        
        print("[LOGIN] ✓ Login complete! Token verification will happen separately.")
        return True
        
    def close(self):
        if self.ws:
            self.ws.close()


class ProjectManager:
    """Manages project state and auto-save"""
    def __init__(self, project_path: str):
        self.project_path = project_path
        self.project_data = {
            'project_name': Path(project_path).stem,
            'created': datetime.now().isoformat(),
            'output_folder': str(Path(project_path).parent),
            'scenes': [],
            'stats': {'total': 0, 'completed': 0, 'failed': 0, 'pending': 0}
        }
    
    def save(self, scenes: List[SceneData]):
        """Save project state"""
        self.project_data['scenes'] = [s.to_dict() for s in scenes]
        self.project_data['stats'] = {
            'total': len(scenes),
            'completed': sum(1 for s in scenes if s.status == 'completed'),
            'failed': sum(1 for s in scenes if s.status == 'failed'),
            'pending': sum(1 for s in scenes if s.status == 'queued')
        }
        
        with open(self.project_path, 'w', encoding='utf-8') as f:
            json.dump(self.project_data, f, indent=2, ensure_ascii=False)
    
    @staticmethod
    def load(project_path: str) -> tuple:
        """Load project state"""
        with open(project_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        scenes = [SceneData.from_dict(s) for s in data['scenes']]
        output_folder = data['output_folder']
        return scenes, output_folder


def parse_json_prompts(text: str) -> List[Dict]:
    """Extract and parse JSON array from text"""
    # Find content between [ and ]
    match = re.search(r'\[(.*)\]', text, re.DOTALL)
    if not match:
        raise ValueError("No JSON array found in text (looking for [...] brackets)")
    
    json_str = '[' + match.group(1) + ']'
    data = json.loads(json_str)
    
    # Send entire JSON object as prompt
    prompts = []
    for item in data:
        scene_id = item.get('scene_id', len(prompts) + 1)
        # Convert entire JSON object to formatted string
        prompt = json.dumps(item, indent=2, ensure_ascii=False)
        prompts.append({'scene_id': scene_id, 'prompt': prompt})
    
    return prompts


def parse_txt_prompts(text: str) -> List[Dict]:
    """Parse line-separated prompts"""
    lines = [line.strip() for line in text.split('\n') if line.strip()]
    return [{'scene_id': i+1, 'prompt': line} for i, line in enumerate(lines)]


# Configuration
PROFILES_DIR = "h:/gravityapps/veo3/profiles"
CHROME_PATH = r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
if not os.path.exists(CHROME_PATH):
    CHROME_PATH = r"C:\Program Files\Google\Chrome\Application\chrome.exe"

class BulkVideoGeneratorGUI:
    """Main GUI for bulk video generation"""
    
    def __init__(self, root):
        self.root = root
        self.root.title("Bulk Video Generator - Production System")
        self.root.geometry("1400x900")
        
        # Ensure directories
        os.makedirs(PROFILES_DIR, exist_ok=True)
        
        self.scenes: List[SceneData] = []
        self.generator: Optional[BrowserVideoGenerator] = None
        self.project_manager: Optional[ProjectManager] = None
        self.scene_cards = {}
        
        # Default output folder - create if doesn't exist
        self.output_folder = str(Path.cwd() / "downloads_videos")
        os.makedirs(self.output_folder, exist_ok=True)
        
        self.is_running = False
        self.is_paused = False
        self.current_index = 0
        self.rate_limit = 2.0  # requests per second
        self.access_token: Optional[str] = None
        
        self.auto_save_timer = None
        
        # Threading
        self.pending_polls = queue.Queue()
        self.active_generations_count = 0
        
        # Auto-relogin on 403 errors
        self.consecutive_403_errors = 0
        self.max_403_before_relogin = 3
        
        # Multi-browser support
        self.browser_connections = []  # List of {profile, port, generator, access_token, 403_count, status}
        self.video_retry_counts = {}  # {scene_id: retry_count} - max 3 retries per video
        self.current_browser_index = 0  # For round-robin distribution
        self.base_debug_port = 9222
        self.multi_browser_mode = False
        
        # UI Setup
        self.setup_ui()
        
        # Start polling thread
        self.polling_thread = threading.Thread(target=self.poll_worker, daemon=True)
        self.polling_thread.start()
        
        # Load profiles
        self.load_profiles()
    
    def load_profiles(self):
        """Load available Chrome profiles"""
        self.profiles = [d.name for d in Path(PROFILES_DIR).iterdir() if d.is_dir()]
        self.profiles.sort()
        if not self.profiles:
            self.profiles = ["Default"]
            os.makedirs(os.path.join(PROFILES_DIR, "Default"), exist_ok=True)
        
        if hasattr(self, 'profile_combo'):
            self.profile_combo['values'] = self.profiles
            if self.profiles:
                self.profile_combo.current(0)
            
    def create_new_profile(self):
        """Create new Chrome profile"""
        name = tk.simpledialog.askstring("New Profile", "Enter profile name:")
        if name:
            clean_name = "".join(x for x in name if x.isalnum() or x in "._- ")
            if not clean_name:
                messagebox.showerror("Error", "Invalid profile name")
                return
                
            path = os.path.join(PROFILES_DIR, clean_name)
            if os.path.exists(path):
                messagebox.showerror("Error", "Profile already exists")
                return
                
            try:
                os.makedirs(path)
                self.load_profiles()
                # Select the new profile
                if clean_name in self.profiles:
                    idx = self.profiles.index(clean_name)
                    self.profile_combo.current(idx)
                messagebox.showinfo("Success", f"Created profile: {clean_name}")
            except Exception as e:
                messagebox.showerror("Error", f"Failed to create profile: {e}")
    
    def delete_profile(self):
        """Delete selected Chrome profile immediately (no confirmation)"""
        profile_name = self.profile_combo.get()
        if not profile_name:
            print("[PROFILE] No profile selected to delete")
            return
        
        profile_path = os.path.join(PROFILES_DIR, profile_name)
        
        if not os.path.exists(profile_path):
            print(f"[PROFILE] Profile path does not exist: {profile_path}")
            return
        
        try:
            # Delete the entire profile folder
            import shutil
            shutil.rmtree(profile_path)
            print(f"[PROFILE] ✓ Deleted profile: {profile_name}")
            
            # Reload profiles
            self.load_profiles()
            
            # Select first available profile, or create Default if none exist
            if self.profiles:
                self.profile_combo.current(0)
            else:
                # No profiles left, create a new Default
                default_path = os.path.join(PROFILES_DIR, "Default")
                os.makedirs(default_path, exist_ok=True)
                self.load_profiles()
                if "Default" in self.profiles:
                    idx = self.profiles.index("Default")
                    self.profile_combo.current(idx)
            
            print(f"[PROFILE] Profile '{profile_name}' deleted successfully")
            
        except Exception as e:
            print(f"[PROFILE] ✗ Failed to delete profile: {e}")
            messagebox.showerror("Error", f"Failed to delete profile: {e}")
    
    def launch_chrome(self):
        """Launch Chrome with selected profile and remote debugging"""
        profile_name = self.profile_combo.get()
        if not profile_name:
            return
            
        profile_path = os.path.join(PROFILES_DIR, profile_name)
        
        try:
            import subprocess
            cmd = [
                CHROME_PATH,
                "--remote-debugging-port=9222",
                "--remote-allow-origins=*",
                f"--user-data-dir={profile_path}",
                "--profile-directory=Default",
                "https://labs.google/fx/tools/flow"
            ]
            
            subprocess.Popen(cmd)
            # Removed popup - just log to console
            print(f"[CHROME] ✓ Chrome launched with profile '{profile_name}'")
            
        except Exception as e:
            print(f"[CHROME] ✗ Failed to launch Chrome: {e}")
        
    def setup_ui(self):
        # Profile Manager Frame (NEW)
        profile_frame = ttk.LabelFrame(self.root, text="Chrome Profile Manager", padding=5)
        profile_frame.pack(fill=tk.X, padx=10, pady=5)
        
        ttk.Label(profile_frame, text="Select Profile:").pack(side=tk.LEFT, padx=5)
        
        self.profile_combo = ttk.Combobox(profile_frame, state="readonly", width=30)
        self.profile_combo.pack(side=tk.LEFT, padx=5)
        if hasattr(self, 'profiles') and self.profiles:
            self.profile_combo['values'] = self.profiles
            self.profile_combo.current(0)
        
        ttk.Button(profile_frame, text="🚀 Launch Chrome", command=self.launch_chrome).pack(side=tk.LEFT, padx=5)
        ttk.Button(profile_frame, text="+ New Profile", command=self.create_new_profile).pack(side=tk.LEFT, padx=5)
        ttk.Button(profile_frame, text="🗑️ Delete", command=self.delete_profile).pack(side=tk.LEFT, padx=2)
        
        # Login credentials
        ttk.Label(profile_frame, text="Email:").pack(side=tk.LEFT, padx=(20,5))
        self.email_entry = ttk.Entry(profile_frame, width=25)
        self.email_entry.insert(0, "zakar12@pingrt.xyz")
        self.email_entry.pack(side=tk.LEFT, padx=2)
        
        ttk.Label(profile_frame, text="Password:").pack(side=tk.LEFT, padx=5)
        self.password_entry = ttk.Entry(profile_frame, width=15, show="*")
        self.password_entry.insert(0, "m1074652")
        self.password_entry.pack(side=tk.LEFT, padx=2)
        
        ttk.Button(profile_frame, text="🔐 Auto Login", command=self.auto_login).pack(side=tk.LEFT, padx=5)
        
        # Multi-browser section
        ttk.Separator(profile_frame, orient='vertical').pack(side=tk.LEFT, fill='y', padx=10)
        
        ttk.Label(profile_frame, text="Multi-Browser:").pack(side=tk.LEFT, padx=5)
        self.browser_count_var = tk.StringVar(value="1")
        self.browser_count_spinbox = ttk.Spinbox(profile_frame, from_=1, to=10, width=3, 
                                                  textvariable=self.browser_count_var)
        self.browser_count_spinbox.pack(side=tk.LEFT, padx=2)
        
        ttk.Button(profile_frame, text="🚀 Login All", command=self.login_all_browsers).pack(side=tk.LEFT, padx=3)
        ttk.Button(profile_frame, text="Connect All Opened", command=self.connect_open_browsers).pack(side=tk.LEFT, padx=3)
        ttk.Button(profile_frame, text="Open Without Login", command=self.open_browsers_no_login).pack(side=tk.LEFT, padx=3)
        
        # Browser status label
        self.browser_status_label = ttk.Label(profile_frame, text="0 browsers connected", foreground="gray")
        self.browser_status_label.pack(side=tk.LEFT, padx=10)



        # Top control panel
        control_frame = ttk.Frame(self.root)
        control_frame.pack(fill=tk.X, padx=10, pady=5)
        
        # File operations
        ttk.Button(control_frame, text="📁 Load JSON/TXT", command=self.load_file).pack(side=tk.LEFT, padx=2)
        ttk.Button(control_frame, text="📋 Paste JSON", command=self.paste_json).pack(side=tk.LEFT, padx=2)
        ttk.Button(control_frame, text="💾 Save Project", command=self.save_project).pack(side=tk.LEFT, padx=2)
        ttk.Button(control_frame, text="📂 Load Project", command=self.load_project).pack(side=tk.LEFT, padx=2)
        ttk.Button(control_frame, text="📁 Set Output Folder", command=self.set_output_folder).pack(side=tk.LEFT, padx=2)
        ttk.Button(control_frame, text="🎬 Concatenate Videos", command=self.concatenate_videos).pack(side=tk.LEFT, padx=2)
        
        # Stats display
        stats_frame = ttk.Frame(self.root)
        stats_frame.pack(fill=tk.X, padx=10, pady=5)
        
        self.stats_label = ttk.Label(stats_frame, text="No scenes loaded", font=('Arial', 10))
        self.stats_label.pack(side=tk.LEFT)
        
        # Queue controls
        queue_frame = ttk.LabelFrame(self.root, text="Queue Controls", padding=5)
        queue_frame.pack(fill=tk.X, padx=10, pady=5)
        
        # Range controls
        range_frame = ttk.Frame(queue_frame)
        range_frame.pack(fill=tk.X, pady=2)
        
        ttk.Label(range_frame, text="From:").pack(side=tk.LEFT)
        self.from_spinbox = ttk.Spinbox(range_frame, from_=1, to=999, width=5)
        self.from_spinbox.set("1")
        self.from_spinbox.pack(side=tk.LEFT, padx=2)
        
        ttk.Label(range_frame, text="To:").pack(side=tk.LEFT, padx=(10,0))
        self.to_spinbox = ttk.Spinbox(range_frame, from_=1, to=999, width=5)
        self.to_spinbox.set("999")
        self.to_spinbox.pack(side=tk.LEFT, padx=2)
        
        # Rate limit
        ttk.Label(range_frame, text="Rate (req/sec):").pack(side=tk.LEFT, padx=(10,0))
        self.rate_var = tk.StringVar(value="2")
        rate_combo = ttk.Combobox(range_frame, textvariable=self.rate_var, values=["1", "2", "3", "4", "10"], width=5, state='readonly')
        rate_combo.pack(side=tk.LEFT, padx=2)
        rate_combo.bind('<<ComboboxSelected>>', lambda e: setattr(self, 'rate_limit', float(self.rate_var.get())))
        
        # Aspect Ratio logic
        ttk.Label(range_frame, text="Ratio:").pack(side=tk.LEFT, padx=(10,0))
        self.ar_var = tk.StringVar(value="VIDEO_ASPECT_RATIO_LANDSCAPE")
        
        ar_display_var = tk.StringVar(value="Landscape (16:9)")
        ar_options = ["Landscape (16:9)", "Portrait (9:16)"]
        self.ar_map = {
            "Landscape (16:9)": "VIDEO_ASPECT_RATIO_LANDSCAPE",
            "Portrait (9:16)": "VIDEO_ASPECT_RATIO_PORTRAIT"
        }
        
        ar_combo = ttk.Combobox(range_frame, textvariable=ar_display_var, values=ar_options, width=15, state='readonly')
        ar_combo.pack(side=tk.LEFT, padx=2)
        
        def on_ar_change(event):
            self.ar_var.set(self.ar_map.get(ar_display_var.get(), "VIDEO_ASPECT_RATIO_LANDSCAPE"))
            print(f"[CONFIG] Aspect Ratio set to: {self.ar_var.get()}")
            
        ar_combo.bind('<<ComboboxSelected>>', on_ar_change)

        # Model selection
        ttk.Label(range_frame, text="Model:").pack(side=tk.LEFT, padx=(10,0))
        self.model_var = tk.StringVar(value="veo_3_1_t2v_fast_ultra_relaxed")
        
        # Friendly names for the dropdown
        model_names = [
            "Veo 3.1 Fast Ultra (Standard - 10 credits)",
            "Veo 3.1 Fast Ultra Relaxed (0 credits - Free)"
        ]
        
        # Map friendly names to keys
        self.model_map = {
            "Veo 3.1 Fast Ultra (Standard - 10 credits)": "veo_3_1_t2v_fast_ultra",
            "Veo 3.1 Fast Ultra Relaxed (0 credits - Free)": "veo_3_1_t2v_fast_ultra_relaxed"
        }
        
        self.model_display_var = tk.StringVar(value="Veo 3.1 Fast Ultra Relaxed (0 credits - Free)")
        
        model_combo = ttk.Combobox(range_frame, textvariable=self.model_display_var, values=model_names, width=35, state='readonly')
        model_combo.pack(side=tk.LEFT, padx=2)
        
        def on_model_change(event):
            selected_name = self.model_display_var.get()
            self.model_var.set(self.model_map.get(selected_name, "veo_3_1_t2v_fast_ultra"))
            print(f"[CONFIG] Model set to: {self.model_var.get()} ({selected_name})")
            
        model_combo.bind('<<ComboboxSelected>>', on_model_change)
        
        # Control buttons
        btn_frame = ttk.Frame(queue_frame)
        btn_frame.pack(fill=tk.X, pady=2)
        
        self.start_btn = ttk.Button(btn_frame, text="▶ Start", command=self.start_generation)
        self.start_btn.pack(side=tk.LEFT, padx=2)
        
        self.pause_btn = ttk.Button(btn_frame, text="⏸ Pause", command=self.pause_generation, state='disabled')
        self.pause_btn.pack(side=tk.LEFT, padx=2)
        
        self.stop_btn = ttk.Button(btn_frame, text="⏹ Stop", command=self.stop_generation, state='disabled')
        self.stop_btn.pack(side=tk.LEFT, padx=2)
        
        ttk.Button(btn_frame, text="🔄 Retry All Failed", command=self.retry_failed).pack(side=tk.LEFT, padx=2)
        ttk.Button(btn_frame, text="📥 Recover Downloads", command=self.recover_downloads).pack(side=tk.LEFT, padx=2)
        ttk.Button(btn_frame, text="🔍 Poll & Download", command=self.start_polling).pack(side=tk.LEFT, padx=2)
        
        # Scene cards container (scrollable)
        canvas_frame = ttk.Frame(self.root)
        canvas_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=5)
        
        canvas = tk.Canvas(canvas_frame, bg='#f0f0f0')
        scrollbar = ttk.Scrollbar(canvas_frame, orient="vertical", command=canvas.yview)
        self.scenes_frame = ttk.Frame(canvas)
        
        self.scenes_frame.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=self.scenes_frame, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)
        
        canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")
        
        # Bind mouse wheel
        canvas.bind_all("<MouseWheel>", lambda e: canvas.yview_scroll(int(-1*(e.delta/120)), "units"))
        
    def load_file(self):
        """Load JSON or TXT file"""
        file_path = filedialog.askopenfilename(
            title="Select Prompts File",
            filetypes=[("JSON files", "*.json"), ("Text files", "*.txt"), ("All files", "*.*")]
        )
        
        if not file_path:
            return
        
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            if file_path.endswith('.json'):
                prompts = parse_json_prompts(content)
            else:
                prompts = parse_txt_prompts(content)
            
            self.scenes = [SceneData(p['scene_id'], p['prompt']) for p in prompts]
            self.to_spinbox.config(to=len(self.scenes))
            self.to_spinbox.set(str(len(self.scenes)))
            
            self.render_scene_cards()
            self.update_stats()
            
            messagebox.showinfo("Success", f"Loaded {len(self.scenes)} scenes")
        except Exception as e:
            messagebox.showerror("Error", f"Failed to load file: {e}")
    
    def paste_json(self):
        """Paste JSON or plain text directly"""
        dialog = tk.Toplevel(self.root)
        dialog.title("Paste Prompts")
        dialog.geometry("700x500")
        
        ttk.Label(dialog, text="Paste JSON (auto-extracts [...]) or plain text (one prompt per line):", 
                  font=('Arial', 10, 'bold')).pack(padx=10, pady=5)
        
        text_area = scrolledtext.ScrolledText(dialog, width=80, height=22, wrap=tk.WORD)
        text_area.pack(padx=10, pady=5, fill=tk.BOTH, expand=True)
        
        # Prompt count label
        count_label = ttk.Label(dialog, text="Prompts detected: 0", foreground='blue')
        count_label.pack(pady=2)
        
        def update_count(*args):
            """Update prompt count as user types"""
            content = text_area.get("1.0", tk.END).strip()
            if not content:
                count_label.config(text="Prompts detected: 0")
                return
            
            try:
                # Try JSON first
                prompts = parse_json_prompts(content)
                count_label.config(text=f"Prompts detected: {len(prompts)} (JSON format)", foreground='green')
            except:
                # Fall back to TXT
                try:
                    prompts = parse_txt_prompts(content)
                    count_label.config(text=f"Prompts detected: {len(prompts)} (Text format)", foreground='blue')
                except:
                    count_label.config(text="No valid prompts detected", foreground='red')
        
        # Bind text change to update count
        text_area.bind('<KeyRelease>', update_count)
        
        def process_content():
            content = text_area.get("1.0", tk.END).strip()
            if not content:
                messagebox.showwarning("Empty", "Please paste content")
                return
            
            try:
                # Try JSON first
                try:
                    prompts = parse_json_prompts(content)
                    format_type = "JSON"
                except:
                    # Fall back to TXT
                    prompts = parse_txt_prompts(content)
                    format_type = "text"
                
                if not prompts:
                    messagebox.showwarning("No Prompts", "No prompts detected in the pasted content")
                    return
                
                self.scenes = [SceneData(p['scene_id'], p['prompt']) for p in prompts]
                self.to_spinbox.config(to=len(self.scenes))
                self.to_spinbox.set(str(len(self.scenes)))
                
                self.render_scene_cards()
                self.update_stats()
                
                dialog.destroy()
                messagebox.showinfo("Success", f"Loaded {len(self.scenes)} scenes from {format_type} format")
            except Exception as e:
                messagebox.showerror("Error", f"Failed to parse content: {e}")
        
        btn_frame = ttk.Frame(dialog)
        btn_frame.pack(pady=5)
        
        ttk.Button(btn_frame, text="✓ Load Scenes", command=process_content).pack(side=tk.LEFT, padx=5)
        ttk.Button(btn_frame, text="✗ Cancel", command=dialog.destroy).pack(side=tk.LEFT, padx=5)
    
    def set_output_folder(self):
        """Set output folder for videos"""
        folder = filedialog.askdirectory(title="Select Output Folder")
        if folder:
            self.output_folder = folder
            messagebox.showinfo("Success", f"Output folder set to:\n{folder}")
    
    def save_project(self):
        """Save project state"""
        if not self.scenes:
            messagebox.showwarning("No Data", "No scenes to save")
            return
        
        file_path = filedialog.asksaveasfilename(
            title="Save Project",
            defaultextension=".json",
            filetypes=[("JSON files", "*.json")]
        )
        
        if file_path:
            self.project_manager = ProjectManager(file_path)
            self.project_manager.project_data['output_folder'] = self.output_folder
            self.project_manager.save(self.scenes)
            messagebox.showinfo("Success", "Project saved")
    
    def recover_downloads(self):
        """Recover missing downloads from log file"""
        ops_file = Path(self.output_folder) / "active_operations.jsonl"
        
        if not ops_file.exists():
            messagebox.showwarning("No Log", "No active_operations.jsonl found in output folder")
            return
            
        try:
            recovered_scenes = []
            seen_ids = set()
            
            # Read operations
            with open(ops_file, 'r', encoding='utf-8') as f:
                for line in f:
                    if not line.strip(): continue
                    try:
                        data = json.loads(line)
                        scene_id = data.get('scene_id')
                        uuid_val = data.get('uuid')
                        
                        # Check if video already exists
                        video_path = Path(self.output_folder) / f"scene_{scene_id:03d}.mp4"
                        
                        if not video_path.exists() and scene_id not in seen_ids:
                            scene = SceneData(scene_id, data.get('prompt', ''))
                            scene.operation_name = data.get('operation')
                            scene.status = 'polling'
                            recovered_scenes.append((scene, uuid_val))
                            seen_ids.add(scene_id)
                            
                    except Exception as e:
                        print(f"[RECOVER] Failed to parse line: {e}")
            
            if not recovered_scenes:
                messagebox.showinfo("Complete", "All videos in log appear to be downloaded already!")
                return
                
            # Populate UI
            self.scenes = [s[0] for s in recovered_scenes]
            self.render_scene_cards()
            self.update_stats()
            
            if messagebox.askyesno("Recover", f"Found {len(recovered_scenes)} pending downloads. Start recovery polling?"):
                self.is_running = True
                self.is_paused = False
                self.start_btn.config(state='disabled')
                self.pause_btn.config(state='disabled')
                self.stop_btn.config(state='normal')
                
                # Setup generator for polling
                try:
                    self.generator = BrowserVideoGenerator()
                    self.generator.connect()
                    self.access_token = self.generator.get_access_token()
                    
                    if not self.access_token:
                        messagebox.showerror("Error", "Failed to get access token from browser")
                        return
                        
                    # Initialize queue
                    self.pending_polls = queue.Queue()
                    self.generation_complete = True  # No generation needed
                    
                    # Fill queue
                    for scene, uuid_val in recovered_scenes:
                        self.pending_polls.put((scene, uuid_val))
                    
                    # Start ONLY polling thread
                    thread = threading.Thread(target=self.process_polling_queue, daemon=True)
                    thread.start()
                    
                except Exception as e:
                    messagebox.showerror("Error", f"Failed to start recovery: {e}")
                    
        except Exception as e:
            messagebox.showerror("Error", f"Recovery processing failed: {e}")
    
    def load_project(self):
        """Load project state"""
        file_path = filedialog.askopenfilename(
            title="Load Project",
            filetypes=[("JSON files", "*.json")]
        )
        
        if file_path:
            try:
                self.scenes, self.output_folder = ProjectManager.load(file_path)
                self.project_manager = ProjectManager(file_path)
                self.render_scene_cards()
                self.update_stats()
                messagebox.showinfo("Success", f"Loaded {len(self.scenes)} scenes from project")
            except Exception as e:
                messagebox.showerror("Error", f"Failed to load project: {e}")
    
    def render_scene_cards(self):
        """Render all scene cards in grid"""
        # Clear existing cards
        for widget in self.scenes_frame.winfo_children():
            widget.destroy()
        self.scene_cards.clear()
        
        # Create grid of cards (4 columns)
        for i, scene in enumerate(self.scenes):
            row = i // 4
            col = i % 4
            
            card = self.create_scene_card(scene)
            card.grid(row=row, column=col, padx=5, pady=5, sticky='nsew')
            self.scene_cards[scene.scene_id] = card
    
    def create_scene_card(self, scene: SceneData) -> ttk.Frame:
        """Create a single scene card"""
        card = ttk.LabelFrame(self.scenes_frame, text=f"Scene {scene.scene_id}", padding=5)
        
        # Editable Prompt (Text Widget)
        # Using a Frame to hold Scrollbar + Text
        text_frame = ttk.Frame(card)
        text_frame.pack(fill=tk.X, expand=True)
        
        prompt_text = tk.Text(text_frame, height=5, width=40, wrap=tk.WORD, font=('Arial', 9))
        prompt_text.insert('1.0', scene.prompt)
        prompt_text.pack(side=tk.LEFT, fill=tk.X, expand=True)
        
        # Scrollbar
        scrollbar = ttk.Scrollbar(text_frame, orient=tk.VERTICAL, command=prompt_text.yview)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        prompt_text['yscrollcommand'] = scrollbar.set
        
        # Bind events to save prompt
        prompt_text.bind('<FocusOut>', lambda e, s=scene, t=prompt_text: self.save_scene_prompt(s, t))
        
        # Store widget ref
        card.prompt_text = prompt_text
        
        # ========== GENERATION METHODS SECTION ==========
        methods_container = ttk.Frame(card)
        methods_container.pack(fill=tk.X, pady=3)
        
        # --- Frames to Video Section ---
        frames_frame = ttk.LabelFrame(methods_container, text="🎬 Frames to Video", padding=3)
        frames_frame.pack(fill=tk.X, pady=2)
        
        # First Frame
        first_frame_row = ttk.Frame(frames_frame)
        first_frame_row.pack(fill=tk.X, pady=1)
        
        ttk.Label(first_frame_row, text="First Frame:", width=10).pack(side=tk.LEFT)
        first_frame_label = ttk.Label(first_frame_row, text="None", foreground="gray", width=20)
        first_frame_label.pack(side=tk.LEFT, padx=2)
        
        if scene.first_frame_path:
            first_frame_label.config(text=Path(scene.first_frame_path).name, foreground="green")
        
        ttk.Button(first_frame_row, text="📷 Pick", width=6,
                  command=lambda: self.pick_image_for_scene(scene, 'first')).pack(side=tk.LEFT, padx=1)
        ttk.Button(first_frame_row, text="✗", width=3,
                  command=lambda: self.clear_image_for_scene(scene, 'first')).pack(side=tk.LEFT)
        
        # Last Frame
        last_frame_row = ttk.Frame(frames_frame)
        last_frame_row.pack(fill=tk.X, pady=1)
        
        ttk.Label(last_frame_row, text="Last Frame:", width=10).pack(side=tk.LEFT)
        last_frame_label = ttk.Label(last_frame_row, text="None", foreground="gray", width=20)
        last_frame_label.pack(side=tk.LEFT, padx=2)
        
        if scene.last_frame_path:
            last_frame_label.config(text=Path(scene.last_frame_path).name, foreground="green")
        
        ttk.Button(last_frame_row, text="📷 Pick", width=6,
                  command=lambda: self.pick_image_for_scene(scene, 'last')).pack(side=tk.LEFT, padx=1)
        ttk.Button(last_frame_row, text="✗", width=3,
                  command=lambda: self.clear_image_for_scene(scene, 'last')).pack(side=tk.LEFT)
        
        # --- Ingredients to Video Section (Reserved for future) ---
        ingredients_frame = ttk.LabelFrame(methods_container, text="🍳 Ingredients to Video (Coming Soon)", padding=3)
        ingredients_frame.pack(fill=tk.X, pady=2)
        
        placeholder_label = ttk.Label(ingredients_frame, text="Feature under development...", 
                                     foreground="gray", font=('Arial', 8, 'italic'))
        placeholder_label.pack(pady=5)
        
        # Store label refs for updates
        card.first_frame_label = first_frame_label
        card.last_frame_label = last_frame_label
        
        # Status
        status_colors = {
            'queued': 'gray',
            'generating': 'blue',
            'pending_poll': 'orange',
            'polling': 'cyan',
            'downloading': 'yellow',
            'completed': 'green',
            'failed': 'red'
        }
        
        status_frame = ttk.Frame(card)
        status_frame.pack(fill=tk.X, pady=2)
        
        status_label = ttk.Label(status_frame, text=f"● {scene.status}", foreground=status_colors.get(scene.status, 'black'))
        status_label.pack(side=tk.LEFT)
        
        # Progress bar
        progress = ttk.Progressbar(card, mode='indeterminate', length=180)
        progress.pack(fill=tk.X, pady=2)
        
        if scene.status in ['generating', 'polling', 'downloading']:
            progress.start()
        
        # Buttons
        btn_frame = ttk.Frame(card)
        btn_frame.pack(fill=tk.X, pady=(5,0))
        
        # Individual Generate / Regenerate Button
        if scene.status == 'queued':
            ttk.Button(btn_frame, text="▶ Generate", command=lambda: self.run_single_generation(scene)).pack(side=tk.LEFT, padx=2)
        else:
            ttk.Button(btn_frame, text="🔄 Regenerate", command=lambda: self.run_single_generation(scene)).pack(side=tk.LEFT, padx=2)
        
        if scene.status == 'completed' and scene.video_path:
            ttk.Button(btn_frame, text="📁 Open", command=lambda: self.open_video(scene)).pack(side=tk.LEFT, padx=2)
        
        # Store references for updates
        card.status_label = status_label
        card.progress = progress
        card.btn_frame = btn_frame
        
        return card
    
    def update_scene_card(self, scene: SceneData):
        """Update a scene card's status"""
        if scene.scene_id not in self.scene_cards:
            return
        
        card = self.scene_cards[scene.scene_id]
        
        status_colors = {
            'queued': 'gray',
            'generating': 'blue',
            'pending_poll': 'orange',
            'polling': 'cyan',
            'downloading': 'yellow',
            'completed': 'green',
            'failed': 'red'
        }
        
        card.status_label.config(text=f"● {scene.status}", foreground=status_colors.get(scene.status, 'black'))
        
        if scene.status in ['generating', 'polling', 'downloading']:
            try:
                card.progress.start(10) # 10ms interval for smooth animation
            except:
                pass
        else:
            card.progress.stop()
            # Set to 100% if complete
            if scene.status == 'completed':
                card.progress['mode'] = 'determinate'
                card.progress['value'] = 100
                
        # Refresh buttons
        
        # Refresh buttons
        for widget in card.btn_frame.winfo_children():
            widget.destroy()
            
        if scene.status == 'queued':
            ttk.Button(card.btn_frame, text="▶ Generate", command=lambda: self.run_single_generation(scene)).pack(side=tk.LEFT, padx=2)
        else:
             ttk.Button(card.btn_frame, text="🔄 Regenerate", command=lambda: self.run_single_generation(scene)).pack(side=tk.LEFT, padx=2)
             
        if scene.status == 'failed':
            ttk.Button(card.btn_frame, text="🔄 Retry", command=lambda: self.retry_scene(scene)).pack(side=tk.LEFT, padx=2)
        
        if scene.status == 'completed' and scene.video_path:
            ttk.Button(card.btn_frame, text="📁 Open", command=lambda: self.open_video(scene)).pack(side=tk.LEFT, padx=2)
        
        self.update_stats()
    
    def save_scene_prompt(self, scene, text_widget):
        """Save prompt from text widget to scene data"""
        scene.prompt = text_widget.get("1.0", tk.END).strip()
        # print(f"Saved prompt for scene {scene.scene_id}")
    
    def pick_image_for_scene(self, scene, frame_type):
        """Pick an image for first or last frame"""
        file_path = filedialog.askopenfilename(
            title=f"Select {frame_type.title()} Frame Image",
            filetypes=[
                ("Image files", "*.jpg *.jpeg *.png *.webp"),
                ("JPEG files", "*.jpg *.jpeg"),
                ("PNG files", "*.png"),
                ("WebP files", "*.webp"),
                ("All files", "*.*")
            ]
        )
        
        if file_path:
            if frame_type == 'first':
                scene.first_frame_path = file_path
                scene.first_frame_media_id = None  # Will be uploaded during generation
            else:
                scene.last_frame_path = file_path
                scene.last_frame_media_id = None  # Will be uploaded during generation
            
            # Update UI
            if scene.scene_id in self.scene_cards:
                card = self.scene_cards[scene.scene_id]
                if frame_type == 'first' and hasattr(card, 'first_frame_label'):
                    card.first_frame_label.config(text=Path(file_path).name, foreground="green")
                elif frame_type == 'last' and hasattr(card, 'last_frame_label'):
                    card.last_frame_label.config(text=Path(file_path).name, foreground="green")
    
    def clear_image_for_scene(self, scene, frame_type):
        """Clear the selected image for first or last frame"""
        if frame_type == 'first':
            scene.first_frame_path = None
            scene.first_frame_media_id = None
        else:
            scene.last_frame_path = None
            scene.last_frame_media_id = None
        
        # Update UI
        if scene.scene_id in self.scene_cards:
            card = self.scene_cards[scene.scene_id]
            if frame_type == 'first' and hasattr(card, 'first_frame_label'):
                card.first_frame_label.config(text="None", foreground="gray")
            elif frame_type == 'last' and hasattr(card, 'last_frame_label'):
                card.last_frame_label.config(text="None", foreground="gray")


    def run_single_generation(self, scene):
        """Run generation for a single scene"""
        if self.is_running:
             messagebox.showwarning("Busy", "Please stop bulk generation first.")
             return
             
        # Trigger save manually just in case
        if scene.scene_id in self.scene_cards:
            card = self.scene_cards[scene.scene_id]
            if hasattr(card, 'prompt_text'):
                self.save_scene_prompt(scene, card.prompt_text)
        
        # Start thread
        t = threading.Thread(target=self._single_generation_worker, args=(scene,), daemon=True)
        t.start()

    def _single_generation_worker(self, scene):
        """Worker for single scene generation"""
        try:
            scene.status = 'generating'
            scene.error = None
            self.root.after(0, lambda: self.update_scene_card(scene))
            
            # 1. Connect/Get Token if needed
            print(f"[SINGLE] Connecting to Chrome...")
            if not self.generator:
                self.generator = BrowserVideoGenerator()
                try:
                    self.generator.connect()
                    print(f"[SINGLE] ✓ Connected to Chrome")
                except Exception as c_err:
                     print(f"[SINGLE] ✗ Connection failed: {c_err}")
                     raise c_err
            
            print(f"[SINGLE] Getting Access Token...")
            if not self.access_token:
                self.access_token = self.generator.get_access_token()
                if not self.access_token:
                     raise Exception("Failed to get access token")
                print(f"[SINGLE] ✓ Token acquired")

            # Restart Poller if dead (it dies if is_running was false previously)
            if not hasattr(self, 'polling_thread') or not self.polling_thread.is_alive():
                 print("[SINGLE] Restarting Polling Thread...")
                 self.pending_polls = queue.Queue() # Reset queue
                 self.polling_thread = threading.Thread(target=self.poll_worker, daemon=True)
                 self.polling_thread.start()

            # 1.5. Upload images if provided
            start_media_id = None
            end_media_id = None
            
            if scene.first_frame_path and not scene.first_frame_media_id:
                print(f"[SINGLE] Uploading first frame image...")
                result = self.generator.upload_image(
                    scene.first_frame_path, 
                    self.access_token
                )
                if result and isinstance(result, dict) and result.get('error'):
                    # Upload failed with error
                    error_msg = result.get('message', 'Upload failed')
                    print(f"[SINGLE] ✗ {error_msg}")
                    raise Exception(f"First frame upload failed: {error_msg}")
                elif result:
                    start_media_id = result
                    scene.first_frame_media_id = start_media_id
                    print(f"[SINGLE] ✓ First frame uploaded: {start_media_id}")
                else:
                    print(f"[SINGLE] ✗ Failed to upload first frame")
            elif scene.first_frame_media_id:
                start_media_id = scene.first_frame_media_id
                print(f"[SINGLE] Using cached first frame: {start_media_id}")
            
            if scene.last_frame_path and not scene.last_frame_media_id:
                print(f"[SINGLE] Uploading last frame image...")
                result = self.generator.upload_image(
                    scene.last_frame_path,
                    self.access_token
                )
                if result and isinstance(result, dict) and result.get('error'):
                    # Upload failed with error
                    error_msg = result.get('message', 'Upload failed')
                    print(f"[SINGLE] ✗ {error_msg}")
                    raise Exception(f"Last frame upload failed: {error_msg}")
                elif result:
                    end_media_id = result
                    scene.last_frame_media_id = end_media_id
                    print(f"[SINGLE] ✓ Last frame uploaded: {end_media_id}")
                else:
                    print(f"[SINGLE] ✗ Failed to upload last frame")
            elif scene.last_frame_media_id:
                end_media_id = scene.last_frame_media_id
                print(f"[SINGLE] Using cached last frame: {end_media_id}")

            # 2. Generate
            selected_model = self.model_var.get() if hasattr(self, 'model_var') else 'veo_3_1_t2v_fast_ultra'
            selected_ar = self.ar_var.get() if hasattr(self, 'ar_var') else 'VIDEO_ASPECT_RATIO_LANDSCAPE'
            
            mode = "I2V" if (start_media_id or end_media_id) else "T2V"
            print(f"[SINGLE] Generating Scene {scene.scene_id} ({mode}) with model {selected_model} ({selected_ar})...")
            
            result = self.generator.generate_video(
                prompt=scene.prompt,
                access_token=self.access_token,
                model=selected_model,
                aspect_ratio=selected_ar,
                start_image_media_id=start_media_id,
                end_image_media_id=end_media_id
            )
            
            # Check for 403 errors (reCAPTCHA failures)
            if result and result.get('status') == 403:
                self.consecutive_403_errors += 1
                print(f"[403 ERROR] Consecutive count: {self.consecutive_403_errors}/{self.max_403_before_relogin}")
                
                if self.consecutive_403_errors >= self.max_403_before_relogin:
                    print("[AUTO-RELOGIN] Triggering auto-relogin due to repeated 403 errors...")
                    self.root.after(0, self.trigger_auto_relogin)
                    scene.status = 'failed'
                    scene.error = f"403 Error - Auto-relogin triggered ({self.consecutive_403_errors} consecutive failures)"
                    self.root.after(0, lambda: self.update_scene_card(scene))
                    return
                else:
                    # Mark as failed but will retry
                    raise Exception(f"403 Forbidden - reCAPTCHA failure ({self.consecutive_403_errors}/{self.max_403_before_relogin})")
            
            if result and result.get('success'):
                # Reset 403 counter on success
                self.consecutive_403_errors = 0
                
                data = result.get('data', {})
                if 'operations' in data and len(data['operations']) > 0:
                     op = data['operations'][0]
                     scene.operation_name = op.get('operation', {}).get('name')
                     scene_uuid = result.get('sceneId')
                     
                     scene.status = 'polling'
                     
                     # Ensure pending_polls queue is initialized for single generation
                     if not hasattr(self, 'pending_polls') or self.pending_polls is None:
                         self.pending_polls = queue.Queue()
                         self.generation_complete = False # Ensure poller doesn't stop prematurely
                         # Start polling thread if not already running
                         polling_thread = threading.Thread(target=self.poll_worker, daemon=True)
                         polling_thread.start()
                     
                     self.pending_polls.put((scene, scene_uuid))
                     self.active_generations_count += 1
                     
                     print(f"[SINGLE] Scene {scene.scene_id} submitted. Polling...")
                else:
                    raise Exception("No operation data received")
            else:
                error = result.get('error', 'Unknown error') if result else "No response"
                raise Exception(error)
                
            self.root.after(0, lambda: self.update_scene_card(scene))
            
        except Exception as e:
            scene.status = 'failed'
            scene.error = str(e)
            print(f"[SINGLE] Error: {e}")
            self.root.after(0, lambda: self.update_scene_card(scene))
            messagebox.showerror("Generation Error", f"Failed to generate scene {scene.scene_id}:\n{e}")
        
        self.update_stats()
    
    def update_stats(self):
        """Update statistics display"""
        total = len(self.scenes)
        completed = sum(1 for s in self.scenes if s.status == 'completed')
        failed = sum(1 for s in self.scenes if s.status == 'failed')
        pending = sum(1 for s in self.scenes if s.status == 'queued')
        active = sum(1 for s in self.scenes if s.status in ['generating', 'polling', 'downloading'])
        
        self.stats_label.config(
            text=f"Total: {total} | ✓ {completed} | ⚙️ {active} | ✗ {failed} | 🕐 {pending}"
        )
    
    def start_generation(self):
        """Start bulk generation"""
        if not self.scenes:
            messagebox.showwarning("No Scenes", "Please load scenes first")
            return
        
        self.is_running = True
        self.is_paused = False
        self.start_btn.config(state='disabled')
        self.pause_btn.config(state='normal')
        self.stop_btn.config(state='normal')
        
        # Start generation thread
        thread = threading.Thread(target=self.generation_worker, daemon=True)
        thread.start()
        
        # Start auto-save
        self.schedule_auto_save()
    
    def pause_generation(self):
        """Pause generation"""
        self.is_paused = not self.is_paused
        self.pause_btn.config(text="▶ Resume" if self.is_paused else "⏸ Pause")
    
    def stop_generation(self):
        """Stop generation"""
        self.is_running = False
        self.start_btn.config(state='normal')
        self.pause_btn.config(state='disabled')
        self.stop_btn.config(state='disabled')
    
    def retry_failed(self):
        """Retry all failed scenes"""
        for scene in self.scenes:
            if scene.status == 'failed':
                scene.status = 'queued'
                scene.error = None
                scene.retry_count = 0
                self.update_scene_card(scene)
    
    def retry_scene(self, scene: SceneData):
        """Retry a single scene"""
        scene.status = 'queued'
        scene.error = None
        self.update_scene_card(scene)
    
    def open_video(self, scene: SceneData):
        """Open video file"""
        if scene.video_path and Path(scene.video_path).exists():
            import subprocess
            subprocess.run(['explorer', '/select,', scene.video_path])
    
    def start_polling(self):
        """Start polling for pending operations from saved file"""
        pending_file = Path(self.output_folder) / "pending_operations.json"
        
        if not pending_file.exists():
            messagebox.showwarning("No Pending Operations", 
                                 "No pending_operations.json found in output folder.\n\n"
                                 "Generate some videos first!")
            return
        
        try:
            # Load pending operations
            with open(pending_file, 'r', encoding='utf-8') as f:
                pending_ops = json.load(f)
            
            if not pending_ops:
                messagebox.showinfo("No Pending", "No pending operations to poll!")
                return
            
            # Ask user to confirm
            if not messagebox.askyesno("Start Polling", 
                                      f"Found {len(pending_ops)} pending operations.\n\n"
                                      f"Start polling and downloading?"):
                return
            
            # Setup generator for polling
            print("\n[POLL] Connecting to Chrome for polling...")
            if not self.generator:
                self.generator = BrowserVideoGenerator()
                self.generator.connect()
            
            if not self.access_token:
                self.access_token = self.generator.get_access_token()
                if not self.access_token:
                    messagebox.showerror("Error", "Failed to get access token from browser")
                    return
            
            # Initialize polling queue
            self.pending_polls = queue.Queue()
            self.active_generations_count = 0
            
            # Load operations into queue and update scene statuses
            loaded_count = 0
            for op_data in pending_ops:
                scene_id = op_data.get('scene_id')
                operation_name = op_data.get('operation')
                scene_uuid = op_data.get('uuid')
                
                # Find or create scene
                scene = None
                for s in self.scenes:
                    if s.scene_id == scene_id:
                        scene = s
                        break
                
                if not scene:
                    # Create new scene from saved data
                    scene = SceneData(scene_id, op_data.get('prompt', ''))
                    self.scenes.append(scene)
                
                # Update scene data
                scene.operation_name = operation_name
                scene.status = 'polling'
                scene.first_frame_media_id = op_data.get('first_frame_media_id')
                scene.last_frame_media_id = op_data.get('last_frame_media_id')
                
                # Add to polling queue
                self.pending_polls.put((scene, scene_uuid))
                self.active_generations_count += 1
                loaded_count += 1
                
                # Update UI if card exists
                if scene.scene_id in self.scene_cards:
                    self.update_scene_card(scene)
            
            print(f"[POLL] Loaded {loaded_count} operations into polling queue")
            
            # Refresh UI if needed
            if loaded_count > len(self.scene_cards):
                self.render_scene_cards()
            
            self.update_stats()
            
            # Start polling thread
            if not hasattr(self, 'polling_thread') or not self.polling_thread.is_alive():
                print("[POLL] Starting polling thread...")
                self.polling_thread = threading.Thread(target=self.poll_worker, daemon=True)
                self.polling_thread.start()
            
            messagebox.showinfo("Polling Started", 
                              f"Polling {loaded_count} videos.\n\n"
                              f"Check console for progress.")
            
        except Exception as e:
            messagebox.showerror("Error", f"Failed to start polling:\n{e}")
            import traceback
            traceback.print_exc()

    
    def generation_worker(self):
        """Worker that manages concurrent generation (4 at a time) with unified polling"""
        try:
            print("\n" + "="*60)
            print("BULK VIDEO GENERATOR - CONCURRENT MODE (4 simultaneous)")
            print("="*60)
            
            # Check if multi-browser mode is active with connections
            if self.multi_browser_mode and self.browser_connections:
                # Use existing browser connections - NO need to reconnect!
                print(f"\n[MULTI-BROWSER] Using {len(self.browser_connections)} existing browser connections")
                for i, browser in enumerate(self.browser_connections):
                    print(f"  Browser {i+1}: port {browser['port']}, token: {browser['access_token'][:30]}...")
                
                # Use first browser's generator as default (for polling)
                self.generator = self.browser_connections[0]['generator']
                self.access_token = self.browser_connections[0]['access_token']
            else:
                # Single browser mode - connect to browser
                print("\n[CONNECT] Connecting to Chrome DevTools...")
                self.generator = BrowserVideoGenerator()
                self.generator.connect()
                print("[CONNECT] ✓ Connected successfully")
                
                # Get access token
                print("\n[AUTH] Fetching access token from browser session...")
                self.access_token = self.generator.get_access_token()
                if not self.access_token:
                    print("[AUTH] ✗ Failed to get access token")
                    messagebox.showerror("Error", "Failed to get access token")
                    return
                print(f"[AUTH] ✓ Token: {self.access_token[:50]}...")
            
            # Get range
            from_idx = int(self.from_spinbox.get()) - 1
            to_idx = int(self.to_spinbox.get())
            scenes_to_process = [s for s in self.scenes[from_idx:min(to_idx, len(self.scenes))] if s.status == 'queued']
            
            print(f"\n[QUEUE] Processing {len(scenes_to_process)} scenes")
            print(f"[QUEUE] Concurrent limit: 4 videos at a time")
            print(f"[QUEUE] Poll interval: 5 seconds")
            
            if self.multi_browser_mode and self.browser_connections:
                print(f"[QUEUE] Multi-browser: Round-robin across {len(self.browser_connections)} browsers")
            
            # Shared state
            self.active_videos = {}  # {scene_id: (scene, operation_name, scene_uuid)}
            self.queue_to_generate = list(scenes_to_process)  # Remaining scenes to generate
            self.generation_complete = False
            
            # Start concurrent generation and polling
            self.run_concurrent_generation()
            
            print("\n" + "="*60)
            print("GENERATION & POLLING COMPLETE")
            print("="*60)
            
        except Exception as e:
            print(f"\n[ERROR] Fatal error: {e}")
            import traceback
            traceback.print_exc()
            messagebox.showerror("Error", f"Generation error: {e}")
        finally:
            # In multi-browser mode, don't close the shared generator
            if not self.multi_browser_mode and self.generator:
                self.generator.close()
            self.root.after(0, self.stop_generation)
    
    def run_concurrent_generation(self):
        """Main loop: Generate up to 4 videos concurrently, poll every 5s, queue next when one completes"""
        poll_interval = 5  # seconds
        
        selected_model = self.model_var.get() if hasattr(self, 'model_var') else 'veo_3_1_t2v_fast_ultra'
        selected_ar = self.ar_var.get() if hasattr(self, 'ar_var') else 'VIDEO_ASPECT_RATIO_LANDSCAPE'
        
        # Set max concurrent based on model - relaxed models have stricter limits
        if 'relaxed' in selected_model.lower():
            max_concurrent = 4  # Relaxed model - max 4 concurrent
            print(f"\n[CONCURRENT] Relaxed model detected - Limiting to {max_concurrent} concurrent")
        else:
            max_concurrent = 4  # Fast model - can also use 4 (or increase if needed)
        
        print(f"[CONCURRENT] Starting with max {max_concurrent} simultaneous generations")
        print(f"[CONCURRENT] Model: {selected_model}, Aspect Ratio: {selected_ar}")
        
        # Flag to temporarily stop new generations (e.g., during relogin)
        stop_new_generations = False
        no_browser_logged = False  # Prevent log spam
        
        while True:
            # Check if we should stop completely
            if not self.is_running:
                print("[CONCURRENT] Generation stopped by user")
                break
            
            # Check if we should pause
            if self.is_paused:
                if not hasattr(self, '_pause_logged') or not self._pause_logged:
                    print("[CONCURRENT] Generation paused - Waiting for resume...")
                    self._pause_logged = True
                time.sleep(2)
                continue
            else:
                # Reset pause log flag when unpaused
                self._pause_logged = False
            
            # Check if any browser is connected (multi-browser mode only)
            if self.multi_browser_mode and not self.has_any_connected_browser():
                if not no_browser_logged:
                    connected = self.count_connected_browsers()
                    relogging = sum(1 for b in self.browser_connections if b['status'] == 'relogging')
                    print(f"\n[PAUSE] No browsers available - {relogging} relogging, {connected} connected")
                    print("[PAUSE] Waiting for at least one browser to reconnect...")
                    no_browser_logged = True
                time.sleep(3)
                continue
            else:
                if no_browser_logged:
                    connected = self.count_connected_browsers()
                    print(f"[RESUME] Browser available! {connected} browsers connected - resuming")
                    no_browser_logged = False
            
            # 1. Fill up to max_concurrent active generations (unless stopped due to 403)
            if not stop_new_generations:
                while len(self.active_videos) < max_concurrent and self.queue_to_generate:
                    scene = self.queue_to_generate.pop(0)
                    
                    # Start generation for this scene
                    success = self.start_single_generation(scene, selected_model, selected_ar)
                    
                    if not success:
                        # Check if 403 error threshold reached
                        if self.consecutive_403_errors >= self.max_403_before_relogin:
                            print("[CONCURRENT] 403 threshold reached - Stopping NEW generations")
                            print("[CONCURRENT] Active videos will continue polling and downloading")
                            stop_new_generations = True
                            break  # Stop starting new generations
                    
                    # Small delay between starting generations
                    time.sleep(0.5)
            
            # 2. If no active videos and queue is empty, check if we should wait or exit
            if not self.active_videos and not self.queue_to_generate:
                # If stop_new_generations is True, we're waiting for relogin - don't exit!
                if stop_new_generations:
                    print("[CONCURRENT] Waiting for relogin to complete...")
                    time.sleep(2)
                    continue
                else:
                    print("[CONCURRENT] All videos completed!")
                    break
            
            # 3. Poll all active videos (only if we have connected browsers)
            if self.active_videos:
                if self.multi_browser_mode and not self.has_any_connected_browser():
                    print(f"[POLL] Skipping poll - no browsers connected")
                else:
                    try:
                        print(f"\n[POLL] Checking {len(self.active_videos)} active videos...")
                        self.poll_and_update_active_videos()
                    except Exception as e:
                        print(f"[POLL] Error (will retry next cycle): {e}")
            
            
            # 4. Check if we can resume new generations after relogin
            if stop_new_generations and self.consecutive_403_errors == 0:
                print("[CONCURRENT] 403 counter reset - Resuming new generations")
                stop_new_generations = False
            
            # 5. Wait before next poll cycle
            if self.active_videos or self.queue_to_generate or stop_new_generations:
                time.sleep(poll_interval)
        
        self.generation_complete = True
        print("[CONCURRENT] Generation worker finished")
    
    def start_single_generation(self, scene, selected_model, selected_ar):
        """Start generation for a single scene and add to active_videos"""
        try:
            scene.status = 'generating'
            self.root.after(0, lambda s=scene: self.update_scene_card(s))
            
            # Track retries
            scene_id = scene.scene_id
            if scene_id not in self.video_retry_counts:
                self.video_retry_counts[scene_id] = 0
            
            # Check if max retries exceeded
            if self.video_retry_counts[scene_id] >= 3:
                scene.status = 'failed'
                scene.error = "Max retries (3) exceeded"
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                print(f"[GENERATE] Scene {scene_id}: Max retries exceeded - skipping")
                return False
            
            # Multi-browser mode: use round-robin
            if self.multi_browser_mode and self.browser_connections:
                result_data = self.get_next_browser()
                if result_data is None:
                    # No browser available - put scene BACK to front of queue
                    self.queue_to_generate.insert(0, scene)
                    scene.status = 'queued'
                    print(f"[GENERATE] Scene {scene_id}: No browsers available - back to queue")
                    return False
                
                browser_idx, browser = result_data
                generator = browser['generator']
                access_token = browser['access_token']
                print(f"\n[GENERATE] Scene {scene_id} on Browser {browser_idx+1}: {scene.prompt[:50]}...")
            else:
                # Single browser mode
                generator = self.generator
                access_token = self.access_token
                browser_idx = 0
                print(f"\n[GENERATE] Scene {scene_id}: {scene.prompt[:50]}...")
            
            # Upload images if needed
            start_media_id = scene.first_frame_media_id
            end_media_id = scene.last_frame_media_id
            
            # Generate video
            result = generator.generate_video(
                prompt=scene.prompt,
                access_token=access_token,
                model=selected_model,
                aspect_ratio=selected_ar,
                start_image_media_id=start_media_id,
                end_image_media_id=end_media_id
            )
            
            # Check for 403 errors
            if result and result.get('status') == 403:
                self.video_retry_counts[scene_id] = self.video_retry_counts.get(scene_id, 0) + 1
                
                if self.multi_browser_mode and self.browser_connections:
                    # Multi-browser: track per-browser 403 count
                    browser = self.browser_connections[browser_idx]
                    browser['403_count'] = browser.get('403_count', 0) + 1
                    print(f"[403 ERROR] Browser {browser_idx+1}: 403 count = {browser['403_count']}/3")
                    
                    # Check if this browser needs relogin
                    if browser['403_count'] >= 3:
                        print(f"[403 ERROR] Browser {browser_idx+1}: Triggering relogin...")
                        self.relogin_single_browser(browser_idx)
                    
                    # Mark scene for retry and add back to FRONT of queue
                    scene.status = 'queued'
                    self.queue_to_generate.insert(0, scene)  # Add to FRONT for immediate retry
                    self.root.after(0, lambda s=scene: self.update_scene_card(s))
                    print(f"[403 ERROR] Scene {scene_id}: Re-queued at front for retry ({self.video_retry_counts[scene_id]}/3)")
                    return False
                else:
                    # Single browser mode
                    self.consecutive_403_errors += 1
                    print(f"[403 ERROR] Consecutive count: {self.consecutive_403_errors}/{self.max_403_before_relogin}")
                    
                    if self.consecutive_403_errors >= self.max_403_before_relogin:
                        print("[AUTO-RELOGIN] Triggering auto-relogin...")
                        scene.status = 'failed'
                        scene.error = f"403 Error - Auto-relogin triggered"
                        self.root.after(0, lambda s=scene: self.update_scene_card(s))
                        self.root.after(0, self.trigger_auto_relogin)
                        return False
                    else:
                        scene.status = 'failed'
                        scene.error = f"403 Forbidden ({self.consecutive_403_errors}/{self.max_403_before_relogin})"
                        self.root.after(0, lambda s=scene: self.update_scene_card(s))
                        return False
            
            if result and result.get('success'):
                # Reset 403 counter
                self.consecutive_403_errors = 0
                
                # Reset browser 403 count in multi-browser mode
                if self.multi_browser_mode and self.browser_connections and browser_idx < len(self.browser_connections):
                    self.browser_connections[browser_idx]['403_count'] = 0
                
                data = result.get('data', {})
                if 'operations' in data and len(data['operations']) > 0:
                    op = data['operations'][0]
                    operation_name = op.get('operation', {}).get('name')
                    scene_uuid = result.get('sceneId')
                    
                    scene.operation_name = operation_name
                    scene.status = 'polling'
                    self.root.after(0, lambda s=scene: self.update_scene_card(s))
                    
                    # Add to active videos
                    self.active_videos[scene.scene_id] = (scene, operation_name, scene_uuid)
                    
                    print(f"[GENERATE] ✓ Scene {scene.scene_id} submitted (Active: {len(self.active_videos)})")
                    return True
                else:
                    scene.status = 'failed'
                    scene.error = "No operation data"
                    self.root.after(0, lambda s=scene: self.update_scene_card(s))
                    return False
            else:
                error = result.get('error', 'Unknown error') if result else "No response"
                scene.status = 'failed'
                scene.error = error
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                return False
                
        except Exception as e:
            scene.status = 'failed'
            scene.error = str(e)
            self.root.after(0, lambda s=scene: self.update_scene_card(s))
            print(f"[GENERATE] Error: {e}")
            return False
    
    def poll_and_update_active_videos(self):
        """Poll all active videos in a single batch request and update their status"""
        if not self.active_videos:
            return
        
        # In multi-browser mode, use a connected browser's generator for polling
        if self.multi_browser_mode and self.browser_connections:
            # Find any connected browser for polling
            poll_generator = None
            poll_token = None
            for browser in self.browser_connections:
                if browser['status'] == 'connected' and browser.get('generator'):
                    poll_generator = browser['generator']
                    poll_token = browser['access_token']
                    break
            
            if not poll_generator:
                print("[POLL] No connected browser - skipping poll")
                return
        else:
            poll_generator = self.generator
            poll_token = self.access_token
        
        # Build batch poll request
        operations_list = [
            (operation_name, scene_uuid)
            for scene_id, (scene, operation_name, scene_uuid) in self.active_videos.items()
        ]
        
        # Batch poll with error handling
        try:
            results = poll_generator.poll_video_status_batch(operations_list, poll_token)
        except Exception as e:
            error_msg = str(e)
            if 'socket is already closed' in error_msg or 'WebSocket' in error_msg:
                print(f"[POLL] WebSocket closed (browser relogging?) - skipping poll")
            else:
                print(f"[POLL] Error during poll: {e}")
            return
        
        if not results:
            print("[POLL] No results from batch poll")
            return
        
        # Process results
        completed_scene_ids = []
        
        for i, (scene_id, (scene, operation_name, scene_uuid)) in enumerate(self.active_videos.items()):
            if i >= len(results):
                break
            
            operation_data = results[i]
            status = operation_data.get('status', 'UNKNOWN')
            
            if status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' or status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL':
                # Extract video URL from nested structure
                # Path: operation_data['operation']['metadata']['video']['fifeUrl']
                try:
                    video_url = operation_data.get('operation', {}).get('metadata', {}).get('video', {}).get('fifeUrl')
                    
                    if video_url:
                        print(f"[POLL] ✓ Scene {scene.scene_id} completed!")
                        scene.download_url = video_url
                        scene.status = 'downloading'
                        self.root.after(0, lambda s=scene: self.update_scene_card(s))
                        
                        # Download in background
                        def download_task(sc, url):
                            try:
                                output_path = Path(self.output_folder) / f"scene_{sc.scene_id}.mp4"
                                self.generator.download_video(url, str(output_path))
                                sc.video_path = str(output_path)
                                sc.status = 'completed'
                                sc.file_size = output_path.stat().st_size
                                self.root.after(0, lambda: self.update_scene_card(sc))
                                print(f"[DOWNLOAD] ✓ Scene {sc.scene_id} downloaded")
                            except Exception as e:
                                sc.status = 'failed'
                                sc.error = f"Download failed: {e}"
                                self.root.after(0, lambda: self.update_scene_card(sc))
                        
                        threading.Thread(target=download_task, args=(scene, video_url), daemon=True).start()
                        completed_scene_ids.append(scene_id)
                    else:
                        print(f"[POLL] ✗ Scene {scene.scene_id}: No fifeUrl found in response")
                        scene.status = 'failed'
                        scene.error = "No video URL in response"
                        self.root.after(0, lambda s=scene: self.update_scene_card(s))
                        completed_scene_ids.append(scene_id)
                except Exception as e:
                    print(f"[POLL] ✗ Scene {scene.scene_id}: Error extracting video URL: {e}")
                    scene.status = 'failed'
                    scene.error = f"URL extraction error: {e}"
                    self.root.after(0, lambda s=scene: self.update_scene_card(s))
                    completed_scene_ids.append(scene_id)
            
            elif status == 'MEDIA_GENERATION_STATUS_FAILED':
                error_msg = operation_data.get('operation', {}).get('metadata', {}).get('error', {}).get('message', 'Generation failed')
                scene.status = 'failed'
                scene.error = error_msg
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                print(f"[POLL] ✗ Scene {scene.scene_id} failed: {error_msg}")
                completed_scene_ids.append(scene_id)
        
        # Remove completed videos from active list
        for scene_id in completed_scene_ids:
            del self.active_videos[scene_id]
            print(f"[POLL] Removed scene {scene_id} from active list (Remaining: {len(self.active_videos)})")
        
        self.root.after(0, self.update_stats)

    def process_generation_queue(self, scenes):
        """Producer: Generates videos and adds them to polling queue"""
        print("\n" + "="*60)
        print("THREAD 1: GENERATION PRODUCER STARTED")
        print("="*60)
        
        ops_file = Path(self.output_folder) / "active_operations.jsonl"
        
        # Get selected model
        selected_model = self.model_var.get() if hasattr(self, 'model_var') else 'veo_3_1_t2v_fast_ultra'
        selected_ar = self.ar_var.get() if hasattr(self, 'ar_var') else 'VIDEO_ASPECT_RATIO_LANDSCAPE'
        print(f"[CONFIG] Using model: {selected_model}")
        print(f"[CONFIG] Using Aspect Ratio: {selected_ar}")
        
        for i, scene in enumerate(scenes):
            if not self.is_running:
                print("\n[STOP] Generation stopped by user")
                break
            
            while self.is_paused:
                time.sleep(0.5)
            
            try:
                # Concurrency limit for Relaxed/Free model
                if selected_model == 'veo_3_1_t2v_fast_ultra_relaxed':
                    while self.is_running:
                        # Calculate total active operations (queue + processing in consumer)
                        # We need a thread-safe way to know consumer's load. 
                        # Ideally, share a counter, but approximating with queue size + heuristic
                        # Better approach: Make 'active_list' shared or expose a property
                        
                        # Since active_list is local to consumer, let's use a shared counter
                        current_active = self.active_generations_count
                        
                        if current_active < 4:
                            break
                        
                        print(f"\r[LIMIT] Waiting for slots (Active: {current_active}/4)...", end="")
                        time.sleep(1)

                # Anti-detection: Random delay with jitter (2-5 seconds)
                if i > 0:
                    base_delay = 1.0 / self.rate_limit
                    jitter = random.uniform(2.0, 5.0)  # Random 2-5 second pause
                    total_delay = base_delay + jitter
                    print(f"\n[ANTI-BOT] Waiting {total_delay:.1f}s (base: {base_delay:.1f}s + jitter: {jitter:.1f}s)")
                    time.sleep(total_delay)
                
                # Refresh session every 8-12 videos to avoid stale tokens
                if i > 0 and i % random.randint(8, 12) == 0:
                    print(f"[ANTI-BOT] Refreshing auth token (every ~10 videos)...")
                    new_token = self.generator.get_access_token()
                    if new_token:
                        self.access_token = new_token
                        print(f"[ANTI-BOT] ✓ Token refreshed")
                    else:
                        print(f"[ANTI-BOT] ⚠ Token refresh failed, continuing with old token")
                
                # Generate with Retry Logic for 429 (Rate Limit)
                max_retries = 10
                retry_count = 0
                
                while retry_count < max_retries:
                    scene.status = 'generating'
                    self.root.after(0, lambda s=scene: self.update_scene_card(s))
                    
                    print(f"\n[GENERATE {i+1}/{len(scenes)}] Scene {scene.scene_id} (Attempt {retry_count+1})")
                    
                    # Upload images if provided
                    start_media_id = None
                    end_media_id = None
                    
                    if scene.first_frame_path and not scene.first_frame_media_id:
                        print(f"[GENERATE] Uploading first frame image...")
                        result = self.generator.upload_image(
                            scene.first_frame_path,
                            self.access_token
                        )
                        if result and isinstance(result, dict) and result.get('error'):
                            # Upload failed with error
                            error_msg = result.get('message', 'Upload failed')
                            print(f"[GENERATE] ✗ {error_msg}")
                            scene.status = 'failed'
                            scene.error = f"Image upload failed: {error_msg}"
                            self.root.after(0, lambda s=scene: self.update_scene_card(s))
                            continue  # Skip to next scene
                        elif result:
                            start_media_id = result
                            scene.first_frame_media_id = start_media_id
                            print(f"[GENERATE] ✓ First frame uploaded: {start_media_id}")
                        else:
                            print(f"[GENERATE] ✗ Failed to upload first frame")
                    elif scene.first_frame_media_id:
                        start_media_id = scene.first_frame_media_id
                        print(f"[GENERATE] Using cached first frame: {start_media_id}")
                    
                    if scene.last_frame_path and not scene.last_frame_media_id:
                        print(f"[GENERATE] Uploading last frame image...")
                        result = self.generator.upload_image(
                            scene.last_frame_path,
                            self.access_token
                        )
                        if result and isinstance(result, dict) and result.get('error'):
                            # Upload failed with error
                            error_msg = result.get('message', 'Upload failed')
                            print(f"[GENERATE] ✗ {error_msg}")
                            scene.status = 'failed'
                            scene.error = f"Image upload failed: {error_msg}"
                            self.root.after(0, lambda s=scene: self.update_scene_card(s))
                            continue  # Skip to next scene
                        elif result:
                            end_media_id = result
                            scene.last_frame_media_id = end_media_id
                            print(f"[GENERATE] ✓ Last frame uploaded: {end_media_id}")
                        else:
                            print(f"[GENERATE] ✗ Failed to upload last frame")
                    elif scene.last_frame_media_id:
                        end_media_id = scene.last_frame_media_id
                        print(f"[GENERATE] Using cached last frame: {end_media_id}")
                    
                    mode = "I2V" if (start_media_id or end_media_id) else "T2V"
                    print(f"[GENERATE] Sending {mode} request to API (Model: {selected_model})...")
                    
                    result = self.generator.generate_video(
                        prompt=scene.prompt,
                        access_token=self.access_token,
                        model=selected_model,
                        aspect_ratio=selected_ar,
                        start_image_media_id=start_media_id,
                        end_image_media_id=end_media_id
                    )
                    
                    # Check for 403 errors (reCAPTCHA failures) - BULK GENERATION
                    if result and result.get('status') == 403:
                        self.consecutive_403_errors += 1
                        print(f"[403 ERROR - BULK] Consecutive count: {self.consecutive_403_errors}/{self.max_403_before_relogin}")
                        
                        if self.consecutive_403_errors >= self.max_403_before_relogin:
                            print("[AUTO-RELOGIN - BULK] Stopping bulk generation due to repeated 403 errors...")
                            # Mark current scene as failed
                            scene.status = 'failed'
                            scene.error = f"403 Error - Auto-relogin triggered ({self.consecutive_403_errors} consecutive failures)"
                            self.root.after(0, lambda s=scene: self.update_scene_card(s))
                            
                            # Trigger auto-relogin (this will pause generation)
                            self.root.after(0, self.trigger_auto_relogin)
                            
                            # Stop the bulk generation loop
                            print("[AUTO-RELOGIN - BULK] Bulk generation stopped. Waiting for relogin...")
                            return  # Exit the generation worker
                        else:
                            # Mark as failed but continue with next scene
                            scene.status = 'failed'
                            scene.error = f"403 Forbidden - reCAPTCHA failure ({self.consecutive_403_errors}/{self.max_403_before_relogin})"
                            self.root.after(0, lambda s=scene: self.update_scene_card(s))
                            retry_count += 1
                            continue
                    
                    if result and result.get('success'):
                        # Reset 403 counter on success
                        self.consecutive_403_errors = 0
                        
                        # ... success handling (same as before) ...
                        data = result.get('data', {})
                        print(f"[GENERATE] ✓ Response received (status {result.get('status')})")
                        
                        if 'operations' in data and len(data['operations']) > 0:
                            op = data['operations'][0]
                            scene.operation_name = op.get('operation', {}).get('name')
                            scene_uuid = result.get('sceneId')
                            
                            # Mark as pending (not polling - will poll manually later)
                            scene.status = 'pending_poll'
                            
                            # Save to pending operations file (JSON format for easy loading)
                            pending_file = Path(self.output_folder) / "pending_operations.json"
                            try:
                                # Load existing operations
                                pending_ops = []
                                if pending_file.exists():
                                    with open(pending_file, 'r', encoding='utf-8') as f:
                                        pending_ops = json.load(f)
                                
                                # Add new operation
                                op_data = {
                                    'timestamp': datetime.now().isoformat(),
                                    'scene_id': scene.scene_id,
                                    'operation': scene.operation_name,
                                    'uuid': scene_uuid,
                                    'prompt': scene.prompt,
                                    'model': selected_model,
                                    'aspect_ratio': selected_ar,
                                    'first_frame_media_id': scene.first_frame_media_id,
                                    'last_frame_media_id': scene.last_frame_media_id
                                }
                                pending_ops.append(op_data)
                                
                                # Save back to file
                                with open(pending_file, 'w', encoding='utf-8') as f:
                                    json.dump(pending_ops, f, indent=2, ensure_ascii=False)
                                    
                                print(f"[GENERATE] ✓ Operation: {scene.operation_name}")
                                print(f"[GENERATE] ✓ Saved to pending_operations.json (Total pending: {len(pending_ops)})")
                            except Exception as file_e:
                                print(f"[FILE] ✗ Failed to save operation: {file_e}")
                                scene.status = 'failed'
                                scene.error = f"Failed to save operation: {file_e}"
                                break
                                
                            break # Success! Exit retry loop
                        else:
                            scene.status = 'failed'
                            scene.error = "No operation data"
                            print(f"[GENERATE] ✗ No operation data")
                            break # Fail, don't retry typical formatting errors
                    else:
                        # Check for 429 Rate Limit
                        status_code = result.get('status') if result else 0
                        is_429 = status_code == 429
                        
                        # Also check error body text just in case
                        if not is_429 and result and 'RESOURCE_EXHAUSTED' in str(result):
                            is_429 = True
                            
                        if is_429:
                            wait_time = 45 # seconds
                            print(f"[RATE LIMIT] 🛑 Hit 429 Quota Limit. Waiting {wait_time}s before retry...")
                            scene.status = 'queued' # Reset status visual
                            self.root.after(0, lambda s=scene: self.update_scene_card(s))
                            time.sleep(wait_time)
                            retry_count += 1
                            continue # Retry
                        
                        # Fatal error
                        scene.status = 'failed'
                        scene.error = result.get('error', 'Unknown error') if result else 'No response'
                        print(f"[GENERATE] ✗ Failed: {scene.error}")
                        if result:
                             print(f"[DEBUG] Full Response: {json.dumps(result, indent=2)}")
                        break # Exit retry loop
                
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                
            except Exception as e:
                scene.status = 'failed'
                scene.error = str(e)
                print(f"[GENERATE] ✗ Exception: {e}")
                self.root.after(0, lambda s=scene: self.update_scene_card(s))

    def poll_worker(self):
        """Consumer: Polls active operations and downloads completed videos in parallel
        
        Uses batch API calls to check all active videos at once, with random 5-10s intervals.
        """
        print("\n" + "="*60)
        print("THREAD 2: POLLING CONSUMER STARTED (Batch Mode + Parallel Downloads)")
        print("="*60)
        
        active_list = []  # List of (scene, uuid) tuples to poll
        
        # Thread pool for parallel downloads
        from concurrent.futures import ThreadPoolExecutor
        download_executor = ThreadPoolExecutor(max_workers=5)
        
        def download_task(scene, video_url):
            """Task to download video in background thread"""
            try:
                scene.status = 'downloading'
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                
                print(f"[DOWNLOAD] Scene {scene.scene_id} STARTED")
                
                output_path = Path(self.output_folder) / f"scene_{scene.scene_id:03d}.mp4"
                output_path.parent.mkdir(parents=True, exist_ok=True)
                
                # Use a new generator instance for download to avoid lock contention
                temp_gen = BrowserVideoGenerator() 
                file_size = temp_gen.download_video(video_url, str(output_path))
                
                scene.video_path = str(output_path)
                scene.download_url = video_url
                scene.file_size = file_size
                scene.generated_at = datetime.now().isoformat()
                scene.status = 'completed'
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                
                print(f"[DOWNLOAD] ✓ Scene {scene.scene_id} Complete ({file_size/1024/1024:.1f} MB)")
                self.active_generations_count -= 1
                
                # Remove from pending operations file
                self.remove_from_pending(scene.scene_id)
                
            except Exception as e:
                scene.status = 'failed'
                scene.error = f"Download failed: {e}"
                print(f"[DOWNLOAD] ✗ Scene {scene.scene_id} Failed: {e}")
                self.active_generations_count -= 1
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                
                # Also remove failed downloads from pending
                self.remove_from_pending(scene.scene_id)
    
    def remove_from_pending(self, scene_id):
        """Remove a scene from pending_operations.json after completion/failure"""
        try:
            pending_file = Path(self.output_folder) / "pending_operations.json"
            if not pending_file.exists():
                return
            
            with open(pending_file, 'r', encoding='utf-8') as f:
                pending_ops = json.load(f)
            
            # Filter out the completed scene
            updated_ops = [op for op in pending_ops if op.get('scene_id') != scene_id]
            
            # Save back
            with open(pending_file, 'w', encoding='utf-8') as f:
                json.dump(updated_ops, f, indent=2, ensure_ascii=False)
            
            print(f"[CLEANUP] Removed scene {scene_id} from pending operations ({len(updated_ops)} remaining)")
        except Exception as e:
            print(f"[CLEANUP] Warning: Failed to remove scene {scene_id} from pending: {e}")


    def poll_worker(self):
        """Consumer: Polls active operations and downloads completed videos in parallel
        
        Uses batch API calls to check all active videos at once, with random 5-10s intervals.
        """
        print("\n" + "="*60)
        print("THREAD 2: POLLING CONSUMER STARTED (Batch Mode + Parallel Downloads)")
        print("="*60)
        
        active_list = []  # List of (scene, uuid) tuples to poll
        
        # Thread pool for parallel downloads
        from concurrent.futures import ThreadPoolExecutor
        download_executor = ThreadPoolExecutor(max_workers=5)
        
        def download_task(scene, video_url):
            """Task to download video in background thread"""
            try:
                scene.status = 'downloading'
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                
                print(f"[DOWNLOAD] Scene {scene.scene_id} STARTED")
                
                output_path = Path(self.output_folder) / f"scene_{scene.scene_id:03d}.mp4"
                output_path.parent.mkdir(parents=True, exist_ok=True)
                
                # Use a new generator instance for download to avoid lock contention
                temp_gen = BrowserVideoGenerator() 
                file_size = temp_gen.download_video(video_url, str(output_path))
                
                scene.video_path = str(output_path)
                scene.download_url = video_url
                scene.file_size = file_size
                scene.generated_at = datetime.now().isoformat()
                scene.status = 'completed'
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                
                print(f"[DOWNLOAD] ✓ Scene {scene.scene_id} Complete ({file_size/1024/1024:.1f} MB)")
                self.active_generations_count -= 1
                
                # Remove from pending operations file
                self.remove_from_pending(scene.scene_id)
                
            except Exception as e:
                scene.status = 'failed'
                scene.error = f"Download failed: {e}"
                print(f"[DOWNLOAD] ✗ Scene {scene.scene_id} Failed: {e}")
                self.active_generations_count -= 1
                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                
                # Also remove failed downloads from pending
                self.remove_from_pending(scene.scene_id)

        while True:  # Always run, just sleep if idle
            # 1. Fetch new items from queue
            while True:
                try:
                    item = self.pending_polls.get_nowait()
                    active_list.append(item)
                except queue.Empty:
                    break
            
            if not active_list:
                time.sleep(1)
                continue
            
            # 2. Random wait interval between 5-10 seconds
            wait_interval = random.uniform(5.0, 10.0)
            print(f"\n[POLLER] Monitoring {len(active_list)} active videos... (Next check in {wait_interval:.1f}s)")
            
            # 3. Batch poll all active items in a single API call
            completed_indices = []
            
            try:
                # Build batch operations list
                operations_batch = [
                    (scene.operation_name, scene_uuid) 
                    for scene, scene_uuid in active_list
                ]
                
                # Make single batch API call for all operations
                operation_results = self.generator.poll_video_status_batch(
                    operations_batch, self.access_token
                )
                
                if operation_results:
                    # Process each result
                    for i, operation_data in enumerate(operation_results):
                        if i >= len(active_list):
                            break  # Safety check
                        
                        scene, scene_uuid = active_list[i]
                        
                        if operation_data:
                            status = operation_data.get('status', '')
                            # print(f"[POLLER] Scene {scene.scene_id} Status: {status}") # Optional debug
                            
                            if status in ['MEDIA_GENERATION_STATUS_SUCCEEDED', 'MEDIA_GENERATION_STATUS_SUCCESSFUL']:
                                # Handle Success
                                video_url = None
                                if 'operation' in operation_data:
                                    metadata = operation_data['operation'].get('metadata', {})
                                    video = metadata.get('video', {})
                                    video_url = video.get('fifeUrl')
                                
                                if video_url:
                                    print(f"[POLLER] Scene {scene.scene_id} READY -> Queuing Download...")
                                    # Submit to thread pool
                                    download_executor.submit(download_task, scene, video_url)
                                else:
                                    scene.status = 'failed'
                                    scene.error = "No video URL"
                                    print(f"[POLLER] ✗ Scene {scene.scene_id}: No video URL")
                                    self.root.after(0, lambda s=scene: self.update_scene_card(s))
                                    self.active_generations_count -= 1
                                
                                completed_indices.append(i)
                                
                            elif status == 'MEDIA_GENERATION_STATUS_FAILED':
                                # Extract detailed error information
                                error_msg = "Generation failed"
                                error_details = {}
                                
                                # Try to get error details from operation metadata
                                if 'operation' in operation_data:
                                    metadata = operation_data['operation'].get('metadata', {})
                                    error_details = metadata.get('error', {})
                                    
                                    if error_details:
                                        error_code = error_details.get('code', 'Unknown')
                                        error_message = error_details.get('message', 'No details')
                                        error_reason = error_details.get('reason', '')
                                        
                                        error_msg = f"{error_message} (Code: {error_code})"
                                        if error_reason:
                                            error_msg += f" - {error_reason}"
                                
                                scene.status = 'failed'
                                scene.error = error_msg
                                
                                # Detailed logging
                                print(f"\n[POLLER] ✗ Scene {scene.scene_id}: GENERATION FAILED")
                                print(f"[POLLER]   Error: {error_msg}")
                                if error_details:
                                    print(f"[POLLER]   Full error data: {json.dumps(error_details, indent=2)}")
                                print(f"[POLLER]   Full operation data: {json.dumps(operation_data, indent=2)}\n")
                                
                                completed_indices.append(i)
                                self.root.after(0, lambda s=scene: self.update_scene_card(s))
                                self.active_generations_count -= 1
                else:
                    print(f"[POLLER] Warning: Batch poll returned no results")
                    
            except Exception as e:
                print(f"[POLLER] Warning during batch polling: {e}")
                import traceback
                traceback.print_exc()
            
            # 4. Remove completed items (in reverse order to keep indices valid)
            for index in sorted(completed_indices, reverse=True):
                active_list.pop(index)
            
            # 5. Wait before next poll cycle (random 5-10 seconds)
            if active_list:
                time.sleep(wait_interval)
        
        # clean up executor
        download_executor.shutdown(wait=False)
    
    def schedule_auto_save(self):
        """Schedule auto-save every 30 seconds"""
        if self.project_manager and self.is_running:
            self.project_manager.save(self.scenes)
            self.auto_save_timer = self.root.after(30000, self.schedule_auto_save)
    
    def concatenate_videos(self):
        """Concatenate multiple video files using FFmpeg"""
        video_files = filedialog.askopenfilenames(
            title="Select Videos to Concatenate (in order)",
            filetypes=[("MP4 files", "*.mp4"), ("All video files", "*.mp4 *.avi *.mkv"), ("All files", "*.*")]
        )
        
        if not video_files or len(video_files) < 2:
            messagebox.showwarning("Not Enough Files", "Please select at least 2 videos to concatenate")
            return
        
        # Ask for output file
        output_file = filedialog.asksaveasfilename(
            title="Save Concatenated Video As",
            defaultextension=".mp4",
            filetypes=[("MP4 files", "*.mp4")]
        )
        
        if not output_file:
            return
        
        try:
            # Create file list for FFmpeg
            list_file = Path(self.output_folder) / "concat_list.txt"
            with open(list_file, 'w', encoding='utf-8') as f:
                for video in video_files:
                    # Escape single quotes and use absolute path
                    escaped_path = str(Path(video).absolute()).replace("'", "'\\''")
                    f.write(f"file '{escaped_path}'\n")
            
            # Run FFmpeg concatenation (no re-encoding)
            import subprocess
            
            cmd = [
                'ffmpeg',
                '-f', 'concat',
                '-safe', '0',
                '-i', str(list_file),
                '-c', 'copy',  # Copy codec (no re-encoding)
                str(output_file)
            ]
            
            # Show progress dialog
            progress_dialog = tk.Toplevel(self.root)
            progress_dialog.title("Concatenating Videos")
            progress_dialog.geometry("400x150")
            
            ttk.Label(progress_dialog, text=f"Concatenating {len(video_files)} videos...", 
                      font=('Arial', 10, 'bold')).pack(pady=10)
            
            progress_bar = ttk.Progressbar(progress_dialog, mode='indeterminate', length=300)
            progress_bar.pack(pady=10)
            progress_bar.start()
            
            status_label = ttk.Label(progress_dialog, text="Processing...")
            status_label.pack(pady=5)
            
            def run_ffmpeg():
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                    
                    # Clean up list file
                    list_file.unlink(missing_ok=True)
                    
                    if result.returncode == 0:
                        self.root.after(0, progress_dialog.destroy)
                        self.root.after(0, lambda: messagebox.showinfo(
                            "Success", 
                            f"Videos concatenated successfully!\n\nOutput: {output_file}\nSize: {Path(output_file).stat().st_size / 1024 / 1024:.1f} MB"
                        ))
                    else:
                        self.root.after(0, progress_dialog.destroy)
                        self.root.after(0, lambda: messagebox.showerror(
                            "FFmpeg Error",
                            f"Concatenation failed:\n{result.stderr[:500]}"
                        ))
                except subprocess.TimeoutExpired:
                    self.root.after(0, progress_dialog.destroy)
                    self.root.after(0, lambda: messagebox.showerror("Timeout", "FFmpeg process timed out"))
                except FileNotFoundError:
                    self.root.after(0, progress_dialog.destroy)
                    self.root.after(0, lambda: messagebox.showerror(
                        "FFmpeg Not Found",
                        "FFmpeg is not installed or not in PATH.\n\nInstall: https://ffmpeg.org/download.html"
                    ))
                except Exception as e:
                    self.root.after(0, progress_dialog.destroy)
                    self.root.after(0, lambda: messagebox.showerror("Error", f"Concatenation error: {e}"))
            
            # Run in thread
            thread = threading.Thread(target=run_ffmpeg, daemon=True)
            thread.start()
            
        except Exception as e:
            messagebox.showerror("Error", f"Failed to prepare concatenation: {e}")
    
    def login_all_browsers(self):
        """Launch and login multiple browsers for parallel video generation"""
        email = self.email_entry.get().strip()
        password = self.password_entry.get().strip()
        
        if not email or not password:
            messagebox.showerror("Error", "Please enter email and password")
            return
        
        try:
            browser_count = int(self.browser_count_var.get())
            if browser_count < 1 or browser_count > 10:
                browser_count = 1
        except:
            browser_count = 1
        
        def login_all_worker():
            self.browser_connections = []
            self.multi_browser_mode = browser_count > 1
            
            print(f"\n{'='*60}")
            print(f"MULTI-BROWSER LOGIN - Launching {browser_count} browsers")
            print("="*60)
            
            for i in range(browser_count):
                profile_name = f"Browser_{i+1}"
                port = self.base_debug_port + i
                
                print(f"\n[BROWSER {i+1}] Setting up profile '{profile_name}' on port {port}...")
                
                # Create profile if doesn't exist
                profile_path = os.path.join(PROFILES_DIR, profile_name)
                if not os.path.exists(profile_path):
                    os.makedirs(profile_path, exist_ok=True)
                    print(f"[BROWSER {i+1}] ✓ Created profile folder")
                
                # Launch Chrome with this profile and unique port
                try:
                    import subprocess
                    cmd = [
                        CHROME_PATH,
                        f"--remote-debugging-port={port}",
                        "--remote-allow-origins=*",
                        f"--user-data-dir={profile_path}",
                        "--profile-directory=Default",
                        "https://labs.google/fx/tools/flow"
                    ]
                    subprocess.Popen(cmd)
                    print(f"[BROWSER {i+1}] ✓ Chrome launched on port {port}")
                    time.sleep(3)  # Wait for Chrome to start
                except Exception as e:
                    print(f"[BROWSER {i+1}] ✗ Failed to launch: {e}")
                    continue
                
                # Wait for Chrome to be ready
                chrome_ready = False
                for attempt in range(5):
                    try:
                        requests.get(f'http://localhost:{port}/json', timeout=2)
                        chrome_ready = True
                        break
                    except:
                        time.sleep(2)
                
                if not chrome_ready:
                    print(f"[BROWSER {i+1}] ✗ Chrome not responding on port {port}")
                    continue
                
                # Login (SimpleAutoLogin.run() already clears data, don't do it twice)
                max_login_attempts = 3
                login_success = False
                
                for login_attempt in range(max_login_attempts):
                    if login_attempt > 0:
                        print(f"[BROWSER {i+1}] Retry login attempt {login_attempt + 1}/{max_login_attempts}...")
                    else:
                        print(f"[BROWSER {i+1}] Starting login for {email}...")
                    
                    try:
                        login = SimpleAutoLogin(email=email, password=password, debug_port=port)
                        success = login.run()
                        login.close()
                        
                        if not success:
                            print(f"[BROWSER {i+1}] ✗ Login flow failed")
                            time.sleep(5)
                            continue
                    except Exception as e:
                        print(f"[BROWSER {i+1}] ✗ Login error: {e}")
                        time.sleep(5)
                        continue
                    
                    # Try to get access token (3 attempts with 15s interval)
                    print(f"[BROWSER {i+1}] Verifying login (3 attempts with 15s interval)...")
                    token = None
                    
                    for token_attempt in range(3):
                        time.sleep(15)  # Wait 15 seconds before each attempt
                        print(f"[BROWSER {i+1}] Token check attempt {token_attempt + 1}/3...")
                        
                        try:
                            generator = BrowserVideoGenerator(debug_port=port)
                            generator.connect()
                            token = generator.get_access_token()
                            
                            if token:
                                # Store this browser connection
                                browser_info = {
                                    'profile': profile_name,
                                    'port': port,
                                    'generator': generator,
                                    'access_token': token,
                                    '403_count': 0,
                                    'status': 'connected'
                                }
                                self.browser_connections.append(browser_info)
                                print(f"[BROWSER {i+1}] ✓ Connected! Token: {token[:30]}...")
                                login_success = True
                                break
                            else:
                                print(f"[BROWSER {i+1}] ✗ No token on attempt {token_attempt + 1}")
                                generator.close()
                        except Exception as e:
                            print(f"[BROWSER {i+1}] ✗ Token check error: {e}")
                    
                    if login_success:
                        break
                    else:
                        print(f"[BROWSER {i+1}] ✗ All 3 token attempts failed - will retry login")
                
                if not login_success:
                    print(f"[BROWSER {i+1}] ✗ Failed after {max_login_attempts} login attempts")
                
                # Small delay between browsers
                time.sleep(2)
            
            # Update status
            connected_count = len(self.browser_connections)
            print(f"\n{'='*60}")
            print(f"MULTI-BROWSER LOGIN COMPLETE - {connected_count}/{browser_count} connected")
            print("="*60)
            
            self.root.after(0, lambda: self.browser_status_label.config(
                text=f"{connected_count} browsers connected",
                foreground="green" if connected_count > 0 else "red"
            ))
            
            # Reload profiles
            self.root.after(0, self.load_profiles)
        
        # Run in thread
        thread = threading.Thread(target=login_all_worker, daemon=True)
        thread.start()
    
    def connect_open_browsers(self):
        """Connect to already-open browsers without launching or logging in"""
        try:
            browser_count = int(self.browser_count_var.get())
            if browser_count < 1 or browser_count > 10:
                browser_count = 1
        except:
            browser_count = 1
        
        def connect_worker():
            self.browser_connections = []
            self.multi_browser_mode = browser_count > 1
            
            print(f"\n{'='*60}")
            print(f"CONNECTING TO {browser_count} OPEN BROWSERS")
            print("="*60)
            
            for i in range(browser_count):
                port = self.base_debug_port + i
                
                print(f"\n[BROWSER {i+1}] Connecting to port {port}...")
                
                # Check if Chrome is running on this port
                try:
                    response = requests.get(f'http://localhost:{port}/json', timeout=2)
                    tabs = response.json()
                    print(f"[BROWSER {i+1}] ✓ Found browser with {len(tabs)} tabs")
                except:
                    print(f"[BROWSER {i+1}] ✗ No browser on port {port}")
                    continue
                
                # Connect and get token
                try:
                    generator = BrowserVideoGenerator(debug_port=port)
                    generator.connect()
                    token = generator.get_access_token()
                    
                    if token:
                        browser_info = {
                            'profile': f'Browser_{i+1}',
                            'port': port,
                            'generator': generator,
                            'access_token': token,
                            '403_count': 0,
                            'status': 'connected'
                        }
                        self.browser_connections.append(browser_info)
                        print(f"[BROWSER {i+1}] ✓ Connected! Token: {token[:30]}...")
                    else:
                        print(f"[BROWSER {i+1}] ✗ No access token - not logged in?")
                        generator.close()
                except Exception as e:
                    print(f"[BROWSER {i+1}] ✗ Connection error: {e}")
            
            # Update status
            connected_count = len(self.browser_connections)
            print(f"\n{'='*60}")
            print(f"CONNECTED TO {connected_count}/{browser_count} BROWSERS")
            print("="*60)
            
            self.root.after(0, lambda: self.browser_status_label.config(
                text=f"{connected_count} browsers connected",
                foreground="green" if connected_count > 0 else "red"
            ))
        
        thread = threading.Thread(target=connect_worker, daemon=True)
        thread.start()
    
    def open_browsers_no_login(self):
        """Open browsers and connect without logging in - for already-logged-in profiles"""
        try:
            browser_count = int(self.browser_count_var.get())
            if browser_count < 1 or browser_count > 10:
                browser_count = 1
        except:
            browser_count = 1
        
        def open_worker():
            self.browser_connections = []
            self.multi_browser_mode = browser_count > 1
            
            print(f"\n{'='*60}")
            print(f"OPENING {browser_count} BROWSERS (NO LOGIN)")
            print("="*60)
            
            for i in range(browser_count):
                profile_name = f"Browser_{i+1}"
                port = self.base_debug_port + i
                
                print(f"\n[BROWSER {i+1}] Opening profile '{profile_name}' on port {port}...")
                
                # Create profile if doesn't exist
                profile_path = os.path.join(PROFILES_DIR, profile_name)
                if not os.path.exists(profile_path):
                    os.makedirs(profile_path, exist_ok=True)
                    print(f"[BROWSER {i+1}] ✓ Created profile folder")
                
                # Launch Chrome
                try:
                    import subprocess
                    cmd = [
                        CHROME_PATH,
                        f"--remote-debugging-port={port}",
                        "--remote-allow-origins=*",
                        f"--user-data-dir={profile_path}",
                        "--profile-directory=Default",
                        "https://labs.google/fx/tools/flow"
                    ]
                    subprocess.Popen(cmd)
                    print(f"[BROWSER {i+1}] ✓ Chrome launched on port {port}")
                    time.sleep(3)
                except Exception as e:
                    print(f"[BROWSER {i+1}] ✗ Failed to launch: {e}")
                    continue
                
                # Wait for Chrome to be ready
                chrome_ready = False
                for attempt in range(5):
                    try:
                        requests.get(f'http://localhost:{port}/json', timeout=2)
                        chrome_ready = True
                        break
                    except:
                        time.sleep(2)
                
                if not chrome_ready:
                    print(f"[BROWSER {i+1}] ✗ Chrome not responding")
                    continue
                
                # Connect and try to get token (may or may not be logged in)
                time.sleep(3)  # Wait for page to load
                try:
                    generator = BrowserVideoGenerator(debug_port=port)
                    generator.connect()
                    token = generator.get_access_token()
                    
                    browser_info = {
                        'profile': profile_name,
                        'port': port,
                        'generator': generator,
                        'access_token': token if token else '',
                        '403_count': 0,
                        'status': 'connected' if token else 'no_token'
                    }
                    self.browser_connections.append(browser_info)
                    
                    if token:
                        print(f"[BROWSER {i+1}] ✓ Connected with token: {token[:30]}...")
                    else:
                        print(f"[BROWSER {i+1}] ✓ Connected (no token - login manually or use Auto Login)")
                except Exception as e:
                    print(f"[BROWSER {i+1}] ✗ Connection error: {e}")
                
                time.sleep(1)
            
            # Update status
            connected_count = len(self.browser_connections)
            print(f"\n{'='*60}")
            print(f"OPENED {connected_count}/{browser_count} BROWSERS")
            print("="*60)
            
            self.root.after(0, lambda: self.browser_status_label.config(
                text=f"{connected_count} browsers connected",
                foreground="green" if connected_count > 0 else "orange"
            ))
            
            self.root.after(0, self.load_profiles)
        
        thread = threading.Thread(target=open_worker, daemon=True)
        thread.start()
    
    
    def relogin_single_browser(self, browser_index):
        """Relogin a single browser that has too many 403 errors - with retry logic"""
        if browser_index >= len(self.browser_connections):
            return
        
        browser = self.browser_connections[browser_index]
        email = self.email_entry.get().strip()
        password = self.password_entry.get().strip()
        port = browser['port']
        
        def relogin_worker():
            print(f"\n[RELOGIN] Browser {browser_index+1} on port {port} - Too many 403 errors")
            
            browser['status'] = 'relogging'
            browser['403_count'] = 0
            
            max_login_attempts = 3
            login_success = False
            
            for login_attempt in range(max_login_attempts):
                if login_attempt > 0:
                    print(f"[RELOGIN] Browser {browser_index+1} - Retry login attempt {login_attempt + 1}/{max_login_attempts}...")
                
                # Login
                try:
                    login = SimpleAutoLogin(email=email, password=password, debug_port=port)
                    success = login.run()
                    login.close()
                    
                    if not success:
                        print(f"[RELOGIN] ✗ Browser {browser_index+1} login flow failed")
                        time.sleep(5)
                        continue
                except Exception as e:
                    print(f"[RELOGIN] ✗ Browser {browser_index+1} login error: {e}")
                    time.sleep(5)
                    continue
                
                # Try to get access token (3 attempts with 15s interval)
                print(f"[RELOGIN] Browser {browser_index+1} - Verifying (3 attempts with 15s interval)...")
                token = None
                
                for token_attempt in range(3):
                    time.sleep(15)  # Wait 15 seconds before each attempt
                    print(f"[RELOGIN] Browser {browser_index+1} - Token check attempt {token_attempt + 1}/3...")
                    
                    try:
                        # Close old generator
                        try:
                            browser['generator'].close()
                        except:
                            pass
                        
                        generator = BrowserVideoGenerator(debug_port=port)
                        generator.connect()
                        token = generator.get_access_token()
                        
                        if token:
                            browser['generator'] = generator
                            browser['access_token'] = token
                            browser['status'] = 'connected'
                            print(f"[RELOGIN] ✓ Browser {browser_index+1} relogged successfully! Token: {token[:30]}...")
                            login_success = True
                            break
                        else:
                            print(f"[RELOGIN] ✗ Browser {browser_index+1} no token on attempt {token_attempt + 1}")
                            generator.close()
                    except Exception as e:
                        print(f"[RELOGIN] ✗ Browser {browser_index+1} token check error: {e}")
                
                if login_success:
                    break
                else:
                    print(f"[RELOGIN] ✗ Browser {browser_index+1} all 3 token attempts failed - will retry login")
            
            if not login_success:
                browser['status'] = 'error'
                print(f"[RELOGIN] ✗ Browser {browser_index+1} failed after {max_login_attempts} login attempts")
        
        thread = threading.Thread(target=relogin_worker, daemon=True)
        thread.start()
    
    def get_next_browser(self):
        """Get next available browser for round-robin generation"""
        if not self.browser_connections:
            return None
        
        # Try to find a connected browser starting from current index
        for i in range(len(self.browser_connections)):
            idx = (self.current_browser_index + i) % len(self.browser_connections)
            browser = self.browser_connections[idx]
            
            if browser['status'] == 'connected':
                self.current_browser_index = (idx + 1) % len(self.browser_connections)
                return idx, browser
        
        return None  # No connected browsers
    
    def has_any_connected_browser(self):
        """Check if any browser is connected and available"""
        if not self.multi_browser_mode or not self.browser_connections:
            return True  # Single browser mode - assume available
        
        for browser in self.browser_connections:
            if browser['status'] == 'connected':
                return True
        return False
    
    def count_connected_browsers(self):
        """Count how many browsers are currently connected"""
        if not self.browser_connections:
            return 0
        return sum(1 for b in self.browser_connections if b['status'] == 'connected')
    
    def all_browsers_relogging(self):
        """Check if all browsers are currently relogging"""
        if not self.browser_connections:
            return False
        return all(b['status'] == 'relogging' for b in self.browser_connections)
    
    
    def auto_login(self):
        """Perform automated login with verification and retry (up to 5 attempts)"""
        email = self.email_entry.get().strip()
        password = self.password_entry.get().strip()
        
        if not email or not password:
            messagebox.showerror("Error", "Please enter email and password")
            return
        
        def login_worker():
            # Check if Chrome is running, if not, launch it
            try:
                response = requests.get('http://localhost:9222/json', timeout=2)
                chrome_was_running = True
                print("[AUTO-LOGIN] Chrome is already running")
            except:
                chrome_was_running = False
                print("[AUTO-LOGIN] Chrome not detected - Will launch it first")
            
            # If Chrome is NOT running, launch it first
            if not chrome_was_running:
                print("[AUTO-LOGIN] Launching Chrome...")
                self.root.after(0, self.launch_chrome)
                print("[AUTO-LOGIN] Waiting 8 seconds for Chrome to start...")
                time.sleep(8)
                
                # Verify Chrome started
                try:
                    requests.get('http://localhost:9222/json', timeout=2)
                    print("[AUTO-LOGIN] ✓ Chrome launched successfully")
                except:
                    print("[AUTO-LOGIN] ✗ Chrome failed to launch")
                    return
            
            # Chrome is now running - DO NOT CLOSE IT (polling continues)
            # Just clear data and login in the same browser session
            print("[AUTO-LOGIN] Clearing browser data (keeping Chrome open for polling)...")
            try:
                temp_login = SimpleAutoLogin(email=email, password=password, debug_port=9222)
                if temp_login.connect():
                    temp_login.clear_data()
                    print("[AUTO-LOGIN] ✓ Browser data cleared")
                else:
                    print("[AUTO-LOGIN] ⚠ Could not connect to clear data")
            except Exception as e:
                print(f"[AUTO-LOGIN] ⚠ Warning during data clearing: {e}")
            
            # Now login (Chrome stays open, polling continues)
            print("[AUTO-LOGIN] Starting login process (polling continues in background)...")
            
            max_attempts = 5
            attempt = 0
            
            while attempt < max_attempts:
                attempt += 1
                try:
                    print(f"\n[AUTO-LOGIN] Attempt {attempt}/{max_attempts} - Starting login for {email}...")
                    
                    # Perform login
                    login = SimpleAutoLogin(email=email, password=password, debug_port=9222)
                    success = login.run()
                    login.close()
                    
                    if not success:
                        print(f"[AUTO-LOGIN] Attempt {attempt} failed - Login process returned False")
                        if attempt < max_attempts:
                            print(f"[AUTO-LOGIN] Retrying in 3 seconds...")
                            time.sleep(3)
                            continue
                        else:
                            # Removed popup - just log error
                            print(f"[AUTO-LOGIN] ✗ Login failed after {max_attempts} attempts")
                            return
                    
                    # Verify login by fetching access token
                    print(f"[AUTO-LOGIN] Verifying login by fetching access token...")
                    time.sleep(3)  # Wait for Flow to fully load
                    
                    try:
                        # Connect to browser and get token
                        temp_gen = BrowserVideoGenerator(debug_port=9222)
                        temp_gen.connect()
                        token = temp_gen.get_access_token()
                        temp_gen.close()
                        
                        if token:
                            print(f"[AUTO-LOGIN] ✓ Login verified! Token: {token[:50]}...")
                            self.access_token = token  # Update stored token
                            self.consecutive_403_errors = 0  # Reset counter
                            print(f"[AUTO-LOGIN] ✓ Login completed and verified (attempt {attempt}/{max_attempts})")
                            
                            # Directly trigger resume after successful login
                            print("[AUTO-LOGIN] Triggering resume in 3 seconds...")
                            time.sleep(3)
                            self.root.after(0, self.resume_failed_and_pending)
                            return
                        else:
                            print(f"[AUTO-LOGIN] Attempt {attempt} - No access token received")
                            if attempt < max_attempts:
                                print(f"[AUTO-LOGIN] Retrying in 5 seconds...")
                                time.sleep(5)
                                continue
                            else:
                                # Removed popup - just log error
                                print(f"[AUTO-LOGIN] ✗ Verification failed after {max_attempts} attempts")
                                return
                    
                    except Exception as e:
                        print(f"[AUTO-LOGIN] Attempt {attempt} - Token verification error: {e}")
                        if attempt < max_attempts:
                            print(f"[AUTO-LOGIN] Retrying in 5 seconds...")
                            time.sleep(5)
                            continue
                        else:
                            # Removed popup - just log error
                            print(f"[AUTO-LOGIN] ✗ Verification error after {max_attempts} attempts: {e}")
                            return
                
                except Exception as e:
                    print(f"[AUTO-LOGIN] Attempt {attempt} - Login error: {e}")
                    import traceback
                    traceback.print_exc()
                    if attempt < max_attempts:
                        print(f"[AUTO-LOGIN] Retrying in 5 seconds...")
                        time.sleep(5)
                        continue
                    else:
                        # Removed popup - just log error
                        print(f"[AUTO-LOGIN] ✗ Login error after {max_attempts} attempts: {e}")
                        return
        
        thread = threading.Thread(target=login_worker, daemon=True)
        thread.start()
    
    def trigger_auto_relogin(self):
        """Trigger automatic relogin and resume after 403 errors"""
        # Pause generation (stops new generations, but polling continues)
        if self.is_running:
            self.is_paused = True
            print("[AUTO-RELOGIN] Paused new generations (polling continues)")
        
        # Auto-login WITHOUT confirmation dialog
        print("[AUTO-RELOGIN] Starting automatic relogin (no confirmation needed)...")
        
        # Perform login (with verification and retry)
        # auto_login will automatically call resume_failed_and_pending after successful login
        self.auto_login()
    
    def resume_failed_and_pending(self):
        """Resume all failed and pending scenes after relogin"""
        resumed_count = 0
        scenes_to_resume = []
        
        # Reconnect to browser after Chrome restart
        print("[RESUME] Reconnecting to Chrome after relogin...")
        try:
            if hasattr(self, 'generator') and self.generator:
                try:
                    self.generator.close()
                except:
                    pass
            
            # Create new connection
            self.generator = BrowserVideoGenerator(debug_port=9222)
            self.generator.connect()
            
            # Update access token
            new_token = self.generator.get_access_token()
            if new_token:
                self.access_token = new_token
                print(f"[RESUME] ✓ Reconnected to Chrome, token updated: {new_token[:50]}...")
            else:
                print("[RESUME] ⚠ Reconnected but no token - using existing token")
        except Exception as e:
            print(f"[RESUME] ⚠ Could not reconnect to Chrome: {e}")
            print("[RESUME] Will try to continue with existing connection...")
        
        # Get active video scene IDs
        active_scene_ids = set()
        if hasattr(self, 'active_videos'):
            active_scene_ids = {scene_id for scene_id in self.active_videos.keys()}
        
        # Find ALL unfinished scenes that need to be resumed:
        # - 'failed' status (any error including 403)
        # - 'generating' status but not in active_videos (stuck/orphaned)
        # - 'queued' status that somehow got skipped
        print("[RESUME] Scanning for unfinished scenes...")
        for scene in self.scenes:
            needs_resume = False
            
            if scene.status == 'failed':
                # Failed scenes need to be retried
                needs_resume = True
                print(f"[RESUME] Scene {scene.scene_id}: was failed - will retry")
            
            elif scene.status == 'generating' and scene.scene_id not in active_scene_ids:
                # Scene was generating but not active (orphaned due to 403)
                needs_resume = True
                print(f"[RESUME] Scene {scene.scene_id}: was generating but orphaned - will retry")
            
            if needs_resume:
                # Reset to queued
                scene.status = 'queued'
                scene.error = None
                scene.operation_name = None  # Clear old operation
                if hasattr(scene, 'retry_count'):
                    scene.retry_count = 0
                self.update_scene_card(scene)
                scenes_to_resume.append(scene)
                resumed_count += 1
        
        # Unpause to allow new generations
        self.is_paused = False
        print("[RESUME] Generation unpaused - New videos can now start")
        
        if resumed_count > 0:
            # Add resumed scenes to the FRONT of queue (priority)
            if hasattr(self, 'queue_to_generate'):
                # Get current queue scene IDs
                current_queue_ids = {s.scene_id for s in self.queue_to_generate}
                
                # Create new list with resumed scenes at front
                scenes_to_add = []
                for scene in scenes_to_resume:
                    if scene.scene_id not in current_queue_ids:
                        scenes_to_add.append(scene)
                        print(f"[RESUME] Adding scene {scene.scene_id} to FRONT of queue")
                
                # Insert at front (priority over remaining scenes)
                self.queue_to_generate = scenes_to_add + list(self.queue_to_generate)
                
                print(f"[RESUME] Total scenes in queue: {len(self.queue_to_generate)}")
                print(f"[RESUME] First in queue: {[s.scene_id for s in self.queue_to_generate[:5]]}")
            
            # Removed popup - just log to console
            print(f"[RESUME] ✓ Generation resumed! Resumed {resumed_count} failed/orphaned scenes")
        else:
            print("[RESUME] No failed scenes to resume - Generation will continue normally")



if __name__ == '__main__':
    root = tk.Tk()
    app = BulkVideoGeneratorGUI(root)
    root.mainloop()
