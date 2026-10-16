#!/usr/bin/env python3
"""verify_task263: Cobblemon showdown 路径绝对化修复的不变量校验。

覆盖面：
  A. agent 源码锚点（门控类名 / 4 个改写值 / 绝对拼接字节码序列 / premain 取证行）
  B. ASM 内嵌件存在性 + class 版本（major<=52，全会话可加载）
  C. JavaApp/Makefile 打包规则（asm 解嵌 + module-info 剔除 + jar -cfm）
  D. 根 Makefile 拷贝行 + TAB 保形（654 前导 TAB）+ 无空格缩进回归
  E. JavaLauncher.m 挂载点（-javaagent + -Dame.showdown.home + 双日志锚）
  F. manifest Premain-Class
  G. Tools.java 相位2 驻停即落栈探针（post-window-parked / parkedDumped / state 变量）
  H. 本地字节级重放：按 agent 源码重编译不可行（无 javac）时退化为源码锚点计数。
"""
import struct
import sys
import zipfile

REPO = __file__.rsplit('/scripts/', 1)[0]

failures = []
passed = 0


def check(name, cond, detail=''):
    global passed
    if cond:
        passed += 1
        print(f'  PASS  {name}')
    else:
        failures.append(name)
        print(f'  FAIL  {name} {detail}')


# ---------- A. agent 源码 ----------
agent_path = f'{REPO}/JavaApp/src/showdown_agent/com/prisma/showdown/ShowdownAgent.java'
src = open(agent_path, encoding='utf-8').read()

check('A1 agent 源码存在', len(src) > 3000)
check('A2 门控类名（Service+Unbundler）',
      'GraalShowdownService' in src and 'GraalShowdownUnbundler' in src)
for v in ['"showdown"', '"./showdown"', '"showdown/index.js"', '"showdown-backup"']:
    check(f'A3 改写值锚 {v}', v in src)
check('A4 绝对拼接序列（getProperty+concat）',
      'getProperty' in src and '"concat"' in src and 'INVOKEVIRTUAL' in src)
check('A5 HOME_PROPERTY', '"ame.showdown.home"' in src)
check('A6 COMPUTE_MAXS（无 Frames 重算）',
      'COMPUTE_MAXS' in src and 'COMPUTE_FRAMES' not in src)
check('A7 premain 取证行', 'showdown-agent armed' in src)
check('A10 import 重定位包（无 org.objectweb）',
      'import com.prisma.shaded.ClassReader' in src and 'org.objectweb' not in src)
check('A8 无分支插入（visitLdcInsn 直改）', 'visitLdcInsn(Object cst)' in src)
check('A9 改写值白名单函数', 'suffixFor' in src)
check('A11 D1 狱中和（$createContext$1 门控 + checkAccess 置空）',
      'GraalShowdownService$createContext$1' in src and 'checkAccess' in src
      and 'jail neutralized' in src)
check('A12 D2 双层供件（jar 资源 + showdown.zip 提取）',
      'data/cobblemon/showdown.zip' in src and 'data/cobblemon/showdown.json' in src
      and 'provisionFromModJar' in src)
check('A13 D3 latch 看门狗（线程名 + 强制放行日志）',
      'Ame263-ShowdownWatchdog' in src and 'force-released' in src)
check('A14 IO 层探针（java.io vs NIO 对照行）',
      'io-probe[' in src and 'safeRealPath' in src)
check('A15 D1 新方法体无帧安全（RETURN 直发 + visitMaxs）',
      'rmv.visitInsn(Opcodes.RETURN)' in src and 'rmv.visitMaxs(0, 4)' in src)
check('A16 看门狗快路径（线程死亡即放行，不等到超时）',
      'showdown thread died uncaught' in src and 'seenAlive' in src)

# ---------- B. ASM 内嵌件（r2：等长重定位，避开 Fabric Loader verifyClasspath 守卫）----------
asm_path = f'{REPO}/JavaApp/libs/asm/asm-9.7-relocated.jar'
try:
    z = zipfile.ZipFile(asm_path)
    names = z.namelist()
    d = z.read('com/prisma/shaded/ClassReader.class')
    major = struct.unpack('>H', d[6:8])[0]
    check('B1 asm-9.7-relocated.jar 存在且含 com/prisma/shaded/ClassReader', True)
    check('B2 asm class major<=52（全会话可加载）', major <= 52, f'major={major}')
    leftover = [n for n in names if 'org/objectweb' in n] + [
        n for n in names if b'org/objectweb' in z.read(n) or b'org.objectweb' in z.read(n)]
    check('B3 零 org/objectweb 残留（Fabric verifyClasspath 守卫区）', len(leftover) == 0,
          str(leftover[:3]))
    files = [n for n in names if not n.endswith('/')]
    check('B4 类条目完整（38 类文件 + 2 目录条目）', len(files) == 38 and len(names) == 40, f'files={len(files)} entries={len(names)}')
except Exception as e:
    check('B1 asm-9.7-relocated.jar 存在且含 com/prisma/shaded/ClassReader', False, str(e))
    check('B2 asm class major<=52（全会话可加载）', False)
    check('B3 零 org/objectweb 残留（Fabric verifyClasspath 守卫区）', False)
    check('B4 包条目重命名完整（40 项）', False)

# ---------- C. JavaApp/Makefile ----------
jam = open(f'{REPO}/JavaApp/Makefile', encoding='utf-8').read()
check('C1 showdown_agent.jar 规则存在', 'showdown_agent.jar: $(CLASSES)' in jam)
check('C2 manifest 引用 showdown_agent.txt', 'src/showdown_agent.txt' in jam)
check('C3 asm 解嵌（重定位件）', 'asm_embed' in jam and 'libs/asm/asm-9.7-relocated.jar' in jam)
check('C4 module-info/META-INF 剔除', 'module-info.class' in jam and 'META-INF' in jam)
check('C5 ClassReader 存在断言（重定位路径）', 'com/prisma/shaded/ClassReader.class' in jam and 'org/objectweb/asm/ClassReader.class' not in jam)
jam_lines = jam.split('\n')
rule_idx = next(i for i, l in enumerate(jam_lines) if 'showdown_agent.jar: $(CLASSES)' in l)
_end = next(i for i, l in enumerate(jam_lines)
            if i > rule_idx and 'Created $(OUTPUTDIR)/showdown_agent.jar' in l)
rule_block = jam_lines[rule_idx:_end + 1]
check('C6 规则行全 TAB 缩进（目标行除外）', all(
    (not l) or l.startswith('\t') or l.startswith('#') or not l.strip() or l.startswith('$(OUTPUTDIR)/showdown_agent.jar:')
    for l in rule_block), str([l for l in rule_block if l.strip() and not l.startswith('\t') and not l.startswith('#') and not l.startswith('$(OUTPUTDIR)/showdown_agent.jar:')][:2]))

# ---------- D. 根 Makefile ----------
root = open(f'{REPO}/Makefile', encoding='utf-8').read()
check('D1 拷贝行含 showdown_agent.jar',
      'JavaApp/build/showdown_agent.jar $(WORKINGDIR)/AngelAuraAmethyst.app/libs/' in root)
tabs = sum(1 for l in root.split('\n') if l.startswith('\t'))
check('D2 前导 TAB 保形（654）', tabs == 654, f'tabs={tabs}')
bad_indent = [l for l in root.split('\n') if l.startswith('    ') and not l.startswith('\t')]
check('D3 无空格缩进回归', len(bad_indent) == 0)

# ---------- E. JavaLauncher.m ----------
jl = open(f'{REPO}/Natives/JavaLauncher.m', encoding='utf-8').read()
check('E1 -javaagent 挂载', '-javaagent:%@/showdown_agent.jar' in jl)
check('E2 -Dame.showdown.home 传递', '-Dame.showdown.home=%@' in jl)
check('E3 enabled 日志锚', '[JavaLauncher] Task263: showdown agent enabled' in jl)
check('E4 missing 日志锚', 'showdown_agent.jar not found in libs' in jl)
check('E5 与 gameDir 同源（PUSH 行存在且引用 gameDir）',
      'PUSH_MARGV_FORMAT(@"-Dame.showdown.home=%@", gameDir)' in jl)

# ---------- F. manifest ----------
mf = open(f'{REPO}/JavaApp/src/showdown_agent.txt', encoding='utf-8').read()
check('F1 Premain-Class', 'Premain-Class: com.prisma.showdown.ShowdownAgent' in mf)

# ---------- G. Tools.java ----------
tools = open(f'{REPO}/JavaApp/src/launcher/net/kdt/pojavlaunch/Tools.java', encoding='utf-8').read()
check('G1 post-window-parked 探针', '"post-window-parked"' in tools)
check('G2 parkedDumped 一次性', 'parkedDumped' in tools)
check('G3 state 变量抽取（TERMINATED 判定同源）',
      'Thread.State state = gameThread.getState();' in tools)
check('G4 三态判定', 'Thread.State.WAITING' in tools and 'Thread.State.BLOCKED' in tools
      and 'Thread.State.TIMED_WAITING' in tools)
check('G5 javadoc Task263 语义', 'post-window-parked' in tools and 'Task263' in tools)

print()
print(f'verify_task263: {passed} passed, {len(failures)} failed')
if failures:
    print('FAILED:', failures)
    sys.exit(1)
print('ALL GREEN')
