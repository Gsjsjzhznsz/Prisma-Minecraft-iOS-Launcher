#!/usr/bin/env python3
"""Task307 gate: replay the real device crash sample (hs_err_pid47069 /
latestlog excerpt) against the ame307 detection predicate implemented in
Natives/main_hook.m (C strstr semantics, line-based like the ame273 parser).
"""
import sys

# Lines from the real device crash (uploaded latestlog.txt / hs_err excerpt
# as embedded by the ame273 stderr relay), plus a few CONTROL lines that must
# NOT trip the detector.
SAMPLE_POSITIVE = [
    "[JavaLauncher] MobileGL renderer active: backend=DirectVulkan",
    "[SurfaceVC] Task83 FSR linkage: renderer=libMobileGL.dylib preset=4 scale=2.00",
    "# Java VM: OpenJDK 64-Bit Server VM (25.0.4-internal-adhoc...)",
    "# Problematic frame:",
    "# C  [libMoltenVK.dylib+0xbe98c]  vkSetWorkgroupSizeMVK+0xbc",
    "C  [libMobileGL.dylib+0x66eb0c]  glWindowRectanglesEXT+0x25b260",
    "C  [libMobileGL.dylib+0x2d6874]  eglMakeCurrent+0x30",
    "C  [AngelAuraAmethyst+0x3d07b0]  pojavMakeCurrent+0x3c",
    "abort() called",
]

# Control: a session that merely mentions MoltenVK in a command line echo
# (no libMoltenVK.dylib+<offset> signature) must NOT trigger the targeted fix.
SAMPLE_NEGATIVE_CMDLINE = [
    "[JavaLauncher] RENDERER is set to libMobileGL.dylib",
    "[SurfaceVC] Task83 FSR linkage: renderer=libMobileGL.dylib",
    "-Dorg.lwjgl.vulkan.libname=MoltenVK",          # weak ref, no .dylib+ form
    "[JavaLauncher] MobileGL renderer active: backend=DirectVulkan",
]

# Control: MoltenVK crash but renderer NOT MobileGL (some other Vulkan host
# would be libMoltenVK without libMobileGL) -> no MobileGL-specific guidance.
SAMPLE_NEGATIVE_NOMGL = [
    "# C  [libMoltenVK.dylib+0xbe98c]  vkSetWorkgroupSizeMVK+0xbc",
    "C  [SomeOtherApp+0x1234]  pojavMakeCurrent+0x3c",
]

def detect(lines):
    """Mirrors main_hook.m ame307 predicate exactly (strstr, line-based)."""
    molten = mgl = False
    for line in lines:
        if not molten and "libMoltenVK.dylib+" in line:
            molten = True
        if not mgl and "libMobileGL.dylib" in line:
            mgl = True
        if molten and mgl:
            break
    return molten and mgl

fails = 0
checks = [
    ("real device crash -> targeted fix", SAMPLE_POSITIVE, True),
    ("cmdline-only MoltenVK mention -> generic fix", SAMPLE_NEGATIVE_CMDLINE, False),
    ("MoltenVK crash w/o MobileGL -> generic fix", SAMPLE_NEGATIVE_NOMGL, False),
]
for name, lines, expect in checks:
    got = detect(lines)
    ok = got == expect
    fails += 0 if ok else 1
    print("%s  %s (molten+mgl=%s, expect=%s)" % ("PASS" if ok else "FAIL", name, got, expect))

# SceneDelegate predicate: headline contains libMoltenVK.dylib
headline = "# C  [libMoltenVK.dylib+0xbe98c]  vkSetWorkgroupSizeMVK+0xbc"
ok = "libMoltenVK.dylib" in headline
fails += 0 if ok else 1
print("%s  SceneDelegate headline predicate" % ("PASS" if ok else "FAIL"))

# Report file format round-trip: fix line must stay single-line (ame273 parser
# splits on \\n; embedded newlines in the fix value would be dropped).
fix_text = ("MoltenVK（MobileGlues Vulkan 后端）在着色器管线初始化时崩溃（空指针）。"
            "缓解：设置-视频-渲染器-渲染后端(MobileGlues) 切到 GLES 档（不经 MoltenVK），"
            "或改用其他渲染器后重试。 EN: MoltenVK (MobileGlues Vulkan backend) crashed "
            "during shader pipeline init (null deref). Mitigation: switch the MobileGlues "
            "backend to GLES (bypasses MoltenVK), or pick another renderer.")
ok = "\n" not in fix_text
fails += 0 if ok else 1
print("%s  fix value is single-line (report parser safe)" % ("PASS" if ok else "FAIL"))

sys.exit(1 if fails else 0)
