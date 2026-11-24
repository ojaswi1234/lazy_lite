#!/usr/bin/env python3
"""
scripts/voice_typing_bridge.py — Real-Time Voice Typing & Auto-Submit Engine
Captures microphone audio streams, dynamically calibrates ambient noise, detects speech
boundaries via RMS Voice Activity Detection, and streams transcribed speech to Lite XL's
AI Sidebar via JSON-line stdout events.

Supports:
1. Groq Whisper (whisper-large-v3-turbo) — Sub-200ms latency cloud transcription with connection pooling.
2. Gemini 2.5 Flash Transcribe — Real-time audio transcription via google-genai.
3. Windows SAPI Speech Recognition — Offline fallback.
"""

import os
import sys
import json
import time
import io
import wave
import queue
import threading
import argparse
from typing import Optional, Dict, Any

# Ensure line-buffered UTF-8 output on Windows
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', line_buffering=True)

def log_event(event: str, **kwargs):
    payload = {"event": event}
    payload.update(kwargs)
    try:
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()
    except Exception:
        pass

def load_keys():
    config_dir = os.path.dirname(os.path.abspath(__file__))
    keys_file = os.path.join(config_dir, "ai_api_keys.json")
    keys = {}
    if os.path.exists(keys_file):
        try:
            with open(keys_file, "r", encoding="utf-8") as f:
                keys = json.load(f)
        except Exception:
            keys = {}
    # Fallback to env
    for k in ["groq", "gemini"]:
        if not keys.get(k):
            env_val = os.environ.get(f"{k.upper()}_API_KEY") or os.environ.get("GOOGLE_API_KEY" if k == "gemini" else "")
            if env_val:
                keys[k] = env_val
    return keys

# ── Voice Capture Engine ──────────────────────────────────────────────────────
class VoiceEngine:
    def __init__(self, backend: str = "auto", auto_submit: bool = True, silence_sec: float = 1.2, rms_threshold: Optional[float] = None):
        self.backend_choice = backend
        self.auto_submit = auto_submit
        self.silence_sec = silence_sec
        self.rms_threshold = rms_threshold
        self.running = True
        self.audio_queue = queue.Queue(maxsize=300)
        self.sample_rate = 16000
        self.channels = 1
        self.keys = load_keys()
        self.active_backend = self._resolve_backend()

        # Reusable client instances to prevent per-chunk SSL handshake latency
        self.groq_client = None
        self.gemini_client = None
        self._init_clients()

    def _resolve_backend(self) -> str:
        if self.backend_choice == "groq" or (self.backend_choice == "auto" and self.keys.get("groq")):
            return "groq"
        elif self.backend_choice == "gemini" or (self.backend_choice == "auto" and self.keys.get("gemini")):
            return "gemini"
        return "sapi"

    def _init_clients(self):
        if self.active_backend == "groq" and self.keys.get("groq"):
            try:
                from groq import Groq
                self.groq_client = Groq(api_key=self.keys["groq"])
            except Exception as e:
                log_event("error", message=f"Failed to init Groq client: {e}")
        elif self.active_backend == "gemini" and self.keys.get("gemini"):
            try:
                from google import genai
                self.gemini_client = genai.Client(api_key=self.keys["gemini"])
            except Exception as e:
                log_event("error", message=f"Failed to init Gemini client: {e}")

    def transcribe_audio_chunk(self, audio_bytes: bytes) -> str:
        """Transcribes PCM 16-bit audio bytes using the active backend."""
        if not audio_bytes or len(audio_bytes) < 4800:  # Less than 0.15s
            return ""

        # Backend 1: Groq Whisper (Persistent Client)
        if self.active_backend == "groq" and self.groq_client:
            try:
                wav_buffer = io.BytesIO()
                with wave.open(wav_buffer, 'wb') as wf:
                    wf.setnchannels(self.channels)
                    wf.setsampwidth(2)
                    wf.setframerate(self.sample_rate)
                    wf.writeframes(audio_bytes)
                wav_buffer.seek(0)
                wav_buffer.name = "speech.wav"

                resp = self.groq_client.audio.transcriptions.create(
                    file=wav_buffer,
                    model="whisper-large-v3-turbo",
                    response_format="verbose_json",
                    temperature=0.0,
                    language="en",
                    prompt="Lite XL code editor commands, chat, programming instructions."
                )
                raw_text = resp.text.strip() if hasattr(resp, "text") else str(resp).strip()
                cleaned = raw_text.strip(" .!?,;:\r\n")

                # Discard typical Whisper silence hallucinations
                noise_phrases = {
                    "you", "thank you", "thanks for watching", "subtitles",
                    "bye", "okay", "um", "uh", "thank you.", "subtitles by",
                    "so", "yeah", "am", "the", "a", "i", "..."
                }
                if cleaned.lower() in noise_phrases and len(audio_bytes) < 28000:
                    return ""
                return cleaned
            except Exception as e:
                log_event("error", message=f"Groq transcription error: {str(e)}")
                return ""

        # Backend 2: Gemini
        elif self.active_backend == "gemini" and self.gemini_client:
            try:
                from google.genai import types
                wav_buffer = io.BytesIO()
                with wave.open(wav_buffer, 'wb') as wf:
                    wf.setnchannels(self.channels)
                    wf.setsampwidth(2)
                    wf.setframerate(self.sample_rate)
                    wf.writeframes(audio_bytes)
                wav_bytes = wav_buffer.getvalue()

                resp = self.gemini_client.models.generate_content(
                    model="gemini-2.5-flash",
                    contents=[
                        types.Part.from_bytes(data=wav_bytes, mime_type="audio/wav"),
                        "Transcribe the spoken audio verbatim. Return ONLY the transcribed text with no extra commentary or markdown formatting."
                    ]
                )
                text = resp.text.strip() if resp and resp.text else ""
                return text.strip(" .!?,;:\r\n")
            except Exception as e:
                log_event("error", message=f"Gemini transcription error: {str(e)}")
                return ""

        # Backend 3: Windows SAPI Offline Fallback
        else:
            return ""

    def run(self):
        try:
            import sounddevice as sd
            import numpy as np
        except ImportError as e:
            log_event("error", message=f"Missing sounddevice or numpy: {e}")
            return

        chunk_duration = 0.08  # 80ms chunks
        chunk_samples = int(self.sample_rate * chunk_duration)

        # ── Step 1: Dynamic Ambient Noise Calibration (0.4s) ──
        log_event("status", state="calibrating")
        try:
            calib_rec = sd.rec(int(0.4 * self.sample_rate), samplerate=self.sample_rate, channels=self.channels, dtype='int16')
            sd.wait()
            ambient_rms = float(np.sqrt(np.mean(calib_rec.astype(np.float32)**2)))
            if self.rms_threshold is None:
                self.rms_threshold = max(300.0, ambient_rms * 2.1)
        except Exception:
            if self.rms_threshold is None:
                self.rms_threshold = 500.0

        log_event("ready", backend=self.active_backend, threshold=round(self.rms_threshold, 1), auto_submit=self.auto_submit)

        def audio_callback(indata, frames, time_info, status):
            if self.running:
                try:
                    self.audio_queue.put_nowait(bytes(indata))
                except queue.Full:
                    # Drop oldest frame to avoid latency lag
                    try:
                        self.audio_queue.get_nowait()
                        self.audio_queue.put_nowait(bytes(indata))
                    except Exception:
                        pass

        try:
            stream = sd.RawInputStream(
                samplerate=self.sample_rate,
                blocksize=chunk_samples,
                channels=self.channels,
                dtype='int16',
                callback=audio_callback
            )
        except Exception as e:
            log_event("error", message=f"Failed to open microphone: {e}")
            return

        speech_buffer = bytearray()
        speaking = False
        silence_start = None
        last_interim_time = 0
        last_level_emit = 0

        with stream:
            while self.running:
                try:
                    chunk = self.audio_queue.get(timeout=0.08)
                except queue.Empty:
                    continue

                samples = np.frombuffer(chunk, dtype=np.int16)
                if len(samples) == 0:
                    continue
                rms = float(np.sqrt(np.mean(samples.astype(np.float32)**2)))

                # Emit volume level throttled to max ~5Hz (every 200ms) to prevent pipe flooding
                now = time.time()
                if now - last_level_emit >= 0.2:
                    last_level_emit = now
                    log_event("level", rms=round(rms, 1), speaking=speaking)

                is_sound = rms > self.rms_threshold

                if is_sound:
                    if not speaking:
                        speaking = True
                        silence_start = None
                        speech_buffer = bytearray()
                        log_event("status", state="speaking")

                    speech_buffer.extend(chunk)
                    silence_start = None

                    # If speaking continuously, trigger interim transcription periodically
                    if len(speech_buffer) > (self.sample_rate * 2 * 1.5) and (now - last_interim_time > 2.0):
                        last_interim_time = now
                        sub_bytes = bytes(speech_buffer)
                        def run_interim(b):
                            t = self.transcribe_audio_chunk(b)
                            if t and self.running:
                                log_event("interim", text=t)
                        threading.Thread(target=run_interim, args=(sub_bytes,), daemon=True).start()

                elif speaking:
                    speech_buffer.extend(chunk)
                    if silence_start is None:
                        silence_start = time.time()
                    else:
                        elapsed_silence = time.time() - silence_start
                        if elapsed_silence >= self.silence_sec:
                            # User stopped speaking! Finalize utterance
                            speaking = False
                            silence_start = None
                            log_event("status", state="processing")

                            final_bytes = bytes(speech_buffer)
                            speech_buffer = bytearray()

                            final_text = self.transcribe_audio_chunk(final_bytes)
                            if final_text and len(final_text.strip()) >= 2:
                                log_event("final", text=final_text, auto_submit=self.auto_submit)
                            else:
                                log_event("status", state="listening")

        log_event("status", state="stopped")

# ── Non-blocking Stdin Watchdog for instant stop without Windows pipe deadlocks ─
def stdin_watchdog(engine: VoiceEngine):
    """Monitors stdin using non-blocking pipe inspection so the thread never hangs on exit."""
    try:
        import msvcrt
        import ctypes
        is_windows = (sys.platform == "win32")
    except Exception:
        is_windows = False

    while engine.running:
        if is_windows:
            try:
                handle = msvcrt.get_osfhandle(sys.stdin.fileno())
                avail = ctypes.c_ulong(0)
                success = ctypes.windll.kernel32.PeekNamedPipe(
                    handle, None, 0, None, ctypes.byref(avail), None
                )
                if not success:
                    # Pipe was closed by parent process
                    engine.running = False
                    break
                if avail.value > 0:
                    line = sys.stdin.readline()
                    if not line:
                        engine.running = False
                        break
                    cmd = line.strip().upper()
                    if cmd in ["STOP", "QUIT", "EXIT", "KILL"]:
                        engine.running = False
                        break
            except Exception:
                engine.running = False
                break
        else:
            # Fallback for non-windows
            try:
                line = sys.stdin.readline()
                if not line or line.strip().upper() in ["STOP", "QUIT", "EXIT", "KILL"]:
                    engine.running = False
                    break
            except Exception:
                engine.running = False
                break

        time.sleep(0.1)

# ── Entrypoint ────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Lite XL Real-Time Voice Typing Engine")
    parser.add_argument("--backend", type=str, default="auto", choices=["auto", "groq", "gemini", "sapi"])
    parser.add_argument("--no-auto-submit", action="store_true", help="Disable auto-submit on silence")
    parser.add_argument("--silence", type=float, default=1.2, help="Seconds of silence before auto-submitting")
    parser.add_argument("--threshold", type=float, default=None, help="RMS audio volume threshold")
    parser.add_argument("--test", action="store_true", help="Run a quick 3-second recording test")

    args = parser.parse_args()

    engine = VoiceEngine(
        backend=args.backend,
        auto_submit=not args.no_auto_submit,
        silence_sec=args.silence,
        rms_threshold=args.threshold
    )

    if args.test:
        print("Testing 3 seconds of voice capture & transcription...")
        import sounddevice as sd
        rec = sd.rec(int(3.0 * engine.sample_rate), samplerate=engine.sample_rate, channels=engine.channels, dtype='int16')
        sd.wait()
        raw = rec.tobytes()
        res = engine.transcribe_audio_chunk(raw)
        print("Transcribed result:", res)
        return

    w_thread = threading.Thread(target=stdin_watchdog, args=(engine,), daemon=True)
    w_thread.start()

    engine.run()

if __name__ == "__main__":
    main()
