#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "PLMirrorCenter.h"   // Task218: download-source label token
#import "LauncherPrefManageJREViewController.h"
#import "NSFileManager+NRFileManager.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "BackgroundManager.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"

#include <lzma.h>
#include <objc/runtime.h>

// 0 is reserved for default pickers
// INT_MAX is reserved for invalid runtimes
#define DEFAULT_JRE 0
#define INVALID_JRE INT_MAX

// https://www.gnu.org/software/tar/manual/html_node/Standard.html
typedef struct {
    char name[100];
    char mode[8];
    char unused1[8+8];
    char size[12];
    char unused2[12+8];
    char typeflag;
    char linkname[100];
    char unused3[6+2+32+32+8+8+155+12];
} TarHeader;

// redesign-download-ui Phase 4 Task 4.3：移除 WFWorkflowProgressView（私有框架），
// 运行时导入进度改由 DownloadTaskManager 统一任务驱动（rawTask = totalProgress，支持取消）
static NSString *currentImportTaskId;

@interface LauncherPrefManageJREViewController ()<UIContextMenuInteractionDelegate, UIDocumentPickerDelegate>
@property(nonatomic) NSMutableDictionary<NSNumber *, NSMutableArray *> *javaRuntimes;
@property(nonatomic) NSMutableArray<NSNumber *> *sortedJavaVersions;
@property(nonatomic) NSArray<NSString *> *selectedRTTags;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *selectedRuntimes;
@property(nonatomic) UIMenu* currentMenu;
@property(nonatomic, weak) NSIndexPath* installingIndexPath;
@end

@implementation LauncherPrefManageJREViewController

+ (LauncherPrefManageJREViewController *)currentInstance {
    // 修复 #41: currentVC() 不一定是 UISplitViewController（在设置子页面里它会返回
    // 当前可见 VC 本身），直接强转并访问 viewControllers 会触发
    // "unrecognized selector viewControllers" 崩溃。这里做严格类型校验。
    UIViewController *current = currentVC();
    if (!current) return nil;

    // 常见路径：当前 VC 是 LauncherPrefManageJREViewController 自身（在导航栈顶）
    if ([current isKindOfClass:LauncherPrefManageJREViewController.class]) {
        return (LauncherPrefManageJREViewController *)current;
    }

    // 走 splitVC 路径：先尝试从 current 往上找 splitVC
    UISplitViewController *splitVC = nil;
    if ([current isKindOfClass:UISplitViewController.class]) {
        splitVC = (UISplitViewController *)current;
    } else if ([current.navigationController isKindOfClass:LauncherNavigationController.class]) {
        // current 的 navigationController 是 LauncherNavigationController
        // LauncherNavigationController 的 presenting/splitViewController 才是 splitVC
        splitVC = current.navigationController.splitViewController;
    } else {
        splitVC = current.splitViewController;
    }
    if (![splitVC isKindOfClass:UISplitViewController.class] || splitVC.viewControllers.count < 2) {
        return nil;
    }
    UIViewController *secondary = splitVC.viewControllers[1];
    LauncherNavigationController *nav = nil;
    if ([secondary isKindOfClass:LauncherNavigationController.class]) {
        nav = (LauncherNavigationController *)secondary;
    } else if ([secondary isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)secondary).topViewController;
        if ([top isKindOfClass:LauncherPrefManageJREViewController.class]) {
            return (LauncherPrefManageJREViewController *)top;
        }
    }
    if (!nav || ![nav.topViewController isKindOfClass:LauncherPrefManageJREViewController.class]) {
        return nil;
    }
    return (LauncherPrefManageJREViewController *)nav.topViewController;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setTitle:localize(@"preference.title.manage_runtime", nil)];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] style:UIBarButtonItemStylePlain target:self action:@selector(actionImportRuntime)];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

    // 适配自定义启动器背景：透明化 tableView + 导航栏毛玻璃
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 修复：使用 Automatic 让系统自动为半透明导航栏添加顶部 contentInset，
    // 避免第一栏（"1.16及更早版本"）被导航栏覆盖。配合 edgesForExtendedLayout=All
    // 保留导航栏毛玻璃穿透效果，内容起始位置自动下移到导航栏下方。
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;

    self.javaRuntimes = @{
        // Task159：1.17+ 预选下新增 "26.0 及更高版本"（tag 1_26_newer，26.x 官方
        // javaVersion.majorVersion=25 → 预选行右侧显示 Java 25）
        @(DEFAULT_JRE): @[@"preference.manage_runtime.default.1165", @"preference.manage_runtime.default.117", @"preference.manage_runtime.default.126", @"launcher.menu.execute_jar"]
    }.mutableCopy;
    self.sortedJavaVersions = @[@(DEFAULT_JRE)].mutableCopy;

    self.selectedRTTags = @[@"1_16_5_older", @"1_17_newer", @"1_26_newer", @"execute_jar"];
    self.selectedRuntimes = getPrefObject(@"java.java_homes");

    NSString *internalPath = [NSString stringWithFormat:@"%@/java_runtimes", NSBundle.mainBundle.bundlePath];
    NSString *externalPath = [NSString stringWithFormat:@"%s/java_runtimes", getenv("POJAV_HOME")];
    [self listJREInPath:internalPath markInternal:YES];
    [self listJREInPath:externalPath markInternal:NO];

    // 监听背景效果变化通知：切换毛玻璃↔半透明或调整透明度时，
    // 重新透明化当前 VC 并 reload cell，让每个 cell 重新应用 applyEffectToCell:
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果变化时重新应用透明化处理，确保 cell 在切换毛玻璃↔半透明后视觉一致
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (void)actionCancelImportRuntime {
    // redesign-download-ui Phase 4 Task 4.3：取消统一任务管理器中的运行时导入任务，
    // rawTask 即 totalProgress（NSProgress），取消后 extractTarXZ 循环按 cancelled 路径清理
    if (currentImportTaskId) {
        [[DownloadTaskManager sharedManager] cancelTaskWithId:currentImportTaskId];
    }
}

- (void)actionImportRuntime {
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/x-xz"]]];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    LauncherNavigationController *nav = (id)self.navigationController;
    [nav setInteractionEnabled:NO forDownloading:NO];

    [url startAccessingSecurityScopedResource];
    NSUInteger xzSize = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil].fileSize;

    NSProgress *totalProgress = [NSProgress progressWithTotalUnitCount:xzSize];
    NSProgress *fileProgress = [NSProgress progressWithTotalUnitCount:0];

    // redesign-download-ui Phase 4 Task 4.3：运行时导入注册为统一下载任务，
    // 单阶段 + autoPresentDetail 自动弹出统一进度页；rawTask = totalProgress 支持取消
    NSString *runtimeName = [url.path substringToIndex:url.path.length-7].lastPathComponent;
    // Task218：来源标签收敛到 PLMirrorCenter（显示层专用 token；路由一律走候选链）。
    NSString *source = [PLMirrorCenter legacySourceTokenForType:PLMirrorResourceTypeGameFile];
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeJavaRuntime
                        resourceName:runtimeName
                         displayName:[NSString stringWithFormat:localize(@"i18n_str_364", nil), runtimeName]
                      downloadSource:source
                             rawTask:totalProgress
                      supportsResume:NO
                             iconURL:nil];
    if (taskItem) {
        taskItem.downloadURL = url.absoluteString;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId stageAtIndex:0 status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId stageAtIndex:0 progress:-1 message:localize(@"i18n_str_365", nil)];
        currentImportTaskId = taskItem.taskId;
    }
    NSString *taskId = taskItem.taskId;
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        NSString *outPath = [NSString stringWithFormat:@"%s/java_runtimes/%@", getenv("POJAV_HOME"), runtimeName];
        NSString *error = [LauncherPrefManageJREViewController extractTarXZ:url.path
        to:outPath progress:totalProgress fileProgress:fileProgress
        fileCallback:^(NSString* name) {
            // fileCallback 在 extractTarXZ 内部（后台线程）调用，
            // manager 上报线程安全；进度文案带当前文件名
            double fraction = totalProgress.fractionCompleted;
            NSString *displayText = [NSString stringWithFormat:localize(@"i18n_str_366", nil), name];
            [manager updateTaskWithId:taskId
                              progress:fraction
                          totalBytes:(int64_t)xzSize
                       downloadedBytes:(int64_t)(xzSize * fraction)];
            [manager updateTaskWithId:taskId stageAtIndex:0 progress:fraction message:displayText];
        }];
        [url stopAccessingSecurityScopedResource];

        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), error);
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            LauncherPrefManageJREViewController *vc = LauncherPrefManageJREViewController.currentInstance;

            // 任务收尾：成功/失败/取消上报到统一任务管理器
            if (taskId) {
                if (error) {
                    [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                    [manager updateTaskWithId:taskId error:[NSError errorWithDomain:@"RuntimeImport" code:-1 userInfo:@{NSLocalizedDescriptionKey: error}]];
                    [manager setTaskWithId:taskId state:DownloadTaskStateFailed];
                } else if (totalProgress.cancelled) {
                    [manager setTaskWithId:taskId state:DownloadTaskStateCancelled];
                } else {
                    [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
                    [manager setTaskWithId:taskId state:DownloadTaskStateCompleted];
                }
                currentImportTaskId = nil;
            }

            if ((error || totalProgress.cancelled) && vc.installingIndexPath) {
                [vc removeRuntimeAtIndexPath:vc.installingIndexPath];
            } else {
                NSNumber *version = self.sortedJavaVersions[vc.installingIndexPath.section];
                NSString *name = self.javaRuntimes[version][vc.installingIndexPath.row];
                objc_setAssociatedObject(name, @"installing", @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            vc.installingIndexPath = nil;
            [vc.tableView reloadData];

            [nav setInteractionEnabled:YES forDownloading:NO];
        });
    });
}

#pragma mark Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sortedJavaVersions.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSNumber *version = self.sortedJavaVersions[section];
    switch (self.sortedJavaVersions[section].intValue) {
        case DEFAULT_JRE: return localize(@"preference.manage_runtime.header.default", nil);
        case INVALID_JRE: return localize(@"preference.manage_runtime.header.invalid", nil);
        default: return [NSString stringWithFormat:@"Java %@", self.sortedJavaVersions[section]];
    }
}

/// section header：透明背景，与界面背景一致（可看到背景图）。
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    UITableViewHeaderFooterView *header = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"JRESectionHeader"];
    if (!header) {
        header = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"JRESectionHeader"];
    }
    header.textLabel.text = title;
    return header;
}

/// section header 透明化：不套毛玻璃，与界面背景融为一体。
/// 有自定义背景时用白色文字 + 阴影保证可读性；无背景时用系统默认色。
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;

    // 透明背景：不再使用毛玻璃，可看到背景图
    header.backgroundView = nil;
    if ([[BackgroundManager sharedManager] hasBackground]) {
        header.textLabel.textColor = [UIColor labelColor];
        // Task160：去文字阴影（重影修复，与启动器设置页同口径）
        header.textLabel.shadowColor = nil;
        header.textLabel.shadowOffset = CGSizeZero;
    } else {
        header.textLabel.textColor = [UIColor labelColor];
        header.textLabel.shadowColor = nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (self.sortedJavaVersions[section].intValue) {
        case DEFAULT_JRE: return localize(@"preference.manage_runtime.footer.default", nil);
        case 8: return localize(@"preference.manage_runtime.footer.java8", nil);
        case 17: return localize(@"preference.manage_runtime.footer.java17", nil);
        // Task159：Java 25 section footer（26.0+ 默认版本说明，与新预选行配套）
        case 25: return localize(@"preference.manage_runtime.footer.java25", nil);
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.javaRuntimes[self.sortedJavaVersions[section]].count;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case 0: return [self tableView:tableView cellForDefaultRowAtIndexPath:indexPath];
        default: return [self tableView:tableView cellForRuntimeRowAtIndexPath:indexPath];
    }
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForDefaultRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DefaultCell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"DefaultCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.text = localize(self.javaRuntimes[@DEFAULT_JRE][indexPath.row], nil);
    // Task159：新 tag 1_26_newer 在存量设备偏好文件里无键（getObject 不做深合并）
    // ——未配置显示“自动”（getSelectedJavaHome 的 minVersion 搜索语义），首次点选后落值
    NSString *ame159_picked = ((NSDictionary *)self.selectedRuntimes[@"0"])[self.selectedRTTags[indexPath.row]];
    cell.detailTextLabel.text = ame159_picked
        ? [NSString stringWithFormat:@"Java %@", ame159_picked]
        : localize(@"preference.auto", nil);
    // 适配自定义启动器背景：cell 应用毛玻璃/半透明效果，避免默认 systemBackgroundColor 遮挡背景
    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRuntimeRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RTCell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RTCell"];
    }
    NSNumber *version = self.sortedJavaVersions[indexPath.section];
    NSString *name = self.javaRuntimes[version][indexPath.row];
    BOOL isInternal = [objc_getAssociatedObject(name, @"internalJRE") boolValue];
    BOOL isInstalling = [objc_getAssociatedObject(name, @"installing") boolValue];
    if (isInternal) {
        cell.textLabel.text = [NSString stringWithFormat:@"[Internal] %@", name];
    } else {
        cell.textLabel.text = name;
    }

    if (isInstalling) {
        self.installingIndexPath = indexPath;

        // redesign-download-ui Phase 4 Task 4.3：进度展示移至统一进度页，
        // cell 内仅显示菊花指示器
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else {
        cell.accessoryView = nil;
    }

    // Set checkmark; with internal runtime it's a bit tricky to check
    if ([self.selectedRuntimes[version.stringValue] isEqualToString:name] ||
      (isInternal && [self.selectedRuntimes[version.stringValue] isEqualToString:@"internal"])) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    // Display size
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long folderSize = 0;
        NSString *directory = [NSString stringWithFormat:@"%@/java_runtimes/%@",
            isInternal ? NSBundle.mainBundle.bundlePath : @(getenv("POJAV_HOME")),
            name];
        [NSFileManager.defaultManager nr_getAllocatedSize:&folderSize ofDirectoryAtURL:[NSURL fileURLWithPath:directory] error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ - %@",
                [self javaVersionForPath:directory],
                [NSByteCountFormatter stringFromByteCount:folderSize countStyle:NSByteCountFormatterCountStyleMemory]];
        });
    });

    // 适配自定义启动器背景：cell 应用毛玻璃/半透明效果，避免默认 systemBackgroundColor 遮挡背景
    // 注意：applyEffectToCell: 只重置 backgroundView/backgroundColor/contentView.backgroundColor，
    // 不影响 accessoryView（progressView）和 accessoryType（checkmark）
    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.section == 0) {
        [self tableView:tableView openPickerAtIndexPath:indexPath
            minVersion:(indexPath.row==1 ? 17 : 8)];
        return;
    } else if (self.sortedJavaVersions[indexPath.section].intValue == INVALID_JRE) {
        // TODO: do something, like alert explaining that the runtime has missing files
        return;
    }

    // Update preference
    NSNumber *version = self.sortedJavaVersions[indexPath.section];
    NSString *name = self.javaRuntimes[version][indexPath.row];
    BOOL isInternal = [objc_getAssociatedObject(name, @"internalJRE") boolValue];
    if (isInternal) {
        self.selectedRuntimes[version.stringValue] = @"internal";
    } else {
        self.selectedRuntimes[version.stringValue] = name;
    }
    setPrefObject(@"java.java_homes", self.selectedRuntimes);

    // Update checkmark
    NSInteger runtimeCount = [self tableView:tableView numberOfRowsInSection:indexPath.section];
    for (int i = 0; i < runtimeCount; i++) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:indexPath.section]];
        if (i == indexPath.row) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
}

#pragma mark Context Menu configuration

- (void)tableView:(UITableView *)tableView openPickerAtIndexPath:(NSIndexPath *)indexPath minVersion:(NSInteger)minVer {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];

    // 收集可选的 Java 版本
    NSMutableArray<NSString *> *versionTitles = [NSMutableArray new];
    NSMutableArray<NSNumber *> *versionNumbers = [NSMutableArray new];
    for (int i = 1; i < self.sortedJavaVersions.count; i++) {
        if (self.sortedJavaVersions[i].intValue < minVer ||
            self.sortedJavaVersions[i].intValue == INVALID_JRE) {
            continue;
        }
        NSString *version = [self tableView:tableView titleForHeaderInSection:i];
        [versionTitles addObject:version];
        [versionNumbers addObject:self.sortedJavaVersions[i]];
    }

    // iPhone 上改用 UIAlertController actionSheet，避免紧凑菜单被压缩不可调整
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:cell.textLabel.text
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        if (versionTitles.count == 0) {
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"None", nil)
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil]];
        } else {
            for (int i = 0; i < versionTitles.count; i++) {
                NSString *version = versionTitles[i];
                NSNumber *verNum = versionNumbers[i];
                // 当前选中项前加 ✓ 标记
                NSString *title = version;
                if ([cell.detailTextLabel.text isEqualToString:version]) {
                    title = [NSString stringWithFormat:@"✓ %@", version];
                }
                [alert addAction:[UIAlertAction actionWithTitle:title
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction *a) {
                    cell.detailTextLabel.text = version;
                    ((NSMutableDictionary *)self.selectedRuntimes[@"0"])[self.selectedRTTags[indexPath.row]] = verNum.stringValue;
                    setPrefObject(@"java.java_homes", self.selectedRuntimes);
                }]];
            }
        }
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // iPad：保留 UIContextMenuInteraction 紧凑菜单
    NSMutableArray *menuItems = [NSMutableArray new];
    for (int i = 0; i < versionTitles.count; i++) {
        NSString *version = versionTitles[i];
        NSNumber *verNum = versionNumbers[i];
        [menuItems addObject:[UIAction
            actionWithTitle:version
            image:nil
            identifier:nil
            handler:^(UIAction *action) {
                cell.detailTextLabel.text = version;
                ((NSMutableDictionary *)self.selectedRuntimes[@"0"])[self.selectedRTTags[indexPath.row]] = verNum.stringValue;
                setPrefObject(@"java.java_homes", self.selectedRuntimes);
            }]];
    }

    cell.detailTextLabel.interactions = [NSArray new];

    if (menuItems.count == 0) {
        [menuItems addObject:[UIAction
            actionWithTitle:localize(@"None", nil)
            image:nil
            identifier:nil
            handler:^(UIAction *action){}]];
    }

    self.currentMenu = [UIMenu menuWithTitle:cell.textLabel.text children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [cell addInteraction:interaction];
    CGRect detailFrame = cell.detailTextLabel.frame;
    CGPoint location = CGPointMake(CGRectGetMidX(detailFrame), CGRectGetMidY(detailFrame));
    [interaction _presentMenuAtLocation:location];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction
styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
{
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3; // _UIContextMenuLayoutCompactMenu
    return style;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;

    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    NSString *title = localize(@"preference.title.confirm", nil);
    NSString *message = [NSString stringWithFormat:localize(@"preference.title.confirm.delete_runtime", nil), cell.textLabel.text];
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    confirmAlert.popoverPresentationController.sourceView = cell;
    confirmAlert.popoverPresentationController.sourceRect = cell.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        NSError *error;
        NSString *directory = [NSString stringWithFormat:@"%s/java_runtimes/%@", getenv("POJAV_HOME"), cell.textLabel.text];
        [NSFileManager.defaultManager removeItemAtPath:directory error:&error];
        if(!error) {
            [self removeRuntimeAtIndexPath:indexPath];
            [self.tableView reloadData];
        } else {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [confirmAlert addAction:cancel];
    [confirmAlert addAction:ok];
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSNumber *version = self.sortedJavaVersions[indexPath.section];
    NSString *name = self.javaRuntimes[version][indexPath.row];
    BOOL isInternal = [objc_getAssociatedObject(name, @"internalJRE") boolValue];
    BOOL isInstalling = [objc_getAssociatedObject(name, @"installing") boolValue];
    if (isInternal || isInstalling) {
        return UITableViewCellEditingStyleNone;
    } else {
        return UITableViewCellEditingStyleDelete;
    }
}

#pragma mark Version parser

- (NSString *)javaVersionForPath:(NSString *)path {
    path = [path stringByAppendingPathComponent:@"release"];
    NSError *error;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        return [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
    }

    content = [content componentsSeparatedByString:@"JAVA_VERSION=\""][1];
    content = [content componentsSeparatedByString:@"\""][0];
    return content;
}

- (NSNumber *)majorVersionForFullVersion:(NSString *)version {
    if ([version hasPrefix:@"1.8.0"]) {
        return @8;
    } else if ([version hasPrefix:@"Error: "]){
        return @(INVALID_JRE);
    } else {
        return @([version componentsSeparatedByString:@"."][0].intValue);
    }
}
- (NSNumber *)majorVersionForPath:(NSString *)path {
    return [self majorVersionForFullVersion:[self javaVersionForPath:path]];
}

- (void)addRuntimePath:(NSString *)path markInternal:(BOOL)markInternal {
    NSNumber *majorVer = [self majorVersionForPath:path];
    if (!self.javaRuntimes[majorVer]) {
        self.javaRuntimes[majorVer] = [NSMutableArray new];
        [self.sortedJavaVersions addObject:majorVer];
        [self.sortedJavaVersions sortUsingSelector:@selector(compare:)];
    }

    NSString *file = path.lastPathComponent;
    objc_setAssociatedObject(file, @"internalJRE", @(markInternal), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!markInternal) {
        NSString *installingDir = [path stringByAppendingPathComponent:@".installing"];
        BOOL markInstalling = [NSFileManager.defaultManager fileExistsAtPath:installingDir isDirectory:nil];
        objc_setAssociatedObject(file, @"installing", @(markInstalling), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [self.javaRuntimes[majorVer] addObject:file];
}

- (void)removeRuntimeAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    NSNumber *version = self.sortedJavaVersions[indexPath.section];
    NSString *name = self.javaRuntimes[version][indexPath.row];

    [self.javaRuntimes[version] removeObject:name];
    if (self.javaRuntimes[version].count == 0) {
        [self.javaRuntimes removeObjectForKey:version];
        [self.selectedRuntimes removeObjectForKey:version.stringValue];
        [self.sortedJavaVersions removeObject:version];
    } else if (cell.accessoryType == UITableViewCellAccessoryCheckmark) {
        self.selectedRuntimes[version.stringValue] = self.javaRuntimes[version][0];
    }

    setPrefObject(@"java.java_homes", self.selectedRuntimes);
}

- (void)listJREInPath:(NSString *)path markInternal:(BOOL)markInternal {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *files = [fm contentsOfDirectoryAtPath:path error:nil];
    BOOL isDir;
    for (NSString *file in files) {
        NSString *rtPath = [path stringByAppendingPathComponent:file];
        [fm fileExistsAtPath:rtPath isDirectory:&isDir];
        if (isDir) {
            [self addRuntimePath:rtPath markInternal:markInternal];
        }
    }
}

#pragma mark Extract tar.xz

+ (NSDictionary *)parseRuntimeInfo:(NSString *)path {
    NSError *error;

    NSString *releaseFile = [path stringByAppendingPathComponent:@"release"];
    NSString *content = [NSString stringWithContentsOfFile:releaseFile encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        return @{@"Error": error.localizedDescription};
    }

    NSMutableDictionary *dict = [NSMutableDictionary new];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length > 0) {
            NSArray *keyValue = [[line substringToIndex:line.length-1] componentsSeparatedByString:@"=\""];
            dict[keyValue[0]] = keyValue[1];
        }
    }
    return dict;
}

+ (NSString *)validateRuntimeInfo:(NSString *)path {
    NSDictionary *dict = [self parseRuntimeInfo:path];

    if (dict[@"Error"]) {
        return dict[@"Error"];
    } else if (![dict[@"OS_ARCH"] isEqualToString:@"aarch64"]) {
        return [NSString stringWithFormat:@"Wrong runtime architecture: %@ (need aarch64)", dict[@"OS_ARCH"]];
    } else if (![dict[@"OS_NAME"] isEqualToString:@"Darwin"]) {
        return [NSString stringWithFormat:@"Wrong runtime platform: %@ (need Darwin)", dict[@"OS_NAME"]];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.currentInstance addRuntimePath:path markInternal:NO];
        [self.currentInstance.tableView reloadData];
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.currentInstance.tableView scrollToRowAtIndexPath:self.currentInstance.installingIndexPath
            atScrollPosition:UITableViewScrollPositionBottom animated:YES];
    });
    return nil;
}

+ (NSString *)lzmaErrorDescriptionForCode:(int)code {
    switch (code) {
        case LZMA_MEM_ERROR:
            return @"Memory allocation failed";
        case LZMA_FORMAT_ERROR:
            return @"The input is not in the .xz format";
        case LZMA_OPTIONS_ERROR:
            return @"Unsupported compression options";
        case LZMA_DATA_ERROR:
            return @"Compressed file is corrupt";
        case LZMA_BUF_ERROR:
            return @"Compressed file is truncated or otherwise corrupt";
        default:
            return @"Unknown error, possibly a bug";
    }
}

// Reference: https://github.com/xz-mirror/xz/blob/master/doc/examples/02_decompress.c
+ (NSString *)extractTarXZ:(NSString *)inPath to:(NSString *)outPath progress:(NSProgress *)progress fileProgress:(NSProgress *)fileProgress fileCallback:(void(^)(NSString* name))fileCallback {
    NSString *installingDir = [outPath stringByAppendingPathComponent:@".installing"];
    [NSFileManager.defaultManager createDirectoryAtPath:installingDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSInputStream *inFile = [NSInputStream inputStreamWithFileAtPath:inPath];
    [inFile open];

    NSString *msg = nil;
    lzma_stream strm = LZMA_STREAM_INIT;
    lzma_action action = LZMA_RUN;
    uint8_t inbuf[BUFSIZ], outbuf[512];

    lzma_ret ret = lzma_stream_decoder(&strm, UINT64_MAX, LZMA_CONCATENATED);
    if (ret != LZMA_OK) {
        return [self lzmaErrorDescriptionForCode:ret];
    }

    strm.next_in = NULL;
    strm.avail_in = 0;
    strm.next_out = outbuf;
    strm.avail_out = sizeof(outbuf);

    TarHeader currFileHeader;
    NSString *currFileName;
    NSOutputStream *currFileOut;
    NSUInteger currFileOff, currFileSize;

    while (!progress.cancelled) {
        if (strm.avail_in == 0 && inFile.hasBytesAvailable) {
            strm.next_in = inbuf;
            strm.avail_in = [inFile read:inbuf maxLength:sizeof(inbuf)];

            if (strm.avail_in == -1) {
                msg = inFile.streamError.localizedDescription;
                break;
            }

            if (!inFile.hasBytesAvailable) {
                action = LZMA_FINISH;
            }
        }

        ret = lzma_code(&strm, action);
        if (strm.avail_out == 0 || ret == LZMA_STREAM_END) {
            if (currFileOut) {
                size_t remaining = currFileSize - currFileOff;
                size_t write_size = MIN(sizeof(outbuf), remaining);
                currFileOff += write_size;
                // Avoid overloading the main queue
                if (currFileOff % 102400 == 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        fileProgress.completedUnitCount = currFileOff;
                        fileCallback(currFileName);
                    });
                }
                if ([currFileOut write:outbuf maxLength:write_size] != write_size) {
                    msg = [NSString stringWithFormat:@"%s: %@", currFileHeader.name, currFileOut.streamError];
                    break;
                } else if (currFileOff >= currFileSize) {
                    [currFileOut close];
                    currFileOut = nil;
                    if ([currFileName isEqualToString:@"./release"]) {
                        msg = [LauncherPrefManageJREViewController validateRuntimeInfo:outPath];
                        if (msg) goto cleanup;
                    }
                }
            } else {
                memcpy(&currFileHeader, outbuf, sizeof(outbuf));
                if (currFileHeader.name[0] == '\0') {
                    // EOF
                    break;
                }
                NSString *absPath = [NSString stringWithFormat:@"%@/%s", outPath, currFileHeader.name];
                NSError *error = nil;
                switch (currFileHeader.typeflag) {
                    case '0':
                    case '\0': { // File
                        currFileName = @(currFileHeader.name);
                        currFileOff = 0;
                        currFileSize = strtol(currFileHeader.size, NULL, 8);
                        // NSProgress 非线程安全，在主线程修改其计数
                        dispatch_async(dispatch_get_main_queue(), ^{
                            fileProgress.completedUnitCount = 0;
                            fileProgress.totalUnitCount = currFileSize;
                        });
                        NSLog(@"[RuntimeUnpack] Extracting %@", currFileName);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            fileCallback(currFileName);
                        });

                        currFileOut = [NSOutputStream outputStreamToFileAtPath:absPath append:NO];
                        [currFileOut open];
                    } break;
                    case '2': { // Symlink
                        symlink(currFileHeader.linkname, currFileHeader.name);
                        //NSLog(@"%s -> %s", currFileHeader.name, currFileHeader.linkname);
                    } break;
                    case '5': { // Folder
                        [NSFileManager.defaultManager createDirectoryAtPath:absPath withIntermediateDirectories:YES attributes:nil error:&error];
                        if (error) {
                            msg = [NSString stringWithFormat:@"%s: %@", currFileHeader.name, error];
                            goto cleanup;
                        }
                    } break;
                    default: // Ignore everything else
                        if (currFileHeader.typeflag < '0' && currFileHeader.typeflag > '7'
                        && (currFileHeader.typeflag != 'x' && currFileHeader.typeflag != 'g')) {
                            msg = [NSString stringWithFormat:@"Invalid typeflag %c", currFileHeader.typeflag];
                            goto cleanup;
                        }
                        NSLog(@"[RuntimeUnpack] Skipped %s (typeflag %c)", currFileHeader.name, currFileHeader.typeflag);
                        break;
                }
            }

            strm.next_out = outbuf;
            strm.avail_out = sizeof(outbuf);

            // NSProgress 非线程安全，在主线程修改其计数
            NSUInteger totalIn = (NSUInteger)strm.total_in;
            dispatch_async(dispatch_get_main_queue(), ^{
                progress.completedUnitCount = totalIn;
            });
        }

        if (ret == LZMA_STREAM_END) {
            break;
        } else if (ret != LZMA_OK) {
            msg = [self lzmaErrorDescriptionForCode:ret];
            break;
        }
    }

cleanup:
    if (msg || progress.cancelled) {
        [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
    } else {
        [NSFileManager.defaultManager removeItemAtPath:installingDir error:nil];
    }
    lzma_end(&strm);
    [inFile close];
    [currFileOut close];
    return msg;
}

@end
