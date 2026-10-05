#!/usr/bin/env python3
"""Task223 CI-repair preflight: symbol-visibility audit for the ~20 app TUs
never compiled in run 37358698030 (make aborted at 76% after 2 errors).
Builds the Natives header import graph, computes each file's transitive
import closure, and verifies every repo-level symbol it uses is declared
in a header within that closure."""
import os, re, sys

REPO = "/home/z/my-project/Amethyst-iOS-MyRemastered"
NAT = os.path.join(REPO, "Natives")

# files compiled clean in CI run 37358698030 (proven) -> skip them
PROVEN = set("""AccountListViewController.m AccountLoginViewController.m DataExportViewController.m
DataTransferService.m DownloadHistoryStore.m DownloadHistoryViewController.m DownloadTaskItem.m
DownloadTaskManager.m DownloadTasksViewController.m GameMenuOverlayView.m InlineMessageView.m
JavaLauncher.m NMToast.m PLDownloadClient.m PLMirrorCenter.m PLTaskProgressViewController.m
PLTaskStage.m ScreenUtils.m ThirdPartyLoginViewController.m UIKit+NativeSurface.m UIKit+hook.m
UIViewController+AMEPanel.m authenticator/BaseAuthenticator.m authenticator/LocalAuthenticator.m
authenticator/MicrosoftAuthenticator.m authenticator/ThirdPartyAuthenticator.m
ctxbridges/gl_bridge.m ctxbridges/mgl_fsr.mm ctxbridges/mgl_metal_fsr.mm ctxbridges/osm_bridge.mm
ctxbridges/virgl_server.m ctxbridges/vk_bridge.m customcontrols/ControlButton.m
customcontrols/ControlDrawer.m customcontrols/ControlJoystick.m customcontrols/ControlLayout.m
customcontrols/ControlSubButton.m customcontrols/CustomControlsUtils.m
customcontrols/NSPredicateUtilitiesExternal.m dyld_bypass_validation.m dyld_patch_platform.m
external/DBNumberedSlider/Classes/DBNumberedSlider.m external/NRFileManager/NSFileManager+NRFileManager.m
external/ballpa1n/HostManager.c external/ballpa1n/wrapped/HostManagerBridge.m external/fishfish.c
external/fishhook/fishhook.c external/mach/mach_excServer.c input/ControllerInput.m input/GyroInput.m
input/KeyboardInput.m installer/FabricInstallViewController.m installer/FabricUtils.m
installer/ForgeDirectInstaller.m installer/ForgeInstallSchemeViewController.m
installer/ForgeInstallViewController.m installer/ForgeProcessorExecutor.m
installer/ModLoaderInstallViewController.m installer/ModpackInstallViewController.m
installer/NeoForgeDirectInstaller.m installer/NeoForgeVersionFetcher.m
installer/modpack/CurseForgeAPI.m installer/modpack/ModpackAPI.m installer/modpack/ModpackConfiguration.m
installer/modpack/ModpackUtils.m installer/modpack/ModrinthAPI.m main.m main_hook.m sdl3_hook.m
shaderc_sandbox.m""".split())

# repo-level symbols -> declaring header (relative to Natives/)
SYMBOLS = {
    'accentColor': 'LauncherPreferences.h',
    'UIWindow.mainWindow': 'UIKit+hook.h',
    'mainWindow': 'UIKit+hook.h',
    'externalWindow': 'UIKit+hook.h',
    'isConnectivityError': 'utils.h',
    'ame223_bg_park_begin': 'utils.h',
    'ame223_bg_park_end': 'utils.h',
    'ame223_bg_park_wait': 'utils.h',
    'localize': 'utils.h',
    'getPrefBool': 'utils.h',
    'getPrefInt': 'utils.h',
    'getPrefObject': 'utils.h',
    'setPrefBool': 'utils.h',
    'setPrefObject': 'utils.h',
    'showDialog': 'utils.h',
    'isJITEnabled': 'utils.h',
    'applyCardEffectToView': 'BackgroundManager.h',
    'makeViewControllerTransparent': 'BackgroundManager.h',
    'applyEffectToView': 'BackgroundManager.h',
    'ame223_wallpaperImage': 'BackgroundManager.h',
    'ame223_wallpaperLuminance': 'BackgroundManager.h',
    'registerTaskWithResourceType': 'DownloadTaskManager.h',
    'DownloadTaskResourceTypeBackup': 'DownloadTaskItem.h',
    'autoPresentDetail': 'DownloadTaskItem.h',
    'ame223_runPipelinedBackupExportWithMethod': 'DataTransferService.h',
    'ame223_presentDestinationPickerForTmpPath': 'DataTransferService.h',
    'ame217_shouldSkipExportEntry': 'DataTransferService.h',
    'PLTaskStagesVanilla': 'PLTaskStages.h',
    'PLTaskStageTitleDisplay': 'PLTaskStages.h',
}

def read(p):
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except OSError:
        return None

INC_RE = re.compile(r'#(?:import|include)\s*[<"]([^">]+)[">]')

def resolve(header, seen=None):
    """transitive closure of local headers reachable from a file"""
    if seen is None: seen = set()
    if header in seen: return seen
    seen.add(header)
    src = read(os.path.join(NAT, header))
    if src is None:
        # maybe relative to subdirectory (e.g. ctxbridges/ includes)
        alt = os.path.join(NAT, 'external', header)
        src = read(alt)
        if src is None:
            return seen
    for m in INC_RE.finditer(src):
        inc = m.group(1)
        if inc.endswith('.h') and not inc.startswith('<'):
            # local header: try same dir first, then Natives root
            base = os.path.dirname(header)
            cands = [os.path.join(base, inc) if base else inc, inc,
                     os.path.join('external', inc)]
            for c in cands:
                if read(os.path.join(NAT, c)) is not None:
                    resolve(c, seen)
                    break
    return seen

# find the app's own .m files (excluding external vendored)
app_ms = []
for root, dirs, files in os.walk(NAT):
    if '/external' in root.replace(os.sep, '/'):
        continue
    for f in files:
        if f.endswith(('.m', '.mm')):
            rel = os.path.relpath(os.path.join(root, f), NAT)
            app_ms.append(rel)

problems = []
for rel in sorted(app_ms):
    if rel in PROVEN:
        continue
    src = read(os.path.join(NAT, rel)) or ''
    # strip comments to avoid false hits on symbol mentions in comments
    code = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    code = re.sub(r'//[^\n]*', '', code)
    # imports of the TU
    direct = [m.group(1) for m in INC_RE.finditer(src)]
    closure = set()
    for inc in direct:
        if inc.endswith('.h'):
            cands = [os.path.dirname(rel) and os.path.join(os.path.dirname(rel), inc) or inc, inc]
            for c in cands:
                if read(os.path.join(NAT, c)) is not None:
                    closure |= resolve(c)
                    break
            else:
                closure |= resolve(inc) if read(os.path.join(NAT, inc)) is not None else set()
    for sym, decl_h in SYMBOLS.items():
        if sym == 'UIWindow.mainWindow':
            used = re.search(r'UIWindow\s*\.\s*mainWindow|\[UIWindow\s+mainWindow\]', code)
        else:
            # word-boundary usage, not in a declaration line of the symbol itself
            used = re.search(r'\b' + re.escape(sym) + r'\b', code)
        if used and decl_h not in closure:
            problems.append((rel, sym, decl_h))

print(f"audited {len([r for r in app_ms if r not in PROVEN])} unproven TUs")
if problems:
    print("VISIBILITY PROBLEMS:")
    for rel, sym, hdr in problems:
        print(f"  {rel}: uses {sym!r} but {hdr} not in import closure")
else:
    print("no visibility problems found")
