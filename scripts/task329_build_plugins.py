#!/usr/bin/env python3
"""Task329: rebuild the 4 bundled plugin zips (device build 6f27aba spec).

Each zip: manifest.json + main.js at zip root (Task318 loader convention).
Set: launch-counter / modrinth-hot / renderer-quickswitch / theme-sunset.
Old demo set (accent-roulette/launch-banner/renderer-guard) is retired --
removed from BuiltinPlugins by this script.
"""
import json
import os
import shutil
import zipfile

OUT = "/home/z/my-project/repo-prisma/Natives/resources/BuiltinPlugins"

PLUGINS = {
    "org.prisma.launch-counter": {
        "manifest": {
            "id": "org.prisma.launch-counter",
            "name": "启动统计",
            "version": "1.1.0",
            "author": "Prisma",
            "description": "统计游戏启动次数与最近一次退出码，全部数据只存本插件私有存储，不上传。",
            "main": "main.js",
            "minApi": 1,
            "permissions": ["events", "files.plugin", "ui", "notify"],
        },
        "main": r'''// 启动统计 —— events + files.plugin + ui 贡献行演示（Task329 内置四件套）
var FILE = "stats.json";
var stats = { boots: 0, launches: 0, lastCode: -1 };
try {
    var raw = prisma.readFile(FILE);
    if (raw) {
        var p = JSON.parse(raw);
        if (p && typeof p === "object") {
            stats.boots = p.boots | 0;
            stats.launches = p.launches | 0;
            stats.lastCode = (p.lastCode === undefined ? -1 : p.lastCode);
        }
    }
} catch (e) {
    prisma.warn("stats parse failed, reset: " + e);
}

function save() { prisma.writeFile(FILE, JSON.stringify(stats)); }
function refresh() {
    prisma.updateRow("stats", {
        detail: "启动 " + stats.boots + " 次 · 游戏 " + stats.launches +
                " 次 · 最近退出码 " + stats.lastCode
    });
}

prisma.registerRow({
    id: "stats",
    title: "启动统计",
    detail: "启动 0 次 · 游戏 0 次",
    onTap: function () { refresh(); prisma.toast("启动统计已刷新"); }
});
prisma.on("launcherBoot", function () { stats.boots++; save(); refresh(); });
prisma.on("gameLaunch", function () { stats.launches++; save(); refresh(); });
prisma.on("gameExit", function (e) {
    stats.lastCode = (e && e.code !== undefined) ? e.code : -1;
    save(); refresh();
});
refresh();
prisma.log("launch-counter ready");
''',
    },
    "org.prisma.modrinth-hot": {
        "manifest": {
            "id": "org.prisma.modrinth-hot",
            "name": "Modrinth 热门榜",
            "version": "1.1.0",
            "author": "Prisma",
            "description": "联网拉取 Modrinth 下载量前五的模组并在对话框展示。联网属高危权限，首次使用请在插件详情页授权。",
            "main": "main.js",
            "minApi": 1,
            "permissions": ["network", "ui", "notify"],
        },
        "main": r'''// Modrinth 热门榜 —— network + ui 弹窗演示（Task329 内置四件套）
var API = "https://api.modrinth.com/v2/search?limit=5&index=downloads";

function fmt(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1) + "M";
    if (n >= 1000) return (n / 1000).toFixed(1) + "K";
    return String(n);
}

prisma.registerRow({
    id: "hot5",
    title: "Modrinth 热门榜",
    detail: "点击拉取下载量前五模组",
    onTap: function () {
        if (!prisma.isGranted("network")) {
            prisma.toast("请先在插件详情页授权联网");
            return;
        }
        prisma.updateRow("hot5", { detail: "正在拉取…" });
        prisma.httpGet(API, function (body) {
            if (!body) {
                prisma.updateRow("hot5", { detail: "拉取失败（检查网络/授权）" });
                prisma.toast("Modrinth 拉取失败");
                return;
            }
            try {
                var data = JSON.parse(body);
                var hits = (data && data.hits) ? data.hits : [];
                if (!hits.length) {
                    prisma.updateRow("hot5", { detail: "暂无数据" });
                    return;
                }
                var lines = "";
                for (var i = 0; i < hits.length && i < 5; i++) {
                    lines += (i + 1) + ". " + hits[i].title +
                             "（" + fmt(hits[i].downloads) + " 下载）\n";
                }
                prisma.updateRow("hot5", { detail: "上次更新：No.1 " + hits[0].title });
                prisma.alert("Modrinth 热门榜（下载量 Top5）", lines.trim());
            } catch (e) {
                prisma.updateRow("hot5", { detail: "解析失败" });
                prisma.warn("parse: " + e);
            }
        });
    }
});
prisma.log("modrinth-hot ready");
''',
    },
    "org.prisma.renderer-quickswitch": {
        "manifest": {
            "id": "org.prisma.renderer-quickswitch",
            "name": "渲染器快切",
            "version": "1.1.0",
            "author": "Prisma",
            "description": "在已安装渲染器之间循环切换并随时查看当前后端。渲染器写入属高危权限，首次切换请在插件详情页授权。",
            "main": "main.js",
            "minApi": 1,
            "permissions": ["renderer.read", "renderer.write", "ui", "notify"],
        },
        "main": r'''// 渲染器快切 —— renderer.read/write + ui 贡献行演示（Task329 内置四件套）
function current() {
    var r = prisma.getRenderer();
    return r ? r : "auto";
}

function refresh() {
    prisma.updateRow("quickswitch", { detail: "当前：" + current() + "（点击切换）" });
}

prisma.registerRow({
    id: "quickswitch",
    title: "渲染器快切",
    detail: "当前：auto（点击切换）",
    onTap: function () {
        if (!prisma.isGranted("renderer.write")) {
            prisma.toast("请先在插件详情页授权渲染器写入");
            refresh();
            return;
        }
        var opts = prisma.listRendererOptions() || [];
        if (!opts.length) { prisma.toast("候选渲染器为空"); return; }
        var cur = current();
        var idx = -1;
        for (var i = 0; i < opts.length; i++) {
            if (opts[i].key === cur) { idx = i; break; }
        }
        // 从当前位置向后找第一个可用候选（循环；找不到可用 = 原值提示）。
        for (var step = 1; step <= opts.length; step++) {
            var cand = opts[(idx + step + opts.length) % opts.length];
            if (prisma.isRendererAvailable(cand.key)) {
                if (prisma.setRenderer(cand.key)) {
                    prisma.toast("渲染器 → " + cand.name);
                    refresh();
                } else {
                    prisma.toast("切换被拒绝（检查授权/白名单）");
                }
                return;
            }
        }
        prisma.toast("没有可用的其他渲染器");
    }
});
refresh();
prisma.log("renderer-quickswitch ready");
''',
    },
    "org.prisma.theme-sunset": {
        "manifest": {
            "id": "org.prisma.theme-sunset",
            "name": "日落主题包",
            "version": "1.1.0",
            "author": "Prisma",
            "description": "四套精选配色（日落/森林/海洋/玫瑰）一键换肤，支持循环切换与恢复默认。主题令牌属高危权限，首次使用请在插件详情页授权。",
            "main": "main.js",
            "minApi": 1,
            "permissions": ["theme.write", "files.plugin", "ui", "notify"],
        },
        "main": r'''// 日落主题包 —— theme.write + ui 贡献行演示（Task329 内置四件套）
// 令牌键名 = PrismaTheme 白名单（accent/canvas/card/cardElevated/stroke/
// textPrimary/textSecondary/textTertiary/danger/success/warning）。
var PALETTES = [
    { name: "日落", accent: "#FF8A5C", canvas: "#241A16", card: "#33241D",
      cardElevated: "#3D2B22", stroke: "#5A3E30", textPrimary: "#F5EDE7",
      textSecondary: "#D9C3B5", textTertiary: "#A98F80" },
    { name: "森林", accent: "#7BC47F", canvas: "#16211A", card: "#1F2E24",
      cardElevated: "#27392C", stroke: "#3C5546", textPrimary: "#EDF5EE",
      textSecondary: "#C4D9C7", textTertiary: "#8FA895" },
    { name: "海洋", accent: "#5CC8FF", canvas: "#141E2A", card: "#1C2B3D",
      cardElevated: "#243649", stroke: "#37516D", textPrimary: "#EAF3FB",
      textSecondary: "#BFD6E8", textTertiary: "#8AA5BC" },
    { name: "玫瑰", accent: "#F472B6", canvas: "#241620", card: "#331E2C",
      cardElevated: "#3E2536", stroke: "#5C3A4E", textPrimary: "#F9EDF4",
      textSecondary: "#E3C4D4", textTertiary: "#B08FA2" },
];
var IDX_KEY = "palette-index";
var idx = 0;
try {
    var raw = prisma.readFile(IDX_KEY);
    if (raw !== null && raw !== undefined) {
        var p = parseInt(raw, 10);
        if (!isNaN(p) && p >= 0 && p < PALETTES.length) idx = p;
    }
} catch (e) {}

function apply(i, silent) {
    var pal = PALETTES[i];
    if (!prisma.isGranted("theme.write")) {
        if (!silent) prisma.toast("换肤被拒绝（请在插件详情页授权主题令牌）");
        return false;
    }
    if (!prisma.setThemeTokens(tokensOf(pal))) {
        if (!silent) prisma.toast("换肤被拒绝");
        return false;
    }
    return true;
}
function tokensOf(p) {
    return { accent: p.accent, canvas: p.canvas, card: p.card,
             cardElevated: p.cardElevated, stroke: p.stroke,
             textPrimary: p.textPrimary, textSecondary: p.textSecondary,
             textTertiary: p.textTertiary };
}
function refresh() {
    prisma.updateRow("sunset", { detail: "当前配色：" + PALETTES[idx].name + "（点击切换）" });
}

prisma.registerRow({
    id: "sunset",
    title: "日落主题包",
    detail: "当前配色：（点击切换）",
    onTap: function () {
        idx = (idx + 1) % PALETTES.length;
        if (apply(idx)) {
            prisma.writeFile(IDX_KEY, String(idx));
            prisma.toast("主题 → " + PALETTES[idx].name);
        }
        refresh();
    }
});
// 启动即恢复上次配色（静默：未授权时零打扰，授权后下次启动生效）。
apply(idx, true);
refresh();
prisma.log("theme-sunset ready (palette " + idx + ")");
''',
    },
}


def main() -> None:
    # 退役旧内置件（accent-roulette/launch-banner/renderer-guard）。
    for name in sorted(os.listdir(OUT)):
        if name.endswith(".zip"):
            pid = name[:-4]
            if pid not in PLUGINS:
                os.remove(os.path.join(OUT, name))
                print("retired:", name)
    for pid, spec in PLUGINS.items():
        path = os.path.join(OUT, pid + ".zip")
        if os.path.exists(path):
            os.remove(path)
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("manifest.json",
                       json.dumps(spec["manifest"], ensure_ascii=False, indent=2) + "\n")
            z.writestr("main.js", spec["main"])
        print("built:", path, os.path.getsize(path), "bytes")
    # 确认终态：目录里恰好 4 个 zip。
    remaining = sorted(n for n in os.listdir(OUT) if n.endswith(".zip"))
    print("final:", remaining)


if __name__ == "__main__":
    main()
