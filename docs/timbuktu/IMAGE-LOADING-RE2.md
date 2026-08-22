# Trader avatars and quest icons never load — the real cause, with disassembly

Build: EFT `1.1.0.1.46777` (IL2CPP), against the aowlspt emulator.
Repo branch with the fix: `feat-image-fix2`.

**Verdict: the client *does* issue the HTTP request. It dies in the TLS
handshake, before a single byte of HTTP, because `DownloadTexture2D` uses
`UnityEngine.Networking.UnityWebRequest` with no `certificateHandler`, and the
emulator's HTTPS listener presents a self-signed certificate. EFT's ordinary
`/client/*` traffic is unaffected because that goes through the managed HTTP
stack, which post-1.0 configures to accept any certificate.**

The three earlier theories were wrong for the same reason this one is right:
everyone was looking at HTTP. The failure is one layer below HTTP.

---

## 1. Correcting the evidence I was handed

Two of the three "decisive" observations were real but did not mean what they
were taken to mean.

| Observation | What it actually proves |
| --- | --- |
| getaddrinfo/GetAddrInfoW hook logged **zero** hostnames | Nothing about images. `backend.Static` is `https://127.0.0.1` — an **IP literal**. There is no name to resolve, for images or for anything else. The hook could never have fired for this traffic. It also never fired for the working `/client/*` traffic, which is the tell that the probe was blind, not that the client was idle. |
| Backend logged **zero** `/files/` requests | True, and the cause is that the connection never got as far as sending a request line. |
| "The client never attempts a network fetch" | **False.** It attempts one for every icon. |

The disproof is in the user's own client logs, which nobody had read:

`D:\Aowlspt\Logs\log_2026.08.21_18-05-08_1.1.0.1.46777\...output_000.log:884`

```
2026-08-21 18:05:48.876|Info|output|Load texture at : https://127.0.0.1/files/quest/icon/64a2c939d73e87e12400432b.jpg
  EFT.<LoadTexture>d__219:MoveNext()
  EFT.<LoadTextureWithCache>d__217:MoveNext()
  EFT.ClientBackendSession:LoadTextureWithCache(String, String)
  EFT.<LoadTextureMain>d__216:MoveNext()
  ... Utils:LoadIconSprite(IImageLoader, String)
  ... EFT.Quests.QuestTemplate:LoadIconSprite(IImageLoader)
  ... EFT.UI.NotesTaskDescription:Show(Quest, IImageLoader)
  ... EFT.UI.QuestsListView:SelectQuestView(QuestListItem, Boolean)

2026-08-21 18:05:48.911|Error|output|Warning! Downloaded sprite is null: /files/quest/icon/64a2c939d73e87e12400432b.jpg
  <LoadIconSprite>d__65:MoveNext()
  EFT.<DownloadTexture2D>d__218:MoveNext()
```

35 ms from request to a null texture. The URL is exactly what the emulator's
`backend.Static` + the database's `avatar`/`image` field produce.

And `D:\Aowlspt\aowlspt\nettrace.log` shows where those 35 ms went — bursts of
accepted TLS sockets that never produce a request line, interleaved with the
`/client/*` traffic that works fine on the same host and port:

```
[44909281] serve sock=804 idx=1 tls=1 req=[POST /client/trading/api/getTraderAssort/5935c25fb3acc3127c3d8cd9 HTTP/1.1]
[44910046] accept sock=736 idx=1 (tls)
[44910062] handshake FATAL sock=736 idx=1
[44910953] accept sock=736 idx=1 (tls)
[44910968] handshake FATAL sock=736 idx=1
[44911859] accept sock=812 idx=1 (tls)
[44911859] handshake FATAL sock=812 idx=1
[44912609] accept sock=744 idx=1 (tls)
[44912625] handshake FATAL sock=744 idx=1
   ... 7 in a row, then the managed client resumes normally ...
[44915765] serve sock=744 idx=1 tls=1 req=[POST /client/items/prices/54cb57776803fa99248b456e HTTP/1.1]
```

123 `handshake FATAL` lines in that one run, clustered in exactly this shape.

---

## 2. The real call chain (types, methods, RVAs)

All RVAs are module-relative in `GameAssembly.dll` (image base `0x180000000`).
Resolved with `tools/il2cpp_resolve.py` against the decrypted metadata, and
disassembled with the scratchpad `disa2.py` / `xref2.py` over the `il2cpp`
section.

### 2.1 Entry points — avatars and quest icons are the *same* path

```
EFT.Trading.Trader::.ctor                          0x0D92420
  -> Settings = Info.Settings                       (store at 0x0D926C1, Info+0xA8)
  -> Settings._avatarGetter = new Func<Task<Texture2D>>(this, Trader::LoadAvatar)
                                                    (store at 0x0D92702, Settings+0xD0)

TraderSettings::GetAvatar                          0x2520C50  (<GetAvatar>d__58   MoveNext 0x2521A90)
TraderSettings::AvatarGetter                       0x2520DE0  (<AvatarGetter>d__60 MoveNext 0x2521420)
EFT.Trading.Trader::LoadAvatar                     0x0D94EA0
```

`AvatarGetter` is called from 15 UI sites (`xref2.py 2520de0`), including
`EFT.UI.TraderAvatar::SetAvatar`, `EFT.UI.NotesTask::Show`,
`EFT.UI.TraderRequirementIcon::SetAvatar`, `EFT.UI.QuestRewardView::Show`,
`EFT.UI.TraderDialogWindow::Show` — i.e. the Traders screen *and* the Tasks
screen. Quest icons come in through
`EFT.Quests.QuestTemplate::LoadIconSprite -> Utils::LoadIconSprite (0x1D1B010)`.
Both funnel into the same three session methods.

### 2.2 `TraderSettings` fields (metadata order + observed offsets)

`Id@0x10, AvatarURL@0x18, ... _avatar@0xC8, _avatarGetter@0xD0, _avatarTask@0xD8`

`<GetAvatar>d__58::MoveNext` (0x2521A90):

```
+0x2521BD0  test rbx, rbx            ; rbx = this._avatar (0xC8)
+0x2521BED  cmp  [rbx+0x10], r14     ; Unity m_CachedPtr != 0  -> live sprite
+0x2521BFE  jne  0x2521E99           ; cached: return it
+0x2521C04  cmp  qword [rdi+0xD0], 0 ; _avatarGetter
+0x2521C0C  je   0x2521E97           ; null getter -> return null (never happens; ctor sets it)
+0x2521C2F  call rax                 ; _avatarTask ??= _avatarGetter()
+0x2521CE2  ... await ...
+0x2521D82  call UnityEngine.Sprite::Create
```

### 2.3 `Trader::LoadAvatar` (0x0D94EA0)

```
+0x0D94EEC  cmp byte [rbx+0x88], 0   ; _disposed
+0x0D94EF9  mov r8,  [rbx+0x30]      ; _trading   (ISession)
+0x0D94EFD  mov rax, [rbx+0x68]      ; Settings   (TraderSettings)
+0x0D94F13  mov r9,  [rax+0x18]      ; Settings.AvatarURL  ("/files/trader/avatar/<id>.jpg")
+0x0D94F17  call 0x180040260         ; interface dispatch -> ISession.LoadTextureMain(string)
```

### 2.4 `EFT.ClientBackendSession::LoadTextureMain` (0x0A6E8D0, SM `<...>d__216::MoveNext` 0x0A84900)

`ClientBackendSession` field offsets were derived from its own property getters
(`get_Traders`=0x120, `get_AllProfiles`=0x138, `get_Profile`=0x140,
`get_BackEndConfig`=0x158, `get_ChatServers`=0x168 …), which pins
**`_backendUrls` at `+0xD0`** (type `JsonType.BackendUrls`,
`Main@0x10, Messaging@0x18, Trading@0x20, RagFair@0x28, Lobby@0x30, Static@0x38`).

```
+0x0A849AC  test rcx, rcx            ; this session
+0x0A849B5  mov  rax, [rcx+0xD0]     ; _backendUrls
+0x0A849BF  je   <NRE>
+0x0A849C5  mov  r10, [rax+0x10]     ; baseUrl = _backendUrls.Main
+0x0A849C9  mov  rdx, [rax+0x38]     ;           _backendUrls.Static
+0x0A849D0  je   +0x0A849DB
+0x0A849D2  cmp  dword [rdx+0x10], 0 ; Static.Length
+0x0A849D8  mov  r10, rdx            ; non-empty Static wins
+0x0A849E5  call EFT.ClientBackendSession::LoadTextureWithCache   ; (url, baseUrl)
```

`EFT.EftClientBackendSession::.ctor` copies the incoming `BackendUrls` and
trims trailing `/` and `\` from each field (loop at `0x0A8BE20`–`0x0A8BE65`,
store to `_backendUrls` at `0x0A8BEBF`). Our `Static = "https://127.0.0.1"`
survives unchanged. **`_backendUrls` is not null and `Static` is not empty — the
"missing Static config" theory is dead on its own terms.**

### 2.5 `LoadTextureWithCache` — the three branches (SM `<...>d__217::MoveNext` 0x0A84C50)

State-machine fields: `state@0x00, builder@0x08, url@0x20, baseUrl@0x28,
diskPath@0x30, u__1@0x38` (`AsyncTaskMethodBuilder<Texture2D>` is 0x18 bytes on
this build; confirmed by `lea rcx,[rdi+8]` into `SetResult` at 0x0A854C8).

```
+0x0A84DE8  call EFT.StringExtensions::ConvertToResourceLocation   ; url -> resource key
+0x0A84E0F  call 0x182B722A0                                       ; UnityResourcesProxy.Load<Texture2D>(key)
+0x0A84E9D  cmp  qword [rbx+0x10], 0        ; Unity-null check on the loaded texture
+0x0A84EAB  jne  0x0A8544D                  ; (A) shipped in Resources -> SetResult, done

+0x0A84EC8  call UnityEngine.Application::get_temporaryCachePath
+0x0A84ED7  call System.String::Concat       ; diskPath = temporaryCachePath + url
+0x0A84EEF  call System.IO.File::Exists
+0x0A84EF6  jne  0x0A852FC                  ; (B) ON DISK -> file:// fetch, see below

+0x0A84F07  call System.String::Concat       ; fullUrl = baseUrl + url
+0x0A85072/83  inlined async  LoadTexture(fullUrl) -> Task<ValueTuple<Texture2D,string>>
+0x0A85160  test rbx, rbx                    ; (C) texture == null?
+0x0A85163  je   0x0A8521F                   ;      -> SetResult(null).  No exception, no retry.
+0x0A851A6..+0x0A85209  Path.GetDirectoryName / Directory.CreateDirectory /
            GetReadableTextureCopy / ImageConversion.EncodeToPNG /
            File.InternalWriteAllBytes       ; success writes diskPath for next time
```

Branch **(B)**, at `0x0A852FC`:

```
+0x0A852FC  mov  r14, [rdi+0x30]            ; diskPath
+0x0A8532C  call System.Uri::CreateThis
+0x0A8533F  call System.Uri::get_AbsoluteUri ; -> file:///C:/.../files/...
+0x0A85349  call EFT.ClientBackendSession::DownloadTexture2D
```

So the on-disk branch reuses the *same* downloader with a `file://` URI. No
socket, no TLS, no DNS.

### 2.6 `DownloadTexture2D` (0x0A6ECA0, SM `<...>d__218::MoveNext` 0x0A7FF70) — the actual failure

```
+0x0A8018F  call UnityEngine.Networking.UnityWebRequest::.ctor    ; (url, method, downloadHandler, uploadHandler)
+0x0A80277  call UnityEngine.Networking.UnityWebRequest::SendWebRequest
+0x0A803E2  call UnityEngine.Networking.UnityWebRequest::get_isHttpError
+0x0A80657  ... get_error, Concat -> return (null, errorString)   ; silent, no log
```

**There is no `set_certificateHandler` anywhere in this method.** A bare
`UnityWebRequest` uses Unity's own transport, which validates the server
certificate. The build *does* ship a permissive handler —
`EFT.ClientCertificateHandler::ValidateCertificate` at `0x06B65D0` is literally
`mov al,1 / ret` — but `DownloadTexture2D` never attaches it
(`xref2.py 252e480` on `ClientCertificateHandler::.ctor` → 0 call sites in
compiled code).

Meanwhile the emulator's own certificate is self-signed: `backend/aowlbackend.nim`
generates it (`aowl_net_tls_gencert`, `--cert`/`--key` default to
`<root>/aowlspt-tls-cert.pem`). The managed EFT backend client accepts it because
post-1.0 disables certificate validation on that stack (the same reason the
`/client/*` requests in `nettrace.log` succeed).

**Exact stall point:** `UnityWebRequest::SendWebRequest` at `+0x0A80277`.
The TCP connection is made, the TLS handshake is rejected by Unity, the request
completes as an error, `DownloadTexture2D` returns `(null, "<error>")` — and
crucially, the error branch at `+0x0A80657` **does not log**. `LoadTextureWithCache`
takes `+0x0A85163` and calls `SetResult(null)`. The task *completes*, with null,
so nothing faults and nothing retries; the caller's spinner has no terminal
state for "loaded nothing" and sits there forever. The only visible trace is
`LoadIconSprite`'s own `Warning! Downloaded sprite is null:` line.

### 2.7 Why "zero DNS" was a red herring

`Static` is `https://127.0.0.1`. `LoadTextureMain` concatenates it with the
relative URL and hands the result to `Uri`. An IPv4 literal never enters the
resolver, so `getaddrinfo` is not called for images — nor for any other traffic
in this configuration, which is exactly why the hook logged nothing at all
rather than "127.0.0.1". The hook was correctly installed and correctly reported
that nothing needed resolving.

---

## 3. Trader avatars vs quest icons — one cause, one open question

Both screens are the same code path (§2.1), and both fail for the reason above.

One detail I could not close from the logs on disk: in the five captured
emulator sessions, only `/files/quest/icon/...` URLs appear in
`Load texture at :` lines — never `/files/trader/avatar/...`. The most likely
explanation is simply that the Traders screen was not opened in those runs
(the Tasks screen was — the stack traces are all `QuestsListView`). The code
path leaves no other plausible short-circuit: `_avatarGetter` is set
unconditionally in `Trader::.ctor`, and the database does carry
`"avatar":"/files/trader/avatar/<id>.jpg"` for all 12 traders. **Probe for the
next live run: open Traders, then grep the run's `output_000.log` for
`Load texture at : https://127.0.0.1/files/trader/avatar/`.** With the fix in
§4 applied, the expected result is that no such line appears at all, because
branch (B) short-circuits before `LoadTexture` ever logs.

---

## 4. The fix

### 4.1 What was shipped (`tools/imagecache.py`, branch `feat-image-fix2`)

Take branch **(B)**. `LoadTextureWithCache` checks
`File.Exists(Application.temporaryCachePath + url)` *before* it goes anywhere
near the network, and on a hit fetches the file through a `file://`
`UnityWebRequest`. That is the client's own cache — a real-server session
leaves exactly this tree behind, and 13 such files were already sitting in it on
this machine from the capture run:

```
C:\Users\savant\AppData\Local\Temp\Battlestate Games\EscapeFromTarkov\files\
    banners\6a60a0bdeafa55f8a10ec1ae.jpg
    quest\icon\68de4f01f7823fce16006ecb.png
    seasonal-perks\...
```

`Application.temporaryCachePath` on Windows is
`%LOCALAPPDATA%\Temp\<company>\<product>`, with company/product being the two
lines of `<game>\EscapeFromTarkov_Data\app.info` — `Battlestate Games` /
`EscapeFromTarkov`, verified against the directory above.

The tool:

1. scans the deployed `db.json` for every `/files/...` URL (536 distinct),
2. resolves each against an image source tree with the same layout, matching the
   exact filename first and then the same stem under any image extension —
   necessary because BSG's URLs say `.jpg` for 112 icons that ship as `.png`,
   and Unity's texture loader sniffs bytes rather than names,
3. copies to `<temporaryCachePath>/files/<relative path>`, using the extension
   the **URL** asks for (that is the name `File.Exists` tests),
4. never overwrites an existing cache file, so a genuine download always wins;
   re-running is free.

Run against this machine's SPT image set:

```
$ python tools/imagecache.py --db D:/Aowlspt/aowlspt/db.json \
      --src D:/SPT/SPT_Runtime/SPT_Data/images --game D:/Aowlspt
cache        : C:\Users\savant\AppData\Local\Temp\Battlestate Games\EscapeFromTarkov\files
urls         : 536
copied       : 533
already there: 0
no source    : 3
   missing Hideout/Icon_Cultist
   missing achievement/Rare_21.png
   missing trader/avatar/5824657996560e1be8000848.png     (Ref)
```

**This has already been run** on the user's machine — the cache now holds 546
files including 11 of 12 trader avatars. It touches nothing but the client's own
scratch directory and is undone by deleting that directory.

#### 4.1.1 The last three, and how a fourth would announce itself

The three "no source" lines above are the whole remaining hole, and one of them
was visible in-game: **Ref**'s avatar
(`/files/trader/avatar/5824657996560e1be8000848.png`) drew as a permanent
spinner on the Traders screen, because SPT 3.x never shipped that trader's
portrait and so `--src` has nothing to copy. The real BSG asset is not
obtainable — `prod.escapefromtarkov.com` answers 403 without a session, and no
mirror in reach carries it at the avatar's 128x128.

Two changes close it, in `feat-refavatar-packs`:

* **`imagecache.py --fill-missing`** writes a correctly-sized image for every
  URL with no source rather than leaving nothing. Trader avatars borrow the
  install's own `trader/avatar/unknown.png` — 128x128, BSG-shaped, and already
  the game's own "no portrait" art, so Ref reads as deliberate; the other two
  get a 128x128 plate synthesised in-process from `zlib` alone (dark gradient,
  head-and-shoulders silhouette, thin border). Nothing BSG-owned is
  redistributed by the repo: the fill is either generated at run time or copied
  out of the user's own install. It still refuses to overwrite, so a genuine
  download always wins later.

* **`onFiles` now logs each distinct path it answers with the placeholder.** A
  request only reaches the server when the client's disk cache missed, so every
  such path is exactly a missing asset. The old failure mode was that this was
  *silent*: the screen looked wrong and gave nobody a string to search for. Now
  `aowlspt-backend.log` names it. Capped at 128 distinct paths, because the path
  comes off the wire.

Why this and not a server change: it removes the transport from the problem
entirely. No TLS, no port, no certificate, no route. It is also strictly faster
than the network path the real client uses.

### 4.2 The server-side alternative, if the network path is ever wanted

Two things must both change, and neither is a one-liner:

1. **Transport.** Either
   (a) serve `/files/*` over **plain HTTP** on a second listener and set
   `backend.Static = "http://127.0.0.1:<plainport>"` while the other five
   `backend.*` fields stay on `https://127.0.0.1` — `UnityWebRequest` over
   `http://` has no certificate to reject; or
   (b) install the emulator's certificate into the Windows Trusted Root store
   *and* give it `subjectAltName = IP:127.0.0.1` (Unity's transport verifies the
   name, and an IP literal only matches an IP SAN). Requires admin, and depends
   on Unity's transport consulting the OS store, which I did not verify.

   (a) is the safe one. It needs `backend/aowlbackend.nim` to run a plain
   listener alongside the TLS one; today `--tls` selects one mode
   (`aowlbackend.nim:1860`–`1975`).

2. **Content.** The current `/files/*` handler
   (`mods/tarkov/tarkov.nim:onFiles`) answers every request with a 77-byte grey
   placeholder PNG. Even with the transport fixed, that yields grey squares, not
   avatars. It would need to serve real bytes off disk — and the backend
   currently hardcodes `Content-Type: application/json` and zlib-deflates every
   response (`aowlbackend.nim:846`, `:686`), so the raw-bytes path added on
   `feat-image-cdn-redirect` is the only thing that makes this possible at all.

### 4.3 What is *not* the fix — retiring three dead theories

* **"A `/files/` route is missing."** The route exists on
  `feat-image-cdn-redirect` and serves. It is never reached.
* **"`backend.Static` is unset / wrong."** It is set, non-empty, survives the
  ctor's trailing-slash trim, and produces exactly the URL the client logs.
* **"The client dials BSG's CDN and needs a DNS redirect."** It dials
  `https://127.0.0.1`. The `imageCdnRedirect` hook in
  `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` can be left off permanently; its
  comment block at lines 135–155 (and the `docs/timbuktu/IMAGE-LOADING-RE.md` it
  cites, which does not exist in the tree) describe the real BSG server's
  behaviour from the capture, not this client's behaviour here.

---

## 5. Build status

No compiled code changed *for §4.1 as originally shipped*. `tools/imagecache.py`
is a standalone stdlib-only Python tool; nothing in `host/`, `backend/`, `abi/`
or `mods/` was touched, so there was nothing to rebuild.

§4.1.1 adds one compiled change: the placeholder logging in `onFiles`
(`mods/tarkov/tarkov.nim`), which needs `aowl build-mod mods/tarkov`. Still
nothing in `host/`, `backend/` or `abi/`. Branch `feat-image-fix2` is cut from
`feat-image-cdn-redirect` (which carries the `/files/` route and the raw-bytes
response path, and which the coordinator has already deployed).

## 6. What the user should see

Start the emulator and the client as usual — no redeploy is required for the
image fix itself, because the cache lives outside the install.

* **Tasks screen:** each task's icon draws immediately, at first paint. No
  spinner frame at all — the file is on disk, so there is no async wait worth
  seeing.
* **Traders screen:** all trader portraits draw, except **Ref**
  (`5824657996560e1be8000848`), whose image the SPT source set does not contain;
  that one keeps spinning until an image is supplied for it.
* **Handbook / achievements / hideout / prestige art:** likewise populated
  (533 of 536 referenced assets).
* **`output_000.log`:** the `Load texture at : https://127.0.0.1/files/...`
  lines and the matching `Warning! Downloaded sprite is null:` errors both
  **disappear**, because the loader short-circuits at `File.Exists` before it
  builds a URL.
* **`nettrace.log`:** the bursts of `accept` + `handshake FATAL` on the worker
  indices stop. Isolated `handshake FATAL` lines on `idx=0` will remain — those
  are a different client (the keepalive/notifier probe) and are immediately
  followed by a successful reconnect.

If an icon still spins, get its URL from `Load texture at :` in the run's
`output_000.log` and check whether that exact path exists under
`%LOCALAPPDATA%\Temp\Battlestate Games\EscapeFromTarkov\files\`; a missing file
there is a gap in the source set, not a regression in the loader.

---

# 6. The general fix: the whole class, not the icons

The cache seeding above fixes the assets we happen to have bytes for. It cannot
fix an asset that was never seeded. So the question was: what *else* fails this
way, and can the class be closed at the source?

## 6.1 Audit — every `UnityWebRequest` in the assembly

Enumerated exhaustively by taking xrefs over `.text` + `il2cpp` to every
constructor and every surviving static factory:

```
python xref2.py 55dd220 55dd2b0 55dd4b0 55dd6f0 55df080 55df020 \
                55d9ea0 55d9fa0 55da5f0 55dfac0 55dfbc0 252e480
```

This build ships **no** `UnityWebRequest::Get/Post/Put/Head` statics (stripped),
**no** `UnityEngine.Caching` type at all, and **no** `DownloadHandlerTexture`.
The only entry points are the three ctors, `UnityWebRequestAssetBundle::
GetAssetBundle`, `UnityWebRequestMultimedia::GetAudioClip`, and
`UnityWebRequestTexture::GetTexture` (which has *zero* managed callers). Eight
distinct sites in the whole assembly.

**The headline: `UnityWebRequest::set_certificateHandler` (`0x55DF080`),
`SetCertificateHandler` (`0x55DF020`) and `EFT.ClientCertificateHandler::.ctor`
(`0x252E480`) have zero call sites anywhere in compiled code.** No path in this
client ever attaches a certificate handler.
`EFT.ClientCertificateHandler::ValidateCertificate` exists at `0x252E3D0` and is
dead. So "has a cert handler?" is *no* for every row below, without exception.

| Class::Method | MoveNext RVA | UWR site | local cache / `file://` first? | verdict against a self-signed HTTPS server |
|---|---|---|---|---|
| `ClientBackendSession::DownloadTexture2D` | `0xA7FF70` | ctor `+0xA8018F`, Send `+0xA80277` | no | **silent fail** — the known one |
| `ClientBackendSession::LoadTextureWithCache` | `0xA84C50` | via the above | **yes** — Resources `+0xA84E9D`, `File.Exists` `+0xA84EEF` then `file://` at `+0xA852FC`/`+0xA85349` | fails only on a cache miss, then `SetResult(null)` `+0xA854C8` |
| `Communications.LongPollingRequest::Request` | `0xD680E0` | ctor `+0xD6845D`, Send `+0xD689B2` | no | **silent-ish fail** — the notifier long-poll *fallback*. Logs at `+0xD6930E` but never recovers. Its url comes from `LongPollingRequestAbstract::GetUri` (`0xD6A620`), a static singleton field at `+0x28` — **not** `BackendUrls` |
| `UnityWebDiagnostics::Execute` | `0x139FBB0` | ctor `+0x13A00C7`, Send `+0x13A0335` | no | **fails** — and it is the connection *diagnostic* (`HTTPTransportManager::RunConnectionDiagnostics` `0x1B799A0`), so it will always corroborate a network fault that is not one |
| `UnityWebSender::WaitResponse` | `0x1B81600` | ctor `+0x1B8186A` | no | **would fail all `/client/*`** if this transport were ever selected — see 6.4 |
| `UnityWebSender::ExecuteOperationCoroutine` | `0x1B80B80` | Send `+0x1B80D23` | — | same |
| `AssetsManager.LoadBundleManifestOperation::Coroutine` | `0x1919430` | `GetAssetBundle` `+0x1919747` | url is `Path.Combine` `+0x19196D0` | **safe** — local path, no TLS |
| `BundleBytesLoadOperation::Coroutine` | `0x191C670` | `GetAssetBundle` `+0x191C738` | `file://` base, `Concat` `+0x191C72E` | **safe** |
| `BundleLoadOperation::Coroutine` | `0x191D2B0` | `GetAssetBundle` `+0x191D6B0` | `file://` | **safe** |
| `Matchmaker.MatchmakerIntroVideoScreen::LoadAudio` | `0x1784490` | ctor `+0x1784835` | `AssetsEnvironment::GetStreamingAssetsFileUrl` `0x252D020` at `+0x1784778` | **safe** |

Ragfair icons, banners, prestige/achievement/hideout art are **not** separate
paths: `RagfairIconsLoader::GetIcon` `0x13AFB30` / `::LoadAvatar` `0x13AFC10` to
`::LoadTexture` `0x13AFE00` to `Utils::LoadIconSprite` `0x1D1B010`, and the whole
`LoadTexture*` family has exactly three call sites (`0xA84689`, `0xA849E5`,
`0xA85349`). They all funnel into `LoadTextureMain` `0xA6E8D0` and inherit its
verdict. Videos use `GetStreamingAssetsFileUrl` and are local.

## 6.2 Which config field the asset loader reads — `Static`

Confirmed byte-for-byte in `<LoadTextureMain>d__216::MoveNext`:

```
+0xA849AC  test rcx, rcx              ; session
+0xA849B5  mov  rax, [rcx+0xD0]       ; ClientBackendSession._backendUrls
+0xA849C5  mov  r10, [rax+0x10]       ; .Main
+0xA849C9  mov  rdx, [rax+0x38]       ; .Static
+0xA849D2  cmp  dword [rdx+0x10], 0   ; Static.Length
+0xA849D6  jbe  +0xA849DB             ; empty -> keep Main
+0xA849D8  mov  r10, rdx              ; a non-empty Static WINS
+0xA849E5  call 0x180A6EAB0           ; LoadTextureWithCache
```

`_backendUrls` is at `ClientBackendSession+0xD0`; `JsonType.BackendUrls` is
`{ Main@0x10, Messaging@0x18, Trading@0x20, RagFair@0x28, Lobby@0x30,
Static@0x38 }`. `Main` is the fallback *only* when `Static` is empty — so a
non-empty `Static` is authoritative and the other five may stay on https.

**No scheme forcing anywhere on these paths.** The url is a bare
`String::Concat(baseUrl, url)` at `+0xA84F07`, handed to the ctor unmodified;
`EftClientBackendSession::.ctor` only trims a trailing `/` or `\`
(`0xA8BE20`–`0xA8BE65`, store `0xA8BEBF`). An `http://` value in `Static` is
used verbatim. That is what makes the fix possible at all.

## 6.3 Bundles do not touch the backend

`BundlesManager::get_DownloadingUrl` (`0x692A50`) reads `+0x28`;
`get_LoadingUrl` (`0x6F1680`) reads `+0x30`, which the ctor (`0x191B700`) sets
at `+0x191B91A` to the same string with a 7-character scheme prefix stripped.
That string comes from `AssetsEnvironment::GetDownloadingUrl` (`0x252CDA0`),
built at `+0x252CE1D` from `Application::get_streamingAssetsPath` — i.e.
`file://...\EscapeFromTarkov_Data\StreamingAssets\Windows\`. The metadata carries
`file://` (lit 26747), `file:///` (26748) and the StreamingAssets path (8995),
and **no** bundle CDN literal at all.

**So bundles are local file reads and always were.** They are not a TLS victim,
and no second config field needs pointing anywhere. For resource packs this is
the load-bearing fact: mod-shipped bundles must reach the client through
`StreamingAssets`, **not** through an HTTP route — serving them over the asset
port would work only if something first pointed a bundle url at it, and nothing
does.

## 6.4 Two cautions this turned up

* **The managed stack is not blanket-permissive.**
  `HttpWebSender::OnCertificateValidation` (`0x1B7C970`) returns `true` at
  `+0x1B7CA1A` *only when `sslPolicyErrors == 0`*; on any error it logs and
  returns `false` (`xor al,al`, `+0x1B7CAE5`). `/client/*` works today because
  the stack reports zero policy errors, not because the callback accepts
  anything. Do not treat "the managed stack accepts self-signed" as an
  invariant.
* **`UnityWebSender` is a live alternative transport.**
  `HTTPTransportManager::get__webSender` (`0x1B792E0`) resolves the sender from
  a static singleton slot (`static+0x20`); three exist — `HttpWebSender`
  (managed), `UnityWebSender`, `WsWebSender`. If anything ever selects
  `UnityWebSender`, *all* backend traffic acquires the same certificate-handler
  hole as the texture loader.

## 6.5 The fix that follows

Serve the asset routes over plain HTTP so no handshake, and therefore no
validation, ever happens:

* `--asset-port N` on the backend (default **80**, `0` disables), active only
  under `--tls`. A second listening socket, always plain, sharing the one
  poller and the one route table — see `g_listenSock2` in `abi/aowlspt_net.h`.
* `backend.Static` = `http://127.0.0.1` in the tarkov mod's `onGameConfig`
  (`AssetUrl`). The other five urls stay on the https base.

The cache seeding of section 5 stays, and composes: it short-circuits at
`File.Exists` before any socket, so a seeded asset still loads from disk with no
request at all, and an unseeded one now gets an immediate answer over http
instead of hanging on a handshake that is never accepted.
