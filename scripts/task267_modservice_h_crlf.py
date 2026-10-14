#!/usr/bin/env python3
# Task267：ModService.h 为 CRLF 文件——字节级插入保形（Task257 K4 教训：
# Edit 工具 LF 行混入 CRLF 文件会编辑失败或破坏行尾一致性）。
import sys

PATH = "Natives/ModService.h"

ANCHOR = "- (nullable NSString *)ame264_effectiveModsFolderForProfile:(NSString *)profileName;"

BLOCK = [
    "",
    "/// Task267（模组管理\u201c下载了但列表不显示\u201d终局修复\u2014\u2014下载先于开页场景）：",
    "/// 记录最近一次成功落盘的 mod 下载目标（profile/文件/时间戳）。",
    "/// handlePLDownloadCompletion 成功路径调用；模组管理页 viewWillAppear 时与本页",
    "/// 生效实例对账\u2014\u2014页面在下载完成之后才打开（Task266 横幅的实时通知够不着）",
    "/// 也能自解释\u201c文件去了哪个实例\u201d。",
    "+ (void)ame267_noteLastModDownloadToProfile:(nullable NSString *)profileName",
    "                                       file:(nullable NSString *)fileName;",
    "",
    "/// Task267：读取最近一次 mod 下载落点记录。",
    "/// 返回 @{ @\"profile\": NSString, @\"file\": NSString, @\"ts\": NSNumber(double) }\uff1b",
    "/// 从未成功落盘过 mod 时返回 nil\u3002",
    "+ (nullable NSDictionary<NSString *, id> *)ame267_lastModDownload;",
]

def main():
    with open(PATH, "rb") as f:
        data = f.read().decode("utf-8")
    if "ame267_noteLastModDownloadToProfile" in data:
        print("SKIP: already injected")
        return
    lines = data.split("\r\n")
    idx = None
    for i, ln in enumerate(lines):
        if ln.strip() == ANCHOR:
            idx = i
            break
    if idx is None:
        print("ERROR: anchor not found", file=sys.stderr)
        sys.exit(1)
    # 对齐 anchor 前导缩进（此处顶格）
    new_lines = lines[:idx + 1] + BLOCK + lines[idx + 1:]
    with open(PATH, "wb") as f:
        f.write("\r\n".join(new_lines).encode("utf-8"))
    print(f"OK: inserted {len(BLOCK)} lines after anchor line {idx + 1}")

if __name__ == "__main__":
    main()
