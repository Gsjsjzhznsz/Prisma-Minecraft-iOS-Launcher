#!/usr/bin/env python3
"""Task223 item-24 port E: CI runner Xcode-26 selection (upstream 2fbac63ef).
Applies the remaining workflow edits that need CRLF-aware handling:
  1. Replace the 'Select Xcode 15.4' step with the prefer-26+ block.
  2. Bump the three cache bucket keys macos14 -> macos15.
Idempotent: skips parts already applied.
"""
import sys

WF = "/home/z/my-project/Amethyst-iOS-MyRemastered/.github/workflows/development.yml"

with open(WF, "rb") as f:
    data = f.read()

text = data.decode("utf-8")
CRLF = "\r\n" in text
nl = "\r\n" if CRLF else "\n"

changed = []

# --- 1. Select Xcode step -------------------------------------------------
old_step = nl.join([
    "      - name: Select Xcode 15.4",
    "        run: |",
    "          sudo xcode-select -s /Applications/Xcode_15.4.app/Contents/Developer",
    "          xcodebuild -version || true",
])
new_step_lines = [
    "      # \u2605 Task223 \u4e0a\u6e38\u540c\u6b65\uff08upstream 2fbac63ef\uff09\uff1a\u4f18\u5148 Xcode \u226526 \u2014\u2014 \u4ea7\u7269\u62ff\u5230",
    "      #   iOS 26 SDK \u540e\uff0cUIVisualEffectView \u7cfb\u7edf\u6750\u8d28\u5728 iPadOS 26/27 \u4e0a\u4ee5\u6db2\u6001",
    "      #   \u73bb\u7483\u6e32\u67d3\uff08\u6e05\u5355\u7b2c 15 \u9879 iPadOS 27 \u8bbe\u8ba1\u8bed\u8a00\u7684\u6784\u5efa\u4fa7\u524d\u63d0\uff09\uff1b\u627e\u4e0d\u5230",
    "      #   Xcode 26 \u65f6\u4fdd\u6301 runner \u9ed8\u8ba4\u5de5\u5177\u94fe\uff08\u8001 SDK \u4ec5\u7f3a\u65b0\u5916\u89c2\uff0c\u4e0d\u5f71\u54cd\u529f\u80fd\uff09\u3002",
    "      #   SDKPATH/DEVELOPER_DIR \u5199\u5165 GITHUB_ENV\uff1aMakefile \u91cc\u662f SDKPATH ?=\uff08?=",
    "      #   \u4e0d\u8986\u76d6\u5df2\u6709\u503c\uff09\uff0c\u82e5\u73af\u5883\u6b8b\u7559\u65e7\u503c\u6216 CMake \u7f13\u5b58\u4e86\u65e7 CMAKE_OSX_SYSROOT\uff0c",
    "      #   \u5c31\u4f1a\u7528\u65e7 SDK \u7f16\u8bd1\u2014\u2014\u90a3\u6837\u6253\u5305\u51fa\u6765\u7684 App \u62ff\u4e0d\u5230 iOS 26 \u65b0\u5916\u89c2\u3002",
    "      - name: Select Xcode (prefer 26+ for iOS 26 Liquid Glass, fallback runner default)",
    "        run: |",
    "          echo \"== \u53ef\u7528 Xcode ==\"",
    "          ls -d /Applications/Xcode*.app 2>/dev/null || true",
    "          echo \"== \u9ed8\u8ba4 ==\"",
    "          xcodebuild -version || true",
    "          # \u9009\u6700\u65b0\u7684 Xcode \u2265 26\uff08\u6db2\u6001\u73bb\u7483\u9700\u8981 iOS 26 SDK\uff09\uff1b\u627e\u4e0d\u5230\u5c31\u4fdd\u6301\u9ed8\u8ba4\u3002",
    "          PICK=\"\"",
    "          for app in $(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V -r); do",
    "            PICK=\"$app\"; break",
    "          done",
    "          if [ -z \"$PICK\" ]; then",
    "            for app in $(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V -r); do",
    "              v=$(basename \"$app\" | sed -E 's/Xcode_?([0-9]+).*/\\1/')",
    "              if [ -n \"$v\" ] && [ \"$v\" -ge 26 ] 2>/dev/null; then PICK=\"$app\"; break; fi",
    "            done",
    "          fi",
    "          if [ -n \"$PICK\" ]; then",
    "            sudo xcode-select -s \"$PICK/Contents/Developer\"",
    "            echo \"\u2605 \u9009\u7528 $PICK\"",
    "          else",
    "            echo \"\u2605 \u672a\u627e\u5230 Xcode 26\uff0c\u4fdd\u6301 runner \u9ed8\u8ba4\u5de5\u5177\u94fe\uff08\u672c\u5305\u4e0d\u542b iOS 26 \u65b0\u5916\u89c2\uff09\"",
    "          fi",
    "          xcodebuild -version || true",
    "          SDK=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo '?')",
    "          SDKPATH_REAL=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo '')",
    "          echo \"\u2605 iPhoneOS SDK = $SDK\"",
    "          echo \"\u2605 SDKPATH = $SDKPATH_REAL\"",
    "          # \u5173\u952e\uff1a\u663e\u5f0f\u5199\u5165 GITHUB_ENV\uff0c\u5f3a\u5236\u540e\u7eed\u6240\u6709\u6b65\u9aa4\u7528\u540c\u4e00\u4e2a SDK\u3002",
    "          echo \"SDKPATH=$SDKPATH_REAL\" >> \"$GITHUB_ENV\"",
    "          echo \"DEVELOPER_DIR=$(xcode-select -p)\" >> \"$GITHUB_ENV\"",
    "          echo \"\u2605 \u5df2\u5199\u5165 GITHUB_ENV:SDKPATH / DEVELOPER_DIR\"",
]
new_step = nl.join(new_step_lines)

if "Select Xcode 15.4" in text:
    if old_step not in text:
        print("ERROR: old Select Xcode step not found verbatim", file=sys.stderr)
        sys.exit(1)
    text = text.replace(old_step, new_step, 1)
    changed.append("select-xcode step")
elif "prefer 26+ for iOS 26 Liquid Glass" in text:
    changed.append("select-xcode step (already applied)")
else:
    print("ERROR: Select Xcode step not found in either form", file=sys.stderr)
    sys.exit(1)

# --- 2. Cache bucket keys --------------------------------------------------
for old, new in [
    ("ccache-macos14-v1-", "ccache-macos15-v1-"),
    ("brew-macos14-v1-", "brew-macos15-v1-"),
    ("ccache-tool-macos14-v1-4.14.1", "ccache-tool-macos15-v1-4.14.1"),
]:
    n = text.count(old)
    if n:
        text = text.replace(old, new)
        changed.append(f"cache key {old.strip()} x{n}")

# Comment note on the ccache key bump (append to the Task206 comment line)
anchor = "          #   \u4e0e vgpu \u540c\u6b3e\u5165\u6876\u53e3\u5f84\uff1b\u5185\u5bb9\u54c8\u5e0c\u81ea\u5931\u6548\uff0c\u6876\u952e\u53ea\u4e3a\u914d\u7f6e\u6f02\u79fb\u6362\u6876\uff09"
note = "          #   Task223\uff1a\u6876\u952e macos14 -> macos15\uff08\u6362 runner + Xcode 26 \u5de5\u5177\u94fe\uff0c"
if anchor in text and "Task223\uff1a\u6876\u952e macos14 -> macos15" not in text:
    text = text.replace(anchor, anchor + nl + note + nl +
                        "          #   \u65e7\u6876\u5bf9\u8c61\u7f16\u8bd1\u5668\u6307\u7eb9\u4e0d\u5339\u914d\u53ea\u4f1a\u5168\u91cf miss\uff0c\u6362\u6876\u4fdd\u6301\u8bed\u4e49\u5e72\u51c0\uff09\u3002", 1)
    changed.append("ccache key comment note")

with open(WF, "wb") as f:
    f.write(text.encode("utf-8"))

print("OK, applied:", "; ".join(changed) if changed else "(nothing to do)")
