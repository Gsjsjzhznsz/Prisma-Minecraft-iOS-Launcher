#!/usr/bin/env python3
# verify_task255.py -- Task255 门禁：15 项清单（路径根修正/毛玻璃第二刀/JVM 预设/
# 右 Shift 会话重置/联机预检 4 peer/控件自动检查/公告精简/品牌替换/i18n 齐备）。
# 用法: python3 scripts/verify_task255.py [REPO]   # 默认取脚本父目录的上级
import json
import os
import subprocess
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as f:
        return f.read()


# ─── 1. 版本路径根修正（GAME_DIR 优先，HOME 兜底） ───
vm = read("Natives/VersionManagerViewController.m")
check("VM:deleteProfile GAME_DIR 主根", 'getenv("POJAV_GAME_DIR") ? getenv("POJAV_GAME_DIR") : getenv("POJAV_HOME"), ame255_versionId' in vm)
check("VM:scan GAME_DIR 主根", 'getenv("POJAV_GAME_DIR") ? getenv("POJAV_GAME_DIR") : getenv("POJAV_HOME")];' in vm)
check("VM:legacy HOME 兜底", 'ame255_legacy' in vm and '%s/versions/%@' in vm)
check("VM:删除后 ReloadProfileList", vm.count('postNotificationName:@"ReloadProfileList"') >= 2)
cl = read("Natives/CleanupViewController.m")
check("Cleanup:GAME_DIR 实例根", 'getenv("POJAV_GAME_DIR")' in cl and 'instanceRoot' in cl)
check("Cleanup:versions/*/game 隔离目录扫", '%@/game' in cl)
check("Cleanup:latestlog.crash 前缀", '"latestlog.crash"' in cl)

# ─── 2. 毛玻璃第二刀（blurIntensity<=0.01 整层不装分支退役） ───
bm = read("Natives/BackgroundManager.m")
check("BG:0.01 跳层分支（Task256 定向复活：最低档=完全透明，须带自愈护栏）",
      "blurIntensity <= 0.01" in bm and "ame256.blurUserSet" in bm)
check("BG:自愈第一刀在位（Task288 重锚：re-armable——blurUserSet 护栏在位、blurHealDone 一次性标志退役）",
      "ame256.blurUserSet" in bm and "re-armable" in bm)
check("BG:blurView 恒 alpha 1.0", "blurView.alpha = 1.0" in bm)

# ─── 3. JVM 预设消费端 ───
jl = read("Natives/JavaLauncher.m")
check("JVM:preset 键读取", 'getPrefObject(@"java.jvm_preset")' in jl)
check("JVM:memory 档 G1 收缩参数", "-XX:MinHeapFreeRatio=5" in jl and "-XX:MaxHeapFreeRatio=15" in jl and "-XX:G1MaxNewSizePercent=40" in jl)
check("JVM:performance 档参数", "-XX:MaxGCPauseMillis=20" in jl and "-XX:G1NewSizePercent=30" in jl)
check("JVM:custom 档跳过 GC 注入", "ame255_isCustom" in jl)
check("JVM:Java8 分流", "-XX:+UseSerialGC" in jl and "-XX:+UseParallelGC" in jl)
check("JVM:custom args 注入", "jvm_preset_custom_args" in jl and "ame255_pushFlag" in jl)
check("JVM:Xms/Xmx purge 保留", '@"Xms", @"Xmx", @"d32", @"d64"' in jl)

# ─── 4. auto 渲染器 ≤1.16 kw 头插 ───
check("Renderer:kw 头插", "RENDERER_NAME_NGGL4ES, @ RENDERER_NAME_GL4ESZL2" in jl)

# ─── 5. 右 Shift 会话重置三件 ───
ib = read("Natives/input_bridge_v3.m")
check("Shift:reset 函数导出", "void CallbackBridge_resetVirtualModifierState(void)" in ib)
check("Shift:kbState 224..231 清零", "ame255_sc = 224; ame255_sc <= 231" in ib)
check("Shift:托管位面掩码清理", "AME66_KMOD_MANAGED_MASK" in ib)
sv = read("Natives/SurfaceViewController.m")
check("Shift:dealloc 清账本", "[s_ame179_toggledMods removeAllObjects]" in sv and "[s_ame176_modDownTime removeAllObjects]" in sv)
check("Shift:dealloc 调重置", "CallbackBridge_resetVirtualModifierState();" in sv)
check("Shift:extern 声明", "extern void CallbackBridge_resetVirtualModifierState(void);" in sv)
sh = read("Natives/sdl3_hook.m")
check("Shift:Task67 RShift 采样", "vRS = r[229]" in sh and "RShift=%d" in sh)

# ─── 6. 联机：扫描闸 + 预检 4 peer ───
lp = read("Natives/LanPortDetector.m")
check("MP:确定性探针闸（Task256：初始化即停探，含旧会话闸语义）",
      "AmeTerracottaProbeSuspended" in lp and "hasInitializedLibrary" in lp)
check("MP:在飞扫描 abort", "_sweepAbort" in lp)
tm = read("Natives/TerracottaManager.m")
check("MP:预检 TCP 2 peer", "public.easytier.top:11010" in tm and "public2.easytier.cn:54321" in tm)
check("MP:预检 https 2 备用线路", "etnode.zkitefly.eu.org/node1" in tm and "etnode.zkitefly.eu.org/node2" in tm)
check("MP:https HEAD 探测", 'HTTPMethod = @"HEAD"' in tm)

# ─── 7. 控件自动检查更新链 ───
cr = read("Natives/ControlRepoViewController.m")
check("Ctrl:autoCheck 类方法", "+ (void)autoCheckControlUpdatesOnce" in cr)
crh = read("Natives/ControlRepoViewController.h")
check("Ctrl:h 声明", "autoCheckControlUpdatesOnce" in crh)
lr = read("Natives/LauncherRootViewController.m")
check("Ctrl:启动链挂载", "[ControlRepoViewController autoCheckControlUpdatesOnce]" in lr)
plp = read("Natives/PLPreferences.m")
check("Ctrl:defaults 注册", '"auto_control_update_check": @NO' in plp)
lpv = read("Natives/LauncherPreferencesViewController.m")
check("Ctrl:设置行", '@"auto_control_update_check"' in lpv)
idx = json.load(open(os.path.join(REPO, "controls/index.json"), encoding="utf-8"))
sizes = {e["id"]: e["size"] for e in idx["layouts"]}
check("Ctrl:index size 对齐", sizes.get("classic") == 112523 and sizes.get("large-buttons") == 111938)

# ─── 8. 公告精简（43→6 + 脏值修复） ───
ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))
check("Ann:精简至 7 条（Task323 重锚实测：Task312 服务地区声明+下载速度公告 +1 = 7）", len(ann["announcements"]) == 7, "got %d" % len(ann["announcements"]))
check("Ann:pin 保留", any(a.get("pin") for a in ann["announcements"]))
check("Ann:priority 字符串化", all(a.get("priority") in ("high", "normal") for a in ann["announcements"]))
check("Ann:pinned 混写清零", all("pinned" not in a for a in ann["announcements"]))

# ─── 9. 品牌替换 ───
en = read("Natives/resources/en.lproj/Localizable.strings")
credits = [l for l in en.split("\n") if '"about.credits.body"' in l]
check("Brand:credits 上游署名保留", len(credits) == 1 and "Amethyst-iOS-MyRemastered" in credits[0])
# ★ Task263 重放版：ame267.jit.legacy_stik（Task267-net 入表）里的
#   "Amethyst-MeloNX.js" 是旧 sideload 构建包内脚本文件的【事实文件名】
#   （老 StikDebug 用户靠它认文件），与 credits 同属"非品牌自称"豁免类。
legacy_jit = [l for l in en.split("\n") if '"ame267.jit.legacy_stik"' in l]
check("Brand:legacy JIT 历史文件名事实引用保留", len(legacy_jit) == 1 and "Amethyst-MeloNX.js" in legacy_jit[0])
body_no_credits = "\n".join(l for l in en.split("\n") if '"about.credits.body"' not in l and '"ame267.jit.legacy_stik"' not in l)
check("Brand:en 表展示层零 Amethyst", "Amethyst" not in body_no_credits)
app = read("Natives/AppDelegate.m") + read("Natives/JavaLauncher.m") + read("Natives/LauncherPreferences.m") + read("Natives/main_hook.m")
check("Brand:日志前缀 [Prisma]", "[Amethyst]" not in app and "[Prisma]" in app)
uc = read("Natives/UpdateChecker.m")
check("Brand:UA Prisma", "Prisma-iOS-UpdateChecker" in uc)
faq = read("help-faq.json")
check("Brand:help-faq 检索串同步", "[Amethyst]" not in faq)
check("Brand:包名/进程名不动", 'CFBundleExecutable' in read("Natives/Info.plist") and "com.air-devs.air" in read("Natives/Info.plist"))

# ─── 10. i18n 键 ───
zh = read("Natives/resources/zh-CN.lproj/Localizable.strings")
check("i18n:orphan_confirm en 转义", '\\"%@\\"' in en and '"cleanup.orphan_confirm"' in en)
check("i18n:auto_update_found 四表", all(
    '"custom_controls.repo.auto_update_found"' in read(f"Natives/resources/{l}.lproj/Localizable.strings")
    for l in ("en", "zh-Hans", "zh-CN", "zh-Hant")))
check("i18n:jvm_preset 键四表", all(
    '"preference.title.jvm_preset"' in read(f"Natives/resources/{l}.lproj/Localizable.strings")
    for l in ("en", "zh-Hans", "zh-CN", "zh-Hant")))

# ─── 11. CI 提速 ───
yml = read(".github/workflows/development.yml")
check("CI:brew 合并单步", "brew install ldid meson ninja bison pkg-config || true" in yml)
check("CI:pip 缓存步", "actions/cache@v4" in yml and "~/.cache/pip" in yml)

# ─── 汇总 ───
fails = [r for r in results if not r[1]]
print("verify_task255: %d/%d PASS" % (len(results) - len(fails), len(results)))
for name, ok, detail in results:
    print(("  PASS  " if ok else "  FAIL  ") + name + (("  -- " + detail) if detail and not ok else ""))
sys.exit(1 if fails else 0)
