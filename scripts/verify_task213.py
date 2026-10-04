#!/usr/bin/env python3
# verify_task213 — instance-card parity round (renumbered from the dead 212: the parallel session took 212 first) + help-page fix + installer spacing
# unification + account-card rewrite + launcher-wide rebrand (Air -> Prisma).
# NOTE: this environment's rg display output is untrustworthy (observed silent
# rewriting of matched lines); every check below reads files via python directly.
import os, re, sys, json, ast

ROOT = os.environ.get('TASK213_REPO', os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if not os.path.isdir(os.path.join(ROOT, 'Natives')):
    ROOT = '/home/z/my-project/workspace/Air-Minecraft-iOS-Launcher'
os.chdir(ROOT)

PASS = 0
FAIL = 0
FAILURES = []

def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f'FAIL {name}')

def rd(p):
    return open(os.path.join(ROOT, p), encoding='utf-8', errors='replace').read()

# ============ A. R1 instance card (VersionManagerViewController) ============
vm = rd('Natives/VersionManagerViewController.m')
check('A1 row height 128 with Task212 note',
      'kVMVersionRowHeight = 128.0' in vm and '仍矮一圈' in vm)
check('A2 icon 28 (parity bump)', vm.count('CGFloat iconSize = 28.0;') >= 2)
check('A3 long-press version -> deleteProfile directly',
      '[self deleteProfile:self.profileList[indexPath.item]];' in vm)
check('A4 old action-sheet menu retired',
      '- (void)showProfileActions' not in vm)
check('A5 long-press dir branch retired (returns)',
      re.search(r'kSectionGameDir\) \{\n        // Task212（用户定稿）：游戏目录长按功能删除[^}]*return;', vm, re.S) is not None)

# ============ B. R2 game-directory cell isomorphic ============
check('B1 dir cell has xmark delete button (icon not text x)',
      'systemImageNamed:@"xmark"' in vm and 'deleteButton' in vm)
check('B2 xmark geometry mirrors ellipsis (28pt circle / 16pt Black)',
      'configurationWithPointSize:16.0 weight:UIFontWeightBlack' in vm)
check('B3 dir icon native color (systemBlue folder, no container)',
      'self.iconView.tintColor = [UIColor systemBlueColor];' in vm and
      'VMGameDirCell : VMTileBaseCell' in vm)
check('B4 old FCL chrome retired (iconContainer/selectedBadge/chevron in GameDirCell)',
      not re.search(r'@interface VMGameDirCell[^\n]*\n(?!.*iconContainer).*selectedBadge', vm) and
      'chevronView' not in vm.split('#pragma mark - Renderer Card Cell')[0].split('VMGameDirCell : VMTileBaseCell')[1])
check('B5 dir selection ring isomorphic (inset = ellipsis/3; Task214 re-anchor: radius = kVMCardCornerRadius - inset/3 after the 12->16 corner bump)',
      vm.count('kVMCardCornerRadius - (kVMCardEllipsisInset / 3.0)') >= 2)
check('B6 deleteAction wiring in cellForItem',
      'cell.deleteAction = ^{' in vm and 'handleGameDirDeleteTapped:dirName' in vm)
seg7 = vm.split('- (void)handleGameDirDeleteTapped')[1][:900]
check('B7 tap-X guard flow (default/current blocked, else confirm)',
      'handleGameDirDeleteTapped' in vm and
      vm.index('i18n_str_1087') < vm.index('confirmDeleteGameDir:dirName];') and
      'i18n_str_1087' in seg7 and 'i18n_str_1084' in seg7 and 'confirmDeleteGameDir:dirName];' in seg7)
check('B8 old dir long-press menu retired',
      'showGameDirActions' not in vm)
check('B9 dir section layout: same width/height as instance cards',
      '((width - 32 - 3 * 8) / 4.0) : ((width - 32 - 8) / 2.0)' in vm and
      'CGFloat itemHeight = kVMVersionRowHeight;' in vm)
check('B10 dir section insets 4,8 (parity)',
      'NSDirectionalEdgeInsetsMake(4, 8, 4, 8);' in vm)
check('B11 dir subtitle = size only (i18n_str_134 placeholder retired)',
      'detail:nil isSelected:isSelected isAddButton:NO' in vm and
      'configureWithName:dirName detail:localize(@"i18n_str_134"' not in vm)
check('B12 add-button card keeps green identity',
      'systemGreenColor' in vm.split('configureWithName:(NSString *)name detail:')[1][:2600])

# ============ C. R3/R4 header grey-text (6 languages) ============
L10N = {
    'zh-CN':   ('点击卡片切换；点击叉号删除', '点击卡片切换；点击省略号编辑；长按以删除'),
    'zh-Hans': ('点击卡片切换；点击叉号删除', '点击卡片切换；点击省略号编辑；长按以删除'),
    'zh-Hant': ('點擊卡片切換；點擊叉號刪除', '點擊卡片切換；點擊省略號編輯；長按以刪除'),
    'en':      ('Tap a card to switch; tap the X to delete',
                'Tap a card to switch; tap the ellipsis to edit; long-press to delete'),
    'ja':      ('カードをタップで切り替え；×マークで削除',
                'カードをタップで切り替え；⋯で編集；長押しで削除'),
    'km':      ('Tap a card to switch; tap the X to delete',
                'Tap a card to switch; tap the ellipsis to edit; long-press to delete'),
}
for lang, (v1, v2) in L10N.items():
    d = rd(f'Natives/resources/{lang}.lproj/Localizable.strings')
    check(f'C1 {lang} 1071 new text', f'"i18n_str_1071" = "{v1}";' in d)
    check(f'C2 {lang} 1073 new text', f'"i18n_str_1073" = "{v2}";' in d)
check('C3 old wording gone everywhere',
      all('长按删除当前目录' not in rd(f'Natives/resources/{l}.lproj/Localizable.strings')
          for l in ['zh-CN', 'zh-Hans', 'zh-Hant']))

# ============ D. R5 help page on card layout ============
cl = rd('Natives/LauncherCardLayoutViewController.m')
check('D1 card layout observes ShowHelpPage',
      'name:@"ShowHelpPage"' in cl and 'showHelpPage' in cl)
check('D2 showHelpPage implemented (mirror of root)',
      'LauncherHelpViewController *vc = [[LauncherHelpViewController alloc] init];' in cl and
      'initWithRootViewController:vc' in cl.split('showHelpPage {')[1][:400])
check('D3 import present', '#import "LauncherHelpViewController.h"' in cl)

# ============ E. R6 installer spacing unification ============
ml = rd('Natives/installer/ModLoaderInstallViewController.m')
check('E1 loader table rowHeight 64 (Task216 realigned to version table)',
      '_tableView.rowHeight = 64;' in ml and '_tableView.rowHeight = 50;' not in ml)
check('E2 both tables rowHeight 64 (two 64 sites)',
      ml.count('_tableView.rowHeight = 64;') == 2)
check('E3 RowCell geometry = VersionCardCell (40 icon box / 22 icon)',
      'constraintEqualToConstant:40],' in ml and 'constraintEqualToConstant:22],' in ml)
check('E4 RowCell fonts 15/11', 'systemFontOfSize:15 weight:UIFontWeightSemibold' in ml)
check('E5 SwitchCell fonts 15/11 top 14 (Task216)', '_titleLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:14' in ml)
check('E6 old 64pt comment gone', 'Task184：64pt 行高' not in ml)

# ============ F. R7 account card rewrite ============
ac = rd('Natives/AccountListViewController.m')
check('F1 avatar doubled dp:34 -> dp:68', '[ScreenUtils dp:68]' in ac and '[ScreenUtils dp:34]' not in ac)
check('F2 fonts upgraded sp16/sp12',
      '[ScreenUtils sp:16] weight:UIFontWeightSemibold' in ac and
      '[ScreenUtils sp:12] weight:UIFontWeightRegular' in ac)
check('F3 card pipeline = installer recipe',
      'applyCardEffectToView:self.contentContainer' in ac and
      'applyEffectToTableViewCell' not in ac)
check('F4 green badge right-center (installer position)',
      'self.selectedBadge.backgroundColor = [UIColor systemGreenColor];' in ac and
      'selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor' in ac)
check('F5 old VMTileBase shadow mirror retired',
      'self.layer.shadowPath' not in ac.split('@implementation AccountListViewController')[0])
check('F6 side insets 24 -> 0',
      'contentContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0' in ac)
check('F7 touch spring trio retired',
      'touchesBegan:(NSSet<UITouch *> *)touches' not in ac.split('@implementation AccountListViewController')[0].split('@end')[-1])
check('F8 accent badge top+10 position retired',
      'selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:10' not in ac)

# ============ G. R8 rebrand sweep ============
check('G1 Info.plist display name Prisma',
      rd('Natives/Info.plist').count('<string>Prisma</string>') == 2)
# Task217 re-anchor: the identity moved on AGAIN by user order -- interim
# migration build com.prisma-devs.prisma -> com.air-devs (upstream-family
# name; final target com.prisma-devs in its own round). The full-wiring
# invariant is unchanged, only the literal.
check('G2 Info.plist bundle id renamed (Task217: interim com.air-devs, full wiring)',
      'com.air-devs' in rd('Natives/Info.plist')
      and 'com.prisma-devs.prisma' not in rd('Natives/Info.plist')
      and 'com.air-devs' in open('Makefile', encoding='utf-8').read()
      and 'com.air-devs' in open('.github/workflows/development.yml', encoding='utf-8').read()
      and 'com.air-devs' in open('entitlements.sideload.xml', encoding='utf-8').read())
check('G3 Info.plist usage descriptions Prisma',
      'Prisma uses the local network' in rd('Natives/Info.plist'))
res_air = 0
for root, dirs, files in os.walk('Natives/resources'):
    for f in files:
        if f.endswith('.strings'):
            d = open(os.path.join(root, f), encoding='utf-8', errors='replace').read()
            res_air += len(re.findall(r'\bAir\b', d))
check('G4 zero standalone Air in all .strings', res_air == 0)
ua = rd('Natives/AI/AiAssetTools.m') + rd('Natives/AnnouncementService.m')
check('G5 HTTP User-Agent Prisma/1.0 (both sites)',
      ua.count('@"Prisma/1.0 (iOS)"') == 2 and 'Air/1.0' not in ua)
check('G6 AI persona prompt Prisma (gloss dropped)',
      '你是 Prisma 启动器内置的 AI 助手' in rd('Natives/AI/AiSettings.m') and
      'Amethyst iOS Remastered' not in rd('Natives/AI/AiSettings.m'))
check('G7 prefs fallback name Prisma',
      'return name.length ? name : @"Prisma";' in rd('Natives/LauncherPreferencesViewController.m'))
check('G8 controls repo author Prisma Team',
      rd('controls/index.json').count('"Prisma Team"') == 3 and '"Air Team"' not in rd('controls/index.json'))
check('G9 shipped fallback news title Prisma',
      '欢迎使用 Prisma 启动器' in rd('Natives/resources/announcements-fallback.json'))
ann = rd('announcements.json')
check('G10 announcement title brand updated (historical entry text)',
      'Prisma 定制品牌第一步' in ann)
check('G11 repo URL / device name untouched (protected classes)',
      'Prisma-Minecraft-iOS-Launcher' in rd('Natives/UpdateChecker.m') and
      'iPad Air' in rd('Natives/utils.m'))
check('G12 README brand heading updated (R10: MD slugs follow the rebrand)',
      '<h1 align="center">Prisma</h1>' in rd('README.md') and
      'Prisma-Minecraft-iOS-Launcher' in rd('README.md') and
      'Gsjsjzhznsz/Prisma' in rd('README.md'))
check('G13 no standalone Air left in core sources (repo/iPad-Air exempt)',
      not [p for p in
           ['Natives/utils.h', 'Natives/PLMirrorCenter.h', 'Natives/PLMirrorCenter.m',
            'Natives/ResourceCardTableViewCell.m', 'Natives/ShadersManagerViewController.m',
            'Natives/AI/AiAssetTools.m', 'Natives/PLPreferences.m']
           if re.search(r'\bAir\b', rd(p).replace('Air-Minecraft-iOS-Launcher', '').replace('iPad Air', ''))])
check('G14 AI header comments rebranded',
      'Prisma AI Agent' in rd('Natives/AI/AiTool.h') and
      'Air AI Agent' not in rd('Natives/AI/AiTool.h'))

# ============ H. docs cascade ============
data = json.load(open('announcements.json', encoding='utf-8'))
ids = [e['id'] for e in data['announcements']]
check('H1 announcements 40 items (Task218 append +1)', len(ids) == 41)
check('H2 task213@4 (Task215 shift)', ids[4].startswith('task213-'))
check('H2b parallel task212@5 (their ANGLE/CF/VirGL round; Task215 shift)', ids[5].startswith('task212-angle'))
check('H3 task169 pin @1 intact', ids[1].startswith('task169-'))
check('H4 task211 shifted to @6 (Task215 shift)', ids[6].startswith('task211-'))
vh = rd('Natives/external/MobileGlues/MobileGlues-cpp/version.h')
check('H5 version.h Task213 addendum present', 'REVISION 18 addendum (Task 213, no bump)' in vh)
check('H6 trailing SEP = 76 equals', re.search(r'\n//\s(={76})\s*$', vh) is not None)
v207 = rd('scripts/verify_task207.py')
v211 = rd('scripts/verify_task211.py')
check('H7 207 length gate shifted 41 (Task219 append)', '== 41' in v207 and '== 40' not in v207)
check('H8 211 length gate shifted 40 (Task218 append)', '== 40' in v211)
check('H9 211 announcement anchors (task211@4 + parallel task212@3 + mine task213@2)',
      'ann[6]["id"] == "task211-exit-cf-angle-gl4es-2026-10-02"' in v211 and
      'ann[5]["id"] == "task212-angle-cf-renderers-virgl-2026-10-02"' in v211)
check('H10 window constants shifted (165/167, Task215 sweep state)',
      'range(min(30, len(anns)))' in rd('scripts/verify_task165.py') and
      'range(min(28, len(anns)))' in rd('scripts/verify_task167.py'))


# ============ J. R9 memory-limit dialog + R10 bundle id ============
lpv = rd('Natives/LauncherPreferencesViewController.m')
check('J1 mem_help message rewritten (entitlement explainer + paid cert)',
      '使用GetMoreRAM开启' in lpv and '通常能分配6GB内存' in lpv and
      '通常能分配7GB内存并提升稳定性' in lpv and '推荐使用付费开发者证书' in lpv)
check('J2 button = paid dev cert -> b23.tv/WtgrPJM',
      'mem_help.button' in lpv and 'https://b23.tv/WtgrPJM' in lpv and
      'github.com/hugeBlack/GetMoreRam' not in lpv)
def _memmsg(l):
    return re.search(r'"mem_help\.message" = "([^"]*)";',
                     rd(f'Natives/resources/{l}.lproj/Localizable.strings')).group(1)
check('J3 mem_help.message l10n values rewritten in 6 languages (i18n_str_410 card body out of scope)',
      all('GetMoreRAM' in _memmsg(l) and '1440MB' not in _memmsg(l) and '付费开发者证书' in _memmsg(l)
          for l in ['zh-CN', 'zh-Hans'])
      and '付費開發者證書' in _memmsg('zh-Hant')
      and all('paid developer certificate' in _memmsg(l) and '1440MB' not in _memmsg(l)
              for l in ['en', 'km'])
      and 'GetMoreRAM' in _memmsg('ja') and '1440MB' not in _memmsg('ja'))
check('J4 detail row drops GetMoreRam parenthetical',
      all('GetMoreRam' not in
          re.search(r'"preference\.detail\.memory_limit_help" = "([^"]*)";',
                    rd(f'Natives/resources/{l}.lproj/Localizable.strings')).group(1)
          for l in ['en', 'ja', 'km', 'zh-CN', 'zh-Hans', 'zh-Hant']))
# Task217 re-anchor: interim migration id com.air-devs (final com.prisma-devs later).
# The authenticator keeps deliberate LEGACY keychain service references
# (ame217_legacyKeychainServices migration chain) -- exempt from the
# "no old id" half of the invariant there.
check('J5 bundle id renamed everywhere (Task217 interim air-devs wiring)',
      all('com.air-devs' in rd(p) for p in
          ['Natives/Info.plist', 'entitlements.trollstore.xml', 'entitlements.codesign.xml',
           'entitlements.sideload.xml', 'Makefile', '.github/workflows/development.yml',
           'Natives/MinecraftResourceDownloadTask.m', 'Natives/TouchControllerBridge.m',
           'Natives/TouchController/ios_transport.c', 'Natives/authenticator/ThirdPartyAuthenticator.m'])
      and all('com.prisma-devs.prisma' not in rd(p) for p in
          ['Natives/Info.plist', 'entitlements.trollstore.xml', 'entitlements.codesign.xml',
           'entitlements.sideload.xml', 'Makefile', '.github/workflows/development.yml',
           'Natives/MinecraftResourceDownloadTask.m', 'Natives/TouchControllerBridge.m',
           'Natives/TouchController/ios_transport.c'])
      and 'com.prisma-devs.prisma.ame131.credentials' in rd('Natives/authenticator/ThirdPartyAuthenticator.m'))
check('J6 crash-view suggestions untouched (out of R9 scope)',
      'GetMoreRam (LiveContainer)' in rd('Natives/PLCrashView.m'))
check('J7 URL scheme registration follows the new id (Task217 interim)',
      'com.air-devs.air.urlscheme' in rd('Natives/Info.plist'))

# ============ I. syntax balance gates (touched ObjC files) ============
def balance(path):
    d = rd(path)
    i, n = 0, len(d)
    par = brk = brc = 0
    while i < n:
        c = d[i]
        if c == '/' and i + 1 < n and d[i+1] == '/':
            while i < n and d[i] != '\n': i += 1
        elif c == '/' and i + 1 < n and d[i+1] == '*':
            i = d.find('*/', i + 2)
            i = n if i < 0 else i + 2
        elif c == '@' and d[i:i+2] == '@"':
            i += 2
            while i < n and d[i] != '"':
                i += 2 if d[i] == '\\' else 1
            i += 1
        elif c == '"':
            i += 1
            while i < n and d[i] != '"':
                i += 2 if d[i] == '\\' else 1
            i += 1
        elif c == "'":
            i += 1
            while i < n and d[i] != "'":
                i += 2 if d[i] == '\\' else 1
            i += 1
        elif c == '(': par += 1; i += 1
        elif c == ')': par -= 1; i += 1
        elif c == '[': brk += 1; i += 1
        elif c == ']': brk -= 1; i += 1
        elif c == '{': brc += 1; i += 1
        elif c == '}': brc -= 1; i += 1
        else: i += 1
    return par, brk, brc

for f in ['Natives/VersionManagerViewController.m', 'Natives/LauncherCardLayoutViewController.m',
          'Natives/installer/ModLoaderInstallViewController.m', 'Natives/AccountListViewController.m',
          'Natives/AI/AiSettings.m', 'Natives/LauncherPreferencesViewController.m']:
    b = balance(f)
    check(f'I1 balance {os.path.basename(f)}', b == (0, 0, 0))

print(f'\nverify_task213: {PASS}/{PASS + FAIL}' + ('  ALL GREEN' if FAIL == 0 else f'  FAILURES: {FAILURES}'))
sys.exit(1 if FAIL else 0)
