import sys
import json
import time
import threading
import yt_dlp
import traceback
import urllib.request
import subprocess
import os
from youtube_transcript_api import YouTubeTranscriptApi

# Explicitly add VLC to the DLL search path for Python 3.8+ on Windows
vlc_path = r"C:\Program Files\VideoLAN\VLC"
if os.path.exists(vlc_path):
    if hasattr(os, 'add_dll_directory'):
        os.add_dll_directory(vlc_path)
    os.environ['PYTHON_VLC_MODULE_PATH'] = vlc_path
    os.environ['PYTHON_VLC_LIB_PATH'] = os.path.join(vlc_path, "libvlc.dll")

import vlc

class YTPlayerBackend:
    def __init__(self):
        # Instantiate VLC headlessly and silently
        self.instance = vlc.Instance('--no-video', '--quiet')
        self.player = self.instance.media_player_new()
        self.keep_segments = []  # List of [start_sec, end_sec]
        self.current_segment_idx = 0
        self.ml_concised = False
        self.running = True
        self.monitor_thread = threading.Thread(target=self.monitor_loop, daemon=True)
        self.monitor_thread.start()

    def run_ml_analysis(self, transcript_list):
        text_parts = []
        for block in transcript_list:
            text_parts.append(f"[{block['start']:.1f}-{block['start'] + block['duration']:.1f}]: {block['text']}")
        
        full_text = '\n'.join(text_parts)
        if len(full_text) > 20000:
            full_text = full_text[:20000]
            
        system_prompt = "You are a YouTube audio editor. Analyze the transcript timestamps and identify only the 'core content' (skip intros, sponsors, generic rambling, and outros). Return a JSON array of start/end arrays to KEEP. Example: [[30.5, 450.0], [480.0, 1200.0]]. Do NOT return markdown, ONLY the JSON array."
        
        try:
            # Load Groq API key
            key_path = r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_keys.json"
            api_key = None
            if os.path.exists(key_path):
                with open(key_path, 'r') as f:
                    keys = json.load(f)
                    api_key = keys.get("groq")
            
            if not api_key:
                self.send({"event": "error", "message": "Groq API key not found in ai_api_keys.json"})
                return

            req_data = json.dumps({
                "model": "llama3-70b-8192",
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": full_text}
                ],
                "temperature": 0.1
            }).encode('utf-8')
            
            req = urllib.request.Request("https://api.groq.com/openai/v1/chat/completions", data=req_data, headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json"
            })
            
            with urllib.request.urlopen(req, timeout=30) as response:
                resp_json = json.loads(response.read().decode('utf-8'))
                output = resp_json['choices'][0]['message']['content']
                
            import re
            match = re.search(r'\[\s*\[.*?\]\s*\]', output.replace('\n', ''))
            if not match:
                match = re.search(r'\[.*\]', output.replace('\n', ''))
                
            if match:
                segments = json.loads(match.group(0))
                self.keep_segments = segments
                self.current_segment_idx = 0
                self.send({"event": "skipped_filler", "to": 0})
            else:
                self.send({"event": "error", "message": f"ML failed to produce JSON. Output: {output[:100]}"})
        except Exception as e:
            self.send({"event": "error", "message": f"Groq API error: {str(e)}"})

    def send(self, msg):
        sys.stdout.write(json.dumps(msg) + '\n')
        sys.stdout.flush()

    def get_music(self, query):
        if not query: return []
        MAX_DURATION = 3600 # 1 hour max
        ydl_opts = {
            'format': 'bestaudio/best',
            'quiet': True,
            'no_warnings': True,
            'extract_flat': True,
            'nocheckcertificate': True,
            'skip_download': True,
        }
        search_query = f"ytsearch10:{query} song audio podcast"
        songs = []
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                result = ydl.extract_info(search_query, download=False)
                if 'entries' in result:
                    for entry in result['entries']:
                        duration_sec = entry.get('duration')
                        if not duration_sec or duration_sec > MAX_DURATION:
                            continue
                        songs.append({
                            'title': entry.get('title'),
                            'id': entry.get('id'),
                            'duration': duration_sec
                        })
        except Exception as e:
            self.send({"event": "error", "message": str(e)})
        return songs

    def play(self, video_id, ml_concised=False):
        self.ml_concised = ml_concised
        self.keep_segments = []
        self.current_segment_idx = 0
        
        ydl_opts = {
            'format': 'bestaudio/best',
            'quiet': True,
            'no_warnings': True,
        }
        url = f"https://www.youtube.com/watch?v={video_id}"
        
        try:
            # 1. Fetch stream URL
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=False)
                stream_url = info['url']
            
            # 2. Start playback
            media = self.instance.media_new(stream_url)
            self.player.set_media(media)
            self.player.play()
            
            self.send({"event": "playing", "video_id": video_id})
            
            # 3. If ML Concised, fetch transcript and request ML segments
            if ml_concised:
                try:
                    transcript_list = YouTubeTranscriptApi.get_transcript(video_id)
                    self.send({"event": "transcript_ready", "message": "Analyzing transcript with ML..."})
                    self.run_ml_analysis(transcript_list)
                except Exception as e:
                    self.send({"event": "error", "message": f"No transcript available: {e}"})
                    self.ml_concised = False
        except Exception as e:
            self.send({"event": "error", "message": str(e)})

    def monitor_loop(self):
        while self.running:
            time.sleep(0.5)
            if not self.player.is_playing() or not self.ml_concised or not self.keep_segments:
                continue
                
            current_time = self.player.get_time() / 1000.0
            if current_time < 0: continue
            
            if self.current_segment_idx < len(self.keep_segments):
                seg_start, seg_end = self.keep_segments[self.current_segment_idx]
                if current_time > seg_end:
                    self.current_segment_idx += 1
                    if self.current_segment_idx < len(self.keep_segments):
                        next_start = self.keep_segments[self.current_segment_idx][0]
                        self.player.set_time(int(next_start * 1000))
                        self.send({"event": "skipped_filler", "to": next_start})
                    else:
                        self.player.stop()

    def run(self):
        while True:
            try:
                line = sys.stdin.readline()
                if not line: break
                req = json.loads(line)
                cmd = req.get("cmd")
                
                if cmd == "search":
                    res = self.get_music(req.get("query"))
                    self.send({"event": "search_results", "results": res})
                elif cmd == "play":
                    # Run play in a thread so we don't block stdin
                    threading.Thread(target=self.play, args=(req.get("video_id"), req.get("ml_concised", False))).start()
                elif cmd == "analyze_ml":
                    transcript_list = req.get("transcript", [])
                    threading.Thread(target=self.run_ml_analysis, args=(transcript_list,)).start()
                elif cmd == "set_ml_segments":
                    self.keep_segments = req.get("segments", [])
                    self.current_segment_idx = 0
                elif cmd == "pause":
                    self.player.set_pause(1)
                elif cmd == "resume":
                    self.player.set_pause(0)
                elif cmd == "seek":
                    offset = req.get("offset", 0)
                    cur = self.player.get_time()
                    if cur > 0:
                        self.player.set_time(int(cur + offset * 1000))
                elif cmd == "status":
                    self.send({
                        "event": "status",
                        "time": self.player.get_time() / 1000.0 if self.player.get_time() > 0 else 0,
                        "length": self.player.get_length() / 1000.0 if self.player.get_length() > 0 else 0,
                        "playing": self.player.is_playing(),
                        "ml_concised": self.ml_concised
                    })
            except Exception as e:
                self.send({"event": "error", "message": traceback.format_exc()})

if __name__ == '__main__':
    backend = YTPlayerBackend()
    backend.run()
