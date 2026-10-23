#!/usr/bin/env python3
# Task318: 内置插件仓库打包 —— 4 个官方示例插件生成 .prismapack（zip）进
# Natives/resources/BuiltinPlugins/（Makefile payload 整目录随包拷贝，
# 运行时 AmePluginRepoViewController 从 bundle Resources/BuiltinPlugins 扫描）。
# 插件包形态：根级 manifest.json + main.js（AmePluginManager 安装闸的合法形态）。
import json, os, zipfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources', 'BuiltinPlugins')

PLUGINS = [
    {
        "id": "org.prisma.launch-banner",
        "name": "启动横幅",
        "version": "1.0.0",
        "author": "Prisma Team",
        "description": "启动 / 退出游戏时弹出提示横幅。Banner on game launch & exit.",
        "main": "main.js",
        "minApi": 1,
        "permissions": ["events", "notify"],
    },
    {
        "id": "org.prisma.renderer-guard",
        "name": "渲染器体检",
        "version": "1.0.0",
        "author": "Prisma Team",
        "description": "启动器启动时检查当前渲染器是否可用，缺失自动回落 auto。Renderer sanity check on boot.",
        "main": "main.js",
        "minApi": 1,
        "permissions": ["events", "notify", "renderer.read", "renderer.write"],
    },
    {
        "id": "org.prisma.accent-roulette",
        "name": "主题色轮盘",
        "version": "1.0.0",
        "author": "Prisma Team",
        "description": "每次退出游戏自动轮换一组主题色。Rotate accent color after each game session.",
        "main": "main.js",
        "minApi": 1,
        "permissions": ["events", "theme.write", "notify"],
    },
    {
        "id": "org.prisma.launch-counter",
        "name": "启动计数器",
        "version": "1.0.0",
        "author": "Prisma Team",
        "description": "统计启动器启动次数，存放在插件私有目录。Count launcher boots in plugin-private storage.",
        "main": "main.js",
        "minApi": 1,
        "permissions": ["events", "files.plugin", "notify"],
    },
]

BODIES = {
    "org.prisma.launch-banner": r'''// 启动横幅 —— gameLaunch / gameExit 事件演示
prisma.log("launch-banner loaded");

prisma.on("gameLaunch", function (e) {
    prisma.toast(e.version ? ("正在启动 " + e.version) : "正在启动 Minecraft");
});

prisma.on("gameExit", function (e) {
    prisma.toast(e.code === 0 ? "游戏已退出，欢迎回来" : ("游戏已退出（代码 " + e.code + "）"));
});
''',
    "org.prisma.renderer-guard": r'''// 渲染器体检 —— 渲染器白名单 API 演示（只读 + 白名单内写入）
prisma.log("renderer-guard loaded");

prisma.on("launcherBoot", function () {
    var cur = prisma.getRenderer();
    prisma.log("current renderer = " + cur);
    if (cur && prisma.isRendererAvailable(cur)) {
        prisma.log("renderer OK, nothing to do");
        return;
    }
    // 当前渲染器不在候选表 / dylib 缺失 → 回落 auto（MCDL 存量值同款语义）
    var ok = prisma.setRenderer("auto");
    prisma.log("renderer unavailable -> fallback auto: " + ok);
    if (ok) {
        prisma.toast("渲染器不可用，已回落自动");
    }
});
''',
    "org.prisma.accent-roulette": r'''// 主题色轮盘 —— theme.write 令牌覆盖演示
var palette = ["#429CF5", "#34C77B", "#F2994A", "#B75DFF", "#EF4478"];
var idx = 0;

prisma.log("accent-roulette loaded");

prisma.on("gameExit", function () {
    idx = (idx + 1) % palette.length;
    var ok = prisma.setThemeTokens({ accent: palette[idx] });
    prisma.log("accent -> " + palette[idx] + " : " + ok);
    if (ok) {
        prisma.toast("主题色已轮换");
    }
});

prisma.on("launcherBoot", function () {
    // 恢复记忆：上次轮到哪一档（存插件私有目录会绕开本插件声明的权限面，
    // 这里用会话内存即可——每次启动器重启从头轮）。
    prisma.log("accent-roulette ready, palette size " + palette.length);
});
''',
    "org.prisma.launch-counter": r'''// 启动计数器 —— files.plugin 私有目录读写演示
var FILE = "counter.txt";

prisma.log("launch-counter loaded");

prisma.on("launcherBoot", function () {
    var n = 0;
    var raw = prisma.readFile(FILE);
    if (raw) {
        var parsed = parseInt(raw, 10);
        if (!isNaN(parsed)) n = parsed;
    }
    n = n + 1;
    var ok = prisma.writeFile(FILE, String(n));
    prisma.log("boot count " + n + " (saved: " + ok + ")");
    prisma.toast("第 " + n + " 次启动");
});
''',
}

def main():
    os.makedirs(ROOT, exist_ok=True)
    for spec in PLUGINS:
        out = os.path.join(ROOT, spec["id"] + ".zip")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("manifest.json", json.dumps(spec, ensure_ascii=False, indent=2))
            z.writestr(spec["main"], BODIES[spec["id"]])
        size = os.path.getsize(out)
        print("packed %-36s %6d bytes  perms=%s" % (os.path.basename(out), size, ",".join(spec["permissions"])))
    print("task318 builtin plugins: %d packs -> %s" % (len(PLUGINS), ROOT))

if __name__ == "__main__":
    main()
