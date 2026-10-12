#!/usr/bin/env python3
"""Minimal JVM class-file disassembler for lwjgl GL$1 Delegate analysis.
Parses constant pool + methods with bytecode mnemonics (subset) + refs.
Usage: python3 scripts/disasm_gl1.py <jar> <entry>
"""
import sys, zipfile, struct

OPCODES = {
    0x00: ("nop", 0), 0x01: ("aconst_null", 0), 0x02: ("iconst_m1", 0),
    0x03: ("iconst_0", 0), 0x04: ("iconst_1", 0), 0x05: ("iconst_2", 0),
    0x06: ("iconst_3", 0), 0x07: ("iconst_4", 0), 0x08: ("iconst_5", 0),
    0x10: ("bipush", 1), 0x11: ("sipush", 2), 0x12: ("ldc", 1),
    0x13: ("ldc_w", 2), 0x14: ("ldc2_w", 2),
    0x15: ("iload", 1), 0x19: ("aload", 1), 0x1a: ("iload_0", 0), 0x1b: ("iload_1", 0),
    0x1c: ("iload_2", 0), 0x1d: ("iload_3", 0), 0x2a: ("aload_0", 0), 0x2b: ("aload_1", 0),
    0x2c: ("aload_2", 0), 0x2d: ("aload_3", 0),
    0x32: ("aload", 2), 0x21: ("lload_1", 0), 0x22: ("lload_2", 0),
    0x3a: ("astore", 1), 0x4b: ("astore_0", 0), 0x4c: ("astore_1", 0), 0x4d: ("astore_2", 0),
    0x57: ("astore_3", 0), 0x3b: ("istore_0", 0), 0x3c: ("istore_1", 0), 0x3d: ("istore_2", 0),
    0x50: ("lstore_1", 0), 0x51: ("lstore_2", 0),
    0xb0: ("areturn", 0), 0xac: ("ireturn", 0), 0xad: ("lreturn", 0), 0xb1: ("return", 0),
    0xb2: ("getstatic", 2), 0xb3: ("putstatic", 2), 0xb4: ("getfield", 2), 0xb5: ("putfield", 2),
    0xb6: ("invokevirtual", 2), 0xb7: ("invokespecial", 2), 0xb8: ("invokestatic", 2),
    0xb9: ("invokeinterface", 4), 0xba: ("invokedynamic", 4),
    0xbb: ("new", 2), 0xbc: ("newarray", 1), 0xbd: ("anewarray", 2),
    0xc0: ("checkcast", 2), 0xc1: ("instanceof", 2),
    0xa7: ("goto", 2), 0xa5: ("if_acmpeq", 2), 0xa6: ("if_acmpne", 2),
    0x9f: ("if_icmpeq", 2), 0xa0: ("if_icmpne", 2), 0xa1: ("if_icmplt", 2),
    0xa2: ("if_icmpge", 2), 0xa3: ("if_icmpgt", 2), 0xa4: ("if_icmple", 2),
    0x99: ("ifeq", 2), 0x9a: ("ifne", 2), 0x9b: ("iflt", 2), 0x9c: ("ifge", 2),
    0x9d: ("ifgt", 2), 0x9e: ("ifle", 2), 0xc6: ("ifnull", 2), 0xc7: ("ifnonnull", 2),
    0x00: ("nop", 0),
    0x60: ("ladd", 0), 0x61: ("lsub", 0), 0x64: ("lsub", 0), 0x84: ("iinc", 2),
    0x6a: ("lmul", 0), 0x69: ("lmul", 0), 0x7a: ("l2i", 0), 0x85: ("l2i", 0),
    0x8b: ("l2d", 0), 0x88: ("l2f", 0), 0x8f: ("d2l", 0),
    0x57+0: ("astore_3", 0),
    0xc7: ("ifnonnull", 2),
    0xbf: ("athrow", 0), 0x59: ("lcmp", 0), 0x80: ("lcmp", 0),
    0x00: ("nop", 0),
    0xbe: ("arraylength", 0), 0x53: ("aaload", 0), 0x2e: ("iaload", 0), 0x2f: ("laload", 0),
    0x4f: ("aastore", 0), 0x48: ("lstore_0", 0),
}

class R:
    def __init__(s, d): s.d, s.p = d, 0
    def u1(s): v = s.d[s.p]; s.p += 1; return v
    def u2(s): v = struct.unpack(">H", s.d[s.p:s.p+2])[0]; s.p += 2; return v
    def u4(s): v = struct.unpack(">I", s.d[s.p:s.p+4])[0]; s.p += 4; return v
    def read(s, n): v = s.d[s.p:s.p+n]; s.p += n; return v

def parse_class(data):
    r = R(data)
    assert r.u4() == 0xCAFEBABE, "not a class file"
    r.u2(); r.u2()
    n = r.u2()
    cp = [None] * n
    i = 1
    while i < n:
        tag = r.u1()
        if tag == 1:
            ln = r.u2(); cp[i] = ("Utf8", r.read(ln).decode("utf-8", "replace"))
        elif tag == 3: cp[i] = ("Int", struct.unpack(">i", r.read(4))[0])
        elif tag == 4: cp[i] = ("Float", struct.unpack(">f", r.read(4))[0])
        elif tag == 5: cp[i] = ("Long", 0); r.read(8); i += 1
        elif tag == 6: cp[i] = ("Double", 0); r.read(8); i += 1
        elif tag == 7: cp[i] = ("Class", r.u2())
        elif tag == 8: cp[i] = ("String", r.u2())
        elif tag == 9: cp[i] = ("Fieldref", r.u2(), r.u2())
        elif tag == 10: cp[i] = ("Methodref", r.u2(), r.u2())
        elif tag == 11: cp[i] = ("InterfaceMethodref", r.u2(), r.u2())
        elif tag == 12: cp[i] = ("NameAndType", r.u2(), r.u2())
        elif tag == 15: cp[i] = ("MethodHandle", r.u1(), r.u2())
        elif tag == 16: cp[i] = ("MethodType", r.u2())
        elif tag == 17: cp[i] = ("Dyn", r.u2(), r.u2())
        elif tag == 18: cp[i] = ("InvokeDynamic", r.u2(), r.u2())
        elif tag == 19: cp[i] = ("Module", r.u2())
        elif tag == 20: cp[i] = ("Package", r.u2())
        else: raise ValueError(f"cp tag {tag} @ {i}")
        i += 1
    def utf8(idx): return cp[idx][1] if cp[idx] and cp[idx][0] == "Utf8" else f"#{idx}"
    def desc(idx):
        e = cp[idx]
        if e is None: return f"#{idx}"
        if e[0] == "Class": return utf8(e[1])
        if e[0] in ("Methodref", "Fieldref", "InterfaceMethodref"):
            cls = desc(e[1]); nat = cp[e[2]]
            if nat and nat[0] == "NameAndType":
                return f"{cls}.{utf8(nat[1])}:{utf8(nat[2])}"
            return f"{cls}.#{e[2]}"
        if e[0] == "String": return f'"{utf8(e[1])}"'
        if e[0] == "NameAndType": return f"{utf8(e[1])}:{utf8(e[2])}"
        return f"{e[0]}:{e[1:]}"
    return r, cp, desc

def disasm(data, name):
    r, cp, desc = parse_class(data)
    print(f"===== {name} constant pool ({len(cp)-1}) =====")
    for idx, e in enumerate(cp):
        if e and e[0] in ("Utf8", "Methodref", "Fieldref", "InterfaceMethodref", "Class", "String", "NameAndType"):
            print(f"  #{idx} {desc(idx)}")
    r.u2(); r.u2(); superc = r.u2(); print("super:", desc(superc))
    nif = r.u2()
    for _ in range(nif): r.u2()
    nf = r.u2()
    print("----- fields -----")
    for _ in range(nf):
        r.u2(); fname = r.u2(); r.u2(); print("  field:", desc(fname))  # access, name, desc; attrcount 由 disasm_attrs 读
        disasm_attrs(r, cp, desc, indent="    ")
    nm = r.u2()
    print("----- methods -----")
    for _ in range(nm):
        r.u2(); r.u2(); mname = r.u2(); mdesc = r.u2()
        print(f"  method: {desc(mname)}  sig={desc(mdesc)}")
        disasm_attrs(r, cp, desc, indent="    ")

def disasm_attrs(r, cp, desc, indent="    "):
    na = r.u2()
    for _ in range(na):
        aname = r.u2(); alen = r.u4()
        start = r.p
        if desc(aname) == "Code":
            r.u2(); r.u2()
            clen = r.u4()
            code = r.read(clen)
            nexc = r.u2()  # exception_table_length
            for _ in range(nexc): r.read(8)  # start/end/handler/catch_type 各 u2
            nia = r.u2()  # code 内层 attributes_count
            for _ in range(nia):
                r.u2(); ialen = r.u4(); r.read(ialen)  # LineNumberTable/StackMapTable 跳过
            print(f"{indent}Code ({clen} bytes):")
            p = 0
            while p < len(code):
                op = code[p]
                mn, argn = OPCODES.get(op, (f"op_{op:02x}", None))
                if argn is None:
                    print(f"{indent}  {p:4d}: {mn} <unparsed width>; aborting rest")
                    break
                args = code[p+1:p+1+argn]
                extra = ""
                if argn == 2 and mn in ("invokevirtual","invokespecial","invokestatic","invokeinterface","getstatic","putstatic","getfield","putfield","checkcast","instanceof","anewarray","new"):
                    idx = struct.unpack(">H", args)[0]
                    extra = f"  // {desc(idx)}"
                elif mn == "ldc":
                    idx = args[0]
                    extra = f"  // {desc(idx)}"
                elif argn == 2 and mn in ("goto","ifeq","ifne","iflt","ifge","ifgt","ifle","ifnull","ifnonnull","if_icmpeq","if_icmpne","if_acmpeq","if_acmpne"):
                    off = struct.unpack(">h", args)[0]
                    extra = f"  -> {p+off}"
                elif mn == "iinc":
                    extra = f"  {args[0]} += {struct.unpack('>b', args[1:2])[0]}"
                print(f"{indent}  {p:4d}: {mn} {args.hex() if args else ''}{extra}")
                p += 1 + argn
        else:
            r.read(alen)

if __name__ == "__main__":
    jar, entry = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(jar) as z:
        data = z.read(entry)
    disasm(data, entry)
