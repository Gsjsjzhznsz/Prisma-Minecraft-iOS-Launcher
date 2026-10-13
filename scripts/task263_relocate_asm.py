#!/usr/bin/env python3
"""Task 263 r2: relocate the embedded ASM package out of Fabric Loader's guard zone.

Forensics (latestlog.selfexit-1013-210534.txt, device v6.5.0 @ a84cfec-era build):
  Fabric Loader 0.19.5 LoaderUtil.verifyClasspath (Knot.<clinit>) refuses to start when
  org/objectweb/asm/ClassReader.class is reachable from the system classpath:
    IllegalStateException: duplicate ASM classes found on classpath: showdown_agent.jar (x2,
    via -javaagent AND libs/*.jar -cp) + minecraft/libraries/org/ow2/asm/asm/9.10.1
  The metallum_agent precedent (com/metallum/shaded/asm) already proves relocated ASM is
  invisible to this guard.

Method: EQUAL-LENGTH byte substitution over every class file -- `org/objectweb/asm` and
`org.objectweb.asm` are both 17 bytes; `com/prisma/shaded` and `com.prisma.shaded` are also
17 bytes. Raw byte replacement preserves the class-file structure byte-for-byte (Utf8
constant entries only carry raw strings; all structural references are CP indexes), so no
re-assembly risk whatsoever. Jar entry paths are renamed to match.
"""
import struct
import sys
import zipfile

SRC = sys.argv[1] if len(sys.argv) > 1 else 'JavaApp/libs/asm/asm-9.7.jar'
DST = sys.argv[2] if len(sys.argv) > 2 else 'JavaApp/libs/asm/asm-9.7-relocated.jar'

OLD_SLASH = b'org/objectweb/asm'
NEW_SLASH = b'com/prisma/shaded'
OLD_DOT = b'org.objectweb.asm'
NEW_DOT = b'com.prisma.shaded'
assert len(OLD_SLASH) == len(NEW_SLASH) == len(OLD_DOT) == len(NEW_DOT) == 17


def relocate(data):
    return data.replace(OLD_SLASH, NEW_SLASH).replace(OLD_DOT, NEW_DOT)


def main():
    zin = zipfile.ZipFile(SRC)
    entries = []
    touched = 0
    for info in zin.infolist():
        name = info.filename
        if name.startswith('META-INF/') or name == 'module-info.class':
            continue
        data = zin.read(name)
        if name.startswith('org/objectweb/asm/'):
            new_name = NEW_SLASH.decode() + name[len(OLD_SLASH):]
            new_data = relocate(data)
            if new_data != data:
                touched += 1
            entries.append((new_name, new_data))
    with zipfile.ZipFile(DST, 'w', zipfile.ZIP_DEFLATED) as zout:
        for name, data in entries:
            zout.writestr(name, data)
    print(f'relocated {touched}/{len(entries)} entries -> {DST}')

    # ---- self-verify ----
    bad = []
    with zipfile.ZipFile(DST) as z:
        for name in z.namelist():
            data = z.read(name)
            if OLD_SLASH in data or OLD_DOT in data:
                bad.append(name)
        assert 'com/prisma/shaded/ClassReader.class' in z.namelist(), 'ClassReader missing'
        assert 'org/objectweb/asm/ClassReader.class' not in z.namelist(), 'old path remains'
    assert not bad, f'leftover references: {bad[:5]}'
    # spot-check class header still valid
    with zipfile.ZipFile(DST) as z:
        d = z.read('com/prisma/shaded/ClassReader.class')
        assert d[:4] == b'\xca\xfe\xba\xbe'
        major = struct.unpack('>H', d[6:8])[0]
        assert major <= 52, f'major={major}'
    print(f'self-verify OK (zero leftover refs, ClassReader major={major})')


if __name__ == '__main__':
    main()
