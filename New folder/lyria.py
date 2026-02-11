import asyncio
import threading
import subprocess
import tkinter as tk
import wave
import os
from tkinter import messagebox

from google import genai
from google.genai import types


class LyriaGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Lyria Realtime Music Tester")
        self.root.geometry("500x320")

        self.session = None
        self.loop = None
        self.ffplay = None

        # UI
        tk.Label(root, text="Google API Key").pack()
        self.api_key_entry = tk.Entry(root, show="*", width=60)
        self.api_key_entry.insert(0, "AIzaSyDDRMIGrg9uUSh714gRgbHmJIsgWfxdlaY")
        self.api_key_entry.pack(pady=5)

        tk.Label(root, text="Prompt").pack()
        self.prompt_entry = tk.Entry(root, width=60)
        self.prompt_entry.insert(0, "Minimal Techno")
        self.prompt_entry.pack(pady=5)

        self.start_btn = tk.Button(root, text="▶ Start Music", command=self.start_music)
        self.start_btn.pack(pady=5)

        self.stop_btn = tk.Button(root, text="⏹ Stop Music", command=self.stop_music, state=tk.DISABLED)
        self.stop_btn.pack(pady=5)

        self.prompt_btn = tk.Button(root, text="🎚 Send Prompt", command=self.send_prompt, state=tk.DISABLED)
        self.prompt_btn.pack(pady=5)

    def start_music(self):
        api_key = self.api_key_entry.get().strip()
        if not api_key:
            messagebox.showerror("Error", "API key required")
            return

        self.start_btn.config(state=tk.DISABLED)
        self.stop_btn.config(state=tk.NORMAL)
        self.prompt_btn.config(state=tk.NORMAL)

        threading.Thread(target=self.run_async, args=(api_key,), daemon=True).start()

    def stop_music(self):
        if self.loop:
            asyncio.run_coroutine_threadsafe(self.cleanup(), self.loop)

        self.start_btn.config(state=tk.NORMAL)
        self.stop_btn.config(state=tk.DISABLED)
        self.prompt_btn.config(state=tk.DISABLED)

    def send_prompt(self):
        if not self.session:
            return

        text = self.prompt_entry.get().strip()
        if not text:
            return

        asyncio.run_coroutine_threadsafe(
            self.session.set_weighted_prompts(
                prompts=[{"text": text, "weight": 1.0}]
            ),
            self.loop
        )

    def run_async(self, api_key):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self.main(api_key))

    async def main(self, api_key):
        client = genai.Client(
            api_key=api_key,
            http_options={"api_version": "v1alpha"}
        )

        output_file = "lyria_output.wav"
        print(f"Starting stream... Saving to {output_file}")
        
        # Setup WAVE file
        self.wav_file = wave.open(output_file, "wb")
        self.wav_file.setnchannels(2)
        self.wav_file.setsampwidth(2) # 16-bit
        self.wav_file.setframerate(48000)

        try:
            async with client.aio.live.music.connect(
                model="models/lyria-realtime-exp"
            ) as session:
                self.session = session

                await session.set_weighted_prompts(
                    prompts=[{"text": self.prompt_entry.get(), "weight": 1.0}]
                )

                await session.set_music_generation_config(
                    config=types.LiveMusicGenerationConfig(bpm=100)
                )

                await session.play()
                print("Connection established. Waiting for audio chunks...")

                async for msg in session.receive():
                    if msg.server_content and msg.server_content.audio_chunks:
                        for chunk in msg.server_content.audio_chunks:
                            audio = chunk.data
                            self.wav_file.writeframes(audio)
                            print(f"Streaming: Received chunk of {len(audio)} bytes")
                    else:
                        # Some messages might be headers or metadata
                        pass
        except Exception as e:
            print(f"Streaming Error: {e}")
        finally:
            self.cleanup()

    def cleanup(self):
        if self.session:
            # We can't await in sync cleanup usually, but we keep state clean
            self.session = None

        if hasattr(self, 'wav_file') and self.wav_file:
            self.wav_file.close()
            self.wav_file = None
            print("WAV file closed.")

        if self.ffplay:
            try:
                self.ffplay.stdin.close()
                self.ffplay.terminate()
            except:
                pass
            self.ffplay = None


if __name__ == "__main__":
    root = tk.Tk()
    app = LyriaGUI(root)
    root.mainloop()
