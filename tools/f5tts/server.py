#!/usr/bin/env python3
"""F5-TTS (SWivid, F5TTS_v1_Base) as a local HTTP text-to-speech server on CUDA --
the `ai-companion` voice for mods/basement: a deliberately corny, AI-sounding
voice cloned from a short reference wav. The user chose it FOR that quality
(2026-09-07: "a funny AI robot companion thing"); Orpheus (Groq) is the voice
for everyone else. Same contract as tools/kokoro/server.py:

    GET  /health        -> {"ok":true,"engine":"f5-tts","device":"cuda","voices":[stems],"voicesDir",
                            "sampleRate":24000,"loadMs","synths","firstMs","lastMs","meanMs",
                            "defaults":{nfe,cfg,speed},"licence"}
    GET  /voices        -> {"ok":true,"voices":[stems]}
    POST /tts           {"text","voice":"<stem>","yell":false,"nfe":32,"cfg":2.0,"speed":1.0,"seed":N
                         [,"out":path]}
                        -> audio/wav 24 kHz mono 16-bit, or with "out": the wav is written there
                           PLUS an "<out>.done" marker, and the answer is
                           {"ok":true,"path","bytes","ms","ref","seed","nfe","yell"} -- the seed is
                           always reported so a line the user likes can be regenerated exactly.
    POST /tts/stream    same body -> chunked audio/pcm s16le 24 kHz, ONE CHUNK PER SENTENCE
                        (F5 is a flow-matching model: the whole sentence is one denoising run, so
                        there is no intra-sentence streaming; a multi-sentence line plays its first
                        sentence while the rest generate). Headers go out with the first chunk.
    Errors are always JSON {"ok":false,"error":...} with a 4xx/5xx, never a wav.

A voice is `<stem>.wav` in --voices-dir with `<stem>.txt` beside it holding its
TRANSCRIPT (F5 conditions on the reference's text; without a .txt it would run a
1.6 GB Whisper download, so a missing transcript is a 400 that names the file).
The DEFAULTS are exactly the settings that produced `samples/f5tts-2.wav`
(kept as `voices/keep-f5-yell.wav`): F5TTS_v1_Base, nfe_step 32, cfg_strength
2.0, speed 1.0, ref placeholder-sapi-david. Its seed was random and not
recorded; every seed here is.

`yell`: F5 has no emotion/energy control, so a yelled line is post-processed:
+6 dB gain, +4 dB RBJ high-shelf at 3 kHz, tanh soft clip -- the SAME chain
that made f5tts-2.wav, so `yell:true` IS the companion's shouted style.

LICENCE: F5-TTS code MIT, F5TTS_v1_Base weights CC-BY-4.0 (attribute SWivid).

Command line:
    python server.py [--root DIR] [--voices-dir DIR] [--port 6977] [--host 127.0.0.1] [--device cuda]
    python server.py --bench "sentence" [--n 4] [--voice stem] [--nfe 32]   # no HTTP
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
MODEL = "F5TTS_v1_Base"
DEFAULTS = {"nfe": 32, "cfg": 2.0, "speed": 1.0}


def default_root():
    env = os.environ.get("AOWLSPT_F5TTS_ROOT")
    if env:
        return env
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "aowlspt", "f5tts")


def default_voices_dir():
    here = os.path.dirname(os.path.abspath(__file__))
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
    d = os.path.dirname(out)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    tmp = out + ".part"
    with open(tmp, "wb") as f:
        f.write(wav)
    os.replace(tmp, out)
    with open(out + ".done", "w") as f:
        f.write("%d\n" % len(wav))


def split_sentences(text):
    return [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()] or [text]


class Engine(object):
    def __init__(self, root, voices_dir, device):
        self.root = root
        self.voices_dir = voices_dir
        self.device = device
        self.lock = threading.Lock()
        self.synths = 0
        self.total_ms = 0.0
        self.last_ms = 0.0
        self.first_ms = 0.0
        self.last_first_chunk_ms = 0.0
        os.environ.setdefault("HF_HOME", os.path.join(root, "hf"))
        t0 = time.perf_counter()
        import torch
        from f5_tts.api import F5TTS
        self.torch = torch
        self.f5 = F5TTS(model=MODEL, device=device, hf_cache_dir=os.path.join(root, "hf"))
        self.load_ms = (time.perf_counter() - t0) * 1000.0
        self.gpu = torch.cuda.get_device_name(0) if device.startswith("cuda") and torch.cuda.is_available() else ""

    def voices(self):
        try:
            names = [f for f in os.listdir(self.voices_dir) if f.lower().endswith(".wav")]
        except OSError:
            names = []
        return sorted(os.path.splitext(f)[0] for f in names)

    def ref_for(self, voice):
        if not voice or not re.match(r"^[A-Za-z0-9_.\-]+$", voice):
            raise ValueError("bad voice %r (have %s in %s)" % (voice, self.voices() or "NONE", self.voices_dir))
        wav = os.path.join(self.voices_dir, voice + ".wav")
        txt = os.path.join(self.voices_dir, voice + ".txt")
        if not os.path.isfile(wav):
            raise ValueError("unknown voice %r (have %s in %s)" % (voice, self.voices() or "NONE", self.voices_dir))
        if not os.path.isfile(txt):
            raise ValueError("voice %r has no transcript: write %s (F5 conditions on the reference's text)"
                             % (voice, txt))
        with open(txt, encoding="utf-8") as f:
            ref_text = f.read().strip()
        if not ref_text:
            raise ValueError("transcript %s is empty" % txt)
        return wav, ref_text

    def _count(self, ms, first_chunk_ms=None):
        self.synths += 1
        self.total_ms += ms
        self.last_ms = ms
        if self.synths == 1:
            self.first_ms = ms
        if first_chunk_ms is not None:
            self.last_first_chunk_ms = first_chunk_ms

    def synth_one(self, text, ref, ref_text, nfe, cfg, speed, seed):
        """One F5 run (must hold self.lock). Returns float32 samples."""
        import numpy as np
        wav, sr, _ = self.f5.infer(ref_file=ref, ref_text=ref_text, gen_text=text, nfe_step=nfe,
                                   cfg_strength=cfg, speed=speed, seed=seed,
                                   show_info=lambda *a, **k: None, progress=None)
        if sr != SAMPLE_RATE:
            raise RuntimeError("F5 returned %d Hz, expected %d" % (sr, SAMPLE_RATE))
        return np.asarray(wav, dtype=np.float32)

    def synth(self, text, voice, yell, nfe, cfg, speed, seed):
        ref, ref_text = self.ref_for(voice)
        t0 = time.perf_counter()
        with self.lock:
            s = self.synth_one(text, ref, ref_text, nfe, cfg, speed, seed)
        if yell:
            s = yellify(s, SAMPLE_RATE)
        ms = (time.perf_counter() - t0) * 1000.0
        self._count(ms)
        return s, ms, ref

    def stats(self):
        return {
            "ok": True,
            "engine": "f5-tts",
            "role": "ai-companion",
            "model": MODEL,
            "device": self.device,
            "gpu": self.gpu,
            "voices": self.voices(),
            "voicesDir": self.voices_dir,
            "sampleRate": SAMPLE_RATE,
            "defaults": DEFAULTS,
            "loadMs": round(self.load_ms, 1),
            "synths": self.synths,
            "firstMs": round(self.first_ms, 1),
            "lastMs": round(self.last_ms, 1),
            "meanMs": round(self.total_ms / self.synths, 1) if self.synths else 0.0,
            "lastFirstChunkMs": round(self.last_first_chunk_ms or 0.0, 1),
            "streaming": "POST /tts/stream -> chunked audio/pcm s16le 24 kHz, one chunk per SENTENCE "
                         "(flow matching: no intra-sentence streaming)",
            "yell": "post-process (+6 dB, +4 dB high-shelf @3 kHz, tanh soft clip) = the f5tts-2.wav chain",
            "licence": "code MIT; F5TTS_v1_Base weights CC-BY-4.0 (SWivid)",
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
        nfe = max(4, min(64, int(req.get("nfe", DEFAULTS["nfe"]))))
        cfg = max(0.0, min(5.0, float(req.get("cfg", DEFAULTS["cfg"]))))
        speed = max(0.5, min(2.0, float(req.get("speed", DEFAULTS["speed"]))))
        seed = req.get("seed")
        seed = int(seed) if seed is not None else int.from_bytes(os.urandom(4), "little")
    except (TypeError, ValueError):
        raise ValueError("nfe/cfg/speed/seed is not a number")
    return text, voice, yell, nfe, cfg, speed, seed, req.get("out")


class Handler(BaseHTTPRequestHandler):
    server_version = "aowlspt-f5tts/1.0"

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
            text, voice, yell, nfe, cfg, speed, seed, out = parse_req(req)
            ref, ref_text = ENGINE.ref_for(voice)
        except ValueError as e:
            self._json(400, {"ok": False, "error": str(e)})
            return
        t0 = time.perf_counter()
        first_ms = None
        parts = []
        started = False
        try:
            with ENGINE.lock:
                for i, sent in enumerate(split_sentences(text)):
                    s = ENGINE.synth_one(sent, ref, ref_text, nfe, cfg, speed, seed + i)
                    pcm = pcm16(yellify(s, SAMPLE_RATE) if yell else s)
                    if not started:
                        first_ms = (time.perf_counter() - t0) * 1000.0
                        self.send_response(200)
                        self.send_header("Content-Type", "audio/pcm")
                        self.send_header("X-Sample-Rate", str(SAMPLE_RATE))
                        self.send_header("X-Channels", "1")
                        self.send_header("X-Bits", "16")
                        self.send_header("X-First-Chunk-Ms", "%.1f" % first_ms)
                        self.send_header("X-Seed", str(seed))
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
        self.wfile.write(b"0\r\n\r\n")
        total_ms = (time.perf_counter() - t0) * 1000.0
        ENGINE._count(total_ms, first_ms)
        if out:
            try:
                write_out(out, wav_from_pcm(b"".join(parts), SAMPLE_RATE))
            except OSError as e:
                sys.stderr.write("could not write %s: %s\n" % (out, e))
        sys.stderr.write("stream %s: first chunk %.0f ms, total %.0f ms, %d chunks, seed %d%s\n"
                         % (voice, first_ms, total_ms, len(parts), seed, " (yell)" if yell else ""))

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
            text, voice, yell, nfe, cfg, speed, seed, out = parse_req(req)
            samples, ms, ref = ENGINE.synth(text, voice, yell, nfe, cfg, speed, seed)
        except ValueError as e:
            self._json(400, {"ok": False, "error": str(e)})
            return
        except Exception as e:  # noqa: BLE001
            self._json(500, {"ok": False, "error": "synth failed: %r" % (e,)})
            return
        wav = wav_from_pcm(pcm16(samples), SAMPLE_RATE)
        meta = {"seed": seed, "nfe": nfe, "cfg": cfg, "speed": speed, "voice": voice, "ref": ref,
                "yell": "post-process" if yell else "none"}
        if out:
            try:
                write_out(out, wav)
            except OSError as e:
                self._json(500, {"ok": False, "error": "could not write %s: %s" % (out, e)})
                return
            doc = {"ok": True, "path": out, "done": out + ".done", "bytes": len(wav), "ms": round(ms, 1),
                   "sampleRate": SAMPLE_RATE}
            doc.update(meta)
            self._json(200, doc)
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-Synth-Ms", "%.1f" % ms)
        self.send_header("X-Voice", voice)
        self.send_header("X-Seed", str(seed))
        self.send_header("X-Yell", meta["yell"])
        self.end_headers()
        self.wfile.write(wav)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=default_root(), help="holds venv/ and hf/ (HF_HOME with the weights)")
    ap.add_argument("--voices-dir", default=default_voices_dir())
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6977)
    ap.add_argument("--bench", default=None)
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--nfe", type=int, default=DEFAULTS["nfe"])
    ap.add_argument("--voice", default=None)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    global ENGINE
    ENGINE = Engine(a.root, a.voices_dir, a.device)
    sys.stderr.write("f5-tts %s loaded in %.0f ms on %s %s; voices: %s\n"
                     % (MODEL, ENGINE.load_ms, a.device, ENGINE.gpu, ENGINE.voices() or "NONE in " + a.voices_dir))
    if a.bench:
        voice = a.voice or "placeholder-sapi-david"
        times = []
        samples = None
        for i in range(max(1, a.n)):
            samples, ms, _ = ENGINE.synth(a.bench, voice, False, a.nfe, DEFAULTS["cfg"], DEFAULTS["speed"], 1000 + i)
            times.append(ms)
            print("synth %d: %.0f ms (%.2f s audio, nfe %d)" % (i + 1, ms, len(samples) / SAMPLE_RATE, a.nfe))
        if a.out and samples is not None:
            write_out(a.out, wav_from_pcm(pcm16(samples), SAMPLE_RATE))
        steady = times[1:] or times
        print("BENCH voice=%s words=%d nfe=%d first=%.0f ms steady(mean of %d)=%.0f ms"
              % (voice, len(a.bench.split()), a.nfe, times[0], len(steady), sum(steady) / len(steady)))
        return
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    sys.stderr.write("listening on http://%s:%d  (POST /tts, POST /tts/stream, GET /health)\n" % (a.host, a.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
