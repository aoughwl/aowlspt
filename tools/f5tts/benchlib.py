"""Shared by the three engine benchmarks: the SAME two sentences, the same
reference wav, the same VRAM probe, the same yell post-process, the same
sample writer. Every number printed is measured in this process."""
import json, os, subprocess, sys, time, wave
import numpy as np

REPO = r"C:\Users\savant\Projects\aowlspt"
SAMPLES = os.path.join(REPO, "mods", "basement", "data", "samples")
VOICES = os.path.join(REPO, "mods", "basement", "data", "voices")
REF = os.path.join(VOICES, "placeholder-sapi-david.wav")
# whisper base.en transcript of all three placeholder wavs (measured 2026-09-07)
REF_TEXT = ("Listen to me. The road past the reactor is closed, the convoy left "
            "before dawn, and if you want to eat tonight you will do exactly what "
            "I tell you, and nothing else. Do you understand?")
CALM = "The basement door is locked, and nobody here is going to open it."   # 13 words
YELL = "Get out of my shop right now, or I swear I'll shoot you!"             # 13 words
assert len(CALM.split()) == 13 and len(YELL.split()) == 13


def _gpu_used_mib():
    """Total GPU memory in use (MiB) -- per-process numbers are [N/A] under
    WDDM on Windows (measured), so callers report a delta from process start."""
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            text=True, timeout=10)
        return int(out.strip().splitlines()[0])
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("vram probe failed: %r\n" % (e,))
        return -1


_GPU_BASE = _gpu_used_mib()


def vram_mib():
    """GPU memory this process added since import (MiB), or -1."""
    now = _gpu_used_mib()
    return now - _GPU_BASE if now >= 0 and _GPU_BASE >= 0 else -1


def high_shelf(x, sr, f0=3000.0, gain_db=4.0, q=0.7071):
    """RBJ cookbook high-shelf biquad (vectorised with scipy if present)."""
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2 * np.pi * f0 / sr
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    sa = 2 * np.sqrt(A) * alpha
    b0 = A * ((A + 1) + (A - 1) * cw + sa)
    b1 = -2 * A * ((A - 1) + (A + 1) * cw)
    b2 = A * ((A + 1) + (A - 1) * cw - sa)
    a0 = (A + 1) - (A - 1) * cw + sa
    a1 = 2 * ((A - 1) - (A + 1) * cw)
    a2 = (A + 1) - (A - 1) * cw - sa
    b = np.array([b0, b1, b2]) / a0
    a = np.array([1.0, a1 / a0, a2 / a0])
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
    """Post-process for a shouted line when the engine has no energy control:
    +6 dB gain, +4 dB high-shelf at 3 kHz, tanh soft clip. Deterministic."""
    x = np.asarray(samples, dtype=np.float64) * 2.0
    x = high_shelf(x, sr)
    x = np.tanh(x * 1.2) / np.tanh(1.2)
    return np.clip(x, -1.0, 1.0).astype(np.float32)


def write_wav(path, samples, sr):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pcm = (np.clip(np.asarray(samples, dtype=np.float32), -1, 1) * 32767.0).astype("<i2").tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm)
    return round(len(pcm) / 2.0 / sr, 2)


def report(engine, **kw):
    doc = {"engine": engine, "ts": time.strftime("%Y-%m-%d %H:%M:%S")}
    doc.update(kw)
    print("BENCH " + json.dumps(doc))
    return doc
