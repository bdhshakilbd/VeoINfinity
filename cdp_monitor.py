"""
VEO3 CDP Monitor - Monitors all browser activity via Chrome DevTools Protocol
Saves all network requests, DOM events to a log file.

Usage:
1. Open Chrome with --remote-debugging-port=9222
2. Navigate to https://labs.google/fx/tools/flow
3. Run this script: python cdp_monitor.py
4. Manually type your prompt and click Generate
5. The script captures everything and saves to veo3_monitor_log.txt
"""

import json
import asyncio
import websocket
import threading
import time
import os
from datetime import datetime

class CDPMonitor:
    def __init__(self, debug_port=9222):
        self.debug_port = debug_port
        self.ws = None
        self.msg_id = 0
        self.log_file = None
        self.running = False
        self.network_requests = []
        self.dom_events = []
        
    def log(self, message, also_print=True):
        """Log to file and optionally print"""
        timestamp = datetime.now().strftime('%H:%M:%S.%f')[:-3]
        log_line = f"[{timestamp}] {message}"
        
        if also_print:
            print(log_line)
        
        if self.log_file:
            self.log_file.write(log_line + "\n")
            self.log_file.flush()
    
    def connect(self):
        """Connect to Chrome DevTools"""
        import requests
        
        # Get list of tabs
        response = requests.get(f'http://localhost:{self.debug_port}/json')
        tabs = response.json()
        
        # Find the labs.google tab
        target_tab = None
        for tab in tabs:
            if 'labs.google' in tab.get('url', ''):
                target_tab = tab
                break
        
        if not target_tab:
            print(f"❌ No labs.google tab found. Open https://labs.google/fx/tools/flow first.")
            return False
        
        ws_url = target_tab['webSocketDebuggerUrl']
        self.ws = websocket.create_connection(ws_url)
        print(f"✅ Connected to: {target_tab['url'][:60]}...")
        return True
    
    def send_command(self, method, params=None):
        """Send CDP command"""
        self.msg_id += 1
        msg = {'id': self.msg_id, 'method': method, 'params': params or {}}
        self.ws.send(json.dumps(msg))
        return self.msg_id
    
    def enable_monitoring(self):
        """Enable CDP domains for monitoring"""
        # Enable Network domain
        self.send_command('Network.enable')
        self.log("✅ Network monitoring enabled")
        
        # Enable Page domain
        self.send_command('Page.enable')
        self.log("✅ Page monitoring enabled")
        
        # Enable DOM domain
        self.send_command('DOM.enable')
        self.log("✅ DOM monitoring enabled")
        
        # Enable Runtime domain for console logs
        self.send_command('Runtime.enable')
        self.log("✅ Runtime monitoring enabled")
    
    def process_event(self, event):
        """Process CDP events"""
        method = event.get('method', '')
        params = event.get('params', {})
        
        # Network request will be sent
        if method == 'Network.requestWillBeSent':
            request = params.get('request', {})
            url = request.get('url', '')
            method_type = request.get('method', '')
            headers = request.get('headers', {})
            post_data = request.get('postData', '')
            
            if 'googleapis.com' in url or 'recaptcha' in url.lower():
                self.log(f"\n{'='*60}")
                self.log(f"📡 NETWORK REQUEST:")
                self.log(f"   URL: {url}")
                self.log(f"   Method: {method_type}")
                self.log(f"   Request ID: {params.get('requestId')}")
                
                if headers:
                    self.log(f"   Headers:")
                    for key, value in headers.items():
                        if key.lower() in ['authorization', 'content-type', 'x-browser-channel', 'x-browser-year', 'x-browser-validation']:
                            self.log(f"      {key}: {value[:80]}..." if len(str(value)) > 80 else f"      {key}: {value}")
                
                if post_data:
                    self.log(f"   POST Data ({len(post_data)} chars):")
                    # Try to pretty print JSON
                    try:
                        parsed = json.loads(post_data)
                        self.log(f"   {json.dumps(parsed, indent=2)[:2000]}")
                    except:
                        self.log(f"   {post_data[:1000]}")
                
                # Save to list
                self.network_requests.append({
                    'timestamp': datetime.now().isoformat(),
                    'url': url,
                    'method': method_type,
                    'headers': headers,
                    'postData': post_data,
                    'requestId': params.get('requestId')
                })
        
        # Network response received
        elif method == 'Network.responseReceived':
            response = params.get('response', {})
            url = response.get('url', '')
            status = response.get('status')
            
            if 'googleapis.com' in url:
                self.log(f"\n📥 RESPONSE: {url[:60]}...")
                self.log(f"   Status: {status}")
        
        # Console log from page
        elif method == 'Runtime.consoleAPICalled':
            args = params.get('args', [])
            log_type = params.get('type', 'log')
            
            if args:
                message = ' '.join([str(arg.get('value', arg.get('description', ''))) for arg in args])
                if message and ('grecaptcha' in message.lower() or 'veo' in message.lower() or 'video' in message.lower()):
                    self.log(f"🖥️ CONSOLE [{log_type}]: {message[:200]}")
        
        # Page navigated
        elif method == 'Page.frameNavigated':
            frame = params.get('frame', {})
            url = frame.get('url', '')
            if url:
                self.log(f"🔗 PAGE NAVIGATED: {url}")
    
    def listen_events(self):
        """Listen for CDP events in a loop"""
        self.log("\n" + "="*60)
        self.log("🎯 MONITORING STARTED - Manually type prompt and click Generate")
        self.log("="*60 + "\n")
        
        while self.running:
            try:
                self.ws.settimeout(0.5)
                message = self.ws.recv()
                event = json.loads(message)
                self.process_event(event)
            except websocket.WebSocketTimeoutException:
                continue
            except Exception as e:
                if self.running:
                    self.log(f"⚠️ Error: {e}")
                break
    
    def start_monitoring(self, log_filename='veo3_monitor_log.txt'):
        """Start monitoring and save logs to file"""
        # Create log file
        self.log_file = open(log_filename, 'w', encoding='utf-8')
        self.log(f"📝 Logging to: {os.path.abspath(log_filename)}")
        
        # Connect
        if not self.connect():
            return
        
        # Enable monitoring
        self.enable_monitoring()
        
        # Start listening
        self.running = True
        
        print("\n" + "="*60)
        print("🔍 VEO3 CDP MONITOR - READY")
        print("="*60)
        print("\nNow manually:")
        print("  1. Type your prompt in the textarea")
        print("  2. Click the Create button")
        print("  3. Wait for generation to start")
        print("\nPress Ctrl+C to stop monitoring and save logs.")
        print("="*60 + "\n")
        
        try:
            self.listen_events()
        except KeyboardInterrupt:
            print("\n\n⏹️ Stopping monitor...")
        finally:
            self.stop()
    
    def stop(self):
        """Stop monitoring and save summary"""
        self.running = False
        
        # Write summary
        self.log("\n" + "="*60)
        self.log("📊 MONITORING SUMMARY")
        self.log("="*60)
        self.log(f"Total API requests captured: {len(self.network_requests)}")
        
        # Save network requests as JSON
        if self.network_requests:
            self.log("\n📦 CAPTURED API REQUESTS (JSON):")
            self.log(json.dumps(self.network_requests, indent=2))
        
        self.log("="*60)
        
        # Close
        if self.ws:
            self.ws.close()
        
        if self.log_file:
            self.log_file.close()
            print(f"\n✅ Logs saved to: {os.path.abspath('veo3_monitor_log.txt')}")

def main():
    print("="*60)
    print("VEO3 CDP MONITOR")
    print("="*60)
    print("\nThis script monitors Chrome via CDP and captures all network")
    print("requests when you manually generate a video.")
    print("\nMake sure Chrome is running with: --remote-debugging-port=9222")
    print("And https://labs.google/fx/tools/flow is open")
    print("="*60)
    
    monitor = CDPMonitor(debug_port=9222)
    monitor.start_monitoring('veo3_monitor_log.txt')

if __name__ == '__main__':
    main()
