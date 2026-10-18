#!/usr/bin/env python3
# Task295：RightPanel 等待环取消语义双通道——字节级补丁（Edit 工具对不可见
# 字符反复未命中，沿 Task293 Makefile 家法走 python 字面量替换）。
# ①删除第二处 ame267_cancelled 声明（Task295 已上移，双声明 = 编译错误）
# ②等待弹窗 cancel handler 加级联忽略守卫
import io, sys

P = "/home/z/my-project/repo-prisma/Natives/LauncherRightPanelViewController.m"
src = io.open(P, encoding="utf-8").read()

# ---- ①删除第二处声明（仅在声明行 + 前置注释 + alert 行的精确序列命中时替换）----
old1 = (
    u"    // Task267\uff1a\u7b49\u5f85\u671f\u53ef\u53d6\u6d88\u2014\u2014\u65e7\u7248 120s\uff08Task226 \u81ea\u52a8\u91cd\u8bd5\u540e\u6700\u957f 240s\uff09\u5f39\u7a97\n"
    u"    // \u96f6 action\uff0c\u60f3\u9000\u51fa\u53ea\u80fd\u6740\u8fdb\u7a0b = \u300cJIT \u672a\u54cd\u5e94\u300d\u89c2\u611f\u7684\u76f4\u63a5\u6765\u6e90\u3002\n"
    u"    __block BOOL ame267_cancelled = NO;\n"
)
new1 = (
    u"    // Task267\uff1a\u7b49\u5f85\u671f\u53ef\u53d6\u6d88\u2014\u2014\u65e7\u7248 120s\uff08Task226 \u81ea\u52a8\u91cd\u8bd5\u540e\u6700\u957f 240s\uff09\u5f39\u7a97\n"
    u"    //   \u96f6 action\uff0c\u60f3\u9000\u51fa\u53ea\u80fd\u6740\u8fdb\u7a0b = \u300cJIT \u672a\u54cd\u5e94\u300d\u89c2\u611f\u7684\u76f4\u63a5\u6765\u6e90\u3002\n"
    u"    //   \uff08ame267_cancelled/builtinDialogShowing \u58f0\u660e\u5df2\u4e0a\u79fb\u81f3 builtin \u5f39\u7a97\u95ed\u5305\n"
    u"    //   \u4e4b\u524d\u2014\u2014Task295 \u53d6\u6d88\u8bed\u4e49\u53cc\u901a\u9053\u9700\u4e24\u5904\u95ed\u5305\u5171\u4eab\uff0c\u89c1\u4e0a\u65b9\u6ce8\u91ca\u3002\uff09\n"
)
assert src.count(old1) == 1, "decl-anchor count=%d" % src.count(old1)
src = src.replace(old1, new1)

# ---- ②cancel handler 级联忽略守卫 ----
old2 = (
    u"        ame267_cancelled = YES;\n"
    u"        NSLog(@\"[JIT] [RightPanel] Task267: user cancelled JIT wait (main)\");\n"
)
new2 = (
    u"        // \u2605 Task295\uff1a\u5931\u8d25\u5f39\u7a97\u5448\u73b0\u5f15\u53d1\u7684\u672c\u5f39\u7a97\u7a0b\u5e8f\u6027 dismiss \u4e5f\u4f1a\u56de\u8c03\u8fd9\u91cc\n"
    u"        //   \uff08UIKit \u5bf9\u7a0b\u5e8f\u6027 dismiss \u540c\u6837\u89e6\u53d1 cancel action\uff09\u2014\u2014\u5f39\u7a97\u5728\u573a\u671f\u95f4\n"
    u"        //   \u89c1\u4f4d\u5373\u5ffd\u7565\uff0c\u975e\u7528\u6237\u610f\u56fe\uff08\u88c5\u673a latestlog \u5b9e\u9524\u8bef\u7f6e\u4f4d\u5f03\u542f\u94fe\uff09\u3002\n"
    u"        if (ame267_builtinDialogShowing) {\n"
    u"            NSLog(@\"[JIT] [RightPanel] Task295: waiting-alert cancel fired by builtin-dialog cascade -- ignored\");\n"
    u"            return;\n"
    u"        }\n"
    u"        ame267_cancelled = YES;\n"
    u"        NSLog(@\"[JIT] [RightPanel] Task267: user cancelled JIT wait (main)\");\n"
)
assert src.count(old2) == 1, "cancel-anchor count=%d" % src.count(old2)
src = src.replace(old2, new2)

io.open(P, "w", encoding="utf-8").write(src)
print("patched OK: decl moved (dup removed) + cascade guard added")
