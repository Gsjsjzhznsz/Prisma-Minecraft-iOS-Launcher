#import <AuthenticationServices/AuthenticationServices.h>
#import "NMToast.h"

#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"
#import "AccountListViewController.h"
#import "AccountLoginViewController.h"
#import "ThirdPartyLoginViewController.h"
#import "AFNetworking.h"
#import "LauncherPreferences.h"
#import "UIImageView+AFNetworking.h"
#import "BackgroundManager.h"
// Task213：AmeCard 主/次文字色函数声明处（安装器同构卡配色依赖；CI 15.4 SDK
// 实锤"call to undeclared function 'AmeCardPrimaryTextColor'"——本地无 clang
// 的静态门没拦住，装机绿门在此收口）
#import "UIKit+NativeSurface.h"
#import "ScreenUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface AccountListViewController()<ASWebAuthenticationPresentationContextProviding>

@property(nonatomic, strong) NSMutableArray *accountList;
@property(nonatomic) ASWebAuthenticationSession *authVC;

@end

#pragma mark - AME190AccountCardCell（Task212：安装器卡列表同构账号卡片）

// 用户定稿（Task212 七问之七："账号列表重写为模组加载器列表修正后的样式，
// 头像放大一倍，字号和样式也改"）——账号卡与 installer/ModLoaderInstall-
// ViewController 的卡列表（ModLoaderVersionCell/ModLoaderRowCell，Task212
// 统一 50pt 行距配方）同构：
//   - 外层 cell 全透明（AME184ClearTableViewCellChrome 同款防御性清镀层语义
//     由手工清空保留）；旧 VMTileBaseCell 阴影/白 0.08 基底/白 0.10 描边/
//     shadowPath 随帧更新整组退役——安装器卡列表无阴影平贴
//   - contentContainer：12pt 连续圆角 + applyCardEffectToView 卡面管线
//     （与安装器 cell 逐字同一条管线调用），左右 0 内缩（inset-grouped
//     系统边距即安装器行边距，旧 ±24 内缩退役）
//   - 左侧 = 圆形头像放大一倍（dp:34 → dp:68，用户定稿"头像要放大一倍"）
//   - 标题 = 账号名 sp:16 semibold AmeCard 主文字色（旧 sp:15 label 色升级，
//     "其字号和样式也改"）
//   - 灰字 = 账号类型 sp:12 AmeCard 次文字色（旧 sp:11 secondary 升级）
//   - 选中徽章 = 20pt 绿圆角方块 + 白勾、右 -14 垂直居中（安装器
//     selectedBadge 同位同色；旧 accent top+10 位 + 边框/淡底三层强化退役）
//   - 触摸缩放弹簧动画删除（Task210"全部磁贴移除"动效冻结的账内清欠）
//   - 上下 4pt 内缩（版本卡 item contentInsets 语义，相邻卡面净距 8pt =
//     版本页 iPhone 档）+ 左右 24pt 总边距（版本页 section 16 + item 8）
@interface AME190AccountCardCell : UITableViewCell
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@property (nonatomic, strong) UIView *selectedBadge;
// ★ Task223（清单第 20 项）：行内可见操作按钮（“现在是要长按才能看到菜单，
//   需要在基础上添加元素进行操作”）——点开与长按同源的完整菜单。
@property (nonatomic, strong) UIButton *ame223_menuButton;
@property (nonatomic, copy, nullable) void (^ame223_onMenuTapped)(void);
- (void)ame190_configureWithUsername:(NSString *)username
                            typeText:(NSString *)typeText
                           avatarURL:(NSString *)avatarURLStr
                            selected:(BOOL)selected;
@end

@implementation AME190AccountCardCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self ame190_setupViews];
    }
    return self;
}

- (void)ame190_setupViews {
    // 外层 cell 全透明（plain 表格无 inset-grouped 系统白底，但选中高亮/
    // 复用重装仍防御性清一遍——ModLoaderInstall AME184ClearTableViewCellChrome
    // 同款配方）；裁剪逐层放行，阴影可越出卡片边界
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.clipsToBounds = NO;
    self.layer.masksToBounds = NO;
    self.contentView.clipsToBounds = NO;
    self.contentView.layer.masksToBounds = NO;
    UIView *clearSel = [[UIView alloc] init];
    clearSel.backgroundColor = [UIColor clearColor];
    clearSel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.selectedBackgroundView = clearSel;

    // Task212：阴影整组退役（安装器卡列表同款无阴影平贴）

    // ----- 卡片容器（VMTileBaseCell 规范 5.1：12pt 连续圆角卡面宿主）-----
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.layer.cornerRadius = 12;
    self.contentContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentContainer.layer.masksToBounds = YES;
    [self.contentView addSubview:self.contentContainer];

    // 卡面管线：Task212 与安装器 cell 同一条调用（applyCardEffectToView，
    // init 单次挂载即平贴 AmeCardSurfaceColor；旧 Task172 applyEffectTo-
    // TableViewCell 三段式泛型管线随 VMTileBaseCell 阴影镜像一并退役）
    [[BackgroundManager sharedManager] applyCardEffectToView:self.contentContainer];

    // ----- 左侧圆形头像（Task212 用户定稿放大一倍：dp:34 → dp:68）-----
    CGFloat ame190_avatarSize = [ScreenUtils dp:68];
    self.avatarView = [[UIImageView alloc] init];
    self.avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarView.contentMode = UIViewContentModeScaleAspectFill;
    self.avatarView.layer.cornerRadius = ame190_avatarSize / 2;
    self.avatarView.layer.cornerCurve = kCACornerCurveContinuous;
    self.avatarView.layer.masksToBounds = YES;
    self.avatarView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.avatarView.image = [UIImage imageNamed:@"DefaultAccount"];
    [self.contentContainer addSubview:self.avatarView];

    // ----- 标题 = 账号名（Task212：sp:16 semibold AmeCard 主文字色）-----
    self.usernameLabel = [[UILabel alloc] init];
    self.usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:16] weight:UIFontWeightSemibold];
    self.usernameLabel.textColor = AmeCardPrimaryTextColor();
    self.usernameLabel.numberOfLines = 1;
    self.usernameLabel.adjustsFontSizeToFitWidth = YES;
    self.usernameLabel.minimumScaleFactor = 0.75;
    self.usernameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentContainer addSubview:self.usernameLabel];

    // ----- 灰字 = 账号类型（Task212：sp:12 AmeCard 次文字色）-----
    self.typeLabel = [[UILabel alloc] init];
    self.typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.typeLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:12] weight:UIFontWeightRegular];
    self.typeLabel.textColor = AmeCardSecondaryTextColor();
    self.typeLabel.numberOfLines = 1;
    self.typeLabel.adjustsFontSizeToFitWidth = YES;
    self.typeLabel.minimumScaleFactor = 0.7;
    self.typeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentContainer addSubview:self.typeLabel];

    // ----- 选中徽章（Task212：安装器 selectedBadge 同款——20pt 绿圆角方块
    // + 白勾 9pt bold，右 -14 垂直居中）-----
    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = [UIColor systemGreenColor];
    self.selectedBadge.layer.cornerRadius = 10;
    self.selectedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.selectedBadge.layer.masksToBounds = YES;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    // ★ Task223（清单第 20 项）：行内 “⋯” 菜单按钮（长按菜单的可见入口，
    //   置于选中徽章左侧；未选中时也常驻——长按发现性问题根治）。
    self.ame223_menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.ame223_menuButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightMedium]]
        forState:UIControlStateNormal];
    self.ame223_menuButton.tintColor = AmeCardSecondaryTextColor();
    self.ame223_menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.ame223_menuButton addTarget:self action:@selector(ame223_menuTapped)
                     forControlEvents:UIControlEventTouchUpInside];
    [self.contentContainer addSubview:self.ame223_menuButton];

    CGFloat ame190_textLead = 16 + ame190_avatarSize + 12;   // 头像 leading 16 + 直径 + 12pt 间距
    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器：上下 4 / 左右 0 内缩（Task212 安装器行边距语义——
        // inset-grouped 的系统 margins 即行边距，旧 ±24 二次内缩退役）
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],

        // 头像：左 16，垂直居中，dp:68 圆；上下距卡缘 ≥4pt（行高由头像
        // 下限驱动：iPhone 76pt 卡 / iPad dp 放大后更高，自动行高自适应）
        [self.avatarView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.avatarView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.avatarView.widthAnchor constraintEqualToConstant:ame190_avatarSize],
        [self.avatarView.heightAnchor constraintEqualToConstant:ame190_avatarSize],
        [self.avatarView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentContainer.topAnchor constant:4],
        [self.avatarView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-4],

        // 文字块：头像右侧 12；标题顶 16 / 灰字紧跟 3 / 灰字底 16——
        // 高度链完整，自动行高（头像 68 + 8pt 呼吸 = 主导高度）
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:ame190_textLead],
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:16],
        [self.usernameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.ame223_menuButton.leadingAnchor constant:-8],

        [self.typeLabel.leadingAnchor constraintEqualToAnchor:self.usernameLabel.leadingAnchor],
        [self.typeLabel.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:3],
        [self.typeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.ame223_menuButton.leadingAnchor constant:-8],
        [self.typeLabel.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor constant:-16],

        // 选中徽章：右 -14 垂直居中（安装器同位）
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor],

        // Task223: menu button sits left of the badge, vertically centered.
        [self.ame223_menuButton.trailingAnchor constraintEqualToAnchor:self.selectedBadge.leadingAnchor constant:-10],
        [self.ame223_menuButton.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.ame223_menuButton.widthAnchor constraintEqualToConstant:32],
        [self.ame223_menuButton.heightAnchor constraintEqualToConstant:32],
    ]];
}

/// Task223: ellipsis button tap -> configured block.
- (void)ame223_menuTapped {
    if (self.ame223_onMenuTapped) self.ame223_onMenuTapped();
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.avatarView.image = [UIImage imageNamed:@"DefaultAccount"];
    self.usernameLabel.text = nil;
    self.typeLabel.text = nil;
    self.selectedBadge.hidden = YES;
    [self ame190_applySelectedAppearance:NO];
}

// Task212：选中态 = 绿徽章显隐（安装器同款；旧 accent 边框 + 淡底的三层
// 强化随卡面管线统一切换退役，选中反馈只来自徽章）
- (void)ame190_applySelectedAppearance:(BOOL)selected {
    self.selectedBadge.hidden = !selected;
    self.selectedBadge.backgroundColor = [UIColor systemGreenColor];
}

- (void)ame190_configureWithUsername:(NSString *)username
                            typeText:(NSString *)typeText
                           avatarURL:(NSString *)avatarURLStr
                            selected:(BOOL)selected {
    self.usernameLabel.text = username;
    self.typeLabel.text = typeText;

    if (avatarURLStr.length > 0) {
        NSString *pic = [avatarURLStr stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
        [self.avatarView setImageWithURL:[NSURL URLWithString:pic]
                        placeholderImage:[UIImage imageNamed:@"DefaultAccount"]];
    }
    [self ame190_applySelectedAppearance:selected];
}

// Task212：触摸缩放弹簧三段退役（Task210"全部磁贴移除"动效冻结的
// 账号页清欠；安装器卡列表同样无按压动效）。

@end

@implementation AccountListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.title = localize(@"login.title", @"账户管理");
    self.view.backgroundColor = [UIColor clearColor];

    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }

    // List accounts
    [self reloadAccountList];

    // 参照 FCL：卡片式账户列表，去除默认分割线，圆角卡片自带视觉分隔
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor clearColor];
    // Task212：行高自动维度——dp:68 头像 + 上下 4pt 内缩驱动
    //（iPhone 约 84pt 行 / 76pt 卡；iPad dp 放大后更高，自动行高自适应）
    self.tableView.estimatedRowHeight = 84;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    // 底部内边距避免最后一个 cell 被浮动按钮遮挡
    self.tableView.contentInset = UIEdgeInsetsMake(8, 0, 80, 0);
    self.tableView.scrollIndicatorInsets = self.tableView.contentInset;
    // 注册卡片 cell（Task190：已安装版本页同构 AME190AccountCardCell，
    // 正规复用替代旧"出列拆光重建"内联卡）
    [self.tableView registerClass:AME190AccountCardCell.class forCellReuseIdentifier:@"accountCardCell"];

    // 添加底部"添加账户"浮动按钮（FCL 风格）
    [self setupAddAccountButton];

    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // Task162：账号增删/切换后自动刷新列表（用户实测：添加账号完成后必须
    // 手动刷新账号标签页才出现）。旧实现只在 viewDidLoad 扫一次 accounts
    // 目录，push 登录页返回后列表过期。三个触发口：viewWillAppear（pop
    // 返回）、AccountChanged、UpdateAccountInfo。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame162_handleAccountsChanged)
                                                 name:@"AccountChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame162_handleAccountsChanged)
                                                 name:@"UpdateAccountInfo"
                                               object:nil];
}

// Task162：重扫 accounts 目录由文末既有的 reloadAccountList（FCL 风格，
// 含 reloadData）承担——viewWillAppear / AccountChanged / UpdateAccountInfo
// 三个新触发口全部复用它，勿在此重复实现（CI 实锤 duplicate declaration）。
- (void)ame162_handleAccountsChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadAccountList];
    });
}

/// 背景效果改变时重新应用透明化（由 BackgroundUIEffectChanged 通知触发）
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

// Task162：pop 返回本页时重扫账号目录——添加账户流程（push 登录页 →
// 登录成功 pop 回来）后新账号立即可见，无需手动刷新（reloadAccountList
// 自带 reloadData）。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAccountList];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupAddAccountButton {
    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [addBtn setTitle:localize(@"login.option.add", @"添加账户") forState:UIControlStateNormal];
    addBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [addBtn setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    addBtn.tintColor = [UIColor whiteColor];
    addBtn.backgroundColor = accentColor();
    addBtn.layer.cornerRadius = 24;
    addBtn.layer.cornerCurve = kCACornerCurveContinuous;
    addBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
    addBtn.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 0);
    // 投影增强浮动感（FCL 风格）
    addBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    addBtn.layer.shadowOpacity = 0.35;
    addBtn.layer.shadowOffset = CGSizeMake(0, 4);
    addBtn.layer.shadowRadius = 10;
    [addBtn addTarget:self action:@selector(addAccountTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:addBtn];
    // 使用 frameLayoutGuide（UITableView 的可见区域锚点）而非 safeAreaLayoutGuide，
    // 确保按钮随可见区域底部浮动，不会跟随 cell 滚动
    [NSLayoutConstraint activateConstraints:@[
        [addBtn.bottomAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor constant:-16],
        [addBtn.centerXAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.centerXAnchor],
        [addBtn.heightAnchor constraintEqualToConstant:48],
        [addBtn.widthAnchor constraintGreaterThanOrEqualToConstant:160]
    ]];
    self.addAccountButton = addBtn;
}

- (void)addAccountTapped {
    [self actionAddAccount:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // FCL 风格：列表只显示已有账户，添加账户改由底部浮动按钮触发
    return self.accountList.count;
}

/// 账号类型文字（Task190：用户定稿"灰字为账号类型"——原 Task136 彩色
/// 类型胶囊随卡片同构重写退役。Task220：判别口径与 loadSavedName / 选择链
///（Task128）统一为 accountType 优先，旧文件才回退键位嗅探——旧版先嗅
/// clientToken 再看 xboxGamertag，混合文件（微软+第三方键并存）会被打成
/// "第三方"，正版账号误判的病灶之一）
- (NSString *)ame190_accountTypeTextForAccount:(NSDictionary *)accountData {
    NSString *username = accountData[@"username"] ?: @"";
    if ([username hasPrefix:@"Demo."]) {
        return localize(@"login.option.demo", @"演示");
    }
    NSString *ame220_type = accountData[@"accountType"];
    if ([ame220_type isKindOfClass:NSString.class] && ame220_type.length > 0) {
        if ([ame220_type isEqualToString:@"thirdparty"]) {
            return localize(@"login.option.3rdparty", @"第三方");
        } else if ([ame220_type isEqualToString:@"local"]) {
            return localize(@"login.option.local", @"本地");
        }
        return @"Microsoft";
    }
    // 旧文件回退（与 loadSavedName 同口径：clientToken 先于 xboxGamertag）
    if (accountData[@"clientToken"] != nil) {
        return localize(@"login.option.3rdparty", @"第三方");
    } else if (accountData[@"xboxGamertag"] == nil) {
        return localize(@"login.option.local", @"本地");
    }
    return @"Microsoft";
}

/// Task220：第三方判别统一口径（accountType 显式优先，旧文件回退
/// clientToken 嗅探）——标签 / 长按菜单 / 选择链三处同源，杜绝混合文件串类
///（病历：Oct-4 装机日志，微软账号带着 LittleSkin authlib 注入启动）。
static BOOL ame220_accountIsThirdParty(NSDictionary *accountData) {
    if (![accountData isKindOfClass:NSDictionary.class]) return NO;
    NSString *ame220_type = accountData[@"accountType"];
    if ([ame220_type isKindOfClass:NSString.class] && ame220_type.length > 0) {
        return [ame220_type isEqualToString:@"thirdparty"];
    }
    return (accountData[@"clientToken"] != nil);
}

/// 当前选中的账户 accountId（用于卡片显示选中状态）
/// 使用 accountId 而非 username，确保同名账户也能正确区分选中状态
- (NSString *)currentSelectedAccountId {
    // BaseAuthenticator.current 保存当前活跃账户的 authData
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    return currentAuth.authData[@"accountId"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Task190：账号卡 = 已安装版本页同构 cell（AME190AccountCardCell，见
    // 文件头类注释）。旧实现每次出列拆除全部子视图重建（Task137/180 多轮
    // 内联卡叠加，卡面 = 白 0.10 + 16pt 圆角 + 旧管线，与版本页观感不一致
    // ——用户实测"白色外框里有了一条边"），现随新 cell 类正规复用；
    // 读侧去重/坏文件过滤（Task180 双保险）在 reloadAccountList 原样保留。
    AME190AccountCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"accountCardCell" forIndexPath:indexPath];
    if (indexPath.row >= self.accountList.count) return cell;
    NSDictionary *accountData = self.accountList[indexPath.row];

    // 标题 = 账号名（Demo 账户去掉前缀展示）
    NSString *displayName = accountData[@"username"] ?: @"";
    if ([displayName hasPrefix:@"Demo."]) {
        displayName = [displayName substringFromIndex:5];
    }

    // 选中态：accountId 精确比对（同名账户也能正确区分）
    NSString *selectedAccountId = [self currentSelectedAccountId];
    BOOL isCurrentSelected = (selectedAccountId.length > 0 &&
                              [selectedAccountId isEqualToString:accountData[@"accountId"]]);

    [cell ame190_configureWithUsername:displayName
                              typeText:[self ame190_accountTypeTextForAccount:accountData]
                             avatarURL:accountData[@"profilePicURL"]
                              selected:isCurrentSelected];
    // ★ Task223（清单第 20 项）：行内菜单按钮接通（与长按同源动作 + 高级项）。
    __weak typeof(self) weakSelf = self;
    cell.ame223_onMenuTapped = ^{
        [weakSelf ame223_showAccountMenuAtIndexPath:indexPath fromView:cell.ame223_menuButton];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self ame190_selectAccountAtIndexPath:indexPath];
}

/// Task190：账户选择流程收口（原 didSelectRowAtIndexPath 主体原样迁入）——
/// 点击卡片与长按菜单"选用账号"共用同一条选择链，杜绝双入口行为漂移。
- (void)ame190_selectAccountAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.accountList.count) return;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];

    self.modalInPresentation = YES;
    self.tableView.userInteractionEnabled = NO;
    [self addActivityIndicatorTo:cell];

    id callback = ^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            [self callbackMicrosoftAuth:status success:success forCell:cell];
        });
    };

    // Check if this is a third party account
    NSDictionary *accountData = self.accountList[indexPath.row];
    // 优先用 accountId 加载；若 accountId 缺失（旧格式账户未迁移），回退到 username 触发迁移
    NSString *loadKey = accountData[@"accountId"];
    if (loadKey.length == 0) {
        loadKey = accountData[@"username"];
    }
    // Task 128：判别统一走显式 accountType（旧文件回退 clientToken 嗅探），
    // 与 BaseAuthenticator.loadSavedName 同口径。
    // Task220：抽到 ame220_accountIsThirdParty，与标签/长按菜单同源。
    if (ame220_accountIsThirdParty(accountData)) {
        // This is a third party account
        ThirdPartyAuthenticator *ame128_auth = [ThirdPartyAuthenticator loadSavedName:loadKey];
        if ([self ame128_sessionValidated:loadKey]) {
            // zl2 同款 isSessionValidated：本会话已通过服务端校验，直接选中，
            // 不再每次选择都打 refresh（旧实现每次选择都请求，token 过期即
            // 硬失败弹错误窗 -> 账户永远选不中 -> "第三方登录完全使用不了"）。
            dispatch_async(dispatch_get_main_queue(), ^(){
                [self ame128_finishSelectionForCell:cell];
            });
        } else {
            [ame128_auth refreshTokenWithCallback:^(id status, BOOL success) {
                dispatch_async(dispatch_get_main_queue(), ^(){
                    if (success) {
                        [self ame128_markSessionValidated:loadKey];
                        [self callbackMicrosoftAuth:status success:YES forCell:cell];
                    } else {
                        // Task 128（zl2 同款优雅回退）：refresh 失败不再硬阻断选择。
                        // 旧实现：错误弹窗 -> 账户无法选中 -> 第三方账户形同虚设。
                        // 现在：仍然选中该账户（current 已由 loadSavedName 设置；
                        // selected_account 持久化），toast 提示重新登录可恢复完整
                        // 功能（皮肤/联机校验可能受限），游戏可正常启动。
                        NSLog(@"[ThirdPartyAuthenticator] Task128: refresh failed (%@) -- selecting with stale token, re-login suggested", [status isKindOfClass:[NSError class]] ? [(NSError *)status localizedDescription] : @"unknown");
                        [self ame128_markSessionValidated:loadKey];
                        setPrefObject(@"internal.selected_account", loadKey);
                        [self ame128_finishSelectionForCell:cell];
                        [NMToast showMessage:[NSString stringWithFormat:@"%@\n%@",
                            localize(@"login.3rdparty.stale.title", nil),
                            localize(@"login.3rdparty.stale.message", nil)]
                                      duration:6.0];
                    }
                });
            }];
        }
    } else {
        // This is a Microsoft or local account
        [[BaseAuthenticator loadSavedName:loadKey] refreshTokenWithCallback:callback];
    }
}

#pragma mark - Task 128: third-party selection resilience (zl2-style)

// 本会话已通过服务端校验的账户（loadKey 集合；zl2 isSessionValidated 同款语义）
static NSMutableSet *ame128_validatedSet(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

- (BOOL)ame128_sessionValidated:(NSString *)loadKey {
    if (loadKey.length == 0) return NO;
    return [ame128_validatedSet() containsObject:loadKey];
}

- (void)ame128_markSessionValidated:(NSString *)loadKey {
    if (loadKey.length > 0) [ame128_validatedSet() addObject:loadKey];
}

// 选中收尾：恢复交互、刷新列表、通知容器（与 callbackMicrosoftAuth 成功路径同款）
- (void)ame128_finishSelectionForCell:(UITableViewCell *)cell {
    if (cell) [self removeActivityIndicatorFrom:cell];
    self.modalInPresentation = NO;
    self.tableView.userInteractionEnabled = YES;
    [self reloadAccountList];
    if (self.whenItemSelected) self.whenItemSelected();
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Task190：长按菜单全账户化（用户定稿：长按呼出选项 —— (person.circle)
// 选用账号、(红字 trash) 删除账号）。原 Task129b 仅第三方多角色账户有
// 长按菜单、Task130b 又为其补了行内 person.2 按钮（长按发现性补偿）——
// 随卡片同构重写统一收敛到这一个长按菜单：所有账户均有两项主操作；
// 第三方多角色账户在两项之间保留 Task129b 的角色切换项
//（ame129b_switchAccountAtIndexPath → switchToProfile refresh 重绑，免密）。
// ★ Task223（清单第 20 项）：本菜单新增高级项（微软：改名/换皮肤；
//   第三方：换皮肤；离线：默认皮肤 Steve/Alex 选择），且行内 “⋯” 按钮
//   与长按共用同一套构建逻辑（ame223_buildAccountMenuActionsAtIndexPath）。
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
    point:(CGPoint)point API_AVAILABLE(ios(13.0)) {
    if (indexPath.row >= self.accountList.count) return nil;
    NSDictionary *accountData = self.accountList[indexPath.row];
    NSString *displayName = accountData[@"username"] ?: @"";
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSDictionary *it in [self ame223_accountMenuItemsAtIndexPath:indexPath]) {
        void (^handler)(void) = it[@"handler"];
        UIAction *a = [UIAction actionWithTitle:it[@"title"]
                                          image:([it[@"systemImage"] length] > 0
                                                     ? [UIImage systemImageNamed:it[@"systemImage"]] : nil)
                                     identifier:nil
                                         handler:^(UIAction * _Nonnull act) {
            if (handler) handler();
        }];
        if ([it[@"destructive"] boolValue]) a.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:a];
    }
    UIMenu *menu = [UIMenu menuWithTitle:displayName children:actions];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
            return menu;
        }];
}

/// Task223：完整菜单项（长按与行内 ⋯ 共用的单一事实源）。
/// 每项：title / systemImage / destructive / handler(void(^)(void))。
- (NSArray<NSDictionary *> *)ame223_accountMenuItemsAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.accountList.count) return @[];
    NSDictionary *accountData = self.accountList[indexPath.row];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];

    void (^ame223_add)(NSString *, NSString *, BOOL, void(^)(void)) = ^(NSString *title, NSString *sysImage, BOOL destructive, void(^handler)(void)) {
        [items addObject:@{
            @"title": title ?: @"",
            @"systemImage": sysImage ?: @"",
            @"destructive": @(destructive),
            @"handler": handler,
        }];
    };

    // ① 选用账号——与点击卡片同一条选择链
    ame223_add(localize(@"account.menu.use", @"选用账号"), @"person.circle", NO, ^{
        [self ame190_selectAccountAtIndexPath:indexPath];
    });

    // ② 第三方多角色账户：角色切换（当前角色标注前缀 ✓）
    BOOL is3P = ame220_accountIsThirdParty(accountData);
    NSArray *profiles = accountData[@"availableProfiles"];
    if (is3P && [profiles isKindOfClass:[NSArray class]] && profiles.count >= 2) {
        NSString *currentProfileId = accountData[@"profileId"];
        for (NSDictionary *p in profiles) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            NSString *pid = [p[@"id"] isKindOfClass:[NSString class]] ? p[@"id"] : nil;
            NSString *pname = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"?";
            if (pid.length == 0) continue;
            NSString *pidNorm = [pid stringByReplacingOccurrencesOfString:@"-" withString:@""];
            NSString *curNorm = [currentProfileId stringByReplacingOccurrencesOfString:@"-" withString:@""];
            NSString *title = [pidNorm isEqualToString:curNorm]
                ? [NSString stringWithFormat:@"✓ %@", pname] : pname;
            ame223_add(title, @"person.2", NO, ^{
                [self ame129b_switchAccountAtIndexPath:indexPath toProfile:p];
            });
        }
    }

    // ★ Task223（清单第 20 项）高级项：
    //   微软 → 更换游戏名字 / 更换皮肤（minecraft.net 官方页）；
    //   第三方 → 更换皮肤（认证服务器皮肤页）；
    //   离线 → 默认皮肤 Steve/Alex。
    NSString *accountType = accountData[@"accountType"];
    BOOL isLocal = [accountType isEqualToString:@"local"];
    BOOL isMicrosoft = [accountType isEqualToString:@"microsoft"];
    if (isMicrosoft) {
        ame223_add(localize(@"account.menu.change_name", @"更换游戏名字"), @"pencil.circle", NO, ^{
            [self ame223_openURLString:@"https://www.minecraft.net/profile"];
        });
        ame223_add(localize(@"account.menu.change_skin", @"更换皮肤"), @"paintbrush", NO, ^{
            [self ame223_openURLString:@"https://www.minecraft.net/profile"];
        });
    } else if (is3P) {
        ame223_add(localize(@"account.menu.change_skin", @"更换皮肤"), @"paintbrush", NO, ^{
            NSString *authserver = accountData[@"authserver"];
            NSString *url = @"https://littleskin.cn/user/profile";
            if ([authserver isKindOfClass:NSString.class] && authserver.length > 0) {
                NSString *base = authserver;
                NSRange apir = [base rangeOfString:@"/api/yggdrasil"];
                if (apir.location != NSNotFound) base = [base substringToIndex:apir.location];
                url = [base stringByAppendingString:@"/user/profile"];
            }
            [self ame223_openURLString:url];
        });
    } else if (isLocal) {
        ame223_add(localize(@"account.menu.default_skin", @"默认皮肤"), @"person.crop.square", NO, ^{
            [self ame223_pickOfflineDefaultSkinAtIndexPath:indexPath];
        });
    }

    // ③ 删除账号（红字破坏性）——与左滑删除同一条删除链
    ame223_add(localize(@"account.menu.delete", @"删除账号"), @"trash", YES, ^{
        [self ame190_deleteAccountAtIndexPath:indexPath];
    });

    return items;
}

/// Task223：行内 “⋯” 按钮的菜单呈现（iPad popover 锚点 / iPhone actionSheet）。
- (void)ame223_showAccountMenuAtIndexPath:(NSIndexPath *)indexPath fromView:(UIView *)sourceView {
    if (indexPath.row >= self.accountList.count) return;
    NSDictionary *accountData = self.accountList[indexPath.row];
    NSString *displayName = accountData[@"username"] ?: @"";
    NSArray<NSDictionary *> *items = [self ame223_accountMenuItemsAtIndexPath:indexPath];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:displayName
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *it in items) {
        void (^handler)(void) = it[@"handler"];
        UIAlertActionStyle style = [it[@"destructive"] boolValue] ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        [sheet addAction:[UIAlertAction actionWithTitle:it[@"title"] style:style handler:^(UIAlertAction * _Nonnull act) {
            if (handler) handler();
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", @"取消")
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView ?: self.view;
    sheet.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// Task223：URL 打开（菜单高级项共用）。
- (void)ame223_openURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

/// Task223（清单第 20 项）：离线账号默认皮肤选择（Steve / Alex 两张原版默认）。
/// 头像与 profilePicURL 同步落盘（账号文件 + keychain 无关字段），
/// 并提示其作用范围（启动器头像/支持皮肤协议的联机服务）。
- (void)ame223_pickOfflineDefaultSkinAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.accountList.count) return;
    NSDictionary *accountData = self.accountList[indexPath.row];
    NSString *loadKey = accountData[@"accountId"] ?: accountData[@"username"];
    if (loadKey.length == 0) return;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:localize(@"account.default_skin.title", @"默认皮肤")
                         message:localize(@"account.default_skin.hint", @"选择原版默认皮肤（Steve / Alex）")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Steve"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self ame223_applyOfflineSkinURL:@"https://minotar.net/helm/Steve/64.png"
                              forAccountAtIndexPath:indexPath loadKey:loadKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Alex"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self ame223_applyOfflineSkinURL:@"https://minotar.net/helm/Alex/64.png"
                              forAccountAtIndexPath:indexPath loadKey:loadKey];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", @"取消")
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)ame223_applyOfflineSkinURL:(NSString *)skinURL forAccountAtIndexPath:(NSIndexPath *)indexPath loadKey:(NSString *)loadKey {
    // 落盘：账号 json 的 profilePicURL（启动器头像链会重读；任务220 的
    // 脏 URL 自愈链同样读这里——写入合法可再派生 URL 即安全）。
    NSString *accountsDir = [@(getenv("POJAV_HOME")) ?: NSHomeDirectory()
        stringByAppendingPathComponent:@"accounts"];
    NSString *jsonPath = [accountsDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.json", loadKey]];
    NSMutableDictionary *acct = [NSMutableDictionary dictionaryWithContentsOfFile:jsonPath];
    if (![acct isKindOfClass:NSDictionary.class]) {
        [NMToast showMessage:localize(@"account.default_skin.failed", @"设置失败：账号文件不可读")];
        return;
    }
    acct[@"profilePicURL"] = skinURL;
    [acct writeToFile:jsonPath atomically:YES];
    [self reloadAccountList];
    [NMToast showMessage:[NSString stringWithFormat:localize(@"account.default_skin.done", @"已更新头像：%@"), skinURL.lastPathComponent]];
    NSLog(@"[AccountList] Task223: offline default skin set for %@ -> %@", loadKey, skinURL);
}

// Task190：Task130b 行内「切换角色」按钮（person.2 + actionSheet）随账号
// 卡片同构重写退役——卡片右侧仅保留选中徽章（用户定稿卡片无多余控件），
// 角色切换入口收敛进全账户长按菜单的 Task129b 角色项（ame129b_
// switchAccountAtIndexPath 免密链原样保留，见上方 contextMenu 实现）。

/// Task 129b：执行角色切换（长按菜单的 action 回调）
- (void)ame129b_switchAccountAtIndexPath:(NSIndexPath *)indexPath toProfile:(NSDictionary *)profile {
    if (indexPath.row >= self.accountList.count) return;
    NSDictionary *accountData = self.accountList[indexPath.row];
    NSString *loadKey = accountData[@"accountId"];
    if (loadKey.length == 0) loadKey = accountData[@"username"];
    if (loadKey.length == 0) return;

    NSLog(@"[AccountList] Task129b: switching profile for %@ -> %@", loadKey, profile[@"name"]);
    [NMToast showMessage:[NSString stringWithFormat:localize(@"account.switch_role.working", @"正在切换到 %@ …"), profile[@"name"]]];

    ThirdPartyAuthenticator *auth = [ThirdPartyAuthenticator loadSavedName:loadKey];
    if (!auth) return;
    [auth switchToProfile:profile callback:^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                NSLog(@"[AccountList] Task129b: profile switch OK (%@)", profile[@"name"]);
                [NMToast showMessage:[NSString stringWithFormat:localize(@"account.switch_role.done", @"已切换到 %@"), profile[@"name"]]];
                [self reloadAccountList];
            } else {
                NSString *errMsg = [status isKindOfClass:[NSError class]] ? [(NSError *)status localizedDescription]
                                 : ([status isKindOfClass:[NSString class]] ? status : localize(@"Error", nil));
                [NMToast showMessage:[NSString stringWithFormat:localize(@"account.switch_role.failed", @"切换失败：%@"), errMsg ?: @"?"]];
            }
        });
    }];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        // TODO: invalidate token
        [self ame190_deleteAccountAtIndexPath:indexPath];
    }
}

/// Task190：删除流程收口（原 commitEditingStyle 删除分支原样迁入）——
/// 左滑删除与长按菜单"删除账号"共用同一条删除链：whenDelete 回调、
/// MSA token 清理、账户文件删除、选中态清空、行删除动画。
- (void)ame190_deleteAccountAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.accountList.count) return;
    NSDictionary *accountData = self.accountList[indexPath.row];

    // 用 accountId 作为文件名（唯一标识），同名账户删除互不影响
    // 若 accountId 缺失（旧格式账户未迁移），回退到 username
    NSString *accountId = accountData[@"accountId"];
    if (accountId.length == 0) {
        accountId = accountData[@"username"];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
    if (self.whenDelete != nil) {
        self.whenDelete(accountId);
    }
    NSString *xuid = accountData[@"xuid"];
    if (xuid) {
        [MicrosoftAuthenticator clearTokenDataOfProfile:xuid];
    }
    [fm removeItemAtPath:path error:nil];
    // 若删除的正是当前选中账户，清空 selected_account，避免下次启动尝试加载已删除的账户
    if ([getPrefObject(@"internal.selected_account") isEqualToString:accountId]) {
        setPrefObject(@"internal.selected_account", @"");
        [BaseAuthenticator setCurrent:nil];
    }
    [self.accountList removeObjectAtIndex:indexPath.row];
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // 所有账户行都可滑动删除
    return UITableViewCellEditingStyleDelete;
}

- (NSDictionary *)parseQueryItems:(NSString *)url {
    NSMutableDictionary *result = [NSMutableDictionary new];
    NSArray<NSURLQueryItem *> *queryItems = [NSURLComponents componentsWithString:url].queryItems;
    for (NSURLQueryItem *item in queryItems) {
        result[item.name] = item.value;
    }
    return result;
}

- (void)actionAddAccount:(UIView *)sender {
    // 参照 FCL：push 卡片式登录方式选择页（替代原来的 ActionSheet）
    AccountLoginViewController *loginVC = [[AccountLoginViewController alloc] init];
    loginVC.onSelectLoginType = ^(AccountLoginType type) {
        // 选完登录方式后 pop 回账户列表，再触发对应登录流程
        [self.navigationController popViewControllerAnimated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            switch (type) {
                case AccountLoginTypeMicrosoft:
                    [self actionLoginMicrosoft:sender];
                    break;
                case AccountLoginTypeLittleSkin:
                    [self actionLoginLittleSkin:sender];
                    break;
                case AccountLoginTypeThirdParty:
                    [self actionLoginThirdParty:sender];
                    break;
                case AccountLoginTypeLocal:
                    [self actionLoginLocal:sender];
                    break;
            }
        });
    };
    [self.navigationController pushViewController:loginVC animated:YES];
}

- (void)actionLoginLocal:(UIView *)sender {
    if (getPrefBool(@"warnings.local_warn")) {
        setPrefBool(@"warnings.local_warn", NO);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"login.warn.title.localmode", nil) message:localize(@"login.warn.message.localmode", nil) preferredStyle:UIAlertControllerStyleActionSheet];
        // 修复：sender 为 nil 时（从 addAccountTapped -> actionAddAccount:nil 链路进入），
        // ActionSheet 在 iPad/LiveContainer 等 popover 场景下必须提供 sourceView，
        // 否则会因 popoverPresentationController.sourceView 为 nil 而崩溃。
        // 回退顺序：sender -> addAccountButton -> self.view 中心点。
        UIView *sourceView = sender ?: self.addAccountButton;
        if (sourceView) {
            alert.popoverPresentationController.sourceView = sourceView;
            alert.popoverPresentationController.sourceRect = sourceView.bounds;
        } else {
            alert.popoverPresentationController.sourceView = self.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
            alert.popoverPresentationController.permittedArrowDirections = 0;
        }
        UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {[self actionLoginLocal:sender];}];
        [alert addAction:ok];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:localize(@"Sign in", nil) message:localize(@"login.option.local", nil) preferredStyle:UIAlertControllerStyleAlert];
    [controller addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = localize(@"login.alert.field.username", nil);
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.borderStyle = UITextBorderStyleRoundedRect;
    }];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray *textFields = controller.textFields;
        UITextField *usernameField = textFields[0];
        if (usernameField.text.length < 3 || usernameField.text.length > 16) {
            controller.message = localize(@"login.error.username.outOfRange", nil);
            [self presentViewController:controller animated:YES completion:nil];
        } else {
            id callback = ^(id status, BOOL success) {
                if (self.whenItemSelected) self.whenItemSelected();
                [self dismissViewControllerAnimated:YES completion:nil];
            };
            [[[LocalAuthenticator alloc] initWithInput:usernameField.text] loginWithCallback:callback];
        }
    }]];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)actionLoginThirdParty:(UIView *)sender {
    // 参照 FCL：push 卡片式第三方登录表单页（替代原 UIAlertController 三字段输入）
    ThirdPartyLoginViewController *vc = [[ThirdPartyLoginViewController alloc] init];
    vc.mode = ThirdPartyLoginModeCustom;
    __weak typeof(self) weakSelf = self;
    vc.onLoginComplete = ^(BOOL success, NSString *errorMessage) {
        if (success) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
            if (weakSelf.whenItemSelected) weakSelf.whenItemSelected();
        }
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)actionLoginLittleSkin:(UIView *)sender {
    // 参照 FCL：push 卡片式 LittleSkin 登录表单页（替代原 UIAlertController 双字段输入）
    // LittleSkin 端点固定为 https://littleskin.cn/api/yggdrasil，由 VC 内部预设
    ThirdPartyLoginViewController *vc = [[ThirdPartyLoginViewController alloc] init];
    vc.mode = ThirdPartyLoginModeLittleSkin;
    __weak typeof(self) weakSelf = self;
    vc.onLoginComplete = ^(BOOL success, NSString *errorMessage) {
        if (success) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
            if (weakSelf.whenItemSelected) weakSelf.whenItemSelected();
        }
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)actionLoginMicrosoft:(UIView *)sender {
    NSURL *url = [NSURL URLWithString:@"https://login.live.com/oauth20_authorize.srf?client_id=00000000402b5328&response_type=code&scope=service%3A%3Auser.auth.xboxlive.com%3A%3AMBI_SSL&redirect_url=https%3A%2F%2Flogin.live.com%2Foauth20_desktop.srf"];

    self.authVC =
        [[ASWebAuthenticationSession alloc] initWithURL:url
        callbackURLScheme:@"ms-xal-00000000402b5328"
        completionHandler:^(NSURL * _Nullable callbackURL, NSError * _Nullable error)
    {
        if (callbackURL == nil) {
            if (error.code != ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
            }
            return;
        }
        // NSLog(@"URL returned = %@", [callbackURL absoluteString]);

        NSDictionary *queryItems = [self parseQueryItems:callbackURL.absoluteString];
        if (queryItems[@"code"]) {
            dispatch_async(dispatch_get_main_queue(), ^(){
                self.modalInPresentation = YES;
                self.tableView.userInteractionEnabled = NO;
                // 仅当 sender 是 UITableViewCell 时才显示加载指示器
                if ([sender isKindOfClass:[UITableViewCell class]]) {
                    [self addActivityIndicatorTo:(UITableViewCell *)sender];
                }
            });
            id callback = ^(id status, BOOL success) {
                if ([status isKindOfClass:NSString.class] && [status isEqualToString:@"DEMO"] && success) {
                    showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
                }
                dispatch_async(dispatch_get_main_queue(), ^(){
                    UITableViewCell *cell = [sender isKindOfClass:[UITableViewCell class]] ? (UITableViewCell *)sender : nil;
                    [self callbackMicrosoftAuth:status success:success forCell:cell];
                });
            };
            [[[MicrosoftAuthenticator alloc] initWithInput:queryItems[@"code"]] loginWithCallback:callback];
        } else {
            if ([queryItems[@"error"] hasPrefix:@"access_denied"]) {
                // Ignore access denial responses
                return;
            }
            showDialog(localize(@"Error", nil), queryItems[@"error_description"]);
        }
    }];

    self.authVC.prefersEphemeralWebBrowserSession = YES;
    self.authVC.presentationContextProvider = self;

    if ([self.authVC start] == NO) {
        showDialog(localize(@"Error", nil), @"Unable to open Safari");
    }
}

- (void)addActivityIndicatorTo:(UITableViewCell *)cell {
    UIActivityIndicatorViewStyle indicatorStyle = UIActivityIndicatorViewStyleMedium;
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:indicatorStyle];
    cell.accessoryView = indicator;
    [indicator sizeToFit];
    [indicator startAnimating];
}

- (void)removeActivityIndicatorFrom:(UITableViewCell *)cell {
    UIActivityIndicatorView *indicator = (id)cell.accessoryView;
    [indicator stopAnimating];
    cell.accessoryView = nil;
}

- (void)callbackMicrosoftAuth:(id)status success:(BOOL)success forCell:(UITableViewCell *)cell {
    if (status != nil) {
        if (success) {
            // Task 126：登录成功/状态提示改走 NMToast（新拟物卡片，自动消失，
            // 点击"查看"无动作需求）。旧 showDialog 的 level-1000 系统窗在
            // OK 后泄漏在场（"弹窗要手动删"的根源），且登录成功本无需用户
            // 做任何决定——非侵入提示即可。错误分支仍走 showDialog（错误
            // 详情需要阅读，且已修复 window 回收）。
            NSString *ame126_msg = nil;
            if ([status isKindOfClass:NSError.class]) {
                ame126_msg = [(NSError *)status localizedDescription];
            } else if ([status isKindOfClass:NSString.class]) {
                ame126_msg = (NSString *)status;
            }
            if (ame126_msg.length > 0) {
                [NMToast showMessage:[NSString stringWithFormat:@"%@：%@",
                    localize(@"login.title", @"账户"), ame126_msg]
                                  duration:6.0];
            }
            if ([status isKindOfClass:NSString.class] && [status isEqualToString:@"DEMO"]) {
                // 演示模式警告仍需用户知悉（影响后续离线体验预期），保留弹窗
                showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
            }
            // 登录成功后刷新列表以显示新账户
            if (cell) [self removeActivityIndicatorFrom:cell];
            self.modalInPresentation = NO;
            self.tableView.userInteractionEnabled = YES;
            [self reloadAccountList];
            if (self.whenItemSelected) self.whenItemSelected();
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            // 认证失败：恢复交互并展示错误
            self.modalInPresentation = NO;
            self.tableView.userInteractionEnabled = YES;
            if (cell) [self removeActivityIndicatorFrom:cell];

            if ([status isKindOfClass:[NSError class]]) {
                NSData *errorData = ((NSError *)status).userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
                if (errorData) {
                    NSString *errorStr = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                    NSLog(@"[MSA] Error: %@", errorStr);
                    showDialog(localize(@"Error", nil), errorStr);
                } else {
                    showDialog(localize(@"Error", nil), [status localizedDescription]);
                }
            } else if ([status isKindOfClass:[NSString class]]) {
                showDialog(localize(@"Error", nil), status);
            } else {
                showDialog(localize(@"Error", nil), localize(@"login.error.invalid_response", nil));
            }
        }
    } else if (success) {
        // 成功登录，无消息
        if (cell) [self removeActivityIndicatorFrom:cell];
        self.modalInPresentation = NO;
        self.tableView.userInteractionEnabled = YES;
        [self reloadAccountList];
        if (self.whenItemSelected) self.whenItemSelected();
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

/// 重新加载账户列表并刷新表格（FCL 风格：登录/删除后刷新卡片视图）
- (void)reloadAccountList {
    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }
    NSString *listPath = [NSString stringWithFormat:@"%s/accounts", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:listPath error:nil];
    // Task180：复制 bug 双保险②——读侧兜底。①按 accountId（缺省退文件名）
    // 去重：历史残留的重复 .json 只展示一份（写盘侧清理见 BaseAuthenticator
    // saveChanges 的 Task180 钩子，存量随每次选择逐步消除）；②过滤解析失败
    // 文件（parseJSONFromFile 失败时返回 @{@"NSErrorObject": ...}，旧代码照单
    // 全收会渲染成空白行，同样被用户感知为“多出来的条目”）。
    NSMutableSet *ame180_seenIds = [NSMutableSet set];
    for (NSString *file in files) {
        NSString *path = [listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if (!isDir && [file hasSuffix:@".json"]) {
            NSDictionary *data = parseJSONFromFile(path);
            if (data == nil || data[@"NSErrorObject"] != nil) {
                NSLog(@"[Task180] skipping unreadable account file: %@", file);
                continue;
            }
            NSString *ame180_key = data[@"accountId"] ?: [file stringByDeletingPathExtension];
            if ([ame180_seenIds containsObject:ame180_key]) {
                NSLog(@"[Task180] dedup account entry by id: %@", ame180_key);
                continue;
            }
            [ame180_seenIds addObject:ame180_key];
            [self.accountList addObject:data];
        }
    }
    [self.tableView reloadData];
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - ASWebAuthenticationPresentationContextProviding
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return UIApplication.sharedApplication.windows.firstObject;
}

@end
