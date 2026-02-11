import flet as ft
import asyncio
import base64
import os
from datetime import datetime
from gemini_hub import GeminiHub


def save_image_to_file(base64_data: str, folder: str = "images", prefix: str = "img") -> str:
    """Save base64 image data to a file and return the path"""
    # Create folder if not exists
    if not os.path.exists(folder):
        os.makedirs(folder)
    
    # Generate filename with timestamp
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:20]
    filename = f"{prefix}_{timestamp}.png"
    filepath = os.path.join(folder, filename)
    
    # Decode and save
    try:
        if "," in base64_data:
            b64_part = base64_data.split(",", 1)[1]
        else:
            b64_part = base64_data
        
        image_bytes = base64.b64decode(b64_part)
        with open(filepath, "wb") as f:
            f.write(image_bytes)
        
        print(f"[SAVE] Saved image to: {filepath}")
        return filepath
    except Exception as e:
        print(f"[SAVE] Error saving image: {e}")
        return None


class GeminiApp:
    def __init__(self):
        self.hub = None
        self.is_connected = False
        self.is_image_mode = False
        self.is_batch_mode = False
        self.reference_images = []
        
    async def main(self, page: ft.Page):
        page.title = "Gemini Hub"
        page.theme_mode = ft.ThemeMode.LIGHT
        page.padding = 20
        page.window.width = 850
        page.window.height = 750
        
        # Status text (small, top right)
        self.status_text = ft.Text(
            "Connecting...",
            size=10,
            color="#666666",
        )
        
        # Reconnect button
        def on_reconnect(e):
            page.run_task(self.reconnect, page)
        
        self.reconnect_btn = ft.IconButton(
            icon="refresh",
            icon_size=16,
            tooltip="Reconnect",
            on_click=on_reconnect,
        )
        
        # Launch Chrome button
        def on_launch_chrome(e):
            import subprocess
            try:
                subprocess.Popen([
                    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                    "--remote-debugging-port=9222",
                    f"--user-data-dir={os.path.abspath('chrome_debug_profile')}",
                    "https://aistudio.google.com/apps/drive/10_Qs0vkJbQIOSKW-rwZOBlC-9lmYJjHo?showPreview=true&showAssistant=true&fullscreenApplet=true"
                ])
                # Restore auto-connect polling logic
                page.run_task(self.auto_connect, page)
            except Exception as ex:
                self.status_text.value = f"Launch failed: {str(ex)}"
                self.status_text.color = "#f44336"
                page.update()
        
        self.launch_chrome_btn = ft.IconButton(
            icon="open_in_browser",
            icon_size=16,
            tooltip="Launch Chrome",
            on_click=on_launch_chrome,
        )
        
        # Test Click Page button
        def on_test_click(e):
            page.run_task(self.test_click_page, page)
        
        self.test_click_btn = ft.IconButton(
            icon="ads_click",
            icon_size=16,
            tooltip="Test Click on Main Page",
            on_click=on_test_click,
            bgcolor="#ff5722",
        )
        
        # Test Hover Page button
        def on_test_hover(e):
            page.run_task(self.test_hover_page, page)
        
        self.test_hover_btn = ft.IconButton(
            icon="gesture",
            icon_size=16,
            tooltip="Test Hover on Main Page (2s)",
            on_click=on_test_hover,
            bgcolor="#9c27b0",
        )
        
        # Mode toggle buttons
        def toggle_text_mode(e):
            self.is_image_mode = False
            self.is_batch_mode = False
            self.text_btn.bgcolor = "#2196F3"
            self.text_btn.color = "#ffffff"
            self.image_btn.bgcolor = "#e0e0e0"
            self.image_btn.color = "#000000"
            self.batch_btn.bgcolor = "#e0e0e0"
            self.batch_btn.color = "#000000"
            self.model_dropdown.visible = True
            self.aspect_dropdown.visible = False
            self.schema_checkbox.visible = True
            self.schema_template_dropdown.visible = self.schema_checkbox.value
            self.schema_field.visible = self.schema_checkbox.value
            self.upload_section.visible = False
            self.prompt_field.hint_text = "Enter your prompt..."
            self.prompt_field.min_lines = 2
            self.prompt_field.max_lines = 4
            self.image_grid_container.visible = False
            page.update()
        
        def toggle_image_mode(e):
            self.is_image_mode = True
            self.is_batch_mode = False
            self.text_btn.bgcolor = "#e0e0e0"
            self.text_btn.color = "#000000"
            self.image_btn.bgcolor = "#2196F3"
            self.image_btn.color = "#ffffff"
            self.batch_btn.bgcolor = "#e0e0e0"
            self.batch_btn.color = "#000000"
            self.model_dropdown.visible = False
            self.aspect_dropdown.visible = True
            self.schema_checkbox.visible = False
            self.schema_template_dropdown.visible = False
            self.schema_field.visible = False
            self.upload_section.visible = True
            self.prompt_field.hint_text = "Describe the image or variation..."
            self.prompt_field.min_lines = 2
            self.prompt_field.max_lines = 4
            self.image_grid_container.visible = False
            page.update()
        
        def toggle_batch_mode(e):
            self.is_image_mode = True
            self.is_batch_mode = True
            self.text_btn.bgcolor = "#e0e0e0"
            self.text_btn.color = "#000000"
            self.image_btn.bgcolor = "#e0e0e0"
            self.image_btn.color = "#000000"
            self.batch_btn.bgcolor = "#9C27B0"
            self.batch_btn.color = "#ffffff"
            self.model_dropdown.visible = False
            self.aspect_dropdown.visible = True
            self.schema_checkbox.visible = False
            self.schema_template_dropdown.visible = False
            self.schema_field.visible = False
            self.upload_section.visible = False
            self.prompt_field.hint_text = "Enter up to 5 prompts (one per line)..."
            self.prompt_field.min_lines = 5
            self.prompt_field.max_lines = 8
            self.image_grid_container.visible = True
            page.update()
        
        self.text_btn = ft.ElevatedButton(
            "Text",
            on_click=toggle_text_mode,
            bgcolor="#2196F3",
            color="#ffffff",
        )
        
        self.image_btn = ft.ElevatedButton(
            "Image",
            on_click=toggle_image_mode,
            bgcolor="#e0e0e0",
            color="#000000",
        )
        
        self.batch_btn = ft.ElevatedButton(
            "Batch",
            on_click=toggle_batch_mode,
            bgcolor="#e0e0e0",
            color="#000000",
        )
        
        # Model dropdown for text
        self.model_dropdown = ft.Dropdown(
            options=[
                ft.dropdown.Option("flash3", "Flash 3"),
                ft.dropdown.Option("flash25", "Flash 2.5"),
                ft.dropdown.Option("pro3", "Pro 3"),
                ft.dropdown.Option("pro25", "Pro 2.5"),
                ft.dropdown.Option("run", "All Models"),
            ],
            value="flash3",
            width=150,
            text_size=13,
        )
        
        # Aspect ratio dropdown for images
        self.aspect_dropdown = ft.Dropdown(
            options=[
                ft.dropdown.Option("1:1", "Square"),
                ft.dropdown.Option("16:9", "Wide"),
                ft.dropdown.Option("9:16", "Tall"),
                ft.dropdown.Option("4:3", "Standard"),
            ],
            value="1:1",
            width=150,
            text_size=13,
            visible=False,
        )
        
        # Structured output checkbox and schema field
        # Define schema templates
        self.schema_templates = {
            "Simple Output": '{\n  "type": "object",\n  "properties": {\n    "output": { "type": "string" }\n  },\n  "required": ["output"]\n}',
            "List of Strings": '{\n  "type": "ARRAY",\n  "items": { "type": "STRING" }\n}',
            "Recipe": '{\n  "type": "OBJECT",\n  "properties": {\n    "recipe_name": {"type": "STRING"},\n    "difficulty": {"type": "STRING"},\n    "calories": {"type": "NUMBER"}\n  },\n  "required": ["recipe_name"]\n}',
            "Status Enum": '{\n  "type": "STRING",\n  "enum": ["PENDING", "SHIPPED", "DELIVERED"]\n}',
            "Story MasterPrompt 001": '{\n  "type": "OBJECT",\n  "properties": {\n    "character_reference": {\n      "type": "ARRAY",\n      "items": {\n        "type": "OBJECT",\n        "properties": {\n          "id": {"type": "STRING"},\n          "name": {"type": "STRING"},\n          "description": {"type": "STRING"}\n        },\n        "required": ["id", "name", "description"]\n      }\n    },\n    "output_structure": {\n      "type": "OBJECT",\n      "properties": {\n        "story_title": {"type": "STRING"},\n        "duration": {"type": "STRING"},\n        "total_scenes": {"type": "INTEGER"},\n        "style": {"type": "STRING"},\n        "characters": {\n          "type": "OBJECT",\n          "properties": {\n            "included_characters": {\n              "type": "ARRAY",\n              "items": {"type": "STRING"}\n            }\n          }\n        },\n        "scenes": {\n          "type": "ARRAY",\n          "items": {\n            "type": "OBJECT",\n            "properties": {\n              "scene_number": {"type": "INTEGER"},\n              "prompt": {"type": "STRING"},\n              "characters_in_scene": {\n                "type": "ARRAY",\n                "items": {"type": "STRING"}\n              },\n              "negative_prompt": {"type": "STRING"}\n            },\n            "required": ["scene_number", "prompt", "characters_in_scene"]\n          }\n        }\n      }\n    }\n  },\n  "required": ["character_reference", "output_structure"]\n}',
            "Custom": ""
        }
        
        def toggle_schema(e):
            self.schema_field.visible = self.schema_checkbox.value
            self.schema_template_dropdown.visible = self.schema_checkbox.value
            # Set default schema when enabled
            if self.schema_checkbox.value and not self.schema_field.value:
                self.schema_field.value = self.schema_templates["Simple Output"]
            page.update()
        
        def on_template_change(e):
            template_name = self.schema_template_dropdown.value
            if template_name and template_name != "Custom":
                self.schema_field.value = self.schema_templates[template_name]
                page.update()
        
        self.schema_checkbox = ft.Checkbox(
            label="Structured Output",
            value=False,
            on_change=toggle_schema,
        )
        
        self.schema_template_dropdown = ft.Dropdown(
            options=[ft.dropdown.Option(name) for name in self.schema_templates.keys()],
            value="Simple Output",
            width=250,
            text_size=11,
            visible=False,
            on_change=on_template_change,
        )
        
        self.schema_field = ft.TextField(
            value='{\n  "type": "object",\n  "properties": {\n    "output": { "type": "string" }\n  },\n  "required": ["output"]\n}',
            multiline=True,
            min_lines=3,
            max_lines=6,
            text_size=11,
            visible=False,
        )
        
        
        # File picker for reference images
        async def pick_files_result(e: ft.FilePickerResultEvent):
            if e.files:
                from PIL import Image
                import io
                
                for file in e.files:
                    # Read file and convert to base64
                    try:
                        # Open and resize image to reduce size
                        img = Image.open(file.path)
                        
                        # Resize if too large (max 800px on longest side)
                        max_size = 800
                        if max(img.size) > max_size:
                            ratio = max_size / max(img.size)
                            new_size = tuple(int(dim * ratio) for dim in img.size)
                            img = img.resize(new_size, Image.Resampling.LANCZOS)
                        
                        # Convert to RGB if needed
                        if img.mode in ('RGBA', 'LA', 'P'):
                            background = Image.new('RGB', img.size, (255, 255, 255))
                            if img.mode == 'P':
                                img = img.convert('RGBA')
                            background.paste(img, mask=img.split()[-1] if img.mode in ('RGBA', 'LA') else None)
                            img = background
                        
                        # Save as JPEG with compression
                        buffer = io.BytesIO()
                        img.save(buffer, format='JPEG', quality=85, optimize=True)
                        image_data = buffer.getvalue()
                        
                        b64_data = base64.b64encode(image_data).decode()
                        data_uri = f"data:image/jpeg;base64,{b64_data}"
                        
                        # Check size (limit to ~500KB base64)
                        if len(b64_data) > 700000:
                            # Further compress
                            buffer = io.BytesIO()
                            img.save(buffer, format='JPEG', quality=70, optimize=True)
                            image_data = buffer.getvalue()
                            b64_data = base64.b64encode(image_data).decode()
                            data_uri = f"data:image/jpeg;base64,{b64_data}"
                        
                        self.reference_images.append(data_uri)
                        
                        # Add thumbnail preview
                        thumb = ft.Image(
                            src_base64=b64_data,
                            width=60,
                            height=60,
                            fit=ft.ImageFit.COVER,
                            border_radius=5,
                        )
                        self.ref_thumbnails.controls.append(thumb)
                        
                        self.ref_count_text.value = f"{len(self.reference_images)} image(s)"
                        page.update()
                    except Exception as ex:
                        self.ref_count_text.value = f"Error: {str(ex)}"
                        page.update()
        
        file_picker = ft.FilePicker(on_result=pick_files_result)
        page.overlay.append(file_picker)
        
        def clear_refs(e):
            self.reference_images = []
            self.ref_thumbnails.controls.clear()
            self.ref_count_text.value = "No images"
            page.update()
        
        self.ref_count_text = ft.Text("No images", size=11, color="#666666")
        
        # Thumbnail container for reference images
        self.ref_thumbnails = ft.Row([], spacing=5, wrap=True)
        
        # Upload section
        self.upload_section = ft.Container(
            content=ft.Column([
                ft.Row(
                    [
                        ft.ElevatedButton(
                            "Upload Reference",
                            icon="upload_file",
                            on_click=lambda _: file_picker.pick_files(
                                allow_multiple=True,
                                allowed_extensions=["png", "jpg", "jpeg", "webp"]
                            ),
                        ),
                        ft.IconButton(
                            icon="delete",
                            icon_size=18,
                            tooltip="Clear all",
                            on_click=clear_refs,
                        ),
                        self.ref_count_text,
                    ],
                    spacing=10,
                ),
                self.ref_thumbnails,
            ]),
            visible=False,
        )
        
        # Prompt input with submit button
        def on_submit_wrapper(e):
            page.run_task(self.submit_prompt, page)
        
        self.submit_btn = ft.IconButton(
            icon="send",
            icon_size=20,
            on_click=on_submit_wrapper,
            tooltip="Submit",
        )
        
        self.prompt_field = ft.TextField(
            hint_text="Enter your prompt...",
            multiline=True,
            min_lines=2,
            max_lines=4,
            text_size=13,
            on_submit=on_submit_wrapper,
            suffix=self.submit_btn,
        )
        
        # Response area with scroll (for text)
        self.response_text = ft.Text(
            "Ready",
            size=12,
            selectable=True,
        )
        
        self.text_response = ft.Container(
            content=ft.Column(
                [self.response_text],
                scroll=ft.ScrollMode.AUTO,
            ),
            border=ft.border.all(1, "#e0e0e0"),
            border_radius=5,
            padding=10,
            expand=True,
        )
        
        # Image preview area
        self.image_preview = ft.Image(
            fit=ft.ImageFit.CONTAIN,
        )
        
        self.image_container = ft.Container(
            content=self.image_preview,
            border=ft.border.all(1, "#e0e0e0"),
            border_radius=5,
            padding=10,
            expand=True,
            visible=False,
        )
        
        # Image grid for batch mode (5 images)
        self.image_grid = ft.Row([], spacing=10, wrap=True)
        self.image_grid_container = ft.Container(
            content=ft.Column([
                ft.Text("Batch Results:", size=11, weight=ft.FontWeight.W_500),
                self.image_grid,
            ]),
            border=ft.border.all(1, "#e0e0e0"),
            border_radius=5,
            padding=10,
            visible=False,
        )
        
        # Layout
        page.add(
            ft.Column(
                [
                    # Top bar: Mode buttons + Status + Test buttons + Launch Chrome + Reconnect
                    ft.Row(
                        [
                            ft.Row([self.text_btn, self.image_btn, self.batch_btn], spacing=5),
                            ft.Container(expand=True),
                            self.status_text,
                            self.test_click_btn,
                            self.test_hover_btn,
                            self.launch_chrome_btn,
                            self.reconnect_btn,
                        ],
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    ),
                    
                    # Model/Aspect selector
                    ft.Row([self.model_dropdown, self.aspect_dropdown]),
                    
                    # Structured output (for text mode)
                    self.schema_checkbox,
                    self.schema_template_dropdown,
                    self.schema_field,
                    
                    # Upload section (for image mode)
                    self.upload_section,
                    
                    # Prompt
                    self.prompt_field,
                    
                    # Response label
                    ft.Text("Response:", size=11, weight=ft.FontWeight.W_500),
                    
                    # Response areas
                    self.text_response,
                    self.image_container,
                    self.image_grid_container,
                ],
                spacing=10,
                expand=True,
            )
        )
        
        # Auto-connect
        await self.auto_connect(page)
    
    async def auto_connect(self, page: ft.Page):
        """Automatically connect to Chrome with 60s timeout polling"""
        self.status_text.value = "● Searching for Chrome..."
        self.status_text.color = "#FF9800"
        page.update()

        start_time = asyncio.get_event_loop().time()
        max_wait = 60 # seconds
        
        while (asyncio.get_event_loop().time() - start_time) < max_wait:
            try:
                if not self.hub:
                    self.hub = GeminiHub()
                
                await self.hub.connect()
                
                self.is_connected = True
                self.status_text.value = "● Connected"
                self.status_text.color = "#4caf50"
                self.response_text.value = "Ready"
                page.update()
                return # Success!
                
            except Exception:
                # Still waiting for Chrome to start or protocol to be ready
                remaining = int(max_wait - (asyncio.get_event_loop().time() - start_time))
                self.status_text.value = f"● Waiting for Chrome ({remaining}s)..."
                page.update()
                await asyncio.sleep(2)
        
        # If we get here, it timed out
        self.is_connected = False
        self.status_text.value = "● Chrome Not Found"
        self.status_text.color = "#f44336"
        self.response_text.value = "Connection failed. Please ensure Chrome is launched with --remote-debugging-port=9222"
        page.update()
    
    async def reconnect(self, page: ft.Page):
        """Reconnect to Chrome"""
        self.status_text.value = "Reconnecting..."
        self.status_text.color = "#ff9800"
        self.is_connected = False
        page.update()
        
        # Close existing connection if any
        if self.hub:
            try:
                await self.hub.close()
            except:
                pass
            self.hub = None
        
        # Wait a moment
        import asyncio
        await asyncio.sleep(1)
        
        # Reconnect
        await self.auto_connect(page)
    
    async def test_iframe_activation(self, page: ft.Page):
        """Manually test iframe activation"""
        if not self.is_connected:
            self.status_text.value = "Not connected"
            self.status_text.color = "#f44336"
            page.update()
            return
        
        self.status_text.value = "Testing iframe click..."
        self.status_text.color = "#ff9800"
        page.update()
        
        try:
            # Click iframe
            result = await self.hub.click_iframe_to_activate()
            
            if result and "clicked" in str(result).lower():
                self.status_text.value = f"✓ {result}"
                self.status_text.color = "#4caf50"
            else:
                self.status_text.value = f"⚠ {result}"
                self.status_text.color = "#ff9800"
                
                # Try focus as fallback
                focus_result = await self.hub.focus_iframe()
                if focus_result:
                    self.status_text.value = f"✓ {focus_result}"
                    self.status_text.color = "#4caf50"
        except Exception as e:
            self.status_text.value = f"Failed: {str(e)}"
            self.status_text.color = "#f44336"
        
        page.update()
    
    async def click_iframe_manual(self, page: ft.Page):
        """Click iframe by trying all CDP targets"""
        self.status_text.value = "Clicking iframe (all targets)..."
        self.status_text.color = "#ff9800"
        page.update()
        
        try:
            result = await self.hub.click_iframe_all_targets()
            
            if "clicked successfully" in str(result).lower():
                self.status_text.value = f"✓ {result}"
                self.status_text.color = "#4caf50"
            elif "not found" in str(result).lower():
                self.status_text.value = f"⚠ {result}"
                self.status_text.color = "#ff9800"
            else:
                self.status_text.value = f"{result}"
                self.status_text.color = "#2196F3"
        except Exception as e:
            self.status_text.value = f"Error: {str(e)}"
            self.status_text.color = "#f44336"
        
        page.update()
    
    async def test_click_page(self, page: ft.Page):
        """Test clicking on main page"""
        self.status_text.value = "Testing click on main page..."
        self.status_text.color = "#ff9800"
        page.update()
        
        try:
            result = await self.hub.test_click_main_page()
            
            if "Clicked at" in str(result):
                self.status_text.value = f"✓ {result}"
                self.status_text.color = "#4caf50"
            else:
                self.status_text.value = f"⚠ {result}"
                self.status_text.color = "#ff9800"
        except Exception as e:
            self.status_text.value = f"Error: {str(e)}"
            self.status_text.color = "#f44336"
        
        page.update()
    
    async def test_hover_page(self, page: ft.Page):
        """Test hovering on main page for 2 seconds"""
        self.status_text.value = "Testing hover on main page (2s)..."
        self.status_text.color = "#9c27b0"
        page.update()
        
        try:
            result = await self.hub.test_hover_main_page(duration_seconds=2.0)
            
            if "Hovered at" in str(result):
                self.status_text.value = f"✓ {result}"
                self.status_text.color = "#4caf50"
            else:
                self.status_text.value = f"⚠ {result}"
                self.status_text.color = "#ff9800"
        except Exception as e:
            self.status_text.value = f"Error: {str(e)}"
            self.status_text.color = "#f44336"
        
        page.update()
    
    async def submit_prompt(self, page: ft.Page):
        """Submit prompt to Gemini"""
        if not self.is_connected:
            self.response_text.value = "Not connected"
            self.text_response.visible = True
            self.image_container.visible = False
            page.update()
            return
        
        prompt = self.prompt_field.value.strip()
        if not prompt:
            self.response_text.value = "Please enter a prompt"
            self.text_response.visible = True
            self.image_container.visible = False
            page.update()
            return
        
        if self.is_batch_mode:
            # Batch image generation mode
            prompts = [p.strip() for p in prompt.split('\n') if p.strip()]
            if len(prompts) == 0:
                self.response_text.value = "Please enter at least one prompt"
                self.text_response.visible = True
                page.update()
                return
            
            if len(prompts) > 5:
                prompts = prompts[:5]  # Limit to 5
            
            self.response_text.value = f"Generating {len(prompts)} images..."
            self.text_response.visible = True
            self.image_container.visible = False
            self.image_grid.controls.clear()
            page.update()
            
            try:
                aspect_ratio = self.aspect_dropdown.value
                results = await self.hub.batch_images(prompts, aspect_ratio)
                
                # Display results in grid
                self.image_grid.controls.clear()
                for i, result in enumerate(results):
                    if result and result.get("status") == "COMPLETED" and result.get("result"):
                        image_data = result["result"]
                        if "," in image_data:
                            b64_part = image_data.split(",", 1)[1]
                        else:
                            b64_part = image_data
                        
                        # Auto-save image
                        save_image_to_file(image_data, prefix=f"batch_{i+1}")
                        
                        # Create image card
                        img_card = ft.Container(
                            content=ft.Column([
                                ft.Image(
                                    src_base64=b64_part,
                                    width=140,
                                    height=140,
                                    fit=ft.ImageFit.COVER,
                                    border_radius=5,
                                ),
                                ft.Text(
                                    result.get("prompt", "")[:20] + "...",
                                    size=10,
                                    text_align=ft.TextAlign.CENTER,
                                    width=140,
                                ),
                            ], spacing=2, horizontal_alignment=ft.CrossAxisAlignment.CENTER),
                            border=ft.border.all(1, "#e0e0e0"),
                            border_radius=5,
                            padding=5,
                        )
                        self.image_grid.controls.append(img_card)
                    else:
                        # Error card
                        error_card = ft.Container(
                            content=ft.Column([
                                ft.Icon("error", size=40, color="#f44336"),
                                ft.Text(
                                    result.get("error", "Failed")[:20] if result else "Error",
                                    size=10,
                                    color="#f44336",
                                    text_align=ft.TextAlign.CENTER,
                                    width=140,
                                ),
                            ], spacing=2, horizontal_alignment=ft.CrossAxisAlignment.CENTER),
                            width=150,
                            height=160,
                            border=ft.border.all(1, "#f44336"),
                            border_radius=5,
                            padding=5,
                        )
                        self.image_grid.controls.append(error_card)
                
                self.response_text.value = f"✓ Generated {len(results)} images"
                self.response_text.color = "#4caf50"
                self.image_grid_container.visible = True
                
            except Exception as e:
                import traceback
                print(f"Batch error: {e}")
                print(traceback.format_exc())
                self.response_text.value = f"Error: {str(e)}"
            
            page.update()
            return
        
        if self.is_image_mode:
            # Image generation
            self.response_text.value = "Generating image..."
            self.text_response.visible = True
            self.image_container.visible = False
            page.update()
            
            try:
                aspect_ratio = self.aspect_dropdown.value
                
                # Prepare reference images
                ref_imgs = None
                if len(self.reference_images) == 1:
                    ref_imgs = self.reference_images[0]
                elif len(self.reference_images) > 1:
                    ref_imgs = self.reference_images
                
                print(f"Calling image generation with aspect: {aspect_ratio}, refs: {ref_imgs is not None}")
                result = await self.hub.image(prompt, aspect_ratio, ref_imgs)
                print(f"Got result type: {type(result)}, length: {len(str(result)) if result else 0}")
                
                if isinstance(result, dict) and "error" in result:
                    self.response_text.value = f"Error: {result['error']}"
                    self.text_response.visible = True
                    self.image_container.visible = False
                elif result == "IMAGE_COPIED":
                    # Image was copied to clipboard - read it
                    try:
                        import subprocess
                        print("[GUI] Reading clipboard...")
                        
                        # Read clipboard using PowerShell
                        ps_cmd = 'powershell -command "Get-Clipboard"'
                        clip_result = subprocess.run(ps_cmd, shell=True, capture_output=True, text=True, timeout=10)
                        clipboard_data = clip_result.stdout.strip()
                        
                        print(f"[GUI] Clipboard data length: {len(clipboard_data)}")
                        print(f"[GUI] Clipboard starts with: {clipboard_data[:50] if len(clipboard_data) > 50 else clipboard_data}")
                        
                        if clipboard_data.startswith("data:image"):
                            # Extract base64 part
                            if "," in clipboard_data:
                                b64_part = clipboard_data.split(",", 1)[1]
                            else:
                                b64_part = clipboard_data
                            
                            print(f"[GUI] Setting image, base64 length: {len(b64_part)}")
                            self.image_preview.src_base64 = b64_part
                            self.image_preview.src = None
                            self.text_response.visible = False
                            self.image_container.visible = True
                            print("[GUI] Image container set to visible")
                        else:
                            print(f"[GUI] Clipboard doesn't contain image data")
                            self.response_text.value = f"✓ Image generated! Check clipboard."
                            self.response_text.color = "#4caf50"
                            self.text_response.visible = True
                            self.image_container.visible = False
                            self.response_text.color = "#4caf50"
                            self.text_response.visible = True
                            self.image_container.visible = False
                    except Exception as clip_err:
                        self.response_text.value = f"✓ Image generated! (clipboard error: {clip_err})"
                        self.response_text.color = "#4caf50"
                        self.text_response.visible = True
                        self.image_container.visible = False
                elif result and isinstance(result, str):
                    # Result is a URL or base64
                    print(f"Result starts with: {result[:50] if len(result) > 50 else result}")
                    
                    if result.startswith("data:image"):
                        # Base64 image
                        try:
                            # Extract base64 data
                            if "," in result:
                                b64_part = result.split(",", 1)[1]
                            else:
                                b64_part = result
                            
                            print(f"Setting base64 image, length: {len(b64_part)}")
                            
                            # Auto-save image
                            save_image_to_file(result, prefix="single")
                            
                            self.image_preview.src_base64 = b64_part
                            self.image_preview.src = None
                        except Exception as e:
                            print(f"Error setting base64: {e}")
                            self.response_text.value = f"Error displaying image: {str(e)}"
                            self.text_response.visible = True
                            self.image_container.visible = False
                            page.update()
                            return
                    else:
                        # URL
                        print(f"Setting image URL: {result}")
                        self.image_preview.src = result
                        self.image_preview.src_base64 = None
                    
                    self.text_response.visible = False
                    self.image_container.visible = True
                else:
                    self.response_text.value = f"Unexpected result: {str(result)[:100]}"
                    self.text_response.visible = True
                    self.image_container.visible = False
            
            except Exception as e:
                import traceback
                print(f"Exception in image generation: {e}")
                print(traceback.format_exc())
                self.response_text.value = f"Error: {str(e)}"
                self.text_response.visible = True
                self.image_container.visible = False
        
        else:
            # Text generation
            model = self.model_dropdown.value
            
            self.response_text.value = "Processing..."
            self.text_response.visible = True
            self.image_container.visible = False
            page.update()
            
            try:
                # Map model dropdown value to geminiHub model ID strings
                model_map = {
                    "flash3": "gemini-3-flash-preview",
                    "flash25": "gemini-2.5-flash-preview", 
                    "pro3": "gemini-3-pro-preview",
                    "pro25": "gemini-2.5-pro-preview",
                    "run": "gemini-3-flash-preview"
                }
                model_name = model_map.get(model, "gemini-3-flash-preview")
                
                # Check if structured output is enabled
                schema = None
                if self.schema_checkbox.value and self.schema_field.value:
                    try:
                        import json
                        schema = json.loads(self.schema_field.value)
                        print(f"[GUI] Using schema: {list(schema.keys()) if isinstance(schema, dict) else 'array/other'}")
                    except json.JSONDecodeError as je:
                        self.response_text.value = f"Invalid JSON schema: {str(je)}"
                        page.update()
                        return
                
                # Streaming callback to update GUI in real-time
                def on_stream_update(text, is_complete):
                    if is_complete:
                        # Final result - format nicely if structured output
                        if schema and isinstance(text, str):
                            try:
                                import json
                                parsed = json.loads(text)
                                self.response_text.value = json.dumps(parsed, indent=2, ensure_ascii=False)
                            except:
                                self.response_text.value = text
                        else:
                            self.response_text.value = text
                    else:
                        # Streaming update - show as-is with indicator
                        self.response_text.value = text + "\n\n⏳ Generating..."
                    page.update()
                
                # Use streaming method for real-time updates
                result = await self.hub.ask_streaming(model_name, prompt, schema, on_stream_update)
                
                if isinstance(result, dict) and "error" in result:
                    self.response_text.value = f"Error: {result['error']}"
                else:
                    # Pretty print JSON if it's structured output
                    if schema and isinstance(result, str):
                        try:
                            import json
                            parsed = json.loads(result)
                            # Use ensure_ascii=False to properly display Unicode characters (Bangla, etc.)
                            self.response_text.value = json.dumps(parsed, indent=2, ensure_ascii=False)
                        except:
                            self.response_text.value = str(result) if result else "No result"
                    else:
                        self.response_text.value = str(result) if result else "No result"
            
            except Exception as e:
                import traceback
                print(f"[GUI] Error: {e}")
                print(traceback.format_exc())
                self.response_text.value = f"Error: {str(e)}"
        
        page.update()


async def main(page: ft.Page):
    app = GeminiApp()
    await app.main(page)


if __name__ == "__main__":
    ft.app(target=main)
