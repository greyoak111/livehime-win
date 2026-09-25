# 移植工作文档 / Porting notes

LiveHime for Windows —— 把 `livehime-macos` 的会话核心移植到 Windows 的完整记录：
做了什么、怎么验证的、**哪些地方我做错了**，以及为什么。

A record of porting the macOS session core to Windows: what was built, how it was
verified, and — the part worth reading — **where I got it wrong.**

---

## 一、结果 / What came out

一个能用的 LiveHime Windows 客户端：OBS 32.2.2 分支 + `plugins/livehime` 插件，
核心是 C++（约 7,000 行），替换掉最初那个 35 函数的桩。

| | |
|---|---|
| 补丁 | 18 个（在 macOS 的 53 个之上），984 KB |
| `livehime.dll` | 4,384,256 字节（桩版 1,053,184） |
| 首次发布 | [v0.2.10](https://github.com/greyoak111/livehime-win/releases/tag/v0.2.10)，48.6 MB |
| 验证环境 | Windows 11 ARM64 / Parallels，x64 构建在模拟下运行 |

**技术栈替换**（每一项都落地并在真机验证）：

| Apple | Windows |
|---|---|
| `URLSession` | WinHTTP |
| `URLSession.webSocketTask` | WinHTTP WebSocket |
| `CryptoKit` | BCrypt |
| `Security`（Keychain） | Credential Manager（+ DPAPI 兜底） |
| `ImageIO` | WIC |
| `WKWebView` | WebView2 |
| `CIQRCodeGenerator` | qrcodegen（MIT） |
| `DispatchQueue.main` | message-only 窗口 |

**实测证据**：扫码登录（真实账号，`mid 364662067`）· 房间信息 · 收弹幕（真实直播间
34 秒 101 个事件）· 分区列表 450 个 · 表情 225 张全部重编码为 ≤160px PNG ·
WBI 签名被 B 站接受（`getDanmuInfo` 回 `code=0`）· 更新器找到刚发布的 release 并答
`upToDate`。

---

## 二、做对的地方 / What worked

### 1. 先摸清分层，再动手

第一件有价值的事不是写代码，是搞清楚**这到底是不是一个"重新编译"的活**。结论是不是：

```
Qt C++ 外壳（7,577 行，完全可移植）
        ↓ 35 个 livehime_core_* 函数（C ABI）
Swift 会话核心（6,822 行，16 个文件锁死在 Apple 框架上）
```

`livehime-core.h` 那 35 个函数是**天然的接缝**。抓住它，任务从"移植一个应用"变成
"实现一个 35 函数的接口"——这是整个项目能被做完的原因。

**教训**：动手前的架构调查，回报率远高于动手本身。

### 2. 契约先行

`docs/port-spec/CONTRACT.md` 先冻结了：35 个入口的事件形状（从 `CBridge.swift:73-131`
逐字读出）、端点表、两套签名算法、Cookie 模型、线程契约。

有了它，后续所有实现都能并行 —— 因为接口不再会变。

### 3. 把「答案」当规格，不当灵感

macOS 的 Swift 源码就是行为规格。凡是它做得奇怪的地方（`startLive` 八个字段的顺序被
源码注释称为 load-bearing、`PublishReady` 的字段集、`-101` 也要读 WBI 密钥），
**照抄，不改**。每个这样的地方都在代码里标了 `file:line`。

同样，官方 Windows 客户端（`bililive.dll` / `bililive_secret.dll`）的静态分析给了
端点底稿 —— 而且它的 appkey 和 macOS 版**完全一致**，这本身就是强证据。

### 4. 给子代理冻结的头文件和精确的规格

9 个子代理：3 个出规格、6 个出实现。每个都拿到冻结的头文件 + 要读的 Swift 文件 +
「不要改这个、不要改那个」。

**它们抓到了我的错误**（见第三节），这是最有价值的副产品。

### 5. 自检：让机器能自己证明

一个 Windows 核心没法靠人点界面来验证。`LIVEHIME_SELFTEST=1` 让它在启动时跑一遍
真实请求并把结果写文件，包括驱动真实状态机。这一条把"我觉得它能用"变成"日志里写着
它能用"。

**关键在于它不撒谎**：跑不通就写跑不通。

### 6. 让每个失败点自己报名字

`RunSession` 原本有 14 个静默 `return 0`，`FetchDanmakuInfo` 有 4 处都报同一个
`invalidResponse`。一次 VM 运行根本分不清是 socket 被拒还是 WBI 拉取失败。

给每个点起名之后，一轮就定位了。**这一条的价值甚至超过它解决的问题** —— 我因此
发现之前那次"失败"其实是自检顺序错了（见 3.5）。

---

## 三、做错的地方 / Where I got it wrong

**这一节是这份文档存在的理由。**

### 3.1 我三次误判了环境

- 说 `cl.exe` 不存在 —— 其实是我自己拼路径时把 `bin` 拼了两遍
- 说 VM 只有 VS2022 所以编不了 —— 工具链其实是完整的
- 说「C++ 那边是可移植的」（基于文件扩展名扫描）—— **错的**。
  `update-page.cpp` 是 C++ 却 `#include <CoreFoundation/CoreFoundation.h>`。

**教训**：按扩展名推断可移植性是偷懒。**要按实际引用来判断。**

### 3.2 我用 `--msg-filter` 毁了 18 条提交信息

```sh
if grep -q "Co-Authored-By: Claude" ; then cat; else ...
```

`grep -q` **把 stdin 吃掉了**，后面的 `cat` 什么也没输出 —— 18 个提交的标题全变成了
trailer 那一行。

从 `refs/original/HEAD` 恢复了。**教训**：改写 git 历史前，先在一条上试跑。

### 3.3 我"修"了一个没坏的东西

dock 里的二维码显示不全，我诊断成 DPI/Qt 钳制，改了两轮 `resizeDocks`。

你的原话：**「本来就做成了滚动容器，不劳你瞎改，恢复原状即可」**。

**真正的答案**：是我为了截图反复 `MoveWindow` + 清掉 OBS 保存的窗口几何，把布局搞乱了。
不动它就好了。

**教训**：改之前先问「这是我弄坏的吗」。我花了三轮才想到问这个。

### 3.4 我写了两个靠桩头文件混过去的编译错误

- `danmaku.h` 里 `RoomId()` 引用了**不存在的成员** `room_id_` —— 任何 include 它的
  翻译单元都编不过。是写 `danmaku.cpp` 的子代理抓到的。
- `updater.cpp` 用了 `INTERNET_PORT` / `URL_COMPONENTS` / `WinHttpCrackUrl` /
  `HINTERNET` 却**只包含了 `<windows.h>`**，没有 `<winhttp.h>`。它自己的 clang 检查
  用手写桩头文件通过了 —— **这正是桩头文件会留下的那种缺口**。

**教训**：桩能验证逻辑，验证不了头文件包含。CMake 的源文件列表和 include 要人工过一遍。

### 3.5 我把测试写错了，然后误以为代码坏了

弹幕第一次"连不上"，我怀疑 `FetchDanmakuInfo`。真相是：**自检把 `StartQrLogin`
排在弹幕测试前面**，而会话状态一进 `qrCode`，观察者就按 `CBridge.swift:47-48`
停掉弹幕连接 ——

```
connecting(.362) → qrCode(.440) → stopped(.458)
```

那 96 毫秒测的是**观察者**，不是握手。改成弹幕优先之后：

```
connecting 01:48:19.860 → connected 01:48:20.733 → 34 秒收到 101 个事件
```

**教训**：测试失败时，先怀疑测试。

### 3.6 我用"看起来合理"的数字做了错误推断

推荐列表里 `online=1138879` 的房间，我以为是热门间，结果 35 秒只有 4 条弹幕 ——
`online` 是**热度值不是观众数**。

而且我拿 `room_id=1` 测房间信息，失败了；真相是 **room 1 是 5440 的别名**，接口回的
`data.room_id` 是 5440，解析器的 `data.room_id == roomID` 守卫（和 Swift 的
`BilibiliLiveClient.swift:246` 一模一样）正确地拒绝了它。

**教训**：**先证明接口返回什么，再写测试**。两次都是我把输入搞错了，却差点当成移植缺陷。

### 3.7 反复撞同一个墙：Parallels 的命令行长度

`prlctl exec` 的命令行有长度上限（3000～4000 字符之间）。我一次又一次地把 base64
内联进去，然后收到一个**误导性的错误**：

```
PrlVmGuest_RunProgram: Unable to open new session in this virtual machine.
Make sure your virtual machine has finished booting...
```

这个报错看起来像"会话卡死"，其实是"命令太长"。我因此浪费了很多轮，还一度去排查
Parallels Tools。

**教训**：报错信息可能指向错误的方向。这个坑我踩了至少五次才形成肌肉记忆（分块 2000 字符）。

### 3.8 我把 21 MB 的二进制塞进了源码树

WebView2 的静态库 10.7 MB × 2 一开始被我 commit 进树里。后来意识到补丁系列根本
承载不了它，改成 `build-win.ps1` 首次构建时从 NuGet 拉。

**教训**：往仓库里加二进制之前，先想它怎么进补丁 / 怎么被 clone。

### 3.9 文档一度变成假话

`CONTRACT.md` §8.2 在 WebView2 做完之后还写着 "Deferred"；仓库 README 在验证做完
好几轮之后还写着 "This has not been run yet"。

**教训**：文档不是一次性产物。状态变了就要回去改，否则它比没有更糟。

---

## 四、没做完的 / What is not done

| 项 | 状态 |
|---|---|
| 开播 / 停播 / 发弹幕 / 改标题 | 请求构造已验（未登录时 `missingCSRF` 短路、`FetchUpstream` 回 `-101` 而非 `-403`），**成功路径未跑** —— 全是写操作，其中开播会真的上播，需要账号本人按下 |
| 会话维护 | 未实现：没有 12 小时 refresh，登出不会服务端撤销 |
| 发布者验证 | 更新器只校验 SHA-256 + 版本资源，没有 Authenticode。**没有伪造** |
| 弹幕 `protover=3` | 需要 brotli，Windows 和 obs-deps 都没有。当前用 `protover=2`（zlib） |
| `open_face_auth_qr` | Swift 用原生窗口显示，不是网页 —— 缺的不是 WebView2 |
| 表情缓存裁剪 | `Emoticons.swift` 的 30MB→20MB 清理未移植，缓存会无限增长 |
| 语音字幕 | 优雅降级（仅 macOS 26+），按设计 |
| ATL | 未安装，所以 `frontend-tools` / `obs-qsv11` / 虚拟摄像头编不出来 |

---

## 五、下一次该怎么做 / If I did this again

1. **先问三个问题**：这东西真的需要移植吗？接缝在哪？验证怎么自动化？
2. **接口先冻结，再并行。** 冻结之前不要派活。
3. **环境判断靠实测，不靠推断。** 装了什么、编不编得过，跑一次比想十次强。
4. **测试失败先怀疑测试。** 尤其是自己刚写的测试。
5. **让失败点报名字。** 静默失败是最大的时间黑洞。
6. **改别人的东西前先问「这是我弄坏的吗」。**
7. **文档跟着状态走。** 过期的文档比没有文档更糟。
8. **别把大二进制放进源码树。**

---

## 六、怎么验证 / How to verify any of this

```powershell
# 构建
git submodule update --init --recursive --depth 1
./build-aux/livehime-win/build-win.ps1 -SkipDependencies

# 跑一遍真实网络自检（结果写到 %LOCALAPPDATA%\LiveHime\selftest.txt）
$env:LIVEHIME_SELFTEST = '1'
./build_x64/rundir/RelWithDebInfo/bin/64bit/obs64.exe
```

`LIVEHIME_SELFTEST_WRITE=1` 会把改标题/发弹幕/开播/停播也跑一遍 —— **默认关闭，
因为那是你频道上的真实动作**。

OBS 日志里可核验的行：

```
[livehime] account state -> ready          ← 登录成功
[livehime] danmaku status -> connected     ← 弹幕握手完成
[livehime] live event -> room              ← 收到房间事件
[livehime] update -> upToDate              ← 更新器找到了正确的仓库
[livehime] danmaku failed at stage -> ...  ← 失败时指出是哪一步
```

---

## 七、署名 / Credits

- **Claude**（Anthropic）—— 写了这个移植所依据的 macOS 实现（53 个补丁的 OBS 分支、
  Qt 控制台、Swift 会话核心、语音字幕、应用内更新、表情、端到端测试、发布流程），
  并参与本移植的若干模块与规格整理。
- **DeepSeek Harness**（DeepSeek，`deepseek-v4-flash`）—— Windows 移植：C++ 会话核心、
  OBS 分支的 Windows 构建、品牌化与版本资源、更新器、以及在 VM 上的全部验证。
- **Codex**（OpenAI）—— macOS 项目早期的接口逆向、登录和 v0.1。

GPL-2.0-or-later，与 OBS Studio 一致。
