#!/usr/bin/env python3
# Task305: SideStore "AppexBundleUnknownExtensionPointIdentifier" 根修
# Helper/Info.plist 摘除 EXAppExtensionAttributes 字典（EXExtensionPointIdentifier=
# com.prisma-devs.prisma.PrismaJITHelper 是自定义值，installd 不认识 → 拒装）。
# 保留 NSExtension=com.apple.widgetkit-extension（Task303 装机实锤 installd 对
# appex placeholder 强制要求 extensionDictionary）。
# EXKit XPC 观察者轨装机三证判死（Code=19，Task302/304），EX 属性兜底价值归零。
import plistlib
import sys

PATH = "/home/z/my-project/repo-prisma/Natives/stikjit/integration/Helper/Info.plist"

with open(PATH, "rb") as f:
    data = f.read()

key = b"<key>EXAppExtensionAttributes</key>"
idx = data.find(key)
if idx < 0:
    print("EXAppExtensionAttributes not found -- nothing to do (already removed?)")
    sys.exit(0)

# 回退到该 key 所在行行首
line_start = data.rfind(b"\n", 0, idx)
line_start = 0 if line_start < 0 else line_start + 1

# EX dict 内部无嵌套 dict（仅 key/string），key 后第一个 </dict> 即其闭合
close_idx = data.find(b"</dict>", idx)
if close_idx < 0:
    print("ERROR: closing </dict> not found -- aborting, file untouched")
    sys.exit(1)
block_end = close_idx + len(b"</dict>")
# 吃掉块后换行
if data[block_end:block_end + 1] == b"\n":
    block_end += 1

removed = data[line_start:block_end]
if b"NSExtension" in removed or b"widgetkit" in removed:
    print("ERROR: removal block unexpectedly contains NSExtension -- aborting")
    sys.exit(1)

new_data = data[:line_start] + data[block_end:]

# plist 结构校验（摘除后必须是合法 plist 且 NSExtension 仍在位）
plistlib.loads(new_data)
if b"<key>NSExtension</key>" not in new_data or b"widgetkit-extension" not in new_data:
    print("ERROR: NSExtension missing after removal -- aborting")
    sys.exit(1)
if b"EXAppExtensionAttributes" in new_data or b"EXExtensionPointIdentifier" in new_data:
    print("ERROR: EX keys still present -- aborting")
    sys.exit(1)

with open(PATH, "wb") as f:
    f.write(new_data)

print("OK: EXAppExtensionAttributes block removed (%d bytes), plist valid, NSExtension kept" % len(removed))
