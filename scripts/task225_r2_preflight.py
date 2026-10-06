#!/usr/bin/env python3
"""Task225 CI repair r2 pre-flight: static audit of the Task225 native diff
for clang error classes the Linux verify gates cannot compile-check.
Sweeps: boxed-literal nesting, @selector vs implementation, duplicate method
definitions, NSLog/NSString format-arity, identifier-vs-macro collisions,
declaration/definition type mismatches for new C functions."""
import re, subprocess, sys, os
from collections import defaultdict

os.chdir('/home/z/my-project/Amethyst-iOS-MyRemastered')
fails = []

def err(msg):
    fails.append(msg)
    print('  FAIL:', msg)

def ok(msg):
    print('  ok  :', msg)

# ---- 1. files + added lines in the Task225 native diff -------------------
base, head = '02a3fe1e', 'ca4b798e'
diff = subprocess.run(['git', 'diff', base, head, '--', 'Natives'],
                      capture_output=True, text=True).stdout
added = defaultdict(list)   # file -> [added line strings]
cur = None
for line in diff.split('\n'):
    if line.startswith('+++ b/'):
        cur = line[6:]
    elif line.startswith('+') and not line.startswith('+++') and cur:
        added[cur].append(line[1:])

native_files = [f for f in added if f.endswith(('.m', '.c'))]
print(f'== diff sweep: {len(native_files)} native source files with additions ==')
for f in native_files:
    print(f'   {f}: +{len(added[f])} lines')

# ---- 2. boxed literal nesting (NSNumber*/NSString* inside @()) ----------
print('== audit 1: boxed-literal nesting ==')
pat_box = re.compile(r'@\(\s*[^()]*@(?:YES|NO|")')
hit = False
for f, lines in added.items():
    for l in lines:
        if pat_box.search(l):
            err(f'{f}: boxed literal nesting: {l.strip()[:120]}')
            hit = True
if not hit: ok('no nested boxed literals in added lines')

# full-file sweep too (tertiary operands like ?: need real parse)
box_full = re.compile(r'@\(\s*([A-Za-z_][\w.]*\s*\?\s*)')
for f in native_files:
    try:
        for i, l in enumerate(open(f, encoding='utf-8', errors='replace'), 1):
            if pat_box.search(l):
                err(f'{f}:{i}: boxed literal nesting: {l.strip()[:120]}')
    except FileNotFoundError:
        pass

# ---- 3. @selector() names vs implementations -----------------------------
print('== audit 2: @selector vs implementation ==')
impl_cache = {}
def file_impls(path):
    if path in impl_cache: return impl_cache[path]
    try:
        src = open(path, encoding='utf-8', errors='replace').read()
    except FileNotFoundError:
        impl_cache[path] = set(); return set()
    sels = set()
    # strip comments crudely
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    for m in re.finditer(r'^\s*[-+]\s*\([^)]+\)\s*([A-Za-z_][\w:]*)', src, re.M):
        sels.add(m.group(1).rstrip(':').split(':')[0])
    # multi-part selector from full signature
    full = set()
    for m in re.finditer(r'^\s*[-+]\s*\([^)]+\)\s*([A-Za-z_][\w:]*(?::[\w:\s\(\)*]+)?)', src, re.M):
        parts = re.findall(r'([A-Za-z_]\w*)\s*:', m.group(1))
        if parts: full.add(':'.join(parts))
        else: full.add(m.group(1).strip())
    impl_cache[path] = full
    return full

all_impls = set()
for f in native_files:
    all_impls |= file_impls(f)
# also everything in Natives (cross-file selector targets)
for root, _, files in os.walk('Natives'):
    if 'external' in root: continue
    for fn in files:
        if fn.endswith(('.m', '.mm')):
            all_impls |= file_impls(os.path.join(root, fn))

bad = 0
for f, lines in added.items():
    for l in lines:
        for m in re.finditer(r'@selector\(\s*([A-Za-z_][\w:]*)\s*\)', l):
            sel = m.group(1)
            # a selector with colons must match a full signature; without colons any name
            base_sel = sel.split(':')[0] if sel.endswith(':') else sel.rstrip(':')
            known = sel in all_impls or base_sel in all_impls
            # system/framework selectors: allow common UIKit/NSObject ones
            SYSTEM = {'delegate','tableView','colorWithAlphaColor:','colorWithWhite:alpha:',
                      'defaultManager',' standardUserDefaults','pushViewController:animated:',
                      'presentViewController:animated:completion:','dismissViewControllerAnimated:completion:',
                      'addTarget:action:forControlEvents:',' resignFirstResponder','becomeFirstResponder',
                      'stringWithFormat:','arrayWithObjects:','dictionaryWithDictionary:',
                      'appearance','count','objectForKey:','setObject:forKeyedSubscript:',
                      'removeObjectForKey:','boolValue','integerValue','floatValue','doubleValue',
                      'stringByAppendingPathComponent:','stringByDeletingLastPathComponent',
                      'fileExistsAtPath:','createDirectoryAtPath:withIntermediateDirectories:attributes:error:',
                      'contentsOfDirectoryAtPath:error:','removeItemAtPath:error:','copyItemAtPath:toPath:error:',
                      'moveItemAtPath:toPath:error:','dataWithContentsOfFile:','writeToFile:atomically:',
                      'isEqual:','isKindOfClass:','respondsToSelector:','performSelectorOnMainThread:withObject:waitUntilDone:',
                      'performSelector:withObject:afterDelay:','cancelPreviousPerformRequestsWithTarget:',
                      'setSelected:','setTitle:forState:','addSubview:','removeFromSuperview',
                      'setTranslatesAutoresizingMaskIntoConstraints:','valueForKey:','setValue:forKey:',
                      'enumerateObjectsUsingBlock:','componentsSeparatedByString:','substringFromIndex:',
                      'length','characterAtIndex:','initWithFrame:','initWithStyle:reuseIdentifier:',
                      'registerClass:forCellReuseIdentifier:','dequeueReusableCellWithIdentifier:forIndexPath:',
                      'setUserInteractionEnabled:','backgroundColor','alpha','hidden',
                      'sizeThatFits:','systemLayoutSizeFittingSize:','layoutIfNeeded'}
            if not known and sel not in SYSTEM and base_sel not in SYSTEM:
                err(f'{f}: @selector({sel}) not found in any implementation (verify manually)')
                bad += 1
if bad == 0: ok('all @selector names resolved')

# ---- 4. duplicate method definitions within one file ----------------------
print('== audit 3: duplicate method definitions ==')
dup = 0
for f in native_files:
    try:
        src = open(f, encoding='utf-8', errors='replace').read()
    except FileNotFoundError:
        continue
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    sigs = re.findall(r'^\s*[-+]\s*\([^)]+\)\s*([A-Za-z_][\w:]*(?::[\w:\s\(\)*\[\]]+)?)\s*\{', src, re.M)
    norm = []
    for s in sigs:
        parts = re.findall(r'([A-Za-z_]\w*)\s*:', s)
        norm.append(':'.join(parts) if parts else s.strip().rstrip(':'))
    counts = defaultdict(int)
    for s in norm: counts[s] += 1
    for s, c in counts.items():
        if c > 1 and s:
            err(f'{f}: method {s} defined {c}x')
            dup += 1
if dup == 0: ok('no duplicate method definitions in changed files')

# ---- 5. NSLog format arity -------------------------------------------------
print('== audit 4: NSLog/NSString format arity ==')
fmt_bad = 0
spec = re.compile(r'%[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|L|z|j|t)?[@dDuUxXoOfeEgGcCsSpaAF]')
for f, lines in added.items():
    for l in lines:
        m = re.search(r'NSLog\(@"((?:[^"\\]|\\.)*)"(?:,\s*(.*))?\)\s*;', l)
        if not m: continue
        fmt, args = m.group(1), m.group(2) or ''
        # %d etc in C89 NSLog variadic: count specifiers vs top-level comma args
        specs = spec.findall(fmt)
        specs = [s for s in specs if not s.startswith('%%')]
        nargs = 0 if not args.strip() else len(re.split(r',(?![^()]*\))', args))
        if len(specs) != nargs:
            # %% filtered; heuristic only for single-line calls
            err(f'{f}: NSLog spec/arg mismatch: {l.strip()[:130]}')
            fmt_bad += 1
if fmt_bad == 0: ok('NSLog format arities consistent (single-line)')

# ---- 6. macro collisions: identifiers shadowing #define --------------------
print('== audit 5: local identifiers vs file macros ==')
macro_bad = 0
for f in native_files:
    try:
        src = open(f, encoding='utf-8', errors='replace').read()
    except FileNotFoundError:
        continue
    macros = set(re.findall(r'^#\s*define\s+(\w+)', src, re.M))
    for mac in macros:
        # local decl of a var named like the macro (the fm lesson)
        for m in re.finditer(rf'^\s+(?:\w[\w\s\*]*?)\b{mac}\s*(?:=|;|\))', src, re.M):
            decl = m.group(0).strip()
            if f'#define {mac}' in decl: continue
            # declarations that USE the macro as a receiver are fine; only flag
            # declarations where mac is the declared NAME
            if re.search(rf'(?:NS\w+|UI\w+|CG\w+|void|BOOL|char|int|unsigned|float|double|id|NSString|NSArray|NSDictionary|NSNumber|NSData|NSError|NSURL|NSDate|NSValue|SEL|Class|SEL|dispatch_[a-z_]+t?|CGFloat|CGPoint|CGRect|CGSize|NSUInteger|NSInteger)\s*\*?\s*{mac}\s*[;=)]', decl):
                err(f'{f}: local/param name {mac!r} collides with #define (fm-lesson class)')
                macro_bad += 1
if macro_bad == 0: ok('no declared-name/macro collisions in changed files')

# ---- 7. C function decl/def type mismatches (vtest lesson) ----------------
print('== audit 6: C function decl vs def signatures ==')
sig_bad = 0
for f in native_files:
    try:
        src = open(f, encoding='utf-8', errors='replace').read()
    except FileNotFoundError:
        continue
    src2 = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src2 = re.sub(r'//[^\n]*', '', src2)
    decls = re.findall(r'^\s*(?:static\s+)?(\w[\w\s\*]*?)\s+(\w+)\s*\(([^;{]*)\)\s*;', src2, re.M)
    defs = re.findall(r'^\s*(?:static\s+)?(\w[\w\s\*]*?)\s+(\w+)\s*\(([^;{]*)\)\s*\{', src2, re.M)
    dmap = {}
    for ret, name, params in defs:
        dmap.setdefault(name, []).append((re.sub(r'\s+', '', ret), re.sub(r'\s+', '', params)))
    for ret, name, params in decls:
        if name not in dmap: continue
        r2, p2 = re.sub(r'\s+', '', ret), re.sub(r'\s+', '', params)
        for dr, dp in dmap[name]:
            if dr != r2:
                err(f'{f}: decl "{ret} {name}(...)" vs def "{dr} {name}(...)"')
                sig_bad += 1
            # void params vs (void) normalization
            pn = p2.replace('void', '') if p2 in ('void', '') else p2
            dpn = dp.replace('void', '') if dp in ('void', '') else dp
            if pn != dpn and not (pn == '' and dpn == ''):
                err(f'{f}: param mismatch in {name}: decl({p2[:60]}) def({dp[:60]})')
                sig_bad += 1
if sig_bad == 0: ok('C declarations match definitions')

print()
print(f'== RESULT: {len(fails)} hard failure(s) ==')
sys.exit(1 if fails else 0)
