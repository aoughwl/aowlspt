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
## STREAMING, AND ITS ONE HONEST LIMITATION
## ----------------------------------------
## The anthropic path runs `curl -N -s` with the SSE written to a file, and then
## parses that file. `util.runCmd` is `execCmdEx`, which BLOCKS until the child
## exits, and a nimony mod has no threads and no async to poll the growing file
## from. So the sentences reach the sink in order, one call per sentence, but
## they reach it AFTER the response has finished arriving rather than while it
## arrives. The parser is written against the real event stream (it consumes
## `data:` lines incrementally in arrival order), so making this genuinely
## concurrent is a change to how curl is launched — a detached curl plus a tick
## that re-reads the file — and not a change to the parsing below. Said out loud
## here because a "streaming" engine that silently is not one is exactly the
## class of quiet wrongness this repo keeps paying for.

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
var gSeq: int = 0
var gCurlCalls: int = 0      ## proves "no key -> no curl" instead of asserting it

const AnthropicUrl = "https://api.anthropic.com/v1/messages"
const AnthropicVersion = "2023-06-01"

proc defaulted(v, fallback: string): string =
  if v.len > 0: v else: fallback

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
  gSeq = gSeq + 1
  result = joinPath(cWorkDir, "aowlbm_" & $nowMs() & "_" & $gSeq & suffix)

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
    p.path = "https://api.openai.com/v1/chat/completions"
    p.model = cOpenAiModel
    if getEnv("OPENAI_API_KEY", "").len == 0:
      p.ok = false
      p.note = "OPENAI_API_KEY is not set in this process's environment " &
               "(never read from config or source)"
    else:
      p.ok = true
      p.note = "ok (cloud; model " & cOpenAiModel & ", non-streaming)"
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
  st.buf = parts[parts.len - 1]

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
  result = done(root).text

proc runOpenAi(system, user: string; sink: SegmentSink;
               note: var string): string =
  let key = getEnv("OPENAI_API_KEY", "")
  if key.len == 0:
    note = "openai: OPENAI_API_KEY is not set; no request was made " &
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
    " --data-binary @" & quoteArg(bodyFile) &
    " https://api.openai.com/v1/chat/completions")
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
  note = "openai " & cOpenAiModel & ": " & $content.len & " chars (non-streaming)"
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
