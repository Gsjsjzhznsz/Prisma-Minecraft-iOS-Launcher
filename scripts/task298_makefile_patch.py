#!/usr/bin/env python3
"""task298_makefile_patch.py -- Makefile JIT payload 段字节级补丁（TAB 保形）。
三处改动：
  1) Task295 注释块后追加 Task298 注释块（单 TAB 独立注释行，绝不入续行链）
  2) appexpt 嵌入名 PrismaJITHelper.appexpt -> AngelAuraAmethyst.appexpt（模块名约定）
  3) appex 二进制 ldid 后补 bundle 级 ldid -S 密封行（非致命 WARN）
  4) 尾部 echo 文案同步新文件名
幂等：已应用则跳过。任何匹配失败立即 exit 1（绝不静默）。
"""
import sys

PATH = 'Makefile'
src = open(PATH, 'rb').read().decode('utf-8')
orig = src

def must_replace(s, old, new, label):
    if new in s and old not in s:
        print(f'[task298] {label}: already applied, skip')
        return s
    count = s.count(old)
    if count != 1:
        print(f'[task298] FATAL {label}: expected 1 occurrence, found {count}')
        sys.exit(1)
    print(f'[task298] {label}: applied')
    return s.replace(old, new, 1)

T = '\t'

# 1) Task298 注释块：锚定 Task295 注释块结尾行（单 TAB）
anchor295 = (T + '#   in Extensions/" 同款）+ 扩展点定义 .appexpt 同目嵌入。\n')
comment298 = (T + '# ★ Task298（装机 run#917 产物 Code=19 实锤后三源定案）：扩展点定义\n'
              + T + '#   文件名必须是【app 模块名】约定（Xcode exutil extract-extension-points\n'
              + T + '#   产出 $(PRODUCT_MODULE_NAME).appexpt；rxlab 实测 test_app_extension.appexpt、\n'
              + T + '#   torrent7 Packaging/TorrentApp.appexpt 同款）——旧名 PrismaJITHelper.appexpt\n'
              + T + '#   （扩展点名）错误；且内容必须含 EXVersion=2 + EXExtensionPointName +\n'
              + T + '#   _EXScopeRestriction=application（torrent7 提交的真实可用 .appexpt 全键），\n'
              + T + '#   缺键时 extensionkitd 解析不了扩展点 → AppExtensionPoint.Monitor 拒注册\n'
              + T + '#   → builtin 轨 Code=19 "Failed to add observer"。appex bundle 同时补\n'
              + T + '#   ldid -S 目录级密封（PocketJ 上游 codesign 重密封 .appex 同语义）。\n')
src = must_replace(src, anchor295, anchor295 + comment298, 'task298-comment')

# 2) appexpt 嵌入名（payload 段，注意保持 TAB 与行尾续行反斜杠）
old_cp = (T * 2 + "cp $(JIT_STAGING)/PrismaJITHelper.appexpt $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appexpt || exit 1; \\\n")
new_cp = (T * 2 + "cp $(JIT_STAGING)/PrismaJITHelper.appexpt $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/AngelAuraAmethyst.appexpt || exit 1; \\\n")
src = must_replace(src, old_cp, new_cp, 'appexpt-rename')

# 3) appex bundle 密封行：插在二进制 ldid 行之后
old_ldid = (T * 2 + "ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex/PrismaJITHelper; \\\n")
new_ldid = old_ldid + (T * 2 + "ldid -S $(OUTPUTDIR)/Payload/AngelAuraAmethyst.app/Extensions/PrismaJITHelper.appex || echo '[Prisma v$(VERSION)] payload - WARN: appex bundle seal failed (continuing)'; \\\n")
src = must_replace(src, old_ldid, new_ldid, 'appex-bundle-seal')

# 4) 尾部 echo 文案
old_echo = (T * 2 + "echo '[Prisma v$(VERSION)] payload - JIT helper embedded (Extensions/PrismaJITHelper.appex + .appexpt)'; \\\n")
new_echo = (T * 2 + "echo '[Prisma v$(VERSION)] payload - JIT helper embedded (Extensions/PrismaJITHelper.appex + AngelAuraAmethyst.appexpt)'; \\\n")
src = must_replace(src, old_echo, new_echo, 'echo-text')

if src == orig:
    print('[task298] FATAL: no change produced')
    sys.exit(1)

open(PATH, 'wb').write(src.encode('utf-8'))
print('[task298] Makefile patched (byte-level, TAB preserved)')
