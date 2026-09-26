# Bilibili HTTP API layer — port specification (Swift/macOS → C++/Windows)

Status: **specification only.** Read-only analysis of the macOS sources; no code
was built, run, or modified to produce this document.

This document specifies, completely and literally, the HTTP layer that a Windows
C++ implementation must reproduce so that the Qt plugin keeps behaving exactly
as the shipped macOS core does.

---

## 0. Conventions

### 0.1 Source abbreviations used in every citation

| Tag | File |
|---|---|
| `BLC` | `plugins/livehime/core/Sources/LiveHimeCore/BilibiliLiveClient.swift` |
| `BCC` | `plugins/livehime/core/Sources/LiveHimeCore/BilibiliControlClient.swift` |
| `LRA` | `plugins/livehime/core/Sources/LiveHimeCore/LiveRoomActions.swift` |
| `AP`  | `plugins/livehime/core/Sources/LiveHimeCore/ApiProbe.swift` |
| `QR`  | `plugins/livehime/core/Sources/LiveHimeCore/QRLogin.swift` |
| `SC`  | `plugins/livehime/core/Sources/LiveHimeCore/SessionCoordinator.swift` |
| `SM`  | `plugins/livehime/core/Sources/LiveHimeCore/SessionMaintenance.swift` |
| `EM`  | `plugins/livehime/core/Sources/LiveHimeCore/Emoticons.swift` |
| `DP`  | `plugins/livehime/core/Sources/LiveHimeCore/DanmakuProtocol.swift` |
| `DC`  | `plugins/livehime/core/Sources/LiveHimeCore/DanmakuClient.swift` |
| `CB`  | `plugins/livehime/core/Sources/LiveHimeCore/CBridge.swift` |
| `CS`  | `plugins/livehime/core/Sources/LiveHimeCore/CredentialStore.swift` |
| `DG`  | `plugins/livehime/core/Sources/LiveHimeCore/Diagnostics.swift` |
| `WL`  | `plugins/livehime/core/Sources/LiveHimeCore/WebLoginWindow.swift` |
| `H`   | `plugins/livehime/core/include/livehime-core.h` |
| `WIN` | `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/CURRENT_PACKAGE_STATIC_ANALYSIS.md` |
| `URLS`| `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/bililive_secret-relevant-urls.txt` |

Paths are relative to `livehime-win-src/` unless absolute.

### 0.2 Rules applied

* Every behavioural claim carries `file:line`.
* Where the sources do not say something, the text says **NOT IN SOURCE**. It is
  never inferred silently.
* Text marked **DERIVED** is arithmetic or decoding logic that follows from
  cited literals but is not itself written in the source. Every DERIVED item is a
  candidate for a golden test on Windows.
* Text marked **PROPOSED** is design for the C++ port. It is not in the source.
* Code blocks contain exact literal strings copied from the source.

---

## 1. Scope and inventory

### 1.1 What this layer is

Five types own every Bilibili HTTP request the core makes. `BilibiliLiveClient`
additionally has two extensions (in `LRA` and `EM`):

* `BilibiliLiveClient` — cookie-authenticated live-room operations
  (`BLC:91`), plus room-action endpoints in an extension (`LRA:27`), plus
  emoticon endpoints in a second extension (`EM:95`).
* `BilibiliControlClient` — the identity probe (`BCC:25`).
* `QRLoginClient` — web QR login (`QR:47`).
* `SessionMaintenance` — cookie refresh / logout (`SM:18`).
* `ApiProbe` — a read-only health check that drives all of the above (`AP:8`).

All of them share one transport function: `BilibiliLiveClient.requestJSON`
(`BLC:387-440`). `BilibiliControlClient.fetchIdentity` (`BCC:33-88`),
`QRLoginClient.get` (`QR:105-121`) and `SessionMaintenance.send`
(`SM:127-145`) are independent re-implementations of the same envelope handling
and must be ported separately — they differ in headers and error mapping (see
§9).

### 1.2 Endpoint count

| Group | Count | Where |
|---|---:|---|
| Endpoints defined in the four named files | **23** | §5.1–§5.23 |
| Endpoints in adjacent files reachable from `ApiProbe` / login | **11** | §5.24 |
| WebSocket (not HTTP) | 1 | §5.25 |
| **Total distinct network targets** | **34 + 1 WS** | |

Call-site duplicates (the same URL reached from more than one function) are
counted once and listed in §4.

---

## 2. Transport contract — `requestJSON`

Single source of truth: `BLC:387-440`. A C++ implementation must reproduce this
exactly, because every endpoint except nav, QR login and session maintenance
goes through it.

### 2.1 Method selection

```swift
request.httpMethod = httpMethod ?? (body == nil ? "GET" : "POST")
```
`BLC:390`

Consequences:

* `stopLive`, `sendDanmaku`, `updateTitle`, `IsUserIdentifiedByFaceAuth`,
  `AddSilentUser`, `GetShieldKeywordList`, `AddShieldKeyword`,
  `DelShieldKeyword`, and the sticker `msg/send` are POST **because they pass a
  body** (`BLC:295`, `LRA:93`, `LRA:100`, `LRA:118`, `LRA:140`, `LRA:148`,
  `LRA:158`, `EM:138`).
* `startLive` is POST **because it passes `httpMethod: "POST"` explicitly while
  `body` stays `nil`** (`BLC:285`). It therefore sends **no body and no
  Content-Type header** (see §2.2).
* Every other call is GET.

### 2.2 Headers — verbatim

Set for every `requestJSON` call (`BLC:392-400`):

```http
Cookie: <cookieHeader argument>
Accept: application/json, text/plain, */*
Origin: https://api.live.bilibili.com
Referer: https://live.bilibili.com/
User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15
```
`BLC:392-399`

Conditionally:

```http
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
```
`BLC:400` — **only when `body != nil`**. Note the `; charset=UTF-8` suffix;
`SessionMaintenance` uses the same media type *without* the charset parameter
(`SM:133`).

Notes for the port:

* The `Cookie` header is set unconditionally, even for an empty string
  (`BLC:392`). `buvid3(cookieHeader:)` deliberately calls `requestJSON` with
  `cookieHeader: ""` (`LRA:32-33`), i.e. an empty `Cookie:` header value is sent.
  Whether an empty header is transmitted or dropped is a Foundation behaviour and
  is **NOT IN SOURCE** — pin it with a capture on both platforms (§13, risk 1).
* No `Accept-Language`, `Accept-Encoding`, `Content-Length`, `Connection`,
  `Cache-Control`, `Pragma` or `X-Requested-With` header is set anywhere in this
  layer. **NOT IN SOURCE**.
* `Origin` is only ever the API origin `https://api.live.bilibili.com`
  (`BLC:397`), including for `https://api.bilibili.com/...` calls such as
  `x/report/click/now` and `x/frontend/finger/spi` made through
  `requestJSON`.

### 2.3 Timeout

```swift
request.timeoutInterval = 12
```
`BLC:389` (also `BCC:36`, `QR:109`, `SM:120`, `AP:118`, `AP:133`)

12 seconds applies to the whole request in URLSession's default configuration.
`URLSessionConfiguration` defaults for resource timeout are **NOT IN SOURCE**
(`BilibiliWeb.session` is created at `QR:127-133` and sets no timeout).

### 2.4 Response ladder

In order (`BLC:409-439`):

1. Transport error (`URLError`) → `BilibiliLiveError.network(code:)` with
   `error.errorCode` (`BLC:412-415`). Non-`URLError` throws →
   `BilibiliLiveError.transport` (`BLC:415`).
2. Response is not `HTTPURLResponse` → `BilibiliLiveError.invalidResponse`
   (`BLC:416-418`).
3. Status outside `200..<300` → `BilibiliLiveError.http(status:retryAfterSeconds:)`,
   `retryAfterSeconds` parsed from the `Retry-After` response header
   (`BLC:419-423`).
4. Body is not a JSON object (`[String: Any]`), or has no usable integral `code`
   → `BilibiliLiveError.invalidResponse` (`BLC:424-427`).
5. `code != 0` → mapping in §9.1 (`BLC:428-437`).
6. `code == 0` → the parsed object is returned as-is (`BLC:438-439`).

The layer does **not** inspect any other response header, does **not** follow
redirects explicitly, does **not** decompress manually, and does **not** retry.
**NOT IN SOURCE**: any retry, backoff, `Retry-After` honouring, or HTTP/2 choice.
`retryAfterSeconds` is only recorded in diagnostics and carried in the error
(`BLC:420-422`); no caller acts on it (grep of `retryAfterSeconds` shows only
`BLC` and `DG`).

### 2.5 Numeric coercion helpers

Used on every response field:

```swift
private static func apiCode(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
          abs(number.doubleValue) <= Double(Int32.max) else { return nil }
    return number.intValue
}
```
`BLC:456-461` — rejects JSON booleans, non-finite numbers, non-integral numbers,
and anything outside ±`Int32.max`. A `code` that fails this becomes
`invalidResponse` (`BLC:424-426`).

```swift
private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? 0 }
private func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? (value as? String).flatMap(Int64.init) ?? 0 }
```
`BLC:511-512` — **both accept a JSON string as well as a number**; anything else
(including a boolean) yields `0`. `2.5` → `2` for `Int`/`Int64` conversion of a
non-integral JSON number (Swift `NSNumber.intValue` truncates).

### 2.6 `Retry-After` parsing

`BLC:463-474`:

* A decimal integer (whitespace-trimmed) `>= 0` → `min(seconds, 86400)`.
* Otherwise parsed as an HTTP-date with POSIX locale, GMT time zone, format
  `"EEE, dd MMM yyyy HH:mm:ss zzz"` → `ceil(seconds from now)`, clamped to
  `0...86400` (`BLC:472-473`).
* Anything else → `nil`.

### 2.7 Diagnostics

`requestJSON` records one `BilibiliDiagnosticEvent` per outcome
(`BLC:404-408`, `BLC:438`). Event fields and enums are `DG:3-70`. The stage is
chosen by URL path (`BLC:442-454`):

| URL path | Stage |
|---|---|
| `endpoints.areaListURL.path` → `/room/v1/Area/getList` | `.areas` |
| `endpoints.liveVersionURL.path` → `/xlive/app-blink/v1/liveVersionInfo/getHomePageLiveVersion` | `.version` |
| `endpoints.upstreamURL.path` → `/xlive/app-blink/v1/live/GetUpStreamRtmp` | `.upstream` |
| `/room/v1/Room/startLive` | `.start` |
| `/room/v1/Room/stopLive` | `.stop` |
| `/x/report/click/now` | `.serverTime` |
| `/room/v1/Room/getRoomInfoOld`, `/room/v2/Room/room_id_by_uid`, `/i/api/liveinfo`, `/room/v1/Room/get_info` | `.room` |
| anything else | `.http` |

The operation is `.mutate` for POST and `.request` otherwise (`BLC:403`).

**In the shipping app the store is always nil**: `CBridge` constructs
`LiveBilibiliAccountAPI()` with no diagnostics (`CB:149`), and
`LiveBilibiliAccountAPI` builds its clients with `diagnostics: diagnostics` =
`nil` (`SC:441-452`, `SC:524-526`). Diagnostics are therefore **not** on the
critical path for the port; a C++ implementation may keep the enum shapes for
parity but nothing is exported to the UI (`livehime_core_probe_run` reports its
own timings, `AP:26-45`).

### 2.8 Diagnostic-free paths

`BilibiliControlClient.fetchIdentity` (`BCC:38-42`), `QRLoginClient.get`
(`QR:105-121`) and `SessionMaintenance.send`/`page` (`SM:127-153`) do **not** go
through `requestJSON`; they have their own HTTP code, their own headers, and (for
nav) different numbers of header fields. They are specified individually in §5.

---

## 3. Cookie model

### 3.1 The credential object

```swift
public static let requiredCookies = ["SESSDATA", "bili_jct", "DedeUserID"]
static let keptCookies: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid", "buvid3"]
```
`QR:7-8`

* Only these six names survive `SessionCredentials.init` (`QR:15`); every other
  cookie Bilibili sets is dropped.
* `isComplete` requires all three of `SESSDATA`, `bili_jct`, `DedeUserID`
  (`QR:20`); a session missing any of them is treated as not logged in
  (`QR:101`, `SC:354`).
* `mid` = `DedeUserID` parsed as `Int64` (`QR:21`); `csrf` = `bili_jct` (`QR:22`).
* **`cookieHeader` is built by sorting cookie names ascending and joining
  `name=value` with `"; "`** (`QR:24-26`):

```swift
public var cookieHeader: String {
    cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
}
```

DERIVED example for a full jar — alphabetical order, this exact string:
`DedeUserID=…; DedeUserID__ckMd5=…; SESSDATA=…; bili_jct=…; buvid3=…; sid=…`

There is no `Cookie:` prefix, no attributes, no domain/path/expiry, and no
quoting. Values are stored verbatim (`QR:92`, `QR:90-93`) — percent-decoding of
`Set-Cookie` values is done by `HTTPCookie` (`QR:91`) and is **NOT IN SOURCE** at
the byte level.

### 3.2 Where cookies come from

Three sources, all producing the same six-name dictionary:

1. **QR login** — `Set-Cookie` headers of the poll response, plus the query items
   of the cross-domain `url` field in the body as a fallback for names not seen
   in the headers (`QR:88-102`).
2. **Official web login page** — the WKWebView cookie store; every cookie whose
   domain ends with `bilibili.com` is copied in (`WL:180-184`), collected with up
   to 20 attempts at 0.3 s intervals (`WL:189-193`).
3. **Legacy v0.1.2 import** — `WebKitLegacyImporter`, cookies only
   (`SC:349-357`, `CS:32-51`).

The cookie jar is written to the Keychain/credential store as one item
(`CS:83-98`); the format is a versioned envelope, `schemaVersion = 2`
(`CS:25-29`). A Windows implementation needs an equivalent — the port plan names
Windows Credential Manager (`WIN:103`).

### 3.3 `bili_jct` injection at client construction

```swift
if let biliJct, !biliJct.isEmpty, !cookieHeader.contains("bili_jct=") {
    self.defaultCookieHeader = cookieHeader + (cookieHeader.isEmpty ? "" : "; ") + "bili_jct=" + biliJct
} else { self.defaultCookieHeader = cookieHeader }
```
`BLC:102-104`

* The separator is `"; "` when the header is non-empty; the resulting string is
  **not** re-sorted (`BLC:103`), so it ends with `; bili_jct=<value>`.
* The guard is a plain substring test `cookieHeader.contains("bili_jct=")`
  (`BLC:102`), not a cookie parse.
* In production the argument is always `nil` (the second initializer is only used
  for QR/web credentials plus the cookie header, `SC:524-526`, `BLC:98-105`), so
  `defaultCookieHeader == cookieHeader` for every `LiveBilibiliAccountAPI` call.
* `defaultCookieHeader` (not the per-call `cookieHeader`) is used by
  `fetchCurrentRoom` (`BLC:109`) and by `fetchServerTimestamp` (`BLC:481`).
  `startLive`/`stopLive` use the per-call argument (`BLC:264`, `BLC:291`,
  `BLC:285`, `BLC:295`).

### 3.4 `csrf` extraction

```swift
func csrf(from cookieHeader: String) throws -> String {
    for part in cookieHeader.split(separator: ";") {
        let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2 && pair[0].trimmingCharacters(in: .whitespaces) == "bili_jct" && !pair[1].isEmpty { return pair[1] }
    }
    throw BilibiliLiveError.missingCSRF
}
```
`BLC:490-496`

* Splits on `;`, then on the **first** `=`; the name is whitespace-trimmed, the
  **value is not** (no trimming of `pair[1]`).
* An empty `bili_jct=` value is skipped and, if no other match exists,
  `missingCSRF` is thrown (`BLC:493-495`).
* Thrown before any request in `startLive` (`BLC:264`), `stopLive` (`BLC:291`),
  `sendDanmaku` (`LRA:81`), `updateTitle` (`LRA:97`), `faceAuthData`
  (`LRA:114`), `muteUser` (`LRA:136`), `shieldKeywords` (`LRA:145`),
  `setShieldKeyword` (`LRA:153`), `sendEmoticon` (`EM:126`).
* `BilibiliLiveError.missingCSRF` is **not** in `CoreBridge.errorFields`
  (`CB:194-218`), so it surfaces as `{"kind":"server","message":"missingCSRF"}`
  via the `default` branch (`CB:214-216`).

### 3.5 `buvid3` handling

* If the header already contains `buvid3`, its value is used and no request is
  made (`LRA:31`).
* Otherwise `GET https://api.bilibili.com/x/frontend/finger/spi` with an **empty
  cookie header** (`LRA:32-33`) and the response field `data.b_3` is used
  (`LRA:34-37`).
* The name comparison in `cookieValue(_:in:)` is exact (`pair[0] == name`,
  `LRA:183`) on both name and value; the value is whitespace-trimmed
  (`LRA:182`).
* When the cookie was absent, the danmaku calls append it to the header used for
  that call only:

```swift
let cookies = cookieValue("buvid3", in: cookieHeader) == nil ? cookieHeader + "; buvid3=" + buvid : cookieHeader
```
`LRA:61` — note this is `"; buvid3="` (no space after `=`), and if
`cookieHeader` is empty the result begins with `"; buvid3="`.

### 3.6 Cookies that matter but are not stored

| Cookie | Role | Evidence |
|---|---|---|
| `SESSDATA` | login; part of `requiredCookies` | `QR:7` |
| `bili_jct` | CSRF token, sent twice per form | `QR:7`, `QR:22`, `BLC:493` |
| `DedeUserID` | the account mid | `QR:7`, `QR:21` |
| `DedeUserID__ckMd5` | kept, never read | `QR:8` |
| `sid` | kept, never read | `QR:8` |
| `buvid3` | kept; danmaku fingerprint; fetched from `finger/spi` when missing | `QR:8`, `LRA:30-38` |
| any other (e.g. `buvid4`, `b_nut`, `bili_ticket`) | dropped at `SessionCredentials.init` | `QR:8`, `QR:15` |

The login WebView does receive non-kept cookies but they are filtered out before
saving (`QR:8`).

---

## 4. Endpoint catalogue

`Auth` column: `C` = full cookie header, `C'` = cookie header plus appended
`buvid3`, `""` = empty `Cookie:` header, `—` = no `Cookie` header set at all.

| ID | Method | URL (verbatim, minus query) | Auth | Query / body | Defined at |
|---|---|---|---|---|---|
| E1 | GET | `https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld` | C | `mid` | `BLC:41`, `BLC:109` |
| E2 | GET | `https://api.live.bilibili.com/room/v2/Room/room_id_by_uid` | C | `uid` | `BLC:42`, `BLC:136` |
| E3 | GET | `https://api.live.bilibili.com/room/v1/Area/getList` | C | `platform`, `parent_id?` | `BLC:43`, `BLC:147-149` |
| E4 | GET | `https://api.live.bilibili.com/xlive/app-blink/v1/liveVersionInfo/getHomePageLiveVersion` | C | `system_version=2` | `BLC:45`, `BLC:194` |
| E5 | GET | `https://api.live.bilibili.com/xlive/app-blink/v1/live/GetUpStreamRtmp` | C | `platform`, `room_id?` | `BLC:44`, `BLC:206-208` |
| E6 | GET | `https://api.live.bilibili.com/i/api/liveinfo` | C | — | `BLC:46`, `BLC:214` |
| E7 | GET | `https://api.live.bilibili.com/room/v1/Room/get_info` | C | `room_id` | `BLC:243-245` |
| E8 | POST | `https://api.live.bilibili.com/room/v1/Room/startLive` | C | signed query, no body | `BLC:284-285` |
| E9 | POST | `https://api.live.bilibili.com/room/v1/Room/stopLive` | C | form body | `BLC:292-296` |
| E10 | GET | `https://api.bilibili.com/x/report/click/now` | C (default) | — | `BLC:477-481` |
| E11 | GET | `https://api.bilibili.com/x/web-interface/nav` | C / C | — | `BCC:34`, `LRA:43`, `AP:118` |
| E12 | GET | `https://api.bilibili.com/x/frontend/finger/spi` | `""` | — | `LRA:32-33` |
| E13 | GET | `https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo` | C' | WBI-signed | `LRA:63-66` |
| E14 | POST | `https://api.live.bilibili.com/msg/send` | C | form body | `LRA:92-93` |
| E15 | POST | `https://api.live.bilibili.com/room/v1/Room/update` | C | form body | `LRA:98-101` |
| E16 | POST | `https://api.live.bilibili.com/xlive/app-blink/v1/preLive/IsUserIdentifiedByFaceAuth` | C | form body | `LRA:115-118` |
| E17 | POST | `https://api.live.bilibili.com/xlive/web-ucenter/v1/banned/AddSilentUser` | C | form body | `LRA:137-141` |
| E18 | POST | `https://api.live.bilibili.com/xlive/web-ucenter/v1/banned/GetShieldKeywordList` | C | form body | `LRA:146-148` |
| E19 | POST | `https://api.live.bilibili.com/xlive/web-ucenter/v1/banned/AddShieldKeyword` | C | form body | `LRA:153-158` |
| E20 | POST | `https://api.live.bilibili.com/xlive/web-ucenter/v1/banned/DelShieldKeyword` | C | form body | `LRA:153-158` |
| E21 | GET | `https://live.bilibili.com/p/html/live-pc-blink/mini-login-v2/` | — | — | `AP:80` |
| E22 | GET | `https://live.bilibili.com/p/html/live-pc-blink/hime-live-cover/` | — | — | `AP:81` |
| E23 | GET | `https://live.bilibili.com/p/html/bilili-page-face-auth/index.html` | — | — | `AP:82` |
| A1 | POST | `https://api.live.bilibili.com/msg/send` (sticker) | C | form body | `EM:137-138` |
| A2 | GET | `https://api.live.bilibili.com/xlive/web-ucenter/v2/emoticon/GetEmoticons` | C | `platform=pc`, `room_id` | `EM:99-102` |
| A3 | GET | `https://api.bilibili.com/x/emote/user/panel/web` | C | `business=reply` | `EM:107-111` |
| A4 | GET | `https://passport.bilibili.com/x/passport-login/web/qrcode/generate` | — | `source=live_pc` | `QR:48`, `QR:61-62` |
| A5 | GET | `https://passport.bilibili.com/x/passport-login/web/qrcode/poll` | — | `qrcode_key`, `source=live_pc` | `QR:49`, `QR:69-73` |
| A6 | GET | `https://passport.bilibili.com/x/passport-login/web/cookie/info` | C | `csrf` | `SM:70-72` |
| A7 | GET | `https://www.bilibili.com/correspond/1/<RSA-path>` (HTML) | C | — | `SM:79` |
| A8 | POST | `https://passport.bilibili.com/x/passport-login/web/cookie/refresh` | C | form body | `SM:83-87` |
| A9 | POST | `https://passport.bilibili.com/x/passport-login/web/confirm/refresh` | C | form body | `SM:103-105` |
| A10 | POST | `https://passport.bilibili.com/login/exit/v2` | C | form body | `SM:112-113` |
| A11 | GET | `https://www.bilibili.com/correspond/0/<sha256-hex>` (iframe, WebView) | WebView jar | — | `WL:166-173` |
| WS1 | WSS | `wss://<host>:<wss_port>/sub` | — (token in frame) | — | `DC:59` |

---

## 5. Endpoint details

### 5.1 E1 — `getRoomInfoOld` (legacy room record by mid)

Request built by `fetchCurrentRoom` (`BLC:107-132`) → `fetchRoomInfo(url:query:cookieHeader:)`
(`BLC:375-383`):

```
GET https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld?mid=<mid>
```
Query item `URLQueryItem(name: "mid", value: String(mid))` (`BLC:109`). `mid` is
`BilibiliIdentity.mid` (`SC:400`).

Response fields read (`BLC:377-382`), all through `int64`/`int`/`as? String`
(`BLC:511-512`):

| JSON path | Type | Model field | Notes |
|---|---|---|---|
| `data` | object | — | must exist, else `missingRoom` (`BLC:377`) |
| `data.room_info` | object | — | used **instead of** `data` when present (`BLC:378`) |
| `<d>.room_id` or `<d>.roomid` | number/string | `roomID` | must be `> 0`, else `missingRoom` (`BLC:381`) |
| `<d>.uid` | number/string | `uid` | `BLC:382` |
| `<d>.short_id` | number/string | `shortRoomID` | `BLC:382` |
| `<d>.title` or `<d>.roomname` | string | `title` | `BLC:382` |
| `<d>.live_status` or `<d>.liveStatus` | number/string | `liveStatus` | `BLC:382`; no `0..2` check here |
| `<d>.area_v2_id` or `<d>.area_id` | number/string | `areaID` | `BLC:382` |

Callers: `fetchCurrentRoom` (`BLC:109`) and the QR/verify path
(`SC:400`, `SC:456`).

### 5.2 E2 — `room_id_by_uid`

```
GET https://api.live.bilibili.com/room/v2/Room/room_id_by_uid?uid=<mid>
```
`BLC:135-139`.

Response: `data.room_id`, falling back to a top-level `room_id`
(`BLC:140-141`). `roomID > 0` is required, else `missingRoom` (`BLC:142`).

Called from `fetchCurrentRoom` **only** after E1 threw `missingRoom`
(`BLC:118-124`).

### 5.3 E3 — `Area/getList`

```
GET https://api.live.bilibili.com/room/v1/Area/getList?platform=pc_link
GET https://api.live.bilibili.com/room/v1/Area/getList?platform=pc_link&parent_id=<parentID>
```
`platform` defaults to the string `"pc_link"` and is a parameter of
`fetchAreas(parentID:platform:)` (`BLC:146-148`); `parent_id` is appended only
when `parentID != nil` (`BLC:148`). Production always calls `fetchAreas()` with
no arguments (`SC:464`).

Response: `data` must exist or `invalidResponse` (`BLC:150`). The flattening
algorithm (`BLC:152-187`) is exact and must be ported literally:

1. If the value is an **array of objects**, flatten each element with the same
   inherited parent (`BLC:153-155`).
2. If it is an object, collect **all** present child arrays among the keys
   `list`, `area_list`, `children`, `areas` (`BLC:158`) — all four are inspected,
   not just the first.
3. A **leaf** is emitted only when: the object has no child array, **and** it has
   `id` or `area_id`, **and** it has `name` or `area_name` (`BLC:164-166`).
4. On a leaf, `parent_id`/`parent_area_id` is filled from the inherited parent
   when absent, and `parent_name`/`parent_area_name` likewise (`BLC:168-173`).
5. Recursion into each child uses `ownID > 0 ? ownID : inheritedParentID` and
   `!ownName.isEmpty ? ownName : inheritedParentName` (`BLC:176-180`).
6. Empty result → `invalidResponse` (`BLC:183`).
7. Final mapping (`BLC:184-187`): `areaID = id ?? area_id` (must be `> 0`),
   `name = name ?? area_name` (must exist), `parentAreaID = parent_id ??
   parent_area_id`, `parentName = parent_name ?? parent_area_name ?? ""`.

Read fields: `id`, `area_id`, `name`, `area_name`, `parent_id`,
`parent_area_id`, `parent_name`, `parent_area_name`, `list`, `area_list`,
`children`, `areas`.

The comment at `BLC:161-163` is a hard requirement: only leaf ids may be sent to
`startLive`; a parent id (for example 网游) produces Bilibili's generic `-400`.

### 5.4 E4 — `getHomePageLiveVersion`

```
GET https://api.live.bilibili.com/xlive/app-blink/v1/liveVersionInfo/getHomePageLiveVersion?system_version=2
```
`BLC:192-197`. Response (`BLC:198-202`): `data` object, falling back to the
**root** object; `curr_version` or `version` (string), `build` (number). Both must
be non-empty/`> 0`, else `invalidResponse` (`BLC:201`).

Note the official installer's own capture uses a second parameter,
`&url_type=1` (`WIN:7`); this Swift code sends only `system_version=2`
(`BLC:194`). See §11.

Used for the `startLive` `version`/`build` fields (`BLC:267-269`) and by the probe
(`AP:58-61`).

### 5.5 E5 — `GetUpStreamRtmp`

```
GET https://api.live.bilibili.com/xlive/app-blink/v1/live/GetUpStreamRtmp?platform=pc_link
GET https://api.live.bilibili.com/xlive/app-blink/v1/live/GetUpStreamRtmp?platform=pc_link&room_id=<roomID>
```
`BLC:205-208`. `room_id` is appended only when the caller passes a room
(`BLC:207`); `LiveBilibiliAccountAPI.upstream` always passes the room
(`SC:476-478`).

Response is parsed by the shared stream-config parser (§5.6.1).

Called by `SC:219-225` **only** when `startLive` succeeded but its payload had no
usable RTMP endpoint (fallback).

### 5.6 E6 — `i/api/liveinfo`

```
GET https://api.live.bilibili.com/i/api/liveinfo
```
No query, cookie-authenticated (`BLC:212-217`).

Response: only the room id is extracted, by the recursive `findRoomID`
(`BLC:218-238`):

1. Inside any object, try keys `roomid`, `room_id`, `roomId` (`BLC:223-225`).
2. Then recurse into keys `room_info`, `live_info`, `room`, `data`
   (`BLC:226-228`).
3. Then accept a bare `id` — **only if** the object has no `room_id`/`roomid`
   **and** has `room_info` or `live_info` (`BLC:229-231`).
4. Then recurse into all remaining values (`BLC:232`) and into arrays
   (`BLC:233-235`).
5. Search starts at `root["data"]`; nothing found → `missingRoom` (`BLC:238-239`).

Callers: `fetchCurrentRoom`'s second fallback (`BLC:129-130`).

#### 5.6.1 Stream-config parser (shared by E5, E8)

`BLC:334-365` (instance wrapper adds a diagnostic at `BLC:367-373`).

* Face-auth check first, `required: false` (`BLC:335`, §9.3).
* A candidate pair needs `addr` | `server` | `rtmp_addr` **and** `code` | `key` |
  `stream_code`, both non-empty (`BLC:336-341`).
* Candidate order (`BLC:356-362`): `data.rtmp`, then every entry of
  `data.protocols` whose `protocol` (lower-cased) is `"rtmp"`, then a recursive
  sweep of `root["data"]` where object keys are visited in **sorted** order
  (`BLC:342-349`, `BLC:345`) so the result is deterministic — the source comment
  at `BLC:314-316` states that dictionary order is random and "first match wins"
  must never decide.
* A candidate is usable only if the address parses as a URL whose scheme
  (lower-cased) is `rtmp` or `rtmps` **and** whose host is non-empty
  (`BLC:350-354`).
* First usable candidate wins; otherwise `missingStreamConfig` (`BLC:363-364`).

### 5.7 E7 — `get_info` (canonical room record)

```swift
var components = URLComponents(string: "https://api.live.bilibili.com/room/v1/Room/get_info")!
components.queryItems = [URLQueryItem(name: "room_id", value: String(roomID))]
```
`BLC:243-244`

Response validation is stricter than E1 (`BLC:246-252`):

* `data` must be an object;
* `data.room_id` must equal the requested `roomID` (exact integer equality);
* `live_status` or `liveStatus` must be integral and in `[0, 1, 2]`.

Failure → a `.room/.parse/.schema` diagnostic (`BLC:250`) and `invalidResponse`.

Mapped fields (`BLC:253-260`): `room_id`→`roomID`, `uid`, `short_id`, `title`,
`live_status`, `area_v2_id ?? area_id`.

Called by `fetchCurrentRoom`'s area-upgrade path (`BLC:113`), the fallback path
(`BLC:123`, `BLC:130`), `LiveBilibiliAccountAPI.roomInfo` (`SC:460`), and the
probe (`AP:69`).

### 5.8 E8 — `startLive` (the signed request)

```swift
let values = [
    ("appkey", "aae92bc66f3edfab"), ("area_v2", String(areaID)),
    ("build", build), ("csrf", csrf), ("platform", "pc_link"),
    ("room_id", String(roomID)), ("ts", await fetchServerTimestamp()),
    ("version", version)
]
let unsigned = formString(values)
let signedValues = values + [("sign", md5Hex(unsigned + "af125a0d5279fd576c1b4418a3e8276d"))]
let query = signedValues.map { URLQueryItem(name: $0.0, value: $0.1) }
```
`BLC:274-282`

* **Field order is part of the protocol** and must not be sorted:
  `appkey, area_v2, build, csrf, platform, room_id, ts, version, sign`
  (`BLC:274-282`). The source comment at `BLC:270-273` states the current
  Windows/web flow places these eight fields on the POST query string in
  insertion order, that the order is required for the signature, and that extra
  fields (`csrf_token`, `backup_stream`) make newer accounts reject the request.
* Query string, not body (`BLC:282-286`), with `httpMethod: "POST"` and `body:
  nil` → no `Content-Type` (§2.2).
* `version`/`build` come from E4 when available, else the literals `"8.6.0"` /
  `11050` (`BLC:267-269`).
* `ts` comes from E10; local time is the fallback (`BLC:476-488`).
* `areaID` is the **leaf** id (`BLC:275`, `SC:468`); `parentAreaID` is accepted as
  a parameter (`BLC:263`) and then **never used** — it does not appear in the
  field list. A C++ port should keep the parameter for ABI parity and keep
  ignoring it.
* `csrf` is the `bili_jct` value (§3.4) and is percent-encoded twice in the
  pipeline: once inside `formString` for the signature input, once by
  `URLComponents` for the wire (`BLC:280-282`, `BLC:385`). For a hex token both
  are identity.
* Response parsed by §5.6.1 (`BLC:287`).

Signature algorithm: §7.

### 5.9 E9 — `stopLive`

```swift
let body = form([("room_id", String(roomID)), ("platform", "pc_link"), ("csrf", csrf), ("csrf_token", csrf)])
```
`BLC:292`, sent to
`https://api.live.bilibili.com/room/v1/Room/stopLive` (`BLC:294`) as a
`x-www-form-urlencoded; charset=UTF-8` POST (`BLC:295`, `BLC:400`).

Note `csrf` **and** `csrf_token` carry the same value, and `csrf_token` is absent
from `startLive` by design (`BLC:273`). The response body is discarded
(`_ = try await`, `BLC:293`), but the `code`/HTTP checks still run.

### 5.10 E10 — server timestamp

```
GET https://api.bilibili.com/x/report/click/now
```
`BLC:477`. Uses `defaultCookieHeader` (§3.3) and the standard headers of §2.2 —
including `Origin: https://api.live.bilibili.com` on an `api.bilibili.com` host
(`BLC:397`).

Response: `data.now` (integer, `> 0`) → `String(value)` (`BLC:482-485`). Any
error, missing field, non-positive value, or a URL-construction failure
(`BLC:477-479`) → `String(Int(Date().timeIntervalSince1970))` (`BLC:487`).

`fetchServerTimestamp()` is `private` and is called only from `startLive`
(`BLC:277`). Errors are swallowed (`catch { }`, `BLC:486`).

### 5.11 E11 — `nav` (three call sites, three header sets)

| Call site | Cookie | UA | Referer | Accept | Origin | Code check |
|---|---|---|---|---|---|---|
| `BCC:33-49` (`fetchIdentity`) | `C` | macOS Safari UA (`BCC:47`) | `https://www.bilibili.com/` (`BCC:48`) | `application/json, text/plain, */*` (`BCC:49`) | — | yes, strict |
| `LRA:42-57` (`wbiSigner`) | `C` | `BilibiliWeb.userAgent` (`LRA:46`) | `https://live.bilibili.com/` (`LRA:47`) | — | — | **none** |
| `AP:117-130` (`ApiProbe.nav`) | `C` | `BilibiliWeb.userAgent` (`AP:120`) | — | — | — | accepts `0` or `-101` |

`BilibiliWeb.userAgent` (`QR:134`):

```swift
static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
```

This is byte-identical to the UA `requestJSON` sets (`BLC:399`).

Response fields:

* `BCC:65-87`: `code` (integral, §BCC's own inline check at `BCC:66-70`),
  `data.isLogin` (Bool, required, `BCC:77`), `data.mid` (`Int64` or `NSNumber`,
  `BCC:81-85`; `mid <= 0` → `invalidResponse`), `data.uname` (String, default
  `""`, `BCC:87`).
* `LRA:51-55`: `data.wbi_img.img_url`, `data.wbi_img.sub_url` — read **without
  any code or HTTP-status check** (`LRA:49-51`); a non-2xx body is still parsed.
* `AP:123-129`: `code` must be `0` or `-101`, `data` must be an object,
  `data.wbi_img` must be an object (`AP:126`); `data.isLogin == true` →
  `"signedIn"`, else `"signedOut"` (`AP:129`).

`ApiProbe.nav` additionally requires HTTP 200 via `httpOK` (`AP:122`,
`AP:153-157`), which is **stricter than `requestJSON`**: it accepts only exactly
`200`, not `2xx`.

### 5.12 E12 — `finger/spi` (buvid3 fallback)

```
GET https://api.bilibili.com/x/frontend/finger/spi
```
`LRA:32-33`, empty `Cookie:` header, standard §2.2 headers. Response:
`data.b_3` (String, non-empty) else `invalidResponse` (`LRA:34-37`).

Note only `b_3` is read; `b_4` (buvid4) is **NOT IN SOURCE**.

### 5.13 E13 — `getDanmuInfo` (WBI-signed)

```swift
let query = signer.sign(["id": String(roomID), "type": "0", "web_location": "444.8"])
```
`LRA:63`, sent to
`https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo` (`LRA:65`)
with the cookie header that includes the appended `buvid3` when it was missing
(`LRA:61-62`, `LRA:66`).

The signed query consists of the three parameters plus `wts` plus `w_rid`
(§6), in ascending key order:
`id, type, w_rid, web_location, wts` (`DP:283-284`).

Response (`LRA:67-74`):

| JSON path | Type | Use |
|---|---|---|
| `data.token` | String | `DanmakuConnectInfo.token`; sent as the danmaku auth frame key (`DC:66-68`) |
| `data.host_list` | array of objects | required |
| `data.host_list[].host` | String | `DanmakuServer.host`; entries without it are dropped (`LRA:70`) |
| `data.host_list[].wss_port` | NSNumber | `DanmakuServer.port`, defaulting to **443** (`LRA:71`) |

Missing `data`, `token` or `host_list`, or an empty server list →
`invalidResponse` (`LRA:67-73`).

Callers: `DanmakuClient.session` (`DC:56-57`), probe check `danmakuInfo`
(`AP:72-76`).

### 5.14 E14 — `msg/send` (danmaku)

```
POST https://api.live.bilibili.com/msg/send
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
```
Body, **in this exact order** (`LRA:84-91`):

| # | Field | Value | Source |
|---:|---|---|---|
| 1 | `bubble` | `0` | `LRA:85` |
| 2 | `msg` | the text | `LRA:85` |
| 3 | `color` | `16777215` | `LRA:85` |
| 4 | `mode` | `1` | `LRA:85` |
| 5 | `room_type` | `0` | `LRA:85` |
| 6 | `jumpfrom` | `0` | `LRA:86` |
| 7 | `reply_mid` | reply target uid or `"0"` | `LRA:82`, `LRA:86` |
| 8 | `reply_attr` | `0` | `LRA:86` |
| 9 | `replay_dmid` | target danmaku id or `""` | `LRA:83`, `LRA:86` |
| 10 | `reply_dmid` | same value (sic) | `LRA:87` |
| 11 | `statistics` | `{"appId":100,"platform":5}` | `LRA:88` |
| 12 | `fontsize` | `25` | `LRA:88` |
| 13 | `rnd` | `Int(Date().timeIntervalSince1970)` — **seconds, not ms** | `LRA:89` |
| 14 | `roomid` | `String(roomID)` | `LRA:89` |
| 15 | `csrf` | `bili_jct` | `LRA:90` |
| 16 | `csrf_token` | same value | `LRA:90` |

The `replay_dmid`/`reply_dmid` duplication is deliberate: the source comment at
`LRA:77-79` says the web room sends `replay_dmid` and LiveHime for Windows names
it `reply_dmid`, so both are sent.

`statistics` is a literal in a raw string (`#"{"appId":100,"platform":5}"#`,
`LRA:88`) — quotes are part of the value and must be percent-encoded (§7.3).

The response body is discarded; only the envelope checks apply (`LRA:92-93`).

### 5.15 E15 — `Room/update` (title)

```
POST https://api.live.bilibili.com/room/v1/Room/update
```
Body order (`LRA:100-101`): `room_id`, `title`, `csrf`, `csrf_token`. The title
is trimmed by `SessionCoordinator.updateTitle` and an empty title returns without
a request (`SC:269-275`).

### 5.16 E16 — `IsUserIdentifiedByFaceAuth`

```
POST https://api.live.bilibili.com/xlive/app-blink/v1/preLive/IsUserIdentifiedByFaceAuth
```
Body order (`LRA:118`): `room_id`, `csrf`, `csrf_token`. The source comment at
`LRA:107` states the endpoint answers POST only (GET returned 405 as of the
comment's date).

Response: the raw `root["data"]` is returned (`LRA:119`) and interpreted by
`identified(_:)` (`LRA:122-131`): walk every key of the object; only keys whose
lower-cased name contains `identif`, contains `is_face`, or equals `is_auth` or
`face_auth` count (`LRA:126`); a `true` Bool or an `NSNumber` with `intValue == 1`
means verified (`LRA:127-128`); otherwise `false`. A non-object value is truthy
only when it is literally `true` (`LRA:123`).

### 5.17 E17–E20 — room moderation

All four are `POST` with `Content-Type: application/x-www-form-urlencoded;
charset=UTF-8` and share the same envelope handling.

| ID | Path | Body order |
|---|---|---|
| E17 | `/xlive/web-ucenter/v1/banned/AddSilentUser` | `room_id`, `tuid`, `mobile_app`=`web`, `type`=`1`, `hour`, `csrf`, `csrf_token`, `visit_id`=`""` (`LRA:139-141`) |
| E18 | `/xlive/web-ucenter/v1/banned/GetShieldKeywordList` | `room_id`, `csrf`, `csrf_token` (`LRA:148`) |
| E19 | `/xlive/web-ucenter/v1/banned/AddShieldKeyword` | `room_id`, `keyword`, `csrf`, `csrf_token` (`LRA:157-158`) |
| E20 | `/xlive/web-ucenter/v1/banned/DelShieldKeyword` | same as E19 (`LRA:154-158`) |

E19/E20 are one call site: `let path = add ? "AddShieldKeyword" : "DelShieldKeyword"`
(`LRA:154`), interpolated into the URL (`LRA:155`).

* `hours`: `-1` permanent, `0` the current live session, otherwise hours
  (`LRA:134`); passed through as a decimal string (`LRA:140`).
* `visit_id` is sent as an **empty value** (`LRA:141`).
* E18 response parsing (`LRA:149`, `LRA:163-178`): walk the payload; an object
  with a non-empty string `keyword` contributes it and is **not** recursed into
  (`LRA:167`); arrays contribute non-empty plain strings directly, other elements
  are recursed (`LRA:169-172`); object keys are visited in sorted order
  (`LRA:168`); duplicates are removed preserving first-seen order (`LRA:176-177`).

### 5.18 E21–E23 — page loads (probe only)

`ApiProbe.run` loads three official pages with `pageLoads` (`AP:80-84`,
`AP:132-139`):

| ID | URL (verbatim) |
|---|---|
| E21 | `https://live.bilibili.com/p/html/live-pc-blink/mini-login-v2/` |
| E22 | `https://live.bilibili.com/p/html/live-pc-blink/hime-live-cover/` |
| E23 | `https://live.bilibili.com/p/html/bilili-page-face-auth/index.html` |

`pageLoads` sets **only** the User-Agent (`BilibiliWeb.userAgent`, `AP:134`), no
`Cookie`, `Accept`, `Referer` or `Origin`. It requires HTTP status exactly `200`
(`AP:154-156`) and a body of **more than 200 bytes** (`AP:137`), else the check
fails with `"empty page"`.

The same pages are opened in a real WebView elsewhere: `WL:17`
(`mini-login-v2/`), `BilibiliPageWindow.swift:402` (`bilili-page-face-auth/
index.html`, with query items added there) and `BilibiliPageWindow.swift:422`
(`hime-live-cover/?pc_ui=680,566,0,1`). Those are browser navigations, not part
of this HTTP layer, and are out of scope except as URLs to keep.

### 5.19 A1 — `msg/send` (sticker)

Same URL and headers as E14 (`EM:137-138`). Body order (`EM:128-136`):
`bubble`, `msg` (= the `emoticon_unique`), `color`, `mode`, `room_type`,
`jumpfrom`, `reply_mid`, `reply_attr`, `replay_dmid`, `reply_dmid`, **`dm_type`=`1`**,
**`emoticonOptions`=`[object Object]`** (a literal, `EM:132`), `statistics`,
`fontsize`, `rnd`, `roomid`, `csrf`, `csrf_token`.

The literal `[object Object]` is intentional: the source comment at `EM:123-124`
records that the web room posts it verbatim.

### 5.20 A2 — `GetEmoticons`

```
GET https://api.live.bilibili.com/xlive/web-ucenter/v2/emoticon/GetEmoticons?platform=pc&room_id=<roomID>
```
`EM:99-102`. Response (`EM:38-58`): `data.data[]` packs; per pack
`emoticons[]` with `url` (non-empty, required), `emoticon_unique` (non-empty,
required), `descript`, `emoji`, `perm` (default `1`; `!= 0` means usable),
`unlock_show_text`, `unlock_need_level`, `width`, `height`; pack-level `pkg_id`,
`pkg_name`, `pkg_type`. Packs or items without a usable image are dropped
(`EM:42-43`, `EM:53`).

### 5.21 A3 — main-site emote panel

```
GET https://api.bilibili.com/x/emote/user/panel/web?business=reply
```
`EM:107-111`. Response (`EM:66-85`): `data.packages[]`; per package `id`,
`text`, `type`, `meta.size`; per item `url` (must start with `http` or `//`),
`text` (must start with `[` and end with `]`), `meta.alias`,
`flags.no_access` / `flags.unlocked`. The sticker key is `"upower_" + text`
(`EM:76`).

### 5.22 A4/A5 — QR login

```
GET https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source=live_pc
GET https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=<key>&source=live_pc
```
`QR:48-51`, `QR:61-73`. `source` is the constant `"live_pc"` (`QR:51`), described
as matching the `origin` the official live PC login page is opened with
(`QR:50`).

Headers for both (`QR:105-111`): `Referer: https://live.bilibili.com/`,
`User-Agent: BilibiliWeb.userAgent`. **No `Cookie` header, no `Accept`,
no `Origin`.** The session is ephemeral and has cookies disabled
(`QR:57`, `QR:127-133`), so `Set-Cookie` is only read by hand for the poll
response (`QR:88-99`).

* generate reads `data.url` and `data.qrcode_key`, both non-empty
  (`QR:63-65`).
* poll reads `data.code` (`QR:74`) → `86101` waiting for scan, `86090` scanned,
  `86038` expired, `0` succeeded (`QR:77-81`); anything else →
  `QRLoginError.api(code:message:)` with `data.message` (`QR:82`).
* On success: cookies from `Set-Cookie` (`QR:90-94`) plus query items of
  `data.url` for names not already present (`QR:95-99`), `refresh_token` from
  `data.refresh_token` (`QR:100`), then `isComplete` or
  `incompleteCredentials` (`QR:101`).
* The outer envelope check requires integral `code == 0`, else
  `QRLoginError.api(code:message:)` with the **root** `message` (`QR:117-119`).

Polling cadence is owned by the coordinator: `pollInterval` default 1500 ms,
at most `maxAutoRefresh = 2` QR regenerations before `qrExpired`
(`SC:86`, `SC:368-378`).

### 5.23 A6–A10 — cookie maintenance and logout

All five use `SessionMaintenance.request` (`SM:118-125`): `Cookie`, the macOS
Safari UA, `Referer: https://www.bilibili.com/`, timeout 12 s. POSTs add
`Content-Type: application/x-www-form-urlencoded` (no charset, `SM:133`) and a
body built with the **same** `urlQueryAllowed - "+&="` encoder as `BLC`
(`SM:131`).

| ID | Request | Fields (order) | Notes |
|---|---|---|---|
| A6 | `GET .../cookie/info?csrf=<bili_jct>` | — | reads `data.refresh` (Bool) and `data.timestamp` (`SM:73-75`); `refresh != true` → **no** renewal (`SM:74`) |
| A7 | `GET https://www.bilibili.com/correspond/1/<hex>` | — | `<hex>` = lower-case hex of RSA-OAEP(SHA-256) of `"refresh_<timestampMs>"` under the embedded modulus (`SM:21`, `SM:49-56`); response is HTML, parsed for `<div id="1-name">([^<]+)</div>` (`SM:58-63`) |
| A8 | `POST .../cookie/refresh` | `csrf`, `refresh_csrf`, `source`=`main_web`, `refresh_token` | new cookies from `Set-Cookie` (`SM:89-91`); `data.refresh_token` (`SM:92`); the renewal is rejected unless `isComplete`, the token is non-empty, **and `SESSDATA` changed** (`SM:94-96`) |
| A9 | `POST .../confirm/refresh` | `csrf`, `refresh_token` (the **previous** token) | retires the old token after the new login is saved (`SM:101-106`, `SC:172-179`) |
| A10 | `POST https://passport.bilibili.com/login/exit/v2` | `biliCSRF`=<bili_jct> | note the different field name (`SM:113`) |

`SessionMaintenance.send` maps **any** failure — transport, non-2xx,
non-JSON, or `code != 0` — to `SessionRefreshError.step(<step name>)`
(`SM:138-143`); the Bilibili `code` is never inspected here. Step names in use:
`"cookieInfo"`, `"correspond"`, `"cookieRefresh"`, `"confirmRefresh"`,
`"logout"` (`SM:72`, `SM:150`, `SM:87`, `SM:105`, `SM:113`) plus
`"noRefreshToken"`, `"encrypt"`, `"refreshCSRF"`, `"cookieRefreshResult"`
(`SM:76`, `SM:78`, `SM:80`, `SM:95`).

Maintenance runs only when the room is not live, at most one at a time, every
12 hours by default (`SC:87`, `SC:159-166`, `SC:187-196`).

#### A11 — `correspond/0/<digest>`

The web-login window navigates a hidden iframe to
`https://www.bilibili.com/correspond/0/<digest>` to make Bilibili set the session
cookies from a login token; `digest = SHA256(hexOf("set_<timestamp>_<token>"))`,
lower-case hex (`WL:166-173`). This is a WebView navigation, not a call of this
HTTP layer, but the URL shape must exist on Windows too.

### 5.24 WS1 — danmaku socket

`wss://<host>:<wss_port>/sub` (`DC:59`), one server chosen at random from the
list returned by E13 (`DC:58`). The upgrade request sets only `User-Agent`
(`DC:60`) and `Origin: https://live.bilibili.com` (`DC:61`) — **no cookies**.
Authentication is carried in the first frame:

```swift
let auth: [String: Any] = ["uid": uid, "roomid": roomID, "protover": 3, "buvid": info.buvid,
                           "platform": "web", "type": 2, "key": info.token]
```
`DC:66-68`. Heartbeat every 30 s with the literal body `[object Object]`
(`DC:72`). A `code != 0` in the auth reply ends that connection attempt
(`DC:86-91`). Reconnect backoff: 2 s after a connection that lasted `> 60 s`,
otherwise doubling to a 30 s cap (`DC:37-48`).

---

## 6. WBI signing (E13 only)

Definition: `DP:259-286`. Used **only** by `danmakuConnectInfo`
(`LRA:62-63`). `startLive` does **not** use WBI — it uses the appkey scheme (§7).

### 6.1 Mixin key

```swift
static let mixinTable = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42,
                         19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51,
                         30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]
```
`DP:261-263` — 64 entries, verbatim.

```swift
init?(imgURL: String, subURL: String) {
    func stem(_ url: String) -> String { (url.split(separator: "/").last.map(String.init) ?? "").components(separatedBy: ".").first ?? "" }
    let raw = Array(stem(imgURL) + stem(subURL))
    guard raw.count >= 64 else { return nil }
    mixinKey = String(Self.mixinTable.map { raw[$0] }.prefix(32))
}
```
`DP:267-272`

* `stem` = the last `/`-separated component, then everything before the first `.`
  (`DP:268`).
* `raw` is the concatenation of both stems as **characters** (Swift `Character`s,
  `DP:269`); fewer than 64 characters → the initializer fails and `wbiSigner`
  throws `invalidResponse` (`LRA:52-55`).
* `mixinKey` = the 64 table entries mapped into `raw` and then truncated to the
  first **32** characters (`DP:271`).

### 6.2 Signature

```swift
func sign(_ params: [String: String], timestamp: Int = Int(Date().timeIntervalSince1970)) -> [URLQueryItem] {
    var all = params
    all["wts"] = String(timestamp)
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    let query = all.keys.sorted().map { key -> String in
        let value = all[key]!.filter { !"!'()*".contains($0) }
        return "\(key.addingPercentEncoding(withAllowedCharacters: unreserved)!)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved)!)"
    }.joined(separator: "&")
    let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8)).map { String(format: "%02x", $0) }.joined()
    return all.keys.sorted().map { URLQueryItem(name: $0, value: all[$0]!.filter { !"!'()*".contains($0) }) }
        + [URLQueryItem(name: "w_rid", value: digest)]
}
```
`DP:274-285`

Step by step, as the C++ must implement it:

1. `all = params`; add `wts = String(timestamp)` (`DP:275-276`). The default
   timestamp is the **local** wall clock in seconds (`DP:274`) — E13 does *not*
   use the server clock (contrast `startLive`, §5.8).
2. **Key order:** `all.keys.sorted()` — ascending byte/Unicode order of the keys
   (`DP:278`, `DP:283`). For E13 that is
   `id`, `type`, `web_location`, `wts` (and `w_rid` appended last,
   `DP:283-284`).
3. **Filtering:** each **value** has the five characters `!`, `'`, `(`, `)`, `*`
   removed (`DP:279`, `DP:283`). Keys are **not** filtered. The same filtered
   value is used both in the signed string and in the returned query item
   (`DP:279`, `DP:283`).
4. **Encoding for the signed string:** each value is percent-encoded with the
   strict RFC 3986 unreserved set
   `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~`
   (`DP:277`, `DP:280`). Nothing else is escaped-preserved: `.`, `_`, `-`, `~`
   stay literal; space, `/`, `:` and every non-ASCII character become `%XX`
   upper-case hex (Swift `addingPercentEncoding` emits upper-case). Keys are not
   encoded in the signed string.
5. **Joined** with `&` as `key=value` in sorted-key order (`DP:278-281`).
6. **Hash:** `MD5((query + mixinKey).utf8)` rendered as **lower-case** hex
   (`DP:282`; `Insecure.MD5` = CryptoKit MD5; the Windows replacement is BCrypt
   `BCRYPT_MD5_ALGORITHM`, `WIN:104`).
7. **Output:** the same sorted items with filtered values, plus a final
   `w_rid=<digest>` item (`DP:283-284`).

### 6.3 Golden vector (from the test suite)

`Tests/LiveHimeCoreTests/DanmakuProtocolTests.swift:169-175` pins the algorithm:

* `img_url` = `https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png`
* `sub_url` = `https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png`
* mixin key = `ea1db124af3c7062474693fa704f4ff8`
* params `{id: "1001", type: "0", web_location: "444.8"}`, timestamp
  `1700000000` → `w_rid` = `6a7b397a3b98a73cebbca7b826767240`

A Windows implementation must reproduce this vector byte-for-byte. Note that
`444.8` contains a `.` which is unreserved, so the signed string is
`id=1001&type=0&web_location=444.8&wts=1700000000` + mixinKey (DERIVED from the
sort and encode rules above).

### 6.4 Where the keys come from

`wbi_img` is read from E11 nav, at the `wbiSigner` call site, without any code
check (`LRA:51-55`). The probe's nav check *requires* `data.wbi_img` to exist for
its own success (`AP:126`).

---

## 7. The `startLive` appkey/csrf/`sign` scheme

### 7.1 Algorithm

```
unsigned = formString(values)                       // BLC:280
sign     = md5_hex(unsigned + "af125a0d5279fd576c1b4418a3e8276d")   // BLC:281
```

* `appkey` is the literal `aae92bc66f3edfab` (`BLC:275`).
* The salt is the literal `af125a0d5279fd576c1b4418a3e8276d` (`BLC:281`).
* The digest is MD5, rendered **lower-case** hex (`BLC:507-509`:

```swift
private func md5Hex(_ string: String) -> String {
    Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}
```
).
* `formString` percent-encodes both key and value with
  `CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))`
  and joins with `&` (`BLC:502-505`) — see §7.3.
* There is **no** `w_rid`/`wts` in this request; `ts` is an ordinary signed field
  (`BLC:277`). `csrf` is a plain field (`BLC:276`).

### 7.2 `ts`

`fetchServerTimestamp` (§5.10) returns `data.now` from E10 as a decimal string,
else `String(Int(Date().timeIntervalSince1970))` (`BLC:476-488`).

### 7.3 Form / query encoding

```swift
private func formString(_ values: [(String, String)]) -> String {
    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
    return values.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }.joined(separator: "&")
}
```
`BLC:502-505`

* Pairs keep **array order** — never sorted (`BLC:504`). This is what makes the
  `startLive` signature order-sensitive.
* The allowed set is Foundation's `urlQueryAllowed` minus `+`, `&`, `=`. The
  composition of `CharacterSet.urlQueryAllowed` itself is **NOT IN SOURCE** (it
  is Foundation's). **DERIVED** from Apple's documented composition
  (`urlQueryAllowed = urlPathAllowed + "?"`,
  `urlPathAllowed = urlUnreserved + "%!$&'()*+,-./:;=@"`), the effective set is
  `ALPHA DIGIT - . _ ~ % ! $ ' ( ) * , / : ; @ ?` — i.e. `+`, `&`, `=` and every
  character outside that list (space, `"`, `#`, `[`, `]`, `{`, `}`, `|`, `\`,
  `^`, `` ` ``, `<`, `>`, and all non-ASCII) are percent-encoded.
* **DERIVED** golden expectations for the two literals that are not trivially
  safe. These must be confirmed by a capture before shipping:

| Input value | Encoded |
|---|---|
| `{"appId":100,"platform":5}` | `%7B%22appId%22%3A100%2C%22platform%22%3A5%7D` |
| `[object Object]` | `%5Bobject%20Object%5D` |

* The URL for the GET endpoints is assembled differently — by `URLComponents`
  (`BLC:385`):

```swift
func withQuery(_ url: URL, _ query: [URLQueryItem]) -> URL { var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!; c.queryItems = query; return c.url! }
```

`URLComponents.queryItems` **replaces** any pre-existing query and applies
Foundation's own query-component encoding, which differs from `formString`. For
every value used in this codebase (decimal ids, hex tokens, `pc_link`,
`444.8`, `live_pc`, `reply`, `pc`, `2`, `0`) the two encoders agree. For values
containing `+` they may not (Foundation may emit a literal `+`, which servers
decode as a space) — **NOT IN SOURCE**, flagged in §13.

---

## 8. Response → model mapping (compiled)

### 8.1 Models

| Model | Fields | Source |
|---|---|---|
| `BilibiliRoomInfo` | `roomID`, `uid`, `shortRoomID`, `title`, `liveStatus`, `areaID` | `BLC:5-20` |
| `BilibiliLiveArea` | `areaID`, `parentAreaID`, `name`, `parentName` | `BLC:22-30` |
| `BilibiliStreamConfig` | `server: URL`, `key: String`; `address` = `server.absoluteString`, `code` = `key` | `BLC:51-66` |
| `BilibiliLiveVersion` | `version: String`, `build: Int` | `BLC:68-72` |
| `BilibiliIdentity` | `mid: Int64`, `username: String`, `isLogin: Bool` | `BCC:4-14` |
| `DanmakuConnectInfo` | `token`, `servers: [DanmakuServer]`, `buvid` | `LRA:8-12` |
| `DanmakuServer` | `host: String`, `port: Int` | `LRA:3-6` |
| `EmoticonPack` / `Emoticon` | see `EM:8-33` | `EM:8-33` |
| `SessionCredentials` | `cookies`, `refreshToken`, `savedAt` | `QR:6-27` |
| `LiveAccount` | `mid`, `username`, `room` | `SC:3-7` |

`LiveAccount` is what reaches the UI as `{"state":"ready", "mid", "username",
"roomId", "shortRoomId", "title", "liveStatus", "areaId"}` (`CB:115-123`).

### 8.2 Field-by-field

| Endpoint | JSON path | Coercion | Model / use | Cite |
|---|---|---|---|---|
| E1/E7 | `data` | object | container | `BLC:377`, `BLC:246` |
| E1 | `data.room_info` | object | preferred container | `BLC:378` |
| E1 | `<d>.room_id` \| `<d>.roomid` | int64, `> 0` | `roomID` | `BLC:381` |
| E1 | `<d>.uid` | int64 | `uid` | `BLC:382` |
| E1 | `<d>.short_id` | int64 | `shortRoomID` | `BLC:382` |
| E1 | `<d>.title` \| `<d>.roomname` | String | `title` | `BLC:382` |
| E1 | `<d>.live_status` \| `<d>.liveStatus` | int | `liveStatus` | `BLC:382` |
| E1 | `<d>.area_v2_id` \| `<d>.area_id` | int | `areaID` | `BLC:382` |
| E7 | `data.room_id` | int64, must `== roomID` | `roomID` | `BLC:247` |
| E7 | `data.uid` | int64 | `uid` | `BLC:255` |
| E7 | `data.short_id` | int64 | `shortRoomID` | `BLC:256` |
| E7 | `data.title` | String | `title` | `BLC:257` |
| E7 | `data.live_status` \| `liveStatus` | int, must be in `0,1,2` | `liveStatus` | `BLC:248-249` |
| E7 | `data.area_v2_id` \| `data.area_id` | int | `areaID` | `BLC:259` |
| E2 | `data.room_id` \| root `room_id` | int64, `> 0` | room id | `BLC:140-142` |
| E3 | `data` (array or object) | — | area tree root | `BLC:150-182` |
| E3 | `id` \| `area_id` | int64, `> 0` | `areaID` | `BLC:185` |
| E3 | `name` \| `area_name` | String, required | `name` | `BLC:185` |
| E3 | `parent_id` \| `parent_area_id` | int64 | `parentAreaID` | `BLC:186` |
| E3 | `parent_name` \| `parent_area_name` | String | `parentName` | `BLC:186` |
| E4 | `data` \| root | object | container | `BLC:198` |
| E4 | `curr_version` \| `version` | String, non-empty | `version` | `BLC:199` |
| E4 | `build` | int, `> 0` | `build` | `BLC:200-201` |
| E5/E8 | `data` | object | container | `BLC:355` |
| E5/E8 | `addr` \| `server` \| `rtmp_addr` | String, non-empty | `server` | `BLC:337` |
| E5/E8 | `code` \| `key` \| `stream_code` | String, non-empty | `key` | `BLC:338` |
| E5/E8 | `rtmp`, `protocols[].protocol` | — | candidate order | `BLC:357-361` |
| E5/E8 | `need_face_auth`, `qr`, `risk_extra.v_voucher` | see §9.3 | face auth | `BLC:322-331` |
| E10 | `data.now` | int64, `> 0` | `ts` | `BLC:482-485` |
| E11 | `data.isLogin` | Bool, required | log-in flag | `BCC:77` |
| E11 | `data.mid` | Int64/NSNumber, `> 0` | `mid` | `BCC:81-85` |
| E11 | `data.uname` | String, default `""` | `username` | `BCC:87` |
| E11 | `data.wbi_img.img_url`, `.sub_url` | String, default `""` | WBI key stems | `LRA:52-53` |
| E11 | `code` | integer | `0`/`-101` accepted by the probe | `AP:124-129` |
| E12 | `data.b_3` | String, non-empty | `buvid` | `LRA:34-36` |
| E13 | `data.token` | String, required | danmaku key | `LRA:67` |
| E13 | `data.host_list[].host` | String, required per entry | `DanmakuServer.host` | `LRA:70` |
| E13 | `data.host_list[].wss_port` | NSNumber, default `443` | `DanmakuServer.port` | `LRA:71` |
| E16 | `data` | any | `identified(_:)` | `LRA:119`, `LRA:122-131` |
| E18 | `keyword`, plain strings | String, non-empty | keyword list | `LRA:163-178` |
| A2 | see §5.20 | — | emoticon packs | `EM:38-58` |
| A3 | see §5.21 | — | emoticon packs | `EM:66-85` |
| A4 | `data.url`, `data.qrcode_key` | String, non-empty | QR url/key | `QR:63-65` |
| A5 | `data.code` | int | poll state | `QR:74-82` |
| A5 | `data.url` | String (query items) | fallback cookies | `QR:95-99` |
| A5 | `data.refresh_token` | String, default `""` | `refreshToken` | `QR:100` |
| A6 | `data.refresh` | Bool | renewal due? | `SM:74` |
| A6 | `data.timestamp` | NSNumber int64 | correspond path | `SM:75` |
| A8 | `data.refresh_token` | String, `""` fails later | new token | `SM:92-96` |

### 8.3 `liveStatus` semantics

`1` is live, anything else is treated as not live by the UI text and by
`maintainSession` (`SC:161`); the probe formats `1` as `"live"` and everything
else as `"offline"` (`AP:70`).

---

## 9. Error and `code` handling

### 9.1 `BilibiliLiveError` (the main enum)

```swift
public enum BilibiliLiveError: Error, Equatable {
    case invalidResponse
    case api(code: Int, message: String)
    case missingCSRF
    case missingRoom
    case transport
    case network(code: Int)
    case http(status: Int, retryAfterSeconds: Int?)
    case notLoggedIn
    case missingStreamConfig
    case faceAuthRequired(voucher: String?)
    /// Pre-live face verification by QR code: scan `url` with the Bilibili app.
    case faceAuthQR(url: String)
}
```
`BLC:74-87`

Mapping inside `requestJSON` (`BLC:428-437`):

| Bilibili `code` | Thrown | Diagnostic kind |
|---|---|---|
| `-101` | `.notLoggedIn` | `.auth` |
| `60043` | `.faceAuthQR` or `.faceAuthRequired` (see §9.3, `required: true`) | `.faceAuth` |
| `60024` | same | `.faceAuth` |
| any other `!= 0` | `.api(code:message:)` | `.api` |

The message is `root["message"]`, else `root["msg"]`, else the literal:

```swift
"Bilibili 接口返回失败"
```
`BLC:436-437`

The static `parseStreamConfig(from:)` applies the same three code rules but throws
`invalidResponse` when `code` is absent (`BLC:299-310`); it is used by tests only
(no production caller: `Sources` grep shows only `BLC:299` itself).

### 9.2 `BilibiliControlError`

`BCC:16-22`. In `fetchIdentity`: `-101` → `.notLoggedIn` (`BCC:74`);
`isLogin == false` → `.notLoggedIn` (`BCC:80`); any other non-zero code →
`.api(code:message:)` with the **fixed literal**

```swift
"身份接口返回失败"
```
`BCC:75` — the response's own `message` is **not** used. Missing/invalid `mid` →
`.invalidResponse` (`BCC:85`).

### 9.3 Face verification

`faceAuthError(_:required:)` (`BLC:321-332`):

* `flagged` = `data.need_face_auth` is `true` **or** is an `NSNumber` whose
  `intValue == 1` (`BLC:322-325`).
* If `data.qr` is a non-empty String **and** (`flagged || required`) →
  `.faceAuthQR(url:)` (`BLC:326-328`). The QR URL is shown natively on macOS
  (`H:42-45`).
* `voucher` = `data.risk_extra.v_voucher` (String, optional, `BLC:329`).
* If `required || flagged` → `.faceAuthRequired(voucher:)` (`BLC:330`).
* Otherwise `nil` — a payload with neither flag nor requirement is not an error
  (`BLC:331`).

`required: true` is passed for codes `60043`/`60024` at `BLC:305` and `BLC:434`;
those two call sites force-unwrap the result (`!`), which is safe because
`required: true` always returns non-nil (`BLC:330`). A C++ port must make that
non-null guarantee explicit.

`LiveRoomActions.faceAuthData` (`LRA:113-120`) exposes the raw `data` for the
probe, which prints the sorted field names so a response-shape change is visible
(`AP:90-95`).

### 9.4 Error → C bridge JSON

`CoreBridge.errorFields` (`CB:194-218`) is the authoritative translation:

| Swift error | JSON |
|---|---|
| `.faceAuthRequired(voucher)` | `{"kind":"faceAuth"[,"voucher":…]}` |
| `.faceAuthQR(url)` | `{"kind":"faceAuthQR","qr":…}` |
| `.notLoggedIn` (either enum) | `{"kind":"sessionExpired"}` |
| `.missingRoom` | `{"kind":"noLiveRoom"}` |
| `.api(code:message:)` | `{"kind":"api","code":…,"message":…}` |
| `.http(status:…)` | `{"kind":"http","code":<status>}` |
| `SessionCoordinator.LiveError.notReady` | `{"kind":"notReady"}` |
| `.missingStreamConfig` | `{"kind":"server","message":"missingStreamConfig"}` |
| anything else | `{"kind": "network"|"server", "message": "\(error)"}` |

`{"event":"liveError", …}` fields are merged into that object (`CB:252`).

### 9.5 Session-rejection semantics

`SessionCoordinator.isSessionRejected` treats only `BilibiliControlError.notLoggedIn`
and `BilibiliLiveError.notLoggedIn` as a rejected login (`SC:419-421`); those
delete the stored credentials and move to `signedOut(.sessionExpired)`
(`SC:320-324`, `SC:407-410`). Every other error leaves the credentials in place
and reports `failed` (`SC:411-413`, `SC:23-25`). **The port must preserve this**:
a transient network error must never sign the user out.

`SessionNotice` values available to the UI: `sessionExpired`,
`legacyNeedsLogin`, `qrExpired`, `noLiveRoom`, `network`, `server`, `keychain`
(`SC:10-18`), mapped from errors by `SC:423-435`.

---

## 10. Public API surface

### 10.1 Swift (the shape the C++ core must provide)

| Declaration | Signature | Cite |
|---|---|---|
| `BilibiliLiveClient.init` | `init(session: URLSession = .shared, diagnostics: BilibiliDiagnosticStore? = nil)` | `BLC:97` |
| `BilibiliLiveClient.init` | `init(cookieHeader: String, biliJct: String? = nil, session: URLSession = .shared, endpoints: BilibiliLiveEndpoints = .init(), diagnostics: BilibiliDiagnosticStore? = nil)` | `BLC:98-99` |
| `fetchCurrentRoom` | `func fetchCurrentRoom(mid: Int64) async throws -> BilibiliRoomInfo` | `BLC:107` |
| `resolveRoomIDByUID` | `func resolveRoomIDByUID(mid: Int64) async throws -> Int64` | `BLC:134` |
| `fetchAreas` | `func fetchAreas(parentID: Int64? = nil, platform: String = "pc_link") async throws -> [BilibiliLiveArea]` | `BLC:146` |
| `fetchLiveVersion` | `func fetchLiveVersion() async throws -> BilibiliLiveVersion` | `BLC:192` |
| `fetchUpstream` | `func fetchUpstream(roomID: Int64? = nil) async throws -> BilibiliStreamConfig` | `BLC:205` |
| `resolveCurrentRoom` | `func resolveCurrentRoom(cookieHeader: String) async throws -> Int64` | `BLC:212` |
| `fetchRoomInfo` | `func fetchRoomInfo(roomID: Int64, cookieHeader: String) async throws -> BilibiliRoomInfo` | `BLC:242` |
| `startLive` | `func startLive(roomID: Int64, areaID: Int, parentAreaID: Int64 = 0, cookieHeader: String) async throws -> BilibiliStreamConfig` | `BLC:263` |
| `stopLive` | `func stopLive(roomID: Int64, cookieHeader: String) async throws` | `BLC:290` |
| `parseStreamConfig` (static) | `static func parseStreamConfig(from data: Data) throws -> BilibiliStreamConfig` | `BLC:299` |
| `faceAuthError` (internal) | `static func faceAuthError(_ data: [String: Any]?, required: Bool) -> BilibiliLiveError?` | `BLC:321` |
| `retryAfterSeconds` (internal) | `static func retryAfterSeconds(_ value: String?, now: Date = Date()) -> Int?` | `BLC:463` |
| `csrf` (internal) | `func csrf(from cookieHeader: String) throws -> String` | `BLC:490` |
| `buvid3` (internal) | `func buvid3(cookieHeader: String) async throws -> String` | `LRA:30` |
| `wbiSigner` (internal) | `func wbiSigner(cookieHeader: String) async throws -> WBISigner` | `LRA:42` |
| `danmakuConnectInfo` | `func danmakuConnectInfo(roomID: Int64, cookieHeader: String) async throws -> DanmakuConnectInfo` | `LRA:59` |
| `sendDanmaku` | `func sendDanmaku(roomID: Int64, text: String, reply: DanmakuReply? = nil, cookieHeader: String) async throws` | `LRA:80` |
| `updateTitle` | `func updateTitle(roomID: Int64, title: String, cookieHeader: String) async throws` | `LRA:96` |
| `isIdentifiedByFaceAuth` | `func isIdentifiedByFaceAuth(roomID: Int64, cookieHeader: String) async throws -> Bool` | `LRA:108` |
| `faceAuthData` (internal) | `func faceAuthData(roomID: Int64, cookieHeader: String) async throws -> Any?` | `LRA:113` |
| `identified` (internal) | `static func identified(_ value: Any?) -> Bool` | `LRA:122` |
| `muteUser` | `func muteUser(roomID: Int64, uid: Int64, hours: Int, cookieHeader: String) async throws` | `LRA:135` |
| `shieldKeywords` | `func shieldKeywords(roomID: Int64, cookieHeader: String) async throws -> [String]` | `LRA:144` |
| `setShieldKeyword` | `func setShieldKeyword(roomID: Int64, keyword: String, add: Bool, cookieHeader: String) async throws` | `LRA:152` |
| `emoticons` | `func emoticons(roomID: Int64, cookieHeader: String) async throws -> [EmoticonPack]` | `EM:98` |
| `mainSiteEmoticons` | `func mainSiteEmoticons(cookieHeader: String) async throws -> [EmoticonPack]` | `EM:107` |
| `allEmoticons` | `func allEmoticons(roomID: Int64, cookieHeader: String) async throws -> [EmoticonPack]` | `EM:117` |
| `sendEmoticon` | `func sendEmoticon(roomID: Int64, unique: String, reply: DanmakuReply? = nil, cookieHeader: String) async throws` | `EM:125` |
| `BilibiliControlClient.fetchIdentity` | `func fetchIdentity(cookieHeader: String) async throws -> BilibiliIdentity` | `BCC:33` |
| `QRLoginClient.generate` | `func generate() async throws -> (url: String, key: String)` | `QR:61` |
| `QRLoginClient.poll` | `func poll(key: String) async throws -> QRLoginPoll` | `QR:69` |
| `SessionMaintenance.refreshIfNeeded` | `func refreshIfNeeded(_ current: SessionCredentials) async throws -> SessionCredentials?` | `SM:68` |
| `SessionMaintenance.confirm` | `func confirm(renewed: SessionCredentials, previousRefreshToken: String) async throws` | `SM:101` |
| `SessionMaintenance.logout` | `func logout(_ current: SessionCredentials) async throws` | `SM:110` |
| `ApiProbe.run` | `static func run(room requested: Int64, report: @escaping (Result) -> Void) async` | `AP:19` |

Every network method is `async throws` and there is **no** synchronous variant
anywhere in this layer. The only synchronous entry points are the C functions
(§10.2).

The `BilibiliAccountAPI` protocol (`SC:35-56`) is the seam used by tests; a C++
port should keep an equivalent interface so the state machine can be tested
without the network.

### 10.2 C ABI (what the Qt plugin calls)

The plugin calls 35 `livehime_core_*` functions declared in `H` and implemented
in `CB`; the ones that reach this HTTP layer are:

| C function | Marshalling | Async result |
|---|---|---|
| `void livehime_core_start(const char *keychain_service, livehime_state_callback callback, void *context)` | `H:17` | builds the coordinator, then `restore()` (`CB:144-159`) |
| `void livehime_core_start_qr_login(void)` | `H:20` | `coordinator.startQRLogin()` (`CB:172-173`) |
| `void livehime_core_cancel_qr_login(void)` | `H:21` | cancels the poll task (`CB:175-176`) |
| `void livehime_core_retry(void)` | `H:22` | verify saved, else new QR (`CB:178-179`, `SC:124-132`) |
| `void livehime_core_sign_out(void)` | `H:23` | local removal then best-effort A10 (`CB:181-182`, `SC:134-154`) |
| `void livehime_core_start_web_login(void)` | `H:26` | opens the login WebView (`CB:372-380`) |
| `void livehime_core_load_areas(void)` | `H:34` | emits `areas` / `areasFailed` (`CB:225-238`) |
| `void livehime_core_start_live(long long area_id, long long parent_area_id)` | `H:35` | emits `streamEndpoint` / `liveError` (`CB:242-256`) |
| `void livehime_core_stop_live(void)` | `H:36` | emits `liveStopped` (`CB:259-272`) |
| `void livehime_core_send_danmaku(const char *text)` | `H:110` | forwards to the reply variant with `0, NULL` (`CB:276-279`) |
| `void livehime_core_send_danmaku_reply(const char *text, long long reply_uid, const char *reply_danmaku_id)` | `H:113` | emits `danmakuSent` (`CB:281-297`) |
| `void livehime_core_update_title(const char *title)` | `H:117` | emits `titleUpdated` (`CB:299-313`) |
| `void livehime_core_send_emoticon(const char *key, long long reply_uid, const char *reply_danmaku_id)` | `H:116` | emits `danmakuSent` with `"sticker":true` (`EM:285-303`) |
| `void livehime_core_emoticons_load(void)` | `H:128` | emits `emoticons` (`EM:252-267`) |
| `void livehime_core_emoticon_image(const char *url)` | `H:129` | emits `emoticonImage` (`EM:271-281`) |
| `void livehime_core_mute_user(long long uid, int hours)` | `H:134` | emits `userMuted` (`CB:322-335`) |
| `void livehime_core_load_shield_keywords(void)` | `H:135` | emits `shieldKeywords` (`CB:337-350`) |
| `void livehime_core_set_shield_keyword(const char *keyword, int add)` | `H:136` | emits `shieldKeywords` after a reload (`CB:353-368`) |
| `void livehime_core_probe_run(long long room)` | `H:100` | emits `probe` running/per-check/done (`AP:177-195`) |
| `void livehime_core_open_face_auth(const char *voucher)` | `H:41` | page only (`BilibiliPageWindow.swift:431`) |
| `void livehime_core_open_face_auth_qr(const char *url)` | `H:45` | page only (`BilibiliPageWindow.swift:525`) |
| `void livehime_core_open_cover_page(void)` | `H:49` | page only (`BilibiliPageWindow.swift:446`) |

Contract rules that must be preserved (`H:3-8`, `CB:134-140`):

* Called on the main thread; the implementation hops to the main thread with
  `onMain` if it is not already there (`CB:134-140`).
* Every function returns `void` immediately; **no C entry point blocks on the
  network** (`CB:229-236` etc. start a `Task`). The C++ port must keep this —
  the UI thread is the Qt main thread.
* Results and failures arrive as JSON through the single
  `livehime_state_callback` registered at `livehime_core_start`, with
  `JSONSerialization` `.sortedKeys` (`CB:189`, `CB:129`).

### 10.3 Event JSON shapes (verbatim field names)

| Event | Shape | Cite |
|---|---|---|
| state | `{"state":"signedOut"\|"qrCode"\|"verifying"\|"ready"\|"failed", …}` | `CB:103-131`, `H:5-8` |
| ready state | `{"state":"ready","mid","username","roomId","shortRoomId","title","liveStatus","areaId"}` | `CB:115-123` |
| areas | `{"event":"areas","areas":[{"id","parentId","name","parentName"}]}` | `CB:220-222`, `H:30` |
| stream | `{"event":"streamEndpoint","server","key"}` | `CB:250`, `H:31` |
| error | `{"event":"liveError","kind":…}` + `errorFields` | `CB:252`, `CB:194-218` |
| stopped | `{"event":"liveStopped","ok":true\|false}` | `CB:266-268` |
| danmaku sent | `{"event":"danmakuSent","ok":true[,"sticker":true]}` | `CB:291`, `EM:296` |
| title | `{"event":"titleUpdated","ok":true\|false}` | `CB:307-309` |
| mute | `{"event":"userMuted","ok","uid"}` | `CB:329-331` |
| keywords | `{"event":"shieldKeywords","ok","keywords":[…]}` | `CB:344-346` |
| emoticons | `{"event":"emoticons","ok":true,"room","packs":[{"id","name","large","items":[{"key","text","name","url","w","h","inline","usable","hint"}]}]}` | `EM:240-245`, `EM:260` |
| emoticon image | `{"event":"emoticonImage","url","path"}` (`path` empty on failure) | `EM:277` |
| probe | `{"event":"probe","status":"running"}` → per check `{"event":"probe","check","result":"ok\|fail\|skip","detail","ms"}` → `{"event":"probe","status":"done","passed","failed","skipped"}` | `AP:182-191` |
| session maintenance | `{"event":"sessionMaintenance","result":"notNeeded"\|"refreshed"\|"skippedWhileLive"\|"failed:<step>"}` | `CB:27`, `SC:70-71`, `SC:168-184` |

`sessionMaintenance` is wired at `CB:27` but is **not** documented in
`H` — **NOT IN SOURCE** (header omission, still emitted).

Probe check ids, in order: `nav`, `buvid`, `areas`, `liveVersion`, `qrcode`,
`roomInfo`, `danmakuInfo`, `danmakuSocket`, `loginPage`, `coverPage`,
`faceAuthPage`, `myRoom`, `faceAuthState`, `shieldKeywords`, `emoticons`,
`mainSiteEmoticons` (`AP:47-112`). Checks needing an account are skipped with
detail `"signedOut"` (`AP:85-86`); checks needing a room are skipped with
`"noRoom"` (`AP:67-68`).

### 10.4 Emoticon image fetching (separate path)

`EmoticonImages` uses its own ephemeral `URLSession` with cookies, cache and
storage disabled, 12 s timeout, 4 connections per host (`EM:153-161`), and only
fetches `https://` URLs whose host is `hdslb.com`, `biliimg.com` or a subdomain
(`EM:168-175`). It **never** sends cookies. Images larger than 4,000,000 bytes
or non-200 responses are rejected (`EM:192-197`); the first frame is scaled to
160 px and re-encoded as PNG (`EM:203-214`); the cache lives under
`Caches/LiveHime/emoticons` with a 30 MB high-water mark trimmed to 20 MB
(`EM:164`, `EM:220`, `EM:224-237`). File name = lower-case SHA-256 hex of the URL
(`EM:178-180`). The Windows replacement for the image codec is named as
WIC/stb_image (`WIN:106`).

---

## 11. Mapping onto the official Windows endpoints

Official list: `URLS` (extracted from `bililive_secret.dll`) and the prose in
`WIN:58-79`. "Exact" means the same path+host appears in the official list.

| Our endpoint | Official counterpart | Verdict |
|---|---|---|
| E8 `/room/v1/Room/startLive` | `URLS:2` `https://api.live.bilibili.com/room/v1/Room/startLive` | **Exact match.** Parameters/authorisation are not in the official list (`WIN:79` warns the strings are not proof of parameters) |
| E9 `/room/v1/Room/stopLive` | `URLS:3` | **Exact match** |
| E5 `/xlive/app-blink/v1/live/GetUpStreamRtmp` | `URLS:56` | **Exact match** |
| E4 `/xlive/app-blink/v1/liveVersionInfo/getHomePageLiveVersion` | `URLS:63`; the official capture added `&url_type=1` (`WIN:7`) | **Match, one extra parameter missing in our call** |
| E16 `/xlive/app-blink/v1/preLive/IsUserIdentifiedByFaceAuth` | `URLS:106` | **Exact match** |
| E13 `/xlive/web-room/v1/index/getDanmuInfo` | `URLS:239` is `…/xlive/app-room/v1/index/getDanmuInfo` | **Different path** (`web-room` vs `app-room`); ours is the web-room variant. Both are named `getDanmuInfo` |
| E21 `…/mini-login-v2/` | `WIN:62` `https://live.bilibili.com/p/html/live-pc-blink/mini-login-v2` | **Exact match** (official string has no trailing slash) |
| E23 `…/bilili-page-face-auth/index.html` | `WIN:63` `https://live.bilibili.com/p/html/bilili-page-face-auth/index.html?...` | **Exact match** |
| E22 `…/hime-live-cover/` | not in `URLS`, not in `WIN` | **macOS-only** (the official cover flow uses `preLive/GetCoverAdviceAndQualityScore`, `URLS:99`) |
| E11 `x/web-interface/nav` | not in `URLS`; `WIN:168-171` shows `[login] nav user info success/failed, code=` in `bililive.dll` | **Official but unlisted** — the Windows client calls nav; the URL was not recovered from that DLL |
| E1 `room/v1/Room/getRoomInfoOld` | — | **macOS-only** (web/legacy). Nearest official: `xlive/app-blink/v1/room/GetInfo`, `URLS:130` |
| E7 `room/v1/Room/get_info` | — | **macOS-only** (web). Same nearest official as above |
| E2 `room/v2/Room/room_id_by_uid` | — | **macOS-only** (web) |
| E6 `i/api/liveinfo` | — | **macOS-only** (legacy web fallback) |
| E3 `room/v1/Area/getList` | — | **macOS-only** (web). Nearest official: `xlive/app-blink/v1/preLive/GetAreaListForLive`, `URLS:98` |
| E10 `x/report/click/now` | — | **macOS-only** (main-site clock; the official client gets time elsewhere, **NOT IN SOURCE**) |
| E12 `x/frontend/finger/spi` | — | **macOS-only** (main-site fingerprint) |
| E14/A1 `msg/send` | — | **macOS-only** (web room). The official client sends danmaku over the WebSocket/auth path; **NOT IN SOURCE** for the exact official call |
| E15 `room/v1/Room/update` | — | **macOS-only**. Nearest official: `preLive/UpdatePreLiveInfo` (`URLS:114`), `room/AnnounceCommit` (`URLS:128`) |
| E17–E20 `xlive/web-ucenter/v1/banned/*` | — | **macOS-only** (web room moderation). The official `Mute` endpoints (`URLS:78`, `URLS:151`) are voice/co-host moderation, not this |
| A2 `web-ucenter/v2/emoticon/GetEmoticons` | — | **macOS-only**. No official emote endpoint in the list |
| A3 `x/emote/user/panel/web` | — | **macOS-only** (main site) |
| A4/A5 passport QR generate/poll | — | **macOS-only HTTP**. The official Windows flow logs in through the CEF mini-login page (`WIN:44-56`, `WIN:161-173`), not through these endpoints |
| A6–A10 `cookie/info`, `correspond/1`, `cookie/refresh`, `confirm/refresh`, `login/exit/v2` | `URLS:240-245` are the **OAuth2** family (`getKey`, `v3/oauth2/login`, `v2/oauth2/access_token`, `refresh_token`, `info`, `revoke`) | **No overlap.** Our cookie-renewal flow is the web flow; the official client uses OAuth2. **macOS-only by comparison** |
| A11 `correspond/0/<digest>` | — | **macOS-only** (carried over from v0.1.2, `WL:164-166`) |
| WS1 `wss://<host>/sub` | — | **macOS-only**. The official client's danmaku transport is **NOT IN SOURCE** |

Summary: of our 34 HTTP targets, **6 are exact official matches**
(E5, E8, E9, E16, E21, E23), 1 matches with a
different path (E13), 1 matches with a missing parameter (E4), 1 is
official-but-unlisted (E11), and the remaining **25 are web/macOS-only
inventions** with no counterpart in the extracted official list. The official
OAuth2 family (`URLS:240-245`) has **no** counterpart in our code — the port
must not silently introduce it or drop our cookie-refresh flow without a
decision.

---

## 12. C++ implementation notes (PROPOSED — not in source)

These are porting recommendations, not observations.

1. **One transport class** mirroring `requestJSON` (`BLC:387-440`) with a
   callback/awaitable interface: build request → set the five/six headers of
   §2.2 → 12 s timeout → status check → JSON parse → `code` ladder (§9.1).
   Everything except nav/QR/maintenance goes through it.
2. **WinHTTP** is the natural fit (the official `bililive_secret.dll` itself
   imports `WINHTTP.dll`, `WIN:88`), but the port plan notes the Apple crypto
   moves to BCrypt/CNG (`WIN:104`) — MD5 for `sign`/`w_rid` and SHA-256 for
   `correspond/0` are the only digests needed; RSA-OAEP(SHA-256) is needed only
   for A7 (`SM:49-56`).
3. A single JSON library with **ordered** member iteration for the recursive
   scanners that sort keys (`BLC:345`, `LRA:168`, `BLC:158`) must produce the
   same order as Swift's `sorted()` on `String` keys — which is a lexicographic
   comparison of Unicode scalars for the ASCII keys used here.
4. Percent-encoding must be centralised and pinned by golden tests (§7.3); the
   two encoders in the source (`formString`, `URLComponents`) are **not** the
   same function, and the port should reproduce both rather than unify them.
5. Keep the `BilibiliAccountAPI` seam (`SC:35-56`) so the session state machine
   (`SC:339-415`) is testable with a fake, exactly as the Swift tests do.
6. Preserve the no-blocking-C-ABI rule (§10.2) and the `.sortedKeys` JSON output
   (`CB:129`, `CB:189`).
7. The Windows stub to replace is `core/win/livehime-core-stub.cpp`; its
   `EmitUnsupported` contract (`livehime-core-stub.cpp:39-55`) must not survive
   for any entry point in §10.2.

---

## 13. Risks and unknowns

### 13.1 Riskiest unknowns

1. **Cookie/header fidelity versus CEF.** The official client performs login and
   (per `WIN:48`) cookie handling inside CEF, and `WIN:56` warns against
   re-implementing the password protocol. Our layer sends a hand-built
   `Cookie` header with at most six names and **no** `buvid4`, `b_nut` or
   `bili_ticket` (`QR:8`), and sends an **empty** `Cookie:` header on the
   fingerprint call (`LRA:32-33`). Whether Bilibili's risk control accepts that
   from a non-CEF Windows client is **NOT IN SOURCE** and is the single largest
   behavioural risk. Mitigation: capture a real Windows session and diff the
   cookie jar and headers.
2. **The `startLive` signature.** The appkey `aae92bc66f3edfab`, the salt
   `af125a0d5279fd576c1b4418a3e8276d`, the eight-field order, and the assertion
   that extra fields make newer accounts reject the request (`BLC:270-281`) are
   asserted by a comment, not by the official binary. The official
   `startLive` call in `bililive_secret.dll` (`URLS:2`, `WIN:74`) is *not*
   accompanied by its parameters or `sign` (`WIN:79`). Any drift here fails at
   the first real broadcast. Mitigation: capture one official `startLive`
   request and compare field-for-field.
3. **WBI key handling and time.** The mixin key is derived from nav's
   `wbi_img` stems (`LRA:52-55`, `DP:267-272`), the signature uses the **local**
   clock (`DP:274`), the `wbiSigner` call site ignores HTTP status and API code
   (`LRA:49-55`), and the signed values are handed to `URLComponents`, which
   re-encodes them differently from the signer's strict unreserved set
   (`DP:277-283` vs `BLC:385`). Key rotation, clock skew > ~60 s, or a value
   containing a byte the two encoders treat differently silently breaks
   `getDanmuInfo` and therefore all chat. Mitigation: port the signer verbatim,
   keep the golden vector (§6.3), and log/verify `wts` against E10.

### 13.2 Smaller unknowns to resolve in the port

| # | Unknown | Cite |
|---|---|---|
| 1 | Is an empty `Cookie:` header sent or dropped? | `BLC:392`, `LRA:33` |
| 2 | Exact character set of Foundation's `urlQueryAllowed` | `BLC:503` |
| 3 | Does `URLComponents` emit `+` literally in a query value, and does the server then read it as a space? | `BLC:385` |
| 4 | URLSession default resource timeout, TLS version, redirect policy, HTTP/2 | `QR:127-133` |
| 5 | `Set-Cookie` value decoding (percent-decoding, quoting) | `QR:91` |
| 6 | Whether `requestJSON`'s `Accept`/`Origin` matter for `api.bilibili.com` hosts | `BLC:393`, `BLC:397` |
| 7 | The official client's own danmaku send/receive transport | `URLS` (absent) |
| 8 | Whether `E4` needs `url_type=1` on Windows | `BLC:194`, `WIN:7` |
| 9 | Whether `buvid4` is required for danmaku auth | `LRA:34-37` |
| 10 | Any HTTP proxy/enterprise-CA behaviour the Windows client must honour | **NOT IN SOURCE** |

---

## 14. Verification checklist for the port

Every item below is checkable against this document without re-reading the Swift:

1. `startLive` request line ends with
   `&ts=<server-seconds>&version=<v>&sign=<md5>` — order and salt per §7.1.
2. `stopLive`, `Room/update`, `IsUserIdentifiedByFaceAuth`, `AddSilentUser`,
   `GetShieldKeywordList`, `AddShieldKeyword`/`DelShieldKeyword`, `msg/send`
   all carry `Content-Type: application/x-www-form-urlencoded; charset=UTF-8`
   and their exact body order from §5.
3. `startLive` carries **no** `Content-Type` and **no** body (§5.8).
4. Every `requestJSON` request carries the five headers of §2.2 verbatim.
5. `getDanmuInfo`'s query is `id`, `type`, `web_location`, `wts`, `w_rid`
   (sorted) and reproduces the golden vector of §6.3.
6. `code: -101` on any call maps to `sessionExpired` and wipes credentials;
   `code: 60043/60024` maps to `faceAuth`/`faceAuthQR` and **never** wipes them
   (§9.3–§9.5).
7. `missingCSRF` is thrown before any request when `bili_jct` is absent or empty
   (§3.4).
8. The cookie header is name-sorted and space-semicolon separated (§3.1).
9. The probe emits exactly the 16 check ids of §10.3, in order, with `skip`
   for the signed-out and no-room cases.
10. No C entry point blocks; every failure arrives as JSON on the registered
    callback (§10.2).
