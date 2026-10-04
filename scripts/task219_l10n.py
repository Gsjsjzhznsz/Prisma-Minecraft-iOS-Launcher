#!/usr/bin/env python3
# Task219: add 38 new l10n keys to the 4 restricted tables + VGPU rename.
# Usage: python3 scripts/task219_l10n.py
import re, sys, os

REPO = os.path.join(os.path.dirname(__file__), "..")

# key -> (en, zh-Hans, zh-Hant, zh-CN)
KEYS = {
    # ---- welcome rebuild (⑤⑧②③⑥) ----
    "welcome.back": ("Back", "返回", "返回", "返回"),
    "welcome.env.title": ("Environment & JIT", "环境与 JIT", "環境與 JIT", "环境与 JIT"),
    "welcome.env.subtitle": ("Detect your install environment and pick how JIT gets enabled.",
                             "检测安装环境，并选择 JIT 的开启方式。",
                             "偵測安裝環境，並選擇 JIT 的開啟方式。",
                             "检测安装环境，并选择 JIT 的开启方式。"),
    "welcome.env.lc.detected": ("Running inside LiveContainer", "检测到 LiveContainer 环境", "偵測到 LiveContainer 環境", "检测到 LiveContainer 环境"),
    "welcome.env.notlc": ("Standard install (LiveContainer not detected)", "标准安装环境（未检测到 LiveContainer）", "標準安裝環境（未偵測到 LiveContainer）", "标准安装环境（未检测到 LiveContainer）"),
    "welcome.env.lc.current": ("Current bundle ID", "当前包名", "目前套件名", "当前包名"),
    "welcome.env.lc.host": ("LiveContainer bundle ID", "LiveContainer 包名", "LiveContainer 套件名", "LiveContainer 包名"),
    "welcome.env.lc.ok": ("LiveContainer's bundle ID is in use: %@ — JIT tools can find the app by this ID.",
                          "已使用 LiveContainer 的包名：%@（JIT 工具可按此包名识别本应用）。",
                          "已使用 LiveContainer 的套件名：%@（JIT 工具可按此套件名識別本應用）。",
                          "已使用 LiveContainer 的包名：%@（JIT 工具可按此包名识别本应用）。"),
    "welcome.env.lc.mismatch.title": ("Please open \"use livecontainer's bundle id\" in livecontainer",
                                      "请在 LiveContainer 中开启“使用 LiveContainer 的包名”",
                                      "請在 LiveContainer 中開啟「使用 LiveContainer 的套件名」",
                                      "请在 LiveContainer 中开启“使用 LiveContainer 的包名”"),
    "welcome.env.lc.mismatch.body": ("JIT enabler tools identify apps by bundle ID. The current ID (%1$@) is not LiveContainer's (%2$@). Open the app's settings in LiveContainer, turn on \"Use LiveContainer's bundle ID\", then restart this launcher.",
                                     "JIT 开启工具按包名识别应用。当前包名（%1$@）不是 LiveContainer 的包名（%2$@）。请在 LiveContainer 的应用设置中开启“使用 LiveContainer 的包名”，然后重启本启动器。",
                                     "JIT 開啟工具按套件名識別應用。目前套件名（%1$@）不是 LiveContainer 的套件名（%2$@）。請在 LiveContainer 的應用設定中開啟「使用 LiveContainer 的套件名」，然後重新啟動本啟動器。",
                                     "JIT 开启工具按包名识别应用。当前包名（%1$@）不是 LiveContainer 的包名（%2$@）。请在 LiveContainer 的应用设置中开启“使用 LiveContainer 的包名”，然后重启本启动器。"),
    "welcome.env.lc.copy": ("Copy %@", "复制 %@", "複製 %@", "复制 %@"),
    "welcome.env.lc.copied": ("Copied", "已复制", "已複製", "已复制"),
    "welcome.jit.title": ("JIT", "JIT", "JIT", "JIT"),
    "welcome.jit.subtitle": ("Pick how JIT gets enabled (changeable anytime in Settings).",
                             "选择 JIT 的开启方式（可随时在设置中更改）。",
                             "選擇 JIT 的開啟方式（可隨時在設定中更改）。",
                             "选择 JIT 的开启方式（可随时在设置中更改）。"),
    "welcome.jit.status.on": ("JIT enabled", "JIT 已开启", "JIT 已開啟", "JIT 已开启"),
    "welcome.jit.status.off": ("JIT not enabled — the launcher will try to enable it when a game starts.",
                               "JIT 未开启（启动游戏时会自动尝试开启）。",
                               "JIT 未開啟（啟動遊戲時會自動嘗試開啟）。",
                               "JIT 未开启（启动游戏时会自动尝试开启）。"),
    "welcome.jit.enable_now": ("Enable now", "立即开启", "立即開啟", "立即开启"),
    "welcome.jit.hint": ("JIT enabler tools identify the app by its bundle ID. If the launcher doesn't respond after switching tools, install that tool first.",
                         "JIT 开启工具按包名识别应用。切换工具后若启动器无响应，请先安装对应工具。",
                         "JIT 開啟工具按套件名識別應用。切換工具後若啟動器無回應，請先安裝對應工具。",
                         "JIT 开启工具按包名识别应用。切换工具后若启动器无响应，请先安装对应工具。"),
    "welcome.jit.hint.lc": ("Under LiveContainer, JIT tools target the host bundle ID — see the environment card above.",
                            "LiveContainer 环境下，JIT 工具识别的是宿主包名——见上方环境卡片。",
                            "LiveContainer 環境下，JIT 工具識別的是宿主套件名——見上方環境卡片。",
                            "LiveContainer 环境下，JIT 工具识别的是宿主包名——见上方环境卡片。"),
    # ---- export rebuild (⑨) ----
    "ame219.export.empty": ("No data to export", "没有可导出的数据", "沒有可匯出的資料", "没有可导出的数据"),
    "ame219.export.pick_level": ("Choose compression level", "选择压缩等级", "選擇壓縮等級", "选择压缩等级"),
    "ame219.export.summary": ("%1$lu files, about %2$@ in total. Pick a compression level for the backup:",
                              "共 %1$lu 个文件，总计约 %2$@。请选择备份的压缩等级：",
                              "共 %1$lu 個個檔案，總計約 %2$@。請選擇備份的壓縮等級：",
                              "共 %1$lu 个文件，总计约 %2$@。请选择备份的压缩等级："),
    "ame219.export.level_none": ("No compression (fastest)", "不压缩（最快）", "不壓縮（最快）", "不压缩（最快）"),
    "ame219.export.level_default": ("Standard compression", "标准压缩", "標準壓縮", "标准压缩"),
    "ame219.export.level_best": ("Maximum compression (smallest, slowest)", "最大压缩（体积最小，速度最慢）", "最大壓縮（體積最小，速度最慢）", "最大压缩（体积最小，速度最慢）"),
    "ame219.export.progress_file": ("Compressing %1$lu/%2$lu: %3$@\n%4$@ written",
                                    "正在压缩 %1$lu/%2$lu：%3$@\n已写入 %4$@",
                                    "正在壓縮 %1$lu/%2$lu：%3$@\n已寫入 %4$@",
                                    "正在压缩 %1$lu/%2$lu：%3$@\n已写入 %4$@"),
    # ---- TouchController (⑩) ----
    "component.touch.fabric_only": ("TouchController only works with the Fabric loader.\n\nThe current instance does not use the Fabric loader, so it cannot be installed.",
                                    "TouchController 仅对 Fabric 加载器有效。\n\n当前版本不是 Fabric 加载器，无法安装。",
                                    "TouchController 僅對 Fabric 載入器有效。\n\n目前版本不是 Fabric 載入器，無法安裝。",
                                    "TouchController 仅对 Fabric 加载器有效。\n\n当前版本不是 Fabric 加载器，无法安装。"),
    "component.touch.unsupported_title": ("Version not supported", "该版本不支持", "該版本不支援", "该版本不支持"),
    "component.touch.unsupported": ("TouchController supports Minecraft 1.12.2 and newer. Minecraft %@ is out of its supported range, so it cannot be installed.",
                                    "TouchController 模组支持 Minecraft 1.12.2 及以上版本，Minecraft %@ 不在支持范围内，无法安装。",
                                    "TouchController 模組支援 Minecraft 1.12.2 及以上版本，Minecraft %@ 不在支援範圍內，無法安裝。",
                                    "TouchController 模组支持 Minecraft 1.12.2 及以上版本，Minecraft %@ 不在支持范围内，无法安装。"),
    "component.touch.confirm_message": ("This will install the TouchController mod (touch controls for Minecraft %1$@) and auto-configure it: UDP transport + hide the launcher's own on-screen controls (the mod's virtual buttons stay).\n\nInstall the TouchController mod for Minecraft %2$@ and auto-configure: UDP transport + hide the launcher's own on-screen controls.",
                                        "将自动安装 TouchController 模组（触屏控制器，适配 Minecraft %1$@）并自动配置：UDP 通信模式 + 屏蔽启动器自带控件（保留模组自己的虚拟按钮）。\n\nInstall the TouchController mod for Minecraft %2$@ and auto-configure: UDP transport + hide the launcher's own on-screen controls.",
                                        "將自動安裝 TouchController 模組（觸控控制器，適配 Minecraft %1$@）並自動設定：UDP 通訊模式 + 隱藏啟動器內建控制（保留模組自己的虛擬按鈕）。\n\nInstall the TouchController mod for Minecraft %2$@ and auto-configure: UDP transport + hide the launcher's own on-screen controls.",
                                        "将自动安装 TouchController 模组（触屏控制器，适配 Minecraft %1$@）并自动配置：UDP 通信模式 + 屏蔽启动器自带控件（保留模组自己的虚拟按钮）。\n\nInstall the TouchController mod for Minecraft %2$@ and auto-configure: UDP transport + hide the launcher's own on-screen controls."),
    "component.touch.searching": ("Searching for a TouchController build for %@...",
                                  "正在寻找适配 %@ 的 TouchController…",
                                  "正在尋找適配 %@ 的 TouchController…",
                                  "正在寻找适配 %@ 的 TouchController…"),
    "component.touch.not_found": ("No matching TouchController project or version found (%@). The mod covers 1.12.2 and newer.",
                                  "未找到适配的 TouchController 项目或版本（%@）。该模组仅覆盖 1.12.2 及以上版本。",
                                  "未找到適配的 TouchController 專案或版本（%@）。該模組僅覆蓋 1.12.2 及以上版本。",
                                  "未找到适配的 TouchController 项目或版本（%@）。该模组仅覆盖 1.12.2 及以上版本。"),
    "component.touch.download_failed": ("Failed to download TouchController: %@", "下载 TouchController 失败：%@", "下載 TouchController 失敗：%@", "下载 TouchController 失败：%@"),
    "component.touch.done": ("TouchController installed and auto-configured (UDP mode + launcher controls hidden):\n%1$@\n\nTouchController 已安装并自动配置（UDP 模式 + 屏蔽启动器控件）：\n%2$@",
                             "TouchController 已安装并自动配置（UDP 模式 + 屏蔽启动器控件）：\n%1$@\n\nTouchController installed and auto-configured (UDP mode + launcher controls hidden):\n%2$@",
                             "TouchController 已安裝並自動設定（UDP 模式 + 隱藏啟動器控制）：\n%1$@\n\nTouchController installed and auto-configured (UDP mode + launcher controls hidden):\n%2$@",
                             "TouchController 已安装并自动配置（UDP 模式 + 屏蔽启动器控件）：\n%1$@\n\nTouchController installed and auto-configured (UDP mode + launcher controls hidden):\n%2$@"),
    # ---- mods isolation badge (⑪) ----
    "ame219.mods.isolated_chip": ("Isolated", "隔离", "隔離", "隔离"),
    "ame219.mods.shared_chip": ("Shared", "共享目录", "共享目錄", "共享目录"),
    # ---- VirGL fallback alert (①) ----
    "ame219.virgl.fallback.title": ("VirGL unavailable", "VirGL 不可用", "VirGL 不可用", "VirGL 不可用"),
    "ame219.virgl.fallback.body": ("The VirGL vtest server could not start this session, so the renderer fell back to Zink to avoid a crash. You can pick another renderer in instance settings.",
                                   "本次 VirGL vtest 服务启动失败，渲染器已回退到 Zink 以避免崩溃。可在实例设置中选择其他渲染器。",
                                   "本次 VirGL vtest 服務啟動失敗，渲染器已回退到 Zink 以避免崩潰。可在實例設定中選擇其他渲染器。",
                                   "本次 VirGL vtest 服务启动失败，渲染器已回退到 Zink 以避免崩溃。可在实例设置中选择其他渲染器。"),
}

# ④ VGPU rename (user order: "VGPU 重新命名为 VGPU（≤1.17）")
VGPU = {
    "preference.title.renderer.debug.vgpu": (
        "VGPU (≤1.17)",
        "VGPU（≤1.17）",
        "VGPU（≤1.17）",
        "VGPU（≤1.17）",
    ),
}

LANGS = ["en", "zh-Hans", "zh-Hant", "zh-CN"]

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

for li, lang in enumerate(LANGS):
    path = os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    lines = content.split("\n")
    # 1) VGPU rename in place
    for key, vals in VGPU.items():
        pat = re.compile(r'^("%s"\s*=)\s*".*";$' % re.escape(key))
        for i, ln in enumerate(lines):
            m = pat.match(ln)
            if m:
                lines[i] = f'{m.group(1)} "{esc(vals[li])}";'
                break
        else:
            print(f"FATAL: {lang}: VGPU key {key} not found"); sys.exit(1)
    # 2) append new keys (after the last existing line, keep trailing newline shape)
    additions = []
    for key, vals in KEYS.items():
        if f'"{key}"' in content:
            print(f"FATAL: {lang}: key {key} already exists"); sys.exit(1)
        additions.append(f'"{key}" = "{esc(vals[li])}";')
    # find last non-empty line index; append block with a section comment
    while lines and lines[-1] == "":
        lines.pop()
    lines.append("")
    lines.append("// Task219：欢迎向导重做（环境/JIT/返回/关于联动）+ 导出压缩等级与进度 + TouchController 专属文案 + 隔离徽标 + VirGL 回退提示")
    lines.extend(additions)
    new_content = "\n".join(lines) + "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
    # unique key count via the verifier's method
    keys = set(re.findall(r'^"([^"]+)"\s*=', new_content, re.M))
    print(f"{lang}: +{len(additions)} keys, unique total = {len(keys)}")
