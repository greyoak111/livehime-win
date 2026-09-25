# LiveHime for Windows

Unofficial third-party [LiveHime] client for Windows, built as an OBS Studio
plugin. Ported from **[livehime-macos]**, which does the same for macOS.

> **Status: compile layer only, and not yet built on Windows.**
> The Qt UI and the OBS integration are real. The Bilibili session core behind
> them is a stub that reports `"unsupported"` — sign-in, going live, danmaku,
> emoticons and captions do not work yet. See
> **[docs/WINDOWS_PORT.md](docs/WINDOWS_PORT.md)** for exactly what is real,
> what is stubbed, and what is left.

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
plugins/livehime/
  src/                     Qt UI (portable) + window-native.{mm,cpp}
  core/Sources/            the macOS session core (Swift — not built on Windows)
  core/win/                livehime-core-stub.cpp — the Windows C ABI
  core/include/            livehime-core.h, the C bridge both cores implement
build-aux/livehime-win/    build-win.ps1
docs/WINDOWS_PORT.md       port map: done / stubbed / remaining
```

The plugin talks to its core through one C ABI (`livehime-core.h`, 35
functions). On macOS that core is Swift; on Windows it is the stub. Both are
selected in `plugins/livehime/CMakeLists.txt`.

## Building

Requires Windows, Visual Studio 2026, CMake 3.28+ and PowerShell 7.2+. The
script installs the remaining dependencies with winget.

```powershell
# x64, RelWithDebInfo
./build-aux/livehime-win/build-win.ps1

# arm64
./build-aux/livehime-win/build-win.ps1 -Target arm64

# skip the winget step when the toolchain is already installed
./build-aux/livehime-win/build-win.ps1 -SkipDependencies
```

Then run `build_x64/rundir/RelWithDebInfo/obs64.exe` and open the LiveHime dock
(`View → Docks → LiveHime`).

**This has not been run yet.** Expect to fix compile errors on the first
attempt — `window-native.cpp` and the CMake platform branch are both new code
that has never been compiled.

## Rebuilding the fork

```sh
git clone --depth 1 --branch 32.2.2 https://github.com/obsproject/obs-studio.git
cd obs-studio
git checkout -b livehime/main ba2f32bdf791005443988a4955e963663e16b1ed
git am obs-fork/patches/*.patch obs-fork/patches-windows/*.patch
```

All 53 patches apply cleanly to that commit.

## Licence

GPL-2.0-or-later, as OBS Studio. OBS and its components keep their own licences;
see `COPYING` and `AUTHORS`. Bilibili's own client and resources are not
included or redistributed.

[livehime-macos]: https://github.com/greyoak111/livehime-macos
[LiveHime]: https://live.bilibili.com/
