#!/usr/bin/env python3
# Task267（E 项）：JIT 等待期可取消——"jit 容易未响应"根修。
# 病历：等待弹窗零 action，用户被锁 120s（Task226 自动重试后最长 240s），
# 想退出只能杀进程 = "未响应"观感直接来源。修法：四个等待点
#（RightPanel 主等待/重挂 + NavCtrl 主等待/重挂）统一挂 cancel action +
# 条件包装（取消 ≤200ms 退出循环）+ 完成块取消分支（不启动、恢复交互态）。
# 全部字节级替换（保行尾），幂等（重复运行跳过已应用项）。
import re, sys

def patch(path, pattern, repl, label, expect=1, flags=0):
    with open(path, "rb") as f:
        data = f.read().decode("utf-8")
    if repl in data:
        print(f"SKIP {label}")
        return
    new, n = re.subn(pattern, repl, data, count=expect, flags=flags)
    if n != expect:
        print(f"FAIL {label}: {n}/{expect} in {path}", file=sys.stderr)
        sys.exit(1)
    with open(path, "wb") as f:
        f.write(new.encode("utf-8"))
    print(f"OK {label}")

RP = "Natives/LauncherRightPanelViewController.m"
NV = "Natives/LauncherNavigationController.m"

# ============ RightPanel 主等待 ============
patch(RP,
    r"""(    UIAlertController \*alert = \[UIAlertController alertControllerWithTitle:localize\(@"i18n_str_437", nil\)\n +message:hasTrollStoreJIT[^\n]*\n +preferredStyle:UIAlertControllerStyleAlert\];\n)""",
    """    // Task267：等待期可取消——旧版 120s（Task226 自动重试后最长 240s）弹窗
    // 零 action，想退出只能杀进程 = 「JIT 未响应」观感的直接来源。
    __block BOOL ame267_cancelled = NO;
\1    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        ame267_cancelled = YES;
        NSLog(@"[JIT] [RightPanel] Task267: user cancelled JIT wait (main)");
    }]];
""",
    "rp-main-alert")

patch(RP,
    r"""(    UIAlertController \*alert = \[UIAlertController alertControllerWithTitle:localize\(@"i18n_str_437", nil\)\n +message:localize\(@"i18n_str_439", nil\)\n +preferredStyle:UIAlertControllerStyleAlert\];\n)""",
    """    // Task267：重挂等待同样可取消（同主等待语义）。
    __block BOOL ame267_cancelled = NO;
\1    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        ame267_cancelled = YES;
        NSLog(@"[JIT] [RightPanel] Task267: user cancelled JIT wait (reattach)");
    }]];
""",
    "rp-reattach-alert")

patch(RP,
    r"return isJITEnabled\(false\); ",
    "return (ame267_cancelled || isJITEnabled(false)); ",
    "rp-main-cond")

patch(RP,
    r"return JIT26IsLikelyDebuggerKeepAttached\(\); ",
    "return (ame267_cancelled || JIT26IsLikelyDebuggerKeepAttached()); ",
    "rp-reattach-cond")

# bgt 收尾块后插入取消分支（本文件两处：主等待 + 重挂）
BG = """            if (ame172_bgt != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:ame172_bgt];
                ame172_bgt = UIBackgroundTaskInvalid;
            }
"""
CANCEL_RP = """            if (ame267_cancelled) {
                // Task267：用户主动取消——不启动游戏，恢复启动器交互态
                NSLog(@"[JIT] [RightPanel] Task267: JIT wait cancelled -- abandoning launch");
                self.task = nil;
                [self setInteractionEnabled:YES];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
                return;
            }
"""
patch(RP,
    re.escape(BG),
    BG + CANCEL_RP,
    "rp-cancel-branches", expect=2)

# ============ NavCtrl 主等待（含退役的 TODO 注释块） ============
patch(NV,
    r"""/\* TODO:\n    UIAlertAction \*cancel = \[UIAlertAction actionWithTitle:localize\(@"Cancel", nil\) style:UIAlertActionStyleCancel handler:\^\{\n        \n    \};\n    \[alert addAction:cancel\];\n\*/\n""",
    "",
    "nv-todo-removed")

patch(NV,
    r"""(    UIAlertController\* alert = \[UIAlertController alertControllerWithTitle:localize\(@"launcher\.wait_jit\.title", nil\)\n +message:hasTrollStoreJIT[^\n]*\n +preferredStyle:UIAlertControllerStyleAlert\];\n)""",
    """    // Task267：等待期可取消（同 RightPanel 主等待语义，旧 TODO 落地）。
    __block BOOL ame267_cancelled = NO;
\1    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        ame267_cancelled = YES;
        NSLog(@"[JIT] [NavCtrl] Task267: user cancelled JIT wait (main)");
    }]];
""",
    "nv-main-alert")

patch(NV,
    r"""(    UIAlertController\* alert = \[UIAlertController alertControllerWithTitle:localize\(@"launcher\.wait_jit\.title", nil\)\n +message:localize\(@"launcher\.wait_jit\.message", nil\)\n +preferredStyle:UIAlertControllerStyleAlert\];\n)""",
    """    // Task267：重挂等待同样可取消（同主等待语义）。
    __block BOOL ame267_cancelled = NO;
\1    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * _Nonnull action) {
        ame267_cancelled = YES;
        NSLog(@"[JIT] [NavCtrl] Task267: user cancelled JIT wait (reattach)");
    }]];
""",
    "nv-reattach-alert")

patch(NV,
    r"return isJITEnabled\(false\); ",
    "return (ame267_cancelled || isJITEnabled(false)); ",
    "nv-main-cond")

patch(NV,
    r"return JIT26IsLikelyDebuggerKeepAttached\(\); ",
    "return (ame267_cancelled || JIT26IsLikelyDebuggerKeepAttached()); ",
    "nv-reattach-cond")

CANCEL_NV = """            if (ame267_cancelled) {
                // Task267：用户主动取消——不启动游戏，恢复启动器交互态
                NSLog(@"[JIT] [NavCtrl] Task267: JIT wait cancelled -- abandoning launch");
                self.task = nil;
                [self setInteractionEnabled:YES forDownloading:YES];
                [self reloadProfileList];
                return;
            }
"""
patch(NV,
    re.escape(BG),
    BG + CANCEL_NV,
    "nv-cancel-branches", expect=2)

print("ALL OK")
