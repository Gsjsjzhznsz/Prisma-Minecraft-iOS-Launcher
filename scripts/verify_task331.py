#!/usr/bin/env python3
"""Task331 verify: Radiance 会话 UseSerialGC 末端强制档 + 有效 argv 回显（JavaLauncher.m）"""
import re, sys

SRC = 'Natives/JavaLauncher.m'
src = open(SRC, encoding='utf-8').read()
checks, fails = [], []

def check(name, cond):
    checks.append((name, cond))
    if not cond:
        fails.append(name)

# 1. Task331 块存在
check('Task331 block present', 'Task331' in src)

# 2. 注入语句存在且为末端档（字面量推送）
check('serial push present', 'PUSH_MARGV_LITERAL("-XX:+UseSerialGC");' in src)

# 3. 尊重用户显式 +/- 逻辑
check('user explicit respect', 'UseSerialGC' in src and 'ame331_userExplicit' in src)

# 4. Radiance 会话检测（mods 目录 + 文件名含 radiance 不分大小写）
check('radiance detection', 'containsString:@"radiance"' in src and 'mods' in src)

# 5. 有效 argv 全量回显
check('argv echo', 'effective JVM argv' in src)

# 6. 顺序保证：Task331 块必须在 init_loadCustomJvmFlags 调用之后、dlsym(JLI_Launch) 之前
i_custom = src.find('init_loadCustomJvmFlags(&margc')
i_331 = src.find('★ Task331')
i_dlsym = src.find('pJLI_Launch = (JLI_Launch_func *)dlsym')
check('anchor positions found', i_custom > 0 and i_331 > 0 and i_dlsym > 0)
if i_custom > 0 and i_331 > 0 and i_dlsym > 0:
    check('order: after custom flags', i_custom < i_331)
    check('order: before dlsym', i_331 < i_dlsym)

# 7. push order 语义注释在位（后推者胜过 Task255 预设 G1）
check('override rationale', 'push order overrides Task255 preset G1' in src)

# 8. 无误伤：预设块原有的 Java8 SerialGC（memory 档）仍在
check('java8 preset intact', src.count('PUSH_MARGV_LITERAL("-XX:+UseSerialGC")') >= 2)

# 9. margv 越界防护沿用宏边界语义（块内循环 <= margc，无自增）
check('no bounds breakage', 'ame331_i <= margc' in src)

for name, ok in checks:
    print(('PASS' if ok else 'FAIL'), '-', name)
print()
print('verify_task331: %d/%d passed' % (sum(1 for _, ok in checks if ok), len(checks)))
sys.exit(0 if not fails else 1)
