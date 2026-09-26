# LiveHime Windows core — port contract

Frozen interfaces for the C++ rewrite of `core/Sources/LiveHimeCore/` (Swift,
macOS) into `core/win/` (C++, Windows). Everything here was read out of the
Swift source or the official Windows client's static analysis; nothing is
invented. `file:line` cites are to the macOS sources under
`plugins/livehime/core/Sources/LiveHimeCore/`.

The rule for this port: **the C++ must behave like the Swift, not like a
reasonable person's idea of what the Swift meant.** Where the Swift does
something odd (field order in a signature, a notice that stays `failed` instead
of returning to `signedOut`), the C++ does the same and the comment says why.

---

## 1. Why this exists

`core/win/livehime-core-stub.cpp` implements all 35 C entry points by emitting
`{"event":"unsupported"}`. The Qt UI shell is complete and correct — the dock
renders, every button is wired — so the only thing standing between "a branded
OBS with a LiveHime panel" and "a working LiveHime" is this layer.

The Swift core cannot simply be compiled for Windows:

| Apple technology | Swift lines | Windows replacement |
|---|---:|---|
| WebKit (`WKWebView`) | 864 in 3 files | WebView2 |
| CryptoKit | 1,576 in 4 files | BCrypt (`bcrypt.dll`) |
| AVFoundation + Speech | 465 in 2 files | not in this milestone |
| Security (Keychain) | 272 in 2 files | Credential Manager |
| Foundation only | 1,977 in 10 files | rewritten in C++ |

`DanmakuClient.swift:62` uses `URLSession.webSocketTask`, which
swift-corelibs-foundation still does not implement on Windows or Linux, so
"install the Swift toolchain" does not avoid writing a WebSocket client either.

---

## 2. Threading contract

`livehime-core.h:4-5`: call from the main thread, state changes arrive on the
main thread. The Swift got that from `DispatchQueue.main`.

- `livehime::dispatch::Init()` creates a message-only window (`HWND_MESSAGE`) on
  the thread that calls it. OBS loads plugins on its Qt main thread, which
  pumps, so this is the main thread.
- Every network completion is `dispatch::Post`ed back to it before the UI
  callback fires. No callback ever runs on a worker thread.
- The core contains no Qt. The dispatcher is raw Win32 on purpose, so the
  session layer stays testable and the plugin can later be built without Qt.

## 3. Foundation modules (written)

| File | Replaces |
|---|---|
| `core/win/platform/dispatch.{h,cpp}` | `DispatchQueue.main` |
| `core/win/net/http.{h,cpp}` | `URLSession` (WinHTTP, 4-worker pool, manual redirects, auto gzip, cookies applied from the jar) |
| `core/win/net/cookies.{h,cpp}` | `HTTPCookieStorage` (RFC 6265 domain/path matching) |
| `core/win/net/crypto.{h,cpp}` | `CryptoKit.Insecure.MD5`, SHA-256, HMAC, base64, CSPRNG — all BCrypt |
| `core/win/net/signing.{h,cpp}` | `WBISigner`, the pc_link app signature |
| `core/win/auth/credentials.{h,cpp}` | `KeychainCredentialStore` (Credential Manager) |

`net::Send(req, done)` is the single entry point: `done` runs on the main
thread, exactly once, even on transport failure. `Request.headers` must not
contain `Cookie` — the jar adds it.

---

## 4. The 35 entry points and what each must emit

Authoritative list: `core/include/livehime-core.h`. Output shapes:
`CBridge.swift:73-131` (`fields(for:)`, `json(for:)`) and
`CBridge.swift:194-222` (`errorFields`, `areaFields`).

JSON is emitted with `JSONSerialization`'s `.sortedKeys`, so key order is
deterministic and the C++ must sort keys too. The C++ UI reads these objects by
key, so ordering is cosmetic — but keeping it makes logs diffable against the
macOS build.

### 4.1 Session state — `{"state": ...}`

`CBridge.swift:103-131`, verbatim field sets:

```json
{"state":"signedOut"}                                  // + "notice" when set
{"state":"qrCode","scanned":false,"qrPng":"<base64 png>"}
{"state":"verifying"}
{"state":"ready","mid":0,"username":"","roomId":0,"shortRoomId":0,"title":"","liveStatus":0,"areaId":0}
{"state":"failed","notice":"...","detail":"..."}
```

`notice` values (`SessionCoordinator.swift:10-18`), emitted as the raw string:

```
sessionExpired | legacyNeedsLogin | qrExpired | noLiveRoom | network | server | keychain
```

`qrPng` is present only when the QR image encoded; `scanned` is always present
for `qrCode`.

The state machine rule that matters (`SessionCoordinator.swift:21-25`): only an
explicit "not logged in" from Bilibili returns to `signedOut`; every other
problem stays `failed` **with the credentials kept**, so a transient outage
never throws the user back to the login screen. Do not "improve" this.

### 4.2 Room events — `{"event": ...}`

`CBridge.swift:73-101`:

```
{"event":"room","kind":"chat","uid":…,"user":…,"text":…[,"medal":…][,"dmid":…][,"replyTo":…][,"emots":{…}][,"sticker":{"url","w","h","key"}]}
{"event":"room","kind":"gift","user","name","count","paid","totalCoin"}
{"event":"room","kind":"superChat","user","text","price","seconds"}
{"event":"room","kind":"guard","user","level","name","count"}
{"event":"room","kind":"enter"|"share"|"follow","user"}
{"event":"room","kind":"watched"|"likes"|"onlineRank","value"}
{"event":"room","kind":"liveStarted"}
{"event":"room","kind":"liveEnded"}
{"event":"room","kind":"roomChanged","title"}
```

### 4.3 Errors — merged into the emitting event

`CBridge.swift:194-218`:

```
{"kind":"faceAuth"[,"voucher":…]}
{"kind":"faceAuthQR","qr":…}
{"kind":"sessionExpired"}
{"kind":"noLiveRoom"}
{"kind":"api","code":…,"message":…}
{"kind":"http","code":…}
{"kind":"notReady"}
{"kind":"server","message":"missingStreamConfig"}
{"kind":"network"|"server","message":"<swift error description>"}
```

### 4.4 Per-entry-point events

| Entry point | Emits |
|---|---|
| `start` | restores the session, then a state object |
| `start_qr_login` / `cancel_qr_login` / `retry` / `sign_out` | state objects |
| `load_areas` | `{"event":"areas","areas":[{"id","parentId","name","parentName"}]}` or `{"event":"areasFailed",…error}` |
| `start_live` | `{"event":"streamEndpoint","server","key"}` or `{"event":"liveError",…error}` — **the key is a secret and must never be logged** |
| `stop_live` | `{"event":"liveStopped","ok":true}` or `…"ok":false` + error |
| `send_danmaku` / `send_danmaku_reply` | `{"event":"danmakuSent","ok":…}` |
| `send_emoticon` | `{"event":"danmakuSent","ok":…,"sticker":true}` |
| `update_title` | `{"event":"titleUpdated","ok":…}` |
| `mute_user` | `{"event":"userMuted","ok":…,"uid":…}` |
| `load_shield_keywords` / `set_shield_keyword` | `{"event":"shieldKeywords","ok":…,"keywords":[…]}` |
| `emoticons_load` | `{"event":"emoticons","ok":…,"room","packs":[…]}` |
| `emoticon_image` | `{"event":"emoticonImage","url","path"}` (`path` empty on failure) |
| `start_web_login` / `open_face_auth` / `open_face_auth_qr` / `open_cover_page` / `page_eval` / `page_click` | WebView2 host |
| `captions_*` | out of this milestone; keep answering `unsupported` |
| `update_*` | out of this milestone; keep answering `failed`/`unsupported` |
| `probe_run` | `{"event":"probe",…}` |

---

## 5. Endpoints

Read from the Swift, cross-checked against the official Windows client's
extracted strings (`artifacts/current/bililive_secret-relevant-urls.txt`).
Where both exist, they agree — that is the strongest evidence available that
the macOS core is speaking the same protocol as the official client.

| Purpose | Method + URL | Source |
|---|---|---|
| identity / nav | `GET https://api.bilibili.com/x/web-interface/nav` | `BilibiliControlClient.swift:34` |
| server clock | `GET https://api.bilibili.com/x/report/click/now` | `BilibiliLiveClient.swift:477` |
| browser fingerprint | `GET https://api.bilibili.com/x/frontend/finger/spi` | `LiveRoomActions.swift:32` |
| QR generate | `GET https://passport.bilibili.com/x/passport-login/web/qrcode/generate` | `QRLogin.swift:48` |
| QR poll | `GET https://passport.bilibili.com/x/passport-login/web/qrcode/poll` | `QRLogin.swift:49` |
| room by uid | `GET https://api.live.bilibili.com/room/v2/Room/room_id_by_uid` | `BilibiliLiveClient.swift:42` |
| room info | `GET https://api.live.bilibili.com/room/v1/Room/get_info` | `BilibiliLiveClient.swift:243` |
| room info (old) | `GET https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld` | `BilibiliLiveClient.swift:41` |
| areas | `GET https://api.live.bilibili.com/room/v1/Area/getList` | `BilibiliLiveClient.swift:43` |
| start live | `POST https://api.live.bilibili.com/room/v1/Room/startLive` (params on the query string) | `BilibiliLiveClient.swift:284` |
| stop live | `POST https://api.live.bilibili.com/room/v1/Room/stopLive` (form body) | `BilibiliLiveClient.swift:294` |
| upstream | `GET https://api.live.bilibili.com/xlive/app-blink/v1/live/GetUpStreamRtmp` | `BilibiliLiveClient.swift:44` |
| live version | `GET https://api.live.bilibili.com/xlive/app-blink/v1/liveVersionInfo/getHomePageLiveVersion?system_version=2` | `BilibiliLiveClient.swift:45,192-203` |
| danmaku servers | `GET https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo` (WBI-signed) | `LiveRoomActions.swift:65` |
| send danmaku | `POST https://api.live.bilibili.com/msg/send` | `LiveRoomActions.swift:92` |
| update title | `POST https://api.live.bilibili.com/room/v1/Room/update` | `LiveRoomActions.swift:98` |
| face-auth check | `POST https://api.live.bilibili.com/xlive/app-blink/v1/preLive/IsUserIdentifiedByFaceAuth` | `LiveRoomActions.swift:116` |
| mute user | `POST https://api.live.bilibili.com/xlive/web-ucenter/v1/banned/AddSilentUser` | `LiveRoomActions.swift:137` |
| shield keywords | `…/banned/GetShieldKeywordList`, `…/banned/{Add,Del}ShieldKeyword` | `LiveRoomActions.swift:146,155` |
| face auth page | `https://live.bilibili.com/p/html/bilili-page-face-auth/index.html?…` | official client, confirmed in `bililive.dll` |
| web login page | `https://live.bilibili.com/p/html/live-pc-blink/mini-login-v2` | official client, confirmed in `bililive.dll` |

Every request carries `Referer: https://live.bilibili.com/` and
`Origin: https://api.live.bilibili.com` where the Swift sets them
(`BilibiliLiveClient.swift:397-398`, `QRLogin.swift:110`).

## 6. Signing

### 6.1 WBI — for `getDanmuInfo` and other web APIs

`DanmakuProtocol.swift:259-286`. The mixin key comes from `nav`'s
`data.wbi_img.{img_url,sub_url}`; take each URL's **file stem**, concatenate,
then permute with the 64-entry `mixinTable` and keep the first 32 characters.

```
query   = join("&", for key in sorted(keys): key + "=" + pct(value with !'()* removed))
w_rid   = md5(query + mixinKey)          # lowercase hex
result  = the same sorted pairs (values still stripped) + ("w_rid", w_rid)
```

`wts` (unix seconds) is added to the parameters before sorting. Percent encoding
is the RFC 3986 unreserved set. `nav` answers `-101` when signed out but still
carries the WBI keys, so read them **without** the usual API-code check
(`LiveRoomActions.swift:40-41`).

### 6.2 pc_link app signature — for `startLive`

`BilibiliLiveClient.swift:263-288`. Eight fields, **in this exact insertion
order** (the source calls the order load-bearing; extra fields such as
`csrf_token`/`backup_stream` make newer accounts reject the request):

```
appkey=aae92bc66f3edfab
area_v2=<leaf area id>
build=<from getHomePageLiveVersion, fallback "11050">
csrf=<bili_jct cookie>
platform=pc_link
room_id=<room id>
ts=<server clock from /x/report/click/now>
version=<from getHomePageLiveVersion, fallback "8.6.0">
```

`sign = md5(that_string + "af125a0d5279fd576c1b4418a3e8276d")`, and the request
is a POST whose **query string** carries all nine pairs. The app key and secret
match what the official client's `bililive_secret.dll` contains
(`platform=pc_link`, appkey `aae92bc66f3edfab`).

## 7. Cookies

`csrf` is the `bili_jct` cookie (`QRLogin.swift:22`). `buvid3` identifies the
browser to the danmaku server and QR login does not set it, so fall back to
`/x/frontend/finger/spi`'s `data.b_3` (`LiveRoomActions.swift:29-38`).

After a web login the order is the one the official client logs
(`CURRENT_PACKAGE_STATIC_ANALYSIS.md:161-173`): apply cookies → `/x/web-interface/nav`
check → `nav user info success, login success`. Never report "started" because
OBS started pushing; only Bilibili's own answer counts.

## 8. Module layout

```
core/win/
  livehime-core.cpp          the 35 extern "C" entry points (replaces the stub)
  core/emit.{h,cpp}          JSON with sorted keys, matching JSONSerialization
  core/qr/                   qrcodegen (vendored, MIT) + a zlib PNG writer
  platform/dispatch.{h,cpp}  main-thread marshalling
  net/http.{h,cpp}           WinHTTP
  net/cookies.{h,cpp}        cookie jar
  net/crypto.{h,cpp}         BCrypt hashing
  net/signing.{h,cpp}        WBI + pc_link
  auth/credentials.{h,cpp}   Credential Manager, with a DPAPI file overflow
  auth/session.{h,cpp}       SessionState machine + notices
  auth/qrlogin.{h,cpp}       QR generate/poll
  live/liveclient.{h,cpp}    nav, room, areas, start/stop, title, upstream
  live/danmaku.{h,cpp}       WinHTTP WebSocket + protocol
```

### 8.1 Deliberate deviations from the Swift

Each of these is a conscious difference, not an oversight. They are listed here
so a later reader can find them without diffing two languages.

| What | Swift | Windows | Why |
|---|---|---|---|
| danmaku `protover` | `3` (brotli) | `2` (zlib) | Neither Windows nor obs-deps ships brotli; the server honours the requested version and the Swift decoder already implements 2. Flipping back to 3 is a one-line change once brotli is vendored. |
| WS read buffering | drops a packet split across reads | accumulates across reads | `WinHttpWebSocketReceive` returns fragments where `URLSession` returned whole messages. Buffering is strictly more correct; complete packets behave identically. |
| credential storage | Keychain item | Credential Manager, DPAPI file when the blob exceeds 2560 bytes | Credential Manager has `CRED_MAX_CREDENTIAL_BLOB_SIZE`; a Bilibili session is not length-bounded. |
| login QR image | CoreImage | qrcodegen + a zlib PNG writer | No Windows equivalent. Same parameters (ECC M, 4-module quiet zone, whole-number scale off 480); the module pattern may differ because the two pick masks independently, but both scan. |
| `User-Agent` | `Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) … Safari/605.1.15` | same string | Faithful port: the whole login flow was validated against Bilibili with this UA. It is one named constant; switching to a Windows UA is a single edit, but doing so unverified would be a behaviour change, not a port. |

### 8.2 The web view

`start_web_login`, `open_cover_page`, `open_face_auth`, `page_eval` and
`page_click` run in WebView2 (`core/win/web/`). The SDK is vendored under
`core/win/web/sdk/` — the header plus both architectures' static loaders, so
`livehime.dll` stays one file — and the Evergreen Runtime is **not** bundled
because it is a machine-wide component. `web::Available()` probes for it with
the loader's synchronous version check and every entry point reports an honest
failure, with the runtime's own reason, when it is missing.

Three things the host has to get right, all of them in the specification
because the official client's own bundle forced them:

1. The page expects **both** shims. A host that implements only
   `livehime_login.LoginSuccess` makes the page take its web fallback branch,
   because the page's `d()` helper treats the presence of `window.biliBridgePc`
   as "the Windows client" and calls `auth/setRefreshToken` through it
   (established from the official client's `miniLogin.umd.min.js`; see
   `artifacts/current/bililive-web-host-bridge.md`).
2. `callNative` returns a **Promise**, so the shim needs a correlation id and a
   reply message; there is no reply-shaped message handler in WebView2.
3. WebView2 runs document-created scripts in **every frame**, so the
   privileged-origin check is load-bearing rather than belt-and-braces.

After a successful login the order is fixed and is the official client's own:
apply the cookies → `/x/web-interface/nav` → only then report success. The host
does not believe the page's word for it.

`open_face_auth_qr` is still unimplemented, and deliberately not because of
WebView2: the Swift shows that one in a native window of its own
(`CBridge.swift:44-45`), so the missing part is a native QR window.

The Windows `User-Agent` and the `device_name`/`device_platform` literals stay
the macOS values, as §8.1 records; the Windows-correct values are not in any
source we have, and guessing them would be a behaviour change rather than a
port.

## 9. Verification bar

A change is only "done" when the Windows VM shows it:

1. `livehime.dll` builds and loads; the log has `[livehime] control dock loaded`.
2. `%APPDATA%\LiveHime\obs-studio\logs\<newest>.txt` contains the behaviour under
   test, not just absence of errors.
3. No fabricated success: an entry point that cannot do its job emits its
   honest error shape. The stub's whole value was that it never lied; the real
   core must keep that property.
