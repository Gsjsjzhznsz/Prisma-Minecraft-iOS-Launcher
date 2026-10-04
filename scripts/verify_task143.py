#!/usr/bin/env python3
# verify_task143 -- Task 143 verifier: three device-log-driven fixes from the
# 4ecc256 build (latestlog uploaded by the user as repo commit ca9d11bb):
#   (1) mobileglues.renderer_backend was never registered in PLPreferences ->
#       setter silently dropped every backend pick ("Setter could not find
#       preference") -> launch always fell back to libMobileGL.dylib --
#       user: "no matter what renderer I switch to it becomes mg".
#   (2) GL_FRAGMENT_SHADER defined as 0x8B92 (= GL_PALETTE4_R5_G6_B5_OES!)
#       in mgl_fsr.mm (copied from osm_bridge.mm's wrong Task84 "erratum";
#       canonical value 0x8B30 per mesa glext.h:599) -> fragment shader
#       glCreateShader returned 0 + GL_INVALID_ENUM -> FSR EASU chain never
#       initialized -> permanent heal to full-res -- user: "FSR not working".
#       Bonus: GL_ARRAY_BUFFER_BINDING 0x8B8C (= GL_SHADING_LANGUAGE_VERSION)
#       -> 0x8894; actually referenced by the RCAS VBO save/restore.
#   (3) standalone MobileGlues (libmobileglues.dylib) entry hidden from the
#       picker lists unless currently selected -- user: "mg is MobileGlues,
#       why does the list have both mg and MobileGlues".
# Usage: python3 scripts/verify_task143.py   (run from repo root)
import os, re, subprocess, sys

PASS = FAIL = 0
def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")

def read(p):
    return open(p, encoding='utf-8', errors='replace').read()

def bracket_balance(src):
    """Strip // comments, /* */ comments, @""/""/'' string literals, then count braces/brackets/parens."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i+1] == '/':
            while i < n and src[i] != '\n': i += 1
        elif c == '/' and i + 1 < n and src[i+1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i+1] == '/'): i += 1
            i += 2
        elif c == '@' and i + 1 < n and src[i+1] == '"':
            i += 2
            while i < n:
                if src[i] == '\\': i += 2; continue
                if src[i] == '"': i += 1; break
                i += 1
        elif c == '"':
            i += 1
            while i < n:
                if src[i] == '\\': i += 2; continue
                if src[i] == '"': i += 1; break
                i += 1
        else:
            out.append(c); i += 1
    s = ''.join(out)
    return (s.count('{') - s.count('}'), s.count('[') - s.count(']'), s.count('(') - s.count(')'))

print("== A. Backend key registration (PLPreferences.m) ==")
plp = read('Natives/PLPreferences.m')
m = re.search(r'@"mobileglues": @\{.*?\}\.mutableCopy', plp, re.S)
mg_section = m.group(0) if m else ''
check("A1 renderer_backend registered inside the mobileglues defaults section",
      '@"renderer_backend": @""' in mg_section)
check("A2 default is the EMPTY string (preserves the legacy tier chain, not a literal backend)",
      '@"renderer_backend": @"",' in mg_section and '@"renderer_backend": @"libMobileGL.dylib"' not in plp)
check("A3 Task 143 root-cause comment present (setter-dropped-pick evidence)",
      'Setter could not find preference' in mg_section and 'Task 143' in mg_section)
check("A4 legacy tier key mobilegl_backend untouched (still defaults to 1 = Vulkan)",
      '@"mobilegl_backend": @(1)' in mg_section)
check("A5 registration order: renderer_backend precedes mobilegl_backend (reads as the newer key)",
      mg_section.index('@"renderer_backend"') < mg_section.index('@"mobilegl_backend"'))

print("== B. FSR shader constants (mgl_fsr.mm) ==")
mgl = read('Natives/ctxbridges/mgl_fsr.mm')
check("B1 GL_FRAGMENT_SHADER canonical 0x8B30",
      '#define GL_FRAGMENT_SHADER  0x8B30' in mgl)
check("B2 wrong 0x8B92 define gone",
      '#define GL_FRAGMENT_SHADER  0x8B92' not in mgl)
check("B3 GL_VERTEX_SHADER still 0x8B31",
      '#define GL_VERTEX_SHADER    0x8B31' in mgl)
check("B4 GL_ARRAY_BUFFER_BINDING canonical 0x8894",
      '#define GL_ARRAY_BUFFER_BINDING 0x8894' in mgl and
      '#define GL_ARRAY_BUFFER_BINDING 0x8B8C' not in mgl)
check("B5 erratum comment names the misdiagnosis (0x8B92 = PALETTE4_OES)",
      'GL_PALETTE4_R5_G6_B5_OES' in mgl and 'Task 143' in mgl)
check("B6 RCAS VBO save/restore site still consumes the fixed constant",
      'glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &saveVbo)' in mgl)
check("B7 fragment compile call site intact (EASU + RCAS)",
      mgl.count('ame119_compile(GL_FRAGMENT_SHADER') == 2)

print("== C. FSR shader constants (osm_bridge.mm, same-source fix) ==")
osm = read('Natives/ctxbridges/osm_bridge.mm')
check("C1 GL_FRAGMENT_SHADER canonical 0x8B30",
      '#define GL_FRAGMENT_SHADER  0x8B30' in osm)
check("C2 wrong Task84 erratum comment replaced (re-erratum)",
      'Task 143' in osm and '再勘误' in osm and '规范值是 0x8B92' not in osm)
check("C3 GL_ARRAY_BUFFER_BINDING canonical 0x8894",
      '#define GL_ARRAY_BUFFER_BINDING 0x8894' in osm and
      '#define GL_ARRAY_BUFFER_BINDING 0x8B8C' not in osm)
check("C4 RCAS VBO save/restore site intact",
      'glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &saveVbo)' in osm)
check("C5 fragment compile call sites intact (EASU + RCAS)",
      osm.count('GL_FRAGMENT_SHADER,') >= 2)

print("== D. Renderer picker: standalone MobileGlues retired from new picks ==")
prefm = read('Natives/LauncherPreferences.m')
check("D1 libmobileglues entry still IN rendererCandidates table (display-mapping source)",
      '@{@"key": @ RENDERER_NAME_MOBILEGLUES,' in prefm)
check("D2 availableRendererCandidates hides it unless currently selected (rule 3)",
      'if ([key isEqualToString:@ RENDERER_NAME_MOBILEGLUES] &&\n            ![key isEqualToString:current]) {' in prefm)
check("D3 rule-3 comment explains the user complaint",
      '为什么列表有个 mg 又有个 MobileGlues' in prefm)
check("D4 ame_renderer_display_name maps the legacy key back to its existing label (zero l10n churn)",
      prefm.index('if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {') <
      prefm.index('NSArray *keys = getRendererKeys(NO);\n    NSArray *names = getRendererNames(NO);'))
check("D5 mapping reuses preference.title.renderer.debug.mg (no new l10n key)",
      'preference.title.renderer.debug.mg' in prefm.split('Task 143：独立 MobileGlues')[1].split('NSArray *keys')[0])
check("D6 mg entry itself untouched (still always listed)",
      '@{@"key": @ RENDERER_KEY_MG,' in prefm and
      '@"file": @""},' in prefm.split('@ RENDERER_KEY_MG,')[1].split('@ RENDERER_NAME_GL4ES')[0])
check("D7 legacy runtime resolution untouched (stored libmobileglues keys still launch)",
      'if (![renderer isEqualToString:@"auto"]) {' in prefm and
      'ame138_physical' in prefm)

print("== E. Syntax gates ==")
for path in ['Natives/PLPreferences.m', 'Natives/LauncherPreferences.m',
             'Natives/ctxbridges/mgl_fsr.mm', 'Natives/ctxbridges/osm_bridge.mm']:
    b = bracket_balance(read(path))
    check(f"E {os.path.basename(path)} brackets balanced {b}", b == (0, 0, 0))

print("== F. No l10n baseline drift (keys stay at 2228 x4) ==")
total = None
drift = []
for lp in ['en', 'zh-CN', 'zh-Hans', 'zh-Hant']:
    p = f'Natives/resources/{lp}.lproj/Localizable.strings'
    keys = set(re.findall(r'^"([^"]+)"\s*=', read(p), re.M))
    if total is None: total = len(keys)
    if len(keys) != total: drift.append(f"{lp}:{len(keys)}")
check(f"F1 four-language key sets identical at {total} keys (Task159 baseline 2228)",
      total == 2520 and not drift, f"drift={drift}")
check("F2 debug.mg key still present x4 (reused for the legacy mapping)",
      all('"preference.title.renderer.debug.mg" =' in
          read(f'Natives/resources/{lp}.lproj/Localizable.strings')
          for lp in ['en', 'zh-CN', 'zh-Hans', 'zh-Hant']))

print("== G. Regression: verify_task142 still green ==")
r = subprocess.run([sys.executable, 'scripts/verify_task142.py'],
                   capture_output=True, text=True)
ok = r.returncode == 0 and '49 passed, 0 failed' in r.stdout
check("G1 verify_task142 49/49 (re-anchored baseline holds)", ok,
      r.stdout.strip().splitlines()[-1] if r.stdout else 'no output')

print(f"\n==== RESULT: {PASS} passed, {FAIL} failed ====")
sys.exit(1 if FAIL else 0)
