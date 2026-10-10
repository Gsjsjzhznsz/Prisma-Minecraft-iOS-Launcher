//
//  ThirdPartyLoginViewController.m
//  Amethyst
//
//  参照 FCL 安卓版：LittleSkin / 自定义第三方登录表单页
//

#import "ThirdPartyLoginViewController.h"
#import "AmeNativeMenu.h"       // ★ Task240：菜单全面系统原生 UIMenu 化
#import "authenticator/ThirdPartyAuthenticator.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface ThirdPartyLoginViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UIImageView *headerIcon;
@property (nonatomic, strong) UILabel *headerTitle;
@property (nonatomic, strong) UILabel *headerSubtitle;

@property (nonatomic, strong) UIView *usernameCard;
@property (nonatomic, strong) UITextField *usernameField;

@property (nonatomic, strong) UIView *passwordCard;
@property (nonatomic, strong) UITextField *passwordField;

@property (nonatomic, strong) UIView *serverCard; // 仅 Custom 模式显示
@property (nonatomic, strong) UITextField *serverField;

// Task 129b：多服务器管理（FCL 参照）——已保存服务器条状列表 + 添加/删除
@property (nonatomic, strong) UIView *serversCard;   // 仅 Custom 模式且列表非空时显示
@property (nonatomic, strong) UIStackView *serverChipsStack;
@property (nonatomic, strong) NSLayoutConstraint *serversCardHeight;

@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UIActivityIndicatorView *loginIndicator;
@property (nonatomic, strong) UILabel *errorLabel;

@end

@implementation ThirdPartyLoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = [UIColor clearColor];
    self.title = (self.mode == ThirdPartyLoginModeLittleSkin) ? localize(@"i18n_str_2050", nil) : localize(@"i18n_str_1035", nil);

    [self setupUI];
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 点击空白收起键盘
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果改变时重新应用透明化（由 BackgroundUIEffectChanged 通知触发）
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
}

#pragma mark - Setup

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:20],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:20],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-20],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-20],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    [self buildHeaderCard];
    [self.contentStack addArrangedSubview:self.headerCard];

    [self buildUsernameCard];
    [self.contentStack addArrangedSubview:self.usernameCard];

    [self buildPasswordCard];
    [self.contentStack addArrangedSubview:self.passwordCard];

    if (self.mode == ThirdPartyLoginModeCustom) {
        [self buildServerCard];
        [self.contentStack addArrangedSubview:self.serverCard];
        // Task 129b：已保存服务器列表（恢复“可添加多个登录服务器”；
        // ALI 解析成功过的地址自动入库，点条回填地址栏，长按删除）
        [self buildServersCard];
        [self.contentStack addArrangedSubview:self.serversCard];
        [self rebuildServerChips];
    }

    // 错误提示（默认隐藏）
    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.font = [UIFont systemFontOfSize:13];
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.hidden = YES;
    [self.contentStack addArrangedSubview:self.errorLabel];

    [self buildLoginButton];
    [self.contentStack addArrangedSubview:self.loginButton];

    // 注册键盘事件，滚动避免遮挡
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)buildHeaderCard {
    self.headerCard = [[UIView alloc] init];
    self.headerCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.headerCard.layer.cornerRadius = 16;
    [[BackgroundManager sharedManager] applyEffectToView:self.headerCard];

    self.headerIcon = [[UIImageView alloc] init];
    self.headerIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerIcon.contentMode = UIViewContentModeScaleAspectFit;

    self.headerTitle = [[UILabel alloc] init];
    self.headerTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.headerTitle.textColor = [UIColor labelColor];

    self.headerSubtitle = [[UILabel alloc] init];
    self.headerSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerSubtitle.font = [UIFont systemFontOfSize:13];
    self.headerSubtitle.textColor = [UIColor secondaryLabelColor];
    self.headerSubtitle.numberOfLines = 0;

    if (self.mode == ThirdPartyLoginModeLittleSkin) {
        self.headerIcon.image = [UIImage systemImageNamed:@"person.fill.viewfinder"]
                              ?: [UIImage systemImageNamed:@"person.crop.circle.fill"];
        self.headerIcon.tintColor = [UIColor systemPurpleColor];
        self.headerTitle.text = @"LittleSkin";
        self.headerSubtitle.text = localize(@"i18n_str_1036", nil);
    } else {
        self.headerIcon.image = [UIImage systemImageNamed:@"globe"];
        self.headerIcon.tintColor = [UIColor systemOrangeColor];
        self.headerTitle.text = localize(@"i18n_str_1037", nil);
        self.headerSubtitle.text = localize(@"i18n_str_1038", nil);
    }

    [self.headerCard addSubview:self.headerIcon];
    [self.headerCard addSubview:self.headerTitle];
    [self.headerCard addSubview:self.headerSubtitle];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerIcon.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:16],
        [self.headerIcon.topAnchor constraintEqualToAnchor:self.headerCard.topAnchor constant:18],
        [self.headerIcon.widthAnchor constraintEqualToConstant:34],
        [self.headerIcon.heightAnchor constraintEqualToConstant:34],

        [self.headerTitle.leadingAnchor constraintEqualToAnchor:self.headerIcon.trailingAnchor constant:12],
        [self.headerTitle.centerYAnchor constraintEqualToAnchor:self.headerIcon.centerYAnchor],
        [self.headerTitle.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-16],

        [self.headerSubtitle.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:16],
        [self.headerSubtitle.topAnchor constraintEqualToAnchor:self.headerIcon.bottomAnchor constant:10],
        [self.headerSubtitle.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-16],
        [self.headerSubtitle.bottomAnchor constraintEqualToAnchor:self.headerCard.bottomAnchor constant:-16],
    ]];
}

/// 构建统一的输入卡片：左侧 SF Symbol 图标 + 右侧 UITextField
/// 返回卡片视图，并将创建好的 UITextField 赋值到 outField（可选）
- (UIView *)buildInputCardWithIcon:(NSString *)iconName
                       accentColor:(UIColor *)accentColor
                        placeholder:(NSString *)placeholder
                            isSecure:(BOOL)isSecure
                        keyboardType:(UIKeyboardType)keyboardType
                         returnField:(UITextField **)outField {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    [[BackgroundManager sharedManager] applyEffectToView:card];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [UIImage systemImageNamed:iconName];
    icon.tintColor = accentColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];

    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.font = [UIFont systemFontOfSize:16];
    field.textColor = [UIColor labelColor];
    field.secureTextEntry = isSecure;
    field.keyboardType = keyboardType;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    field.returnKeyType = UIReturnKeyNext;
    [card addSubview:field];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],

        [field.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [field.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [field.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    if (outField) *outField = field;
    return card;
}

- (void)buildUsernameCard {
    UITextField *field = nil;
    self.usernameCard = [self buildInputCardWithIcon:@"person"
                                         accentColor:[UIColor systemBlueColor]
                                          placeholder:localize(@"i18n_str_1039", nil)
                                            isSecure:NO
                                        keyboardType:UIKeyboardTypeDefault
                                         returnField:&field];
    self.usernameField = field;
}

- (void)buildPasswordCard {
    UITextField *field = nil;
    self.passwordCard = [self buildInputCardWithIcon:@"lock"
                                         accentColor:[UIColor systemBlueColor]
                                          placeholder:localize(@"i18n_str_1040", nil)
                                            isSecure:YES
                                        keyboardType:UIKeyboardTypeDefault
                                         returnField:&field];
    self.passwordField = field;
    self.passwordField.returnKeyType = (self.mode == ThirdPartyLoginModeCustom) ? UIReturnKeyNext : UIReturnKeyGo;
}

- (void)buildServerCard {
    UITextField *field = nil;
    self.serverCard = [self buildInputCardWithIcon:@"link"
                                       accentColor:[UIColor systemBlueColor]
                                        placeholder:localize(@"i18n_str_1041", nil)
                                          isSecure:NO
                                      keyboardType:UIKeyboardTypeURL
                                       returnField:&field];
    self.serverField = field;
    self.serverField.text = @"https://littleskin.cn/api/yggdrasil";
    self.serverField.returnKeyType = UIReturnKeyGo;
}

#pragma mark Task 129b - 已保存服务器列表（FCL 多服务器管理）

/// 存储键：general.thirdparty_servers（NSString 数组，plist 安全）。
/// 旧版只有单个地址输入框（每次登录都要重输）；现在 ALI 解析成功过的地址
/// 自动入库，点条回填，长按删除，恢复“之前可以添加服务器地址”的体验。
+ (NSMutableArray<NSString *> *)savedServerList {
    id raw = getPrefObject(@"general.thirdparty_servers");
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)raw) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                [list addObject:item];
            }
        }
    }
    return list;
}

+ (void)saveServerList:(NSArray<NSString *> *)list {
    setPrefObject(@"general.thirdparty_servers", list ?: @[]);
}

+ (void)rememberServer:(NSString *)url {
    if (![url isKindOfClass:[NSString class]] || url.length == 0) return;
    // 去掉尾部斜杠后去重
    NSString *normalized = [url hasSuffix:@"/"] ? [url substringToIndex:url.length - 1] : url;
    NSMutableArray<NSString *> *list = [self savedServerList];
    for (NSString *existing in list) {
        NSString *norm2 = [existing hasSuffix:@"/"] ? [existing substringToIndex:existing.length - 1] : existing;
        if ([norm2 isEqualToString:normalized]) return; // 已存在
    }
    [list addObject:url];
    // 上限 12 条，防无限增长
    if (list.count > 12) {
        [list removeObjectsInRange:NSMakeRange(0, list.count - 12)];
    }
    [self saveServerList:list];
    NSLog(@"[ThirdPartyLogin] Task129b: remembered server %@ (total %lu)", url, (unsigned long)list.count);
}

- (void)buildServersCard {
    self.serversCard = [[UIView alloc] init];
    self.serversCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.serversCard.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.serversCard.layer.cornerRadius = 16;
    self.serversCard.layer.cornerCurve = kCACornerCurveContinuous;
    self.serversCard.layer.borderWidth = 0.5;
    self.serversCard.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    self.serversCard.hidden = YES; // 列表为空时隐藏（rebuildServerChips 控制）

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = localize(@"login.thirdparty.servers.title", @"已保存的服务器");
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [UIColor secondaryLabelColor];
    [self.serversCard addSubview:title];

    self.serverChipsStack = [[UIStackView alloc] init];
    self.serverChipsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.serverChipsStack.axis = UILayoutConstraintAxisVertical;
    self.serverChipsStack.spacing = 8;
    [self.serversCard addSubview:self.serverChipsStack];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.serversCard.topAnchor constant:12],
        [title.leadingAnchor constraintEqualToAnchor:self.serversCard.leadingAnchor constant:14],
        [title.trailingAnchor constraintEqualToAnchor:self.serversCard.trailingAnchor constant:-14],
        [self.serverChipsStack.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.serverChipsStack.leadingAnchor constraintEqualToAnchor:self.serversCard.leadingAnchor constant:14],
        [self.serverChipsStack.trailingAnchor constraintEqualToAnchor:self.serversCard.trailingAnchor constant:-14],
        [self.serverChipsStack.bottomAnchor constraintEqualToAnchor:self.serversCard.bottomAnchor constant:-12],
    ]];
}

/// 每行一个服务器条：点按回填地址栏；长按确认删除
- (UIButton *)serverChipForURL:(NSString *)url {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    // 展示名：去掉协议前缀，取 host+首段路径，过长截断
    NSString *display = url;
    if ([display hasPrefix:@"https://"]) display = [display substringFromIndex:8];
    if ([display hasPrefix:@"http://"]) display = [display substringFromIndex:7];
    if (display.length > 34) display = [[display substringToIndex:31] stringByAppendingString:@"…"];
    [chip setTitle:display forState:UIControlStateNormal];
    [chip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:14];
    chip.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    chip.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    chip.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
    chip.layer.cornerRadius = 10;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    [chip.heightAnchor constraintEqualToConstant:38].active = YES;

    UIImage *icon = [UIImage systemImageNamed:@"server.rack"];
    [chip setImage:icon forState:UIControlStateNormal];
    chip.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
    chip.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);

    [chip addTarget:self action:@selector(serverChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    chip.accessibilityLabel = url;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(serverChipLongPressed:)];
    lp.minimumPressDuration = 0.5;
    [chip addGestureRecognizer:lp];
    return chip;
}

- (void)serverChipTapped:(UIButton *)sender {
    NSString *url = sender.accessibilityLabel;
    if (url.length == 0) return;
    self.serverField.text = url;
    [self.serverField resignFirstResponder];
    // 轻微视觉反馈
    [UIView animateWithDuration:0.08 animations:^{
        sender.alpha = 0.5;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.12 animations:^{
            sender.alpha = 1.0;
        }];
    }];
}

- (void)serverChipLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIButton *chip = (UIButton *)gesture.view;
    NSString *url = chip.accessibilityLabel;
    if (url.length == 0) return;

    // ★ Task240：换装系统原生 UIMenu（长按服务器 chip → 删除项；
    // 旧 actionSheet 确认壳退役）。
    [AmeNativeMenu ame240_presentMenuWithTitle:localize(@"login.thirdparty.servers.remove.title", @"删除该服务器？")
                                     dictItems:@[
        @{ @"title": localize(@"login.thirdparty.servers.remove.confirm", @"删除"), @"destructive": @YES, @"handler": ^{
            NSMutableArray<NSString *> *list = [ThirdPartyLoginViewController savedServerList];
            [list removeObject:url];
            [ThirdPartyLoginViewController saveServerList:list];
            [self rebuildServerChips];
        } },
    ] sourceView:chip];
}

- (void)rebuildServerChips {
    // 清空重建
    for (UIView *sub in self.serverChipsStack.arrangedSubviews) {
        [self.serverChipsStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }
    NSArray<NSString *> *list = [ThirdPartyLoginViewController savedServerList];
    for (NSString *url in list) {
        [self.serverChipsStack addArrangedSubview:[self serverChipForURL:url]];
    }
    self.serversCard.hidden = (list.count == 0);
}

- (void)buildLoginButton {
    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loginButton setTitle:localize(@"i18n_str_1042", nil) forState:UIControlStateNormal];
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    UIColor *accent = (self.mode == ThirdPartyLoginModeLittleSkin)
                        ? [UIColor systemPurpleColor]
                        : [UIColor systemOrangeColor];
    self.loginButton.backgroundColor = accent;
    self.loginButton.layer.cornerRadius = 14;
    [self.loginButton addTarget:self action:@selector(loginTapped) forControlEvents:UIControlEventTouchUpInside];

    self.loginIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.loginIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginIndicator.hidesWhenStopped = YES;
    [self.loginButton addSubview:self.loginIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [self.loginButton.heightAnchor constraintEqualToConstant:50],
        [self.loginIndicator.centerXAnchor constraintEqualToAnchor:self.loginButton.centerXAnchor],
        [self.loginIndicator.centerYAnchor constraintEqualToAnchor:self.loginButton.centerYAnchor],
    ]];
}

#pragma mark - Actions

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)loginTapped {
    [self dismissKeyboard];
    [self hideError];

    NSString *username = self.usernameField.text ?: @"";
    NSString *password = self.passwordField.text ?: @"";
    NSString *serverURL = nil;
    if (self.mode == ThirdPartyLoginModeCustom) {
        serverURL = (self.serverField.text.length > 0) ? self.serverField.text : nil;
    } else {
        serverURL = @"https://littleskin.cn/api/yggdrasil";
    }

    // 输入校验
    if (username.length == 0 || password.length == 0) {
        [self showError:localize(@"i18n_str_1043", nil)];
        return;
    }
    if (self.mode == ThirdPartyLoginModeCustom) {
        if (serverURL.length == 0) {
            [self showError:localize(@"i18n_str_1044", nil)];
            return;
        }
        NSURL *url = [NSURL URLWithString:serverURL];
        if (!url || !url.scheme || !url.host) {
            [self showError:localize(@"i18n_str_1045", nil)];
            return;
        }
    }

    [self setLoginInProgress:YES];

    // 参照 authlib-injector 启动器技术规范：登录前先解析 ALI，将简写地址解析为完整 API Root
    // 同时预取服务器元数据，用于启动时传 -Dauthlibinjector.yggdrasil.prefetched
    [self showError:localize(@"i18n_str_1046", nil)];
    self.errorLabel.textColor = [UIColor secondaryLabelColor];

    __weak typeof(self) weakSelf = self;
    [ThirdPartyAuthenticator resolveAuthserverURL:serverURL completion:^(NSString *resolvedURL, NSString *metadata) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf hideError];

        // Task 129b：ALI 解析成功 = 服务器可达且是合法 Yggdrasil 端点 ->
        // 自动存入已保存服务器列表（下次登录一键回填，恢复多服务器体验）
        if (strongSelf.mode == ThirdPartyLoginModeCustom && resolvedURL.length > 0) {
            [ThirdPartyLoginViewController rememberServer:resolvedURL];
            [strongSelf rebuildServerChips];
        }

        ThirdPartyAuthenticator *auth = [[ThirdPartyAuthenticator alloc] initWithInput:username];
        auth.authData[@"password"] = password;
        auth.authData[@"authserver"] = resolvedURL;
        // 缓存元数据，供 getJvmArgsForAuthlib 使用
        if (metadata.length > 0) {
            auth.authData[@"prefetchedMetadata"] = metadata;
        }

        // Task 129b（FCL 多角色管理）：多角色账户登录时弹出角色选择器，
        // 不再自动绑定第一个角色。选择器锚定在登录按钮上方（悬浮面板，
        // 与设置页 pick 一致）；取消则优雅终止登录。
        __weak typeof(strongSelf) weakSelf2 = strongSelf;
        auth.onProfileSelection = ^(NSArray<NSDictionary *> *profiles, ThirdPartyProfileChoice complete) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf2) sSelf = weakSelf2;
                if (!sSelf) {
                    complete(nil);
                    return;
                }
                // ★ Task240：换装系统原生 UIMenu（角色选择器；外部点按
                // 未选任何人 = 旧取消语义 → complete(nil)，流程不悬死）。
                NSMutableArray<NSDictionary *> *ame240_items = [NSMutableArray array];
                for (NSDictionary *p in profiles) {
                    NSString *pname = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"?";
                    [ame240_items addObject:@{
                        @"title": pname,
                        @"handler": ^{ complete(p); },
                    }];
                }
                [AmeNativeMenu ame240_presentMenuWithTitle:localize(@"login.thirdparty.profiles.title", @"选择要登录的角色")
                                                 dictItems:ame240_items
                                                sourceView:sSelf.loginButton
                                                onDismiss:^{ complete(nil); }];
            });
        };

        id callback = ^(id status, BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) sSelf = weakSelf;
                if (!sSelf) return;

                // 状态码为 0 的"进度"消息（如正在下载 authlib-injector）不算最终结果
                if (success && [status isKindOfClass:[NSError class]] &&
                    [(NSError *)status code] == 0) {
                    NSString *msg = [(NSError *)status localizedDescription];
                    if (msg.length > 0) {
                        [sSelf.errorLabel setText:msg];
                        sSelf.errorLabel.textColor = [UIColor secondaryLabelColor];
                        sSelf.errorLabel.hidden = NO;
                    }
                    return;
                }

                [sSelf setLoginInProgress:NO];

                if (success && (status == nil ||
                                ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]))) {
                    if ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]) {
                        showDialog(localize(@"login.warn.title.demomode", nil),
                                   localize(@"login.warn.message.demomode", nil));
                    }
                    if (sSelf.onLoginComplete) {
                        sSelf.onLoginComplete(YES, nil);
                    }
                    return;
                }

                // 失败
                NSString *errMsg;
                if ([status isKindOfClass:[NSError class]]) {
                    errMsg = [(NSError *)status localizedDescription];
                } else if ([status isKindOfClass:[NSString class]]) {
                    errMsg = status;
                } else {
                    errMsg = localize(@"i18n_str_1047", nil);
                }
                [sSelf showError:errMsg];
                if (sSelf.onLoginComplete) {
                    sSelf.onLoginComplete(NO, errMsg);
                }
            });
        };

        [auth loginWithCallback:callback];
    }];
}

- (void)setLoginInProgress:(BOOL)inProgress {
    self.loginButton.userInteractionEnabled = !inProgress;
    self.usernameField.userInteractionEnabled = !inProgress;
    self.passwordField.userInteractionEnabled = !inProgress;
    self.serverField.userInteractionEnabled = !inProgress;

    if (inProgress) {
        [self.loginIndicator startAnimating];
        [self.loginButton setTitle:@"" forState:UIControlStateNormal];
        self.loginButton.alpha = 0.85;
    } else {
        [self.loginIndicator stopAnimating];
        [self.loginButton setTitle:localize(@"i18n_str_1042", nil) forState:UIControlStateNormal];
        self.loginButton.alpha = 1.0;
    }
}

- (void)showError:(NSString *)message {
    self.errorLabel.text = message;
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.hidden = NO;
}

- (void)hideError {
    self.errorLabel.hidden = YES;
    self.errorLabel.text = @"";
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.usernameField) {
        [self.passwordField becomeFirstResponder];
    } else if (textField == self.passwordField) {
        if (self.mode == ThirdPartyLoginModeCustom && self.serverField) {
            [self.serverField becomeFirstResponder];
        } else {
            [self loginTapped];
        }
    } else if (textField == self.serverField) {
        [self loginTapped];
    }
    return YES;
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = endFrame.size.height;
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = keyboardHeight + 20;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
