#!/usr/bin/env python3
"""Kokoro-82M as a local HTTP text-to-speech server (CPU, ONNX runtime).

    POST /tts   {"text": "...", "voice": "am_michael", "speed": 1.0,
                 "lang": "en-us", "out": "C:/path/to/write.wav"}
        -> audio/wav (24 kHz mono 16-bit PCM) when "out" is absent, or
        -> {"ok":true,"path":...,"bytes":N,"ms":T,"voice":...} when "out" names
           When "out" is given the wav is written ATOMICALLY (a .tmp then
           os.replace) and an empty `<out>.done` marker follows it, so a
           caller that spawned the request detached can poll for the marker
           instead of blocking on the response. A stale marker is removed
           before synthesis starts.
           a file the server should write instead (the caller keeps the bytes
           off the wire -- that is what a curl-only client wants).
        Errors are HTTP 4xx/5xx with a JSON body {"ok":false,"error":"..."}
        and NEVER a wav, so a client that checks the RIFF magic cannot be
        handed a plausible-looking failure.
    GET  /health -> {"ok":true,"engine":"kokoro-onnx","voices":[...],
                     "model":..., "sampleRate":24000, "synths":N, ...}
    GET  /voices -> the same list on its own.

Everything is stdlib plus `kokoro_onnx` (+ numpy, which it requires). No
framework: one ThreadingHTTPServer, one model loaded once at start-up, one
lock around `create()` because the onnx session is not documented as
thread-safe and two concurrent synths on a CPU are slower than one anyway.

Command line:
    python server.py --root <dir>            # <dir>/kokoro-v1.0.onnx + voices-v1.0.bin
                     [--port 6971] [--host 127.0.0.1]
                     [--model PATH] [--voices PATH]
    python server.py --root <dir> --bench "twelve word sentence ..." [--n 5]
                     # no HTTP: load, synthesise n times, print first/steady ms
"""
import argparse
import io
import json
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_NAME = "kokoro-v1.0.onnx"
VOICES_NAME = "voices-v1.0.bin"
SAMPLE_RATE = 24000


def default_root():
    env = os.environ.get("AOWLSPT_KOKORO_ROOT")
    if env:
        return env
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "aowlspt", "kokoro")


def write_out_atomic(out, data):
    """Write `data` to `out` and then an empty `<out>.done` marker.

    The wav goes to `<out>.tmp` first and is `os.replace`d into place, so a
    poller that is watching the path NEVER sees a half-written RIFF file; the
    `.done` marker is written only after the rename, so its existence means
    "the wav at `out` is complete". A stale marker from an earlier synthesis
    of the same text is removed FIRST -- otherwise a caller that spawned this
    request would read the previous run's marker and take a truncated file
    for a finished one. Raises OSError; the caller reports it.
    """
    d = os.path.dirname(out)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    done = out + ".done"
    try:
        os.remove(done)
    except OSError:
        pass
    tmp = out + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, out)
    with open(done, "wb"):
        pass


def wav_bytes(samples, rate):
    """float32 [-1,1] -> 16-bit PCM RIFF, via the stdlib so a missing
    `soundfile` can never turn into a silent failure at synth time."""
    import numpy as np
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


class Engine(object):
    def __init__(self, model_path, voices_path):
        self.model_path = model_path
        self.voices_path = voices_path
        self.lock = threading.Lock()
        self.synths = 0
        self.total_ms = 0.0
        self.last_ms = 0.0
        self.first_ms = 0.0
        self.load_ms = 0.0
        self.last_first_chunk_ms = 0.0
        t0 = time.perf_counter()
        from kokoro_onnx import Kokoro
        self.k = Kokoro(model_path, voices_path)
        self.load_ms = (time.perf_counter() - t0) * 1000.0
        self.voices = sorted(self.k.get_voices())

    def synth(self, text, voice, speed, lang):
        if voice not in self.voices:
            raise ValueError("unknown voice %r (have %d: %s)"
                             % (voice, len(self.voices), " ".join(self.voices)))
        t0 = time.perf_counter()
        with self.lock:
            samples, rate = self.k.create(text, voice=voice, speed=speed, lang=lang)
        ms = (time.perf_counter() - t0) * 1000.0
        self.synths += 1
        self.total_ms += ms
        self.last_ms = ms
        if self.synths == 1:
            self.first_ms = ms
        return wav_bytes(samples, rate), rate, ms

    def stats(self):
        return {
            "ok": True,
            "engine": "kokoro-onnx",
            "model": self.model_path,
            "voicesFile": self.voices_path,
            "voices": self.voices,
            "sampleRate": SAMPLE_RATE,
            "loadMs": round(self.load_ms, 1),
            "synths": self.synths,
            "firstMs": round(self.first_ms, 1),
            "lastMs": round(self.last_ms, 1),
            "meanMs": round(self.total_ms / self.synths, 1) if self.synths else 0.0,
            "lastFirstChunkMs": round(self.last_first_chunk_ms or 0.0, 1),
            "streaming": "POST /tts/stream -> chunked audio/pcm s16le 24 kHz, "
                         "one chunk per SENTENCE (create_stream batches on ~510 "
                         "phonemes and gave one chunk for 4 sentences)",
            "pid": os.getpid(),
        }


ENGINE = None
STARTED = time.time()


class Handler(BaseHTTPRequestHandler):
    server_version = "aowlspt-kokoro/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def _json(self, code, doc):
        body = json.dumps(doc).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/", "/voices"):
            doc = ENGINE.stats()
            doc["uptimeS"] = round(time.time() - STARTED, 1)
            if self.path == "/voices":
                doc = {"ok": True, "voices": doc["voices"]}
            self._json(200, doc)
        else:
            self._json(404, {"ok": False, "error": "no such route: " + self.path})

    def _stream(self, req):
        """POST /tts/stream: raw 16-bit PCM, chunked transfer, ONE CHUNK PER
        SENTENCE, headers sent with the FIRST chunk so a client's
        time-to-first-byte IS time-to-first-audio. The complete wav is written
        to `out` afterwards when given, so the file cache still fills.

        MEASURED 2026-09-07: `Kokoro.create_stream` batches on PHONEME COUNT
        (~510 tokens), so a 4-sentence, 39-word line came back as ONE chunk at
        3.1 s -- no earlier than /tts. Splitting on sentence ends ourselves and
        calling `create` per sentence gets the first sentence out at ~1 s."""
        import re
        text = str(req.get("text", "")).strip()
        if not text:
            self._json(400, {"ok": False, "error": "empty text"})
            return
        voice = str(req.get("voice") or "am_michael")
        try:
            speed = max(0.5, min(2.0, float(req.get("speed", 1.0))))
        except (TypeError, ValueError):
            self._json(400, {"ok": False, "error": "speed is not a number"})
            return
        lang = str(req.get("lang") or "en-us")
        out = req.get("out")
        if voice not in ENGINE.voices:
            self._json(400, {"ok": False, "error": "unknown voice %r" % voice})
            return
        import numpy as np
        t0 = time.perf_counter()
        first_ms = None
        pcm_parts = []
        started = False
        parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()] or [text]
        try:
            with ENGINE.lock:
                for sent in parts:
                    samples, rate = ENGINE.k.create(sent, voice=voice, speed=speed, lang=lang)
                    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
                    if not started:
                        first_ms = (time.perf_counter() - t0) * 1000.0
                        self.send_response(200)
                        self.send_header("Content-Type", "audio/pcm")
                        self.send_header("X-Sample-Rate", str(rate))
                        self.send_header("X-Channels", "1")
                        self.send_header("X-Bits", "16")
                        self.send_header("X-First-Chunk-Ms", "%.1f" % first_ms)
                        self.send_header("Transfer-Encoding", "chunked")
                        self.end_headers()
                        started = True
                    self.wfile.write(b"%x\r\n" % len(pcm) + pcm + b"\r\n")
                    self.wfile.flush()
                    pcm_parts.append(pcm)
        except Exception as e:  # noqa: BLE001
            if not started:
                self._json(500, {"ok": False, "error": "stream failed: %r" % (e,)})
                return
            raise
        if not started:
            self._json(500, {"ok": False, "error": "kokoro produced no chunks"})
            return
        self.wfile.write(b"0\r\n\r\n")
        total_ms = (time.perf_counter() - t0) * 1000.0
        ENGINE.synths += 1
        ENGINE.total_ms += total_ms
        ENGINE.last_ms = total_ms
        ENGINE.last_first_chunk_ms = first_ms
        if out:
            all_pcm = b"".join(pcm_parts)
            buf = io.BytesIO()
            with wave.open(buf, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(SAMPLE_RATE)
                w.writeframes(all_pcm)
            try:
                write_out_atomic(out, buf.getvalue())
            except OSError as e:
                sys.stderr.write("could not write %s: %s\n" % (out, e))
        sys.stderr.write("stream %s: first chunk %.0f ms, total %.0f ms, %d chunks\n"
                         % (voice, first_ms, total_ms, len(pcm_parts)))

    def do_POST(self):
        if self.path not in ("/tts", "/tts/stream"):
            self._json(404, {"ok": False, "error": "no such route: " + self.path})
            return
        if self.path == "/tts/stream":
            try:
                n = int(self.headers.get("Content-Length") or 0)
                req = json.loads((self.rfile.read(n) if n > 0 else b"").decode("utf-8") or "{}")
            except Exception as e:  # noqa: BLE001
                self._json(400, {"ok": False, "error": "bad JSON body: %s" % e})
                return
            self._stream(req)
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n > 0 else b""
            req = json.loads(raw.decode("utf-8") or "{}")
        except Exception as e:  # noqa: BLE001
            self._json(400, {"ok": False, "error": "bad JSON body: %s" % e})
            return
        text = str(req.get("text", "")).strip()
        if not text:
            self._json(400, {"ok": False, "error": "empty text"})
            return
        voice = str(req.get("voice") or "am_michael")
        try:
            speed = float(req.get("speed", 1.0))
        except (TypeError, ValueError):
            self._json(400, {"ok": False, "error": "speed is not a number"})
            return
        speed = max(0.5, min(2.0, speed))
        lang = str(req.get("lang") or "en-us")
        out = req.get("out")
        try:
            wav, rate, ms = ENGINE.synth(text, voice, speed, lang)
        except ValueError as e:
            self._json(400, {"ok": False, "error": str(e)})
            return
        except Exception as e:  # noqa: BLE001
            self._json(500, {"ok": False, "error": "synth failed: %r" % (e,)})
            return
        if out:
            try:
                write_out_atomic(out, wav)
            except OSError as e:
                self._json(500, {"ok": False, "error": "could not write %s: %s" % (out, e)})
                return
            self._json(200, {"ok": True, "path": out, "bytes": len(wav),
                             "ms": round(ms, 1), "voice": voice, "speed": speed,
                             "sampleRate": rate})
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-Synth-Ms", "%.1f" % ms)
        self.send_header("X-Voice", voice)
        self.end_headers()
        self.wfile.write(wav)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=default_root(),
                    help="directory holding %s and %s" % (MODEL_NAME, VOICES_NAME))
    ap.add_argument("--model", default=None)
    ap.add_argument("--voices", default=None)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6971)
    ap.add_argument("--bench", default=None, help="synthesise this text N times and exit")
    ap.add_argument("--n", type=int, default=5)
    ap.add_argument("--voice", default="am_michael")
    ap.add_argument("--out", default=None, help="with --bench: write the last wav here")
    a = ap.parse_args()
    model = a.model or os.path.join(a.root, MODEL_NAME)
    voices = a.voices or os.path.join(a.root, VOICES_NAME)
    for p in (model, voices):
        if not os.path.isfile(p):
            sys.stderr.write("MISSING %s -- run tools/kokoro/setup.ps1\n" % p)
            sys.exit(2)
    global ENGINE
    ENGINE = Engine(model, voices)
    sys.stderr.write("kokoro loaded in %.0f ms: %d voices from %s\n"
                     % (ENGINE.load_ms, len(ENGINE.voices), voices))
    if a.bench:
        times = []
        wav = b""
        rate = SAMPLE_RATE
        for i in range(max(1, a.n)):
            wav, rate, ms = ENGINE.synth(a.bench, a.voice, 1.0, "en-us")
            times.append(ms)
            print("synth %d: %.0f ms, %d bytes (%.2f s audio)"
                  % (i + 1, ms, len(wav), (len(wav) - 44) / 2.0 / rate))
        if a.out:
            with open(a.out, "wb") as f:
                f.write(wav)
        steady = times[1:] or times
        print("BENCH voice=%s words=%d first=%.0f ms steady(mean of %d)=%.0f ms min=%.0f max=%.0f"
              % (a.voice, len(a.bench.split()), times[0], len(steady),
                 sum(steady) / len(steady), min(steady), max(steady)))
        return
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    sys.stderr.write("listening on http://%s:%d  (POST /tts, GET /health)\n"
                     % (a.host, a.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
