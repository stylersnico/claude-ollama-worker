#!/usr/bin/env python3
"""ollama-logproxy - transparent HTTP proxy 127.0.0.1:11435 -> Ollama :11434.
Logs every generation request (last message sent) and the generated answer to
~/.local/state/local-worker/exchanges.jsonl."""
import http.client, json, os, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UP = ("127.0.0.1", 11434)
LISTEN = ("127.0.0.1", int(os.environ.get("LOGPROXY_PORT", 11435)))
STATE = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "local-worker")
os.makedirs(STATE, exist_ok=True)
LOG = os.path.join(STATE, "exchanges.jsonl"); lock = threading.Lock()

def text_of(c):
    if isinstance(c, str): return c
    if isinstance(c, list):
        out = []
        for b in c:
            if not isinstance(b, dict): continue
            if b.get("type") == "text": out.append(b.get("text", ""))
            elif b.get("type") == "tool_result": out.append("[tool_result] " + text_of(b.get("content")))
            elif b.get("type") == "tool_use": out.append(f"[tool_use {b.get('name')}] " + json.dumps(b.get("input"))[:300])
        return "\n".join(out)
    return ""

def write(rec):
    with lock, open(LOG, "a", encoding="utf-8") as f: f.write(json.dumps(rec, ensure_ascii=False) + "\n")

def parse_response(raw):
    """Extract generated text from an Anthropic SSE stream, Ollama NDJSON or plain JSON."""
    out = []
    for line in raw.decode(errors="ignore").splitlines():
        line = line.removeprefix("data:").strip()
        if not line.startswith("{"): continue
        try: e = json.loads(line)
        except Exception: continue
        d = e.get("delta") or {}
        if d.get("type") == "text_delta": out.append(d.get("text", ""))
        elif d.get("type") == "input_json_delta": out.append(d.get("partial_json", ""))
        elif e.get("type") == "content_block_start" and (e.get("content_block") or {}).get("type") == "tool_use":
            out.append(f"\n[tool_use {e['content_block'].get('name')}] ")
        elif "message" in e and isinstance(e["message"], dict) and "content" in e["message"] and e.get("type") is None:
            out.append(text_of(e["message"]["content"]))
        elif "response" in e: out.append(e["response"])
        elif e.get("type") == "message": out.append(text_of(e.get("content")))
    return "".join(out)

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def proxy(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        req = {}
        try: req = json.loads(body) if body else {}
        except Exception: pass
        gen = isinstance(req, dict) and ("messages" in req or "prompt" in req)
        t0 = time.time()
        conn = http.client.HTTPConnection(*UP, timeout=3600)
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
        conn.request(self.command, self.path, body=body or None, headers=hdrs)
        r = conn.getresponse()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"): self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        captured = bytearray()
        while chunk := r.read1(65536):
            if gen: captured += chunk
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk)); self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        if gen:
            msgs = req.get("messages") or []
            last = text_of(msgs[-1].get("content")) if msgs else req.get("prompt", "")
            write({"ts": time.strftime("%H:%M:%S"), "path": self.path, "model": req.get("model"),
                   "n_msgs": len(msgs), "dur": round(time.time() - t0, 1), "status": r.status,
                   "request": last[:4000], "response": parse_response(bytes(captured))[:4000]})
    do_GET = do_POST = do_HEAD = do_DELETE = proxy

if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, H).serve_forever()
