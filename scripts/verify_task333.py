#!/usr/bin/env python3
"""Task333 verify: telemetry dylib swap + revert-state integrity."""
import hashlib, os, struct, sys

DYLIB = 'Natives/resources/Frameworks/libMoltenVK.dylib'
SHA = 'cdb86c4d613f6b1eae2de1761a65fa628ef4de306feeea5dc9d363e32b8f5c4a'
SIZE = 5255472

checks, fails = [], []
def check(name, cond):
    checks.append((name, cond))
    if not cond:
        fails.append(name)

data = open(DYLIB, 'rb').read()
check('dylib size == %d (telemetry build)' % SIZE, len(data) == SIZE)
check('dylib sha256 pinned (javamc-rt telemetry)', hashlib.sha256(data).hexdigest() == SHA)

magic = struct.unpack_from('<I', data, 0)[0]
cputype, _, filetype, ncmds = struct.unpack_from('<iiII', data, 4)
check('Mach-O 64 LE', magic == 0xfeedfacf)
check('arm64', cputype == 0x0100000C)
check('MH_DYLIB', filetype == 6)
off, install, platform, minos = 32, None, None, None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', data, off)
    if cmd == 0x32:
        platform, minos, _, _ = struct.unpack_from('<IIII', data, off + 8)
    elif cmd == 0xD:
        nameoff = struct.unpack_from('<I', data, off + 8)[0]
        end = data.index(b'\x00', off + nameoff)
        install = data[off + nameoff:end].decode()
    off += cmdsize
check('install name unchanged', install == '@rpath/MoltenVK.framework/MoltenVK')
check('platform iOS', platform == 2)
check('minos 15.0', minos == (15 << 16))

# telemetry evidence (19 format strings expected; spot-check all 9 tags)
tags = [b'[MVK-RT][CAPS]', b'[MVK-RT][DEVICE]', b'[MVK-RT][API]', b'[MVK-RT][AS-CREATE]',
        b'[MVK-RT][AS-BUILD]', b'[MVK-RT][AS-COPY]', b'[MVK-RT][AS-DESTROY]',
        b'[MVK-RT][PIPELINE]', b'[MVK-RT][TRACE]', b'[MVK-RT][PERF]']
check('telemetry tags x10 in binary', all(t in data for t in tags))
check('telemetry config member string', b'MVK_CONFIG_RAY_TRACING_LOGGING' in data)
check('telemetry count = 19 [MVK-RT] strings', data.count(b'[MVK-RT]') >= 19)

# vk_bridge compatibility + RT family
check('vkGetMoltenVKConfigurationMVK exported', b'vkGetMoltenVKConfigurationMVK' in data)
check('vkSetMoltenVKConfigurationMVK exported', b'vkSetMoltenVKConfigurationMVK' in data)
syms = [b'vkCreateRayTracingPipelinesKHR', b'vkCmdTraceRaysKHR', b'vkCmdTraceRaysIndirectKHR',
        b'vkBuildAccelerationStructuresKHR', b'vkCmdBuildAccelerationStructuresKHR',
        b'vkCreateAccelerationStructureKHR', b'vkGetRayTracingShaderGroupHandlesKHR']
check('RT symbol family (7)', all(s in data for s in syms))
check('version 1.4.3', b'1.4.3' in data)

# revert-state integrity
jl = open('Natives/JavaLauncher.m', encoding='utf-8').read()
check('Task331 revert state intact (no radiance block)', 'Task331' not in jl and 'radiance' not in jl.lower())

# Task333 surfaces
vk = open('Natives/ctxbridges/vk_bridge.m', encoding='utf-8').read()
check('vk_bridge Task333 provenance note', 'Task333' in vk and 'cdb86c4d' in vk and 'b41b09b' in vk)
wl = open('worklog.md', encoding='utf-8').read()
check('worklog Task333 entry', '## Task 333——' in wl)
check('worklog Task332 entry still present', '## Task 332——' in wl)

# historical gate untouched (verify_task332.py still pins the OLD dylib -> revertable semantics)
v332 = open('scripts/verify_task332.py', encoding='utf-8').read()
check('verify_task332.py untouched (pins 6b45b4b2, historical gate)',
      '6b45b4b2ffd40e3438daf4bea0331ca35f5bb12b98b6861af34d8b2b52bfe747' in v332 and '5238912' in v332)

for name, ok in checks:
    print(('PASS' if ok else 'FAIL'), '-', name)
print()
print('verify_task333: %d/%d passed' % (sum(1 for _, ok in checks if ok), len(checks)))
sys.exit(0 if not fails else 1)
