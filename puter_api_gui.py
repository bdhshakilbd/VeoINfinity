import tkinter as tk
from tkinter import ttk, scrolledtext, messagebox
import requests
import json
import os
from pathlib import Path

class PuterAPIGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Puter AI Chat Completion")
        self.root.geometry("800x600")
        
        # Default token (hardcoded)
        self.default_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0IjoiYXUiLCJ2IjoiMC4wLjAiLCJ1dSI6ImIyWjllRmdwVG9DTk1TZ2RpVjJ3REE9PSIsImF1IjoiSE0xbzIrVlRWMm1QRDd5bWpFdHhhUT09IiwicyI6Im94b1pPQkpCRDV3TTNDTXJTdjE1bFE9PSIsImlhdCI6MTc2Nzg2NjcwNX0.XshXf_UVTHrtcU6SL2QrFADdDmFhPxhUDlyk1QabMDQ"
        
        # Token file path
        self.token_file = Path(__file__).parent / "puter_token.txt"
        
        # Load saved token or use default
        self.auth_token = self.load_token()
        
        self.setup_ui()
        
    def load_token(self):
        """Load token from file or return default"""
        if self.token_file.exists():
            try:
                with open(self.token_file, 'r') as f:
                    token = f.read().strip()
                    if token:
                        return token
            except Exception as e:
                print(f"Error loading token: {e}")
        return self.default_token
    
    def save_token(self, token):
        """Save token to file"""
        try:
            with open(self.token_file, 'w') as f:
                f.write(token)
            messagebox.showinfo("Success", "Token saved successfully!")
        except Exception as e:
            messagebox.showerror("Error", f"Failed to save token: {e}")
    
    def setup_ui(self):
        """Setup the GUI components"""
        # Main container
        main_frame = ttk.Frame(self.root, padding="10")
        main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        # Configure grid weights
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        main_frame.columnconfigure(0, weight=1)
        main_frame.rowconfigure(3, weight=1)
        main_frame.rowconfigure(6, weight=1)
        
        # Token Section
        token_frame = ttk.LabelFrame(main_frame, text="Authentication Token", padding="5")
        token_frame.grid(row=0, column=0, sticky=(tk.W, tk.E), pady=(0, 10))
        token_frame.columnconfigure(0, weight=1)
        
        self.token_entry = ttk.Entry(token_frame, width=80)
        self.token_entry.grid(row=0, column=0, sticky=(tk.W, tk.E), padx=(0, 5))
        self.token_entry.insert(0, self.auth_token)
        
        ttk.Button(token_frame, text="Save Token", command=self.update_token).grid(row=0, column=1)
        ttk.Button(token_frame, text="Reset to Default", command=self.reset_token).grid(row=0, column=2, padx=(5, 0))
        
        # Model Selection Section
        model_frame = ttk.LabelFrame(main_frame, text="Model Selection", padding="5")
        model_frame.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 10))
        model_frame.columnconfigure(1, weight=1)
        
        ttk.Label(model_frame, text="Gemini Model:").grid(row=0, column=0, sticky=tk.W, padx=(0, 10))
        
        self.models = [
            "gemini-3-flash-preview",
            "gemini-3-pro-preview",
            "gemini-2.5-pro",
            "gemini-2.5-flash-lite",
            "gemini-2.5-flash",
            "gemini-2.0-flash-lite",
            "gemini-2.0-flash",
            "gemini-1.5-flash"
        ]
        
        self.model_var = tk.StringVar(value=self.models[0])
        self.model_dropdown = ttk.Combobox(model_frame, textvariable=self.model_var, values=self.models, state='readonly', width=30)
        self.model_dropdown.grid(row=0, column=1, sticky=(tk.W, tk.E))
        
        # Input Section
        ttk.Label(main_frame, text="Input Prompt:", font=('Arial', 10, 'bold')).grid(row=2, column=0, sticky=tk.W, pady=(0, 5))
        
        self.input_text = scrolledtext.ScrolledText(main_frame, height=8, wrap=tk.WORD, font=('Arial', 10))
        self.input_text.grid(row=3, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), pady=(0, 10))
        self.input_text.insert(1.0, "Write a bangla short story")
        
        # Generate Button
        self.generate_btn = ttk.Button(main_frame, text="Generate", command=self.generate_response, style='Accent.TButton')
        self.generate_btn.grid(row=4, column=0, pady=(0, 10))
        
        # Output Section
        ttk.Label(main_frame, text="Response:", font=('Arial', 10, 'bold')).grid(row=5, column=0, sticky=tk.W, pady=(0, 5))
        
        self.output_text = scrolledtext.ScrolledText(main_frame, height=12, wrap=tk.WORD, font=('Arial', 10), state='disabled')
        self.output_text.grid(row=6, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        # Status Bar
        self.status_var = tk.StringVar()
        self.status_var.set("Ready")
        status_bar = ttk.Label(main_frame, textvariable=self.status_var, relief=tk.SUNKEN, anchor=tk.W)
        status_bar.grid(row=7, column=0, sticky=(tk.W, tk.E), pady=(10, 0))
        
    def update_token(self):
        """Update and save the token"""
        new_token = self.token_entry.get().strip()
        if new_token:
            self.auth_token = new_token
            self.save_token(new_token)
        else:
            messagebox.showwarning("Warning", "Token cannot be empty!")
    
    def reset_token(self):
        """Reset token to default"""
        self.auth_token = self.default_token
        self.token_entry.delete(0, tk.END)
        self.token_entry.insert(0, self.default_token)
        self.save_token(self.default_token)
    
    def generate_response(self):
        """Generate response from Puter API with streaming"""
        prompt = self.input_text.get(1.0, tk.END).strip()
        
        if not prompt:
            messagebox.showwarning("Warning", "Please enter a prompt!")
            return
        
        # Disable button during generation
        self.generate_btn.config(state='disabled')
        self.status_var.set("Generating response...")
        
        # Clear output
        self.output_text.config(state='normal')
        self.output_text.delete(1.0, tk.END)
        
        self.root.update()
        
        try:
            # Prepare the request
            url = "https://api.puter.com/drivers/call"
            
            headers = {
                "Content-Type": "text/plain;actually=json",
                "sec-ch-ua-platform": "Windows",
                "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
                "sec-ch-ua": '"Google Chrome";v="143", "Chromium";v="143", "Not A(Brand";v="24"',
                "sec-ch-ua-mobile": "?0",
                "accept": "*/*",
                "origin": "http://localhost:8000",
                "sec-fetch-site": "cross-site",
                "sec-fetch-mode": "cors",
                "sec-fetch-dest": "empty",
                "referer": "http://localhost:8000/",
                "accept-encoding": "gzip, deflate, br, zstd",
                "accept-language": "en-US,en;q=0.9",
                "priority": "u=1, i"
            }
            
            payload = {
                "interface": "puter-chat-completion",
                "driver": "ai-chat",
                "test_mode": False,
                "method": "complete",
                "args": {
                    "messages": [
                        {
                            "content": prompt
                        }
                    ],
                    "model": self.model_var.get(),
                    "stream": True
                },
                "auth_token": self.auth_token
            }
            
            # Make the streaming request (10 minute timeout)
            response = requests.post(url, headers=headers, json=payload, timeout=600, stream=True)
            
            if response.status_code == 200:
                # Process streaming response
                full_response = ""
                for line in response.iter_lines():
                    if line:
                        try:
                            # Decode the line
                            line_text = line.decode('utf-8')
                            
                            # Parse JSON if possible
                            if line_text.startswith('data: '):
                                line_text = line_text[6:]  # Remove 'data: ' prefix
                            
                            if line_text.strip() and line_text != '[DONE]':
                                try:
                                    data = json.loads(line_text)
                                    
                                    # Extract text from different possible response formats
                                    text_content = None
                                    if isinstance(data, dict):
                                        # Try different possible keys
                                        if 'text' in data:
                                            text_content = data['text']
                                        elif 'content' in data:
                                            text_content = data['content']
                                        elif 'message' in data and isinstance(data['message'], dict):
                                            text_content = data['message'].get('content', '')
                                        elif 'choices' in data and len(data['choices']) > 0:
                                            choice = data['choices'][0]
                                            if 'delta' in choice and 'content' in choice['delta']:
                                                text_content = choice['delta']['content']
                                            elif 'text' in choice:
                                                text_content = choice['text']
                                    
                                    if text_content:
                                        full_response += text_content
                                        self.output_text.insert(tk.END, text_content)
                                        self.output_text.see(tk.END)
                                        self.root.update()
                                        
                                except json.JSONDecodeError:
                                    # If not JSON, treat as plain text
                                    full_response += line_text
                                    self.output_text.insert(tk.END, line_text + "\n")
                                    self.output_text.see(tk.END)
                                    self.root.update()
                        
                        except Exception as e:
                            print(f"Error processing line: {e}")
                            continue
                
                if full_response:
                    self.status_var.set("Response generated successfully!")
                else:
                    self.status_var.set("Response completed (check output)")
                    
            else:
                error_msg = f"Error {response.status_code}: {response.text}"
                self.output_text.insert(1.0, error_msg)
                self.status_var.set(f"Error: {response.status_code}")
                
            self.output_text.config(state='disabled')
            
        except requests.exceptions.Timeout:
            messagebox.showerror("Error", "Request timed out. Please try again.")
            self.status_var.set("Request timed out")
            self.output_text.config(state='disabled')
        except requests.exceptions.RequestException as e:
            messagebox.showerror("Error", f"Request failed: {str(e)}")
            self.status_var.set("Request failed")
            self.output_text.config(state='disabled')
        except Exception as e:
            messagebox.showerror("Error", f"An error occurred: {str(e)}")
            self.status_var.set("Error occurred")
            self.output_text.config(state='disabled')
        finally:
            # Re-enable button
            self.generate_btn.config(state='normal')

def main():
    root = tk.Tk()
    app = PuterAPIGUI(root)
    root.mainloop()

if __name__ == "__main__":
    main()
