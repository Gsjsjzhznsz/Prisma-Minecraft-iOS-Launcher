<div align="center">
  <img src="Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png" alt="Prisma 图标" width="120" style="border-radius: 24px;">
</div>

<h1 align="center">Prisma</h1>
<p align="center"><b>一款面向中国用户深度优化的 iOS Minecraft: Java Edition 启动器</b></p>
<p align="center"><sub>派生自 <a href="https://github.com/herbrine8403/Amethyst-iOS-MyRemastered">Amethyst-iOS-MyRemastered</a></sub></p>

<div align="center">
  <img alt="构建状态" src="https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/actions/workflows/development.yml/badge.svg?branch=main">
  <img alt="下载量" src="https://img.shields.io/github/downloads/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/total?label=Downloads&style=flat">
  <img alt="版本" src="https://img.shields.io/github/v/release/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher?style=flat">
  <img alt="许可证" src="https://img.shields.io/github/license/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher?style=flat">
  <img alt="最后提交" src="https://img.shields.io/github/last-commit/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher?color=c78aff&label=last%20commit&style=flat">
</div>

<p align="center">
  <b>中文</b> | <a href="./README_EN.md">English</a>
</p>

<!-- ★ Task222（清单第 13 项）：QQ 群与贡献入口置顶 -->
<table align="center">
  <tr>
    <td align="center" width="50%">
      <b>💬 QQ 群：1126547426</b><br/>
      <sub>用户交流 · 反馈 · 构建发布通知（启动器「关于」页可一键复制）</sub>
    </td>
    <td align="center" width="50%">
      <b>❤️ 支持我们</b><br/>
      <sub><a href="https://afdian.com/a/yiqiu4178">爱发电</a> · <a href="donate.png">微信赞赏码</a>（关于页同款入口）</sub>
    </td>
  </tr>
</table>

---

## Prisma 是什么？

**Prisma** 是 [Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered) 的定制 Fork，一款面向 iOS 和 iPadOS 的 Minecraft: Java Edition 高端启动器。本 Fork 聚焦**中国用户体验** -- 提供完整的中文本地化、应用内中英文切换、iOS 26+ JIT 直接启动优化，以及来自上游议题审计的 Bug 修复。

> **不知道该用哪个 Fork？** 请查看下方的 [Fork 网络](#fork-网络) 章节，了解各活跃 Fork 的功能对比。

---

## 与上游的差异

| 改动 | 说明 |
|------|------|
| **LWJGL 3.4.1 兼容** | 更新 LWJGL 至 3.4.1 兼容层，支持 Sodium 0.9+ 等要求 LWJGL >= 3.4.1 的模组。采用 herbrine8403 的方案：3.3.x 基础模块 + lwjgl-callback-descriptor.jar (3.4.1) + 源码覆盖层同时兼容两种 Callback API。 |
| **Minecraft 26.3 SDL3 通路** | MC 26.3 弃用 GLFW 改用 SDL3。我们借鉴了 [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) 的 SDL3 嵌入方案：将其 Android 端 `sdl_hook.c` 兼容层移植为 `Natives/sdl3_hook.m`（ES profile 强制、主窗口复用、Vulkan 加载器句柄共享、EGL 兼容重试），并随包发布打了补丁的 `libSDL3.dylib`（`patches/sdl3-amethyst.patch`：uikit 触摸穿透、文本框重挂安全、宿主视图嵌入）。 |
| **原生分辨率渲染修复** | 根因定位并修复了整个分辨率链路：EGL 查询常量对调、1x 渲染钉扎、SDL3 点/像素尺寸分裂。游戏现以原生 2x retina 分辨率 1:1 渲染，SDL3（26.3）与 LWJGL/GLFW（26.2）两条路径画面均锐利。 |
| **像素级精准触控** | 修复长期存在的输入错位 bug（输入桥像素/点语义错配）。触控坐标现在精确落在手指所在位置，游戏内与菜单均准确。 |
| **键位调整编辑器修复** | 修复保存控件时闪退（`unrecognized selector doUpdateButton:from:to:`，编辑器被 UINavigationController 包裹呈现所致）并恢复设置入口的全屏编辑画布。撤销记录现与编辑器同生命周期。 |
| **窗口模式恢复** | 恢复 iPadOS 26 多任务/窗口化（移除 `UIRequiresFullScreen`）。此前怀疑窗口模式导致画面分裂/模糊，后经取证排除——真因（EGL 常量、px/pt 语义）已另行修复。后台稳定性（MINIMIZED 事件处理）与呈现模式无关，继续生效。 |
| **JIT 优化重连** | 在非 iOS 26 设备上，JIT 已启用时直接启动游戏。在 iOS 26+ 需要调试 JIT 映射的设备上，静默加载 UniversalJIT26 脚本（不显示等待对话框），避免后台切换闪退的同时确保 brk 指令能被正确处理。 |
| **应用内语言切换** | 在设置 > 通用中新增语言选择器，支持跟随系统、简体中文、English 三种选项，切换后立即生效无需重启。 |
| **增强中文本地化** | 完整中文界面翻译（2000+ 行），覆盖比上游更全面。 |
| **上游议题审计 Bug 修复** | 通过系统性审查上游及上上游 GitHub 议题，修复了 8+ 个 Bug，包括 JIT 脚本加载 nil 崩溃、UIKit 线程安全、KVO 观察者清理等。 |
| **v6.0.0：mg 全后端 FSR + 装机反馈四连修** | **mg 三个后端（Vulkan 直连 / GLES / OpenGL 4.0）全部支持 FSR 1.0 超分**——其中 Vulkan 直连通过 Metal 呈现层拦截方案实现（私有低分辨率交换层 + AMD FSR1 EASU/RCAS 移植到 Metal，MobileGL/MoltenVK 二进制零改动）；另修复装机反馈四项：CurseForge 镜像网关错误不再被静默吞掉（自动重试 + 真实错误显示）、本地整合包从"文件"App/下载/iCloud 任意位置可直接安装、主页头像 10s 超时 + 磁盘缓存秒显、JIT 等待 120s 超时 + 重试弹窗（不再无限卡在"正在开启 JIT"）；公告支持置顶（推荐服务器 mysv.dpdns.org 置顶显示）。 |
| **Makefile 健壮性** | 修复 TAB 缩进被转为空格导致 CI 构建失败的问题。 |
| **Zink（Mesa 25.0.7）渲染器 + FSR1 管线** | 完整的 OSMesa/zink 桥接：分相位呈现计时、双哨兵 EASU 验证、视口自适应上采样、消灭重复全幅回读的 bundle-direct 快路径。设置 > 视频内五档 FSR 预设可在分辨率与帧率间取舍。 |
| **MobileGL 渲染后端单一选项** | 设置 > MobileGlues > 「渲染后端」（v6.0.0 口径，不占渲染器列表）：Vulkan 直连（默认，DirectVulkan 直呈，无逐帧 CPU 回读，实测最流畅，且经 Metal 呈现层拦截方案支持 FSR）/ GLES / OpenGL 4.0。仅对"自动"渲染器生效——显式选择的渲染器永远优先；GLES/4.0 路径同样支持 FSR 画质档。 |
| **崩溃根治系列** | 二进制级修复：glslang 左值栈踩踏（7 重防护机器码补丁 + SIGSEGV 恢复网）、spark 签名 macOS 采样库（dlopen 拦截 + iPadOS 27 平台重标签后的 ad-hoc 重签名）、26.3 OpenAL `alcEventIsSupportedSOFT` NPE（绝对路径 pin，阻断 classpath natives 劫持）。 |
| **帧率解锁系列** | 26.x AFK/闲置限帧器中和（options.txt 去重写入 + 45s 滚轮心跳）；dynamic_fps 模组的窗口状态机前台读到 FOCUSED（30fps 钉死根因修复）、后台读到 UNFOCUSED（限帧类模组在后台过渡期合法省电）。 |
| **键盘自动弹出修复** | SDL 文本输入入口（Start/Stop TextInput、SetTextInputArea）主线程化 + 将 `SDL_ENABLE_SCREEN_KEYBOARD=1` 覆盖回 MC 桌面惯例的 0 —— 游戏内输入框光标闪烁时键盘正常自动弹出。 |
| **新拟态 UI + 自定义背景** | 全面新拟态化重设计：深浅双主题、自定义图片/视频背景 + 毛玻璃卡片、可自定义强调色/文字色/卡片色、主界面图标自愈管线。 |
| **更新检测指向本仓库 + 启动时自动检查** | 应用内检查更新与发布页链接现指向本仓库（此前指向上游）；启动器启动时自动检测新版本，发现新版以应用内卡片通知提示（点击直达发布页），无新版时完全静默，可在设置中关闭。 |
| **第三方登录完整恢复** | LittleSkin / 自定义 authlib-injector 服务器（外置登录）：FCL 风格卡片式登录表单、多角色账户、皮肤与正版服务器验证全部可用。登录组件随包内置（不再依赖在线下载）；令牌过期的账户仍可选中启动并提示重新登录。 |
| **正版登录提示改进** | 微软账户登录的结果提示改为自动消失的应用内通知；修复了系统弹窗需要手动处理才能消失的问题。 |
| **子面板新拟物设计** | 所有子级面板（账户、下载、Mod 管理、文件列表、帮助等约 30 个）统一新拟物基底样式，与主界面/设置页设计语言一致；自定义背景透出的面板不受影响。 |
| **设置项本地化补全** | 所有设置行（含 UI 刷新新增的全部详情脚注）中英文完整本地化 —— 任何位置不再显示原始 key。 |
| **26.1.x/26.2 整合包崩溃链修复** | 26.1.2 的 SoundEngine NPE（OpenAL 扩展守卫缺失）由内置 OpenAL 垫片根治；controlify/JNA 的 SIGBUS（libffi 闭包页在 iOS 上不可执行）四层拦截：dlsym 层对 `SDL_SetEventFilter`/`SDL_AddEventWatch` 的 no-op 守卫 + 内置 libSDL3.dylib 二进制入口机器码守卫（非空事件回调在 SDL 函数入口一律置空/拒绝，与调用方符号解析路径完全无关）+ JVM 自身 dlopen/dlsym 槽的经典/chained-fixup 双法重绑定 + 200ms dyld 镜像扫描看门狗（无论 JVM 走哪条加载路径都能兜住 JNA 解包的 `jna*.tmp`）。；controlify 根治后新增的"进世界闪退"最终定案为语音模组麦克风采集的 AVAudioEngine tap 格式不匹配异常——现按设备原生格式装 tap 并在回调内重采样，麦克风不可用时优雅降级为无麦，绝不闪退。 |
| **渲染器每游戏强制单选 + 全后端修复** | 设置页的全局渲染器选择退役，每个游戏在自己的设置页单独选择渲染器（未单独设置过的实例缺省"自动"，1.17+ 自动解析为 MobileGL Vulkan 直连）——渲染器列表中 MobileGL 家族合并为唯一的 mg 条目（不写后端，后端在 设置 > MobileGlues > 渲染后端 选择，默认 Vulkan 直连）；MobileGL 两后端的 FSR 因符号解析命中错误图形库从未生效，现已根治（符号从渲染器 dylib 句柄直连）；OpenGL 4.0 (Mithril) 上下文参数错误导致的启动崩溃已修复。 |
| **TouchController 静态库模式** | 触摸事件双通道投递（native 单例 + 模组 UDP 回落），菜单与游戏内触控一致可用；屏蔽控件只隐藏启动器自带经典按钮、保留模组自己的虚拟按钮（内置完整布局），存量空布局配置下次启动自动修复。 |
| **Forge 安装 JIT 自动申请** | 处理器执行需要 JIT 时不再弹错，与启动游戏同款自动跳转申请并等待；iOS 26+ 无活跃调试器时自动重附 JIT 脚本。 |
| **iPhone 右侧边栏精简** | 96pt 图标轨（头像 + 启动/选版本/执行JAR 图标按钮），信息卡仅在 iPad 展示。 |
| **TouchController 模组双 ABI 传输层** | 内置 iOS 传输层同时服务两代 TouchController 模组：旧句柄制（`new(path)/receive(handle,buffer)`）与 26.2 世代单例制（`init()/receive(buffer)`）共用同一组 JNI 符号，以零解引用的指针注册表判别分发；鉴于 mod 0.3.1-alpha14 的静态库分支在上游尚未完成，静态库模式现在会自动附带模组自带的 legacy UDP 通道（端口 12450）作为回落——任何当前版本模组都能开箱即用；“屏蔽控件”开关只隐藏启动器自带控件（模组虚拟按钮保留，见上）。 |
| **JIT 开启工具选择（LiveContainer 方案）** | 没装 StikDebug 的用户不再遭遇“点了没反应”：设置 > 调试提供 自动 / StikDebug / SideStore / StosDebug / JitStreamer-EB / TrollStore / 手动 七选，各自分发正确的 URL scheme；另提供独立开关，把 UniversalJIT26.js 脚本从 iOS 26+ 的 JIT 请求中剥离（供不支持脚本的工具）。 |
| **第三方皮肤头像本地渲染** | Yggdrasil profile URL 改用无连字符 UUID（带连字符在 Blessing Skin 系直接 404），会话内立即下载签名皮肤纹理并本地渲染头像（脸 + 帽层）落盘为 `file://` URL —— 存量账户首次启动自愈，首页磁贴实时刷新无需重启。 |
| **仓库托管公告 + FSR RCAS 锐化** | 启动器公告随仓库 `announcements.json` 发布（raw.githubusercontent.com 主源 / jsDelivr 镜像 / 离线兑底），零第三方接口依赖；FSR 在 MobileGL 与 zink 管线上新增 RCAS 锐化 pass（7 档滑杆）。 |
| **多人联机恢复（陶瓦 + ZeroTier）** | 陶瓦联机（与 HMCL/FCL/ZL2 互通）与 ZeroTier 双入口恢复：FCL 风格联机界面 + 局域网端口自动检测（日志尾随 + 本机扫描验证）+ 30 秒等待提示；lazy 初始化设计（启动路径不创建联机管理器，不引入旧启动崩溃风险）；同步上游切后台回前台卡死修复（暂停判据放宽 + 回前台呈现面自愈，对 zink/mg/所有渲染器生效）。 |

---

## Fork 谱系

```
PojavLauncherTeam/PojavLauncher_iOS          (最初的上游 - 官方 PojavLauncher iOS 移植版)
        |
        v
herbrine8403/Amethyst-iOS-MyRemastered       (主要重制版 Fork - UI 重构、Mod 管理、
                                            BMCLAPI 支持、多账户、自动渲染器/JVM)
        |
        v
Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher       (本仓库 - 中国用户体验、JIT 优化、
                                            应用内语言切换、Bug 修复、LWJGL 3.4.1)
```

---

## 目录

- [Prisma 是什么？](#prisma-是什么)
- [与上游的差异](#与上游的差异)
- [Fork 谱系](#fork-谱系)
- [核心特性](#核心特性)
- [快速上手](#快速上手)
  - [设备要求](#设备要求)
  - [侧载准备](#侧载准备)
  - [安装步骤](#安装步骤)
  - [启用 JIT](#启用-jit)
- [贡献者](#贡献者)
- [Fork 致谢](#fork-致谢)
- [第三方组件](#第三方组件)
- [捐赠](#捐赠)

## 核心特性

- **全新的现代化 UI** -- UI 界面深度美化，更符合现代设计风格
- **资源管理/下载** -- 浏览、启用、禁用和删除 Mod、光影包、资源包等各种资源，集成 Modrinth/CurseForge 下载支持。
- **整合包导入** -- 直接在启动器内导入 ZIP 格式的整合包。
- **下载源切换** -- 用户可在 Mojang 官方源、BMCLAPI 镜像源等之间切换，获得最佳下载速度。
- **完整中文本地化** -- 界面完整汉化，提供原生级中文语言体验。可在设置中切换中英文，无需重启。
- **账户限制解除** -- 支持本地账户、演示模式和第三方认证，无需 Microsoft 账户即可下载和游玩。
- **多账户支持** -- 在 Microsoft 账户、本地账户和第三方认证账户之间无缝切换。
- **自动渲染器选择** -- 设为 Auto 时自动选择最优渲染后端（含 MobileGlues、MoltenVK 等渲染器）。
- **适配 Minecraft 26.X** -- 添加 Minecraft 26.X 支持（实验性）：26.2 走 LWJGL/GLFW 通路，26.3+ 走 SDL3 通路（嵌入方案借鉴自 ZalithLauncher2）。
- **自定义鼠标指针** -- 在设置中自定义虚拟鼠标指针皮肤。
- **TouchController 支持** -- 通过 UDP 和 XCFramework 两种通信方式与 TouchController Mod 通信，为 iOS 提供完整的触屏控制。
- **AI 深度集成** -- (开发中，目标为实现 AI 完全管理启动器，包括资源下载、实例管理等功能)
- ... 还有更多功能等着您探索！


> [!NOTE]
> 暂无计划将重制版移植至 Android 平台。Android 生态已有诸多优秀启动器，如 [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2)、[Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher)。如需官方 Android 版本，请前往 [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android)。

## 快速上手

完整文档请参阅 [Amethyst 官方 Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios) 或 [B站教程视频](https://b23.tv/KyxZr12)。以下为精简指南。

### 设备要求

| 级别 | iOS 版本 | 支持机型 |
|------|----------|----------|
| **最低配置** | iOS 14.0+ | iPhone 6s+、iPad 5 代+、iPad Air 2+、iPad mini 4+、全部 iPad Pro、iPod touch 7 代 |
| **推荐配置** | iOS 14.5+ | iPhone XS+（不含 XR/SE 2 代）、iPad 10 代+、iPad Air 4 代+、iPad mini 6 代+、iPad Pro（不含 9.7 英寸） |

> [!CAUTION]
> iOS 14.0--14.4.2 存在已知的严重兼容性问题，**强烈建议升级至 iOS 14.5 或更高版本。** iOS 17.x 和 18.x 受支持，但首次配置 JIT 需要电脑辅助（参见[官方 JIT 指南](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)）。

### 侧载准备

优先选择支持「永久签名 + 自动 JIT」的工具：

1. **TrollStore** *(推荐)* -- 永久签名、自动启用 JIT、提升内存上限。兼容部分 iOS 版本。[从官方仓库下载](https://github.com/opa334/TrollStore)
2. **AltStore / SideStore** *(替代方案)* -- 需定期重签；首次设置需要电脑和 Wi-Fi。仅兼容**开发证书**（必须含 `com.apple.security.get-task-allow` 权限才能启用 JIT）。不支持分发证书签名服务。

> [!WARNING]
> 仅从官方或可信来源下载侧载工具和 IPA 文件。因使用非官方软件导致的设备问题，作者不承担责任。越狱设备支持永久签名，但不建议在日常设备上越狱。

### 安装步骤

<details>
<summary><b>正式版（TrollStore 渠道）</b></summary>

1. 前往 [Releases](https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/releases) 下载 `.tipa` 安装包。
2. 通过系统分享菜单，选择用 TrollStore 打开，即可自动完成安装。
</details>

<details>
<summary><b>正式版（AltStore / SideStore 渠道）</b></summary>

1. 前往 [Releases](https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/releases) 下载 `.ipa` 安装包。
2. 按照侧载工具的标准流程导入 IPA 完成安装。
</details>

<details>
<summary><b>Nightly 测试版（每日构建）</b></summary>

> [!CAUTION]
> 测试版可能包含崩溃、无法启动等严重缺陷，仅限开发测试使用。

1. 前往 [GitHub Actions](https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/actions) 页面下载最新 IPA 构建产物。
2. 在侧载工具（AltStore、SideStore 等）中导入 IPA 完成安装。
</details>

### 启用 JIT

JIT（即时编译）是流畅运行游戏的关键。请根据自身环境选择合适的方案：

| 工具 | 需外部设备 | 需 Wi-Fi | 自动启用 | 备注 |
|------|:---:|:---:|:---:|-------|
| TrollStore | 否 | 否 | 是 | 首选方案，无需额外操作 |
| AltStore | 是 | 是 | 是 | 需本地网络运行 AltServer |
| SideStore | 仅首次 | 仅首次 | 否 | 初始设置后无需设备/网络 |
| StikDebug | 仅首次 | 仅首次 | 是 | 初始设置后无需设备/网络 |
| Jitterbug | 是（无 VPN 时） | 是 | 否 | 需手动触发 |
| 已越狱设备 | 否 | 否 | 是 | 系统级自动支持 |

## 贡献者

- [@herbrine8403](https://github.com/herbrine8403) -- Amethyst-iOS-MyRemastered 原项目作者
- [EternityQwQ](https://github.com/EternityQwQ) -- 添加 Metal Universal Mod 支持
- [@LanRhyme](https://github.com/LanRhyme) -- iOS 26 兼容性适配及日志改进
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) -- Mod 下载功能集成、TouchController 优化
- [@Li2548](https://github.com/Li2548) -- 上游同步维护

## 社区

- **QQ 群：1126547426** -- 用户交流、反馈与构建发布通知（启动器的"关于"页也展示群号，支持一键复制）。

## 许可证

本启动器以 **GNU Affero General Public License v3.0（AGPL-3.0）** 授权。

- 完整许可证文本即仓库根目录的 [`LICENSE`](./LICENSE) 文件——**该文件就是许可证内容所在处**。
- 第三方组件保留各自许可证：见下方表格及 `ThirdParty/`、`Natives/external/` 目录内的许可证/说明文件（如 PojavLauncher 血统 GPL-3.0、MobileGlues LGPL-3.0、gl4es MIT 等）。
- 依照上游（AGPL）的要求，本 Fork 保持许可证不变、说明许可证内容所在位置，并持续公开全部源代码。

## Fork 致谢

本项目基于以下 Fork 链构建，特此致谢：

- **[PojavLauncherTeam/PojavLauncher_iOS](https://github.com/PojavLauncherTeam/PojavLauncher_iOS)** -- 最初的 iOS Minecraft 启动器，一切的起点。
- **[herbrine8403/Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered)** -- 主要重制版 Fork，添加了现代化 UI、Mod 管理、BMCLAPI 下载源、多账户、自动渲染器/JVM 选择等功能。这是 Prisma 的直接上游。
- **[ZalithLauncher/ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2)** -- Minecraft 26.3+ 使用的 SDL3 窗口嵌入方案借鉴自该项目：其 Android 端 `sdl_hook.c` 兼容层被移植为 iOS 端的 `Natives/sdl3_hook.m`，其 SDL 嵌入补丁也启发了我们针对 SDL uikit 后端的 `patches/sdl3-amethyst.patch`。以 `ThirdParty/ZalithLauncher2` 子模块形式随仓库引用。

## 第三方组件

| 组件 | 用途 | 许可证 | 来源 |
|------|------|--------|------|
| SDL3 | MC 26.3+ 的游戏窗口与输入后端（嵌入宿主视图，已打补丁） | zlib | [GitHub](https://github.com/libsdl-org/SDL) -- 经 `patches/sdl3-amethyst.patch` 打补丁；嵌入方案借鉴自 [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) |
| Caciocavallo | AWT 运行时框架 | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | 代码注解支持 | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | 核心功能适配 | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL 到 GLES 转译 | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3D 图形库 | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal 到 OpenGL ES 转译 | BSD-2 | [GitHub](https://github.com/khanhduytran0/MetalANGLE) |
| MoltenVK | Vulkan 到 Metal 转译 | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | 跨平台 3D 音频 | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java 运行时（8/17/21/25） | GPL-2.0 | [官网](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java 游戏开发库 | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 兼容层 | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI 滑块控件 | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | 动态库重绑定 | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan 着色器编译 | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | 文件管理工具 | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore 集成 | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIP 解压处理 | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | 库验证绕过 | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | 第三方渲染器 | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core 到 ES 封装 | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | 第三方认证支持 | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

额外感谢 [MCHeads](https://mc-heads.net) 提供 Minecraft 头像服务、[Modrinth](https://modrinth.com) 提供资源分发服务，以及 [BMCLAPI](https://bmclapidoc.bangbang93.com) 提供 Minecraft 下载镜像服务。

## 捐赠

如果您觉得这个项目对您有价值，欢迎通过 [爱发电](https://afdian.com/a/yiqiu4178) 或[微信赞赏码](donate.png) 进行捐赠支持。

## Star History

<a href="https://star-history.com/#Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher&Date">
 <picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher&type=Date&theme=dark" />
  <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher&type=Date" />
  <img alt="Star history" src="https://api.star-history.com/svg?repos=Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher&type=Date" />
 </picture>
</a>
