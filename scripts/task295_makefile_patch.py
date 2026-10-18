#!/usr/bin/env python3
# Task295：Makefile JIT 打包根修——字节级补丁（\t 保真，Task293 TAB 险情家法）。
#
# 病历（装机 latestlog Code=19 "Failed to add observer" + PocketJ 上游
# build_pocketj.sh 注释定案）：ExtensionKit 自定义扩展点要求宿主包
# Extensions/ 内有 <点>.appexpt 扩展点定义文件（Xcode 构建由 Swift 编译器
# 自动写入 wrapper 的 Extensions/，swiftc 直编不落盘）；且泛用
# ExtensionFoundation appex 的正确落位是 Extensions/ 而非 PlugIns/
# （上游注释原话 "Generic ExtensionFoundation extensions live in
# Extensions/"）。本仓 Makefile 两处全错：appex 塞 PlugIns/ + 从未生成
# appexpt → extensionkitd 无法解析扩展点 → Monitor 注册观察者即抛 Code=19
# → builtin 轨必失败。
#
# 补丁：
# ①jit_helper 尾部：staging 无编译器自产 .appexpt 时拷入库内手作版
#   （老 .appextensionpoint content-keyed 形态，与上游 appex 的
#   EXExtensionPointIdentifier=com.prisma-devs.prisma.PrismaJITHelper 对齐）。
# ②payload 嵌入段：PlugIns/PrismaJITHelper.appex → Extensions/PrismaJITHelper.appex，
#   并把 .appexpt 一并嵌入宿主包 Extensions/。
import io

P = "/home/z/my-project/repo-prisma/Makefile"
src = io.open(P, encoding="utf-8").read()
TAB = "\t"

# ---- ①jit_helper 尾部（锚：build ok echo 行后追加收集步）----
a1 = TAB + u"echo '[Prisma v$(VERSION)] jit_helper - build ok'\n"
n1 = (
    TAB + u"echo '[Prisma v$(VERSION)] jit_helper - build ok'\n"
    + TAB + u"# \u2462 \u5bbf\u4e3b\u6269\u5c55\u70b9\u5b9a\u4e49\uff08.appexpt\uff09\uff1aExtensionFoundation @Definition \u5c55\u5f00\u5728 Xcode \u4e0b\u7531\n"
    + TAB + u"#   Swift \u7f16\u8bd1\u5668\u76f4\u5199 wrapper \u7684 Extensions/ \u76ee\u5f55\uff1bswiftc \u76f4\u7f16\u4e0d\u843d\u76d8\u2014\u2014\u82e5\u672c\u6b21\n"
    + TAB + u"#   \u7f16\u8bd1\u5728 staging \u81ea\u4ea7\u4e86 .appexpt \u5219\u4f18\u5148\u91c7\u7528\uff0c\u5426\u5219\u7528\u5e93\u5185\u624b\u4f5c\u7248\uff08\u8001\n"
    + TAB + u"#   .appextensionpoint content-keyed \u5f62\u6001\uff0c\u4e0e appex \u7684\n"
    + TAB + u"#   EXExtensionPointIdentifier \u5bf9\u9f50\uff09\u3002\u7f3a\u6b64\u6587\u4ef6 extensionkitd \u5373\u62a5\n"
    + TAB + u"#   \"Failed to add observer\"\uff08PocketJ \u4e0a\u6e38 build_pocketj.sh \u540c\u6b3e\u75c5\u5386\n"
    + TAB + u"#   \u5b9a\u6848\uff1b\u88c5\u673a run#909 \u4ea7\u7269 Code=19 \u5b9e\u9524\uff09\u3002\n"
    + TAB + u"appexpt_src=$$(find $(JIT_STAGING) $(SOURCEDIR) -maxdepth 1 -name '*.appexpt' 2>/dev/null | head -1); \\\n"
    + TAB + u"if [ -n \"$$appexpt_src\" ]; then cp -p \"$$appexpt_src\" $(JIT_STAGING)/PrismaJITHelper.appexpt; \\\n"
    + TAB + u"else cp $(JIT_APP_SRC)/integration/Host/PrismaJITHelper.appexpt $(JIT_STAGING)/PrismaJITHelper.appexpt; fi\n"
)
assert src.count(a1) == 1, "jit_helper-anchor count=%d" % src.count(a1)
src = src.replace(a1, n1)

# ---- ②payload 嵌入段（锚：mkdir PlugIns 行起至 chmod 755 行止的整块；recipe 行 = 双 TAB）----
T2 = "\t\t"
old_block = (
    T2 + u"mkdir -p $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/PlugIns/PrismaJITHelper.appex $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks; \\\n"
    + T2 + u"cp $(JIT_STAGING)/PrismaJITHelper $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/PlugIns/PrismaJITHelper.appex/PrismaJITHelper || exit 1; \\\n"
    + T2 + u"cp $(SOURCEDIR)/Natives/stikjit/integration/Helper/Info.plist $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/PlugIns/PrismaJITHelper.appex/Info.plist || exit 1; \\\n"
    + T2 + u"cp $(JIT_STAGING)/Resources/universal.js $(JIT_STAGING)/Resources/legacy.js $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/PlugIns/PrismaJITHelper.appex/ || exit 1; \\\n"
    + T2 + u"ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/PlugIns/PrismaJITHelper.appex/PrismaJITHelper; \\\n"
    + T2 + u"cp $(JIT_STAGING)/libPrismaJITCoordinator.dylib $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks/ || exit 1; \\\n"
    + T2 + u"ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks/libPrismaJITCoordinator.dylib; \\\n"
    + T2 + u"chmod 755 $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/PlugIns/PrismaJITHelper.appex/PrismaJITHelper $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks/libPrismaJITCoordinator.dylib; \\\n"
    + T2 + u"echo '[Prisma v$(VERSION)] payload - JIT helper embedded (PlugIns/PrismaJITHelper.appex)'; \\\n"
)
new_block = (
    T2 + u"# \u2605 Task295\uff1a\u6cdb\u7528 ExtensionFoundation appex \u843d Extensions/\uff08\u975e PlugIns/\uff0c\n"
    + T2 + u"#   \u4e0a\u6e38 build_pocketj.sh \"Generic ExtensionFoundation extensions live\n"
    + T2 + u"#   in Extensions/\" \u540c\u6b3e\uff09+ \u6269\u5c55\u70b9\u5b9a\u4e49 .appexpt \u540c\u76ee\u5d4c\u5165\u3002\n"
    + T2 + u"mkdir -p $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks; \\\n"
    + T2 + u"cp $(JIT_STAGING)/PrismaJITHelper $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex/PrismaJITHelper || exit 1; \\\n"
    + T2 + u"cp $(SOURCEDIR)/Natives/stikjit/integration/Helper/Info.plist $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex/Info.plist || exit 1; \\\n"
    + T2 + u"cp $(JIT_STAGING)/Resources/universal.js $(JIT_STAGING)/Resources/legacy.js $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex/ || exit 1; \\\n"
    + T2 + u"cp $(JIT_STAGING)/PrismaJITHelper.appexpt $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appexpt || exit 1; \\\n"
    + T2 + u"ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex/PrismaJITHelper; \\\n"
    + T2 + u"cp $(JIT_STAGING)/libPrismaJITCoordinator.dylib $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks/ || exit 1; \\\n"
    + T2 + u"ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks/libPrismaJITCoordinator.dylib; \\\n"
    + T2 + u"chmod 755 $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex/PrismaJITHelper $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Frameworks/libPrismaJITCoordinator.dylib; \\\n"
    + T2 + u"echo '[Prisma v$(VERSION)] payload - JIT helper embedded (Extensions/PrismaJITHelper.appex + .appexpt)'; \\\n"
)
assert src.count(old_block) == 1, "payload-block count=%d" % src.count(old_block)
src = src.replace(old_block, new_block)

io.open(P, "w", encoding="utf-8").write(src)
print("Makefile patched: appexpt collection + Extensions/ embedding")
