#!/usr/bin/env python3
# Task267（屎山优化第 1 批）：目标实例三元式单点化——零行为变更重构。
# ModVersionViewController.m 5 处  self.targetProfileName ?: (selected ?: @"default")
# DownloadViewController.m   6 处  self.targetProfileName ?: @"default"
# 收敛为文件级 static inline（两文件各自作用域，跨类 Ame232 前置实现亦可直调）。
import re, sys

def patch(path, pattern, repl, label, expect=1, marker=None):
    data = open(path, "rb").read().decode("utf-8")
    if marker:
        if marker in data:
            print(f"SKIP {label}")
            return
    elif not callable(repl) and repl in data:
        print(f"SKIP {label}")
        return
    new, n = re.subn(pattern, repl, data, count=expect)
    if n != expect:
        print(f"FAIL {label}: {n}/{expect}", file=sys.stderr)
        sys.exit(1)
    open(path, "wb").write(new.encode("utf-8"))
    print(f"OK {label} x{n}")

MV = "Natives/ModVersionViewController.m"
DL = "Natives/DownloadViewController.m"

# ① ModVersionVC：注入 helper（首个 @implementation 之前，imports 之后）
HELPER_MV = """
/// Task267（屎山优化）：目标实例三元式单点化（原 5 处复制粘贴表达式收敛）。
/// 语义与 Task265 原式逐字节等价：来源页显式绑定优先，否则跟随当前选中实例。
static inline NSString *ame267_effectiveTargetProfile(NSString *ame267_target) {
    return ame267_target ?: ([PLProfiles current].selectedProfileName ?: @"default");
}
"""
patch(MV,
    r"(@implementation ModVersionViewController\n)",
    lambda m: HELPER_MV + m.group(1),
    "mv-helper", marker="ame267_effectiveTargetProfile")

MV_EXPR = re.escape('self.targetProfileName ?: ([PLProfiles current].selectedProfileName ?: @"default")')
patch(MV, MV_EXPR + "; // ★ Task265：依赖跳转页继承目标实例",
      "ame267_effectiveTargetProfile(self.targetProfileName); // ★ Task265：依赖跳转页继承目标实例（Task267 单点化）",
      "mv-site-1187")
patch(MV, "NSString \\*ame236_profile = " + MV_EXPR + ";",
      "NSString *ame236_profile = ame267_effectiveTargetProfile(self.targetProfileName);",
      "mv-site-1211")
patch(MV, "detail\\.targetProfileName = " + MV_EXPR + ";",
      "detail.targetProfileName = ame267_effectiveTargetProfile(self.targetProfileName);",
      "mv-site-1253")
patch(MV, "ame235_vc\\.targetProfileName = " + MV_EXPR + "; // ★ Task265：依赖跳转页继承目标实例",
      "ame235_vc.targetProfileName = ame267_effectiveTargetProfile(self.targetProfileName); // ★ Task265：依赖跳转页继承目标实例（Task267 单点化）",
      "mv-site-1637")
patch(MV, "NSString \\*ame235_profile = " + MV_EXPR + ";",
      "NSString *ame235_profile = ame267_effectiveTargetProfile(self.targetProfileName);",
      "mv-site-1659")

# ② DownloadVC：注入 helper
HELPER_DL = """
/// Task267（屎山优化）：下载页锁定目标单点化（原 6 处复制粘贴表达式收敛）。
/// 语义与原式逐字节等价：锁定打开下载页时的 targetProfileName，缺省 default。
static inline NSString *ame267_lockedDownloadTarget(NSString *ame267_target) {
    return ame267_target ?: @"default";
}
"""
patch(DL,
    r"(@implementation DownloadViewController\n)",
    lambda m: HELPER_DL + m.group(1),
    "dl-helper", marker="ame267_lockedDownloadTarget")

DL_EXPR = re.escape('self.targetProfileName ?: @"default"')
data = open(DL, "rb").read().decode("utf-8")
n_expr = len(re.findall(DL_EXPR, data))
# 699 行的 `self.targetProfileName.length` 判断不在替换域（表达式带 .length）
new, n = re.subn(DL_EXPR, "ame267_lockedDownloadTarget(self.targetProfileName)", data)
if n != n_expr or n == 0:
    print(f"FAIL dl-sites: {n}/{n_expr}", file=sys.stderr)
    sys.exit(1)
open(DL, "wb").write(new.encode("utf-8"))
print(f"OK dl-sites x{n}")

print("ALL OK")
