#!/usr/bin/env python3
"""Reference server for imagine's tts_http backend.

This is not Qwen's HTTP API. imagine speaks imagine.tts_http.v1; this process
is the adapter. `--mock` returns a tiny WAV and never imports weights, so CI
and `scripts/e2e.sh` do not download a model. A real process imports `qwen_tts`
only when `--mock` is absent.

Official Qwen `non_streaming_mode=false` buffers the whole clip and then slices
the body. That is not incremental audio. This server reports `"streaming": false`
unless `--stream-chunks` is set, which yields PCM lines before `complete`.
"""

import argparse
import base64
import json
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def tiny_wav():
    pcm = b"\x00\x00\x01\x00"
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(pcm), b"WAVE",
        b"fmt ", 16, 1, 1, 8000, 16000, 2, 16,
        b"data", len(pcm),
    )
    return header + pcm


WAV = tiny_wav()
MOCK = True
STREAM_CHUNKS = False


def pcm_chunks():
    return (
        b'{"event":"meta","codec":"pcm_s16le","sample_rate_hz":8000,"channels":1}\n'
        b'{"event":"audio_chunk","data":"AAA="}\n'
        b'{"event":"audio_chunk","data":"AQA="}\n'
        b'{"event":"complete"}\n'
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def send_bytes(self, code, payload, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, code, obj):
        self.send_bytes(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/capabilities":
            return self.send_json(200, {
                "protocol": "imagine.tts_http.v1",
                "modes": ["speech", "voice_design", "voice_clone"],
                "streaming": STREAM_CHUNKS,
                "formats": ["wav"],
                "style": True,
            })
        if path == "/voices":
            return self.send_json(200, {"voices": ["default"]})
        if path == "/healthz":
            return self.send_json(200, {"ok": True, "mock": MOCK, "streaming": STREAM_CHUNKS})
        return self.send_json(404, {"error": {"message": self.path}})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        if path != "/generate":
            return self.send_json(404, {"error": {"message": self.path}})
        try:
            body = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            return self.send_json(400, {"error": {"message": "body is not JSON"}})
        if body.get("stream") and not STREAM_CHUNKS:
            return self.send_json(400, {"error": {"message": "this server is not incremental; streaming is false"}})
        if STREAM_CHUNKS and body.get("stream"):
            return self.send_bytes(200, pcm_chunks(), "application/x-ndjson")
        audio = synthesize(body)
        return self.send_json(200, {
            "audio": base64.b64encode(audio).decode(),
            "mime": "audio/wav",
            "sample_rate_hz": 8000,
            "channels": 1,
        })


def synthesize(body):
    if MOCK:
        return WAV
    # Imported only for a real run. The three entry points match the Qwen3-TTS
    # package; this file does not vendor the weights.
    from qwen_tts import Qwen3TTS

    mode = body.get("mode") or "speech"
    model = Qwen3TTS()
    if mode == "voice_design":
        wav = model.generate_voice_design(body.get("text") or "", body.get("style") or "")
    elif mode == "voice_clone":
        ref = body.get("reference_audio") or {}
        wav = model.generate_voice_clone(
            body.get("text") or "",
            base64.b64decode(ref.get("data") or ""),
            body.get("reference_text") or "",
        )
    else:
        wav = model.generate_custom_voice(body.get("text") or "", body.get("voice") or "default")
    return wav if isinstance(wav, (bytes, bytearray)) else WAV


def main():
    global MOCK, STREAM_CHUNKS
    parser = argparse.ArgumentParser(description="imagine tts_http reference server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8712)
    parser.add_argument("--mock", action="store_true", help="return a tiny WAV and do not import qwen_tts (default)")
    parser.add_argument("--real", action="store_true", help="import qwen_tts and run the local model")
    parser.add_argument("--stream-chunks", action="store_true", help="advertise real incremental PCM chunks")
    args = parser.parse_args()
    MOCK = not args.real
    STREAM_CHUNKS = args.stream_chunks
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"qwen3-tts listening on http://{args.host}:{args.port} mock={MOCK} streaming={STREAM_CHUNKS}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
