# LiveHime Windows port — what is real and what is not

Status: **compile layer only.** The plugin compiles and links from this tree;
the Bilibili session core behind it is a stub. Nothing here has been run on
Windows yet. Read the table below before trusting any part of it.

Source of truth for the macOS side: <https://github.com/greyoak111/livehime-macos>.
This tree is that project's 53-patch series (`obs-fork/patches/`) applied to
upstream OBS Studio `32.2.2` (`ba2f32bdf791005443988a4955e963663e16b1ed`), plus
the compile-only changes listed below.

## 1. Why this is a port and not a recompile

The macOS plugin has three layers:

```
src/*.cpp           Qt UI            7,577 lines, 40 files   portable
core/Sources/*.swift session core    6,822 lines, 33 files   Apple-only
src/window-native.* window behaviour 149 lines (.mm)         Apple-only
```

`core/` and `window-native` are written against frameworks that do not exist
on Windows, and there is **no `#if os(...)` / `#if canImport(...)` guard
anywhere in `core/`** — the code was never meant to build outside Apple
platforms. Counting the Swift imports:

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

**16 files / 3,878 lines import at least one Apple-only framework.** The other
17 files are Foundation-only and can move as they are.

The Qt UI never touches bilibili directly: it calls 35 `livehime_core_*`
functions declared in `core/include/livehime-core.h` and implemented in
`CBridge.swift`. Those 35 symbols are what has to exist for the plugin to link.

## 2. What this tree changes (compile layer only)

| Path | Change |
|---|---|
| `plugins/livehime/CMakeLists.txt` | Was Darwin-only: listed 21 `.swift` files, `window-native.mm` and five `.framework`s unconditionally, so `cmake` failed on Windows. Now selects `core/` and the window layer per platform. |
| `plugins/livehime/src/window-native.cpp` | New. Windows implementation of the five functions in `window-native.hpp` (topmost level, `SetWindowDisplayAffinity` for capture exclusion, HWND as the window id, the capture-exception proc). Each function documents how it differs from the Objective-C++ version. |
| `plugins/livehime/core/win/livehime-core-stub.cpp` | New. All 35 `livehime_core_*` entry points, reporting `"unsupported"`/`"failed"`. It exists so the UI links and loads; it implements nothing. |
| `build-aux/livehime-win/build-win.ps1` | New. Windows counterpart of `build-macos.sh`; drives upstream's `windows-<target>` preset and winget dependency step, and passes the LiveHime branding below. |

### Branding, icon and config isolation

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

**Deliberately not changed:**

- **The executable name stays `obs64.exe`.** Renaming it would break plugin
  search paths, the crash handler, portable mode and every shortcut. The macOS
  build renames its executable, but the Windows surface is wider. The product
  *identity* (version resource, icon, config root, window title) is LiveHime;
  the process name is not, yet.
- **The installer and code signing.** OBS's CPack/NSIS setup is untouched.
- **Artwork padding.** The `.ico` keeps the macOS master's Apple-grid padding
  (the tile is 824 of 1024 units). Windows icons usually fill more of the
  frame, so this may want a Windows-specific crop later.

## 3. What is left, in order

1. **Build it on Windows.** Nothing below is verified until this works.
   Needs Visual Studio 2026, CMake 3.28+, PowerShell 7.2+; the script installs
   the rest with winget. Expect configure/build fixes in `window-native.cpp`
   and the CMake branch — this is the first time either is compiled.
2. **Port the Foundation-only core** (17 files / 2,944 lines):
   `SessionCoordinator`, `QRLogin`, `ApiProbe`, `Diagnostics`, `LiveRoomActions`,
   `CBridge`. They are the session state machine and the room actions, and they
   need only an HTTP client, JSON and a credential store interface.
3. **Replace the Apple-only APIs** (16 files / 3,878 lines):

   | macOS | Windows |
   |---|---|
   | `WKWebView` (login, face verification, cover manager) | WebView2 |
   | Keychain (`CredentialStore`, `SessionMaintenance`) | Credential Manager (`wincred`) |
   | `CryptoKit` (signing, digests) | BCrypt / CNG |
   | `AVFoundation` + `Speech` (captions) | WASAPI + Windows speech, or Whisper |
   | `ImageIO` / `UniformTypeIdentifiers` / `CoreImage` (emoticons, QR) | WIC / stb_image |
   | `Compression` (danmaku protocol) | zlib |

4. **Packaging**: an installer (OBS's CPack/NSIS setup is untouched) and code
   signing. Optionally a Windows-specific icon crop.
5. **Release automation**: a GitHub Actions `windows-latest` job mirroring the
   macOS release flow (prebuilt OBS, versioned archive, dependency inventory).

## 4. Rebuilding this tree from scratch

```sh
git clone --depth 1 --branch 32.2.2 https://github.com/obsproject/obs-studio.git
cd obs-studio
git checkout -b livehime/main ba2f32bdf791005443988a4955e963663e16b1ed
git am obs-fork/patches/*.patch obs-fork/patches-windows/*.patch
# then apply the four compile-layer changes from section 2
```

All 53 patches apply cleanly to that commit — verified.
