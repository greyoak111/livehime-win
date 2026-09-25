# LiveHime for Windows

Unofficial third-party [LiveHime] client for Windows, built as an OBS Studio
plugin. Ported from **[livehime-macos]**, which does the same for macOS.

> **Status: working, and verified on Windows.** The Qt UI, the OBS integration
> and the session core behind them are all real. Signing in with a Bilibili
> account, loading the room, receiving danmaku and the emoticon pipeline were
> each exercised against the live service on a Windows 11 ARM64 VM; going live,
> stopping, sending a danmaku and editing the title build correct requests and
> are verified as far as they can be without writing to an account.
> **[docs/WINDOWS_PORT.md](docs/WINDOWS_PORT.md)** is the port map.

Learning and community exchange only. Not affiliated with Bilibili or the OBS
Project. No commercial use.

## Why this exists

Bilibili ships LiveHime for Windows only. `livehime-macos` reimplements it on
macOS by forking OBS Studio. This repository does the same for Windows, reusing
that project's work: its 53-patch series against upstream OBS, its Qt control
dock, and the domain knowledge in its Swift session core.

## Layout

```
obs-fork/patches/          the macOS project's 53 patches, unchanged
obs-fork/patches-windows/  the Windows port, as patches on top of them
plugins/livehime/
  src/                     Qt UI (portable) + window-native.{mm,cpp}
  core/Sources/            the macOS session core (Swift — not built on Windows)
  core/win/                the Windows core, in C++
  core/include/            livehime-core.h, the C bridge both cores implement
build-aux/livehime-win/    build-win.ps1
docs/WINDOWS_PORT.md       port map: done / stubbed / remaining
docs/port-spec/            the port contract and the module specifications
```

The plugin talks to its core through one C ABI (`livehime-core.h`, 35
functions). On macOS that core is Swift; on Windows it is C++, selected in
`plugins/livehime/CMakeLists.txt`. The C++ side is not a rewrite of the Swift's
structure — it is a port of its behaviour, and
**[docs/port-spec/CONTRACT.md](docs/port-spec/CONTRACT.md)** is where the
endpoints, the signing algorithms, the JSON shapes and every deliberate
deviation are written down.

## Building

Requires Windows, Visual Studio 2022 or newer with **the ATL component** (it is
not in the default workload, and `frontend-tools`, `obs-qsv11` and the
virtual-camera module need it), CMake 3.28+ and PowerShell 7.2+. The script
installs the rest with winget.

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

Then run `build_x64/rundir/RelWithDebInfo/obs64.exe`. The LiveHime dock is on
the right; if it is hidden, `View → Docks → LiveHime`.

The WebView2 SDK is **not** in the patch series — its header alone is 69k lines
and its two static loaders are 21 MB between them — so `build-win.ps1` fetches
the NuGet package into `plugins/livehime/core/win/web/sdk/` on the first build
and skips it afterwards. The **Evergreen Runtime** it needs at run time is a
machine component and is present on any current Windows.

## Rebuilding the fork

```sh
git clone --depth 1 --branch 32.2.2 https://github.com/obsproject/obs-studio.git
cd obs-studio
git checkout -b livehime/main ba2f32bdf791005443988a4955e963663e16b1ed
git am obs-fork/patches/*.patch obs-fork/patches-windows/*.patch
```

All 53 macOS patches apply cleanly to that commit, and the Windows series on top
of them.

## Credits

- **[OBS Studio](https://github.com/obsproject/obs-studio)**（OBS Project，GPL-2.0-or-later）：
  LiveHime 就建立在 OBS 之上。LiveHime is built on OBS Studio.
- **Claude**（Anthropic，通过 Claude Code）：**写了这个移植所依据的 macOS 实现** ——
  OBS 分支与直播姬插件、Swift 会话核心、语音字幕、应用内更新、表情、端到端测试和发布流程；
  并参与了本移植的若干模块与规格整理。
  Wrote the macOS implementation this port follows — the OBS fork and plugin,
  the Swift session core, captions, in-app updates, emoticons, the end-to-end
  tests and the release process — and contributed to several modules and the
  specifications here.
- **DeepSeek Harness**（DeepSeek，`deepseek-v4-flash`）：**Windows 移植** ——
  C++ 会话核心（WinHTTP、BCrypt、Credential Manager、WIC、WebView2）、
  OBS 分支的 Windows 构建、品牌化与版本资源、更新器、以及全部在 VM 上的验证。
  The Windows port: the C++ session core (WinHTTP, BCrypt, Credential Manager,
  WIC, WebView2), the Windows build of the OBS fork, branding and the version
  resource, the updater, and all of the verification on the VM.
- **Codex**（OpenAI）：完成了 macOS 项目早期的接口逆向、登录和 v0.1。
  Did the early interface reverse-engineering, login and v0.1 of the macOS
  project.

## Licence

GPL-2.0-or-later, as OBS Studio. OBS and its components keep their own licences;
see `COPYING` and `AUTHORS`. Bilibili's own client and resources are not
included or redistributed.

Bundled third-party code, each with its licence beside it:

- **qrcodegen** (Project Nayuki, MIT) — `plugins/livehime/core/win/core/qr/`.
  The same library obs-deps ships for the macOS build; the login QR code.
- **WebView2 SDK** (Microsoft) — fetched by `build-win.ps1` into
  `plugins/livehime/core/win/web/sdk/`: header and static loaders only. The
  Evergreen Runtime itself is not redistributed, and the package's own
  `LICENSE.txt` and `NOTICE.txt` are copied in beside it.

[livehime-macos]: https://github.com/greyoak111/livehime-macos
[LiveHime]: https://live.bilibili.com/
