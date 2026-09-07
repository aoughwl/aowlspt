#!/usr/bin/env python3
"""Coqui XTTS-v2 as a local HTTP text-to-speech server on CUDA, with voice
CLONING from a reference wav and TRUE chunked streaming. Same contract as
tools/kokoro/server.py and tools/chatterbox/server.py:

    GET  /health        -> {"ok":true,"engine":"xtts-v2","device":"cuda","voices":[stems],
                            "voicesDir",...,"sampleRate":24000,"loadMs","synths","firstMs",
                            "lastMs","meanMs","lastFirstChunkMs","licence"}
    GET  /voices        -> {"ok":true,"voices":[stems]}
    POST /tts           {"text","voice":"<stem>","yell":false,"speed":1.0,"temperature":0.75,
                         "lang":"en"[,"out":path]}
                        -> audio/wav 24 kHz mono 16-bit, or with "out": the wav is written
                           there PLUS an "<out>.done" marker, and the answer is
                           {"ok":true,"path","bytes","ms","ref","yell"}.
    POST /tts/stream    same body -> Transfer-Encoding: chunked, Content-Type: audio/pcm
                        (s16le, X-Sample-Rate: 24000). Chunks come out of
                        Xtts.inference_stream every `stream_chunk_size` (20) GPT tokens --
                        the FIRST chunk of a 13-word sentence lands ~0.5 s after the request
                        on an RTX 2060 SUPER (measured 2026-09-07), i.e. before the sentence
                        is finished. Headers go out WITH the first chunk. With "out" the
                        complete wav (+ .done) is written when the stream ends.
    Errors are always JSON {"ok":false,"error":...} with a 4xx/5xx, never a wav.

A voice is `<stem>.wav` in --voices-dir (default mods/basement/data/voices),
rescanned on every request; its conditioning latents are cached per (path,
mtime). An unknown stem is a 400 -- there is no built-in voice in XTTS, so
falling back silently would clone the wrong person.

`yell`: XTTS has no emotion/energy control, so a yelled line is post-processed:
+6 dB gain, +4 dB RBJ high-shelf at 3 kHz, tanh soft clip (the same `yellify`
that produced the F5/XTTS shouted samples). The response says so in "yell".

LICENCE: XTTS-v2 weights are under the Coqui Public Model License (CPML),
NON-COMMERCIAL. Fine for a private mod; say so before shipping anything paid.

Command line:
    python server.py [--root DIR] [--voices-dir DIR] [--port 6976] [--host 127.0.0.1]
                     [--device cuda] [--chunk 20]
    python server.py --bench "sentence" [--n 4] [--voice stem]   # no HTTP
"""
import argparse
import io
import json
import os
import re
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SAMPLE_RATE = 24000
MODEL_ID = "tts_models/multilingual/multi-dataset/xtts_v2"


def default_root():
    env = os.environ.get("AOWLSPT_XTTS_ROOT")
    if env:
        return env
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "aowlspt", "xtts")


def default_voices_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.path.join(here, "..", "..", "mods", "basement", "data", "voices"),
                 os.path.join(here, "voices")):
        if os.path.isdir(cand):
            return os.path.normpath(cand)
    return os.path.normpath(os.path.join(here, "..", "..", "mods", "basement", "data", "voices"))


def high_shelf(x, sr, f0=3000.0, gain_db=4.0, q=0.7071):
    import numpy as np
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2 * np.pi * f0 / sr
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    sa = 2 * np.sqrt(A) * alpha
    b = np.array([A * ((A + 1) + (A - 1) * cw + sa), -2 * A * ((A - 1) + (A + 1) * cw),
                  A * ((A + 1) + (A - 1) * cw - sa)])
    a0 = (A + 1) - (A - 1) * cw + sa
    a = np.array([a0, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sa])
    b, a = b / a0, a / a0
    try:
        from scipy.signal import lfilter
        return lfilter(b, a, x.astype(np.float64))
    except ImportError:
        y = np.zeros_like(x, dtype=np.float64)
        x1 = x2 = y1 = y2 = 0.0
        for i, xi in enumerate(x.astype(np.float64)):
            yi = b[0] * xi + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            y[i] = yi
            x2, x1, y2, y1 = x1, xi, y1, yi
        return y


def yellify(samples, sr):
    import numpy as np
    x = np.asarray(samples, dtype=np.float64) * 2.0
    x = high_shelf(x, sr)
    x = np.tanh(x * 1.2) / np.tanh(1.2)
    return np.clip(x, -1.0, 1.0).astype(np.float32)


def pcm16(samples):
    import numpy as np
    return (np.clip(np.asarray(samples, dtype=np.float32), -1.0, 1.0) * 32767.0).astype("<i2").tobytes()


def wav_from_pcm(pcm, rate):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def write_out(out, wav):
    """Write the wav and the `<out>.done` marker; the marker is written LAST so a
    reader that sees it can trust the wav is complete."""
    d = os.path.dirname(out)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    tmp = out + ".part"
    with open(tmp, "wb") as f:
        f.write(wav)
    os.replace(tmp, out)
    with open(out + ".done", "w") as f:
        f.write("%d\n" % len(wav))


class Engine(object):
    def __init__(self, root, voices_dir, device, chunk):
        self.root = root
        self.voices_dir = voices_dir
        self.device = device
        self.chunk = chunk
        self.lock = threading.Lock()
        self.synths = 0
        self.total_ms = 0.0
        self.last_ms = 0.0
        self.first_ms = 0.0
        self.last_first_chunk_ms = 0.0
        self.cond = {}  # abs path -> (mtime, latent, embedding)
        os.environ.setdefault("COQUI_TOS_AGREED", "1")
        os.environ.setdefault("TTS_HOME", root)
        t0 = time.perf_counter()
        import torch
        from TTS.api import TTS
        self.torch = torch
        self.tts = TTS(MODEL_ID).to(device)
        self.model = self.tts.synthesizer.tts_model
        self.load_ms = (time.perf_counter() - t0) * 1000.0
        self.gpu = torch.cuda.get_device_name(0) if device.startswith("cuda") and torch.cuda.is_available() else ""

    def voices(self):
        try:
            names = [f for f in os.listdir(self.voices_dir) if f.lower().endswith(".wav")]
        except OSError:
            names = []
        return sorted(os.path.splitext(f)[0] for f in names)

    def ref_for(self, voice):
        p = os.path.join(self.voices_dir, voice + ".wav")
        if not voice or not re.match(r"^[A-Za-z0-9_.\-]+$", voice) or not os.path.isfile(p):
            raise ValueError("unknown voice %r (have %s in %s)" % (voice, self.voices() or "NONE", self.voices_dir))
        return p

    def conditioning(self, path):
        st = os.stat(path)
        hit = self.cond.get(path)
        if hit and hit[0] == st.st_mtime:
            return hit[1], hit[2]
        lat, emb = self.model.get_conditioning_latents(audio_path=[path])
        self.cond[path] = (st.st_mtime, lat, emb)
        return lat, emb

    def _count(self, ms, first_chunk_ms=None):
        self.synths += 1
        self.total_ms += ms
        self.last_ms = ms
        if self.synths == 1:
            self.first_ms = ms
        if first_chunk_ms is not None:
            self.last_first_chunk_ms = first_chunk_ms

    def synth(self, text, voice, yell, speed, temperature, lang):
        """Whole sentence -> (float32 samples, ms)."""
        import numpy as np
        ref = self.ref_for(voice)
        t0 = time.perf_counter()
        with self.lock:
            lat, emb = self.conditioning(ref)
            with self.torch.inference_mode():
                out = self.model.inference(text, lang, lat, emb, speed=speed, temperature=temperature,
                                           enable_text_splitting=True)
        samples = np.asarray(out["wav"], dtype=np.float32)
        if yell:
            samples = yellify(samples, SAMPLE_RATE)
        ms = (time.perf_counter() - t0) * 1000.0
        self._count(ms)
        return samples, ms, ref

    def stream(self, text, voice, yell, speed, temperature, lang):
        """Generator of float32 chunks straight out of inference_stream. The
        yell post-process is applied per chunk (the shelf filter carries no state
        across chunks -- a click at a boundary is possible; measured none on the
        samples, but it is per-chunk, and the whole-wav written to `out` is
        re-processed as one piece)."""
        ref = self.ref_for(voice)
        lat, emb = self.conditioning(ref)
        with self.torch.inference_mode():
            for ch in self.model.inference_stream(text, lang, lat, emb, stream_chunk_size=self.chunk,
                                                  speed=speed, temperature=temperature,
                                                  enable_text_splitting=True):
                s = ch.detach().float().cpu().numpy().ravel()
                yield (yellify(s, SAMPLE_RATE) if yell else s)

    def stats(self):
        return {
            "ok": True,
            "engine": "xtts-v2",
            "model": MODEL_ID,
            "device": self.device,
            "gpu": self.gpu,
            "voices": self.voices(),
            "voicesDir": self.voices_dir,
            "sampleRate": SAMPLE_RATE,
            "loadMs": round(self.load_ms, 1),
            "synths": self.synths,
            "firstMs": round(self.first_ms, 1),
            "lastMs": round(self.last_ms, 1),
            "meanMs": round(self.total_ms / self.synths, 1) if self.synths else 0.0,
            "lastFirstChunkMs": round(self.last_first_chunk_ms or 0.0, 1),
            "streaming": "POST /tts/stream -> chunked audio/pcm s16le 24 kHz, a chunk every %d GPT "
                         "tokens (Xtts.inference_stream), first chunk ~0.5 s" % self.chunk,
            "yell": "post-process (+6 dB, +4 dB high-shelf @3 kHz, tanh soft clip); XTTS has no emotion control",
            "licence": "CPML (Coqui Public Model License) -- NON-COMMERCIAL",
            "pid": os.getpid(),
        }


ENGINE = None
STARTED = time.time()


def parse_req(req):
    text = str(req.get("text", "")).strip()
    if not text:
        raise ValueError("empty text")
    voice = str(req.get("voice") or "")
    yell = bool(req.get("yell", False))
    try:
        speed = max(0.5, min(2.0, float(req.get("speed", 1.0))))
        temperature = max(0.05, min(1.5, float(req.get("temperature", 0.75))))
    except (TypeError, ValueError):
        raise ValueError("speed/temperature is not a number")
    lang = str(req.get("lang") or "en").split("-")[0]
    return text, voice, yell, speed, temperature, lang, req.get("out")


class Handler(BaseHTTPRequestHandler):
    server_version = "aowlspt-xtts/1.0"

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

    def _read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n > 0 else b""
        return json.loads(raw.decode("utf-8") or "{}")

    def _stream(self, req):
        try:
            text, voice, yell, speed, temperature, lang, out = parse_req(req)
            ENGINE.ref_for(voice)
        except ValueError as e:
            self._json(400, {"ok": False, "error": str(e)})
            return
        t0 = time.perf_counter()
        first_ms = None
        parts = []
        started = False
        try:
            with ENGINE.lock:
                for s in ENGINE.stream(text, voice, yell, speed, temperature, lang):
                    pcm = pcm16(s)
                    if not pcm:
                        continue
                    if not started:
                        first_ms = (time.perf_counter() - t0) * 1000.0
                        self.send_response(200)
                        self.send_header("Content-Type", "audio/pcm")
                        self.send_header("X-Sample-Rate", str(SAMPLE_RATE))
                        self.send_header("X-Channels", "1")
                        self.send_header("X-Bits", "16")
                        self.send_header("X-First-Chunk-Ms", "%.1f" % first_ms)
                        self.send_header("X-Yell", "post-process" if yell else "none")
                        self.send_header("Transfer-Encoding", "chunked")
                        self.end_headers()
                        started = True
                    self.wfile.write(b"%x\r\n" % len(pcm) + pcm + b"\r\n")
                    self.wfile.flush()
                    parts.append(pcm)
        except Exception as e:  # noqa: BLE001
            if not started:
                self._json(500, {"ok": False, "error": "stream failed: %r" % (e,)})
                return
            raise
        if not started:
            self._json(500, {"ok": False, "error": "xtts produced no chunks"})
            return
        self.wfile.write(b"0\r\n\r\n")
        total_ms = (time.perf_counter() - t0) * 1000.0
        ENGINE._count(total_ms, first_ms)
        if out:
            try:
                write_out(out, wav_from_pcm(b"".join(parts), SAMPLE_RATE))
            except OSError as e:
                sys.stderr.write("could not write %s: %s\n" % (out, e))
        sys.stderr.write("stream %s: first chunk %.0f ms, total %.0f ms, %d chunks%s\n"
                         % (voice, first_ms, total_ms, len(parts), " (yell)" if yell else ""))

    def do_POST(self):
        if self.path not in ("/tts", "/tts/stream"):
            self._json(404, {"ok": False, "error": "no such route: " + self.path})
            return
        try:
            req = self._read_json()
        except Exception as e:  # noqa: BLE001
            self._json(400, {"ok": False, "error": "bad JSON body: %s" % e})
            return
        if self.path == "/tts/stream":
            self._stream(req)
            return
        try:
            text, voice, yell, speed, temperature, lang, out = parse_req(req)
            samples, ms, ref = ENGINE.synth(text, voice, yell, speed, temperature, lang)
        except ValueError as e:
            self._json(400, {"ok": False, "error": str(e)})
            return
        except Exception as e:  # noqa: BLE001
            self._json(500, {"ok": False, "error": "synth failed: %r" % (e,)})
            return
        wav = wav_from_pcm(pcm16(samples), SAMPLE_RATE)
        if out:
            try:
                write_out(out, wav)
            except OSError as e:
                self._json(500, {"ok": False, "error": "could not write %s: %s" % (out, e)})
                return
            self._json(200, {"ok": True, "path": out, "done": out + ".done", "bytes": len(wav),
                             "ms": round(ms, 1), "voice": voice, "ref": ref,
                             "yell": "post-process" if yell else "none", "sampleRate": SAMPLE_RATE})
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-Synth-Ms", "%.1f" % ms)
        self.send_header("X-Voice", voice)
        self.send_header("X-Yell", "post-process" if yell else "none")
        self.end_headers()
        self.wfile.write(wav)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=default_root(), help="TTS_HOME holding tts/ (the downloaded weights)")
    ap.add_argument("--voices-dir", default=default_voices_dir())
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--chunk", type=int, default=20, help="stream_chunk_size in GPT tokens")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6976)
    ap.add_argument("--bench", default=None)
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--voice", default=None)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    global ENGINE
    ENGINE = Engine(a.root, a.voices_dir, a.device, a.chunk)
    sys.stderr.write("xtts-v2 loaded in %.0f ms on %s %s; voices: %s\n"
                     % (ENGINE.load_ms, a.device, ENGINE.gpu, ENGINE.voices() or "NONE in " + a.voices_dir))
    if a.bench:
        voice = a.voice or (ENGINE.voices() or [""])[0]
        times = []
        firsts = []
        samples = None
        for i in range(max(1, a.n)):
            samples, ms, _ = ENGINE.synth(a.bench, voice, False, 1.0, 0.75, "en")
            times.append(ms)
            t0 = time.perf_counter()
            first = None
            n = 0
            for _ in ENGINE.stream(a.bench, voice, False, 1.0, 0.75, "en"):
                if first is None:
                    first = (time.perf_counter() - t0) * 1000.0
                n += 1
            firsts.append(first)
            print("synth %d: whole %.0f ms (%.2f s audio); stream first chunk %.0f ms, %d chunks, total %.0f ms"
                  % (i + 1, ms, len(samples) / SAMPLE_RATE, first, n, (time.perf_counter() - t0) * 1000.0))
        if a.out and samples is not None:
            write_out(a.out, wav_from_pcm(pcm16(samples), SAMPLE_RATE))
        steady = times[1:] or times
        print("BENCH voice=%s words=%d first=%.0f ms steady(mean of %d)=%.0f ms ttfa(mean)=%.0f ms"
              % (voice, len(a.bench.split()), times[0], len(steady), sum(steady) / len(steady),
                 sum(firsts) / len(firsts)))
        return
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    sys.stderr.write("listening on http://%s:%d  (POST /tts, POST /tts/stream, GET /health)\n" % (a.host, a.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
