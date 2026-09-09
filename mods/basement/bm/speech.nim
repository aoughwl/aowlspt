## bm/speech — speech in and speech out.
##
## ---------------------------------------------------------------------------
## STT IS PROGRESSIVE, AND THAT IS THE WHOLE POINT
## ---------------------------------------------------------------------------
##
## The player holds a key and talks. The client posts small PCM chunks as they
## are captured; this module keeps a per-session 16 kHz mono 16-bit WAV **on
## disk** under `workDir`, appends each chunk to it, and rewrites the RIFF
## header's two size fields every time so the file is a valid wav after every
## append rather than only at the end. That matters because whisper is run
## against that same file mid-utterance, every `sttPartialMs` of NEW audio, to
## produce a `partial`.
##
## A partial is a preview. It is NEVER the input to the brain: whisper.cpp's
## transcription of a truncated utterance changes as more audio arrives (a
## measured property of aowl.voice's pipeline, restated in DESIGN.md §7), so
## only the `final` pass -- one more run over the whole buffer, after which the
## session is closed and its buffer freed -- produces `finalText`.
##
## When whisper is absent, `sttSessionChunk` still accepts and stores the audio
## and returns TRUE, but `partial`/`finalText` stay empty and `note` names the
## exact path that was missing. It must never look like a transcription of
## silence.
##
## ---------------------------------------------------------------------------
## TTS IS PER SENTENCE, AND CACHED ON DISK
## ---------------------------------------------------------------------------
##
## The brain hands over one sentence at a time as it streams, so the first
## sentence is spoken while the last is still being generated. Each sentence is
## keyed by `hash(engine, resolved voice model, normalized sentence)` and the
## wav is written to `cacheDir/tts/<hash>.wav`. The SECOND request for the same
## sentence returns that same file with `cached = true` -- byte-identical,
## because it is literally the same file, which is what makes the selfcheck's
## byte comparison a check that can fail rather than a tautology.
##
## The index is sentinel-tailed (the tear-guard idiom from mods/voice): a
## half-written index is discarded wholesale instead of being parsed into
## plausible garbage, and an entry whose wav has vanished from disk is dropped
## on load rather than handed back as a path to nothing.

import std/[strutils, base64, envvars]
import aowlspt
import aowlspt/server as server
import aowlspt/json as jr
import util
import stream
import hearing

type
  SpeechProbe* = object
    slot*: string        ## "stt" | "tts"
    engine*: string
    path*: string        ## the exact absolute exe path that would run
    model*: string       ## the exact absolute model/voice path
    note*: string
    ok*: bool

# ---------------------------------------------------------------------------
# Config. Literal initialisers only (DLL globals).
# ---------------------------------------------------------------------------

var cSttEngine: string = "whisper-server"
var cTtsEngine: string = "piper"
var cToolsDir: string = ""
var cWhisperExe: string = ""
var cWhisperModel: string = ""
var cPiperExe: string = ""
var cPiperVoice: string = ""
var cCurlExe: string = "curl.exe"
var cWorkDir: string = ""
var cCacheDir: string = ""
var cWhisperPort: int = 9111
var cSttPartialMs: int = 1200

# HTTP TTS servers (kokoro = CPU/onnx, chatterbox = CUDA voice cloning). Each
# is a python venv OUTSIDE the repo (tools/<engine>/setup.ps1 makes it) that
# the backend starts detached on first use when /health does not answer.
var cKokoroUrl: string = "http://127.0.0.1:6971"
var cKokoroRoot: string = ""
var cKokoroExe: string = ""
var cChatterUrl: string = "http://127.0.0.1:6974"
var cChatterRoot: string = ""
var cChatterExe: string = ""
var cVoicesDir: string = ""       ## <stem>.wav reference voices for chatterbox

# OpenAI-COMPATIBLE cloud speech. Groq serves the same shapes at
# https://api.groq.com/openai/v1 -- MEASURED 2026-09-07: whisper-large-v3-turbo
# transcribed a 42 KB push-to-talk wav in 0.53 s round trip. The KEY is never
# in config.json or in source: these settings name an ENVIRONMENT VARIABLE and
# the value is read from the process environment, so switching provider changes
# which variable is read, never where a secret is written down.
var cSttBase: string = "https://api.openai.com/v1"
var cSttKeyEnv: string = "OPENAI_API_KEY"
var cSttModel: string = "whisper-large-v3-turbo"
var cTtsBase: string = "https://api.openai.com/v1"
var cTtsKeyEnv: string = "OPENAI_API_KEY"
var cTtsModel: string = "canopylabs/orpheus-v1-english"

var gWhisperSpawned: bool = false
var gKokoroSpawned: bool = false
var gChatterSpawned: bool = false
var gTmpSeq: int = 0

# Voice table (data/voices.json): tag -> per-engine voice. Parallel seqs.
var gVTag: seq[string] = @[]
var gVKokoro: seq[string] = @[]
var gVSpeed: seq[float] = @[]
var gVChatter: seq[string] = @[]
var gVExag: seq[float] = @[]
var gVCfg: seq[float] = @[]
var gVPiper: seq[string] = @[]
var gVOrpheus: seq[string] = @[]
var gPoolOrpheus: seq[string] = @[]
var gPoolKokoro: seq[string] = @[]
var gPoolChatter: seq[string] = @[]
var gVoicesNote: string = "voices.json not loaded"

# TTS cache
var gTKey: seq[string] = @[]
var gTWav: seq[string] = @[]
var gTSentence: seq[string] = @[]
var gTHits: int = 0
var gTMiss: int = 0
var gTLoadNote: string = "not loaded"

# STT sessions (parallel seqs; nimony has no tables here by house rule)
var gSId: seq[string] = @[]
var gSPath: seq[string] = @[]
var gSPcm: seq[string] = @[]        ## raw PCM payload accumulated so far
var gSRate: seq[int] = @[]
var gSChan: seq[int] = @[]
var gSBits: seq[int] = @[]
var gSLastSeq: seq[int] = @[]
var gSSincePartial: seq[int] = @[]  ## PCM bytes since the last whisper run
var gSPartials: seq[int] = @[]

const IndexName = "index.json"
const Sentinel = "\n#aowlspt-basement-tts-end"

proc defaulted(v, fallback: string): string =
  if v.len > 0: v else: fallback

proc ttsCacheDir(): string =
  if cCacheDir.len == 0: return ""
  result = joinPath(cCacheDir, "tts")

proc ensureTtsDir(): bool =
  ## `util.ensureDir` creates the FINAL component only -- MEASURED 2026-09-06:
  ## with cacheDir = %TEMP%/bmcache, creating %TEMP%/bmcache/tts failed because
  ## bmcache did not exist yet, every sentence missed the cache, and the
  ## selfcheck's byte-identity check failed. So walk the ancestors.
  let dir = ttsCacheDir()
  if dir.len == 0: return false
  var i = 0
  while i < dir.len:
    if dir[i] == '/' or dir[i] == '\\':
      if i > 2: discard ensureDir(dir[0 ..< i])
    i = i + 1
  result = ensureDir(dir)

proc speechConfigure*(sttEngine, ttsEngine, toolsDir, whisperExe, whisperModel,
                      piperExe, piperVoice, curlExe, workDir, cacheDir: string;
                      whisperPort, sttPartialMs: int;
                      kokoroUrl: string = ""; kokoroRoot: string = "";
                      kokoroExe: string = ""; chatterboxUrl: string = "";
                      chatterboxRoot: string = ""; chatterboxExe: string = "";
                      voicesDir: string = ""; localAppData: string = "") =
  cSttEngine = defaulted(sttEngine, "whisper-server")
  cTtsEngine = defaulted(ttsEngine, "piper")
  cToolsDir = toolsDir
  cWhisperExe = defaulted(whisperExe, joinPath(toolsDir, "whisper/whisper-server.exe"))
  cWhisperModel = defaulted(whisperModel, joinPath(toolsDir, "whisper/ggml-base.en.bin"))
  cPiperExe = defaulted(piperExe, joinPath(toolsDir, "piper/piper.exe"))
  cPiperVoice = defaulted(piperVoice, joinPath(toolsDir, "piper/en_US-lessac-medium.onnx"))
  cCurlExe = defaulted(curlExe, "curl.exe")
  cWorkDir = defaulted(workDir, ".")
  cCacheDir = cacheDir
  if whisperPort > 0: cWhisperPort = whisperPort
  if sttPartialMs > 0: cSttPartialMs = sttPartialMs
  # The roots default to where tools/kokoro/setup.ps1 and
  # tools/chatterbox/setup.ps1 put their venvs: %LOCALAPPDATA%/aowlspt/<engine>.
  let lad = defaulted(localAppData, ".")
  cKokoroUrl = defaulted(kokoroUrl, "http://127.0.0.1:6971")
  cKokoroRoot = defaulted(kokoroRoot, joinPath(lad, "aowlspt/kokoro"))
  cKokoroExe = defaulted(kokoroExe, joinPath(cKokoroRoot, "venv/Scripts/python.exe"))
  cChatterUrl = defaulted(chatterboxUrl, "http://127.0.0.1:6974")
  cChatterRoot = defaulted(chatterboxRoot, joinPath(lad, "aowlspt/chatterbox"))
  cChatterExe = defaulted(chatterboxExe, joinPath(cChatterRoot, "venv/Scripts/python.exe"))
  cVoicesDir = voicesDir

# ---------------------------------------------------------------------------
# Voice table -- data/voices.json, loaded by the root (it owns paths).
# ---------------------------------------------------------------------------

type
  VoiceSpec* = object
    tag*: string         ## the person's tag as gen wrote it
    mapped*: bool        ## false = not in voices.json, picked from the pool
    kokoro*: string
    speed*: float
    chatterbox*: string
    exaggeration*: float
    cfgWeight*: float
    piper*: string
    orpheus*: string     ## the openai-tts (Groq Orpheus) voice name
    note*: string

proc voicesLoad*(text: string): int =
  ## `{"pools":{"kokoro":[..],"chatterbox":[..]},"tags":{tag:{kokoro,speed,
  ## chatterbox,exaggeration,cfg_weight,piper}}}`. Returns the tag count; 0
  ## with `voicesNote` saying why when the text is empty or malformed.
  gVTag = @[]; gVKokoro = @[]; gVSpeed = @[]; gVChatter = @[]
  gVExag = @[]; gVCfg = @[]; gVPiper = @[]; gVOrpheus = @[]
  gPoolKokoro = @[]; gPoolChatter = @[]; gPoolOrpheus = @[]
  if text.len == 0:
    gVoicesNote = "voices.json is empty or unreadable"
    return 0
  let root = jr.whole(text)
  let pools = jr.child(root, "pools")
  for e in jr.each(jr.child(pools, "kokoro")):
    let t = jr.asText(e, "")
    if t.len > 0: gPoolKokoro.add t
  for e in jr.each(jr.child(pools, "chatterbox")):
    let t = jr.asText(e, "")
    if t.len > 0: gPoolChatter.add t
  for e in jr.each(jr.child(pools, "orpheus")):
    let t = jr.asText(e, "")
    if t.len > 0: gPoolOrpheus.add t
  let tags = jr.child(root, "tags")
  for k in jr.keys(tags):
    let row = jr.child(tags, k)
    gVTag.add k
    gVKokoro.add jr.asText(jr.child(row, "kokoro"), "")
    gVSpeed.add jr.asFloat(jr.child(row, "speed"), 1.0)
    gVChatter.add jr.asText(jr.child(row, "chatterbox"), "")
    gVExag.add jr.asFloat(jr.child(row, "exaggeration"), 0.5)
    gVCfg.add jr.asFloat(jr.child(row, "cfg_weight"), 0.5)
    gVPiper.add jr.asText(jr.child(row, "piper"), "")
    gVOrpheus.add jr.asText(jr.child(row, "orpheus"), "")
  gVoicesNote = $gVTag.len & " tags, pools kokoro=" & $gPoolKokoro.len &
                " chatterbox=" & $gPoolChatter.len & " orpheus=" &
                $gPoolOrpheus.len
  if gVTag.len == 0: gVoicesNote = "voices.json parsed but has no `tags`"
  result = gVTag.len

proc voicesNote*(): string = gVoicesNote
proc voiceTagCount*(): int = gVTag.len
proc voiceTagAt*(i: int): string =
  if i < 0 or i >= gVTag.len: return ""
  result = gVTag[i]

proc pickFrom(pool: seq[string]; seed: string; fallback: string): string =
  if pool.len == 0: return fallback
  let h = fnv1a64(seed)
  result = pool[int(h mod uint64(pool.len))]

proc resolveVoice*(tag, personId: string): VoiceSpec =
  ## A tag -> the row in voices.json. An unmapped tag is resolved by a
  ## DETERMINISTIC pick from the pools keyed on the person id (so one person
  ## always sounds the same across restarts) and says so in `note`.
  var r = VoiceSpec(tag: tag, mapped: false, kokoro: "am_michael", speed: 1.0,
                    chatterbox: "default", exaggeration: 0.5, cfgWeight: 0.5,
                    piper: "", orpheus: "daniel", note: "")
  var i = 0
  while i < gVTag.len:
    if gVTag[i] == tag:
      r.mapped = true
      r.kokoro = defaulted(gVKokoro[i], "am_michael")
      r.speed = gVSpeed[i]
      r.chatterbox = defaulted(gVChatter[i], "default")
      r.exaggeration = gVExag[i]
      r.cfgWeight = gVCfg[i]
      r.piper = gVPiper[i]
      r.orpheus = defaulted(gVOrpheus[i], "daniel")
      r.note = "voices.json[" & tag & "]"
      return r
    i = i + 1
  let seed = (if personId.len > 0: personId else: tag)
  r.kokoro = pickFrom(gPoolKokoro, seed, "am_michael")
  r.chatterbox = pickFrom(gPoolChatter, seed, "default")
  r.orpheus = pickFrom(gPoolOrpheus, seed, "daniel")
  # Spread the speed a little too, so two unmapped people who hash to the
  # same pool entry still differ: 0.90 .. 1.10 in 0.02 steps.
  let step = int((fnv1a64("speed:" & seed) shr 8'u64) mod 11'u64)
  r.speed = quant3(0.90 + 0.02 * float(step))
  r.note = (if gVTag.len == 0: "no voices.json loaded (" & gVoicesNote & "); "
            else: "unmapped tag '" & tag & "'; ") &
           "picked by hash of '" & seed & "'"
  result = r

proc voiceSpecJson*(v: VoiceSpec): JsonObject =
  var o = obj()
  o.put("tag", v.tag)
  o.put("mapped", v.mapped)
  o.put("kokoro", v.kokoro)
  o.put("speed", v.speed)
  o.put("chatterbox", v.chatterbox)
  o.put("exaggeration", v.exaggeration)
  o.put("cfg_weight", v.cfgWeight)
  o.put("piper", v.piper)
  o.put("orpheus", v.orpheus)
  o.put("note", v.note)
  result = o

proc tempPath(suffix: string): string =
  gTmpSeq = gTmpSeq + 1
  result = joinPath(cWorkDir, "bm_" & $nowMs() & "_" & $gTmpSeq & suffix)

# ---------------------------------------------------------------------------
# Voices
# ---------------------------------------------------------------------------

proc piperDir(): string =
  var i = cPiperVoice.len - 1
  while i >= 0 and cPiperVoice[i] != '/' and cPiperVoice[i] != '\\':
    i = i - 1
  if i < 0: return cToolsDir
  result = cPiperVoice[0 ..< i]

proc voiceToPiperModel*(voice: string): string =
  ## A person's `voice` tag -> a concrete .onnx path. Every candidate is
  ## PROBED; an unknown tag falls back to the configured default voice rather
  ## than returning a path that does not exist (which piper would report as an
  ## obscure model-load failure).
  if voice.len == 0: return cPiperVoice
  if voice.endsWith(".onnx") or voice.contains("/") or voice.contains("\\"):
    if exists(voice): return voice
    return cPiperVoice
  let d = piperDir()
  let cands = @[joinPath(d, "en_US-" & voice & "-medium.onnx"),
                joinPath(d, "en_US-" & voice & "-low.onnx"),
                joinPath(d, voice & ".onnx")]
  for c in cands:
    if exists(c): return c
  result = cPiperVoice

# ---------------------------------------------------------------------------
# Probes -- an absolute path, present or missing, always.
# ---------------------------------------------------------------------------

proc probeOf(slot, engine, path, model: string): SpeechProbe =
  var r = SpeechProbe(slot: slot, engine: engine, path: path, model: model,
                      note: "", ok: true)
  if path.len > 0 and not exists(path):
    r.ok = false
    r.note = "missing: " & path
  elif model.len > 0 and not exists(model):
    r.ok = false
    r.note = "missing: " & model
  else:
    r.note = (if path.len > 0: "ok: " & path else: "ok (no external file)")
  result = r

proc speechConfigureCloud*(sttBaseUrl, sttKeyEnv, sttModel,
                           ttsBaseUrl, ttsKeyEnv, ttsModel: string) =
  cSttBase = defaulted(sttBaseUrl, "https://api.openai.com/v1")
  cSttKeyEnv = defaulted(sttKeyEnv, "OPENAI_API_KEY")
  cSttModel = defaulted(sttModel, "whisper-large-v3-turbo")
  cTtsBase = defaulted(ttsBaseUrl, "https://api.openai.com/v1")
  cTtsKeyEnv = defaulted(ttsKeyEnv, "OPENAI_API_KEY")
  cTtsModel = defaulted(ttsModel, "canopylabs/orpheus-v1-english")

proc sttUrl(): string = trimSlash(cSttBase) & "/audio/transcriptions"
proc ttsUrl(): string = trimSlash(cTtsBase) & "/audio/speech"
proc sttKey(): string = getEnv(cSttKeyEnv, "")
proc ttsKeyValue(): string = getEnv(cTtsKeyEnv, "")

proc apiErrorOf(resp: string): string =
  ## The provider's own message, verbatim. An OpenAI-compatible error is
  ## `{"error":{"message":...}}`; Groq's terms-acceptance refusal is a 400 in
  ## exactly that shape, and repeating it word for word is the difference
  ## between "TTS failed" and "click accept on the model's terms page".
  result = jr.asText(jr.child(jr.field(resp, "error"), "message"), "")
  if result.len == 0:
    result = jr.asText(jr.field(resp, "error"), "")

proc sttProbe*(): SpeechProbe =
  case cSttEngine
  of "whisper-server": result = probeOf("stt", cSttEngine, cWhisperExe, cWhisperModel)
  of "none": result = probeOf("stt", "none", "", "")
  of "openai-whisper":
    result = SpeechProbe(slot: "stt", engine: cSttEngine, path: sttUrl(),
                         model: cSttModel, note: "", ok: false)
    if sttKey().len == 0:
      result.note = cSttKeyEnv & " is not set in this process's environment, " &
        "so no transcription will be attempted (the key is never read from " &
        "config.json or from source; sttKeyEnv only NAMES the variable)"
    else:
      result.ok = true
      result.note = "ok (cloud; " & sttUrl() & " model " & cSttModel &
        "). MEASURED 2026-09-07 against Groq: 0.53 s round trip for a 42 KB wav"
  else:
    result = probeOf("stt", cSttEngine, "", "")
    result.ok = false
    result.note = "unknown stt engine '" & cSttEngine &
      "' (have: whisper-server, openai-whisper, none)"

proc kokoroModelPath(): string = joinPath(cKokoroRoot, "kokoro-v1.0.onnx")
proc kokoroServerPy(): string = joinPath(cKokoroRoot, "server.py")
proc chatterServerPy(): string = joinPath(cChatterRoot, "server.py")

proc serverProbe(engine, url, exe, model, serverPy, setupCmd: string): SpeechProbe =
  ## An HTTP engine is "present" when its venv python, its model/server file
  ## and its server.py all exist -- the files setup.ps1 leaves behind. Whether
  ## the SERVER answers is a separate question (`serverUp`), asked at synth
  ## time, because the backend starts it itself on first use.
  var r = probeOf("tts", engine, exe, model)
  if r.ok and not exists(serverPy):
    r.ok = false
    r.note = "missing: " & serverPy
  if not r.ok:
    r.note = r.note & " -- run: " & setupCmd
  else:
    r.note = "ok: " & exe & " serves " & url & " (started on first use)"
  result = r

proc ttsProbeCloud(): SpeechProbe =
  result = SpeechProbe(slot: "tts", engine: cTtsEngine, path: ttsUrl(),
                       model: cTtsModel, note: "", ok: false)
  if ttsKeyValue().len == 0:
    result.note = cTtsKeyEnv & " is not set in this process's environment, " &
      "so nothing will be synthesised (the key is never read from " &
      "config.json or from source; ttsKeyEnv only NAMES the variable)"
  else:
    result.ok = true
    result.note = "ok (cloud; " & ttsUrl() & " model " & cTtsModel &
      ", response_format wav). A 400 whose message asks you to accept the " &
      "model's terms is a REAL answer and is surfaced verbatim in the " &
      "segment's ttsNote, not folded into a generic failure"

proc ttsProbe*(): SpeechProbe =
  if cTtsEngine == "openai-tts": return ttsProbeCloud()
  case cTtsEngine
  of "piper": result = probeOf("tts", "piper", cPiperExe, cPiperVoice)
  of "kokoro":
    result = serverProbe("kokoro", cKokoroUrl, cKokoroExe, kokoroModelPath(),
                         kokoroServerPy(),
                         "powershell -ExecutionPolicy Bypass -File tools/kokoro/setup.ps1")
  of "chatterbox":
    result = serverProbe("chatterbox", cChatterUrl, cChatterExe, chatterServerPy(),
                         chatterServerPy(),
                         "powershell -ExecutionPolicy Bypass -File tools/chatterbox/setup.ps1")
    if result.ok and cVoicesDir.len > 0 and not dirPresent(cVoicesDir):
      result.note = result.note & "; voicesDir " & cVoicesDir &
                    " is MISSING, so every voice is the built-in default"
  of "client":
    result = probeOf("tts", "client", "", "")
    result.note = "ok (no wav here: the client synthesises from the say " &
                  "segment's text + voice spec)"
  of "sapi":
    result = probeOf("tts", "sapi", "", "")
    result.note = "ok (Windows System.Speech via powershell)"
  of "none": result = probeOf("tts", "none", "", "")
  else:
    result = probeOf("tts", cTtsEngine, "", "")
    result.ok = false
    result.note = "unknown tts engine '" & cTtsEngine &
                  "' (have: piper, kokoro, chatterbox, client, sapi, none)"

proc urlPort(url: string; default: int): int =
  ## The port of `http://host:PORT[/...]`, or `default` when there is none.
  var i = url.len - 1
  var digits = ""
  # Walk back over an optional path, then read digits before ':'.
  var j = 0
  var afterScheme = url
  if url.contains("://"):
    j = 0
    while j + 2 < url.len and url[j ..< j + 3] != "://": j = j + 1
    afterScheme = url[j + 3 ..< url.len]
  var k = 0
  var colonAt = -1
  while k < afterScheme.len and afterScheme[k] != '/':
    if afterScheme[k] == ':': colonAt = k
    k = k + 1
  if colonAt < 0: return default
  i = colonAt + 1
  while i < k:
    digits.add afterScheme[i]
    i = i + 1
  if digits.len == 0: return default
  var n = 0
  for c in digits:
    if c < '0' or c > '9': return default
    n = n * 10 + (int(c) - int('0'))
  result = n

proc serverUp(url: string): bool =
  let r = runCmd(quoteArg(cCurlExe) & " -s --max-time 3 " & quoteArg(url & "/health"))
  result = (not r.failed) and r.output.contains("\"ok\": true")

proc ensureKokoro(): bool =
  ## Same shape as ensureWhisper: Start-Process (no handle inheritance), once.
  if gKokoroSpawned: return true
  if serverUp(cKokoroUrl):
    gKokoroSpawned = true
    return true
  gKokoroSpawned = spawnDetached(cKokoroExe,
    quoteArg(kokoroServerPy()) & " --root " & quoteArg(cKokoroRoot) &
    " --port " & $urlPort(cKokoroUrl, 6971))
  result = gKokoroSpawned

proc ensureChatterbox(): bool =
  if gChatterSpawned: return true
  if serverUp(cChatterUrl):
    gChatterSpawned = true
    return true
  gChatterSpawned = spawnDetached(cChatterExe,
    quoteArg(chatterServerPy()) & " --voices-dir " & quoteArg(cVoicesDir) &
    " --port " & $urlPort(cChatterUrl, 6974))
  result = gChatterSpawned

proc httpTts(url, bodyJson, dst: string; retries: int; note: var string): bool =
  ## POST bodyJson to url/tts with `out` = dst; the server writes the wav
  ## itself. Success is judged on the FINISHED STATE -- a RIFF file at dst --
  ## never on curl's exit code, and a non-200 carries the server's `error`.
  let bodyPath = tempPath(".json")
  if not writeAll(bodyPath, bodyJson):
    note = "could not write the request body to " & bodyPath
    return false
  let respPath = tempPath(".resp")
  let r = runCmd(quoteArg(cCurlExe) & " -s -o " & quoteArg(respPath) &
                 " -w \"%{http_code}\" --retry " & $retries &
                 " --retry-connrefused --retry-delay 1 --max-time 600" &
                 " -H \"Content-Type: application/json\"" &
                 " --data-binary @" & quoteArg(bodyPath) & " " &
                 quoteArg(url & "/tts"))
  let resp = readAll(respPath)
  if r.failed:
    note = "curl could not be started: " & cCurlExe
    return false
  let code = oneLine(r.output)
  if code != "200":
    let err = jr.asText(jr.field(resp, "error"), "")
    note = "server answered HTTP " & (if code.len > 0: code else: "(none)") &
           (if err.len > 0: ": " & err else: ": " & oneLine(resp)) &
           (if code.len == 0 or code == "000": " -- is the server up at " & url &
              "? (started detached; the model takes seconds to load)" else: "")
    return false
  let bytes = readAll(dst)
  if bytes.len <= 44 or bytes[0 ..< 4] != "RIFF":
    note = "server said 200 but " & dst & " is " & $bytes.len &
           " bytes and not RIFF: " & oneLine(resp)
    return false
  let ms = jr.asText(jr.field(resp, "ms"), "?")
  note = "wrote " & $bytes.len & " bytes in " & ms & " ms"
  result = true

# ---------------------------------------------------------------------------
# TTS cache
# ---------------------------------------------------------------------------

proc ttsKey(engine, voiceModel, sentence: string): string =
  result = engine & "\x1f" & voiceModel & "\x1f" & normalizeText(sentence)

proc findTts(key: string): int =
  var i = 0
  while i < gTKey.len:
    if gTKey[i] == key: return i
    i = i + 1
  result = -1

proc hexEncode(s: string): string =
  const hexd = "0123456789abcdef"
  result = ""
  for ch in s:
    result.add hexd[(ord(ch) shr 4) and 0xF]
    result.add hexd[ord(ch) and 0xF]

proc hexNibble(c: char): int =
  if c >= '0' and c <= '9': return ord(c) - ord('0')
  if c >= 'a' and c <= 'f': return 10 + ord(c) - ord('a')
  if c >= 'A' and c <= 'F': return 10 + ord(c) - ord('A')
  result = -1

proc hexDecode(s: string): string =
  result = ""
  var i = 0
  while i + 1 < s.len:
    let hi = hexNibble(s[i])
    let lo = hexNibble(s[i+1])
    if hi < 0 or lo < 0: return ""
    result.add chr(hi * 16 + lo)
    i = i + 2

proc ttsPersist() =
  ## The key holds a `\x1f` unit separator, which the json reader does NOT
  ## decode back from `` on load (measured in mods/voice) -- so the key is
  ## stored hex-encoded and compared byte-exactly.
  let dir = ttsCacheDir()
  if dir.len == 0: return
  if not ensureTtsDir(): return
  var a = arr()
  var i = 0
  while i < gTKey.len:
    var o = obj()
    o.put("keyHex", hexEncode(gTKey[i]))
    o.put("wav", baseName(gTWav[i]))
    o.put("sentence", gTSentence[i])
    a.add done(o)
    i = i + 1
  var root = obj()
  root.put("schema", "aowlspt.basement.ttscache/1")
  root.put("entries", done(a))
  discard writeAll(joinPath(dir, IndexName), done(root).text & Sentinel)

proc ttsCacheLoad*() =
  ## Read the persisted index. Missing = empty (not an error). No sentinel =
  ## written torn, so discard it wholesale.
  gTKey = @[]; gTWav = @[]; gTSentence = @[]
  let dir = ttsCacheDir()
  if dir.len == 0:
    gTLoadNote = "no cacheDir configured"
    return
  let text = readAll(joinPath(dir, IndexName))
  if text.len == 0:
    gTLoadNote = "0 entries (no index on disk yet)"
    return
  if not text.endsWith(Sentinel):
    gTLoadNote = "index.json was written torn (no sentinel) -- starting empty"
    return
  var skipped = 0
  for e in jr.each(jr.field(text, "entries")):
    let key = hexDecode(jr.asText(jr.child(e, "keyHex"), ""))
    let wavBase = jr.asText(jr.child(e, "wav"), "")
    if key.len == 0 or wavBase.len == 0: continue
    let wavAbs = joinPath(dir, wavBase)
    if not exists(wavAbs):
      skipped = skipped + 1
      continue
    gTKey.add key
    gTWav.add wavAbs
    gTSentence.add jr.asText(jr.child(e, "sentence"), "")
  gTLoadNote = $gTKey.len & " entries loaded" &
    (if skipped > 0: ", " & $skipped & " dropped (wav missing)" else: "")

proc ttsCommit(key, dst, sentence: string) =
  ## The ONE place a finished wav enters the cache. Both the synchronous
  ## `ttsSegment` and the asynchronous poller land here, so a wav that arrived
  ## late is cached on exactly the same terms as one that arrived on time.
  let idx = findTts(key)
  if idx >= 0:
    gTWav[idx] = dst
    gTSentence[idx] = sentence
  else:
    gTKey.add key
    gTWav.add dst
    gTSentence.add sentence
  ttsPersist()

proc orpheusInput(spec: VoiceSpec; sentence: string; yell: bool): string =
  ## Orpheus honours inline emotive cues (`<laugh>`, `<sigh>`) but there is NO
  ## documented shout tag. WHAT WAS TRIED, so the next person does not repeat
  ## it: `<yell>` and `<shout>` are not in the published cue set and are read
  ## as literal text, which the model then SPEAKS -- that is worse than a flat
  ## delivery. What is left is the prosody the text itself carries, so a yell
  ## is upper-cased and given a terminal `!`. That is a WEAK effect and this
  ## comment says so rather than claiming the shout works.
  if not yell: return sentence
  var t = sentence.toUpperAscii()
  while t.len > 0 and (t[t.len-1] == '.' or t[t.len-1] == ' '):
    t = t[0 ..< t.len - 1]
  if t.len == 0: return sentence
  if t[t.len-1] != '!' and t[t.len-1] != '?': t.add '!'
  result = t

proc ttsCloudBody(spec: VoiceSpec; sentence: string; yell: bool): string =
  var o = obj()
  o.put("model", cTtsModel)
  o.put("input", orpheusInput(spec, sentence, yell))
  o.put("voice", defaulted(spec.orpheus, "daniel"))
  o.put("response_format", "wav")
  result = done(o).text

proc ttsCloudArgs(bodyPath, dst: string): string =
  ## The wav comes back as the RESPONSE BODY, so `-o` writes it straight to the
  ## cache path. An HTTP error writes the provider's JSON there instead, which
  ## is exactly why the failure note reads `dst` -- the message is surfaced
  ## verbatim rather than replaced by "not a wav".
  result = "-s --max-time 180" &
           " -H \"Content-Type: application/json\"" &
           " -H \"Authorization: Bearer " & ttsKeyValue() & "\"" &
           " --data-binary @" & quoteArg(bodyPath) &
           " -o " & quoteArg(dst) & " " & quoteArg(ttsUrl())

proc synthesize(spec: VoiceSpec; voiceModel, sentence: string; dst: string;
                note: var string): bool =
  ## Produce a wav at `dst`. Returns false with a note a person can act on.
  case cTtsEngine
  of "none":
    note = "tts=none: no audio produced"
    return false
  of "client":
    note = "tts=client: no wav here, the client synthesises from text + voice"
    return false
  of "kokoro":
    let p = ttsProbe()
    if not p.ok:
      note = "tts unavailable -- " & p.note
      return false
    discard ensureKokoro()
    let body = "{\"text\":" & jr.quoted(sentence) & ",\"voice\":" &
               jr.quoted(spec.kokoro) & ",\"speed\":" & fmtF(spec.speed) &
               ",\"out\":" & jr.quoted(dst) & "}"
    # kokoro loads in ~2-4 s (MEASURED 2026-09-07: 1.6-3.5 s); 30 retries at 1 s.
    var n2 = ""
    if not httpTts(cKokoroUrl, body, dst, 30, n2):
      note = "kokoro: " & n2
      return false
    note = "kokoro " & spec.kokoro & "@" & fmtF(spec.speed) & " " & n2
    return true
  of "chatterbox":
    let p = ttsProbe()
    if not p.ok:
      note = "tts unavailable -- " & p.note
      return false
    discard ensureChatterbox()
    let body = "{\"text\":" & jr.quoted(sentence) & ",\"voice\":" &
               jr.quoted(spec.chatterbox) & ",\"exaggeration\":" &
               fmtF(spec.exaggeration) & ",\"cfg_weight\":" & fmtF(spec.cfgWeight) &
               ",\"out\":" & jr.quoted(dst) & "}"
    # chatterbox loads ~3 GB of weights onto the GPU; allow 120 s of retries.
    var n2 = ""
    if not httpTts(cChatterUrl, body, dst, 120, n2):
      note = "chatterbox: " & n2
      return false
    note = "chatterbox " & spec.chatterbox & " " & n2
    return true
  of "openai-tts":
    let p = ttsProbe()
    if not p.ok:
      note = "tts unavailable -- " & p.note
      return false
    let bodyPath = tempPath(".json")
    if not writeAll(bodyPath, ttsCloudBody(spec, sentence, false)):
      note = "could not write the request body to " & bodyPath
      return false
    discard removeIfPresent(dst)
    let r = runCmd(quoteArg(cCurlExe) & " " & ttsCloudArgs(bodyPath, dst))
    if r.failed:
      note = "curl could not be started: " & cCurlExe
      return false
    let bytes = readAll(dst)
    if bytes.len <= 44 or bytes[0 ..< 4] != "RIFF":
      let em = apiErrorOf(bytes)
      note = ttsUrl() & " did not return a wav (" & $bytes.len &
             " bytes at " & dst & ")" &
             (if em.len > 0: ": " & em else: ": " & oneLine(bytes))
      return false
    note = cTtsModel & "/" & defaulted(spec.orpheus, "daniel") & " wrote " &
           $bytes.len & " bytes"
    return true
  of "piper":
    let p = ttsProbe()
    if not p.ok:
      note = "tts unavailable -- " & p.note
      return false
    # `--output_file` makes piper write the RIFF header itself; the alternative
    # (`--output-raw` on stdout) is a binary pipe that has deadlocked before.
    let r = runCmd(quoteArg(cPiperExe) & " --model " & quoteArg(voiceModel) &
                   " --output_file " & quoteArg(dst), input = sentence & "\n")
    if r.failed:
      note = "piper could not be started: " & cPiperExe
      return false
    let sz = sizeOfFile(dst)
    if sz <= 44:
      note = "piper produced " & $sz & " bytes (exit " & $r.code & "): " &
             oneLine(r.output)
      return false
    note = "piper wrote " & $sz & " bytes"
    return true
  of "sapi":
    # 16 kHz mono 16-bit, stated explicitly rather than taking the voice's
    # default rate -- whisper.cpp wants 16 kHz and will not resample.
    let ps = "Add-Type -AssemblyName System.Speech; " &
      "$f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000," &
      "[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen," &
      "[System.Speech.AudioFormat.AudioChannel]::Mono); " &
      "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " &
      "$s.SetOutputToWaveFile(" & psQuote(dst) & ",$f); " &
      "$s.Speak(" & psQuote(sentence) & "); $s.Dispose()"
    let r = runCmd("powershell -NoProfile -NonInteractive -Command \"" &
                   ps.replace("\"", "") & "\"")
    if r.failed:
      note = "powershell could not be started"
      return false
    let sz = sizeOfFile(dst)
    if sz <= 44:
      note = "sapi produced " & $sz & " bytes: " & oneLine(r.output)
      return false
    note = "sapi wrote " & $sz & " bytes"
    return true
  else:
    note = "tts unavailable -- unknown engine '" & cTtsEngine & "'"
    result = false

proc voiceModelKey*(spec: VoiceSpec; voice: string): string =
  ## The RESOLVED voice as the cache key sees it: for piper the .onnx path,
  ## for kokoro `id@speed`, for chatterbox `stem@exX,cfgY` -- every knob that
  ## changes the audio is in the key, so two tags that share a kokoro id but
  ## differ in speed are two entries.
  case cTtsEngine
  of "piper":
    result = voiceToPiperModel(if spec.mapped and spec.piper.len > 0: spec.piper
                               else: voice)
  of "kokoro": result = spec.kokoro & "@" & fmtF(spec.speed)
  of "openai-tts": result = cTtsModel & "/" & defaulted(spec.orpheus, "daniel")
  of "chatterbox":
    result = spec.chatterbox & "@ex" & fmtF(spec.exaggeration) & ",cfg" &
             fmtF(spec.cfgWeight)
  else: result = voice

proc ttsSegment*(voice, sentence: string; note: var string;
                 cached: var bool; personId: string = ""): string =
  ## One sentence -> a wav path, or "" with a note saying why not. `personId`
  ## only matters for a tag voices.json does not list: it seeds the
  ## deterministic pool pick so that person always gets the same voice.
  cached = false
  note = ""
  if normalizeText(sentence).len == 0:
    note = "nothing to speak (the sentence is empty after normalisation)"
    return ""
  let spec = resolveVoice(voice, personId)
  let model = voiceModelKey(spec, voice)
  let key = ttsKey(cTtsEngine, model, sentence)
  let idx = findTts(key)
  if idx >= 0 and exists(gTWav[idx]):
    gTHits = gTHits + 1
    cached = true
    note = "cache hit: " & gTWav[idx]
    return gTWav[idx]
  gTMiss = gTMiss + 1
  let dir = ttsCacheDir()
  if dir.len == 0 or not ensureTtsDir():
    # Still speak, just without persistence -- and say so.
    let tmp = tempPath(".wav")
    var n2 = ""
    if not synthesize(spec, model, sentence, tmp, n2):
      note = n2
      return ""
    note = n2 & " (NOT cached: no writable cacheDir)"
    return tmp
  let dst = joinPath(dir, hex64(fnv1a64(key)) & ".wav")
  var n2 = ""
  if not synthesize(spec, model, sentence, dst, n2):
    note = n2
    return ""
  ttsCommit(key, dst, sentence)
  note = n2 & " (cached as " & baseName(dst) & ")"
  result = dst

proc sayPayloadOf*(personId, voice, text: string; segmentIdx: int;
                   final: bool; source, wav: string; cached: bool;
                   note: string): string =
  ## THE shape of a spoken line, given a wav that has ALREADY been decided.
  ## Split out of `sayPayload` so the asynchronous path -- which learns the wav
  ## path a second or two after the sentence -- cannot grow a second copy of
  ## this object. That drift is exactly the bug of 2026-09-07 (`"wav":""`
  ## hardcoded in the encounter machine's own copy).
  ##
  ## `tts` names the engine so a client knows whether an empty `wav` means
  ## "synthesise it yourself" (client) or "the backend failed / gave up
  ## waiting" (anything else, with ttsNote saying which). `voiceSpec` is the
  ## resolved voices.json row so a client-side engine maps the same person to
  ## the same voice.
  var o = obj()
  o.put("personId", personId)
  o.put("text", text)
  o.put("wav", wav)
  o.put("segmentIdx", segmentIdx)
  o.put("final", final)
  o.put("cachedWav", cached)
  o.put("source", source)
  o.put("voice", voice)
  o.put("tts", cTtsEngine)
  o.put("voiceSpec", voiceSpecJson(resolveVoice(voice, personId)))
  o.put("ttsNote", note)
  result = done(o).text

proc sayPayload*(personId, voice, text: string; segmentIdx: int; final: bool;
                 source: string; wav: var string; cached: var bool;
                 note: var string): string =
  ## THE shape of a spoken line, and the ONLY place that decides whether it
  ## carries a wav.
  ##
  ## MEASURED 2026-09-07: `/say` produced piper wavs while every line the
  ## ENCOUNTER machine emitted (the threat bark after `player_aimed_at`)
  ## reached the client with `"wav":""`, so the plugin logged "(no wav -- TTS
  ## is off, missing or failed; the text IS the line)" and the world was mute
  ## exactly when it was most dramatic. The cause was two copies of this
  ## object, only one of which called `ttsSegment`. There is now one, and
  ## `note` always says why a wav is absent -- never a silent "".
  wav = ""
  cached = false
  note = ""
  if text.len > 0:
    wav = ttsSegment(voice, text, note, cached, personId)
  else:
    note = "no text in this segment, so nothing was synthesised"
  # `tts` names the engine so a client knows whether an empty `wav` means
  # "synthesise it yourself" (client) or "the backend failed" (anything else,
  # with ttsNote saying why). `voiceSpec` is the resolved voices.json row so a
  # client-side engine can map the same person to the same voice.
  result = sayPayloadOf(personId, voice, text, segmentIdx, final, source,
                        wav, cached, note)

# ---------------------------------------------------------------------------
# ASYNCHRONOUS TTS + the ordered say queue
#
# THE PROBLEM, MEASURED 2026-09-07 on the live sidecar: `ttsSegment` ran INSIDE
# the tick, under the mod lock, because `saySink` called it while
# `pumpStreamingTurns` held the lock. One kokoro sentence is ~1.3 s, so a
# five-sentence turn held the lock for ~6 s and every route queued behind it --
# an `/events` long-poll TIMED OUT mid-turn.
#
# THE SHAPE OF THE FIX is the one the LLM stream already uses: a request is
# STARTED and the tick picks up its completion. curl is spawned detached; the
# server writes the wav and then an empty `<wav>.done` marker (added to
# tools/kokoro/server.py and tools/chatterbox/server.py); the poller looks for
# the marker. Nothing here ever waits on a socket or a process, so the lock is
# only ever held across memory reads.
#
# WHAT IS DELIBERATELY NOT ASYNCHRONOUS: piper and sapi. Both are subprocesses
# we run to completion for their exit status, and there is no server to leave a
# marker. They stay synchronous and `ttsAsyncNote` SAYS SO -- a probe that
# claimed "async" for every engine would be a check that cannot fail.
#
# THE BOUNDED WAIT: `ttsTimeoutMs` (default 8000). After it, the segment is
# emitted WITHOUT a wav and the note says the wait was given up on, so the
# client shows the subtitle rather than the turn going silent forever. The
# entry is NOT dropped: it stays in the table as `late`, and when the wav does
# land it is committed to the cache, so the same sentence is instant next time.
# ---------------------------------------------------------------------------

var cTtsAsync: bool = true
var cTtsTimeoutMs: int = 8000

var gPKey: seq[string] = @[]        ## cache key, for the commit on arrival
var gPDst: seq[string] = @[]        ## where the server is writing the wav
var gPResp: seq[string] = @[]       ## curl's -o body, read only to explain a failure
var gPSent: seq[string] = @[]
var gPStart: seq[int64] = @[]
var gPLate: seq[bool] = @[]         ## true once the bounded wait was given up on
var gPId: seq[int] = @[]
var gPNextId: int = 0

var gTAsyncStarts: int = 0
var gTAsyncArrived: int = 0
var gTAsyncTimeouts: int = 0
var gTAsyncLateArrivals: int = 0
var gTAsyncSpawnFails: int = 0
var gTAsyncNote: string = "no asynchronous synthesis yet"

proc speechConfigureAsync*(async: bool; timeoutMs: int) =
  cTtsAsync = async
  if timeoutMs > 0: cTtsTimeoutMs = timeoutMs

proc ttsAsyncEngine*(): bool =
  ## The two local HTTP servers (which leave a `<wav>.done` marker themselves)
  ## and the cloud endpoint (where `cmd` writes the marker after curl exits).
  result = cTtsEngine == "kokoro" or cTtsEngine == "chatterbox" or
           cTtsEngine == "openai-tts"

proc ttsAsyncActive*(): bool = cTtsAsync and ttsAsyncEngine()

proc ttsTimeoutMs*(): int = cTtsTimeoutMs

proc ttsAsyncNote*(): string =
  if not ttsAsyncEngine():
    result = "engine '" & cTtsEngine & "' is SYNCHRONOUS here (it is a " &
             "subprocess we run to completion, not an endpoint that can leave " &
             "a done-marker); only kokoro, chatterbox and openai-tts " &
             "synthesise off the tick"
  elif not cTtsAsync:
    result = "asynchronous synthesis is available for '" & cTtsEngine &
             "' but ttsAsync is false in config.json, so the tick blocks on it"
  else:
    result = "asynchronous: detached curl, the server writes <wav>.done, the " &
             "tick collects it; bounded wait " & $cTtsTimeoutMs & " ms"

proc ttsPendingCount*(): int = gPId.len

proc findPending(id: int): int =
  var i = 0
  while i < gPId.len:
    if gPId[i] == id: return i
    i = i + 1
  result = -1

proc dropPending(i: int) =
  if i < 0 or i >= gPId.len: return
  var j = i
  while j + 1 < gPId.len:
    let tgPId = gPId[j+1]
    gPId[j] = tgPId
    let tgPKey = gPKey[j+1]
    gPKey[j] = tgPKey
    let tgPDst = gPDst[j+1]
    gPDst[j] = tgPDst
    let tgPResp = gPResp[j+1]
    gPResp[j] = tgPResp
    let tgPSent = gPSent[j+1]
    gPSent[j] = tgPSent
    let tgPStart = gPStart[j+1]
    gPStart[j] = tgPStart
    let tgPLate = gPLate[j+1]
    gPLate[j] = tgPLate
    j = j + 1
  discard gPId.pop()
  discard gPKey.pop()
  discard gPDst.pop()
  discard gPResp.pop()
  discard gPSent.pop()
  discard gPStart.pop()
  discard gPLate.pop()

proc ttsBodyFor(spec: VoiceSpec; sentence, dst: string): string =
  if cTtsEngine == "chatterbox":
    result = "{\"text\":" & jr.quoted(sentence) & ",\"voice\":" &
             jr.quoted(spec.chatterbox) & ",\"exaggeration\":" &
             fmtF(spec.exaggeration) & ",\"cfg_weight\":" &
             fmtF(spec.cfgWeight) & ",\"out\":" & jr.quoted(dst) & "}"
  else:
    result = "{\"text\":" & jr.quoted(sentence) & ",\"voice\":" &
             jr.quoted(spec.kokoro) & ",\"speed\":" & fmtF(spec.speed) &
             ",\"out\":" & jr.quoted(dst) & "}"

proc ttsStartAsync(spec: VoiceSpec; sentence, key, dst: string; yell: bool;
                   id: var int; note: var string): bool =
  ## Spawn the request and return AT ONCE. False means nothing was started and
  ## the caller must fall back to the synchronous path -- never "wait and see".
  id = -1
  let cloud = cTtsEngine == "openai-tts"
  let url = (if cTtsEngine == "chatterbox": cChatterUrl else: cKokoroUrl)
  if not cloud:
    if cTtsEngine == "chatterbox": discard ensureChatterbox()
    else: discard ensureKokoro()
  let donePath = dst & ".done"
  # A marker left by an EARLIER synthesis of this same sentence would be read
  # as "this request finished" on the very first poll, and the caller would
  # ship whatever bytes happen to be at `dst`. Clearing it is not optional.
  if not removeIfPresent(donePath):
    note = "a stale " & donePath & " could not be removed, so a done-marker " &
           "could not be trusted; synthesised synchronously instead"
    return false
  let bodyPath = tempPath(".json")
  let body = (if cloud: ttsCloudBody(spec, sentence, yell)
              else: ttsBodyFor(spec, sentence, dst))
  if not writeAll(bodyPath, body):
    note = "could not write the request body to " & bodyPath
    return false
  # For the cloud engine the WAV IS THE RESPONSE BODY, so curl writes it to
  # `dst` and an HTTP error lands there instead -- which is why `dst` is also
  # the file the failure note reads: the provider's message survives verbatim.
  let respPath = (if cloud: dst else: tempPath(".resp"))
  if cloud:
    discard removeIfPresent(dst)
    if ttsKeyValue().len == 0:
      note = cTtsKeyEnv & " is not set, so no request was made"
      return false
    # No server to leave the marker, so `cmd` writes it after curl exits 0.
    # This is `cmd` as the DIRECT child of startProcess, not reached through
    # `runCmd`: the measured 10110 ms EOF hang was `cmd /c start` inside a
    # `runCmd`, whose pipe the grandchild inherited. There is no such pipe on
    # this path -- see util.spawnDetachedProc for the measurement.
    let line = "/s /c \"" & quoteArg(cCurlExe) & " " &
               ttsCloudArgs(bodyPath, dst) & " && type nul > " &
               quoteArg(donePath) & "\""
    if not spawnDetached("cmd.exe", line):
      gTAsyncSpawnFails = gTAsyncSpawnFails + 1
      note = "could not spawn a detached curl (" & spawnNote() & ")"
      return false
    gPNextId = gPNextId + 1
    id = gPNextId
    gPId.add id
    gPKey.add key
    gPDst.add dst
    gPResp.add respPath
    gPSent.add sentence
    gPStart.add nowMs()
    gPLate.add false
    gTAsyncStarts = gTAsyncStarts + 1
    gTAsyncNote = "started " & cTtsEngine & " request " & $id & " in " &
                  $spawnLastMs() & " ms (spawn only)"
    note = "synthesising asynchronously into " & baseName(dst) & " via " &
           cTtsModel
    return true
  # --retry-connrefused with a long --max-time so a COLD server (kokoro loads
  # in 1.6-3.5 s) still lands the wav; the bounded wait below is what protects
  # the turn, not curl's timeout.
  let args = "-s -o " & quoteArg(respPath) &
             " --retry 30 --retry-connrefused --retry-delay 1 --max-time 600" &
             " -H \"Content-Type: application/json\"" &
             " --data-binary @" & quoteArg(bodyPath) & " " &
             quoteArg(url & "/tts")
  if not spawnDetached(cCurlExe, args):
    gTAsyncSpawnFails = gTAsyncSpawnFails + 1
    note = "could not spawn a detached curl (" & spawnNote() & ")"
    return false
  gPNextId = gPNextId + 1
  id = gPNextId
  gPId.add id
  gPKey.add key
  gPDst.add dst
  gPResp.add respPath
  gPSent.add sentence
  gPStart.add nowMs()
  gPLate.add false
  gTAsyncStarts = gTAsyncStarts + 1
  gTAsyncNote = "started " & cTtsEngine & " request " & $id & " in " &
                $spawnLastMs() & " ms (spawn only)"
  note = "synthesising asynchronously into " & baseName(dst)
  result = true

proc wavIsComplete(dst: string): bool =
  ## The marker says the server finished; the RIFF magic says the bytes really
  ## are a wav. BOTH, because either alone has been wrong: a marker can outlive
  ## a failed write, and a RIFF header appears before the file is whole when it
  ## is written in place (which is why the server now renames into position).
  if not exists(dst & ".done"): return false
  let bytes = readAll(dst)
  result = bytes.len > 44 and bytes[0 ..< 4] == "RIFF"

proc ttsPollAsync*(id: int; wav: var string; note: var string): int =
  ## 1 = ready (`wav` is the path), 0 = still pending, -1 = gave up waiting
  ## (emit the text without audio and SAY why). Never blocks.
  wav = ""
  note = ""
  let i = findPending(id)
  if i < 0:
    note = "no pending synthesis with id " & $id
    return -1
  if wavIsComplete(gPDst[i]):
    wav = gPDst[i]
    let waited = nowMs() - gPStart[i]
    ttsCommit(gPKey[i], gPDst[i], gPSent[i])
    gTAsyncArrived = gTAsyncArrived + 1
    note = cTtsEngine & " wrote " & baseName(gPDst[i]) & " in " & $waited &
           " ms, off the tick"
    dropPending(i)
    return 1
  let waited = nowMs() - gPStart[i]
  if waited >= int64(cTtsTimeoutMs):
    gTAsyncTimeouts = gTAsyncTimeouts + 1
    gPLate[i] = true
    let resp = oneLine(readAll(gPResp[i]))
    note = "no wav after " & $waited & " ms (ttsTimeoutMs = " &
           $cTtsTimeoutMs & "): the line is being spoken as text only. The " &
           "request is still being watched and will fill the cache if it " &
           "lands" & (if resp.len > 0: "; the server said: " & resp
                      else: "; the server has answered nothing yet")
    return -1
  result = 0

proc ttsPumpLate*(): int =
  ## Entries whose bounded wait expired but whose wav may still arrive. Called
  ## from the tick: a late arrival is CACHED so the next identical sentence is
  ## instant, and an entry that never arrives is dropped after 8x the timeout
  ## rather than accumulating forever.
  result = 0
  var i = 0
  while i < gPId.len:
    if not gPLate[i]:
      i = i + 1
      continue
    if wavIsComplete(gPDst[i]):
      ttsCommit(gPKey[i], gPDst[i], gPSent[i])
      gTAsyncLateArrivals = gTAsyncLateArrivals + 1
      result = result + 1
      dropPending(i)
      continue
    if nowMs() - gPStart[i] > int64(cTtsTimeoutMs) * 8:
      discard removeIfPresent(gPResp[i])
      dropPending(i)
      continue
    i = i + 1

# ---------------------------------------------------------------------------
# The ordered say queue
#
# A segment is emitted ONLY when its wav exists, and IN PER-PERSON ORDER: two
# people can speak concurrently but one person's second sentence never
# overtakes their first, because a client plays segments in the order they
# arrive. The queue lives here, next to the synthesis, so the two cannot drift;
# the emission itself is `stream.emitEvent`, which is what every other
# directive already goes through.
# ---------------------------------------------------------------------------

var gQPerson: seq[string] = @[]
var gQVoice: seq[string] = @[]
var gQText: seq[string] = @[]
var gQIdx: seq[int] = @[]
var gQFinal: seq[bool] = @[]
var gQSource: seq[string] = @[]
var gQAck: seq[bool] = @[]
var gQHandle: seq[int] = @[]      ## -1 = resolved already
var gQWav: seq[string] = @[]
var gQCached: seq[bool] = @[]
var gQNote: seq[string] = @[]
var gQReady: seq[bool] = @[]
# The hearing decoration the EMITTER decided (encounter.emitBarkEx needs the
# audibility verdict before it picks the words, so it cannot be re-derived at
# drain time). `gQDeco` false means "let stream.emitEvent decide", which is
# what it already does for any say payload without an "audible" field.
var gQDeco: seq[bool] = @[]
var gQDist: seq[float] = @[]
var gQMode: seq[string] = @[]
var gQAudible: seq[bool] = @[]
var gQReaction: seq[bool] = @[]
var gQWhy: seq[string] = @[]

var gQEmitted: int = 0
var gQMuted: int = 0

proc sayQueueDepth*(): int = gQPerson.len
proc sayEmitted*(): int = gQEmitted
proc sayMuted*(): int = gQMuted

proc qDrop(i: int) =
  var j = i
  while j + 1 < gQPerson.len:
    let tgQPerson = gQPerson[j+1]
    gQPerson[j] = tgQPerson
    let tgQVoice = gQVoice[j+1]
    gQVoice[j] = tgQVoice
    let tgQText = gQText[j+1]
    gQText[j] = tgQText
    let tgQIdx = gQIdx[j+1]
    gQIdx[j] = tgQIdx
    let tgQFinal = gQFinal[j+1]
    gQFinal[j] = tgQFinal
    let tgQSource = gQSource[j+1]
    gQSource[j] = tgQSource
    let tgQAck = gQAck[j+1]
    gQAck[j] = tgQAck
    let tgQHandle = gQHandle[j+1]
    gQHandle[j] = tgQHandle
    let tgQWav = gQWav[j+1]
    gQWav[j] = tgQWav
    let tgQCached = gQCached[j+1]
    gQCached[j] = tgQCached
    let tgQNote = gQNote[j+1]
    gQNote[j] = tgQNote
    let tgQReady = gQReady[j+1]
    gQReady[j] = tgQReady
    let tgQDeco = gQDeco[j+1]
    gQDeco[j] = tgQDeco
    let tgQDist = gQDist[j+1]
    gQDist[j] = tgQDist
    let tgQMode = gQMode[j+1]
    gQMode[j] = tgQMode
    let tgQAudible = gQAudible[j+1]
    gQAudible[j] = tgQAudible
    let tgQReaction = gQReaction[j+1]
    gQReaction[j] = tgQReaction
    let tgQWhy = gQWhy[j+1]
    gQWhy[j] = tgQWhy
    j = j + 1
  discard gQPerson.pop()
  discard gQVoice.pop()
  discard gQText.pop()
  discard gQIdx.pop()
  discard gQFinal.pop()
  discard gQSource.pop()
  discard gQAck.pop()
  discard gQHandle.pop()
  discard gQWav.pop()
  discard gQCached.pop()
  discard gQNote.pop()
  discard gQReady.pop()
  discard gQDeco.pop()
  discard gQDist.pop()
  discard gQMode.pop()
  discard gQAudible.pop()
  discard gQReaction.pop()
  discard gQWhy.pop()

proc sayEnqueue*(personId, voice, text: string; segmentIdx: int; final: bool;
                 source: string; needsAck: bool;
                 deco: bool = false; distanceM: float = 0.0;
                 mode: string = "speak"; audible: bool = true;
                 reaction: bool = false; why: string = ""): bool =
  ## Queue one spoken segment and START its synthesis. Returns true when the
  ## segment was queued -- NOT when it has been emitted; `sayDrain` does that,
  ## this tick or a later one.
  ##
  ## The synchronous engines resolve here and now, so nothing about piper's
  ## behaviour changes; only kokoro and chatterbox defer.
  var handle = -1
  var wav = ""
  var cached = false
  var note = ""
  var ready = true
  if text.len == 0:
    note = "no text in this segment, so nothing was synthesised"
  elif ttsAsyncActive():
    let spec = resolveVoice(voice, personId)
    let model = voiceModelKey(spec, voice)
    # A YELL is different AUDIO for the cloud engine (the input text is
    # upper-cased), so it must be a different cache entry or the first
    # delivery of a sentence would be served for both. It changes nothing for
    # kokoro/chatterbox, whose key is deliberately left alone so they do not
    # start missing the cache for a distinction they do not make.
    let keyModel = (if cTtsEngine == "openai-tts" and mode == "yell":
                      model & "|yell" else: model)
    let key = ttsKey(cTtsEngine, keyModel, text)
    let idx = findTts(key)
    if idx >= 0 and exists(gTWav[idx]):
      gTHits = gTHits + 1
      wav = gTWav[idx]
      cached = true
      note = "cache hit: " & wav
    else:
      gTMiss = gTMiss + 1
      let p = ttsProbe()
      let dir = ttsCacheDir()
      if not p.ok:
        note = "tts unavailable -- " & p.note
      elif dir.len == 0 or not ensureTtsDir():
        note = "no writable cache directory, so there is nowhere for the " &
               "server to write the wav; the line is text only"
      else:
        let dst = joinPath(dir, hex64(fnv1a64(key)) & ".wav")
        var n2 = ""
        if ttsStartAsync(spec, text, key, dst, mode == "yell", handle, n2):
          ready = false
          note = n2
        else:
          # Falling back to the blocking path is a DECISION, and it is stated:
          # nothing was started, so waiting here is the only way to have audio.
          var n3 = ""
          wav = ttsSegment(voice, text, n3, cached, personId)
          note = "asynchronous start refused (" & n2 &
                 "); synthesised on the tick instead: " & n3
  else:
    wav = ttsSegment(voice, text, note, cached, personId)
  gQPerson.add personId
  gQVoice.add voice
  gQText.add text
  gQIdx.add segmentIdx
  gQFinal.add final
  gQSource.add source
  gQAck.add needsAck
  gQHandle.add handle
  gQWav.add wav
  gQCached.add cached
  gQNote.add note
  gQReady.add ready
  gQDeco.add deco
  gQDist.add distanceM
  gQMode.add mode
  gQAudible.add audible
  gQReaction.add reaction
  gQWhy.add why
  result = true

proc sayDrain*(): int =
  ## Emit every segment whose wav has landed, in per-person order. Returns the
  ## number emitted. Safe to call as often as you like; it never blocks.
  ##
  ## A person is BLOCKED by their own first unresolved segment and by nothing
  ## else, so a slow line from one NPC cannot mute another's.
  result = 0
  var blocked: seq[string] = @[]
  var i = 0
  while i < gQPerson.len:
    var isBlocked = false
    for b in blocked:
      if b == gQPerson[i]:
        isBlocked = true
        break
    if isBlocked:
      i = i + 1
      continue
    if not gQReady[i]:
      var w = ""
      var n = ""
      let st = ttsPollAsync(gQHandle[i], w, n)
      if st == 0:
        blocked.add gQPerson[i]
        i = i + 1
        continue
      gQReady[i] = true
      gQWav[i] = w
      gQNote[i] = n
      if st < 0: gQMuted = gQMuted + 1
    var payload = sayPayloadOf(gQPerson[i], gQVoice[i], gQText[i], gQIdx[i],
                               gQFinal[i], gQSource[i], gQWav[i], gQCached[i],
                               gQNote[i])
    if gQDeco[i]:
      # The emitter already decided who can hear this and in what voice mode.
      # Re-deciding here would use the distance at DRAIN time, which is a
      # second or two later and after the player has moved.
      payload = decorateSay(payload, gQDist[i], gQMode[i], gQAudible[i],
                            gQReaction[i], gQWhy[i])
    discard emitEvent("say", payload, gQAck[i])
    discard broadcast("basement.say", payload)
    gQEmitted = gQEmitted + 1
    result = result + 1
    qDrop(i)

proc ttsAsyncStats*(): JsonObject =
  var o = obj()
  o.put("enabled", cTtsAsync)
  o.put("engineCanAsync", ttsAsyncEngine())
  o.put("active", ttsAsyncActive())
  o.put("timeoutMs", cTtsTimeoutMs)
  o.put("starts", gTAsyncStarts)
  o.put("arrived", gTAsyncArrived)
  o.put("timedOut", gTAsyncTimeouts)
  o.put("lateArrivals", gTAsyncLateArrivals)
  o.put("spawnFailures", gTAsyncSpawnFails)
  o.put("pending", gPId.len)
  o.put("queueDepth", gQPerson.len)
  o.put("emitted", gQEmitted)
  o.put("mutedByTimeout", gQMuted)
  o.put("spawnMode", spawnMode())
  o.put("spawnCalls", spawnCalls())
  o.put("spawnFallbacks", spawnFallbacks())
  o.put("spawnFailures", spawnFailures())
  o.put("spawnLastMs", int(spawnLastMs()))
  o.put("spawnNote", spawnNote())
  o.put("lastStart", gTAsyncNote)
  o.put("note", ttsAsyncNote())
  result = o

proc ttsStats*(): JsonObject =
  var o = obj()
  o.put("engine", cTtsEngine)
  o.put("dir", ttsCacheDir())
  o.put("entries", gTKey.len)
  o.put("hits", gTHits)
  o.put("misses", gTMiss)
  o.put("load", gTLoadNote)
  o.put("defaultVoice", cPiperVoice)
  o.put("kokoroUrl", cKokoroUrl)
  o.put("kokoroRoot", cKokoroRoot)
  o.put("chatterboxUrl", cChatterUrl)
  o.put("chatterboxRoot", cChatterRoot)
  o.put("voicesDir", cVoicesDir)
  o.put("voices", gVoicesNote)
  o.put("note", "keyed on (tts engine, RESOLVED voice model (piper path | " &
    "kokoro id@speed | chatterbox stem@ex,cfg), normalized sentence); a hit " &
    "returns the same file on disk, so the bytes are identical by construction")
  result = o

# ---------------------------------------------------------------------------
# WAV plumbing
# ---------------------------------------------------------------------------

proc le32(v: int): string =
  result = ""
  result.add chr(v and 0xFF)
  result.add chr((v shr 8) and 0xFF)
  result.add chr((v shr 16) and 0xFF)
  result.add chr((v shr 24) and 0xFF)

proc le16(v: int): string =
  result = ""
  result.add chr(v and 0xFF)
  result.add chr((v shr 8) and 0xFF)

proc rd32(s: string; at: int): int =
  if at + 3 >= s.len: return -1
  result = ord(s[at]) or (ord(s[at+1]) shl 8) or (ord(s[at+2]) shl 16) or
           (ord(s[at+3]) shl 24)

proc rd16(s: string; at: int): int =
  if at + 1 >= s.len: return -1
  result = ord(s[at]) or (ord(s[at+1]) shl 8)

proc riffHeader(dataLen, rate, channels, bits: int): string =
  ## A canonical 44-byte PCM header. Both size fields are recomputed here, so
  ## re-emitting the whole file after each append is what "maintaining the
  ## header" means -- there is no partial-write path that can leave a stale size.
  let byteRate = rate * channels * (bits div 8)
  let blockAlign = channels * (bits div 8)
  result = "RIFF" & le32(36 + dataLen) & "WAVE" &
           "fmt " & le32(16) & le16(1) & le16(channels) & le32(rate) &
           le32(byteRate) & le16(blockAlign) & le16(bits) &
           "data" & le32(dataLen)

proc parseWav(bytes: string; rate, channels, bits: var int;
              payload: var string; note: var string): bool =
  ## Pull the PCM payload out of a RIFF/WAVE file by WALKING the chunk list --
  ## `data` is not always at offset 36 (SAPI writes a `fact` chunk first), and
  ## assuming it is would silently prepend 12 bytes of chunk header to the audio.
  rate = 0; channels = 0; bits = 0; payload = ""
  if bytes.len < 44 or bytes[0 ..< 4] != "RIFF" or bytes[8 ..< 12] != "WAVE":
    note = "not a RIFF/WAVE file"
    return false
  var i = 12
  var haveFmt = false
  while i + 8 <= bytes.len:
    let id = bytes[i ..< i+4]
    let sz = rd32(bytes, i + 4)
    if sz < 0 or i + 8 + sz > bytes.len:
      # A truncated final chunk: take what is there for `data`, refuse otherwise.
      if id == "data" and haveFmt:
        payload = bytes[i+8 ..< bytes.len]
        note = "data chunk was truncated; took " & $payload.len & " bytes"
        return true
      note = "chunk '" & id & "' claims " & $sz & " bytes but the file has " &
             $(bytes.len - i - 8)
      return false
    if id == "fmt ":
      let fmtTag = rd16(bytes, i + 8)
      channels = rd16(bytes, i + 10)
      rate = rd32(bytes, i + 12)
      bits = rd16(bytes, i + 22)
      haveFmt = true
      if fmtTag != 1:
        note = "wav is not PCM (format tag " & $fmtTag & ")"
        return false
    elif id == "data":
      if not haveFmt:
        note = "the data chunk came before fmt "
        return false
      payload = bytes[i+8 ..< i+8+sz]
      note = ""
      return true
    i = i + 8 + sz + (sz and 1)      # chunks are word-aligned
  note = "no data chunk in the wav"
  result = false

# ---------------------------------------------------------------------------
# STT sessions
# ---------------------------------------------------------------------------

proc sttSessionCount*(): int = gSId.len

proc findSession(id: string): int =
  var i = 0
  while i < gSId.len:
    if gSId[i] == id: return i
    i = i + 1
  result = -1

proc closeSession(idx: int) =
  if idx < 0 or idx >= gSId.len: return
  var a: seq[string] = @[]; var b: seq[string] = @[]; var c: seq[string] = @[]
  var r: seq[int] = @[]; var ch: seq[int] = @[]; var bi: seq[int] = @[]
  var ls: seq[int] = @[]; var sp: seq[int] = @[]; var pc: seq[int] = @[]
  var i = 0
  while i < gSId.len:
    if i != idx:
      a.add gSId[i]; b.add gSPath[i]; c.add gSPcm[i]
      r.add gSRate[i]; ch.add gSChan[i]; bi.add gSBits[i]
      ls.add gSLastSeq[i]; sp.add gSSincePartial[i]; pc.add gSPartials[i]
    i = i + 1
  gSId = a; gSPath = b; gSPcm = c; gSRate = r; gSChan = ch; gSBits = bi
  gSLastSeq = ls; gSSincePartial = sp; gSPartials = pc

proc ensureWhisper(): bool =
  ## Start whisper-server once and leave it running. It goes through
  ## PowerShell's Start-Process because CreateProcess would hand the child a
  ## duplicate of our stdout pipe, whose read end then never sees EOF -- a
  ## measured hang in mods/voice, twice. curl's --retry-connrefused covers the
  ## start-up race, so no sleep is needed (and a nimony mod has none to reach for).
  if gWhisperSpawned: return true
  gWhisperSpawned = spawnDetached(cWhisperExe,
    "-m " & quoteArg(cWhisperModel) &
    " --port " & $cWhisperPort & " --host 127.0.0.1")
  result = gWhisperSpawned

proc runWhisper(wav: string; note: var string): string =
  if cSttEngine == "none":
    note = "stt=none: nothing transcribed"
    return ""
  let p = sttProbe()
  if not p.ok:
    note = "stt unavailable -- " & p.note
    return ""
  if not exists(wav):
    note = "no such wav: " & wav
    return ""
  if cSttEngine == "openai-whisper":
    # The SAME funnel the local whisper uses, so the PARTIAL every sttPartialMs
    # and the FINAL transcription both go through here -- there is no second
    # copy that could take a different endpoint.
    let key = sttKey()
    if key.len == 0:
      note = "stt: " & cSttKeyEnv & " is not set; no request was made"
      return ""
    let rc = runCmd(quoteArg(cCurlExe) & " -s --max-time 120" &
                    " -H \"Authorization: Bearer " & key & "\"" &
                    " -F file=@" & quoteArg(wav) &
                    " -F model=" & quoteArg(cSttModel) &
                    " -F response_format=json " & quoteArg(sttUrl()))
    if rc.failed or rc.output.len == 0:
      note = "no response from curl for " & sttUrl()
      return ""
    let tc = jr.asText(jr.field(rc.output, "text"), "")
    if tc.len == 0:
      let em = apiErrorOf(rc.output)
      note = (if em.len > 0: sttUrl() & " refused: " & em
              else: "the transcription endpoint answered but had no `text`: " &
                    oneLine(rc.output))
      return ""
    result = oneLine(tc)
    note = "transcribed " & $result.len & " chars via " & cSttModel &
           " at " & trimSlash(cSttBase)
    return result
  discard ensureWhisper()
  let url = "http://127.0.0.1:" & $cWhisperPort & "/inference"
  let r = runCmd(quoteArg(cCurlExe) & " -s --retry 20 --retry-connrefused" &
                 " --retry-delay 1 --max-time 180" &
                 " -F file=@" & quoteArg(wav) &
                 " -F response_format=json " & quoteArg(url))
  if r.failed or r.output.len == 0:
    note = "whisper produced no response (is curl.exe present?)"
    return ""
  let t = jr.asText(jr.field(r.output, "text"), "")
  if t.len == 0:
    note = "whisper answered but had no `text`: " & oneLine(r.output)
    return ""
  # whisper.cpp emits [_BEG_] / [BLANK_AUDIO] / [MUSIC] inline; strip them so a
  # marker never reads as speech.
  var stripped = ""
  var depth = 0
  for chx in t:
    if chx == '[': depth = depth + 1
    elif chx == ']':
      if depth > 0: depth = depth - 1
    elif depth == 0: stripped.add chx
  result = oneLine(stripped)
  note = "transcribed " & $result.len & " chars"

proc rewriteSessionWav(idx: int): bool =
  let hdr = riffHeader(gSPcm[idx].len, gSRate[idx], gSChan[idx], gSBits[idx])
  result = writeAll(gSPath[idx], hdr & gSPcm[idx])

proc sttSessionChunk*(session: string; seq: int; wavPath, wavBase64: string;
                      final: bool; partial: var string; finalText: var string;
                      note: var string): bool =
  partial = ""; finalText = ""; note = ""
  if session.len == 0:
    note = "no session id"
    return false

  var bytes = ""
  if wavBase64.len > 0:
    try:
      bytes = base64.decode(wavBase64)
    except:
      note = "wavBase64 is not valid base64 (" & $wavBase64.len & " chars)"
      return false
  elif wavPath.len > 0:
    if not exists(wavPath):
      note = "no such file: " & wavPath
      return false
    bytes = readAll(wavPath)
    if bytes.len == 0:
      note = "read 0 bytes from " & wavPath
      return false
  elif not final:
    note = "chunk carried neither wavBase64 nor path, and is not final"
    return false

  var rate = 16000
  var chans = 1
  var bits = 16
  var pcm = bytes
  var srcNote = "raw PCM assumed 16000 Hz mono 16-bit"
  if bytes.len >= 12 and bytes[0 ..< 4] == "RIFF":
    var n2 = ""
    if not parseWav(bytes, rate, chans, bits, pcm, n2):
      note = "could not read the wav: " & n2
      return false
    srcNote = "wav " & $rate & " Hz " & $chans & "ch " & $bits & "-bit" &
      (if n2.len > 0: " (" & n2 & ")" else: "")

  var idx = findSession(session)
  if idx < 0:
    if not ensureDir(cWorkDir):
      note = "workDir is not writable: " & cWorkDir
      return false
    gSId.add session
    gSPath.add joinPath(cWorkDir, "bm_stt_" & hex64(fnv1a64(session)) & ".wav")
    gSPcm.add ""
    gSRate.add rate
    gSChan.add chans
    gSBits.add bits
    gSLastSeq.add -1
    gSSincePartial.add 0
    gSPartials.add 0
    idx = gSId.len - 1
  else:
    if seq <= gSLastSeq[idx]:
      note = "chunk seq " & $seq & " is a duplicate or out of order (last was " &
             $gSLastSeq[idx] & ") -- refused, nothing appended"
      return false
    if pcm.len > 0 and (rate != gSRate[idx] or chans != gSChan[idx] or
                        bits != gSBits[idx]):
      note = "chunk format " & $rate & "/" & $chans & "/" & $bits &
             " differs from the session's " & $gSRate[idx] & "/" &
             $gSChan[idx] & "/" & $gSBits[idx] &
             " -- refused (no resampling is done here)"
      return false
  gSLastSeq[idx] = seq
  if pcm.len > 0:
    gSPcm[idx] = gSPcm[idx] & pcm
    gSSincePartial[idx] = gSSincePartial[idx] + pcm.len
    if not rewriteSessionWav(idx):
      note = "could not write the session wav: " & gSPath[idx]
      return false

  let bytesPerMs = (gSRate[idx] * gSChan[idx] * (gSBits[idx] div 8)) div 1000
  let threshold = (if bytesPerMs > 0: cSttPartialMs * bytesPerMs else: 32000)
  var sttNote = ""

  if final:
    let text = runWhisper(gSPath[idx], sttNote)
    finalText = text
    let held = gSPcm[idx].len
    closeSession(idx)
    note = srcNote & "; final over " & $held & " PCM bytes; " & sttNote
    if gSRate.len > 0 and rate != 16000:
      note = note & "; NOTE the source is " & $rate &
             " Hz and whisper.cpp expects 16000 Hz"
    return true

  if gSSincePartial[idx] >= threshold:
    partial = runWhisper(gSPath[idx], sttNote)
    gSSincePartial[idx] = 0
    gSPartials[idx] = gSPartials[idx] + 1
    note = srcNote & "; partial #" & $gSPartials[idx] & " after " &
           $gSPcm[idx].len & " PCM bytes; " & sttNote &
           " (a partial is a preview and is NEVER fed to the brain)"
  else:
    let msSince = (if bytesPerMs > 0: gSSincePartial[idx] div bytesPerMs else: 0)
    note = srcNote & "; buffered " & $gSPcm[idx].len & " PCM bytes, " &
           $msSince & " of " & $cSttPartialMs & " ms until the next partial"
  if rate != 16000:
    note = note & "; NOTE the source is " & $rate &
           " Hz and whisper.cpp expects 16000 Hz"
  result = true

proc sttStats*(): JsonObject =
  var a = arr()
  var i = 0
  while i < gSId.len:
    var o = obj()
    o.put("session", gSId[i])
    o.put("path", gSPath[i])
    o.put("pcmBytes", gSPcm[i].len)
    o.put("rate", gSRate[i])
    o.put("lastSeq", gSLastSeq[i])
    o.put("partials", gSPartials[i])
    a.add done(o)
    i = i + 1
  var o = obj()
  o.put("engine", cSttEngine)
  o.put("partialMs", cSttPartialMs)
  o.put("whisperSpawned", gWhisperSpawned)
  o.put("port", cWhisperPort)
  o.put("sessions", done(a))
  result = o

# ---------------------------------------------------------------------------
# PUSH TO TALK -- the backend holds the microphone, because the game does
#
# `/speech/chunk` is the SPT shape: a plugin captures PCM and posts it. On
# aowlspt the client cannot capture at all -- EFT holds the mic exclusively,
# which is exactly why EscapeFromMyBasement ships a standalone winmm
# `recorder.exe` (aowl.voice reuses it for the same reason, `vx/pipeline.nim
# ::record`). So `/speech/ptt` moves the capture to this side: `down` spawns
# the recorder, the tick feeds the GROWING file through the same
# `sttSessionChunk` machinery, and `up` finalises.
#
# TWO THINGS MEASURED HERE, both of which a naive implementation gets wrong:
#
# * **The recorder writes the RIFF size fields only when it exits.** Mid-
#   recording the `data` chunk's size field reads 0 (or a stale value) while
#   real audio sits behind it, so `parseWav` -- which trusts that field --
#   returns an EMPTY payload and the whole thing looks like silence. The pump
#   therefore locates the data chunk's OFFSET by walking the header and takes
#   everything from there to EOF, and reports both numbers side by side so the
#   discrepancy is visible rather than assumed.
# * **The recorder cannot be stopped early from here.** Its protocol is "a
#   line on stdin stops it", and a detached spawn has no stdin to write to.
#   The alternative -- `CreateProcess` with an inherited pipe -- is the hang
#   aowl.voice measured twice (the child holds our stdout write end, so the
#   read end never sees EOF). So the recorder is started with the
#   `pttMaxSeconds` bound and `up` finalises over WHAT IS ON DISK at that
#   moment; the process keeps writing until its bound expires. That is stated
#   in every `up` reply rather than being a silent property.
#
# It is launched through a generated `.cmd` wrapper instead of directly,
# because the recorder's EXIT CODE is the only way to tell "recorded silence"
# from "there are no capture devices" (`waveInGetNumDevs()==0` -> exit 2,
# NO_DEVICES -- aowl.voice DESIGN 5.1 measured that on this machine), and a
# detached spawn throws the exit code away. The wrapper writes it to a file.
# `<NUL` gives the recorder the immediate stdin EOF that `execCmdEx` gives it
# in `vx/pipeline.nim`; without it a hidden console would leave `ReadLine`
# blocking forever.
# ---------------------------------------------------------------------------

var cRecorderExe: string = ""
var cPttMaxSeconds: int = 20

var gPttActive: bool = false
var gPttSession: string = ""
var gPttWav: string = ""
var gPttOutFile: string = ""
var gPttCodeFile: string = ""
var gPttStopFile: string = ""    ## `up` creates this; the wrapper polls it
var gPttStartMs: int64 = 0
var gPttSecs: int = 0
var gPttFed: int = 0
var gPttSeq: int = 0
var gPttDataField: int = -1
var gPttRate: int = 0
var gPttChan: int = 0
var gPttBits: int = 0
var gPttPumps: int = 0
var gPttLastNote: string = "no push-to-talk yet"

proc pttConfigure*(recorderExe: string; maxSeconds: int) =
  cRecorderExe = defaulted(recorderExe, joinPath(cToolsDir, "recorder/recorder.exe"))
  if maxSeconds > 0: cPttMaxSeconds = maxSeconds

proc recProbe*(): SpeechProbe = probeOf("rec", "recorder", cRecorderExe, "")

proc pttActive*(): bool = gPttActive
proc pttSessionId*(): string = gPttSession

proc pttOutcome(): string =
  ## What the recorder process has to say for itself. Three states, never two:
  ## still running / exited with a code we read / we could not tell.
  if gPttCodeFile.len == 0: return "no recorder has been started"
  if not exists(gPttCodeFile):
    # "no exit code file" is NOT the same claim as "still running", and saying
    # the second when the first is all we know is how a wrapper that never ran
    # reads as a recording in progress. Once the wav should certainly exist and
    # does not, say the honest thing instead.
    let ms = int(nowMs() - gPttStartMs)
    if ms > 3000 and not exists(gPttWav):
      return "NO EVIDENCE IT EVER RAN: " & $ms & " ms after the spawn there " &
             "is neither a wav at " & gPttWav & " nor an exit code at " &
             gPttCodeFile & " -- the wrapper (cmd /c) may not have started"
    return "still running (no exit code file yet at " & gPttCodeFile & ")"
  var digits = ""
  for ch in readAll(gPttCodeFile):
    if ch >= '0' and ch <= '9': digits.add ch
    elif digits.len > 0: break
  let outText = oneLine(readAll(gPttOutFile))
  if digits.len == 0:
    return "exited, but the exit code file was unreadable; output: " & outText
  var code = 0
  for ch in digits: code = code * 10 + (ord(ch) - ord('0'))
  var why = ""
  if code == 2 or outText.contains("NO_DEVICES"):
    why = " (NO_DEVICES: waveInGetNumDevs()==0 -- there is no capture device " &
          "on this machine right now, so there is no audio to transcribe; " &
          "that is INCONCLUSIVE, not silence)"
  result = "exited " & $code & why &
           (if outText.len > 0: "; output: " & outText else: "")

proc pcmStartOf(bytes: string; rate, chans, bits, dataField: var int): int =
  ## The OFFSET at which PCM begins, by walking the chunk list. Deliberately
  ## does NOT trust the `data` chunk's size field -- that is the field the
  ## recorder leaves at 0 until it exits. Returns -1 when the header is not yet
  ## readable, which is honest for a file that is 12 bytes old.
  rate = 0; chans = 0; bits = 0; dataField = -1
  if bytes.len < 44: return -1
  if bytes[0 ..< 4] != "RIFF" or bytes[8 ..< 12] != "WAVE": return -1
  var i = 12
  var haveFmt = false
  while i + 8 <= bytes.len:
    let id = bytes[i ..< i+4]
    let sz = rd32(bytes, i + 4)
    if id == "fmt ":
      if i + 24 > bytes.len: return -1
      chans = rd16(bytes, i + 10)
      rate = rd32(bytes, i + 12)
      bits = rd16(bytes, i + 22)
      haveFmt = true
    elif id == "data":
      if not haveFmt: return -1
      if rate <= 0 or chans <= 0 or bits <= 0: return -1
      dataField = sz
      return i + 8
    if sz <= 0: return -1          # a zero-length non-data chunk would spin
    i = i + 8 + sz + (sz and 1)
  result = -1

proc pttPump*(partial: var string; note: var string): bool =
  ## Feed whatever NEW audio is on disk into the session. Called from the tick
  ## and from `/speech/ptt {"state":"poll"}`. The partial cadence is not decided
  ## here: `sttSessionChunk` runs whisper only once `sttPartialMs` of new audio
  ## has arrived, so pumping more often than that is free.
  partial = ""
  note = ""
  if not gPttActive:
    note = "no push-to-talk recording is running"
    return false
  gPttPumps = gPttPumps + 1
  let bytes = readAll(gPttWav)
  if bytes.len == 0:
    note = "the recorder has written nothing yet at " & gPttWav & "; " & pttOutcome()
    gPttLastNote = note
    return true
  var rate = 0
  var chans = 0
  var bits = 0
  var dataField = -1
  let start = pcmStartOf(bytes, rate, chans, bits, dataField)
  if start < 0:
    note = "the wav header is not readable yet (" & $bytes.len &
           " bytes on disk); " & pttOutcome()
    gPttLastNote = note
    return true
  gPttRate = rate
  gPttChan = chans
  gPttBits = bits
  gPttDataField = dataField
  let avail = bytes.len - start
  if avail <= gPttFed:
    note = "no new audio: " & $avail & " PCM bytes on disk, " & $gPttFed &
           " already fed (the RIFF data size field still reads " &
           $dataField & "); " & pttOutcome()
    gPttLastNote = note
    return true
  let slice = bytes[start + gPttFed ..< bytes.len]
  gPttFed = avail
  gPttSeq = gPttSeq + 1
  # Re-wrap the raw slice in a correct header rather than handing it over as
  # "raw PCM": that path ASSUMES 16 kHz mono 16-bit, and an assumption is
  # exactly what the session's format check exists to catch.
  let wrapped = riffHeader(slice.len, rate, chans, bits) & slice
  var finalText = ""
  var sttNote = ""
  let ok = sttSessionChunk(gPttSession, gPttSeq, "", base64.encode(wrapped),
                           false, partial, finalText, sttNote)
  note = "fed " & $slice.len & " new PCM bytes of " & $avail & " on disk (" &
         $rate & " Hz " & $chans & "ch " & $bits & "-bit) while the RIFF data " &
         "size field reads " & $dataField &
         " -- the recorder writes the sizes only when it exits; " & sttNote
  gPttLastNote = note
  result = ok

proc pttWrapperPs(recorder, wavPath, outPath, codePath, stopPath: string;
                  secs: int): string =
  ## The PowerShell wrapper that OWNS the recorder process.
  ##
  ## MEASURED 2026-09-07, first live SPT 4.1.5 raid: every `up` read
  ## "0 PCM bytes fed, wav -1 bytes, recorder still running" 0.9-1.4 s after
  ## the `down`. `recorder.exe` writes the RIFF sizes and closes the file only
  ## when it STOPS, and it is told to stop by a line on its STDIN -- but the
  ## old wrapper was `cmd /c recorder.exe ... <NUL`, a detached child with no
  ## usable stdin, so the only thing that could ever end it was its own
  ## `maxSeconds` bound. Every push-to-talk turn was therefore silent by
  ## construction, and no amount of waiting in `up` could have helped.
  ##
  ## So: start it with RedirectStandardInput, poll for `<wav>.stop`, write
  ## "stop" into its stdin, wait for it, and only then write the exit code.
  ## stdout and stderr are redirected to files so the child inherits none of
  ## OUR handles -- the pipe-never-sees-EOF hang measured twice in mods/voice.
  result =
    "$ErrorActionPreference = 'Stop'\r\n" &
    "$psi = New-Object System.Diagnostics.ProcessStartInfo\r\n" &
    "$psi.FileName = '" & recorder & "'\r\n" &
    "$psi.Arguments = '\"" & wavPath & "\" " & $secs & "'\r\n" &
    "$psi.UseShellExecute = $false\r\n" &
    "$psi.RedirectStandardInput = $true\r\n" &
    "$psi.RedirectStandardOutput = $true\r\n" &
    "$psi.RedirectStandardError = $true\r\n" &
    "$p = [System.Diagnostics.Process]::Start($psi)\r\n" &
    "$deadline = (Get-Date).AddSeconds(" & $(secs + 5) & ")\r\n" &
    "while (-not $p.HasExited -and (Get-Date) -lt $deadline) {\r\n" &
    "  if (Test-Path -LiteralPath '" & stopPath & "') {\r\n" &
    "    try { $p.StandardInput.WriteLine('stop'); $p.StandardInput.Flush() } catch {}\r\n" &
    "    break\r\n" &
    "  }\r\n" &
    "  Start-Sleep -Milliseconds 50\r\n" &
    "}\r\n" &
    "if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch {} }\r\n" &
    "$o = ''\r\n" &
    "try { $o = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd() } catch {}\r\n" &
    "Set-Content -LiteralPath '" & outPath & "' -Value $o -Encoding ascii\r\n" &
    "Set-Content -LiteralPath '" & codePath & "' -Value ([string]$p.ExitCode + ' ') -Encoding ascii\r\n"

proc pttWaitForWav(note: var string): bool =
  ## Bounded wait for the recorder to finish CLOSING the file: the RIFF `data`
  ## size field must be non-zero and the byte count must be the same across two
  ## reads 50 ms apart. Three outcomes -- complete / timed out (said so) / no
  ## file at all -- never "assume it is done".
  let t0 = nowMs()
  var lastSize = -1
  var stable = 0
  while (nowMs() - t0) < 2500'i64:
    let bytes = readAll(gPttWav)
    if bytes.len > 44:
      var r = 0
      var c = 0
      var b = 0
      var df = -1
      let start = pcmStartOf(bytes, r, c, b, df)
      if start > 0 and df > 0:
        if bytes.len == lastSize:
          stable = stable + 1
          if stable >= 1:
            note = "wav complete: " & $bytes.len & " bytes, RIFF data size " &
                   $df & " after " & $int(nowMs() - t0) & " ms"
            return true
        else:
          stable = 0
        lastSize = bytes.len
    var spin = 0
    let tw = nowMs()
    while (nowMs() - tw) < 50'i64: spin = spin + 1
  note = "TIMED OUT after " & $int(nowMs() - t0) & " ms waiting for the " &
         "recorder to close " & gPttWav & " (" & $sizeOfFile(gPttWav) &
         " bytes on disk, RIFF data size field " & $gPttDataField &
         "); the final transcription runs over whatever was fed, which may be " &
         "less than was spoken. " & pttOutcome()
  result = false

proc pttStart*(session: string; wav: var string; already: var bool;
               note: var string): bool =
  already = false
  wav = ""
  note = ""
  if session.len == 0:
    note = "no session id"
    return false
  if gPttActive:
    wav = gPttWav
    if gPttSession == session:
      already = true
      note = "already recording into " & gPttWav & " (" &
             $int(nowMs() - gPttStartMs) & " ms so far); " & pttOutcome()
      return true
    note = "session '" & gPttSession & "' is already recording -- send it an " &
           "`up` before starting '" & session & "'"
    return false
  let p = recProbe()
  if not p.ok:
    note = "capture unavailable -- " & p.note
    return false
  if not ensureDir(cWorkDir):
    note = "workDir is not writable: " & cWorkDir
    return false
  # A RELATIVE workDir is refused outright. The recorder is started by a
  # detached `cmd /c`, whose working directory is not ours, so a relative path
  # means the wrapper is looked for in the wrong place and the wav is written
  # somewhere nobody reads -- MEASURED 2026-09-06: with workDir defaulted to
  # "." the check reported "still running" forever because the .cmd was never
  # found. Every path here has to be absolute.
  var absolute = false
  if cWorkDir.len >= 2 and cWorkDir[1] == ':': absolute = true
  if cWorkDir.len >= 1 and (cWorkDir[0] == '/' or cWorkDir[0] == '\\'): absolute = true
  if not absolute:
    note = "workDir '" & cWorkDir & "' is a RELATIVE path; the recorder runs " &
           "under a detached powershell whose working directory is not " &
           "ours, so it " &
           "would write the wav somewhere nothing here can read. Set " &
           "\"workDir\" in mods/basement/config.json to an absolute directory."
    return false
  var secs = cPttMaxSeconds
  if secs < 1: secs = 1
  if secs > 600: secs = 600
  let tag = hex64(fnv1a64(session & "." & $nowMs()))
  let wavPath = joinPath(cWorkDir, "bm_ptt_" & tag & ".wav")
  let outPath = joinPath(cWorkDir, "bm_ptt_" & tag & ".out")
  let codePath = joinPath(cWorkDir, "bm_ptt_" & tag & ".code")
  let batPath = joinPath(cWorkDir, "bm_ptt_" & tag & ".ps1")
  let stopPath = joinPath(cWorkDir, "bm_ptt_" & tag & ".stop")
  let bat = pttWrapperPs(cRecorderExe, wavPath, outPath, codePath,
                         stopPath, secs)
  if not writeAll(batPath, bat):
    note = "could not write the recorder wrapper at " & batPath
    return false
  if not spawnDetached("powershell.exe",
      "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" &
      batPath & "\""):
    note = "the recorder wrapper could not be started (powershell -File " &
           batPath & ")"
    return false
  gPttActive = true
  gPttSession = session
  gPttWav = wavPath
  gPttOutFile = outPath
  gPttCodeFile = codePath
  gPttStartMs = nowMs()
  gPttSecs = secs
  gPttFed = 0
  gPttSeq = 0
  gPttPumps = 0
  gPttStopFile = stopPath
  gPttDataField = -1
  gPttRate = 0
  gPttChan = 0
  gPttBits = 0
  wav = wavPath
  note = "recording into " & wavPath & " for at most " & $secs & " s (the " &
         "recorder cannot be interrupted from here -- `up` finalises over " &
         "what is on disk at that moment)"
  gPttLastNote = note
  result = true

proc pttStop*(sess: var string; finalText: var string; note: var string): bool =
  ## `up`. Pumps the tail, then runs the FINAL transcription over the whole
  ## session buffer and closes the session.
  sess = ""
  finalText = ""
  note = ""
  if not gPttActive:
    note = "no push-to-talk recording is running -- an `up` without a `down` " &
           "is refused, nothing was transcribed"
    return false
  # Tell the wrapper to stop the recorder, then WAIT (bounded) for the wav to
  # be closed, and only then pump the tail. Without this the final
  # transcription runs over a file the recorder has not written yet -- which is
  # what "0 PCM bytes fed" meant on every live turn.
  var stopNote2 = "no stop file path (the recorder was not started by this " &
                  "process's wrapper)"
  if gPttStopFile.len > 0:
    if writeAll(gPttStopFile, "stop"):
      stopNote2 = ""
      var waitNote = ""
      let complete = pttWaitForWav(waitNote)
      stopNote2 = (if complete: waitNote else: waitNote)
    else:
      stopNote2 = "REFUSED: could not write the stop file " & gPttStopFile &
                  "; the recorder will run to its " & $gPttSecs &
                  " s bound and this turn transcribes only what is on disk now"
  var lastPartial = ""
  var pumpNote = ""
  discard pttPump(lastPartial, pumpNote)
  sess = gPttSession
  let heldMs = int(nowMs() - gPttStartMs)
  let onDisk = sizeOfFile(gPttWav)
  let outcome = pttOutcome()
  let fed = gPttFed
  gPttSeq = gPttSeq + 1
  var p2 = ""
  var sttNote = ""
  let ok = sttSessionChunk(gPttSession, gPttSeq, "", "", true, p2, finalText,
                           sttNote)
  gPttActive = false
  gPttSession = ""
  note = "stopped after " & $heldMs & " ms; " & $fed & " PCM bytes fed, wav " &
         $onDisk & " bytes at " & gPttWav & "; recorder " & outcome &
         "; the recorder was bounded at " & $gPttSecs & " s; stop: " &
         stopNote2 & "; " & pumpNote & "; " & sttNote
  gPttLastNote = note
  result = ok

proc pttStatus*(): JsonObject =
  let p = recProbe()
  var o = obj()
  o.put("recording", gPttActive)
  o.put("session", gPttSession)
  o.put("seconds", (if gPttActive: int(nowMs() - gPttStartMs) div 1000 else: 0))
  o.put("wavBytes", (if gPttWav.len > 0: sizeOfFile(gPttWav) else: -1))
  o.put("wav", gPttWav)
  o.put("pcmFed", gPttFed)
  o.put("pumps", gPttPumps)
  o.put("riffDataSizeField", gPttDataField)
  o.put("rate", gPttRate)
  o.put("channels", gPttChan)
  o.put("bits", gPttBits)
  o.put("maxSeconds", cPttMaxSeconds)
  o.put("recorder", cRecorderExe)
  o.put("recorderOk", p.ok)
  o.put("recorderNote", p.note)
  o.put("outcome", pttOutcome())
  o.put("note", gPttLastNote)
  result = o
