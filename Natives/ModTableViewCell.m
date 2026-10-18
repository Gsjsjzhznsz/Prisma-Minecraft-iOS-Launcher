//
//  ModTableViewCell.m
//  Amethyst
//
//  Mod 卡片 Cell 实现（继承 ResourceCardTableViewCell）。
//  卡片三层背景 / 圆角 / 阴影 / 选中态视觉由基类提供，
//  本类仅补充 Mod 专属内容：图标（jar 内嵌 > 加载器品牌 > 语义色回退）、
//  文字三行（名称 / 文件名 / 版本·游戏版本）、启用开关与在线模式按钮。
//

#import "ModTableViewCell.h"
#import "ModItem.h"
#import "ModService.h"
#import "ModLoaderIconHelper.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import <QuartzCore/QuartzCore.h>

@interface ModTableViewCell ()
// 当前配置的 Mod 与显示模式（外观变化时用于重新加载图标）
@property (nonatomic, strong, nullable) ModItem *currentMod;
@property (nonatomic, assign) ModTableViewCellDisplayMode currentMode;
// 在线模式专属 accessory（懒加载，本地列表不创建）
@property (nonatomic, strong, nullable) UIButton *downloadButton;
@property (nonatomic, strong, nullable) UIButton *openLinkButton;
// ★ Task288：加载器错配警告徽章（懒加载，accessory 插槽 stack 自动收起隐藏项）
@property (nonatomic, strong, nullable) UIImageView *loaderBadge;
@end

@implementation ModTableViewCell

#pragma mark - Init

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // 触发基类懒加载创建启用开关插槽并绑定事件（本地模式显示）
        [self.toggleSwitch addTarget:self action:@selector(toggleTapped) forControlEvents:UIControlEventValueChanged];
    }
    return self;
}

#pragma mark - Configuration

- (void)configureWithMod:(ModItem *)mod displayMode:(ModTableViewCellDisplayMode)mode {
    self.currentMod = mod;
    self.currentMode = mode;

    [self configureIconForMod:mod];

    // 主标题：显示名（回退文件名）
    self.nameLabel.text = mod.displayName.length > 0 ? mod.displayName
                       : (mod.fileName.length > 0 ? mod.fileName : mod.basename);

    if (mode == ModTableViewCellDisplayModeLocal) {
        [self configureLocalContent:mod];
    } else {
        [self configureOnlineContent:mod];
    }
}

/// 配置左侧图标：
/// jar 内嵌图标 > 加载器品牌图标（PNG/SF Symbol，ModLoaderIconHelper 统一）> puzzlepiece 回退
/// 图标容器背景使用加载器品牌色（无加载器信息时用 Mod 语义色橙色）
- (void)configureIconForMod:(ModItem *)mod {
    NSString *loaderName = nil;
    if (mod.isFabric) {
        loaderName = @"fabric";
    } else if (mod.isForge) {
        loaderName = @"forge";
    } else if (mod.isNeoForge) {
        loaderName = @"neoforge";
    }

    UIColor *brandColor = loaderName ? [ModLoaderIconHelper brandColorForLoader:loaderName] : nil;
    self.iconContainer.backgroundColor = brandColor ?: [UIColor systemOrangeColor];

    if (mod.icon) {
        // 本地已解析的 jar 内嵌图标（pack.png 等）：直接显示，不做着色
        self.iconImageView.image = mod.icon;
        self.iconImageView.tintColor = nil;
        return;
    }

    if (loaderName) {
        // 加载器品牌图标：PNG 优先（保持原色），SF Symbol 回退（品牌色着色）
        [ModLoaderIconHelper configureImageView:self.iconImageView
                                      forLoader:loaderName
                              traitCollection:self.traitCollection];
    } else {
        self.iconImageView.image = nil;
    }
    // 无图标可用时的语义色回退（容器内 SF Symbol，非裸图标）
    if (!self.iconImageView.image) {
        self.iconImageView.image = [UIImage systemImageNamed:@"puzzlepiece.extension.fill"];
        self.iconImageView.tintColor = [UIColor whiteColor];
    }
}

/// 本地模式：副标题 = 文件名，元信息 = 版本 · 游戏版本，右侧 = 启用开关
- (void)configureLocalContent:(ModItem *)mod {
    self.subtitleLabel.text = mod.fileName.length > 0 ? mod.fileName : mod.basename;
    self.subtitleLabel.hidden = (self.subtitleLabel.text.length == 0);

    // 版本信息行：v版本 · MC 游戏版本（两者都缺省时隐藏）
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (mod.version.length > 0) [parts addObject:[NSString stringWithFormat:@"v%@", mod.version]];
    if (mod.gameVersion.length > 0) [parts addObject:[NSString stringWithFormat:@"MC %@", mod.gameVersion]];
    self.detailLabel.text = [parts componentsJoinedByString:@" · "];
    self.detailLabel.hidden = (parts.count == 0);

    // accessory：本地模式只显示启用开关（基类插槽，stack 自动收起隐藏项）
    self.toggleSwitch.hidden = NO;
    if (self.downloadButton) self.downloadButton.hidden = YES;
    if (self.openLinkButton) self.openLinkButton.hidden = YES;
    self.chevronImageView.hidden = YES;

    [self updateToggleState:mod.disabled];
}

/// 在线模式：副标题 = 作者，元信息 = 下载量，右侧 = 链接 + 下载按钮
- (void)configureOnlineContent:(ModItem *)mod {
    self.subtitleLabel.text = [NSString stringWithFormat:@"by %@", mod.author ?: @"Unknown"];

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *downloadsStr = [formatter stringFromNumber:mod.downloads ?: @0];
    self.detailLabel.text = [NSString stringWithFormat:localize(@"resman.mods.download_count", nil), downloadsStr];
    self.detailLabel.hidden = NO;

    // accessory：隐藏开关，显示链接 + 下载
    self.toggleSwitch.hidden = YES;
    self.downloadButton.hidden = NO;
    self.openLinkButton.hidden = NO;
    self.chevronImageView.hidden = YES;

    self.contentView.alpha = 1.0;
}

#pragma mark - Lazy accessory（在线模式专属）

- (UIButton *)downloadButton {
    if (!_downloadButton) {
        _downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_downloadButton setTitle:localize(@"resman.mods.download", nil) forState:UIControlStateNormal];
        // Task137：恢复 Task89 之前的原生下载按钮（accent 底白字 + 胶囊圆角）
        [_downloadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _downloadButton.backgroundColor = accentColor();
        _downloadButton.layer.cornerRadius = 13.0;
        _downloadButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _downloadButton.contentEdgeInsets = UIEdgeInsetsMake(5, 12, 5, 12);
        [_downloadButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_downloadButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_downloadButton addTarget:self action:@selector(downloadTapped) forControlEvents:UIControlEventTouchUpInside];
        _downloadButton.hidden = YES;
        [self.accessoryStack insertArrangedSubview:_downloadButton atIndex:0];
    }
    return _downloadButton;
}

- (UIButton *)openLinkButton {
    if (!_openLinkButton) {
        _openLinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _openLinkButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImage *image = [[UIImage systemImageNamed:@"globe"] imageWithTintColor:[UIColor secondaryLabelColor]];
        [_openLinkButton setImage:image forState:UIControlStateNormal];
        _openLinkButton.contentMode = UIViewContentModeScaleAspectFit;
        [_openLinkButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_openLinkButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_openLinkButton addTarget:self action:@selector(openLinkTapped) forControlEvents:UIControlEventTouchUpInside];
        _openLinkButton.hidden = YES;
        [self.accessoryStack insertArrangedSubview:_openLinkButton atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [_openLinkButton.widthAnchor constraintEqualToConstant:28],
            [_openLinkButton.heightAnchor constraintEqualToConstant:28],
        ]];
    }
    return _openLinkButton;
}

#pragma mark - State Updates

- (void)updateToggleState:(BOOL)disabled {
    [self.toggleSwitch setOn:!disabled animated:YES];
    // 已禁用 Mod 整体降透明度（含文字与图标，与旧版视觉一致）
    self.contentView.alpha = disabled ? 0.6 : 1.0;
}

- (void)setUpdateAvailable:(BOOL)available {
    self.updateBadge.hidden = !available;
}

#pragma mark - Task288：加载器不兼容标记

- (UIImageView *)loaderBadge {
    if (!_loaderBadge) {
        _loaderBadge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.triangle.fill"]];
        _loaderBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _loaderBadge.contentMode = UIViewContentModeScaleAspectFit;
        _loaderBadge.tintColor = [UIColor systemOrangeColor];
        _loaderBadge.hidden = YES;
        [_loaderBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_loaderBadge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.accessoryStack addArrangedSubview:_loaderBadge];
        [NSLayoutConstraint activateConstraints:@[
            [_loaderBadge.widthAnchor constraintEqualToConstant:16],
            [_loaderBadge.heightAnchor constraintEqualToConstant:16],
        ]];
    }
    return _loaderBadge;
}

- (void)setLoaderIncompatibleDetail:(NSString *)detail {
    if (detail.length > 0) {
        // configureWithMod 每次重置 detailLabel 后才走到这里（cellForRow 装配序），
        // 追加安全；无元信息时独占该行。
        if (self.detailLabel.text.length > 0) {
            self.detailLabel.text = [self.detailLabel.text stringByAppendingFormat:@" · %@", detail];
        } else {
            self.detailLabel.text = detail;
        }
        self.detailLabel.hidden = NO;
        self.loaderBadge.hidden = NO;
    } else {
        if (_loaderBadge) _loaderBadge.hidden = YES;
    }
}

#pragma mark - Trait Collection（深浅色切换重载加载器 PNG 图标）

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        if (self.currentMod && self.currentMode == ModTableViewCellDisplayModeLocal) {
            [self configureIconForMod:self.currentMod];
        }
    }
}

#pragma mark - Reuse

- (void)prepareForReuse {
    [super prepareForReuse]; // 基类已复位文字 / 图标 / accessory 插槽
    self.contentView.alpha = 1.0;
    if (self.downloadButton) self.downloadButton.hidden = YES;
    if (self.openLinkButton) self.openLinkButton.hidden = YES;
    if (_loaderBadge) _loaderBadge.hidden = YES;
    self.currentMod = nil;
}

#pragma mark - Actions

- (void)toggleTapped {
    if ([self.delegate respondsToSelector:@selector(modCellDidTapToggle:)]) {
        [self.delegate modCellDidTapToggle:self];
    }
}

- (void)downloadTapped {
    if ([self.delegate respondsToSelector:@selector(modCellDidTapDownload:)]) {
        [self.delegate modCellDidTapDownload:self];
    }
}

- (void)openLinkTapped {
    if ([self.delegate respondsToSelector:@selector(modCellDidTapOpenLink:)]) {
        [self.delegate modCellDidTapOpenLink:self];
    }
}

@end
