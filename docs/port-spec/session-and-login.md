# Session & login — Windows C++ port specification

Status: **specification only.** This document specifies what a C++ (Windows) reimplementation of
the LiveHime session/auth core must do to be behaviourally equivalent to the macOS Swift core that
ships in this tree today. It contains no implementation.

Method: read-only analysis of the seven Swift sources below, the Windows package artifacts at
`/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/` (static analysis of
`Livehime-Win-beta-8.6.0.11050-x64.exe`, never executed), and the portable Qt consumer in
`plugins/livehime/src/`. Every claim carries `file:line`. Where a value is not present in any source
it is marked **NOT IN SOURCE** rather than guessed.

Citation convention: a full reference is `File.swift:LINE` (or `File.swift:FROM-TO`). Inside a
numbered list or table whose introductory sentence names one file, a following bare `:LINE` refers
to that same file. `bililive.dll@0x…` / `bililive_secret.dll@0x…` are byte offsets of the cited
literal inside the extracted binary.

---

## 0. Source key

| Short name used below | Full path (relative to `livehime-win-src/` unless absolute) |
|---|---|
| `SessionCoordinator.swift` | `plugins/livehime/core/Sources/LiveHimeCore/SessionCoordinator.swift` |
| `QRLogin.swift` | `plugins/livehime/core/Sources/LiveHimeCore/QRLogin.swift` |
| `CredentialStore.swift` | `plugins/livehime/core/Sources/LiveHimeCore/CredentialStore.swift` |
| `SessionMaintenance.swift` | `plugins/livehime/core/Sources/LiveHimeCore/SessionMaintenance.swift` |
| `AuthBridgeContract.swift` | `plugins/livehime/core/Sources/LiveHimeCore/AuthBridgeContract.swift` |
| `AuthWebViewBridge.swift` | `plugins/livehime/core/Sources/LiveHimeCore/AuthWebViewBridge.swift` |
| `WebLoginWindow.swift` | `plugins/livehime/core/Sources/LiveHimeCore/WebLoginWindow.swift` |
| `CBridge.swift` | `plugins/livehime/core/Sources/LiveHimeCore/CBridge.swift` |
| `PlatformSupport.swift` | `plugins/livehime/core/Sources/LiveHimeCore/PlatformSupport.swift` |
| `BilibiliControlClient.swift` | `plugins/livehime/core/Sources/LiveHimeCore/BilibiliControlClient.swift` |
| `BilibiliLiveClient.swift` | `plugins/livehime/core/Sources/LiveHimeCore/BilibiliLiveClient.swift` |
| `Diagnostics.swift` | `plugins/livehime/core/Sources/LiveHimeCore/Diagnostics.swift` |
| `livehime-core.h` | `plugins/livehime/core/include/livehime-core.h` |
| `CBridge` tests | `plugins/livehime/core/Tests/LiveHimeCoreTests/SessionCoordinatorTests.swift` |
| `account-panel.cpp` | `plugins/livehime/src/account-panel.cpp` |
| `automation.cpp` | `plugins/livehime/src/automation.cpp` |
| `CMakeLists.txt` | `plugins/livehime/CMakeLists.txt` |
| `WINDOWS_PORT.md` | `docs/WINDOWS_PORT.md` |
| `bridge.md` | `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/bililive-web-host-bridge.md` |
| `package.md` | `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/CURRENT_PACKAGE_STATIC_ANALYSIS.md` |
| `minilogin.md` | `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/MINI_LOGIN_WEB_STATIC_ANALYSIS.md` |
| `bililive.dll@0x…` | file offset into `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/extracted/app/bililive.dll` |
| `bililive_secret.dll@0x…` | file offset into `…/extracted/app/bililive_secret.dll` |

The page itself (`mini-login-v2.html`, `miniLogin.umd.min.js`) is quoted from
`/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/` (hashes in `minilogin.md:11-13`).

---

## 1. The C ABI surface being reimplemented

The Qt UI never talks to Bilibili; it calls a flat C ABI and receives JSON through one callback.
A C++ port must expose exactly these symbols (the Windows stub already does, and is the file to
delete function by function: `WINDOWS_PORT.md:51`, `livehime-core-stub.cpp:1-18`).

| Symbol | Contract | Source |
|---|---|---|
| `livehime_core_start(const char *keychain_service, livehime_state_callback, void *context)` | Creates the core, registers the callback, **publishes the initial state**, then restores any saved login. `keychain_service` may be `NULL` for the default store name. | `livehime-core.h:17`, `CBridge.swift:144-159` |
| `livehime_core_stop(void)` | Drops the callback, stops danmaku/TTS, cancels QR login, destroys the core. | `livehime-core.h:18`, `CBridge.swift:161-170` |
| `livehime_core_start_qr_login(void)` | Starts the QR flow. | `livehime-core.h:20`, `CBridge.swift:172-173` |
| `livehime_core_cancel_qr_login(void)` | Cancels it. | `livehime-core.h:21`, `CBridge.swift:175-176` |
| `livehime_core_retry(void)` | Re-verifies the saved login, or starts QR login when nothing is saved. | `livehime-core.h:22`, `CBridge.swift:178-179` |
| `livehime_core_sign_out(void)` | Local sign-out + best-effort server logout. | `livehime-core.h:23`, `CBridge.swift:181-182` |
| `livehime_core_start_web_login(void)` | Cancels QR login and opens the official password/SMS page. | `livehime-core.h:24-26`, `CBridge.swift:372-381` |

Callback type and threading:

```c
typedef void (*livehime_state_callback)(const char *state_json, void *context);
```

- `livehime-core.h:14`; "Call from the main thread. State changes arrive on the main thread"
  (`livehime-core.h:4-5`).
- The string is a NUL-terminated UTF-8 JSON object, valid only for the duration of the call
  (`withCString` at `CBridge.swift:36`, `CBridge.swift:190`).
- The consumer dispatches on the presence of `"event"`: messages **with** `event` are events,
  messages **without** it are session state (`account-panel.cpp:133-136`).
- The UI logs only the `state` name, never the raw JSON (`account-panel.cpp:126-127`, `:143`).
- The store name is overridable at runtime by the environment variable
  `LIVEHIME_KEYCHAIN_SERVICE` (`account-panel.cpp:97`); `NULL` means the default
  (`CBridge.swift:147`, `livehime-core.h:16`). A Windows port must keep this override hook for its
  own store name.

Non-goals of this document: danmaku, live start/stop, emoticons, moderation, captions, updates,
probes. Those are separate events on the same callback (`livehime-core.h:28-136`).

---

## 2. Session state machine

### 2.1 States

Five cases, definition at `SessionCoordinator.swift:26-32`:

| Case | Payload | Meaning |
|---|---|---|
| `signedOut` | `SessionNotice?` (nullable) | Not logged in. The notice is optional; `nil` is a plain signed-out. |
| `qrCode` | `url: String`, `scanned: Bool` | A QR code is on screen. `url` is the QR **content**, not shown as text. |
| `verifying` | — | Identity + room are being checked. |
| `ready` | `LiveAccount` (`mid`, `username`, `room`) | Signed in with a room loaded. |
| `failed` | `SessionNotice`, `detail: String` | Recoverable failure; the saved login is **kept**. |

`LiveAccount` = `mid: Int64`, `username: String`, `room: BilibiliRoomInfo`
(`SessionCoordinator.swift:3-7`). `BilibiliRoomInfo` = `roomID: Int64`, `uid: Int64`,
`shortRoomID: Int64`, `title: String`, `liveStatus: Int`, `areaID: Int`
(`BilibiliLiveClient.swift:5-20`).

The load-bearing invariant, quoted from the source (`SessionCoordinator.swift:20-25`):

> `ready` is only reached once identity AND room have loaded. Only an explicit "not logged in"
> answer from Bilibili returns to `signedOut`; every other problem stays in `failed` with the
> credentials kept, so a transient error never throws the user back to the login screen.

### 2.2 Notices

`SessionNotice: String` — the raw value is the case name, so the JSON `notice` field is exactly one
of these (`SessionCoordinator.swift:10-18`):

| Raw value | Comment in source | Line |
|---|---|---|
| `sessionExpired` | Bilibili rejected the saved login (-101) | `:11` |
| `legacyNeedsLogin` | a v0.1.2 login could not be carried over | `:12` |
| `qrExpired` | the QR code expired repeatedly without a scan | `:13` |
| `noLiveRoom` | the account has no live room | `:14` |
| `network` | could not reach Bilibili | `:15` |
| `server` | Bilibili answered with an unexpected error | `:16` |
| `keychain` | the login could not be read or saved locally | `:17` |

The Qt panel maps `notice` to a locale key by string concatenation
`"LiveHime.Account.Notice." + notice` (`account-panel.cpp:146`, `:180`). The locale files define
exactly these seven suffixes (`data/locale/en-US.ini:34-40`). **A Windows port must keep these
literal strings on the wire**, including `keychain` — renaming it to a Windows-flavoured word
would silently blank the notice text (`account-panel.cpp:146`).

### 2.3 Exact JSON emitted per state

Serialization is `JSONSerialization.data(withJSONObject:options:[.sortedKeys])`, falling back to
`{}` if encoding ever fails (`CBridge.swift:129`). Keys are therefore emitted in ascending order.
All keys here are ASCII, so byte order and lexicographic order coincide. The string is UTF-8 and is
parsed by `QJsonDocument::fromJson` on the UI side (`account-panel.cpp:129`), so only JSON validity
and the key/value semantics are load-bearing.

| State | Keys emitted | Source |
|---|---|---|
| `signedOut` with no notice | `state` | `CBridge.swift:106-108` |
| `signedOut` with notice | `state`, `notice` | `CBridge.swift:108` |
| `qrCode` | `state`, `scanned`, `qrPng` (only when the PNG rendered) | `CBridge.swift:109-112` |
| `verifying` | `state` | `CBridge.swift:113-114` |
| `ready` | `state`, `mid`, `username`, `roomId`, `shortRoomId`, `title`, `liveStatus`, `areaId` — all eight always present | `CBridge.swift:115-123` |
| `failed` | `state`, `notice`, `detail` | `CBridge.swift:124-127` |

Exact wire strings (values illustrative; key order is the sorted order that `.sortedKeys` produces):

```json
{"state":"signedOut"}
{"notice":"sessionExpired","state":"signedOut"}
{"notice":"legacyNeedsLogin","state":"signedOut"}
{"notice":"qrExpired","state":"signedOut"}
{"qrPng":"iVBORw0KGgoAAAANSUhEUg...","scanned":false,"state":"qrCode"}
{"qrPng":"iVBORw0KGgoAAAANSUhEUg...","scanned":true,"state":"qrCode"}
{"scanned":false,"state":"qrCode"}
{"state":"verifying"}
{"areaId":7,"liveStatus":1,"mid":42,"roomId":1001,"shortRoomId":0,"state":"ready","title":"t","username":"up"}
{"detail":"...","notice":"network","state":"failed"}
```

Notes that a port must preserve:

- `qrPng` is the **base64** of a PNG (`Data.base64EncodedString()`, default options)
  (`CBridge.swift:112`). The QR **URL is never emitted to the UI** — only the image
  (`CBridge.swift:109-112`). The URL exists only in the transient `SessionState` value.
- If the PNG cannot be rendered, the `qrPng` key is **omitted** while the state is still `qrCode`
  (`CBridge.swift:112`, optional binding). The macOS tests treat a missing PNG as a failure
  (`SessionCoordinatorTests.swift:458-463`); the automation surface derives `hasQr` from the key's
  presence (`automation.cpp:97`).
- `state` values are exactly `signedOut`, `qrCode`, `verifying`, `ready`, `failed`
  (`livehime-core.h:6`).
- **No cookie, token, CSRF or stream key ever appears in a state message**
  (`CBridge.swift:6-8`, asserted by `SessionCoordinatorTests.swift:449-456`).
- The `detail` field carries `"\(error)"` — the Swift `String(describing:)` of the thrown error
  (`SessionCoordinator.swift:111`, `:342`, `:356`, `:381`, `:391`, `:412`, `:146`). It is diagnostic
  prose, not a stable enum; a port may substitute its own message text, but must never put secrets
  in it.

### 2.4 Publish rule

```swift
public private(set) var state: SessionState = .signedOut(nil) {
    didSet { if state != oldValue { onChange?(state) } }
}
```

`SessionCoordinator.swift:65-67`. Only a *changed* state is published. `CoreBridge` installs
`coordinator.onChange = { self.publish($0) }` (`CBridge.swift:26`), and `publish` forwards the JSON
to the C callback (`CBridge.swift:32-37`). Corollaries:

- Setting `.signedOut(nil)` while already `.signedOut(nil)` emits nothing (e.g. restore with an
  empty store, `SessionCoordinator.swift:346`).
- `maintainSession` changes `credentials` but **not** `state`, so a successful token renewal emits
  no state message at all (`SessionCoordinator.swift:172-176`); it emits the `sessionMaintenance`
  event instead (`CBridge.swift:27`).
- `refreshRoom` produces `.ready` with a different room, so it *does* publish
  (`SessionCoordinator.swift:307`).

### 2.5 Initial message

`livehime_core_start` publishes the coordinator's initial state **before** restoring:

```swift
bridge.publish(coordinator.state)
coordinator.restore()
```

`CBridge.swift:156-157`. The first message the UI ever sees is therefore
`{"state":"signedOut"}` (`SessionCoordinator.swift:65`). `restore()` then possibly re-emits. A
Windows port must emit this first message synchronously inside `livehime_core_start`, before any
network work.

### 2.6 Transition table

Actions are single-flight: `run()` cancels the previous action task before starting a new one
(`SessionCoordinator.swift:334-337`), so a second `startQRLogin` aborts the first.

`restore()` has exactly one call site — the end of `livehime_core_start`
(`CBridge.swift:157`) — where the state is still the initial `.signedOut(nil)`
(`SessionCoordinator.swift:65`). Rows 2-5 below assume that starting state.

| # | From | Trigger | To | Emitted state JSON | Source |
|---|---|---|---|---|---|
| 1 | (start) | `livehime_core_start` | `.signedOut(nil)` | `{"state":"signedOut"}` | `CBridge.swift:156`, `SessionCoordinator.swift:65` |
| 2 | any | `restore()`, `store.load()` throws | `.failed(.keychain, detail:)` | `{"detail":…,"notice":"keychain","state":"failed"}` | `SessionCoordinator.swift:98-100`, `:341-342` |
| 3 | `.signedOut` | `restore()`, store `.none` | `.signedOut(nil)` (unchanged → silent) | — | `:345-346` |
| 4 | `.signedOut` | `restore()`, store `.current` | `.verifying` | `{"state":"verifying"}` | `:347-348`, `:396` |
| 5 | `.signedOut` | `restore()`, store `.legacy` | `.verifying` (then imports legacy cookies) | `{"state":"verifying"}` | `:349-350` |
| 6 | `.verifying` | legacy import incomplete | `.signedOut(.legacyNeedsLogin)` | `{"notice":"legacyNeedsLogin","state":"signedOut"}` | `:354` |
| 7 | `.verifying` | legacy import save fails | `.failed(.keychain, detail:)` | as #2 | `:355-356` |
| 8 | `.verifying` | `nav`/identity answers `isLogin == false` or code `-101` | `.signedOut(.sessionExpired)`, store removed, `credentials = nil` | `{"notice":"sessionExpired","state":"signedOut"}` | `:398-399`, `:407-410`; `BilibiliControlClient.swift:74`, `:80` |
| 9 | `.verifying` | identity or room threw any other error | `.failed(notice(for:), detail:)` | `{"detail":…,"notice":"<mapped>","state":"failed"}` | `:412`, `:423-435` |
| 10 | `.verifying` | identity ok **and** room ok | `.ready(LiveAccount)`, `credentials = saved`, maintenance started | `{"areaId":…,"liveStatus":…,"mid":…,"roomId":…,"shortRoomId":…,"state":"ready","title":…,"username":…}` | `:398-404` |
| 11 | `.signedOut` / `.failed` / any | `startQRLogin()` | `.qrCode(url, scanned:false)` | `{"qrPng":…,"scanned":false,"state":"qrCode"}` | `:102-104`, `:362-367` |
| 12 | `.qrCode(_,false)` | poll → `waitingForScan` (86101) | unchanged (silent) | — | `:370-372` |
| 13 | `.qrCode(url,false)` | poll → `scanned` (86090) | `.qrCode(url,true)` | `{"qrPng":…,"scanned":true,"state":"qrCode"}` | `:373-374` |
| 14 | `.qrCode` | poll → `expired` (86038), `refreshes < maxAutoRefresh` | break poll loop → new `generateQR()` → `.qrCode(newURL,false)` | new `{"qrPng":…,"scanned":false,"state":"qrCode"}` | `:375-378` |
| 15 | `.qrCode` | poll → `expired`, `refreshes == maxAutoRefresh` | `.signedOut(.qrExpired)` | `{"notice":"qrExpired","state":"signedOut"}` | `:376` |
| 16 | `.qrCode` | poll → `succeeded`, `store.save` ok | `.verifying` (then #8/#9/#10) | `{"state":"verifying"}` | `:379-382`, `:396` |
| 17 | `.qrCode` | poll → `succeeded`, `store.save` throws | `.failed(.keychain, detail:)` | as #2 | `:380-381` |
| 18 | any (task running) | `generateQR`/`pollQR` threw, not a cancellation | `.failed(notice(for:), detail:)` | `{"detail":…,"notice":"<mapped>","state":"failed"}` | `:387-392` |
| 19 | any (task running) | `CancellationError` | unchanged, task returns | — | `:387-388` |
| 20 | `.qrCode` | `cancelQRLogin()` | `.signedOut(nil)` | `{"state":"signedOut"}` | `:116-120` |
| 21 | `.qrCode`-less state | `cancelQRLogin()` | unchanged (the `if case` does not match) | — | `:119` |
| 22 | any | `completeWebLogin(fresh)`, save ok | `.verifying` (then #8/#9/#10) | `{"state":"verifying"}` first | `:108-114`, `:396`; test `SessionCoordinatorTests.swift:202-211` |
| 23 | any | `completeWebLogin(fresh)`, save fails | `.failed(.keychain, detail:)` | as #2 | `:109-111` |
| 24 | `.failed` / `.signedOut` | `retry()` with a stored `.current` | `.verifying` | `{"state":"verifying"}` | `:124-127` |
| 25 | `.failed` / `.signedOut` | `retry()` with no stored login **or a store read error** (`try?`) | QR login starts → `.qrCode` | `{"qrPng":…,"scanned":false,"state":"qrCode"}` | `:126-130` |
| 26 | any | `signOut()`, `store.remove()` ok | `.signedOut(nil)`, `credentials = nil`, both tasks cancelled | `{"state":"signedOut"}` | `:134-144` |
| 27 | any | `signOut()`, `store.remove()` throws | `.failed(.keychain, detail:)` | as #2 | `:145-147` |
| 28 | `.ready` | `refreshRoom()` got a room and the mid still matches | `.ready` with the fresh room | new ready JSON | `:303-307` |
| 29 | `.ready` | any room/live request threw `notLoggedIn` | `.signedOut(.sessionExpired)`, store removed, `credentials = nil`, error rethrown | `{"notice":"sessionExpired","state":"signedOut"}` | `:316-327` |
| 30 | `.ready` | `maintainSession()` renewed the login | `.ready` unchanged → **no state message**; emits `{"event":"sessionMaintenance","result":"refreshed"}` | `:172-176`, `CBridge.swift:27` |
| 31 | `.ready` with `liveStatus == 1` | `maintainSession()` | unchanged; emits `{"event":"sessionMaintenance","result":"skippedWhileLive"}` | `:161` |

Error classification feeding rows 9/18 (`SessionCoordinator.swift:419-435`):

- `isSessionRejected` = `BilibiliControlError.notLoggedIn` **or** `BilibiliLiveError.notLoggedIn`
  (`:419-421`) → row 8 / row 29 behaviour.
- `notice(for:)` (`:423-435`): `BilibiliLiveError.missingRoom` → `noLiveRoom`;
  `BilibiliControlError.transport`, `BilibiliLiveError.transport`, `BilibiliLiveError.network`,
  `QRLoginError.network` → `network`; any other `URLError` **except `.cancelled`** → `network`;
  everything else → `server`. Note there is **no** case producing `keychain` here — `keychain` comes
  only from explicit store failures (`:111`, `:146`, `:342`, `:356`, `:381`).
- `notLoggedIn` is produced from Bilibili's API code `-101` at
  `BilibiliControlClient.swift:74` and `BilibiliLiveClient.swift:303`, `:432`; and from
  `data.isLogin == false` on the nav response (`BilibiliControlClient.swift:80`).

Side effects attached to state changes: the danmaku connection follows the ready room
(`CBridge.swift:40-52`) — start on `ready` with a new `roomID`, stop on `signedOut`/`qrCode`, and
do nothing on `verifying`/`failed`.

---

## 3. QR login

### 3.1 Endpoints and parameters

| Literal | Value | Source |
|---|---|---|
| Generate URL | `https://passport.bilibili.com/x/passport-login/web/qrcode/generate` | `QRLogin.swift:48` |
| Poll URL | `https://passport.bilibili.com/x/passport-login/web/qrcode/poll` | `QRLogin.swift:49` |
| `source` | `live_pc` | `QRLogin.swift:51` |
| User-Agent | `Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15` | `QRLogin.swift:134` |
| Referer | `https://live.bilibili.com/` | `QRLogin.swift:110` |
| Request timeout | 12 s | `QRLogin.swift:109` |
| HTTP method | GET, query items | `QRLogin.swift:105-108` |

`source=live_pc` is documented as "Matches the `origin` the official live PC login page is opened
with" (`QRLogin.swift:50-51`) and matches the page's own `origin: 'live_pc'`
(`mini-login-v2.html`, and `minilogin.md:17`). The official page uses the same two paths
(`minilogin.md:35-36`).

Query strings:

```text
GET https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source=live_pc
GET https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=<KEY>&source=live_pc
```

Generate sends exactly one item, `source` (`QRLogin.swift:62`). Poll sends `qrcode_key` first then
`source` (`QRLogin.swift:70-73`). This matches the page's own parameter shapes
(`minilogin.md:72-73`).

### 3.2 No shared cookie jar

```swift
static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    return URLSession(configuration: configuration)
}()
```

`QRLogin.swift:127-133`; the QR client additionally defaults to an ephemeral session
(`QRLogin.swift:56-59`). The comment is explicit: "Requests carry an explicit Cookie header;
nothing is read from or written to a shared cookie jar inside the OBS process"
(`QRLogin.swift:125-126`). Cookies that Bilibili sets on the poll response are harvested manually
(§3.5) and stored by the core, never by an HTTP stack's cookie store.

### 3.3 HTTP response handling

`QRLoginClient.get` (`QRLogin.swift:105-121`), in order:

1. Transport error (`URLError`) → `QRLoginError.network(code: error.errorCode)` (`:114`).
2. Response is not `HTTPURLResponse` → `QRLoginError.invalidResponse` (`:115`).
3. Status outside `200..<300` → `QRLoginError.http(status:)` (`:116`).
4. Body not a JSON object, or `code` not a number → `QRLoginError.invalidResponse` (`:117-118`).
5. Top-level `code != 0` → `QRLoginError.api(code:message:)` (`:119`).

The error enum is `QRLoginError { invalidResponse, api(code:message:), incompleteCredentials,
network(code:), http(status:) }` (`QRLogin.swift:36-42`).

### 3.4 Generate and poll payloads

Generate (`QRLogin.swift:61-67`) reads `data.url` (non-empty `String`) and `data.qrcode_key`
(non-empty `String`); anything else → `invalidResponse`. It returns `(url, key)` where `url` is the
string that gets rendered as a QR image and `key` is the polling key.

Poll (`QRLogin.swift:69-84`) reads `data.code` as a number and maps:

| `data.code` | `QRLoginPoll` | Meaning | Line |
|---|---|---|---|
| `86101` | `.waitingForScan` | not scanned yet | `:78` |
| `86090` | `.scanned` | scanned, waiting for confirmation on the phone | `:79` |
| `86038` | `.expired` | QR expired | `:80` |
| `0` | `.succeeded(SessionCredentials)` | confirmed; session cookies present | `:81` |
| anything else | throws `QRLoginError.api(code:message:)` | `:82` |

Same constants as the official page (`minilogin.md:73`). `message` comes from `data.message`
(`:82`).

### 3.5 Turning the poll response into credentials

`QRLoginClient.credentials(from:response:)` (`QRLogin.swift:88-103`):

1. If the response URL and an `allHeaderFields` mapping exist, parse `Set-Cookie` through
   `HTTPCookie.cookies(withResponseHeaderFields:for:)` and record `name -> value` (`:90-94`).
2. Fallback: if `data.url` is present, parse its query items and add every item whose name is **not
   already present** (`:95-99`). This is the cross-domain URL Bilibili returns; only the names are
   harvested, never the URL itself (`SessionCoordinatorTests.swift:415-424`).
3. `refreshToken = data.refresh_token ?? ""` (`:100`).
4. Require `isComplete` (all of `SESSDATA`, `bili_jct`, `DedeUserID`, §5), else
   `QRLoginError.incompleteCredentials` (`:101-102`).

`SessionCredentials.init` then filters to `keptCookies` and drops empty values
(`QRLogin.swift:14-18`). Test vector: three `Set-Cookie` headers produce exactly
`["SESSDATA": "s1", "bili_jct": "c1", "DedeUserID": "7"]` with `refreshToken = "rt"`
(`SessionCoordinatorTests.swift:405-413`); a cross-domain URL yields `mid == 9` and does **not**
keep `gourl` (`:415-424`); a lone `SESSDATA` throws `incompleteCredentials` (`:426-432`).

### 3.6 QR image → base64 PNG

`QRImage.png(for:pixels:)` (`PlatformSupport.swift:24-43`), called as `QRImage.png(for: url)` with
the default `pixels = 480` (`CBridge.swift:112`, `PlatformSupport.swift:26`):

1. Filter `CIQRCodeGenerator` (`CoreImage`) (`:27`).
2. `inputMessage` = the QR URL's UTF-8 bytes (`:28`).
3. `inputCorrectionLevel` = `"M"` (`:29`).
4. `modules = code.extent.width + 8` — the generated image is 1 px per module, plus a four-module
   quiet zone on each side (`:31`).
5. `scale = floor(pixels / modules)` (`:32`) — integer scale factor.
6. Scale the code, then translate by `4 * scale` so the quiet zone sits around it (`:33-34`).
7. Composite over opaque white on a `modules * scale` square canvas (`:35-36`).
8. Render with a `CIContext` (hardware renderer preferred) and encode as PNG through
   `CGImageDestinationCreateWithData(..., UTType.png, ...)` (`:37-42`).

Consequences a C++ port must reproduce:

- The output is **not necessarily 480 px**: for `modules = 37` the scale is `floor(480/37) = 12` and
  the PNG is `444 × 444`. `pixels` is a target, not a size.
- Error correction level **M** and a **4-module** quiet zone are part of the spec; both macOS tests
  and the UI assume a decodable PNG (`SessionCoordinatorTests.swift:458-463`).
- Base64: `Data.base64EncodedString()` with default options, i.e. standard alphabet with padding
  (`CBridge.swift:112`).
- The UI decodes it back with `QByteArray::fromBase64` + `QPixmap::loadFromData(..., "PNG")` and
  scales to 180 × 180 keeping aspect ratio (`account-panel.cpp:151-153`).
- The same helper is reused with `pixels: 560` for the face-auth QR (`BilibiliPageWindow.swift:484`)
  — a port should keep the parameter.

### 3.7 Polling cadence, timeout, refresh budget

- `pollInterval` default: `Duration.milliseconds(1500)` (`SessionCoordinator.swift:86`).
- The loop **sleeps first, then polls** (`try await Task.sleep(for: pollInterval)` at `:369`
  precedes `api.pollQR` at `:370`). The first poll therefore happens ~1.5 s after the QR appears.
- A `.waitingForScan` result loops with no state change (`:371-372`) — no message is emitted for
  repeated "still waiting".
- QR expiry is **server-driven only**: there is no client wall-clock timeout for the QR flow.
  **NOT IN SOURCE:** any maximum total QR-login duration.
- `maxAutoRefresh` default: `2` (`SessionCoordinator.swift:86`). On each `.expired` the client
  counts up; while `refreshes < maxAutoRefresh` it abandons the poll loop and requests a **new** QR
  (`:375-378`); once the budget is exhausted it gives up with `.signedOut(.qrExpired)` (`:376`).
  With the defaults that is at most **three** QR codes (initial + two refreshes). Test with
  `maxAutoRefresh: 1`: two `generateQR` calls, final state `.signedOut(.qrExpired)`
  (`SessionCoordinatorTests.swift:134-141`).
- Both `pollInterval` and `maxAutoRefresh` are constructor parameters and must stay injectable for
  tests (`SessionCoordinator.swift:85-94`).

### 3.8 Cancellation

`cancelQRLogin()` (`SessionCoordinator.swift:116-120`):

```swift
task?.cancel()
task = nil
if case .qrCode = state { state = .signedOut(nil) }
```

- Cancellation is cooperative: the loop checks `Task.isCancelled` in both `while` conditions
  (`:365`, `:368`) and `Task.sleep` throws `CancellationError`, which the outer `catch is
  CancellationError { return }` swallows (`:387-388`).
- The final state change is conditional on the current state being `qrCode` (`:119`) — cancelling
  from `verifying` or `failed` leaves that state untouched (row 21 of §2.6).
- A throwing poll after cancellation is suppressed by `guard !Task.isCancelled else { return }`
  (`:390`).
- `QRLoginClient` has no cancel API of its own: an in-flight HTTP request is abandoned by dropping
  the task. **NOT IN SOURCE:** an explicit request abort. A Windows port should cancel the pending
  WinHTTP request explicitly; the observable requirement is only that no `.failed` is emitted and
  the state ends at `.signedOut(nil)`.
- `livehime_core_start_web_login` cancels QR login before opening the web window
  (`CBridge.swift:376`).
- `livehime_core_stop` calls `cancelQRLogin()` after dropping the callback, so this state change is
  not delivered anywhere (`CBridge.swift:164-168`).

---

## 4. Web login (official password / SMS page)

The page itself does passwords, image captcha, geetest, SMS and secondary verification; the host
only supplies the bridge the page expects and collects the resulting cookies
(`WebLoginWindow.swift:5-12`). Static evidence for the same conclusion on the Windows client:
`package.md:26`, `:43-56`, `minilogin.md:47-64`.

### 4.1 URL and window

| Item | Value | Source |
|---|---|---|
| Login page | `https://live.bilibili.com/p/html/live-pc-blink/mini-login-v2/` | `WebLoginWindow.swift:17` |
| Load policy | `URLRequest(url:cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)` | `WebLoginWindow.swift:71` |
| Window content size | `820 × 460` | `WebLoginWindow.swift:47` |
| Minimum content size | `820 × 460` | `WebLoginWindow.swift:64` |
| Window title | `哔哩哔哩登录` | `WebLoginWindow.swift:63` |
| Style | titled, closable, miniaturizable; not released on close | `WebLoginWindow.swift:48`, `:66` |
| Data store | `.nonPersistent()` — no persistent profile | `WebLoginWindow.swift:43` |
| Single instance | A second `present` re-focuses the existing window | `WebLoginWindow.swift:26-32` |

The same page URL is a literal in `bililive.dll@0x3405100` (`https://live.bilibili.com/p/html/live-pc-blink/mini-login-v2`,
shown without the trailing slash) and in the official package analysis (`package.md:62`); the
Windows host is CEF, not a native form (`package.md:26`, `bridge.md:5-19`). The page's own
initialisation parameters are `origin: 'live_pc'`, `from_app_id: 102`,
`isNeedRegisterTab: false`, `isDefaultPasswordLogin: false`, `isShowThirdLogin: false`
(`mini-login-v2.html`; `minilogin.md:17-21`).

### 4.2 Scripts injected by the host

Two scripts at document start, main frame only (`WebLoginWindow.swift:53-56`):

**(a) `window.browser` context** — `browserContextScript()` (`WebLoginWindow.swift:75-87`). The
comment says why: "The Windows host defines `window.browser` before the page loads; the page copies
it into cookies and checks it after verification" (`WebLoginWindow.swift:51-52`). The page proves
it: it reads `window.browser.appkey/buvid3/device_name/device_platform` and writes them into
`document.cookie` with `domain=.bilibili.com; path=/` (`mini-login-v2.html`).

The emitted statement (values substituted at runtime):

```js
window.browser = Object.assign({}, window.browser || {}, {"appkey":"aae92bc66f3edfab","buvid3":"<32 lowercase hex chars>","device_name":"macOS","device_platform":"mac"});
```

- `appkey` literal `aae92bc66f3edfab` (`WebLoginWindow.swift:84`) — also the appkey the official
  Windows secret DLL uses (`bridge.md:50`) and the one `startLive` signs with
  (`BilibiliLiveClient.swift:275`).
- `buvid3` is generated as `UUID().uuidString` with `-` removed and lowercased (32 hex chars), then
  persisted in `UserDefaults` under the key `livehime.buvid3` and reused ("buvid3 is kept per
  install", `WebLoginWindow.swift:74-83`).
- `device_name`/`device_platform` are the literals `macOS` / `mac` (`WebLoginWindow.swift:84`).
  The Windows values are **NOT IN SOURCE** (see §8).

**(b) `livehime_login` shim** — `AuthWebViewBridge.wkWebViewShim` (`AuthWebViewBridge.swift:33-42`),
verbatim:

```js
(() => {
  window.livehime_login = {
    LoginSuccess: data => webkit.messageHandlers.livehime_login.postMessage({method: 'LoginSuccess', data}),
    Cancel: () => webkit.messageHandlers.livehime_login.postMessage({method: 'Cancel'}),
    SecondaryValidationResult: () => webkit.messageHandlers.livehime_login.postMessage({method: 'SecondaryValidationResult'}),
    SwitchLogin: (width, height) => webkit.messageHandlers.livehime_login.postMessage({method: 'SwitchLogin', width, height})
  };
})();
```

Handler names registered on the content controller (`WebLoginWindow.swift:57-58`):

- `livehime_login` — legacy `WKScriptMessageHandler` (no reply).
- `livehime_native` — `WKScriptMessageHandlerWithReply`, registered in `contentWorld: .page` so the
  page can see it.

**(c) `biliBridgePc` shim**, injected **after every navigation finishes** via
`evaluateJavaScript` (`WebLoginWindow.swift:199-200`; "Inject after navigation finishes, preserving
the v0.1.0 render order", `AuthBridgeContract.swift:80`). `AuthWebViewBridge.nativeAuthBridgeScript`
(`AuthBridgeContract.swift:83-96`), verbatim:

```js
(() => {
  if (window.biliBridgePc) return false;
  window.biliBridgePc = {
    callNative: (action, payload) => {
      if (!['auth/setRefreshToken', 'auth/setCookies'].includes(action)) {
        return Promise.reject(new Error('unsupported_action'));
      }
      return window.webkit.messageHandlers.livehime_native.postMessage({action, payload});
    }
  };
  return true;
})();
```

`callNative` **returns a Promise** because `WKScriptMessageHandlerWithReply` supplies one; the
acknowledgement means "host handling finished, not that login is valid"
(`AuthBridgeContract.swift:81-82`).

### 4.3 What the page calls (verbatim from the page)

From `mini-login-v2.html` (official mini-login page, hashes in `minilogin.md:11`):

```js
livehime_login.LoginSuccess(data)      // the page's own 'success' listener; data is passed through unchanged
livehime_login.Cancel()                // the page's own 'cancel' listener
livehime_login.SecondaryValidationResult()  // window.onload, when document.referrer contains passport.bilibili.com
livehime_login.SwitchLogin(width, height)   // global switchLogin(width, height)
```

and, from `miniLogin.umd.min.js` (bundle hash in `minilogin.md:12`):

```js
if (d()) h("auth/setRefreshToken", e)   // loginSuccess(), when window.biliBridgePc is an object
```

```js
window.biliBridgePc.callNative("auth/setCookies", [{ name, value, expirationDate: Math.ceil(Date.now()/1e3)+ttl, isExpiredRemove: true }])
```

Host detection `d()` returns true when `window.biliBridgePc` is an object, including via
`window.top.biliBridgePc` (`d()` in `miniLogin.umd.min.js`, quoted in `bridge.md:7-19`). The
Windows-side counterpart of these names is present in `plugins/bililive_browser.exe` as a
contiguous string block: `LoginSuccess`, `Cancel`, `SwitchLogin`, `SecondaryValidationResult`,
`livehime_login`, `MiniLoginSuccess`, `MiniLoginCancel`, `MiniLoginChangeLoginMode`,
`MiniLoginSecVldResult`, `validateLogin` (offsets `0x18a2xx`–`0x18aa78`; `package.md:43-48`).

### 4.4 `livehime_login` dispatch (host side)

`WebLoginWindow.userContentController(_:didReceive:)` (`WebLoginWindow.swift:98-108`):

| Page call | Host action | Line |
|---|---|---|
| `{method:"LoginSuccess", data}` | `bridge.loginSuccess(dictionary(body["data"]))` | `:102` |
| `{method:"Cancel"}` | `bridge.cancel()` | `:103` |
| `{method:"SecondaryValidationResult"}` | `bridge.secondaryValidationResult()` | `:104` |
| `{method:"SwitchLogin", width, height}` | `bridge.switchLogin(width: body["width"] as? Double ?? 0, height: … ?? 0)` | `:105` |
| anything else | ignored | `:106` |

The handler returns early unless the message comes from this web view, from an allowed origin
(§4.6), is named `livehime_login`, and carries a `method` string (`:99-100`).

The `data` payload may be an object **or** a JSON string; `dictionary(_:)` accepts both and returns
`[:]` otherwise (`WebLoginWindow.swift:137-143`; test `SessionCoordinatorTests.swift:213-217`).

`LoginResult` field mapping (`AuthWebViewBridge.swift:51-61`):

| Field | Source key(s) |
|---|---|
| `type` | `payload["type"]` |
| `refreshToken` | `payload["refresh_token"]` ?? `payload["refreshToken"]` ?? `payload["token"]` |
| `timestamp` | `String(describing: payload["timestamp"])` |
| `url` | `payload["url"]` parsed as a URL |

Events emitted (`AuthWebViewBridge.swift:3-8`, `:63-74`): `succeeded(LoginResult)`, `cancelled`,
`secondaryValidationReturned`, `resize(width:height:)`. `switchLogin` silently drops non-finite or
non-positive sizes (`:72`); a valid resize is clamped to `max(820, min(width, 1200)) × max(460, min(height, 900))`
(`WebLoginWindow.swift:160`).

### 4.5 `biliBridgePc.callNative` dispatch (host side)

`NativeAuthRequest.parse(action:payload:)` (`AuthBridgeContract.swift:18-37`):

| Action literal | Accepted payload | Result |
|---|---|---|
| `auth/setRefreshToken` | object, or a JSON **string** that decodes to a non-empty object | `.login(object)` → `bridge.loginSuccess(object)` |
| `auth/setCookies` | array of cookie descriptors | `.cookies(batch)` |
| anything else | — | throws `unsupported_action` |

Error literals returned to the page as the reply's error string (`AuthBridgeContract.swift:12-16`,
`:113`, `:130-134`):

```text
malformed_payload
unsupported_action
untrusted_origin
```

Success reply is the object `{"accepted": true}` (`WebLoginWindow.swift:120`, `:127`).

Cookie batch validation — the **whole batch is validated before anything is written**
(`AuthBridgeContract.swift:39-40`):

- payload must be an array of at most **128** items (`:49-51`);
- each item needs non-empty `name` (`≤ 256` UTF-8 bytes) and `value` (`≤ 16384` UTF-8 bytes)
  (`:53-54`);
- neither name nor value may contain control characters, and the name may not contain `;` or `=`
  (`:55-57`);
- domain is forced to `.bilibili.com`, path to `/`, `secure` TRUE (`:60-63`);
- optional `expirationDate` (seconds since epoch, finite) becomes the expiry; `remove` is true only
  when the expiry is `<= now` **and** `isExpiredRemove == true` (`:65-70`);
- any failure throws `malformed_payload` (`:58`, `:66`, `:71`).

Application: sequentially on the web view's cookie store — `deleteCookie` when `remove`, else
`setCookie` — and only then the `{"accepted": true}` reply (`WebLoginWindow.swift:121-128`). Note
the reply is sent after all writes complete, not per cookie.

### 4.6 Origin policy (security invariant)

```swift
isMainFrame && scheme.lowercased() == "https" &&
    host.lowercased() == "live.bilibili.com" && (port == 0 || port == 443)
```

`AuthBridgeContract.swift:6-9`, with the rationale "Privileged login callbacks are accepted only
from our top-level official page. The face-auth window has no native login handler; its origin
cannot inherit one" (`:3-4`). Combined with `message.webView === webView`
(`WebLoginWindow.swift:93-95`), this means: **privileged messages are accepted only from the main
frame of our own web view while it is on `https://live.bilibili.com[:443]`.** A navigation to
`passport.bilibili.com` (secondary verification) silences the bridge by design; the page returns to
`live.bilibili.com` and then reports `SecondaryValidationResult()` from its `window.onload`
referrer check (`mini-login-v2.html`).

### 4.7 Cookie read-back after success

`collectCookies(attempt:attempts:)` (`WebLoginWindow.swift:178-195`):

1. Bail out if already completed (`:179`).
2. `httpCookieStore.getAllCookies` (`:180`).
3. Keep every cookie whose `domain.hasSuffix("bilibili.com")`, keyed by name (`:182-183`).
4. Build `SessionCredentials(cookies: jar, refreshToken: self.refreshToken)` — which applies the
   `keptCookies` filter and the completeness check (`:184`).
5. If complete: set `completed = true`, call `onComplete(credentials)`, close the window
   (`:186-188`).
6. Otherwise retry every **0.3 s** up to **20 attempts** total (~6 s), then give up silently
   (`:189-192`).

Call sites: on `.succeeded` (`:152`), on `.secondaryValidationReturned` ("the page redirects back
after verification; the cookie jar is already authenticated at this point", `:153-156`), and after
**every** finished navigation with `attempts: 1` (`:199-206`) — this covers third-party
(QQ/WeChat/Weibo) logins and verification steps that return already signed in without calling
`LoginSuccess` (`:201-205`).

`refreshToken` is remembered from the success payload (`:148-150`). If it is present **and** a
`timestamp` was supplied, `seedCookies` runs first (`:150`).

### 4.8 `seedCookies` — asking Bilibili to set the cookies

`WebLoginWindow.swift:166-174` ("The page hands back a refresh token; loading correspond/0 with
this digest asks Bilibili to set the matching cookies (v0.1.2 behaviour)", `:164-165`):

1. `marker = "set_<timestamp>_<token>"` (`:167`).
2. `hex` = every Unicode scalar of `marker` rendered as lowercase base-16 with no padding,
   concatenated (`:168`).
3. `digest` = lowercase hex of `SHA256(hex as UTF-8)` (`:169`).
4. Build the URL `https://www.bilibili.com/correspond/0/<digest>` (`:170`).
5. Create a hidden iframe with that `src`, append it to `document.body`, via
   `evaluateJavaScript` (`:171-173`).

Note the double encoding: the **hex text**, not the marker bytes, is hashed. A C++ port must
replicate this exactly (`BCrypt`/`CryptHashData` over the ASCII hex string).

### 4.9 Completion

`onComplete` is the closure from `livehime_core_start_web_login`:
`WebLoginWindow.present { credentials in CoreBridge.shared?.coordinator.completeWebLogin(credentials) }`
(`CBridge.swift:377-379`). `completeWebLogin` saves then verifies (§2.6 rows 22-23), so the rest of
the flow is identical to a QR login. The window then closes (`WebLoginWindow.swift:188`), and
`windowWillClose` stops loading and clears the cached instance (`:236-239`).

Other web-view behaviours to keep:

- New-window requests (`_blank`: "forgot password", the user agreement, the privacy policy) are
  opened in the **system browser**, not in the login window (`WebLoginWindow.swift:210-218`).
- JS `alert`/`confirm` panels are shown as sheets; confirm buttons are `确定` / `取消`
  (`WebLoginWindow.swift:220-234`).

---

## 5. Credential storage

### 5.1 What is persisted

One Keychain generic-password item holding a JSON **envelope** (`CredentialStore.swift:24-29`):

```swift
struct CredentialEnvelope: Codable {
    static let currentVersion = 2
    var schemaVersion: Int
    var credentials: SessionCredentials
}
```

JSON keys on the wire: `schemaVersion` and `credentials`; `credentials` in turn is
`SessionCredentials` (`Codable`, `QRLogin.swift:6`) with keys `cookies`, `refreshToken`, `savedAt`
(`QRLogin.swift:10-12`). `savedAt` is a `Date`, which `JSONEncoder` writes as a number (seconds
since 2001-01-01) by default. **NOT IN SOURCE:** an explicit `dateEncodingStrategy`.

The Keychain item identity (`CredentialStore.swift:55-69`):

```text
kSecClass        = kSecClassGenericPassword
kSecAttrService  = "local.livehime.macos.session"   (default, overridable)
kSecAttrAccount  = "default"                        (default, overridable)
```

with `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` set **only on insert**
(`:92`).

`SessionCredentials` content rules (`QRLogin.swift:6-27`):

```swift
public static let requiredCookies = ["SESSDATA", "bili_jct", "DedeUserID"]
static let keptCookies: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid", "buvid3"]
```

- Cookies outside `keptCookies`, and cookies with empty values, are dropped at construction
  (`:15`).
- `isComplete` = all three `requiredCookies` present (`:20`).
- `mid` = `DedeUserID` parsed as `Int64` (`:21`).
- `csrf` = `bili_jct` (`:22`).
- `cookieHeader` = cookies sorted by name, `name=value`, joined with `"; "` (`:24-26`).
  Test vector: `DedeUserID=42; SESSDATA=s; bili_jct=csrf`
  (`SessionCoordinatorTests.swift:131`).

### 5.2 When it is written, read, removed

| Operation | Trigger | Source |
|---|---|---|
| `save` | QR login succeeded | `SessionCoordinator.swift:380` |
| `save` | web login returned credentials | `:110` |
| `save` | legacy v0.1.2 session migrated | `:355` |
| `save` | session maintenance renewed the login (**before** confirming) | `:172` |
| `load` | `restore()` on core start | `:341` |
| `load` | `retry()` | `:126` |
| `load` | `signOut()` fallback, to find the credentials to revoke server-side | `:140` |
| `remove` | `signOut()` | `:143` |
| `remove` | verification answered "not logged in" | `:408` |
| `remove` | any live-room call answered "not logged in" | `:321` |

`save` does `SecItemUpdate`, and on `errSecItemNotFound` does `SecItemAdd` with the accessibility
attribute (`CredentialStore.swift:83-98`). `remove` accepts `errSecSuccess` or `errSecItemNotFound`
(`:100-105`). `load` treats `errSecItemNotFound` as `.none` (`:77`) and any other non-success as a
thrown `CredentialStoreError.keychain(OSStatus)` (`:78`), which the coordinator surfaces as the
`keychain` notice (`SessionCoordinator.swift:342`).

### 5.3 Legacy (v0.1.2) migration

`StoredCredentials` = `.none` | `.current(SessionCredentials)` |
`.legacy(refreshToken: String?, sessdata: String?)` (`CredentialStore.swift:7-11`).

Decoding precedence (`CredentialStore.swift:37-51`):

1. A `CredentialEnvelope` with `schemaVersion == 2` → `.current` (`:39-42`).
2. Otherwise a `LegacyStoredLoginSession { type: String?, refreshToken: String }` (`:32-35`) with a
   non-empty `refreshToken` → `type == "cookie"` yields
   `.legacy(refreshToken: nil, sessdata: token)` (v0.1.2 stored the SESSDATA cookie in
   `refreshToken` for type `"cookie"`), anything else yields
   `.legacy(refreshToken: token, sessdata: nil)` (`:43-47`).
3. Unknown data → `.none`, deliberately: "Unknown data is treated as signed out rather than as a
   crash or a silent partial session" (`:48-50`).

Migration flow (`SessionCoordinator.swift:349-357`): emit `.verifying`, import cookies from the old
WebKit store (`LegacySessionImporter`, `:59-61`; implementation `WebKitLegacyImporter`,
`PlatformSupport.swift:10-22`, which reads
`WKWebsiteDataStore.default().httpCookieStore.allCookies()` and keeps domains ending
`bilibili.com`), build `SessionCredentials(cookies: imported, refreshToken: refreshToken ?? "")`
(`:352`), check cancellation (`:353`), then either `.signedOut(.legacyNeedsLogin)` when incomplete
(`:354`) or save and verify (`:355-357`). The importer's premise is that "the store belongs to the
bundle identifier, so an upgraded app with the same identifier sees the previous login"
(`PlatformSupport.swift:7-9`).

### 5.4 What sign-out clears

`signOut()` (`SessionCoordinator.swift:134-154`), in order:

1. Cancel the action task and the maintenance task (`:136-138`).
2. Resolve the credentials to revoke: the in-memory ones, else a fresh `store.load()` (`:139-140`).
3. `credentials = nil` (`:141`).
4. `store.remove()` — deletes the single Keychain item; success → `.signedOut(nil)` (`:143-144`),
   failure → `.failed(.keychain, detail:)` (`:145-147`).
5. Best-effort server logout in a detached task: `api.logout(previous)` with errors ignored
   (`:148-153`), i.e. `POST https://passport.bilibili.com/login/exit/v2` with form
   `biliCSRF=<csrf>` (§6.6).

Not cleared by sign-out: the `buvid3` device identifier in `UserDefaults`
(`WebLoginWindow.swift:74-83`). The web-login page's own data needs no clearing because the store
is non-persistent (`WebLoginWindow.swift:43`).

### 5.5 Keychain-only concepts (no Windows equivalent)

| Concept | Source | Windows status |
|---|---|---|
| `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | `CredentialStore.swift:92` | No equivalent. "After first unlock" and "ThisDeviceOnly" (never synced/backed up) have no Credential Manager counterpart. |
| Per-application ACL enforced by code signature | implicit in the Keychain design; the store is addressed by service+account only (`CredentialStore.swift:65-69`) | No equivalent. Any process running as the user can `CredRead` the same target. |
| `service` scoping tied to a bundle identifier | `PlatformSupport.swift:7-9` (the legacy import relies on it) | No equivalent; the Windows client's own store is a private file/database, not a per-bundle credential (§8). |
| `Security` framework `OSStatus` error surface | `CredentialStore.swift:19-22`, `:78` | Replaced by Win32 error codes; only the observable `keychain` notice string is contractual (`SessionCoordinator.swift:17`, `account-panel.cpp:146`). |
| `SecKey` RSA public key + `SecKeyCreateEncryptedData` | `SessionMaintenance.swift:32-56` | CNG/BCrypt equivalent exists (§7), but not via the same API shape. |

---

## 6. Session maintenance

Purpose, quoted: "Keeps a web login alive and ends it on the server" (`SessionMaintenance.swift:4`).
Renewal follows Bilibili's web flow, documented in the header comment
(`SessionMaintenance.swift:6-12`): `cookie/info` says whether a refresh is due;
`refresh_<timestamp ms>` is RSA-OAEP(SHA-256) encrypted under the public key the main site ships in
`wasm_rsa_encrypt_bg.wasm`; the `correspond/1/<hex>` page reveals `refresh_csrf`; `cookie/refresh`
issues new cookies and a new refresh token; `confirm/refresh` retires the old token.

### 6.1 Cadence and triggers

- `maintenanceInterval` default: `Duration.seconds(12 * 3600)` = **43 200 s = 12 h**
  (`SessionCoordinator.swift:87`); injectable for tests (`SessionCoordinatorTests.swift:341`).
- Started **only** on reaching `.ready`, inside `verify` (`SessionCoordinator.swift:404`).
- `startMaintenance()` cancels any previous maintenance task and starts a new one
  (`SessionCoordinator.swift:187-196`). The loop body is:

  ```swift
  while !Task.isCancelled {
      await self?.maintainSession()
      guard let interval = self?.maintenanceInterval else { return }
      try? await Task.sleep(for: interval)
  }
  ```

  → **the first maintenance check runs immediately when the session becomes ready**, then every
  12 h (`SessionCoordinator.swift:190-194`).
- Triggers for a re-check, exhaustively: (a) entering `ready`; (b) each 12 h tick; (c) an explicit
  `maintainSession()` call (`:159`). **NOT IN SOURCE:** a re-check triggered by a failing request —
  a `-101` from a room call goes to `guarded`, not to maintenance (`:316-327`).
- Cancelled only by `signOut()` (`:137-138`) and by the next `startMaintenance()` (`:188`).
  A QR or web login while already `ready` does not cancel it, but `maintainSession`'s guard makes
  it a no-op.
- Single-flight: `guard !maintaining else { return }` with a `defer` reset (`:162-166`), because
  "a second run would present an already retired refresh token" (`:162-163`).
- Skipped while live: `guard account.room.liveStatus != 1 else { onMaintenance?("skippedWhileLive"); return }`
  — "Skipped while the room is live so cookies never change mid-stream" (`:156-157`, `:161`).
- Skipped when not ready or when `credentials == nil` (`:160`).

### 6.2 Result strings

`onMaintenance` receives one of these strings (`SessionCoordinator.swift:69-71`, `:159-185`) and
`CBridge` forwards them as `{"event":"sessionMaintenance","result":"<value>"}`
(`CBridge.swift:27`). "Never carries secrets" (`SessionCoordinator.swift:71-72`).

| Literal | Meaning | Line |
|---|---|---|
| `notNeeded` | Bilibili says no refresh is due | `:169` |
| `skippedWhileLive` | room is live (`liveStatus == 1`) | `:161` |
| `refreshed` | renewed **and** the old token was retired | `:176` |
| `refreshed:confirmFailed` | renewed and saved, but `confirm/refresh` failed | `:178` |
| `failed:<step>` | a refresh step threw `SessionRefreshError.step(step)` | `:181` |
| `failed:<ErrorType>` | any other error (Swift type name) | `:183` |

`<step>` values used by `SessionMaintenance` (`SessionMaintenance.swift:13-16` and the `step:`
arguments below): `cookieInfo` (`:72`), `noRefreshToken` (`:76`), `encrypt` (`:78`),
`correspond` (`:150`), `refreshCSRF` (`:80`), `cookieRefresh` (`:87`), `cookieRefreshResult`
(`:95`), `confirmRefresh` (`:105`), `logout` (`:113`). `missingCSRF` is a separate error case
(`:14`, thrown at `:69`, `:102`, `:111`) and would surface as `failed:missingCSRF` under the generic
branch (`:182-183`).

### 6.3 Refresh flow, step by step

`refreshIfNeeded(_:)` (`SessionMaintenance.swift:68-98`) returns `nil` when no refresh is due:

1. Require `csrf` (= `bili_jct`), else throw `missingCSRF` (`:69`).
2. `GET https://passport.bilibili.com/x/passport-login/web/cookie/info?csrf=<csrf>` with the
   current cookie header; step name `cookieInfo` (`:70-72`).
3. If `data.refresh != true` → return `nil` (`:74`).
4. `timestamp` = `data.timestamp` (Int64 ms) or, when absent, now in ms (`:75`).
5. Require a non-empty stored `refreshToken`, else step `noRefreshToken` (`:76`).
6. `correspondPath(timestamp)` = RSA-OAEP(SHA-256)-encrypt the ASCII string `refresh_<timestampMs>`
   under the embedded public key and hex-encode the ciphertext (lowercase, 2 digits per byte);
   `nil` → step `encrypt` (`:49-56`, `:78`).
7. `GET https://www.bilibili.com/correspond/1/<hex>` with the current cookie header → HTML
   (`:79`); a non-2xx or transport failure throws step `correspond` (`:147-153`).
8. Extract `refresh_csrf` from the HTML with the regex
   `<div id="1-name">([^<]+)</div>` (`:58-63`); missing → step `refreshCSRF` (`:80`). Test vector:
   `<html><div id="1-name">abc123</div></html>` → `abc123`; `<html></html>` → `nil`
   (`SessionCoordinatorTests.swift:395-401`).
9. `POST https://passport.bilibili.com/x/passport-login/web/cookie/refresh`, form fields in this
   order: `csrf`, `refresh_csrf`, `source=main_web`, `refresh_token` (`:82-87`); step
   `cookieRefresh`.
10. Overlay every `Set-Cookie` from the response onto the current cookie map (`:88-91`); read the
    new token from `data.refresh_token` (`:92`).
11. Accept only when the new credentials are complete, the new token is non-empty, **and** the new
    `SESSDATA` differs from the old one (`:93-96`); otherwise step `cookieRefreshResult`.

The RSA key is hard-coded: modulus hex at `SessionMaintenance.swift:21` (1024-bit, exponent 65537,
`:19-20`, `:41`), assembled into PKCS#1 `RSAPublicKey` DER as `SEQUENCE { INTEGER n, INTEGER 65537 }`
with a leading `0x00` sign pad on the modulus (`:31-47`). Test vector: the ciphertext hex is 256
characters and differs between calls (OAEP is randomized)
(`SessionCoordinatorTests.swift:395-398`).

`correspondPath` returns **lowercase** hex (`String(format: "%02x", $0)`, `:55`).

### 6.4 Save-then-confirm ordering

`maintainSession()` (`SessionCoordinator.swift:167-179`):

```swift
try store.save(renewed)
credentials = renewed
do { try await api.confirmRefresh(renewed: renewed, previousRefreshToken: current.refreshToken)
     onMaintenance?("refreshed") }
catch { onMaintenance?("refreshed:confirmFailed") }
```

The renewed login is persisted (and installed in memory) **before** the old refresh token is
retired (`:156-158` comment, `:172-175`). A confirmation failure is reported but is not rolled
back. A failure anywhere earlier leaves both the stored and the in-memory login untouched — asserted
by `SessionCoordinatorTests.swift:362-373` (`failed:refreshCSRF`, store still `.current(original)`,
state still `.ready`).

`confirm` (`SessionMaintenance.swift:101-106`): require `csrf` of the **renewed** credentials, then
`POST https://passport.bilibili.com/x/passport-login/web/confirm/refresh` with form `csrf` and
`refresh_token=<previous>`, step `confirmRefresh`.

### 6.5 Expiry behaviour

Maintenance itself never signs the user out and never changes the session state (§2.6 row 30). An
expired login is discovered by the next call that talks to Bilibili with the stored cookies:

- `verify` (on restore, retry, or after a login): `-101` or `isLogin == false` → remove the stored
  login, drop `credentials`, `.signedOut(.sessionExpired)` (`SessionCoordinator.swift:407-410`).
- any live-room call through `guarded`: same three effects, then the error is rethrown to the caller
  (`:316-327`; test `SessionCoordinatorTests.swift:277-283`).

`logout(_:)` (`SessionMaintenance.swift:110-114`): require `csrf`, then
`POST https://passport.bilibili.com/login/exit/v2` with form `biliCSRF=<csrf>`, step `logout`
("the same request the web header's \"log out\" makes", `:108-109`).

### 6.6 HTTP conventions shared by maintenance

`request(_:cookies:)` (`SessionMaintenance.swift:118-125`): timeout **12 s**, header
`Cookie: <cookieHeader>`, `User-Agent: <BilibiliWeb.userAgent>` (the same macOS Safari literal as
§3.1, `QRLogin.swift:134`), `Referer: https://www.bilibili.com/`.

`send(_:cookies:form:step:)` (`SessionMaintenance.swift:127-145`): POST bodies are
`application/x-www-form-urlencoded`, with `+`, `&`, `=` removed from the allowed percent-encoding
set (`:131-136`). Success requires a 2xx status **and** a JSON object with `code == 0`; otherwise
the generic step error is thrown (`:138-142`).

---

## 7. Windows mapping table

Conventions: "already in tree" means the dependency or linker input is present in this repository
today. Nothing below has been executed on Windows (`WINDOWS_PORT.md:1-5`).

### 7.1 Core plumbing

| # | Concern | macOS (source) | Windows mechanism | Fidelity notes |
|---|---|---|---|---|
| 1 | Session state machine, emits JSON through one C callback | Swift enums + `@MainActor` (`SessionCoordinator.swift:26-32`, `:65-67`) | Plain C++ behind the same ABI (`livehime-core.h:14-26`); the Windows stub is the file to replace function-by-function (`WINDOWS_PORT.md:51`) | Callbacks must be delivered on the Qt main thread and must be re-entrancy-safe: the UI's handler runs synchronously (`account-panel.cpp:124-137`) |
| 2 | JSON encoding with sorted keys | `JSONSerialization(..., [.sortedKeys])` (`CBridge.swift:129`, `:189`) | `deps/json11` is already vendored (`deps/json11/json11.hpp`); it does **not** sort keys, so emit the fixed key order of §2.3 explicitly | Only JSON validity is load-bearing (`account-panel.cpp:129`), but a stable byte order keeps log diffs and tests comparable |
| 3 | HTTP client with no shared cookie jar | `URLSessionConfiguration.ephemeral`, cookies disabled (`QRLogin.swift:126-133`) | **WinHTTP** (the official Windows client already imports `WINHTTP.dll`, `package.md:88`) or Qt Network; cookies must be handled manually from headers exactly as §3.5 | The port must **not** use a cookie jar; cookies are core-owned state |
| 4 | TLS/UA | Safari UA literal in three files (`QRLogin.swift:134`, `BilibiliControlClient.swift:47`, `BilibiliLiveClient.swift:399`) | Substitute a Chrome/Edge UA for WinHTTP and WebView2 | **Decision required.** The source comment explains why the UA matters: a bespoke UA is more likely to be treated as an unsupported client by `nav` after a risk-control login (`BilibiliControlClient.swift:44-47`). One UA constant must be shared by the HTTP client and the WebView2 page host; the Windows-correct value is **NOT IN SOURCE** |
| 5 | SHA-256 (`correspond/0` digest) | `CryptoKit.SHA256` (`WebLoginWindow.swift:169`) | `crypt32` (already linked: `CMakeLists.txt:150-152`) or BCrypt | Replicate the double encoding exactly: Unicode scalars → lowercase hex → SHA-256 of the **ASCII hex**, then lowercase hex (`WebLoginWindow.swift:167-169`) |
| 6 | RSA-OAEP-SHA256 (`correspond/1/<hex>`) | `SecKeyCreateWithData` + `SecKeyCreateEncryptedData(.rsaEncryptionOAEPSHA256)` (`SessionMaintenance.swift:32-56`) | CNG/BCrypt: build `BCRYPT_RSAPUBLIC_BLOB` from the modulus hex (`SessionMaintenance.swift:21`) + public exponent `65537`, then `BCryptEncrypt` with `BCRYPT_PAD_OAEP` and SHA-256 | OAEP parameters (hash, MGF1 hash, label) are not recoverable from the Swift call; the Swift API pins hash = MGF1 hash = SHA-256 and an empty label. **Must be verified against a real `correspond/1` request** |
| 7 | Threading/lifecycle | `livehime_core_stop` clears the callback first, then tears down (`CBridge.swift:161-170`) | Same order; the Qt panel calls `livehime_core_stop()` from its destructor (`account-panel.cpp:104`) | No state message may be emitted after `stop` (callback is already `NULL`) |

### 7.2 QR login

| # | Concern | macOS (source) | Windows mechanism | Fidelity notes |
|---|---|---|---|---|
| 8 | QR PNG rendering | CoreImage `CIQRCodeGenerator`, level M, 480 px target, 4-module quiet zone (`PlatformSupport.swift:24-43`) | Vendor **qrcodegen** (Nayuki, MIT) or use `libqrcodegencpp`; a finder already exists in this tree (`cmake/finders/Findqrcodegencpp.cmake:1-8`) and Ubuntu CI installs it (`.github/scripts/utils.zsh/setup_ubuntu:91`) | Reproduce the geometry of §3.6 exactly (level M, quiet zone 4, `scale = floor(target/modules)`, white background). Encode PNG with WIC or GDI+ (`WINDOWS_PORT.md:106` lists the ImageIO/CoreImage row) |
| 9 | QR polling timer | `Task.sleep(for: 1500 ms)` before each poll (`SessionCoordinator.swift:369`) | Any monotonic timer (Win32 waitable timer / asio / Qt) with the same sleep-then-poll order | First poll ~1.5 s after the QR appears; no client-side QR timeout (§3.7) |
| 10 | Cancellation | Cooperative task cancellation (`SessionCoordinator.swift:116-120`, `:387-388`) | Cancel the pending WinHTTP request and the timer; emit no `.failed` | The observable contract is only the final state (§3.8) |

### 7.3 Web login host

| # | Concern | macOS (source) | Windows mechanism | Fidelity notes |
|---|---|---|---|---|
| 11 | Page host | `WKWebView` with `.nonPersistent()` store (`WebLoginWindow.swift:43`) | **WebView2** with a dedicated user-data folder under `%TEMP%`, deleted on close (optionally `ICoreWebView2ControllerOptions::IsInPrivateModeEnabled`) | The official Windows client hosts this page in CEF (`WebLoginWindow.swift:5-6`, `package.md:26`, `:89`); CEF remains the higher-fidelity option because it is what the page is tested against upstream, at the cost of a ~172 MiB runtime (`package.md:27`). Choose one and record it |
| 12 | Document-start injection | `WKUserScript(injectionTime: .atDocumentStart, forMainFrameOnly: true)` ×2 (`WebLoginWindow.swift:53-56`) | `ICoreWebView2::AddScriptToExecuteOnDocumentCreated` for the `livehime_login` shim and the `window.browser` script | **Gap:** WebView2's document-created script runs in **all** frames; there is no main-frame-only flag. Mitigate by starting the shim with `if (window.top !== window) return false;` and by keeping the host-side origin check (§7.4) |
| 13 | Post-navigation injection | `evaluateJavaScript(nativeAuthBridgeScript)` in `didFinish` (`WebLoginWindow.swift:199-200`) | `ICoreWebView2::ExecuteScript` in `add_NavigationCompleted` | Same order: navigation completes → inject `window.biliBridgePc` → probe cookies (§4.7). The shim is idempotent (`if (window.biliBridgePc) return false;`) |
| 14 | Page→host messages without reply | `WKScriptMessageHandler` named `livehime_login` (`WebLoginWindow.swift:57`, `:98-108`) | `window.chrome.webview.postMessage` + `add_WebMessageReceived`; shim maps the same four method names | Message bodies must keep the exact keys `method`, `data`, `width`, `height` (§4.4) |
| 15 | Page→host messages **with reply** | `WKScriptMessageHandlerWithReply` named `livehime_native`, in the page content world (`WebLoginWindow.swift:58`, `:110-135`) | `PostWebMessageAsJson` reply correlated by id; the shim must synthesize a Promise and resolve/reject it | **Genuine gap:** WebView2 has no with-reply handler. The page's `callNative` **must** return a Promise resolving to `{accepted:true}` or rejecting with `malformed_payload` / `unsupported_action` / `untrusted_origin` (`AuthBridgeContract.swift:12-16`, `WebLoginWindow.swift:120`, `:127`, `:131-134`) |
| 16 | Privileged-callback origin gate | main frame + `https` + host `live.bilibili.com` + port 0/443 (`AuthBridgeContract.swift:6-9`), plus `message.webView === webView` (`WebLoginWindow.swift:93`) | Compare `ICoreWebView2WebMessageReceivedEventArgs::get_Source` against the allowed origin, and additionally require the sender to be the top-level document | **Genuine gap:** the per-message main-frame flag is not exposed. Enforce it in the shim (`window.top === window`) *and* keep the host-side origin check; never accept privileged actions from a non-`live.bilibili.com` origin (this is what keeps `passport.bilibili.com` and the iframe-borne flows unprivileged, §4.6) |
| 17 | Cookie write/delete | `WKHTTPCookieStore.setCookie` / `deleteCookie` (`WebLoginWindow.swift:121-128`) | `ICoreWebView2CookieManager::AddOrUpdateCookie` / `DeleteCookie`; create with domain `.bilibili.com`, path `/`, `IsSecure = TRUE` | Deletion matches on name+domain+path; construct the cookie to delete from the validated batch, never from a raw string (`AuthBridgeContract.swift:60-63`) |
| 18 | Cookie read-back | `getAllCookies`, filter `domain.hasSuffix("bilibili.com")`, ≤20 attempts × 0.3 s (`WebLoginWindow.swift:178-195`) | `ICoreWebView2CookieManager::GetCookies(nullptr, ...)` with the same filter and the same poll budget | Keep the `completed` single-shot guard and both call sites (success payload, secondary-validation return) plus the per-navigation probe (`WebLoginWindow.swift:152-156`, `:199-206`) |
| 19 | `correspond/0` seeding | hidden iframe via `evaluateJavaScript` (`WebLoginWindow.swift:166-174`) | `ExecuteScript` with the same snippet | Reuse the SHA-256 rule of §4.8 |
| 20 | New-window / dialog handling | system browser for `http(s)` popups; sheets for `alert`/`confirm` (`WebLoginWindow.swift:210-234`) | `add_NewWindowRequested` (open in the default browser, cancel the WebView2 window) and `add_ScriptDialogOpening` | Confirm buttons are `确定` / `取消` (`WebLoginWindow.swift:231-232`) |
| 21 | Window sizing | 820×460, resize clamped to 820–1200 × 460–900 (`WebLoginWindow.swift:47`, `:160`) | WebView2 controller `Bounds` on an owner HWND; same clamps | The page drives resizing through `SwitchLogin` (`mini-login-v2.html`) |

### 7.4 Credentials

| # | Concern | macOS (source) | Windows mechanism | Fidelity notes |
|---|---|---|---|---|
| 22 | Credential store | One Keychain generic-password item, service `local.livehime.macos.session`, account `default` (`CredentialStore.swift:56-69`) | **Credential Manager**: `CredWrite`/`CredRead`/`CredDelete` with `CRED_TYPE_GENERIC`, a `TargetName` (e.g. `local.livehime.windows.session`), `CRED_PERSIST_LOCAL_MACHINE`; `advapi32` must be added to the link line (currently only `user32 dwmapi version crypt32`, `CMakeLists.txt:152`) | Keep the `LIVEHIME_KEYCHAIN_SERVICE` environment override (`account-panel.cpp:97`) as the `TargetName` override |
| 23 | Blob size | Unbounded in source; each cookie value is capped at 16 384 bytes by the bridge validator (`AuthBridgeContract.swift:54`) | `CRED_MAX_CREDENTIAL_BLOB_SIZE` = 2560 bytes | **Risk.** A realistic envelope (SESSDATA ~200–600 chars + 5 small cookies + refresh token + `savedAt`) fits, but nothing in the source bounds `SESSDATA`. Either enforce a size check with a defined fallback, or store the envelope as a DPAPI-protected file (`CryptProtectData`, per-user) and keep only a marker in Credential Manager |
| 24 | Accessibility class | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on insert (`CredentialStore.swift:92`) | None | **Cannot be mapped.** Document the loss: the blob becomes readable to any process of the same user, and Windows credentials may roam with a roaming profile — there is no `ThisDeviceOnly` guarantee |
| 25 | Legacy migration | Read the previous app's WebKit cookie store (`PlatformSupport.swift:10-22`), decode v0.1.2's `{"type","refreshToken"}` (`CredentialStore.swift:32-51`) | **NOT IN SOURCE.** The old Windows client's persisted keys are known (`mid`, `account`, `auto_login`, `mini_login`, `token`, `refresh_token`, `expires`, `cookies`, `domains`, `device_id`, `device_flag`, `csrf` at `bililive_secret.dll@0x10d35a8`–`0x10d35f8`), but the physical store (CEF `Cookies` SQLite vs. an own file) and its encryption are not | Recommendation: implement `.none` for legacy on Windows, i.e. keep §2.6 row 3 behaviour, unless the old store is identified. A wrong guess here risks reading another app's private data |
| 26 | Sign-out | Delete the item + best-effort `POST /login/exit/v2` (`SessionCoordinator.swift:143`, `:148-153`) | `CredDelete` (treat "not found" as success, `CredentialStore.swift:100-105`) + the same POST | Also delete the WebView2 user-data folder if the profile is persistent; with the temp-folder design it is removed with the folder |
| 27 | `buvid3` persistence | `UserDefaults` key `livehime.buvid3` (`WebLoginWindow.swift:76-83`) | Registry (`HKCU\Software\LiveHime`) or an ini under `%APPDATA%\LiveHime`; keep the env override pattern | Must be per-install stable and **not** cleared on sign-out |
| 28 | `device_name` / `device_platform` | Literals `macOS` / `mac` (`WebLoginWindow.swift:84`) | Windows equivalents | **NOT IN SOURCE.** The official client's values must be observed (the page writes them into cookies and "checks it after verification", `WebLoginWindow.swift:51-52`) |

### 7.5 Things that genuinely cannot be mapped

1. **Keychain per-application access control.** Any same-user process can read a Credential Manager
   blob (§7.4 rows 23-24). If that matters, wrap the envelope with DPAPI plus an application
   entropy secret, accepting that the secret is in the binary.
2. **`WKScriptMessageHandlerWithReply`.** No WebView2 equivalent; the Promise semantics of
   `biliBridgePc.callNative` must be emulated (§7.3 row 15). If the page ever relies on the promise
   resolving *after* cookie writes, the emulation must reply after the writes, exactly as
   `WebLoginWindow.swift:121-128` does.
3. **`message.frameInfo.isMainFrame`.** Not exposed per web message; enforcement must move into the
   injected shim plus the origin check (§7.3 row 16).
4. **Non-persistent web data store with per-window isolation.** `.nonPersistent()`
   (`WebLoginWindow.swift:43`) has no exact WebView2 counterpart in every SDK version; a disposable
   user-data folder is the robust equivalent. **NOT IN SOURCE:** any claim about what WebView2
   InPrivate leaves on disk.
5. **Bundle-identifier-scoped legacy cookie store.** The migration premise
   (`PlatformSupport.swift:7-9`) does not exist on Windows (§7.4 row 25).
6. **`URLError.cancelled` special case.** `notice(for:)` maps every `URLError` *except* `.cancelled`
   to `network` (`SessionCoordinator.swift:430-431`). WinHTTP reports cancellation as
   `ERROR_WINHTTP_OPERATION_CANCELLED`; the port must special-case it or a cancelled QR login will
   surface a spurious `failed` notice.
7. **The UA literal.** §7.1 row 4.

---

## 8. Order of operations after a successful web login

### 8.1 The official Windows client (static evidence)

The ordering below is read from contiguous string blocks, not from executed code. All offsets are
file offsets in `…/extracted/app/bililive.dll`; the analysis that produced them is `bridge.md:35-51`
and `package.md:161-173`.

| Step | Evidence | Offset |
|---|---|---|
| 1. Cookies are written into the web view | `SetTokenCookies`, `SetMiniLoginCookies`; nearby: `cef proxy post set_cookie successed. `, `cef proxy try set cookie when cef loading.` | `0x3362c83`, `0x3362d48`, `0x3362c40`-`0x3362d90` |
| 2. Auth check reports success | `[login] login auth check success, ` + `, will check auth validity.` | `0x34051b3`, `0x34051d6` |
| 2b. (secondary verification path) | `[login] second sign-in verification result completed, will check auth validity.` | `0x3405376` |
| 3. Auth validity is checked with a cookie | `[login] check auth validity, ` + `cookie` (two separate literals) | `0x34053e2`, `0x34053ff` |
| 3b. Unexpected page guard | `[login] unexpected page "` / `MiniLoginUnexpectedPage` | `0x3405448`, `0x3405430` |
| 4. User info resolves | `[login] nav user info success, login success.` | `0x3405465` |
| 4b. Failure form | `[login] nav user info failed, code=` | `0x3405493` |
| 5. User info handler | `OnGetUserInfo` | `0x34054d6` |

The `nav` endpoint the check uses is a literal in the secret DLL:
`https://api.bilibili.com/x/web-interface/nav` at `bililive_secret.dll@0x1107300`, immediately
followed by `If-None-Match` (`@0x110732d`) — the Windows client issues a conditional nav request.
Also in the secret DLL: `bili_jct` (`@0x10d390a`), `buvid3` (`@0x10d3913`), the format string
`buvid3={0}; DedeUserID={1}` (`@0x10f6dec`), and the guard messages
`[secret] can't find csrf token.` / `[secret] can't find buvid3.` (`@0x10d35fd`, `@0x10d361d`).
**NOT IN SOURCE:** the exact nav request headers, query, and how `SetTokenCookies` vs.
`SetMiniLoginCookies` differ (both names appear; their split is not recoverable statically).

### 8.2 Required order for the port

The order below is the macOS core's, which implements the same sequence and is the normative
specification for this port. Steps 1-6 are the web-login host (§4); steps 7-12 are session
verification (§2).

1. Page reports success — either `livehime_login.LoginSuccess(data)` **or**
   `auth/setRefreshToken` — and/or the cookie jar becomes complete.
   (`WebLoginWindow.swift:102`, `:117-120`, `:199-206`)
2. `LoginResult` is built from the payload; `refresh_token`/`refreshToken`/`token` are all accepted
   (`AuthWebViewBridge.swift:51-61`).
3. If a refresh token and a timestamp are present, load
   `https://www.bilibili.com/correspond/0/<SHA-256 hex>` in a hidden iframe so Bilibili sets the
   matching cookies (`WebLoginWindow.swift:148-151`, `:166-174`).
4. Read back the cookie jar (filter `bilibili.com`, poll ≤20 × 0.3 s) and build
   `SessionCredentials` (`WebLoginWindow.swift:178-195`).
5. On `isComplete`, close the window and hand the credentials to the core
   (`WebLoginWindow.swift:186-188`; `CBridge.swift:377-379`).
6. **Persist first**: `store.save(fresh)`; a failure here is terminal for this attempt and reports
   `.failed(.keychain, …)` (`SessionCoordinator.swift:110-111`).
7. Emit `.verifying` (`SessionCoordinator.swift:396`).
8. **auth/nav check**: `GET https://api.bilibili.com/x/web-interface/nav` with the credential cookie
   header, `User-Agent`, `Referer: https://www.bilibili.com/`,
   `Accept: application/json, text/plain, */*`, timeout 12 s
   (`BilibiliControlClient.swift:34`, `:43-49`).
9. Require HTTP 2xx, a numeric `code`, `code == 0`, `data.isLogin == true`, `mid > 0`; `-101` or
   `isLogin == false` is the **only** path back to `signedOut` (`BilibiliControlClient.swift:60-87`,
   `SessionCoordinator.swift:407-410`).
10. **Room check**: `GET https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld?mid=<mid>`, with
    fallbacks to `room_id_by_uid` and the authenticated `i/api/liveinfo` when the legacy endpoint
    returns no room, then the canonical `room/v1/Room/get_info` for the child-area id
    (`BilibiliLiveClient.swift:107-132`, `:242-261`).
11. Emit `.ready(LiveAccount)` with `mid`, `username` and the room, install `credentials`, and start
    session maintenance (`SessionCoordinator.swift:400-404`).
12. The UI then loads the area list (`account-panel.cpp:174-178`) and the danmaku connection follows
    the room (`CBridge.swift:40-52`).

Failure handling between steps 8 and 11 follows §2.6 rows 8-10: only an explicit "not logged in"
signs out; a missing room yields `.failed(.noLiveRoom, …)` with the login kept
(`SessionCoordinator.swift:425-426`; test `SessionCoordinatorTests.swift:177-184`); transport and
server errors stay `.failed` with the login kept (`:150-175`).

---

## 9. Conformance checklist

Use these as the acceptance tests for the C++ port. They are the macOS tests plus the wire contracts
above.

1. Start with an empty store: the first two messages are exactly `{"state":"signedOut"}` and nothing
   else (`CBridge.swift:156-157`; §2.5).
2. `startQRLogin` emits, in order: `qrCode` (`scanned:false`) → `qrCode` (`scanned:true`) →
   `verifying` → `ready`, with a decodable base64 PNG whose first four bytes are `89 50 4E 47`
   (`SessionCoordinatorTests.swift:114-132`, `:458-463`).
3. `waitingForScan` polls emit nothing (`SessionCoordinator.swift:371-372`).
4. `maxAutoRefresh: 1` with two `.expired` polls ⇒ exactly two QR generations and final state
   `signedOut(qrExpired)` (`SessionCoordinatorTests.swift:134-141`).
5. `cancelQRLogin` from `qrCode` ⇒ `{"state":"signedOut"}` (`e2e-account.mjs:18-19`).
6. A transport error during verification ⇒ `failed(network)` **and** the stored login is still
   present; `retry()` then reaches `ready` (`SessionCoordinatorTests.swift:143-155`).
7. `notLoggedIn` during verification ⇒ `signedOut(sessionExpired)` **and** the store is empty
   (`:157-165`).
8. HTTP 412 during verification ⇒ `failed(server)` with the login kept (`:167-175`).
9. `missingRoom` ⇒ `failed(noLiveRoom)`, not signed out (`:177-184`).
10. Web login: `store.save` happens **before** the first emitted state, and the first emitted state
    is `verifying` (`:202-211`).
11. `signOut` empties the store and emits `signedOut` (`:219-227`).
12. Maintenance: renewed login is saved and installed, then `confirm` is called with the **previous**
    token, result `refreshed` (`:348-360`); a failing step keeps the original stored login and the
    state at `ready`, result `failed:<step>` (`:362-373`); `liveStatus == 1` ⇒ no refresh call and
    result `skippedWhileLive` (`:375-384`).
13. `signOut` issues the server logout with the account's CSRF (`:386-393`).
14. Credential parsing: three `Set-Cookie` values ⇒ exact cookie map; cross-domain URL ⇒ `mid`
    parsed and `gourl` dropped; a lone `SESSDATA` ⇒ thrown (`:404-432`).
15. Stored-data versioning: a `schemaVersion: 2` envelope decodes as current;
    `{"type":"cookie","refreshToken":"SESS"}` decodes as legacy-with-sessdata;
    `{"type":"qr","refreshToken":"RT",…}` decodes as legacy-with-refresh-token; `garbage` decodes as
    `.none` (`:434-444`).
16. `correspondPath` produces a 256-character lowercase hex string that differs across calls;
    the `refresh_csrf` regex extracts `abc123` and returns `nil` for HTML without the div
    (`:395-401`).
17. The JSON of every state parses, contains no `SESSDATA`/`bili_jct`, and the `ready` object carries
    `roomId` (`:449-456`).
18. `getAllCookies`-equivalent filtering, the `completed` single-shot guard and the 20 × 0.3 s budget
    are observable only as timing; the contract is: never complete twice, never hand over an
    incomplete credential set (`WebLoginWindow.swift:178-195`).
19. A `livehime_login` message from an origin other than `https://live.bilibili.com:443`, or from a
    child frame, must be ignored (`AuthBridgeContract.swift:6-9`; §4.6).
20. `auth/setCookies` must reject the whole batch if any item is invalid (name/value limits, control
    characters, `;`/`=`, more than 128 items) and reply `malformed_payload`
    (`AuthBridgeContract.swift:48-77`).

---

## 10. Open questions and risks

Ordered by how likely they are to change the design.

1. **The exact Windows `nav` request and the `SetTokenCookies`/`SetMiniLoginCookies` split.** The nav
   URL is known (`bililive_secret.dll@0x1107300`) and the success/failure log strings are known
   (`bililive.dll@0x3405465`, `@0x3405493`), but the request headers (including `If-None-Match`,
   `@0x110732d`), the cookie set each function writes, and whether the check reads cookies from CEF
   or from the process are **NOT IN SOURCE**. This port therefore follows the macOS order (§8.2); a
   byte-for-byte match with the official client is not achievable from static evidence alone.
2. **Credential storage fidelity.** The Keychain item is unbounded, per-app, and
   `ThisDeviceOnly` (`CredentialStore.swift:56-92`); Credential Manager is no-larger-than-2560
   bytes, readable by any same-user process, and potentially roaming. A published `SESSDATA` can be
   several hundred bytes; nothing in the source bounds it (`AuthBridgeContract.swift:54` allows
   16 384). **Decision needed:** Credential Manager blob vs. DPAPI file vs. hybrid, plus what
   happens when the envelope does not fit.
3. **WebView2 bridge fidelity.** Three separate gaps: no with-reply message handler (the
   `biliBridgePc.callNative` Promise must be emulated), no per-message main-frame flag (the
   `isMainFrame` gate must move into the shim), and document-created scripts run in every frame, so
   the shim is injected into third-party iframes such as geetest. Getting any of these wrong either
   breaks the page's success path (`bridge.md:7-19`) or opens the privileged actions to a
   non-official origin (`AuthBridgeContract.swift:3-9`).
4. **Windows UA, `device_name`, `device_platform`.** All three are macOS literals in the source
   (`QRLogin.swift:134`, `WebLoginWindow.swift:84`) and all three feed risk control: the source
   warns that a non-browser-like UA can make `nav` reject a risk-control login
   (`BilibiliControlClient.swift:44-47`), and the page writes the device fields into cookies that it
   "checks after verification" (`WebLoginWindow.swift:51-52`). The Windows-correct values are
   **NOT IN SOURCE**.
5. **QR PNG geometry.** CoreImage's module count for a given URL is not specified by the source; the
   port must derive `modules` from its own encoder and apply the same level-M / quiet-zone-4 /
   `floor(target/modules)` rules (§3.6). A different quiet zone or correction level still produces a
   scannable QR, so this is a low-severity but easily-detected deviation (the tests assert only a
   valid PNG header, `SessionCoordinatorTests.swift:462`).
6. **Legacy migration on Windows.** The importer's whole premise is Apple-specific
   (`PlatformSupport.swift:7-9`), and the old Windows client's store format is unknown (§7.4
   row 25). Treating legacy as `.none` is safe and matches §2.6 row 3, but it silently drops any
   login a previous Windows build wrote.
7. **`detail` string stability.** The `failed.detail` field is Swift error description text
   (`SessionCoordinator.swift:412`). It is displayed verbatim by the UI (`account-panel.cpp:181`).
   The port must produce something human-readable; it can never match byte-for-byte, and no test
   should depend on it.
8. **CEF vs. WebView2.** The official client uses CEF (`package.md:26-27`) and the page is the
   Windows client's own page (`WebLoginWindow.swift:5-6`). WebView2 is the smaller dependency and
   the natural Windows counterpart of `WKWebView`, but CEF is the environment this page is designed
   and tested against upstream. **NOT IN SOURCE:** any evidence about how the page behaves
   differently in WebView2 (for example whether it detects the host via `window.chrome.webview`).
