#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task180.py -- Task 180 交付校验（Task184 诚实重锚版）
Task 180 原始交付：两滑条透明度体系（背景/按钮）+ 账号列表新拟态重写
+ 复制bug双保险 + 头像防御性修 + 安装方式页对齐版本卡 + 全局默认值定稿。

Task184 重锚说明（用户裁决"先撤销180task的UI效果调整，先修好这两样"）：
  - 180 的双滑条透明度体系（backgroundOpacity/buttonOpacity + 引擎 opacity
    变体 + 20+ 接线）被整体撤销，回归 uiOpacity/cardsNeumorphOpacity 单键
    时代（= Task178/179 形态）。本文件 A~F 组相应翻转为"回退态"断言。
  - 180 的功能修复（账号复制双保险 / 头像防御 / 账号列表凸起重写 / 模糊外
    的默认值 card/dark）全部保留，断言原样。
  - 180 的"安装方式页对齐版本卡"由 Task184 以 VersionCardCell 同构配方
    真正落地（内层 cardContainer + 系统白底清除），G 组安装页断言重锚到
    新配方；细节断言由 verify_task183.py 承担。
"""
import io, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
N = os.path.join(ROOT, 'Natives')
PASS, FAIL = [], []

def check(group, name, cond, detail=''):
    (PASS if cond else FAIL).append(f'[{group}] {name}' + (f' -- {detail}' if detail and not cond else ''))

def rd(p):
    return io.open(os.path.join(N, p), encoding='utf-8').read()

# ============ A. 引擎层（UIKit+NativeSurface）——183 撤销 opacity 变体 ============
h = rd('UIKit+NativeSurface.h'); m = rd('UIKit+NativeSurface.m')
check('A', 'Flat/Panel opacity 变体 .h 声明退役', 'opacity:(CGFloat)opacity;' not in h)
check('A', 'Flat opacity .m 实现退役', 'cornerRadius opacity:(CGFloat)opacity {' not in m)
check('A', 'Task210：旧 Flat 实现零残留（ame_applyNeumorphSurfaceFlatWithRadius 退役）', 'ame_applyNeumorphSurfaceFlatWithRadius' not in m)
check('A', 'Task210：平贴灰面身份色接棒（AmeCardSurfaceColor 在位）', 'UIColor *AmeCardSurfaceColor(void)' in m)
check('A', '无 opacity 内部 colorWithAlphaComponent:o', 'colorWithAlphaComponent:o' not in m)
check('A', 'Task210：opacity clamp 全域零残留（卡体透明度原语随退役删除）', 'MAX(0.0, MIN(1.0, opacity))' not in m and 'CGFloat o = MAX(0.0, MIN(1.0, opacity));' not in m)
check('A', 'Task210：Panel 单签名转发 Card 平贴版', '[self ame_applyCardSurfaceWithRadius:cornerRadius];' in m)
check('A', 'Task210：ame_applyNeumorphSurface 声明退役（注释留档不计）', 'ame_applyNeumorphSurface' not in '\n'.join(l.split('//')[0] for l in h.split('\n')))
check('A', 'Task210：卡体透明度原语声明退役（注释留档不计）', 'ame_applyNeumorphCardOpacity' not in '\n'.join(l.split('//')[0] for l in h.split('\n')))
check('A', 'Task210：圆角钉住原语声明退役（注释留档不计）', 'ame_setNeumorphPinnedCornerRadius' not in '\n'.join(l.split('//')[0] for l in h.split('\n')))

# ============ B. BackgroundManager——183 回归 uiOpacity/cardsNeumorphOpacity ============
bm = rd('BackgroundManager.m'); bh = rd('BackgroundManager.h')
check('B', '新键 background_bg_opacity 退役', 'background_bg_opacity' not in bm)
check('B', '新键 background_btn_opacity 退役', 'background_btn_opacity' not in bm)
check('B', '旧键 background_ui_opacity 回归', 'kBackgroundUIOpacityKey = @"background_ui_opacity"' in bm)
check('B', 'Task210：旧键 background_cards_neumorph_opacity 随退役删除', 'kBackgroundCardsNeumorphOpacityKey' not in bm)
check('B', '默认透明度 1.0（Task216 用户定稿）', '_uiOpacity = 1.0;' in bm)
check('B', '默认模糊 0.75（Task216 用户定稿）', '_blurIntensity = 0.75;' in bm)
check('B', 'uiOpacity 下限 0.1 回归', '_uiOpacity = MAX(0.1, MIN(1.0, uiOpacity));' in bm)
check('B', '.h 属性 uiOpacity 回归', '@property (nonatomic, assign) CGFloat uiOpacity;' in bh)
check('B', 'Task210：.h 属性 cardsNeumorphOpacity 随退役删除（注释留档不计）', 'cardsNeumorphOpacity' not in '\n'.join(l.split('//')[0] for l in bh.split('\n')))
check('B', '新属性 backgroundOpacity/buttonOpacity 退役', 'CGFloat backgroundOpacity;' not in bh and 'CGFloat buttonOpacity;' not in bh)
check('B', 'Task210：挂点①（泛型管线 ON 分支）随退役删除', '[target ame_applyNeumorphCardOpacity' not in bm)
check('B', 'Task210：挂点②（applyCardEffectToView ON 分支）随退役删除', '[view ame_applyNeumorphCardOpacity' not in bm)
check('B', 'makeViewControllerTransparent 读 uiOpacity（Task216 重锚：正向语义，驼峰根除）',
      'viewController.view.backgroundColor = [base colorWithAlphaComponent:self.uiOpacity];' in bm)
check('B', 'applyEffectToCell 半透明档读 uiOpacity', bm.count('colorWithWhite:0.1 alpha:self.uiOpacity]') >= 2)
check('B', 'Task210：applyEffectToView 无壁纸 = 平贴灰面（AmeCardSurfaceColor）', 'view.backgroundColor = AmeCardSurfaceColor();' in bm)
check('B', 'Task210：applyCardEffectToCell 直转 applyEffectToCell（Flat 特调行退役）', '[cell.contentView ame_applyNeumorphSurfaceFlatWithRadius:12];' not in bm and '[self applyEffectToCell:cell];' in bm)
check('B', '导航栏/工具栏读 uiOpacity', bm.count('colorWithWhite:0.1 alpha:self.uiOpacity]') >= 4)
check('B', 'searchBar 输入框读 uiOpacity', 'colorWithAlphaComponent:MAX(0.3, self.uiOpacity)]' in bm)
check('B', 'saveUISettings 落盘旧键', 'setFloat:self.uiOpacity forKey:kBackgroundUIOpacityKey]' in bm)
check('B', 'loadUISettings 读旧键', '[defaults objectForKey:kBackgroundUIOpacityKey]' in bm)

# ============ C. 设置页——183 回归 透明度 + 新拟态透明度 双行（Task178 形态） ============
st = rd('BackgroundSettingsViewController.m')
check('C', 'Task210：sections[0] 无 neumorph 键（退役）', 'background.cards.neumorph' not in st)
check('C', 'sections[0] 无 button.opacity', 'background.button.opacity.title' not in st)
check('C', 'Task210：新拟态滑条 tags 500/501/502 随行退役', 'slider.tag = 500;' not in st and 'viewWithTag:501]' not in st and 'viewWithTag:502]' not in st)
check('C', '无按钮滑条 tags 600/601/602', 'slider.tag = 600;' not in st and 'viewWithTag:601]' not in st)
check('C', 'Task210：cardsNeumorphOpacitySliderChanged 回调随行退役', 'cardsNeumorphOpacitySliderChanged' not in st)
check('C', 'Task210：新拟态滑条写点随行退役', 'cardsNeumorphOpacity = slider.value' not in st)
check('C', '透明度滑条写 uiOpacity', '[BackgroundManager sharedManager].uiOpacity = value;' in st)
check('C', 'Task210：新拟态滑条值读点随行退役', 'slider.value = manager.cardsNeumorphOpacity;' not in st)
check('C', 'ButtonOpacityCell 标识退役', '@"ButtonOpacityCell"' not in st)
check('C', 'Task210：无壁纸 section0 = 0 行（整段隐藏）', 'return 0;' in st and 'hasBackground ? 4 : 1]' not in st)
check('C', '恢复默认按钮不再写 0.75/1.0 双键', 'manager.backgroundOpacity = 0.75;' not in st and 'manager.buttonOpacity = 1.0;' not in st)
check('C', '恢复默认写新出厂默认（Task216：1.0/0.75/毛玻璃）', 'manager.uiOpacity = 1.0;' in st and 'manager.blurIntensity = 0.75;' in st and 'manager.uiEffect = BackgroundUIEffectBlur;' in st)
check('C', 'Task210：新拟态开关行随退役删除（tag 410 零残留）', 'neumorphSwitch.tag = 410;' not in st)

# ============ D. l10n（×6 语言 + 计数 2228 保持；183 回退键集） ============
RES = os.path.join(N, 'resources')
for lang, expect_1296 in [
    ('en', 'Opacity'),
    ('zh-Hans', '透明度'),
    ('zh-CN', '透明度'),
    ('zh-Hant', '透明度'),
    ('ja', 'Opacity'),
    ('km', 'Opacity'),
]:
    s = io.open(os.path.join(RES, f'{lang}.lproj/Localizable.strings'), encoding='utf-8').read()
    keys = set(re.findall(r'^"([^"]+)" =', s, re.M))
    check('D', f'{lang} 1296 回归旧值', f'"i18n_str_1296" = "{expect_1296}";' in s)
    check('D', f'{lang} button.opacity 键退役', 'background.button.opacity.title' not in keys)
    check('D', f'{lang} Task210：neumorph.opacity 键随退役删除', 'background.cards.neumorph.opacity.title' not in keys)
    check('D', f'{lang} 无 180 背景透明度字样', '背景透明度' not in s and 'Background Opacity' not in s)
tot = None
for lang in ['en', 'zh-Hans', 'zh-CN', 'zh-Hant']:
    s = io.open(os.path.join(RES, f'{lang}.lproj/Localizable.strings'), encoding='utf-8').read()
    keys = set(re.findall(r'^"([^"]+)" =', s, re.M))
    tot = len(keys) if tot is None else tot
    check('D', f'{lang} 唯一键总数 == 2520', len(keys) == 2520, f'got {len(keys)}')

# ============ E. 按钮接线——183 撤销（回归恒定底色）+ 头像防御保留 ============
rp = rd('LauncherRightPanelViewController.m')
check('E', '启动/执行Jar/选择版本 回归恒定 accentColor', rp.count('self.launchButton.backgroundColor = accentColor();') == 2 and 'btnO' not in rp)
check('E', '下载中心按钮回归语义色', 'self.downloadCenterButton.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];' in rp)
check('E', '信息卡回归 0.15 恒定淡底', 'card.backgroundColor = [accent colorWithAlphaComponent:0.15];' in rp)
check('E', 'RightPanel reapply 不再重刷按钮', '[self applyCustomAppearance];' not in rp.split('reapplyBackgroundEffect')[1].split('}')[0] if 'reapplyBackgroundEffect' in rp else False)
mn = rd('LauncherMenuViewController.m')
check('E', '菜单按钮选中底回归恒定 0.15 淡底', '0.15 * [BackgroundManager sharedManager].buttonOpacity' not in mn)
check('E', 'Menu reapply 重刷退役（180 挂点撤销，Task138 原有两个调用保留）', mn.count('[self updateButtonColors];') == 2)
dl = rd('DownloadViewController.m')
check('E', 'importModpack 回归恒定紫底', 'systemPurpleColor]\n        colorWithAlphaComponent:[BackgroundManager sharedManager].buttonOpacity];' not in dl)
check('E', '侧栏筛选/重置按钮回归恒定底', 'tertiarySystemFillColor]\n        colorWithAlphaComponent:[BackgroundManager sharedManager].buttonOpacity];' not in dl)
check('E', 'handleBackgroundUIEffectChanged 不再刷按钮透明度', 'btnO' not in dl)
nt = rd('NMToast.m')
check('E', 'NMToast 不再接按钮透明度', 'buttonOpacity' not in nt)
pc = rd('PLCrashView.m')
check('E', '崩溃窗 ame180_buttonColor 辅助退役', 'ame180_buttonColor' not in pc)

# ============ F. 大背景接线——183 撤销（回归 179 形态） ============
rt = rd('LauncherRootViewController.m')
check('F', 'Root 侧栏/右面板回归单签名 Panel', rt.count('[self.sidebarContainer ame_applyPanelSurfaceWithRadius:16];') == 1 and rt.count('[self.rightPanelContainer ame_applyPanelSurfaceWithRadius:16];') == 1)
check('F', 'Root 无 bgOpacity 残留', 'bgOpacity' not in rt)
bg = rd('BingWallpaperGalleryViewController.m')
check('F', '壁纸选择页不再接背景透明度', 'backgroundOpacity' not in bg)
tv = rd('DownloadTasksViewController.m')
check('F', '下载中心弹窗不再接背景透明度', 'backgroundOpacity' not in tv)
check('F', '下载页 tabSegment 回归恒定底', 'self.tabSegment.backgroundColor = [[UIColor systemBackgroundColor]\n        colorWithAlphaComponent:[BackgroundManager sharedManager].backgroundOpacity];' not in dl)
check('F', '下载页搜索栏 180 接线退役（pre-180 无此调用）', 'applyEffectToSearchBar' not in dl)
check('F', '胶囊轨道回归恒定底', 'tertiarySystemFillColor]\n        colorWithAlphaComponent:[BackgroundManager sharedManager].backgroundOpacity];' not in dl)
ps = rd('ProfileSettingsViewController.m')
check('F', '实例页 blurView 回归（不接透明度）', 'backgroundOpacity' not in ps)

# ============ G. 账号/头像/安装页（180 功能修复保留 + 183 安装页新配方重锚） ============
ac = rd('AccountListViewController.m')
# Task190 重锚：用户定稿账号卡与已安装版本页同构（AME190AccountCardCell）——
# 180 的内联卡（cardView + 凸起管线直挂 + 钉 16 + 自绘阴影退役断言）整体被
# 同构卡替代：管线换 Task172 三段式泛型入口 applyEffectToTableViewCell，卡面
# 规格移交 VMTileBaseCell 镜像（12pt 连续圆角 + 0.12/6 阴影 + shadowPath）。
check('G', '账号 cell 卡面管线（Task212 重锚：同构卡走安装器 applyCardEffectToView 调用）',
      '[[BackgroundManager sharedManager] applyCardEffectToView:self.contentContainer];' in ac)
check('G', '账号 cell 引擎符号/引擎头配对（Task213 hotfix 重锚：卡列表启用 AmeNeumorph 色族后按 Task180 教训带引擎头 import，Task214 顺手对齐断言语义）',
      '#import "UIKit+NativeSurface.h"' in ac
      or 'ame_setNeumorphPinnedCornerRadius' not in ac)
check('G', '账号 cell 同构卡规格（Task212 重锚：12pt 连续圆角 + 安装器无阴影平贴）',
      'self.contentContainer.layer.cornerRadius = 12;' in ac
      and 'self.layer.shadowOpacity' not in ac.split('@implementation AccountListViewController')[0]
      and 'applyCardEffectToView' in ac)
check('G', '账号 cell 裁剪放行（保留）', 'self.contentView.layer.masksToBounds = NO;' in ac)
check('G', '账号 cell 无旧内联卡残留（cardView/钉 16/白 0.10 零出现）',
      'cardView' not in ac and 'ame_setNeumorphPinnedCornerRadius' not in ac)
check('G', 'reloadAccountList 去重（180 双保险保留）', 'ame180_seenIds' in ac and 'dedup account entry by id' in ac)
check('G', 'reloadAccountList 过滤坏文件（180 双保险保留）', 'NSErrorObject' in ac and 'skipping unreadable account file' in ac)
ba = rd('authenticator/BaseAuthenticator.m')
check('G', 'saveChanges 漂移感知属性（180 保留）', 'ame180_savedAccountId' in ba)
check('G', '写盘成功后清理旧文件（180 保留）', 'account file migrated after accountId drift' in ba)
check('G', '写盘收口迁移头像（180 保留）', 'ame180_migrateAvatarFromAccount:ame180_old' in ba)
am = rd('AvatarManager.m')
check('G', 'username 回退查询（180 保留）', 'avatarForAccount:(NSString *)accountName\n             usernameFallback:(NSString *)username {' in am)
check('G', '头像迁移原语（180 保留）', 'ame180_migrateAvatarFromAccount:(NSString *)oldAccount' in am)
check('G', 'RightPanel username 回退调用（183 补挂点保留）', 'usernameFallback:currentAuth.authData[@"username"]' in rp)
nw = rd('LauncherNewsViewController.m')
check('G', '主页 username 回退调用（183 补挂点保留）', 'usernameFallback:auth.authData[@"username"]' in nw)
check('G', 'RightPanel fetch 失败日志锚（180 保留）', ('[Task180] RightPanel avatar fetch failed' in rp) or ('[Task180] RightPanel avatar chain exhausted' in rp))  # Task185 重锚：单 URL 拉取升级为三层回退链
ml = rd('installer/ModLoaderInstallViewController.m')
check('G', '安装页凸起管线 ×3（Task210 重锚：applyCardEffectToView 内层 cardContainer init 挂载）', ml.count("[[BackgroundManager sharedManager] applyCardEffectToView:_cardContainer];") == 3)
check('G', '安装页 contentView 直挂退役（183 重锚）', 'applyNeumorphCardEffectToView:cell.contentView];' not in ml)
check('G', '安装页逐帧 applyEffectToCell 退役（183 重锚）', 'applyEffectToCell:cell];' not in ml)
check('G', '安装页系统白底清除辅助（183 新配方）', 'AME184ClearTableViewCellChrome' in ml and 'cell.backgroundView = clearBg;' in ml)
check('G', '安装页选中高亮清除（183 新配方）', 'cell.selectedBackgroundView = clearSel;' in ml)
check('G', '安装页内层容器圆角 12 continuous（183 同构版本卡）', ml.count('_cardContainer.layer.cornerRadius = 12;') == 3 and ml.count('_cardContainer.layer.cornerCurve = kCACornerCurveContinuous;') == 3)
check('G', '安装页容器上下内缩 4（183 同构版本卡）', ml.count('constraintEqualToAnchor:self.contentView.topAnchor constant:4]') >= 3)
check('G', '安装页 40x40 图标容器（Task216 重锚：对齐版本表 40/10 规格）', 'widthAnchor constraintEqualToConstant:40],' in ml and 'heightAnchor constraintEqualToConstant:40],' in ml)
check('G', '安装页 64 行高（Task216 重锚：对齐版本表真基准）', ml.count('_tableView.rowHeight = 64;') == 2)
check('G', '安装页规格文字色（Task210 重锚：AmeCard 色族，版本卡同款）', ml.count('AmeCardPrimaryTextColor()') >= 3 and ml.count('AmeCardSecondaryTextColor()') >= 3)
check('G', '安装页版本子页 64 行高 + 无分隔线（183/Task216）', '_tableView.rowHeight = 64;' in ml and 'separatorStyle = UITableViewCellSeparatorStyleNone;' in ml)
check('G', '安装页引擎头 import', '#import "../UIKit+NativeSurface.h"' in ml)
sc = rd('SceneDelegate.m')
check('G', '布局默认 card（显式 vs 才三栏；180 默认值保留）', 'if ([layout isEqualToString:@"vs"]) {' in sc)
check('G', '主题迁移目标 auto（Task216 改靶：默认回归跟随系统；显式选择不覆盖）', "setPrefObject(@\"general.ui_theme\", @\"auto\");" in sc)
check('G', 'Layout 注释锚 [Task180]', 'Task180 用户定稿默认 = 卡片式便当盒布局' in sc)

# ============ 汇总 ============
print(f'PASS {len(PASS)}  FAIL {len(FAIL)}')
for f in FAIL:
    print('  FAIL:', f)
sys.exit(1 if FAIL else 0)
