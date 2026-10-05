#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task 185 验证器：五线根修的锚点/结构/语法门。

覆盖：
  A. 共享匹配器（utils.h/utils.m）
  B. NeoForgeVersionFetcher 过滤器换匹配器
  C. ModLoaderInstallViewController：Fabric/Quilt 精选 + Forge 竞速验证重写
  D. ForgeInstallViewController：提取器/过滤器/分区头
  E. JIT 自愈式派发 + 键盘收起 + openURL 回执（RightPanel + NavCtrl + utils）
  F. keychain 三处根修（MicrosoftAuthenticator）
  G. 头像回退链（AvatarManager + 两个调用方）
  H. 语法门（全部改动文件括号平衡 + 字符串/注释感知）
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILED = []
PASSED = 0


def check(cond, label):
    global PASSED
    if cond:
        PASSED += 1
    else:
        FAILED.append(label)
        print(f"FAIL  {label}")


def read(p):
    return (ROOT / p).read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------- A. 匹配器
uh = read("Natives/utils.h")
um = read("Natives/utils.m")
check("ame185_loaderVersionMatchesGameVersion(NSString *loaderVersion, NSString *gameVersion);" in uh,
      "A1: utils.h 匹配器声明")
check("void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label);" in uh,
      "A2: utils.h 自愈式派发声明")
check("BOOL ame185_loaderVersionMatchesGameVersion(NSString *loaderVersion, NSString *gameVersion) {" in um,
      "A3: utils.m 匹配器实现")
check("void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label) {" in um,
      "A4: utils.m 自愈式派发实现")
check("ame185_loaderCandidates" in um and "ame185_gameCandidates" in um,
      "A5: 候选集函数在场")
# 匹配器行为单测（纯逻辑重实现于 Python，对照 utils.m 语义）
sys.path.insert(0, str(ROOT / "scripts"))
import task185_matcher_test  # noqa: E402
check(task185_matcher_test.run_all(), "A6: 匹配器行为单测（26.x/legacy/快照形态）")

# 自愈式派发三防线
for a, lbl in [("UIApplicationDidBecomeActiveNotification", "A7: 防线②前台激活监听"),
               ("QOS_CLASS_DEFAULT", "A8: 防线③看门狗队列"),
               ("NOT delivered after 120s", "A9: 看门狗终局锚点日志")]:
    check(a in um, lbl)

# ---------------------------------------------------- B. NeoForgeVersionFetcher
nvf = read("Natives/installer/NeoForgeVersionFetcher.m")
check("ame185_loaderVersionMatchesGameVersion(version, gameVersion)" in nvf,
      "B1: filterVersions 换共享匹配器")
check("extractMinecraftVersionFromNeoForgeVersion:version];\n        if" not in nvf,
      "B2: 旧提取器比对路径已退位（不再作为过滤器依据）")

# ---------------------------------------------------------- C. ModLoaderInstall
mli = read("Natives/installer/ModLoaderInstallViewController.m")
check("@property (nonatomic, assign) BOOL fabricQuiltShowAll;" in mli,
      "C1: 精选开关属性")
check("@property (nonatomic, strong) NSArray *fabricQuiltFullList;" in mli,
      "C2: 全量缓存属性")
check("ame185ShowAllRow(" in mli and "__AME185_SHOW_ALL__\\x1f" in mli or
      ("ame185ShowAllRow(" in mli and "\\x1f\\x1f\\x1f" in mli),
      "C3: 哨兵行打包格式（复用 \\x1f 显示约定）")
check("[raw hasPrefix:ame185ShowAllSentinel()]" in mli,
      "C4: didSelectRow 哨兵特判")
check("list.count > 30 && !strongSelf->_fabricQuiltShowAll" in mli,
      "C5: 30 条精选门")
check("ame185_fetchForgeFallbackJSON" in mli,
      "C6: BMCL 按版本 JSON 兜底方法")
check("bmclEnded && officialEnded && (!fallbackFired || fallbackEnded)" in mli,
      "C7: 三路终态判定")
check("ame185_loaderVersionMatchesGameVersion(raw, _gameVersion)" in mli,
      "C8: XML 解析过滤换匹配器")
check("_forgeParseSink" in mli and "_forgeParseCompletion" in mli,
      "C9: 竞速 sink 基础设施")
check("_forgeFallbackTask cancel" in mli,
      "C10: 兜底任务 dealloc 取消")
check("forge/minecraft/%@" in mli,
      "C11: 兜底 URL 端点")
# 竞速状态机：settled 只由非空结果置位
check(re.search(r"if \(!settled && parsed\.count > 0\) \{\s*settled = YES;", mli) is not None,
      "C12: XML 源 settle 仅在 count>0")
check(re.search(r"if \(!settled && list\.count > 0\) \{\s*settled = YES;", mli) is not None,
      "C13: 兜底源 settle 仅在 count>0")

# --------------------------------------------------------- D. ForgeInstallVC
fiv = read("Natives/installer/ForgeInstallViewController.m")
check("!ame185_loaderVersionMatchesGameVersion(version, self.gameVersion)" in fiv,
      "D1: addVersionToList 双分支换匹配器（NeoForge+Forge 共用断言文本）")
check(fiv.count("ame185_loaderVersionMatchesGameVersion(version, self.gameVersion)") == 2,
      "D2: 两处过滤器都换（NeoForge + Forge 分支）")
check("majorVal >= 26" in fiv,
      "D3: 提取器 26.x 新纪元分支")
check("components.count - 1" in fiv,
      "D4: 去尾分量（build 号）规则")
check("^\\\\d+(\\\\.\\\\d+)*$" in fiv or "^\\d+(\\.\\d+)*$" in fiv,
      "D5: Forge 提取器正则扩展（数字点分全接受）")
check("ame185_numericHead" in fiv,
      "D6: 分区头数字前缀判定")

# ------------------------------------- E. JIT 自愈式派发 + 键盘 + 回执
rp = read("Natives/LauncherRightPanelViewController.m")
nc = read("Natives/LauncherNavigationController.m")
check(rp.count("ame185_dispatchToMainSelfHealing(^{") == 2,
      "E1: RightPanel 两处等待块换自愈式派发")
check(nc.count("ame185_dispatchToMainSelfHealing(^{") == 2,
      "E2: NavCtrl 两处等待块换自愈式派发")
check(rp.count("resignFirstResponder") >= 1 and nc.count("resignFirstResponder") >= 1,
      "E3: 双入口键盘收起")
check(rp.count("ame185_openJITEnablerURL") >= 6,
      "E4: RightPanel 助手定义 + 5 个调用点")
check(nc.count("ame185_openJITEnablerURL") >= 2,
      "E5: NavCtrl 助手定义 + 调用点")
check("apple-magnifier:// -> %d" in rp and "apple-magnifier:// -> %d" in nc,
      "E6: TrollStore 分支回执锚点（双文件）")
check(rp.count(r"openURL:.*options:@{} completionHandler:nil") == 0 and
      nc.count("options:@{} completionHandler:nil") == 0,
      "E7: JIT 链 openURL 无回执形态清零")
check("Task185 re-attach stikjit://" in rp and "Task185 re-attach stikjit://" in nc,
      "E8: 重挂回执取证（双文件）")
check('"RightPanel main wait"' in rp and '"RightPanel reattach wait"' in rp,
      "E9: RightPanel 派发标签")
check('"NavCtrl main wait"' in nc and '"NavCtrl reattach wait"' in nc,
      "E10: NavCtrl 派发标签")

# --------------------------------------------------- F. keychain 三处根修
msa = read("Natives/authenticator/MicrosoftAuthenticator.m")
check('self.authData[@"username"] = response[@"name"];' in msa
      and msa.find('self.authData[@"username"] = response[@"name"]') < msa.find("ame220_pic"),
      "F1: 先落 username 再处理头像键（顺序修复；Task220 重锚：不再拼 rms.net.cn 死链镜像，"
      "改为保留 Xbox gamerpic + 剔除脏值，username 仍先行）")
check("ame185_shown" in msa,
      "F2: 会话内弹窗去重")
check("ame187_showAccountRepairDialog(self.authData[@\"username\"]," in msa,
      "F3: 可行动的双语文案（Task187 升级为一键修复弹窗：删账号 + 拉起登录页，"
      "旧纯文案已由 ios_uikit_bridge.m 的弹窗体承接）")
check("OSStatus %d" in msa,
      "F4: keychain 状态码取证")
check('containsString:@"(null)"]' in msa,
      "F5: 坏 URL 内存态修复")
check('"Failed to load account tokens from keychain"' not in msa,
      "F6: 旧死胡同文案退场")

# --------------------------------------------------- G. 头像回退链
am_h = read("Natives/AvatarManager.h")
am_m = read("Natives/AvatarManager.m")
check("ame185_fetchAvatarForAuthData" in am_h and "ame185_fetchAvatarForAuthData" in am_m,
      "G1: 回退链方法（声明+实现）")
check("crafatar.com/renders/head" in am_m and "minotar.net/helm" in am_m,
      "G2: 两个回退源")
check("00000000-0000-0000-0000-000000000000" in am_m,
      "G3: Demo UUID 排除")
check("ame185_fetchAvatarForAuthData:currentAuth.authData" in rp,
      "G4: RightPanel 调用方切换")
check("ame185_fetchAvatarForAuthData:auth.authData" in read("Natives/LauncherNewsViewController.m"),
      "G5: NewsView 调用方切换")

# ---------------------------------------------------------------- H. 语法门
def bracket_balance(text, allow_delta=0):
    """字符串/字符字面量与 // 注释感知的括号平衡（对齐 task175 工艺）。"""
    depth_p = depth_b = depth_c = 0
    i, n = 0, len(text)
    state = "code"  # code | str | chr | line_comment | block_comment
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if ch == '"':
                state = "str"
            elif ch == "'":
                state = "chr"
            elif ch == "/" and nxt == "/":
                state = "line_comment"; i += 1
            elif ch == "/" and nxt == "*":
                state = "block_comment"; i += 1
            elif ch == "(":
                depth_p += 1
            elif ch == ")":
                depth_p -= 1
            elif ch == "[":
                depth_b += 1
            elif ch == "]":
                depth_b -= 1
            elif ch == "{":
                depth_c += 1
            elif ch == "}":
                depth_c -= 1
        elif state == "str":
            if ch == "\\":
                i += 1
            elif ch == '"':
                state = "code"
        elif state == "chr":
            if ch == "\\":
                i += 1
            elif ch == "'":
                state = "code"
        elif state == "line_comment":
            if ch == "\n":
                state = "code"
        elif state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"; i += 1
        i += 1
    return depth_p, depth_b, depth_c


EDITED = [
    "Natives/utils.h", "Natives/utils.m",
    "Natives/installer/NeoForgeVersionFetcher.m",
    "Natives/installer/ModLoaderInstallViewController.m",
    "Natives/installer/ForgeInstallViewController.m",
    "Natives/LauncherRightPanelViewController.m",
    "Natives/LauncherNavigationController.m",
    "Natives/authenticator/MicrosoftAuthenticator.m",
    "Natives/AvatarManager.h", "Natives/AvatarManager.m",
    "Natives/LauncherNewsViewController.m",
]
for f in EDITED:
    text = read(f)
    dp, db, dc = bracket_balance(text)
    ok = (dp == 0 and db == 0 and dc == 0)
    check(ok, f"H: 括号平衡 {f} ((){dp} []{db} {{}}{dc})")

# version.h addendum
vh = read("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("Task 185" in vh, "H2: version.h Task 185 addendum 在场")

print(f"\nRESULT: {'ALL PASS' if not FAILED else f'{len(FAILED)} FAILED'} ({PASSED} passed)")
sys.exit(1 if FAILED else 0)
