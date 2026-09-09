#!/usr/bin/env python3
"""Chatterbox (Resemble AI) as a local HTTP text-to-speech server, on CUDA.

Voice cloning from a reference wav: every `<stem>.wav` in --voices-dir IS a
voice, named by its file stem, rescanned on every request so dropping a new
wav into the folder needs no restart. The stem `default` (or a stem that does
not exist) uses the model's built-in conditioning (`conds.pt`), and the reply
says so -- an unknown stem is never silently the default.

    POST /tts   {"text": "...", "voice": "<stem>", "exaggeration": 0.5,
                 "cfg_weight": 0.5, "out": "C:/path/to/write.wav"}
        -> {"ok":true,"path":...,"bytes":N,"ms":T,"voice":...,"ref":...}
           When "out" is given the wav is written ATOMICALLY (a .tmp then
           os.replace) and an empty `<out>.done` marker follows it, so a
           caller that spawned the request detached can poll for the marker
           instead of blocking on the response. A stale marker is removed
           before synthesis starts.
           when "out" is given (the wav is written there: 24 kHz mono 16-bit),
           else audio/wav on the wire.
        Errors are HTTP 4xx/5xx with {"ok":false,"error":...} and NEVER a wav.
    GET  /health -> {"ok":true,"engine":"chatterbox","device":"cuda",
                     "voices":[...stems...],"voicesDir":...,"sampleRate":24000,
                     "synths":N,"firstMs":..,"lastMs":..,"meanMs":..}

Command line:
    python server.py --voices-dir DIR [--port 6971] [--host 127.0.0.1]
                     [--device cuda|cpu]
    python server.py --voices-dir DIR --bench "..." [--voice STEM] [--n 5] [--out X.wav]
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

SAMPLE_RATE = 24000


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
    """float32 [-1,1] (numpy, 1-D) -> 16-bit PCM RIFF via the stdlib."""
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
    def __init__(self, voices_dir, device):
        self.voices_dir = os.path.abspath(voices_dir)
        self.lock = threading.Lock()
        self.synths = 0
        self.total_ms = 0.0
        self.last_ms = 0.0
        self.first_ms = 0.0
        self.last_first_chunk_ms = 0.0
        t0 = time.perf_counter()
        import torch
        if device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("--device cuda but torch.cuda.is_available() is False "
                               "(torch %s; is this the CUDA wheel?)" % torch.__version__)
        from chatterbox.tts import ChatterboxTTS
        self.model = ChatterboxTTS.from_pretrained(device=device)
        self.device = device
        self.torch = torch
        self.load_ms = (time.perf_counter() - t0) * 1000.0
        self.sr = int(getattr(self.model, "sr", SAMPLE_RATE))
        self.gpu = torch.cuda.get_device_name(0) if device == "cuda" else "cpu"

    def voices(self):
        out = []
        if os.path.isdir(self.voices_dir):
            for n in sorted(os.listdir(self.voices_dir)):
                if n.lower().endswith(".wav"):
                    out.append(n[:-4])
        return out

    def ref_for(self, voice):
        if not voice or voice == "default":
            return None, "default (built-in conds.pt)"
        p = os.path.join(self.voices_dir, voice + ".wav")
        if os.path.isfile(p):
            return p, p
        return None, "UNKNOWN stem %r (no %s) -> built-in default voice" % (voice, p)

    def synth(self, text, voice, exaggeration, cfg_weight):
        ref, ref_note = self.ref_for(voice)
        t0 = time.perf_counter()
        with self.lock:
            with self.torch.inference_mode():
                wav = self.model.generate(text, audio_prompt_path=ref,
                                          exaggeration=exaggeration,
                                          cfg_weight=cfg_weight)
        samples = wav.squeeze(0).detach().cpu().numpy()
        ms = (time.perf_counter() - t0) * 1000.0
        self.synths += 1
        self.total_ms += ms
        self.last_ms = ms
        if self.synths == 1:
            self.first_ms = ms
        return wav_bytes(samples, self.sr), self.sr, ms, ref_note

    def stats(self):
        return {
            "ok": True,
            "engine": "chatterbox",
            "device": self.device,
            "gpu": self.gpu,
            "voicesDir": self.voices_dir,
            "voices": self.voices(),
            "sampleRate": self.sr,
            "loadMs": round(self.load_ms, 1),
            "synths": self.synths,
            "firstMs": round(self.first_ms, 1),
            "lastMs": round(self.last_ms, 1),
            "meanMs": round(self.total_ms / self.synths, 1) if self.synths else 0.0,
            "lastFirstChunkMs": round(self.last_first_chunk_ms or 0.0, 1),
            "streaming": "POST /tts/stream -> chunked audio/pcm s16le, one chunk "
                         "per SENTENCE (chatterbox-tts 0.1.7 has no generate_stream)",
            "pid": os.getpid(),
        }


ENGINE = None
STARTED = time.time()


class Handler(BaseHTTPRequestHandler):
    server_version = "aowlspt-chatterbox/1.0"

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
        """POST /tts/stream. chatterbox-tts 0.1.7 (the version installed,
        MEASURED 2026-09-07) exposes ONLY `ChatterboxTTS.generate` -- no
        generate_stream / chunked decoding -- so the only streaming available
        is per SENTENCE: the text is split on . ! ? and each sentence is
        generated and flushed as one chunk. For a one-sentence request the
        first chunk arrives when the whole thing is done; for a multi-sentence
        line the first sentence plays while the rest generate. Headers go out
        with the first chunk so time-to-first-byte is time-to-first-audio."""
        import re
        text = str(req.get("text", "")).strip()
        if not text:
            self._json(400, {"ok": False, "error": "empty text"})
            return
        voice = str(req.get("voice") or "default")
        try:
            exaggeration = max(0.0, min(2.0, float(req.get("exaggeration", 0.5))))
            cfg_weight = max(0.0, min(1.0, float(req.get("cfg_weight", 0.5))))
        except (TypeError, ValueError):
            self._json(400, {"ok": False, "error": "exaggeration/cfg_weight not numbers"})
            return
        out = req.get("out")
        parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", text) if p.strip()] or [text]
        t0 = time.perf_counter()
        first_ms = None
        started = False
        pcm_parts = []
        rate = ENGINE.sr
        try:
            for sent in parts:
                wav, rate, ms, ref = ENGINE.synth(sent, voice, exaggeration, cfg_weight)
                pcm = wav[44:]
                if not started:
                    first_ms = (time.perf_counter() - t0) * 1000.0
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/pcm")
                    self.send_header("X-Sample-Rate", str(rate))
                    self.send_header("X-Channels", "1")
                    self.send_header("X-Bits", "16")
                    self.send_header("X-First-Chunk-Ms", "%.1f" % first_ms)
                    self.send_header("X-Ref", ref)
                    self.send_header("X-Chunking", "per-sentence (chatterbox-tts 0.1.7 has no generate_stream)")
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
        self.wfile.write(b"0\r\n\r\n")
        total_ms = (time.perf_counter() - t0) * 1000.0
        ENGINE.last_first_chunk_ms = first_ms
        if out:
            buf = io.BytesIO()
            with wave.open(buf, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(rate)
                w.writeframes(b"".join(pcm_parts))
            try:
                write_out_atomic(out, buf.getvalue())
            except OSError as e:
                sys.stderr.write("could not write %s: %s\n" % (out, e))
        sys.stderr.write("stream %s: first chunk %.0f ms, total %.0f ms, %d sentence(s)\n"
                         % (voice, first_ms, total_ms, len(parts)))

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
        voice = str(req.get("voice") or "default")
        try:
            exaggeration = float(req.get("exaggeration", 0.5))
            cfg_weight = float(req.get("cfg_weight", 0.5))
        except (TypeError, ValueError):
            self._json(400, {"ok": False, "error": "exaggeration/cfg_weight not numbers"})
            return
        exaggeration = max(0.0, min(2.0, exaggeration))
        cfg_weight = max(0.0, min(1.0, cfg_weight))
        out = req.get("out")
        try:
            wav, rate, ms, ref_note = ENGINE.synth(text, voice, exaggeration, cfg_weight)
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
                             "ms": round(ms, 1), "voice": voice, "ref": ref_note,
                             "exaggeration": exaggeration, "cfg_weight": cfg_weight,
                             "sampleRate": rate})
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-Synth-Ms", "%.1f" % ms)
        self.send_header("X-Voice", voice)
        self.send_header("X-Ref", ref_note)
        self.end_headers()
        self.wfile.write(wav)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--voices-dir", required=True, help="folder of <stem>.wav reference voices")
    ap.add_argument("--device", default="cuda", choices=["cuda", "cpu"])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6971)
    ap.add_argument("--bench", default=None, help="synthesise this text N times and exit")
    ap.add_argument("--n", type=int, default=5)
    ap.add_argument("--voice", default="default")
    ap.add_argument("--out", default=None, help="with --bench: write the last wav here")
    a = ap.parse_args()
    global ENGINE
    ENGINE = Engine(a.voices_dir, a.device)
    sys.stderr.write("chatterbox loaded in %.0f ms on %s (%s); voices: %s\n"
                     % (ENGINE.load_ms, a.device, ENGINE.gpu, " ".join(ENGINE.voices()) or "(none)"))
    if a.bench:
        times = []
        wav = b""
        rate = SAMPLE_RATE
        for i in range(max(1, a.n)):
            wav, rate, ms, ref = ENGINE.synth(a.bench, a.voice, 0.5, 0.5)
            times.append(ms)
            print("synth %d: %.0f ms, %d bytes (%.2f s audio) ref=%s"
                  % (i + 1, ms, len(wav), (len(wav) - 44) / 2.0 / rate, ref))
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
