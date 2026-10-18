#!/usr/bin/env python3
# Task 297-ci: 修复 Makefile payload 目标中 Task295 注释行打断 shell 反斜杠续行链
# 根因: if [...]; then \ 的续行链被 3 行注释打断 -> bash -c 收到残缺 if 块
#       ("line 2: syntax error: unexpected end of file", run#916 Makefile:923 payload Error 2)
# 修法: 3 行注释整体上移到 if 行之前(单 TAB 缩进, 独立 recipe 注释行, 与 945-949 同款)
import io, sys

path = '/home/z/my-project/repo-prisma/Makefile'
src = open(path, encoding='utf-8').read()
lines = src.split('\n')

# 定位注释三连(Task295 appexpt 注释)与其后紧邻的 if 行
c_start = None
for i, l in enumerate(lines):
    if l.startswith('\t\t# \u2605 Task295\uff1a\u6cdb\u7528 ExtensionFoundation appex'):
        c_start = i
        break
if c_start is None:
    print('ANCHOR-NOT-FOUND'); sys.exit(1)

comment = lines[c_start:c_start+3]
for c in comment:
    if not c.lstrip().startswith('#'):
        print('COMMENT-BLOCK-NOT-CONTIGUOUS'); sys.exit(1)

if_line_idx = c_start + 3
if not lines[c_start - 1].startswith("\tif [ -f '$(JIT_STAGING)/PrismaJITHelper' ]"):
    print('IF-LINE-MISMATCH:', repr(lines[c_start - 1][:60])); sys.exit(1)

# 摘出注释三连, 改单 TAB 缩进(与 945-949 独立注释行同款), 插到 if 行之前
moved = ['\t' + c.lstrip('\t') for c in comment]
del lines[c_start:c_start+3]
if_idx = c_start - 1  # 删除后 if 行落位原 c_start-1
lines[if_idx:if_idx] = moved

out = '\n'.join(lines)
open(path, 'w', encoding='utf-8', newline='').write(out)
print('OK moved', len(moved), 'comment lines before if-line; file lines:', len(lines))
