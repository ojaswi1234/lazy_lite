import sqlite3
import json
import os
import math
import urllib.request
import urllib.parse
from typing import List

# Use a purely math-based cosine similarity instead of heavy libraries
def cosine_similarity(v1: List[float], v2: List[float]) -> float:
    dot_product = sum(a * b for a, b in zip(v1, v2))
    magnitude1 = math.sqrt(sum(a * a for a in v1))
    magnitude2 = math.sqrt(sum(b * b for b in v2))
    if magnitude1 * magnitude2 == 0:
        return 0
    return dot_product / (magnitude1 * magnitude2)

class MicroMemory:
    def __init__(self, db_path: str):
        self.db_path = db_path
        self._init_db()
        self.dim = 384
        
    def _init_db(self):
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute('''CREATE TABLE IF NOT EXISTS sacred_memory
                     (id INTEGER PRIMARY KEY AUTOINCREMENT, 
                      fact TEXT, 
                      vector TEXT)''')
        conn.commit()
        conn.close()

    def _get_embedding(self, text: str) -> List[float]:
        # Look for GEMINI key since it's free.
        config_dir = os.path.dirname(os.path.abspath(__file__))
        keys_file = os.path.join(config_dir, "ai_api_keys.json")
        api_key = None
        if os.path.exists(keys_file):
            with open(keys_file, "r") as f:
                keys = json.load(f)
                api_key = keys.get("gemini")
        
        if api_key:
            url = f"https://generativelanguage.googleapis.com/v1beta/models/text-embedding-004:embedContent?key={api_key}"
            data = json.dumps({"model": "models/text-embedding-004", "content": {"parts": [{"text": text}]}}).encode('utf-8')
            req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(req) as response:
                    res = json.loads(response.read().decode())
                    vec = res['embedding']['values']
                    return vec[:256]
            except Exception as e:
                print(f"Embedding error: {e}")
                return [0.0] * 256
        else:
            return [0.0] * 256

    def remember(self, fact: str):
        vec = self._get_embedding(fact)
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute("INSERT INTO sacred_memory (fact, vector) VALUES (?, ?)", (fact, json.dumps(vec)))
        conn.commit()
        conn.close()
        return "Fact committed to Sacred Memory."

    def recall(self, query: str, top_k: int = 3) -> str:
        query_vec = self._get_embedding(query)
        if not any(query_vec): return ""
        
        conn = sqlite3.connect(self.db_path)
        c = conn.cursor()
        c.execute("SELECT fact, vector FROM sacred_memory")
        rows = c.fetchall()
        conn.close()
        
        results = []
        for fact, vec_str in rows:
            vec = json.loads(vec_str)
            sim = cosine_similarity(query_vec, vec)
            results.append((sim, fact))
            
        results.sort(key=lambda x: x[0], reverse=True)
        top_facts = [fact for sim, fact in results[:top_k] if sim > 0.4]
        
        if top_facts:
            return "SACRED MEMORY RECALLED:\\n- " + "\\n- ".join(top_facts)
        return ""
