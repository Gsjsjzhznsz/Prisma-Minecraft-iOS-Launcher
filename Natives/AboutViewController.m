//
//  AboutViewController.m
//  Amethyst
//
//  Task217：关于页实现。视觉沿用应用的卡片语言（12pt 连续圆角 +
//  半透明基底 + BackgroundManager 透明化管线），纯 UIStackView 滚动布局。
//

#import "AboutViewController.h"
#import "BackgroundManager.h"
#import "UpdateChecker.h"
#import "LauncherPreferences.h"
#import "utils.h"

/// 本启动器的 QQ 群号（用户指令：README 与关于页都展示）。
static NSString *const ame217_qqGroup = @"1126547426";

@interface AboutViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *versionValueLabel;
@property (nonatomic, strong) UISwitch *autoUpdateSwitch;
@end

@implementation AboutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"about.nav_title", nil);
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 适配自定义启动器背景：透明化当前页，让全局背景/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 14;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:20],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:20],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-20],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    [self ame217_buildHeaderCard];
    [self ame217_buildQQCard];
    [self ame217_buildUpdateCard];
    [self ame217_buildLicenseCard];
    [self ame217_buildCreditsCard];
}

#pragma mark - 卡片工厂

/// 卡片容器：12pt 连续圆角 + 半透明基底（与设置页卡片同语言）。
- (UIView *)ame217_card {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 12.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    card.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    return card;
}

- (UILabel *)ame217_labelText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = NO;
    return label;
}

/// 头部卡：图标 + 名称 + 版本（动态读 Info.plist，双键同值 6.5.0）。
- (void)ame217_buildHeaderCard {
    UIView *card = [self ame217_card];
    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.alignment = UIStackViewAlignmentCenter;
    inner.spacing = 8;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];

    // Task219：图标加载改走多候选链（与欢迎向导同源）。病历：旧代码
    // imageNamed:@"AppIcon-Light" 在 bundle 根 PNG 实名（AppIcon-Light60x60
    // @2x.png）下必然落空 → 回退 SF Symbol 小图标（"没有图标装饰"反馈的
    // 关于页一半）。候选链按实名去 @2x 后缀逐个试。
    UIImage *icon = nil;
    for (NSString *ame219_name in @[@"AppIcon-Light60x60", @"AppIcon-Light76x76",
                                     @"AppIcon60x60", @"AppIcon-Light", @"AppIcon"]) {
        icon = [UIImage imageNamed:ame219_name];
        if (icon != nil) break;
    }
    if (icon == nil) {
        icon = [UIImage systemImageNamed:@"app.fill"];
    }
    if (icon) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 22.0;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.layer.masksToBounds = YES;
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [inner addArrangedSubview:iv];
        [NSLayoutConstraint activateConstraints:@[
            [iv.widthAnchor constraintEqualToConstant:96],
            [iv.heightAnchor constraintEqualToConstant:96],
        ]];
    }

    [inner addArrangedSubview:[self ame217_labelText:@"Prisma"
        font:[UIFont systemFontOfSize:24 weight:UIFontWeightBold]
        color:[UIColor labelColor]]];

    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: version;
    self.versionValueLabel = [self ame217_labelText:[NSString stringWithFormat:@"%@ (%@)", version, build]
        font:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]
        color:[UIColor secondaryLabelColor]];
    [inner addArrangedSubview:self.versionValueLabel];

    [self ame217_addCard:card inner:inner];
}

/// QQ 群卡：群号展示 + 点击复制（iOS 无 QQ 群通用深链，复制群号后
/// 在 QQ 内搜索加入是通用路径）。
- (void)ame217_buildQQCard {
    UIView *card = [self ame217_card];
    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 6;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];

    [inner addArrangedSubview:[self ame217_labelText:localize(@"about.qq.title", nil)
        font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
        color:[UIColor labelColor]]];
    [inner addArrangedSubview:[self ame217_labelText:ame217_qqGroup
        font:[UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightSemibold]
        color:accentColor()]];

    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyButton setTitle:localize(@"about.qq.copy", nil) forState:UIControlStateNormal];
    copyButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    copyButton.backgroundColor = [accentColor() colorWithAlphaComponent:0.14];
    copyButton.layer.cornerRadius = 12.0;
    copyButton.contentEdgeInsets = UIEdgeInsetsMake(8, 16, 8, 16);
    copyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [copyButton addTarget:self action:@selector(ame217_copyQQGroup) forControlEvents:UIControlEventTouchUpInside];
    [inner addArrangedSubview:copyButton];

    [self ame217_addCard:card inner:inner];
}

/// 启动器更新区（Task217 从设置·通用区迁移）：检查更新按钮 +
/// 启动时自动检查开关（general.auto_update_check，Task125 语义不变）。
- (void)ame217_buildUpdateCard {
    UIView *card = [self ame217_card];
    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 10;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];

    [inner addArrangedSubview:[self ame217_labelText:localize(@"about.update.section", nil)
        font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
        color:[UIColor labelColor]]];

    UIButton *checkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [checkButton setTitle:localize(@"preference.title.check_update", nil) forState:UIControlStateNormal];
    [checkButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    checkButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    checkButton.backgroundColor = accentColor();
    checkButton.layer.cornerRadius = 12.0;
    checkButton.contentEdgeInsets = UIEdgeInsetsMake(10, 16, 10, 16);
    checkButton.translatesAutoresizingMaskIntoConstraints = NO;
    [checkButton addTarget:self action:@selector(ame217_checkForUpdate) forControlEvents:UIControlEventTouchUpInside];
    [inner addArrangedSubview:checkButton];

    // 启动时自动检查（开关行）
    UIStackView *switchRow = [[UIStackView alloc] init];
    switchRow.axis = UILayoutConstraintAxisHorizontal;
    switchRow.distribution = UIStackViewDistributionFill;
    switchRow.alignment = UIStackViewAlignmentCenter;
    switchRow.spacing = 10;
    switchRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *textCol = [[UIStackView alloc] init];
    textCol.axis = UILayoutConstraintAxisVertical;
    textCol.spacing = 2;
    [textCol addArrangedSubview:[self ame217_labelText:localize(@"preference.title.auto_update_check", nil)
        font:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]
        color:[UIColor labelColor]]];
    [textCol addArrangedSubview:[self ame217_labelText:localize(@"preference.detail.auto_update_check", nil)
        font:[UIFont systemFontOfSize:11]
        color:[UIColor tertiaryLabelColor]]];

    self.autoUpdateSwitch = [[UISwitch alloc] init];
    self.autoUpdateSwitch.on = [getPrefObject(@"general.auto_update_check") boolValue];
    [self.autoUpdateSwitch addTarget:self action:@selector(ame217_autoUpdateChanged:)
                      forControlEvents:UIControlEventValueChanged];

    [switchRow addArrangedSubview:textCol];
    [switchRow addArrangedSubview:self.autoUpdateSwitch];
    [inner addArrangedSubview:switchRow];

    [self ame217_addCard:card inner:inner];
}

/// 许可证卡：AGPL-3.0 声明 + 许可证内容所在处（按上游要求说明）。
- (void)ame217_buildLicenseCard {
    UIView *card = [self ame217_card];
    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 6;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];

    [inner addArrangedSubview:[self ame217_labelText:localize(@"about.license.title", nil)
        font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
        color:[UIColor labelColor]]];
    [inner addArrangedSubview:[self ame217_labelText:localize(@"about.license.body", nil)
        font:[UIFont systemFontOfSize:12]
        color:[UIColor secondaryLabelColor]]];

    [self ame217_addCard:card inner:inner];
}

/// Fork 溯源致谢卡。
- (void)ame217_buildCreditsCard {
    UIView *card = [self ame217_card];
    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 6;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];

    [inner addArrangedSubview:[self ame217_labelText:localize(@"about.credits.title", nil)
        font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
        color:[UIColor labelColor]]];
    [inner addArrangedSubview:[self ame217_labelText:localize(@"about.credits.body", nil)
        font:[UIFont systemFontOfSize:12]
        color:[UIColor secondaryLabelColor]]];

    [self ame217_addCard:card inner:inner];
}

- (void)ame217_addCard:(UIView *)card inner:(UIView *)inner {
    [self.stack addArrangedSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
}

#pragma mark - Actions

- (void)ame217_copyQQGroup {
    [UIPasteboard generalPasteboard].string = ame217_qqGroup;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"about.qq.copied", nil)
                         message:ame217_qqGroup
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"好的")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ame217_autoUpdateChanged:(UISwitch *)sender {
    // Task125 语义原样迁移：仅在新版本可用时以卡片通知提示。
    setPrefObject(@"general.auto_update_check", @(sender.isOn));
}

/// 检查更新（与设置页旧入口同链路：UpdateChecker 正式版检查 + 弹窗结果）。
- (void)ame217_checkForUpdate {
    UIAlertController *loadingAlert = [UIAlertController
        alertControllerWithTitle:localize(@"check_update.checking", @"正在检查更新…")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loadingAlert animated:YES completion:nil];

    [UpdateChecker checkForUpdateWithCompletion:^(UpdateInfo *info, NSError *error) {
        [loadingAlert dismissViewControllerAnimated:YES completion:^{
            if (error || info == nil) {
                [self ame217_showUpdateAlertWithTitle:localize(@"check_update.failed", @"检查更新失败")
                                                message:error.localizedDescription ?: localize(@"i18n_str_97", nil)];
                return;
            }
            if (info.hasUpdate) {
                [self ame217_showUpdateAvailableAlert:info];
            } else {
                [self ame217_showUpdateAlertWithTitle:localize(@"check_update.up_to_date", @"已是最新版本")
                                                message:[NSString stringWithFormat:
                                                    localize(@"check_update.current_version", @"当前版本 %@，已是最新正式版。"),
                                                    info.currentVersion]];
            }
        }];
    }];
}

- (void)ame217_showUpdateAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"好的")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ame217_showUpdateAvailableAlert:(UpdateInfo *)info {
    NSString *title = [NSString stringWithFormat:localize(@"check_update.new_version_title",
                                                          localize(@"i18n_str_407", nil)), info.latestVersion];
    NSString *notes = info.releaseNotes ?: @"";
    if (notes.length > 500) {
        notes = [[notes substringToIndex:500] stringByAppendingString:@"…"];
    }
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@",
                         localize(@"check_update.new_version_message", localize(@"i18n_str_408", nil)),
                         notes];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"check_update.download", @"前往下载")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [UpdateChecker openReleasePage];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", @"取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
