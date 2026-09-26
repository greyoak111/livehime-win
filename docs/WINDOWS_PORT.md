# LiveHime Windows port — the port map

Status: **working, and verified on Windows.** The Qt UI, the OBS integration and
the session core behind them are all real, and the account owner has taken it
end to end on a real Bilibili account. Sections 3 and 4 are the honest split:
what is real, and what deliberately is not.

Source of truth for the macOS side: <https://github.com/greyoak111/livehime-macos>.
This tree is that project's 53-patch series (`obs-fork/patches/`) applied to
upstream OBS Studio `32.2.2` (`ba2f32bdf791005443988a4955e963663e16b1ed`), plus
this port's 20 patches (`obs-fork/patches-windows/`). Apply order and a script
that checks the result: section 7.

## 1. Why this is a port and not a recompile

The macOS plugin has three layers:

```
src/*.cpp           Qt UI            7,577 lines, 40 files   portable
core/Sources/*.swift session core    6,822 lines, 33 files   Apple-only
src/window-native.* window behaviour 149 lines (.mm)         Apple-only
```

`core/` and `window-native` are written against frameworks that do not exist on
Windows, and there is **no `#if os(...)` / `#if canImport(...)` guard anywhere in
`core/`** — the code was never meant to build outside Apple platforms. Counting
the Swift imports:

| Framework | Files | Windows |
|---|---|---|
| Foundation, XCTest | 17 files / 2,944 lines | available |
| WebKit (`WKWebView`) | 5 | no |
| CryptoKit | 5 | no |
| Security (Keychain) | 3 | no |
| AppKit | 3 | no |
| ImageIO, UniformTypeIdentifiers | 3 | no |
| AVFoundation | 2 | no |
| Speech, CoreMedia, CoreImage, Compression | 4 | no |

**16 files / 3,878 lines import at least one Apple-only framework.**

The Qt UI never touches bilibili directly: it calls 35 `livehime_core_*`
functions declared in `core/include/livehime-core.h`. Those 35 symbols are the
seam the whole port hangs off, and keeping them unchanged is why the UI needed
no work.

## 2. What implements the seam

| | macOS | Windows |
|---|---|---|
| session core | `core/Sources/LiveHimeCore/*.swift` (Swift) | `core/win/**` (C++, 33 files / ~14,400 lines) |
| window behaviour | `src/window-native.mm` | `src/window-native.cpp` |
| selected in | `plugins/livehime/CMakeLists.txt`, per platform | same file |

The C++ side is a port of the Swift's **behaviour**, not of its structure. Where
the Swift does something odd — a signature whose field order is load-bearing, a
notice that stays `failed` rather than returning to `signedOut` — the C++ does
the same thing and the comment says why. The frozen interfaces, with `file:line`
cites into the Swift, are in `docs/port-spec/`.

`core/win/livehime-core-stub.cpp` is the first Windows build's core: all 35 entry
points reporting `"unsupported"`. It is **not built** and is kept only as the
record of the state the port landed behind, file by file.

## 3. What is real

Every Apple framework the Swift imports has a Windows counterpart, and each one
is exercised:

| macOS | Windows | Where |
|---|---|---|
| `URLSession` | WinHTTP | `core/win/net/http.cpp` |
| `URLSession.webSocketTask` | WinHTTP WebSocket | `core/win/live/danmaku.cpp` |
| `CryptoKit` | BCrypt | `core/win/net/crypto.cpp` |
| `Security` (Keychain) | Credential Manager, DPAPI file fallback | `core/win/auth/credentials.cpp` |
| `ImageIO` | WIC | `core/win/core/qr/`, emoticon re-encode |
| `WKWebView` | WebView2 | `core/win/web/webview.cpp` |
| `CIQRCodeGenerator` | qrcodegen (MIT) + zlib PNG | `core/win/core/qr/` |
| `DispatchQueue.main` | message-only window | `core/win/platform/dispatch.cpp` |
| `Compression` (zlib) | zlib | `core/win/live/danmaku.cpp` |

Verified against the live service, not against a mock:

| | Evidence |
|---|---|
| QR sign-in | `account state -> qrCode → verifying → ready` |
| Room load, areas | room event; 450 areas |
| Danmaku receive | `danmaku status -> connecting → connected`; 101 room events in 34 s in a busy room |
| Emoticons | 225 images re-encoded through WIC, every one a valid ≤160 px PNG |
| WBI signing | `getDanmuInfo` answers `code=0` |
| **Go live / stop live** | `stream state -> Starting → Live`, then `stream state -> Stopping → liveStopped → Idle` |
| **Send danmaku** | `live event -> danmakuSent` |
| Updater | `update -> checking → upToDate` against the published release |
| WebView2 runtime | Evergreen present and probed at startup |

Go live, stop live and sending danmaku were exercised by the **account owner**
on their own channel on 2026-09-26; editing the title is confirmed by them, but
note that `titleUpdated` is emitted by `livehime_core_update_title`
(`core/win/livehime-core.cpp`) and does not appear in the log of that session,
so that one row rests on the owner's word rather than on a log line.

The Windows core also carries a self-test that runs the real network path at
startup (`LIVEHIME_SELFTEST=1`), including the parts that cannot be checked by
clicking: the WBI signature, the danmaku handshake and the credential store.

## 4. What is not

| Item | State |
|---|---|
| Session maintenance | Not implemented: no 12-hour refresh, and signing out does not revoke the session server-side |
| Publisher verification | The updater checks SHA-256 and the version resource, not Authenticode. **Nothing is faked** |
| Danmaku `protover=3` | Needs brotli, which neither Windows nor obs-deps ships; the client negotiates `protover=2` (zlib) and fails loudly by name if a room insists on 3 |
| `open_face_auth_qr` | The Swift version shows a native window, not a web page — the missing piece is not WebView2 |
| Emoticon cache trim | `Emoticons.swift`'s 30 MB → 20 MB sweep is not ported, so the cache grows unbounded |
| Live captions | Graceful degradation by design: on-device captions need macOS 26+ APIs with no Windows equivalent here. `set_tts` accepts the flag and speech output is not wired |
| ATL | Not installed on the build VM, so `frontend-tools`, `obs-qsv11` and the virtual-camera module do not build there. The LiveHime plugin itself does not need it |

## 5. Branding, icon and config isolation

The Windows counterpart of what patch `0001` does for the macOS bundle, using
the same shape: cache variables with upstream-keeping defaults, overridden at
configure time.

| Path | Change |
|---|---|
| `cmake/windows/defaults.cmake` | New `LIVEHIME_APP_NAME`, `LIVEHIME_APP_DISPLAY_NAME`, `LIVEHIME_COMPANY_NAME`, `LIVEHIME_APP_ICON`, `OBS_USER_CONFIG_SUBDIR` cache variables. Defaults reproduce upstream OBS exactly. |
| `frontend/cmake/windows/obs.rc.in` | Version resource strings now come from those variables instead of hardcoded `OBS` / `OBS Studio`; the icon path too. |
| `cmake/windows/livehime-win.ico` | New. Rendered from `build-aux/livehime/icon/livehime-appicon.svg` (the same master the macOS icon comes from) at 16/32/48/64/128/256, PNG-compressed. |
| `libobs/cmake/os-windows.cmake` | Adds the `OBS_USER_CONFIG_SUBDIR` compile definition to `util/platform-windows.c`, as `os-macos.cmake` does for `platform-cocoa.m`. |
| `libobs/util/platform-windows.c` | New `user_config_subdir()`: per-user paths (`CSIDL_APPDATA`) gain the subdirectory, `%PROGRAMDATA%` paths are untouched. Mirrors `user_config_root()` in `platform-cocoa.m`. |

Resulting layout, identical in shape to the macOS build's
`~/Library/Application Support/LiveHime/obs-studio/…`:

```
%APPDATA%\LiveHime\obs-studio\basic|logs|plugin_config|global.ini …
%APPDATA%\obs-studio\…                    ← a separately installed OBS Studio
```

The in-app updater points at this project's GitHub releases
(`greyoak111/livehime-win`); the macOS build keeps pointing at its own.

### Deliberately not changed

- **The executable name stays `obs64.exe`.** Renaming it would break plugin
  search paths, the crash handler, portable mode and every shortcut. The macOS
  build renames its executable, but the Windows surface is wider. The product
  *identity* (version resource, icon, config root, window title) is LiveHime;
  the process name is not.
- **OBS's CPack/NSIS setup.** The Windows installer is built from Inno Setup
  instead; see `build-aux/livehime-win/`.
- **Artwork padding.** The `.ico` keeps the macOS master's Apple-grid padding
  (the tile is 824 of 1024 units). Windows icons usually fill more of the
  frame, so this may want a Windows-specific crop later.
- **Code signing.** The installer and the binaries are unsigned, and the updater
  does not pretend otherwise.

## 6. Building

```powershell
# the source tree needs its submodules, once
git submodule update --init --recursive --depth 1

# x64, RelWithDebInfo
./build-aux/livehime-win/build-win.ps1

# arm64
./build-aux/livehime-win/build-win.ps1 -Target arm64

# skip the winget step when the toolchain is already installed
./build-aux/livehime-win/build-win.ps1 -SkipDependencies
```

Requires Windows, Visual Studio 2022 or newer, CMake 3.28+ and PowerShell 7.2+.
The WebView2 SDK is deliberately **not** in the patch series — its header alone
is 69k lines and its two static loaders are 21 MB — so the script fetches the
NuGet package into `plugins/livehime/core/win/web/sdk/` on the first build and
skips it afterwards. The Evergreen Runtime it needs at run time is a machine
component, present on any current Windows.

## 7. Rebuilding this tree from scratch

```sh
git clone https://github.com/obsproject/obs-studio.git obs-studio
cd obs-studio
git checkout -b livehime/main ba2f32bdf791005443988a4955e963663e16b1ed
git am /path/to/livehime-win/obs-fork/patches/*.patch
git am /path/to/livehime-win/obs-fork/patches-windows/*.patch
```

All 53 macOS patches apply cleanly to that commit and all 20 Windows patches
apply cleanly on top of them — 73 commits, no fuzz and no rejects. Verified, and
re-verifiable: `build-aux/livehime-win/verify-patches.sh` does exactly this in a
scratch directory and then checks the result, including that all 35 entry points
are implemented and that the WebView2 SDK is correctly absent.

Patches `0019` and `0020` post-date the v0.2.10 build: `0019` corrects two
comments that still described the pre-port tree, and `0020` is this document.
Neither touches a translation unit, so the released binaries correspond to the
first 18 Windows patches.

One commit of the original working tree is deliberately **not** in the series:
`Vendor the WebView2 SDK`, whose only content was those 21 MB of binaries. It is
the only difference between the rebuilt tree and the tree the release was built
from — 6 files, every one of them that SDK.
