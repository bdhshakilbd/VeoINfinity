"""
Simple HTTP server for serving story frames
Enables CORS for cross-origin requests from Flow
"""

from http.server import HTTPServer, SimpleHTTPRequestHandler
import os

class CORSRequestHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        # Enable CORS
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        super().end_headers()
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

if __name__ == '__main__':
    # Change to the story_frames directory
    os.chdir(r'C:\Users\Lenovo\Documents\story_frames')
    
    port = 8000
    server = HTTPServer(('localhost', port), CORSRequestHandler)
    
    print("="*60)
    print(f"🌐 Story Frames Server Running")
    print("="*60)
    print(f"\n📁 Serving from: C:\\Users\\Lenovo\\Documents\\story_frames")
    print(f"🔗 Server URL: http://localhost:{port}/")
    print(f"\n📸 Available frames:")
    print(f"   - http://localhost:{port}/frame_001.png")
    print(f"   - http://localhost:{port}/frame_002.png")
    print(f"\n⚠️  Press Ctrl+C to stop the server")
    print("="*60 + "\n")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\n🛑 Server stopped")
        server.shutdown()
