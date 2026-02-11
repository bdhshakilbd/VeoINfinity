"""
Direct connection to the blob iframe where geminiHub lives
"""

import asyncio
import json
import websockets
import aiohttp
import random
from typing import List




class GeminiHub:
    def __init__(self):
        self.ws = None
        self.msg_id = 0
        self.responses = {}
        self.main_ws = None  # Connection to main page
        self.main_msg_id = 0
        self.first_image_generated = False
        
    async def focus_chrome(self):
        """Brings the Google AI Studio window to the front to ensure content loads"""
        try:
            import subprocess
            # Use PowerShell to find and activate the AI Studio window
            ps_cmd = '(New-Object -ComObject WScript.Shell).AppActivate("Google AI Studio")'
            subprocess.run(['powershell', '-command', ps_cmd], capture_output=True)
            print("✓ Focused Google AI Studio")
            await asyncio.sleep(0.5)
            return True
        except Exception as e:
            print(f"⚠ Focus error: {e}")
            return False

    async def connect(self):
        """Connect to blob page for geminiHub API and main page for interactions"""
        await self.focus_chrome()
        async with aiohttp.ClientSession() as session:
            async with session.get("http://localhost:9222/json") as resp:
                targets = await resp.json()
                
                # Find both blob frame and main page
                blob_ws_url = None
                main_ws_url = None
                
                for t in targets:
                    url = t.get('url', '')
                    if 'blob:' in url:
                        blob_ws_url = t['webSocketDebuggerUrl']
                        print(f"✓ Found blob frame")
                    elif 'aistudio.google.com' in url and t.get('type') == 'page':
                        main_ws_url = t['webSocketDebuggerUrl']
                        print(f"✓ Found main AI Studio page")
                
                if not blob_ws_url:
                    raise Exception("Blob frame not found! Make sure your AI Studio app is loaded.")
        
        # Connect to blob frame (for geminiHub API)
        self.ws = await websockets.connect(blob_ws_url, max_size=16 * 1024 * 1024)
        asyncio.create_task(self._listen())
        await self._cmd("Runtime.enable")
        
        # Also connect to main page (for click/hover tests)
        if main_ws_url:
            self.main_ws = await websockets.connect(main_ws_url, max_size=16 * 1024 * 1024)
            self.main_msg_id = 0
            print("✓ Connected to main page for interactions")
        else:
            self.main_ws = None
            print("⚠ Main page not found - click/hover tests may not work")
        
        print("✓ Ready to use geminiHub\n")
        
    async def _cmd(self, method: str, params: dict = None):
        self.msg_id += 1
        msg = {"id": self.msg_id, "method": method, "params": params or {}}
        future = asyncio.Future()
        self.responses[self.msg_id] = future
        await self.ws.send(json.dumps(msg))
        return await future
    
    async def _listen(self):
        try:
            async for msg in self.ws:
                data = json.loads(msg)
                if 'id' in data and data['id'] in self.responses:
                    future = self.responses.pop(data['id'])
                    if not future.done():
                        future.set_result(data)
        except:
            pass
    
    async def _cmd_main(self, method: str, params: dict):
        """Send a raw CDP command to the main page"""
        if not self.main_ws: return None
        self.main_msg_id += 1
        msg = {
            "id": self.main_msg_id,
            "method": method,
            "params": params
        }
        await self.main_ws.send(json.dumps(msg))
        return self.main_msg_id

    async def _click_modal_humanly_cdp(self, rect):
        """Ultra-Programmatic Bypass: Uses Touch and Drag sequences (Works while minimized)"""
        try:
            cx = rect['x'] + (rect['width'] / 2)
            cy = rect['y'] + (rect['height'] / 2)
            
            print(f"\n[PROGRAMMATIC-BYPASS] Starting 15X Touch/Drag Sequence at ({cx}, {cy})...")
            
            for i in range(15):
                # Attempt 1: Programmatic Tap (Touch Event)
                await self._cmd_main("Input.dispatchTouchEvent", {
                    "type": "touchStart",
                    "touchPoints": [{"x": cx, "y": cy}]
                })
                await asyncio.sleep(0.05)
                await self._cmd_main("Input.dispatchTouchEvent", {
                    "type": "touchEnd",
                    "touchPoints": []
                })
                
                # Attempt 2: Mouse Drag (Human-like sweep)
                await self._cmd_main("Input.dispatchMouseEvent", {
                    "type": "mousePressed", "x": cx, "y": cy, "button": "left", "clickCount": 1
                })
                for step in range(1, 5):
                    await self._cmd_main("Input.dispatchMouseEvent", {
                        "type": "mouseMoved", "x": cx + (step * 5), "y": cy + (step * 2), "button": "left"
                    })
                    await asyncio.sleep(0.02)
                await self._cmd_main("Input.dispatchMouseEvent", {
                    "type": "mouseReleased", "x": cx + 20, "y": cy + 8, "button": "left", "clickCount": 1
                })
                
                # Attempt 3: Standard Click
                await self._cmd_main("Input.dispatchMouseEvent", {
                    "type": "mousePressed", "x": cx, "y": cy, "button": "left", "clickCount": 1, "force": 1
                })
                await self._cmd_main("Input.dispatchMouseEvent", {
                    "type": "mouseReleased", "x": cx, "y": cy, "button": "left", "clickCount": 1, "force": 1
                })
                
                await asyncio.sleep(0.3)
                
            print("[PROGRAMMATIC-BYPASS] Sequence complete.\n")
            return True
        except Exception as e:
            print(f"[CDP-BYPASS] Error: {e}")
            return False

    async def _check_modal_blocking(self):
        """Check if Launch modal is blocking execution"""
        if not self.main_ws: return False
        try:
            self.main_msg_id += 1
            # Get Modal Rect if it exists
            check_script = """(() => {
                const m = document.querySelector('.interaction-modal');
                if (m && m.offsetParent !== null) {
                    const r = m.getBoundingClientRect();
                    return {found: true, x: r.x, y: r.y, width: r.width, height: r.height};
                }
                return {found: false};
            })()"""
            
            msg = {
                "id": self.main_msg_id,
                "method": "Runtime.evaluate",
                "params": {
                    "expression": check_script,
                    "returnByValue": True
                }
            }
            await self.main_ws.send(json.dumps(msg))
            
            # Quick wait for response
            async def wait_resp():
                async for raw in self.main_ws:
                    data = json.loads(raw)
                    if data.get("id") == self.main_msg_id:
                        return data
                        
            try:
                resp = await asyncio.wait_for(wait_resp(), timeout=1.0)
                res = resp.get("result", {}).get("result", {}).get("value", {})
                
                if res.get("found"):
                    print("\n" + "!"*60)
                    print("⚠ BLOCKING MODAL DETECTED")
                    
                    # Try Programmatic CDP Click
                    await self._click_modal_humanly_cdp(res)
                        
                    print("!"*60 + "\n")
                    return True
                    print("!"*60 + "\n")
                    return True
            except:
                pass
        except:
            pass
        return False

    async def _eval(self, code: str, timeout: int = 60):
        """Execute JavaScript in the blob frame with timeout"""
        
        # Create a Task so we can safely await it multiple times if needed
        cmd_coro = self._cmd("Runtime.evaluate", {
            "expression": code,
            "awaitPromise": True,
            "returnByValue": True
        })
        task = asyncio.create_task(cmd_coro)
        
        # First try: wait 3 seconds
        try:
            resp = await asyncio.wait_for(asyncio.shield(task), timeout=3)
        except asyncio.TimeoutError:
            # If slow, check if modal is blocking
            await self._check_modal_blocking()
            
            # Continue waiting for the remaining time
            try:
                resp = await asyncio.wait_for(task, timeout=max(1, timeout-3))
            except asyncio.TimeoutError:
                return {"error": f"Operation timeout after {timeout} seconds"}
        
        if 'result' in resp:
            result = resp['result']
            
            # Check for exception
            if 'exceptionDetails' in result:
                error = result['exceptionDetails']
                print(f"    ✗ JS Error: {error.get('text', 'Unknown error')}")
                return {"error": error.get('text', 'Unknown error')}
            
            # Get the result value
            if 'result' in result:
                result_obj = result['result']
                
                # Handle different result types
                if result_obj.get('type') == 'string':
                    return result_obj.get('value')
                elif result_obj.get('type') == 'object':
                    if result_obj.get('subtype') == 'null':
                        return None
                    return result_obj.get('value')
                else:
                    return result_obj.get('value')
        
        return None
    
    async def _eval_main_page(self, expression: str, timeout: int = 30):
        """Evaluate JavaScript on the main AI Studio page (not the blob frame)"""
        if not self.main_ws:
            print("[MAIN] Main page not connected")
            return None
        
        try:
            self.main_msg_id += 1
            msg = {
                "id": self.main_msg_id,
                "method": "Runtime.evaluate",
                "params": {
                    "expression": expression,
                    "returnByValue": True,
                    "awaitPromise": True
                }
            }
            
            await self.main_ws.send(json.dumps(msg))
            
            # Wait for response
            async def wait_for_response():
                async for raw in self.main_ws:
                    data = json.loads(raw)
                    if data.get("id") == self.main_msg_id:
                        return data
            
            response = await asyncio.wait_for(wait_for_response(), timeout=timeout)
            
            result = response.get("result", {}).get("result", {})
            if result.get("type") == "string":
                return result.get("value")
            elif result.get("type") == "object":
                return result.get("value")
            else:
                return result.get("value")
                
        except asyncio.TimeoutError:
            print(f"[MAIN] Timeout after {timeout}s")
            return None
        except Exception as e:
            print(f"[MAIN] Error: {e}")
            return None
    
    async def click_iframe_to_activate(self):
        """Click the iframe to activate it and dismiss the Launch modal (runs on main page)"""
        try:
            click_code = """
            (() => {
                const iframe = document.querySelector('iframe[title="Preview"]');
                if (iframe) {
                    iframe.click();
                    return 'Iframe clicked - page activated';
                }
                return 'Iframe not found';
            })()
            """
            # Execute on main page, not blob frame
            result = await self._eval_main_page(click_code, timeout=5)
            print(f"[ACTIVATE] {result}")
            return result
        except Exception as e:
            print(f"[ACTIVATE] Warning: Failed to click iframe: {e}")
            return None
    
    async def focus_iframe(self):
        """Focus the iframe as fallback activation method (runs on main page)"""
        try:
            focus_code = """
            (() => {
                const iframe = document.querySelector('iframe[title="Preview"]');
                if (iframe) {
                    iframe.focus();
                    if (iframe.contentWindow) {
                        iframe.contentWindow.focus();
                    }
                    return 'Iframe focused';
                }
                return 'Iframe not found';
            })()
            """
            # Execute on main page, not blob frame
            result = await self._eval_main_page(focus_code, timeout=5)
            print(f"[ACTIVATE] {result}")
            return result
        except Exception as e:
            print(f"[ACTIVATE] Warning: Failed to focus iframe: {e}")
            return None
    
    async def click_iframe_all_targets(self):
        """Try to click iframe by executing on ALL CDP targets until it works"""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get("http://localhost:9222/json") as resp:
                    targets = await resp.json()
            
            click_code = """
            (() => {
                const iframe = document.querySelector('iframe[title="Preview"]');
                if (iframe) {
                    iframe.click();
                    console.log('Iframe clicked');
                    return 'Iframe clicked successfully';
                }
                return null;
            })()
            """
            
            results = []
            for target in targets:
                try:
                    ws_url = target.get('webSocketDebuggerUrl')
                    if not ws_url:
                        continue
                    
                    # Try to execute on this target
                    ws = await websockets.connect(ws_url, max_size=16 * 1024 * 1024)
                    
                    # Enable runtime
                    await ws.send(json.dumps({
                        "id": 1,
                        "method": "Runtime.enable",
                        "params": {}
                    }))
                    
                    # Wait for response
                    await ws.recv()
                    
                    # Execute click code
                    await ws.send(json.dumps({
                        "id": 2,
                        "method": "Runtime.evaluate",
                        "params": {
                            "expression": click_code,
                            "returnByValue": True
                        }
                    }))
                    
                    # Get result
                    response = await asyncio.wait_for(ws.recv(), timeout=2)
                    data = json.loads(response)
                    result_value = data.get("result", {}).get("result", {}).get("value")
                    
                    await ws.close()
                    
                    if result_value:
                        print(f"[CLICK_ALL] Success on target: {target.get('url', 'unknown')[:50]}")
                        results.append(f"✓ {result_value}")
                    
                except Exception as e:
                    continue
            
            if results:
                return " | ".join(results)
            else:
                return "Iframe not found on any target"
                
        except Exception as e:
            print(f"[CLICK_ALL] Error: {e}")
            return f"Error: {str(e)}"
    
    async def test_click_main_page(self):
        """Test clicking anywhere on the main page using CDP Input.dispatchMouseEvent"""
        if not self.main_ws:
            return "Error: Main page not connected"
        
        try:
            # Get window size first
            size_code = "({width: window.innerWidth, height: window.innerHeight})"
            
            self.main_msg_id += 1
            await self.main_ws.send(json.dumps({
                "id": self.main_msg_id,
                "method": "Runtime.evaluate",
                "params": {"expression": size_code, "returnByValue": True}
            }))
            
            response = await asyncio.wait_for(self.main_ws.recv(), timeout=3)
            data = json.loads(response)
            size = data.get("result", {}).get("result", {}).get("value", {})
            
            x = size.get('width', 1920) // 2
            y = size.get('height', 1080) // 2
            
            # Use CDP Input.dispatchMouseEvent (the only method that works!)
            # Mouse pressed
            self.main_msg_id += 1
            await self.main_ws.send(json.dumps({
                "id": self.main_msg_id,
                "method": "Input.dispatchMouseEvent",
                "params": {
                    "type": "mousePressed",
                    "x": x,
                    "y": y,
                    "button": "left",
                    "clickCount": 1
                }
            }))
            await self.main_ws.recv()
            
            # Mouse released
            self.main_msg_id += 1
            await self.main_ws.send(json.dumps({
                "id": self.main_msg_id,
                "method": "Input.dispatchMouseEvent",
                "params": {
                    "type": "mouseReleased",
                    "x": x,
                    "y": y,
                    "button": "left",
                    "clickCount": 1
                }
            }))
            await self.main_ws.recv()
            
            result = f"Clicked at ({x}, {y}) on main page (CDP native)"
            print(f"[CLICK TEST] {result}")
            return result
            
        except Exception as e:
            print(f"[CLICK TEST] Error: {e}")
            return f"Error: {str(e)}"
    
    async def test_hover_main_page(self, duration_seconds=2.0):
        """Test hovering mouse on the main page using CDP Input.dispatchMouseEvent"""
        if not self.main_ws:
            return "Error: Main page not connected"
        
        try:
            # Get window size first
            size_code = "({width: window.innerWidth, height: window.innerHeight})"
            
            self.main_msg_id += 1
            await self.main_ws.send(json.dumps({
                "id": self.main_msg_id,
                "method": "Runtime.evaluate",
                "params": {"expression": size_code, "returnByValue": True}
            }))
            
            response = await asyncio.wait_for(self.main_ws.recv(), timeout=3)
            data = json.loads(response)
            size = data.get("result", {}).get("result", {}).get("value", {})
            
            x = size.get('width', 1920) // 2
            y = size.get('height', 1080) // 2
            
            # Use CDP Input.dispatchMouseEvent for hover
            # Mouse moved
            self.main_msg_id += 1
            await self.main_ws.send(json.dumps({
                "id": self.main_msg_id,
                "method": "Input.dispatchMouseEvent",
                "params": {
                    "type": "mouseMoved",
                    "x": x,
                    "y": y
                }
            }))
            await self.main_ws.recv()
            
            # Wait for specified duration
            await asyncio.sleep(duration_seconds)
            
            result = f"Hovered at ({x}, {y}) for {duration_seconds}s on main page (CDP native)"
            print(f"[HOVER TEST] {result}")
            return result
            
        except Exception as e:
            print(f"[HOVER TEST] Error: {e}")
            return f"Error: {str(e)}"
    
    
    async def pro3(self, prompt: str):
        """Gemini 3 Pro"""
        code = f"""(async () => {{
            try {{
                return await geminiHub.pro3({json.dumps(prompt)});
            }} catch (e) {{
                return {{ error: e.message, stack: e.stack }};
            }}
        }})()"""
        return await self._eval(code)
    
    async def pro25(self, prompt: str):
        """Gemini 2.5 Pro"""
        code = f"""(async () => {{
            try {{
                return await geminiHub.pro25({json.dumps(prompt)});
            }} catch (e) {{
                return {{ error: e.message, stack: e.stack }};
            }}
        }})()"""
        return await self._eval(code)
    
    async def flash3(self, prompt: str):
        """Gemini 3 Flash"""
        code = f"""(async () => {{
            try {{
                return await geminiHub.flash3({json.dumps(prompt)});
            }} catch (e) {{
                return {{ error: e.message, stack: e.stack }};
            }}
        }})()"""
        return await self._eval(code)
    
    async def flash25(self, prompt: str):
        """Gemini 2.5 Flash"""
        code = f"""(async () => {{
            try {{
                return await geminiHub.flash25({json.dumps(prompt)});
            }} catch (e) {{
                return {{ error: e.message, stack: e.stack }};
            }}
        }})()"""
        return await self._eval(code)
    
    async def run(self, prompt: str):
        """Run all models"""
        code = f"""(async () => {{
            try {{
                return await geminiHub.run({json.dumps(prompt)});
            }} catch (e) {{
                return {{ error: e.message, stack: e.stack }};
            }}
        }})()"""
        return await self._eval(code)
    
    async def ask(self, model: str, prompt: str, schema=None):
        """Ask a question using geminiHub.ask() - waits for result"""
        # Use model constants from geminiHub.models
        if schema:
            # Convert Python dict to JSON string for JavaScript
            schema_json = json.dumps(schema)
            code = f"""(async () => {{
                try {{
                    const result = await window.geminiHub.ask(
                        {json.dumps(model)}, 
                        {json.dumps(prompt)},
                        {schema_json}
                    );
                    return result;
                }} catch (e) {{
                    return {{ error: e.message }};
                }}
            }})()"""
            print(f"[ASK] Model: {model}, Prompt: {prompt[:30]}..., Schema: Yes")
        else:
            code = f"""(async () => {{
                try {{
                    const result = await window.geminiHub.ask(
                        {json.dumps(model)}, 
                        {json.dumps(prompt)}
                    );
                    return result;
                }} catch (e) {{
                    return {{ error: e.message }};
                }}
            }})()"""
            print(f"[ASK] Model: {model}, Prompt: {prompt[:30]}...")
        
        result = await self._eval(code, timeout=600)
        return result
    
    async def spawn_text(self, model: str, prompt: str, schema=None):
        """Spawn a text generation task and return the thread ID immediately"""
        if schema:
            schema_json = json.dumps(schema)
            code = f"""window.geminiHub.spawnText({json.dumps(model)}, {json.dumps(prompt)}, {schema_json})"""
        else:
            code = f"""window.geminiHub.spawnText({json.dumps(model)}, {json.dumps(prompt)})"""
        thread_id = await self._eval(code, timeout=10)
        print(f"[SPAWN TEXT] Created thread: {thread_id} for: {prompt[:30]}...")
        return thread_id
    
    async def wait_for(self, thread_id: str):
        """Wait for a thread to complete and get the result"""
        code = f"""(async () => {{
            try {{
                return await window.geminiHub.waitFor({json.dumps(thread_id)});
            }} catch (e) {{
                return {{ error: e.message }};
            }}
        }})()"""
        return await self._eval(code, timeout=600)
    
    async def get_models(self):
        """Get available model IDs from geminiHub"""
        code = """JSON.stringify(window.geminiHub.models)"""
        result = await self._eval(code, timeout=10)
        print(f"[MODELS] Available: {result}")
        return result
    
    async def image(self, prompt: str, aspect_ratio: str = "1:1", reference_images=None):
        """Generate an image using spawnImage + waitFor"""
        print(f"[IMAGE] Starting generation: {prompt[:50]}...")
        print(f"[IMAGE] Reference images provided: {reference_images is not None}")
        
        # Check if spawnImage supports refs - let's see its signature
        sig_check = """window.geminiHub.spawnImage.toString().substring(0, 300)"""
        sig = await self._eval(sig_check, timeout=5)
        print(f"[IMAGE] spawnImage signature: {sig}")
        
        # Build spawn code with reference image if provided
        if reference_images is None:
            spawn_code = f"""window.geminiHub.spawnImage({json.dumps(prompt)}, {json.dumps(aspect_ratio)})"""
        elif isinstance(reference_images, str):
            print(f"[IMAGE] Passing single ref image (length: {len(reference_images)})")
            spawn_code = f"""window.geminiHub.spawnImage({json.dumps(prompt)}, {json.dumps(aspect_ratio)}, {json.dumps(reference_images)})"""
        else:
            print(f"[IMAGE] Passing {len(reference_images)} ref images, using first one")
            spawn_code = f"""window.geminiHub.spawnImage({json.dumps(prompt)}, {json.dumps(aspect_ratio)}, {json.dumps(reference_images[0])})"""
        
        print(f"[IMAGE] Spawn code length: {len(spawn_code)}")
        
        thread_id = await self._eval(spawn_code, timeout=10)
        print(f"[IMAGE] Spawned thread: {thread_id}")
        
        if not thread_id:
            return {"error": "Failed to spawn image thread"}
        
        # Activate iframe after first image generation (wait 3s then click)
        if not self.first_image_generated:
            print("[IMAGE] First image spawned - activating iframe in 3 seconds...")
            await asyncio.sleep(3)
            await self.click_iframe_to_activate()
            self.first_image_generated = True
        
        # Wait for result using waitFor with timeout handling
        wait_code = f"""(async () => {{
            try {{
                return await window.geminiHub.waitFor({json.dumps(thread_id)});
            }} catch (e) {{
                return {{ error: e.message }};
            }}
        }})()"""
        
        # Poll with 60s timeout and activation fallback
        print("[IMAGE] Polling for result (60s timeout)...")
        start_time = asyncio.get_event_loop().time()
        timeout_duration = 60
        
        try:
            result = await asyncio.wait_for(
                self._eval(wait_code, timeout=120),
                timeout=timeout_duration
            )
        except asyncio.TimeoutError:
            print("[IMAGE] Polling timed out after 60s - activating iframe...")
            # Apply activation methods
            await self.click_iframe_to_activate()
            await asyncio.sleep(0.5)
            await self.focus_iframe()
            
            # Try polling again with extended timeout
            print("[IMAGE] Retrying poll after activation...")
            try:
                result = await asyncio.wait_for(
                    self._eval(wait_code, timeout=120),
                    timeout=60
                )
            except asyncio.TimeoutError:
                print("[IMAGE] Polling timed out again after activation")
                return {"error": "Image generation timed out after 120s total"}
        
        if isinstance(result, str) and result.startswith("data:image"):
            print(f"[IMAGE] Got image, length: {len(result)}")
            return result
        elif isinstance(result, dict) and "error" in result:
            print(f"[IMAGE] Error: {result['error']}")
            return result
        else:
            print(f"[IMAGE] Unexpected result: {type(result)}")
            return {"error": "Unexpected response from image generation"}
    
    async def spawn_image(self, prompt: str, aspect_ratio: str = "1:1"):
        """Spawn an image generation task and return the thread ID immediately"""
        code = f"""window.geminiHub.spawnImage({json.dumps(prompt)}, {json.dumps(aspect_ratio)})"""
        thread_id = await self._eval(code, timeout=10)
        print(f"[SPAWN] Created thread: {thread_id} for: {prompt[:30]}...")
        return thread_id
    
    async def get_thread(self, thread_id: str):
        """Get the status and result of a thread"""
        code = f"""(() => {{
            const thread = window.geminiHub.getThread({json.dumps(thread_id)});
            if (!thread) return {{ status: 'NOT_FOUND' }};
            return {{
                status: thread.status,
                error: thread.error || null,
                hasResult: !!thread.result,
                resultPreview: thread.result ? thread.result.substring(0, 30) : null
            }};
        }})()"""
        return await self._eval(code, timeout=10)
    
    async def get_thread_result(self, thread_id: str):
        """Get the full result of a completed thread"""
        code = f"""window.geminiHub.getThread({json.dumps(thread_id)}).result"""
        return await self._eval(code, timeout=60)
    
    async def get_thread_partial(self, thread_id: str):
        """Get partial/current result of a thread (for streaming display)"""
        code = f"""(() => {{
            const thread = window.geminiHub.getThread({json.dumps(thread_id)});
            if (!thread) return {{ status: 'NOT_FOUND', text: '' }};
            return {{
                status: thread.status,
                text: thread.result || thread.partialResult || '',
                error: thread.error || null
            }};
        }})()"""
        return await self._eval(code, timeout=10)
    
    async def ask_streaming(self, model: str, prompt: str, schema=None, on_update=None):
        """Ask with streaming updates - calls on_update callback with partial results"""
        # Spawn the text generation
        thread_id = await self.spawn_text(model, prompt, schema)
        
        if not thread_id:
            return {"error": "Failed to spawn text thread"}
        
        print(f"[STREAM] Started thread: {thread_id}")
        
        last_text = ""
        max_polls = 2000  # 2000 * 0.3s = 600s max
        
        for i in range(max_polls):
            await asyncio.sleep(0.3)  # Poll every 300ms
            
            result = await self.get_thread_partial(thread_id)
            
            if result is None:
                continue
            
            if isinstance(result, dict):
                status = result.get("status", "")
                current_text = result.get("text", "")
                error = result.get("error")
                
                # Call update callback if text changed
                if current_text and current_text != last_text:
                    last_text = current_text
                    if on_update:
                        on_update(current_text, False)  # False = not complete
                    print(f"[STREAM] Update: {len(current_text)} chars")
                
                if status == "COMPLETED":
                    print(f"[STREAM] Completed with {len(current_text)} chars")
                    if on_update:
                        on_update(current_text, True)  # True = complete
                    return current_text
                
                elif status == "FAILED":
                    print(f"[STREAM] Failed: {error}")
                    return {"error": error or "Generation failed"}
            
            # Log progress every 10 polls
            if (i + 1) % 10 == 0:
                print(f"[STREAM] Polling... ({i+1}/{max_polls})")
        
        # Timeout
        return {"error": "Streaming timeout after 600s"}
    
    async def batch_images(self, prompts: list, aspect_ratio: str = "1:1"):
        """Generate multiple images concurrently using thread spawning"""
        print(f"[BATCH] Starting {len(prompts)} image generations...")
        
        # Spawn all tasks
        thread_ids = []
        for prompt in prompts:
            thread_id = await self.spawn_image(prompt.strip(), aspect_ratio)
            thread_ids.append((thread_id, prompt.strip()))
            await asyncio.sleep(0.5)  # Small delay between spawns
        
        print(f"[BATCH] All threads spawned: {[t[0] for t in thread_ids]}")
        
        # Poll for completion
        results = {}
        pending = set(t[0] for t in thread_ids)
        
        for attempt in range(120):  # Max 4 minutes
            await asyncio.sleep(2)
            
            for thread_id, prompt in thread_ids:
                if thread_id not in pending:
                    continue
                
                status = await self.get_thread(thread_id)
                
                if status.get("status") == "COMPLETED":
                    print(f"[BATCH] Thread {thread_id} completed!")
                    result = await self.get_thread_result(thread_id)
                    results[thread_id] = {"prompt": prompt, "result": result, "status": "COMPLETED"}
                    pending.discard(thread_id)
                    
                elif status.get("status") == "FAILED":
                    print(f"[BATCH] Thread {thread_id} failed: {status.get('error')}")
                    results[thread_id] = {"prompt": prompt, "error": status.get("error"), "status": "FAILED"}
                    pending.discard(thread_id)
            
            if not pending:
                print(f"[BATCH] All {len(prompts)} images completed!")
                break
            
            if (attempt + 1) % 5 == 0:
                print(f"[BATCH] Still waiting for {len(pending)} threads... (attempt {attempt+1}/120)")
        
        # Handle any still pending
        for thread_id, prompt in thread_ids:
            if thread_id in pending:
                results[thread_id] = {"prompt": prompt, "error": "Timed out", "status": "TIMEOUT"}
        
        return [results.get(t[0]) for t in thread_ids]
    
    async def batch(self, prompts: List[str], model: str = "flash3"):
        """Process multiple prompts"""
        results = []
        method = getattr(self, model)
        
        for i, prompt in enumerate(prompts, 1):
            print(f"[{i}/{len(prompts)}] {prompt[:50]}...")
            result = await method(prompt)
            results.append(result)
            
            if isinstance(result, str):
                print(f"    ✓ {result[:100]}...\n")
            else:
                print(f"    ✓ {result}\n")
        
        return results
    
    async def close(self):
        if self.ws:
            await self.ws.close()


# ============= DEMO =============

async def main():
    hub = GeminiHub()
    
    try:
        await hub.connect()
        
        print("="*60)
        print("TEST 1: Single Query")
        print("="*60)
        result = await hub.flash3("What is 2+2?")
        print(f"Result: {result}\n")
        
        print("="*60)
        print("TEST 2: Batch Processing")
        print("="*60)
        prompts = [
            "Say hello",
            "What is Python?",
            "Tell me a joke"
        ]
        results = await hub.batch(prompts, model="flash3")
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        await hub.close()


if __name__ == "__main__":
    print("\n🚀 Gemini Hub Controller\n")
    asyncio.run(main())
