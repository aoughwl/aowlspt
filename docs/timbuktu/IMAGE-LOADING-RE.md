# Post-1.0 client image loading (`/files/*`) — why trader avatars & quest icons never load

Client build **1.1.0.1.46777**. Symptom: trader avatars spin forever on the Traders
screen, quest icons never draw on Tasks, and the backend log shows **zero
`GET /files/` requests** — the client never asks our backend for these images at all.

This note records what is provable **headless** (static analysis + the capture + the
SPT surface), what is **not** provable headless, and the fix that follows.

---

## Headline

**The image base is not something the config we serve can redirect.** The post-1.0
client fetches `/files/*` images (trader avatars, `/files/handbook/*` icons,
`/files/quest/icon/*`, `/files/documents/*`) from BSG's **asset CDN host**
(`s3-prod.escapefromtarkov.com/regular`, from the capture), **independent of the
`backend.Static` field we set in `/client/game/config`.** Offline that host is
unreachable, so the request never leaves for a host we answer → infinite spinner,
zero `/files` at our backend. Serving `/files` and setting `backend.Static` are both
**necessary-but-not-sufficient**: they are the right destination, but nothing is
pointing the client at them.

**This is not fixable from the tarkov mod / server config alone.** It needs a
**host-level host redirect** of the CDN host onto our backend, plus one **live trace**
to confirm the exact host+path the client actually dials.

---

## What is proven

### 1. The image URL the client is *told* to build
`/client/game/config` (capture `responses/034.json`) carries:

```
backend.Static  = "https://s3-prod.escapefromtarkov.com/regular"
trader.avatar   = "/files/trader/avatar/<id>.jpg"      (capture 071 = traderSettings)
quest.image     = "/files/quest/icon/<id>.jpg"         (build/db/db.json)
```

The image URL the client forms is therefore `Static + path` =
`https://s3-prod.escapefromtarkov.com/regular/files/trader/avatar/<id>.jpg` — note the
**`/regular` path prefix** the CDN base contributes.

All CDN/host names present anywhere in the captured responses:

| host | role (config field) |
|---|---|
| `gw-pvp.escapefromtarkov.com` | Main / Trading / Messaging / RagFair |
| `lobby.escapefromtarkov.com`  | Lobby |
| **`s3-prod.escapefromtarkov.com/regular`** | **Static — the image/asset CDN** |
| `wsn-01/02/03.escapefromtarkov.com` | notifier websockets |

### 2. On our stack, `/files` was never requested — in the capture *or* live
The captured main-backend traffic (manifest URL list) contains **no `/files` request
at all** — images went to `s3-prod` over a separate connection the capture did not
record. Live, with our `backend.Static = https://127.0.0.1` served (coordinator
confirmed), the client **still** issues nothing to us. So the client is not resolving
`/files` against the value we put in `backend.Static`.

### 3. The client reaches our backend by the launcher `BackendUrl`, not the config hosts
The backend serves **HTTPS on port 443** for a post-1.0 client (`aowlbackend.nim`:
"Terminates TLS on port 443 … what a real post-1.0 client needs, on port 443").
`BackendUrl = "https://127.0.0.1"` (= 443) is reachable and is what `/client/*` and the
`il2cpp_init` `/client/metadata` POST use (see `docs/timbuktu/METADATA-RE.md`: metadata
is a WinHTTP POST to **port 443** of the launcher `BackendUrl` host, cert validation
disabled). The config `Backend.*` hosts (`gw-pvp`, `lobby`) are **not** how the client
reaches us — they are unreachable BSG hosts; if the client routed `/client/*` through
`Backend.Main` the menu could not have booted. So `Backend.Main`/`Static`/… are not the
routing lever for this client; the launcher `BackendUrl` is. That is exactly why
setting `Static` changed nothing.

### 4. Corroboration from SPT 4.1 (`reference/spt-4.1-surface.txt`)
- `SPTarkov.Server.Core.Models.Eft.Game.Backend` has only **five** fields:
  `Lobby, Main, Messaging, RagFair, Trading` — **no `Static`.** So a `Static` key we add
  is schema-foreign for this lineage; on the typed client object it lands in
  `ExtensionData` and drives nothing.
- SPT serves images via `Routers.ImageRouter : IHttpListener` on the **same**
  `BackendIp:BackendPort` as everything else (no separate CDN), i.e. SPT makes the
  client take images from the one host it already talks to. It does not do that by
  setting a `Static` CDN URL (there is no such field) — it does it because that client
  generation resolved `/files` against the main connection. Our post-1.0 build clearly
  added the `s3-prod` CDN split (the capture proves it), which SPT's model predates.

### 5. Static string RE of the loader is **not possible headless**
Every managed string literal (class/method names, URL format fragments, config field
names) lives in the **encrypted** `global-metadata.dat` (27 MB). Verified:
`"/files/"`, `"avatar"`, `"s3-prod"`, `"Static"`, `"EasyBundle"`, `"RequestHandler"`,
`"TexturesPool"`, `"escapefromtarkov"` — **0 occurrences** in `global-metadata.dat` and
**0** in `GameAssembly.dll` (ASCII and UTF-16). There is no plaintext image host in the
binary (matching METADATA-RE's finding for the metadata path). So the exact
class/method/RVA of the image loader cannot be named without either running the
documented metadata decryptor (large) or the live client.

---

## What is *not* proven headless (needs one live trace)
Whether the client's image base is a **hardcoded** `s3-prod` constant, or a config
field we are **not** setting, cannot be told apart from strings (encrypted) alone. Both
predict the exact live symptom (our `Static` ignored, zero `/files` to us). The one
observation that settles it and names the redirect target:

> On the Traders screen, capture the client's outbound **DNS query / TLS SNI / WinHTTP
> `WinHttpSendRequest`** (a host-side hook is the cleanest — the notifier and metadata
> paths are already WinHTTP). Record the exact **host : port : path** of the avatar GET.

Expected from the capture evidence: `s3-prod.escapefromtarkov.com : 443 :
/regular/files/trader/avatar/<id>.jpg`.

---

## The fix (host-level, not tarkov-mod)
Once the host is confirmed, make the client's CDN request land on our backend:

1. **Redirect the CDN host → our backend.** Add `s3-prod.escapefromtarkov.com`
   (and any regional image host the trace reveals) to whatever the injected host uses
   to steer the client at `127.0.0.1` — a `hosts` file entry `127.0.0.1
   s3-prod.escapefromtarkov.com`, or a WinHTTP/`getaddrinfo` hook in
   `host/Aowlspt.Host.Il2Cpp`. Our 443 TLS backend already routes by **path**, so a
   request with a foreign `Host:` header is served fine, and TLS cert validation is
   disabled client-side (METADATA-RE), so a self-signed cert for that host is accepted.

2. **Serve the CDN path prefix.** The CDN URL carries the `/regular` segment, so the
   real path is `/regular/files/...`, not `/files/...`. The `/files/` placeholder route
   (this branch) must **also** answer `/regular/files/` (register the extra prefix and
   widen the backend's image-content-type/no-deflate check to match it), or the host
   redirect strips `/regular` before dispatch.

Item 1 is host/installer work (branch `fix-graphics-gate-on-bridge`), **out of scope
for the tarkov mod / backend.** Item 2 is a one-line route add on this branch, ready to
apply the moment the trace confirms the `/regular/files/` path.

## Honest status
- **Server config alone cannot fix this** (proven: `Static` ignored, backend already
  reachable, client dials a host our config does not control).
- The `Static`/`Lobby` keys added earlier this branch are harmless but **were not the
  fix** — keep or drop; they change nothing for images.
- Real fix = **host-level CDN host redirect + `/regular/files/` serving**, gated on one
  live WinHTTP/DNS trace to confirm the host.
