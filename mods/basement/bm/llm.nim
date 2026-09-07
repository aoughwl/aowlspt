## bm/llm — tier 2. Four engines behind one call, and an honest probe for each.
##
## HTTP from a nimony mod is `curl.exe`. The backend embeds an HTTP *server*;
## there is no client in the API and none in nimony's stdlib, so shelling out to
## the curl Windows ships in System32 is the honest route rather than writing a
## socket client here. (Same conclusion `mods/voice` reached.)
##
## KEYS COME FROM THE ENVIRONMENT AND NOWHERE ELSE. Not from config.json, not
## from a literal here. EscapeFromMyBasement hardcoded a live OpenAI key into
## `client/Plugin.cs:52` and shipped it inside the DLL; that is the mistake this
## file exists to not repeat. With no key, `llmProbe().ok` is false and
## `llmComplete` returns "" with a note **without invoking curl at all** — a
## check in the selfcheck asserts exactly that, by counting curl invocations.
##
## STREAMING: TWO PATHS, AND WHICH ONE YOU GOT IS SAID OUT LOUD
## ------------------------------------------------------------
## `llmComplete` (below) is the SYNCHRONOUS path: `util.runCmd` is `execCmdEx`,
## which BLOCKS until curl exits, so its sentences reach the sink in order but
## only AFTER the whole response has arrived. That cost ~4 s before the first
## spoken sentence on gpt-4o-mini, MEASURED 2026-09-07.
##
## `llmStreamStart` / `llmStreamPoll` (bottom of this file) is the ASYNC path
## the fix predicted: a DETACHED curl writing the SSE to a file, and a caller
## that re-reads the new bytes every tick. The parsing did not have to change —
## it always consumed `data:` lines in arrival order — only the launch did.
## `llmStreaming: false` in config selects the synchronous path unchanged, and
## `llmStreamStats().streaming` reports which one is live, because a "streaming"
## engine that silently is not one is exactly the class of quiet wrongness this
## repo keeps paying for.

import std/[strutils, envvars]
import aowlspt
import aowlspt/server
import aowlspt/json as jr
import util

type
  LlmProbe* = object
    engine*, path*, model*, note*: string
    ok*: bool

  SegmentSink* = nil proc (sentence: string; final: bool)

# Config -- literal initialisers only; a DLL global initialised by a call is
# silently zeroed by nimony.
var cEngine: string = "builtin"
var cAnthropicModel: string = "claude-opus-5"
var cOpenAiModel: string = "gpt-4o-mini"
var cLlamaExe: string = ""
var cLlamaModel: string = ""
var cCurlExe: string = "curl.exe"
var cWorkDir: string = ""
var cMaxTokens: int = 200
# The `openai` engine is really "any OpenAI-compatible chat endpoint". Groq
# serves the SAME wire format (chat/completions, the same SSE delta shape) at
# https://api.groq.com/openai/v1, so pointing these two settings at it is the
# WHOLE port -- MEASURED 2026-09-07: openai/gpt-oss-120b answered a full
# in-character reply in 0.56 s against ~4 s on gpt-4o-mini.
#
# The KEY is still never in config.json or in source: `openAiKeyEnv` names an
# ENVIRONMENT VARIABLE and the value is read from the process environment, so
# switching provider changes which variable is read, never where a secret is
# written down.
var cOpenAiBase: string = "https://api.openai.com/v1"
var cOpenAiKeyEnv: string = "OPENAI_API_KEY"
# Extra top-level request fields, as a raw JSON fragment WITHOUT the braces
# (e.g. `"reasoning_effort":"low"`). It exists because a compatible endpoint is
# not an identical one: MEASURED 2026-09-07 on Groq openai/gpt-oss-120b, the
# model spends its budget on a `reasoning` field FIRST -- at max_tokens 80 the
# spoken `content` came back EMPTY and at 120 it was cut off mid-word
# (finish_reason "length"). With `"reasoning_effort":"low"` the reasoning fell
# from 487 to 57 characters and the reply landed whole in 488 ms. Sending that
# field unconditionally would 400 on real OpenAI, so it is configuration, not
# a special case in the code.
var cOpenAiExtra: string = ""
var gSeq: int = 0
var gCurlCalls: int = 0      ## proves "no key -> no curl" instead of asserting it

const AnthropicUrl = "https://api.anthropic.com/v1/messages"
const AnthropicVersion = "2023-06-01"

proc defaulted(v, fallback: string): string =
  if v.len > 0: v else: fallback

proc openAiUrl(): string = trimSlash(cOpenAiBase) & "/chat/completions"
proc openAiKey(): string = getEnv(cOpenAiKeyEnv, "")
proc openAiBaseUrl*(): string = trimSlash(cOpenAiBase)
proc openAiKeyEnvName*(): string = cOpenAiKeyEnv

proc llmConfigureOpenAi*(baseUrl, keyEnv, extraJson: string) =
  cOpenAiBase = defaulted(baseUrl, "https://api.openai.com/v1")
  cOpenAiKeyEnv = defaulted(keyEnv, "OPENAI_API_KEY")
  # UNESCAPE `\"` -> `"`. MEASURED 2026-09-07: `aowlspt/json` hands a string
  # setting back with its backslash escapes STILL IN IT (the tts cache index
  # hit the same thing and works around it by hex-encoding), so a config value
  # written as "\"reasoning_effort\":\"low\"" arrived here with literal
  # backslashes and Groq answered, word for word:
  #   failed to unmarshal JSON: invalid character '\' looking for beginning
  #   of object key string
  # -- after which the turn fell through to the builtin template tier, which
  # answers fluently and is NOT a language model. Worth reading twice: the
  # visible symptom was a perfectly good reply.
  cOpenAiExtra = extraJson.strip().replace("\\\"", "\"")
  while cOpenAiExtra.len > 0 and cOpenAiExtra[0] == ',':
    cOpenAiExtra = cOpenAiExtra[1 ..< cOpenAiExtra.len].strip()
  while cOpenAiExtra.len > 0 and cOpenAiExtra[cOpenAiExtra.len-1] == ',':
    cOpenAiExtra = cOpenAiExtra[0 ..< cOpenAiExtra.len-1].strip()

proc withExtra(body: string): string =
  ## Splice the fragment in before the closing brace. A body that does not end
  ## in `}` is returned UNCHANGED rather than corrupted -- a malformed fragment
  ## must cost a missing field, never an unparseable request.
  if cOpenAiExtra.len == 0: return body
  if body.len < 2 or body[body.len-1] != '}': return body
  result = body[0 ..< body.len-1] & "," & cOpenAiExtra & "}"

proc llmConfigure*(engine, anthropicModel, openAiModel, llamaExe, llamaModel,
                   curlExe, workDir: string; maxTokens: int) =
  cEngine = defaulted(engine, "builtin")
  cAnthropicModel = defaulted(anthropicModel, "claude-opus-5")
  cOpenAiModel = defaulted(openAiModel, "gpt-4o-mini")
  cLlamaExe = llamaExe
  cLlamaModel = llamaModel
  cCurlExe = defaulted(curlExe, "curl.exe")
  cWorkDir = defaulted(workDir, getEnv("TEMP", "."))
  if maxTokens > 0: cMaxTokens = maxTokens

proc llmEngine*(): string = cEngine
proc llmCurlCalls*(): int = gCurlCalls
proc llmModel*(): string =
  case cEngine
  of "anthropic": result = cAnthropicModel
  of "openai": result = cOpenAiModel
  of "llamacpp": result = cLlamaModel
  else: result = ""

proc tempPath(suffix: string): string =
  ## WALL-clock ms, not `nowMs()` (ms since the host started): MEASURED
  ## 2026-09-07, two backend restarts issued their first turn ~8125 ms after
  ## start, so both named their files `aowlbm_8125_1.sse`; the second turn
  ## found the first's `.code` file already on disk and the pump declared it
  ## finished at 1.2 s with "0 bytes" before curl had written anything.
  gSeq = gSeq + 1
  result = joinPath(cWorkDir, "aowlbm_" & $wallMs() & "_" & $gSeq & suffix)

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------

proc llmProbe*(): LlmProbe =
  var p = LlmProbe(engine: cEngine, path: "", model: "", note: "", ok: false)
  case cEngine
  of "builtin":
    p.ok = true
    p.note = "ok (the ontology's fallback row -- a template, NOT a language model)"
  of "none":
    p.ok = false
    p.note = "llm=none: no engine will be called"
  of "anthropic":
    p.path = AnthropicUrl
    p.model = cAnthropicModel
    if getEnv("ANTHROPIC_API_KEY", "").len == 0:
      p.ok = false
      p.note = "ANTHROPIC_API_KEY is not set in this process's environment. " &
               "The key is never read from config.json or from source. " &
               "Set it and restart the backend; until then `say` will not " &
               "invoke curl at all."
    else:
      p.ok = true
      p.note = "ok (cloud; model " & cAnthropicModel & ", streaming SSE via " &
               cCurlExe & ")"
  of "openai":
    p.path = openAiUrl()
    p.model = cOpenAiModel
    if openAiKey().len == 0:
      p.ok = false
      p.note = cOpenAiKeyEnv & " is not set in this process's environment " &
               "(never read from config or source). That is the env var " &
               "`openAiKeyEnv` names for base " & openAiBaseUrl()
    else:
      p.ok = true
      p.note = "ok (cloud; " & openAiBaseUrl() & " model " & cOpenAiModel &
               ", streaming SSE via " & cCurlExe & ")"
  of "llamacpp":
    p.path = cLlamaExe
    p.model = cLlamaModel
    if cLlamaExe.len == 0 or cLlamaModel.len == 0:
      p.note = "llamacpp needs both llamaExe and llamaModel in config"
    elif not exists(cLlamaExe):
      p.note = "missing: " & cLlamaExe
    elif not exists(cLlamaModel):
      p.note = "missing: " & cLlamaModel
    else:
      p.ok = true
      p.note = "ok: " & cLlamaExe & " with " & cLlamaModel
  else:
    p.note = "unknown llm engine '" & cEngine &
             "' (have: builtin, anthropic, openai, llamacpp, none)"
  result = p

# ---------------------------------------------------------------------------
# Sentence streaming
# ---------------------------------------------------------------------------

type
  Streamer = object
    buf: string          ## text not yet emitted as a sentence
    emitted: int

proc tailAfter*(buf, tail: string): string =
  ## `tail` with the WHITESPACE `splitSentences` stripped off it put back.
  ##
  ## MEASURED 2026-09-07: re-seeding the buffer with `parts[^1]` ate the space
  ## at the end of "I know a way out ", and the next arriving chunk landed
  ## against it -- "I know a way outof here." The sentence text was right in
  ## every check that happened to receive both chunks in one poll, which is
  ## exactly the kind of defect that passes until the network is slow.
  if tail.len == 0: return ""
  if tail.len > buf.len: return tail
  var i = buf.len - tail.len
  while i >= 0:
    if buf[i ..< i + tail.len] == tail: return buf[i ..< buf.len]
    i = i - 1
  result = tail

proc feed(st: var Streamer; chunk: string; sink: SegmentSink) =
  ## Emit every COMPLETE sentence now available, in order, and keep the tail.
  st.buf.add chunk
  let parts = splitSentences(st.buf)
  if parts.len <= 1: return
  # The last part may still be growing; everything before it is complete.
  var i = 0
  while i < parts.len - 1:
    if sink != nil: sink(parts[i], false)
    st.emitted = st.emitted + 1
    i = i + 1
  st.buf = tailAfter(st.buf, parts[parts.len - 1])

proc finish(st: var Streamer; sink: SegmentSink) =
  let tail = st.buf.strip()
  st.buf = ""
  if tail.len > 0:
    if sink != nil: sink(tail, true)
    st.emitted = st.emitted + 1
  elif st.emitted == 0:
    if sink != nil: sink("", true)

# ---------------------------------------------------------------------------
# SSE parsing
# ---------------------------------------------------------------------------

proc splitLines0(s: string): seq[string] =
  result = @[]
  var cur = ""
  for ch in s:
    if ch == '\n':
      result.add cur
      cur = ""
    elif ch != '\r':
      cur.add ch
  if cur.len > 0: result.add cur

proc deltaTextOf(ev: string): string =
  ## The wire field is `delta.text`. `delta.text_delta.text` is also read,
  ## because that is the shape the brief named; whichever is present wins and
  ## neither is assumed.
  let d = jr.child(jr.whole(ev), "delta")
  var t = jr.asText(jr.child(d, "text"), "")
  if t.len == 0:
    t = jr.asText(jr.child(jr.child(d, "text_delta"), "text"), "")
  result = t

proc parseSse(text: string; sink: SegmentSink; cacheRead: var int;
              stopReason: var string; note: var string): string =
  var st = Streamer(buf: "", emitted: 0)
  var full = ""
  var events = 0
  var apiErr = ""
  let lines = splitLines0(text)
  for line in lines:
    if not line.startsWith("data:"): continue
    let payload = line[5 ..< line.len].strip()
    if payload.len == 0 or payload == "[DONE]": continue
    let t = jr.asText(jr.child(jr.whole(payload), "type"), "")
    events = events + 1
    case t
    of "content_block_delta":
      let piece = deltaTextOf(payload)
      if piece.len > 0:
        full.add piece
        feed(st, piece, sink)
    of "message_delta":
      let sr = jr.asText(jr.field(payload, "delta.stop_reason"), "")
      if sr.len > 0: stopReason = sr
      let cr = jr.asInt(jr.field(payload, "usage.cache_read_input_tokens"), -1)
      if cr >= 0: cacheRead = cr
    of "message_start":
      let cr = jr.asInt(jr.field(payload, "message.usage.cache_read_input_tokens"), -1)
      if cr >= 0: cacheRead = cr
    of "error":
      apiErr = jr.asText(jr.field(payload, "error.message"), "")
      if apiErr.len == 0: apiErr = oneLine(payload)
    else:
      discard
  finish(st, sink)
  if apiErr.len > 0:
    note = "the API returned an error event: " & apiErr
    return ""
  if events == 0:
    note = "no SSE events in the response (" & $text.len & " bytes) -- " &
           "curl wrote something that is not an event stream"
    return ""
  result = full

# ---------------------------------------------------------------------------
# Engines
# ---------------------------------------------------------------------------

proc anthropicBody(system, user: string): string =
  ## The system block carries `cache_control: ephemeral` so the stable prefix is
  ## cached by the provider; `usage.cache_read_input_tokens` on the response is
  ## how we SEE that it fired, and a zero across repeated calls means something
  ## made the prefix unstable.
  var sysBlock = obj()
  sysBlock.put("type", "text")
  sysBlock.put("text", system)
  var cc = obj()
  cc.put("type", "ephemeral")
  sysBlock.put("cache_control", done(cc))
  var sysArr = arr()
  sysArr.add done(sysBlock)

  var msg = obj()
  msg.put("role", "user")
  msg.put("content", user)
  var msgs = arr()
  msgs.add done(msg)

  var oc = obj()
  oc.put("effort", "low")

  var root = obj()
  root.put("model", cAnthropicModel)
  root.put("max_tokens", cMaxTokens)
  root.put("stream", true)
  root.put("system", done(sysArr))
  root.put("messages", done(msgs))
  root.put("output_config", done(oc))
  result = done(root).text

proc runAnthropic(system, user: string; sink: SegmentSink; note: var string;
                  cacheRead: var int; stopReason: var string): string =
  let key = getEnv("ANTHROPIC_API_KEY", "")
  if key.len == 0:
    note = "anthropic: ANTHROPIC_API_KEY is not set; no request was made " &
           "(curl was NOT invoked). The key is read from the environment only."
    return ""
  let bodyFile = tempPath(".json")
  let outFile = tempPath(".sse")
  if not writeAll(bodyFile, anthropicBody(system, user)):
    note = "anthropic: could not write the request body to " & bodyFile
    return ""
  # -N unbuffers so the SSE lands in the file as it arrives; -s keeps the
  # progress meter out of it. The key goes in a header on the command line and
  # never into the body file.
  let cmd = quoteArg(cCurlExe) & " -N -s --max-time 120" &
    " -H \"x-api-key: " & key & "\"" &
    " -H \"anthropic-version: " & AnthropicVersion & "\"" &
    " -H \"content-type: application/json\"" &
    " --data-binary @" & quoteArg(bodyFile) &
    " -o " & quoteArg(outFile) &
    " " & quoteArg(AnthropicUrl)
  gCurlCalls = gCurlCalls + 1
  let r = runCmd(cmd)
  if r.failed:
    note = "anthropic: curl could not be started (" & cCurlExe & ")"
    return ""
  let sse = readAll(outFile)
  if sse.len == 0:
    note = "anthropic: curl exited " & $r.code & " and wrote 0 bytes to " &
           outFile & " -- " & oneLine(r.output)
    return ""
  var pnote = ""
  let full = parseSse(sse, sink, cacheRead, stopReason, pnote)
  if full.len == 0:
    note = "anthropic: " & (if pnote.len > 0: pnote else: "empty completion") &
           " (curl exit " & $r.code & ")"
    return ""
  note = "anthropic " & cAnthropicModel & ": " & $full.len & " chars" &
         (if cacheRead >= 0: ", cache_read_input_tokens=" & $cacheRead
          else: ", no usage reported") &
         (if stopReason.len > 0: ", stop_reason=" & stopReason else: "")
  result = full

proc openAiBody(system, user: string): string =
  var sys = obj()
  sys.put("role", "system")
  sys.put("content", system)
  var usr = obj()
  usr.put("role", "user")
  usr.put("content", user)
  var msgs = arr()
  msgs.add done(sys)
  msgs.add done(usr)
  var root = obj()
  root.put("model", cOpenAiModel)
  root.put("max_tokens", cMaxTokens)
  root.put("messages", done(msgs))
  result = withExtra(done(root).text)

proc runOpenAi(system, user: string; sink: SegmentSink;
               note: var string): string =
  let key = openAiKey()
  if key.len == 0:
    note = "openai: " & cOpenAiKeyEnv & " is not set; no request was made " &
           "(curl was NOT invoked)"
    return ""
  let bodyFile = tempPath(".json")
  if not writeAll(bodyFile, openAiBody(system, user)):
    note = "openai: could not write the request body to " & bodyFile
    return ""
  gCurlCalls = gCurlCalls + 1
  let r = runCmd(quoteArg(cCurlExe) & " -s --max-time 90" &
    " -H \"Content-Type: application/json\"" &
    " -H \"Authorization: Bearer " & key & "\"" &
    " --data-binary @" & quoteArg(bodyFile) & " " & quoteArg(openAiUrl()))
  if r.failed or r.output.len == 0:
    note = "openai: no response from curl"
    return ""
  let content = jr.asText(
    jr.child(jr.child(jr.at(jr.field(r.output, "choices"), 0), "message"),
             "content"), "")
  if content.len == 0:
    note = "openai answered but had no content: " & oneLine(r.output)
    return ""
  var st = Streamer(buf: "", emitted: 0)
  feed(st, content, sink)
  finish(st, sink)
  note = "openai " & cOpenAiModel & " at " & openAiBaseUrl() & ": " &
         $content.len & " chars (non-streaming)"
  result = content

proc runLlama(system, user: string; sink: SegmentSink;
              note: var string): string =
  let prompt = system & "\n\n" & user
  let r = runCmd(quoteArg(cLlamaExe) & " -m " & quoteArg(cLlamaModel) &
                 " -n " & $cMaxTokens & " --temp 0.8 --no-display-prompt -p " &
                 quoteArg(prompt.replace("\"", "'")))
  if r.failed:
    note = "llamacpp could not be started: " & cLlamaExe
    return ""
  let txt = oneLine(r.output)
  if txt.len == 0:
    note = "llamacpp exit " & $r.code & " produced no text"
    return ""
  var st = Streamer(buf: "", emitted: 0)
  feed(st, txt, sink)
  finish(st, sink)
  note = "llamacpp exit " & $r.code
  result = txt

# ---------------------------------------------------------------------------
# The one entry point
# ---------------------------------------------------------------------------

proc llmComplete*(system, user: string; sink: SegmentSink; note: var string;
                  cacheRead: var int; stopReason: var string): string =
  ## Returns the full text, or "" with a note saying why. `cacheRead` is -1
  ## unless the provider reported `usage.cache_read_input_tokens`. Never throws.
  cacheRead = -1
  stopReason = ""
  note = ""
  case cEngine
  of "builtin":
    note = "llm=builtin: no model is called; the caller serves the ontology " &
           "fallback row, which is not a language model"
    result = ""
  of "none":
    note = "llm=none: no reasoning performed"
    result = ""
  of "anthropic":
    result = runAnthropic(system, user, sink, note, cacheRead, stopReason)
  of "openai":
    result = runOpenAi(system, user, sink, note)
  of "llamacpp":
    let p = llmProbe()
    if not p.ok:
      note = "llamacpp unavailable -- " & p.note
      result = ""
    else:
      result = runLlama(system, user, sink, note)
  else:
    note = "unknown llm engine '" & cEngine & "'"
    result = ""

proc llmProbeJson*(p: LlmProbe): JsonObject =
  result = obj()
  result.put("engine", p.engine)
  result.put("path", p.path)
  result.put("model", p.model)
  result.put("ok", p.ok)
  result.put("note", p.note)
  result.put("curlCalls", gCurlCalls)

# ---------------------------------------------------------------------------
# ASYNC STREAMING -- a detached curl plus a tick that re-reads the file
# ---------------------------------------------------------------------------
#
# The limitation stated at the top of this file is what this section removes.
# `llmComplete` runs curl to completion, so on gpt-4o-mini the first sentence
# reaches the player ~4 s after they stopped talking (MEASURED 2026-09-07).
# Here curl is spawned DETACHED, writing the SSE to a file with `-o`, and the
# mod's tick polls that file: the parse is incremental and byte-positioned, so
# each poll consumes only what arrived since the last one.
#
# HONESTY ABOUT THE END OF A STREAM. There are three independent end signals
# and all three are used, because each alone has a hole: `data: [DONE]` /
# `message_stop` (absent when the connection dies), the exit-code file the
# `cmd /c` wrapper writes after curl returns (absent when the wrapper itself
# never starts), and the caller's timeout. A turn that ends on the timeout says
# so in its note rather than looking like a short reply.
#
# THE FAKE. `llmFakeStreamFile` points at a fixture SSE file and makes the
# whole path run with NO curl and NO key: the poller reveals `fakeChunkBytes`
# of it per poll, so "a sentence was emitted BEFORE the stream ended" is a
# thing the sim can actually observe. `llmFakeStreamStall` reveals the first
# chunk and then nothing, which is the input that makes the timeout path fire.

var cStreaming: bool = true
var cMaxInFlight: int = 4
var cTurnTimeoutMs: int = 60000
var cFakeFile: string = ""
var cFakeStall: bool = false
var cFakeChunk: int = 240

var gTId: seq[int] = @[]
var gTOut: seq[string] = @[]
var gTCode: seq[string] = @[]
var gTPos: seq[int] = @[]        ## bytes of the file already parsed
var gTPend: seq[string] = @[]    ## the partial last line
var gTFake: seq[bool] = @[]
var gTEnded: seq[bool] = @[]     ## an end marker was seen
var gTEvents: seq[int] = @[]
var gTStop: seq[string] = @[]    ## stop_reason, when the provider sent one
var gTErr: seq[string] = @[]
var gNextTurn: int = 0
var gStreamStarts: int = 0

proc llmStreamingConfigure*(streaming: bool; maxInFlight, turnTimeoutMs: int;
                            fakeFile: string; fakeStall: bool;
                            fakeChunkBytes: int) =
  cStreaming = streaming
  if maxInFlight > 0: cMaxInFlight = maxInFlight
  if turnTimeoutMs > 0: cTurnTimeoutMs = turnTimeoutMs
  cFakeFile = fakeFile
  cFakeStall = fakeStall
  if fakeChunkBytes > 0: cFakeChunk = fakeChunkBytes

proc llmStreamingEnabled*(): bool = cStreaming
proc llmTurnTimeoutMs*(): int = cTurnTimeoutMs
proc llmMaxInFlight*(): int = cMaxInFlight
proc llmStreamInFlight*(): int = gTId.len
proc llmStreamStarts*(): int = gStreamStarts

proc llmCanStream*(): bool =
  ## Which engines have a token-by-token wire format here. `llamacpp` prints to
  ## stdout and `builtin`/`none` never call anything, so they stay synchronous
  ## rather than pretending.
  if not cStreaming: return false
  if cFakeFile.len > 0: return true
  result = cEngine == "anthropic" or cEngine == "openai"

proc findTurn(id: int): int =
  result = -1
  var i = 0
  while i < gTId.len:
    if gTId[i] == id: return i
    i = i + 1

proc dropTurnAt(idx: int) =
  if idx < 0 or idx >= gTId.len: return
  var a: seq[int] = @[]
  var b: seq[string] = @[]
  var c: seq[string] = @[]
  var d: seq[int] = @[]
  var e: seq[string] = @[]
  var f: seq[bool] = @[]
  var g: seq[bool] = @[]
  var h: seq[int] = @[]
  var k: seq[string] = @[]
  var m: seq[string] = @[]
  var i = 0
  while i < gTId.len:
    if i != idx:
      a.add gTId[i]
      b.add gTOut[i]
      c.add gTCode[i]
      d.add gTPos[i]
      e.add gTPend[i]
      f.add gTFake[i]
      g.add gTEnded[i]
      h.add gTEvents[i]
      k.add gTStop[i]
      m.add gTErr[i]
    i = i + 1
  gTId = a
  gTOut = b
  gTCode = c
  gTPos = d
  gTPend = e
  gTFake = f
  gTEnded = g
  gTEvents = h
  gTStop = k
  gTErr = m

proc llmStreamDrop*(id: int) =
  dropTurnAt(findTurn(id))

proc openAiStreamBody(system, user: string): string =
  var sys = obj()
  sys.put("role", "system")
  sys.put("content", system)
  var usr = obj()
  usr.put("role", "user")
  usr.put("content", user)
  var msgs = arr()
  msgs.add done(sys)
  msgs.add done(usr)
  var root = obj()
  root.put("model", cOpenAiModel)
  root.put("max_tokens", cMaxTokens)
  root.put("stream", true)
  root.put("messages", done(msgs))
  result = withExtra(done(root).text)

proc spawnCurlDetached(curlCmd, codeFile: string): bool =
  ## A per-turn PowerShell wrapper FILE runs curl through `cmd /c` and writes
  ## the exit code afterwards; that file is the "the process is gone" signal
  ## the poller needs and that a detached spawn otherwise cannot give.
  ##
  ## Why a file and not an inline command line -- MEASURED 2026-09-07 on the
  ## live sidecar: the inline form `... && (echo 0> code) || (echo 1> code)`
  ## produced a 0-byte code file at once and NO .sse at all: cmd reads the
  ## digit before `>` as a stream handle (`0>` redirects stdin), and the
  ## nested PowerShell/cmd quoting of the `-H "..."` headers broke the curl
  ## line, so the `||` branch ran immediately. The recorder wrapper
  ## (speech.nim) already uses a script file for the same reason.
  let ps1 = codeFile & ".ps1"
  # No `cmd /c`: MEASURED 2026-09-07, a line that BEGINS with a quoted exe
  # (`"curl.exe" -N ...`) makes cmd strip the first and last quote of the
  # whole line, which mangles the `-o "<path>"` at the end -- curl exited 1
  # and wrote nothing. The wrapper starts curl itself: exe and arguments
  # split here, each in a single-quoted PowerShell string.
  var exe = curlCmd
  var args = ""
  if curlCmd.len > 0 and curlCmd[0] == '"':
    let q = curlCmd.find('"', 1)
    if q > 0:
      exe = curlCmd[1 ..< q]
      args = curlCmd[q + 1 .. ^1].strip()
  else:
    let sp = curlCmd.find(' ')
    if sp > 0:
      exe = curlCmd[0 ..< sp]
      args = curlCmd[sp + 1 .. ^1].strip()
  let script = "$ErrorActionPreference = 'Continue'\r\n" &
    "$p = Start-Process -FilePath '" & exe.replace("'", "''") &
    "' -ArgumentList '" & args.replace("'", "''") &
    "' -Wait -PassThru -WindowStyle Hidden\r\n" &
    "Set-Content -Path '" & codeFile.replace("'", "''") &
    "' -Value ([string]$p.ExitCode) -NoNewline\r\n"
  if not writeAll(ps1, script): return false
  result = spawnDetached("powershell.exe",
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & quoteArg(ps1))

proc llmStreamStart*(system, user: string; id: var int;
                     note: var string): bool =
  ## Launch a turn and return AT ONCE. False + a note means nothing was
  ## launched and the caller must fall back to the synchronous path.
  id = -1
  note = ""
  if not llmCanStream():
    note = "engine '" & cEngine & "' has no streaming path here" &
           (if cStreaming: "" else: " (llmStreaming is off)")
    return false
  if gTId.len >= cMaxInFlight:
    note = "maxTurnsInFlight (" & $cMaxInFlight & ") already streaming; " &
           "this turn was answered synchronously instead"
    return false
  let outFile = tempPath(".sse")
  let codeFile = outFile & ".code"
  var fake = false
  if cFakeFile.len > 0:
    # The fixture stands in for curl entirely: no key is read and no process
    # is started, and `llmCurlCalls()` therefore does not move -- which is what
    # the "no key -> no curl" check counts.
    if not exists(cFakeFile):
      note = "llmFakeStreamFile is set to " & cFakeFile & " and there is no " &
             "such file; nothing was started"
      return false
    fake = true
  elif cEngine == "anthropic":
    let key = getEnv("ANTHROPIC_API_KEY", "")
    if key.len == 0:
      note = "anthropic: ANTHROPIC_API_KEY is not set; no request was made"
      return false
    let bodyFile = tempPath(".json")
    if not writeAll(bodyFile, anthropicBody(system, user)):
      note = "anthropic: could not write the request body to " & bodyFile
      return false
    gCurlCalls = gCurlCalls + 1
    if not spawnCurlDetached(quoteArg(cCurlExe) & " -N -s --max-time 120" &
        " -H \"x-api-key: " & key & "\"" &
        " -H \"anthropic-version: " & AnthropicVersion & "\"" &
        " -H \"content-type: application/json\"" &
        " --data-binary @" & quoteArg(bodyFile) &
        " -o " & quoteArg(outFile) & " " & quoteArg(AnthropicUrl), codeFile):
      note = "anthropic: could not spawn a detached curl"
      return false
  else:
    let key = openAiKey()
    if key.len == 0:
      note = "openai: " & cOpenAiKeyEnv & " is not set; no request was made"
      return false
    let bodyFile = tempPath(".json")
    if not writeAll(bodyFile, openAiStreamBody(system, user)):
      note = "openai: could not write the request body to " & bodyFile
      return false
    gCurlCalls = gCurlCalls + 1
    if not spawnCurlDetached(quoteArg(cCurlExe) & " -N -s --max-time 120" &
        " -H \"Content-Type: application/json\"" &
        " -H \"Authorization: Bearer " & key & "\"" &
        " --data-binary @" & quoteArg(bodyFile) &
        " -o " & quoteArg(outFile) & " " & quoteArg(openAiUrl()), codeFile):
      note = "openai: could not spawn a detached curl"
      return false
  gNextTurn = gNextTurn + 1
  gStreamStarts = gStreamStarts + 1
  id = gNextTurn
  gTId.add id
  gTOut.add (if fake: cFakeFile else: outFile)
  gTCode.add codeFile
  gTPos.add 0
  gTPend.add ""
  gTFake.add fake
  gTEnded.add false
  gTEvents.add 0
  gTStop.add ""
  gTErr.add ""
  note = (if fake: "streaming from the fixture " & cFakeFile &
                   " (no curl, no key)"
          else: "streaming " & cEngine & " " & llmModel() & " into " & outFile)
  result = true

proc deltaOfPayload(payload: string; stopReason: var string; apiErr: var string;
                    ended: var bool): string =
  ## One payload, either wire shape. Anthropic events carry `type`; OpenAI's
  ## chunks carry `choices`. Neither is assumed of the other.
  result = ""
  let t = jr.asText(jr.child(jr.whole(payload), "type"), "")
  if t.len > 0:
    case t
    of "content_block_delta":
      result = deltaTextOf(payload)
    of "message_delta":
      let sr = jr.asText(jr.field(payload, "delta.stop_reason"), "")
      if sr.len > 0: stopReason = sr
    of "message_stop":
      ended = true
    of "error":
      apiErr = jr.asText(jr.field(payload, "error.message"), "")
      if apiErr.len == 0: apiErr = oneLine(payload)
    else:
      discard
    return
  let ch = jr.at(jr.field(payload, "choices"), 0)
  result = jr.asText(jr.child(jr.child(ch, "delta"), "content"), "")
  let fr = jr.asText(jr.child(ch, "finish_reason"), "")
  if fr.len > 0 and fr != "null":
    stopReason = fr
    ended = true
  let em = jr.asText(jr.field(payload, "error.message"), "")
  if em.len > 0: apiErr = em

proc llmStreamPoll*(id: int; newText: var string; finished: var bool;
                    note: var string): bool =
  ## Consume whatever arrived since the last poll. `finished` is the finished
  ## STATE of the stream, not "this poll produced nothing" -- a stream that is
  ## merely slow reports false with an empty `newText`.
  newText = ""
  finished = false
  note = ""
  let idx = findTurn(id)
  if idx < 0:
    note = "no in-flight turn " & $id
    return false
  let content = readAll(gTOut[idx])
  var avail = content.len
  if gTFake[idx]:
    let want = gTPos[idx] + cFakeChunk
    if cFakeStall and gTPos[idx] > 0:
      avail = gTPos[idx]
    elif want < avail:
      avail = want
  if avail > gTPos[idx]:
    let text = gTPend[idx] & content[gTPos[idx] ..< avail]
    gTPos[idx] = avail
    # Only COMPLETE lines are parsed; the tail is carried to the next poll.
    var lines: seq[string] = @[]
    var cur = ""
    for chx in text:
      if chx == '\n':
        lines.add cur
        cur = ""
      elif chx != '\r':
        cur.add chx
    gTPend[idx] = cur
    for line in lines:
      if not line.startsWith("data:"): continue
      let payload = line[5 ..< line.len].strip()
      if payload.len == 0: continue
      if payload == "[DONE]":
        gTEnded[idx] = true
        continue
      gTEvents[idx] = gTEvents[idx] + 1
      var stop = gTStop[idx]
      var err = gTErr[idx]
      var ended = gTEnded[idx]
      let piece = deltaOfPayload(payload, stop, err, ended)
      gTStop[idx] = stop
      gTErr[idx] = err
      gTEnded[idx] = ended
      if piece.len > 0: newText.add piece
  if gTEnded[idx]:
    finished = true
  elif gTFake[idx]:
    if gTPos[idx] >= content.len and not cFakeStall: finished = true
  elif exists(gTCode[idx]) and gTPos[idx] >= content.len:
    # curl is gone AND everything it wrote has been parsed. Both halves matter:
    # the exit-code file can land while the last bytes are still unread.
    finished = true
  if finished:
    if gTErr[idx].len > 0:
      note = "the API returned an error event: " & gTErr[idx]
    elif gTEvents[idx] == 0:
      note = "the stream ended with no SSE events (" & $content.len &
             " bytes in " & gTOut[idx] & ") -- curl wrote something that is " &
             "not an event stream"
    else:
      note = $gTEvents[idx] & " SSE events" &
             (if gTStop[idx].len > 0: ", stop_reason=" & gTStop[idx] else: "")
  result = true

proc llmStreamStopReason*(id: int): string =
  let idx = findTurn(id)
  if idx < 0: return ""
  result = gTStop[idx]

proc llmStreamStats*(): JsonObject =
  result = obj()
  result.put("streaming", cStreaming)
  result.put("canStream", llmCanStream())
  result.put("inFlight", gTId.len)
  result.put("maxInFlight", cMaxInFlight)
  result.put("turnTimeoutMs", cTurnTimeoutMs)
  result.put("started", gStreamStarts)
  result.put("fakeStreamFile", cFakeFile)
  result.put("fakeStall", cFakeStall)

proc llmHasFake*(): bool = cFakeFile.len > 0

proc llmFakeSyncComplete*(sink: SegmentSink; note: var string): string =
  ## The SYNCHRONOUS shape of the very same fixture, so the negative control
  ## ("with llmStreaming off the reply is identical in text") compares like
  ## with like instead of comparing streaming against the builtin fallback --
  ## which would differ for a reason that is not the code under test.
  note = ""
  let text = readAll(cFakeFile)
  if text.len == 0:
    note = "llmFakeStreamFile " & cFakeFile & " is missing or empty"
    return ""
  var st = Streamer(buf: "", emitted: 0)
  var full = ""
  var events = 0
  var stop = ""
  var err = ""
  var ended = false
  for line in splitLines0(text):
    if not line.startsWith("data:"): continue
    let payload = line[5 ..< line.len].strip()
    if payload.len == 0 or payload == "[DONE]": continue
    events = events + 1
    let piece = deltaOfPayload(payload, stop, err, ended)
    if piece.len > 0:
      full.add piece
      feed(st, piece, sink)
  finish(st, sink)
  if err.len > 0:
    note = "the fixture carries an error event: " & err
    return ""
  note = "llmFakeStreamFile (SYNCHRONOUS): " & $events & " SSE events, " &
         $full.len & " chars, no curl and no key"
  result = full
