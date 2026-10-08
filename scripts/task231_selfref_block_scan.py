#!/usr/bin/env python3
"""Task 231: 精确扫描真·自引用 block（递归 block 未加 __block = 未定义行为）。
用括号平衡圈定 block 字面量自身 body，仅在 body 内查 name( 调用，
排除后续其他 block/代码对同名变量的正常引用（粗扫的误报来源）。"""
import re, glob, sys

files = sorted(glob.glob('*.m') + glob.glob('*.mm'))
real_hits = []
for f in files:
    src = open(f, encoding='utf-8', errors='replace').read()
    for m in re.finditer(r'(\w*)\s*\(\^(\w+)\)\s*\([^)]*\)\s*=\s*\^\(?[^)]*\)?\s*\{', src):
        decl_kw, name = m.group(1), m.group(2)
        start_body = m.end() - 1  # 指向 '{'
        depth, i, in_str, in_chr, esc = 0, start_body, False, False, False
        end = None
        while i < len(src):
            c = src[i]
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif in_str:
                if c == '"':
                    in_str = False
            elif in_chr:
                if c == "'":
                    in_chr = False
            elif c == '"':
                in_str = True
            elif c == "'":
                in_chr = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        if end is None:
            continue
        body = src[start_body:end]
        refs = re.findall(r'(?<![\w.])' + re.escape(name) + r'\s*\(', body)
        if refs:
            line_no = src[:m.start()].count('\n') + 1
            # __block 判定：仅检查声明所在行内（行首到匹配点），避免上一行的
            # __block 变量声明污染（ame230_changed 误判教训）
            line_start = src.rfind('\n', 0, m.start()) + 1
            same_line_prefix = src[line_start:m.start()]
            real_hits.append((f, line_no, name, len(refs), '__block' in same_line_prefix))
for f, ln, name, cnt, hb in real_hits:
    print(f"{'OK ' if hb else '***'} {f}:{ln}  '{name}'  self-ref x{cnt}  {'__block' if hb else 'MISSING __block'}")
print(f"\ntotal real self-referencing blocks: {len(real_hits)}")
sys.exit(0)
