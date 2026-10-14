#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task269.py —— Task269「一实例一文件夹」迁移算法离线复演验证锚（r2 含 mods 身份键）
对 Natives/ModpackImportService.m 的 ame269 迁移实现做规格级复演：
  1) 规范名聚类（剥 " (N)" 序号后缀，仅 custom_gamedir 实例参与）
  2) canonical 选取（无后缀原名优先，其次 created 最早）
  3) 合并规则：目标缺失→move / 同名同尺寸→dedupe / 同名不同尺寸→stash 备份
  4) r2: mods/ 内 mod 身份键冲突（sodium-0.6.0 vs 0.6.1）→ stash，绝不同存双版本
  5) 剪空目录→删重复文件夹→删重复 profile→选中被合并则切 canonical
全部断言通过输出最终 PASS 行，任一失败 exit 1。
"""
import os, re, shutil, sys, tempfile

SUFFIX_RE = re.compile(r"\s*[（(]\d{1,2}[)）]\s*$")
VER_SEG = re.compile(r"^(v|V)?\d+(\.\d+)*$")

def norm(name):
    return SUFFIX_RE.sub("", name)

def mod_identity_key(fname):
    base = fname
    low = fname.lower()
    if low.endswith(".jar.disabled"):
        base = base[:-13]
    elif low.endswith(".jar"):
        base = base[:-4]
    segs = [s for s in re.split(r"[-_.+]", base)]
    while len(segs) > 1 and VER_SEG.match(segs[-1]):
        segs.pop()
    return "_".join(segs).lower()

def inst_id_from_gamedir(gd):
    if not gd or "custom_gamedir/" not in gd:
        return None
    tail = gd[gd.rindex("custom_gamedir/") + len("custom_gamedir/"):]
    if not tail or tail == "." or "/" in tail:
        return None
    return tail

def collect(root):
    files, dirs = [], []
    for dp, dns, fns in os.walk(root):
        rel = os.path.relpath(dp, root)
        for d in dns:
            dirs.append(os.path.normpath(os.path.join(rel, d)) if rel != "." else d)
        for f in fns:
            files.append(os.path.normpath(os.path.join(rel, f)) if rel != "." else f)
    return files, dirs

def merge(src, dst, backup, stat):
    sf, _ = collect(src)
    canon_mods = os.path.join(dst, "mods")
    mod_keys = {mod_identity_key(f) for f in (os.listdir(canon_mods) if os.path.isdir(canon_mods) else [])}
    for rel in sf:
        s, d = os.path.join(src, rel), os.path.join(dst, rel)
        low, name = rel.lower(), os.path.basename(rel)
        in_mods = rel.startswith("mods/") and (low.endswith(".jar") or low.endswith(".jar.disabled"))
        if not os.path.exists(d):
            if in_mods:
                key = mod_identity_key(name)
                if key in mod_keys:
                    b = os.path.join(backup, rel)
                    os.makedirs(os.path.dirname(b), exist_ok=True)
                    shutil.move(s, b); stat["stashed"] += 1
                    continue
                mod_keys.add(key)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.move(s, d); stat["moved"] += 1
        elif os.path.getsize(s) == os.path.getsize(d):
            os.remove(s); stat["deduped"] += 1
        else:
            b = os.path.join(backup, rel)
            os.makedirs(os.path.dirname(b), exist_ok=True)
            shutil.move(s, b); stat["stashed"] += 1

def prune(root):
    _, dirs = collect(root)
    for rel in sorted(dirs, key=lambda x: (-len(x), x)):
        try: os.rmdir(os.path.join(root, rel))
        except OSError: pass

def migrate(game_dir, profiles):
    custom = os.path.join(game_dir, "custom_gamedir")
    clusters = {}
    for key, prof in profiles.items():
        gd = prof.get("gameDir", "")
        if "custom_gamedir/" not in gd:
            continue
        clusters.setdefault(norm(key), []).append(key)
    plans = []
    for base, members in clusters.items():
        if len(members) < 2:
            continue
        members = sorted(members, key=lambda k: (norm(k) != k, profiles[k].get("created", ""), k))
        canon = members[0]
        canon_id = inst_id_from_gamedir(profiles[canon]["gameDir"])
        assert canon_id, "canonical id must resolve"
        canon_dir = os.path.join(custom, canon_id)
        backup_root = os.path.join(custom, ".ame269_backup", "ts")
        merged = []
        for dup in members[1:]:
            dup_id = inst_id_from_gamedir(profiles[dup]["gameDir"])
            if not dup_id or dup_id == canon_id:
                continue
            dup_dir = os.path.join(custom, dup_id)
            if not os.path.isdir(dup_dir):
                merged.append(dup); continue
            stat = {"moved": 0, "deduped": 0, "stashed": 0}
            merge(dup_dir, canon_dir, os.path.join(backup_root, dup_id), stat)
            prune(dup_dir)
            try:
                os.rmdir(dup_dir); merged.append(dup)
            except OSError:
                print(f"  [warn] folder {dup_id} not fully merged")
        if merged:
            plans.append({"canonical": canon, "merged": merged})
    for plan in plans:
        for dead in plan["merged"]:
            profiles.pop(dead, None)
    return profiles, plans

def build_case(root):
    """复刻用户装机实况：FO=原名(47 jar) + FO (2)=重下实例(JEI 独有+sodium 新版本)"""
    ca = os.path.join(root, "custom_gamedir", "modrinth_CA336076-FF45-4B33-88A7-F746B2E23B33")
    bb = os.path.join(root, "custom_gamedir", "modrinth_BB10129F-2272-4B3F-968A-FFF753C58CB2")
    os.makedirs(os.path.join(ca, "mods"), exist_ok=True)
    os.makedirs(os.path.join(ca, "saves", "world1"), exist_ok=True)
    os.makedirs(os.path.join(bb, "mods"), exist_ok=True)
    os.makedirs(os.path.join(bb, "screenshots"), exist_ok=True)
    for i in range(47):
        with open(os.path.join(ca, "mods", f"pack_{i:02d}.jar"), "wb") as f:
            f.write(b"X" * (100 + i))
    with open(os.path.join(ca, "mods", "sodium-fabric-0.6.0.jar"), "wb") as f:
        f.write(b"OLD-VERSION" * 10)
    with open(os.path.join(ca, "saves", "world1", "level.dat"), "wb") as f:
        f.write(b"SAVE")
    for i in range(47):
        with open(os.path.join(bb, "mods", f"pack_{i:02d}.jar"), "wb") as f:
            f.write(b"X" * (100 + i))
    with open(os.path.join(bb, "mods", "sodium-fabric-0.6.1.jar"), "wb") as f:
        f.write(b"NEW-VERSION" * 12)
    with open(os.path.join(bb, "mods", "jei-1.21.1-fabric-19.21.2.313.jar"), "wb") as f:
        f.write(b"JEI" * 50)
    with open(os.path.join(bb, "screenshots", "shot1.png"), "wb") as f:
        f.write(b"PNG")
    return {
        "Fabulously Optimized":     {"gameDir": "./custom_gamedir/modrinth_CA336076-FF45-4B33-88A7-F746B2E23B33", "created": "2026-10-01"},
        "Fabulously Optimized (2)": {"gameDir": "./custom_gamedir/modrinth_BB10129F-2272-4B3F-968A-FFF753C58CB2", "created": "2026-10-14"},
        "(Default)":                {"gameDir": ".", "created": "2026-09-01"},
    }, ca, bb

def main():
    ok = [0]; fail = [0]
    def check(name, cond):
        if cond: ok[0] += 1; print(f"  PASS {name}")
        else: fail[0] += 1; print(f"  FAIL {name}")

    tmp = tempfile.mkdtemp(prefix="verify269_")
    try:
        print("== case1: 规范名归一 ==")
        check("X (2) -> X", norm("X (2)") == "X")
        check("X（12） -> X", norm("X（12）") == "X")
        check("X (2023) 不误伤(3位数字)", norm("X (2023)") == "X (2023)")
        check("X 保持 X", norm("X") == "X")

        print("== case1b: mods 身份键 ==")
        check("sodium 新旧版本同身份", mod_identity_key("sodium-fabric-0.6.1.jar") == mod_identity_key("sodium-fabric-0.6.0.jar") == "sodium_fabric")
        check("jei 版本段剥离", mod_identity_key("jei-1.21.1-fabric-19.21.2.313.jar") == "jei_1_21_1_fabric")
        check("纯数字文件名至少保一段", mod_identity_key("123.jar") == "123")
        check("disabled 后缀剥离", mod_identity_key("apple-2.0.jar.disabled") == "apple")

        print("== case2: gameDir → 实例 id ==")
        check("标准路径", inst_id_from_gamedir("./custom_gamedir/modrinth_ABC") == "modrinth_ABC")
        check("拒绝深层", inst_id_from_gamedir("./custom_gamedir/a/b") is None)
        check("拒绝根目录", inst_id_from_gamedir(".") is None)
        check("拒绝非实例", inst_id_from_gamedir("./versions/1.21") is None)

        print("== case3: 装机实况复演（FO + FO (2)）==")
        game_dir = os.path.join(tmp, "gd")
        profiles, ca, bb = build_case(game_dir)
        new_profiles, plans = migrate(game_dir, profiles)
        check("产出 1 个迁移计划", len(plans) == 1)
        check("canonical = 原名实例", plans[0]["canonical"] == "Fabulously Optimized")
        check("合并对象 = (2) 实例", plans[0]["merged"] == ["Fabulously Optimized (2)"])
        check("(2) profile 已删除", "Fabulously Optimized (2)" not in new_profiles)
        check("canonical profile 保留", "Fabulously Optimized" in new_profiles)
        check("(Default) 不受牵连", "(Default)" in new_profiles)
        check("重复文件夹已删除", not os.path.exists(bb))
        ca_mods = set(os.listdir(os.path.join(ca, "mods")))
        check("47 个 pack jar 全在", sum(1 for f in ca_mods if f.startswith("pack_")) == 47)
        check("JEI 独有文件 move 进 canonical", "jei-1.21.1-fabric-19.21.2.313.jar" in ca_mods)
        check("sodium 新版本未混入（防双版本崩）", "sodium-fabric-0.6.1.jar" not in ca_mods)
        check("sodium 旧版本保留", "sodium-fabric-0.6.0.jar" in ca_mods)
        check("存档未动", os.path.exists(os.path.join(ca, "saves", "world1", "level.dat")))
        check("截图独有文件收进 canonical", os.path.exists(os.path.join(ca, "screenshots", "shot1.png")))
        stashed = os.path.join(game_dir, "custom_gamedir", ".ame269_backup", "ts",
                               "modrinth_BB10129F-2272-4B3F-968A-FFF753C58CB2", "mods", "sodium-fabric-0.6.1.jar")
        check("sodium 新版本进备份绝不丢失", os.path.exists(stashed))

        print("== case4: 幂等复跑 ==")
        profiles2, plans2 = migrate(game_dir, dict(new_profiles))
        check("二次复跑零计划", len(plans2) == 0)

        print("== case5: 选中实例被合并 → 切 canonical（复演主线程收口）==")
        prof3 = {
            "A":     {"gameDir": "./custom_gamedir/x_ca", "created": "2026-01-01"},
            "A (2)": {"gameDir": "./custom_gamedir/x_bb", "created": "2026-02-01"},
        }
        os.makedirs(os.path.join(game_dir, "custom_gamedir", "x_ca"), exist_ok=True)
        os.makedirs(os.path.join(game_dir, "custom_gamedir", "x_bb"), exist_ok=True)
        _, plans3 = migrate(game_dir, prof3)
        sel = "A (2)"
        for plan in plans3:
            for dead in plan["merged"]:
                prof3.pop(dead, None)
            if sel in plan["merged"]:
                sel = plan["canonical"]
        check("选中自动切到 canonical", sel == "A")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    total = ok[0] + fail[0]
    print(f"\n== 结论: PASS {ok[0]} / FAIL {fail[0]} ==")
    if fail[0]:
        sys.exit(1)
    print(f"verify269: {ok[0]}/{total}")

if __name__ == "__main__":
    main()
