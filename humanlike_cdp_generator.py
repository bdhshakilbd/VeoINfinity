#!/usr/bin/env python3
"""
Human-like CDP Video Generator for VEO3

This version includes all the behaviors needed to pass reCAPTCHA:
1. Natural mouse movements with curves
2. Variable keystroke delays (based on key distance)
3. Random micro-pauses (human thinking)
4. Mouse hovering before clicks
5. Proper focus/blur patterns

The key insight: reCAPTCHA Enterprise analyzes the ENTIRE interaction pattern,
not just whether events are "trusted". We need to simulate human behavior.
"""

import sys
import time
import json
import asyncio
import websockets
import requests
import random
import math

# Configuration
CDP_PORT = 9222

# Keyboard layout for realistic typing delays
KEYBOARD_ROWS = {
    '1': 0, '2': 0, '3': 0, '4': 0, '5': 0, '6': 0, '7': 0, '8': 0, '9': 0, '0': 0, '-': 0, '=': 0,
    'q': 1, 'w': 1, 'e': 1, 'r': 1, 't': 1, 'y': 1, 'u': 1, 'i': 1, 'o': 1, 'p': 1, '[': 1, ']': 1,
    'a': 2, 's': 2, 'd': 2, 'f': 2, 'g': 2, 'h': 2, 'j': 2, 'k': 2, 'l': 2, ';': 2, "'": 2,
    'z': 3, 'x': 3, 'c': 3, 'v': 3, 'b': 3, 'n': 3, 'm': 3, ',': 3, '.': 3, '/': 3,
    ' ': 4,  # Space bar
}

KEYBOARD_COLS = {
    '1': 0, 'q': 0, 'a': 0, 'z': 0,
    '2': 1, 'w': 1, 's': 1, 'x': 1,
    '3': 2, 'e': 2, 'd': 2, 'c': 2,
    '4': 3, 'r': 3, 'f': 3, 'v': 3,
    '5': 4, 't': 4, 'g': 4, 'b': 4,
    '6': 5, 'y': 5, 'h': 5, 'n': 5,
    '7': 6, 'u': 6, 'j': 6, 'm': 6,
    '8': 7, 'i': 7, 'k': 7, ',': 7,
    '9': 8, 'o': 8, 'l': 8, '.': 8,
    '0': 9, 'p': 9, ';': 9, '/': 9,
    '-': 10, '[': 10, "'": 10,
    '=': 11, ']': 11,
    ' ': 5,  # Center of space bar
}


def get_key_distance(char1: str, char2: str) -> float:
    """Calculate distance between two keys on keyboard"""
    c1, c2 = char1.lower(), char2.lower()
    if c1 not in KEYBOARD_ROWS or c2 not in KEYBOARD_ROWS:
        return 2.0  # Default for special characters
    
    row_diff = abs(KEYBOARD_ROWS.get(c1, 2) - KEYBOARD_ROWS.get(c2, 2))
    col_diff = abs(KEYBOARD_COLS.get(c1, 5) - KEYBOARD_COLS.get(c2, 5))
    return math.sqrt(row_diff ** 2 + col_diff ** 2)


def get_typing_delay(prev_char: str, curr_char: str) -> float:
    """Calculate human-like delay between keystrokes"""
    base_delay = random.uniform(0.05, 0.12)  # Base typing speed
    
    # Add delay based on key distance
    distance = get_key_distance(prev_char, curr_char)
    distance_delay = distance * random.uniform(0.015, 0.025)
    
    # Random chance of micro-pause (thinking/looking at screen)
    if random.random() < 0.05:
        thinking_pause = random.uniform(0.2, 0.5)
    else:
        thinking_pause = 0
    
    # Longer pause after punctuation
    if prev_char in '.,!?:;':
        punctuation_pause = random.uniform(0.1, 0.25)
    else:
        punctuation_pause = 0
    
    # Longer pause after space (end of word)
    if prev_char == ' ':
        word_pause = random.uniform(0.05, 0.15)
    else:
        word_pause = 0
    
    return base_delay + distance_delay + thinking_pause + punctuation_pause + word_pause


def generate_bezier_curve(start: tuple, end: tuple, num_points: int = 20) -> list:
    """Generate points along a bezier curve for natural mouse movement"""
    cx1 = start[0] + (end[0] - start[0]) * random.uniform(0.2, 0.4)
    cy1 = start[1] + (end[1] - start[1]) * random.uniform(-0.3, 0.3)
    cx2 = start[0] + (end[0] - start[0]) * random.uniform(0.6, 0.8)
    cy2 = start[1] + (end[1] - start[1]) * random.uniform(-0.3, 0.3)
    
    points = []
    for i in range(num_points + 1):
        t = i / num_points
        
        # Cubic bezier formula
        x = (1 - t) ** 3 * start[0] + \
            3 * (1 - t) ** 2 * t * cx1 + \
            3 * (1 - t) * t ** 2 * cx2 + \
            t ** 3 * end[0]
        y = (1 - t) ** 3 * start[1] + \
            3 * (1 - t) ** 2 * t * cy1 + \
            3 * (1 - t) * t ** 2 * cy2 + \
            t ** 3 * end[1]
        
        # Add small random jitter
        x += random.uniform(-2, 2)
        y += random.uniform(-2, 2)
        
        points.append((x, y))
    
    return points


class HumanlikeCDPGenerator:
    """Human-like video generator using CDP with realistic behavior patterns"""
    
    def __init__(self, port: int = 9222):
        self.port = port
        self.ws = None
        self.msg_id = 0
        self.mouse_pos = (500, 300)  # Simulated mouse position
    
    async def connect(self) -> bool:
        """Connect to Chrome via CDP"""
        try:
            resp = requests.get(f"http://localhost:{self.port}/json")
            tabs = resp.json()
        except Exception as e:
            print(f"✗ Failed to connect: {e}")
            return False
        
        # Find VEO3 tab
        veo_tab = None
        for tab in tabs:
            if 'labs.google' in tab.get('url', ''):
                veo_tab = tab
                break
        
        if not veo_tab:
            print("✗ No VEO3 tab found")
            return False
        
        self.ws = await websockets.connect(veo_tab['webSocketDebuggerUrl'])
        print(f"✓ Connected to: {veo_tab['url'][:60]}...")
        return True
    
    async def send_command(self, method: str, params: dict = None) -> dict:
        """Send CDP command and wait for response"""
        self.msg_id += 1
        await self.ws.send(json.dumps({
            'id': self.msg_id,
            'method': method,
            'params': params or {}
        }))
        
        while True:
            response = json.loads(await self.ws.recv())
            if response.get('id') == self.msg_id:
                return response.get('result', {})
    
    async def execute_js(self, code: str):
        """Execute JavaScript and return result"""
        result = await self.send_command('Runtime.evaluate', {
            'expression': code,
            'returnByValue': True,
            'awaitPromise': True
        })
        if 'result' in result and 'value' in result['result']:
            return result['result']['value']
        return None
    
    async def move_mouse_naturally(self, target_x: float, target_y: float):
        """Move mouse along a bezier curve to target position"""
        start = self.mouse_pos
        end = (target_x, target_y)
        
        points = generate_bezier_curve(start, end, num_points=random.randint(15, 25))
        
        for x, y in points:
            await self.send_command('Input.dispatchMouseEvent', {
                'type': 'mouseMoved',
                'x': x,
                'y': y
            })
            # Variable delay between mouse movements
            await asyncio.sleep(random.uniform(0.008, 0.025))
        
        self.mouse_pos = end
        
        # Small pause after reaching destination (human reaction)
        await asyncio.sleep(random.uniform(0.05, 0.15))
    
    async def click_naturally(self, x: float, y: float):
        """Perform a natural mouse click with movement first"""
        # Move to position first
        await self.move_mouse_naturally(x, y)
        
        # Small hover before click
        await asyncio.sleep(random.uniform(0.05, 0.12))
        
        # Mouse down with slight delay before up
        await self.send_command('Input.dispatchMouseEvent', {
            'type': 'mousePressed',
            'x': x,
            'y': y,
            'button': 'left',
            'clickCount': 1
        })
        
        # Human click duration
        await asyncio.sleep(random.uniform(0.05, 0.12))
        
        await self.send_command('Input.dispatchMouseEvent', {
            'type': 'mouseReleased',
            'x': x,
            'y': y,
            'button': 'left',
            'clickCount': 1
        })
        
        # Post-click pause
        await asyncio.sleep(random.uniform(0.1, 0.2))
    
    async def type_naturally(self, text: str):
        """Type text with human-like timing"""
        prev_char = ' '
        
        for i, char in enumerate(text):
            # Calculate delay based on keyboard distance
            delay = get_typing_delay(prev_char, char)
            await asyncio.sleep(delay)
            
            # Send keydown/keypress/keyup for more realistic event sequence
            await self.send_command('Input.dispatchKeyEvent', {
                'type': 'keyDown',
                'text': char,
                'key': char,
            })
            await asyncio.sleep(random.uniform(0.02, 0.05))  # Key hold time
            await self.send_command('Input.dispatchKeyEvent', {
                'type': 'keyUp',
                'key': char,
            })
            
            prev_char = char
            
            # Progress indicator every 20 chars
            if (i + 1) % 20 == 0:
                print(f"    ... typed {i+1}/{len(text)} chars")
        
        # Final pause after typing (thinking/reviewing)
        await asyncio.sleep(random.uniform(0.5, 1.0))
    
    async def press_enter_naturally(self):
        """Press Enter key with natural timing"""
        # Small pause before pressing Enter (hesitation)
        await asyncio.sleep(random.uniform(0.2, 0.4))
        
        await self.send_command('Input.dispatchKeyEvent', {
            'type': 'keyDown',
            'key': 'Enter',
            'code': 'Enter',
            'windowsVirtualKeyCode': 13,
            'nativeVirtualKeyCode': 13
        })
        
        # Key hold time
        await asyncio.sleep(random.uniform(0.08, 0.15))
        
        await self.send_command('Input.dispatchKeyEvent', {
            'type': 'keyUp',
            'key': 'Enter',
            'code': 'Enter',
            'windowsVirtualKeyCode': 13,
            'nativeVirtualKeyCode': 13
        })
    
    async def generate_video(self, prompt: str) -> dict:
        """Generate video using human-like UI automation"""
        print("\n" + "=" * 60)
        print("Human-like VEO3 Video Generation")
        print("=" * 60)
        
        # Step 1: Connect
        print("\n[1] Connecting to Chrome...")
        if not await self.connect():
            return {'success': False, 'error': 'Failed to connect'}
        
        # Step 2: Initial random mouse movement (page exploration)
        print("\n[2] Simulating initial mouse activity...")
        for _ in range(3):
            rx = random.uniform(300, 700)
            ry = random.uniform(200, 600)
            await self.move_mouse_naturally(rx, ry)
            await asyncio.sleep(random.uniform(0.3, 0.8))
        
        # Step 3: Find textarea
        print("\n[3] Finding textarea...")
        pos = await self.execute_js('''
        (function() {
            const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
            if (!textarea) return null;
            const rect = textarea.getBoundingClientRect();
            return {
                x: rect.left + rect.width / 2,
                y: rect.top + rect.height / 2
            };
        })()
        ''')
        
        if not pos:
            return {'success': False, 'error': 'Textarea not found'}
        
        x, y = pos['x'], pos['y']
        print(f"    ✓ Found at ({x:.0f}, {y:.0f})")
        
        # Step 4: Move to textarea naturally and click
        print("\n[4] Moving to and clicking textarea...")
        await self.click_naturally(x, y)
        print("    ✓ Clicked")
        
        # Step 5: Clear any existing text
        print("\n[5] Clearing existing text...")
        await self.send_command('Input.dispatchKeyEvent', {
            'type': 'keyDown',
            'key': 'a',
            'code': 'KeyA',
            'modifiers': 2  # Ctrl
        })
        await asyncio.sleep(0.08)
        await self.send_command('Input.dispatchKeyEvent', {
            'type': 'keyUp',
            'key': 'a',
            'code': 'KeyA',
            'modifiers': 2
        })
        await asyncio.sleep(0.1)
        await self.send_command('Input.dispatchKeyEvent', {
            'type': 'keyDown',
            'key': 'Backspace',
            'code': 'Backspace'
        })
        await asyncio.sleep(0.06)
        await self.send_command('Input.dispatchKeyEvent', {
            'type': 'keyUp',
            'key': 'Backspace',
            'code': 'Backspace'
        })
        await asyncio.sleep(random.uniform(0.3, 0.5))
        print("    ✓ Cleared")
        
        # Step 6: Type prompt naturally
        print(f"\n[6] Typing prompt ({len(prompt)} chars)...")
        await self.type_naturally(prompt)
        print("    ✓ Typing complete")
        
        # Step 7: Review pause (human reads what they typed)
        review_time = random.uniform(1.0, 2.0)
        print(f"\n[7] Review pause ({review_time:.1f}s)...")
        await asyncio.sleep(review_time)
        
        # Step 8: Press Enter to submit
        print("\n[8] Pressing Enter to generate...")
        await self.press_enter_naturally()
        print("    ✓ Enter pressed!")
        
        # Step 9: Monitor for completion
        print("\n[9] Monitoring for video completion (max 5 minutes)...")
        start_time = time.time()
        max_wait = 300
        
        while time.time() - start_time < max_wait:
            elapsed = int(time.time() - start_time)
            
            result = await self.execute_js('''
            (function() {
                // Check for video element
                const video = document.querySelector('video[src]');
                if (video && video.src && video.src.includes('http')) {
                    return { success: true, url: video.src, method: 'video_element' };
                }
                
                // Check for failed generation
                const failed = document.querySelector('[class*="Failed"]');
                if (failed) {
                    return { success: false, error: 'Generation failed (likely reCAPTCHA)' };
                }
                
                // Check for error
                const error = document.querySelector('[role="alert"]');
                if (error && error.textContent.includes('error')) {
                    return { success: false, error: error.textContent };
                }
                
                return { waiting: true };
            })()
            ''')
            
            if result:
                if result.get('success'):
                    print(f"\n    ✓ VIDEO READY after {elapsed}s!")
                    print(f"    URL: {result.get('url')[:80]}...")
                    return {
                        'success': True,
                        'url': result.get('url'),
                        'prompt': prompt,
                        'duration': elapsed
                    }
                elif result.get('error'):
                    print(f"\n    ✗ Error: {result.get('error')}")
                    return {'success': False, 'error': result.get('error')}
            
            print(f"    [{elapsed}s] Still generating...", end='\r')
            await asyncio.sleep(3)
        
        return {'success': False, 'error': 'Timeout'}
    
    async def close(self):
        """Close the WebSocket connection"""
        if self.ws:
            await self.ws.close()


async def main():
    prompt = "A majestic golden retriever running through a field of sunflowers at sunset"
    
    generator = HumanlikeCDPGenerator(port=CDP_PORT)
    try:
        result = await generator.generate_video(prompt)
        print("\n" + "=" * 60)
        if result.get('success'):
            print("✓ Generation successful!")
            print(f"  Video URL: {result.get('url')[:100]}...")
        else:
            print(f"✗ Generation failed: {result.get('error')}")
        print("=" * 60)
    finally:
        await generator.close()


if __name__ == '__main__':
    print("""
╔══════════════════════════════════════════════════════════╗
║         Human-like VEO3 Video Generator                  ║
║                                                          ║
║  This script simulates realistic human behavior to       ║
║  pass reCAPTCHA Enterprise's behavioral analysis:        ║
║                                                          ║
║  • Natural bezier-curve mouse movement                   ║
║  • Variable keystroke delays (keyboard distance)         ║
║  • Random micro-pauses (thinking moments)                ║
║  • Proper hover-before-click patterns                    ║
║  • Review pauses after typing                            ║
╚══════════════════════════════════════════════════════════╝
    """)
    
    print("Prerequisites:")
    print("1. Chrome running with: --remote-debugging-port=9222")
    print("2. Logged into https://labs.google/fx/tools/video-fx")
    print("3. Page loaded and ready\n")
    
    asyncio.run(main())
