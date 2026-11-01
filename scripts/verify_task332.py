#!/usr/bin/env python3
"""Task332 verify: libMoltenVK.dylib javamc-rt 替换 + Task 331 撤销干净度"""
import hashlib, os, struct, sys

DYLIB = 'Natives/resources/Frameworks/libMoltenVK.dylib'
EXPECT_SHA256 = '6b45b4b2ffd40e3438daf4bea0331ca35f5bb12b98b6861af34d8b2b52bfe747'
EXPECT_SIZE = 5238912

checks, fails = [], []
def check(name, cond):
    checks.append((name, cond))
    if not cond:
        fails.append(name)

# 1. dylib 存在 + 大小 + SHA256 钉死（release javamc-rt 根资产逐字节）
data = open(DYLIB, 'rb').read()
check('dylib exists', len(data) > 0)
check('dylib size == %d' % EXPECT_SIZE, len(data) == EXPECT_SIZE)
check('dylib sha256 pinned (javamc-rt)', hashlib.sha256(data).hexdigest() == EXPECT_SHA256)

# 2. Mach-O 四锚：64 位 LE / arm64 / MH_DYLIB / install name / iOS minos 15
magic = struct.unpack_from('<I', data, 0)[0]
cputype, cpusubtype, filetype, ncmds = struct.unpack_from('<iiII', data, 4)
check('Mach-O 64 LE magic', magic == 0xfeedfacf)
check('arm64 cputype', cputype == 0x0100000C)
check('MH_DYLIB filetype', filetype == 6)
off, install, platform, minos = 32, None, None, None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', data, off)
    if cmd == 0x32:  # LC_BUILD_VERSION
        platform, minos, sdk, _ = struct.unpack_from('<IIII', data, off + 8)
    elif cmd == 0xD:  # LC_ID_DYLIB
        nameoff = struct.unpack_from('<I', data, off + 8)[0]
        end = data.index(b'\x00', off + nameoff)
        install = data[off + nameoff:end].decode()
    off += cmdsize
check('install name unchanged (@rpath/MoltenVK.framework/MoltenVK)', install == '@rpath/MoltenVK.framework/MoltenVK')
check('platform iOS(2)', platform == 2)
check('minos 15.0 (loader floor unchanged)', minos == (15 << 16))

# 3. RT 符号族（导出符号名实锚）
syms = [b'vkCreateRayTracingPipelinesKHR', b'vkCmdTraceRaysKHR', b'vkCmdTraceRaysIndirectKHR',
        b'vkBuildAccelerationStructuresKHR', b'vkCmdBuildAccelerationStructuresKHR',
        b'vkCreateAccelerationStructureKHR', b'vkGetRayTracingShaderGroupHandlesKHR']
check('RT symbol family (7) present', all(s in data for s in syms))

# 4. vk_bridge 依赖的 MVK 配置 API 仍导出 + 版本串不变
check('vkGetMoltenVKConfigurationMVK exported', b'vkGetMoltenVKConfigurationMVK' in data)
check('vkSetMoltenVKConfigurationMVK exported', b'vkSetMoltenVKConfigurationMVK' in data)
check('version string 1.4.3 (MVKConfigurationLocal layout stable)', b'1.4.3' in data)

# 5. Task 331 撤销残留三查
jl = open('Natives/JavaLauncher.m', encoding='utf-8').read()
check('JavaLauncher Task331/radiance block gone', 'Task331' not in jl and 'radiance' not in jl.lower())
check('UseSerialGC pushes back to 1 (Java8 memory preset only)', jl.count('PUSH_MARGV_LITERAL("-XX:+UseSerialGC")') == 1)
check('verify_task331.py removed', not os.path.exists('scripts/verify_task331.py'))

# 6. Task 332 面：worklog 条目 + vk_bridge 出处注记
wl = open('worklog.md', encoding='utf-8').read()
check('worklog Task331 entry removed', '## Task 331——' not in wl)
check('worklog Task332 entry present', '## Task 332——' in wl)
vk = open('Natives/ctxbridges/vk_bridge.m', encoding='utf-8').read()
check('vk_bridge Task332 provenance note', 'Task332' in vk and 'javamc-rt' in vk)

for name, ok in checks:
    print(('PASS' if ok else 'FAIL'), '-', name)
print()
print('verify_task332: %d/%d passed' % (sum(1 for _, ok in checks if ok), len(checks)))
sys.exit(0 if not fails else 1)
