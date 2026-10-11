#!/usr/bin/env python3
# Task 250 (11): i18n dynamic-key full audit
# 1) Four-table presence check for every literal key referenced via localize()/MPLocalized()
# 2) Dynamic-key families: enumerate concrete keys per family and check four tables
# 3) "key shown as value" check: any table row whose VALUE equals its KEY
import re, os, sys, collections

ROOT = "/home/z/my-project/repo-prisma/Natives"
RES = os.path.join(ROOT, "resources")
FOUR = ["en", "zh-CN", "zh-Hans", "zh-Hant"]

def load_table(lang):
    path = os.path.join(RES, lang + ".lproj", "Localizable.strings")
    table = {}
    pat = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = pat.match(line)
            if m:
                table[m.group(1)] = m.group(2)
    return table

tables = {lang: load_table(lang) for lang in FOUR}
print("table sizes:", {k: len(v) for k, v in tables.items()})

# ---------- 1) literal localize keys ----------
lit = set()
loc = re.compile(r'(?:localize|MPLocalized)\(\s*@ "((?:[^"\\]|\\.)*)"', re.X)
loc2 = re.compile(r'(?:localize|MPLocalized)\(\s*@((?:[^"\\]|\\.)*)"', re.X)
for dirpath, _, files in os.walk(ROOT):
    if "resources" in dirpath:
        continue
    for fn in files:
        if not fn.endswith(".m"):
            continue
        src = open(os.path.join(dirpath, fn), encoding="utf-8", errors="replace").read()
        # match localize(@"key",  / MPLocalized(@"key",
        for m in re.finditer(r'(?:localize|MPLocalized)\(\s*@((?:[^"\\]|\\.)*)"', src):
            k = m.group(1)
            if k.startswith('"'):
                lit.add(k[1:])
            else:
                lit.add(k)

missing = collections.defaultdict(list)
for k in sorted(lit):
    for lang in FOUR:
        if k not in tables[lang]:
            missing[k].append(lang)
print("literal keys:", len(lit), "| missing across four tables:", len(missing))
for k, langs in list(missing.items())[:40]:
    print("  MISS", k, langs)

# ---------- 2) dynamic families ----------
# family: (prefix regex on table keys, generator of concrete keys)
dyn_report = []

def check_family(name, keys):
    miss = collections.defaultdict(list)
    for k in keys:
        for lang in FOUR:
            if k not in tables[lang]:
                miss[k].append(lang)
    if miss:
        dyn_report.append((name, miss))

# 2a. preference.* families from PLPrefTableViewController — enumerate section/key
# sources from LauncherPreferencesViewController.m row dicts: @{@"section": @"x"...}
# and @{@"key": @"y"}; sections list rows.
pref_rows = []
sections = []
lpc = open(os.path.join(ROOT, "LauncherPreferencesViewController.m"), encoding="utf-8").read()
for m in re.finditer(r'@\{@"section"\s*:\s*@"([A-Za-z0-9_]+)"', lpc):
    sections.append(m.group(1))
for m in re.finditer(r'@\{@"key"\s*:\s*@"([A-Za-z0-9_\.]+)"', lpc):
    pref_rows.append(m.group(1))
ptvc = open(os.path.join(ROOT, "PLPrefTableViewController.m"), encoding="utf-8").read()
for m in re.finditer(r'@\{@"key"\s*:\s*@"([A-Za-z0-9_\.]+)"', ptvc):
    pref_rows.append(m.group(1))
# known standalone section keys used by buildEntryForSection etc.
sec_keys = sorted(set(sections)) or ["general", "video", "control", "launcher", "download", "instance", "ai"]
row_keys = sorted(set(pref_rows))
check_family("preference.section.*", ["preference.section." + s for s in sec_keys])
check_family("preference.detail.*", ["preference.detail." + k for k in row_keys])
check_family("preference.warn.*", ["preference.warn." + k for k in row_keys])
check_family("preference.title.confirm.*", ["preference.title.confirm." + k for k in row_keys])
check_family("preference.title.done.*", ["preference.title.done." + k for k in row_keys])

# 2b. controller_configurator.<ctype>.title.<name>
# ctype values: collect from controller_type pick keys + getPrefObject defaults
ctypes = set()
for m in re.finditer(r'@"(xbox|ps|switch|keyboard|steam|generic|8bitdo|gamepad)"', ptvc):
    ctypes.add(m.group(1))
for m in re.finditer(r'controller_type[^\n]*@"([A-Za-z0-9_]+)"', open(os.path.join(ROOT, "LauncherPreferencesViewController.m"), encoding="utf-8").read()):
    ctypes.add(m.group(1))
# item names from LauncherPrefContCfgViewController.m: @{@"name": @"x"...}
cfg_names = set()
for m in re.finditer(r'@\{@"name"\s*:\s*@"([A-Za-z0-9_]+)"', open(os.path.join(ROOT, "LauncherPrefContCfgViewController.m"), encoding="utf-8").read()):
    cfg_names.add(m.group(1))
# also the type.* family
if not ctypes:
    ctypes = {"xbox", "ps", "switch", "keyboard"}
check_family("controller_configurator.<t>.title.<n>",
             ["controller_configurator.%s.title.%s" % (c, n) for c in sorted(ctypes) for n in sorted(cfg_names)])
check_family("controller_configurator.title.type.*",
             ["controller_configurator.title.type." + c for c in sorted(ctypes)])

# 2c. dataexport.section.*
de = open(os.path.join(ROOT, "DataExportViewController.m"), encoding="utf-8").read()
sids = set(m.group(1) for m in re.finditer(r'@"sid"\s*,\s*@"([A-Za-z0-9_]+)"', de))
sids |= set(m.group(1) for m in re.finditer(r'ame223_section(?:With|For)[^\n]*@"([A-Za-z0-9_]+)"', de))
sids |= set(m.group(1) for m in re.finditer(r'sid:\s*@"([A-Za-z0-9_]+)"', de))
if sids:
    check_family("dataexport.section.*", ["dataexport.section." + s for s in sorted(sids)])

# 2d. SurfaceVC+Navigation menuArray (game menu titles are table keys)
nav = open(os.path.join(ROOT, "SurfaceViewController+Navigation.m"), encoding="utf-8").read()
mkeys = set(m.group(1) for m in re.finditer(r'@"((?:game\.menu|menu)\.[A-Za-z0-9_\.]+)"', nav))
if mkeys:
    check_family("game.menu.*", sorted(mkeys))

print("\n== dynamic family misses ==")
if not dyn_report:
    print("  (none)")
for name, miss in dyn_report:
    print(" ", name, "->", len(miss), "missing")
    for k, langs in list(miss.items())[:60]:
        print("    MISS", k, langs)

# ---------- 3) key==value sanity ----------
eq = []
for lang in FOUR:
    for k, v in tables[lang].items():
        if v == k and ("." in k) and len(k) > 8:
            eq.append((lang, k))
print("\n== key-value identical rows (key name would display) ==")
for lang, k in eq[:40]:
    print("  EQ", lang, k)
print("  total:", len(eq))
