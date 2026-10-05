#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadTasksViewController.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskProgressViewController.h"
#import "JavaGUIViewController.h"
#import "JavaLauncher.h"
#import "PLCrashView.h"
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "UIKit+NativeSurface.h"
#import "UIViewController+AMEPanel.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PickTextField.h"
#import "PLPickerView.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "installer/modpack/ModrinthAPI.h"

#include <sys/time.h>

#define AUTORESIZE_MASKS UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherNavigationController () <UIDocumentPickerDelegate, UIPickerViewDataSource, PLPickerViewDelegate, UIPopoverPresentationControllerDelegate> {
}

@property(nonatomic) MinecraftResourceDownloadTask* task;
@property(nonatomic) PLPickerView* versionPickerView;
@property(nonatomic) UITextField* versionTextField;
@property(nonatomic) int profileSelectedAt;
// Task162（选择器键稳定化）：主页版本选择器的行→profile 映射快照（字典键，
// 排序后固定顺序）。旧实现每次 dataSource 回调都实时取 profiles.allValues
//（无序，字典变更后顺序可能变），且 didSelectRow 把【name 字段】写进
// selectedProfileName——键≠名（整合包重名导入 " (2)"）时选中错档/
// 指向不存在的条目，叠加 ProfileSettings 的幻影写入，就是装机实测
// “切换渲染器为其他都会自动切回自动”的另一半根因。
@property(nonatomic, strong) NSArray<NSString *> *ame162PickerKeys;

// ===== 下载中心入口（参照 FCL/ZL2/HMCL 下载进度弹窗入口）=====
// 在工具栏上添加"下载中心"按钮，点击后弹出 DownloadTasksViewController，
// 集中显示所有下载任务的进度（MC本体/模组/光影/资源包/数据包/世界存档/整合包）。
// 所有通过 DownloadTaskManager 注册的下载任务都统一由这个弹窗显示进度。
@property(nonatomic, strong) UIButton *downloadCenterButton;
@property(nonatomic, strong) UIActivityIndicatorView *downloadCenterActivityIndicator;
@property(nonatomic, strong) UILabel *downloadCenterProgressLabel;
// 进行中任务数徽标（redesign-download-ui Task 2.4）：红色圆形小徽标
// 叠在按钮左侧下载图标右上角，显示进行中（下载中/排队中）任务数
@property(nonatomic, strong) UILabel *downloadCenterBadgeLabel;
@property(nonatomic, weak) DownloadTasksViewController *presentedDownloadCenterVC;
// 标记用户是否手动关闭了下载中心（避免下载任务更新时反复自动弹出）
@property(nonatomic, assign) BOOL userDismissedDownloadCenter;

@end

@implementation LauncherNavigationController

// Task 127（单一执法点）→ Task137 原生化：所有子级面板的原生基底样式。
// 主界面/设置页之外的推入子面板统一回归 iOS 原生页面底色（systemBackground）。
// 在 pushViewController: 与 viewDidAppear:（根面板）统一调用
// ame_applySubpanelBaseStyle（幂等；透明定制面板自动跳过，
// 见 UIViewController+AMEPanel.h 头注释），现存与未来新增的子面板
// 全部自动继承，无需逐个改造。
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    [super pushViewController:viewController animated:animated];
    [viewController ame_applySubpanelBaseStyle];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 根面板（LauncherNewsViewController 等）也吃基底样式；
    // viewDidAppear 而非 viewDidLoad：确保 view 已加载（loadView 惰性）
    [self.viewControllers.firstObject ame_applySubpanelBaseStyle];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    if ([self respondsToSelector:@selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)]) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }

    self.versionTextField = [[PickTextField alloc] initWithFrame:CGRectMake(4, 4, self.toolbar.frame.size.width * 0.8 - 8, self.toolbar.frame.size.height - 8)];
    [self.versionTextField addTarget:self.versionTextField action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    self.versionTextField.autoresizingMask = AUTORESIZE_MASKS;
    self.versionTextField.placeholder = @"Specify version...";
    self.versionTextField.leftView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    self.versionTextField.rightView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"SpinnerArrow"] _imageWithSize:CGSizeMake(30, 30)]];
    self.versionTextField.rightView.frame = CGRectMake(0, 0, self.versionTextField.frame.size.height * 0.9, self.versionTextField.frame.size.height * 0.9);
    self.versionTextField.leftViewMode = UITextFieldViewModeAlways;
    self.versionTextField.rightViewMode = UITextFieldViewModeAlways;
    self.versionTextField.textAlignment = NSTextAlignmentCenter;

    self.versionPickerView = [[PLPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    UIToolbar *versionPickToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width, 44.0)];

    [self reloadProfileList];

    // 监听配置文件列表刷新通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadProfileList)
                                                 name:@"ReloadProfileList"
                                               object:nil];

    UIBarButtonItem *versionFlexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:self action:nil];
    UIBarButtonItem *versionDoneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)];
    versionPickToolbar.items = @[versionFlexibleSpace, versionDoneButton];
    self.versionTextField.inputAccessoryView = versionPickToolbar;
    self.versionTextField.inputView = self.versionPickerView;

    UIView *targetToolbar = self.toolbar;
    [targetToolbar addSubview:self.versionTextField];

    self.buttonInstall = [UIButton buttonWithType:UIButtonTypeSystem];
    setButtonPointerInteraction(self.buttonInstall);
    [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
    self.buttonInstall.autoresizingMask = AUTORESIZE_MASKS;
    // Task137：恢复 Task89 之前的原生主按钮（品牌紫底白字）
    self.buttonInstall.backgroundColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:1.0];
    self.buttonInstall.layer.cornerRadius = 5;
    self.buttonInstall.frame = CGRectMake(self.toolbar.frame.size.width * 0.8, 4, self.toolbar.frame.size.width * 0.2, self.toolbar.frame.size.height - 8);
    self.buttonInstall.tintColor = UIColor.whiteColor;
    self.buttonInstall.enabled = NO;
    [self.buttonInstall addTarget:self action:@selector(performInstallOrShowDetails:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [targetToolbar addSubview:self.buttonInstall];

    // ===== 下载中心入口按钮（参照 FCL/ZL2/HMCL 下载进度弹窗入口）=====
    // 在工具栏左侧添加一个"下载中心"按钮，当有下载任务时显示，
    // 点击弹出 DownloadTasksViewController（FormSheet 方式），集中显示所有下载任务进度。
    // 按钮布局：[图标] [进度百分比] [活动指示器]
    CGFloat dcBtnWidth = 72.0;
    CGFloat dcBtnHeight = self.toolbar.frame.size.height - 8;
    self.downloadCenterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    // 不使用按钮的 title 显示文字，改用独立的 progressLabel 避免与图标布局冲突
    // Task137：恢复 Task89 之前的原生入口按钮（品牌紫底 + 白色图标）
    self.downloadCenterButton.backgroundColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:0.85];
    self.downloadCenterButton.layer.cornerRadius = 5;
    self.downloadCenterButton.frame = CGRectMake(4, 4, dcBtnWidth, dcBtnHeight);
    self.downloadCenterButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    [self.downloadCenterButton setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
    self.downloadCenterButton.tintColor = [UIColor whiteColor];
    // 图标固定在按钮左侧
    CGFloat iconSize = 22.0;
    [self.downloadCenterButton setImageEdgeInsets:UIEdgeInsetsMake(0, 4, 0, dcBtnWidth - iconSize - 4)];
    [self.downloadCenterButton addTarget:self action:@selector(openDownloadCenter) forControlEvents:UIControlEventTouchUpInside];
    self.downloadCenterButton.hidden = YES;
    [targetToolbar addSubview:self.downloadCenterButton];

    // 活动指示器（按钮右侧，下载中时旋转）
    self.downloadCenterActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    // Task137：恢复原生白色指示器（原紫色按钮底假设）
    self.downloadCenterActivityIndicator.color = [UIColor whiteColor];
    self.downloadCenterActivityIndicator.hidesWhenStopped = YES;
    CGFloat indicatorSize = 20.0;
    self.downloadCenterActivityIndicator.frame = CGRectMake(dcBtnWidth - indicatorSize - 4, (dcBtnHeight - indicatorSize) / 2.0, indicatorSize, indicatorSize);
    self.downloadCenterActivityIndicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.downloadCenterButton addSubview:self.downloadCenterActivityIndicator];

    // 进度百分比标签（按钮中间，显示聚合进度百分比）
    self.downloadCenterProgressLabel = [[UILabel alloc] init];
    self.downloadCenterProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
    self.downloadCenterProgressLabel.textColor = [UIColor whiteColor];
    self.downloadCenterProgressLabel.textAlignment = NSTextAlignmentCenter;
    self.downloadCenterProgressLabel.text = @"";
    self.downloadCenterProgressLabel.frame = CGRectMake(iconSize + 6, 0, dcBtnWidth - iconSize - indicatorSize - 12, dcBtnHeight);
    self.downloadCenterProgressLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.downloadCenterButton addSubview:self.downloadCenterProgressLabel];

    // 进行中任务数徽标（redesign-download-ui Task 2.4）：红色圆形小徽标叠在
    // 左侧下载图标右上角（app 图标徽标风格），无进行中任务时隐藏。
    // 按钮内部已无空余空间（图标+百分比+指示器排满），叠图标视觉损耗最小。
    self.downloadCenterBadgeLabel = [[UILabel alloc] init];
    self.downloadCenterBadgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
    self.downloadCenterBadgeLabel.textColor = [UIColor whiteColor];
    self.downloadCenterBadgeLabel.backgroundColor = [UIColor systemRedColor];
    self.downloadCenterBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.downloadCenterBadgeLabel.layer.cornerRadius = 8.0;
    self.downloadCenterBadgeLabel.layer.masksToBounds = YES;
    self.downloadCenterBadgeLabel.frame = CGRectMake(iconSize - 10, 0, 16, 16);
    self.downloadCenterBadgeLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    self.downloadCenterBadgeLabel.hidden = YES;
    [self.downloadCenterButton addSubview:self.downloadCenterBadgeLabel];

    [self fetchRemoteVersionList];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(receiveNotification:)
        name:@"InstallModpack"
        object:nil];

    // ===== 下载中心入口通知监听 =====
    // 监听 DownloadTaskManager 的通知，当有新下载任务注册或进度更新时：
    // 1. 更新下载中心按钮的显示状态和进度百分比
    // 2. 自动弹出下载中心弹窗（如果用户未手动关闭且没有其他模态视图）
    // 这确保了模组、光影、资源包等所有下载都能通过下载中心统一显示进度。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskUpdate:)
                                                 name:DownloadTaskManagerDidUpdateTaskNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
    // 监听下载中心被用户手动关闭的通知，设置标记避免反复自动弹出
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadCenterDismissed)
                                                 name:@"DownloadCenterDidDismiss"
                                               object:nil];

    if ([BaseAuthenticator.current isKindOfClass:MicrosoftAuthenticator.class]) {
        // Perform token refreshment on startup
        [self setInteractionEnabled:NO forDownloading:NO];
        id callback = ^(id status, BOOL success) {
            status = [status description];
            if (status == nil) {
                [self setInteractionEnabled:YES forDownloading:NO];
            } else if (!success) {
                showDialog(localize(@"Error", nil), status);
            }
        };
        [BaseAuthenticator.current refreshTokenWithCallback:callback];
    }
}

- (BOOL)isVersionInstalled:(NSString *)versionId {
    NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    BOOL isDirectory;
    [NSFileManager.defaultManager fileExistsAtPath:localPath isDirectory:&isDirectory];
    return isDirectory;
}

- (void)fetchLocalVersionList {
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:Nil];
    for (NSString *versionId in list) {
        if (![self isVersionInstalled:versionId]) continue;
        [localVersionList addObject:@{
            @"id": versionId,
            @"type": @"custom"
        }];
    }
}

- (void)fetchRemoteVersionList {
    self.buttonInstall.enabled = NO;
    remoteVersionList = @[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ].mutableCopy;

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    // 配置响应序列化器以接受application/octet-stream
    AFJSONResponseSerializer *serializer = [AFJSONResponseSerializer serializer];
    [serializer setAcceptableContentTypes:[NSSet setWithObjects:@"application/json", @"text/json", @"text/javascript", @"application/octet-stream", nil]];
    manager.responseSerializer = serializer;
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    [manager GET:versionManifestURL parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSDictionary *responseObject) {
        [remoteVersionList addObjectsFromArray:responseObject[@"versions"]];
        NSDebugLog(@"[VersionList] Got %d versions", remoteVersionList.count);
        setPrefObject(@"internal.latest_version", responseObject[@"latest"]);
        self.buttonInstall.enabled = YES;
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSDebugLog(@"[VersionList] Warning: Unable to fetch version list: %@", error.localizedDescription);
        self.buttonInstall.enabled = YES;
    }];
}

- (void)fetchRemoteVersionListForce:(BOOL)force {
    // 直接调用 fetchRemoteVersionList，忽略 force 参数
    [self fetchRemoteVersionList];
}

// Invoked by: startup, instance change event
- (void)reloadProfileList {
    // Reload local version list
    [self fetchLocalVersionList];
    // Reload launcher_profiles.json
    [PLProfiles updateCurrent];
    [self ame162RefreshPickerKeys];
    [self.versionPickerView reloadAllComponents];
    // Reload selected profile info
    self.profileSelectedAt = (int)[self.ame162PickerKeys indexOfObject:PLProfiles.current.selectedProfileName];
    if (self.profileSelectedAt == -1) {
        // This instance has no profiles?
        return;
    }
    [self.versionPickerView selectRow:self.profileSelectedAt inComponent:0 animated:NO];
    [self pickerView:self.versionPickerView didSelectRow:self.profileSelectedAt inComponent:0];
}

// Task162：重建选择器键快照（排序 → 行号稳定；字典增删后行号不漂移）。
- (void)ame162RefreshPickerKeys {
    NSArray *keys = PLProfiles.current.profiles.allKeys;
    self.ame162PickerKeys = [keys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 关键修复（KVO 泄漏）：兜底移除 KVO 观察者。
    // 正常流程中下载完成/出错时已移除，但若 VC 在下载过程中被释放（如退出启动器），
    // KVO 观察者会指向已释放对象，导致野指针崩溃。
    if (self.task && self.task.progress) {
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}
    }
}

#pragma mark - 下载中心（参照 FCL/ZL2/HMCL 下载进度弹窗）

/// 打开下载中心弹窗
/// 参照 FCL/ZL2/HMCL 的下载进度显示方式：以 FormSheet 方式弹出 DownloadTasksViewController，
/// 集中显示所有下载任务（MC本体/模组/光影/资源包/数据包/世界存档/整合包）的实时进度。
/// 所有通过 DownloadTaskManager 注册的下载任务都会在这里显示，实现统一的下载进度管理。
- (void)openDownloadCenter {
    // 如果已经弹出了下载中心，直接返回避免重复弹出
    if (self.presentedDownloadCenterVC) {
        return;
    }

    // 用户主动打开了下载中心，重置"用户已关闭"标记
    self.userDismissedDownloadCenter = NO;

    DownloadTasksViewController *downloadCenterVC = [[DownloadTasksViewController alloc] init];
    downloadCenterVC.modalPresentationStyle = UIModalPresentationFormSheet;
    downloadCenterVC.preferredContentSize = CGSizeMake(500, 600);

    // 弱引用持有，避免循环持有
    self.presentedDownloadCenterVC = downloadCenterVC;

    // 获取最顶层的视图控制器来 present
    UIViewController *topVC = self;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    [topVC presentViewController:downloadCenterVC animated:YES completion:nil];
}

/// 处理下载任务更新通知（进度变化、新任务注册等）
/// 当收到通知时仅更新下载中心按钮的状态，不再自动弹出下载中心界面。
///
/// redesign-download-ui Phase 3：单任务进度展示统一由任务注册时置
/// autoPresentDetail=YES 的 DownloadTaskItem 触发 DownloadTaskManager
/// 自动弹出统一进度页（PLTaskProgressViewController）；下载中心
/// DownloadTasksViewController 仅保留为手动打开（通过下载中心按钮）。
- (void)handleDownloadTaskUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// 处理下载任务完成通知
- (void)handleDownloadTaskCompleted:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// 处理下载中心被用户手动关闭的通知
/// 设置 userDismissedDownloadCenter=YES，避免后续下载任务更新时反复自动弹出下载中心。
/// 用户可以通过点击启动器上的"下载中心"按钮重新打开（会重置此标记）。
- (void)handleDownloadCenterDismissed {
    self.userDismissedDownloadCenter = YES;
    self.presentedDownloadCenterVC = nil;
}

/// 更新下载中心按钮的显示状态和进度百分比
- (void)updateDownloadCenterButton {
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSArray<DownloadTaskItem *> *allTasks = [manager allTasks];

    if (allTasks.count == 0) {
        self.downloadCenterButton.hidden = YES;
        self.downloadCenterBadgeLabel.hidden = YES;
        [self.downloadCenterActivityIndicator stopAnimating];
        return;
    }

    self.downloadCenterButton.hidden = NO;

    BOOL hasActive = NO;
    BOOL allCompleted = YES;
    double totalProgress = 0.0;
    NSInteger activeCount = 0;

    for (DownloadTaskItem *task in allTasks) {
        if (task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending) {
            hasActive = YES;
            allCompleted = NO;
            totalProgress += task.progress;
            activeCount++;
        } else if (task.state != DownloadTaskStateCompleted) {
            allCompleted = NO;
        }
    }

    // 进行中任务数徽标（redesign-download-ui Task 2.4）：有进行中任务时显示数量
    if (hasActive) {
        self.downloadCenterBadgeLabel.text = activeCount > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)activeCount];
        self.downloadCenterBadgeLabel.hidden = NO;
    } else {
        self.downloadCenterBadgeLabel.hidden = YES;
    }

    if (hasActive) {
        double avgProgress = activeCount > 0 ? totalProgress / activeCount : 0.0;
        NSInteger percent = (NSInteger)(avgProgress * 100.0 + 0.5);
        percent = MAX(0, MIN(100, percent));
        self.downloadCenterProgressLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.downloadCenterActivityIndicator startAnimating];
    } else if (allCompleted) {
        self.downloadCenterProgressLabel.text = localize(@"i18n_str_323", nil);
        [self.downloadCenterActivityIndicator stopAnimating];
    } else {
        self.downloadCenterProgressLabel.text = localize(@"i18n_str_128", nil);
        [self.downloadCenterActivityIndicator stopAnimating];
    }
}

#pragma mark - Options
- (void)enterCustomControls {
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^{
        return getPrefObject(@"control.default_ctrl");
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)enterModInstaller {
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/java-archive"]]
        asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}



- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    // 关键修复（二次执行 jar 卡死）：iOS 进程内 JVM 只能创建一次
    // （gJVMUsedInProcess，第二次 JLI_Launch 会崩溃）。首次执行 jar 已在本进程
    // 创建过 JVM，再次进入 JavaGUIViewController 会黑屏卡死。因此在此处提前拦截，
    // 提示用户重启启动器，而不是进入注定失败的界面。
    if (JVMUsedInProcess()) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_214", nil)
                                                                       message:localize(@"i18n_str_1143", nil)
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_216", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [PLCrashView restartLauncher];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_217", nil) style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    if (!vc.requiredJavaVersion) {
        // 解析失败（manifest 缺失/主类非法）时明确提示，避免静默 return 让用户以为安装器已启动
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:localize(@"i18n_str_221", nil), path.lastPathComponent]);
        return;
    }
    // execute_jar 路径：Caciocavallo17 jar 现已统一为 Java 17 编译版本，
    // Java 17/21 均可加载，不再需要强制提升 requiredJavaVersion 到 25。
    // - Java 8 JAR（如 OptiFine 安装器）走 Caciocavallo（非 17）路径，用 Java 8
    // - Java 17+ JAR 走 Caciocavallo17 路径，用 Java 17/21 即可
    // 与 JavaLauncher.m launchJar 分支保持一致。
    int requiredJavaVersion = vc.requiredJavaVersion;
    // 预检 execute_jar 标签的 JRE 是否已配置，避免 present 后才发现没 JRE 导致黑屏
    // 与 LauncherRightPanelViewController.enterModInstallerWithPath: 行为一致
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:localize(@"i18n_str_222", nil), requiredJavaVersion, requiredJavaVersion]);
        return;
    }
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    // Handle normal jar file import
    [self enterModInstallerWithPath:url.path hitEnterAfterWindowShown:NO];
}

- (void)setInteractionEnabled:(BOOL)enabled forDownloading:(BOOL)downloading {
    for (UIControl *view in self.toolbar.subviews) {
        if ([view isKindOfClass:UIControl.class]) {
            view.alpha = enabled ? 1 : 0.2;
            view.enabled = enabled;
        }
    }
    if (downloading) {
        [self.buttonInstall setTitle:localize(enabled ? @"Play" : @"Details", nil) forState:UIControlStateNormal];
        self.buttonInstall.alpha = 1;
        self.buttonInstall.enabled = YES;
    }
    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
}

- (void)launchMinecraft:(UIButton *)sender {
    if (!self.versionTextField.hasText) {
        [self.versionTextField becomeFirstResponder];
        return;
    }

    if (BaseAuthenticator.current == nil) {
        // Present the account selector if none selected
        UIViewController *view = [(UINavigationController *)self.splitViewController.viewControllers[0]
        viewControllers][0];
        [view performSelector:@selector(selectAccount:) withObject:sender];
        return;
    }

    [self setInteractionEnabled:NO forDownloading:YES];

    NSString *versionId = PLProfiles.current.profiles[self.versionTextField.text][@"lastVersionId"];
    NSDictionary *object = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", versionId]].firstObject;
    if (!object) {
        object = @{
            @"id": versionId,
            @"type": @"custom"
        };
    }

    self.task = [MinecraftResourceDownloadTask new];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                // 关键修复（KVO 泄漏）：出错时必须先移除 KVO 再置 nil task，
                // 否则 task.progress 仍持有对 self 的 KVO 观察者，下次下载会重复添加。
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:ProgressObserverContext];
                } @catch (NSException *e) {}
                weakSelf.task = nil;
            });
        };
        [self.task downloadVersion:object];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.task.progress addObserver:self
                forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial
                context:ProgressObserverContext];

            // redesign-download-ui Phase 3 Task 3.4：启动下载的进度页已由任务内部
            // 阶段上报（MinecraftResourceDownloadTask.downloadVersion: 注册任务并
            // 置 autoPresentDetail=YES）自动弹出统一进度页，此处不再手动 present 旧进度 VC。
        });
    });
}

- (void)performInstallOrShowDetails:(UIButton *)sender {
    if (self.task) {
        // redesign-download-ui Phase 3 Task 3.4：Details 按钮改为打开统一进度页。
        // 任务由 MinecraftResourceDownloadTask 内部注册到 DownloadTaskManager，
        // 此处按 rawTask 反查 taskId 后呈现统一进度页。
        NSString *taskId = nil;
        for (DownloadTaskItem *item in [DownloadTaskManager sharedManager].allTasks) {
            if (item.rawTask == self.task) {
                taskId = item.taskId;
                break;
            }
        }
        if (taskId) {
            [PLTaskProgressViewController presentForTaskId:taskId];
        }
    } else {
        [self launchMinecraft:sender];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    // Calculate download speed and ETA
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL); 
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!progress.finished) return;

        // 关键修复（KVO 泄漏）：下载完成时移除 KVO 观察者。
        // 之前不移除，导致每次下载都在 self.task.progress 上累积一个观察者，
        // 多次下载后 progress 变化会触发多次 observeValueForKeyPath，UI 异常。
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}
        if (self.task.metadata) {
            [self invokeAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(self.view.window, self.task.metadata);
            }];
        } else {
            self.task = nil;
            [self setInteractionEnabled:YES forDownloading:YES];
            [self reloadProfileList];
        }
    });
}

- (void)receiveNotification:(NSNotification *)notification {
    if (![notification.name isEqualToString:@"InstallModpack"]) {
        return;
    }
    [self setInteractionEnabled:NO forDownloading:YES];
    self.task = [MinecraftResourceDownloadTask new];
    NSDictionary *userInfo = notification.userInfo;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                // 关键修复（KVO 泄漏）：出错时移除 KVO，与 launchMinecraft 流程一致
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:ProgressObserverContext];
                } @catch (NSException *e) {}
                weakSelf.task = nil;
            });
        };
        [self.task downloadModpackFromAPI:notification.object detail:userInfo[@"detail"] atIndex:[userInfo[@"index"] unsignedLongValue]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.task.progress addObserver:self
                forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial
                context:ProgressObserverContext];
        });
    });
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    // 注意：不要在此清空 localVersionList/remoteVersionList
    // 该方法既被 JAR 执行调用，也被正常启动游戏调用；清空会导致用户返回后版本列表为空、
    // buttonInstall 短暂不可用。版本列表的生命周期应由 reloadProfileList 统一管理。
    // Task185：收起任何活跃键盘（卡死会话独有环境 = 二级菜单文本框 + 拼音
    // 键盘；启动前强制 resign，病历见 RightPanel 同名方法 + utils.h）。
    [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];

    // Task91：entitlement 标记 AND 磁盘标记双确认——entitlements.sideload.xml
    // 模板给普通侧载包也预写了 jb.pmap_cs.custom_trust 字符串，单看签名会把
    // 非 TrollStore 环境误导入 apple-magnifier:// 死路（JIT 无法自动开启）
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust") && isTrollStoreInstall();

    // Diagnostic: dump the full JIT decision state so device-specific issues
    // can be debugged from latestlog alone (TrollStore vs dynamic-codesigning
    // vs CS_DEBUGGED vs debugger attachment).
    {
        BOOL hasDynamicCS = getEntitlementValue(@"dynamic-codesigning");
        int diagCsFlags = 0;
        csops(getpid(), 0, &diagCsFlags, sizeof(diagCsFlags));
        NSLog(@"[JIT] invokeAfterJITEnabled: dynamicCS=%d trollStore=%d CS_DEBUGGED=%d ppid=%d traced=%d exn=%d JIT_FLAGS=0x%X",
              hasDynamicCS, hasTrollStoreJIT, (diagCsFlags & CS_DEBUGGED) != 0, getppid(), JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts(), DeviceGetJITFlags(NO));
    }

    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        // iPadOS 26+ TXM devices: HotSpot's RX mappings are allocated by the
        // JIT26 debugger script while it services brk #0x69.  CS_DEBUGGED
        // being set only proves JIT was enabled once for this process -- the
        // JIT26 debugger itself is normally long gone by launch time
        // (ppid==1, P_TRACED==0, no task exception ports).  launchJVM() then
        // runs JIT26CreateRegionLegacy() whose brk #0x69 is instantly fatal
        // with no live debugger (measured 2026-08-30: crash right after
        // custom-env init when this re-attach step was skipped -- the old
        // "stubs gracefully fall back" assumption is disproven).  So when
        // launchJVM would enter the JIT26 path and no debugger is live,
        // re-attach the Universal script via stikjit:// first, then launch.
        // NOTE: this intentionally does NOT reuse isJITEnabled() -- that
        // reports the persistent CS_DEBUGGED state, not debugger liveness.
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
            !JIT26IsLikelyDebuggerKeepAttached()) {
            NSLog(@"[JIT] [NavCtrl] CS_DEBUGGED set but no live JIT26 debugger (ppid=%d traced=%d exn=%d) — re-attaching script via stikjit://",
                  getppid(), JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            // Task172：重挂逻辑抽取为共用助手（本分支 + 等待成功后的存活性
            // 复查两处调用，见 ame172_reattachJIT26ThenLaunch）。
            [self ame172_reattachJIT26ThenLaunch:handler];
            return;
        }
        NSLog(@"[JIT] [NavCtrl] JIT enabled with live JIT26 debugger (flags=0x%X, ppid=%d), launching game directly",
              DeviceGetJITFlags(NO), getppid());
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        // Task185：回执检查（他人装机反馈“巨魔 JIT 启动游戏没有任何反应”——
        // completionHandler:nil 时 URL 无人处理完全静默，只能盲等 120s）。
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:^(BOOL ame185_ok) {
            NSLog(@"[JIT] [NavCtrl] Task185 openURL apple-magnifier:// -> %d", ame185_ok);
            if (!ame185_ok) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    showDialog(localize(@"Error", nil), @"apple-magnifier:// 无响应（TrollStore JIT 助手未接管，常见于 TrollStore 版本过旧）。请更新 TrollStore，或在设置的 JIT 开启工具改用 stikjit / SideStore / StosDebug 后重试。\napple-magnifier:// not handled. Update TrollStore or switch the JIT enabler in Settings.");
                });
            }
        }];
        // Do not return, wait for TrollStore to enable JIT and jump back
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        // Task176：openURL 结果取证（同 RightPanel；stikjit:// 拉起失败时
        // 下一行日志直接可见，不再与 120s 盲等混淆）。
        NSURL *ame176_jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]];
        [UIApplication.sharedApplication openURL:ame176_jitURL options:@{} completionHandler:^(BOOL ame176_ok) {
            NSLog(@"[JIT] [NavCtrl] Task176 openURL stikjit:// -> %d", ame176_ok);
        }];
    } else {
        // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
        [self ame185_openJITEnablerURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]]
            toolLabel:@"sidestore://sidejit-enable"];
    }

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
        message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
        preferredStyle:UIAlertControllerStyleAlert];
/* TODO:
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^{
        
    }];
    [alert addAction:cancel];
*/
    // ★ Task223（用户报“版本设置启动游戏，JIT 有概率卡死”，2832c2b latestlog.8
    //   判读：condition satisfied 后 Task183 锚点缺失、主队列楔死，而
    //   Task192 的全局队列心跳照常——stikjit:// 把 App 切后台的转场瞬间
    //   presentViewController:animated:YES 正是主线程阻塞的头号嫌疑类；
    //   动画时钟冻结 + present 半途 = 主线程不再回 runloop）。进度型弹窗
    //   改无动画呈现/消失，后台态零风险，前台态视觉差异可忽略。
    [self presentViewController:alert animated:NO completion:nil];

    // Task172：后台任务断言（同 RightPanel，见其病历）：stikjit:// 切后台后
    // 防 iOS 立即挂起冻结等待循环。
    __block UIBackgroundTaskIdentifier ame172_bgt = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ame172-jit-wait" expirationHandler:^{
        // 宽限期到由系统挂起；恢复后循环按剩余预算继续。
    }];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Task169：有界等待（120s）+每 10s 心跳日志，超时走重试弹窗（同
        // RightPanel/DownloadVC 两处，群见 utils.m 病历）。
        BOOL ok = ame169_waitForJITCondition(^{ return isJITEnabled(false); }, 120.0, @"isJITEnabled");
        // Task185：自愈式派发（11e4b63 latestlog.2 病历：condition satisfied
        // 后旧 dispatch_async(main) 续接块在后台被楔死的主队列上永不执行——
        // 见 utils.h ame185_dispatchToMainSelfHealing）。
        ame185_dispatchToMainSelfHealing(^{
            // Task183（断点钉死锚点，同 RightPanel 病历 59d4b48 latestlog.1）。
            NSLog(@"[JIT] [NavCtrl] Task183 wait-completed block entered on main (ok=%d)", ok);
            if (ame172_bgt != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:ame172_bgt];
                ame172_bgt = UIBackgroundTaskInvalid;
            }
            if (ok) {
                // Task182：后台态 dismiss completion 悬空风险（同 RightPanel
                // 主等待路径，病历 bc1941b latestlog.1）——completion:nil +
                // 直接执行后续链。Task223：再降一档动画风险（animated:NO）。
                [alert dismissViewControllerAnimated:NO completion:nil];
                // Task172：存活性复查（同 RightPanel）：CS_DEBUGGED 已置但
                // 调试器已死时直接启动 = brk #0x69 闪退，先重挂。
                if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
                    !JIT26IsLikelyDebuggerKeepAttached()) {
                    NSLog(@"[JIT] [NavCtrl] Task172 wait satisfied but JIT26 debugger is gone — re-attaching before launch");
                    [self ame172_reattachJIT26ThenLaunch:handler];
                } else {
                    NSLog(@"[JIT] [NavCtrl] Task183 invoking launch handler");
                    handler();
                }
            } else {
                // Task182：同上，超时弹窗不包进 dismiss completion。
                [alert dismissViewControllerAnimated:NO completion:nil];
                [self ame169_showJITTimeoutAlertWithRetry:handler];
            }
        }, @"NavCtrl main wait");
    });
}

/// Task185：JIT 开启工具 URL 统一拉起（回执取证 + 失败即时指引，同
/// RightPanel.ame185_openJITEnablerURL）。
- (void)ame185_openJITEnablerURL:(NSURL *)url toolLabel:(NSString *)tool {
    if (!url) {
        NSLog(@"[JIT] [NavCtrl] Task185 openURL skipped: nil URL (tool=%@)", tool);
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL ok) {
        NSLog(@"[JIT] [NavCtrl] Task185 openURL %@ -> %d", tool, ok);
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"%@ 未接管启动请求（未安装或版本过旧？）。请在设置的 JIT 开启工具中换用其它工具后重试。\n%@ did not handle the request. Switch the JIT enabler in Settings and retry.", tool, tool]);
            });
        }
    }];
}

/// Task172：JIT26 调试器重挂统一助手（stikjit:// + 有界等待 + 前台等待 +
/// 后台任务断言，同 RightPanel.ame172_reattachJIT26ThenLaunch，本文本
/// alert 标题/文案用 NavCtrl 的本地化键）。
- (void)ame172_reattachJIT26ThenLaunch:(void(^)(void))handler {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
        message:localize(@"launcher.wait_jit.message", nil)
        preferredStyle:UIAlertControllerStyleAlert];
    // Task223：同主等待路径——重挂弹窗也无动画（后台态 present 安全）。
    [self presentViewController:alert animated:NO completion:nil];

    __block UIBackgroundTaskIdentifier ame172_bgt = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ame172-jit26-reattach" expirationHandler:^{
        // 同上：宽限期到由系统挂起，恢复后继续。
    }];

    void (^ame172_fireURL)(void) = ^{
        NSString *scriptDataString = @"";
        NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
        if (scriptData) {
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:^(BOOL ame185_ok) {
            // Task185：回执取证（重挂场景已有等待弹窗 + 超时重试兑底，失败只记日志）
            NSLog(@"[JIT] [NavCtrl] Task185 re-attach stikjit:// -> %d", ame185_ok);
        }];
        NSLog(@"[JIT] [NavCtrl] Task172 stikjit:// re-attach fired (script=%lu bytes)",
              (unsigned long)scriptData.length);
    };

    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        // 后台态：openURL 无效，先等回前台再拉起（一次性监听 + 10s 兜底，
        // 双 nil 防护防双发）。
        __block id ame172_obs = nil;
        ame172_obs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *ame172_n) {
            [[NSNotificationCenter defaultCenter] removeObserver:ame172_obs];
            ame172_obs = nil;
            ame172_fireURL();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (ame172_obs) {
                [[NSNotificationCenter defaultCenter] removeObserver:ame172_obs];
                ame172_obs = nil;
                ame172_fireURL();
            }
        });
    } else {
        ame172_fireURL();
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Wait for the JIT26 debugger to actually attach (P_TRACED /
        // exception ports / spawned-by-debugger), not for CS_DEBUGGED
        // -- that flag is already set and would race the first brk.
        // Task169：有界等待（120s）+心跳日志，超时走重试弹窗。
        BOOL ok = ame169_waitForJITCondition(^{ return JIT26IsLikelyDebuggerKeepAttached(); }, 120.0, @"JIT26 debugger attach");
        // Task185：自愈式派发（同主等待路径，病历见 utils.h）。
        ame185_dispatchToMainSelfHealing(^{
            if (ame172_bgt != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:ame172_bgt];
                ame172_bgt = UIBackgroundTaskInvalid;
            }
            if (ok) {
                // Task182：同主等待路径——completion:nil + 直接执行。
                // Task223：animated:NO（后台态 dismiss 安全）。
                [alert dismissViewControllerAnimated:NO completion:nil];
                if (handler) handler();
            } else {
                [alert dismissViewControllerAnimated:NO completion:nil];
                [self ame169_showJITTimeoutAlertWithRetry:handler];
            }
        }, @"NavCtrl reattach wait");
    });
}

/// Task169：JIT 等待超时后的出路弹窗（重试 = 重新走一轮 invokeAfterJITEnabled，
/// 会重新拉起 stikjit://；取消 = 回到启动器）。
- (void)ame169_showJITTimeoutAlertWithRetry:(void(^)(void))handler {
    NSLog(@"[JIT] [NavCtrl] Task169 JIT wait timed out, showing retry alert");
    UIAlertController *retry = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
                                                                   message:localize(@"ame189.jit.timeout_msg", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [retry addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [retry addAction:[UIAlertAction actionWithTitle:localize(@"ame189.jit.retry", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self invokeAfterJITEnabled:handler];
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        retry.popoverPresentationController.sourceView = self.view;
        retry.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:retry animated:YES completion:nil];
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - UIPickerView stuff
- (void)pickerView:(PLPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    self.profileSelectedAt = (int)row;
    //((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    ((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    // Task162：selectedProfileName 必须落【字典键】（与 resolveKeyForCurrentProfile
    // 同一命名空间）。旧行为写 name 字段，键≠名时启动链读到 nil/幻影条目。
    if (row >= 0 && row < (NSInteger)self.ame162PickerKeys.count) {
        PLProfiles.current.selectedProfileName = self.ame162PickerKeys[row];
    }
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    // Task162：行号一律基于键快照；字典变更后（增删 profile）自动重建，
    // 避免 allValues 无序导致行号↔条目错位。
    if (self.ame162PickerKeys.count != PLProfiles.current.profiles.count) {
        [self ame162RefreshPickerKeys];
    }
    return self.ame162PickerKeys.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    // Task162：显示 name 字段，但行号经快照键定位（越界防御）。
    if (row < 0 || row >= (NSInteger)self.ame162PickerKeys.count) return @"";
    NSDictionary *profile = PLProfiles.current.profiles[self.ame162PickerKeys[row]];
    NSString *name = profile[@"name"];
    return [name isKindOfClass:NSString.class] && name.length > 0 ? name : self.ame162PickerKeys[row];
}

- (void)pickerView:(UIPickerView *)pickerView enumerateImageView:(UIImageView *)imageView forRow:(NSInteger)row forComponent:(NSInteger)component {
    UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    // Task162：同款快照键定位。
    NSString *urlString = nil;
    if (row >= 0 && row < (NSInteger)self.ame162PickerKeys.count) {
        urlString = PLProfiles.current.profiles[self.ame162PickerKeys[row]][@"icon"];
    }
    [imageView setImageWithURL:[NSURL URLWithString:urlString] placeholderImage:fallbackImage];
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

#pragma mark - View controller UI mode

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 发送通知更新账户信息
    [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
}

@end
