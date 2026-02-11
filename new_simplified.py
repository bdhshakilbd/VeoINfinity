# character_studio_full.py
import os
import re
import json
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, simpledialog
from PIL import Image, ImageTk, ImageDraw, ImageFont
from datetime import datetime
import time
import urllib.request
import subprocess
import sys

# Selenium ChromeDriver
try:
    from selenium import webdriver
    from selenium.webdriver.chrome.service import Service
    from selenium.webdriver.chrome.options import Options as ChromeOptions
    from selenium.webdriver.common.by import By
    from selenium.webdriver.common.keys import Keys
    from selenium.webdriver.common.action_chains import ActionChains
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.common.desired_capabilities import DesiredCapabilities
    
    # Add thread lock for concurrent webdriver initialization
    import threading
    _chrome_init_lock = threading.Lock()
    selenium_available = True
except ImportError:
    webdriver = None
    selenium_available = False
    _chrome_init_lock = None

# Image download module (Disabled - download_images.py missing)
download_module_available = False
# Fast Generation Hub (WebSocket-based)
try:
    import asyncio
    import base64
    import websockets
    import aiohttp
    
    class GeminiHub:
        """Direct connection to both the blob iframe (for API) and main page (for interactions).
           FULLY SELF-CONTAINED: Includes all methods for text/image generation and interaction.
        """
        def __init__(self):
            self.ws = None
            self.msg_id = 0
            self.responses = {}
            self.main_ws = None
            self.main_msg_id = 0
            self.main_responses = {} # NEW: Tracker for top page responses
            self.first_image_generated = False
            
        async def focus_chrome(self, profile_name=None):
            """Brings the Google AI Studio window to the front to ensure focus for interactions"""
            try:
                # Try specific profile title if provided, otherwise generic
                win_title = f"Google AI Studio"
                ps_cmd = f'(New-Object -ComObject WScript.Shell).AppActivate("{win_title}")'
                subprocess.run(['powershell', '-command', ps_cmd], capture_output=True)
                await asyncio.sleep(0.5)
                return True
            except:
                return False

        async def connect(self, port=9222):
            """Connect to both the blob iframe and the main AI Studio page"""
            await self.focus_chrome()
            async with aiohttp.ClientSession() as session:
                async with session.get(f"http://localhost:{port}/json") as resp:
                    targets = await resp.json()
                    
                    blob_ws_url = None
                    main_ws_url = None
                    for t in targets:
                        url = t.get('url', '')
                        if 'blob:' in url:
                            blob_ws_url = t['webSocketDebuggerUrl']
                        elif 'aistudio.google.com' in url and t.get('type') == 'page':
                            main_ws_url = t['webSocketDebuggerUrl']
                    
                    if not blob_ws_url:
                        raise Exception(f"Port {port}: Blob frame not found!")
            
            # Connect to blob frame with relaxed ping settings to prevent disconnects during heavy load
            self.ws = await websockets.connect(blob_ws_url, max_size=16 * 1024 * 1024, ping_interval=None)
            asyncio.create_task(self._listen())
            await self._cmd("Runtime.enable")
            
            # Force the page to the front in Chrome's internal scheduler
            await self._cmd("Page.bringToFront")
            
            # Connect to main page with relaxed ping settings
            if main_ws_url:
                self.main_ws = await websockets.connect(main_ws_url, max_size=16 * 1024 * 1024, ping_interval=None)
                asyncio.create_task(self._listen_main())
                await self._cmd_main("Runtime.enable")
                

                
                # Force the page to active state
                await self._cmd("Page.bringToFront")
                
                # NEW: Set Zoom to 30% for better visibility in small windows
                await self._cmd_main("Runtime.evaluate", {"expression": "document.body.style.zoom = '30%'", "returnByValue": True})
                
                # Force the page to active state
                await self._cmd("Page.bringToFront")
                
                # REVERT: Zoom back to 100% to fix click coordinate mismatch
                await self._cmd_main("Runtime.evaluate", {"expression": "document.body.style.zoom = '100%'", "returnByValue": True})
                
                # NEW: Aggressive check for "Untrusted App" or "Launch!" modals
                for _ in range(3): # Try a few times as page loads
                    await self._check_modal_blocking()
                    await asyncio.sleep(1)
                # NEW: Initial check for "Untrusted App" or "Launch!" modals
                await asyncio.sleep(2) 
                await self._check_modal_blocking()
        
        async def close(self):
            """Close all WebSocket connections"""
            if self.ws: await self.ws.close()
            if self.main_ws: await self.main_ws.close()
            
        async def _cmd(self, method: str, params: dict = None):
            """Send CDP command to blob frame"""
            self.msg_id += 1
            msg = {"id": self.msg_id, "method": method, "params": params or {}}
            future = asyncio.Future()
            self.responses[self.msg_id] = future
            await self.ws.send(json.dumps(msg))
            return await future

        async def _cmd_main(self, method: str, params: dict = None):
            """Send CDP command to main page (Fire and Forget)"""
            if not self.main_ws: return None
            self.main_msg_id += 1
            msg = {"id": self.main_msg_id, "method": method, "params": params or {}}
            await self.main_ws.send(json.dumps(msg))
            return self.main_msg_id

        async def _cmd_main_await(self, method: str, params: dict = None, timeout: int = 10):
            """Send CDP command to main page and WAIT for response"""
            if not self.main_ws: return None
            self.main_msg_id += 1
            msg = {"id": self.main_msg_id, "method": method, "params": params or {}}
            future = asyncio.Future()
            self.main_responses[self.main_msg_id] = future
            await self.main_ws.send(json.dumps(msg))
            try:
                return await asyncio.wait_for(future, timeout=timeout)
            except:
                return None
        
        async def _listen(self):
            """Listen for responses from blob frame"""
            try:
                async for msg in self.ws:
                    data = json.loads(msg)
                    if 'id' in data and data['id'] in self.responses:
                        future = self.responses.pop(data['id'])
                        if not future.done():
                            future.set_result(data)
            except:
                pass

        async def _listen_main(self):
            """Listen for responses from main/top page"""
            try:
                async for msg in self.main_ws:
                    data = json.loads(msg)
                    if 'id' in data and data['id'] in self.main_responses:
                        future = self.main_responses.pop(data['id'])
                        if not future.done():
                            future.set_result(data)
            except:
                pass
        
        async def _eval(self, code: str, timeout: int = 60):
            """Robust JS evaluation with automatic modal bypass"""
            cmd_coro = self._cmd("Runtime.evaluate", {"expression": code, "awaitPromise": True, "returnByValue": True})
            task = asyncio.create_task(cmd_coro)
            
            try:
                # Step 1: Wait 3s
                resp = await asyncio.wait_for(asyncio.shield(task), timeout=3)
            except asyncio.TimeoutError:
                # Step 2: Clear Modal if it appeared
                await self._check_modal_blocking()
                # Step 3: Re-wait for the SAME task
                try:
                    resp = await asyncio.wait_for(task, timeout=max(1, timeout-3))
                except asyncio.TimeoutError:
                    return {"error": f"Operation timed out after {timeout} seconds"}
            
            if 'result' in resp:
                result = resp['result']
                if 'exceptionDetails' in result:
                    return {"error": result['exceptionDetails'].get('text', 'Unknown error')}
                if 'result' in result:
                    result_obj = result['result']
                    return result_obj.get('value')
            return None

        async def _eval_main_page(self, expression: str, timeout: int = 30):
            """Evaluate JavaScript on the main AI Studio page using listener"""
            if not self.main_ws: return None
            try:
                self.main_msg_id += 1
                msg = {"id": self.main_msg_id, "method": "Runtime.evaluate", 
                       "params": {"expression": expression, "returnByValue": True, "awaitPromise": True}}
                future = asyncio.Future()
                self.main_responses[self.main_msg_id] = future
                await self.main_ws.send(json.dumps(msg))
                
                response = await asyncio.wait_for(future, timeout=timeout)
                return response.get("result", {}).get("result", {}).get("value")
            except:
                return None

        async def _click_modal_humanly_cdp(self, rect):
            """Targeted modal click: Direct JS first -> then simple Mouse fallback"""
            cx, cy = rect['x'] + rect['width']/2, rect['y'] + rect['height']/2
            
            # 1. New: Try Direct JS Click (Most reliable for Material buttons)
            js_force_click = f"""
                (() => {{
                   let el = document.elementFromPoint({cx}, {cy});
                   if(el) el.click();
                }})()
            """
            await self._cmd_main("Runtime.evaluate", {"expression": js_force_click})
            
            # 2. Mouse Click Fallback (Standard Press/Release)
            await self._cmd_main("Input.dispatchMouseEvent", {"type": "mousePressed", "x": cx, "y": cy, "button": "left", "clickCount": 1})
            await asyncio.sleep(0.1)
            await self._cmd_main("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": cx, "y": cy, "button": "left", "clickCount": 1})
            await asyncio.sleep(0.5)
            
            # 3. Restore Full "Human Sequence" (Touch/Drag/Click Loop) for stubborn "Launch!" modals
            # The user specifically requested this back for the post-API request modal
            for i in range(10): # Run a few times to force it
                # Touch
                await self._cmd_main("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": cx, "y": cy}]})
                await self._cmd_main("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
                # Drag
                await self._cmd_main("Input.dispatchMouseEvent", {"type": "mousePressed", "x": cx, "y": cy, "button": "left"})
                await self._cmd_main("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": cx + 5, "y": cy + 5, "button": "left"})
                await self._cmd_main("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": cx + 5, "y": cy + 5, "button": "left"})
                await asyncio.sleep(0.2)

        async def _check_modal_blocking(self):
            """Check and clear 'Launch!' or 'Untrusted App' modals on Top level"""
            if not self.main_ws: return
            
            # Use the EXACT logic from the backup for the interaction-modal
            # merged with the untrusted-dialog check
            check_js = """(() => {
                // 1. Check for "Untrusted App" dialog
                let d = document.querySelector('#untrusted-dialog');
                if (d && d.offsetParent !== null) {
                    let btn = d.querySelector('button.ms-button-primary');
                    if (btn) {
                        const r = btn.getBoundingClientRect();
                        return {found: true, x: r.left, y: r.top, width: r.width, height: r.height, type: 'untrusted'};
                    }
                }

                // 2. Check for standard 'Launch!' interaction modal (Original Backup Logic)
                const m = document.querySelector('.interaction-modal');
                if (m && m.offsetParent !== null) {
                    const r = m.getBoundingClientRect();
                    // Original code used x/y, not left/top (though they are usually same)
                    return {found: true, x: r.x, y: r.y, width: r.width, height: r.height, type: 'launch'};
                }
                return {found: false};
            })()"""
            
            res = await self._eval_main_page(check_js, timeout=2)
            if res and res.get('found'):
                await self._click_modal_humanly_cdp(res)

        # --- High Level Interaction API ---
        async def click_iframe_to_activate(self):
            click_code = "(() => { const f = document.querySelector('iframe[title=\"Preview\"]'); if(f){f.click(); return 'Iframe clicked';} return 'Not found'; })()"
            return await self._eval_main_page(click_code, timeout=5)

        async def focus_iframe(self):
            focus_code = "(() => { const f = document.querySelector('iframe[title=\"Preview\"]'); if(f){f.focus(); if(f.contentWindow)f.contentWindow.focus(); return 'Iframe focused';} return 'Not found'; })()"
            return await self._eval_main_page(focus_code, timeout=5)

        # --- Gemini Hub Generation methods ---
        async def ask(self, model: str, prompt: str, schema=None):
            schema_arg = f", {json.dumps(schema)}" if schema else ""
            code = f"(async () => {{ try {{ return await window.geminiHub.ask(window.geminiHub.models.{model}, {json.dumps(prompt)}{schema_arg}); }} catch(e) {{ return {{error: e.message}}; }} }})()"
            return await self._eval(code, timeout=120)

        async def flash3(self, prompt: str): return await self.ask("GEMINI_2_0_FLASH", prompt)
        async def flash25(self, prompt: str): return await self.ask("GEMINI_1_5_FLASH", prompt)
        async def pro3(self, prompt: str): return await self.ask("GEMINI_2_0_PRO", prompt)
        async def pro25(self, prompt: str): return await self.ask("GEMINI_1_5_PRO", prompt)

        async def spawn_image(self, prompt: str, aspect_ratio: str = "1:1", ref_images=None, model=None):
            model_arg = f", {model}" if model else ""
            ref_arg = f", {json.dumps(ref_images)}" if ref_images else ", undefined"
            code = f"window.geminiHub.spawnImage({json.dumps(prompt)}, {json.dumps(aspect_ratio)}{ref_arg}{model_arg})"
            return await self._eval(code, timeout=15)

        async def get_thread(self, thread_id: str):
            code = f"""(() => {{
                try {{
                    const t = window.geminiHub.getThread('{thread_id}');
                    if (!t) return {{ status: 'NOT_FOUND' }};
                    return {{ status: t.status, error: t.error || null, result: t.status === 'COMPLETED' ? t.result : null }};
                }} catch(e) {{ return {{ status: 'ERROR', error: e.message }}; }}
            }})()"""
            return await self._eval(code, timeout=10)

        async def waitFor(self, thread_id: str):
            code = f"(async () => {{ try {{ return await window.geminiHub.waitFor('{thread_id}'); }} catch(e) {{ return {{error: e.message}}; }} }})()"
            return await self._eval(code, timeout=120)

        async def get_models(self):
            return await self._eval("window.geminiHub.models", timeout=5)

        async def set_browser_window_rect(self, x, y, width, height):
            """Forcefully set the Chrome window size and position via CDP"""
            if not self.main_ws: return
            try:
                # 1. Get window ID for the current target
                win = await self._cmd_main_await("Browser.getWindowForTarget")
                if win and 'windowId' in win.get('result', {}):
                    window_id = win['result']['windowId']
                    # 2. Set bounds
                    await self._cmd_main("Browser.setWindowBounds", {
                        "windowId": window_id,
                        "bounds": {
                            "left": x,
                            "top": y,
                            "width": width,
                            "height": height,
                            "windowState": "normal"
                        }
                    })
                    return True
            except:
                pass
            return False
    
    class GeminiHubWithPort(GeminiHub):
        """GeminiHub that connects to a specific debug port"""
        def __init__(self, port=9222):
            super().__init__()
            self.port = port
            
        async def connect(self):
            """Connect using specific port override"""
            await super().connect(self.port)
    
    cdp_available = True
except ImportError:
    cdp_available = False
    asyncio = None
    base64 = None
    GeminiHub = None
    GeminiHubWithPort = None

# ---------- MAC Authentication Functions ----------
def fetch_whitelist_mac_prefixes(url):
    try:
        response = urllib.request.urlopen(url)
        content = response.read().decode('utf-8')
        mac_prefixes = []
        for line in content.strip().splitlines():
            match = re.match(r'([0-9A-Fa-f\-:]{17})', line)
            if match:
                mac = match.group(1).replace(":", "-").upper()
                mac_prefix = "-".join(mac.split("-")[:5])
                mac_prefixes.append(mac_prefix)
        return set(mac_prefixes)
    except Exception as e:
        messagebox.showerror("Error", f"Failed to download MAC whitelist: {e}")
        sys.exit(1)

def get_mac_prefixes_from_pc():
    try:
        output = subprocess.check_output("getmac", shell=True).decode('utf-8')
        macs = re.findall(r'([0-9A-Fa-f\-]{17})', output)
        return set(["-".join(mac.upper().split("-")[:5]) for mac in macs])
    except Exception as e:
        messagebox.showerror("Error", f"Failed to get MAC addresses: {e}")
        sys.exit(1)

def verify_mac_access():
    """Verify if this PC's MAC prefixes are in the whitelist"""
    whitelist_url = "https://www.dropbox.com/scl/fi/0p49tkocabpv3gnaaji8r/nanobanana-imageAutomation.txt?rlkey=ifh9ucmrdqhdklt8oxv8njvyf&st=dt4rb9cu&dl=1"
    
    try:
        whitelist = fetch_whitelist_mac_prefixes(whitelist_url)
        local_macs = get_mac_prefixes_from_pc()
        
        if not any(mac in whitelist for mac in local_macs):
            messagebox.showwarning("Unauthorized", "⚠️ This PC is not registered. Contact support.")
            sys.exit(1)
            
        print("✅ MAC address verified successfully.")
        return True
        
    except Exception as e:
        messagebox.showerror("Error", f"MAC verification failed: {e}")
        sys.exit(1)

# ---------- Config ----------
APP_TITLE = "Character Studio — Full"
CHAR_DIR = "characters"
THUMB_SIZE = (96, 96)
AI_STUDIO_URL = "https://aistudio.google.com/prompts/new_chat?model=gemini-2.5-flash-image"
#https://aistudio.google.com/prompts/new_chat?model=gemini-2.5-flash-image
IMAGEN_BASE_URL = "https://aistudio.google.com/prompts/new_image?model="
PROFILE_CONFIG = "chrome_profile_config.json"
IMAGE_MODELS_CONFIG = "image_models_config.json"
DEFAULT_PROFILE_DIR = os.path.join(os.getcwd(), "Chrome_Batch")
os.makedirs(CHAR_DIR, exist_ok=True)

# ---------- Utility: Scrollable Frame ----------
class ScrollableFrame(ttk.Frame):
    def __init__(self, parent, *args, **kwargs):
        super().__init__(parent, **kwargs)
        canvas = tk.Canvas(self, highlightthickness=0)
        vscroll = ttk.Scrollbar(self, orient="vertical", command=canvas.yview)
        self.inner = ttk.Frame(canvas)
        self._win = canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self.inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.configure(yscrollcommand=vscroll.set)
        canvas.pack(side="left", fill="both", expand=True)
        vscroll.pack(side="right", fill="y")
        self.canvas = canvas
        self.bind("<Configure>", self._on_resize)

    def _on_resize(self, event):
        self.canvas.itemconfig(self._win, width=event.width)

# ---------- ToolTip Class ----------
class ToolTip(object):
    def __init__(self, widget, text='widget info'):
        self.widget = widget
        self.text = text
        self.tip_window = None
        self.id = None
        self.x = self.y = 0
        self._id = None
        self.widget.bind('<Enter>', self.show_tip)
        self.widget.bind('<Leave>', self.hide_tip)

    def show_tip(self, event=None):
        """Display text in tooltip window"""
        if self.tip_window or not self.text:
            return
        x, y, _, _ = self.widget.bbox('insert')
        x = x + self.widget.winfo_rootx() + 25
        y = y + self.widget.winfo_rooty() + 25
        
        self.tip_window = tw = tk.Toplevel(self.widget)
        tw.wm_overrideredirect(True)
        tw.wm_geometry(f"+{x}+{y}")
        
        label = ttk.Label(tw, text=self.text, justify='left',
                         background='#ffffe0', relief='solid', borderwidth=1,
                         font=('TkDefaultFont', '8', 'normal'))
        label.pack(ipadx=1)

    def hide_tip(self, event=None):
        """Hide the tooltip"""
        tw = self.tip_window
        self.tip_window = None
        if tw:
            tw.destroy()

# ---------- Main App ----------
class CharacterStudioApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("1000x600")
        self.minsize(900, 520)

        self.json_path = None
        self.data = {}
        self.characters = []  # dicts: id,name,key_path,images
        self.char_widgets = {}
        self.modified_prompts = {}
        self.profile_dir = DEFAULT_PROFILE_DIR
        self.load_profile_config()
        
        # Image models configuration
        self.image_models = self.load_image_models()
        self.selected_image_model = None
        
        # Smart batch processing state
        self.smart_batch_running = False
        self.smart_batch_thread = None
        self.current_uploaded_chars = set()  # Track uploaded characters in current tab
        
        # Initialize progress log variables BEFORE UI building
        self.show_progress = tk.BooleanVar(value=True)
        
        # Prompt history toggle (include previous 5 prompts in context)
        self.include_history_var = tk.BooleanVar(value=True)
        
        # Initialize WebDriver tracking
        self.active_webdrivers = {}  # Store active WebDriver instances
        self.webdriver_tabs = {}     # Store tab information for each driver
        # Map each browser tab handle -> scene number for correct naming
        self.tab_scene_number_map = {}
        
        # CDP (Chrome DevTools Protocol) Image Generation state
        self.cdp_hubs = {}  # Dict: profile_name -> (port, GeminiHub instance)
        self.cdp_base_port = 9222  # Starting port for remote debugging
        self.cdp_running = False  # Track if CDP batch is running
        self.cdp_output_folder = os.path.join(os.getcwd(), "Generated_Images")
        os.makedirs(self.cdp_output_folder, exist_ok=True)
        
        self.after(0, self.update_browser_status)
        
        self.protocol("WM_DELETE_WINDOW", self.on_closing)
        self._build_ui()

    # ---------- UI ----------
    def _build_ui(self):
        style = ttk.Style(self)
        style.configure("Card.TFrame", relief="groove", padding=6)
        style.configure("TButton", padding=6)
        style.configure('TFrame', background=self.cget('bg'))
        style.configure('Highlighted.TFrame', background='#e6f3ff')  # Light blue background for highlighted frames
        style.configure('Header.TLabel', font=('TkDefaultFont', 9, 'bold'))
        style.configure('Status.TLabel', font=('TkDefaultFont', 8))
        style.configure('Section.TLabelframe.Label', font=('TkDefaultFont', 9, 'bold'))

        # Top toolbar container
        toolbar_container = ttk.Frame(self)
        toolbar_container.pack(side="top", fill="x", padx=8, pady=6)
        
        # ═══════════════════════════════════════════════════════════════
        # TOP ROW: Common controls (File, Model, Profile)
        # ═══════════════════════════════════════════════════════════════
        top_row = ttk.Frame(toolbar_container)
        top_row.pack(side="top", fill="x", pady=(0, 6))
        
        # Left side: File operations
        file_frame = ttk.Frame(top_row)
        file_frame.pack(side="left")
        ttk.Button(file_frame, text="📂 Load JSON", command=self.load_json).pack(side="left", padx=(0, 4))
        ttk.Button(file_frame, text="💾 Save JSON", command=self.save_json_as).pack(side="left")
        
        ttk.Separator(top_row, orient="vertical").pack(side="left", fill="y", padx=12)
        
        # Center: Image Model selection
        model_frame = ttk.Frame(top_row)
        model_frame.pack(side="left")
        ttk.Label(model_frame, text="🎨 Image Model:").pack(side="left")
        self.image_model_var = tk.StringVar(value="None")
        self.image_model_combo = ttk.Combobox(model_frame, textvariable=self.image_model_var, state="readonly", width=22)
        self.image_model_combo.pack(side="left", padx=(4, 2))
        self.image_model_combo.bind("<<ComboboxSelected>>", self.on_image_model_change)
        self.populate_image_models()
        ttk.Button(model_frame, text="Open", command=self.open_image_model).pack(side="left", padx=(2, 2))
        ttk.Button(model_frame, text="+", width=3, command=self.add_new_image_model).pack(side="left")
        
        ttk.Separator(top_row, orient="vertical").pack(side="left", fill="y", padx=12)
        
        # Right side: Profile and Debug
        profile_frame = ttk.Frame(top_row)
        profile_frame.pack(side="left")
        ttk.Label(profile_frame, text="👤 Profile:").pack(side="left")
        self.profile_var = tk.StringVar(value=os.path.basename(self.profile_dir))
        self.profile_combo = ttk.Combobox(profile_frame, textvariable=self.profile_var, state="readonly", width=12)
        self.profile_combo.pack(side="left", padx=(4, 4))
        self.profile_combo.bind("<<ComboboxSelected>>", self.on_profile_change)
        self.populate_profiles()
        open_debug_btn = ttk.Button(profile_frame, text="🌐 Open Chrome", command=self.open_chrome_with_remote_debug)
        open_debug_btn.pack(side="left")
        ToolTip(open_debug_btn, "Launch Chrome with your selected profile")
        
        # ═══════════════════════════════════════════════════════════════
        # MAIN CONTROL PANEL: Two columns side by side
        # ═══════════════════════════════════════════════════════════════
        control_panel = ttk.Frame(toolbar_container)
        control_panel.pack(side="top", fill="x")
        control_panel.columnconfigure(0, weight=1)
        control_panel.columnconfigure(1, weight=1)
        
        # ─────────────────────────────────────────────────────────────
        # LEFT COLUMN: Browser Automation (Selenium)
        # ─────────────────────────────────────────────────────────────
        browser_frame = ttk.LabelFrame(control_panel, text="🌐 Browser Automation", padding=8)
        browser_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 4), pady=2)
        
        # Row 1: Range selection and Aspect
        range_row = ttk.Frame(browser_frame)
        range_row.pack(fill="x", pady=(0, 6))
        
        ttk.Label(range_row, text="📍 Range:").pack(side="left")
        ttk.Label(range_row, text="From:").pack(side="left", padx=(8, 2))
        self.from_prompt_var = tk.StringVar(value="1")
        self.from_prompt_entry = ttk.Entry(range_row, textvariable=self.from_prompt_var, width=5)
        self.from_prompt_entry.pack(side="left")
        ttk.Label(range_row, text="To:").pack(side="left", padx=(8, 2))
        self.to_prompt_var = tk.StringVar(value="1")
        self.to_prompt_entry = ttk.Entry(range_row, textvariable=self.to_prompt_var, width=5)
        self.to_prompt_entry.pack(side="left")
        
        ttk.Label(range_row, text="Aspect:").pack(side="left", padx=(12, 2))
        self.aspect_ratio_var = tk.StringVar(value="YouTube 16:9")
        self.aspect_ratio_combo = ttk.Combobox(
            range_row, textvariable=self.aspect_ratio_var, state="readonly", width=12,
            values=["YouTube 16:9", "Reels 9:16"]
        )
        self.aspect_ratio_combo.pack(side="left")
        
        # Row 2: Smart Batch controls
        batch_row = ttk.Frame(browser_frame)
        batch_row.pack(fill="x")
        
        self.history_checkbox = ttk.Checkbutton(batch_row, text="📜 History (prev 5)", variable=self.include_history_var)
        self.history_checkbox.pack(side="left", padx=(0, 8))
        
        ttk.Label(batch_row, text="Prompts/Tab:").pack(side="left", padx=(0, 2))
        self.prompts_per_tab_var = tk.StringVar(value="5")
        ttk.Entry(batch_row, textvariable=self.prompts_per_tab_var, width=4).pack(side="left", padx=(0, 6))
        
        self.smart_batch_btn = ttk.Button(batch_row, text="🚀 Smart Batch", command=self.toggle_smart_batch)
        self.smart_batch_btn.pack(side="left", padx=(0, 4))
        ttk.Button(batch_row, text="📁 Char Folder", command=self.open_char_folder).pack(side="left")
        
        # ─────────────────────────────────────────────────────────────
        # RIGHT COLUMN: Fast Generation (Multi-Browser)
        # ─────────────────────────────────────────────────────────────
        cdp_frame = ttk.LabelFrame(control_panel, text="⚡ Fastest Generation", padding=8)
        cdp_frame.grid(row=0, column=1, sticky="nsew", padx=(4, 0), pady=2)
        
        # Row 1: Browser control buttons and status
        status_row = ttk.Frame(cdp_frame)
        status_row.pack(fill="x", pady=(0, 6))
        
        self.cdp_status_var = tk.StringVar(value="● 0 Browsers")
        self.cdp_status_label = ttk.Label(status_row, textvariable=self.cdp_status_var, 
                                          style='Status.TLabel', foreground="gray")
        self.cdp_status_label.pack(side="left")
        
        ttk.Label(status_row, text="Profiles:").pack(side="left", padx=(8, 2))
        self.cdp_profiles_var = tk.StringVar(value="3")
        ttk.Entry(status_row, textvariable=self.cdp_profiles_var, width=3).pack(side="left", padx=(0, 4))
        
        ttk.Button(status_row, text="🌐 Open", command=self.open_all_chrome_profiles).pack(side="left", padx=(0, 4))
        ttk.Button(status_row, text="🔌 Connect", command=self.connect_all_browsers).pack(side="left")
        
        # Row 2: Batch and Retry settings
        settings_row = ttk.Frame(cdp_frame)
        settings_row.pack(fill="x", pady=(0, 6))
        
        ttk.Label(settings_row, text="Per Browser Batch Image:").pack(side="left")
        self.cdp_batch_size_var = tk.StringVar(value="2")
        cdp_batch_entry = ttk.Entry(settings_row, textvariable=self.cdp_batch_size_var, width=4)
        cdp_batch_entry.pack(side="left", padx=(2, 8))
        ToolTip(cdp_batch_entry, "Number of images to generate in parallel")
        
        ttk.Label(settings_row, text="Retries:").pack(side="left")
        self.cdp_retry_var = tk.StringVar(value="1")
        cdp_retry_entry = ttk.Entry(settings_row, textvariable=self.cdp_retry_var, width=4)
        cdp_retry_entry.pack(side="left", padx=(2, 8))
        ToolTip(cdp_retry_entry, "Number of retries on failure")
        
        ttk.Label(settings_row, text="Delay:").pack(side="left")
        self.cdp_delay_var = tk.StringVar(value="1")
        cdp_delay_entry = ttk.Entry(settings_row, textvariable=self.cdp_delay_var, width=4)
        cdp_delay_entry.pack(side="left", padx=(2, 8))
        ToolTip(cdp_delay_entry, "Delay in seconds between each request")
        
        ttk.Label(settings_row, text="Aspect:").pack(side="left")
        self.cdp_aspect_var = tk.StringVar(value="16:9")
        cdp_aspect_combo = ttk.Combobox(
            settings_row, textvariable=self.cdp_aspect_var, state="readonly", width=6,
            values=["1:1", "16:9", "9:16", "4:3", "3:4"]
        )
        cdp_aspect_combo.pack(side="left", padx=(2, 0))
        
        # Row 3: Generate and Output buttons
        action_row = ttk.Frame(cdp_frame)
        action_row.pack(fill="x")
        
        self.cdp_gen_btn = ttk.Button(action_row, text="⚡ Generate Range", command=self.start_cdp_image_generation)
        self.cdp_gen_btn.pack(side="left", padx=(0, 4))
        ToolTip(self.cdp_gen_btn, "Generate images at high speed")
        ttk.Button(action_row, text="📂 Open Output", command=self.open_cdp_output_folder).pack(side="left")

        # Main content area with 3 responsive columns
        main_frame = ttk.Frame(self)
        main_frame.pack(fill="both", expand=True, padx=8, pady=(0,8))
        main_frame.columnconfigure(0, weight=1)  # Column 1 - Progress Log (30%)
        main_frame.columnconfigure(1, weight=2)  # Column 2 - Scenes (40%)
        main_frame.columnconfigure(2, weight=1)  # Column 3 - Characters (30%)
        main_frame.rowconfigure(0, weight=1)

        # Column 1: Progress Log section (left column)
        self.progress_section = ttk.LabelFrame(main_frame, text="Automation Progress")
        self.progress_section.grid(row=0, column=0, sticky="nsew", padx=(0,4))
        self.progress_section.columnconfigure(0, weight=1)
        self.progress_section.rowconfigure(1, weight=1)
        
        # Progress controls at top
        progress_controls = ttk.Frame(self.progress_section)
        progress_controls.grid(row=0, column=0, sticky="ew", padx=4, pady=4)
        progress_controls.columnconfigure(1, weight=1)
        
        # Show/hide checkbox
        self.show_progress_checkbox = ttk.Checkbutton(
            progress_controls, 
            text="Show Log", 
            variable=self.show_progress, 
            command=self.toggle_progress_log
        )
        self.show_progress_checkbox.grid(row=0, column=0, sticky="w")
        
        # Clear button
        ttk.Button(
            progress_controls, 
            text="Clear", 
            command=self.clear_progress_log,
            width=8
        ).grid(row=0, column=2, sticky="e")
        
        # Progress text area with scrollbar
        progress_text_frame = ttk.Frame(self.progress_section)
        progress_text_frame.grid(row=1, column=0, sticky="nsew", padx=4, pady=(0,4))
        progress_text_frame.columnconfigure(0, weight=1)
        progress_text_frame.rowconfigure(0, weight=1)
        
        self.progress_text = tk.Text(
            progress_text_frame, 
            wrap="word", 
            font=('Consolas', 8),
            state="disabled",  # Read-only by default
            bg="#f8f8f8"
        )
        progress_scroll = ttk.Scrollbar(
            progress_text_frame, 
            orient="vertical", 
            command=self.progress_text.yview
        )
        self.progress_text.configure(yscrollcommand=progress_scroll.set)
        
        self.progress_text.grid(row=0, column=0, sticky="nsew")
        progress_scroll.grid(row=0, column=1, sticky="ns")
        
        # Initially show progress log
        self.show_progress.set(True)
        
        # WebDriver status area below progress log
        webdriver_section = ttk.LabelFrame(self.progress_section, text="WebDriver Status")
        webdriver_section.grid(row=2, column=0, sticky="nsew", padx=4, pady=4)
        webdriver_section.columnconfigure(0, weight=1)
        webdriver_section.rowconfigure(1, weight=1)
        
        # WebDriver controls
        webdriver_controls = ttk.Frame(webdriver_section)
        webdriver_controls.grid(row=0, column=0, sticky="ew", padx=4, pady=2)
        webdriver_controls.columnconfigure(1, weight=1)
        
        ttk.Button(
            webdriver_controls, 
            text="Download Images", 
            command=self.download_images_from_all_tabs,
            width=15
        ).grid(row=0, column=0, sticky="w")
        
        ttk.Button(
            webdriver_controls, 
            text="Refresh Status", 
            command=self.refresh_webdriver_status,
            width=12
        ).grid(row=0, column=2, sticky="e")
        
        # WebDriver status display
        webdriver_status_frame = ttk.Frame(webdriver_section)
        webdriver_status_frame.grid(row=1, column=0, sticky="nsew", padx=4, pady=(0,4))
        webdriver_status_frame.columnconfigure(0, weight=1)
        webdriver_status_frame.rowconfigure(0, weight=1)
        
        self.webdriver_status_text = tk.Text(
            webdriver_status_frame, 
            wrap="word", 
            font=('Consolas', 8),
            height=6,
            state="disabled",
            bg="#f0f0f0"
        )
        webdriver_status_scroll = ttk.Scrollbar(
            webdriver_status_frame, 
            orient="vertical", 
            command=self.webdriver_status_text.yview
        )
        self.webdriver_status_text.configure(yscrollcommand=webdriver_status_scroll.set)
        
        self.webdriver_status_text.grid(row=0, column=0, sticky="nsew")
        webdriver_status_scroll.grid(row=0, column=1, sticky="ns")
        
        # Initialize WebDriver tracking
        self.active_webdrivers = {}  # Store active WebDriver instances
        self.webdriver_tabs = {}     # Store tab information for each driver
        
        # Update WebDriver status initially
        self.refresh_webdriver_status()

        # Column 2: Scenes section (center column)
        scenes_section = ttk.LabelFrame(main_frame, text="Scenes")
        scenes_section.grid(row=0, column=1, sticky="nsew", padx=4)
        scenes_section.columnconfigure(0, weight=1)
        scenes_section.rowconfigure(1, weight=1)

        top_row = ttk.Frame(scenes_section)
        top_row.grid(row=0, column=0, sticky="ew", padx=6, pady=(6,4))
        ttk.Label(top_row, text="Scene:").pack(side="left")
        self.scene_var = tk.StringVar()
        self.scene_combo = ttk.Combobox(top_row, textvariable=self.scene_var, state="readonly", width=10)
        self.scene_combo.pack(side="left", padx=4)
        self.scene_combo.bind("<<ComboboxSelected>>", self.on_scene_change)
        ttk.Button(top_row, text="Detect Chars", command=self.detect_chars_in_prompt).pack(side="left", padx=2)
        ttk.Button(top_row, text="Copy", command=self.copy_prompt).pack(side="left", padx=2)

        self.prompt_text = tk.Text(scenes_section, wrap="word")
        self.prompt_text.grid(row=1, column=0, sticky="nsew", padx=6, pady=(0,6))

        bottom_row = ttk.Frame(scenes_section)
        bottom_row.grid(row=2, column=0, sticky="ew", padx=6, pady=(0,6))
        bottom_row.columnconfigure(1, weight=1)
        ttk.Button(bottom_row, text="Use Manual Prompt", command=self.use_manual_prompt).grid(row=0, column=0, sticky="w")
        self.char_detect_label = ttk.Label(bottom_row, text="", font=('TkDefaultFont', 8))
        self.char_detect_label.grid(row=0, column=1, sticky="e")

        # Column 3: Character Management section (right column)
        chars_section = ttk.LabelFrame(main_frame, text="Characters")
        chars_section.grid(row=0, column=2, sticky="nsew", padx=(4,0))
        chars_section.columnconfigure(0, weight=1)
        chars_section.rowconfigure(1, weight=1)
        
        # Bulk operations at top
        bulk_frame = ttk.Frame(chars_section)
        bulk_frame.grid(row=0, column=0, sticky="ew", padx=4, pady=4)
        bulk_frame.columnconfigure(1, weight=1)
        
        ttk.Button(bulk_frame, text="Clear All", command=self.clear_all_images).grid(row=0, column=0, padx=(0,2))
        ttk.Button(bulk_frame, text="Open Folder", command=self.open_char_folder).grid(row=0, column=2, padx=(2,0))
        
        # Enhanced scrollable character list with explicit scrollbar
        chars_scroll_container = ttk.Frame(chars_section)
        chars_scroll_container.grid(row=1, column=0, sticky="nsew", padx=4, pady=4)
        chars_scroll_container.columnconfigure(0, weight=1)
        chars_scroll_container.rowconfigure(0, weight=1)
        
        # Create canvas and scrollbar for character list
        self.chars_canvas = tk.Canvas(chars_scroll_container, highlightthickness=0, bg='white')
        self.chars_vscroll = ttk.Scrollbar(chars_scroll_container, orient="vertical", command=self.chars_canvas.yview)
        self.chars_inner_frame = ttk.Frame(self.chars_canvas)
        
        # Configure scrolling
        self.chars_canvas.configure(yscrollcommand=self.chars_vscroll.set)
        
        # Pack canvas and scrollbar
        self.chars_canvas.grid(row=0, column=0, sticky="nsew")
        self.chars_vscroll.grid(row=0, column=1, sticky="ns")
        
        # Create window in canvas
        self.chars_canvas_window = self.chars_canvas.create_window((0, 0), window=self.chars_inner_frame, anchor="nw")
        
        # Bind events for scrolling
        def configure_chars_scroll(event):
            self.chars_canvas.configure(scrollregion=self.chars_canvas.bbox("all"))
            # Update canvas window width to match canvas width
            canvas_width = self.chars_canvas.winfo_width()
            self.chars_canvas.itemconfig(self.chars_canvas_window, width=canvas_width)
        
        self.chars_inner_frame.bind("<Configure>", configure_chars_scroll)
        
        # Bind mouse wheel to canvas for scrolling
        def on_chars_mousewheel(event):
            self.chars_canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")
        
        self.chars_canvas.bind("<MouseWheel>", on_chars_mousewheel)
        
        # Set the container reference
        self.chars_container = self.chars_inner_frame
        
        # Status bar
        status_frame = ttk.Frame(self)
        status_frame.pack(side="bottom", fill="x")
        
        self.status_var = tk.StringVar(value="Ready")
        status = ttk.Label(status_frame, textvariable=self.status_var, relief="sunken", anchor="w")
        status.pack(side="left", fill="x", expand=True)
        
        # Current step indicator in status bar
        self.current_step_var = tk.StringVar(value="")
        self.step_label = ttk.Label(status_frame, textvariable=self.current_step_var, 
                                   font=('Arial', 8), foreground="blue", relief="sunken")
        self.step_label.pack(side="right", padx=(5, 0))

    # ---------- JSON ----------
    def load_json(self):
        path = filedialog.askopenfilename(
            title="Select story file",
            filetypes=[
                ("JSON files", "*.json"),
                ("Text files", "*.txt"),
                ("All files", "*.*"),
            ],
        )
        if not path:
            return
        try:
            ext = os.path.splitext(path)[1].lower()
            self.json_path = path

            # Handle plain text story: one prompt per non-empty line
            if ext == ".txt":
                with open(path, "r", encoding="utf-8") as f:
                    lines = [ln.strip() for ln in f.readlines()]
                prompts = [ln for ln in lines if ln]
                # Build normalized internal structure
                self.data = {
                    "output_structure": {
                        "scenes": [
                            {"scene_number": i + 1, "prompt": p} for i, p in enumerate(prompts)
                        ]
                    }
                }
                # No characters available in txt format
                self.characters.clear()
                self.char_widgets.clear()
                self.update_char_selector()
                self.populate_scenes()
                self.status_var.set(f"Loaded TXT: {os.path.basename(path)} ({len(prompts)} prompts)")
                return

            # Handle JSON story
            with open(path, "r", encoding="utf-8") as f:
                loaded = json.load(f)

            # If already in app-native structure, keep it
            if isinstance(loaded, dict) and isinstance(loaded.get("output_structure", {}).get("scenes", None), list):
                self.data = loaded
                if 'character_reference' in self.data and isinstance(self.data.get('character_reference'), list):
                    self.parse_dash_story_characters()
                else:
                    self.parse_characters()
            else:
                # Try to normalize arbitrary JSON formats into scenes
                scenes = self.normalize_to_scenes(loaded)
                if scenes:
                    self.data = {"output_structure": {"scenes": scenes}}
                    # No characters info in generic formats
                    self.characters.clear()
                    self.char_widgets.clear()
                    self.update_char_selector()
                else:
                    # Fallback: keep as-is and try character parsing
                    self.data = loaded
                    if 'character_reference' in self.data and isinstance(self.data.get('character_reference'), list):
                        self.parse_dash_story_characters()
                    else:
                        self.parse_characters()

            self.populate_scenes()
            self.status_var.set(f"Loaded: {os.path.basename(path)}")
        except Exception as e:
            messagebox.showerror(APP_TITLE, f"Failed to load file:\n{e}")
            
    def parse_dash_story_characters(self):
        """Parse characters from dash_story.json format"""
        self.characters.clear()
        self.char_widgets.clear()
        
        # Process character_reference array
        for char_data in self.data.get("character_reference", []):
            if not isinstance(char_data, dict) or "id" not in char_data:
                continue
                
            char_id = char_data["id"]
            char_name = char_data.get("name", char_id)
            
            self.characters.append({
                "id": char_id,
                "name": char_name,
                "key_path": ["character_reference", char_id],
                "images": []
            })
            
            # Auto-load images from folder if they exist
            self.auto_load_character_images(self.characters[-1])
        
        self.update_char_selector()

    def parse_characters(self):
        self.characters.clear()
        self.char_widgets.clear()
        cref = self.data.get("character_reference", {})
        main = cref.get("main_character")
        if isinstance(main, dict) and main.get("id"):
            char_data = {
                "id": main["id"],
                "name": main.get("name",""),
                "key_path": ("character_reference","main_character"),
                "images": list(main.get("images", []))
            }
            # Auto-load images from folder if they exist
            self.auto_load_character_images(char_data)
            self.characters.append(char_data)
            
        for idx,s in enumerate(cref.get("secondary_characters", []) or []):
            if isinstance(s, dict) and s.get("id"):
                char_data = {
                    "id": s["id"],
                    "name": s.get("name",""),
                    "key_path": ("character_reference","secondary_characters", idx),
                    "images": list(s.get("images", []))
                }
                # Auto-load images from folder if they exist
                self.auto_load_character_images(char_data)
                self.characters.append(char_data)
        
        # Update the character selector dropdown
        self.update_char_selector()

    def populate_scenes(self):
        is_dash_story = 'character_reference' in self.data and 'output_structure' in self.data
        
        if is_dash_story:
            # Handle dash_story.json format
            scenes = self.data.get("output_structure", {}).get("scenes", [])
            numbers = [str(s.get("scene_number", i+1)) for i, s in enumerate(scenes)]
        else:
            # Handle original format
            scenes = self.data.get("output_structure", {}).get("scenes", [])
            numbers = [str(s.get("scene_number", i+1)) for i, s in enumerate(scenes)]
        
        self.scene_combo["values"] = numbers
        if numbers:
            self.scene_combo.current(0)
            self.on_scene_change()
        else:
            self.prompt_text.delete("1.0","end")


    def optimize_image_for_size(self, img, target_kb=30, min_quality=50):
        """Fast image optimization - prioritize speed over perfect compression"""
        from io import BytesIO
        target_bytes = target_kb * 1024
        
        # Fast approach: Try only 2-3 size reductions with fewer quality tests
        size_reductions = [1.0, 0.8, 0.6]  # Only try 3 sizes instead of 7
        quality_levels = [85, 70, min_quality]  # Only try 3 quality levels
        
        for size_factor in size_reductions:
            if size_factor < 1.0:
                new_width = int(img.width * size_factor)
                new_height = int(img.height * size_factor)
                test_img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
            else:
                test_img = img
            
            for quality in quality_levels:
                # Try JPEG first as it's usually smaller and faster
                if test_img.mode in ('RGBA', 'LA'):
                    # Convert RGBA to RGB with white background for JPEG
                    jpg_img = Image.new('RGB', test_img.size, (255, 255, 255))
                    jpg_img.paste(test_img, mask=test_img.split()[-1] if test_img.mode == 'RGBA' else None)
                else:
                    jpg_img = test_img.convert('RGB')
                
                jpg_buffer = BytesIO()
                jpg_img.save(jpg_buffer, format='JPEG', quality=quality, optimize=True)
                jpg_size = len(jpg_buffer.getvalue())
                
                if jpg_size <= target_bytes:
                    return jpg_img, 'JPEG', quality
                
                # Only try PNG if JPEG failed and it's the original size
                if size_factor == 1.0:
                    png_buffer = BytesIO()
                    test_img.save(png_buffer, format='PNG', optimize=True)
                    png_size = len(png_buffer.getvalue())
                    
                    if png_size <= target_bytes:
                        return test_img, 'PNG', None
        
        # Return the most compressed version if nothing worked
        final_img = img.resize((int(img.width * 0.5), int(img.height * 0.5)), Image.Resampling.LANCZOS)
        if final_img.mode in ('RGBA', 'LA'):
            jpg_img = Image.new('RGB', final_img.size, (255, 255, 255))
            jpg_img.paste(final_img, mask=final_img.split()[-1] if final_img.mode == 'RGBA' else None)
        else:
            jpg_img = final_img.convert('RGB')
        
        return jpg_img, 'JPEG', min_quality
    
    def add_character_watermark(self, img, char_id):
        """Add character ID watermark to the bottom center of the image with large, bold text"""
        try:
            # Create a copy to avoid modifying the original
            watermarked_img = img.copy()
            
            # Get image dimensions
            width, height = watermarked_img.size
            
            # Create drawing context
            draw = ImageDraw.Draw(watermarked_img)
            
            # Calculate font size based on image size - MUCH LARGER for AI visibility
            # Minimum 24px, maximum 80px, and use 8% of height instead of 4%
            font_size = max(24, min(80, int(height * 0.08)))
            
            # Try to load a BOLD system font, fallback to regular then default
            try:
                # Try BOLD fonts first for better AI recognition
                bold_font_paths = [
                    "C:/Windows/Fonts/arialbd.ttf",      # Arial Bold
                    "C:/Windows/Fonts/calibrib.ttf",     # Calibri Bold  
                    "C:/Windows/Fonts/tahoma.ttf",       # Tahoma (bold-ish)
                    "C:/Windows/Fonts/arial.ttf",        # Arial regular
                    "C:/Windows/Fonts/calibri.ttf",      # Calibri regular
                    "/System/Library/Fonts/Arial Bold.ttf",  # macOS Bold
                    "/System/Library/Fonts/Arial.ttf",       # macOS regular
                    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"  # Linux Bold
                ]
                
                font = None
                for font_path in bold_font_paths:
                    if os.path.exists(font_path):
                        try:
                            font = ImageFont.truetype(font_path, font_size)
                            break
                        except:
                            continue
                
                if font is None:
                    font = ImageFont.load_default()
            except:
                font = ImageFont.load_default()
            
            # Get text dimensions - use UPPERCASE and add extra formatting
            text = char_id.upper().strip()
            
            # For older Pillow versions compatibility
            try:
                bbox = draw.textbbox((0, 0), text, font=font)
                text_width = bbox[2] - bbox[0]
                text_height = bbox[3] - bbox[1]
            except AttributeError:
                # Fallback for older Pillow versions
                text_width, text_height = draw.textsize(text, font=font)
            
            # Position text at bottom center with more margin
            x = (width - text_width) // 2
            y = height - text_height - 15  # 15px from bottom for larger text
            
            # Draw background rectangle with larger padding for better readability
            padding = 8  # Increased padding for larger text
            rect_coords = [
                x - padding,
                y - padding,
                x + text_width + padding,
                y + text_height + padding
            ]
            
            # Draw semi-transparent black background with higher opacity
            draw.rectangle(rect_coords, fill=(0, 0, 0, 200))  # Darker background
            
            # Draw bright white text for maximum contrast and AI visibility
            draw.text((x, y), text, fill=(255, 255, 255, 255), font=font)
            
            # Add a subtle outline/shadow effect for even better visibility
            try:
                # Draw text outline by drawing the text in black at offset positions
                outline_color = (0, 0, 0, 255)  # Black outline
                for adj in range(1, 2):  # 1px outline
                    # Draw outline in 8 directions
                    draw.text((x-adj, y), text, fill=outline_color, font=font)
                    draw.text((x+adj, y), text, fill=outline_color, font=font)
                    draw.text((x, y-adj), text, fill=outline_color, font=font)
                    draw.text((x, y+adj), text, fill=outline_color, font=font)
                    draw.text((x-adj, y-adj), text, fill=outline_color, font=font)
                    draw.text((x+adj, y-adj), text, fill=outline_color, font=font)
                    draw.text((x-adj, y+adj), text, fill=outline_color, font=font)
                    draw.text((x+adj, y+adj), text, fill=outline_color, font=font)
                
                # Redraw the main text on top in white
                draw.text((x, y), text, fill=(255, 255, 255, 255), font=font)
            except:
                # If outline fails, just use the white text
                pass
            
            return watermarked_img
            
        except Exception as e:
            print(f"Warning: Could not add watermark to image: {e}")
            return img  # Return original image if watermarking fails
    
    def _import_images_thread(self, ch, files, callback):
        """Thread function to process and save images with real-time GUI feedback"""
        import time
        start_time = time.time()
        
        try:
            # Show initial progress with estimated time
            self.after(0, lambda: self.status_var.set(f"🚀 Starting import of {len(files)} images for {ch['id']}..."))
            
            # Ensure characters directory exists
            os.makedirs(CHAR_DIR, exist_ok=True)
            
            # Find the next available index for this character's images
            existing = []
            if os.path.exists(CHAR_DIR):
                existing = [p for p in os.listdir(CHAR_DIR) 
                          if p.startswith(ch["id"] + "_") 
                          and (p.lower().endswith(".png") or p.lower().endswith(".jpg"))]
            
            # Find the highest existing index and add 1
            start_idx = 1
            if existing:
                indices = []
                for p in existing:
                    match = re.search(r"_(\d+)\.(png|jpg)$", p, re.IGNORECASE)
                    if match:
                        try:
                            indices.append(int(match.group(1)))
                        except (ValueError, IndexError):
                            pass
                start_idx = max(indices) + 1 if indices else 1
                
            saved = []
            i = start_idx
            
            for idx, f in enumerate(files):
                try:
                    # Update status with progress percentage and ETA
                    progress_percent = int((idx / len(files)) * 100)
                    elapsed = time.time() - start_time
                    
                    if idx > 0:
                        avg_time_per_image = elapsed / idx
                        remaining_images = len(files) - idx
                        eta = remaining_images * avg_time_per_image
                        eta_text = f" (ETA: {int(eta)}s)" if eta > 1 else ""
                    else:
                        eta_text = ""
                    
                    status_msg = f"📸 Processing {idx+1}/{len(files)} for {ch['id']} [{progress_percent}%]{eta_text}"
                    self.after(0, lambda s=status_msg: self.status_var.set(s))
                    
                    # Load and process image (faster processing)
                    with Image.open(f) as img:
                        original_size = os.path.getsize(f) if os.path.exists(f) else 0
                        
                        # Quick mode conversion (faster)
                        if img.mode not in ('RGB', 'RGBA'):
                            if img.mode == 'P' and 'transparency' in img.info:
                                img = img.convert('RGBA')
                            else:
                                img = img.convert('RGB')
                        
                        # Fast optimization with reduced complexity
                        optimized_img, format_type, quality = self.optimize_image_for_size(img, target_kb=30)
                        
                        # Determine file extension based on format
                        ext = '.jpg' if format_type == 'JPEG' else '.png'
                        out_path = os.path.join(CHAR_DIR, f"{ch['id']}_{i}{ext}")
                        
                        # Ensure output directory exists
                        os.makedirs(os.path.dirname(out_path), exist_ok=True)
                        
                        # Save optimized image (no watermark for speed)
                        save_kwargs = {'format': format_type, 'optimize': True}
                        if format_type == 'JPEG':
                            if optimized_img.mode == 'RGBA':
                                # Create white background for JPEGs with transparency
                                background = Image.new('RGB', optimized_img.size, (255, 255, 255))
                                background.paste(optimized_img, mask=optimized_img.split()[3])
                                optimized_img = background
                            save_kwargs['quality'] = quality
                        
                        optimized_img.save(out_path, **save_kwargs)
                        
                        # Verify the file was saved
                        if not os.path.exists(out_path):
                            raise IOError(f"Failed to save image to {out_path}")
                        
                        # Check final size
                        final_size = os.path.getsize(out_path)
                        final_size_kb = final_size / 1024
                        
                        saved.append(out_path)
                        
                        # Show individual progress for each image
                        self.after(0, lambda s=f"✅ Saved {os.path.basename(out_path)}: {original_size/1024:.0f}KB → {final_size_kb:.0f}KB": self.status_var.set(s))
                        
                        print(f"Saved {os.path.basename(out_path)}: {original_size/1024:.1f}KB -> {final_size_kb:.1f}KB ({format_type})")
                        i += 1
                    
                except Exception as e:
                    error_msg = f"Failed to import {os.path.basename(f)}: {str(e)}"
                    print(error_msg)
                    # Show error in status bar but don't popup
                    self.after(0, lambda s=f"❌ Error: {os.path.basename(f)} - {str(e)[:30]}": self.status_var.set(s))
                    continue
            
            # Calculate processing statistics
            total_time = time.time() - start_time
            avg_time = total_time / len(files) if files else 0
            
            # Update UI in main thread
            if saved:
                ch.setdefault("images", [])
                for p in saved:
                    if p not in ch["images"]:
                        ch["images"].append(p)
                
                # Save to JSON and update UI in main thread
                self.after(0, lambda: self._save_and_update_ui(ch, saved, total_time))
            else:
                self.after(0, lambda: self.status_var.set(f"❌ No images were successfully imported for {ch['id']}"))
                
        except Exception as e:
            error_msg = f"Error in import thread: {str(e)}"
            print(error_msg)
            self.after(0, lambda: self.status_var.set(f"💥 Import failed: {str(e)[:40]}"))
        finally:
            # Call the callback when done
            if callback:
                self.after(0, callback)
    
    def _save_and_update_ui(self, ch, saved_images, total_time=0):
        """Save changes and update UI in the main thread"""
        try:
            self._write_images_back_to_json(ch)
            self.update_char_selector()  # Refresh the character list
            
            # Show summary with processing statistics
            total_size_kb = sum(os.path.getsize(p)/1024 for p in saved_images)
            avg_size_kb = total_size_kb / len(saved_images) if saved_images else 0
            
            if total_time > 0:
                avg_time = total_time / len(saved_images)
                self.status_var.set(f"✅ Imported {len(saved_images)} images for {ch['id']} (avg: {avg_size_kb:.0f}KB, {total_time:.1f}s total, {avg_time:.2f}s/image)")
            else:
                self.status_var.set(f"✅ Imported {len(saved_images)} optimized images for {ch['id']} (avg: {avg_size_kb:.1f}KB)")
        except Exception as e:
            messagebox.showerror(APP_TITLE, f"Error updating UI: {str(e)}")
    
    def import_images_for_char(self, ch, callback=None):
        """Start the image import process in a separate thread with per-character status"""
        # Get widget references for this character
        widget = self.char_widgets.get(ch.get('id'))
        if not widget:
            return
            
        status_label = widget.get('status_label')
        progress_bar = widget.get('progress_bar')
        
        # Helper function to update character-specific status
        def update_char_status(msg, show_progress=False, progress_value=0):
            def update_ui():
                if status_label and status_label.winfo_exists():
                    status_label.config(text=msg)
                if progress_bar and progress_bar.winfo_exists():
                    if show_progress:
                        progress_bar.pack(side='right', padx=(5, 0))
                        progress_bar['value'] = progress_value
                    else:
                        progress_bar.pack_forget()
            self.after(0, update_ui)
        
        # Show file dialog
        update_char_status("📁 Select images...", False)
        files = filedialog.askopenfilenames(
            title=f"Select images for {ch['id']}",
            filetypes=[("Images", "*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.tiff"), ("All", "*.*")]
        )
        
        if not files:
            update_char_status("", False)  # Clear status if cancelled
            return
            
        # Show initial import status with progress bar
        update_char_status(f"🚀 Starting import {len(files)} imgs...", True, 0)
        
        # Start the import in a separate thread
        import threading
        thread = threading.Thread(
            target=self._import_images_thread_with_char_status,
            args=(ch, files, callback, update_char_status),
            daemon=True  # Thread will close when main program exits
        )
        thread.start()

    def _import_images_thread_with_char_status(self, ch, files, callback, update_char_status):
        """Thread function to process and save images with per-character status updates"""
        import time
        start_time = time.time()
        
        try:
            # Show initial progress with estimated time
            update_char_status("🚀 Starting import...", True, 0)
            
            # Ensure characters directory exists
            os.makedirs(CHAR_DIR, exist_ok=True)
            
            # Find the next available index for this character's images
            existing = []
            if os.path.exists(CHAR_DIR):
                existing = [p for p in os.listdir(CHAR_DIR) 
                          if p.startswith(ch["id"] + "_") 
                          and (p.lower().endswith(".png") or p.lower().endswith(".jpg"))]
            
            # Find the highest existing index and add 1
            start_idx = 1
            if existing:
                indices = []
                for p in existing:
                    match = re.search(r"_(\d+)\.(png|jpg)$", p, re.IGNORECASE)
                    if match:
                        try:
                            indices.append(int(match.group(1)))
                        except (ValueError, IndexError):
                            pass
                start_idx = max(indices) + 1 if indices else 1
                
            saved = []
            i = start_idx
            
            for idx, f in enumerate(files):
                try:
                    # Update status with progress percentage and ETA
                    progress_percent = int((idx / len(files)) * 100)
                    elapsed = time.time() - start_time
                    
                    if idx > 0:
                        avg_time_per_image = elapsed / idx
                        remaining_images = len(files) - idx
                        eta = remaining_images * avg_time_per_image
                        eta_text = f" (ETA: {int(eta)}s)" if eta > 1 else ""
                    else:
                        eta_text = ""
                    
                    # Update character-specific progress
                    status_msg = f"📸 Processing {idx+1}/{len(files)}{eta_text}"
                    update_char_status(status_msg, True, progress_percent)
                    
                    # Load and process image (faster processing)
                    with Image.open(f) as img:
                        original_size = os.path.getsize(f) if os.path.exists(f) else 0
                        
                        # Quick mode conversion (faster)
                        if img.mode not in ('RGB', 'RGBA'):
                            if img.mode == 'P' and 'transparency' in img.info:
                                img = img.convert('RGBA')
                            else:
                                img = img.convert('RGB')
                        
                        # Fast optimization with reduced complexity
                        optimized_img, format_type, quality = self.optimize_image_for_size(img, target_kb=30)
                        
                        # Determine file extension based on format
                        ext = '.jpg' if format_type == 'JPEG' else '.png'
                        out_path = os.path.join(CHAR_DIR, f"{ch['id']}_{i}{ext}")
                        
                        # Ensure output directory exists
                        os.makedirs(os.path.dirname(out_path), exist_ok=True)
                        
                        # Save optimized image (no watermark for speed)
                        save_kwargs = {'format': format_type, 'optimize': True}
                        if format_type == 'JPEG':
                            if optimized_img.mode == 'RGBA':
                                # Create white background for JPEGs with transparency
                                background = Image.new('RGB', optimized_img.size, (255, 255, 255))
                                background.paste(optimized_img, mask=optimized_img.split()[3])
                                optimized_img = background
                            save_kwargs['quality'] = quality
                        
                        optimized_img.save(out_path, **save_kwargs)
                        
                        # Verify the file was saved
                        if not os.path.exists(out_path):
                            raise IOError(f"Failed to save image to {out_path}")
                        
                        # Check final size
                        final_size = os.path.getsize(out_path)
                        final_size_kb = final_size / 1024
                        
                        saved.append(out_path)
                        
                        # Show individual progress for each image
                        update_char_status(f"✅ Saved {os.path.basename(out_path)}: {final_size_kb:.0f}KB", True, progress_percent)
                        
                        print(f"Saved {os.path.basename(out_path)}: {original_size/1024:.1f}KB -> {final_size_kb:.1f}KB ({format_type})")
                        i += 1
                    
                except Exception as e:
                    error_msg = f"Failed to import {os.path.basename(f)}: {str(e)}"
                    print(error_msg)
                    # Show error in character status
                    update_char_status(f"❌ Error: {os.path.basename(f)[:15]}...", True, progress_percent)
                    time.sleep(2)  # Brief pause to show error
                    continue
            
            # Calculate processing statistics
            total_time = time.time() - start_time
            avg_time = total_time / len(files) if files else 0
            
            # Update UI in main thread
            if saved:
                ch.setdefault("images", [])
                for p in saved:
                    if p not in ch["images"]:
                        ch["images"].append(p)
                
                # Show final success status
                final_msg = f"✅ Imported {len(saved)} imgs ({total_time:.1f}s)"
                update_char_status(final_msg, False, 100)  # Hide progress bar, show 100%
                
                # Save to JSON and update UI in main thread
                self.after(0, lambda: self._save_and_update_ui(ch, saved, total_time))
                
                # Clear status after 5 seconds
                def clear_status():
                    update_char_status("", False, 0)
                self.after(5000, clear_status)
            else:
                update_char_status("❌ No images imported", False, 0)
                
        except Exception as e:
            error_msg = f"Error in import thread: {str(e)}"
            print(error_msg)
            update_char_status(f"💥 Import failed: {str(e)[:20]}", False, 0)
        finally:
            # Call the callback when done
            if callback:
                self.after(0, callback)

    def rename_char_id_from_text(self, ch, text_widget):
        """Rename character ID using text from the textarea widget"""
        new_id = text_widget.get("1.0", "end-1c").strip()
        self.rename_char_id(ch, new_id)

    def _write_images_back_to_json(self, ch):
        try:
            # Check if this is the new dash_story.json format
            if 'character_reference' in self.data and isinstance(self.data['character_reference'], list):
                # Find the character in the character_reference list
                for char_ref in self.data['character_reference']:
                    if isinstance(char_ref, dict) and char_ref.get('id') == ch['id']:
                        char_ref['images'] = ch.get('images', [])
                        break
            else:
                # Old format
                path = ch.get("key_path", [])
                if len(path) > 1 and path[1] == "main_character":
                    self.data["character_reference"]["main_character"]["images"] = ch.get("images", [])
                elif len(path) > 2:  # secondary character
                    idx = path[2]
                    self.data["character_reference"]["secondary_characters"][idx]["images"] = ch.get("images", [])
        except Exception as e:
            messagebox.showerror(APP_TITLE, f"Failed to write images to JSON: {e}")
            print(f"Error in _write_images_back_to_json: {e}")
            import traceback
            traceback.print_exc()

    def rename_char_id(self,ch,new_id):
        old_id = ch["id"]
        new_id = (new_id or "").strip()
        if not new_id or new_id==old_id:
            return
        if any(c is not ch and c["id"]==new_id for c in self.characters):
            messagebox.showerror(APP_TITLE,f"ID '{new_id}' exists.")
            return
        renamed=[]
        for p in list(ch.get("images",[])):
            if os.path.isfile(p):
                m = re.search(r"_(\d+)\.png$", os.path.basename(p))
                idx = m.group(1) if m else "1"
                new_path = os.path.join(CHAR_DIR,f"{new_id}_{idx}.png")
                try:
                    os.replace(p,new_path)
                    renamed.append(new_path)
                except Exception as e:
                    messagebox.showerror(APP_TITLE,f"Failed to rename {os.path.basename(p)}:\n{e}")
        if renamed:
            ch["images"]=renamed
        path=ch["key_path"]
        try:
            if path[1]=="main_character":
                self.data["character_reference"]["main_character"]["id"]=new_id
            else:
                idx=path[2]
                self.data["character_reference"]["secondary_characters"][idx]["id"]=new_id
        except Exception as e:
            messagebox.showerror(APP_TITLE,f"Failed to update JSON ID:\n{e}")
        ch["id"]=new_id
        widgets=self.char_widgets.pop(old_id,{})
        if widgets:
            # Update the text widget with the new ID
            id_text = widgets.get("id_text")
            if id_text:
                id_text.delete("1.0", "end")
                id_text.insert("1.0", new_id)
            self.char_widgets[new_id]=widgets
        self.status_var.set(f"Renamed {old_id} → {new_id}")

    def open_char_folder(self):
        path = os.path.join(os.getcwd(), CHAR_DIR)
        os.makedirs(path, exist_ok=True)
        try:
            if os.name=="nt": os.startfile(path)
            elif os.name=="posix": os.system(f'xdg-open "{path}"')
            else: import webbrowser; webbrowser.open(f"file://{path}")
        except: pass

    # ---------- Scenes ----------
    def on_scene_change(self, event=None):
        sn = self.scene_var.get()
        if not sn: 
            return
            
        try: 
            snum = int(sn)
        except: 
            snum = self.scene_combo.current() + 1
            
        is_dash_story = 'character_reference' in self.data and 'output_structure' in self.data
        scenes = self.data.get("output_structure", {}).get("scenes", [])
        
        # Find the target scene
        target = next((s for s in scenes if str(s.get("scene_number")) == str(snum)), None)
        self.prompt_text.delete("1.0", "end")
        
        if target:
            # Check if we have a modified version
            if target.get("scene_number") in self.modified_prompts:
                text = self.modified_prompts[target.get("scene_number")]
            else:
                # Show the scene JSON object WITHOUT voice_scripts
                try:
                    filtered = self.strip_voice_scripts(target)
                    text = json.dumps(filtered, ensure_ascii=False, indent=2)
                except Exception:
                    text = json.dumps(target, ensure_ascii=False, indent=2)
            
            self.prompt_text.insert("1.0", text)
            
            # Highlight characters in the scene for dash_story format
            if is_dash_story and 'characters_in_scene' in target:
                self.highlight_characters_in_scene(target['characters_in_scene'])
                
    def highlight_characters_in_scene(self, character_ids):
        """Highlight characters that appear in the current scene"""
        # First, clear all highlights
        for char_id, widget in self.char_widgets.items():
            if 'highlight' in widget:
                widget['highlight'] = False
                self._update_char_widget_style(char_id)
        
        # Then highlight characters in this scene
        for char_id in character_ids:
            if char_id in self.char_widgets:
                self.char_widgets[char_id]['highlight'] = True
                self._update_char_widget_style(char_id)

    def _update_char_widget_style(self, char_id):
        """Update the visual style of a character widget based on its highlight state"""
        if char_id not in self.char_widgets:
            return
            
        widget = self.char_widgets[char_id]
        frame = widget.get('frame')
        
        if not frame or not frame.winfo_exists():
            return
            
        # Configure the frame style based on highlight state
        if widget.get('highlight', False):
            frame.configure(style='Highlighted.TFrame')
        else:
            frame.configure(style='TFrame')
    
    def detect_chars_in_prompt(self):
        txt = self.prompt_text.get("1.0", "end").strip()
        present=[c["id"] for c in self.characters if c["id"] in txt]
        self.char_detect_label.config(text=", ".join(present) if present else "No chars detected")

    # --- Helper methods to strip voice_scripts from prompts ---
    def strip_voice_scripts(self, obj):
        """Recursively remove any 'voice_scripts' keys from dict/list structures."""
        try:
            if isinstance(obj, dict):
                return {k: self.strip_voice_scripts(v) for k, v in obj.items() if k != 'voice_scripts'}
            if isinstance(obj, list):
                return [self.strip_voice_scripts(v) for v in obj]
            return obj
        except Exception:
            return obj

    def strip_voice_scripts_from_text(self, text):
        """If text is JSON, remove all 'voice_scripts' keys and reformat; otherwise return as-is."""
        try:
            data = json.loads(text)
            cleaned = self.strip_voice_scripts(data)
            return json.dumps(cleaned, ensure_ascii=False, indent=2)
        except Exception:
            return text

    # --- Generic JSON → scenes normalizer ---
    def normalize_to_scenes(self, loaded):
        """Convert many JSON shapes into a list of scene dicts.
        Rules:
        - Top-level list: each item becomes a scene (dicts are copied; scalars become prompt strings).
        - Known list keys on dicts: storyboard_prompts, image_prompts, prompts, scenes, items, data, results, list, frames, entries, rows, records.
        - Dict mapping keys -> str/dict: each value becomes a scene; key stored as 'id'.
        - Single dict with a 'prompt'-like field becomes one scene.
        Each scene will have at least: scene_number (int) and prompt (str).
        """
        try:
            def pick_prompt(obj):
                if isinstance(obj, str):
                    return obj
                if isinstance(obj, (int, float)):
                    return str(obj)
                if isinstance(obj, dict):
                    for k in [
                        "prompt", "image_prompt", "imagePrompts", "image", "text",
                        "description", "caption", "scene", "content", "instruction"
                    ]:
                        v = obj.get(k)
                        if isinstance(v, str) and v.strip():
                            return v
                    # arrays of strings under common keys
                    for k in ["prompts", "image_prompts", "lines"]:
                        v = obj.get(k)
                        if isinstance(v, list) and v and all(isinstance(x, str) for x in v):
                            return "\n".join(v)
                    return json.dumps(obj, ensure_ascii=False)
                return str(obj)

            def process_list(lst):
                scenes = []
                for i, item in enumerate(lst):
                    if isinstance(item, dict):
                        scene = dict(item)  # shallow copy to preserve extra fields
                        if "scene_number" not in scene:
                            scene["scene_number"] = item.get("scene_number", i + 1)
                        if not isinstance(scene.get("prompt"), str):
                            scene["prompt"] = pick_prompt(item)
                        scenes.append(scene)
                    else:
                        scenes.append({
                            "scene_number": i + 1,
                            "prompt": pick_prompt(item)
                        })
                return scenes

            # Case 1: top-level list
            if isinstance(loaded, list):
                return process_list(loaded)

            # Case 2: dict with known list keys
            if isinstance(loaded, dict):
                for key in [
                    "storyboard_prompts", "image_prompts", "prompts", "scenes",
                    "items", "data", "results", "list", "frames", "entries", "rows", "records"
                ]:
                    val = loaded.get(key)
                    if isinstance(val, list) and len(val) >= 1:
                        return process_list(val)

                # Dict mapping identifiers -> str/dict
                if loaded and all(isinstance(v, (str, dict)) for v in loaded.values()):
                    scenes = []
                    for i, (k, v) in enumerate(loaded.items()):
                        if isinstance(v, dict):
                            scene = dict(v)
                            scene.setdefault("id", k)
                            scene.setdefault("scene_number", i + 1)
                            if not isinstance(scene.get("prompt"), str):
                                scene["prompt"] = pick_prompt(v)
                            scenes.append(scene)
                        else:
                            scenes.append({
                                "scene_number": i + 1,
                                "id": k,
                                "prompt": pick_prompt(v)
                            })
                    return scenes

                # Single-object scene with prompt-like fields
                if any(k in loaded for k in ["prompt", "image_prompt", "text", "description", "caption"]):
                    scene = dict(loaded)
                    scene.setdefault("scene_number", 1)
                    if not isinstance(scene.get("prompt"), str):
                        scene["prompt"] = pick_prompt(loaded)
                    return [scene]

            return []
        except Exception:
            return []

    def copy_prompt(self):
        txt=self.prompt_text.get("1.0","end").strip()
        # Remove any voice_scripts fields before copying (if JSON)
        filtered_txt = self.strip_voice_scripts_from_text(txt)
        self.clipboard_clear()
        self.clipboard_append(filtered_txt)
        messagebox.showinfo(APP_TITLE,"Prompt copied to clipboard.")

    def use_manual_prompt(self):
        sn = self.scene_var.get()
        if not sn: 
            return
            
        try: 
            snum = int(sn)
        except: 
            snum = self.scene_combo.current() + 1
            
        is_dash_story = 'character_reference' in self.data and 'output_structure' in self.data
        scenes = self.data.get("output_structure", {}).get("scenes", [])
        txt = self.prompt_text.get("1.0", "end").strip()
        
        # Find the target scene
        for s in scenes:
            if str(s.get("scene_number")) == str(snum):
                # Always store the text as-is; no special parsing
                s["prompt"] = txt

                # For dash_story.json, still update characters_in_scene based on highlights
                if is_dash_story:
                    if 'characters_in_scene' not in s:
                        s['characters_in_scene'] = []
                    s['characters_in_scene'] = [
                        char_id for char_id, widget in self.char_widgets.items()
                        if widget.get('highlight', False)
                    ]
                break
                
        self.modified_prompts[snum] = txt
        self.status_var.set(f"Updated prompt for scene {snum} (in memory).")

    def save_json_as(self):
        if not self.data:
            messagebox.showwarning(APP_TITLE,"No data to save.")
            return
        initial=os.path.dirname(self.json_path) if self.json_path else os.getcwd()
        initialfile=f"{os.path.splitext(os.path.basename(self.json_path or 'story'))[0]}_updated_{datetime.now().strftime('%Y%m%d_%H%M')}.json"
        path=filedialog.asksaveasfilename(title="Save JSON As", defaultextension=".json", initialdir=initial, initialfile=initialfile, filetypes=[("JSON files","*.json")])
        if not path: return
        try:
            with open(path,"w",encoding="utf-8") as f:
                json.dump(self.data,f,ensure_ascii=False,indent=2)
            messagebox.showinfo(APP_TITLE,f"Saved: {os.path.basename(path)}")
        except Exception as e:
            messagebox.showerror(APP_TITLE,f"Failed to save JSON:\n{e}")

    # ---------- Profile ----------
    def populate_profiles(self):
        """Populate the profile dropdown with available Chrome profiles"""
        profiles = []
        chrome_batch_dir = os.path.join(os.getcwd(), "Chrome_Batch")
        user_data_dir = os.path.join(os.getcwd(), "User Data")
        try:
            if os.path.exists(chrome_batch_dir):
                # First check for .lnk files in Chrome_Batch
                for item in os.listdir(chrome_batch_dir):
                    if item.lower().endswith('.lnk') and item.startswith("Profile"):
                        profile_name = os.path.splitext(item)[0]  # Remove .lnk extension
                        profiles.append(profile_name)
                
                # If no .lnk files found, check for directories in User Data
                if not profiles and os.path.exists(user_data_dir):
                    for item in os.listdir(user_data_dir):
                        if os.path.isdir(os.path.join(user_data_dir, item)) and item.startswith("Profile"):
                            profiles.append(item)
        except:
            pass
        
        if not profiles:
            profiles = ["Profile 18"]  # Default fallback
            
        self.profile_combo["values"] = profiles
        
        # Set current profile - use actual profile directory path
        current_profile_name = self.get_current_profile_name()
        if current_profile_name in profiles:
            self.profile_var.set(current_profile_name)
        elif profiles:
            self.profile_var.set(profiles[0])
            self._update_profile_dir_for_name(profiles[0])
    
    def on_profile_change(self, event=None):
        """Handle profile selection change"""
        selected_profile = self.profile_var.get()
        if selected_profile:
            # Always use the current project directory for user profiles
            user_data_dir = os.path.join(os.getcwd(), "User Data")
            self.profile_dir = os.path.join(user_data_dir, selected_profile)
            
            # Create the profile directory if it doesn't exist
            os.makedirs(self.profile_dir, exist_ok=True)
            
            self.save_profile_config()
            self.status_var.set(f"Profile set to: {selected_profile} (project local)")

    def save_profile_config(self):
        try:
            with open(PROFILE_CONFIG,"w",encoding="utf-8") as f:
                json.dump({"profile_dir":self.profile_dir},f)
        except: pass

    def load_profile_config(self):
        try:
            if os.path.exists(PROFILE_CONFIG):
                with open(PROFILE_CONFIG,"r",encoding="utf-8") as f:
                    j=json.load(f)
                    self.profile_dir=j.get("profile_dir",DEFAULT_PROFILE_DIR)
            else: self.profile_dir=DEFAULT_PROFILE_DIR
        except:
            self.profile_dir=DEFAULT_PROFILE_DIR
    
    def get_current_profile_name(self):
        """Get the current profile name from the profile_dir"""
        if hasattr(self, 'profile_dir') and self.profile_dir:
            return os.path.basename(self.profile_dir)
        return "Profile 18"  # Default fallback
    
    def _update_profile_dir_for_name(self, profile_name):
        """Update profile_dir based on profile name - always use current project directory"""
        # Always use the current project directory for user data
        user_data_dir = os.path.join(os.getcwd(), "User Data")
        self.profile_dir = os.path.join(user_data_dir, profile_name)
        
        # Create the profile directory if it doesn't exist
        os.makedirs(self.profile_dir, exist_ok=True)
        self.save_profile_config()
    
    def open_chrome_with_remote_debug(self):
        """Open Chrome with remote debugging enabled on port 9222 using the selected profile"""
        try:
            # Get the selected profile
            profile_name = self.profile_var.get()
            if not profile_name:
                profile_name = "Profile 18"
            
            # Build user data directory path
            user_data_dir = os.path.join(os.getcwd(), "User Data")
            os.makedirs(user_data_dir, exist_ok=True)
            
            # Find Chrome executable
            chrome_paths = [
                r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
            ]
            
            chrome_exe = None
            for path in chrome_paths:
                if os.path.exists(path):
                    chrome_exe = path
                    break
            
            if not chrome_exe:
                messagebox.showerror(APP_TITLE, "Chrome executable not found.\n\nPlease install Google Chrome.")
                return
            
            # AI Studio App URL to open (where geminiHub is available for CDP)
            ai_studio_url = "https://aistudio.google.com/apps/drive/10_Qs0vkJbQIOSKW-rwZOBlC-9lmYJjHo?showPreview=true&showAssistant=true"
            
            # Build command with remote debugging
            cmd = [
                chrome_exe,
                f"--remote-debugging-port=9222",
                f"--user-data-dir={user_data_dir}",
                f"--profile-directory={profile_name}",
                ai_studio_url
            ]
            
            self.add_progress_log(f"🚀 Launching Chrome with remote debugging...")
            self.add_progress_log(f"📁 User Data: {user_data_dir}")
            self.add_progress_log(f"👤 Profile: {profile_name}")
            self.add_progress_log(f"🔌 Debug Port: 9222")
            
            # Launch Chrome
            subprocess.Popen(cmd, shell=False)
            
            self.status_var.set(f"✅ Chrome launched with remote debugging (port 9222)")
            self.add_progress_log("✅ Chrome launched! Wait for AI Studio to load, then click 'Connect'")
            
            # Update CDP status indicator
            self.after(0, lambda: self.cdp_status_var.set("● Chrome launched, click Connect"))
            self.after(0, lambda: self.cdp_status_label.config(foreground="orange"))
            
        except Exception as e:
            error_msg = str(e)[:100]
            messagebox.showerror(APP_TITLE, f"Failed to launch Chrome:\n{error_msg}")
            self.add_progress_log(f"❌ Chrome launch failed: {error_msg}")
    
    # ---------- Image Model Management Methods ----------
    def load_image_models(self):
        """Load image models from config file"""
        default_models = {
            "imagen-4.0-generate-001": "Imagen 4.0"
        }
        
        try:
            if os.path.exists(IMAGE_MODELS_CONFIG):
                with open(IMAGE_MODELS_CONFIG, "r", encoding="utf-8") as f:
                    saved_models = json.load(f)
                    # Merge with defaults
                    default_models.update(saved_models)
        except Exception as e:
            print(f"Error loading image models: {e}")
        
        return default_models
    
    def save_image_models(self):
        """Save image models to config file"""
        try:
            with open(IMAGE_MODELS_CONFIG, "w", encoding="utf-8") as f:
                json.dump(self.image_models, f, indent=2)
        except Exception as e:
            messagebox.showerror(APP_TITLE, f"Failed to save image models: {e}")
    
    def populate_image_models(self):
        """Populate the image model dropdown"""
        model_names = ["NanoBanana (Chat)"] + [f"{name} ({model_id})" for model_id, name in self.image_models.items()]
        self.image_model_combo["values"] = model_names
        
        # Set default to NanoBanana
        if model_names:
            self.image_model_var.set(model_names[0])
    
    def on_image_model_change(self, event=None):
        """Handle image model selection change"""
        selected = self.image_model_var.get()
        
        if selected == "NanoBanana (Chat)":
            self.selected_image_model = None
            self.status_var.set("Model set to: NanoBanana (Chat)")
        else:
            # Extract model ID from the selection
            for model_id, name in self.image_models.items():
                if f"{name} ({model_id})" == selected:
                    self.selected_image_model = model_id
                    self.status_var.set(f"Model set to: {name} ({model_id})")
                    break
    
    def open_image_model(self):
        """Open the selected image model in Chrome"""
        if not selenium_available:
            messagebox.showerror(APP_TITLE, "Selenium webdriver not installed.")
            return
        
        selected = self.image_model_var.get()
        
        if selected == "NanoBanana (Chat)":
            url = AI_STUDIO_URL
            model_name = "NanoBanana"
        elif self.selected_image_model:
            url = f"{IMAGEN_BASE_URL}{self.selected_image_model}"
            model_name = self.selected_image_model
        else:
            messagebox.showwarning(APP_TITLE, "Please select an image model first.")
            return
        
        # Open in Chrome
        threading.Thread(target=self._open_model_in_chrome, args=(url, model_name), daemon=True).start()
    
    def _open_model_in_chrome(self, url, model_name):
        """Open model URL in Chrome in a separate thread"""
        try:
            self.add_progress_log(f"🚀 Opening {model_name}...")
            self.status_var.set(f"Opening {model_name}...")
            
            # Initialize Chrome
            driver, wait = self.initialize_chrome_for_batch()
            if not driver:
                self.after(0, lambda: messagebox.showerror(APP_TITLE, "Failed to launch Chrome"))
                return
            
            # Navigate to model URL
            driver.get(url)
            self.add_progress_log(f"✅ {model_name} opened successfully!")
            self.after(0, lambda: self.status_var.set(f"✅ {model_name} opened in Chrome"))
            
        except Exception as e:
            error_msg = f"Failed to open {model_name}: {str(e)}"
            self.add_progress_log(f"❌ {error_msg}")
            self.after(0, lambda: messagebox.showerror(APP_TITLE, error_msg))
    
    def add_new_image_model(self):
        """Add a new image model"""
        # Create a dialog for adding new model
        dialog = tk.Toplevel(self)
        dialog.title("Add New Image Model")
        dialog.geometry("450x200")
        dialog.transient(self)
        dialog.grab_set()
        
        # Center the dialog
        dialog.update_idletasks()
        x = (dialog.winfo_screenwidth() // 2) - (dialog.winfo_width() // 2)
        y = (dialog.winfo_screenheight() // 2) - (dialog.winfo_height() // 2)
        dialog.geometry(f"+{x}+{y}")
        
        # Model Name
        ttk.Label(dialog, text="Model Name:", font=('TkDefaultFont', 9)).pack(pady=(20, 5))
        name_entry = ttk.Entry(dialog, width=50)
        name_entry.pack(pady=5)
        name_entry.insert(0, "Imagen 4.0")
        
        # Model ID
        ttk.Label(dialog, text="Model ID (e.g., imagen-4.0-generate-001):", font=('TkDefaultFont', 9)).pack(pady=(10, 5))
        id_entry = ttk.Entry(dialog, width=50)
        id_entry.pack(pady=5)
        id_entry.insert(0, "imagen-4.0-generate-001")
        
        # Info label
        info_label = ttk.Label(dialog, text="The model will be accessed at:\nhttps://aistudio.google.com/prompts/new_image?model={model_id}", 
                              font=('TkDefaultFont', 8), foreground="gray")
        info_label.pack(pady=(10, 10))
        
        def save_model():
            model_name = name_entry.get().strip()
            model_id = id_entry.get().strip()
            
            if not model_name or not model_id:
                messagebox.showwarning("Invalid Input", "Please enter both model name and ID.")
                return
            
            # Add to models
            self.image_models[model_id] = model_name
            self.save_image_models()
            self.populate_image_models()
            
            # Select the newly added model
            self.image_model_var.set(f"{model_name} ({model_id})")
            self.selected_image_model = model_id
            
            messagebox.showinfo(APP_TITLE, f"Model '{model_name}' added successfully!")
            dialog.destroy()
        
        # Buttons
        button_frame = ttk.Frame(dialog)
        button_frame.pack(pady=(10, 10))
        ttk.Button(button_frame, text="Save", command=save_model).pack(side="left", padx=5)
        ttk.Button(button_frame, text="Cancel", command=dialog.destroy).pack(side="left", padx=5)
    
    # ---------- Character Management Methods ----------
    def update_char_selector(self):
        """Create compact character interface showing all characters at once"""
        # Clear existing character widgets
        for widget in list(self.chars_container.children.values()):
            widget.destroy()
        
        if not self.characters:
            no_chars_label = ttk.Label(self.chars_container, text="No characters loaded", 
                                     foreground="gray", font=('TkDefaultFont', 10))
            no_chars_label.pack(pady=20)
            return
        
        # Create character cards
        for ch in self.characters:
            self.create_character_card(ch)
    
    def create_character_card(self, ch):
        """Create a compact character card with real-time processing indicators"""
        if not ch or 'id' not in ch:
            return
            
        # Main character frame
        char_frame = ttk.Frame(self.chars_container, padding=2)
        char_frame.pack(fill="x", padx=2, pady=1)
        
        # Create a frame for the ID and import button
        id_frame = ttk.Frame(char_frame)
        id_frame.pack(fill='x', pady=(0, 2))
        
        # Add character ID as a small label
        ttk.Label(id_frame, text=ch['id'], font=('TkDefaultFont', 8, 'bold')).pack(side='left')
        
        # Add import button
        import_btn = ttk.Button(id_frame, text="Import", width=6, 
                              command=lambda c=ch: self.import_images_for_char(c))
        import_btn.pack(side='right', padx=5)
        
        # Add tooltip for the import button
        ToolTip(import_btn, "Import images for this character")
        
        # Processing status area (initially hidden)
        status_frame = ttk.Frame(char_frame)
        status_frame.pack(fill='x', pady=(0, 2))
        
        # Processing status label with progress indicator
        status_label = ttk.Label(status_frame, text="", font=('TkDefaultFont', 7), 
                                foreground="blue")
        status_label.pack(side='left', fill='x', expand=True)
        
        # Progress bar for this character
        progress_bar = ttk.Progressbar(status_frame, mode='determinate', length=100)
        progress_bar.pack(side='right', padx=(5, 0))
        progress_bar.pack_forget()  # Hide initially
        
        # Image preview area (horizontal scroll with small thumbnails)
        preview_frame = ttk.Frame(char_frame)
        preview_frame.pack(fill="x")
        
        # Create horizontal scrollable area for image thumbnails
        if ch.get('images'):
            self.create_image_thumbnails(preview_frame, ch)
        else:
            # If no images, show a placeholder with the character ID
            placeholder = ttk.Label(preview_frame, text=f"No images for {ch['id']}", 
                                 foreground="gray", font=('TkDefaultFont', 8))
            placeholder.pack(pady=5)
        
        # Store reference to the character frame for highlighting and status updates
        if hasattr(self, 'char_widgets'):
            self.char_widgets[ch['id']] = {
                'frame': char_frame, 
                'highlight': False,
                'id': ch['id'],
                'status_label': status_label,
                'progress_bar': progress_bar,
                'preview_frame': preview_frame
            }
    
    def create_image_thumbnails(self, parent, ch):
        """Create horizontal scrollable thumbnails for character images"""
        # Canvas for horizontal scrolling
        canvas = tk.Canvas(parent, height=60, highlightthickness=0)
        h_scroll = ttk.Scrollbar(parent, orient="horizontal", command=canvas.xview)
        thumb_frame = ttk.Frame(canvas)
        
        canvas.configure(xscrollcommand=h_scroll.set)
        canvas.pack(side="top", fill="x")
        h_scroll.pack(side="bottom", fill="x")
        
        canvas_window = canvas.create_window((0, 0), window=thumb_frame, anchor="nw")
        
        # Load and display thumbnails
        thumb_cache = []
        for i, img_path in enumerate(ch.get('images', [])[:10]):  # Limit to 10 thumbnails
            try:
                img = Image.open(img_path)
                img.thumbnail((50, 50))  # Small thumbnails
                tkimg = ImageTk.PhotoImage(img)
                
                thumb_label = ttk.Label(thumb_frame, image=tkimg)
                thumb_label.image = tkimg  # Keep reference
                thumb_label.pack(side="left", padx=2)
                
                thumb_cache.append(tkimg)
            except Exception as e:
                error_label = ttk.Label(thumb_frame, text="?", width=6, 
                                       background="lightgray")
                error_label.pack(side="left", padx=2)
        
        # Show "..." if more than 10 images
        if len(ch.get('images', [])) > 10:
            more_label = ttk.Label(thumb_frame, text=f"+{len(ch.get('images', [])) - 10} more")
            more_label.pack(side="left", padx=4)
        
        # Configure canvas scrolling
        def configure_scroll(event):
            canvas.configure(scrollregion=canvas.bbox("all"))
        thumb_frame.bind("<Configure>", configure_scroll)
        
        # Keep thumbnail references
        thumb_frame._thumb_cache = thumb_cache
    
    def import_char_images(self, ch):
        """Import images for character"""
        self.import_images_for_char(ch)
        self.update_char_selector()  # Refresh the interface
    
    def replace_char_images(self, ch):
        """Replace all images for character"""
        result = messagebox.askyesno(APP_TITLE, f"Replace all images for '{ch['id']}'?")
        if result:
            # Clear existing images
            old_images = ch.get("images", [])
            for img_path in old_images:
                if os.path.exists(img_path):
                    try:
                        os.remove(img_path)
                    except:
                        pass
            ch["images"] = []
            
            # Import new images
            self.import_images_for_char(ch)
            self.update_char_selector()  # Refresh the interface
    
    def clear_char_images(self, ch):
        """Clear all images for character"""
        result = messagebox.askyesno(APP_TITLE, f"Clear all images for '{ch['id']}'?")
        if result:
            ch["images"] = []
            self._write_images_back_to_json(ch)
            self.update_char_selector()  # Refresh the interface
            self.status_var.set(f"Cleared images for {ch['id']}")
    
    def rename_char_dialog(self, ch):
        """Show rename dialog for character"""
        new_id = tk.simpledialog.askstring("Rename Character", 
                                          f"Enter new ID for '{ch['id']}':", 
                                          initialvalue=ch["id"])
        if new_id:
            self.rename_char_id(ch, new_id)
            self.update_char_selector()  # Refresh the interface
    
    def auto_load_character_images(self, char_data):
        """Automatically load character images from the characters folder based on character ID"""
        char_id = char_data.get("id")
        if not char_id:
            return
        
        # Look for images in the characters folder with pattern: {char_id}_{number}.png
        char_folder = os.path.abspath(CHAR_DIR)
        if not os.path.exists(char_folder):
            return
        
        found_images = []
        try:
            for filename in os.listdir(char_folder):
                # Check if file matches pattern: {char_id}_{number}.png or {char_id}_{number}.jpg
                if filename.lower().startswith(char_id.lower() + "_") and (filename.lower().endswith(".png") or filename.lower().endswith(".jpg")):
                    full_path = os.path.join(char_folder, filename)
                    if os.path.isfile(full_path):
                        found_images.append(full_path)
        except Exception as e:
            print(f"Error scanning character folder: {e}")
            return
        
        if found_images:
            # Sort images by number if possible
            def extract_number(filepath):
                basename = os.path.basename(filepath)
                match = re.search(r"_(\d+)\.(png|jpg)$", basename)
                return int(match.group(1)) if match else 0
            
            found_images.sort(key=extract_number)
            
            # Merge with existing images, avoiding duplicates
            existing_images = set(char_data.get("images", []))
            new_images = []
            
            for img_path in found_images:
                if img_path not in existing_images:
                    new_images.append(img_path)
            
            if new_images:
                # Add new images to the character data
                if "images" not in char_data:
                    char_data["images"] = []
                char_data["images"].extend(new_images)
                
                # Update JSON with the auto-loaded images
                self._write_images_back_to_json(char_data)
                
                print(f"Auto-loaded {len(new_images)} images for character '{char_id}'")
    
    def clear_all_images(self):
        """Clear all images for all characters"""
        result = messagebox.askyesno(APP_TITLE, "Clear all images for all characters? This cannot be undone.")
        if result:
            for ch in self.characters:
                ch["images"] = []
                self._write_images_back_to_json(ch)
            self.status_var.set("Cleared all character images")
            self.update_selected_preview()
    
    def update_selected_preview(self, event=None):
        """Update the preview images in the right column for selected character"""
        # Clear existing preview
        for widget in list(self.preview_inner.children.values()):
            widget.destroy()
        
        ch = self.get_selected_character()
        if not ch:
            return
            
        # Show character ID
        id_label = ttk.Label(self.preview_inner, text=f"Character ID: {ch['id']}", font=('TkDefaultFont', 9, 'bold'))
        id_label.pack(pady=(0, 8))
        
        # Show images
        preview_cache = []
        for i, img_path in enumerate(ch.get("images", [])):
            try:
                img = Image.open(img_path)
                # Larger preview images
                img.thumbnail((120, 120))
                tkimg = ImageTk.PhotoImage(img)
                
                # Create frame for each image
                img_frame = ttk.Frame(self.preview_inner)
                img_frame.pack(pady=4, fill="x")
                
                # Image label
                lbl = ttk.Label(img_frame, image=tkimg)
                lbl.image = tkimg  # Keep reference
                lbl.pack(side="top")
                
                # Image filename
                filename = os.path.basename(img_path)
                filename_lbl = ttk.Label(img_frame, text=filename, font=('TkDefaultFont', 8))
                filename_lbl.pack(side="top", pady=(2, 0))
                
                preview_cache.append(tkimg)
            except Exception as e:
                error_lbl = ttk.Label(self.preview_inner, text=f"Error loading image {i+1}", foreground="red")
                error_lbl.pack(pady=2)
        
        if not ch.get("images"):
            no_images_lbl = ttk.Label(self.preview_inner, text="No images imported", foreground="gray")
            no_images_lbl.pack(pady=20)
        
        # Keep reference to prevent garbage collection
        self.preview_inner._preview_cache = preview_cache
        
        # Update canvas scroll region
        self.preview_inner.update_idletasks()
        self.preview_canvas.configure(scrollregion=self.preview_canvas.bbox("all"))

    # ---------- Progress Log Methods ----------
    def toggle_progress_log(self):
        """Show/hide the progress log content"""
        if self.show_progress.get():
            # Enable the progress log text area
            self.progress_text.config(state="normal")
            self.add_progress_log("📝 Progress log enabled - ready for automation")
            self.progress_text.config(state="disabled")  # Make read-only again
        else:
            # Clear and disable the progress log text area
            self.progress_text.config(state="normal")
            self.progress_text.delete(1.0, tk.END)
            self.progress_text.config(state="disabled")
    
    def add_progress_log(self, message):
        """Add a message to the progress log with timestamp"""
        if hasattr(self, 'progress_text') and self.show_progress.get():
            timestamp = datetime.now().strftime("%H:%M:%S")
            formatted_message = f"[{timestamp}] {message}\n"
            
            def update_text():
                self.progress_text.config(state="normal")
                self.progress_text.insert(tk.END, formatted_message)
                self.progress_text.see(tk.END)  # Auto-scroll to bottom
                self.progress_text.config(state="disabled")
            
            self.after(0, update_text)
    
    def update_current_step(self, step_text):
        """Update the current step indicator"""
        def update_step():
            self.current_step_var.set(f"🔄 {step_text}")
            # Also update main status bar
            self.status_var.set(f"AI Studio: {step_text}")
        
        self.after(0, update_step)
    
    def clear_progress_log(self):
        """Clear the progress log"""
        if hasattr(self, 'progress_text'):
            self.progress_text.config(state="normal")
            self.progress_text.delete(1.0, tk.END)
            self.progress_text.config(state="disabled")
            # Add log cleared message if progress log is enabled
            if self.show_progress.get():
                self.add_progress_log("📝 Log cleared")
    
    def automation_complete(self, success=True, message=""):
        """Mark automation as complete"""
        def update_completion():
            if success:
                self.current_step_var.set("✅ Complete!")
                self.status_var.set(f"✅ Success: {message}")
                self.add_progress_log(f"🎉 SUCCESS: {message}")
            else:
                self.current_step_var.set("❌ Failed")
                self.status_var.set(f"❌ Failed: {message}")
                self.add_progress_log(f"💥 ERROR: {message}")
        
        self.after(0, update_completion)
    
    # ---------- Simple Tab Batch Processing ----------
    def toggle_smart_batch(self):
        """Toggle simple tab batch processing - Start/Stop"""
        if self.smart_batch_running:
            # Stop the current batch
            self.stop_smart_batch()
        else:
            # Start simple tab batch processing
            self.start_simple_tab_batch()
    
    def start_simple_tab_batch(self):
        """Start simple tab batch processing - one tab per scene with 5s interval"""
        # Validate range
        try:
            from_num = int(self.from_prompt_var.get().strip())
            to_num = int(self.to_prompt_var.get().strip())
        except ValueError:
            messagebox.showerror(APP_TITLE, "Please enter valid numbers for the range.")
            return
        
        if from_num > to_num:
            messagebox.showerror(APP_TITLE, "'From' number must be less than or equal to 'To' number.")
            return
        
        # Check scenes availability
        scenes = self.data.get("output_structure", {}).get("scenes", [])
        if not scenes:
            messagebox.showerror(APP_TITLE, "No scenes loaded. Please load a JSON file first.")
            return
        
        available_scenes = [s.get("scene_number", i+1) for i, s in enumerate(scenes)]
        valid_scenes = [num for num in range(from_num, to_num + 1) if num in available_scenes]
        
        if not valid_scenes:
            messagebox.showerror(APP_TITLE, f"No valid scenes found in range {from_num}-{to_num}.")
            return
        
        # Determine which URL to use based on selected model
        selected = self.image_model_var.get()
        if selected == "NanoBanana (Chat)" or not self.selected_image_model:
            target_url = AI_STUDIO_URL
            model_name = "NanoBanana (Chat)"
        else:
            target_url = f"{IMAGEN_BASE_URL}{self.selected_image_model}"
            model_name = selected
        
        # Update UI and start processing
        self.smart_batch_running = True
        self.smart_batch_btn.config(text="🛑 Stop Batch", style="Accent.TButton")
        
        # Show progress log
        if not self.show_progress.get():
            self.show_progress.set(True)
            self.toggle_progress_log()
        
        # Initialize the log
        self.add_progress_log("🚀 Simple Tab Batch Processing started...")
        self.add_progress_log(f"🎯 Using Model: {model_name}")
        self.add_progress_log(f"🌐 Target URL: {target_url}")
        self.add_progress_log(f"📊 Processing {len(valid_scenes)} scenes in separate tabs")
        self.add_progress_log(f"📁 Profile: {os.path.basename(self.profile_dir)}")
        self.add_progress_log(f"⏰ 5-second interval between new tabs")
        self.add_progress_log("-" * 60)
        
        # Start processing in background thread
        self.smart_batch_thread = threading.Thread(
            target=self.run_simple_tab_batch_processing, 
            args=(valid_scenes, target_url), 
            daemon=True
        )
        self.smart_batch_thread.start()
    
    def stop_smart_batch(self):
        """Stop simple tab batch processing"""
        self.smart_batch_running = False
        self.smart_batch_btn.config(text="Smart Batch", style="TButton")
        self.add_progress_log("🛑 Simple Tab Batch Processing stopped by user")
        self.automation_complete(False, "Batch processing stopped by user")
    
    def run_simple_tab_batch_processing(self, scene_numbers, target_url):
        """Simple tab processing - pre-load model, then create one new tab per scene with 5-second intervals"""
        if not selenium_available:
            self.automation_complete(False, "selenium webdriver not installed")
            return
        
        driver = None
        try:
            self.add_progress_log(f"🚀 Starting Simple Tab Processing...")
            self.add_progress_log(f"📑 Processing {len(scene_numbers)} scenes - one tab per scene")
            self.add_progress_log(f"⏰ 5-second interval between new tabs")
            
            # Launch Chrome
            self.update_current_step("Launching Chrome")
            self.add_progress_log("🔧 Launching Chrome...")
            
            driver, wait = self.initialize_chrome_for_batch()
            if not driver:
                self.automation_complete(False, "Failed to launch Chrome")
                return
            
            self.add_progress_log("✅ Chrome launched successfully!")
            
            # Store driver reference
            self.batch_driver = driver
            self.batch_wait = wait
            
            successful_scenes = []
            failed_scenes = []
            
            # STEP 1: Process each scene in a new tab with delay
            self.add_progress_log("\n🆕 STEP 1: Creating new tabs for each scene...")
            
            for i, scene_number in enumerate(scene_numbers):
                if not self.smart_batch_running:
                    self.add_progress_log("🛑 Processing stopped by user")
                    break
                
                self.update_current_step(f"Processing scene {scene_number} ({i+1}/{len(scene_numbers)})")
                self.add_progress_log(f"\n📑 Starting scene {scene_number} ({i+1}/{len(scene_numbers)})...")
                
                # Create new tab with selected model URL directly
                self.add_progress_log(f"🆕 Creating new tab with selected model for scene {scene_number}...")
                driver.execute_script(f"window.open('{target_url}', '_blank');")
                # Switch to the new tab
                driver.switch_to.window(driver.window_handles[-1])
                self.add_progress_log(f"✅ New tab created with model URL (Tab {len(driver.window_handles)})")
                
                # Process this scene in the current tab
                # Only upload images for NanoBanana (chat model), skip for image generation models
                is_nanobanana = (target_url == AI_STUDIO_URL)
                success = self.process_scene_in_simple_tab(scene_number, driver, wait, i+1, upload_images=is_nanobanana)
                
                if success:
                    successful_scenes.append(scene_number)
                    self.add_progress_log(f"✅ Scene {scene_number} completed successfully!")
                else:
                    failed_scenes.append(scene_number)
                    self.add_progress_log(f"❌ Scene {scene_number} failed")
                
                # Wait 5 seconds before next scene (except for last one)
                if i < len(scene_numbers) - 1 and self.smart_batch_running:
                    self.add_progress_log(f"⏰ Waiting 5 seconds before next scene...")
                    time.sleep(5)
            
            # Final summary
            self.add_progress_log("\n" + "=" * 50)
            self.add_progress_log(f"🏁 Simple Tab Processing Complete!")
            self.add_progress_log(f"✅ Successful: {len(successful_scenes)} scenes {successful_scenes}")
            self.add_progress_log(f"❌ Failed: {len(failed_scenes)} scenes {failed_scenes}")
            self.add_progress_log(f"🌐 Browser remains open with {len(driver.window_handles)} tabs total")
            
            if successful_scenes:
                self.automation_complete(True, f"Processing completed! {len(successful_scenes)}/{len(scene_numbers)} scenes successful")
            else:
                self.automation_complete(False, f"Processing failed for all {len(scene_numbers)} scenes")
        
        except Exception as e:
            self.add_progress_log(f"💥 Processing error: {str(e)}")
            self.automation_complete(False, f"Processing failed: {str(e)}")
        finally:
            # Reset UI state but keep browser open
            self.smart_batch_running = False
            self.after(0, lambda: self.smart_batch_btn.config(text="Smart Batch", style="TButton"))
    
    
    def run_smart_batch_processing(self, scene_numbers, prompts_per_tab):
        """Main smart batch processing logic - create separate WebDriver for each batch for TRUE simultaneous processing"""
        if not selenium_available:
            self.automation_complete(False, "selenium webdriver not installed")
            return
        
        try:
            # Group scenes into batches (each batch = prompts_per_tab prompts in separate browser)
            scene_batches = [scene_numbers[i:i+prompts_per_tab] for i in range(0, len(scene_numbers), prompts_per_tab)]
            
            self.add_progress_log(f"🎯 Starting TRUE SIMULTANEOUS batch processing: {len(scene_batches)} separate browsers")
            self.add_progress_log(f"🌐 Each batch will get its OWN WebDriver instance and run TRULY SIMULTANEOUSLY")
            self.add_progress_log(f"🚀 Processing {prompts_per_tab} prompts per browser")
            self.add_progress_log(f"🔥 This enables REAL parallel processing across multiple Chrome instances!")
            
            # STEP 1: Start ALL batches simultaneously with separate WebDrivers
            self.add_progress_log(f"\n🚀 STEP 1: Starting ALL {len(scene_batches)} batches SIMULTANEOUSLY with separate browsers...")
            batch_threads = []
            batch_results = {}
            
            for batch_idx, batch_scenes in enumerate(scene_batches):
                if not self.smart_batch_running:
                    break
                
                self.add_progress_log(f"🔥 Starting SIMULTANEOUS batch {batch_idx + 1} with dedicated browser: {batch_scenes}")
                
                # Start each batch in its own thread with its own WebDriver immediately
                thread = threading.Thread(
                    target=self.process_batch_with_separate_webdriver,
                    args=(batch_scenes, batch_idx, batch_results),
                    daemon=True
                )
                batch_threads.append(thread)
                thread.start()
                
                self.add_progress_log(f"✅ Batch {batch_idx + 1} thread started with dedicated browser - running SIMULTANEOUSLY")
                
                # No delay - launch all browsers truly simultaneously for maximum parallel processing!
            
            self.add_progress_log(f"\n🔥 ALL {len(batch_threads)} BATCHES RUNNING SIMULTANEOUSLY IN SEPARATE BROWSERS!")
            
            # STEP 2: Wait for all batches to complete
            self.add_progress_log(f"⏳ Waiting for all {len(batch_threads)} simultaneous batches to complete...")
            for i, thread in enumerate(batch_threads):
                thread.join()
                self.add_progress_log(f"✅ Batch {i + 1} completed")
            
            # STEP 3: Collect and summarize results
            successful_scenes = []
            failed_scenes = []
            
            for batch_idx in range(len(scene_batches)):
                if batch_idx in batch_results:
                    batch_success, batch_failed = batch_results[batch_idx]
                    successful_scenes.extend(batch_success)
                    failed_scenes.extend(batch_failed)
                    self.add_progress_log(f"📊 Batch {batch_idx + 1}: ✅{len(batch_success)} ❌{len(batch_failed)}")
            
            # Final summary
            self.add_progress_log("\n" + "=" * 60)
            self.add_progress_log(f"🏁 TRUE SIMULTANEOUS BATCH PROCESSING COMPLETE!")
            self.add_progress_log(f"🌐 Processed {len(scene_batches)} batches SIMULTANEOUSLY in {len(scene_batches)} separate browsers")
            self.add_progress_log(f"✅ Total Successful: {len(successful_scenes)} scenes {successful_scenes}")
            self.add_progress_log(f"❌ Total Failed: {len(failed_scenes)} scenes {failed_scenes}")
            
            if successful_scenes:
                self.automation_complete(True, f"Simultaneous batch completed! {len(successful_scenes)}/{len(scene_numbers)} scenes successful")
            else:
                self.automation_complete(False, f"Simultaneous batch failed for all {len(scene_numbers)} scenes")
        
        except Exception as e:
            self.add_progress_log(f"💥 Smart batch error: {str(e)}")
            self.automation_complete(False, f"Smart batch failed: {str(e)}")
        finally:
            # Reset UI state
            self.smart_batch_running = False
            self.after(0, lambda: self.smart_batch_btn.config(text="Smart Batch", style="TButton"))
    
    def process_batch_with_separate_webdriver(self, scene_numbers, batch_idx, results_dict):
        """Process a batch in its own separate WebDriver instance - enables TRUE simultaneous processing"""
        batch_num = batch_idx + 1
        driver = None
        try:
            self.add_progress_log(f"🌐 Browser {batch_num}: Launching dedicated Chrome instance for batch {batch_idx + 1}...")
            
            # Create dedicated WebDriver instance for this batch
            driver, wait = self.initialize_chrome_for_batch()
            if not driver:
                self.add_progress_log(f"❌ Browser {batch_num}: Failed to launch dedicated Chrome instance")
                results_dict[batch_idx] = ([], scene_numbers)
                return
            
            self.add_progress_log(f"✅ Browser {batch_num}: Dedicated Chrome instance launched successfully!")
            
            # Process this specific batch in this dedicated browser
            successful_scenes, failed_scenes = self.process_batch_in_dedicated_browser(
                driver, wait, scene_numbers, batch_num
            )
            
            # Store results
            results_dict[batch_idx] = (successful_scenes, failed_scenes)
            self.add_progress_log(f"🏁 Browser {batch_num}: BATCH processing completed! ✅{len(successful_scenes)} ❌{len(failed_scenes)}")
            
        except Exception as e:
            self.add_progress_log(f"💥 Browser {batch_num} processing error: {str(e)[:100]}")
            results_dict[batch_idx] = ([], scene_numbers)
        finally:
            # Don't close the Chrome instance - keep it open for the user
            if driver:
                try:
                    self.add_progress_log(f"🚀 Browser {batch_num}: Keeping Chrome instance open for continued use")
                    # Register the driver for tracking in the WebDriver Status panel
                    self.register_webdriver_for_tracking(driver, f"batch_{batch_idx}")
                except Exception as cleanup_error:
                    self.add_progress_log(f"⚠️ Browser {batch_num}: Error registering Chrome: {str(cleanup_error)[:50]}")
    
    def process_batch_in_dedicated_browser(self, driver, wait, scene_numbers, browser_num):
        """Process a batch in its dedicated browser - TRUE simultaneous processing with separate WebDriver"""
        try:
            self.add_progress_log(f"🌐 Browser {browser_num}: Starting processing in dedicated Chrome instance...")
            
            # Navigate to AI Studio for this dedicated browser
            self.add_progress_log(f"🌐 Browser {browser_num}: Opening AI Studio in dedicated browser...")
            driver.get(AI_STUDIO_URL)
            self.add_progress_log(f"⏳ Browser {browser_num}: Waiting 10 seconds for page to fully load...")
            time.sleep(10)  # Wait for page to fully load
            
            # Log current page state for debugging
            try:
                current_url = driver.current_url
                page_title = driver.title
                self.add_progress_log(f"🔍 Browser {browser_num}: Page loaded - URL: {current_url[:50]}... Title: {page_title[:30]}...")
            except Exception as e:
                self.add_progress_log(f"⚠️ Browser {browser_num}: Could not get page info: {str(e)[:50]}")
            
            # Check authentication with detailed logging
            self.add_progress_log(f"🔐 Browser {browser_num}: Checking authentication...")
            if not self.check_authentication(driver):
                self.add_progress_log(f"❌ Browser {browser_num}: Authentication failed - skipping this batch")
                return [], scene_numbers
            else:
                self.add_progress_log(f"✅ Browser {browser_num}: Authentication successful")
            
            # Track uploaded characters for this specific browser
            uploaded_chars_this_browser = set()
            successful_scenes = []
            failed_scenes = []
            
            # Process each scene in this dedicated browser sequentially
            for scene_idx, scene_number in enumerate(scene_numbers):
                if not self.smart_batch_running:
                    self.add_progress_log(f"⏹️ Browser {browser_num}: Batch processing stopped by user")
                    break
                
                self.update_current_step(f"Browser {browser_num}: Processing scene {scene_number} ({scene_idx+1}/{len(scene_numbers)})")
                self.add_progress_log(f"\n🎬 Browser {browser_num}: Processing Scene {scene_number} ({scene_idx+1}/{len(scene_numbers)})")
                
                # Process this scene with smart character management
                success = self.process_scene_with_smart_management(
                    driver, wait, scene_number, browser_num, uploaded_chars_this_browser
                )
                
                if success:
                    successful_scenes.append(scene_number)
                    self.add_progress_log(f"✅ Browser {browser_num}: Scene {scene_number} completed successfully!")
                else:
                    failed_scenes.append(scene_number)
                    self.add_progress_log(f"❌ Browser {browser_num}: Scene {scene_number} failed after all retries")
            
            self.add_progress_log(f"📊 Browser {browser_num}: Batch completed - ✅{len(successful_scenes)} ❌{len(failed_scenes)}")
            return successful_scenes, failed_scenes
            
        except Exception as e:
            self.add_progress_log(f"💥 Browser {browser_num}: Critical error in dedicated browser processing: {str(e)[:100]}")
            import traceback
            self.add_progress_log(f"💥 Browser {browser_num}: Full traceback: {traceback.format_exc()[:200]}")
            return [], scene_numbers
    
    def process_batch_in_same_tab(self, driver, wait, scene_numbers, tab_num):
        """Process multiple prompts sequentially in the same tab with smart character management"""
        successful_scenes = []
        failed_scenes = []
        
        # Navigate to AI Studio for this tab
        self.add_progress_log(f"🌐 Opening AI Studio in Tab {tab_num}...")
        driver.get(AI_STUDIO_URL)
        time.sleep(10)
        
        # Check authentication
        if not self.check_authentication(driver):
            self.add_progress_log(f"❌ Tab {tab_num}: Authentication failed - skipping this batch")
            return [], scene_numbers
        
        # Reset uploaded characters for this tab
        uploaded_chars_this_tab = set()
        
        # Process each scene in the batch sequentially
        for scene_idx, scene_number in enumerate(scene_numbers):
            if not self.smart_batch_running:
                break
            
            self.update_current_step(f"Tab {tab_num}: Processing prompt {scene_idx+1}/{len(scene_numbers)} (Scene {scene_number})")
            self.add_progress_log(f"\n🎬 Processing Scene {scene_number} (Tab {tab_num}, prompt {scene_idx+1}/{len(scene_numbers)})")
            
            # Process with retries
            success = self.process_scene_with_smart_management(
                driver, wait, scene_number, tab_num, uploaded_chars_this_tab
            )
            
            if success:
                successful_scenes.append(scene_number)
                self.add_progress_log(f"✅ Scene {scene_number} completed successfully!")
                
                # NO WAITING - continue immediately to next prompt
                # This allows faster processing without waiting for AI responses
                
            else:
                failed_scenes.append(scene_number)
                self.add_progress_log(f"❌ Scene {scene_number} failed after all retries")
        
        return successful_scenes, failed_scenes
    
    def process_scene_with_smart_management(self, driver, wait, scene_number, tab_num, uploaded_chars_this_tab, max_retries=3):
        """Process a single scene with smart character management and retry logic"""
        for attempt in range(max_retries):
            if not self.smart_batch_running:
                self.add_progress_log(f"⏹️ Scene {scene_number}: Processing stopped by user")
                return False
            
            attempt_text = f" (Attempt {attempt+1}/{max_retries})" if attempt > 0 else ""
            self.add_progress_log(f"🔄 Browser {tab_num}: Processing Scene {scene_number}{attempt_text}...")
            
            try:
                # Get scene data with detailed logging
                self.add_progress_log(f"📄 Browser {tab_num}: Getting scene {scene_number} data...")
                scene_data = self.get_scene_data(scene_number)
                if not scene_data:
                    self.add_progress_log(f"❌ Browser {tab_num}: No scene data found for scene {scene_number}")
                    return False
                
                prompt_text, present_chars = scene_data
                self.add_progress_log(f"✅ Browser {tab_num}: Scene {scene_number} data loaded - {len(prompt_text)} chars, {len(present_chars)} characters detected")
                
                # Smart character image upload - only upload NEW characters for this tab
                new_chars = [char for char in present_chars if char not in uploaded_chars_this_tab]
                if new_chars:
                    self.add_progress_log(f"📤 Browser {tab_num}: Scene {scene_number}: Uploading images for new characters: {', '.join(new_chars)}")
                    success = self.upload_and_wait_for_tokens(driver, wait, new_chars, scene_number)
                    if not success:
                        self.add_progress_log(f"⚠️ Browser {tab_num}: Scene {scene_number}: Image upload failed, retrying...")
                        continue
                    
                    # Add to uploaded characters for this tab
                    uploaded_chars_this_tab.update(new_chars)
                    self.add_progress_log(f"✅ Browser {tab_num}: Scene {scene_number}: Successfully uploaded {len(new_chars)} new character types")
                else:
                    self.add_progress_log(f"ℹ️ Browser {tab_num}: Scene {scene_number}: All character images already uploaded in this browser")
                
                # Find textarea and paste prompt with detailed logging
                self.add_progress_log(f"📝 Browser {tab_num}: Scene {scene_number}: Starting prompt paste and submission...")
                success = self.paste_prompt_and_click_run(driver, wait, prompt_text, scene_number)
                if success:
                    self.add_progress_log(f"✅ Browser {tab_num}: Scene {scene_number}: Prompt submitted successfully!")
                    return True
                else:
                    self.add_progress_log(f"⚠️ Browser {tab_num}: Scene {scene_number}: Prompt submission failed")
            
            except Exception as e:
                self.add_progress_log(f"⚠️ Browser {tab_num}: Scene {scene_number} attempt {attempt+1} error: {str(e)[:100]}")
                import traceback
                self.add_progress_log(f"💥 Browser {tab_num}: Scene {scene_number} traceback: {traceback.format_exc()[:200]}")
            
            # Wait before retry
            if attempt < max_retries - 1:
                self.add_progress_log(f"⏰ Browser {tab_num}: Scene {scene_number}: Waiting 5 seconds before retry...")
                time.sleep(5)
        
        self.add_progress_log(f"❌ Browser {tab_num}: Scene {scene_number}: All {max_retries} attempts failed")
        return False
    
    def upload_and_wait_for_tokens(self, driver, wait, new_chars, scene_number):
        """Upload character images and wait for token processing to complete"""
        try:
            # Get image files for new characters
            image_files = []
            for char_id in new_chars:
                ch = next((c for c in self.characters if c["id"] == char_id), None)
                if ch:
                    char_images = [img for img in ch.get("images", []) if os.path.exists(img)]
                    image_files.extend(char_images)
                    self.add_progress_log(f"🖼️ {char_id}: {len(char_images)} images queued")
            
            if not image_files:
                self.add_progress_log("ℹ️ No new character images to upload")
                return True
            
            # Click "Insert Assets" button
            trigger_button = self.wait_for_insert_assets_accessible(driver, wait, timeout=180, interval=5)
            if not trigger_button:
                self.add_progress_log(f"❌ Scene {scene_number}: Insert assets UI not available")
                return False
            driver.execute_script("arguments[0].scrollIntoView(true);", trigger_button)
            ActionChains(driver).move_to_element(trigger_button).click().perform()
            time.sleep(2)
            
            # Upload images
            file_input = wait.until(EC.presence_of_element_located((
                By.XPATH, "//input[@type='file' and @multiple]"
            )))
            all_file_paths = '\n'.join([os.path.abspath(img) for img in image_files])
            file_input.send_keys(all_file_paths)
            
            self.add_progress_log(f"📤 Uploading {len(image_files)} images for {len(new_chars)} new characters...")
            
            # Wait for processing with token detection
            upload_success = self.wait_for_token_processing_complete(driver, len(image_files), scene_number)
            
            # No need to close upload popup - let it stay
            # self.close_upload_popup(driver)  # Removed as requested
            
            return upload_success
        
        except Exception as e:
            self.add_progress_log(f"💥 Image upload failed: {str(e)[:100]}")
            return False
    
    def wait_for_token_processing_complete(self, driver, image_count, scene_number, timeout=90):
        """Wait for token processing to complete and show token count - INSTANT TRIGGER when ready"""
        start_time = time.time()
        last_log_time = 0
        
        while (time.time() - start_time) < timeout:
            try:
                # Check for token count increase
                result = driver.execute_script("""
                    function getTokenCount() {
                        const selectors = ['.v3-token-count-value', '[class*="token-count"]', 'ms-token-count span'];
                        for (let selector of selectors) {
                            let elements = document.querySelectorAll(selector);
                            for (let element of elements) {
                                let text = element.textContent.trim();
                                let match = text.match(/(\\d[\\d,]*)\\s*tokens?/i);
                                if (match) return {count: parseInt(match[1].replace(/,/g, '')), found: true};
                            }
                        }
                        return {count: 0, found: false};
                    }
                    return getTokenCount();
                """)
                
                elapsed = int(time.time() - start_time)
                
                if result and result.get('found', False) and result.get('count', 0) > 0:
                    token_count = result.get('count', 0)
                    self.add_progress_log(f"🎯 Scene {scene_number}: Tokens processed successfully: {token_count} tokens - RUNNING INSTANTLY!")
                    # NO WAITING - return immediately when tokens are ready
                    return True
                elif elapsed - last_log_time >= 10:
                    self.add_progress_log(f"⏰ Scene {scene_number}: Still processing tokens... ({elapsed}s elapsed)")
                    last_log_time = elapsed
                
                time.sleep(2)
            except:
                time.sleep(2)
        
        self.add_progress_log(f"⚠️ Scene {scene_number}: Token processing timeout after {timeout}s, continuing anyway...")
        return True
    
    def wait_for_tokens_and_trigger(self, driver, chat_input, scene_number, tab_number, timeout=90):
        """Wait for tokens to be processed and immediately trigger with Ctrl+Enter when ready"""
        start_time = time.time()
        last_log_time = 0
        
        self.add_progress_log(f"🎯 Tab {tab_number}: Waiting for tokens and will auto-trigger for scene {scene_number}...")
        
        while (time.time() - start_time) < timeout:
            try:
                # Check for token count increase
                result = driver.execute_script("""
                    function getTokenCount() {
                        const selectors = ['.v3-token-count-value', '[class*="token-count"]', 'ms-token-count span'];
                        for (let selector of selectors) {
                            let elements = document.querySelectorAll(selector);
                            for (let element of elements) {
                                let text = element.textContent.trim();
                                let match = text.match(/(\\d[\\d,]*)\\s*tokens?/i);
                                if (match) return {count: parseInt(match[1].replace(/,/g, '')), found: true};
                            }
                        }
                        return {count: 0, found: false};
                    }
                    return getTokenCount();
                """)
                
                elapsed = int(time.time() - start_time)
                
                if result and result.get('found', False) and result.get('count', 0) > 0:
                    token_count = result.get('count', 0)
                    self.add_progress_log(f"🎯 Tab {tab_number}: Tokens ready ({token_count} tokens) - AUTO-TRIGGERING scene {scene_number}!")
                    
                    # Focus textarea and immediately trigger
                    try:
                        driver.execute_script("arguments[0].focus();", chat_input)
                        chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                        self.add_progress_log(f"🚀 Tab {tab_number}: Scene {scene_number} auto-triggered immediately after token processing!")
                        return True
                    except Exception as trigger_error:
                        try:
                            # Fallback method
                            action = ActionChains(driver)
                            action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                            self.add_progress_log(f"🚀 Tab {tab_number}: Scene {scene_number} auto-triggered with ActionChains!")
                            return True
                        except Exception as fallback_error:
                            self.add_progress_log(f"❌ Tab {tab_number}: Failed to auto-trigger scene {scene_number}: {str(fallback_error)[:50]}")
                            return False
                elif elapsed - last_log_time >= 5:
                    self.add_progress_log(f"⏰ Tab {tab_number}: Still waiting for tokens... ({elapsed}s elapsed)")
                    last_log_time = elapsed
                
                time.sleep(1)  # Check more frequently for faster response
            except:
                time.sleep(1)
        
        self.add_progress_log(f"⚠️ Tab {tab_number}: Token timeout for scene {scene_number}, will trigger manually")
        return False  # Return False so manual trigger can be attempted
    
    def wait_for_run_ready(self, driver, scene_number, timeout=900):
        """Wait for Run button to be available (not Stop) - minimum 900s for image generation"""
        start_time = time.time()
        
        while (time.time() - start_time) < timeout:
            try:
                # Check if there's a Stop button (indicating AI is running)
                stop_button_exists = driver.execute_script("""
                    const stopSelectors = [
                        'button[aria-label*="Stop"]',
                        'button[aria-label*="stop"]', 
                        'button[title*="Stop"]',
                        'button[title*="stop"]',
                        'button[class*="stop"]'
                    ];
                    
                    for (let selector of stopSelectors) {
                        let elements = document.querySelectorAll(selector);
                        for (let element of elements) {
                            if (element && element.offsetParent !== null && !element.disabled) {
                                return true;
                            }
                        }
                    }
                    return false;
                """)
                
                if not stop_button_exists:
                    self.add_progress_log(f"✅ Scene {scene_number}: Ready to paste (no Stop button detected)")
                    return True
                
                elapsed = int(time.time() - start_time)
                if elapsed % 5 == 0:  # Log every 5 seconds
                    self.add_progress_log(f"⏰ Scene {scene_number}: Waiting for Stop button to disappear... ({elapsed}s)")
                
                time.sleep(1)
            except Exception as e:
                self.add_progress_log(f"⚠️ Scene {scene_number}: Stop check error: {str(e)[:50]}")
                time.sleep(2)
        
        self.add_progress_log(f"⚠️ Scene {scene_number}: Timeout waiting for Run ready, proceeding anyway...")
        return True
    
    def paste_prompt_and_click_run(self, driver, wait, prompt_text, scene_number):
        """Wait for Run ready, paste prompt text, then select Aspect Ratio and use Ctrl+Enter to run"""
        try:
            # First wait for the tab to be ready (no Stop button)
            self.add_progress_log(f"🔍 Scene {scene_number}: Checking if tab is ready for new prompt...")
            if not self.wait_for_run_ready(driver, scene_number):
                return False
            
            # Find textarea
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            for selector in textarea_selectors:
                try:
                    chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                    break
                except:
                    continue
            
            if not chat_input:
                self.add_progress_log(f"❌ Scene {scene_number}: Could not find textarea")
                return False
            
            # Clear and paste prompt
            driver.execute_script("arguments[0].scrollIntoView(true);", chat_input)
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            # Paste entire prompt in one shot
            success_paste = self.paste_text_all_at_once(driver, chat_input, prompt_text)
            if not success_paste:
                self.add_progress_log(f"❌ Scene {scene_number}: Failed to paste prompt")
                return False
            
            # Wait 2 seconds after pasting and prepare WebDriver-based monitoring
         # Wait 2 seconds after pasting and prepare WebDriver-based monitoring
            try:
                current_handle = driver.current_window_handle
                tab_index = driver.window_handles.index(current_handle) + 1
            except:
                tab_index = 1
            
            # Select Aspect Ratio before triggering run
            try:
                selected_label = self.aspect_ratio_var.get() if hasattr(self, "aspect_ratio_var") else "YouTube 16:9"
                self.add_progress_log(f"🎛️ Scene {scene_number}: Selecting aspect ratio: {selected_label}")
                # Use NanoBanana selection for Run Single button
                self.select_aspect_ratio_in_ai_studio(driver, is_image_model=False)
                time.sleep(1)  # brief wait for menu selection to apply
            except Exception as e:
                self.add_progress_log(f"⚠️ Scene {scene_number}: Aspect ratio selection skipped or failed: {str(e)[:50]}")
            
            self.add_progress_log(f"⏰ Scene {scene_number}: Waiting 2 seconds before sending Ctrl+Enter...")
            time.sleep(2)
            
            # Focus the textarea and send Ctrl+Enter
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            try:
                # Primary method: Use WebElement send_keys
                chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                self.add_progress_log(f"🚀 Scene {scene_number}: Ctrl+Enter sent successfully!")
                
                # Auto-download removed - user will download manually
                self.add_progress_log(f"✅ Scene {scene_number}: Prompt triggered successfully! Use 'Download Images' for manual download.")
                
                return True
            except Exception as primary_error:
                self.add_progress_log(f"⚠️ Scene {scene_number}: Primary Ctrl+Enter failed: {str(primary_error)[:50]}")
                try:
                    # Fallback method: Use ActionChains
                    action = ActionChains(driver)
                    action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                    self.add_progress_log(f"🚀 Scene {scene_number}: Ctrl+Enter sent successfully (fallback)!")
                    
                    # Auto-download removed - user will download manually
                    self.add_progress_log(f"✅ Scene {scene_number}: Prompt triggered successfully (fallback)! Use 'Download Images' for manual download.")
                    
                    return True
                except Exception as fallback_error:
                    self.add_progress_log(f"❌ Scene {scene_number}: Both Ctrl+Enter methods failed: {str(fallback_error)[:50]}")
                    return False
        
        except Exception as e:
            self.add_progress_log(f"❌ Scene {scene_number}: Failed to submit prompt: {str(e)[:50]}")
            return False
    
    def wait_for_ai_response_completion(self, driver, scene_number, timeout=45):
        """Wait for AI response to complete before processing next prompt in same tab"""
        self.add_progress_log(f"⏳ Scene {scene_number}: Waiting for AI response to complete...")
        start_time = time.time()
        
        while (time.time() - start_time) < timeout:
            try:
                # Check for response completion indicators
                is_responding = driver.execute_script("""
                    // Look for loading indicators, generating text, or disabled send buttons
                    const indicators = [
                        '[class*="generating"]',
                        '[class*="loading"]', 
                        '[class*="thinking"]',
                        '[aria-label*="generating"]',
                        '[aria-label*="Generating"]',
                        'button[disabled][aria-label*="send"]',
                        'button[disabled][aria-label*="Send"]'
                    ];
                    
                    for (let selector of indicators) {
                        if (document.querySelector(selector)) return true;
                    }
                    return false;
                """)
                
                if not is_responding:
                    self.add_progress_log(f"✅ Scene {scene_number}: AI response completed, ready for next prompt")
                    time.sleep(2)  # Brief pause before next prompt
                    return
                
                time.sleep(2)
            except:
                time.sleep(2)
        
        self.add_progress_log(f"⏰ Scene {scene_number}: Response timeout, continuing to next prompt...")
    
    def process_scene_with_retries(self, driver, wait, scene_number, batch_num, max_retries=3):
        """Process a single scene with retry logic"""
        for attempt in range(max_retries):
            if not self.smart_batch_running:
                return False
            
            attempt_text = f" (Attempt {attempt+1}/{max_retries})" if attempt > 0 else ""
            self.add_progress_log(f"🔄 Processing scene {scene_number}{attempt_text}...")
            
            try:
                # Get scene data
                scene_data = self.get_scene_data(scene_number)
                if not scene_data:
                    return False
                
                prompt_text, present_chars = scene_data
                
                # Smart character image upload - only upload NEW characters
                new_chars = self.get_new_characters(present_chars)
                if new_chars:
                    self.add_progress_log(f"📤 Scene {scene_number}: Uploading images for new characters: {', '.join(new_chars)}")
                    success = self.upload_new_character_images(driver, wait, new_chars)
                    if not success:
                        self.add_progress_log(f"⚠️ Scene {scene_number}: Image upload failed, retrying...")
                        continue
                    
                    # Add to uploaded characters
                    self.current_uploaded_chars.update(new_chars)
                else:
                    self.add_progress_log(f"ℹ️ Scene {scene_number}: All character images already uploaded")
                
                # Find textarea and paste prompt
                success = self.paste_and_trigger_prompt(driver, wait, prompt_text, scene_number)
                if success:
                    # Wait for AI response to complete before next prompt
                    self.wait_for_ai_response(driver, scene_number)
                    return True
                else:
                    self.add_progress_log(f"⚠️ Scene {scene_number}: Prompt submission failed")
            
            except Exception as e:
                self.add_progress_log(f"⚠️ Scene {scene_number} attempt {attempt+1} error: {str(e)[:100]}")
            
            # Wait before retry
            if attempt < max_retries - 1:
                self.add_progress_log(f"⏰ Waiting 5 seconds before retry...")
                time.sleep(5)
        
        return False
    
    def get_scene_data(self, scene_number):
        """Get scene prompt text and character list in JSON structure format"""
        scenes = self.data.get("output_structure", {}).get("scenes", [])
        target_scene = next((s for s in scenes if str(s.get("scene_number")) == str(scene_number)), None)
        
        if not target_scene:
            self.add_progress_log(f"❌ Scene {scene_number} not found in data")
            return None
        
        # Get current prompt text
        if scene_number in self.modified_prompts:
            current_prompt = self.modified_prompts[scene_number]
        else:
            # Use the scene JSON object as the prompt, but strip voice_scripts first
            filtered_scene = self.strip_voice_scripts(target_scene)
            current_prompt = json.dumps(filtered_scene, ensure_ascii=False, indent=2)
        
        if not current_prompt.strip():
            self.add_progress_log(f"❌ Scene {scene_number} has no prompt text")
            return None
        
        # Detect characters in current prompt
        present_chars = [c["id"] for c in self.characters if c["id"] in current_prompt]
        
        # Build simple JSON structure with only current prompt and (optionally) previous scenes
        prompt_json = {
            "previous_scenes_context": [],
            "current_prompt_to_proceed": {
                "scene_number": int(scene_number),
                "prompt": current_prompt
            }
        }
        
        # Determine whether to include previous 5 prompts based on GUI toggle and model type
        include_history = True
        try:
            is_image_model = bool(getattr(self, 'selected_image_model', None))
            if is_image_model and hasattr(self, 'include_history_var') and not self.include_history_var.get():
                include_history = False
        except Exception:
            include_history = True
        
        if include_history:
            # Add previous scenes context (up to 5 previous scenes)
            current_scene_num = int(scene_number)
            for i in range(1, 6):
                prev_scene_num = current_scene_num - i
                if prev_scene_num < 1:
                    break
                    
                prev_scene = next((s for s in scenes if str(s.get("scene_number")) == str(prev_scene_num)), None)
                if prev_scene:
                    if prev_scene_num in self.modified_prompts:
                        prev_prompt = self.modified_prompts[prev_scene_num]
                    else:
                        # Format previous prompts properly too
                        is_dash_story = 'character_reference' in self.data and 'output_structure' in self.data
                        if is_dash_story:
                            prev_prompt = ""
                            if prev_scene.get("emotion"):
                                prev_prompt += f"Emotion: {prev_scene.get('emotion')}\n\n"
                            prev_prompt += prev_scene.get("prompt", "")
                            if prev_scene.get("negative_prompt"):
                                prev_prompt += f"\n\nNegative Prompt: {prev_scene.get('negative_prompt')}"
                        else:
                            # Use previous scene JSON but strip voice_scripts before dumping
                            prev_prompt = json.dumps(self.strip_voice_scripts(prev_scene), ensure_ascii=False, indent=2)
                    
                    # Add to previous scenes context
                    prompt_json["previous_scenes_context"].append({
                        "scene_number": prev_scene_num,
                        "prompt": prev_prompt
                    })
            
            # Reverse to have chronological order (oldest to newest)
            prompt_json["previous_scenes_context"].reverse()
        
        # Convert to JSON string with proper formatting
        final_prompt = json.dumps(prompt_json, ensure_ascii=False, indent=2)
        
        self.add_progress_log(f"📝 Scene {scene_number}: Clean prompt with {len(prompt_json['previous_scenes_context'])} previous scenes (no internal modifications)")
        
        return (final_prompt, present_chars)
    
    def get_all_characters_reference(self):
        """Get all character details for reference at the top of prompts"""
        if not self.characters:
            return ""
        
        char_details = []
        char_details.append("=== ALL CHARACTER REFERENCE (For AI Context) ===")
        
        for char in self.characters:
            char_id = char.get('id', 'Unknown')
            char_name = char.get('name', char_id)
            
            # Get character data from JSON for detailed info
            char_info = self.get_character_full_details(char_id)
            
            if char_info:
                char_details.append(f"\nCharacter: {char_id}")
                if char_name and char_name != char_id:
                    char_details.append(f"Name: {char_name}")
                char_details.append(char_info)
            else:
                char_details.append(f"\nCharacter: {char_id} (Name: {char_name})")
        
        return "\n".join(char_details) if len(char_details) > 1 else ""
    
    def get_characters_details_for_prompt(self, present_chars):
        """Get detailed character information for characters present in current prompt"""
        if not present_chars:
            return ""
        
        char_details = []
        char_details.append(f"\n\n=== CHARACTER DETAILS FOR CURRENT SCENE ({', '.join(present_chars)}) ===")
        
        for char_id in present_chars:
            char_info = self.get_character_full_details(char_id)
            char = next((c for c in self.characters if c["id"] == char_id), None)
            
            if char:
                char_name = char.get('name', char_id)
                char_details.append(f"\n--- {char_id} ---")
                if char_name and char_name != char_id:
                    char_details.append(f"Name: {char_name}")
                
                if char_info:
                    char_details.append(char_info)
                else:
                    char_details.append("(Basic character reference - no detailed description available)")
                    
                # Add image count info
                image_count = len(char.get('images', []))
                char_details.append(f"Images available: {image_count}")
        
        return "\n".join(char_details) if len(char_details) > 1 else ""
    
    def get_character_full_details(self, char_id):
        """Extract full character details from the JSON data"""
        try:
            # Check if this is dash_story format
            if 'character_reference' in self.data and isinstance(self.data['character_reference'], list):
                # New dash_story.json format
                for char_ref in self.data['character_reference']:
                    if isinstance(char_ref, dict) and char_ref.get('id') == char_id:
                        details = []
                        
                        # Add all available character details
                        for key, value in char_ref.items():
                            if key not in ['id', 'name', 'images'] and value:
                                if isinstance(value, (str, int, float)):
                                    details.append(f"{key.replace('_', ' ').title()}: {value}")
                                elif isinstance(value, list):
                                    details.append(f"{key.replace('_', ' ').title()}: {', '.join(map(str, value))}")
                                elif isinstance(value, dict):
                                    details.append(f"{key.replace('_', ' ').title()}: {json.dumps(value, ensure_ascii=False)}")
                        
                        return "\n".join(details) if details else ""
            else:
                # Original format
                char_ref = self.data.get("character_reference", {})
                
                # Check main character
                main_char = char_ref.get("main_character", {})
                if isinstance(main_char, dict) and main_char.get("id") == char_id:
                    return self.extract_character_details(main_char)
                
                # Check secondary characters
                secondary_chars = char_ref.get("secondary_characters", [])
                for char_data in secondary_chars:
                    if isinstance(char_data, dict) and char_data.get("id") == char_id:
                        return self.extract_character_details(char_data)
            
            return ""
            
        except Exception as e:
            self.add_progress_log(f"⚠️ Error extracting character details for {char_id}: {str(e)[:50]}")
            return ""
    
    def extract_character_details(self, char_data):
        """Extract character details from character data dictionary"""
        details = []
        
        # Skip basic fields and focus on descriptive content
        skip_keys = ['id', 'name', 'images', 'key_path']
        
        for key, value in char_data.items():
            if key not in skip_keys and value:
                if isinstance(value, str) and len(value.strip()) > 0:
                    details.append(f"{key.replace('_', ' ').title()}: {value}")
                elif isinstance(value, list) and len(value) > 0:
                    details.append(f"{key.replace('_', ' ').title()}: {', '.join(map(str, value))}")
                elif isinstance(value, dict):
                    # For nested dictionaries, format nicely
                    dict_details = []
                    for subkey, subvalue in value.items():
                        if subvalue:
                            dict_details.append(f"{subkey}: {subvalue}")
                    if dict_details:
                        details.append(f"{key.replace('_', ' ').title()}: {' | '.join(dict_details)}")
        
        return "\n".join(details) if details else ""
    
    def get_new_characters(self, present_chars):
        """Get list of characters that haven't been uploaded in current tab yet"""
        return [char for char in present_chars if char not in self.current_uploaded_chars]
    
    def upload_new_character_images(self, driver, wait, new_chars):
        """Upload images for new characters only"""
        try:
            # Get image files for new characters
            image_files = []
            for char_id in new_chars:
                ch = next((c for c in self.characters if c["id"] == char_id), None)
                if ch:
                    char_images = [img for img in ch.get("images", []) if os.path.exists(img)]
                    image_files.extend(char_images)
                    self.add_progress_log(f"🖼️ {char_id}: {len(char_images)} images queued")
            
            if not image_files:
                self.add_progress_log("ℹ️ No new character images to upload")
                return True
            
            # Trigger file picker using new menu workflow
            picker_ready = self.wait_for_insert_assets_accessible(driver, wait, timeout=180, interval=5)
            if not picker_ready:
                self.add_progress_log("❌ File picker not available for new character upload")
                return False
            time.sleep(1)
            
            # Upload images using correct selector
            file_input = wait.until(EC.presence_of_element_located((
                By.CSS_SELECTOR, "input[data-test-upload-file-input]"
            )))
            all_file_paths = '\n'.join([os.path.abspath(img) for img in image_files])
            file_input.send_keys(all_file_paths)
            
            self.add_progress_log(f"📤 Uploading {len(image_files)} images for {len(new_chars)} new characters...")
            
            # Wait for processing with timeout
            upload_success = self.wait_for_image_processing(driver, len(image_files))
            
            # No need to close upload popup - let it stay
            # self.close_upload_popup(driver)  # Removed as requested
            
            return upload_success
        
        except Exception as e:
            self.add_progress_log(f"💥 Image upload failed: {str(e)[:100]}")
            return False
    
    def wait_for_image_processing(self, driver, image_count, timeout=60):
        """Wait for image processing to complete"""
        start_time = time.time()
        last_log_time = 0
        
        while (time.time() - start_time) < timeout:
            try:
                # Check for token count increase
                result = driver.execute_script("""
                    function getTokenCount() {
                        const selectors = ['.v3-token-count-value', '[class*="token-count"]', 'ms-token-count span'];
                        for (let selector of selectors) {
                            let elements = document.querySelectorAll(selector);
                            for (let element of elements) {
                                let text = element.textContent.trim();
                                let match = text.match(/(\\d[\\d,]*)\\s*tokens?/i);
                                if (match) return {count: parseInt(match[1].replace(/,/g, '')), found: true};
                            }
                        }
                        return {count: 0, found: false};
                    }
                    return getTokenCount();
                """)
                
                elapsed = int(time.time() - start_time)
                
                if result and result.get('found', False) and result.get('count', 0) > 0:
                    token_count = result.get('count', 0)
                    self.add_progress_log(f"✅ Images processed successfully: {token_count} tokens")
                    return True
                elif elapsed - last_log_time >= 10:
                    self.add_progress_log(f"⏰ Still processing images... ({elapsed}s elapsed)")
                    last_log_time = elapsed
                
                time.sleep(2)
            except:
                time.sleep(2)
        
        self.add_progress_log(f"⚠️ Image processing timeout after {timeout}s, continuing anyway...")
        return True  # Continue even if we can't confirm processing
    
    def paste_and_trigger_prompt(self, driver, wait, prompt_text, scene_number):
        """Paste prompt and trigger AI response"""
        try:
            # Find textarea
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            for selector in textarea_selectors:
                try:
                    chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                    break
                except:
                    continue
            
            if not chat_input:
                self.add_progress_log(f"❌ Scene {scene_number}: Could not find textarea")
                return False
            
            # Clear and paste prompt
            driver.execute_script("arguments[0].scrollIntoView(true);", chat_input)
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            # Paste entire prompt in one shot
            success_paste = self.paste_text_all_at_once(driver, chat_input, prompt_text)
            if not success_paste:
                self.add_progress_log(f"❌ Scene {scene_number}: Failed to paste prompt")
                return False
            
            # Select Aspect Ratio before triggering run
            try:
                selected_label = self.aspect_ratio_var.get() if hasattr(self, "aspect_ratio_var") else "YouTube 16:9"
                self.add_progress_log(f"🎛️ Scene {scene_number}: Selecting aspect ratio: {selected_label}")
                # Default to NanoBanana style unless overridden in call site
                self.select_aspect_ratio_in_ai_studio(driver, is_image_model=False)
                time.sleep(1)
            except Exception as e:
                self.add_progress_log(f"⚠️ Scene {scene_number}: Aspect ratio selection skipped or failed: {str(e)[:50]}")
            
            # Trigger AI response
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            try:
                chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                self.add_progress_log(f"🚀 Scene {scene_number}: AI response triggered")
                return True
            except:
                # Fallback method
                action = ActionChains(driver)
                action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                self.add_progress_log(f"🚀 Scene {scene_number}: AI response triggered (fallback)")
                return True
        
        except Exception as e:
            self.add_progress_log(f"❌ Scene {scene_number}: Prompt submission failed: {str(e)[:50]}")
            return False
    
    def wait_for_ai_response(self, driver, scene_number, timeout=30):
        """Wait for AI response to complete before next prompt"""
        self.add_progress_log(f"⏳ Scene {scene_number}: Waiting for AI response...")
        start_time = time.time()
        
        while (time.time() - start_time) < timeout:
            try:
                # Check for response completion indicators
                is_responding = driver.execute_script("""
                    // Look for loading indicators, generating text, or disabled send buttons
                    const indicators = [
                        '[class*="generating"]',
                        '[class*="loading"]',
                        '[aria-label*="generating"]',
                        'button[disabled][aria-label*="send"]'
                    ];
                    
                    for (let selector of indicators) {
                        if (document.querySelector(selector)) return true;
                    }
                    return false;
                """)
                
                if not is_responding:
                    self.add_progress_log(f"✅ Scene {scene_number}: AI response completed")
                    time.sleep(2)  # Brief pause before next prompt
                    return
                
                time.sleep(1)
            except:
                time.sleep(1)
        
        self.add_progress_log(f"⏰ Scene {scene_number}: Response timeout, continuing...")
    
    
    def close_upload_popup(self, driver):
        """Close any upload popups"""
        try:
            popup_closed = driver.execute_script("""
                const selectors = ['button[aria-label*="close"]', 'button[aria-label*="Close"]', 
                                 'button[title*="close"]', 'button[title*="Close"]'];
                for (let selector of selectors) {
                    let elements = document.querySelectorAll(selector);
                    for (let element of elements) {
                        if (element && element.offsetParent !== null) {
                            element.click(); return true;
                        }
                    }
                }
                return false;
            """)
            if popup_closed:
                self.add_progress_log("✅ Upload popup closed")
        except:
            pass
    
    def select_aspect_ratio_in_ai_studio(self, driver, is_image_model=False):
        """Select aspect ratio - different methods for NanoBanana vs Image Models.
        
        Args:
            is_image_model: If True, use button-based selection for image models.
                           If False, use mat-select dropdown for NanoBanana.
        """
        # Determine desired text from UI selection
        selected_label = self.aspect_ratio_var.get() if hasattr(self, 'aspect_ratio_var') else 'YouTube 16:9'
        desired_text = '16:9' if '16:9' in selected_label else '9:16'
        
        # Use different selection method based on model type
        if is_image_model:
            return self._select_aspect_ratio_image_model(driver, desired_text)
        else:
            return self._select_aspect_ratio_nanobanana(driver, desired_text)
    
    def _select_aspect_ratio_image_model(self, driver, desired_text):
        """Select aspect ratio for image generation models using button-based UI"""
        try:
            self.add_progress_log(f"🎛️ Selecting aspect ratio {desired_text} for Image Model...")
            
            # JavaScript to find and click the aspect ratio button
            js = f"""
                // Find all aspect ratio buttons
                const buttons = document.querySelectorAll('ms-aspect-ratio-radio-button button');
                
                for (let button of buttons) {{
                    // Check if button text contains the desired ratio
                    const textDiv = button.querySelector('.aspect-ratio-text');
                    if (textDiv && textDiv.textContent.trim() === '{desired_text}') {{
                        button.click();
                        return true;
                    }}
                }}
                
                // Fallback: try broader search
                const allButtons = document.querySelectorAll('button');
                for (let button of allButtons) {{
                    if (button.textContent.includes('{desired_text}') && 
                        button.className.includes('aspect-ratio')) {{
                        button.click();
                        return true;
                    }}
                }}
                
                return false;
            """
            
            result = driver.execute_script(js)
            
            if result:
                self.add_progress_log(f"✅ Aspect ratio {desired_text} selected successfully (Image Model)")
                return True
            else:
                self.add_progress_log(f"⚠️ Could not find aspect ratio button for {desired_text} (Image Model)")
                return False
                
        except Exception as e:
            self.add_progress_log(f"⚠️ Aspect ratio selection failed for Image Model: {str(e)[:50]}")
            return False
    
    def _select_aspect_ratio_nanobanana(self, driver, desired_text):
        """Select aspect ratio for NanoBanana using mat-select dropdown"""
        
        def try_in_current_context():
            try:
                # Try several CSS selectors for the dropdown
                candidates = [
                    'mat-select[aria-label="Aspect ratio"]',
                    'mat-select[aria-label="Aspect Ratio"]',
                    'mat-select[aria-label*="Aspect"]',
                ]
                dropdown = None
                for css in candidates:
                    try:
                        el = driver.find_element(By.CSS_SELECTOR, css)
                        if el and el.is_displayed():
                            dropdown = el
                            break
                    except:
                        continue
                if not dropdown:
                    return False
                # Click via Selenium to simulate a user gesture
                ActionChains(driver).move_to_element(dropdown).click().perform()
                # Wait for overlay options to appear
                try:
                    opts = WebDriverWait(driver, 3).until(
                        EC.presence_of_all_elements_located((By.CSS_SELECTOR, '.cdk-overlay-container mat-option'))
                    )
                except Exception:
                    # Some apps render options without .cdk-overlay-container
                    opts = driver.find_elements(By.CSS_SELECTOR, 'mat-option')
                # Find target by text contains
                target = None
                for o in opts:
                    try:
                        if o.is_displayed() and desired_text in (o.text or '').strip():
                            target = o
                            break
                        # Some Material versions put text inside .mat-option-text
                        spans = o.find_elements(By.CSS_SELECTOR, '.mat-option-text')
                        for sp in spans:
                            if desired_text in (sp.text or '').strip():
                                target = o
                                break
                        if target:
                            break
                    except:
                        continue
                if not target:
                    # Last resort: query via JS from overlay
                    try:
                        js = """
                            const overlays = document.querySelectorAll('.cdk-overlay-container mat-option');
                            for (const opt of overlays) {
                              const t = (opt.innerText || '').trim();
                              if (t.includes(arguments[0])) { opt.click(); return true; }
                            }
                            const all = document.querySelectorAll('mat-option');
                            for (const opt of all) {
                              const t = (opt.innerText || '').trim();
                              if (t.includes(arguments[0])) { opt.click(); return true; }
                            }
                            return false;
                        """
                        ok = driver.execute_script(js, desired_text)
                        return bool(ok)
                    except:
                        return False
                # Click the target option
                try:
                    ActionChains(driver).move_to_element(target).click().perform()
                except:
                    driver.execute_script('arguments[0].click();', target)
                return True
            except Exception:
                return False
        
        # Try in default content
        driver.switch_to.default_content()
        if try_in_current_context():
            return True
        
        # Try each iframe
        frames = driver.find_elements(By.TAG_NAME, 'iframe')
        for idx, fr in enumerate(frames):
            try:
                driver.switch_to.default_content()
                driver.switch_to.frame(fr)
                if try_in_current_context():
                    # Switch back to default to keep later steps consistent
                    driver.switch_to.default_content()
                    return True
            except Exception:
                continue
        
        # Fallback: JS that searches broadly in whatever context we're in
        try:
            driver.switch_to.default_content()
            js = """
                const openAndPick = (desired) => {
                  const selects = Array.from(document.querySelectorAll('mat-select'));
                  const targetSel = selects.find(s => {
                    const al = (s.getAttribute('aria-label')||'').toLowerCase();
                    return al.includes('aspect');
                  });
                  if (!targetSel) return false;
                  targetSel.click();
                  setTimeout(() => {
                    const overlayOpts = Array.from(document.querySelectorAll('.cdk-overlay-container mat-option'));
                    const all = overlayOpts.length ? overlayOpts : Array.from(document.querySelectorAll('mat-option'));
                    const hit = all.find(o => (o.innerText||'').trim().includes(desired));
                    if (hit) hit.click();
                  }, 300);
                  return true;
                };
                return openAndPick(arguments[0]);
            """
            ok = driver.execute_script(js, desired_text)
            time.sleep(0.6)
            return bool(ok)
        except Exception:
            return False
    
    def select_aspect_ratio_selenium_fallback(self, driver, desired_text):
        """Deprecated: kept for compatibility; selection now handled in select_aspect_ratio_in_ai_studio"""
        try:
            return False
        except Exception:
            return False
        
    
    def check_authentication(self, driver):
        """Check if user is authenticated"""
        try:
            page_title = driver.title.lower()
            current_url = driver.current_url.lower()
            
            self.add_progress_log(f"🔍 Authentication check - Title: '{page_title[:50]}', URL: '{current_url[:50]}'")
            
            # Check for authentication indicators
            auth_indicators = ['sign in', 'login', 'authenticate', 'access denied', 'unauthorized']
            needs_auth = any(indicator in page_title for indicator in auth_indicators)
            is_login_page = 'accounts.google.com' in current_url or 'login' in current_url
            
            if needs_auth or is_login_page:
                self.add_progress_log(f"⚠️ Authentication required - found indicators: needs_auth={needs_auth}, is_login_page={is_login_page}")
                return False
            
            # Check if we're actually on AI Studio
            if 'aistudio.google.com' not in current_url:
                self.add_progress_log(f"⚠️ Not on AI Studio - URL: {current_url}")
                return False
            
            self.add_progress_log(f"✅ Authentication successful - on AI Studio")
            return True
        except Exception as e:
            self.add_progress_log(f"⚠️ Authentication check error: {str(e)[:50]}")
            return False
    
    def initialize_chrome_for_batch(self):
        """Initialize Chrome for batch processing with thread synchronization"""
        global _chrome_init_lock
        
        if not _chrome_init_lock:
            self.add_progress_log("⚠️ Chrome lock not available - proceeding without synchronization")
            return self._create_chrome_instance()
        
        # Use thread lock to prevent concurrent initialization conflicts
        with _chrome_init_lock:
            self.add_progress_log("🔒 Acquired Chrome initialization lock")
            driver, wait = self._create_chrome_instance()
            # Brief delay to prevent rapid successive initializations
            time.sleep(1)
            self.add_progress_log("🔓 Released Chrome initialization lock")
            return driver, wait
    
    def _create_chrome_instance(self):
        """Create a single Chrome instance using regular selenium ChromeDriver"""
        try:
            # Setup Chrome options - using regular selenium ChromeOptions
            from selenium.webdriver.chrome.options import Options
            options = Options()
            
            # Always use the current project directory for user data
            user_data_dir = os.path.join(os.getcwd(), "User Data")
            
            # Get current profile name or default to Profile 18
            current_profile_name = self.get_current_profile_name()
            if not current_profile_name or current_profile_name == "Profile 18":
                profile_name = "Profile 18"
            else:
                profile_name = current_profile_name
            
            # Set profile directory and create if not exists
            self.profile_dir = os.path.join(user_data_dir, profile_name)
            os.makedirs(self.profile_dir, exist_ok=True)
            
            self.add_progress_log(f"📁 Using profile: {profile_name} at {user_data_dir}")
            
            # Chrome arguments for better automation (fixed)
            options.add_argument(f"--user-data-dir={user_data_dir}")
            options.add_argument(f"--profile-directory={profile_name}")
            options.add_argument("--start-maximized")
            options.add_argument("--no-sandbox")
            options.add_argument("--disable-dev-shm-usage")
            options.add_argument("--disable-blink-features=AutomationControlled")
            options.add_argument("--log-level=3")
            
            # IMPORTANT: Add detach option to keep Chrome running after Python closes
            options.add_experimental_option("detach", True)
            
            # Add experimental options for better automation
            options.add_experimental_option("excludeSwitches", ["enable-automation"])
            options.add_experimental_option('useAutomationExtension', False)
            
            # Add preferences to prevent popups and improve stability
            prefs = {
                "profile.default_content_settings.popups": 0,
                "profile.default_content_setting_values.notifications": 2,
            }
            options.add_experimental_option("prefs", prefs)
            
            self.add_progress_log(f"🔧 Chrome arguments: --user-data-dir={user_data_dir}, --profile-directory={profile_name}")
            
            # Launch Chrome with enhanced error handling using regular selenium
            try:
                driver = webdriver.Chrome(options=options)
                wait = WebDriverWait(driver, 15)
                self.add_progress_log("✅ Chrome initialized successfully!")
                return driver, wait
            except Exception as chrome_error:
                # If Chrome fails, wait a moment and try once more
                self.add_progress_log(f"⚠️ First Chrome launch attempt failed: {str(chrome_error)[:50]}")
                self.add_progress_log("🔄 Retrying Chrome launch in 3 seconds...")
                time.sleep(3)
                driver = webdriver.Chrome(options=options)
                wait = WebDriverWait(driver, 15)
                self.add_progress_log("✅ Chrome initialized successfully on retry!")
                return driver, wait
        
        except Exception as e:
            self.add_progress_log(f"💥 Chrome initialization failed: {str(e)}")
            return None, None
    
    # ---------- AI Studio Automation ----------
    def run_in_ai_studio_thread(self):
        # Show progress log if not already visible
        if not self.show_progress.get():
            self.show_progress.set(True)
            self.toggle_progress_log()
        
        # Initialize the log
        self.add_progress_log("🚀 AI Studio automation started...")
        self.add_progress_log(f"📁 Profile: {os.path.basename(self.profile_dir)}")
        self.add_progress_log(f"🌐 Target: {AI_STUDIO_URL}")
        self.add_progress_log("-" * 50)
        
        threading.Thread(target=self.run_in_ai_studio, daemon=True).start()

    def run_in_ai_studio(self):
        if not selenium_available:
            self.automation_complete(False, "selenium webdriver not installed")
            messagebox.showerror(APP_TITLE,"selenium webdriver not installed.")
            return
        
        self.update_current_step("Setting up Chrome options")
        self.add_progress_log("🔧 Configuring Chrome options...")
        
        # Setup Chrome options using regular selenium ChromeOptions
        from selenium.webdriver.chrome.options import Options
        opts = Options()
        
        # Always use the current project directory for user data
        user_data_dir = os.path.join(os.getcwd(), "User Data")
        
        # Get current profile name or default to Profile 18
        current_profile_name = self.get_current_profile_name()
        if not current_profile_name or current_profile_name == "Profile 18":
            profile_name = "Profile 18"
        else:
            profile_name = current_profile_name
        
        # Set profile directory and create if not exists
        self.profile_dir = os.path.join(user_data_dir, profile_name)
        os.makedirs(self.profile_dir, exist_ok=True)
        
        self.add_progress_log(f"📁 User data dir: {user_data_dir}")
        self.add_progress_log(f"👤 Profile: {profile_name}")
        
        # Use the EXACT same Chrome options as ai_studio_gui.py that work
        opts.add_argument(f"--user-data-dir={user_data_dir}")
        opts.add_argument(f"--profile-directory={profile_name}")
        opts.add_argument("--disable-blink-features=AutomationControlled")
        opts.add_argument("--start-maximized")
        opts.add_argument("--no-sandbox")
        opts.add_argument("--disable-dev-shm-usage")
        opts.add_argument("--log-level=3")
        
        # Log all Chrome arguments for debugging
        all_args = []
        for arg in opts.arguments:
            all_args.append(arg)
        self.add_progress_log(f"🔧 Chrome arguments: {', '.join(all_args)}")
        
        # Log experimental options
        if hasattr(opts, '_experimental_options'):
            self.add_progress_log(f"🧪 Experimental options: {opts._experimental_options}")
        
        self.update_current_step("Launching Chrome browser")
        self.add_progress_log("🚀 Starting Chrome with regular selenium webdriver...")
        self.add_progress_log("📝 Using minimal Chrome options for selenium")
        
        # Enable verbose logging for debugging
        print(f"DEBUG: User data dir: {user_data_dir}")
        print(f"DEBUG: Profile: {profile_name}")
        print(f"DEBUG: Profile dir exists: {os.path.exists(os.path.join(user_data_dir, profile_name))}")
        print(f"DEBUG: Chrome arguments: {opts.arguments}")
        
        try:
            self.add_progress_log("⏳ Calling webdriver.Chrome()...")
            driver = webdriver.Chrome(options=opts)
            self.add_progress_log("✅ webdriver.Chrome() returned successfully!")
            
            self.add_progress_log("⏳ Creating WebDriverWait...")
            wait = WebDriverWait(driver, 15)
            self.add_progress_log("✅ WebDriverWait created successfully!")
            
            # Test that Chrome is actually running
            try:
                current_url = driver.current_url
                self.add_progress_log(f"✅ Chrome is running! Current URL: {current_url}")
            except Exception as url_error:
                self.add_progress_log(f"⚠️ Chrome launched but URL check failed: {str(url_error)}")
            
            self.add_progress_log("✅ Chrome launched successfully and is responsive!")
            
        except Exception as e:
            error_details = str(e)
            self.add_progress_log(f"💥 Chrome launch failed with error: {error_details}")
            # Print to console for immediate debugging
            print(f"CHROME ERROR: {error_details}")
            print(f"Error type: {type(e).__name__}")
            import traceback
            print(f"Full traceback: {traceback.format_exc()}")
            self.automation_complete(False, f"Failed to launch Chrome: {error_details}")
            return
        
        try:
            self.update_current_step("Navigating to AI Studio")
            self.add_progress_log(f"🌐 Opening: {AI_STUDIO_URL}")
            driver.get(AI_STUDIO_URL)
            self.add_progress_log("⏳ Waiting 15 seconds for page to fully load...")
            time.sleep(15)
            
            # Check if we need to authenticate
            self.add_progress_log("🔍 Checking authentication status...")
            page_title = driver.title.lower()
            current_url = driver.current_url.lower()
            
            # Check for common authentication indicators
            auth_indicators = ['sign in', 'login', 'authenticate', 'access denied', 'unauthorized']
            needs_auth = any(indicator in page_title for indicator in auth_indicators)
            is_login_page = 'accounts.google.com' in current_url or 'login' in current_url
            
            if needs_auth or is_login_page:
                self.add_progress_log("⚠️ Authentication required! Please log in manually in the browser window.")
                self.add_progress_log("👆 Click on the browser window and complete the login process.")
                self.add_progress_log("⏳ Waiting up to 60 seconds for authentication to complete...")
                
                # Wait for authentication to complete
                auth_wait_time = 60
                auth_start = time.time()
                
                while (time.time() - auth_start) < auth_wait_time:
                    try:
                        current_url = driver.current_url.lower()
                        page_title = driver.title.lower()
                        
                        # Check if we're back to AI Studio
                        if 'aistudio.google.com' in current_url and 'sign in' not in page_title:
                            self.add_progress_log("✅ Authentication successful! Continuing with automation...")
                            break
                        
                        time.sleep(2)
                    except:
                        time.sleep(2)
                else:
                    self.add_progress_log("⚠️ Authentication timeout. Continuing anyway...")
                
                # Additional wait for page to stabilize after login
                self.add_progress_log("⏳ Waiting for page to stabilize after authentication...")
                time.sleep(5)
            else:
                self.add_progress_log("✅ Already authenticated! Proceeding with automation...")
            
            # Get the current prompt text
            prompt_text = self.prompt_text.get("1.0", "end").strip()
            # Strip any voice_scripts from JSON before sending to AI Studio
            prompt_text = self.strip_voice_scripts_from_text(prompt_text)
            if not prompt_text:
                self.automation_complete(False, "No prompt text available to send")
                return
            
            prompt_length = len(prompt_text)
            self.add_progress_log(f"📝 Prompt loaded: {prompt_length} characters")
            
            # Detect character IDs in the prompt text
            present_ids = [c["id"] for c in self.characters if c["id"] in prompt_text]
            self.add_progress_log(f"🔍 Detected characters in prompt: {', '.join(present_ids) if present_ids else 'None'}")
            
            # STEP 1: Upload images FIRST (NEW ORDER AS REQUESTED!)
            self.update_current_step("Uploading images FIRST - STEP 1")
            self.add_progress_log("📤 UPLOADING IMAGES FIRST (NEW ORDER AS REQUESTED)...")
            
            # Upload images first if we have any
            if present_ids:
                # Get all image files for detected characters
                image_files = []
                for cid in present_ids:
                    ch = next((c for c in self.characters if c["id"] == cid), None)
                    if ch:
                        char_images = [img for img in ch.get("images", []) if os.path.exists(img)]
                        image_files.extend(char_images)
                        self.add_progress_log(f"🖼️ {cid}: Found {len(char_images)} images")
                
                if image_files:
                    self.update_current_step(f"Uploading {len(image_files)} character images - STEP 1")
                    self.add_progress_log(f"📤 Uploading {len(image_files)} images FIRST...")
                    
                    # Click "Insert Assets" button
                    self.add_progress_log("🔘 Looking for 'Insert Assets' button...")
                    trigger_button = self.wait_for_insert_assets_accessible(driver, wait, timeout=180, interval=5)
                    if not trigger_button:
                        self.add_progress_log("❌ 'Insert Assets' UI not available within timeout")
                        self.automation_complete(False, "Image import UI not accessible")
                        return
                    self.add_progress_log("✅ 'Insert Assets' button is ready, clicking...")
                    driver.execute_script("arguments[0].scrollIntoView(true);", trigger_button)
                    ActionChains(driver).move_to_element(trigger_button).click().perform()
                    time.sleep(2)
                    
                    # Upload all character images at once
                    self.add_progress_log("📁 Looking for file input element...")
                    file_input = wait.until(EC.presence_of_element_located((
                        By.XPATH, "//input[@type='file' and @multiple]"
                    )))
                    self.add_progress_log("✅ Found file input, preparing file paths...")
                    
                    # Prepare all file paths
                    all_file_paths = '\n'.join([os.path.abspath(img) for img in image_files])
                    self.add_progress_log(f"📋 Sending {len(image_files)} file paths to input...")
                    file_input.send_keys(all_file_paths)
                    
                    self.update_current_step("Waiting for image processing")
                    self.add_progress_log("⏳ Waiting for images to be processed (checking token count)...")
                    
                    # Wait for upload processing using token count detection
                    token_check_js = """
                    function getTokenCount() {
                        const selectors = [
                            '.v3-token-count-value',
                            '[class*="token-count"]',
                            'ms-token-count span'
                        ];
                        
                        for (let selector of selectors) {
                            try {
                                let elements = document.querySelectorAll(selector);
                                for (let element of elements) {
                                    let text = element.textContent.trim();
                                    let match = text.match(/(\\d[\\d,]*)\\s*tokens?/i);
                                    if (match) {
                                        return {
                                            count: parseInt(match[1].replace(/,/g, '')),
                                            found: true
                                        };
                                    }
                                }
                            } catch (e) {
                                continue;
                            }
                        }
                        
                        try {
                            let result = document.evaluate(
                                `//span[contains(text(), 'token')]`, 
                                document, 
                                null, 
                                XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, 
                                null
                            );
                            
                            for (let i = 0; i < result.snapshotLength; i++) {
                                let element = result.snapshotItem(i);
                                let text = element.textContent.trim();
                                let match = text.match(/(\\d[\\d,]*)\\s*tokens?/i);
                                if (match) {
                                    return {
                                        count: parseInt(match[1].replace(/,/g, '')),
                                        found: true
                                    };
                                }
                            }
                        } catch (e) {}
                        
                        return {count: 0, found: false};
                    }
                    return getTokenCount();
                    """
                    
                    max_wait = 120
                    start_time = time.time()
                    upload_complete = False
                    last_log_time = 0
                    
                    while (time.time() - start_time) < max_wait:
                        try:
                            result = driver.execute_script(token_check_js)
                            elapsed = int(time.time() - start_time)
                            
                            if result and result.get('found', False) and result.get('count', 0) > 0:
                                token_count = result.get('count', 0)
                                self.add_progress_log(f"🎯 SUCCESS! Images processed: {token_count} tokens detected")
                                upload_complete = True
                                break
                            elif elapsed - last_log_time >= 10:  # Log every 10 seconds
                                self.add_progress_log(f"⏰ Still waiting for token processing... ({elapsed}s elapsed)")
                                last_log_time = elapsed
                        except Exception as e:
                            self.add_progress_log(f"⚠️ Token check error: {str(e)[:50]}")
                        time.sleep(2)
                    
                    if not upload_complete:
                        self.add_progress_log("⚠️ Upload timeout reached, continuing anyway...")
                    
                    # Close any upload popups
                    self.add_progress_log("🔄 Attempting to close upload popups...")
                    try:
                        popup_close_js = """
                        function closePopups() {
                            const selectors = [
                                'button[aria-label*="close"]',
                                'button[aria-label*="Close"]', 
                                'button[title*="close"]',
                                'button[title*="Close"]'
                            ];
                            
                            for (let selector of selectors) {
                                let elements = document.querySelectorAll(selector);
                                for (let element of elements) {
                                    if (element && element.offsetParent !== null) {
                                        element.click();
                                        return true;
                                    }
                                }
                            }
                            return false;
                        }
                        return closePopups();
                        """
                        popup_closed = driver.execute_script(popup_close_js)
                        if popup_closed:
                            self.add_progress_log("✅ Upload popup closed successfully")
                        else:
                            self.add_progress_log("ℹ️ No upload popup found to close")
                        time.sleep(1)
                    except Exception as e:
                        self.add_progress_log(f"⚠️ Popup close error: {str(e)[:50]}")
                else:
                    self.add_progress_log("ℹ️ No character images to upload")
            else:
                self.add_progress_log("ℹ️ No characters detected in prompt, skipping image upload")
            
            # STEP 2: Wait 3 seconds after uploading images (as requested)
            self.add_progress_log("⏱️ Waiting 3 seconds after image upload (as requested)...")
            time.sleep(3)
            
            # STEP 3: Find and paste prompt text AFTER uploading images
            self.update_current_step("Finding text input area - STEP 3")
            self.add_progress_log("🔍 Searching for textarea element - PASTING PROMPT AFTER IMAGES...")
            
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            for i, selector in enumerate(textarea_selectors):
                try:
                    chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                    self.add_progress_log(f"✅ Found textarea using selector #{i+1}")
                    break
                except:
                    continue
            
            if not chat_input:
                self.automation_complete(False, "Could not find textarea element")
                return
            
            # STEP 3: Paste prompt AFTER uploading images
            self.update_current_step("Pasting prompt text - STEP 3")
            self.add_progress_log("📝 Focusing textarea and pasting prompt AFTER uploading images...")
            
            # Focus and paste prompt AFTER images
            driver.execute_script("arguments[0].scrollIntoView(true);", chat_input)
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            success_paste = self.paste_text_all_at_once(driver, chat_input, prompt_text)
            if not success_paste:
                self.automation_complete(False, "Failed to paste prompt text")
                return
            self.add_progress_log(f"✅ Prompt pasted AFTER uploading images ({len(prompt_text)} characters) - NEW ORDER!")
            
            # Select Aspect Ratio before triggering run
            try:
                selected_label = self.aspect_ratio_var.get() if hasattr(self, "aspect_ratio_var") else "YouTube 16:9"
                self.add_progress_log(f"🎛️ Selecting aspect ratio: {selected_label}")
                # Use NanoBanana selection for run_in_ai_studio
                self.select_aspect_ratio_in_ai_studio(driver, is_image_model=False)
                time.sleep(1)  # brief wait for selection to apply
            except Exception as e:
                self.add_progress_log(f"⚠️ Aspect ratio selection skipped or failed: {str(e)[:50]}")
            
            # STEP 4: Wait 2 seconds after pasting text before running (as requested)
            self.add_progress_log("⏱️ Waiting 2 seconds after pasting text before running (as requested)...")
            time.sleep(2)
            
            # STEP 5: Focus again and trigger AI response
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            self.update_current_step("Triggering AI response - STEP 5")
            self.add_progress_log("🚀 Sending Ctrl+Enter to trigger AI response (STEP 5 - FINAL STEP)...")
            
            try:
                chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                self.add_progress_log("✅ Ctrl+Enter sent successfully via WebElement!")
                success_msg = "AI automation completed successfully! Check Chrome window for response."
                self.automation_complete(True, success_msg)
            except Exception as primary_error:
                self.add_progress_log(f"⚠️ Primary Ctrl+Enter failed: {str(primary_error)[:50]}")
                self.add_progress_log("🔄 Trying ActionChains fallback...")
                try:
                    action = ActionChains(driver)
                    action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                    self.add_progress_log("✅ Ctrl+Enter sent successfully via ActionChains!")
                    success_msg = "AI automation completed successfully! Check Chrome window for response."
                    self.automation_complete(True, success_msg)
                except Exception as fallback_error:
                    error_msg = f"Both Ctrl+Enter methods failed: {str(fallback_error)}"
                    self.add_progress_log(f"❌ {error_msg}")
                    self.automation_complete(False, error_msg)
            
        except Exception as e:
            error_msg = str(e)
            self.add_progress_log(f"💥 CRITICAL ERROR: {error_msg}")
            self.automation_complete(False, error_msg)

    def upload_file(self,driver,filepath):
        try:
            # find <input type="file">
            input_el=WebDriverWait(driver,5).until(lambda d:d.find_element(By.XPATH,'//input[@type="file"]'))
            driver.execute_script("arguments[0].style.display='block';",input_el)
            input_el.send_keys(os.path.abspath(filepath))
        except Exception as e:
            print("Upload failed:",e)
    
    # ---------- Range Processing ----------
    def run_range_in_ai_studio_thread(self):
        """Run range processing in a separate thread"""
        # Show progress log if not already visible
        if not self.show_progress.get():
            self.show_progress.set(True)
            self.toggle_progress_log()
        
        # Validate range
        try:
            from_num = int(self.from_prompt_var.get().strip())
            to_num = int(self.to_prompt_var.get().strip())
        except ValueError:
            messagebox.showerror(APP_TITLE, "Please enter valid numbers for the range.")
            return
        
        if from_num > to_num:
            messagebox.showerror(APP_TITLE, "'From' number must be less than or equal to 'To' number.")
            return
        
        # Check if we have scenes for this range
        scenes = self.data.get("output_structure", {}).get("scenes", [])
        if not scenes:
            messagebox.showerror(APP_TITLE, "No scenes loaded. Please load a JSON file first.")
            return
        
        available_scenes = [s.get("scene_number", i+1) for i, s in enumerate(scenes)]
        valid_scenes = [num for num in range(from_num, to_num + 1) if num in available_scenes]
        
        if not valid_scenes:
            messagebox.showerror(APP_TITLE, f"No valid scenes found in range {from_num}-{to_num}.")
            return
        
        # Determine which URL to use based on selected model
        selected = self.image_model_var.get()
        if selected == "NanoBanana (Chat)" or not self.selected_image_model:
            target_url = AI_STUDIO_URL
            model_name = "NanoBanana (Chat)"
        else:
            target_url = f"{IMAGEN_BASE_URL}{self.selected_image_model}"
            model_name = selected
        
        # Initialize the log
        self.add_progress_log("🚀 Range processing started...")
        self.add_progress_log(f"🎯 Using Model: {model_name}")
        self.add_progress_log(f"🌐 Target URL: {target_url}")
        self.add_progress_log(f"📊 Processing scenes: {from_num} to {to_num} ({len(valid_scenes)} scenes)")
        self.add_progress_log(f"📁 Profile: {os.path.basename(self.profile_dir)}")
        self.add_progress_log("-" * 50)
        
        threading.Thread(target=self.run_range_in_ai_studio, args=(valid_scenes, target_url), daemon=True).start()
    
    def run_range_in_ai_studio(self, scene_numbers, target_url):
        """Process multiple scenes in separate tabs using selected model"""
        if not uc:
            self.automation_complete(False, "undetected_chromedriver not installed")
            messagebox.showerror(APP_TITLE, "undetected_chromedriver not installed.")
            return
        
        self.update_current_step("Setting up Chrome for range processing")
        self.add_progress_log("🔧 Configuring Chrome options for range processing...")
        
        # Setup Chrome options
        opts = uc.ChromeOptions()
        
        # Get the base user data directory and profile name correctly
        if os.path.exists(self.profile_dir):
            user_data_dir = os.path.dirname(self.profile_dir)
            profile_name = os.path.basename(self.profile_dir)
        else:
            user_data_dir = "C:/SeleniumProfile"
            profile_name = "Profile 18"
            os.makedirs(os.path.join(user_data_dir, profile_name), exist_ok=True)
        
        self.add_progress_log(f"📁 User data dir: {user_data_dir}")
        self.add_progress_log(f"👤 Profile: {profile_name}")
        
        # Use the same Chrome options
        opts.add_argument(f"--user-data-dir={user_data_dir}")
        opts.add_argument(f"--profile-directory={profile_name}")
        opts.add_argument("--disable-blink-features=AutomationControlled")
        opts.add_argument("--start-maximized")
        opts.add_argument("--no-sandbox")
        opts.add_argument("--disable-dev-shm-usage")
        opts.add_argument("--log-level=3")
        
        try:
            self.add_progress_log("⏳ Launching Chrome for range processing...")
            driver = uc.Chrome(options=opts)
            self.add_progress_log("✅ Chrome launched successfully!")
            
            wait = WebDriverWait(driver, 15)
            
            # Test that Chrome is running
            current_url = driver.current_url
            self.add_progress_log(f"✅ Chrome is running! Current URL: {current_url}")
            
        except Exception as e:
            error_details = str(e)
            self.add_progress_log(f"💥 Chrome launch failed: {error_details}")
            self.automation_complete(False, f"Failed to launch Chrome: {error_details}")
            return
        
        # Store driver reference for tab management
        self.batch_driver = driver
        self.batch_wait = wait
        
        # Process each scene in a separate tab
        successful_scenes = []
        failed_scenes = []
        
        for i, scene_number in enumerate(scene_numbers):
            try:
                self.update_current_step(f"Processing scene {scene_number} ({i+1}/{len(scene_numbers)})")
                self.add_progress_log(f"\n🎬 Starting scene {scene_number} ({i+1}/{len(scene_numbers)})...")
                
                # Create new tab (except for first scene)
                if i > 0:
                    self.add_progress_log("📑 Creating new tab with selected model...")
                    driver.execute_script(f"window.open('{target_url}', '_blank');")
                    # Switch to the new tab
                    driver.switch_to.window(driver.window_handles[-1])
                    self.add_progress_log("✅ New tab created with model URL")
                    
                    # Wait 5 seconds between tab creation
                    self.add_progress_log("⏰ Waiting 5 seconds before processing...")
                    time.sleep(5)
                
                # Process this scene immediately
                # Only upload images for NanoBanana
                is_nanobanana = (target_url == AI_STUDIO_URL)
                success = self.process_scene_in_simple_tab(scene_number, driver, wait, i + 1, upload_images=is_nanobanana)
                
                if success:
                    successful_scenes.append(scene_number)
                    self.add_progress_log(f"✅ Scene {scene_number} completed successfully!")
                else:
                    failed_scenes.append(scene_number)
                    self.add_progress_log(f"❌ Scene {scene_number} failed!")
                
            except Exception as e:
                error_msg = f"Scene {scene_number} error: {str(e)[:100]}"
                self.add_progress_log(f"💥 {error_msg}")
                failed_scenes.append(scene_number)
        
        # Final summary
        self.add_progress_log("\n" + "=" * 50)
        self.add_progress_log(f"🏁 BATCH PROCESSING COMPLETE!")
        self.add_progress_log(f"✅ Successful: {len(successful_scenes)} scenes {successful_scenes}")
        self.add_progress_log(f"❌ Failed: {len(failed_scenes)} scenes {failed_scenes}")
        
        if successful_scenes:
            self.automation_complete(True, f"Range processing completed! {len(successful_scenes)}/{len(scene_numbers)} scenes successful")
        else:
            self.automation_complete(False, f"Range processing failed for all {len(scene_numbers)} scenes")
    
    def start_scene_processing_simultaneous(self, scene_number, driver, wait, tab_number):
        """Start scene processing immediately without waiting - for simultaneous processing"""
        try:
            self.add_progress_log(f"🚀 Tab {tab_number}: Starting IMMEDIATE processing for scene {scene_number}...")
            
            # Get scene data
            scene_data = self.get_scene_data(scene_number)
            if not scene_data:
                self.add_progress_log(f"❌ Tab {tab_number}: No scene data found for scene {scene_number}")
                return False
            
            prompt_text, present_chars = scene_data
            self.add_progress_log(f"✅ Tab {tab_number}: Scene {scene_number} data loaded - {len(prompt_text)} chars, {len(present_chars)} characters detected")
            
            # Navigate to AI Studio
            self.add_progress_log(f"🌐 Tab {tab_number}: Opening AI Studio for scene {scene_number}...")
            driver.get(AI_STUDIO_URL)
            self.add_progress_log(f"⏳ Tab {tab_number}: Waiting 8 seconds for page to load (FAST mode)...")
            time.sleep(8)  # Reduced wait time for speed
            
            # Quick authentication check
            page_title = driver.title.lower()
            current_url = driver.current_url.lower()
            
            if 'sign in' in page_title or 'accounts.google.com' in current_url:
                self.add_progress_log(f"⚠️ Tab {tab_number}: Authentication required for scene {scene_number} - skipping")
                return False
            
            self.add_progress_log(f"✅ Tab {tab_number}: Successfully opened AI Studio for scene {scene_number}")
            
            # Record scene number for this tab handle to ensure correct naming later
            try:
                current_handle = driver.current_window_handle
                self.tab_scene_number_map[current_handle] = int(scene_number)
                self.add_progress_log(f"🧭 Tab {tab_number}: Mapped handle to scene {scene_number} for naming")
            except Exception:
                pass

            # Find textarea and paste prompt FIRST (NEW ORDER!)
            self.add_progress_log(f"📝 Tab {tab_number}: FAST finding textarea for scene {scene_number} (PROMPT FIRST!)...")
            
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            for selector in textarea_selectors:
                try:
                    chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                    break
                except:
                    continue
            
            if not chat_input:
                self.add_progress_log(f"❌ Tab {tab_number}: Could not find textarea for scene {scene_number}")
                return False
            
            # Paste prompt FIRST (NEW ORDER!)
            self.add_progress_log(f"📝 Tab {tab_number}: FAST pasting prompt for scene {scene_number} (PROMPT FIRST!)...")
            driver.execute_script("arguments[0].scrollIntoView(true);", chat_input)
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.3)  # Reduced wait time
            
            # Paste entire prompt in one shot
            success_paste = self.paste_text_all_at_once(driver, chat_input, prompt_text)
            if not success_paste:
                self.add_progress_log(f"❌ Tab {tab_number}: Failed to paste prompt for scene {scene_number}")
                return False
            self.add_progress_log(f"✅ Tab {tab_number}: Prompt pasted FIRST for scene {scene_number} (NEW ORDER!)")
            
            # NOW upload character images AFTER pasting prompt (NEW ORDER!)
            if present_chars:
                image_files = []
                for char_id in present_chars:
                    ch = next((c for c in self.characters if c["id"] == char_id), None)
                    if ch:
                        char_images = [img for img in ch.get("images", []) if os.path.exists(img)]
                        image_files.extend(char_images)
                        self.add_progress_log(f"🖼️ Tab {tab_number}: {char_id}: {len(char_images)} images queued AFTER prompt")
                
                if image_files:
                    self.add_progress_log(f"📤 Tab {tab_number}: FAST uploading {len(image_files)} images for scene {scene_number} (AFTER PROMPT!)...")
                    
                    try:
                        # Trigger file picker using new menu workflow
                        picker_ready = self.wait_for_insert_assets_accessible(driver, wait, timeout=180, interval=5)
                        if not picker_ready:
                            self.add_progress_log(f"❌ Tab {tab_number}: File picker not available for scene {scene_number}")
                            return False
                        time.sleep(0.5)  # Reduced wait time
                        
                        # Upload images using correct selector
                        file_input = wait.until(EC.presence_of_element_located((
                            By.CSS_SELECTOR, "input[data-test-upload-file-input]"
                        )))
                        all_file_paths = '\n'.join([os.path.abspath(img) for img in image_files])
                        file_input.send_keys(all_file_paths)
                        
                        # Quick wait for upload processing
                        self.add_progress_log(f"⏳ Tab {tab_number}: FAST processing images for scene {scene_number} (AFTER PROMPT!)...")
                        time.sleep(8)  # Reduced wait for simultaneous processing
                        
                        self.add_progress_log(f"✅ Tab {tab_number}: Images uploaded AFTER prompt for scene {scene_number} (NEW ORDER!)")
                        
                    except Exception as upload_error:
                        self.add_progress_log(f"⚠️ Tab {tab_number}: Image upload failed for scene {scene_number}: {str(upload_error)[:50]}")
                        # Continue anyway
                else:
                    self.add_progress_log(f"ℹ️ Tab {tab_number}: No images to upload for scene {scene_number}")
            else:
                self.add_progress_log(f"ℹ️ Tab {tab_number}: No characters detected in scene {scene_number}")
            
            # Focus textarea again for trigger
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.3)
            
            # Inject JavaScript for auto-download functionality
            self.inject_auto_download_script_into_all_frames(driver, scene_number, tab_number)
            
            try:
                chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                self.add_progress_log(f"🚀 Tab {tab_number}: Scene {scene_number} STARTED SIMULTANEOUSLY with auto-download!")
                return True
            except Exception as primary_error:
                try:
                    # Fallback method
                    action = ActionChains(driver)
                    action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                    self.add_progress_log(f"🚀 Tab {tab_number}: Scene {scene_number} STARTED SIMULTANEOUSLY (fallback) with auto-download!")
                    return True
                except Exception as fallback_error:
                    self.add_progress_log(f"❌ Tab {tab_number}: Failed to trigger scene {scene_number}: {str(fallback_error)[:50]}")
                    return False
        
        except Exception as e:
            self.add_progress_log(f"💥 Tab {tab_number}: Error starting scene {scene_number}: {str(e)[:100]}")
            return False
    
    def inject_complete_automation_script(self, driver, tab_index, scene_number, scene_data, total_tabs):
        """Inject complete AI Studio automation script that runs entirely in browser without webdriver interaction"""
        try:
            self.add_progress_log(f"💉 Tab {tab_index+1}: Injecting enhanced automation script for scene {scene_number}...")
            
            prompt_text = scene_data['prompt']
            image_files = scene_data['image_files']
            
            # Switch to the target tab
            driver.switch_to.window(driver.window_handles[tab_index])
            
            # Convert images to base64 for injection (limit to first few images to avoid size issues)
            base64_images = []
            for img_path in image_files[:3]:  # Reduced to 3 images to avoid script size issues
                try:
                    import base64
                    with open(img_path, 'rb') as f:
                        img_data = base64.b64encode(f.read()).decode()
                    base64_images.append({
                        'name': os.path.basename(img_path),
                        'data': img_data
                    })
                except Exception as img_error:
                    self.add_progress_log(f"⚠️ Failed to encode image {img_path}: {str(img_error)[:30]}")
            
            # Clean prompt text for JavaScript injection - escape properly
            clean_prompt = prompt_text.replace('\n', '\\n').replace('\r', '\\r').replace('`', '\\`').replace('\\', '\\\\').replace('"', '\\"').replace("'", "\\'")
            
            # Also encode images as JSON string to avoid issues
            import json as json_module
            base64_images_json = json_module.dumps(base64_images)
            
            # Simple console-style JavaScript that mimics manual script pasting
            complete_automation_js = '''
// 🚀 SIMPLE CONSOLE AUTOMATION for scene {scene_number}
console.log("Starting automation for scene {scene_number}");

// Configuration
window.SCENE_NUMBER = {scene_number};
window.PROMPT_TEXT = `{clean_prompt}`;
window.AI_STUDIO_URL = "{AI_STUDIO_URL}";

// Simple wait function
window.sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

// Find textarea - simple and direct
window.findTextarea = function() {{
    // Try most common selectors first
    let textarea = document.querySelector('textarea[aria-label*="Type"]') ||
                   document.querySelector('textarea[placeholder*="Type"]') ||
                   document.querySelector('textarea.textarea') ||
                   document.querySelector('ms-autosize-textarea textarea') ||
                   document.querySelector('textarea');
    
    if (textarea && textarea.offsetParent && !textarea.disabled) {{
        console.log("✅ Found textarea:", textarea);
        return textarea;
    }}
    console.log("❌ No valid textarea found");
    return null;
}};

// Paste text - simple and reliable
window.pasteText = function(text) {{
    let textarea = window.findTextarea();
    if (!textarea) return false;
    
    console.log("📝 Pasting text...");
    textarea.focus();
    textarea.value = "";
    textarea.value = text;
    
    // Trigger events
    textarea.dispatchEvent(new Event('input', {{bubbles: true}}));
    textarea.dispatchEvent(new Event('change', {{bubbles: true}}));
    
    console.log("✅ Text pasted:", text.length, "chars");
    return true;
}};

// Send message - using modern approach
window.sendMessage = function() {
    let textarea = window.findTextarea();
    if (!textarea) return false;
    
    console.log("🚀 Sending message...");
    textarea.focus();
    
    // Try clicking send button first (more reliable than KeyboardEvent)
    let sendBtn = document.querySelector('button[aria-label*="Send"]') ||
                 document.querySelector('button[title*="Send"]') ||
                 document.querySelector('button[type="submit"]');
    
    if (sendBtn && !sendBtn.disabled) {
        sendBtn.click();
        console.log("🔘 Clicked send button");
        console.log("✅ Message sent via button click");
        return true;
    }
    
    // Fallback: try simulating Enter key with modern approach
    textarea.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Enter',
        code: 'Enter',
        bubbles: true,
        cancelable: true
    }));
    
    console.log("✅ Message sent via Enter key");
    return true;
};

// Auto-download function
window.startAutoDownload = function() {{
    console.log("📥 Starting auto-download monitor...");
    
    let downloadAttempted = false;
    let startTime = Date.now();
    
    let checkForImages = () => {{
        if (downloadAttempted) return;
        
        // Check if AI is still generating
        let stopBtn = document.querySelector('button[aria-label*="Stop"]');
        if (stopBtn && stopBtn.offsetParent && !stopBtn.disabled) {{
            // Still generating, check again later
            setTimeout(checkForImages, 3000);
            return;
        }}
        
        // Look for generated images
        let images = document.querySelectorAll('img[src*="googleusercontent.com"], img[src^="blob:"], img[src^="data:image"]');
        let validImages = Array.from(images).filter(img => img.complete && img.naturalWidth > 100);
        
        if (validImages.length > 0) {{
            console.log(`📸 Found ${{validImages.length}} images, downloading...`);
            downloadAttempted = true;
            
            validImages.forEach((img, i) => {
                setTimeout(() => {
                    // Create sanitized filename from prompt text
                    let sanitizedPrompt = window.PROMPT_TEXT.substring(0, 100) // Limit to first 100 chars
                        .replace(/[^a-zA-Z0-9\\s-_]/g, '') // Remove special characters
                        .replace(/\\s+/g, '_') // Replace spaces with underscores
                        .replace(/_+/g, '_') // Replace multiple underscores with single
                        .replace(/^_+|_+$/g, ''); // Remove leading/trailing underscores
                    
                    // Fallback to scene number if sanitization results in empty string
                    if (!sanitizedPrompt || sanitizedPrompt.length < 3) {
                        sanitizedPrompt = `scene_${{String(window.SCENE_NUMBER).padStart(3, '0')}}`;
                    }
                    
                    const filename = `${{sanitizedPrompt}}_${{i+1}}.jpg`;
                    
                    // Use simple direct download method
                    const link = document.createElement('a');
                    link.href = img.src;
                    link.download = filename;
                    document.body.appendChild(link);
                    link.click();
                    document.body.removeChild(link);
                    console.log(`📥 Downloaded image ${{i+1}} as ${{filename}}`);
                }, i * 200);
            });
        }} else if ((Date.now() - startTime) < 300000) {{
            // Keep checking for up to 5 minutes
            setTimeout(checkForImages, 5000);
        }}
    }};
    
    // Start checking after 5 seconds
    setTimeout(checkForImages, 5000);
}};

// Main automation function
window.runAutomation = async function() {{
    console.log("🎬 Starting scene {scene_number} automation");
    
    try {{
        // Wait for page to be ready
        console.log("⏳ Waiting for page...");
        await window.sleep(3000);
        
        // Navigate to AI Studio if needed
        if (!window.location.href.includes('aistudio.google.com')) {{
            console.log("🌐 Navigating to AI Studio...");
            window.location.href = window.AI_STUDIO_URL;
            await window.sleep(10000);
        }}
        
        // Check auth
        if (document.title.toLowerCase().includes('sign in')) {{
            console.log("❌ Authentication required");
            return;
        }}
        
        // Paste prompt
        if (!window.pasteText(window.PROMPT_TEXT)) {{
            console.log("❌ Failed to paste text");
            return;
        }}
        
        // Wait a moment then send
        await window.sleep(2000);
        
        if (!window.sendMessage()) {{
            console.log("❌ Failed to send message");
            return;
        }}
        
        // Start auto-download monitoring
        window.startAutoDownload();
        
        
        console.log("🎉 Automation complete for scene {scene_number}!");
        
    }} catch (error) {{
        console.error("💥 Automation error:", error);
    }}
}};

// Start the automation
console.log("🔥 Script loaded, starting automation in 2 seconds...");
setTimeout(window.runAutomation, 2000);'''.format(
                scene_number=scene_number,
                clean_prompt=clean_prompt,
                AI_STUDIO_URL=AI_STUDIO_URL
            )
            
            # Execute the complete automation script in the tab
            driver.execute_script(complete_automation_js)
            self.add_progress_log(f"✅ Tab {tab_index+1}: Complete automation script injected and RUNNING for scene {scene_number}!")
            self.add_progress_log(f"🔥 Tab {tab_index+1}: This tab will now run COMPLETELY AUTONOMOUSLY!")
            
            return True
            
        except Exception as e:
            self.add_progress_log(f"💥 Tab {tab_index+1}: Failed to inject complete automation script for scene {scene_number}: {str(e)}")
            return False
    
    def check_and_download_generated_images(self, driver, scene_number, tab_number, timeout=300):
        """Check for generated images using WebDriver and download them directly using Python"""
        start_time = time.time()
        max_wait_time = timeout  # 5 minutes default
        check_interval = 5  # Check every 5 seconds
        download_attempted = False
        
        self.add_progress_log(f"🔍 Tab {tab_number}: Starting WebDriver-based image monitoring for scene {scene_number}...")
        self.add_progress_log(f"⏰ Will check every {check_interval} seconds for up to {max_wait_time//60} minutes")
        
        while (time.time() - start_time) < max_wait_time:
            try:
                elapsed = int(time.time() - start_time)
                
                if download_attempted:
                    break  # Already attempted download
                
                # Check if AI generation is complete (no Stop button)
                if self.is_ai_generation_complete(driver):
                    self.add_progress_log(f"🎯 Tab {tab_number}: AI generation completed for scene {scene_number}! Looking for images...")
                    
                    # Find generated images using WebDriver
                    images = self.find_loaded_images(driver)
                    if images:
                        self.add_progress_log(f"📸 Tab {tab_number}: Found {len(images)} generated image(s) for scene {scene_number}")
                        
                        download_attempted = True
                        downloaded_count = 0
                        
                        # Download all found images using WebDriver with retry logic
                        for i, img_element in enumerate(images):
                            success = self.download_image_with_webdriver(driver, img_element, scene_number, i + 1)
                            if success:
                                downloaded_count += 1
                                self.add_progress_log(f"✅ Tab {tab_number}: Downloaded image {i+1} for scene {scene_number}")
                            else:
                                self.add_progress_log(f"❌ Tab {tab_number}: Failed to download image {i+1} for scene {scene_number}")
                        
                        if downloaded_count > 0:
                            self.add_progress_log(f"✅ Tab {tab_number}: Auto-download completed for scene {scene_number}! ({downloaded_count}/{len(images)} images downloaded)")
                            return True
                        else:
                            self.add_progress_log(f"⚠️ Tab {tab_number}: All downloads failed for scene {scene_number}, will retry in next check...")
                            download_attempted = False  # Allow retry
                    else:
                        self.add_progress_log(f"⚠️ Tab {tab_number}: Generation complete but no images found for scene {scene_number}, will retry...")
                else:
                    # Log progress every 10 seconds
                    if elapsed % 10 == 0 and elapsed > 0:
                        self.add_progress_log(f"⏳ Tab {tab_number}: Still generating scene {scene_number}... ({elapsed}s elapsed)")
                
                # Wait before next check
                time.sleep(check_interval)
                
            except Exception as error:
                self.add_progress_log(f"💥 Tab {tab_number}: Monitor error for scene {scene_number}: {str(error)[:50]}")
                time.sleep(check_interval)  # Continue monitoring even if there's an error
        
        if not download_attempted:
            self.add_progress_log(f"⏰ Tab {tab_number}: Max wait time reached for scene {scene_number}, stopping monitor")
        
        return download_attempted
    
    def is_ai_generation_complete(self, driver):
        """Check if AI generation is complete by looking for absence of Stop buttons and loading indicators"""
        try:
            # Check for busy indicators (should be absent when complete)
            busy_selectors = [
                'button[aria-label*="Stop"]',
                'button[aria-label*="stop"]', 
                'button[title*="Stop"]',
                'button[title*="stop"]',
                '[class*="generating"]',
                '[class*="loading"]',
                '[aria-label*="generating"]',
                '[aria-label*="Generating"]',
                'button[class*="stop"]'
            ]
            
            for selector in busy_selectors:
                elements = driver.find_elements(By.CSS_SELECTOR, selector)
                for element in elements:
                    if element.is_displayed() and element.is_enabled():
                        return False  # Still generating
            
            # Check if we have generated images (additional confirmation)
            images = self.find_loaded_images(driver)
            return len(images) > 0
            
        except Exception as e:
            # If we can't determine status, assume not complete
            return False
    
    def find_loaded_images(self, driver):
        """Find generated images across NanoBanana and other Image Models.
        Prioritize base64 data URLs from the gallery component, then fall back to other candidates.
        """
        images = []
        try:
            # 1) Primary selectors: other image models (gallery component) and generic base64 imgs
            primary_selectors = [
                "ms-image-generation-gallery-image img[alt='Generated image'][src^='data:image']",
                "ms-image-generation-gallery-image img[src^='data:image']",
                "img.loaded-image[src^='data:image']",  # NanoBanana legacy
                "img[src^='data:image']",
            ]
            found_elements = []
            for selector in primary_selectors:
                try:
                    els = driver.find_elements(By.CSS_SELECTOR, selector)
                except Exception:
                    els = []
                for el in els:
                    try:
                        src = el.get_attribute("src") or ""
                        if not src.startswith("data:image"):
                            continue
                        if not el.is_displayed():
                            continue
                        width = driver.execute_script("return arguments[0].naturalWidth || 0;", el)
                        height = driver.execute_script("return arguments[0].naturalHeight || 0;", el)
                        if width > 64 and height > 64:
                            found_elements.append(el)
                    except Exception:
                        continue
            # Deduplicate by src
            unique = []
            seen_src = set()
            for el in found_elements:
                try:
                    src = el.get_attribute("src") or ""
                except Exception:
                    src = ""
                if src and src in seen_src:
                    continue
                seen_src.add(src)
                unique.append(el)
            if unique:
                self.add_progress_log(f"🔍 Found {len(unique)} base64 image(s) via gallery/data selectors")
                return unique
            # 2) Fallback selectors: blobs and hosted images (canvas conversion may work depending on CORS)
            fallback_selectors = [
                "ms-image-generation-gallery-image img[src^='blob:']",
                "img[src^='blob:']",
                "img[src*='googleusercontent.com']",
            ]
            fallback_found = []
            for selector in fallback_selectors:
                try:
                    els = driver.find_elements(By.CSS_SELECTOR, selector)
                except Exception:
                    els = []
                for el in els:
                    try:
                        if not el.is_displayed():
                            continue
                        width = driver.execute_script("return arguments[0].naturalWidth || 0;", el)
                        height = driver.execute_script("return arguments[0].naturalHeight || 0;", el)
                        if width > 64 and height > 64:
                            fallback_found.append(el)
                    except Exception:
                        continue
            if fallback_found:
                self.add_progress_log(f"🔍 Fallback: found {len(fallback_found)} non-base64 image(s) (blob/hosted)")
                return fallback_found
            self.add_progress_log("❌ No generated images found with known selectors")
        except Exception as e:
            self.add_progress_log(f"💥 Error finding loaded images: {str(e)[:50]}")
        return images
    
    def download_image_with_webdriver(self, driver, img_element, scene_number, image_index=1, max_retries=3):
        """Download image using WebDriver using data-URL decoding only.
        Strategy:
        - If the image src is a data URL, decode it and save directly (preferred, avoids duplicate browser downloads)
        - Otherwise, try canvas.toDataURL() to obtain a data URL, then decode and save
        Note: We intentionally skip the browser-native <a download> trigger to prevent duplicate downloads.
        """
        for attempt in range(max_retries):
            try:
                # Get the image source
                src = img_element.get_attribute("src")
                if not src:
                    self.add_progress_log(f"❌ Image {image_index}: No src attribute found")
                    return False
                
                # Create filename with proper scene number and image index
                filename = f"prompt_{str(scene_number).zfill(3)}_{image_index}.png"
                
                # If it's already a data URL, decode and save directly (single method)
                if src.startswith('data:'):
                    self.add_progress_log(f"📥 Image {image_index}: Processing data URL...")
                    header, data = src.split(',', 1)
                    import base64, os
                    image_data = base64.b64decode(data)
                    downloads_dir = os.path.join(os.path.expanduser("~"), "Downloads")
                    if not os.path.exists(downloads_dir):
                        downloads_dir = os.getcwd()
                    file_path = os.path.join(downloads_dir, filename)
                    with open(file_path, 'wb') as f:
                        f.write(image_data)
                    self.add_progress_log(f"✅ Image {image_index}: Saved data URL to {filename} ({len(image_data)} bytes)")
                    return True
                
                # Otherwise, try to convert to data URL via canvas and then save
                self.add_progress_log(f"📥 Image {image_index}: Attempting canvas conversion to data URL (attempt {attempt+1})...")
                canvas_script = """
                return new Promise((resolve) => {
                    try {
                        const img = arguments[0];
                        const canvas = document.createElement('canvas');
                        const ctx = canvas.getContext('2d');
                        canvas.width = img.naturalWidth;
                        canvas.height = img.naturalHeight;
                        ctx.drawImage(img, 0, 0);
                        const dataUrl = canvas.toDataURL('image/png');
                        resolve({ok: true, dataUrl});
                    } catch (error) {
                        resolve({ok: false, error: error && (error.message || String(error))});
                    }
                });
                """
                result2 = driver.execute_async_script(canvas_script, img_element)
                if result2 and result2.get('ok') and result2.get('dataUrl', '').startswith('data:'):
                    header, data = result2['dataUrl'].split(',', 1)
                    import base64, os
                    image_data = base64.b64decode(data)
                    downloads_dir = os.path.join(os.path.expanduser("~"), "Downloads")
                    if not os.path.exists(downloads_dir):
                        downloads_dir = os.getcwd()
                    file_path = os.path.join(downloads_dir, filename)
                    with open(file_path, 'wb') as f:
                        f.write(image_data)
                    self.add_progress_log(f"✅ Image {image_index}: Saved canvas image to {filename} ({len(image_data)} bytes)")
                    return True
                else:
                    err = (result2 or {}).get('error', 'unknown error')
                    raise Exception(f"Canvas conversion failed: {err}")
                
            except Exception as error:
                if attempt < max_retries - 1:
                    self.add_progress_log(f"⚠️ Image {image_index} attempt {attempt+1} failed: {str(error)[:80]}, retrying in 5 seconds...")
                    time.sleep(5)
                else:
                    self.add_progress_log(f"❌ Image {image_index} failed after {max_retries} attempts: {str(error)[:80]}")
        
        return False
    
    def inject_auto_download_script_into_all_frames(self, driver, scene_number, tab_number):
        """Attempt to inject the auto-download script into the top document and all accessible iframes."""
        injected_any = False
        try:
            # Always start from top document
            driver.switch_to.default_content()
            self.add_progress_log(f"🔍 Tab {tab_number}: Injecting auto-download script into TOP frame for scene {scene_number}...")
            try:
                self.inject_auto_download_script(driver, scene_number, tab_number)
                injected_any = True
            except Exception as top_err:
                self.add_progress_log(f"⚠️ Tab {tab_number}: Top frame injection error: {str(top_err)[:80]}")
            
            # BFS over iframes
            from selenium.common.exceptions import WebDriverException
            def inject_recursive(depth=1, max_depth=3):
                if depth > max_depth:
                    return
                try:
                    frames = driver.find_elements(By.TAG_NAME, 'iframe')
                except Exception:
                    frames = []
                for idx, frame in enumerate(frames):
                    try:
                        driver.switch_to.frame(frame)
                        self.add_progress_log(f"🔍 Tab {tab_number}: Injecting into iframe depth {depth} index {idx} for scene {scene_number}...")
                        try:
                            self.inject_auto_download_script(driver, scene_number, tab_number)
                            injected_any = True
                        except Exception as fr_err:
                            self.add_progress_log(f"⚠️ Tab {tab_number}: Frame depth {depth} index {idx} injection error: {str(fr_err)[:80]}")
                        # Recurse into nested frames
                        inject_recursive(depth + 1, max_depth)
                    except WebDriverException as we:
                        # Cross-origin frames will throw; skip them
                        self.add_progress_log(f"ℹ️ Tab {tab_number}: Skipping inaccessible iframe at depth {depth} index {idx}")
                    finally:
                        try:
                            driver.switch_to.parent_frame()
                        except Exception:
                            try:
                                driver.switch_to.default_content()
                            except Exception:
                                pass
            inject_recursive()
        finally:
            # Ensure we return to top document
            try:
                driver.switch_to.default_content()
            except Exception:
                pass
        if injected_any:
            self.add_progress_log(f"✅ Tab {tab_number}: Auto-download script injection attempted in all frames for scene {scene_number}")
        else:
            self.add_progress_log(f"❌ Tab {tab_number}: Auto-download injection failed in all frames for scene {scene_number}")
    
    def inject_auto_download_script(self, driver, scene_number, tab_number):
        """Inject the auto-download script using WebDriver-based monitoring"""
        try:
            self.add_progress_log(f"🔄 Tab {tab_number}: Starting WebDriver-based image monitoring for scene {scene_number}...")
            
            # Start monitoring in a separate thread to not block the main process
            import threading
            monitor_thread = threading.Thread(
                target=self.check_and_download_generated_images,
                args=(driver, scene_number, tab_number, 300),
                daemon=True
            )
            monitor_thread.start()
            
            self.add_progress_log(f"✅ Tab {tab_number}: WebDriver image monitoring started for scene {scene_number}")
        except Exception as e:
            self.add_progress_log(f"❌ Tab {tab_number}: Failed to start image monitoring: {str(e)[:50]}")
    
    def monitor_tabs_and_keep_alive(self, driver, tab_data):
        """Monitor tabs and keep the driver alive for continuous processing"""
        try:
            self.add_progress_log(f"🔍 Starting KEEP-ALIVE monitoring of {len(tab_data)} simultaneous tabs...")
            self.add_progress_log(f"🌐 Browser will stay open indefinitely for automation scripts to complete")
            self.add_progress_log(f"💡 Auto-download scripts are running independently in each tab")
            
            # Brief monitoring period just to mark tabs as active
            monitor_time = 30  # Only 30 seconds of active monitoring
            start_monitor_time = time.time()
            
            active_count = 0
            
            while (time.time() - start_monitor_time) < monitor_time and self.smart_batch_running:
                # Just check that tabs are responsive
                for tab in tab_data:
                    if tab['status'] == 'processing':
                        try:
                            # Quick tab check
                            if tab['tab_handle'] in driver.window_handles:
                                active_count += 1
                        except Exception as tab_error:
                            self.add_progress_log(f"⚠️ Tab {tab['tab_index']+1} not responsive: {str(tab_error)[:50]}")
                
                time.sleep(5)  # Check every 5 seconds
            
            # Mark all tabs as active (let JavaScript handle completion)
            for tab in tab_data:
                if tab['status'] == 'processing':
                    tab['status'] = 'completed'  # Mark as "completed" but really means "active"
                    
            self.add_progress_log(f"✅ All {len(tab_data)} tabs are active with automation scripts running")
            self.add_progress_log(f"🔄 Browser will remain open for continued processing")
            self.add_progress_log(f"📥 Images will download automatically when generation completes")
            
            # Don't close anything - let it stay open!
            
        except Exception as e:
            self.add_progress_log(f"💥 Monitor error: {str(e)}")
            # Still mark all as active
            for tab in tab_data:
                if tab['status'] == 'processing':
                    tab['status'] = 'completed'

    def monitor_and_download_all_tabs(self, driver, tab_data):
        """Monitor all tabs for completion and handle downloads"""
        try:
            self.add_progress_log(f"🔍 Starting monitoring of {len(tab_data)} simultaneous tabs...")
            
            max_monitor_time = 900  # 15 minutes total monitoring time
            start_monitor_time = time.time()
            check_interval = 5  # Check every 5 seconds
            
            completed_count = 0
            failed_count = 0
            
            while (time.time() - start_monitor_time) < max_monitor_time and self.smart_batch_running:
                # Check each tab's status
                for tab in tab_data:
                    if tab['status'] == 'processing':
                        try:
                            # Switch to this tab
                            driver.switch_to.window(tab['tab_handle'])
                            
                            # Check if this tab has completed (simplified check)
                            elapsed_time = time.time() - tab['start_time']
                            
                            # Mark as completed after reasonable time (auto-download handles the rest)
                            if elapsed_time > 120:  # 2 minutes minimum processing time
                                tab['status'] = 'completed'
                                completed_count += 1
                                self.add_progress_log(f"✅ Tab {tab['tab_index']+1}: Scene {tab['scene_number']} marked as completed (auto-download active)")
                        
                        except Exception as tab_error:
                            self.add_progress_log(f"⚠️ Error checking Tab {tab['tab_index']+1}: {str(tab_error)[:50]}")
                            tab['status'] = 'failed'
                            failed_count += 1
                
                # Update progress
                processing_count = len([t for t in tab_data if t['status'] == 'processing'])
                if processing_count > 0:
                    elapsed_monitor = int(time.time() - start_monitor_time)
                    self.add_progress_log(f"📊 Monitor status: ✅{completed_count} ❌{failed_count} ⏳{processing_count} ({elapsed_monitor}s elapsed)")
                else:
                    self.add_progress_log(f"🎉 All tabs completed monitoring! ✅{completed_count} ❌{failed_count}")
                    break
                
                # Wait before next check
                time.sleep(check_interval)
            
            # Final status update
            if (time.time() - start_monitor_time) >= max_monitor_time:
                self.add_progress_log(f"⏰ Monitoring timeout reached. Auto-download scripts will continue in background.")
                # Mark remaining processing tabs as completed (auto-download will handle them)
                for tab in tab_data:
                    if tab['status'] == 'processing':
                        tab['status'] = 'completed'
                        completed_count += 1
            
            self.add_progress_log(f"📊 Final monitoring results: ✅{completed_count} ❌{failed_count} total tabs")
            
        except Exception as e:
            self.add_progress_log(f"💥 Monitor error: {str(e)}")
            # Mark all as completed to continue
            for tab in tab_data:
                if tab['status'] == 'processing':
                    tab['status'] = 'completed'
    
    def process_scene_in_simple_tab(self, scene_number, driver, wait, tab_number, upload_images=True):
        """Process a single scene in simple mode - open model, optionally upload images, paste prompt, run
        
        Args:
            upload_images: If True, upload character images (for NanoBanana). If False, skip images (for image models)
        """
        try:
            model_type = "NanoBanana (with images)" if upload_images else "Image Model (no image upload)"
            self.add_progress_log(f"📑 Tab {tab_number}: Starting simple processing for scene {scene_number} [{model_type}]...")
            
            # Get scene data
            scene_data = self.get_scene_data(scene_number)
            if not scene_data:
                self.add_progress_log(f"❌ Tab {tab_number}: No scene data found for scene {scene_number}")
                return False
            
            prompt_text, present_chars = scene_data
            self.add_progress_log(f"✅ Tab {tab_number}: Scene {scene_number} data loaded - {len(prompt_text)} chars, {len(present_chars)} characters detected")
            
            # Record scene number for this tab handle to ensure correct naming later
            try:
                current_handle = driver.current_window_handle
                self.tab_scene_number_map[current_handle] = int(scene_number)
                self.add_progress_log(f"🧭 Tab {tab_number}: Mapped handle to scene {scene_number} for naming")
            except Exception:
                pass

            # Tab already has model URL, just wait for it to load
            self.add_progress_log(f"⏳ Tab {tab_number}: Waiting for page to load for scene {scene_number}...")
            
            # Fast page load detection - check if textarea is available
            # For image models, use shorter timeout since no image upload needed
            max_wait = 10 if not upload_images else 15
            start_time = time.time()
            page_ready = False
            
            while (time.time() - start_time) < max_wait:
                try:
                    # Check if textarea is available
                    textarea = driver.find_element(By.XPATH, "//textarea")
                    if textarea and textarea.is_displayed():
                        self.add_progress_log(f"✅ Tab {tab_number}: Page ready for scene {scene_number} ({int(time.time() - start_time)}s)")
                        page_ready = True
                        break
                except:
                    pass
                time.sleep(0.3)  # Check every 0.3 seconds for faster detection
            
            if not page_ready:
                self.add_progress_log(f"⚠️ Tab {tab_number}: Page load timeout, continuing anyway for scene {scene_number}...")
                # Skip additional wait for image models
                if upload_images:
                    time.sleep(2)
            
            # Check authentication (simplified)
            page_title = driver.title.lower()
            current_url = driver.current_url.lower()
            
            if 'sign in' in page_title or 'accounts.google.com' in current_url:
                self.add_progress_log(f"⚠️ Tab {tab_number}: Authentication required for scene {scene_number} - skipping")
                return False
            
            self.add_progress_log(f"✅ Tab {tab_number}: Successfully opened model page for scene {scene_number}")
            
            # STEP 1: Upload character images FIRST (only for NanoBanana)
            if upload_images:
                self.add_progress_log(f"📤 Tab {tab_number}: STEP 1 - Uploading images FIRST for scene {scene_number} (NanoBanana mode)...")
            else:
                self.add_progress_log(f"⏭️ Tab {tab_number}: Skipping image upload (Image Model mode - no image support)")
            
            if upload_images and present_chars:
                # Get image files for characters
                image_files = []
                for char_id in present_chars:
                    ch = next((c for c in self.characters if c["id"] == char_id), None)
                    if ch:
                        char_images = [img for img in ch.get("images", []) if os.path.exists(img)]
                        image_files.extend(char_images)
                        self.add_progress_log(f"🖼️ Tab {tab_number}: {char_id}: {len(char_images)} images queued FIRST")
                
                if image_files:
                    self.add_progress_log(f"📤 Tab {tab_number}: Uploading {len(image_files)} images FIRST for scene {scene_number}...")
                    
                    try:
                        # Click "Insert Assets" button
                        trigger_button = self.wait_for_insert_assets_accessible(driver, wait, timeout=180, interval=5)
                        if not trigger_button:
                            self.add_progress_log(f"❌ Tab {tab_number}: Insert assets UI not available for scene {scene_number}")
                            # Continue anyway - maybe images aren't critical
                        else:
                            driver.execute_script("arguments[0].scrollIntoView(true);", trigger_button)
                            ActionChains(driver).move_to_element(trigger_button).click().perform()
                            time.sleep(2)
                        
                        # Upload images
                        file_input = wait.until(EC.presence_of_element_located((
                            By.XPATH, "//input[@type='file' and @multiple]"
                        )))
                        all_file_paths = '\n'.join([os.path.abspath(img) for img in image_files])
                        file_input.send_keys(all_file_paths)
                        
                        # Wait for tokens and run immediately when ready
                        self.add_progress_log(f"👁️ Tab {tab_number}: Watching for tokens to run immediately for scene {scene_number}...")
                        
                        # FAST token detection - minimal waiting after upload
                        self.add_progress_log(f"⚡ Tab {tab_number}: FAST token check for scene {scene_number} (no long waiting!)...")
                        
                        # Quick 3-second wait for immediate token processing
                        time.sleep(3)
                        
                        # Single token check - if we find any tokens, we're ready to go!
                        try:
                            result = driver.execute_script("""
                                function getTokenCount() {
                                    const selectors = ['.v3-token-count-value', '[class*="token-count"]', 'ms-token-count span'];
                                    for (let selector of selectors) {
                                        let elements = document.querySelectorAll(selector);
                                        for (let element of elements) {
                                            let text = element.textContent.trim();
                                            let match = text.match(/(\\d[\\d,]*)\\s*tokens?/i);
                                            if (match) return {count: parseInt(match[1].replace(/,/g, '')), found: true};
                                        }
                                    }
                                    return {count: 0, found: false};
                                }
                                return getTokenCount();
                            """)
                            
                            if result and result.get('found', False):
                                token_count = result.get('count', 0)
                                self.add_progress_log(f"⚡ Tab {tab_number}: Found {token_count} tokens - READY TO RUN scene {scene_number}!")
                            else:
                                self.add_progress_log(f"⚡ Tab {tab_number}: No tokens found yet - RUNNING ANYWAY for scene {scene_number}!")
                                
                        except Exception as e:
                            self.add_progress_log(f"⚡ Tab {tab_number}: Token check failed - RUNNING ANYWAY for scene {scene_number}!")
                        
                        self.add_progress_log(f"✅ Tab {tab_number}: Images processed FIRST for scene {scene_number}!")
                        
                    except Exception as upload_error:
                        self.add_progress_log(f"⚠️ Tab {tab_number}: Image upload failed for scene {scene_number}: {str(upload_error)[:50]}")
                        # Continue anyway - maybe images aren't critical
                else:
                    self.add_progress_log(f"ℹ️ Tab {tab_number}: No images to upload for scene {scene_number}")
            
            # STEP 2: Wait after uploading images (only if we uploaded images)
            if upload_images:
                self.add_progress_log(f"⏱️ Tab {tab_number}: STEP 2 - Waiting 2 seconds after image upload (NanoBanana mode)...")
                time.sleep(2)  # Reduced from 3 to 2 seconds
            else:
                self.add_progress_log(f"⏭️ Tab {tab_number}: Skipping wait (Image Model - no wait needed)")
            
            # STEP 3: Find textarea and paste prompt
            if upload_images:
                self.add_progress_log(f"📝 Tab {tab_number}: STEP 3 - Finding textarea and pasting prompt AFTER uploading images...")
            else:
                self.add_progress_log(f"📝 Tab {tab_number}: Finding textarea and pasting prompt (Image Model mode)...")
            
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            # For image models, use faster element finding without long waits
            if not upload_images:
                # Fast mode - try direct find first
                for selector in textarea_selectors:
                    try:
                        chat_input = driver.find_element(By.XPATH, selector)
                        if chat_input and chat_input.is_displayed():
                            break
                    except:
                        continue
                # If not found immediately, quick wait
                if not chat_input:
                    for selector in textarea_selectors:
                        try:
                            chat_input = WebDriverWait(driver, 3).until(EC.presence_of_element_located((By.XPATH, selector)))
                            break
                        except:
                            continue
            else:
                # NanoBanana mode - use standard wait
                for selector in textarea_selectors:
                    try:
                        chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                        break
                    except:
                        continue
            
            if not chat_input:
                self.add_progress_log(f"❌ Tab {tab_number}: Could not find textarea for scene {scene_number}")
                return False
            
            # Paste prompt
            if upload_images:
                self.add_progress_log(f"📝 Tab {tab_number}: Pasting prompt AFTER uploading images for scene {scene_number} ({len(prompt_text)} chars)...")
            else:
                self.add_progress_log(f"📝 Tab {tab_number}: Pasting prompt for scene {scene_number} ({len(prompt_text)} chars)...")
            
            driver.execute_script("arguments[0].scrollIntoView(true);", chat_input)
            driver.execute_script("arguments[0].focus();", chat_input)
            # Shorter wait for image models
            time.sleep(0.2 if not upload_images else 0.5)
            
            # Paste entire prompt in one shot (fast mode for image models)
            success_paste = self.paste_text_all_at_once(driver, chat_input, prompt_text, fast_mode=not upload_images)
            if not success_paste:
                self.add_progress_log(f"❌ Tab {tab_number}: Failed to paste prompt for scene {scene_number}")
                return False
            
            if upload_images:
                self.add_progress_log(f"✅ Tab {tab_number}: Prompt pasted AFTER uploading images for scene {scene_number}!")
            else:
                self.add_progress_log(f"✅ Tab {tab_number}: Prompt pasted for scene {scene_number}!")
            
            # Select Aspect Ratio before triggering run
            try:
                selected_label = self.aspect_ratio_var.get() if hasattr(self, "aspect_ratio_var") else "YouTube 16:9"
                self.add_progress_log(f"🎛️ Tab {tab_number}: Selecting aspect ratio: {selected_label}")
                # Use image-model-specific selection when upload_images is False
                self.select_aspect_ratio_in_ai_studio(driver, is_image_model=not upload_images)
                # Shorter wait for image models
                time.sleep(0.5 if not upload_images else 1)
            except Exception as e:
                self.add_progress_log(f"⚠️ Tab {tab_number}: Aspect ratio selection skipped or failed: {str(e)[:50]}")
            
            # STEP 4: Wait after pasting text before running
            if upload_images:
                self.add_progress_log(f"⏱️ Tab {tab_number}: STEP 4 - Waiting 1.5 seconds before running (NanoBanana mode)...")
                time.sleep(1.5)  # Reduced from 2 to 1.5 seconds
            else:
                self.add_progress_log(f"⏭️ Tab {tab_number}: STEP 4 - Minimal wait (Image Model - fast mode)...")
                time.sleep(0.5)  # Just 0.5 second for image models
            
            # STEP 5: Focus textarea again and trigger AI response (FINAL STEP!)
            self.add_progress_log(f"🚀 Tab {tab_number}: STEP 5 - Final focus and trigger for scene {scene_number}...")
            
            # Focus textarea again before triggering
            driver.execute_script("arguments[0].focus();", chat_input)
            # Minimal wait for image models
            time.sleep(0.2 if not upload_images else 0.5)
            
            # Final trigger
            try:
                chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                self.add_progress_log(f"🚀 Tab {tab_number}: Scene {scene_number} triggered successfully with NEW ORDER (Images → Wait 3s → Prompt → Wait 2s → Run)!")
                
                # Auto-download removed - user will download manually
                self.add_progress_log(f"✅ Tab {tab_number}: Scene {scene_number} triggered successfully! Use 'Download Images' for manual download.")
                
                return True
            except Exception as primary_error:
                try:
                    # Fallback method
                    action = ActionChains(driver)
                    action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                    self.add_progress_log(f"🚀 Tab {tab_number}: Scene {scene_number} triggered successfully with ActionChains (NEW ORDER)!")
                    
                    # Auto-download removed - user will download manually
                    self.add_progress_log(f"✅ Tab {tab_number}: Scene {scene_number} triggered successfully (fallback)! Use 'Download Images' for manual download.")
                    
                    return True
                except Exception as fallback_error:
                    self.add_progress_log(f"❌ Tab {tab_number}: Failed to trigger scene {scene_number}: {str(fallback_error)[:50]}")
                    return False
        
        except Exception as e:
            self.add_progress_log(f"💥 Tab {tab_number}: Error processing scene {scene_number}: {str(e)[:100]}")
            return False
            target_scene = next((s for s in scenes if str(s.get("scene_number")) == str(scene_number)), None)
            
            if not target_scene:
                self.add_progress_log(f"❌ Scene {scene_number} not found in data")
                return False
            
            # Get prompt text for this scene
            if scene_number in self.modified_prompts:
                prompt_text = self.modified_prompts[scene_number]
            else:
                prompt_text = json.dumps(target_scene, ensure_ascii=False, indent=2)
            
            if not prompt_text.strip():
                self.add_progress_log(f"❌ Scene {scene_number} has no prompt text")
                return False
            
            self.add_progress_log(f"📝 Scene {scene_number} prompt: {len(prompt_text)} characters")
            
            # Navigate to AI Studio
            self.add_progress_log(f"🌐 Opening AI Studio in tab for scene {scene_number}...")
            driver.get(AI_STUDIO_URL)
            time.sleep(10)  # Wait for page load
            
            # Check authentication (simplified for batch processing)
            page_title = driver.title.lower()
            current_url = driver.current_url.lower()
            
            if 'sign in' in page_title or 'accounts.google.com' in current_url:
                self.add_progress_log(f"⚠️ Scene {scene_number}: Authentication required - skipping this scene")
                return False
            
            # Detect character IDs in the prompt text
            present_ids = [c["id"] for c in self.characters if c["id"] in prompt_text]
            self.add_progress_log(f"🔍 Scene {scene_number} characters: {', '.join(present_ids) if present_ids else 'None'}")
            
            # Upload character images if needed
            if present_ids:
                image_files = []
                for cid in present_ids:
                    ch = next((c for c in self.characters if c["id"] == cid), None)
                    if ch:
                        char_images = [img for img in ch.get("images", []) if os.path.exists(img)]
                        image_files.extend(char_images)
                
                if image_files:
                    self.add_progress_log(f"📤 Scene {scene_number}: Uploading {len(image_files)} images...")
                    
                    try:
                        # Click "Insert Assets" button
                        trigger_button = wait.until(EC.element_to_be_clickable((
                            By.XPATH, "//button[contains(@aria-label, 'Insert assets')]"
                        )))
                        driver.execute_script("arguments[0].scrollIntoView(true);", trigger_button)
                        ActionChains(driver).move_to_element(trigger_button).click().perform()
                        time.sleep(2)
                        
                        # Upload images
                        file_input = wait.until(EC.presence_of_element_located((
                            By.XPATH, "//input[@type='file' and @multiple]"
                        )))
                        all_file_paths = '\n'.join([os.path.abspath(img) for img in image_files])
                        file_input.send_keys(all_file_paths)
                        
                        # Wait briefly for upload processing
                        self.add_progress_log(f"⏳ Scene {scene_number}: Waiting for image processing...")
                        time.sleep(15)  # Shortened wait for batch processing
                        
                        # Close upload popup if present
                        try:
                            popup_close_js = """
                            function closePopups() {
                                const selectors = [
                                    'button[aria-label*="close"]',
                                    'button[aria-label*="Close"]', 
                                    'button[title*="close"]',
                                    'button[title*="Close"]'
                                ];
                                for (let selector of selectors) {
                                    let elements = document.querySelectorAll(selector);
                                    for (let element of elements) {
                                        if (element && element.offsetParent !== null) {
                                            element.click();
                                            return true;
                                        }
                                    }
                                }
                                return false;
                            }
                            return closePopups();
                            """
                            driver.execute_script(popup_close_js)
                            time.sleep(1)
                        except:
                            pass
                        
                        self.add_progress_log(f"✅ Scene {scene_number}: Images uploaded")
                    
                    except Exception as upload_error:
                        self.add_progress_log(f"⚠️ Scene {scene_number}: Image upload failed: {str(upload_error)[:50]}")
            
            # Find textarea and paste prompt
            self.add_progress_log(f"📝 Scene {scene_number}: Finding textarea...")
            
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            for selector in textarea_selectors:
                try:
                    chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                    break
                except:
                    continue
            
            if not chat_input:
                self.add_progress_log(f"❌ Scene {scene_number}: Could not find textarea")
                return False
            
            # Paste prompt and trigger
            self.add_progress_log(f"📝 Scene {scene_number}: Pasting prompt and triggering...")
            driver.execute_script("arguments[0].scrollIntoView(true);", chat_input)
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            # Paste entire prompt in one shot
            success_paste = self.paste_text_all_at_once(driver, chat_input, prompt_text)
            if not success_paste:
                self.add_progress_log(f"❌ Scene {scene_number}: Failed to paste prompt")
                return False
            time.sleep(0.5)
            
            # Select Aspect Ratio before triggering run
            try:
                selected_label = self.aspect_ratio_var.get() if hasattr(self, "aspect_ratio_var") else "YouTube 16:9"
                self.add_progress_log(f"🎛️ Scene {scene_number}: Selecting aspect ratio: {selected_label}")
                # This is internal, default to NanoBanana
                self.select_aspect_ratio_in_ai_studio(driver, is_image_model=False)
                time.sleep(1)
            except Exception as e:
                self.add_progress_log(f"⚠️ Scene {scene_number}: Aspect ratio selection skipped or failed: {str(e)[:50]}")
            
            # Trigger AI response
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(0.5)
            
            try:
                chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                self.add_progress_log(f"✅ Scene {scene_number}: Prompt sent successfully!")
                return True
            except Exception as trigger_error:
                try:
                    action = ActionChains(driver)
                    action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                    self.add_progress_log(f"✅ Scene {scene_number}: Prompt sent successfully (fallback)!")
                    return True
                except Exception as fallback_error:
                    self.add_progress_log(f"❌ Scene {scene_number}: Failed to trigger: {str(fallback_error)[:50]}")
                    return False
        
        except Exception as e:
            self.add_progress_log(f"💥 Scene {scene_number} error: {str(e)[:100]}")
            return False
    
    def send_test_message_first_tab(self, driver, wait, scene_number):
        """Send a test message like 'hello banana' to handle internal errors in first tab"""
        try:
            self.add_progress_log(f"🍌 First tab test: Sending 'hello banana' for scene {scene_number} to handle internal errors...")
            
            # Skip navigating to AI Studio - assume we're already in the right tab
            # Check authentication
            page_title = driver.title.lower()
            current_url = driver.current_url.lower()
            
            if 'sign in' in page_title or 'accounts.google.com' in current_url:
                self.add_progress_log(f"⚠️ First tab test: Authentication required - skipping test message")
                return False
            
            # Find textarea
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            for selector in textarea_selectors:
                try:
                    chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                    break
                except:
                    continue
            
            if not chat_input:
                self.add_progress_log(f"❌ First tab test: Could not find textarea for test message")
                return False
            
            # Send test message
            test_message = "hello banana"
            self.add_progress_log(f"🍌 First tab test: Sending test message: '{test_message}'...")
            
            driver.execute_script("arguments[0].scrollIntoView(true);", chat_input)
            driver.execute_script("arguments[0].focus();", chat_input)
            
            chat_input.clear()
            chat_input.send_keys(test_message)
            
            # Wait for token count and immediately send message when ready
            self.add_progress_log(f"👁️ First tab test: Watching for token count...")
            
            # Monitor token count and send immediately when ready
            max_wait = 10  # Maximum 10 seconds to wait for tokens
            check_interval = 0.5  # Check every 0.5 seconds (faster checking)
            start_time = time.time()
            message_sent = False
            
            while (time.time() - start_time) < max_wait and not message_sent:
                try:
                    # Check for token count
                    result = driver.execute_script("""
                        function getTokenCount() {
                            const selectors = ['.v3-token-count-value', '[class*="token-count"]', 'ms-token-count span'];
                            for (let selector of selectors) {
                                let elements = document.querySelectorAll(selector);
                                for (let element of elements) {
                                    let text = element.textContent.trim();
                                    let match = text.match(/(\\d[\\d,]*)\\s*tokens?/i);
                                    if (match) return {count: parseInt(match[1].replace(/,/g, '')), found: true};
                                }
                            }
                            return {count: 0, found: false};
                        }
                        return getTokenCount();
                    """)
                    
                    if result and result.get('found', False) and result.get('count', 0) > 0:
                        token_count = result.get('count', 0)
                        self.add_progress_log(f"🎯 First tab test: Tokens ready ({token_count} tokens) - sending immediately!")
                        
                        # Immediately send message once tokens are processed
                        try:
                            chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                            self.add_progress_log(f"🍌 First tab test: Test message sent successfully!")
                            message_sent = True
                        except Exception as primary_error:
                            try:
                                # Fallback method
                                action = ActionChains(driver)
                                action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                                self.add_progress_log(f"🍌 First tab test: Test message sent successfully (fallback)!")
                                message_sent = True
                            except Exception as fallback_error:
                                self.add_progress_log(f"❌ First tab test: Failed to send test message: {str(fallback_error)[:50]}")
                                return False
                except Exception as e:
                    pass  # Silent failure on token check
                
                if not message_sent:
                    time.sleep(check_interval)  # Brief pause between checks
            
            # If still no tokens after timeout, try sending anyway
            if not message_sent:
                self.add_progress_log(f"⚠️ First tab test: Token count not found, sending message anyway...")
                try:
                    chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                    self.add_progress_log(f"🍌 First tab test: Test message sent without token confirmation")
                    message_sent = True
                except Exception as e:
                    try:
                        action = ActionChains(driver)
                        action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                        self.add_progress_log(f"🍌 First tab test: Test message sent without token confirmation (fallback)")
                        message_sent = True
                    except Exception as fallback_e:
                        self.add_progress_log(f"❌ First tab test: All send attempts failed: {str(fallback_e)[:50]}")
                        return False
            
            # Only brief wait to check for errors
            self.add_progress_log(f"⏳ First tab test: Checking for errors...")
            time.sleep(4)  # Reduced wait time
            
            # Check for internal error message
            has_internal_error = self.check_for_internal_error(driver)
            if has_internal_error:
                self.add_progress_log(f"⚠️ First tab test: Internal error detected! Will implement retry logic.")
                # Try to retry automatically
                retry_success = self.retry_after_internal_error(driver, wait)
                if retry_success:
                    self.add_progress_log(f"✅ First tab test: Retry after internal error was successful!")
                else:
                    self.add_progress_log(f"❌ First tab test: Retry after internal error failed")
            else:
                self.add_progress_log(f"✅ First tab test: No errors detected, continuing with normal processing!")
            
            return True
            
        except Exception as e:
            self.add_progress_log(f"💥 First tab test error: {str(e)[:100]}")
            return False
    
    def check_for_internal_error(self, driver):
        """Check if there's an 'An internal error has occurred' message"""
        try:
            # Look for internal error message
            error_text = driver.execute_script("""
                const errorSelectors = [
                    '[class*="error"]',
                    '[class*="Error"]', 
                    '.error-message',
                    '.error',
                    'div[role="alert"]'
                ];
                
                for (let selector of errorSelectors) {
                    let elements = document.querySelectorAll(selector);
                    for (let element of elements) {
                        let text = element.textContent.toLowerCase();
                        if (text.includes('internal error') || text.includes('error occurred')) {
                            return text;
                        }
                    }
                }
                
                // Also check for generic error patterns in the page
                let pageText = document.body.textContent.toLowerCase();
                if (pageText.includes('an internal error has occurred') || 
                    pageText.includes('internal error occurred')) {
                    return 'internal error detected';
                }
                
                return null;
            """)
            
            return error_text is not None
            
        except Exception as e:
            self.add_progress_log(f"⚠️ Error checking for internal error: {str(e)[:50]}")
            return False
    
    def retry_after_internal_error(self, driver, wait):
        """Retry by sending Ctrl+Enter again after internal error"""
        try:
            self.add_progress_log(f"🔄 Retry: Attempting to retry with Ctrl+Enter after internal error...")
            
            # Find textarea again
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea') and contains(@class, 'ng-valid')]",
                "//ms-autosize-textarea//textarea[@class*='textarea']",
                "//div[contains(@class, 'text-input-wrapper')]//textarea",
                "//textarea[@aria-label*='Type something']",
                "//textarea"
            ]
            
            chat_input = None
            for selector in textarea_selectors:
                try:
                    chat_input = wait.until(EC.presence_of_element_located((By.XPATH, selector)))
                    break
                except:
                    continue
            
            if not chat_input:
                self.add_progress_log(f"❌ Retry: Could not find textarea for retry")
                return False
            
            # Focus and retry
            driver.execute_script("arguments[0].focus();", chat_input)
            time.sleep(1)
            
            self.add_progress_log(f"🔄 Retry: Sending Ctrl+Enter to retry...")
            
            try:
                chat_input.send_keys(Keys.CONTROL + Keys.ENTER)
                self.add_progress_log(f"✅ Retry: Ctrl+Enter sent successfully!")
            except Exception as primary_error:
                try:
                    # Fallback method
                    action = ActionChains(driver)
                    action.key_down(Keys.CONTROL).send_keys(Keys.ENTER).key_up(Keys.CONTROL).perform()
                    self.add_progress_log(f"✅ Retry: Ctrl+Enter sent successfully (fallback)!")
                except Exception as fallback_error:
                    self.add_progress_log(f"❌ Retry: Failed to send Ctrl+Enter: {str(fallback_error)[:50]}")
                    return False
            
            # Wait a bit for the retry to process
            self.add_progress_log(f"⏳ Retry: Waiting 5 seconds for retry response...")
            time.sleep(5)
            
            # Check if error is still there
            still_has_error = self.check_for_internal_error(driver)
            if still_has_error:
                self.add_progress_log(f"⚠️ Retry: Internal error still present after retry")
                return False
            else:
                self.add_progress_log(f"✅ Retry: Internal error resolved after retry!")
                return True
                
        except Exception as e:
            self.add_progress_log(f"💥 Retry error: {str(e)[:100]}")
            return False
    
    # ---------- WebDriver Management Methods ----------
    def refresh_webdriver_status(self):
        """Refresh the WebDriver status display"""
        try:
            self.webdriver_status_text.config(state="normal")
            self.webdriver_status_text.delete(1.0, tk.END)
            
            if not hasattr(self, 'batch_driver') or not self.batch_driver:
                self.webdriver_status_text.insert(tk.END, "No active WebDriver sessions\n")
                self.webdriver_status_text.insert(tk.END, "\nStart batch processing to see WebDriver status")
            else:
                try:
                    # Get current driver information
                    driver = self.batch_driver
                    current_url = driver.current_url
                    window_handles = driver.window_handles
                    current_handle = driver.current_window_handle
                    
                    # Update active webdrivers tracking
                    self.active_webdrivers['batch_driver'] = {
                        'driver': driver,
                        'current_url': current_url,
                        'tabs': len(window_handles),
                        'active': True
                    }
                    
                    self.webdriver_status_text.insert(tk.END, f"🌐 Active WebDriver Session Found\n")
                    self.webdriver_status_text.insert(tk.END, f"📑 Total Tabs: {len(window_handles)}\n")
                    self.webdriver_status_text.insert(tk.END, f"🔗 Current URL: {current_url[:50]}...\n")
                    self.webdriver_status_text.insert(tk.END, "\n📋 Tab Information:\n")
                    
                    # Get information about each tab
                    for i, handle in enumerate(window_handles):
                        try:
                            driver.switch_to.window(handle)
                            tab_url = driver.current_url
                            tab_title = driver.title
                            
                            # Determine tab status
                            if 'aistudio.google.com' in tab_url:
                                status = "🎯 AI Studio"
                                # Try to get scene info from tab
                                tab_info = self.get_tab_scene_info(driver, i+1)
                                self.webdriver_status_text.insert(tk.END, f"  Tab {i+1}: {status} {tab_info}\n")
                            else:
                                status = "📄 Other"
                                self.webdriver_status_text.insert(tk.END, f"  Tab {i+1}: {status} - {tab_title[:30]}...\n")
                                
                        except Exception as tab_error:
                            self.webdriver_status_text.insert(tk.END, f"  Tab {i+1}: ❌ Error accessing tab\n")
                    
                    # Switch back to original tab
                    try:
                        driver.switch_to.window(current_handle)
                    except:
                        if window_handles:
                            driver.switch_to.window(window_handles[0])
                            
                except Exception as driver_error:
                    self.webdriver_status_text.insert(tk.END, f"❌ WebDriver Error: {str(driver_error)[:50]}\n")
                    # Mark driver as inactive
                    if hasattr(self, 'batch_driver'):
                        self.active_webdrivers['batch_driver'] = {
                            'driver': self.batch_driver,
                            'active': False,
                            'error': str(driver_error)
                        }
            
            self.webdriver_status_text.config(state="disabled")
            
        except Exception as e:
            try:
                self.webdriver_status_text.config(state="normal")
                self.webdriver_status_text.delete(1.0, tk.END)
                self.webdriver_status_text.insert(tk.END, f"Error updating status: {str(e)}")
                self.webdriver_status_text.config(state="disabled")
            except:
                pass
    
    def get_tab_scene_info(self, driver, tab_number):
        """Try to extract scene information from the current tab"""
        try:
            # Check if there's a prompt in the textarea that might give us scene info
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea')]",
                "//textarea[@aria-label*='Type']",
                "//textarea"
            ]
            
            for selector in textarea_selectors:
                try:
                    textarea = driver.find_element(By.XPATH, selector)
                    prompt_text = textarea.get_attribute("value") or ""
                    if prompt_text:
                        # Try to detect scene number from prompt
                        scene_match = re.search(r'scene[_\s]*[#\d]*\s*(\d+)', prompt_text.lower())
                        if scene_match:
                            scene_num = scene_match.group(1)
                            return f"(Scene {scene_num})"
                        elif len(prompt_text) > 20:
                            return f"(Prompt: {len(prompt_text)} chars)"
                    break
                except:
                    continue
            
            # Check if there are images indicating generation
            images = driver.find_elements(By.CSS_SELECTOR, "img[src^='data:image'], img[src*='googleusercontent.com']")
            if images:
                return f"(Generated: {len(images)} images)"
            
            return "(Active)"
            
        except Exception as e:
            return "(Unknown)"
    
    def download_images_from_all_tabs(self):
        """Download images from all opened tabs with proper prompt-based naming"""
        if not hasattr(self, 'batch_driver') or not self.batch_driver:
            self.add_progress_log("❌ No active WebDriver session found. Start batch processing first.")
            messagebox.showwarning(APP_TITLE, "No active WebDriver session found. Please start batch processing first.")
            return
        
        # Check if auto-download is already in progress
        if hasattr(self, '_auto_download_in_progress') and self._auto_download_in_progress:
            self.add_progress_log("⚠️ Auto-download is already in progress. Please wait...")
            return
        
        # Show progress log
        if not self.show_progress.get():
            self.show_progress.set(True)
            self.toggle_progress_log()
        
        # Start download process in a separate thread
        self.add_progress_log("🚀 Starting manual download from all tabs...")
        
        # Set a flag to indicate manual download is in progress
        self._manual_download_in_progress = True
        
        # Start the download thread
        threading.Thread(
            target=self._download_from_all_tabs_worker, 
            daemon=True,
            name="ManualDownloadThread"
        ).start()
    
    def _download_from_all_tabs_worker(self):
        """Worker method to download images from all tabs - ensures no duplicate downloads"""
        try:
            driver = self.batch_driver
            
            # Set the parent_app reference on the driver for the download_images module to check
            if not hasattr(driver, 'parent_app'):
                driver.parent_app = self
                
            window_handles = driver.window_handles
            current_handle = driver.current_window_handle
            
            self.add_progress_log(f"🔍 Found {len(window_handles)} tabs to check for images")
            
            downloaded_total = 0
            processed_tabs = 0
            downloaded_hashes = set()  # Track downloaded image hashes to prevent duplicates
            
            for i, handle in enumerate(window_handles):
                try:
                    self.add_progress_log(f"\n📑 Checking Tab {i+1}/{len(window_handles)}...")
                    driver.switch_to.window(handle)
                    
                    # Check if this is an AI Studio tab
                    current_url = driver.current_url
                    if 'aistudio.google.com' not in current_url:
                        self.add_progress_log(f"⏭️ Tab {i+1}: Skipping non-AI Studio tab")
                        continue
                    
                    processed_tabs += 1
                    
                    # Determine scene number for this tab using mapping first (avoid tab-index fallback)
                    prompt_text = self.extract_prompt_from_tab(driver)
                    mapped_scene = None
                    try:
                        mapped_scene = self.tab_scene_number_map.get(handle)
                    except Exception:
                        mapped_scene = None
                    if mapped_scene is not None:
                        scene_number = int(mapped_scene)
                    else:
                        # Try to extract from prompt content
                        scene_number = self.extract_scene_number_from_prompt(prompt_text, None)
                        if scene_number is None:
                            # As a last resort, do NOT offset by tab index; just log unknown and use 1
                            scene_number = 1
                            self.add_progress_log(f"ℹ️ Tab {i+1}: Scene number unknown, defaulting to 1")
                    
                    self.add_progress_log(f"📝 Tab {i+1}: Using scene {scene_number} for naming ({len(prompt_text)} chars prompt)")
                    
                    # Find images in this tab
                    images = self.find_loaded_images(driver)
                    if images:
                        self.add_progress_log(f"📸 Tab {i+1}: Found {len(images)} candidate images")
                        
                        tab_downloaded = 0
                        for img_idx, img_element in enumerate(images):
                            try:
                                # Get image source to create a unique hash
                                src = img_element.get_attribute('src')
                                if not src:
                                    continue
                                    
                                # Create a simple hash of the image source to detect duplicates
                                import hashlib
                                img_hash = hashlib.md5(src.encode('utf-8')).hexdigest()
                                
                                if img_hash in downloaded_hashes:
                                    self.add_progress_log(f"⏭️ Tab {i+1}: Image {img_idx + 1} already downloaded, skipping...")
                                    continue
                                    
                                downloaded_hashes.add(img_hash)
                                
                                success = self.download_image_with_proper_naming(
                                    driver, img_element, scene_number, img_idx + 1, prompt_text
                                )
                                if success:
                                    tab_downloaded += 1
                                    downloaded_total += 1
                                
                            except Exception as img_error:
                                self.add_progress_log(f"⚠️ Tab {i+1}: Error processing image {img_idx + 1}: {str(img_error)[:30]}")
                        
                        self.add_progress_log(f"✅ Tab {i+1}: Downloaded {tab_downloaded}/{len(images)} new images")
                    else:
                        self.add_progress_log(f"🔍 Tab {i+1}: No images found")
                        
                except Exception as tab_error:
                    self.add_progress_log(f"❌ Tab {i+1}: Error processing tab: {str(tab_error)[:50]}")
            
            # Switch back to original tab
            try:
                driver.switch_to.window(current_handle)
            except:
                if window_handles:
                    driver.switch_to.window(window_handles[0])
            
            # Summary
            self.add_progress_log("\n" + "=" * 50)
            self.add_progress_log(f"🏁 Manual download completed!")
            self.add_progress_log(f"📑 Processed: {processed_tabs} AI Studio tabs")
            self.add_progress_log(f"📥 Downloaded: {downloaded_total} unique images")
            
            # Clear the manual download flag when done
            self._manual_download_in_progress = False
            
            if downloaded_total > 0:
                self.automation_complete(True, f"Downloaded {downloaded_total} images from {processed_tabs} tabs")
                # Update WebDriver status
                self.after(0, self.refresh_webdriver_status)
            else:
                self.automation_complete(False, "No images found to download")
                
        except Exception as e:
            self.add_progress_log(f"💥 Download process failed: {str(e)}")
    
    def download_image_with_proper_naming(self, driver, img_element, scene_number, image_index, prompt_text):
        """Download image with proper scene-based naming using deduplication by hash and project-local directory"""
        try:
            # Get the image source
            src = img_element.get_attribute("src")
            if not src:
                self.add_progress_log(f"❌ Image {image_index}: No src attribute found")
                return False
            
            # Use project-local downloads folder to avoid conflicts
            downloads_dir = os.path.join(os.getcwd(), "Downloaded_Images")
            os.makedirs(downloads_dir, exist_ok=True)
            
            self.add_progress_log(f"📥 Image {image_index}: Processing image for deduplication...")
            
            # Get image data for deduplication
            image_data = None
            
            # If it's already a data URL, decode it directly
            if src.startswith('data:'):
                self.add_progress_log(f"📥 Image {image_index}: Processing data URL...")
                try:
                    header, data = src.split(',', 1)
                    import base64
                    image_data = base64.b64decode(data)
                    self.add_progress_log(f"✅ Image {image_index}: Decoded data URL ({len(image_data)} bytes)")
                except Exception as e:
                    self.add_progress_log(f"❌ Image {image_index}: Failed to decode data URL: {str(e)[:50]}")
                    return False
            else:
                # Otherwise, try to convert to data URL via canvas and then decode
                self.add_progress_log(f"📥 Image {image_index}: Converting to data URL via canvas...")
                canvas_script = """
                return new Promise((resolve) => {
                    try {
                        const img = arguments[0];
                        const canvas = document.createElement('canvas');
                        const ctx = canvas.getContext('2d');
                        canvas.width = img.naturalWidth;
                        canvas.height = img.naturalHeight;
                        ctx.drawImage(img, 0, 0);
                        const dataUrl = canvas.toDataURL('image/png');
                        resolve({ok: true, dataUrl});
                    } catch (error) {
                        resolve({ok: false, error: error && (error.message || String(error))});
                    }
                });
                """
                result = driver.execute_async_script(canvas_script, img_element)
                if result and result.get('ok') and result.get('dataUrl', '').startswith('data:'):
                    try:
                        header, data = result['dataUrl'].split(',', 1)
                        import base64
                        image_data = base64.b64decode(data)
                        self.add_progress_log(f"✅ Image {image_index}: Canvas converted ({len(image_data)} bytes)")
                    except Exception as e:
                        self.add_progress_log(f"❌ Image {image_index}: Failed to decode canvas data: {str(e)[:50]}")
                        return False
                else:
                    err = (result or {}).get('error', 'unknown error')
                    self.add_progress_log(f"❌ Image {image_index}: Canvas conversion failed: {err}")
                    return False
            
            # Check for duplicates by content hash
            import hashlib
            image_hash = hashlib.md5(image_data).hexdigest()
            self.add_progress_log(f"🔍 Image {image_index}: Content hash: {image_hash[:8]}...")
            
            # Check if this content hash already exists in any file
            existing_files = [f for f in os.listdir(downloads_dir) if f.endswith(('.png', '.jpg', '.jpeg'))]
            for existing_file in existing_files:
                try:
                    existing_path = os.path.join(downloads_dir, existing_file)
                    with open(existing_path, 'rb') as f:
                        existing_data = f.read()
                    existing_hash = hashlib.md5(existing_data).hexdigest()
                    if existing_hash == image_hash:
                        self.add_progress_log(f"⏭️ Image {image_index}: Duplicate content detected, skipping (matches {existing_file})")
                        return True  # Return True since content already exists
                except Exception as e:
                    continue  # Skip this file if we can't read it
            
            # Find next available index for this scene
            scene_files = [f for f in existing_files if f.startswith(f"prompt_{str(scene_number).zfill(3)}_")]
            used_indices = set()
            for scene_file in scene_files:
                try:
                    # Extract index from filename like "prompt_003_1.png"
                    parts = scene_file.split('_')
                    if len(parts) >= 3:
                        index_part = parts[2].split('.')[0]  # Get "1" from "1.png"
                        used_indices.add(int(index_part))
                except:
                    continue
            
            # Find next available index
            next_index = 1
            while next_index in used_indices:
                next_index += 1
            
            # Create filename with proper scene number and incremented index
            filename = f"prompt_{str(scene_number).zfill(3)}_{next_index}.png"
            file_path = os.path.join(downloads_dir, filename)
            
            # Save the unique image
            with open(file_path, 'wb') as f:
                f.write(image_data)
            
            self.add_progress_log(f"✅ Image {image_index}: Saved unique image as {filename} ({len(image_data)} bytes)")
            return True
                
        except Exception as error:
            self.add_progress_log(f"❌ Image {image_index}: Download failed: {str(error)[:80]}")
            return False
    
    def extract_prompt_from_tab(self, driver):
        """Extract prompt text from current tab's textarea"""
        try:
            textarea_selectors = [
                "//textarea[contains(@class, 'textarea')]",
                "//textarea[@aria-label*='Type']",
                "//textarea"
            ]
            
            for selector in textarea_selectors:
                try:
                    textarea = driver.find_element(By.XPATH, selector)
                    prompt_text = textarea.get_attribute("value") or ""
                    if prompt_text:
                        return prompt_text
                except:
                    continue
            
            return ""
        except Exception as e:
            return ""
    
    def extract_scene_number_from_prompt(self, prompt_text, default_number=None):
        """Extract scene number from prompt text. Returns int or default_number.
        Does NOT infer from tab index to avoid off-by-one errors.
        """
        if prompt_text:
            # Try multiple patterns to detect scene number
            patterns = [
                r'current\s*scene\s*(\d+)',           # === CURRENT SCENE N TO PROCEED ===
                r'\bscene\s*(\d+)\b',               # scene N
                r'scene[_\s]*[#\d]*\s*(\d+)'        # legacy flexible matcher
            ]
            text = prompt_text.lower()
            for pat in patterns:
                m = re.search(pat, text)
                if m:
                    try:
                        return int(m.group(1))
                    except Exception:
                        continue
        return default_number

    def paste_text_all_at_once(self, driver, chat_input, text, fast_mode=False):
        """Paste entire text into a textarea in one action using JS, then dispatch input/change events.
        
        Args:
            fast_mode: If True, skip the progress log to reduce overhead
        """
        try:
            driver.execute_script(
                """
                const el = arguments[0];
                const value = arguments[1];
                el.focus();
                // Set value in one go
                el.value = value;
                // Dispatch events so frameworks detect the change
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return el.value.length;
                """,
                chat_input, text
            )
            if not fast_mode:
                self.add_progress_log(f"📝 Prompt pasted in a single action ({len(text)} chars)")
            return True
        except Exception as e:
            # Fallback to send_keys if JS fails
            try:
                chat_input.clear()
                chat_input.send_keys(text)
                if not fast_mode:
                    self.add_progress_log(f"📝 Prompt pasted via fallback send_keys ({len(text)} chars)")
                return True
            except Exception as e2:
                if not fast_mode:
                    self.add_progress_log(f"❌ Failed to paste prompt: {str(e2)[:50]}")
                return False

    def wait_for_insert_assets_accessible(self, driver, wait, timeout=180, interval=5):
        """Wait until the file upload UI is accessible using the new menu workflow.
        Clicks: note_add icon -> "Upload a file" button to make file input accessible
        Does NOT trigger the file picker dialog - files will be set directly via send_keys
        Returns True if successful, False otherwise.
        """
        start = time.time()
        last_log = -1
        
        while (time.time() - start) < timeout:
            try:
                # Execute JavaScript to open menu and make file input accessible
                result = driver.execute_script("""
                    (function(){
                      function click(el){
                        if(!el) return;
                        el.dispatchEvent(new MouseEvent("mousedown",{bubbles:true}));
                        el.dispatchEvent(new MouseEvent("mouseup",{bubbles:true}));
                        el.dispatchEvent(new MouseEvent("click",{bubbles:true}));
                      }

                      // 1. Click the note_add icon (opens menu)
                      const addBtn = document.evaluate(
                        "//span[text()='note_add']",
                        document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null
                      ).singleNodeValue;

                      if(addBtn){
                        console.log("Clicking note_add");
                        click(addBtn);
                        return 'note_add_clicked';
                      } else {
                        console.log("note_add not found");
                        return 'note_add_not_found';
                      }
                    })();
                """)
                
                if result == 'note_add_clicked':
                    self.add_progress_log("✅ Clicked note_add icon, waiting for menu...")
                    time.sleep(0.5)  # Wait for menu to open
                    
                    # Click "Upload a file" button to make file input accessible
                    upload_result = driver.execute_script("""
                        (function(){
                          function click(el){
                            if(!el) return;
                            el.dispatchEvent(new MouseEvent("mousedown",{bubbles:true}));
                            el.dispatchEvent(new MouseEvent("mouseup",{bubbles:true}));
                            el.dispatchEvent(new MouseEvent("click",{bubbles:true}));
                          }

                          const uploadSpan = document.evaluate(
                            "//span[normalize-space(text())='Upload a file']",
                            document,
                            null,
                            XPathResult.FIRST_ORDERED_NODE_TYPE,
                            null
                          ).singleNodeValue;

                          if(uploadSpan){
                            console.log("Found Upload a file span — clicking parent button");
                            const btn = uploadSpan.closest("button");
                            click(btn);
                            return 'upload_clicked';
                          } else {
                            console.log("Upload a file span not found");
                            return 'upload_not_found';
                          }
                        })();
                    """)
                    
                    if upload_result == 'upload_clicked':
                        self.add_progress_log("✅ Clicked 'Upload a file' button, file input now accessible")
                        time.sleep(0.3)  # Brief wait for file input to appear
                        
                        # Verify file input is now accessible (but don't click it)
                        input_exists = driver.execute_script("""
                            const input = document.querySelector("input[data-test-upload-file-input]");
                            return input !== null;
                        """)
                        
                        if input_exists:
                            self.add_progress_log("✅ File input is accessible, ready for direct file import!")
                            return True
                        else:
                            self.add_progress_log("⚠️ File input not found after clicking upload button")
                    else:
                        self.add_progress_log("⚠️ 'Upload a file' button not found in menu")
                else:
                    # note_add icon not found, keep waiting
                    pass
                    
            except Exception as e:
                self.add_progress_log(f"⚠️ Error making file input accessible: {str(e)[:50]}")
            
            elapsed = int(time.time() - start)
            if elapsed // interval != last_log // interval:
                self.add_progress_log(f"⏳ File upload UI not ready yet. Waiting {interval}s and retrying... (elapsed {elapsed}s)")
                last_log = elapsed
            time.sleep(interval)
        
        self.add_progress_log(f"⚠️ File upload UI not accessible after {timeout}s")
        return False
    
    # ---------- CDP Image Generation Methods ----------
    def open_cdp_output_folder(self):
        """Open the CDP generated images output folder"""
        try:
            os.makedirs(self.cdp_output_folder, exist_ok=True)
            if os.name == "nt":
                os.startfile(self.cdp_output_folder)
            elif os.name == "posix":
                os.system(f'xdg-open "{self.cdp_output_folder}"')
            else:
                import webbrowser
                webbrowser.open(f"file://{self.cdp_output_folder}")
        except Exception as e:
            self.add_progress_log(f"❌ Failed to open output folder: {str(e)[:50]}")
    
    def get_profile_port(self, profile_index):
        """Get the debug port for a profile (0-indexed)"""
        return self.cdp_base_port + profile_index
    
    def open_all_chrome_profiles(self):
        """Open multiple Chrome profiles with different debug ports"""
        # Show progress log first
        if not self.show_progress.get():
            self.show_progress.set(True)
            self.toggle_progress_log()
        
        self.add_progress_log("=" * 60)
        self.add_progress_log("🌐 Opening Chrome Profiles...")
        
        # Get number of profiles to open
        try:
            num_profiles = max(1, int(self.cdp_profiles_var.get().strip()))
        except ValueError:
            num_profiles = 3
        
        self.add_progress_log(f"📋 Opening {num_profiles} profiles...")
        
        # Find Chrome executable (same as Open Chrome button)
        chrome_paths = [
            r"C:\Program Files\Google\Chrome\Application\chrome.exe",
            r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
            os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
        ]
        chrome_exe = None
        for path in chrome_paths:
            if os.path.exists(path):
                chrome_exe = path
                break
        
        if not chrome_exe:
            self.add_progress_log("❌ Chrome not found!")
            messagebox.showerror(APP_TITLE, "Chrome executable not found.\n\nPlease install Google Chrome.")
            return
        
        self.add_progress_log(f"✅ Chrome found")
        
        # AI Studio App URL
        target_url = "https://aistudio.google.com/apps/drive/10_Qs0vkJbQIOSKW-rwZOBlC-9lmYJjHo?showPreview=true&showAssistant=true"
        
        launched = 0
        for idx in range(num_profiles):
            port = self.get_profile_port(idx)
            profile_name = f"Profile {idx + 1}"
            user_data_dir = os.path.join(os.getcwd(), profile_name, "User Data")
            os.makedirs(user_data_dir, exist_ok=True)
            
            self.add_progress_log(f"  {profile_name} -> Port {port}")
            
            cmd = [
                chrome_exe,
                f"--remote-debugging-port={port}",
                f"--user-data-dir={user_data_dir}",
                "--no-first-run",
                "--no-default-browser-check",
                "--window-size=450,350", # Request small size initially
                # Anti-throttling flags for background stability
                "--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding",
                "--disable-features=CalculateNativeWinOcclusion",
                target_url
            ]
            
            try:
                proc = subprocess.Popen(cmd, shell=False)
                self.add_progress_log(f"    ✅ Launched (PID: {proc.pid})")
                launched += 1
                
                # Force OS-level resize after short delay using specific PID
                self.after(2000, lambda pid=proc.pid, i=idx: self.force_window_resize_os(pid, i))
            except Exception as e:
                self.add_progress_log(f"    ❌ Failed: {e}")
            
            # Reduced delay to 2.5s - PID resize handles focus stealing now
            time.sleep(2.5)  
        
        self.add_progress_log("=" * 60)
        if launched > 0:
            self.add_progress_log(f"✅ Launched {launched} Chrome instances!")
            self.add_progress_log("⏳ Auto-connecting in background...")
            self.after(0, lambda: self.cdp_status_var.set(f"● {launched} Launched"))
            self.after(0, lambda: self.cdp_status_label.config(foreground="orange"))
            
            # Start auto-connect in background (uses existing connect_all_browsers logic)
            # Give Chrome 3 seconds to start before first connection attempt
            self.after(3000, self.connect_all_browsers)
        else:
            self.add_progress_log("❌ No profiles were launched!")
            
    def force_window_resize_os(self, pid, idx):
        """Force resize specific process window using PowerShell and User32.dll"""
        try:
            # Grid calc (Strict non-overlapping)
            # 3 windows per row to fit safely on 1080p width
            cols = 3 
            row = idx // cols
            col = idx % cols
            
            w, h = 450, 400
            x = col * w
            y = row * h
            
            # PowerShell script to resize SPECIFIC PID window
            # We use MainWindowHandle of the specific process ID
            ps_script = f"""
            Add-Type @"
                using System;
                using System.Runtime.InteropServices;
                public class Win32 {{
                    [DllImport("user32.dll")]
                    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
                }}
            "@
            
            $p = Get-Process -Id {pid} -ErrorAction SilentlyContinue
            if ($p) {{
                # Wait for window handle if needed
                if ($p.MainWindowHandle -eq 0) {{ Start-Sleep -Seconds 1; $p.Refresh(); }}
                if ($p.MainWindowHandle -ne 0) {{
                    [Win32]::MoveWindow($p.MainWindowHandle, {x}, {y}, {w}, {h}, $true)
                }}
            }}
            """
            subprocess.run(["powershell", "-Command", ps_script], capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
        except: pass

    def connect_all_browsers(self):
        """Connect to all open Chrome browsers with debug ports"""
        if not cdp_available:
            messagebox.showerror(APP_TITLE, "Required dependencies not available.\n\nPlease install:\npip install asyncio websockets aiohttp")
            return
        
        # Get number of profiles to connect
        try:
            num_profiles = max(1, int(self.cdp_profiles_var.get().strip()))
        except ValueError:
            num_profiles = 3
        
        def connect_async():
            self.add_progress_log(f"🔗 Connecting to {num_profiles} browsers (60s timeout)...")
            self.after(0, lambda: self.cdp_status_var.set("● Connecting..."))
            self.after(0, lambda: self.cdp_status_label.config(foreground="orange"))
            
            # Create new event loop for this thread
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            
            connected = 0
            self.cdp_hubs.clear()
            
            async def connect_single(idx):
                nonlocal connected
                port = self.get_profile_port(idx)
                profile_name = f"Profile {idx + 1}"
                
                # Retry loop (up to 60s) for THIS browser
                start_time = time.time()
                hub_connected = False
                
                while (time.time() - start_time) < 60:
                    try:
                        hub = GeminiHubWithPort(port)
                        await hub.connect()
                        self.cdp_hubs[profile_name] = (port, hub)
                        connected += 1
                        self.add_progress_log(f"  ✅ {profile_name} (port {port})")
                        hub_connected = True
                        break
                    except:
                        await asyncio.sleep(2) # Wait 2s between retries
                
                if not hub_connected:
                    self.add_progress_log(f"  ❌ {profile_name} (port {port}): Timeout")

            # Run all connection tasks in parallel
            tasks = [connect_single(i) for i in range(num_profiles)]
            loop.run_until_complete(asyncio.gather(*tasks))
            
            if connected > 0:
                self.add_progress_log(f"✅ Connected to {connected}/{num_profiles} browsers!")
                self.after(0, lambda c=connected: self.cdp_status_var.set(f"● {c} Ready"))
                self.after(0, lambda: self.cdp_status_label.config(foreground="green"))
            else:
                self.add_progress_log("❌ No browsers connected. Make sure Chrome is running with AI Studio loaded.")
                self.after(0, lambda: self.cdp_status_var.set("● 0 Browsers"))
                self.after(0, lambda: self.cdp_status_label.config(foreground="red"))
        
        threading.Thread(target=connect_async, daemon=True).start()
    
    def update_browser_status(self):
        """Update the browser connection status display"""
        connected = len(self.cdp_hubs)
        if connected > 0:
            self.cdp_status_var.set(f"● {connected} Ready")
            self.cdp_status_label.config(foreground="green")
        else:
            self.cdp_status_var.set("● 0 Browsers")
            self.cdp_status_label.config(foreground="gray")
    
    def start_cdp_image_generation(self):
        """Start or stop fast image generation for the selected range"""
        if self.cdp_running:
            # Stop the generation
            self.cdp_running = False
            self.add_progress_log("🛑 Stopping generation...")
            self.cdp_gen_btn.config(text="⚡ Generate Range")
            return
            
        if not cdp_available:
            messagebox.showerror(APP_TITLE, "Required dependencies not available.\n\nPlease install:\npip install asyncio websockets aiohttp")
            return
        
        # Validate range
        try:
            from_num = int(self.from_prompt_var.get().strip())
            to_num = int(self.to_prompt_var.get().strip())
        except ValueError:
            messagebox.showerror(APP_TITLE, "Please enter valid numbers for the range.")
            return
        
        if from_num > to_num:
            messagebox.showerror(APP_TITLE, "'From' number must be less than or equal to 'To' number.")
            return
        
        # Check scenes availability
        scenes = self.data.get("output_structure", {}).get("scenes", [])
        if not scenes:
            messagebox.showerror(APP_TITLE, "No scenes loaded. Please load a JSON file first.")
            return
        
        available_scenes = [s.get("scene_number", i+1) for i, s in enumerate(scenes)]
        valid_scenes = [num for num in range(from_num, to_num + 1) if num in available_scenes]
        
        if not valid_scenes:
            messagebox.showerror(APP_TITLE, f"No valid scenes found in range {from_num}-{to_num}.")
            return
        
        # Check for connected browsers
        if not self.cdp_hubs:
            messagebox.showerror(APP_TITLE, "No browsers connected!\n\nClick 'Open All' to launch Chrome profiles,\nthen 'Connect All' to establish connections.")
            return
        
        # Get batch size and retry count
        try:
            batch_size = min(5, max(1, int(self.cdp_batch_size_var.get().strip())))
        except ValueError:
            batch_size = 3
            
        try:
            retry_count = max(0, int(self.cdp_retry_var.get().strip()))
        except ValueError:
            retry_count = 1
        
        try:
            request_delay = max(0.5, float(self.cdp_delay_var.get().strip()))
        except ValueError:
            request_delay = 1.0
        
        aspect_ratio = self.cdp_aspect_var.get()
        
        self.cdp_running = True
        self.cdp_gen_btn.config(text="🛑 Stop", state="normal")
        
        # Show progress log
        if not self.show_progress.get():
            self.show_progress.set(True)
            self.toggle_progress_log()
        
        num_browsers = len(self.cdp_hubs)
        self.add_progress_log("=" * 60)
        self.add_progress_log("🚀 Fast Image Generation Started")
        self.add_progress_log(f"🌐 Browsers: {num_browsers} active")
        self.add_progress_log(f"📊 Scenes: {valid_scenes}")
        self.add_progress_log(f"🖼️ Batch Size: {batch_size} per browser ({request_delay}s delay)")
        self.add_progress_log(f"🔄 Retries: {retry_count} (10s interval)")
        self.add_progress_log(f"📐 Aspect Ratio: {aspect_ratio}")
        self.add_progress_log(f"📁 Output: {self.cdp_output_folder}")
        self.add_progress_log("=" * 60)
        
        # Start processing in background thread
        threading.Thread(
            target=self.run_cdp_image_generation,
            args=(valid_scenes, batch_size, retry_count, aspect_ratio, request_delay),
            daemon=True
        ).start()
    
    def run_cdp_image_generation(self, scene_numbers, batch_size, retry_count, aspect_ratio, request_delay=1.0):
        """Run fast image generation with parallel batching and browser rotation"""
        try:
            # Create a localized event loop for this generation session
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            
            # Use already established connections from cdp_hubs
            # NOTE: We reconnect internally here because WebSockets are loop-bound
            # but we skip the 'focus' and 'open' steps as they are already done.
            active_hubs = []
            for profile_name, (port, _) in self.cdp_hubs.items():
                try:
                    hub = GeminiHubWithPort(port)
                    # Fast connect (already focused/open)
                    loop.run_until_complete(hub.connect())
                    active_hubs.append((profile_name, port, hub))
                except:
                    continue
            
            if not active_hubs:
                self.add_progress_log("❌ No browsers connected! Please click 'Open' and wait for 'Ready' status.")
                self.cdp_running = False
                self.after(0, lambda: self.cdp_gen_btn.config(text="⚡ Generate Range"))
                return
            
            self.add_progress_log(f"🌐 Using {len(active_hubs)} connected browsers")
            
            # Prepare prompts from scenes
            scene_prompts = []
            for scene_num in scene_numbers:
                scene_data = self.get_scene_data(scene_num)
                if scene_data:
                    prompt_text, present_chars = scene_data
                    ref_images_list = []
                    if present_chars:
                        for char_id in present_chars:
                            char_data = next((c for c in self.characters if c["id"] == char_id), None)
                            if char_data:
                                char_images = [img for img in char_data.get("images", []) if os.path.exists(img)]
                                for img_path in char_images:
                                    try:
                                        with open(img_path, "rb") as f:
                                            img_b64 = base64.b64encode(f.read()).decode('utf-8')
                                            ref_images_list.append(img_b64)
                                    except: pass
                    scene_prompts.append((scene_num, prompt_text, ref_images_list))
            
            if not scene_prompts:
                self.add_progress_log("❌ No valid prompts to generate")
                self.cdp_running = False
                return

            self.add_progress_log(f"📝 Prepared {len(scene_prompts)} prompts")
            successful = 0
            failed = 0
            
            # Parallel batch processing logic
            async def process_batch_async(batch_prompts):
                """Process a chunk of prompts in parallel across all browsers"""
                # batch_prompts is a list of (scene_num, prompt, ref_imgs)
                results_map = {} # scene_num -> result
                pending_tasks = [] # list of (scene_num, hub, t_id, browser_name)
                
                # Determine model
                if self.selected_image_model is None:
                    model_id_js = "window.geminiHub.models.GEMINI_2_5_FLASH_IMAGE"
                    model_name = "Gemini 2.5 Flash Image"
                else:
                    model_id_js = "window.geminiHub.models.IMAGEN_4"
                    model_name = "Imagen 4"

                # 0. Ensure all browsers are active and iframes focused
                unique_hubs = {h for _, _, h in active_hubs}
                for h in unique_hubs:
                    await h.focus_iframe() 
                    await h._cmd("Page.bringToFront")
                
                # 1. Distribute and Spawn all tasks in the batch
                hub_iterator = 0
                for scene_num, prompt, ref_imgs in batch_prompts:
                    if not self.cdp_running: break
                    
                    # Round-robin selection of hub
                    browser_name, port, hub = active_hubs[hub_iterator % len(active_hubs)]
                    hub_iterator += 1
                    
                    try:
                        spawn_code = f"window.geminiHub.spawnImage({json.dumps(prompt)}, {json.dumps(aspect_ratio)}, {json.dumps(ref_imgs) if ref_imgs else 'undefined'}, {model_id_js})"
                        t_id = await hub._eval(spawn_code, timeout=15)
                        
                        if isinstance(t_id, str) and t_id and "error" not in t_id.lower():
                            pending_tasks.append({
                                "scene_num": scene_num,
                                "hub": hub,
                                "t_id": t_id,
                                "browser": browser_name
                            })
                            self.add_progress_log(f"  • [{browser_name}] Spawned Scene {scene_num} (ID: {t_id[:8]})")
                        else:
                            self.add_progress_log(f"  ❌ [{browser_name}] Failed to spawn Scene {scene_num}: {t_id}")
                            results_map[scene_num] = {"status": "FAILED", "error": str(t_id)}
                    except Exception as e:
                        results_map[scene_num] = {"status": "FAILED", "error": str(e)}
                
                if not pending_tasks: return results_map

                # 2. Wait for processing (spec says 3s)
                await asyncio.sleep(3)
                
                # 3. Check modals for all involved hubs
                unique_hubs = {t["hub"] for t in pending_tasks}
                for h in unique_hubs:
                    await h._check_modal_blocking()
                
                # 4. Polling for results of all pending tasks (Instant status checks)
                self.add_progress_log(f"  🔄 Polling {len(pending_tasks)} parallel tasks...")
                
                start_poll = time.time()
                while pending_tasks and (time.time() - start_poll < 180): # 3 min max
                    if not self.cdp_running: break
                    
                    still_pending = []
                    for task in pending_tasks:
                        try:
                            # Instant status check (no waitFor here to avoid blocking)
                            check_code = f"""(() => {{
                                try {{
                                    const t = window.geminiHub.getThread('{task['t_id']}');
                                    if (!t) return {{ status: 'NOT_FOUND' }};
                                    return {{ 
                                        status: t.status, 
                                        error: t.error || null,
                                        result: t.status === 'COMPLETED' ? t.result : null 
                                    }};
                                }} catch(e) {{ return {{ status: 'ERROR', error: e.message }}; }}
                            }})()"""
                            
                            # Increased timeout to 30s to prevent early failures on slow responses
                            res = await task["hub"]._eval(check_code, timeout=30)
                            
                            if isinstance(res, dict):
                                status = res.get("status")
                                if status == "COMPLETED" and res.get("result"):
                                    results_map[task["scene_num"]] = {"status": "COMPLETED", "result": res["result"]}
                                    self.add_progress_log(f"  ✓ Scene {task['scene_num']} completed on {task['browser']}")
                                elif status == "FAILED":
                                    error = res.get("error") or "Unknown AI Studio Error"
                                    # Check for quota
                                    if any(x in str(error).lower() for x in ["429", "quota", "rate"]):
                                        self.add_progress_log(f"  ⚠️ [{task['browser']}] Quota hit on Scene {task['scene_num']}")
                                    else:
                                        self.add_progress_log(f"  ❌ Scene {task['scene_num']} failed: {str(error)[:40]}")
                                    results_map[task["scene_num"]] = {"status": "FAILED", "error": error}
                                elif status == "NOT_FOUND":
                                    results_map[task["scene_num"]] = {"status": "FAILED", "error": "Task not found in browser"}
                                    self.add_progress_log(f"  ❌ Scene {task['scene_num']} lost focus")
                                else:
                                    # Still processing (PENDING/RUNNING)
                                    still_pending.append(task)
                            elif isinstance(res, str) and "timeout" in res.lower():
                                # This is a network timeout for the check itself, just keep pending
                                still_pending.append(task)
                            else:
                                still_pending.append(task)
                        except Exception as e:
                            # Check if connection died
                            if "closed" in str(e).lower() or "timeout" in str(e).lower():
                                self.add_progress_log(f"  ⚠️ [{task['browser']}] Connection lost on Scene {task['scene_num']}")
                                results_map[task["scene_num"]] = {"status": "FAILED", "error": "Connection closed"}
                            else:
                                # Network stutter, try again in next loop
                                still_pending.append(task)
                    
                    pending_tasks = still_pending
                    if pending_tasks:
                        await asyncio.sleep(2)
                
                # Any remaining are timeouts
                for task in pending_tasks:
                    results_map[task["scene_num"]] = {"status": "TIMEOUT", "error": "Polling timed out"}
                
                return results_map

            # Main Batch Execution Loop with Queue-based Retries
            from collections import deque
            queue = deque([(s, p, r) for s, p, r in scene_prompts])
            retry_tracker = {s: 0 for s, p, r in scene_prompts}
            total_batch_size = batch_size * len(active_hubs)
            
            self.add_progress_log(f"🎯 Total Concurrency: {batch_size} per browser × {len(active_hubs)} = {total_batch_size}")
            
            batch_count = 1
            while queue and self.cdp_running:
                # Fill the current batch from the queue
                current_batch = []
                for _ in range(total_batch_size):
                    if queue:
                        current_batch.append(queue.popleft())
                
                if not current_batch: break
                
                self.add_progress_log(f"\n📦 Processing batch {batch_count} ({len(current_batch)} images)...")
                batch_count += 1
                
                try:
                    batch_results = loop.run_until_complete(process_batch_async(current_batch))
                except Exception as e:
                    import traceback
                    self.add_progress_log(f"⚠️ Batch Error: {str(e)[:100]}")
                    # Push everything back to queue
                    for item in current_batch:
                        queue.append(item)
                    self.add_progress_log(f"  🔄 Re-queued {len(current_batch)} items from failed batch.")
                    time.sleep(5)
                    continue
                
                # Save results and handle retries
                for scene_num, res in batch_results.items():
                    # Find original data for this scene_num to allow re-queueing
                    original_item = next((item for item in scene_prompts if item[0] == scene_num), None)
                    
                    if res.get("status") == "COMPLETED" and res.get("result"):
                        saved_path = self.save_cdp_image(res["result"], scene_num)
                        if saved_path:
                            successful += 1
                        else: 
                            failed += 1
                    else:
                        # Logic for re-queueing failed items
                        if retry_tracker[scene_num] < retry_count:
                            retry_tracker[scene_num] += 1
                            self.add_progress_log(f"  🔄 Scene {scene_num} failed/timed out. Re-queuing (Retry {retry_tracker[scene_num]}/{retry_count})")
                            queue.append(original_item)
                        else:
                            self.add_progress_log(f"  ❌ Scene {scene_num} failed after {retry_count} retries.")
                            failed += 1
            
            # Final summary
            self.add_progress_log("\n" + "=" * 60)
            self.add_progress_log(f"🏁 Generation Finished!")
            self.add_progress_log(f"✅ Successful: {successful}")
            self.add_progress_log(f"❌ Failed: {failed}")
            self.add_progress_log(f"📁 Images saved to: {self.cdp_output_folder}")
            self.add_progress_log("=" * 60)
            
        except Exception as e:
            self.add_progress_log(f"💥 Generation error: {str(e)[:100]}")
            import traceback
            self.add_progress_log(f"💥 Traceback: {traceback.format_exc()[:200]}")
        finally:
            self.cdp_running = False
            self.after(0, lambda: self.cdp_gen_btn.config(text="⚡ Generate Range", state="normal"))
    
    def save_cdp_image(self, base64_data, scene_num):
        """Save base64 image data to file"""
        try:
            # Create output folder if needed
            os.makedirs(self.cdp_output_folder, exist_ok=True)
            
            # Generate filename with timestamp
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"scene_{scene_num}_{timestamp}.png"
            filepath = os.path.join(self.cdp_output_folder, filename)
            
            # Extract base64 data
            if "," in base64_data:
                b64_part = base64_data.split(",", 1)[1]
            else:
                b64_part = base64_data
            
            # Decode and save
            image_bytes = base64.b64decode(b64_part)
            with open(filepath, "wb") as f:
                f.write(image_bytes)
            
            return filepath
            
        except Exception as e:
            self.add_progress_log(f"💥 Save error: {str(e)[:50]}")
            return None
    
    def register_webdriver_for_tracking(self, driver, driver_id="batch_driver"):
        """Register a WebDriver instance for tracking"""
        try:
            self.active_webdrivers[driver_id] = {
                'driver': driver,
                'created_at': time.time(),
                'active': True
            }
            
            # Update tab tracking when a new driver is registered
            self.webdriver_tabs[driver_id] = {
                'handles': driver.window_handles if driver else [],
                'last_updated': time.time()
            }
            
            # Update UI after registration
            self.after(0, self.refresh_webdriver_status)
            
        except Exception as e:
            self.add_progress_log(f"⚠️ Error registering WebDriver: {str(e)[:50]}")

    def on_closing(self):
        """Clean up and close app"""
        # Close standard WebDrivers if any
        if hasattr(self, 'active_webdrivers'):
            for driver_id, info in self.active_webdrivers.items():
                try:
                    info['driver'].quit()
                except: pass
        
        # Destroy app
        self.destroy()

# ---------- Run ----------
if __name__=="__main__":
    # MAC address authentication check
    if not verify_mac_access():
        print("Access denied. Your MAC address is not whitelisted.")
        messagebox.showerror("Access Denied", "Your MAC address is not authorized to use this application.")
        sys.exit(1)
    
    app = CharacterStudioApp()
    app.mainloop()
