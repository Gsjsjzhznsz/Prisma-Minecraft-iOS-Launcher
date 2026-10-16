#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task267 i18n 注册：
6 个 ame267.* 新键（Vulkan 遮罩超时 toast / Vulkan 回退 toast / JIT 旧脚本
弹窗×2 / 下载页目标实例标题与偏差提醒）注册进 en / zh-Hans / zh-CN / zh-Hant
四份 Localizable.strings（task189 惯例：其余 50 表缺键时走 localize 的
用户语言→en 回退链，无需逐表注入）。
幂等：已存在的键跳过。引号统一转义（Task227/228 整表解析事故防线）。
"""
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(REPO, "Natives", "resources")

# 键 -> (zh-CN/zh-Hans, zh-Hant, en)
KEYS = {
    "ame267.launch.overlay_timeout": (
        "加载时间较长，已自动显示游戏画面；如仍黑屏请点菜单里的关闭按钮返回",
        "載入時間較長，已自動顯示遊戲畫面；如仍黑屏請點選單裡的關閉按鈕返回",
        "Loading is taking longer than expected; the game screen has been revealed automatically. If it is still black, use the close button in the game menu to return.",
    ),
    "ame267.toast.vulkan_fallback": (
        "游戏已回退到 Vulkan 渲染（GL 后端不可用）。若出现崩溃或性能问题，建议在实例设置里更换渲染器",
        "遊戲已回退到 Vulkan 渲染（GL 後端不可用）。若出現崩潰或效能問題，建議在實例設定裡更換渲染器",
        "Game fell back to Vulkan rendering (GL backend unavailable). If you hit crashes or poor performance, switch the renderer in the instance settings.",
    ),
    "ame267.jit.legacy_lc": (
        "Prisma 检测到旧版 JIT 脚本。已自动更新为 Universal 脚本，请重启 LiveContainer 后继续。",
        "Prisma 偵測到舊版 JIT 腳本。已自動更新為 Universal 腳本，請重啟 LiveContainer 後繼續。",
        "Prisma was launched with a legacy JIT script. It has been updated to the Universal script automatically, please restart LiveContainer to continue.",
    ),
    "ame267.jit.legacy_stik": (
        "旧版 JIT 脚本支持已移除，请切换到 Universal JIT 脚本。新版 StikDebug 会按应用名自动指派脚本（旧版侧载安装包内置的脚本名为 Amethyst-MeloNX.js），更新 StikDebug 是最简单的修复方式。手动指派：在 StikDebug 启用 JIT 时长按本启动器应用 → 点 \"Assign Script\" → 选择启动器 Documents 目录里的 UniversalJIT26.js（每次启动都会自动导出）。",
        "舊版 JIT 腳本支援已移除，請切換到 Universal JIT 腳本。新版 StikDebug 會按應用名稱自動指派腳本（舊版側載安裝套件內建的腳本名為 Amethyst-MeloNX.js），更新 StikDebug 是最簡單的修復方式。手動指派：在 StikDebug 啟用 JIT 時長按本啟動器應用 → 點 \"Assign Script\" → 選擇啟動器 Documents 目錄裡的 UniversalJIT26.js（每次啟動都會自動匯出）。",
        "Support for legacy JIT scripts has been removed, please switch to the Universal JIT script. Current StikDebug builds auto-assign the script by app name (older sideloaded builds bundled the same script as Amethyst-MeloNX.js), so updating StikDebug is the easiest fix. To assign manually: long-press on the launcher app when enabling JIT in StikDebug, tap \"Assign Script\", then pick UniversalJIT26.js from the launcher's Documents directory (exported automatically at every startup).",
    ),
    "ame267.download.target_title": (
        "下载 · 实例：%@",
        "下載 · 實例：%@",
        "Download · Instance: %@",
    ),
    "ame267.download.target_mismatch": (
        "注意：下载目标实例仍为「%@」（打开下载页时锁定），切换实例请重新进入下载页",
        "注意：下載目標實例仍為「%@」（開啟下載頁時鎖定），切換實例請重新進入下載頁",
        "Note: downloads still target instance \"%@\" (locked when the page was opened). Re-enter the download page to switch instances.",
    ),
}

TABLES = {
    "en.lproj": 2,
    "zh-Hans.lproj": 0,
    "zh-CN.lproj": 0,
    "zh-Hant.lproj": 1,
}


def esc(value: str) -> str:
    return value.replace('\\', '\\\\').replace('"', '\\"')


def main():
    appended = 0
    for table, idx in TABLES.items():
        path = os.path.join(RES, table, "Localizable.strings")
        if not os.path.exists(path):
            print(f"[SKIP] {table}: no Localizable.strings")
            continue
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        additions = []
        for key, values in KEYS.items():
            # 幂等：键已存在（精确 "key" = 形态）则跳过
            if re.search(r'^"%s"\s*=' % re.escape(key), content, re.M):
                continue
            value = esc(values[idx])
            additions.append('"%s" = "%s";' % (key, value))
        if additions:
            if not content.endswith("\n"):
                content += "\n"
            content += "\n// ---- Task267 (Vulkan overlay / JIT legacy dialogs / download target visibility) ----\n"
            content += "\n".join(additions) + "\n"
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            appended += len(additions)
            print(f"[OK] {table}: +{len(additions)} keys")
        else:
            print(f"[IDEMPOTENT] {table}: all keys present")
    print(f"Task267 i18n done: {appended} entries appended.")


if __name__ == "__main__":
    main()
