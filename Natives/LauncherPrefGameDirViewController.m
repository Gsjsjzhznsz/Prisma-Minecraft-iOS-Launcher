#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefGameDirViewController.h"
#import "BackgroundManager.h"
#import "NSFileManager+NRFileManager.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AmeNativeMenu.h"       // Task247（T9）：伪玻璃档长按菜单 ame240 路由
#import "LiquidGlassCompat.h"   // Task247（T9）：伪玻璃档分档判定

@interface LauncherPrefGameDirViewController ()<UITextFieldDelegate>
@property(nonatomic) NSMutableArray *array;
@end

@implementation LauncherPrefGameDirViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // ★ Task247（T9）：伪玻璃档——系统 UIContextMenu 长按菜单改由长按手势
    //   + ame240 统一路由（磨砂面板）；真液态玻璃/原生档保留系统菜单。
    if (LGCIsPseudoGlassStyleActive()) {
        UILongPressGestureRecognizer *ame247_lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(ame247_longPressDirMenu:)];
        ame247_lp.minimumPressDuration = 0.45;
        [self.tableView addGestureRecognizer:ame247_lp];
    }
    [self setTitle:localize(@"preference.title.game_directory", nil)];

    self.array = [[NSMutableArray alloc] init];
    [self.array addObject:@"default"];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.sectionFooterHeight = 50;

    NSString *path = [NSString stringWithFormat:@"%s/instances", getenv("POJAV_HOME")];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *files = [fm contentsOfDirectoryAtPath:path error:nil];
    BOOL isDir;
    for (NSString *file in files) {
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if (isDir && ![file isEqualToString:@"default"]) {
            [self.array addObject:file];
        }
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

- (void)changeSelectionTo:(NSString *)name {
    if (getenv("DEMO_LOCK")) return;

    setPrefObject(@"general.game_directory", name);
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSString *lasmPath = @(getenv("POJAV_GAME_DIR"));
    NSError *removeError = nil;
    [NSFileManager.defaultManager removeItemAtPath:lasmPath error:&removeError];
    // removeItem 失败不一定是致命的（首次切换时 lasmPath 可能不存在），忽略并继续

    NSError *linkError = nil;
    BOOL linkOK = [NSFileManager.defaultManager createSymbolicLinkAtPath:lasmPath
                                                       withDestinationPath:multidirPath
                                                                     error:&linkError];
    if (!linkOK) {
        // 符号链接创建失败：POJAV_GAME_DIR 仍是断链，后续所有路径都会失败。
        // 提示用户并尽早返回，避免把状态搞得更乱。
        NSLog(@"[GameDir] createSymbolicLink failed: %@", linkError.localizedDescription);
        showDialog(localize(@"Error", nil),
                   [NSString stringWithFormat:localize(@"i18n_str_363", nil), linkError.localizedDescription]);
        return;
    }
    [NSFileManager.defaultManager changeCurrentDirectoryPath:lasmPath];
    // 切换 pref.instancePath 到新目录的 launcher_preferences.plist
    // （内部会基于 POJAV_GAME_DIR 重新计算，已修复之前需重启启动器的 bug）
    toggleIsolatedPref(NO);

    // 刷新 PLProfiles 缓存，确保后续读取的是新游戏目录的 launcher_profiles.json
    [PLProfiles updateCurrent];

    // 尝试直接调用 reloadProfileList，如果 navigationController 响应该选择器
    if ([self.navigationController respondsToSelector:@selector(reloadProfileList)]) {
        [self.navigationController performSelector:@selector(reloadProfileList)];
    } else {
        // 否则发送通知
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    }

    // 发送通知刷新版本配置和编辑 profile 界面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.array.count;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITextField *view;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        view = [[UITextField alloc] initWithFrame:CGRectMake(20, 10, (cell.bounds.size.width-40)/2, cell.bounds.size.height-20)];
        [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        view.autocorrectionType = UITextAutocorrectionTypeNo;
        view.autocapitalizationType = UITextAutocapitalizationTypeNone;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        view.delegate = self;
        view.returnKeyType = UIReturnKeyDone;
        view.userInteractionEnabled = indexPath.row != 0;
        [cell.contentView addSubview:view];
        cell.detailTextLabel.text = @"...";
    }
    view = cell.contentView.subviews.firstObject;
    view.placeholder = self.array[indexPath.row];
    view.text = self.array[indexPath.row];
    cell.textLabel.hidden = YES;
    cell.textLabel.text = view.text;

    // Calculate the instance size
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long folderSize = 0;
        NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), self.array[indexPath.row]];
        [NSFileManager.defaultManager nr_getAllocatedSize:&folderSize ofDirectoryAtURL:[NSURL fileURLWithPath:directory] error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:folderSize countStyle:NSByteCountFormatterCountStyleMemory];
        });
    });

    if ([getPrefObject(@"general.game_directory") isEqualToString:self.array[indexPath.row]]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView 
viewForFooterInSection:(NSInteger)section
{
    UITextField *view = [[UITextField alloc] init];
    [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    view.autocorrectionType = UITextAutocorrectionTypeNo;
    view.autocapitalizationType = UITextAutocapitalizationTypeNone;
    view.delegate = self;
    view.placeholder = localize(@"preference.multidir.add_directory", nil);
    view.returnKeyType = UIReturnKeyDone;
    return view;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self changeSelectionTo:self.array[indexPath.row]];
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    for (int i = 0; i < self.array.count; i++) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]];
        if (i == indexPath.row) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
}

- (id)createOpenScheme:(NSString *)scheme at:(NSString *)directory {
    return ^(UIAction *action) {
        [UIApplication.sharedApplication
            openURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", scheme, directory]]
            options:@{} completionHandler:nil];
    };
}

// ★ Task247（T9）：伪玻璃档长按手势 → ame240 统一路由（磨砂面板）。
//   菜单项与系统上下文菜单同源：外部打开（按可用 scheme）+ 重命名 + 删除
//   （default 实例仅外部打开）。
- (void)ame247_longPressDirMenu:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint ame247_pt = [gesture locationInView:self.tableView];
    NSIndexPath *ame247_ip = [self.tableView indexPathForRowAtPoint:ame247_pt];
    if (ame247_ip == nil || ame247_ip.row >= self.array.count) return;

    NSString *ame247_name = self.array[ame247_ip.row];
    NSString *ame247_dir = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), ame247_name];
    NSMutableArray<NSDictionary *> *ame247_items = [NSMutableArray array];
    NSDictionary *ame247_apps = @{
        @"shareddocuments": @"Files",
        @"filza": @"Filza",
        @"santander": @"Santander",
    };
    for (NSString *ame247_key in ame247_apps.allKeys) {
        NSString *ame247_url = [NSString stringWithFormat:@"%@://", ame247_key];
        if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:ame247_url]]) {
            NSString *ame247_scheme = ame247_key;
            [ame247_items addObject:@{
                @"title": ame247_apps[ame247_key],
                @"handler": ^{
                    [UIApplication.sharedApplication
                        openURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", ame247_scheme, ame247_dir]]
                        options:@{} completionHandler:nil];
                },
            }];
        }
    }
    if (ame247_ip.row != 0) {
        [ame247_items addObject:@{
            @"title": localize(@"Rename", nil),
            @"systemImage": @"pencil",
            @"handler": ^{
                UITableViewCell *ame247_cell = [self.tableView cellForRowAtIndexPath:ame247_ip];
                [ame247_cell.contentView.subviews.firstObject becomeFirstResponder];
            },
        }];
        [ame247_items addObject:@{
            @"title": localize(@"Delete", nil),
            @"systemImage": @"trash",
            @"destructive": @YES,
            @"handler": ^{
                [self actionDeleteAtIndexPath:ame247_ip];
            },
        }];
    }
    if (ame247_items.count == 0) return;
    UITableViewCell *ame247_anchor = [self.tableView cellForRowAtIndexPath:ame247_ip];
    [AmeNativeMenu ame240_presentMenuWithTitle:ame247_name
                                     dictItems:ame247_items
                                    sourceView:ame247_anchor ?: self.view];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point 
{
    // ★ Task247（T9）：伪玻璃档返回 nil（系统上下文菜单不上场），长按由
    //   viewDidLoad 挂的手势经 ame240 路由呈磨砂面板。
    if (LGCIsPseudoGlassStyleActive()) return nil;
    NSArray *menuItems;
    NSMutableArray *openItems = [[NSMutableArray alloc] init];

    NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), self.array[indexPath.row]];
    NSDictionary *apps = @{
        @"shareddocuments": @"Files",
        @"filza": @"Filza",
        @"santander": @"Santander",
    };
    for (NSString *key in apps.allKeys) {
        NSString *url = [NSString stringWithFormat:@"%@://", key];
        if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:url]]) {
            [openItems addObject:[UIAction
                actionWithTitle:apps[key]
                image:nil
                identifier:nil
                handler:[self createOpenScheme:key at:directory]]];
        }
    }
    UIMenu *open = [UIMenu
        menuWithTitle:@""
        image:nil
        identifier:nil
        options:UIMenuOptionsDisplayInline
        children:openItems];

    if (indexPath.row == 0) {
        // You can't delete or rename the default instance, though there will be a reset action (TODO)
        menuItems = @[open];
    } else {
        UIAction *rename = [UIAction
            actionWithTitle:localize(@"Rename", nil)
            image:[UIImage systemImageNamed:@"pencil"]
            identifier:nil
            handler:^(UIAction *action) {
                UITableViewCell *view = [self.tableView cellForRowAtIndexPath:indexPath];
                [view.contentView.subviews.firstObject becomeFirstResponder];
            }
        ];

        UIAction *delete = [UIAction
            actionWithTitle:localize(@"Delete", nil)
            image:[UIImage systemImageNamed:@"trash"]
            identifier:nil
            handler:^(UIAction *action) {
                [self actionDeleteAtIndexPath:indexPath];
            }
        ];
        delete.attributes = UIMenuElementAttributesDestructive;

        menuItems = @[open, rename, delete];
    }

    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            return [UIMenu menuWithTitle:self.array[indexPath.row] children:menuItems];
        }
    ];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [self actionDeleteAtIndexPath:indexPath];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row == 0) {
        // TODO: Reset action?
        return UITableViewCellEditingStyleNone;
    } else {
        return UITableViewCellEditingStyleDelete;
    }
}

- (void)actionDeleteAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *view = [self.tableView cellForRowAtIndexPath:indexPath];
    NSString *title = localize(@"preference.title.confirm", nil);
    NSString *message = [NSString stringWithFormat:localize(@"preference.title.confirm.delete_game_directory", nil), self.array[indexPath.row]];
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    confirmAlert.popoverPresentationController.sourceView = view;
    confirmAlert.popoverPresentationController.sourceRect = view.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), self.array[indexPath.row]];
        NSError *error;
        if([NSFileManager.defaultManager removeItemAtPath:directory error:&error]) {
            if ([getPrefObject(@"general.game_directory") isEqualToString:self.array[indexPath.row]]) {
                [self changeSelectionTo:self.array[0]];
                [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].accessoryType = UITableViewCellAccessoryCheckmark;
            }
            [self.array removeObjectAtIndex:indexPath.row];
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        } else {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [confirmAlert addAction:cancel];
    [confirmAlert addAction:ok];
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (void) dismissModalViewController {
    dismissModalViewController(self);
}

#pragma mark UITextField

- (void)textFieldDidEndEditing:(UITextField *)sender {
    BOOL isFooterView = sender.superview == self.tableView;
    if (!sender.hasText || [sender.text isEqualToString:sender.placeholder]) {
        if (isFooterView) {
            return;
        }
        sender.text = sender.placeholder;
        return;
    }

    NSError *error;

    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), sender.text];
    if (isFooterView) {
        [NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:NO attributes:nil error:&error];
    } else {
        NSString *source = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), sender.placeholder];
        [NSFileManager.defaultManager moveItemAtPath:source toPath:dest error:&error];
    }

    if (error == nil) {
        [self changeSelectionTo:sender.text];
        if (isFooterView) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:self.array.count inSection:0];
            [self.array addObject:sender.text];
            [self.tableView beginUpdates];
            [self.tableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            [self.tableView endUpdates];
            [self tableView:self.tableView didSelectRowAtIndexPath:indexPath];
            // Clear text
            sender.text = @"";
        } else {
            int index = [self.array indexOfObject:sender.placeholder];
            self.array[index] = sender.placeholder = sender.text;
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
            [self tableView:self.tableView didSelectRowAtIndexPath:indexPath];
        }
    } else {
        // Restore to the previous name if we encounter an error
        if (!isFooterView) {
            sender.text = sender.placeholder;
        }
        showDialog(localize(@"Error", nil), error.localizedDescription);
    }
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    [textField invalidateIntrinsicContentSize];
    CGRect frame = textField.frame;
    frame.size.width = MAX(50, textField.intrinsicContentSize.width + 10);
    textField.frame = frame;
    return YES;
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
