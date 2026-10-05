#import "LauncherNewsViewController.h"
#import "HomeCustomizeViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherPreferences.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "BackgroundSettingsViewController.h"
#import "BackgroundManager.h"
#import "UIKit+NativeSurface.h" // Task160 新拟态规格色
#import "PLProfiles.h"
#import "utils.h"
#import "ios_uikit_bridge.h"
#import "MinecraftNewsService.h"
#import "MinecraftNewsItem.h"
#import "MinecraftNewsViewController.h"
#import "AnnouncementService.h"
#import "AnnouncementItem.h"
#import "AnnouncementListViewController.h"
#import "IconLoader.h"
#import "AvatarManager.h"
#import <SafariServices/SafariServices.h>
#import <QuartzCore/QuartzCore.h>

// MARK: - Shortcut Action Constants

NSString * const kShortcutActionMods       = @"mods";
NSString * const kShortcutActionShaders    = @"shaders";
NSString * const kShortcutActionModpack    = @"modpack";
NSString * const kShortcutActionBackground = @"background";
NSString * const kShortcutActionVersions   = @"versions";

// MARK: - Color Helpers

static UIColor *colorFromHex(NSString *hex) {
    hex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// MARK: - HomeTileConfig Implementation

@implementation HomeTileConfig

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _tileId = [coder decodeObjectOfClass:[NSString class] forKey:@"tileId"];
        _tileType = [coder decodeIntegerForKey:@"tileType"];
        _tileSize = [coder decodeIntegerForKey:@"tileSize"];
        _visible = [coder decodeBoolForKey:@"visible"];
        _customTitle = [coder decodeObjectOfClass:[NSString class] forKey:@"customTitle"];
        _iconName = [coder decodeObjectOfClass:[NSString class] forKey:@"iconName"];
        _accentColorHex = [coder decodeObjectOfClass:[NSString class] forKey:@"accentColorHex"];
        _shortcutAction = [coder decodeObjectOfClass:[NSString class] forKey:@"shortcutAction"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_tileId forKey:@"tileId"];
    [coder encodeInteger:_tileType forKey:@"tileType"];
    [coder encodeInteger:_tileSize forKey:@"tileSize"];
    [coder encodeBool:_visible forKey:@"visible"];
    [coder encodeObject:_customTitle forKey:@"customTitle"];
    [coder encodeObject:_iconName forKey:@"iconName"];
    [coder encodeObject:_accentColorHex forKey:@"accentColorHex"];
    [coder encodeObject:_shortcutAction forKey:@"shortcutAction"];
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (_tileId) dict[@"tileId"] = _tileId;
    dict[@"tileType"] = @(_tileType);
    dict[@"tileSize"] = @(_tileSize);
    dict[@"visible"] = @(_visible);
    if (_customTitle) dict[@"customTitle"] = _customTitle;
    if (_iconName) dict[@"iconName"] = _iconName;
    if (_accentColorHex) dict[@"accentColorHex"] = _accentColorHex;
    if (_shortcutAction) dict[@"shortcutAction"] = _shortcutAction;
    return dict;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    HomeTileConfig *config = [[HomeTileConfig alloc] init];
    config.tileId = dict[@"tileId"];
    config.tileType = [dict[@"tileType"] integerValue];
    config.tileSize = [dict[@"tileSize"] integerValue];
    config.visible = [dict[@"visible"] boolValue];
    config.customTitle = dict[@"customTitle"];
    config.iconName = dict[@"iconName"];
    config.accentColorHex = dict[@"accentColorHex"];
    config.shortcutAction = dict[@"shortcutAction"];
    return config;
}

- (UIColor *)accentColor {
    if (_accentColorHex) return colorFromHex(_accentColorHex);
    // 默认颜色基于磁贴类型
    switch (_tileType) {
        case HomeTileTypeProfile:        return colorFromHex(@"#8B5CF6");
        case HomeTileTypeAnnouncement:   return colorFromHex(@"#3B82F6");
        case HomeTileTypeVersionRelease: return colorFromHex(@"#10B981");
        case HomeTileTypeVersionSnapshot:return colorFromHex(@"#F59E0B");
        case HomeTileTypeNews:           return colorFromHex(@"#EF4444");
        case HomeTileTypeShortcut:       return colorFromHex(@"#14B8A6");
        default:                         return [UIColor systemBlueColor];
    }
}

+ (NSArray<HomeTileConfig *> *)defaultTileConfigs {
    NSMutableArray *tiles = [NSMutableArray array];
    
    // 0. 用户资料 (全宽)
    HomeTileConfig *profile = [[HomeTileConfig alloc] init];
    profile.tileId = @"profile";
    profile.tileType = HomeTileTypeProfile;
    profile.tileSize = HomeTileSizeFull;
    profile.visible = YES;
    profile.iconName = @"person.crop.circle.fill";
    profile.accentColorHex = @"#8B5CF6";
    [tiles addObject:profile];
    
    // 1. 公告 (全宽) — 位于版本信息之前
    HomeTileConfig *announcement = [[HomeTileConfig alloc] init];
    announcement.tileId = @"announcement";
    announcement.tileType = HomeTileTypeAnnouncement;
    announcement.tileSize = HomeTileSizeFull;
    announcement.visible = YES;
    announcement.iconName = @"megaphone.fill";
    announcement.accentColorHex = @"#3B82F6";
    [tiles addObject:announcement];
    
    // 2. 最新正式版 (半宽)
    HomeTileConfig *release = [[HomeTileConfig alloc] init];
    release.tileId = @"latest_release";
    release.tileType = HomeTileTypeVersionRelease;
    release.tileSize = HomeTileSizeCompact;
    release.visible = YES;
    release.iconName = @"cube.box.fill";
    release.accentColorHex = @"#10B981";
    [tiles addObject:release];
    
    // 3. 最新快照 (半宽)
    HomeTileConfig *snapshot = [[HomeTileConfig alloc] init];
    snapshot.tileId = @"latest_snapshot";
    snapshot.tileType = HomeTileTypeVersionSnapshot;
    snapshot.tileSize = HomeTileSizeCompact;
    snapshot.visible = YES;
    snapshot.iconName = @"ant.fill";
    snapshot.accentColorHex = @"#F59E0B";
    [tiles addObject:snapshot];
    
    // 4. 新闻 (全宽)
    HomeTileConfig *news = [[HomeTileConfig alloc] init];
    news.tileId = @"news";
    news.tileType = HomeTileTypeNews;
    news.tileSize = HomeTileSizeFull;
    news.visible = YES;
    news.iconName = @"newspaper.fill";
    news.accentColorHex = @"#EF4444";
    [tiles addObject:news];
    
    // 5. 快捷入口: Mod管理 (半宽)
    HomeTileConfig *mods = [[HomeTileConfig alloc] init];
    mods.tileId = @"shortcut_mods";
    mods.tileType = HomeTileTypeShortcut;
    mods.tileSize = HomeTileSizeCompact;
    mods.visible = YES;
    mods.customTitle = localize(@"i18n_str_275", nil);
    mods.iconName = @"puzzlepiece.extension.fill";
    mods.shortcutAction = kShortcutActionMods;
    mods.accentColorHex = @"#14B8A6";
    [tiles addObject:mods];
    
    // 6. 快捷入口: 光影管理 (半宽)
    HomeTileConfig *shaders = [[HomeTileConfig alloc] init];
    shaders.tileId = @"shortcut_shaders";
    shaders.tileType = HomeTileTypeShortcut;
    shaders.tileSize = HomeTileSizeCompact;
    shaders.visible = YES;
    shaders.customTitle = localize(@"i18n_str_2016", nil);
    shaders.iconName = @"sun.max.fill";
    shaders.shortcutAction = kShortcutActionShaders;
    shaders.accentColorHex = @"#F97316";
    [tiles addObject:shaders];
    
    // 7. 快捷入口: 整合包 (半宽)
    HomeTileConfig *modpack = [[HomeTileConfig alloc] init];
    modpack.tileId = @"shortcut_modpack";
    modpack.tileType = HomeTileTypeShortcut;
    modpack.tileSize = HomeTileSizeCompact;
    modpack.visible = YES;
    modpack.customTitle = localize(@"i18n_str_277", nil);
    modpack.iconName = @"shippingbox.fill";
    modpack.shortcutAction = kShortcutActionModpack;
    modpack.accentColorHex = @"#8B5CF6";
    [tiles addObject:modpack];
    
    // 8. 快捷入口: 壁纸设置 (半宽)
    HomeTileConfig *bg = [[HomeTileConfig alloc] init];
    bg.tileId = @"shortcut_bg";
    bg.tileType = HomeTileTypeShortcut;
    bg.tileSize = HomeTileSizeCompact;
    bg.visible = YES;
    bg.customTitle = localize(@"i18n_str_278", nil);
    bg.iconName = @"photo.fill.on.rectangle.fill";
    bg.shortcutAction = kShortcutActionBackground;
    bg.accentColorHex = @"#EC4899";
    [tiles addObject:bg];
    
    return tiles;
}

+ (NSArray<HomeTileConfig *> *)loadSavedConfigs {
    NSArray *savedArray = [[NSUserDefaults standardUserDefaults] objectForKey:@"home_tiles_config"];
    if (!savedArray || ![savedArray isKindOfClass:[NSArray class]]) {
        return [self defaultTileConfigs];
    }
    
    NSMutableArray *configs = [NSMutableArray array];
    for (NSDictionary *dict in savedArray) {
        if ([dict isKindOfClass:[NSDictionary class]]) {
            [configs addObject:[self fromDictionary:dict]];
        }
    }
    return configs.count > 0 ? configs : [self defaultTileConfigs];
}

+ (void)saveConfigs:(NSArray<HomeTileConfig *> *)configs {
    NSMutableArray *arr = [NSMutableArray array];
    for (HomeTileConfig *c in configs) {
        [arr addObject:[c toDictionary]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:@"home_tiles_config"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end

// MARK: - Festival Detection

static NSString *festivalGreeting(void) {
    NSDate *now = [NSDate date];
    NSCalendar *gregorian = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *solar = [gregorian components:(NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
    NSInteger month = solar.month;
    NSInteger day = solar.day;
    
    // 公历节日
    if (month == 1  && day == 1)  return localize(@"i18n_str_324", nil);
    if (month == 4  && (day >= 4 && day <= 6)) return localize(@"i18n_str_325", nil);
    if (month == 5  && day == 1)  return localize(@"i18n_str_326", nil);
    if (month == 6  && day == 1)  return localize(@"i18n_str_327", nil);
    if (month == 9  && day == 10) return localize(@"i18n_str_328", nil);
    if (month == 10 && (day >= 1 && day <= 7)) return localize(@"i18n_str_329", nil);
    if (month == 12 && day == 24) return localize(@"i18n_str_330", nil);
    if (month == 12 && day == 25) return localize(@"i18n_str_331", nil);
    
    // 农历节日 (使用中国日历)
    NSCalendar *chineseCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierChinese];
    NSDateComponents *lunar = [chineseCalendar components:(NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
    NSInteger lunarMonth = lunar.month;
    NSInteger lunarDay = lunar.day;
    
    if (lunarMonth == 1  && lunarDay == 1)  return localize(@"i18n_str_332", nil);
    if (lunarMonth == 1  && lunarDay == 2)  return localize(@"i18n_str_333", nil);
    if (lunarMonth == 1  && lunarDay == 3)  return localize(@"i18n_str_334", nil);
    if (lunarMonth == 1  && lunarDay == 15) return localize(@"i18n_str_335", nil);
    if (lunarMonth == 5  && lunarDay == 5)  return localize(@"i18n_str_336", nil);
    if (lunarMonth == 7  && lunarDay == 7)  return localize(@"i18n_str_337", nil);
    if (lunarMonth == 8  && lunarDay == 15) return localize(@"i18n_str_338", nil);
    if (lunarMonth == 9  && lunarDay == 9)  return localize(@"i18n_str_339", nil);
    if (lunarMonth == 12 && (lunarDay == 29 || lunarDay == 30)) return localize(@"i18n_str_340", nil);
    
    // 非节日 - 按时段随机问候
    NSInteger hour = [gregorian component:NSCalendarUnitHour fromDate:now];
    if (hour < 6)       return localize(@"i18n_str_341", nil);
    if (hour < 12)      return localize(@"i18n_str_342", nil);
    if (hour < 14)      return localize(@"i18n_str_343", nil);
    if (hour < 18)      return localize(@"i18n_str_344", nil);
    return localize(@"i18n_str_345", nil);
}

// MARK: - HomeTileBaseCell

@interface HomeTileBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIView *contentContainer;
- (void)setupBaseViews;
// Task90：卡片顶部渐变装饰条（accentBar）已按用户反馈移除，保留本方法
// 仅为兼容子类/数据源既有调用点（现为空操作）；磁贴图标的彩色语义由
// cellForItemAtIndexPath 直接作用于 iconView.tintColor，不受影响。
- (void)setAccentColor:(UIColor *)color;
@end

@implementation HomeTileBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupBaseViews];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleBackgroundUIEffectChanged)
                                                     name:@"BackgroundUIEffectChanged"
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleBackgroundUIEffectChanged {
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
}

- (void)setupBaseViews {
    // Task149：主页面所有卡片取消阴影（用户指令）——阴影四件套退役，
    // 卡片视觉由 contentView 圆角裁剪 + 原生表面呈现，层级/尺寸零变化
    
    // Task90：卡片顶部渐变装饰条已移除（用户反馈去掉红框色条），
    // 卡片视觉统一交给新拟态表面 + 图标语义色。
    
    // 内容容器
    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.contentContainer];

    // 圆角：contentView 设置圆角 + masksToBounds，让 BackgroundManager 注入的
    // 毛玻璃 blurView 也获得一致的圆角（applyEffectToCollectionViewCell: 会读取
    // cell.contentView.layer.cornerRadius）。
    // Task137：圆角回摑 Task136 之前的 16pt（原生磁贴卡片），阴影路径退场。
    self.contentView.layer.cornerRadius = 16;
    self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentView.layer.masksToBounds = YES;

    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
}

- (void)setAccentColor:(UIColor *)color {
    // Task90：顶部渐变装饰条已移除，空操作保留以兼容调用点
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Task137：原生磁贴卡片无自绘阴影，shadowPath 生成随新拟态一并退役
}

// 弹簧按压动画
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

// MARK: - HomeProfileTileCell

@interface HomeProfileTileCell : HomeTileBaseCell
// Task136：MC 头像接管原用户图标（皮肤全身预览）的最左位置；原 52×52
// 小头像与 skinImageView 均已退场
@property (nonatomic, strong) UIImageView *avatarImageView;
@property (nonatomic, strong) UILabel *welcomeLabel;
// Task149：第二行回归原灰字问候语（Task141 的公告标题行+查看详情按钮
// 按用户指令整体退役；公告预览回归主页面公告卡片本体）。
@property (nonatomic, strong) UILabel *greetingLabel;
@property (nonatomic, strong) UIStackView *welcomeStack;
// Task149：头像等边距（到左边缘 = 到上/下边缘）动态约束——头像高度
// = 卡高 × 0.5，上/下边距恒等于 side/2，左边距与文字间距同步取该值
// （layoutSubviews 随实际尺寸刷新；卡片/头像尺寸均不变，仅挪位置）。
@property (nonatomic, strong) NSLayoutConstraint *avatarLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *textLeadingConstraint;
@end

@implementation HomeProfileTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    // Task136：MC 头像（原右侧 52×52 小头像移过来接管最左位置）：
    // 保留原样式——半透明白色边框 + 圆形（layoutSubviews 按尺寸动态取半）；
    // 大小对齐原用户图标（约卡片高度一半、随卡高自适应）。
    self.avatarImageView = [[UIImageView alloc] init];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
    // 圆形裁剪：AspectFill 下图片必须裁进圆形边框。
    // Task138：胶囊常量圆角根治"切标签页变正方形"。CALayer 对超过边长一半
    // 的圆角自动钳制为半边长——方形视图 + 大常量 = 恒为正圆，与布局时序
    // 完全解耦。此前仅靠 layoutSubviews 动态取半，集合视图切标签页回来时
    // 离屏预布局阶段头像 bounds 仍为 0，守卫跳过赋值，新图层 radius 停留
    // 0（正方形），要等下一次布局通过才恢复——用户实测"切一次变方、再切
    // 恢复"。现初始化即设 999（任何 ≥ 半边长的值等价），layoutSubviews
    // 的精确取半保留为冗余兜底。
    self.avatarImageView.layer.cornerRadius = 999.0;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.layer.borderWidth = 2.5;
    self.avatarImageView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    // Task137：原生占位底色
    self.avatarImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    // Task149：首帧即默认头像（用户实测“不点击不加载”——init 先用 SF
    // 占位、等 cellForItem 才换 DefaultAccount 的时序路径封死：无账号
    // 首帧直接呈现账户列表同款 DefaultAccount；账号态仍由 cellForItem
    // 的 currentAvatar 分支接管）
    UIImage *ame149_defaultAvatar = [UIImage imageNamed:@"DefaultAccount"];
    if (ame149_defaultAvatar) {
        self.avatarImageView.image = ame149_defaultAvatar;
        self.avatarImageView.tintColor = nil;
        self.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
        self.avatarImageView.tintColor = [UIColor systemGrayColor];
    }
    [self.contentContainer addSubview:self.avatarImageView];
    
    // 欢迎文本
    self.welcomeLabel = [[UILabel alloc] init];
    self.welcomeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.welcomeLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    self.welcomeLabel.textColor = AmeCardPrimaryTextColor(); // Task160
    self.welcomeLabel.numberOfLines = 1;
    self.welcomeLabel.adjustsFontSizeToFitWidth = YES;
    self.welcomeLabel.minimumScaleFactor = 0.7;
    
    // Task149：第二行回归原灰字问候语（14pt，festivalGreeting 由 cellForItem 填充）
    self.greetingLabel = [[UILabel alloc] init];
    self.greetingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.greetingLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.greetingLabel.textColor = AmeCardSecondaryTextColor(); // Task160
    self.greetingLabel.numberOfLines = 1;
    
    // Task136：两行欢迎句组成纵向 stack，整体相对头像纵轴居中
    // Task149：第二行 = 原问候语（公告标题行退役）
    self.welcomeStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.welcomeLabel, self.greetingLabel]];
    self.welcomeStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.welcomeStack.axis = UILayoutConstraintAxisVertical;
    self.welcomeStack.alignment = UIStackViewAlignmentLeading;
    self.welcomeStack.spacing = 4;
    [self.contentContainer addSubview:self.welcomeStack];
    
    // Task149：头像等边距——左边距与文字间距的常量由 layoutSubviews 按
    // 头像实际边长（= 卡高/2）取半刷新，与上/下边距恒等；初始常量仅占位。
    self.avatarLeadingConstraint = [self.avatarImageView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:42.5];
    self.textLeadingConstraint = [self.welcomeStack.leadingAnchor constraintEqualToAnchor:self.avatarImageView.trailingAnchor constant:42.5];
    
    [NSLayoutConstraint activateConstraints:@[
        // MC 头像（最左）：高度 ≈ 卡片高度一半，宽度=高度（正圆基准），垂直居中
        self.avatarLeadingConstraint,
        [self.avatarImageView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.avatarImageView.heightAnchor constraintEqualToAnchor:self.contentContainer.heightAnchor multiplier:0.5],
        [self.avatarImageView.widthAnchor constraintEqualToAnchor:self.avatarImageView.heightAnchor],
        
        // 两行欢迎句：头像右侧（间距 = 头像距卡片边缘的距离），纵轴居中
        self.textLeadingConstraint,
        [self.welcomeStack.centerYAnchor constraintEqualToAnchor:self.avatarImageView.centerYAnchor],
        [self.welcomeStack.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-18],
    ]];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Task136：圆形 MC 头像——圆角随实际尺寸取半（原 26 固定值对应 52×52）
    CGFloat side = self.avatarImageView.bounds.size.height;
    if (side > 0) {
        self.avatarImageView.layer.cornerRadius = side / 2.0;
        // Task149：等边距刷新——头像高度 = 卡高 × 0.5，上/下边距 = side/2，
        // 左边距与文字间距同步取 side/2（到四边距离一致，头像/卡片尺寸均不变）
        self.avatarLeadingConstraint.constant = side / 2.0;
        self.textLeadingConstraint.constant = side / 2.0;
    }
}

@end

// MARK: - HomeInfoTileCell

@interface HomeInfoTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@end

@implementation HomeInfoTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor systemGreenColor];
    [self.contentContainer addSubview:self.iconView];
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.titleLabel.textColor = [UIColor tertiaryLabelColor];
    self.titleLabel.textAlignment = NSTextAlignmentLeft;
    [self.contentContainer addSubview:self.titleLabel];
    
    self.valueLabel = [[UILabel alloc] init];
    self.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.valueLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.valueLabel.textColor = [UIColor labelColor];
    self.valueLabel.numberOfLines = 2;
    self.valueLabel.adjustsFontSizeToFitWidth = YES;
    self.valueLabel.minimumScaleFactor = 0.6;
    [self.contentContainer addSubview:self.valueLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:18],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.widthAnchor constraintEqualToConstant:26],
        [self.iconView.heightAnchor constraintEqualToConstant:26],
        
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.iconView.centerYAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:8],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        
        [self.valueLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:10],
        [self.valueLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.valueLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
    ]];
}

@end

// MARK: - HomeAnnouncementTileCell

@interface HomeAnnouncementTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
// Task149：公告卡重排——标题/简介分离，样式对齐新闻卡片（标题 15pt
// semibold / 简介 12pt tertiary）；喇叭图标垂直居中；查看详情按钮内联标题后
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UIStackView *titleRowStack;
@property (nonatomic, strong) UIStackView *textStack;
@end

@implementation HomeAnnouncementTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"megaphone.fill"];
    self.iconView.tintColor = colorFromHex(@"#3B82F6");
    [self.contentContainer addSubview:self.iconView];
    
    // Task149：标题样式对齐新闻卡片（15pt semibold）；查看详情按钮内联到
    // 标题后面并缩小（contentEdgeInsets 自适应宽 + 28pt 高胶囊圆角）
    self.titleRowStack = [[UIStackView alloc] init];
    self.titleRowStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleRowStack.axis = UILayoutConstraintAxisHorizontal;
    self.titleRowStack.alignment = UIStackViewAlignmentCenter;
    self.titleRowStack.spacing = 8;
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = AmeCardPrimaryTextColor(); // Task160 公告卡标题
    self.titleLabel.numberOfLines = 1;
    [self.titleRowStack addArrangedSubview:self.titleLabel];
    
    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.actionButton.layer.cornerRadius = 8;
    self.actionButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.actionButton.clipsToBounds = YES;
    self.actionButton.hidden = YES;
    self.actionButton.contentEdgeInsets = UIEdgeInsetsMake(4, 12, 4, 12);
    [self.actionButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.actionButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.actionButton.heightAnchor constraintEqualToConstant:28].active = YES;
    [self.titleRowStack addArrangedSubview:self.actionButton];
    
    // Task149：简介样式对齐新闻卡片（12pt tertiary）；高度不够时优先截断
    // （与 MC 新闻页 cell 同序：简介 750 < 标题行 998）
    self.summaryLabel = [[UILabel alloc] init];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.summaryLabel.textColor = AmeCardSecondaryTextColor(); // Task160 公告卡简介
    self.summaryLabel.numberOfLines = 0;
    [self.summaryLabel setContentCompressionResistancePriority:750 forAxis:UILayoutConstraintAxisVertical];
    [self.titleRowStack setContentCompressionResistancePriority:998 forAxis:UILayoutConstraintAxisVertical];
    
    self.textStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleRowStack, self.summaryLabel]];
    self.textStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.textStack.axis = UILayoutConstraintAxisVertical;
    self.textStack.alignment = UIStackViewAlignmentFill;
    self.textStack.spacing = 4;
    [self.contentContainer addSubview:self.textStack];
    
    [NSLayoutConstraint activateConstraints:@[
        // Task149：喇叭图标放在中间的高度位置（垂直居中，尺寸不变）
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:22],
        [self.iconView.heightAnchor constraintEqualToConstant:22],
        
        // 文本块：不足时钳制在上下 14pt 内（简介优先截断），短内容整体居中
        [self.textStack.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:10],
        [self.textStack.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.textStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [self.textStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-14],
    ]];
    NSLayoutConstraint *ame149_textCenter = [self.textStack.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor];
    ame149_textCenter.priority = 999;
    ame149_textCenter.active = YES;
}

@end

// MARK: - HomeNewsTileCell

@interface HomeNewsTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *placeholderLabel;
@end

@implementation HomeNewsTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    // 左侧缩略图占位
    self.thumbnailView = [[UIImageView alloc] init];
    self.thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
    self.thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    self.thumbnailView.clipsToBounds = YES;
    self.thumbnailView.layer.cornerRadius = 10;
    self.thumbnailView.layer.cornerCurve = kCACornerCurveContinuous;
    // Task137：原生占位底色
    self.thumbnailView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
    self.thumbnailView.tintColor = [UIColor secondaryLabelColor];
    [self.contentContainer addSubview:self.thumbnailView];
    
    // 标题
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = AmeCardPrimaryTextColor(); // Task160 新闻卡标题
    self.titleLabel.numberOfLines = 2;
    [self.contentContainer addSubview:self.titleLabel];
    
    // 摘要
    self.summaryLabel = [[UILabel alloc] init];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.summaryLabel.textColor = AmeCardSecondaryTextColor(); // Task160 新闻卡简介
    self.summaryLabel.numberOfLines = 2;
    [self.contentContainer addSubview:self.summaryLabel];
    
    // 占位提示
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.placeholderLabel.textColor = [UIColor quaternaryLabelColor];
    self.placeholderLabel.text = localize(@"i18n_str_346", nil);
    [self.contentContainer addSubview:self.placeholderLabel];
    
    // Task149：文字块参照欢迎卡模式重排——标题+简介纵向 stack 相对缩略图
    // 纵轴居中；高度不够时简介优先截断（750 < 标题 997）
    [self.summaryLabel setContentCompressionResistancePriority:750 forAxis:UILayoutConstraintAxisVertical];
    [self.titleLabel setContentCompressionResistancePriority:997 forAxis:UILayoutConstraintAxisVertical];
    self.summaryLabel.numberOfLines = 0;
    UIStackView *ame149_textStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.summaryLabel]];
    ame149_textStack.translatesAutoresizingMaskIntoConstraints = NO;
    ame149_textStack.axis = UILayoutConstraintAxisVertical;
    ame149_textStack.alignment = UIStackViewAlignmentFill;
    ame149_textStack.spacing = 4;
    [self.contentContainer addSubview:ame149_textStack];
    
    [NSLayoutConstraint activateConstraints:@[
        // Task149：缩略图等边距——卡高 100、缩略图高 60，上/下边距恒为 20，
        // 左边距与文字间距同步取 20（到左/上/下边缘距离一致，尺寸不变）
        [self.thumbnailView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:20],
        [self.thumbnailView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.thumbnailView.widthAnchor constraintEqualToConstant:80],
        [self.thumbnailView.heightAnchor constraintEqualToConstant:60],
        
        // 文字块：相对缩略图居中，不足时钳制（简介优先截断到能显示的行）
        [ame149_textStack.leadingAnchor constraintEqualToAnchor:self.thumbnailView.trailingAnchor constant:20],
        [ame149_textStack.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [ame149_textStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [ame149_textStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-14],
        
        [self.placeholderLabel.bottomAnchor constraintEqualToAnchor:self.thumbnailView.bottomAnchor],
        [self.placeholderLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
    ]];
    NSLayoutConstraint *ame149_newsTextCenter = [ame149_textStack.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor];
    ame149_newsTextCenter.priority = 999;
    ame149_newsTextCenter.active = YES;
}

@end

// MARK: - HomeShortcutTileCell

@interface HomeShortcutTileCell : HomeTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation HomeShortcutTileCell

- (void)setupBaseViews {
    [super setupBaseViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor systemTealColor];
    [self.contentContainer addSubview:self.iconView];
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = AmeCardPrimaryTextColor(); // Task160
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.7;
    [self.contentContainer addSubview:self.titleLabel];
    
    self.chevronView = [[UIImageView alloc] init];
    self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chevronView.contentMode = UIViewContentModeScaleAspectFit;
    self.chevronView.image = [UIImage systemImageNamed:@"chevron.right"];
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    [self.contentContainer addSubview:self.chevronView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.widthAnchor constraintEqualToConstant:28],
        [self.iconView.heightAnchor constraintEqualToConstant:28],
        
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        
        [self.chevronView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.chevronView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.chevronView.widthAnchor constraintEqualToConstant:12],
        [self.chevronView.heightAnchor constraintEqualToConstant:16],
    ]];
}

@end

// MARK: - LauncherNewsViewController

@interface LauncherNewsViewController () <UICollectionViewDataSource, UICollectionViewDelegate>

@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UIButton *customizeButton;

// 磁贴配置
@property (nonatomic, strong) NSMutableArray<HomeTileConfig *> *allTileConfigs;
@property (nonatomic, strong) NSArray<NSArray<HomeTileConfig *> *> *displaySections;

// 数据
@property (nonatomic, strong) NSString *latestRelease;
@property (nonatomic, strong) NSString *latestSnapshot;
@property (nonatomic, strong) NSString *currentUsername;
@property (nonatomic, strong) UIImage *currentSkin;
@property (nonatomic, strong) UIImage *currentAvatar;
@property (nonatomic, assign) BOOL isLoadingVersions;

// 公告/更新检测
@property (nonatomic, strong) NSString *announcementText;
@property (nonatomic, assign) BOOL hasUpdate;
@property (nonatomic, strong) NSString *latestVersion;
// 公告系统（从官网拉取 JSON 的最新一条公告）
@property (nonatomic, strong, nullable) AnnouncementItem *latestAnnouncement;

// MC 新闻（首页 News tile 预览用，展示最新一条）
@property (nonatomic, strong, nullable) MinecraftNewsItem *latestNewsItem;
@property (nonatomic, assign) BOOL isLoadingNews;

@end

@implementation LauncherNewsViewController

- (id)init {
    self = [super init];
    if (self) {
        // 不设置 self.title，避免顶部导航栏出现"主页"标题黑条（参照 FCL 无 title 风格）
        self.latestRelease = localize(@"i18n_str_347", nil);
        self.latestSnapshot = localize(@"i18n_str_347", nil);
        self.isLoadingVersions = YES;
        self.announcementText = localize(@"i18n_str_348", nil);
        self.hasUpdate = NO;
    }
    return self;
}

- (NSString *)imageName {
    return @"MenuNews";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    self.navigationController.navigationBarHidden = YES;
    
    // 加载磁贴配置
    self.allTileConfigs = [[HomeTileConfig loadSavedConfigs] mutableCopy];
    [self rebuildDisplaySections];
    
    [self setupHeader];
    [self setupCollectionView];
    [self updateSkinDisplay];
    [self checkMinecraftVersions];
    [self checkForUpdate];
    [self loadLatestNewsForTile];
    [self loadAnnouncementsForTile];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 本控制器为 UIViewController 子类，其 collectionView 为手动创建，
    // makeViewControllerTransparent 会设置 view 背景透明；collectionView 背景已在 setupCollectionView 中清空。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateSkinDisplay)
                                                 name:@"AccountChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateSkinDisplay)
                                                 name:@"UpdateAccountInfo"
                                               object:nil];
}

// Task149：首帧默认头像保险——viewWillAppear 再跑一次 updateSkinDisplay
// （标签页往返/返回前台时补齐账号态；无账号时 avatarImageView 首帧
// 已由 setupBaseViews 直接呈现 DefaultAccount，点击前不再出现空白）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateSkinDisplay];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Task171：转场结束后补一次可见 Profile 卡直刷——viewWillAppear 期的
    // reloadSections 可能落在标签页转场中途被 UIKit 丢弃（重绘不发生），
    // 装机实测"切换标签页返回后头像缺失"。此刻 cells 必然已可见，直写
    // image 是最后的兑底（与 updateSkinDisplay 尾部的直刷同一 helper）。
    [self ame171_syncVisibleProfileAvatar];
    // Task172：转场完全落定后再补一刷（0.35s）。Task169/171 两轮装机仍
    // 复现"切标签页回来头像要点一下才显示"，且本类每次返回主页都是全新
    // 实例（showHomePage 每次 alloc）——viewDidAppear 时刻的直写仍可能
    // 落在集合视图与转场动画的窗口期内，此次延迟兑底保证至少有一次
    // 在完全静止的布局上写入。取证日志同步输出分支与可见卡计数。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Task175：直写 image 不足以对抗 crossDissolve 转场快照——静态层
        // 在转场窗口内被拍走后，真实 imageView 的更新要等下一次布局才上
        // 屏（装机实测"要点一下才显示"）。这里先 reloadProfileSection 走
        // cellForItemAt 全链（与首屏成功渲染同一条代码路径），再直写兜底：
        // 两道都过，静态快照论与重绘论同时封死。
        [strongSelf reloadProfileSection];
        [strongSelf ame171_syncVisibleProfileAvatar];
    });
}

// Task171：把 currentAvatar 直写所有可见 Profile 卡。Task169 的直刷只挂在
// 网络完成回调上，切标签页返回走会话缓存命中分支时只有 reloadSections
// （布局时序下不重绘）——头像缺失。本 helper 全分支兑底：updateSkinDisplay
// 尾部 + viewDidAppear + 网络完成回调三处共用。
- (void)ame171_syncVisibleProfileAvatar {
    if (self.currentAvatar == nil) {
        // Task172 取证：头像缺失时必须能从日志分辨"数据层就没有"还是
        // "写入了但没渲染"——前者看 updateSkinDisplay 的分支日志，后者
        // 看本方法后续的可见卡计数。
        NSLog(@"[HomeAvatar] Task172 sync skipped: currentAvatar is nil (check branch log above)");
        return;
    }
    NSInteger ame172_profileCells = 0;
    for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
        if ([cell isKindOfClass:HomeProfileTileCell.class]) {
            ame172_profileCells++;
            ((HomeProfileTileCell *)cell).avatarImageView.image = self.currentAvatar;
        }
    }
    NSLog(@"[HomeAvatar] Task172 direct-sync: %ld visible profile cell(s), image %ldx%ld",
          (long)ame172_profileCells,
          (long)self.currentAvatar.size.width, (long)self.currentAvatar.size.height);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// MARK: - Build Display Sections

- (void)rebuildDisplaySections {
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *currentCompactGroup = nil;
    
    for (HomeTileConfig *tile in self.allTileConfigs) {
        if (!tile.visible) continue;
        
        if (tile.tileSize == HomeTileSizeCompact) {
            if (!currentCompactGroup) {
                currentCompactGroup = [NSMutableArray array];
            }
            [currentCompactGroup addObject:tile];
            if (currentCompactGroup.count >= 2) {
                [sections addObject:[currentCompactGroup copy]];
                currentCompactGroup = nil;
            }
        } else {
            if (currentCompactGroup.count > 0) {
                [sections addObject:[currentCompactGroup copy]];
                currentCompactGroup = nil;
            }
            [sections addObject:@[tile]];
        }
    }
    if (currentCompactGroup.count > 0) {
        [sections addObject:[currentCompactGroup copy]];
    }
    
    self.displaySections = sections;
}

// MARK: - Header Setup

- (void)setupHeader {
    self.headerView = [[UIView alloc] init];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.headerView];
    
    self.headerTitleLabel = [[UILabel alloc] init];
    self.headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitleLabel.text = localize(@"i18n_str_349", nil);
    self.headerTitleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    self.headerTitleLabel.textColor = [UIColor labelColor];
    [self.headerView addSubview:self.headerTitleLabel];
    
    self.customizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.customizeButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *gearIcon = [UIImage systemImageNamed:@"slider.horizontal.3"];
    [self.customizeButton setImage:gearIcon forState:UIControlStateNormal];
    [self.customizeButton setTitle:[@" " stringByAppendingString:localize(@"preference.title.appicon-custom", nil)] forState:UIControlStateNormal];
    self.customizeButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.customizeButton.tintColor = [UIColor secondaryLabelColor];
    [self.customizeButton addTarget:self action:@selector(openCustomize) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.customizeButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:44],
        
        [self.headerTitleLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:20],
        [self.headerTitleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        
        [self.customizeButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-20],
        [self.customizeButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
    ]];
}

// MARK: - Collection View Setup

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.showsVerticalScrollIndicator = NO;
    self.collectionView.contentInset = UIEdgeInsetsMake(0, 0, 20, 0);
    
    [self.collectionView registerClass:[HomeProfileTileCell class]      forCellWithReuseIdentifier:@"ProfileCell"];
    [self.collectionView registerClass:[HomeInfoTileCell class]         forCellWithReuseIdentifier:@"InfoCell"];
    [self.collectionView registerClass:[HomeAnnouncementTileCell class] forCellWithReuseIdentifier:@"AnnouncementCell"];
    [self.collectionView registerClass:[HomeNewsTileCell class]         forCellWithReuseIdentifier:@"NewsCell"];
    [self.collectionView registerClass:[HomeShortcutTileCell class]     forCellWithReuseIdentifier:@"ShortcutCell"];
    
    [self.view addSubview:self.collectionView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

/// Task149：公告磁贴自适应高度机制退役（ame138_announcementTileHeight 删除）
/// ——公告/新闻磁贴与「最新正式版」磁贴等高（用户指令，固定 100），
/// 高度不够时简介优先截断到能显示的行（各 cell 内压缩序已就位）。
- (CGFloat)heightForTileConfig:(HomeTileConfig *)config {
    switch (config.tileType) {
        case HomeTileTypeProfile:
            return config.tileSize == HomeTileSizeFull ? 170 : 140;
        case HomeTileTypeAnnouncement:
            // Task149：与最新正式版卡片等高
            return 100;
        case HomeTileTypeVersionRelease:
        case HomeTileTypeVersionSnapshot:
            return 100;
        case HomeTileTypeNews:
            // Task149：与最新正式版卡片等高（原 120/100 双档退役）
            return 100;
        case HomeTileTypeShortcut:
            return 76;
        default:
            return 100;
    }
}

- (UICollectionViewLayout *)createLayout {
    __weak typeof(self) weakSelf = self;
    
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> env) {
        
        if (sectionIndex >= weakSelf.displaySections.count) return nil;
        
        NSArray *sectionTiles = weakSelf.displaySections[sectionIndex];
        HomeTileConfig *firstTile = sectionTiles.firstObject;
        BOOL isCompact = (firstTile.tileSize == HomeTileSizeCompact);
        CGFloat height = [weakSelf heightForTileConfig:firstTile];
        
        // Task170（用户定稿）："主页面每个卡片中间的间距改成外围的卡片距离
        // 侧边栏的间距一样长"——统一 20pt：外沿 = section 10 + item 10 = 20
        // （与旧形态 15+5=20 一致，外围观感不变）；卡间横向 = 10+10 = 20
        // （旧 5+5=10，加倍）；行间纵向 = 10+10 = 20（旧 5+5=10，加倍）。
        if (isCompact && sectionTiles.count >= 2) {
            // 双列紧凑布局
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.5]
                heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1.0]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            item.contentInsets = NSDirectionalEdgeInsetsMake(0, 10, 0, 10);
            
            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                heightDimension:[NSCollectionLayoutDimension absoluteDimension:height]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];
            
            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
            section.interGroupSpacing = 20; // 每节单组，防御性对齐 Task170 间距口径
            return section;
            
        } else {
            // 全宽 / 单个紧凑磁贴
            CGFloat wFrac = isCompact ? 0.5 : 1.0;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:wFrac]
                heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1.0]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            item.contentInsets = NSDirectionalEdgeInsetsMake(0, 10, 0, 10);
            
            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                heightDimension:[NSCollectionLayoutDimension absoluteDimension:height]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];
            
            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(10, 10, 10, 10);
            return section;
        }
    }];
}

// MARK: - UICollectionView DataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return self.displaySections.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.displaySections[section].count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    HomeTileConfig *config = self.displaySections[indexPath.section][indexPath.item];
    
    switch (config.tileType) {
        case HomeTileTypeProfile: {
            HomeProfileTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"ProfileCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            
            NSString *name = self.currentUsername ?: localize(@"i18n_str_351", nil);
            cell.welcomeLabel.text = [NSString stringWithFormat:localize(@"i18n_str_352", nil), name];
            // Task149：第二行回归原灰字问候语（Task141 公告标题行+按钮已退役，
            // 公告预览回归主页面公告卡片本体）
            cell.greetingLabel.text = festivalGreeting();
            // Task136：头像接管最左位置；有真实 MC 头像时铺满裁剪。
            // Task141：无头像（未选择账号/本地账户）时使用与应用列表同款的
            // DefaultAccount 默认头像（此前 SF person 占位符在白卡上观感"空白"）
            if (self.currentAvatar) {
                cell.avatarImageView.image = self.currentAvatar;
                cell.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
            } else {
                UIImage *defaultAvatar = [UIImage imageNamed:@"DefaultAccount"];
                if (defaultAvatar) {
                    cell.avatarImageView.image = defaultAvatar;
                    cell.avatarImageView.tintColor = nil;
                    cell.avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
                } else {
                    cell.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
                    cell.avatarImageView.tintColor = [UIColor systemGrayColor];
                    cell.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
                }
            }
            return cell;
        }
            
        case HomeTileTypeVersionRelease: {
            HomeInfoTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"InfoCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            cell.titleLabel.text = config.customTitle ?: localize(@"i18n_str_283", nil);
            cell.valueLabel.text = self.latestRelease;
            cell.iconView.image = [UIImage systemImageNamed:config.iconName ?: @"cube.box.fill"];
            cell.iconView.tintColor = [config accentColor];
            return cell;
        }
            
        case HomeTileTypeVersionSnapshot: {
            HomeInfoTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"InfoCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            cell.titleLabel.text = config.customTitle ?: localize(@"i18n_str_284", nil);
            cell.valueLabel.text = self.latestSnapshot;
            cell.iconView.image = [UIImage systemImageNamed:config.iconName ?: @"ant.fill"];
            cell.iconView.tintColor = [config accentColor];
            return cell;
        }
            
        case HomeTileTypeAnnouncement: {
            HomeAnnouncementTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"AnnouncementCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];

            // Task149：公告卡重排——标题/简介分离（样式对齐新闻卡片），
            // 查看详情按钮内联标题后；预览档位仅控制简介是否显示
            if (self.latestAnnouncement) {
                AnnouncementItem *ann = self.latestAnnouncement;
                NSString *previewLevel = getPrefObject(@"general.announcement_preview_level") ?: @"summary";

                cell.titleLabel.text = ann.title;
                BOOL ame149_showSummary = (![previewLevel isEqualToString:@"title_only"] && ann.summary.length > 0);
                cell.summaryLabel.text = ame149_showSummary ? ann.summary : nil;
                cell.summaryLabel.hidden = !ame149_showSummary;

                // 如果有 actionURL，内联按钮显示在标题后
                if (ann.actionURL.length > 0 && ann.actionTitle.length > 0) {
                    cell.actionButton.hidden = NO;
                    [cell.actionButton setTitle:ann.actionTitle forState:UIControlStateNormal];
                    cell.actionButton.backgroundColor = colorFromHex(@"#3B82F6");
                    [cell.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    [cell.actionButton removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
                    [cell.actionButton addTarget:self action:@selector(openAnnouncementActionURL) forControlEvents:UIControlEventTouchUpInside];
                } else {
                    cell.actionButton.hidden = YES;
                }
            } else {
                // 无公告数据时显示更新检测结果
                cell.titleLabel.text = self.announcementText;
                cell.summaryLabel.text = nil;
                cell.summaryLabel.hidden = YES;

                if (self.hasUpdate) {
                    cell.actionButton.hidden = NO;
                    [cell.actionButton setTitle:localize(@"i18n_str_353", nil) forState:UIControlStateNormal];
                    cell.actionButton.backgroundColor = colorFromHex(@"#3B82F6");
                    [cell.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    [cell.actionButton removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
                    [cell.actionButton addTarget:self action:@selector(downloadLatestVersion) forControlEvents:UIControlEventTouchUpInside];
                } else {
                    cell.actionButton.hidden = YES;
                }
            }
            return cell;
        }
            
        case HomeTileTypeNews: {
            HomeNewsTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"NewsCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];

            if (self.latestNewsItem) {
                // 显示最新一条新闻的标题/摘要/封面
                cell.titleLabel.text = self.latestNewsItem.title ?: localize(@"i18n_str_285", nil);
                cell.summaryLabel.text = self.latestNewsItem.summary ?: @"";
                cell.placeholderLabel.text = self.latestNewsItem.formattedDateString ?: @"";
                // 加载封面图（用 IconLoader，带缓存）
                [IconLoader cancelLoadingForImageView:cell.thumbnailView];
                if (self.latestNewsItem.imageURL.length > 0) {
                    [IconLoader loadIconForImageView:cell.thumbnailView
                                                 URL:self.latestNewsItem.imageURL
                                         placeholder:[UIImage systemImageNamed:@"newspaper.fill"]
                                            fallback:[UIImage systemImageNamed:@"newspaper.fill"]
                                        targetSize:CGSizeMake(160, 120)];
                } else {
                    cell.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
                }
            } else if (self.isLoadingNews) {
                cell.titleLabel.text = localize(@"i18n_str_285", nil);
                cell.summaryLabel.text = localize(@"i18n_str_354", nil);
                cell.placeholderLabel.text = localize(@"i18n_str_40", nil);
                cell.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
            } else {
                // 加载失败或未加载
                cell.titleLabel.text = localize(@"i18n_str_285", nil);
                cell.summaryLabel.text = localize(@"i18n_str_355", nil);
                cell.placeholderLabel.text = localize(@"i18n_str_356", nil);
                cell.thumbnailView.image = [UIImage systemImageNamed:@"newspaper.fill"];
            }
            return cell;
        }
            
        case HomeTileTypeShortcut: {
            HomeShortcutTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"ShortcutCell" forIndexPath:indexPath];
            [cell setAccentColor:[config accentColor]];
            cell.titleLabel.text = config.customTitle ?: localize(@"i18n_str_286", nil);
            cell.iconView.image = [UIImage systemImageNamed:config.iconName ?: @"arrow.right.circle.fill"];
            cell.iconView.tintColor = [config accentColor];
            return cell;
        }
    }
    
    // Fallback
    return [collectionView dequeueReusableCellWithReuseIdentifier:@"InfoCell" forIndexPath:indexPath];
}

// MARK: - UICollectionView Delegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    HomeTileConfig *config = self.displaySections[indexPath.section][indexPath.item];

    if (config.tileType == HomeTileTypeShortcut) {
        [self handleShortcutAction:config.shortcutAction];
    } else if (config.tileType == HomeTileTypeVersionRelease || config.tileType == HomeTileTypeVersionSnapshot) {
        [self checkMinecraftVersions];
    } else if (config.tileType == HomeTileTypeNews) {
        // 跳转到 MC 新闻列表页
        MinecraftNewsViewController *newsVC = [[MinecraftNewsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:newsVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        // 适配自定义启动器背景：透明化导航栏，让全局背景透出
        [self presentViewController:nav animated:YES completion:nil];
    } else if (config.tileType == HomeTileTypeAnnouncement) {
        // 跳转到公告列表页
        AnnouncementListViewController *listVC = [[AnnouncementListViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:listVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

// MARK: - Shortcut Actions

- (void)handleShortcutAction:(NSString *)action {
    if ([action isEqualToString:kShortcutActionMods]) {
        // 切到中间内容区版本管理页并直接展开模组管理（参照 FCL 安卓，不再 FormSheet 弹窗）
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowModsManager" object:nil];

    } else if ([action isEqualToString:kShortcutActionShaders]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowShadersManager" object:nil];

    } else if ([action isEqualToString:kShortcutActionModpack]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowModpackImport" object:nil];

    } else if ([action isEqualToString:kShortcutActionBackground]) {
        BackgroundSettingsViewController *vc = [[BackgroundSettingsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];

    } else if ([action isEqualToString:kShortcutActionVersions]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
    }
}

// MARK: - Customize

- (void)openCustomize {
    HomeCustomizeViewController *customVC = [[HomeCustomizeViewController alloc] init];
    customVC.tileConfigs = [self.allTileConfigs copy];
    
    __weak typeof(self) weakSelf = self;
    customVC.onConfigsChanged = ^(NSArray<HomeTileConfig *> *newConfigs) {
        weakSelf.allTileConfigs = [newConfigs mutableCopy];
        [HomeTileConfig saveConfigs:newConfigs];
        [weakSelf rebuildDisplaySections];
        
        // 重建布局并刷新
        weakSelf.collectionView.collectionViewLayout = [weakSelf createLayout];
        [weakSelf.collectionView reloadData];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:customVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    
    // 毛玻璃背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        nav.view.backgroundColor = [UIColor clearColor];
    }
    
    [self presentViewController:nav animated:YES completion:nil];
}

// MARK: - Data Loading

// Task162：主页头像会话级缓存（URL → UIImage）。旧实现每次 viewWillAppear
// 的 updateSkinDisplay 都裸 NSData dataWithContentsOfURL 重新下载，切标签页
// 返回时网络往返未完成 → cellForItem 先用旧值/默认头像渲染，弱网下头像
// 长时间“缺失”（用户实测：切其它标签页再回主页，顶部头像必须点一下才有）。
// 本缓存保证第二次进入同步命中；进程内有效（跨启动首次仍会下载一次）。
static NSCache<NSString *, UIImage *> *ame162_avatarCache(void) {
    static NSCache<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 16;
    });
    return cache;
}

- (void)updateSkinDisplay {
    BaseAuthenticator *auth = BaseAuthenticator.current;
    
    if (auth && auth.authData) {
        NSString *username = auth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.currentUsername = username;
        } else {
            self.currentUsername = localize(@"i18n_str_351", nil);
        }
        
        // 加载头像 (与右侧面板相同来源)。Task136：皮肤全身预览退场，
        // 不再请求全身渲染图，主页顶卡只显示 MC 头像。
        // Task162：三层链——① AvatarManager 本地自定义头像（与右面板
        // updateAccountInfo 同源，磁盘直读零延迟）；② 会话缓存（切标签页
        // 返回同步命中，不再闪烁默认头像）；③ 网络拉取（成功后回填缓存）。
        // Task169：第③层换 AvatarManager fetchAvatarFromURL（10s 超时 +
        // Caches 磁盘缓存 + 失败日志）——旧裸 dataWithContentsOfURL 默认
        // 60s 挂起且失败静默，装机实测"头像要点一下才能显示"；另加可见
        // Profile 卡直刷兜底（reloadSections 在个别布局时序下不触发重绘）。
        // Task180→Task183 保留：查询加 username 回退（与右面板同步——历史
        // username 文件名 / 账号 ID 漂移后的旧文件仍可命中；头像防御非
        // 透明度体系成员，不随本轮回退）
        UIImage *ame162_local = [[AvatarManager sharedManager]
            avatarForAccount:auth.authData[@"accountId"]
            usernameFallback:auth.authData[@"username"]];
        if (ame162_local) {
            self.currentAvatar = ame162_local;
            NSLog(@"[HomeAvatar] Task172 branch: AvatarManager local hit (%ldx%ld)",
                  (long)ame162_local.size.width, (long)ame162_local.size.height);
        } else {
            // Task185：脏 URL（首登顺序 bug 的历史产物）不作缓存键也不作首跳
            NSString *avatarURL = auth.authData[@"profilePicURL"];
            if ([avatarURL isKindOfClass:NSString.class] &&
                ([avatarURL containsString:@"(null)"] || [avatarURL containsString:@"(nil)"])) {
                avatarURL = nil;
            }
            if (avatarURL) {
                avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                UIImage *ame162_cached = [ame162_avatarCache() objectForKey:avatarURL];
                if (ame162_cached) {
                    // 命中缓存：同步上屏，本次不再发起网络请求
                    self.currentAvatar = ame162_cached;
                    NSLog(@"[HomeAvatar] Task172 branch: session cache hit (%ldx%ld)",
                          (long)ame162_cached.size.width, (long)ame162_cached.size.height);
                } else {
                    NSLog(@"[HomeAvatar] Task172 branch: network fetch started (URL present, length=%lu)",
                          (unsigned long)avatarURL.length);
                    [[AvatarManager sharedManager] ame185_fetchAvatarForAuthData:auth.authData completion:^(UIImage *img) {
                        // Task179：completion 全体主线程化（用户反馈的崩溃链：
                        // fetchAvatarFromURL completion → updateSkinDisplay →
                        // reloadProfileSection → cellForItemAtIndexPath →
                        // HomeProfileTileCell setupBaseViews → Auto Layout 崩溃。
                        // 头像域名解析失败只是触发条件，根因是后台线程碰 UIKit）。
                        dispatch_async(dispatch_get_main_queue(), ^{
                        if (img) {
                            [ame162_avatarCache() setObject:img forKey:avatarURL];
                        }
                        self.currentAvatar = img;
                        NSLog(@"[HomeAvatar] Task172 fetch completion: img=%@ (%ldx%ld)",
                              img ? @"yes" : @"nil",
                              (long)img.size.width, (long)img.size.height);
                        [self reloadProfileSection];
                        // Task169：直接同步可见 Profile 卡（保险路径）
                        if (img) {
                            [self ame171_syncVisibleProfileAvatar];
                        }
                        });  // Task179：dispatch_async(main) 收口
                    }];
                }
            } else {
                // Task185：无可用主 URL（缺失或脏数据）也走回退链
                //（crafatar UUID / minotar username），不再静默保持 nil。
                NSLog(@"[HomeAvatar] Task185 branch: no clean profilePicURL, trying avatar fallback chain (keys: %@)",
                      [auth.authData.allKeys componentsJoinedByString:@","]);
                [[AvatarManager sharedManager] ame185_fetchAvatarForAuthData:auth.authData completion:^(UIImage *img) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.currentAvatar = img;
                        NSLog(@"[HomeAvatar] Task185 fallback chain completion: img=%@", img ? @"yes" : @"nil");
                        [self reloadProfileSection];
                        if (img) {
                            [self ame171_syncVisibleProfileAvatar];
                        }
                    });
                }];
            }
        }
    } else {
        self.currentUsername = localize(@"i18n_str_357", nil);
        self.currentAvatar = nil;
    }
    
    [self reloadProfileSection];
    // Task171：缓存命中/本地头像分支同样直刷可见 Profile 卡（reloadSections
    // 的布局时序兑底，详见 ame171_syncVisibleProfileAvatar 注释）。
    [self ame171_syncVisibleProfileAvatar];
}

- (void)loadSkinForUUID:(NSString *)uuid {
    // Task220：原硬编码 http://111.170.35.224:3000 私有渲染镜像已死（明文
    // HTTP、无 TLS、无容错），换 crafatar 官方全身渲染 + minotar 回退
    //（FCL/HMCL 同款公开源，均接受 UUID）。注：本方法自 Task136 皮肤预览
    // 退役后已无调用者，修在死代码上防复活时带回死链。
    NSString *skinURL = [NSString stringWithFormat:@"https://crafatar.com/renders/body/%@?overlay", uuid];
    NSString *ame220_fallbackURL = [NSString stringWithFormat:@"https://minotar.net/body/%@/100.png", uuid];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:skinURL]];
        if (!data) {
            data = [NSData dataWithContentsOfURL:[NSURL URLWithString:ame220_fallbackURL]];
        }
        UIImage *skin = data ? [UIImage imageWithData:data] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (skin) {
                self.currentSkin = skin;
            } else {
                [self loadDefaultSkin];
                return;
            }
            [self reloadProfileSection];
        });
    });
}

- (void)loadDefaultSkin {
    // Task220：Steve 默认皮肤同源替换（原同样指向 111.170.35.224:3000 死
    // 镜像）：crafatar 官方默认皮肤 UUID → minotar 回退 → 本地占位图标。
    NSString *steveSkinURL = @"https://crafatar.com/renders/body/8667ba71b85a4004af54457a9734eed7?overlay";
    NSString *ame220_steveFallback = @"https://minotar.net/body/8667ba71b85a4004af54457a9734eed7/100.png";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:steveSkinURL]];
        if (!data) {
            data = [NSData dataWithContentsOfURL:[NSURL URLWithString:ame220_steveFallback]];
        }
        UIImage *steve = data ? [UIImage imageWithData:data] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.currentSkin = steve ?: [UIImage systemImageNamed:@"person.fill"];
            [self reloadProfileSection];
        });
    });
}

- (void)reloadProfileSection {
    // Task179：主线程守卫（别人反馈的异常崩溃：AvatarManager 头像下载
    // completion 在后台线程回调时直达此处 → 后台线程创建 cell / 改 Auto
    // Layout → NSInternalInconsistencyException "Modifications to the layout
    // engine must not be performed from a background thread"）。AvatarManager
    // 侧已保证主线程回调（Task172），这里再守一道——任何调用路径（未来的
    // 新回调点）都不再可能把 UIKit 工作带进后台线程。
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadProfileSection];
        });
        return;
    }
    // 找到 Profile 类型的 section 并刷新
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeProfile) {
                [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                return;
            }
        }
    }
}

- (void)loadLatestNewsForTile {
    if (self.isLoadingNews) return;
    self.isLoadingNews = YES;
    __weak typeof(self) weakSelf = self;
    [[MinecraftNewsService sharedService] fetchLatestNewsWithCompletion:^(NSArray<MinecraftNewsItem *> *items, NSInteger totalCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isLoadingNews = NO;
        if (items.count > 0) {
            strongSelf.latestNewsItem = items.firstObject;
        }
        // 刷新 News tile 显示最新标题/摘要/封面
        [strongSelf reloadNewsSection];
    }];
}

/// 重新加载 News tile 所在 section
- (void)reloadNewsSection {
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeNews) {
                [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                return;
            }
        }
    }
}

- (void)checkMinecraftVersions {
    self.isLoadingVersions = YES;
    self.latestRelease = localize(@"i18n_str_347", nil);
    self.latestSnapshot = localize(@"i18n_str_347", nil);
    [self reloadVersionSections];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *url;
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        url = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        url = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoadingVersions = NO;
            if (data && !error) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (json) {
                    NSDictionary *latest = json[@"latest"];
                    self.latestRelease = latest[@"release"] ?: localize(@"i18n_str_121", nil);
                    self.latestSnapshot = latest[@"snapshot"] ?: localize(@"i18n_str_121", nil);
                } else {
                    self.latestRelease = localize(@"i18n_str_358", nil);
                    self.latestSnapshot = localize(@"i18n_str_358", nil);
                }
            } else {
                self.latestRelease = localize(@"i18n_str_202", nil);
                self.latestSnapshot = localize(@"i18n_str_202", nil);
            }
            [self reloadVersionSections];
        });
    }];
    [task resume];
}

- (void)reloadVersionSections {
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeVersionRelease || tile.tileType == HomeTileTypeVersionSnapshot) {
                [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                return;
            }
        }
    }
}

// MARK: - Update Check

- (void)checkForUpdate {
    NSString *currentVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    
    if ([currentVersion rangeOfString:@"Preview" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        self.announcementText = localize(@"i18n_str_359", nil);
        self.hasUpdate = NO;
        [self reloadAnnouncementSection];
        return;
    }
    
    NSURL *url = [NSURL URLWithString:@"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ((NSHTTPURLResponse *)response).statusCode != 200 || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.announcementText = localize(@"i18n_str_360", nil);
                self.hasUpdate = NO;
                [self reloadAnnouncementSection];
            });
            return;
        }
        
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *latestVer = [self extractVersionFromHTML:html];
        
        if (!latestVer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.announcementText = localize(@"i18n_str_360", nil);
                self.hasUpdate = NO;
                [self reloadAnnouncementSection];
            });
            return;
        }
        
        if ([latestVer hasPrefix:@"v"]) {
            latestVer = [latestVer substringFromIndex:1];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSComparisonResult cmp = [self compareVersion:currentVersion withVersion:latestVer];
            if (cmp == NSOrderedAscending) {
                self.announcementText = [NSString stringWithFormat:localize(@"i18n_str_361", nil), latestVer];
                self.latestVersion = latestVer;
                self.hasUpdate = YES;
            } else {
                self.announcementText = localize(@"i18n_str_362", nil);
                self.hasUpdate = NO;
            }
            [self reloadAnnouncementSection];
        });
    }];
    [task resume];
}

- (void)reloadAnnouncementSection {
    for (NSInteger s = 0; s < self.displaySections.count; s++) {
        for (HomeTileConfig *tile in self.displaySections[s]) {
            if (tile.tileType == HomeTileTypeAnnouncement) {
                // Task149：reloadSections 走 performBatchUpdates——公告数据
                // 到达或预览档位变化时以 0.3s 平滑过渡呈现（自适应高度机制
                // 已退役，保留平滑刷新体验）。
                [self.collectionView performBatchUpdates:^{
                    [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:s]];
                } completion:^(BOOL finished) {
                    if (finished) [self.collectionView.collectionViewLayout invalidateLayout];
                }];
                return;
            }
        }
    }
}

// MARK: - Announcements (官网 JSON 公告)

/// 为首页公告磁贴拉取最新公告（取首条），失败时回退到更新检测文案
- (void)loadAnnouncementsForTile {
    __weak typeof(self) weakSelf = self;
    [[AnnouncementService sharedService] fetchAnnouncementsWithCompletion:^(NSArray<AnnouncementItem *> *items, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (items.count > 0) {
            strongSelf.latestAnnouncement = items.firstObject;
        }
        [strongSelf reloadAnnouncementSection];
    }];
}

/// 打开公告磁贴上 actionURL 指向的链接（SFSafariViewController 内嵌打开）
- (void)openAnnouncementActionURL {
    if (self.latestAnnouncement.actionURL.length > 0) {
        NSURL *url = [NSURL URLWithString:self.latestAnnouncement.actionURL];
        if (url) {
            SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
            safari.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:safari animated:YES completion:nil];
        }
    }
}

- (NSString *)extractVersionFromHTML:(NSString *)html {
    NSRange titleRange = [html rangeOfString:@"<title>"];
    if (titleRange.location == NSNotFound) return nil;
    
    NSString *afterTitle = [html substringFromIndex:NSMaxRange(titleRange)];
    NSRange endTitleRange = [afterTitle rangeOfString:@"</title>"];
    if (endTitleRange.location == NSNotFound) return nil;
    
    NSString *titleContent = [afterTitle substringToIndex:endTitleRange.location];
    
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"v([0-9]+\\.[0-9]+\\.[0-9]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:titleContent options:0 range:NSMakeRange(0, titleContent.length)];
    
    if (match) {
        return [titleContent substringWithRange:[match rangeAtIndex:1]];
    }
    return nil;
}

- (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2 {
    NSArray *c1 = [v1 componentsSeparatedByString:@"."];
    NSArray *c2 = [v2 componentsSeparatedByString:@"."];
    NSInteger max = MAX(c1.count, c2.count);
    
    for (NSInteger i = 0; i < max; i++) {
        NSInteger n1 = (i < c1.count) ? [c1[i] integerValue] : 0;
        NSInteger n2 = (i < c2.count) ? [c2[i] integerValue] : 0;
        if (n1 < n2) return NSOrderedAscending;
        if (n1 > n2) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

- (void)downloadLatestVersion {
    NSString *urlString = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest";
    NSURL *url = [NSURL URLWithString:urlString];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// MARK: - Cell Fade-In Animation

/// Task138：本会话已播过入场动画的 indexPath（防滚动重播）。
/// willDisplayCell 在每次滚动回滑、标签页往返时都会再次触发，无条件
/// 重播 alpha+位移入场会让列表"闪一下再弹一遍"（用户反馈的动画毛刺
/// 主源）。此集合按 indexPath 记忆首现：首次显示播 0.35s 弹簧入场，
/// 之后任何重复显示立即原样呈现，滚动丝滑无重播。
static NSMutableSet<NSIndexPath *> *ame138_animatedPaths = nil;

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ame138_animatedPaths = [NSMutableSet set];
    });
    if ([ame138_animatedPaths containsObject:indexPath]) {
        // 已播过：直接呈现（滚动回滑/标签页往返零重播）
        cell.alpha = 1;
        cell.transform = CGAffineTransformIdentity;
        return;
    }
    [ame138_animatedPaths addObject:indexPath];
    // Task138：stagger 细化到条目级（原仅按 section，同区条目同时弹出）：
    // 区级 0.04s + 条目级 0.02s 波浪感，上限 0.3s 防长列表尾部拖沓
    NSTimeInterval ame138_delay =
        MIN(0.3, indexPath.section * 0.04 + indexPath.item * 0.02);
    cell.alpha = 0;
    cell.transform = CGAffineTransformMakeTranslation(0, 12);
    [UIView animateWithDuration:0.35 delay:ame138_delay usingSpringWithDamping:0.85 initialSpringVelocity:0.3 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        cell.alpha = 1;
        cell.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// MARK: - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并手动清空 collectionView 背景色（UICollectionView 无 backgroundView 属性），
/// 确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.collectionView.backgroundColor = [UIColor clearColor];
}

@end