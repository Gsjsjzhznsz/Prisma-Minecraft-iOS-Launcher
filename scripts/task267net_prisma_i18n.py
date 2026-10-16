#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task267-净重放：54 表 ai.crash.* 12 键的键值 Prisma 化。
远端并行会话（Task267 重放版）把 AiCrashAnalyzer 文案键化但【原样保留上游
内容】（966475918 群号/法定节假日/LWJGL 3.3.3 魔改/26.3-Snapshot4 无解/
LiveContainer JIT）——键化≠Prisma 化。本脚本对全部 54 表做键值替换：
zh-CN/zh-Hans = 新中文；zh-Hant = 新繁体；其余 50 表 = 英文。
幂等：键不存在则跳过（不新增）。"""
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(REPO, "Natives", "resources")

ZH = {
    "ai.crash.sdl3.explanation": "Minecraft 26.3 起渲染库从 LWJGL 改为 SDL3，本启动器已内置 SDL3 通路；此报错通常是加载器/API 模组版本或渲染器选择与 26.3 不适配。",
    "ai.crash.sdl3.sugg1": "查看启动器「帮助与常见问题」里 26.3 专项排障条目，逐项检查（Fabric API/Sodium 版本、渲染器等）；仍无法启动时通过 GitHub Issues 或官方 QQ 群（1126547426）反馈并附上日志。",
    "ai.crash.launchercrash.sugg1": "通过 GitHub Issues（Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher 仓库）或官方 QQ 群（1126547426）反馈，附上 latestlog.txt。",
    "ai.crash.launchercrash.sugg2": "反馈时说明设备型号、系统版本与复现步骤，便于定位。",
    "ai.crash.lwjgl.explanation": "本启动器基于 LWJGL 3.4.1 兼容层运行游戏；某些旧版本游戏/模组与该兼容层的组合可能不适配。",
    "ai.crash.lwjgl.sugg2": "通过 GitHub Issues 或官方 QQ 群（1126547426）反馈具体版本组合。",
    "ai.crash.magickeyboard.explanation": "这是 iOS 平台点击妙控键盘（Magic Keyboard）触发的已知兼容性问题。",
    "ai.crash.magickeyboard.sugg1": "若影响日常使用，可通过 GitHub Issues 或官方 QQ 群（1126547426）反馈设备型号与复现步骤。",
    "ai.crash.jit.sugg1": "在「设置 → 调试」里选择合适的 JIT 方案（自动 / StikDebug / SideStore / StosDebug / JitStreamer-EB / TrollStore / 手动）开启后重试。",
    "ai.crash.jit.sugg2": "仍失败时通过 GitHub Issues 或官方 QQ 群（1126547426）反馈并附上日志。",
}
ZHT = {
    "ai.crash.sdl3.explanation": "Minecraft 26.3 起渲染庫從 LWJGL 改為 SDL3，本啟動器已內建 SDL3 通路；此報錯通常是載入器/API 模組版本或渲染器選擇與 26.3 不適配。",
    "ai.crash.sdl3.sugg1": "查看啟動器「幫助與常見問題」裡 26.3 專項排障條目，逐項檢查（Fabric API/Sodium 版本、渲染器等）；仍無法啟動時透過 GitHub Issues 或官方 QQ 群（1126547426）回報並附上日誌。",
    "ai.crash.launchercrash.sugg1": "透過 GitHub Issues（Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher 倉庫）或官方 QQ 群（1126547426）回報，附上 latestlog.txt。",
    "ai.crash.launchercrash.sugg2": "回報時說明設備型號、系統版本與重現步驟，便於定位。",
    "ai.crash.lwjgl.explanation": "本啟動器基於 LWJGL 3.4.1 相容層執行遊戲；某些舊版本遊戲/模組與該相容層的組合可能不適配。",
    "ai.crash.lwjgl.sugg2": "透過 GitHub Issues 或官方 QQ 群（1126547426）回報具體版本組合。",
    "ai.crash.magickeyboard.explanation": "這是 iOS 平台點擊妙控鍵盤（Magic Keyboard）觸發的已知相容性問題。",
    "ai.crash.magickeyboard.sugg1": "若影響日常使用，可透過 GitHub Issues 或官方 QQ 群（1126547426）回報設備型號與重現步驟。",
    "ai.crash.jit.sugg1": "在「設定 → 除錯」裡選擇合適的 JIT 方案（自動 / StikDebug / SideStore / StosDebug / JitStreamer-EB / TrollStore / 手動）開啟後重試。",
    "ai.crash.jit.sugg2": "仍失敗時透過 GitHub Issues 或官方 QQ 群（1126547426）回報並附上日誌。",
}
EN = {
    "ai.crash.sdl3.explanation": "Minecraft 26.3+ moved from LWJGL to SDL3; this launcher ships the SDL3 path. This error usually means the loader/API mod version or renderer is not a good fit for 26.3.",
    "ai.crash.sdl3.sugg1": "Check the 26.3 troubleshooting entries in Help & FAQ (Fabric API/Sodium versions, renderer, etc.); if it still fails, report via GitHub Issues or the official QQ group (1126547426) with logs.",
    "ai.crash.launchercrash.sugg1": "Report via GitHub Issues (Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher) or the official QQ group (1126547426) with latestlog.txt.",
    "ai.crash.launchercrash.sugg2": "Include device model, OS version and repro steps so it can be diagnosed.",
    "ai.crash.lwjgl.explanation": "This launcher runs the game on an LWJGL 3.4.1 compatibility layer; some older game/mod combinations may not fit it.",
    "ai.crash.lwjgl.sugg2": "Report the exact version combination via GitHub Issues or the official QQ group (1126547426).",
    "ai.crash.magickeyboard.explanation": "This is a known compatibility issue triggered by tapping the Magic Keyboard on iOS.",
    "ai.crash.magickeyboard.sugg1": "If it disrupts daily use, report your device model and repro steps via GitHub Issues or the official QQ group (1126547426).",
    "ai.crash.jit.sugg1": "Pick a JIT method in Settings > Debug (Auto / StikDebug / SideStore / StosDebug / JitStreamer-EB / TrollStore / Manual) and relaunch.",
    "ai.crash.jit.sugg2": "If it still fails, report via GitHub Issues or the official QQ group (1126547426) with logs.",
}


def esc(v):
    return v.replace('\\', '\\\\').replace('"', '\\"')


def main():
    tables = sorted(d for d in os.listdir(RES) if d.endswith(".lproj"))
    total = 0
    for t in tables:
        path = os.path.join(RES, t, "Localizable.strings")
        if not os.path.exists(path):
            continue
        if t.startswith("zh-CN") or t.startswith("zh-Hans"):
            src = ZH
        elif t.startswith("zh-Hant"):
            src = ZHT
        else:
            src = EN
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        changed = 0
        for key, value in src.items():
            pattern = re.compile(r'^("%s"\s*=\s*")[^"]*("\s*;)' % re.escape(key), re.M)
            if pattern.search(content):
                content = pattern.sub(lambda m: m.group(1) + esc(value) + m.group(2), content, count=1)
                changed += 1
        if changed:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            total += changed
            print(f"[OK] {t}: {changed} keys updated")
    print(f"Task267-net prisma i18n done: {total} key-values rewritten.")


if __name__ == "__main__":
    main()
