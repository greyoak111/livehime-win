# Bilibili danmaku WebSocket client — implementation-ready port spec (C++ / Windows / WinHTTP WebSocket)

Scope: everything needed to reimplement `DanmakuClient` + `DanmakuProtocol` in C++ on
Windows, including the HTTP calls that feed it (`getDanmuInfo`, `buvid3`, `nav`) and the
HTTP call that sends a danmaku (`/msg/send`).

Every claim below carries a `file:line` citation into this tree. Where the Swift source
does not answer a question, the text says **NOT IN SOURCE** instead of guessing.

## 0. Citation legend

| Alias | Path (relative to `livehime-win-src/`) |
|---|---|
| `DMC` | `plugins/livehime/core/Sources/LiveHimeCore/DanmakuClient.swift` |
| `DMP` | `plugins/livehime/core/Sources/LiveHimeCore/DanmakuProtocol.swift` |
| `LRA` | `plugins/livehime/core/Sources/LiveHimeCore/LiveRoomActions.swift` |
| `BLC` | `plugins/livehime/core/Sources/LiveHimeCore/BilibiliLiveClient.swift` |
| `QR`  | `plugins/livehime/core/Sources/LiveHimeCore/QRLogin.swift` |
| `EMO` | `plugins/livehime/core/Sources/LiveHimeCore/Emoticons.swift` |
| `SC`  | `plugins/livehime/core/Sources/LiveHimeCore/SessionCoordinator.swift` |
| `T`   | `plugins/livehime/core/Tests/LiveHimeCoreTests/DanmakuProtocolTests.swift` |
| `WIN` | `plugins/livehime/core/win/…` (existing Windows port layer) |
| `REF-AN` | `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/CURRENT_PACKAGE_STATIC_ANALYSIS.md` |
| `REF-URL` | `/Users/sunxifeng/哔哩哔哩直播姬/artifacts/current/bililive_secret-relevant-urls.txt` |

Two facts established by byte-level verification during this analysis (raw frames decoded
with an independent zlib/brotli implementation, not by running the Swift code):

- **V1** — the zlib container's body is a standard RFC1950 zlib stream (`78 9c` header,
  trailing 4-byte Adler-32), and the brotli container's body is a **raw brotli stream with
  no prefix at all**.
- **V2** — packets nested inside a compressed container carry **protocol version 0**, not 2
  or 3 (`T:8-9` fixtures; see §11 test vectors).

---

## 1. Obtaining the danmaku server list

### 1.1 Step 1 — `buvid3`

`LRA:30-38`:

```text
if cookieHeader contains a non-empty "buvid3" cookie  -> use it, no request   (LRA:31)
else:
  GET https://api.bilibili.com/x/frontend/finger/spi                          (LRA:32)
      Cookie: ""            <- explicitly EMPTY cookie header                 (LRA:33)
  response: data.b_3 must be a non-empty String  else BilibiliLiveError.invalidResponse (LRA:34-36)
```

The SPI request is issued through `requestJSON(url:cookieHeader:body:)`, so it carries the
standard headers of §1.4 and requires `code == 0` in the JSON root (`BLC:424-437`).

QR logins do not set `buvid3`, hence the fallback (`LRA:28-29`).

### 1.2 Step 2 — WBI keys from `nav`

`LRA:42-57`:

```text
GET https://api.bilibili.com/x/web-interface/nav
    timeoutInterval = 12                                                       (LRA:44)
    Cookie: <cookieHeader>                                                     (LRA:45)
    User-Agent: BilibiliWeb.userAgent                                          (LRA:46)
    Referer: https://live.bilibili.com/                                        (LRA:47)
read data.wbi_img.img_url and data.wbi_img.sub_url                             (LRA:52-53)
```

The API code is deliberately **not** checked: `nav` answers `-101` when not logged in but
still carries `wbi_img` (`LRA:40-41`). Missing keys → `invalidResponse` (`LRA:53-55`).

### 1.3 WBI signing

`WBISigner` — `DMP:260-286`.

**Mixin key** (`DMP:261-272`): take the file stem (last `/` segment, up to the first `.`) of
`img_url` and of `sub_url`, concatenate them into `raw`, require `raw.count >= 64`, then

```text
mixinKey = first 32 chars of  raw[mixinTable[i]]  for i in 0..<64
```

`mixinTable` verbatim (`DMP:261-263`), 64 entries:

```text
46, 47, 18,  2, 53,  8, 23, 32, 15, 50, 10, 31, 58,  3, 45, 35,
27, 43,  5, 49, 33,  9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
37, 48,  7, 16, 24, 55, 40, 61, 26, 17,  0,  1, 60, 51, 30,  4,
22, 25, 54, 21, 56, 59,  6, 63, 57, 62, 11, 36, 20, 34, 44, 52
```

**Digest** (`DMP:274-285`):

1. `all = params`; then `all["wts"] = String(timestamp)` where `timestamp` defaults to
   `Int(Date().timeIntervalSince1970)` (`DMP:274-276`).
2. Build `query` from `all.keys.sorted()`, each as `key=value`, joined by `&`; values have
   the characters `!'()*` filtered out first; both key and value are then percent-encoded
   with the unreserved set `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~`
   (`DMP:277-281`).
3. `w_rid = lowercase_hex(MD5(utf8(query + mixinKey)))` (`DMP:282`).
4. Returned query items: **all keys sorted** (this already includes `wts`) as raw
   `(name, value)` pairs, with **`w_rid` appended last** (`DMP:283-284`). The values in the
   returned items are the filtered but *un-encoded* strings; encoding happens when the URL
   is assembled (`BLC:385`).

Verified test vector (`T:169-175`, reproduced independently):

```text
img_url = https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png
sub_url = https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png
mixinKey = ea1db124af3c7062474693fa704f4ff8
params   = id=1001, type=0, web_location=444.8, timestamp=1700000000
digest   = id=1001&type=0&web_location=444.8&wts=1700000000 + mixinKey
w_rid    = 6a7b397a3b98a73cebbca7b826767240
```

### 1.4 Step 3 — `getDanmuInfo` (the call the Swift client makes)

`LRA:59-75`:

```text
GET https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo   (LRA:65)
query = signer.sign(["id": String(roomID), "type": "0", "web_location": "444.8"])  (LRA:63)
Cookie: <cookieHeader + "; buvid3=" + buvid  if the cookie was absent>    (LRA:61, 66)
```

Signed query emission order is `id`, `type`, `web_location`, `wts`, `w_rid`
(sorted params, then the appended digest — `DMP:283-284`).

Shared request shape for every JSON call (`BLC:387-400`):

```text
method          = body == nil ? "GET" : "POST"                       (BLC:390)
timeoutInterval = 12 s                                              (BLC:389)
Cookie          = <cookieHeader>                                    (BLC:392)
Accept          = application/json, text/plain, */*                 (BLC:393)
Origin          = https://api.live.bilibili.com                     (BLC:397)
Referer         = https://live.bilibili.com/                        (BLC:398)
User-Agent      = Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15   (BLC:399)
Content-Type    = application/x-www-form-urlencoded; charset=UTF-8  (only when body != nil)  (BLC:400)
```

`BilibiliWeb.userAgent` (`QR:134`) is the identical string; the danmaku socket reuses it
(`DMC:60`).

Response handling (`BLC:416-439`):

- HTTP status must be `200..<300`, else `BilibiliLiveError.http(status:retryAfterSeconds:)`
  (`BLC:419-423`; `Retry-After` parsed by `BLC:463-474`, seconds or IMF-fixdate, clamped to
  `0...86400`).
- The JSON root must be a dictionary whose `code` is an **integer** — booleans, non-integral
  and out-of-`Int32` numbers are rejected (`BLC:424-427`, `BLC:456-461`).
- `code != 0` → `-101` becomes `notLoggedIn`, `60043`/`60024` become face-auth errors, else
  `BilibiliLiveError.api(code:message:)` with `message ?? msg ?? "Bilibili 接口返回失败"`
  (`BLC:428-437`).

**Response fields actually read** (`LRA:67-74`):

```text
data.token                  String, required                       (LRA:67)
data.host_list              [[String: Any]], required              (LRA:68)
data.host_list[i].host      String, required, else entry dropped   (LRA:70)
data.host_list[i].wss_port  Int, default 443 when absent/not a number  (LRA:71)
```

Servers are `wss_port`-only; `ws_port`/`port` are never read. If `host_list` yields no usable
entry the connect info is rejected (`LRA:73`). Server selection is **uniform random over the
whole list**, once per session (`DMC:58`); there is no sequential fallback within a session,
but the list is re-fetched on every reconnect attempt because `danmakuConnectInfo` is called
inside `session()` (`DMC:57`).

### 1.5 What the official Windows client uses — differs

The static analysis of `Livehime-Win-beta-8.6.0.11050-x64.exe` contains
`https://api.live.bilibili.com/xlive/app-room/v1/index/getDanmuInfo` (`REF-AN:76`,
`REF-URL:239`) — the **`app-room`** path, not the `web-room` path the Swift core uses.
Parameters, response shape and signing for the app-room variant: **NOT IN SOURCE**. If the
Windows port must match LiveHime exactly rather than the macOS core, that call has to be
reverse-engineered separately; nothing in this tree implements it.

---

## 2. Connect handshake

### 2.1 WebSocket URL and upgrade headers

`DMC:59-64`:

```text
URL        = wss://<host>:<port>/sub           // port from wss_port, path literal "/sub"   (DMC:59)
User-Agent = Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15   (DMC:60, QR:134)
Origin     = https://live.bilibili.com         (DMC:61)
```

Notes that matter for the port:

- **No `Cookie` header is set on the upgrade request.** Authentication happens only through
  the op-7 packet body (`DMC:66-68`). The server list HTTP call is the only place cookies are
  used.
- The socket uses a dedicated ephemeral `URLSession` (`DMC:19`), separate from the JSON
  session (`DMC:56`); the JSON session is configured with no cookie storage at all
  (`QR:127-133`).
- On teardown the socket is cancelled with close code `.goingAway` (1001) and no reason
  (`DMC:64`). No close frame is sent on `stop()` other than this `defer`; a hard cancel also
  lands here.

### 2.2 Auth packet (operation 7)

Sent as a **binary** WebSocket message (`DMC:68`, `.data(...)`), one frame, version = 1
(the `encode` default, `DMP:25`), operation = 7 (`DMP:14`).

Body is `JSONSerialization` of exactly this dictionary (`DMC:66-67`):

```json
{"uid": <int64>, "roomid": <int64>, "protover": 3, "buvid": "<info.buvid>", "platform": "web", "type": 2, "key": "<info.token>"}
```

| Field | Type | Source of value |
|---|---|---|
| `uid` | JSON number (Int64) | `start(roomID:uid:cookieHeader:)` argument; anonymous is `0` (`DMC:23`, `T:17`) |
| `roomid` | JSON number (Int64) | the same `roomID` argument (`DMC:23`, `DMC:66`) |
| `protover` | JSON number, literal `3` | hard-coded (`DMC:66`) — requests brotli containers |
| `buvid` | JSON string | `DanmakuConnectInfo.buvid`, i.e. the `buvid3` cookie or `data.b_3` (`LRA:74`, §1.1) |
| `platform` | JSON string, literal `"web"` | hard-coded (`DMC:67`) |
| `type` | JSON number, literal `2` | hard-coded (`DMC:67`) |
| `key` | JSON string | `DanmakuConnectInfo.token`, i.e. `data.token` from `getDanmuInfo` (`LRA:67`, `LRA:74`) |

Canonical worked example (any key order is accepted; see the caveat below):

```json
{"uid":10001,"roomid":2233,"protover":3,"buvid":"BUVUD-EXAMPLE","platform":"web","type":2,"key":"TOKEN-EXAMPLE"}
```

112 body bytes → 128-byte frame:

```text
00 00 00 80  00 10  00 01  00 00 00 07  00 00 00 01  | 7b 22 75 69 64 22 ...
^len=128     ^hlen  ^ver1 ^op=7       ^seq=1          ^ body (112 bytes of UTF-8 JSON)
```

Exact key order and whitespace of the emitted JSON: **NOT IN SOURCE** — `JSONSerialization`
guarantees neither ordering nor spacing (`DMC:68`). The auth body is therefore only
semantically specified, not byte-specified. The server accepts any order.

### 2.3 Auth reply (operation 8)

`DMC:86-91`:

```text
packet.operation == 8                                  -> parse body as JSON object
DanmakuParser.int(reply["code"]) == 0                  -> connectedAt = now; status = .connected
otherwise                                              -> return .zero  (end this session at once)
```

`DanmakuParser.int` accepts an `NSNumber` or a numeric `String`, else yields `0`
(`DMP:204-206`).

**Port quirk to preserve or deliberately fix:** if the body is not valid JSON, or is not an
object, `reply` is `nil`, `reply?["code"]` is `nil`, `int(nil) == 0`, and the guard **passes**
— a malformed auth reply is treated as success (`DMC:87-90`). Only an explicit non-zero,
integer-or-numeric-string `code` rejects the session.

The reply's other fields (`data`, `code` in nested objects, any server metadata) are unused —
**NOT IN SOURCE**.

---

## 3. Wire packet format

16-byte fixed header, **all multi-byte fields big-endian**, followed by the body.
Header length is the constant `16` (`DMP:23`). There is no magic number, no checksum, no
length field for the body — the body length is implied by `packetLength - headerLength`.

| Offset | Size | Type | Field | Notes |
|---:|---:|---|---|---|
| 0 | 4 | `UInt32` BE | packet length | `headerLength + body.count`, total frame size (`DMP:28`) |
| 4 | 2 | `UInt16` BE | header length | always `16` on send (`DMP:29`) |
| 6 | 2 | `UInt16` BE | protocol version | `1` on send (`DMP:25`); see §5 for received values |
| 8 | 4 | `UInt32` BE | operation | see §4 (`DMP:31`) |
| 12 | 4 | `UInt32` BE | sequence | always `1` on send (`DMP:32`); **never read** by the decoder |
| 16 | … | bytes | body | `packetLength - headerLength` bytes, sliced from `offset + header` (`DMP:47`) |

Encoder (`DMP:25-35`), literal order of appends:

```text
append(UInt32(16 + body.count).bigEndian)
append(UInt16(16).bigEndian)
append(version)                 // parameter, default 1
append(operation.rawValue)
append(UInt32(1))
append(body)
```

Decoder (`DMP:38-57`):

```text
offset = 0
while (endIndex - offset) >= 16:
    length = u32be(offset + 0)
    header = u16be(offset + 4)
    guard length >= header
          header >= 16
          offset + length <= endIndex      // else BREAK and drop the remainder
    packet.version   = u16be(offset + 6)
    packet.operation = u32be(offset + 8)
    packet.body      = data[offset + header ..< offset + length]
    offset += length
```

Behaviours the C++ port must reproduce exactly:

- The loop is driven by `packetLength`, not by the buffer end; one WS message may hold any
  number of concatenated frames, including zero-length bodies.
- A truncated tail is **silently discarded** (`break` leaves `offset..<end` unprocessed); no
  buffer is carried across messages (`DMP:41-44`, asserted by `T:142-145`). See §9.3 — this is
  the one place where a faithful port loses data that a buffered port would keep.
- The body slice uses the **header field**, not the constant 16 (`DMP:47`).
- `header > 16` is tolerated on receive (extra header bytes are skipped); `header < 16`
  aborts the loop.
- The sequence field at offset 12 is not read at all — incoming sequence numbers are ignored
  (`DMP:45-47`).
- No validation of `version` outside the compression branch of §5.

---

## 4. Operation codes

Complete set present in the source — `DanmakuOperation` (`DMP:10-16`):

| Value | Case | Direction | Meaning in this client |
|---:|---|---|---|
| `2` | `heartbeat` | client → server | Sent every 30 s with body `[object Object]`, version 1, sequence 1 (`DMP:11`, `DMC:72`) |
| `3` | `heartbeatReply` | server → client | **Received but never handled.** No branch reads it; `DanmakuParser.events` requires operation 5 (`DMP:12`, `DMC:85-93`, `DMP:125`) |
| `5` | `message` | server → client | A JSON command, possibly a compressed container (§5). The only operation that produces events (`DMP:13`, `DMP:125`) |
| `7` | `auth` | client → server | Auth handshake, sent once immediately after the socket opens (`DMP:14`, `DMC:68`) |
| `8` | `authReply` | server → client | Auth result; `code == 0` means accepted (`DMP:15`, `DMC:86-91`) |

No other operation code exists in the Swift source. Values such as `0`, `1`, `4`, `6` are
unused here — **NOT IN SOURCE**. Anything else received falls through both branches and is
dropped without a trace.

There is **no WebSocket-level ping/pong handling**: liveness is protocol operation 2 only
(`DMC:70-75`), and the absence of an op-3 reply is never detected (`DMC:85-93`). Any
"no heartbeat reply within N seconds → reconnect" rule the official Windows client may apply
is **NOT IN SOURCE**.

---

## 5. Compression and nested bodies

`protover = 3` is requested (`DMC:66`); the decoder handles versions 2 and 3 (`DMP:48-50`).

```text
operation == 5 AND (version == 2 OR version == 3):
    inflated = decompress(body, brotli: version == 3)
    if inflated: packets += decode(inflated)      // recursive
    else:        packets.append(packet as-is)     // body left compressed
else:
    packets.append(packet)
```

### 5.1 Version 2 — zlib

`DMP:65-73`:

```text
body layout on the wire (verified, V1):
  [0..1]     zlib stream header, e.g. 78 9c
  [2..n-5]   raw DEFLATE data
  [n-4..n-1] Adler-32 (big-endian)
Swift:  guard input.count > 6 ; input = input[2 ..< count-4] ; decode as COMPRESSION_ZLIB (raw deflate)
```

Because the Swift code strips the 2-byte header and 4-byte trailer and then runs a raw-deflate
decoder, the wire format is exactly RFC1950 zlib. On Windows the whole body can be handed to
zlib's `inflateInit`/`inflate` (zlib wrapper) or `uncompress2` unchanged — that is
behaviourally identical and needs no prefix surgery. The `count > 6` guard means bodies of
6 bytes or fewer never inflate and are passed through compressed (`DMP:70`).

### 5.2 Version 3 — brotli

`DMP:69-73`:

```text
body layout on the wire (verified, V1): a RAW brotli stream, no prefix, no trailer.
Swift: no bytes are stripped for brotli (the strip is inside `if !brotli`), then COMPRESSION_BROTLI.
```

**Brotli is required.** There is no fallback path: if the server answers with version-3
containers and the client cannot inflate brotli, every message is silently dropped
(the compressed body fails JSON parsing in `DanmakuParser.events`, `DMP:126`). See §9.4 for
where to get a brotli decoder.

### 5.3 Inflate guard and retry loop

`DMP:74-87`:

```text
capacity = max(4096, input.count * 8)
loop while capacity <= 64 << 20:            // hard ceiling 67 108 864 bytes
    written = decode_buffer(output[capacity], input)
    if written == 0: return nil             // failure
    if written < capacity: return output[0..<written]   // success
    capacity *= 4                           // output may have been truncated; retry larger
return nil
```

Failure semantics: a failed inflate makes the compressed packet be **appended as-is** rather
than dropped (`DMP:48-53`); downstream that body fails JSON parsing and yields no event
(`DMP:126`). No error is surfaced anywhere.

### 5.4 Nested / concatenated bodies

- The inflated output is a **packet stream**, i.e. a sequence of 16-byte-header frames, walked
  by the same `decode` (`DMP:50`). It is not a bare JSON blob.
- Fixtures show **two** frames in one container per message (`T:8-9`), and the inner frames
  carry **version 0** (`V2`) — so the recursion terminates: a version-0 op-5 frame is emitted
  as-is (`DMP:48`).
- The recursion is not depth-limited, so a doubly-compressed stream would also be expanded.
- A version-2/3 packet whose operation is **not** 5 is emitted with its body still compressed
  and is never retried (`DMP:48`).

---

## 6. Timing, heartbeat and reconnect

### 6.1 Heartbeat

`DMC:70-76`:

```text
Task started immediately after the auth packet is sent          (DMC:68 -> DMC:70)
loop:
    send binary frame: op 2, version 1, seq 1, body = "[object Object]" (15 bytes)   (DMC:72, DMP:25-32)
    sleep 30 seconds                                                              (DMC:73)
cancelled by `defer` when the session function returns                            (DMC:76)
```

- The first heartbeat goes out **immediately**, before the first 30-second wait (`DMC:72-73`).
- Send errors are discarded (`try?`), so a broken socket does not stop the heartbeat task; the
  receive loop is what detects the break and unwinds the session (`DMC:72`, `DMC:78-97`).
- Exact frame (31 bytes):

```text
00 00 00 1f  00 10  00 01  00 00 00 02  00 00 00 01  5b 6f 62 6a 65 63 74 20 4f 62 6a 65 63 74 5d
```

- No jitter, no drift compensation, no reply timeout, no `Task.sleep` tolerance: exactly
  30 s (`DMC:73`). The interval is a literal, not a constant.

### 6.2 Session lifecycle and status

`DMC:36-99`:

```text
run():
  backoff = 2 s ; attempt = 0
  while !cancelled:
      status = (attempt == 0) ? .connecting : .reconnecting    // DMC:40
      attempt += 1
      connectedFor = await session(...)                        // re-fetches token + server list
      if cancelled: break
      backoff = (connectedFor > 60 s) ? 2 s : min(backoff * 2, 30 s)   // DMC:45
      status = .reconnecting
      sleep(backoff)                                           // DMC:47
```

`connectedFor` is `now - connectedAt`, where `connectedAt` is set **only** on a successful
auth reply; a session that never authenticated returns `.zero` (`DMC:88-98`).

Consequences to reproduce:

- Backoff sequence when the connection never authenticates: `2, 4, 8, 16, 30, 30, …` seconds.
- Backoff is reset to 2 s **only** after a session that stayed authenticated for more than
  60 s (`DMC:45`). A connection that authenticates and dies after 59 s keeps doubling.
- `attempt` is never reset, so `.connecting` is emitted exactly once for the lifetime of a
  `start()` call (`DMC:40`).
- Any thrown error from connect/send/receive ends the session; the error is swallowed and the
  dock only sees the status (`DMC:95-97`).
- The server list and token are refetched on every attempt (`DMC:57`), so a
  `getDanmuInfo` failure also lands in the backoff path; it costs one HTTP round trip per
  reconnect.
- `stop()` cancels the task, drops `roomID`, and forces `.stopped` (`DMC:29-34`). Because the
  class is `@MainActor` (`DMC:7-8`) and every status write is separated from its cancellation
  check by no `await`, the status writes are serialized against `stop()` and `.stopped` is
  final. A threaded C++ port must re-establish that invariant explicitly (e.g. re-assert
  `stopped` after the worker joins, or guard the status setter with the same check).
- No maximum attempt count, no jitter, no circuit breaker, no distinction between DNS, TLS and
  protocol failures — **NOT IN SOURCE**.

### 6.3 Receive loop

`DMC:78-94`:

- Binary frames are used as-is; **text frames are converted to bytes via UTF-8** (`DMC:80-84`)
  and then decoded by the same binary path — this is why both `WINHTTP_WEB_SOCKET_BINARY_*`
  and `WINHTTP_WEB_SOCKET_UTF8_*` must feed the same accumulator.
- Each received message is decoded independently: `for packet in DanmakuPacket.decode(data)`
  (`DMC:85`), then auth-reply handling, then event dispatch (`DMC:85-93`).
- Unknown `@unknown default` cases `continue` without consuming anything (`DMC:83`).

---

## 7. Message decoding — the `cmd` table

`DanmakuParser.events(from:)` (`DMP:124-128`) requires `operation == 5` and a body that parses
as a JSON **object**; otherwise it returns no events. The command dispatch (`DMP:130-201`)
first strips any `:`-suffix:

```swift
let command = rawCommand.split(separator: ":").first.map(String.init) ?? rawCommand   // DMP:133
```

so `DANMU_MSG:4:0:2:2:2:0` dispatches as `DANMU_MSG` (asserted at `T:57`).
`data` defaults to an empty dictionary when absent (`DMP:134`).
`int()`/`int64()` accept `NSNumber` or a numeric `String`, else `0` (`DMP:204-210`).

Handled commands, in source order:

### 7.1 `DANMU_MSG` (`DMP:136-165`)

Shape: `{"cmd": "...", "info": [ ... ]}` — the payload is the `info` **array**, not `data`.

| Read | Path | Requirement |
|---|---|---|
| text | `info[1]` as String | `info.count > 2` else no event (`DMP:137-138`) |
| user array | `info[2]` as Array | `user.count > 1` else no event (`DMP:138`) |
| uid | `int64(user[0])` | — (`DMP:164`) |
| user name | `user[1]` as String, default `""` | (`DMP:164`) |
| medal | `info[3]` as Array, `m.count > 1`, `m[1]` String non-empty → `"\(m[1]) \(int(m[0]))"` | otherwise `nil` (`DMP:139-142`) |
| meta | `info[0]` as Array | (`DMP:147`) |
| danmaku id | `meta[15]["extra"]` (String) → inner JSON → `id_str` String; empty → `nil` | `meta.count > 15` (`DMP:148-151`) |
| reply target | same inner JSON → `reply_uname` String; empty → `nil` | (`DMP:152`) |
| inline emots | inner JSON → `emots` object; for each `(code, value)`: keep when `value["url"]` is a non-empty String **and** `text.contains(code)` | key is the literal code such as `[dog]` (`DMP:153-157`) |
| sticker | `meta.count > 13` **and** `int(meta[12]) == 1` **and** `meta[13]` object with non-empty `url` | `DMP:159-163` |
| sticker fields | `url`, `width` = `int(picture["width"])`, `height` = `int(picture["height"])`, `key` = `picture["emoticon_unique"] as? String ?? ""` | (`DMP:161-162`) |

Emits `.chat(uid:user:text:medal:id:replyTo:emots:sticker:)` (`DMP:164-165`, `DMP:97-98`).

`info[0][15].extra` is a **JSON string nested inside the JSON**, and must be parsed a second
time (`DMP:149-150`, fixture at `T:36-38`).

### 7.2 `SEND_GIFT`, `SEND_GIFT_V2` (`DMP:166-171`)

Payload is `data`.

| Field | Path |
|---|---|
| user | `data.uname` as String, default `""` |
| gift name | `data.giftName` as String, else `data.gift_name` as String, else `""` |
| count | `int(data.num)` |
| paid | `data.coin_type == "gold"` (string compare) |
| totalCoin | `int(data.total_coin)` |

Emits `.gift(user:name:count:paid:totalCoin:)` (`DMP:99`).

### 7.3 `SUPER_CHAT_MESSAGE` (`DMP:172-175`)

Payload is `data`; the user name is nested one level deeper.

| Field | Path |
|---|---|
| user | `data.user_info.uname` as String, default `""` |
| text | `data.message` as String, default `""` |
| price | `int(data.price)` |
| seconds | `int(data.time)` |

Emits `.superChat(user:text:price:seconds:)` (`DMP:100`).

### 7.4 `GUARD_BUY` (`DMP:176-178`)

| Field | Path |
|---|---|
| user | `data.username` as String, default `""` (note: `username`, not `uname`) |
| level | `int(data.guard_level)` |
| name | `data.gift_name` as String, default `""` |
| count | `int(data.num)` |

Emits `.guardBought(user:level:name:count:)` (`DMP:101`).

### 7.5 `INTERACT_WORD` (`DMP:179-181`)

```text
kind = data.msg_type as Int -> InteractionKind(rawValue:)
       guard fails => NO event (not a default kind)          (DMP:180)
user = data.uname as String, default ""                      (DMP:181)
```

`InteractionKind` (`DMP:118-120`):

| Value | Case | Meaning |
|---:|---|---|
| 1 | `enter` | viewer entered |
| 2 | `follow` | followed |
| 3 | `share` | shared |
| 4 | `specialFollow` | special follow |
| 5 | `mutualFollow` | mutual follow |

Any other `msg_type` (including 0) yields no event. Emits
`.interaction(user:kind:)` (`DMP:102`).

### 7.6 `INTERACT_WORD_V2` (`DMP:182-186`)

```text
pb      = base64-decode(data.pb as String); failure => NO event      (DMP:183)
fields  = Protobuf.fields(pb)                                        (DMP:184)
kind    = InteractionKind(rawValue: Int(fields.varint(5) ?? 0)); failure => NO event  (DMP:185)
user    = fields.string(2) ?? ""      // protobuf field 2, UTF-8 bytes  (DMP:186)
```

So: **field 5 = varint `msg_type`, field 2 = length-delimited `uname`**. Fixture:
`EgRUKioqIgEBKAEwtqOsCjjZ48/VBkD89KL3jDRK` → uname `T***`, msg_type 1 (`T:147-151`).

Protobuf reader (`DMP:214-257`): a minimal wire-format walker.

```text
key = varint; field = key >> 3; wire = key & 7
wire 0 -> varint value                (varints[field] = value)          DMP:240-242
wire 2 -> length-prefixed bytes       (bytes[field] = data)             DMP:243-246
wire 1 -> skip 8 bytes                                                  DMP:247-248
wire 5 -> skip 4 bytes                                                  DMP:249-250
other  -> stop, return what was collected                               DMP:251-252
malformed / truncated -> return what was collected so far               DMP:241, 244
```

Repeated fields: the dictionary assignment keeps the **last** occurrence
(`DMP:242`, `DMP:245`). Nested messages are not descended into (`fields.string(2)` assumes
field 2 is UTF-8, `DMP:219`).

### 7.7 Counter / state commands

| `cmd` | Reads | Emits | Citation |
|---|---|---|---|
| `WATCHED_CHANGE` | `int(data.num)` | `.watched(Int)` | `DMP:187-188`, `DMP:103` |
| `LIKE_INFO_V3_UPDATE` | `int(data.click_count)` | `.likes(Int)` | `DMP:189-190`, `DMP:104` |
| `ONLINE_RANK_COUNT` | `int(data.count)` | `.onlineRank(Int)` | `DMP:191-192`, `DMP:105` |
| `LIVE` | nothing | `.liveStarted` | `DMP:193-194`, `DMP:106` |
| `PREPARING` | nothing | `.liveEnded` | `DMP:195-196`, `DMP:107` |
| `ROOM_CHANGE` | `data.title` as String, default `""` | `.roomChanged(title:)` | `DMP:197-198`, `DMP:108` |

### 7.8 Everything else

`default: return nil` (`DMP:199-200`) — no event, no log, no counter. In particular
`DANMU_MSG`-adjacent, `ENTRY_EFFECT`, `ONLINE_RANK_V2`, `ROOM_REAL_TIME_MESSAGE_UPDATE`,
`STOP_LIVE_ROOM_LIST`, `NOTICE_MSG`, `WIDGET_BANNER`, `COMBO_SEND`, `USER_TOAST_MSG`,
`SUPER_CHAT_MESSAGE_JPN`, `HOT_RANK_CHANGED` and every other command are unhandled —
**NOT IN SOURCE**.

### 7.9 The delivered event objects

`LiveRoomEvent` (`DMP:92-121`) is the interface to the rest of the app. A C++ port needs an
equivalent variant with exactly these payloads:

```text
chat(uid Int64, user, text, medal?, id?, replyTo?, emots [code->url], sticker?)
gift(user, name, count Int, paid Bool, totalCoin Int)
superChat(user, text, price Int, seconds Int)
guardBought(user, level Int, name, count Int)
interaction(user, kind enum 1..5)
watched(Int) | likes(Int) | onlineRank(Int)
liveStarted | liveEnded | roomChanged(title)
Sticker { url, width Int, height Int, key }                  // DMP:110-116
```

---

## 8. Sending a danmaku (HTTP, not the socket)

### 8.1 Endpoint and body

`LRA:80-94`:

```text
POST https://api.live.bilibili.com/msg/send                  (LRA:92)
Content-Type: application/x-www-form-urlencoded; charset=UTF-8   (BLC:400)
```

Form fields, in this exact emission order (`LRA:84-91`):

```text
bubble=0
msg=<text>
color=16777215
mode=1
room_type=0
jumpfrom=0
reply_mid=<target uid or "0">
reply_attr=0
replay_dmid=<target danmaku id or "">     // sic — Bilibili's own misspelling, kept
reply_dmid=<target danmaku id or "">      // LiveHime for Windows names it this way; both are sent
statistics={"appId":100,"platform":5}
fontsize=25
rnd=<Int(Date().timeIntervalSince1970)>
roomid=<roomID>
csrf=<bili_jct>
csrf_token=<bili_jct>
```

Reply mapping is documented at `LRA:77-79`: `reply_mid` = the target viewer's uid,
`replay_dmid` = the web room's spelling, `reply_dmid` = the official Windows client's
spelling; both are sent. With no reply, `reply_mid` is `"0"` and both dmid fields are empty
(`LRA:82-83`).

### 8.2 Encoding

`form(_:)` (`BLC:498-505`):

```text
allowed = CharacterSet.urlQueryAllowed minus "+&="      (BLC:503)
"key=value" pairs joined by "&", each side percent-encoded with `allowed`   (BLC:504)
```

Note `statistics` contains `{`, `}`, `"`, `:` — these survive `urlQueryAllowed` and are
percent-encoded by it only where required. The Windows layer already exposes
`net::FormEncode` / `net::UrlEncode` (`WIN/net/http.h:63,66`).

### 8.3 CSRF

`BLC:490-496`: scan the cookie header for a non-empty `bili_jct` and use it verbatim; if
absent, throw `BilibiliLiveError.missingCSRF` (`BLC:77`, `BLC:495`). `SessionCredentials.csrf`
is exactly `cookies["bili_jct"]` (`QR:22`). Note the csrf is taken from the **caller's**
`cookieHeader` argument, not from the client's `defaultCookieHeader` (`LRA:81`, `LRA:93`).

Both `csrf` and `csrf_token` carry the same value (`LRA:90`).

### 8.4 Request headers and response handling

Identical to §1.4 except the method is POST because a body is present (`BLC:390`), plus:

```text
Origin:  https://api.live.bilibili.com    (BLC:397)
Referer: https://live.bilibili.com/       (BLC:398)
Cookie:  <cookieHeader>                   (BLC:392)
```

Response: HTTP `200..<300` required (`BLC:419-423`); the JSON root must carry an integer
`code` (`BLC:424-427`); `code == 0` succeeds and the `data` payload is **discarded**
(`LRA:93`, `_ = try await requestJSON(...)`).

### 8.5 Error codes

Every code the source distinguishes (`BLC:428-437`):

| Condition | Result |
|---|---|
| HTTP status outside `200..<300` | `BilibiliLiveError.http(status:retryAfterSeconds:)` — `Retry-After` seconds or IMF-fixdate, clamped `0...86400` (`BLC:419-423`, `BLC:463-474`) |
| root has no integer `code` | `BilibiliLiveError.invalidResponse` (`BLC:424-427`) |
| `code == -101` | `BilibiliLiveError.notLoggedIn` (`BLC:429`, `BLC:432`) |
| `code == 60043` or `60024` | face-auth error, `data.risk_extra.v_voucher` or `data.qr` (`BLC:430`, `BLC:433-435`) |
| any other `code != 0` | `BilibiliLiveError.api(code:message:)`, message from `message ?? msg ?? "Bilibili 接口返回失败"` (`BLC:436`) |
| transport/DNS/TLS failure | `BilibiliLiveError.network(code:)` from `URLError.errorCode`, else `transport` (`BLC:412-415`) |

These surface to the UI as `{"kind": ...}` (`CBridge.swift:194-218`): `api` → `{kind:"api",
code, message}`, `-101` → `{kind:"sessionExpired"}`, HTTP → `{kind:"http", code}`,
face-auth → `{kind:"faceAuth"|"faceAuthQR"}`.

**Danmaku-specific reject codes** (rate limiting,内容过长, 被禁言, 房间未开播, 需要粉丝牌 …) are
**NOT IN SOURCE** — the client treats every non-`-101`/non-face-auth code as an opaque
`api(code, message)` and never enumerates them. A Windows port that wants friendly messages
for those has to add them from observation.

### 8.6 Sticker danmaku

Same endpoint, same field list, plus `dm_type=1` and `emoticonOptions=[object Object]`
(literal), with `msg` set to the emoticon's `emoticon_unique` (`EMO:125-138`; the `msg`
value is the `unique` argument, `EMO:129`).

### 8.7 Client-side rules

- Text is trimmed of whitespace and newlines; an empty result sends **nothing** and does not
  throw (`SC:242-250`, asserted `SessionCoordinatorTests.swift:286-291`).
- No client-side length limit, no rate limiter, no dedupe, and **no send queueing or
  serialization**: `sendDanmaku` awaits the HTTP call in the caller's task, wrapped only by
  `guarded` (`SC:242-250`); the coordinator's `run(_:)` task slot (`SC:334-337`) is not used
  on this path, so two concurrent sends race.
- Only `BilibiliLiveError.notLoggedIn` (i.e. API code `-101`) is treated as a rejected
  session: it deletes stored credentials and flips the app to signed-out
  (`SC:316-327`, `SC:419-421`). Any other send failure, including the face-auth codes, just
  propagates.

---

## 9. Windows mapping

### 9.1 Existing Windows infrastructure to build on

The port layer already exists under `plugins/livehime/core/win/`:

| Need | Existing facility | Citation |
|---|---|---|
| HTTP with WinHTTP, worker pool, cookie jar | `livehime::net::Send` / `SendSync` / `Request` / `Response`, default timeout 15 000 ms | `WIN/net/http.h:20-60` |
| Form + URL encoding | `net::FormEncode`, `net::UrlEncode` | `WIN/net/http.h:63,66` |
| WBI signing (the exact algorithm of §1.3) | `net::WbiSigner::FromNav` / `SignQuery` | `WIN/net/signing.h:29-45` |
| MD5/SHA-256/HMAC/base64 | BCrypt-backed `livehime::crypto::Md5Hex` etc. | `WIN/net/crypto.h:19-35` |
| Main-thread delivery of results | `livehime::dispatch::Init/Post/OnMainThread` | `WIN/platform/dispatch.h:20-38` |
| WinHTTP session setup precedent | `WinHttpOpen`, `WinHttpSetTimeouts(10000,10000,15000,30000)`, `WINHTTP_FLAG_SECURE`, gzip/deflate decompression, manual redirects | `WIN/net/http.cpp:90-139` |

**MbedTLS is not needed.** MD5 for WBI and for `pc_link` comes from BCrypt through
`crypto::Md5Hex`; MbedTLS is only linked into obs-studio, not into the livehime module
(`WIN/net/crypto.h:4-5`). TLS for `wss://` and `https://` is WinHTTP/schannel's job.

### 9.2 HTTP calls (server list, token, send)

Map 1:1 onto `net::Request` (`WIN/net/http.h:37-49`):

| Swift | Windows |
|---|---|
| `URLRequest` + `timeoutInterval = 12` (`BLC:389`) | `Request::timeout_ms = 12000` (default is 15000, so set it explicitly) |
| `httpMethod = body == nil ? "GET" : "POST"` (`BLC:390`) | `Request::method` |
| `Cookie:` header (`BLC:392`) | the jar applies cookies automatically; pass Bilibili's own headers, **not** `Cookie` (`WIN/net/http.h:6-8`) |
| `Content-Type` (`BLC:400`) | `Request::content_type` |
| `Accept`/`Origin`/`Referer`/`User-Agent` (`BLC:393-399`) | `Request::headers` |
| form body (`BLC:498-505`) | `net::FormEncode` |
| signed query (`DMP:274-285`) | `net::WbiSigner::SignQuery` + `net::AppendQuery` |
| HTTP-status + integer-`code` validation (`BLC:416-437`) | replicate in the caller; `net::Response::Ok()` plus a JSON parse |

Keep the 12 s timeout, the `Retry-After` handling and the `-101`/`60043`/`60024` mapping
(§8.5) identical; they are the contract the Qt UI already consumes.

### 9.3 WebSocket: WinHTTP WebSocket API

Minimum OS: Windows 8 / Server 2012 (`winhttp.h`, per the SDK docs below).

| Step | Swift equivalent | WinHTTP |
|---|---|---|
| Open session/connection | `URLSession.ephemeral` + task (`DMC:19, 62`) | `WinHttpOpen(L"LiveHime/…", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, …)`; `WinHttpConnect(host, wss_port, 0)` |
| Secure upgrade | `wss://` scheme (`DMC:59`) | `WinHttpOpenRequest(connect, L"GET", L"/sub", nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE)` |
| Mark as WebSocket | implicit in `webSocketTask` | `WinHttpSetOption(req, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0)` — required before sending |
| — | — | `WinHttpAddRequestHeaders(req, L"Origin: https://live.bilibili.com", …)` and the UA of `DMC:60`. Never add `Sec-WebSocket-*` by hand; WinHTTP owns the handshake |
| Send handshake | `socket.resume()` (`DMC:63`) | `WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, nullptr, 0, 0, 0)` then `WinHttpReceiveResponse` |
| Verify upgrade | — | status must be **101**; any other status makes the next step fail |
| Get the socket | — | `WinHttpWebSocketCompleteUpgrade(req, 0)` → `HINTERNET hWebSocket`; then `WinHttpCloseHandle(req)` (the connection handle can also be closed) |
| — | — | `WinHttpWebSocketQueryCloseStatus` for the close code/reason |
| Send binary (`DMC:68, 72`) | `.data(frame)` | `WinHttpWebSocketSend(hWebSocket, WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE, buf, len)`. Each call with a `…_MESSAGE_BUFFER_TYPE` is one complete message; no manual framing |
| Send text, if ever needed | `.string(...)` | `WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE` |
| Close | `.cancel(with: .goingAway, reason: nil)` (`DMC:64`) | `WinHttpWebSocketClose(hWebSocket, WINHTTP_WEB_SOCKET_ENDPOINT_TERMINATED_CLOSE_STATUS /* 1001 */, nullptr, 0)`, or `WinHttpWebSocketShutdown` for a one-way close |
| Hard stop | task cancellation (`DMC:30`), which makes `receive()` throw (`DMC:95-97`) | `WinHttpCloseHandle(hWebSocket)` / `WinHttpCloseHandle(session)` from the controlling thread; a blocked `WinHttpWebSocketReceive` then fails with `ERROR_WINHTTP_OPERATION_CANCELLED` |

Receive-side mapping — **the important one**:

```text
WINHTTP_WEB_SOCKET_BUFFER_TYPE (winhttp.h, Windows 8+):
  WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE  = 0   // whole binary message, or its last part
  WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE = 1   // more of a binary message follows
  WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE    = 2   // whole UTF-8 message, or its last part
  WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE   = 3   // more of a UTF-8 message follows
  WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE           = 4   // server sent a close frame
```

`WinHttpWebSocketReceive` fills a caller buffer and reports which of these it returned, so:

- A single `receive()` may return **only part** of a WebSocket message (fragment types 1/3).
  URLSession's `receive()` always yielded a whole message (`DMC:80-84`), so a port that
  ignores fragmentation will corrupt frames. Accumulate until a `*_MESSAGE_BUFFER_TYPE`
  (0 or 2) or `CLOSE_BUFFER_TYPE` (4) arrives, then treat the accumulated bytes as one
  message — text (2) and binary (0) feed the **same** decoder (`DMC:81-84`).
- A WebSocket message boundary is **not** a danmaku packet boundary. `DMC:85` decodes each
  message independently and `DMP:41-44` silently drops a truncated tail, so the Swift client
  loses a packet split across messages. A WinHTTP port should instead keep a persistent byte
  accumulator across messages and pop complete frames (`len >= 16` and `offset + len <=
  available`), because fragment boundaries are now visible to the application. That is a
  deliberate divergence: strictly better, and it cannot mis-parse a well-formed stream.
  If exact bug-compatibility is required, decode per message and drop the tail, as `DMP:41-44`
  does, and keep test `T:142-145` green.
- `CLOSE_BUFFER_TYPE` (4) is the analogue of the receive loop throwing: end the session, let
  the caller's backoff run (§6.2), and read the status via
  `WinHttpWebSocketQueryCloseStatus(…, &code, &reason…)` for diagnostics. The Swift client
  discards the close reason entirely (`DMC:95-97`), so logging it is new behaviour.
- Receive must not run on the UI thread. Put the socket loop on the worker pool, run the
  heartbeat and the reconnect timer on the same worker (the Swift code used a child `Task`,
  `DMC:70`), and hand decoded `LiveRoomEvent`s to the UI through `dispatch::Post`
  (`WIN/platform/dispatch.h:29`), preserving the "always main thread" contract (`DMC:92`).
- Preserve the §6.2 invariant explicitly: a stop flag must be checked immediately before
  every status write, or re-assert `stopped` after joining the worker. In Swift this was free
  because `@MainActor` serialized it (`DMC:7-8`, `DMC:29-34`).

### 9.4 Compression facilities

| Protocol version | Algorithm | Windows facility |
|---|---|---|
| 2 | zlib / DEFLATE (`DMP:65-73`, `V1`) | **zlib is already in the build**: `find_package(ZLIB REQUIRED)` in `libobs/CMakeLists.txt:15`, linked at `libobs/CMakeLists.txt:251`. Use `inflateInit`/`inflate` (zlib wrapper) or `uncompress2` on the body as-is — equivalent to the Swift strip-2/strip-4 step. Keep the `count > 6` guard (`DMP:70`) and the `max(4096, 8×)`→`×4`→64 MiB growth loop (`DMP:74-87`) or a `z_stream` loop that grows on `Z_BUF_ERROR` |
| 3 | brotli (`DMP:69-73`, `V1`) | **No C/C++ brotli facility exists in this tree — brotli must be added.** A case-insensitive grep of the whole tree matches `brotli` only in the Swift source and its test (`DMP:8,49,67-73`, `T:5,8,20-21`); a path search for `*brotli*` returns no file, and the plugin links only `user32 dwmapi version crypt32` on Windows (`plugins/livehime/CMakeLists.txt:152`). Vendor `deps/brotli` (or vcpkg `brotli`) and link it, then call `BrotliDecoderDecompress` for the one-shot case, or `BrotliDecoderCreateInstance`/`BrotliDecoderDecompressStream` to reproduce the grow-and-retry behaviour of `DMP:74-87` |

**Do not** try the Windows Compression API (`CreateDecompressor`, `compressapi.h`) for either
version: the only algorithms it supports are `COMPRESS_ALGORITHM_MSZIP` (2),
`COMPRESS_ALGORITHM_XPRESS` (3), `COMPRESS_ALGORITHM_XPRESS_HUFF` (4) and
`COMPRESS_ALGORITHM_LZMS` (5) — no DEFLATE, no brotli. WinHTTP's own
`WINHTTP_OPTION_DECOMPRESSION` (`WIN/net/http.cpp:130-133`) applies to HTTP response bodies
only and is irrelevant to WebSocket payloads.

If the app wants to dodge brotli entirely it would have to send `protover = 2` in the auth
packet (`DMC:66`) and hope the server honours zlib only — **NOT IN SOURCE**, unverified, and
not what the Swift client does.

### 9.5 Environment / API references

- [`WINHTTP_WEB_SOCKET_BUFFER_TYPE`](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/ne-winhttp-winhttp_web_socket_buffer_type)
- [`WINHTTP_WEB_SOCKET_CLOSE_STATUS`](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/ne-winhttp-winhttp_web_socket_close_status)
- [`WinHttpWebSocketCompleteUpgrade`](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpwebsocketcompleteupgrade)
- [`CreateDecompressor` (Compression API algorithm list)](https://learn.microsoft.com/en-us/windows/win32/api/compressapi/nf-compressapi-createdecompressor)

---

## 10. Explicitly NOT IN SOURCE

Collected so nobody re-derives them by guesswork:

1. Byte-exact ordering/whitespace of the auth JSON (`DMC:66-68`) — only the field set is specified.
2. The `app-room` / `getDanmuInfo` request parameters that the official Windows client sends (`REF-AN:76`, `REF-URL:239`).
3. Any use of the heartbeat **reply** (op 3): no branch reads it (`DMP:12`, `DMC:85-93`).
4. Any heartbeat-reply timeout, any WebSocket-level ping/pong, any liveness detection beyond TCP/WS failure.
5. Danmaku send error codes other than `-101`, `60043`, `60024` and the generic `api(code,message)`.
6. Maximum danmaku length, client-side rate limiting, and the meaning of `bubble`/`mode`/`room_type`/`jumpfrom`/`reply_attr`/`fontsize`/`statistics` values beyond "these literals are sent" (`LRA:85-90`).
7. Any `ws_port`/`port` fallback in the server list (`LRA:69-72` reads `wss_port` only).
8. Handling for command types other than the 15 in §7 (`DMP:199-200`).
9. Reconnect jitter, maximum attempt counts, and error classification by transport type (`DMC:95-97` swallows everything).
10. Whether the server ever answers with protocol versions other than 0, 1, 2 or 3 (`DMP:48-50` only branches on 2 and 3).

---

## 11. Test vectors (independently reproduced, V1 + V2)

Fixtures from `T:8-9`; the surrounding frame structure was decoded here with zlib and brotli
directly, not by running the Swift code.

### 11.1 Brotli container, `protover 3`

```text
base64: AAAA2QAQAAMAAAAFAAAAARvpAAAsCuzGYiNDhWv1zRqiHb+gwQN/riXJ40XRtzUNR5GUdzS6BvL8dEIUYlFINl2yKaZLwu3NotPVt0W+nMhW0JTZTocDxN1u9DfZ7iYVhWGsiaWBZTekQcqqqPeGBbskSbOEkrAuPcsX036RWFFWzEUgHOHxdEDtv6mqnAbvy08dqsDDv/n9PMRpVJ6L3+h746dmPhyBJL2S6WbF6B67m6hr0YWjr6K4FAHkfQ67dy++qCs4Hbt8g+k8nwJxEDB1GBZyCzXndg==

header : 00 00 00 d9  00 10  00 03  00 00 00 05  00 00 00 01
         len=217      hlen=16 ver=3  op=5        seq=1
body   : 201 bytes, raw brotli, first bytes 1b e9 00 00 2c 0a ec c6

inflated (234 bytes) = two concatenated frames:
  00 00 00 69  00 10  00 00  00 00 00 05  00 00 00 01
  {"cmd":"DANMU_MSG:4:0:2:2:2:0","info":[[0],"你好",[42,"观众A",0],[21,"粉丝牌",0]]}
  00 00 00 81  00 10  00 00  00 00 00 05  00 00 00 01
  {"cmd":"SEND_GIFT","data":{"uname":"观众B","giftName":"小心心","num":3,"coin_type":"silver","total_coin":0}}
```

Expected events (`T:11-14`):

```text
.chat(uid: 42, user: "观众A", text: "你好", medal: "粉丝牌 21")
.gift(user: "观众B", name: "小心心", count: 3, paid: false, totalCoin: 0)
```

Note `medal` renders as `"<m[1]> <int(m[0])>"` = `"粉丝牌 21"` from `[21,"粉丝牌",0]` (`DMP:141`).

### 11.2 zlib container, `protover 2`

```text
base64: AAAA3QAQAAIAAAAFAAAAAXicY2BgyGQQYAABVgYGBsZqpeTcFCUrJRdHP9/QeN9gdysTKwMrIzA0UNJRysxLy1eyio42iNVRerJ3wdOle5V0ok2MdJReLG96sme6o5KOQaxOtJGhjtLzTZ1Pdsx93tkDEoqtBRreiM2iYFc/l3h3T7cQJR2llMSSRCWraqXSvMTcVCUrqJlOSjpK6ZlpJX4Qwacb+p/ub366v1lJRymvNFfJylhHKTk/My++pLIAJF+cmVOWWqSko1SSX5KYEw+SUrIyqK0FAPO2Soc=

header : 00 00 00 dd  00 10  00 02  00 00 00 05  00 00 00 01
         len=221      hlen=16 ver=2  op=5        seq=1
body   : 205 bytes = 78 9c | raw deflate | f3 b6 4a 87 (Adler-32)

inflated (234 bytes) = the SAME two frames as 11.1, both with version 0
```

### 11.3 Other fixed vectors

```text
heartbeat frame (31 bytes)   : 00 00 00 1f 00 10 00 01 00 00 00 02 00 00 00 01 + "[object Object]"
auth frame, example of 2.2   : 00 00 00 80 00 10 00 01 00 00 00 07 00 00 00 01 + <112-byte JSON>
round trip                   : encode(op 7, {"roomid":1}) == 16-byte header + body (T:28-33)
truncated frame              : the first 10 bytes of any frame decode to [] (T:142-145)
INTERACT_WORD_V2 fixture     : pb "EgRUKioqIgEBKAEwtqOsCjjZ48/VBkD89KL3jDRK" -> enter, "T***" (T:147-151)
WBI fixture                  : see 1.3 (T:169-175)
```

### 11.4 Suggested C++ unit tests

1. `Encode(Heartbeat)` equals the 31-byte vector of 11.3 byte for byte.
2. `Decode(brotliFrame)` and `Decode(zlibFrame)` each yield two op-5 version-0 packets whose
   bodies equal the strings in 11.1, and the parser yields the two events of 11.1.
3. `Decode(frame[0..10])` yields zero packets.
4. A frame whose `packetLength` exceeds the buffer yields zero packets and consumes nothing.
5. `Decode` over a buffer holding two concatenated uncompressed frames yields both.
6. WbiSigner reproduces `mixinKey` and `w_rid` of `T:172-174`.
7. A 30 s fake clock advances the heartbeat sender exactly once per interval, first send at t=0.
8. Backoff trace for repeated instant failures: 2, 4, 8, 16, 30, 30 s; and 2 s after a 61 s session.
