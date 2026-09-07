"""F5-TTS shouted lines in the style of f5tts-2.wav (the user's "hilarious" clip).
Baseline settings = what bench_f5.py used for f5tts-2: F5TTS_v1_Base, ref
placeholder-sapi-david.wav + its whisper transcript, nfe_step=32, cfg_strength=2.0,
speed=1.0, random seed (NOT recorded for f5tts-2 -- unrecoverable), then the
yellify post-process (+6 dB, +4 dB high-shelf @3 kHz, tanh soft clip).
Every clip here records its seed so a hit is reproducible: `--seed N --line K`.
Writes each wav the moment it exists and appends a row to F5-YELL-NOTES.md."""
import argparse, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
root = os.path.join(os.environ["LOCALAPPDATA"], "aowlspt", "f5tts")
os.environ["HF_HOME"] = os.path.join(root, "hf")
from benchlib import *
import torch
from f5_tts.api import F5TTS

LINES = [
    ("threat",  "Drop the bag and walk away, or I put you in the ground!"),
    ("order",   "Everybody on the floor now, hands where I can see them!"),
    ("panic",   "They're coming through the wall, run, run, don't look back!"),
    ("taunt",   "Is that all you've got? My grandmother hits harder than you!"),
    ("slaver",  "Move it, cattle! Anyone who stops walking gets left for the dogs!"),
    ("trader",  "Fresh ammo, two hundred a box, no haggling, no refunds, no crying!"),
    ("medic",   "Cover me, he's bleeding out, somebody get me a tourniquet now!"),
    ("threat",  "Touch that door again and I swear you lose the hand!"),
    ("order",   "Nobody leaves this basement until I find out who took my keys!"),
    ("panic",   "The generator's on fire, kill the power, kill it, kill it!"),
    ("taunt",   "Come on then, hero, show everyone what a big man you are!"),
    ("trader",  "Last call! Water's ten a bottle, tomorrow it's twenty, your choice!"),
    ("slaver",  "Chain them up, count them twice, I'm not losing another one tonight!"),
    ("medic",   "Stop screaming and hold still, I can't stitch a moving target!"),
]
REFS = {
    "david": os.path.join(VOICES, "placeholder-sapi-david.wav"),
    "zira": os.path.join(VOICES, "placeholder-sapi-zira.wav"),
    "lessac": os.path.join(VOICES, "placeholder-piper-lessac.wav"),
}
NOTES = os.path.join(SAMPLES, "F5-YELL-NOTES.md")

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="F5TTS_v1_Base")
ap.add_argument("--nfe", type=int, default=32)
ap.add_argument("--seed", type=int, default=None, help="fixed seed (else random, recorded)")
ap.add_argument("--line", type=int, default=None, help="only this line index")
ap.add_argument("--ref", default=None, help="only this ref stem")
ap.add_argument("--start", type=int, default=1, help="first output index")
ap.add_argument("--tag", default="")
a = ap.parse_args()

f5 = F5TTS(model=a.model, device="cuda", hf_cache_dir=os.path.join(root, "hf"))
quiet = lambda *x, **k: None  # noqa: E731

if not os.path.exists(NOTES):
    with open(NOTES, "w", encoding="utf-8", newline="\n") as f:
        f.write("# F5-TTS shouted clips -- how each one was made\n\n"
                "Baseline = `f5tts-2.wav` (kept verbatim as `data/voices/keep-f5-yell.wav`, md5 "
                "cbd7c0a62e8a98d33d89c56f28ad9ed1): model F5TTS_v1_Base, ref "
                "`placeholder-sapi-david.wav` with its whisper transcript as ref_text, nfe_step 32, "
                "cfg_strength 2.0, speed 1.0, seed RANDOM AND NOT RECORDED (bench_f5.py did not print "
                "it -- that clip cannot be regenerated bit-for-bit), then post-process `yellify`: "
                "gain +6 dB, RBJ high-shelf +4 dB @ 3 kHz, tanh soft clip (x1.2, normalised).\n\n"
                "Every clip below records its seed. Regenerate one with\n"
                "`f5_yells.py --model M --ref R --nfe N --seed S --line K --start <n>` "
                "(tools/f5tts/yells.py, run with the f5tts venv python).\n\n"
                "| file | style | model | ref | nfe | cfg | seed | gen ms | audio s | text |\n"
                "|---|---|---|---|---|---|---|---|---|---|\n")

idx = a.start
refs = [(a.ref, REFS[a.ref])] if a.ref else list(REFS.items())
lines = [LINES[a.line]] if a.line is not None else LINES
ri = 0
for li, (style, text) in enumerate(lines):
    stem, ref = refs[ri % len(refs)] if not a.ref else refs[0]
    ri += 1
    seed = a.seed if a.seed is not None else int.from_bytes(os.urandom(4), "little")
    t = time.perf_counter()
    wav, sr, _ = f5.infer(ref_file=ref, ref_text=REF_TEXT, gen_text=text, nfe_step=a.nfe,
                          cfg_strength=2.0, speed=1.0, seed=seed, show_info=quiet, progress=None)
    ms = (time.perf_counter() - t) * 1000
    name = "f5tts-yell-%d%s.wav" % (idx, a.tag)
    dur = write_wav(os.path.join(SAMPLES, name), yellify(np.asarray(wav, np.float32), sr), sr)
    row = "| %s | %s | %s | %s | %d | 2.0 | %d | %.0f | %.2f | %s |\n" % (
        name, style, a.model, stem, a.nfe, seed, ms, dur, text)
    with open(NOTES, "a", encoding="utf-8", newline="\n") as f:
        f.write(row)
    print("WROTE " + row.strip(), flush=True)
    idx += 1
