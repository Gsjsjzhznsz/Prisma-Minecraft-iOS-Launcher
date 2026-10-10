#import <Foundation/Foundation.h>
#import "AmeNativeMenu.h"       // ★ Task240：菜单全面系统原生 UIMenu 化
#import <objc/runtime.h>

#import "DBNumberedSlider.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "PLPrefTableViewController.h"
#import "BackgroundManager.h"
#import "UIKit+hook.h"

#import "ios_uikit_bridge.h"
#import "utils.h"

@interface PLPrefTableViewController()<UIContextMenuInteractionDelegate>{
    NSString *_currentSearchText;
}
@property(nonatomic) UIMenu* currentMenu;
@property(nonatomic) UIBarButtonItem *helpBtn;
@property(nonatomic, strong) UISearchController *searchController;
/// 搜索结果：filteredSections[0] 为扁平化的所有匹配项（忽略 section 归属）
@property(nonatomic, strong) NSArray<NSDictionary *> *filteredItems;

@end

@implementation PLPrefTableViewController

- (id)init {
    self = [super init];
    [self initViewCreation];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    if (self.prefSections) {
        self.prefSectionsVisibility = [[NSMutableArray<NSNumber *> alloc] initWithCapacity:self.prefSections.count];
        for (int i = 0; i < self.prefSections.count; i++) {
            [self.prefSectionsVisibility addObject:@(self.prefSectionsVisible)];
        }
    } else {
        // Display one singe section if prefSection is unspecified
        self.prefSectionsVisibility = (id)@[@YES];
    }

    // 搜索栏初始化（仅当 searchEnabled=YES 时启用，子类负责设置）
    if (self.searchEnabled) {
        self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        self.searchController.searchResultsUpdater = self;
        self.searchController.obscuresBackgroundDuringPresentation = NO;
        self.searchController.searchBar.placeholder = localize(@"i18n_str_844", nil);
        self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
        self.tableView.tableHeaderView = self.searchController.searchBar;
        self.definesPresentationContext = YES;
        _currentSearchText = @"";
    }

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 放在 tableView 重新创建之后调用，确保 makeViewControllerTransparent 处理的是最终的 tableView。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (NSString *)currentSearchText {
    return _currentSearchText ?: @"";
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _currentSearchText = query ?: @"";

    if (query.length == 0) {
        self.filteredItems = nil;
        [self.tableView reloadData];
        return;
    }

    // 扁平化所有 prefContents 中的设置项，按 title/key/icon/localizedTitle 模糊匹配
    NSMutableArray *results = [NSMutableArray array];
    NSString *lowerQuery = query.lowercaseString;
    for (int s = 0; s < self.prefContents.count; s++) {
        NSArray *section = self.prefContents[s];
        // 第 0 项是 section 头，跳过
        for (int r = (self.prefSections ? 1 : 0); r < section.count; r++) {
            NSDictionary *item = section[r];
            NSString *title = item[@"title"];
            if (!title) {
                title = [NSString stringWithFormat:@"preference.title.%@", item[@"key"]];
            }
            NSString *localizedTitle = localize(title, nil);
            NSString *key = item[@"key"] ?: @"";
            NSString *icon = item[@"icon"] ?: @"";
            // 匹配本地化标题、key、icon 名、原文标题
            if ([localizedTitle.lowercaseString containsString:lowerQuery] ||
                [key.lowercaseString containsString:lowerQuery] ||
                [icon.lowercaseString containsString:lowerQuery] ||
                [title.lowercaseString containsString:lowerQuery]) {
                // 记录原始 section 和 row，便于点击时定位
                NSMutableDictionary *matched = [item mutableCopy];
                matched[@"__origSection"] = @(s);
                matched[@"__origRow"] = @(r);
                matched[@"__localizedTitle"] = localizedTitle;
                [results addObject:matched];
            }
        }
    }
    self.filteredItems = results;
    [self.tableView reloadData];
}

- (UIBarButtonItem *)drawHelpButton {
    if (!self.helpBtn) {
        self.helpBtn = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"questionmark.circle"] style:UIBarButtonItemStyleDone target:self action:@selector(toggleDetailVisibility)];
    }
    return self.helpBtn;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Put navigation buttons back in place if we're first of the navigation controller
    if (self.hasDetail && self.navigationController) {
        self.navigationItem.rightBarButtonItems = @[[self drawHelpButton]];
    }

    // Scan for child pane cells and reload them
    // FIXME: any cheaper operations?
    NSMutableArray *indexPaths = [[NSMutableArray alloc] init];
    for (int section = 0; section < self.prefContents.count; section++) {
        if (!self.prefSectionsVisibility[section].boolValue) {
            continue;
        }
        for (int row = 0; row < self.prefContents[section].count; row++) {
            if (self.prefContents[section][row][@"type"] == self.typeChildPane) {
                [indexPaths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
            }
        }
    }
    [self.tableView reloadRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark UITableView

- (void)toggleDetailVisibility {
    self.prefDetailVisible = !self.prefDetailVisible;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // 搜索结果为单一扁平 section
    if (self.filteredItems) return 1;
    return self.prefSectionsVisibility.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // 搜索结果模式
    if (self.filteredItems) {
        return self.filteredItems.count;
    }
    if (self.prefSectionsVisibility[section].boolValue) {
        return self.prefContents[section].count;
    }
    return 1;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 搜索结果模式：使用扁平化的 filteredItems
    if (self.filteredItems) {
        NSDictionary *item = self.filteredItems[indexPath.row];
        NSString *cellID = @"searchResultCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
            cell.textLabel.adjustsFontSizeToFitWidth = YES;
            // Task160：回归原生单行（numberOfLines=0 时标题换行第二行会压到
            // detailTextLabel 上，用户实测"选项文字重叠两次"的布局半因）；
            // 长标题由 adjustsFontSizeToFitWidth 缩字，不再跨行侵入小字区
            cell.textLabel.numberOfLines = 1;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        cell.textLabel.text = item[@"__localizedTitle"];
        // 副标题显示所属 section
        NSNumber *origSection = item[@"__origSection"];
        if (origSection && self.prefSections && origSection.intValue < (int)self.prefSections.count) {
            NSString *sectionKey = self.prefSections[origSection.intValue];
            cell.detailTextLabel.text = localize(([NSString stringWithFormat:@"preference.section.%@", sectionKey]), nil);
        } else {
            cell.detailTextLabel.text = nil;
        }
        cell.imageView.image = [UIImage systemImageNamed:item[@"icon"]];
        cell.imageView.tintColor = [item[@"destructive"] boolValue] ? UIColor.systemRedColor : nil;
        cell.userInteractionEnabled = YES;
        return cell;
    }

    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    NSString *cellID;
    UITableViewCellStyle cellStyle;
    if (item[@"type"] == self.typeChildPane || item[@"type"] == self.typePickField) {
        cellID = @"cellValue1";
        cellStyle = UITableViewCellStyleValue1;
    } else {
        cellID = @"cellSubtitle";
        cellStyle = UITableViewCellStyleSubtitle;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:cellStyle reuseIdentifier:cellID];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        // Task160：textLabel/detailTextLabel 回归原生单行（同上：多行标题
        // 换行后压到灰色小字上，修复"文字重叠"）；颜色用系统默认，
        // 浅色模式 = 黑色标题 + 灰色小字（原生语义）
        cell.textLabel.numberOfLines = 1;
        cell.detailTextLabel.numberOfLines = 1;
    }
    // Reset cell properties, as it could be reused
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = nil;
    cell.detailTextLabel.text = nil;

    NSString *key = item[@"key"];
    if (indexPath.row == 0 && self.prefSections) {
        key = self.prefSections[indexPath.section];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = localize(([NSString stringWithFormat:@"preference.section.%@", key]), nil);
    } else {
        CreateView createView = item[@"type"];
        createView(cell, self.prefSections[indexPath.section], key, item);
        if (cell.accessoryView) {
            objc_setAssociatedObject(cell.accessoryView, @"section", self.prefSections[indexPath.section], OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"key", key, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        }
        cell.textLabel.text = localize((item[@"title"] ? item[@"title"] :
            [NSString stringWithFormat:@"preference.title.%@", key]), nil);
    }

    // Set general properties
    BOOL destructive = [item[@"destructive"] boolValue];
    cell.imageView.tintColor = destructive ? UIColor.systemRedColor : nil;
    cell.imageView.image = [UIImage systemImageNamed:item[@"icon"]];
    
    if (cellStyle != UITableViewCellStyleValue1) {
        cell.detailTextLabel.text = nil;
        if ([item[@"hasDetail"] boolValue] && self.prefDetailVisible) {
            cell.detailTextLabel.text = localize(([NSString stringWithFormat:@"preference.detail.%@", key]), nil);
        }
    }

    // Check if one has enable condition and call if it does
    BOOL(^checkEnable)(void) = item[@"enableCondition"];
    cell.userInteractionEnabled = !checkEnable || checkEnable();
    cell.textLabel.enabled = cell.detailTextLabel.enabled = cell.userInteractionEnabled;
    [(id)cell.accessoryView setEnabled:cell.userInteractionEnabled];

    return cell;
}

#pragma mark initViewCreation, showAlert, checkWarn

- (void)initViewCreation {
    __weak PLPrefTableViewController *weakSelf = self;

    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        BOOL destructive = [item[@"destructive"] boolValue];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.textColor = destructive ? UIColor.systemRedColor : weakSelf.view.tintColor;
    };

    self.typeChildPane = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeTextField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        Class cls = item[@"customClass"];
        if (!cls) cls = UITextField.class;
        UITextField *view = [[cls alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        view.adjustsFontSizeToFitWidth = YES;
        view.autocorrectionType = UITextAutocorrectionTypeNo;
        view.autocapitalizationType = UITextAutocapitalizationTypeNone;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        //view.contentVerticalAlignment = UIControlContentVerticalAlignmentTop;
        view.delegate = weakSelf;
        //view.nonEditingLinebreakMode = NSLineBreakByCharWrapping;
        view.returnKeyType = UIReturnKeyDone;
        view.textAlignment = NSTextAlignmentRight;
        view.placeholder = localize((item[@"placeholder"] ? item[@"placeholder"] :
            [NSString stringWithFormat:@"preference.placeholder.%@", key]), nil);
        view.text = weakSelf.getPreference(section, key);
        cell.accessoryView = view;
    };

    self.typePickField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        // Task 132：存储值命中 pickKeys 时，行右侧显示对应 pickList 本地化
        // 标签（Task121 注释声称的行为至此真正落地——此前 reloadData 后
        // 显示的是原始存储值）。未命中（动态键列表/复合映射行等）回落旧
        // 显示路径，零行为回归。数字存储值按 stringValue 比对（与 ✓ 标记
        // 的 ame121_curs 同款口径）。
        NSArray *ame132_pickKeys = item[@"pickKeys"];
        NSArray *ame132_pickList = item[@"pickList"];
        if (ame132_pickKeys != nil && ame132_pickList != nil && value != nil) {
            NSString *ame132_s = [value isKindOfClass:[NSString class]]
                ? value : [value stringValue];
            if ([ame132_s isKindOfClass:[NSString class]]) {
                NSUInteger ame132_idx = [ame132_pickKeys indexOfObject:ame132_s];
                if (ame132_idx != NSNotFound && ame132_idx < ame132_pickList.count) {
                    cell.detailTextLabel.text = ame132_pickList[ame132_idx];
                    return;
                }
            }
        }
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeSlider = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        DBNumberedSlider *view = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:weakSelf action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        view.minimumValue = [item[@"min"] intValue];
        view.maximumValue = [item[@"max"] intValue];
        view.continuous = YES;
        view.value = [weakSelf.getPreference(section, key) intValue];
        cell.accessoryView = view;
    };

    self.typeSwitch = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISwitch *view = [[UISwitch alloc] init];
        NSArray *customSwitchValue = item[@"customSwitchValue"];
        if (customSwitchValue == nil) {
            [view setOn:[weakSelf.getPreference(section, key) boolValue] animated:NO];
        } else {
            [view setOn:[weakSelf.getPreference(section, key) isEqualToString:customSwitchValue[1]] animated:NO];
        }
        [view addTarget:weakSelf action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = view;
    };
}

- (void)showAlertOnView:(UIView *)view title:(NSString *)title message:(NSString *)message {
    // ★ Task240：纯提示弹窗（非菜单）→ 改用居中 Alert 形态。
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkWarn:(UIView *)view {
    NSDictionary *item = objc_getAssociatedObject(view, @"item");
    NSString *key = item[@"key"];

    BOOL(^isWarnable)(UIView *) = item[@"warnCondition"];
    NSString *warnKey = item[@"warnKey"];
    // Display warning if: warn condition is met and either one of these:
    // - does not have warnKey, always warn
    // - has warnKey and its value is YES, warn once and set it to NO
    if (isWarnable && isWarnable(view) && (!warnKey || [self.getPreference(@"warnings", warnKey) boolValue])) {
        if (warnKey) {
            self.setPreference(@"warnings", warnKey, @NO);
        }

        NSString *message = localize(([NSString stringWithFormat:@"preference.warn.%@", key]), nil);
        [self showAlertOnView:view title:localize(@"Warning", nil) message:message];
    }
}

#pragma mark Control event handlers

- (void)sliderMoved:(DBNumberedSlider *)sender {
    [self checkWarn:sender];
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = objc_getAssociatedObject(sender, @"key");

    sender.value = (int)sender.value;
    self.setPreference(section, key, @(sender.value));
}

- (void)switchChanged:(UISwitch *)sender {
    [self checkWarn:sender];
    NSDictionary *item = objc_getAssociatedObject(sender, @"item");
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = item[@"key"];

    // Special switches may define custom value instead of NO/YES
    NSArray *customSwitchValue = item[@"customSwitchValue"];
    self.setPreference(section, key, customSwitchValue ?
        customSwitchValue[sender.isOn] : @(sender.isOn));

    void(^invokeAction)(BOOL) = item[@"action"];
    if (invokeAction) {
        invokeAction(sender.isOn);
    }

    // Some settings may affect the availability of other settings
    // In this case, a switch may request to reload to apply user interaction change
    if ([item[@"requestReload"] boolValue]) {
        // TODO: only reload needed rows
        [self.tableView reloadData];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    // 搜索结果模式：跳转到原始 section 并展开该 section
    if (self.filteredItems) {
        NSDictionary *item = self.filteredItems[indexPath.row];
        NSNumber *origSection = item[@"__origSection"];
        NSNumber *origRow = item[@"__origRow"];
        if (!origSection || !origRow) return;

        // 关闭搜索并恢复原始布局
        // 注意：UISearchController 没有 setActive:animated:，用 active 属性替代
        self.searchController.active = NO;
        self.filteredItems = nil;
        _currentSearchText = @"";

        // 展开对应 section
        if (origSection.intValue < (int)self.prefSectionsVisibility.count) {
            self.prefSectionsVisibility[origSection.intValue] = @YES;
        }
        [self.tableView reloadData];

        // 跳转到该项并触发原始点击行为
        NSIndexPath *origIndexPath = [NSIndexPath indexPathForRow:origRow.intValue inSection:origSection.intValue];
        [self.tableView scrollToRowAtIndexPath:origIndexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        // 延迟触发，等滚动完成
        dispatch_async(dispatch_get_main_queue(), ^{
            [self tableView:tableView didSelectRowAtIndexPath:origIndexPath];
        });
        return;
    }

    if (indexPath.row == 0 && self.prefSections) {
        self.prefSectionsVisibility[indexPath.section] = @(![self.prefSectionsVisibility[indexPath.section] boolValue]);
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationFade];
        return;
    }

    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    if (item[@"type"] == self.typeButton) {
        [self tableView:tableView invokeActionWithPromptAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typeChildPane) {
        [self tableView:tableView openChildPaneAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typePickField) {
        [self tableView:tableView openPickerAtIndexPath:indexPath];
        return;
    } else if (realUIIdiom != UIUserInterfaceIdiomTV) {
        return;
    }

    // userInterfaceIdiom = tvOS
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (item[@"type"] == self.typeSwitch) {
        UISwitch *view = (id)cell.accessoryView;
        view.on = !view.isOn;
        [view sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

#pragma mark External UITableView functions

- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    UIViewController *vc = [item[@"class"] new];
    if ([item[@"canDismissWithSwipe"] boolValue]) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = YES;
        nav.modalInPresentation = YES;
        [self.navigationController presentViewController:nav animated:YES completion:nil];
    }
}

// Task 129e：以下 UIContextMenuInteraction 代理方法随旧 iPad"紧凑菜单"分支一并
// 退役（openPickerAtIndexPath 已统一悬浮 actionSheet/popover）。保留方法体以
// 最小化改动面——无任何代码路径再创建 UIContextMenuInteraction，不会被执行。
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
{
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3; // _UIContextMenuLayoutCompactMenu
    return style;
}

- (void)tableView:(UITableView *)tableView openPickerAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    NSString *message = nil;
    if ([item[@"hasDetail"] boolValue]) {
        message = localize(([NSString stringWithFormat:@"preference.detail.%@", item[@"key"]]), nil);
    }

    NSArray *pickKeys = item[@"pickKeys"];
    NSArray *pickList = item[@"pickList"];

    // Task 129e：统一悬浮选择器（用户实测反馈："像 FSR、下载源等可打开的悬浮
    // 设置项变成了二级菜单入口，导致无法切换"）。
    // 旧 iPad 分支用 UIContextMenuInteraction + _presentMenuAtLocation:（私有
    // API）呈现"紧凑菜单"——观感是锚定在 cell 上的二级小菜单，且在 iPadOS 27
    // 上该私有入口已不可靠（点按无反应 = 无法切换）。Task120 合并 MobileGL 三
    // 后端为单一 pick 行（用户唯一要求的合并）后，pick 行成为切换后端/FSR 档位
    // /下载源的唯一途径，此缺陷升级为阻断项。
    // 修复：iPhone 与 iPad 一律用 UIAlertController actionSheet——iPhone 从底部
    // 弹出全宽选择器；iPad 经 popoverPresentationController 锚定在行旁，呈现为
    // 标准悬浮面板（与设置页其余浮层一致）。✓ 选中标记沿用 Task121 的存储值
    // 比较与本地化标签回写。
    // ★ Task240：pick 行换装系统原生 UIMenu（iPhone/iPad 一致；iOS 26
    // 自动原生液态玻璃；旧 actionSheet/popover 双轨退役）。✓ 选中标记
    // 沿用 Task121 的存储值比较与本地化标签回写。
    NSMutableArray<NSDictionary *> *ame240_items = [NSMutableArray array];
    // Task 121：✓ 选中标记改按【存储值】比较——Task120 起 pick 行右侧
    // 显示本地化标签而非原始存储值，按 cell 文本比较会永远失配。
    id ame121_cur = self.getPreference(self.prefSections[indexPath.section], item[@"key"]);
    NSString *ame121_curs = [ame121_cur isKindOfClass:NSString.class]
        ? ame121_cur : [ame121_cur stringValue];
    for (int i = 0; i < pickList.count; i++) {
        NSString *title = pickList[i];
        NSString *value = pickKeys[i];
        // 在标题前加 ✓ 标记当前选中项，让用户能直观看到当前值
        if ([ame121_curs isEqualToString:value]) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [ame240_items addObject:@{
            @"title": title,
            @"handler": ^{
                // Task 121：选中后 cell 右侧显示本地化标签（存储值不变）。
                cell.detailTextLabel.text = pickList[i];
                self.setPreference(self.prefSections[indexPath.section], item[@"key"], value);
                void(^invokeAction)(NSString *) = item[@"action"];
                if (invokeAction) {
                    invokeAction(value);
                }
            },
        }];
    }
    // Task 134：附加动作机制随三个浮窗行回归二级页面而退役（唯一使用者
    // 已在 Task 134 恢复 typeChildPane；机制代码移除，l10n 键
    // preference.pickextra.* 同步清理）。
    // Task 131：诊断日志保留（取证锚点延续）。“呈现收口”（沿 presented
    // 链上溯再 present）随 UIMenu 呈现自然消亡：上下文菜单不走
    // presentViewController，不存在“点了没反应”的静默拒绝面。
    NSLog(@"[PLPrefTable] Task131/240: pick opened as native UIMenu: %@.%@ (%lu options)",
          self.prefSections[indexPath.section], item[@"key"], (unsigned long)pickList.count);
    [AmeNativeMenu ame240_presentMenuWithTitle:message
                                     dictItems:ame240_items
                                    sourceView:cell ?: self.view];
}

- (void)tableView:(UITableView *)tableView invokeActionWithPromptAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *view = [self.tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    NSString *key = item[@"key"];

    if ([item[@"showConfirmPrompt"] boolValue]) {
        BOOL destructive = [item[@"destructive"] boolValue];
        NSString *title = localize(@"preference.title.confirm", nil);
        NSString *message = localize(([NSString stringWithFormat:@"preference.title.confirm.%@", key]), nil);
        UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
        confirmAlert.popoverPresentationController.sourceView = view;
        confirmAlert.popoverPresentationController.sourceRect = view.bounds;
        UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:destructive?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self tableView:tableView invokeActionAtIndexPath:indexPath];
        }];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
        [confirmAlert addAction:cancel];
        [confirmAlert addAction:ok];
        [self presentViewController:confirmAlert animated:YES completion:nil];
    } else {
        [self tableView:tableView invokeActionAtIndexPath:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView invokeActionAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    NSString *key = item[@"key"];

    void(^invokeAction)(void) = item[@"action"];
    if (invokeAction) {
        invokeAction();
    }

    // 对于typeButton类型的操作，不显示done提示
    if (item[@"type"] != self.typeButton) {
        UIView *view = [self.tableView cellForRowAtIndexPath:indexPath];
        NSString *title = localize(([NSString stringWithFormat:@"preference.title.done.%@", key]), nil);
        [self showAlertOnView:view title:title message:nil];
    }
}

#pragma mark UITextField

- (void)textFieldDidEndEditing:(UITextField *)sender {
    [self checkWarn:sender];
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = objc_getAssociatedObject(sender, @"key");

    self.setPreference(section, key, sender.text);
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 确保 tableView 背景透明、全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
