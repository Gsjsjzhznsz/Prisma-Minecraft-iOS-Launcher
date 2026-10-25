#!/usr/bin/env python3
"""Task329: register new i18n keys into all 54 Localizable.strings tables.

New surface: plugin list page rebuild (rows section / about / guide) +
bridge alert OK + two new permission titles/details (ui / network).
Real translations for en / zh-Hans / zh-Hant / zh-CN; EN fallback for the
rest (Task312 ALIAS convention).
"""
import glob
import os
import sys

BASE = "/home/z/my-project/repo-prisma/Natives/resources"

EN = {
    "ame318.list.section.rows": "Rows contributed by plugins",
    "ame318.rows.empty": "No plugin rows yet",
    "ame318.rows.empty_hint": "Enable a plugin and grant its permissions; its feature rows appear here.",
    "ame318.list.section.about": "About",
    "ame318.list.about.api": "Plugin API version: %@",
    "ame318.list.section.guide": "Plugin guide",
    "ame318.guide.install.title": "Install plugins",
    "ame318.guide.install.detail": "From the built-in repo or local import via the + button.",
    "ame318.guide.perm.title": "Permissions",
    "ame318.guide.perm.detail": "High-risk permissions (network/theme/renderer write/profile) are denied by default; grant them in the plugin detail page.",
    "ame318.guide.ai.title": "AI-written plugins",
    "ame318.guide.ai.detail": "Tell the AI assistant to write a plugin with your needs; it generates and installs one.",
    "ame318.alert.ok": "OK",
    "ame318.perm.ui": "Launcher UI contribution",
    "ame318.perm.ui.detail": "Contribute launcher rows and show dialogs inside the plugin page.",
    "ame318.perm.network": "Network access",
    "ame318.perm.network.detail": "Allow the plugin to fetch data over the network (high-risk).",
}

ZH_HANS = {
    "ame318.list.section.rows": "插件贡献的启动器行",
    "ame318.rows.empty": "暂无插件贡献行",
    "ame318.rows.empty_hint": "启用插件并在详情页授权后，其功能行会出现在这里。",
    "ame318.list.section.about": "关于",
    "ame318.list.about.api": "插件 API 版本：%@",
    "ame318.list.section.guide": "插件使用指南",
    "ame318.guide.install.title": "安装插件",
    "ame318.guide.install.detail": "插件来源于内置仓库，或经右上角 + 本地导入。",
    "ame318.guide.perm.title": "权限授权",
    "ame318.guide.perm.detail": "高危权限（联网/主题/渲染器写入/实例管理）默认拒绝，进插件详情页打开对应开关即可。",
    "ame318.guide.ai.title": "AI 写插件",
    "ame318.guide.ai.detail": "对 AI 助手说「帮我写一个插件」并描述需求，即可自动生成并安装。",
    "ame318.alert.ok": "确定",
    "ame318.perm.ui": "启动器界面贡献",
    "ame318.perm.ui.detail": "在插件页贡献功能行与弹窗提示。",
    "ame318.perm.network": "联网取数",
    "ame318.perm.network.detail": "允许插件向指定地址发起网络请求取回数据（高危）。",
}

ZH_HANT = {
    "ame318.list.section.rows": "插件貢獻的啟動器行",
    "ame318.rows.empty": "暫無插件貢獻行",
    "ame318.rows.empty_hint": "啟用插件並在詳情頁授權後，其功能行會出現在這裡。",
    "ame318.list.section.about": "關於",
    "ame318.list.about.api": "插件 API 版本：%@",
    "ame318.list.section.guide": "插件使用指南",
    "ame318.guide.install.title": "安裝插件",
    "ame318.guide.install.detail": "插件來源於內建倉庫，或經右上角 + 本地匯入。",
    "ame318.guide.perm.title": "權限授權",
    "ame318.guide.perm.detail": "高危權限（聯網/主題/渲染器寫入/實例管理）預設拒絕，進插件詳情頁打開對應開關即可。",
    "ame318.guide.ai.title": "AI 寫插件",
    "ame318.guide.ai.detail": "對 AI 助手說「幫我寫一個插件」並描述需求，即可自動生成並安裝。",
    "ame318.alert.ok": "確定",
    "ame318.perm.ui": "啟動器介面貢獻",
    "ame318.perm.ui.detail": "在插件頁貢獻功能行與彈窗提示。",
    "ame318.perm.network": "聯網取數",
    "ame318.perm.network.detail": "允許插件向指定位址發起網路請求取回資料（高危）。",
}

ZH_CN = dict(ZH_HANS)


def esc(value: str) -> str:
    return (value.replace("\\", "\\\\").replace('"', '\\"')
                 .replace("\n", "\\n"))


def lang_dict(lang: str) -> dict:
    if lang == "zh-Hans":
        return ZH_HANS
    if lang == "zh-Hant":
        return ZH_HANT
    if lang == "zh-CN":
        return ZH_CN
    return EN  # 其余 50 表 EN 兜底（主语言实译优先，回退链消费）


def append_keys(path: str, additions: dict) -> int:
    content = open(path, encoding="utf-8").read()
    added = 0
    lines = []
    for key, value in additions.items():
        # 已存在（任意位置）即跳过，幂等可重入。
        marker = '"%s"' % key
        if marker in content:
            continue
        lines.append('"%s" = "%s";\n' % (key, esc(value)))
        added += 1
    if lines:
        if not content.endswith("\n"):
            content += "\n"
        content += "\n/* Task329: plugin rows/about/guide + ui/network perms */\n"
        content += "".join(lines)
        open(path, "w", encoding="utf-8").write(content)
    return added


def main() -> int:
    tables = sorted(glob.glob(os.path.join(BASE, "*.lproj", "Localizable.strings")))
    if not tables:
        print("FATAL: no tables found", file=sys.stderr)
        return 1
    total = 0
    for path in tables:
        lang = os.path.basename(os.path.dirname(path)).replace(".lproj", "")
        added = append_keys(path, lang_dict(lang))
        total += added
        print("%-10s +%d" % (lang, added))
    print("tables=%d added=%d" % (len(tables), total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
