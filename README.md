<div align="center">
  <img src="Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png" alt="Prisma Icon" width="120" style="border-radius: 24px;">
</div>

<h1 align="center">Prisma</h1>
<p align="center"><b>A polished Minecraft: Java Edition launcher for iOS, optimized for Chinese users.</b></p>
<p align="center"><sub>Forked from <a href="https://github.com/herbrine8403/Amethyst-iOS-MyRemastered">Amethyst-iOS-MyRemastered</a></sub></p>

<div align="center">
  <img alt="Build Status" src="https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/actions/workflows/development.yml/badge.svg?branch=main">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/total?label=Downloads&style=flat">
  <img alt="Release" src="https://img.shields.io/github/v/release/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher?style=flat">
  <img alt="License" src="https://img.shields.io/github/license/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher?style=flat">
  <img alt="Last Commit" src="https://img.shields.io/github/last-commit/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher?color=c78aff&label=last%20commit&style=flat">
</div>

<p align="center">
  <a href="./README.md">English</a> | <a href="./README_CN.md">Chinese</a>
</p>

---

## What is Prisma?

**Prisma** is a customized fork of [Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered), a premium Minecraft: Java Edition launcher for iOS and iPadOS. This fork focuses on the **Chinese user experience** -- delivering robust Chinese localization, in-app language switching, streamlined JIT handling for iOS 26+, and bug fixes sourced from upstream issue audits.

> **Not sure which fork to use?** See the [Fork Network](#fork-network) section below for a comparison of active forks and their unique features.

---

## What's Different from Upstream

| Change | Description |
|--------|-------------|
| **LWJGL 3.4.1 Compatibility** | Updated LWJGL to a 3.4.1-compatible layer, enabling mods like Sodium 0.9+ that require LWJGL >= 3.4.1. Uses developer herbrine8403's approach: 3.3.x base modules + lwjgl-callback-descriptor.jar (3.4.1) + source overlay for dual-API compatibility. |
| **Minecraft 26.3 via SDL3** | MC 26.3 dropped GLFW for SDL3. We ported the SDL3-embedding approach from [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) (its Android `sdl_hook.c` became `Natives/sdl3_hook.m`: ES profile forcing, main-window reuse, Vulkan loader handle sharing, EGL compat retry) and ship a patched `libSDL3.dylib` (`patches/sdl3-amethyst.patch`: uikit touch passthrough, text-field re-add safety, host-view embedding). |
| **Native-Resolution Rendering Fix** | Root-caused and fixed the entire resolution chain: swapped EGL query constants, 1x render-scale pin, and SDL3 point/pixel size split. The game now renders 1:1 at native 2x retina resolution with sharp visuals on both the SDL3 (26.3) and LWJGL/GLFW (26.2) paths. |
| **Pixel-Accurate Touch Input** | Fixed the long-standing input-offset bug (pixel-vs-point semantic mismatch across the input bridge). Touch coordinates now land exactly where your finger is, in-game and in menus. |
| **Custom Controls Editor Fixes** | Fixed the crash when saving an edited control (`unrecognized selector doUpdateButton:from:to:` -- the editor was presented through a UINavigationController wrapper) and restored the full-screen editing canvas from the Settings entry. Undo history is now scoped to the editor's lifetime. |
| **Windowed Mode Restored** | iPadOS 26 multitasking/windowing re-enabled (`UIRequiresFullScreen` removed). The earlier suspicion that windowed mode caused the split-picture/blur bugs was disproven -- the true root causes (EGL constants, px/pt semantics) were fixed instead. Backgrounding resilience (MINIMIZED event handling) is mode-independent and stays. |
| **Optimized JIT Re-launch** | When JIT is already enabled on non-iOS-26 devices, the game launches directly without re-requesting via stikjit://. On iOS 26+ devices that require debug JIT mapping, the UniversalJIT26 script is loaded silently (without showing a waiting dialog) to avoid background transition crashes while still ensuring brk instructions are handled. |
| **In-App Language Switching** | Added a language picker in Settings > General that allows switching between Follow System, Simplified Chinese, and English without restarting the app. The `localize()` function respects the user's choice while maintaining the full fallback chain. |
| **Enhanced Chinese Localization** | Complete Chinese UI translation (2000+ lines), more comprehensive than upstream. |
| **Bug Fixes from Upstream Issue Audit** | 8+ bug fixes identified through systematic review of upstream and upstream's upstream GitHub issues, including nil crash in JIT script loading, UIKit thread safety, KVO observer cleanup, and more. |
| **v6.0.0: FSR on All mg Backends + Device-Feedback Quadruple Fix** | **All three mg backends (Vulkan-direct / GLES / OpenGL 4.0) now support FSR 1.0 upscaling** -- Vulkan-direct via a Metal presentation-layer intercept (private low-res swap layer + AMD FSR1 EASU/RCAS ported to Metal, zero MobileGL/MoltenVK binary changes). Plus four device-feedback fixes: CurseForge mirror gateway errors are no longer silently swallowed (auto-retry + real error surfaced), local modpacks import directly from anywhere in the Files app / Downloads / iCloud, the home avatar loads with a 10s timeout + disk cache, and JIT waits are bounded at 120s with a retry dialog (no more infinite "enabling JIT" spinner). Announcements support pinning (the recommended server mysv.dpdns.org is pinned first). |
| **Makefile Robustness** | Fixed TAB-to-space indentation issues that caused CI build failures. |
| **Zink (Mesa 25.0.7) Renderer + FSR1 Pipeline** | Full OSMesa/zink bridge with per-phase present timing, dual-sentinel EASU validation, viewport-adaptive upscaling, and a bundle-direct fast path that eliminates duplicate full-surface readbacks. Five FSR presets trade resolution for fps in Settings > Video. |
| **MobileGL Vulkan Direct-Present Option** | A single switch in Settings > Video (next to the ANGLE ES driver option) launches with MobileGL's DirectVulkan backend (GL -> Vulkan -> MoltenVK -> CAMetalLayer direct present, no per-frame CPU readback). The renderer list stays uncluttered by design. |
| **Crash Root-Cause Series** | Binary-level fixes for: glslang lvalue stack-corruption (7-guard machine-code patch + SIGSEGV recovery net), spark's signed macOS profiler lib (dlopen blocklist + ad-hoc re-signing after platform retag on iPadOS 27), and the 26.3 OpenAL `alcEventIsSupportedSOFT` NPE (absolute-path pin defeating classpath natives hijacking). |
| **Frame-Rate Unlock Series** | 26.x AFK/inactivity limiters neutralized (options.txt dedup writes + 45s wheel heartbeat); the dynamic_fps mod's window-state machine now reads FOCUSED in the foreground (30fps pin root-caused and fixed) and UNFOCUSED in the background so throttle mods legitimately save power during background transitions. |
| **On-Screen Keyboard Auto-Open Fix** | SDL text-input entry points (Start/Stop TextInput, SetTextInputArea) marshalled to the main thread and `SDL_ENABLE_SCREEN_KEYBOARD=1` re-asserted over MC's desktop-convention 0 -- the keyboard now opens when an in-game text field gains a blinking cursor. |
| **Neomorph UI + Custom Backgrounds** | Full neomorphism redesign with dual light/dark themes, custom image/video backgrounds with glass-blur cards, customizable accent/text/card colors, and a self-healing main-screen icon pipeline. |
| **Self-Hosted Update Checks + Auto Check on Launch** | In-app update checks and release-page links now target this repo (previously the upstream); the launcher also checks for new releases automatically on startup -- a new version surfaces as an in-app card notification (tap to open the release page), total silence otherwise, disableable in Settings. |
| **Third-party Login Fully Restored** | LittleSkin / custom authlib-injector servers (external Yggdrasil auth): FCL-style card login form, multi-profile accounts, skins and server authentication all working. The login component ships in the app bundle (no online download dependency); accounts with expired tokens can still be selected and launch, with a re-login hint. |
| **Microsoft Login Notice Rework** | Genuine-account login result notices are now auto-dismissing in-app notifications; fixed the system-style popup that had to be manually dismissed. |
| **Sub-panel Neumorphic Design** | All sub-level panels (~30 of them: accounts, downloads, mod management, file lists, help, ...) now share the neumorphic base style of the main UI; panels with custom background pass-through are unaffected. |
| **Complete Settings Localization** | Every settings row (including all detail footers added by the UI refresh) is fully localized in Chinese and English -- no raw keys shown anywhere. |
| **26.1.x/26.2 Modpack Crash Chain Fixes** | 26.1.2's SoundEngine NPE (missing OpenAL extension guard) fixed by a bundled OpenAL shim; the controlify/JNA SIGBUS (libffi closure pages are non-executable on iOS) intercepted at four layers -- dlsym-level no-op guards for `SDL_SetEventFilter`/`SDL_AddEventWatch`, a machine-code entry guard patched into the bundled libSDL3.dylib itself (non-NULL event callbacks are nullified/rejected inside the SDL binary, fully independent of how the caller resolved the symbol), classic + chained-fixup rebinding of the JVM's own dlopen/dlsym slots, and a 200ms dyld image-scan watchdog that catches JNA's extracted `jna*.tmp` regardless of the JVM's load path. |
| **TouchController Mod: Dual-ABI Transport** | The bundled iOS transport now serves BOTH generations of the TouchController mod natively: the legacy handle-based ABI (`new(path)/receive(handle,buffer)`) and the 26.2-era singleton ABI (`init()/receive(buffer)`) share the same JNI symbols, discriminated by a zero-deref pointer registry -- plus a chain-independent 200ms scan. Because mod 0.3.1-alpha14's static-library branch is unfinished upstream, Static Library mode now also arms the mod's own legacy UDP channel (port 12450) as an automatic fallback, so touch controls work out of the box on every current mod version. The "Hide Launcher Controls" option now hides only the launcher's own classic button layer, keeping the mod's virtual buttons (built-in full layout); polluted empty-layout configs from earlier builds are remediated on next launch. |
| **Task 139 field fixes** | World-join crash on 26.1.2 traced to Simple Voice Chat's microphone (AVAudioEngine tap format mismatch) -- native-format capture + in-callback resampling + graceful no-mic degradation; MobileGL-gles input misalignment fixed (FSR-heal input-scale reset); OpenGL 4.0 experimental backend ships with the bundled Mithril dylib; renderer selection is now per-game mandatory -- the Settings global picker is retired ([revertable] removal), games without an explicit choice default to Auto (1.17+ resolves to MobileGL Vulkan direct), and the MobileGL family stays collapsed into the single mg entry with the backend picked in Settings > MobileGlues (Vulkan direct by default); MobileGL FSR fixed on both backends (symbols now dlsym'd from the renderer dylib handle instead of the flat namespace hitting ANGLE); Mithril OpenGL 4.0 startup crash fixed (desktop-GL context attribs); TouchController static-library mode dual-sends events (in-world touch restored) and Hide-Controls keeps the mod's buttons while hiding the launcher's own; Forge/NeoForge install auto-requests JIT like game launch (with the iOS 26+ debugger re-attach); iPhone right panel streamlined to a 96pt icon rail. |
| **JIT Enabler Picker (LiveContainer-style)** | Users without StikDebug no longer get a dead "tap does nothing" flow: Settings > Debug now offers Auto / StikDebug / SideStore / StosDebug / JitStreamer-EB / TrollStore / Manual, each dispatching the correct URL scheme. A separate toggle strips the UniversalJIT26.js script from iOS 26+ JIT requests for tools that don't support scripts. |
| **Third-party Skin Avatars Rendered Locally** | Yggdrasil profile URLs use the undashed UUID form (hyphenated form 404s on Blessing Skin servers), the signed one-time skin texture is downloaded in-session and the avatar (face + hat layer) is rendered locally to a `file://` URL -- existing accounts self-heal on first launch and the home tile refreshes live, no restart needed. |
| **Repo-Hosted Announcements + FSR RCAS Sharpening** | Launcher announcements ship as `announcements.json` in this repo (raw.githubusercontent.com primary, jsDelivr mirror, offline fallback) -- no third-party API dependency. FSR gains an RCAS sharpening pass (7-step slider) on the MobileGL and zink pipelines. |

---

## Fork Lineage

```
PojavLauncherTeam/PojavLauncher_iOS          (Original upstream - official PojavLauncher iOS port)
        |
        v
herbrine8403/Amethyst-iOS-MyRemastered       (Major remastered fork - UI overhaul, mod management,
                                            BMCLAPI support, multi-account, auto renderer/JVM)
        |
        v
Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher       (THIS REPO - Chinese UX, JIT optimization,
                                            in-app language switch, bug fixes, LWJGL 3.4.1)
```

---

## Table of Contents

- [What is Prisma?](#what-is-prisma)
- [What's Different from Upstream](#whats-different-from-upstream)
- [Fork Lineage](#fork-lineage)
- [Core Features](#core-features)
- [Quick Start](#quick-start)
  - [Device Requirements](#device-requirements)
  - [Sideload Preparation](#sideload-preparation)
  - [Installation](#installation)
  - [Enabling JIT](#enabling-jit)
- [Contributors](#contributors)
- [Fork Acknowledgments](#fork-acknowledgments)
- [Third-Party Components](#third-party-components)
- [Sponsor](#sponsor)

## Core Features

- **Modern UI Redesign** -- The interface has been deeply refined for a contemporary, polished visual style.
- **Resource Management & Downloads** -- Browse, enable, disable, and delete mods, shader packs, resource packs, and other assets, with integrated Modrinth and CurseForge download support.
- **Modpack Import** -- Import ZIP-format modpacks directly from the launcher interface.
- **Smart Download Sources** -- Switch between Mojang Official, BMCLAPI mirror, and other sources on the fly for optimal download speeds.
- **Complete Chinese Localization** -- Fully translated interface with native-quality Chinese language support. In-app language switching between Chinese and English available in Settings.
- **Unrestricted Accounts** -- Local accounts, demo mode, and third-party authentication all supported; no Microsoft account required to download and play.
- **Multi-Account** -- Seamlessly switch between Microsoft, local, and third-party authentication accounts.
- **Auto Renderer Selection** -- Automatically chooses the optimal rendering backend (including MobileGlues, MoltenVK, and more) when set to Auto.
- **Auto JVM Selection** -- Automatically selects the correct JVM version (Java 8, 17, 21, or 25) based on the game version.
- **Minecraft 26.X Support** -- Experimental support for Minecraft 26.x: 26.2 runs through the LWJGL/GLFW path, 26.3+ runs through the SDL3 path (embedding approach ported from ZalithLauncher2).
- **Custom Mouse Pointer** -- Customize the virtual mouse pointer skin in settings.
- **Custom News URL** -- Configure a custom news feed URL for the launcher home screen.
- **TouchController Support** -- Communicates with the TouchController mod via both UDP local proxy and XCFramework, delivering full touchscreen control on iOS.
- **AI Integration** -- (In development) The goal is to enable AI to fully manage the launcher, including resource downloads and instance management.
- **Custom App Icons** -- (In development)

... and much more to explore!

> [!NOTE]
> There are no plans to port this remastered version to Android. The Android ecosystem already has excellent launchers such as [Zalith Launcher](https://github.com/ZalithLauncher/ZalithLauncher), [Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher), and ShardLauncher. For the official Android version, visit [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android).

## Quick Start

For complete documentation, refer to the [Amethyst Official Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios) or the [Bilibili tutorial](https://b23.tv/KyxZr12). Below is a condensed guide.

### Device Requirements

| Tier | iOS Version | Supported Devices |
|------|-------------|-------------------|
| **Minimum** | iOS 14.0+ | iPhone 6s+, iPad 5th gen+, iPad Air 2+, iPad mini 4+, all iPad Pro, iPod touch 7th gen |
| **Recommended** | iOS 14.5+ | iPhone XS+ (excl. XR/SE 2nd gen), iPad 10th gen+, iPad Air 4th gen+, iPad mini 6th gen+, iPad Pro (excl. 9.7-inch) |

> [!CAUTION]
> iOS 14.0--14.4.2 has known critical compatibility issues. **Upgrading to iOS 14.5 or later is strongly recommended.** iOS 17.x and 18.x are supported but require a companion computer for initial JIT configuration (see the [Official JIT Guide](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)).

### Sideload Preparation

Prioritize tools that support permanent signing and automatic JIT enablement:

1. **TrollStore** *(Recommended)* -- Permanent signing, automatic JIT, increased memory limits. Compatible with select iOS versions. [Download from official repo](https://github.com/opa334/TrollStore)
2. **AltStore / SideStore** *(Alternative)* -- Requires periodic re-signing; initial setup needs a computer and Wi-Fi. Only compatible with **development certificates** (must include `com.apple.security.get-task-allow` entitlement for JIT). Distribution certificate signing services are not supported.

> [!WARNING]
> Only download sideloading tools and IPA files from official or trusted sources. The author is not responsible for device issues caused by unofficial software. Jailbroken devices support permanent signing, but daily-driver jailbreaking is not recommended.

### Installation

<details>
<summary><b>Official Release (TrollStore)</b></summary>

1. Download the `.tipa` package from [Releases](https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/releases).
2. Open the file with TrollStore via the system share menu to complete installation.
</details>

<details>
<summary><b>Official Release (AltStore / SideStore)</b></summary>

1. Download the `.ipa` package from [Releases](https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/releases).
2. Import the IPA into your sideloading tool following its standard installation procedure.
</details>

<details>
<summary><b>Nightly Builds (Development Testing)</b></summary>

> [!CAUTION]
> Nightly builds may contain critical bugs including crashes and startup failures. Use only for development and testing purposes.

1. Navigate to the [GitHub Actions](https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/actions) page and download the latest IPA artifact.
2. Import the IPA into your sideloading tool (AltStore, SideStore, etc.) to install.
</details>

### Enabling JIT

JIT (Just-In-Time compilation) is essential for smooth gameplay. Choose the approach that matches your environment:

| Tool | External Device | Wi-Fi Required | Auto-Enable | Notes |
|------|:---:|:---:|:---:|-------|
| TrollStore | No | No | Yes | Preferred; no additional action needed |
| AltStore | Yes | Yes | Yes | Requires AltServer running on local network |
| SideStore | First time only | First time only | No | Device/network-free after initial setup |
| StikDebug | First time only | First time only | Yes | Device/network-free after initial setup |
| Jitterbug | Yes (without VPN) | Yes | No | Manual trigger required |
| Jailbroken | No | No | Yes | System-level automatic support |

## Contributors

- [@herbrine8403](https://github.com/herbrine8403) -- Original Amethyst-iOS-MyRemastered author
- [@EternityQwQ](https://github.com/EternityQwQ) -- Metal Universal Mod support
- [@LanRhyme](https://github.com/LanRhyme) -- iOS 26 compatibility and logging improvements
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) -- Mod download integration, TouchController optimizations
- [@Li2548](https://github.com/Li2548) -- Upstream synchronization

## Community

- **QQ Group: 1126547426** -- User support, feedback and build announcements (also shown in the launcher's About page, with one-tap copy).

## License

This launcher is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.

- The full license text is the [`LICENSE`](./LICENSE) file at the repository root -- that file **is** the license content.
- Third-party components keep their own licenses: see the table below and the license/readme files inside `ThirdParty/` and `Natives/external/` (e.g. PojavLauncher lineage GPL-3.0, MobileGlues LGPL-3.0, gl4es MIT).
- In line with the upstream (AGPL) requirements, this fork keeps the license intact, states where the license content lives, and continues to publish its full source code.

## Fork Acknowledgments

This project would not exist without the following fork chain:

- **[PojavLauncherTeam/PojavLauncher_iOS](https://github.com/PojavLauncherTeam/PojavLauncher_iOS)** -- The original iOS Minecraft launcher that started it all.
- **[herbrine8403/Amethyst-iOS-MyRemastered](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered)** -- The major remastered fork that added the modern UI, mod management, BMCLAPI support, multi-account, and auto renderer/JVM selection. This is the direct upstream of Prisma.
- **[ZalithLauncher/ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2)** -- The SDL3 window-embedding approach used for Minecraft 26.3+ was borrowed from this project: its Android-side `sdl_hook.c` compatibility layer was ported to iOS as `Natives/sdl3_hook.m`, and its SDL embedding patches informed our `patches/sdl3-amethyst.patch` against the SDL uikit backend. Vendored as the `ThirdParty/ZalithLauncher2` submodule for reference.

## About Translations

If you would like to contribute translations for this project, please go to [Crowdin](https://crowdin.com/project/amethyst-ios-remastered).

## Third-Party Components

| Component | Purpose | License | Source |
|-----------|---------|---------|--------|
| SDL3 | Game window & input backend for MC 26.3+ (embedded in the host view, patched) | zlib | [GitHub](https://github.com/libsdl-org/SDL) -- patched via `patches/sdl3-amethyst.patch`; embedding approach ported from [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) |
| Caciocavallo | AWT runtime framework | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | Code annotation support | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | Core functionality adaptation | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL-to-GLES translation | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3D graphics library | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal-to-OpenGL ES translation | BSD-2 | [GitHub](https://github.com/khanhduytran0/MetalANGLE) |
| MoltenVK | Vulkan-to-Metal translation | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | Cross-platform 3D audio | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java runtime (8/17/21/25) | GPL-2.0 | [Website](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java game development library | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 compatibility layer | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI slider control | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | Dynamic library rebinding | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan shader compilation | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | File management utilities | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore integration | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIP archive handling | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | Library verification bypass | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | Third-party renderer | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core-to-ES wrapper | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | Third-party authentication | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

Additional thanks to [MCHeads](https://mc-heads.net) for Minecraft avatar services, [Modrinth](https://modrinth.com) for mod distribution, and [BMCLAPI](https://bmclapidoc.bangbang93.com) for Minecraft download mirroring.

## Sponsor

If you find this project valuable, consider supporting the original author through [Afdian](https://afdian.com/a/yiqiu4178), or [WeChat Reward Code](donate.png).

## Star History

<a href="https://www.star-history.com/?type=date&repos=Gsjsjzhznsz%2FPrisma-Minecraft-iOS-Launcher">
 <picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Gsjsjzhznsz%2FPrisma-Minecraft-iOS-Launcher&type=date&theme=dark" />
  <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Gsjsjzhznsz%2FPrisma-Minecraft-iOS-Launcher&type=date&legend=top-left" />
  <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Gsjsjzhznsz%2FPrisma-Minecraft-iOS-Launcher&type=date&legend=top-left" />
 </picture>
</a>
