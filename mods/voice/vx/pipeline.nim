## vx/pipeline — the three swappable stages: capture, transcribe, reason, speak.
##
## Each stage dispatches on a config string (`sttEngine`, `llmEngine`,
## `ttsEngine`), so replacing a backend is a config edit, not a code change. Each
## stage also **probes** first and returns a note saying what it did or why it
## could not, because the failure mode this project has been burned by is a
## feature that silently does nothing.

import std/[strutils, envvars]
import aowlspt
import aowlspt/json as jr
import engine
import agents

# ---------------------------------------------------------------------------
# Config -- literal-initialised globals, filled by `configure` at load.
#
# nimony silently ZEROES any DLL global whose initialiser is a call, so every
# one of these must be a literal here and be assigned at run time. A mod is a
# DLL; this is not a style choice.
# ---------------------------------------------------------------------------

var cToolsDir: string = ""
var cSttEngine: string = "whisper-server"
var cLlmEngine: string = "builtin"
var cTtsEngine: string = "piper"
var cWhisperExe: string = ""
var cWhisperModel: string = ""
var cWhisperPort: int = 9000
var cPiperExe: string = ""
var cPiperVoice: string = ""
var cRecorderExe: string = ""
var cCurlExe: string = "curl.exe"
var cLlamaExe: string = ""
var cLlamaModel: string = ""
var cOpenAiModel: string = "gpt-4o-mini"
var cWorkDir: string = ""
var cMaxTurns: int = 12
var cMaxTokens: int = 160

var gWhisperSpawned: bool = false
var gSeq: int = 0

proc defaulted(v, fallback: string): string =
  if v.len > 0: v else: fallback

proc configure*(toolsDir, stt, llm, tts, whisperExe, whisperModel, piperExe,
                piperVoice, recorderExe, curlExe, llamaExe, llamaModel,
                openAiModel, workDir: string; whisperPort, maxTurns,
                maxTokens: int) =
  cToolsDir = toolsDir
  cSttEngine = defaulted(stt, "whisper-server")
  cLlmEngine = defaulted(llm, "builtin")
  cTtsEngine = defaulted(tts, "piper")
  cWhisperExe = defaulted(whisperExe, joinPath(toolsDir, "whisper/whisper-server.exe"))
  cWhisperModel = defaulted(whisperModel, joinPath(toolsDir, "whisper/ggml-base.en.bin"))
  cPiperExe = defaulted(piperExe, joinPath(toolsDir, "piper/piper.exe"))
  cPiperVoice = defaulted(piperVoice, joinPath(toolsDir, "piper/en_US-lessac-medium.onnx"))
  cRecorderExe = defaulted(recorderExe, joinPath(toolsDir, "recorder/recorder.exe"))
  cCurlExe = defaulted(curlExe, "curl.exe")
  cLlamaExe = llamaExe
  cLlamaModel = llamaModel
  cOpenAiModel = defaulted(openAiModel, "gpt-4o-mini")
  cWorkDir = defaulted(workDir, getEnv("TEMP", "."))
  if whisperPort > 0: cWhisperPort = whisperPort
  if maxTurns > 0: cMaxTurns = maxTurns
  if maxTokens > 0: cMaxTokens = maxTokens

proc maxTurns*(): int = cMaxTurns
proc sttEngine*(): string = cSttEngine
proc llmEngine*(): string = cLlmEngine
proc ttsEngine*(): string = cTtsEngine

proc tempPath*(suffix: string): string =
  gSeq = gSeq + 1
  result = joinPath(cWorkDir, "aowlvoice_" & $nowMs() & "_" & $gSeq & suffix)

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

proc sttProbe*(): Probe =
  case cSttEngine
  of "whisper-server": result = probeOf("stt", cSttEngine, cWhisperExe, cWhisperModel)
  of "none": result = probeOf("stt", "none", "", "")
  else:
    result = probeOf("stt", cSttEngine, "", "")
    result.ok = false
    result.note = "unknown stt engine '" & cSttEngine & "' (have: whisper-server, none)"

proc llmProbe*(): Probe =
  case cLlmEngine
  of "builtin":
    result = probeOf("llm", "builtin", "", "")
    result.note = "ok (template responder, NOT a language model)"
  of "llamacpp":
    result = probeOf("llm", "llamacpp", cLlamaExe, cLlamaModel)
    if cLlamaExe.len == 0 or cLlamaModel.len == 0:
      result.ok = false
      result.note = "llamacpp needs both llamaExe and llamaModel in config; " &
                    "no .gguf model exists on this machine yet (see DESIGN.md)"
  of "openai":
    result = probeOf("llm", "openai", "", "")
    if getEnv("OPENAI_API_KEY", "").len == 0:
      result.ok = false
      result.note = "OPENAI_API_KEY is not set in the environment (this mod " &
                    "never carries a key in source or config)"
    else:
      result.note = "ok (cloud; model " & cOpenAiModel & ")"
  of "none":
    result = probeOf("llm", "none", "", "")
  else:
    result = probeOf("llm", cLlmEngine, "", "")
    result.ok = false
    result.note = "unknown llm engine '" & cLlmEngine &
                  "' (have: builtin, llamacpp, openai, none)"

proc ttsProbe*(): Probe =
  case cTtsEngine
  of "piper": result = probeOf("tts", "piper", cPiperExe, cPiperVoice)
  of "sapi":
    result = probeOf("tts", "sapi", "", "")
    result.note = "ok (Windows System.Speech via powershell)"
  of "none": result = probeOf("tts", "none", "", "")
  else:
    result = probeOf("tts", cTtsEngine, "", "")
    result.ok = false
    result.note = "unknown tts engine '" & cTtsEngine & "' (have: piper, sapi, none)"

proc recProbe*(): Probe = probeOf("rec", "recorder", cRecorderExe, "")

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

proc record*(seconds: int; note: var string): string =
  ## Spawn EFMB's standalone winmm recorder and wait for it. This exe exists
  ## precisely *because* EFT holds the microphone exclusively, so in-process
  ## capture fails -- that reason survives the port to IL2CPP unchanged, which
  ## is why the recorder is reused rather than rewritten.
  ##
  ## Its stdin protocol is "a line stops recording early"; `Console.ReadLine()`
  ## returns null at EOF and the exe checks for null, so closing stdin (which is
  ## what `execCmdEx` does) is safe and it simply records for `seconds`.
  let p = recProbe()
  if not p.ok:
    note = "capture unavailable -- " & p.note
    return ""
  var secs = seconds
  if secs < 1: secs = 1
  if secs > 30: secs = 30
  let wav = tempPath(".wav")
  let r = runCmd(quoteArg(cRecorderExe) & " " & quoteArg(wav) & " " & $secs)
  if r.failed:
    note = "recorder could not be started"
    return ""
  let sz = sizeOfFile(wav)
  if sz <= 44:
    note = "recorder produced " & $sz & " bytes (exit " & $r.code & "): " &
           oneLine(r.output)
    return ""
  note = "recorded " & $sz & " bytes at " & wav
  result = wav

# ---------------------------------------------------------------------------
# Transcribe
# ---------------------------------------------------------------------------

proc ensureWhisper(): bool =
  ## Start whisper-server once and leave it running. There is deliberately no
  ## supervision, health check or shutdown hook -- see DESIGN.md §5. `curl`'s
  ## own `--retry-connrefused` covers the startup race, which is why no sleep is
  ## needed here (and nimony's mod side has no sleep to reach for).
  if gWhisperSpawned: return true
  gWhisperSpawned = spawnDetached(cWhisperExe,
    "-m " & quoteArg(cWhisperModel) &
    " --port " & $cWhisperPort & " --host 127.0.0.1")
  result = gWhisperSpawned

proc transcribe*(wav: string; note: var string): string =
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
  discard ensureWhisper()
  # HTTP from a nimony mod is `curl.exe`. The backend embeds an HTTP *server*
  # and there is no client in the API or in nimony's stdlib, so shelling out to
  # the curl Windows ships in System32 is the honest route rather than writing a
  # socket client here.
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
  result = oneLine(t)
  note = "transcribed " & $result.len & " chars"

# ---------------------------------------------------------------------------
# Reason
# ---------------------------------------------------------------------------

proc buildPrompt*(agentIdx: int; heard: string; hits: var string): string =
  ## The system prompt. The framing, the brevity rule and the tool grammar are
  ## carried over from EFMB's `BuildSystemPrompt` -- that text is the real design
  ## asset in that repo -- with two things it did not have: the agent's own
  ## persona from data rather than a hardcoded dict, and the conversation so far.
  var hitList = ""
  let facts = retrieve(heard, agentTags(agentIdx), 4, hitList)
  hits = hitList
  result = "You are " & agentName(agentIdx) & ". " & agentPersona(agentIdx) & "\n" &
    "Stay in character. Keep the reply to 1-3 short spoken sentences. " &
    "Never describe your actions, never use markdown, never mention being an AI.\n"
  if facts.len > 0:
    result.add "Known facts:\n" & facts
  let mem = memoryOf(agentIdx, cMaxTurns)
  if mem.len > 0:
    result.add "The conversation so far:\n" & mem
  result.add "You may append at most one tag to your reply, on its own: " &
    "[OBJ: <objective>] to set the current objective, [ADD: <objective>] to " &
    "add one, or [CLEAR] to clear them. Say nothing about the tags.\n"
  result.add "The person speaking to you says: " & heard

proc builtinReply(agentIdx: int; heard: string): string =
  ## The zero-dependency responder. **It is not a language model.** It exists so
  ## the whole spine -- mic, transcription, routing, memory, retrieval, speech --
  ## can be proved on a machine with no .gguf on it, which is this machine.
  ## Every response it produces carries a note saying exactly this.
  var hits = ""
  let facts = retrieve(heard, agentTags(agentIdx), 1, hits)
  let low = heard.toLowerAscii()
  var body = ""
  if heard.len == 0:
    body = "I did not catch that. Say again."
  elif low.contains("hello") or low.contains("hey") or low.contains("you there"):
    body = defaulted(agentGreeting(agentIdx), "I hear you.")
  elif low.contains("who are you") or low.contains("your name"):
    body = "I am " & agentName(agentIdx) & "."
  elif low.contains("where"):
    body = (if facts.len > 0: facts.strip() else: "Not somewhere I can point to from here.")
  elif low.endsWith("?"):
    body = (if facts.len > 0: facts.strip() else:
            "I do not know. Ask me something I would know.")
  else:
    body = (if facts.len > 0: facts.strip() else: "Copy that.")
  result = body.replace("- ", "")

proc jsonEscape(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add ""
    of '\t': result.add " "
    else:
      if ch >= ' ': result.add ch

proc reason*(agentIdx: int; heard: string; hits: var string;
             note: var string): string =
  let p = llmProbe()
  case cLlmEngine
  of "builtin":
    var h = ""
    discard buildPrompt(agentIdx, heard, h)   # for the retrieval hits only
    hits = h
    note = "llm=builtin: template responder, NOT a language model -- " &
           "set llmEngine to llamacpp with a .gguf for real reasoning"
    result = builtinReply(agentIdx, heard)
  of "none":
    hits = ""
    note = "llm=none: no reasoning performed"
    result = ""
  of "llamacpp":
    if not p.ok:
      note = "llm unavailable -- " & p.note
      hits = ""
      return ""
    let prompt = buildPrompt(agentIdx, heard, hits)
    let r = runCmd(quoteArg(cLlamaExe) & " -m " & quoteArg(cLlamaModel) &
                   " -n " & $cMaxTokens & " --temp 0.8 --no-display-prompt -p " &
                   quoteArg(prompt.replace("\"", "'")))
    if r.failed:
      note = "llamacpp could not be started: " & cLlamaExe
      return ""
    note = "llamacpp exit " & $r.code
    result = oneLine(r.output)
  of "openai":
    if not p.ok:
      note = "llm unavailable -- " & p.note
      hits = ""
      return ""
    let prompt = buildPrompt(agentIdx, heard, hits)
    let body = "{\"model\":\"" & cOpenAiModel & "\",\"max_tokens\":" &
      $cMaxTokens & ",\"temperature\":0.8,\"messages\":[{\"role\":\"system\"," &
      "\"content\":\"" & jsonEscape(prompt) & "\"},{\"role\":\"user\"," &
      "\"content\":\"" & jsonEscape(heard) & "\"}]}"
    let bodyFile = tempPath(".json")
    if not writeAll(bodyFile, body):
      note = "could not write the request body to " & bodyFile
      return ""
    let key = getEnv("OPENAI_API_KEY", "")
    let r = runCmd(quoteArg(cCurlExe) & " -s --max-time 60" &
      " -H \"Content-Type: application/json\"" &
      " -H \"Authorization: Bearer " & key & "\"" &
      " --data-binary @" & quoteArg(bodyFile) &
      " https://api.openai.com/v1/chat/completions")
    if r.failed or r.output.len == 0:
      note = "openai produced no response"
      return ""
    let msg = jr.field(r.output, "choices")
    let first = jr.at(msg, 0)
    let content = jr.asText(jr.child(jr.child(first, "message"), "content"), "")
    if content.len == 0:
      note = "openai answered but had no content: " & oneLine(r.output)
      return ""
    note = "openai " & cOpenAiModel
    result = oneLine(content)
  else:
    note = "llm unavailable -- " & p.note
    result = ""

# ---------------------------------------------------------------------------
# Tool tags -- EFMB's `[OBJ:]/[ADD:]/[CLEAR]` grammar
# ---------------------------------------------------------------------------

var gObjectives: seq[string] = @[]

proc objectives*(): seq[string] = gObjectives

proc applyTags*(reply: string; acted: var string): string =
  ## Pull the tags out, act on them, and return the reply with them removed so
  ## they are never spoken. **The objectives are stored and nothing renders or
  ## acts on them yet** -- that is a client-side concern and out of this mod's
  ## scope; see DESIGN.md §5.
  acted = ""
  result = ""
  var i = 0
  while i < reply.len:
    if reply[i] == '[':
      var j = i + 1
      var inner = ""
      while j < reply.len and reply[j] != ']':
        inner.add reply[j]
        j = j + 1
      let up = inner.strip()
      if up.toUpperAscii() == "CLEAR":
        gObjectives = @[]
        acted = "clear"
      elif up.toUpperAscii().startsWith("OBJ:"):
        gObjectives = @[up.substr(4).strip()]
        acted = "set"
      elif up.toUpperAscii().startsWith("ADD:"):
        gObjectives.add up.substr(4).strip()
        acted = "add"
      else:
        # Not a tag we know; keep the text so nothing is silently eaten.
        result.add "[" & inner & "]"
      i = j + 1
    else:
      result.add reply[i]
      i = i + 1
  result = collapseSpace(result)

# ---------------------------------------------------------------------------
# Speak
# ---------------------------------------------------------------------------

proc speak*(agentIdx: int; text: string; note: var string): string =
  if text.len == 0:
    note = "nothing to speak"
    return ""
  case cTtsEngine
  of "none":
    note = "tts=none: no audio produced"
    result = ""
  of "piper":
    let p = ttsProbe()
    if not p.ok:
      note = "tts unavailable -- " & p.note
      return ""
    # EFMB used `--output-raw` and hand-built a 22050/mono/16-bit RIFF header
    # around the PCM. `--output_file` makes piper write a correct wav itself,
    # which removes the hand-written header *and* the stdout binary-pipe
    # deadlock its comments describe having to work around.
    let wav = tempPath(".wav")
    var voice = cPiperVoice
    if agentVoice(agentIdx).len > 0 and exists(agentVoice(agentIdx)):
      voice = agentVoice(agentIdx)
    let r = runCmd(quoteArg(cPiperExe) & " --model " & quoteArg(voice) &
                   " --output_file " & quoteArg(wav), input = text & "\n")
    if r.failed:
      note = "piper could not be started: " & cPiperExe
      return ""
    let sz = sizeOfFile(wav)
    if sz <= 44:
      note = "piper produced " & $sz & " bytes (exit " & $r.code & "): " &
             oneLine(r.output)
      return ""
    note = "spoke " & $sz & " bytes"
    result = wav
  of "sapi":
    let wav = tempPath(".wav")
    let ps = "Add-Type -AssemblyName System.Speech; " &
      "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " &
      "$s.SetOutputToWaveFile('" & wav.replace("'", "") & "'); " &
      "$s.Speak('" & text.replace("'", "") & "'); $s.Dispose()"
    let r = runCmd("powershell -NoProfile -NonInteractive -Command \"" &
                   ps.replace("\"", "") & "\"")
    if r.failed:
      note = "powershell could not be started"
      return ""
    let sz = sizeOfFile(wav)
    if sz <= 44:
      note = "sapi produced " & $sz & " bytes: " & oneLine(r.output)
      return ""
    note = "spoke " & $sz & " bytes (sapi)"
    result = wav
  else:
    note = "tts unavailable -- unknown engine '" & cTtsEngine & "'"
    result = ""
