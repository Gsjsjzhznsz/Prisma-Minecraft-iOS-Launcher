#import <Foundation/Foundation.h>

#import "DBNumberedSlider.h"
#import "HostManagerBridge.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "UIKit+NativeSurface.h" // Task160 新拟态规格色
// Task 132：renderer_backend 行的 legacy 显示精化需读当前 profile 的
// renderer 键（与 ame_effective_renderer 同一解析入口）
#import "PLProfiles.h"
#import "PLMirrorCenter.h"   // Task138: mod_mirror 粗控落键后的测速引擎触发
#import "LauncherPrefContCfgViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "UIKit+hook.h"

#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#import "ImageCropperViewController.h"
#import "CustomIconManager.h"
#import "BackgroundSettingsViewController.h"
#import "BackgroundManager.h"
#import "LiquidGlassCompat.h"   // Task224（#4/#19）：界面风格 + 界面缩放中枢
#import "NMToast.h"
#import "UpdateChecker.h"
#import "DataTransferService.h"
#import "DataExportViewController.h"  // Task223：数据导出二级入口   // Task217：数据导出/导入（包名迁移配套）
#import "AboutViewController.h"   // Task217：关于页二级菜单入口
#import "CurseForgeAPIKeyViewController.h"
#import "CustomControlsViewController.h"
#import "AI/AIProviderConfigViewController.h"
#import "AI/AISessionListViewController.h"
#import "AI/AISystemPromptEditorViewController.h"
#import "AI/AiSettings.h"

// ============================================================================
// Task202（G）：语言选择器全量化
// 用户反馈：设置里的语言只能手动选 2 个（+system 共 3 项），要求把全部
// 内置语言填进去。bundle 里实际装着 54 个 <code>.lproj 语言表（crowdin
// 同步体系，见 crowdin.yml），此前 pickKeys 却只硬编码了 system/zh-Hans/en。
// localize()（utils.m）对任意语言码本来就通用：目标 lproj 未命中 → en
// → zh-Hans 三级回退，所以这里的全部 54 个码都可以直接作为 app_language
// 存储值生效，零额外接线。
// 非四主表（zh-Hans/zh-Hant/en/zh-CN，键数 2442）的翻译都只覆盖部分
// 键（如 ja 1868 / km 1863），显示名追加"部分翻译"标记（ame202.lang.partial）
// 以免用户误以为是完整翻译。
// ============================================================================
/// 枚举 mainBundle 内全部语言表目录（"xx.lproj" → "xx"），按码字典序排序。
/// dispatch_once 缓存——目录集在运行期不变，54 项枚举没必要每行刷新都跑。
static NSArray* ame202_availableLanguageCodes(void) {
    static NSArray *ame202_codes = nil;
    static dispatch_once_t ame202_once;
    dispatch_once(&ame202_once, ^{
        NSMutableArray *ame202_list = [NSMutableArray array];
        for (NSString *ame202_path in [NSBundle.mainBundle pathsForResourcesOfType:@"lproj"
                                                                        inDirectory:nil]) {
            NSString *ame202_name = ame202_path.lastPathComponent;
            // Base.lproj 是界面基座资源不是语言；过短的 "xx.lproj" 之外形态不收
            if ([ame202_name hasSuffix:@".lproj"] && ame202_name.length > 6 &&
                ![ame202_name isEqualToString:@"Base.lproj"]) {
                [ame202_list addObject:[ame202_name substringToIndex:ame202_name.length - 6]];
            }
        }
        [ame202_list sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        ame202_codes = [ame202_list copy];
    });
    return ame202_codes;
}

/// 语言码 → 选择器显示名。原生名优先（用户看得懂），NSLocale(en) 兜底，
/// 玩笑语言（Minecraft 特有码）手工表覆盖，最后裸码保底。
/// 四主表之外的码追加"部分翻译"标记。
static NSString* ame202_languageDisplayName(NSString *ame202_code) {
    static NSDictionary *ame202_native = nil;
    static dispatch_once_t ame202_once;
    dispatch_once(&ame202_once, ^{
        ame202_native = @{
            @"af": @"Afrikaans",          @"ar": @"العربية",
            @"az": @"Azərbaycan dili",    @"ba": @"Башҡортса",
            @"bn": @"বাংলা",              @"bn-IN": @"বাংলা (ভারত)",
            @"ca": @"Català",             @"cs": @"Čeština",
            @"da": @"Dansk",              @"de": @"Deutsch",
            @"el": @"Ελληνικά",           @"en": @"English",
            @"en-GB": @"English (UK)",    @"es": @"Español",
            @"et": @"Eesti",              @"fa": @"فارسی",
            @"fi": @"Suomi",              @"fil": @"Filipino",
            @"fr": @"Français",           @"he": @"עברית",
            @"hi": @"हिन्दी",              @"hu": @"Magyar",
            @"id": @"Bahasa Indonesia",   @"it": @"Italiano",
            @"ja": @"日本語",              @"kk": @"Қазақша",
            @"km": @"ភាសាខ្មែរ",           @"ko": @"한국어",
            @"la": @"Latina",             @"lt": @"Lietuvių",
            @"ms": @"Bahasa Melayu",      @"nl": @"Nederlands",
            @"no": @"Norsk",              @"pl": @"Polski",
            @"pt": @"Português",          @"pt-BR": @"Português (Brasil)",
            @"ro": @"Română",             @"ru": @"Русский",
            @"sk": @"Slovenčina",         @"sr": @"Српски",
            @"sr-Latn": @"Srpski (Latin)", @"sv": @"Svenska",
            @"th": @"ไทย",                @"tr": @"Türkçe",
            @"tt": @"Татарча",            @"uk": @"Українська",
            @"vi": @"Tiếng Việt",         @"zh-Hans": @"简体中文",
            @"zh-Hant": @"繁體中文",       @"zh-CN": @"简体中文 (zh-CN)",
            // Minecraft 特有玩笑语言（NSLocale 不认识，手工表）
            @"en-PT": @"Pirate Speak",    @"en-UD": @"English (Upside Down)",
            @"lol": @"LOLCAT",            @"pr": @"Prussian",
        };
    });
    NSString *ame202_name = ame202_native[ame202_code];
    if (ame202_name.length == 0) {
        ame202_name = [[NSLocale localeWithLocaleIdentifier:@"en"]
            displayNameForKey:NSLocaleIdentifier value:ame202_code];
    }
    if (ame202_name.length == 0) {
        ame202_name = ame202_code;
    }
    // 四主表 = 完整翻译；其余（含 ja/km 等高覆盖表）都存在未翻译键，
    // 回退链会把缺键显示成 en/zh-Hans 内容——追加标记说明。
    if (![@[@"zh-Hans", @"zh-Hant", @"en", @"zh-CN"] containsObject:ame202_code]) {
        ame202_name = [ame202_name stringByAppendingFormat:@" · %@",
            localize(@"ame202.lang.partial", nil)];
    }
    return ame202_name;
}

// ============================================================================
// Task225（反馈 #13）：Ame224ZoomEditorViewController（独立缩放编辑页）退役
// ——用户指令"不要单独开一个专区，要放到启动器设置"。缩放（界面/文字）
// 与文字反色开关已内联为外观分区的滑条/开关行；本类与 ame224_openZoomEditor
// 一并删除（调用点已同步清理）。
// ============================================================================

@interface LauncherPreferencesViewController()
// Task 150（[可撤销] 删除渲染器全局控制）：rendererKeys/rendererList 属性
// 退役（唯一消费者 = 设置页渲染器行，行删后无读取方）
@property(nonatomic) BOOL pickingMousePointer;
// 当前正在选择的颜色偏好键（general.text_color / general.card_color）
@property(nonatomic, copy, nullable) NSString *pickingColorPrefKey;
// 顶部 Hero 卡片视图（App 名 + 版本 + 设备信息），作为 tableHeaderView 的一部分
@property(nonatomic, strong, nullable) UIView *heroCard;
@end

@implementation LauncherPreferencesViewController

#pragma mark - Task229: options.txt toolkit (sprint toggle + keybind sync)

/// 返回 POJAV_HOME 下所有实例的 options.txt 绝对路径（instances/<inst>/
/// versions/<ver>/game/options.txt 三层扫描；mtime 降序排列）。
- (NSArray<NSString *> *)ame229_allInstanceOptionsPaths {
    const char *home = getenv("POJAV_HOME");
    if (home == NULL || home[0] == '\0') return @[];
    NSString *instancesRoot = [NSString stringWithFormat:@"%s/instances", home];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *inst in [fm contentsOfDirectoryAtPath:instancesRoot error:nil]) {
        NSString *instDir = [instancesRoot stringByAppendingPathComponent:inst];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:instDir isDirectory:&isDir] || !isDir) continue;
        // 新隔离布局：instances/<inst>/versions/<ver>/game/options.txt
        NSString *versionsDir = [instDir stringByAppendingPathComponent:@"versions"];
        for (NSString *ver in [fm contentsOfDirectoryAtPath:versionsDir error:nil]) {
            NSString *opt = [[versionsDir stringByAppendingPathComponent:ver]
                stringByAppendingPathComponent:@"game/options.txt"];
            if ([fm fileExistsAtPath:opt]) [out addObject:opt];
        }
        // 兼容旧布局：实例根直接挂 options.txt
        NSString *optRoot = [instDir stringByAppendingPathComponent:@"options.txt"];
        if ([fm fileExistsAtPath:optRoot] && ![out containsObject:optRoot]) {
            [out addObject:optRoot];
        }
    }
    // mtime 降序（最近玩的在前）
    __block NSFileManager *fmB = fm;
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [fmB attributesOfItemAtPath:a error:nil].fileModificationDate ?: [NSDate distantPast];
        NSDate *db = [fmB attributesOfItemAtPath:b error:nil].fileModificationDate ?: [NSDate distantPast];
        return [db compare:da];
    }];
    return out;
}

/// 读 options.txt 成行数组（空文件/缺失返回 nil）。
- (NSArray<NSString *> *)ame229_linesOfOptions:(NSString *)path {
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) return nil;
    return [content componentsSeparatedByString:@"\n"];
}

/// Task229（反馈 #2 持续奔跑）：把 toggleSprint 写进指定 options.txt。
/// present=写 true（切换疾跑：按一次疾跑键=持续奔跑，vanilla 辅助功能）。
- (BOOL)ame229_writeToggleSprint:(BOOL)present toOptions:(NSString *)path {
    NSArray<NSString *> *lines = [self ame229_linesOfOptions:path];
    if (lines == nil) return NO;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL wrote = NO;
    for (NSString *ln in lines) {
        if ([ln hasPrefix:@"toggleSprint:"]) {
            [out addObject:present ? @"toggleSprint:true" : @"toggleSprint:false"];
            wrote = YES;
        } else {
            [out addObject:ln];
        }
    }
    if (!wrote) {
        // 追加到末尾（找最后一个非空行之后；MC 对行序不敏感）
        [out addObject:present ? @"toggleSprint:true" : @"toggleSprint:false"];
    }
    NSString *newContent = [out componentsJoinedByString:@"\n"];
    BOOL ok = [newContent writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (ok) {
        NSLog(@"[Settings] Task229 toggleSprint %@ -> %@ (%@)", present ? @"true" : @"false",
              path.lastPathComponent, path);
    }
    return ok;
}

/// Task229（反馈 #2 右 Shift 复发）：跨实例键位同步。源 = mtime 最新且
/// key_key.* 行数最多的 options.txt；把这些键位行合并进其他实例（只补
/// 缺失键，不覆盖已有绑定——各实例显式改过的键位不动）。
- (void)ame229_syncKeybindsAcrossInstances {
    NSArray<NSString *> *paths = [self ame229_allInstanceOptionsPaths];
    if (paths.count < 2) {
        [self showSuccessMessage:localize(@"ame229.keybind.sync.one_instance", nil)];
        return;
    }
    // 源选择：优先“非默认键位行最多”的（用户改绑痕迹最重的档），
    // 并列时取 mtime 最新（paths 已按 mtime 降序）。
    NSString *source = nil;
    NSInteger bestCount = 0;
    for (NSString *p in paths) {
        NSArray<NSString *> *lines = [self ame229_linesOfOptions:p];
        if (lines == nil) continue;
        NSInteger cnt = 0;
        for (NSString *ln in lines) {
            if ([ln hasPrefix:@"key_key."]) cnt++;
        }
        if (cnt > bestCount) { bestCount = cnt; source = p; }
    }
    if (source == nil || bestCount == 0) {
        [self showSuccessMessage:localize(@"ame229.keybind.sync.no_bindings", nil)];
        return;
    }
    NSDictionary *sourceBindings = [self ame229_keybindsOfOptions:source];
    if (sourceBindings.count == 0) {
        [self showSuccessMessage:localize(@"ame229.keybind.sync.no_bindings", nil)];
        return;
    }
    NSInteger syncedFiles = 0, addedRows = 0;
    for (NSString *p in paths) {
        if ([p isEqualToString:source]) continue;
        NSArray<NSString *> *lines = [self ame229_linesOfOptions:p];
        if (lines == nil) continue;
        NSMutableSet *existing = [NSMutableSet set];
        NSMutableArray<NSString *> *out = [NSMutableArray arrayWithArray:lines];
        for (NSString *ln in lines) {
            NSRange c = [ln rangeOfString:@":"];
            if (c.location != NSNotFound) {
                [existing addObject:[ln substringToIndex:c.location]];
            }
        }
        NSInteger before = out.count;
        for (NSString *key in sourceBindings) {
            if (![existing containsObject:key]) {
                NSString *row = [NSString stringWithFormat:@"%@:%@", key, sourceBindings[key]];
                // 插在最后一行（通常为空行）之前
                if (out.count > 0 && [out.lastObject isEqualToString:@""]) {
                    [out insertObject:row atIndex:out.count - 1];
                } else {
                    [out addObject:row];
                }
            }
        }
        if (out.count > before) {
            NSString *newContent = [out componentsJoinedByString:@"\n"];
            if ([newContent writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                syncedFiles++;
                addedRows += (out.count - before);
            }
        }
    }
    NSLog(@"[Settings] Task229 keybind sync: source=%@ (%ld binding rows) -> %ld file(s), %ld row(s) added",
          source, (long)bestCount, (long)syncedFiles, (long)addedRows);
    NSString *msg = [NSString stringWithFormat:localize(@"ame229.keybind.sync.done", nil),
                     (long)syncedFiles, (long)addedRows];
    [self showSuccessMessage:msg];
}

/// 抽取 options.txt 的全部 key_key.* 绑定（key -> value）。
- (NSDictionary<NSString *, NSString *> *)ame229_keybindsOfOptions:(NSString *)path {
    NSArray<NSString *> *lines = [self ame229_linesOfOptions:path];
    if (lines == nil) return @{};
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    for (NSString *ln in lines) {
        if (![ln hasPrefix:@"key_key."]) continue;
        NSRange c = [ln rangeOfString:@":"];
        if (c.location == NSNotFound || c.location + 1 >= ln.length) continue;
        out[[ln substringToIndex:c.location]] = [ln substringFromIndex:c.location + 1];
    }
    return out;
}


- (id)init {
    self = [super init];
    // 不设置 self.title，避免顶部导航栏出现"设置"标题黑条（参照 FCL 无 title 风格）
    return self;
}

- (NSString *)imageName {
    return @"MenuSettings";
}

- (void)openImagePicker {
    // 检查是否已经显示了图片选择器
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in scene.windows) {
                    for (UIView *view in window.subviews) {
                        if ([view isKindOfClass:[UIAlertController class]] || 
                            [view isKindOfClass:[UIImagePickerController class]]) {
                            // 如果已经显示了相关控制器，直接返回
                            return;
                        }
                    }
                }
            }
        }
    }
    
    UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
    imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    imagePicker.delegate = self;
    
    // 延迟显示图片选择器，避免与UIAlertController冲突
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:imagePicker animated:YES completion:nil];
    });
}

- (void)openMousePointerPicker {
    self.pickingMousePointer = YES;
    UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
    imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    imagePicker.delegate = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:imagePicker animated:YES completion:nil];
    });
}

#pragma mark - 自定义颜色选择（字体/卡片颜色）

- (void)openColorPickerForKey:(NSString *)fullKey title:(NSString *)title {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.title = title;
        picker.delegate = self;
        // 预选当前已保存的颜色
        NSString *hex = getPrefObject(fullKey);
        UIColor *current = [self colorFromHexString:hex];
        if (current) {
            picker.selectedColor = current;
        }
        self.pickingColorPrefKey = fullKey;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentViewController:picker animated:YES completion:nil];
        });
    } else {
        [self showCustomIconError:localize(@"i18n_str_367", nil)];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController API_AVAILABLE(ios(14.0)) {
    NSString *key = self.pickingColorPrefKey;
    self.pickingColorPrefKey = nil;
    if (!key) return;
    UIColor *color = viewController.selectedColor;
    NSString *hex = [self hexStringFromColor:color];
    setPrefObject(key, hex);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceChanged" object:nil];
    [self.tableView reloadData];
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

- (NSString *)hexStringFromColor:(UIColor *)color {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02X%02X%02X", (unsigned)(r * 255), (unsigned)(g * 255), (unsigned)(b * 255)];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        // 在图片选择器完全关闭后再处理图片
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showCustomIconError:localize(@"i18n_str_368", nil)];
                return;
            }
            if (self.pickingMousePointer) {
                self.pickingMousePointer = NO;
                NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                NSData *pngData = UIImagePNGRepresentation(selectedImage);
                [NSFileManager.defaultManager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                BOOL ok = [pngData writeToFile:path atomically:YES];
                if (ok) {
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:localize(@"i18n_str_369", nil)];
                } else {
                    [self showCustomIconError:localize(@"i18n_str_370", nil)];
                }
                return;
            }
            // 显示处理中的提示
            [self showProcessingIndicator];
            
            // 检查图片是否为正方形
            if (selectedImage.size.width != selectedImage.size.height) {
                // 如果不是正方形，打开裁剪界面
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    if (croppedImage) {
                        // 保存裁剪后的图片
                        [[CustomIconManager sharedManager] saveCustomIcon:croppedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (success) {
                                    [weakSelf showSuccessMessage:localize(@"i18n_str_371", nil)];
                                    // 更新应用图标选择器的显示
                                    [weakSelf.tableView reloadData];
                                } else {
                                    NSString *errorMessage = error.localizedDescription ?: localize(@"i18n_str_372", nil);
                                    [weakSelf showCustomIconError:errorMessage];
                                }
                            });
                        }];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf showCustomIconError:localize(@"i18n_str_373", nil)];
                        });
                    }
                };
                [weakSelf.navigationController pushViewController:cropperVC animated:YES];
            } else {
                // 如果是正方形，直接保存
                [[CustomIconManager sharedManager] saveCustomIcon:selectedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (success) {
                            [self showSuccessMessage:localize(@"i18n_str_371", nil)];
                            // 更新应用图标选择器的显示
                            [self.tableView reloadData];
                        } else {
                            NSString *errorMessage = error.localizedDescription ?: localize(@"i18n_str_372", nil);
                            [self showCustomIconError:errorMessage];
                        }
                    });
                }];
            }
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pickingMousePointer) {
                self.pickingMousePointer = NO;
            } else {
                [self showCustomIconError:localize(@"i18n_str_374", nil)];
            }
        });
    }];
}

#pragma mark - Custom Icon Helper Methods

- (void)showProcessingIndicator {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_78", nil) message:localize(@"i18n_str_375", nil) preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    // 2秒后自动关闭提示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_80", nil) message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCustomIconError:(NSString *)errorMessage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil) message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
    // 彻底隐藏导航栏黑条（仅当作为非 modal 根页面且是栈中唯一 VC 时）
    // 尽早设置，避免导航栏闪烁
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }

    // 启用设置项搜索（必须在 super viewDidLoad 之前设置，父类据此创建 searchController）
    self.searchEnabled = YES;

    self.getPreference = ^id(NSString *section, NSString *key){
        // AI 助手分区：直接与 AiSettings 打通（AiSettings 读写 NSUserDefaults，不走通用偏好存储）
        if ([section isEqualToString:@"ai"]) {
            if ([key isEqualToString:@"safety_mode"]) {
                // Task189：存储值改稳定 ID（safe/ask/yolo）——旧中文显示串
                // 仅存在于历史 UI 层往返，NSUserDefaults 恒存枚举号，零迁移负担；
                // pickList 本地化展示，✓ 标记按 ID 匹配。
                switch ([[AiSettings sharedSettings] safetyMode]) {
                    case AiSafetyModeSafe:  return @"safe";
                    case AiSafetyModeAsk:   return @"ask";
                    case AiSafetyModeYOLO:  return @"yolo";
                }
            }
            if ([key isEqualToString:@"markdown_enabled"]) {
                return @([[AiSettings sharedSettings] markdownEnabled]);
            }
            return nil;
        }
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        // Task 83（FSR 独立化）：FSR 行已移入"视频设置"分区（跟随渲染器/
        // 分辨率），但存储键保持历史键名 mobileglues.fsr1_setting——
        // JavaLauncher（MG config.json）、SurfaceViewController（Task83 联动）
        // 等所有读者都读它，改键名会静默丢失用户设置。
        if ([section isEqualToString:@"video"] && [key isEqualToString:@"fsr1_setting"]) {
            keyFull = @"mobileglues.fsr1_setting";
        }
        // Task 130：同款重映射——video.fsr_rcas_sharpness -> mobileglues.
        // fsr_rcas_sharpness（RCAS 锐化强度 pick 行也挂在视频分区，多渲染器
        // 通用：MobileGlues 读 config.json，zink/MobileGL 读环境变量，
        // 三路同源见 JavaLauncher ame130_export_rcas_env）。
        if ([section isEqualToString:@"video"] && [key isEqualToString:@"fsr_rcas_sharpness"]) {
            keyFull = @"mobileglues.fsr_rcas_sharpness";
        }
        // Task 132（MG 三端合并）-> Task 142（后端独立存储）：MobileGlues
        // 分区的单一 pick 行现在是【mg 后端设置】本体（mobileglues.
        // renderer_backend），与渲染器层（video.renderer：auto/mg/经典项）
        // 分居——用户明令"渲染器选择只有一个 mg，不写什么后端，后端根据
        // mg 设置启动，默认 vulkan"。历史：Task139 双写让设置页覆写当前
        // 游戏的独立渲染器（"变回设置里选的那个"），Task140 改为只写全局
        // video.renderer，Task142 起后端彻底独立成键。
        // 分层：设置页 = 全局默认；实例设置页（ProfileSettings）= 该游戏
        // 自己的值（含"跟随全局"开关）；启动链 ame_effective_renderer /
        // JavaLauncher profile 优先不变。
        if ([section isEqualToString:@"mobileglues"] && [key isEqualToString:@"renderer_backend"]) {
            // Task 142：本行回归"mg 设置"本职——显示 mg 的当前后端
            // （ame142_effective_backend_key：新键 → legacy 全局家族键 →
            // legacy 档位 → 默认 Vulkan 直连）。Task140 曾在此显示全局
            // 渲染器 video.renderer 的值（当时后端行直写渲染器键），
            // 两层职责现已分居：渲染器行管渲染器（auto/mg/经典项），
            // 本行管 mg 的后端，互不伪装。返回家族物理键：pickKeys ✓
            // 匹配 + pickList 本地化显示。
            ame142_migrateRendererStorage();
            return ame142_effective_backend_key();
        }
        // Task138：模组镜像源行（已移入 download 分区）——统一粗控读数：
        // 读 assetDownloadSource 为准（写入时两键同值；细粒度分叉时以
        // 文件下载键为准显示，用户在两行上仍可单独调整）。
        if ([section isEqualToString:@"download"] && [key isEqualToString:@"mod_mirror"]) {
            NSString *ame138_mm = getPrefObject(@"download.assetDownloadSource");
            if ([ame138_mm isKindOfClass:NSString.class] &&
                ([ame138_mm isEqualToString:@"official_first"] ||
                 [ame138_mm isEqualToString:@"mirror_first"] ||
                 [ame138_mm isEqualToString:@"speed_first"])) {
                return ame138_mm;
            }
            return @"speed_first";
        }
        // Task218：四个细粒度镜像策略行的显示兜底——存储值缺失/非法时显示
        // 出厂默认 speed_first（与 PLMirrorCenter policyForType 的语义一致），
        // 保证"行右侧标签"与"点开选择器的 ✓ 标记"永远同源同值（隔离实例
        // 新播种等极端场合下键短暂缺席也不出现空标签 + 无 ✓ 的错位观感）。
        if ([section isEqualToString:@"download"] &&
            ([key isEqualToString:@"fileSource"] ||
             [key isEqualToString:@"assetSearchSource"] ||
             [key isEqualToString:@"assetDownloadSource"] ||
             [key isEqualToString:@"modLoaderSource"])) {
            NSString *ame218_v = getPrefObject([NSString stringWithFormat:@"download.%@", key]);
            if ([ame218_v isKindOfClass:NSString.class] &&
                ([ame218_v isEqualToString:@"official_first"] ||
                 [ame218_v isEqualToString:@"mirror_first"] ||
                 [ame218_v isEqualToString:@"speed_first"])) {
                return ame218_v;
            }
            return @"speed_first";
        }
        // Task 150（[可撤销] 删除渲染器全局控制）：主渲染器行（video.renderer）
        // 随设置页渲染器选择一并退役——每个实例强制单独选择（实例页独占写
        // profile 键），无键实例由 ame_effective_renderer 落 auto。
        // Task224（#4/#19）：外观分区两行经 LiquidGlassCompat 存取
        // （NSUserDefaults 键 prisma.interface_style / prisma.ui_scale，
        // 与通用偏好存储解耦——风格解析在 C 层零依赖可用，启动早期/
        // 其它 TU 均可直接调用）。
                // ★ Task226（#17）：外观行已从独立 appearance 分区迁入【启动器设置
        //（general）】——键判定同步改挂 general；#16 反色开关退役
        //（text_auto_contrast 读取移除，白底黑边全局字体常开）。
if ([section isEqualToString:@"general"]) {
            if ([key isEqualToString:@"interface_style"]) {
                return LGCStringFromInterfaceStyle(LGCStoredInterfaceStyle());
            }
            // Task225（#13）：界面/文字缩放以【整数百分比】呈现给滑条
            //（85-125 / 85-130），存储仍是 prisma.ui_scale / prisma.text_scale
            // 双精度倍率。旧 ui_zoom 键退役（独立编辑页一并退役）。
            if ([key isEqualToString:@"ui_scale"]) {
                return @((NSInteger)round(LGCUIScaleMultiplier() * 100.0));
            }
            if ([key isEqualToString:@"text_scale"]) {
                return @((NSInteger)round(LGCTextScaleMultiplier() * 100.0));
            }
        }
        return getPrefObject(keyFull);
    };
    self.setPreference = ^(NSString *section, NSString *key, id value){
        // Task 150（[可撤销] 删除渲染器全局控制）：旧 ame140_writeRendererGlobal
        // 块（全局 video.renderer 写入 + profile 遮蔽提示）随渲染器行一并退役；
        // 渲染器选择唯一入口 = 实例设置页（profile 键）。
        // AI 助手分区：回写到 AiSettings
        if ([section isEqualToString:@"ai"]) {
            if ([key isEqualToString:@"safety_mode"]) {
                AiSafetyMode mode = AiSafetyModeSafe;
                if ([value isKindOfClass:[NSNumber class]]) {
                    mode = (AiSafetyMode)[value integerValue];
                } else if ([value isKindOfClass:[NSString class]]) {
                    NSString *s = value;
                    // Task189：稳定 ID 优先；模式词兜底兼容任何语言的显示串
                    //（所有翻译都保留括号内的 Safe/Ask/YOLO 模式词）。
                    if ([s containsString:@"ask"]) {
                        mode = AiSafetyModeAsk;
                    } else if ([s containsString:@"yolo"]) {
                        mode = AiSafetyModeYOLO;
                    } else if ([s containsString:@"Ask"]) {
                        mode = AiSafetyModeAsk;
                    } else if ([s containsString:@"YOLO"]) {
                        mode = AiSafetyModeYOLO;
                    }
                }
                [[AiSettings sharedSettings] setSafetyMode:mode];
            } else if ([key isEqualToString:@"markdown_enabled"]) {
                [[AiSettings sharedSettings] setMarkdownEnabled:[value boolValue]];
            }
            return;
        }
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        // Task 83：同上——video.fsr1_setting 重映射到 mobileglues.fsr1_setting
        if ([section isEqualToString:@"video"] && [key isEqualToString:@"fsr1_setting"]) {
            keyFull = @"mobileglues.fsr1_setting";
        }
        // Task 130：锐化强度同款重映射（存储值 pick 行写字符串，
        // ame130_export_rcas_env 双态解析 NSNumber/NSString）
        if ([section isEqualToString:@"video"] && [key isEqualToString:@"fsr_rcas_sharpness"]) {
            keyFull = @"mobileglues.fsr_rcas_sharpness";
        }
        // Task138：模组镜像源行——统一粗控写入：同时落
        // assetSearchSource 与 assetDownloadSource（模组的 API 搜索与
        // 文件下载同属 MCIM 体系，粗控一体变更语义最直观）。
        if ([section isEqualToString:@"download"] && [key isEqualToString:@"mod_mirror"]) {
            setPrefObject(@"download.assetSearchSource", value);
            setPrefObject(@"download.assetDownloadSource", value);
            // 选择变化后让测速引擎立即跟上（speed_first 时补测）
            [PLMirrorCenter startSpeedProbesIfNeeded];
            return;
        }
        // Task 132（MG 三端合并）-> Task 142（后端独立存储）：本行只写
        // 自己的键 mobileglues.renderer_backend（mg 的后端设置），不再
        // 触碰渲染器层 video.renderer（Task132-140 曾直写渲染器键——
        // "后端"与"渲染器"两层耦合正是"选了后端、渲染器行跟着变"的
        // 伪装来源）。渲染器层的选择（auto/mg/经典项）由渲染器行独占；
        // mg 启动时按本键解析后端（ame_effective_renderer 的 mg 分支，
        // 默认 Vulkan 直连）。legacy 档位键 mobilegl_backend 同步退役
        // （显式改选即 Task132 承诺的 legacy 终点；也避免 JavaLauncher
        // 的档位环境变量分支与新键互相矛盾）。
        if ([section isEqualToString:@"mobileglues"] && [key isEqualToString:@"renderer_backend"]) {
            NSString *ame142_rbValue = [value isKindOfClass:NSString.class] ? value : nil;
            if (ame142_rbValue && [getRendererFamilyKeys() containsObject:ame142_rbValue]) {
                setPrefObject(@"mobileglues.renderer_backend", ame142_rbValue);
                setPrefInt(@"mobileglues.mobilegl_backend", 0);
                NSLog(@"[PLPrefTable] Task142: renderer_backend written to OWN KEY = %@ "
                      @"(video.renderer untouched; legacy tier retired)", ame142_rbValue);
            } else {
                setPrefObject(@"mobileglues.renderer_backend", value);
            }
            // Task 138：选择即提示（dylib 缺失不再等到启动闪退才发现）。
            // 三个选项按用户指令无条件列出（Task132），Mithril 的
            // libmithril.dylib 是需另外下载的预编译产物——缺失时此处
            // NMToast 即时告知，启动时 ame_effective_renderer 会再兜底
            // 回落 auto（ANGLE），游戏不会闪退。
            if ([value isKindOfClass:NSString.class] && ![value isEqualToString:@"auto"]) {
                NSString *ame138_pick = @(ame_physical_renderer_dylib([value UTF8String]));
                NSString *ame138_pickPath = [NSBundle.mainBundle.bundlePath
                    stringByAppendingPathComponent:[@"Frameworks"
                        stringByAppendingPathComponent:ame138_pick]];
                if ([ame138_pick hasSuffix:@".dylib"] &&
                    ![[NSFileManager defaultManager] fileExistsAtPath:ame138_pickPath]) {
                    NSString *ame138_pickName =
                        [ame138_pick isEqualToString:@ RENDERER_NAME_MITHRIL]
                            ? localize(@"preference.title.renderer_backend-mithril", nil)
                            : value;
                    [NMToast showMessage:[NSString stringWithFormat:
                        localize(@"preference.warning.renderer_missing_dylib", nil), ame138_pickName]];
                }
            }
            return;
        }
        // Task 150（[可撤销] 删除渲染器全局控制）：video.renderer 写入分支
        // 退役（行已删，此分支不再可达）。
        // Task224（#4）：外观分区的写入走 LiquidGlassCompat（广播 + 日志
        // 铅点在该层）；行的 action 块补 refreshUIEffect +
        // BackgroundUIEffectChanged 的全量重铺（与背景设置页同通路）。
        if ([section isEqualToString:@"general"]) {
            if ([key isEqualToString:@"interface_style"]) {
                if ([value isKindOfClass:[NSString class]]) {
                    LGCSetStoredInterfaceStyle(LGCInterfaceStyleFromString(value));
                }
                return;
            }
            if ([key isEqualToString:@"ui_scale"]) {
                // 滑条回调每 tick 都走这里（sliderMoved 不派发 action）——
                // LGCSetUIScaleMultiplier 内部做步进铉制 + 广播，主菜单/
                // 右栏实时重排即由该广播驱动。
                double ame225_pct = [value isKindOfClass:[NSNumber class]]
                    ? [value doubleValue] : [value doubleValue];
                LGCSetUIScaleMultiplier(ame225_pct / 100.0);
                return;
            }
            if ([key isEqualToString:@"text_scale"]) {
                double ame225_pct = [value doubleValue];
                LGCSetTextScaleMultiplier(ame225_pct / 100.0);
                return;
            }
        }
        setPrefObject(keyFull, value);
    };
    
    self.hasDetail = YES;
    self.prefDetailVisible = self.navigationController == nil;
    
    self.prefSections = @[@"general", @"download", @"video", @"mobileglues", @"control", @"java", @"debug", @"ai"];

    // Task224（#19）：「界面缩放」行右侧显示当前百分比。typeButton 基类
    // 块不写 detailTextLabel——在 prefContents 构建之前包装基类块并只对
    // ui_zoom 行追加显示（Task133 家法：type* 块替换必须在 items 构建
    // 之前完成，否则指针比较失配、点击路由全部失灵；本包装点在
    // prefContents 赋值之前，满足该约束）。
    CreateView ame224_baseButton = self.typeButton;
    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        ame224_baseButton(cell, section, key, item);
        if ([key isEqualToString:@"ui_zoom"]) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%d%%",
                (int)round(LGCUIScaleMultiplier() * 100.0)];
        }
    };

    // Task 142：渲染器键读取前先做分层迁移（幂等；旧版家族键直写
    // video.renderer/profile 的存量数据在此入位——渲染器层 "mg" +
    // 后端键）。Task150：设置页渲染器行退役，迁移仍保留（实例页与
    // 启动链读前仍需归一家族键）。
    ame142_migrateRendererStorage();
    
    // 检查是否在游戏中：如果当前可见视图控制器是 SurfaceViewController，则在游戏中
    BOOL(^whenNotInGame)() = ^BOOL(){
        UIViewController *visibleVC = currentVC();
        return ![visibleVC isKindOfClass:NSClassFromString(@"SurfaceViewController")];
    };

    // Task202（G）：app_language 行的动态键值表——system + 全部 54 个内置
    // 语言码。在此预构建局部数组，字典字面量内只做引用（不使用语句
    // 表达式——上轮结论：该形态在树内无先例，维护风险不值当）。
    NSArray *ame202_langKeys =
        [@[@"system"] arrayByAddingObjectsFromArray:ame202_availableLanguageCodes()];
    NSMutableArray *ame202_langNames = [NSMutableArray
        arrayWithObject:localize(@"i18n_str_382", nil)];
    for (NSString *ame202_code in ame202_availableLanguageCodes()) {
        [ame202_langNames addObject:ame202_languageDisplayName(ame202_code)];
    }

    // --- 定义弹窗显示的 Block，防止循环引用使用 weakSelf ---
    __weak typeof(self) weakSelf = self;
    void (^showTouchInfoAlert)(BOOL) = ^(BOOL enabled) {
        // 这个 Block 仅用于显示说明，不再负责逻辑判断
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"preference.popup.touch_info.title", nil)
                                                                           message:localize(@"preference.popup.touch_info.message", nil)
                                                                    preferredStyle:UIAlertControllerStyleAlert];

            [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]];

            [alert addAction:[UIAlertAction actionWithTitle:@"GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/TouchController/TouchController"] options:@{} completionHandler:nil];
            }]];

            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    };

    // -----------------------------------------------------------

    self.prefContents = @[
        @[
            // General settings
            @{@"icon": @"cube"},
            // ★ Task226（反馈 #17：取消 appearance 独立分区——外观三行内联
            // 进启动器设置；反色开关随 #16 一并退役）：从旧 appearance 分区
            // 原位投迁（getPreference/setPreference 的键处理同步改挂
            // general 分区，存储仍走 LiquidGlassCompat 的 NSUserDefaults
            // 键 prisma.interface_style / prisma.ui_scale / prisma.text_scale）。
            @{@"key": @"interface_style",
              @"title": localize(@"preference.title.interface_style", nil),
              @"hasDetail": @YES,
              @"icon": @"paintbrush",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"auto",
                  @"native",
                  @"liquid_glass",
                  @"pseudo_glass"
              ],
              @"pickList": @[
                  localize(@"prisma.interface_style.auto", nil),
                  localize(@"prisma.interface_style.native", nil),
                  localize(@"prisma.interface_style.liquid_glass", nil),
                  localize(@"prisma.interface_style.pseudo_glass", nil)
              ],
              @"action": ^(NSString *value){
                  // Task224（#4）：全量重铺与背景设置页同一既有 live-reload
                  // 通路（refreshUIEffect + BackgroundUIEffectChanged——
                  // 卡片/cell/导航栏/模态底层全量重铺）。
                  // ★ Task226（反馈 #6：切换风格闪退）：pick 弹层收起动画
                  // 进行中同步全量重铺（数百视图层级拆装）会与 UIKit 的
                  // 过渡事务竞争（装机表现为闪退一下，重启后正常）。延迟
                  // 一个 runloop 拍——让弹层收起事务先落地，重铺在干净
                  // 的事务边界上执行。
                  dispatch_async(dispatch_get_main_queue(), ^{
                      [[BackgroundManager sharedManager] refreshUIEffect];
                      [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
                  });
              }
            },
            @{@"key": @"ui_scale",
              @"title": localize(@"preference.title.ui_scale", nil),
              @"hasDetail": @YES,
              @"icon": @"arrow.up.left.and.arrow.down.right",
              @"type": self.typeSlider,
              @"min": @(85),
              @"max": @(125),
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"text_scale",
              @"title": localize(@"preference.title.text_scale", nil),
              @"hasDetail": @YES,
              @"icon": @"textformat.size",
              @"type": self.typeSlider,
              @"min": @(85),
              @"max": @(130),
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"check_sha",
              @"hasDetail": @YES,
              @"icon": @"lock.shield",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            // 旧"下载源"行已移除：general.download_source 已由启动时的
            // migrateDownloadSourcePreferences 迁移到下方"下载镜像策略"分组的 4 个分类键。
            // Task138：模组镜像源行也移入"下载镜像策略"分区（用户指令），
            // 成为搜索+下载两键的统一粗控（见 download 分区新行与
            // getPreference/setPreference 的 mod_mirror 分支）。
            @{@"key": @"ui_layout",
              @"title": localize(@"i18n_str_376", nil),
              @"hasDetail": @YES,
              @"icon": @"rectangle.split.3x3",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"vs",
                  @"card"
              ],
              @"pickList": @[
                  localize(@"i18n_str_377", nil),
                  localize(@"i18n_str_378", nil)
              ]
            },
            @{@"key": @"ui_theme",
              @"title": localize(@"i18n_str_379", nil),
              @"hasDetail": @YES,
              @"icon": @"circle.lefthalf.filled",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"dark",
                  @"light",
                  @"auto"
              ],
              @"pickList": @[
                  localize(@"i18n_str_380", nil),
                  localize(@"i18n_str_381", nil),
                  localize(@"i18n_str_382", nil)
              ],
              @"action": ^(NSString *value){
                  // 实时应用主题，发通知由 SceneDelegate 处理。
                  // 不调用 loadPreferences(YES) 等会重置账号偏好的操作，
                  // 仅设置 window.overrideUserInterfaceStyle，账号数据不受影响。
                  // Task161：显式选择标记——SceneDelegate 的一次性迁移
                  // （历史默认 dark/light → auto）从此对本设备免疫。
                  setPrefBool(@"general.ui_theme_explicit", YES);
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"UIThemeChanged" object:value];
              }
            },
            @{@"key": @"app_language",
              @"title": localize(@"i18n_str_2068", nil),
              @"hasDetail": @YES,
              @"icon": @"globe",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              // Task202（G）：system + 全部内置语言（bundle 实测 54 个
              // .lproj 表）。localize() 的 en→zh-Hans 回退链对任意码
              // 通用（utils.m），缺键语言显示回退内容 + "部分翻译"标记。
              @"pickKeys": ame202_langKeys,
              @"pickList": ame202_langNames,
              @"action": ^(NSString *value){
                  // 语言切换后发送通知，让界面重新加载以应用新语言
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"AppLanguageChanged" object:value];
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"custom_accent_color",
              @"title": localize(@"i18n_str_383", nil),
              @"hasDetail": @YES,
              @"icon": @"paintpalette.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.accent_color" title:localize(@"i18n_str_383", nil)];
              }
            },
            @{@"key": @"custom_text_color",
              @"title": localize(@"i18n_str_384", nil),
              @"hasDetail": @YES,
              @"icon": @"textformat",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.text_color" title:localize(@"i18n_str_384", nil)];
              }
            },
            @{@"key": @"custom_card_color",
              @"title": localize(@"i18n_str_385", nil),
              @"hasDetail": @YES,
              @"icon": @"rectangle.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.card_color" title:localize(@"i18n_str_385", nil)];
              }
            },
            @{@"key": @"reset_appearance_colors",
              @"title": localize(@"i18n_str_386", nil),
              @"icon": @"arrow.counterclockwise",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  setPrefObject(@"general.accent_color", @"");
                  setPrefObject(@"general.text_color", @"");
                  setPrefObject(@"general.card_color", @"");
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceChanged" object:nil];
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"multi_threaded",
              @"title": localize(@"i18n_str_387", nil),
              @"hasDetail": @YES,
              @"icon": @"bolt.fill",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"curseforge_api_key",
              @"hasDetail": @YES,
              @"icon": @"key.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"cosmetica",
              @"hasDetail": @YES,
              @"icon": @"eyeglasses",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_logging",
              @"hasDetail": @YES,
              @"icon": @"doc.badge.gearshape",
              @"type": self.typeSwitch,
              // Task205：本行升格为全局日志等级开关——除原有启动器侧
              // NSDebugLog 外，JavaLauncher 读 general.debug_logging 向
              // 游戏会话导出 AMETHYST_LOG_LEVEL=debug（vgpu 探针放宽限频
              // + realize 属性装配 tracer、tinygl4angle 观察器扩容、
              // 预编译 gl4es 开 LIBGL_LOGSHADERERROR）。用户需求原文：
              // "能不能添加日志等级，比如 debug 等级，可以让渲染器错误
              // 更为详细的显示错误，放在启动器设置"。设置下次会话生效。
              @"action": ^(BOOL enabled){
                  debugLogEnabled = enabled;
                  NSLog(@"[Debugging] Debug log enabled: %@ (renderer diagnostics verbose from next game session)", enabled ? @"YES" : @"NO");
              }
            },
            @{@"key": @"appicon",
              @"hasDetail": @YES,
              @"icon": @"paintbrush",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"action": ^void(NSString *iconName) {
                  if ([iconName isEqualToString:@"AppIcon-Light"]) {
                      iconName = nil;
                      [[CustomIconManager sharedManager] removeCustomIcon];
                  } else if ([iconName isEqualToString:@"CustomIcon"]) {
                      if (![[CustomIconManager sharedManager] hasCustomIcon]) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil) message:localize(@"i18n_str_389", nil) preferredStyle:UIAlertControllerStyleAlert];
                              UIAlertAction *okAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil];
                              [alert addAction:okAction];
                              [self presentViewController:alert animated:YES completion:nil];
                          });
                          dispatch_async(dispatch_get_main_queue(), ^{
                              [self.tableView reloadData];
                          });
                          return;
                      }
                      [[CustomIconManager sharedManager] setCustomIconWithCompletion:^(BOOL success, NSError * _Nullable error) {
                          if (!success) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  NSLog(@"Error in appicon: %@", error);
                                  showDialog(localize(@"Error", nil), error.localizedDescription);
                              });
                          }
                      }];
                      return;
                  }
                  [UIApplication.sharedApplication setAlternateIconName:iconName completionHandler:^(NSError * _Nullable error) {
                      if (error == nil) return;
                      NSLog(@"Error in appicon: %@", error);
                      showDialog(localize(@"Error", nil), error.localizedDescription);
                  }];
              },
              @"pickKeys": @[
                  @"AppIcon-Light",
                  @"CustomIcon"
              ],
              @"pickList": @[
                  localize(@"preference.title.appicon-default", nil),
                  localize(@"preference.title.appicon-custom", nil)
              ]
            },
            @{@"key": @"custom_appicon",
              @"hasDetail": @YES,
              @"icon": @"photo",
              @"type": self.typeButton,
              @"enableCondition": ^BOOL(){
                  return NO;
              },
              @"action": ^void(){
                  [self openImagePicker];
              }
            },
            @{@"key": @"launcher_background",
              @"hasDetail": @YES,
              @"icon": @"photo.fill.on.rectangle.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  BackgroundSettingsViewController *bgVC = [[BackgroundSettingsViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:bgVC];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"hidden_sidebar",
              @"hasDetail": @YES,
              @"icon": @"sidebar.leading",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"announcement_preview_level",
              @"hasDetail": @YES,
              @"icon": @"megaphone",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"full",
                  @"summary",
                  @"title_only"
              ],
              @"pickList": @[
                  localize(@"i18n_str_390", nil),
                  localize(@"i18n_str_391", nil),
                  localize(@"i18n_str_392", nil)
              ]
            },
            @{@"key": @"reset_warnings",
              @"icon": @"exclamationmark.triangle",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  resetWarnings();
              }
            },
            @{@"key": @"reset_settings",
              @"icon": @"trash",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"requestReload": @YES,
              @"showConfirmPrompt": @YES,
              @"destructive": @YES,
              @"action": ^void(){
                  loadPreferences(YES);
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"memory_limit_help",
              @"hasDetail": @YES,
              @"icon": @"memorychip",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self showMemoryLimitHelp];
              }
            },
            @{@"key": @"erase_demo_data",
              @"icon": @"trash",
              @"type": self.typeButton,
              @"enableCondition": ^BOOL(){
                  NSString *demoPath = [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")];
                  int count = [NSFileManager.defaultManager contentsOfDirectoryAtPath:demoPath error:nil].count;
                  return whenNotInGame() && count > 0;
              },
              @"showConfirmPrompt": @YES,
              @"destructive": @YES,
              @"action": ^void(){
                  NSString *demoPath = [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")];
                  NSError *error;
                  if([NSFileManager.defaultManager removeItemAtPath:demoPath error:&error]) {
                      [NSFileManager.defaultManager createDirectoryAtPath:demoPath
                                              withIntermediateDirectories:YES attributes:nil error:nil];
                      [NSFileManager.defaultManager changeCurrentDirectoryPath:demoPath];
                      if (getenv("DEMO_LOCK")) {
                          [(LauncherNavigationController *)self.navigationController fetchLocalVersionList];
                      }
                  } else {
                      NSLog(@"Error in erase_demo_data: %@", error);
                      showDialog(localize(@"Error", nil), error.localizedDescription);
                  }
              }
            },
            // Task217：数据导出（包名迁移配套——旧容器数据全量备份到 zip，
            // 落点由用户经系统文件选择器决定）。
            // ★ Task223（清单第 12 项）：改为二级入口页（抛弃压缩等级悬浮
            //   菜单；进度借用版本下载任务体系，可离开页面后台继续）。
            @{@"key": @"data_export",
              @"hasDetail": @YES,
              @"icon": @"square.and.arrow.up",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  DataExportViewController *vc = [[DataExportViewController alloc] init];
                  [self.navigationController pushViewController:vc animated:YES];
              }
            },
            // Task217：从备份导入（新包名容器直接恢复 zip 备份，重启生效）。
            @{@"key": @"data_import",
              @"hasDetail": @YES,
              @"icon": @"square.and.arrow.down",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [[DataTransferService sharedService] importDataFromViewController:self];
              }
            },
            // Task217：关于页入口（二级菜单）。启动器更新的两个选项
            //（check_update / auto_update_check）已随本项迁往关于页
            //（用户指令："将启动器更新功能的 2 个选项移动到关于页面"）。
            @{@"key": @"about",
              @"hasDetail": @YES,
              @"icon": @"info.circle",
              @"type": self.typeButton,
              @"action": ^void(){
                  AboutViewController *aboutVC = [[AboutViewController alloc] init];
                  [self.navigationController pushViewController:aboutVC animated:YES];
              }
            }
        ], @[
            // Download mirror policy settings（分类镜像策略，由 PLMirrorCenter 统一读取）
            // Task138：全部行新增加载速度快优先（speed_first，参考 FCL 测速策略，
            // PLMirrorCenter 官方 vs 镜像竞速、24 小时缓存）并设为默认。
            @{@"icon": @"arrow.down.circle"},
            // 模组镜像源（Task138 从启动器设置分区移入，用户指令）：统一粗控，
            // 选择同时写入 assetSearchSource + assetDownloadSource 两键（模组的
            // API 搜索与文件下载本就同属 MCIM 体系）；细粒度仍可用下方两行单独调整
            @{@"key": @"mod_mirror",
              @"hasDetail": @YES,
              @"icon": @"network",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first",
                  @"speed_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mod_mirror-official", nil),
                  localize(@"preference.title.mod_mirror-mcim", nil),
                  localize(@"preference.title.mirror_policy-speed_first", nil)
              ]
            },
            @{@"key": @"fileSource",
              @"hasDetail": @YES,
              @"icon": @"arrow.down.circle",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first",
                  @"speed_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil),
                  localize(@"preference.title.mirror_policy-speed_first", nil)
              ]
            },
            @{@"key": @"assetSearchSource",
              @"hasDetail": @YES,
              @"icon": @"magnifyingglass",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first",
                  @"speed_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil),
                  localize(@"preference.title.mirror_policy-speed_first", nil)
              ]
            },
            @{@"key": @"assetDownloadSource",
              @"hasDetail": @YES,
              @"icon": @"square.and.arrow.down",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first",
                  @"speed_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil),
                  localize(@"preference.title.mirror_policy-speed_first", nil)
              ]
            },
            @{@"key": @"modLoaderSource",
              @"hasDetail": @YES,
              @"icon": @"wrench.and.screwdriver",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official_first",
                  @"mirror_first",
                  @"speed_first"
              ],
              @"pickList": @[
                  localize(@"preference.title.mirror_policy-official_first", nil),
                  localize(@"preference.title.mirror_policy-mirror_first", nil),
                  localize(@"preference.title.mirror_policy-speed_first", nil)
              ]
            }
        ], @[
            // Video and renderer settings
            @{@"icon": @"video"},
            // Task159（[可撤销] 分辨率缩放实例化）：全局分辨率缩放行退役——
            // 与 Task150 渲染器同款迁移：每个实例在实例设置页"渲染器"行下
            // 单独设置（profile 键 resolution，25~100 数字输入框 + 右侧 %）。
            // 全局键 video.resolution 保留：PLProfiles prefDefaults 回退链
            // （profile 无键 → 全局存量值）+ 游戏内菜单/Java GUI 仍走全局。
            // 撤销 = 恢复本行字典（typeSlider 25-150）+ 实例页行。
            // Task 83（FSR 独立化）：FSR 档位从 MobileGlues 分区移到视频分区
            // ——它现在是多渲染器功能（MG 内置 FSR1 / zink EASU / Vulkan 渲染器
            // 的 GL 路径）。存储键经上方 get/set 重映射仍写
            // mobileglues.fsr1_setting（历史键名兼容）。
            @{@"key": @"fsr1_setting",
              @"hasDetail": @YES,
              @"icon": @"square.grid.3x2",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              // Task 78：补齐第 5 档 Performance(4)——旧 UI 只列 0-3，"性能优先"
              // 标签错贴在 Balanced(3) 上（枚举：0=Disabled/1=UQ/2=Q/3=Balanced/
              // 4=Performance，见 MobileGlues-cpp config/settings.h）。开启任一档
              // 即触发渲染分辨率联动（Task78/83：MC 窗口=表面/档位系数，
              // 渲染器侧升采样回全表面）。
              @"pickKeys": @[@"0", @"1", @"2", @"3", @"4"],
              @"pickList": @[
                  localize(@"preference.title.mg_fsr1_setting-0", nil),
                  localize(@"preference.title.mg_fsr1_setting-1", nil),
                  localize(@"preference.title.mg_fsr1_setting-2", nil),
                  localize(@"preference.title.mg_fsr1_setting-3", nil),
                  localize(@"preference.title.mg_fsr1_setting-4", nil)
              ]
            },
            // Task 130：FSR1 RCAS 锐化强度（mpv 口径 [0,1] 越大越锐，默认 0.2；
            // -1 = 关闭仅 EASU）。EASU 档位并排，悬浮 pick 直接切换。
            // pickKeys 是存储值（字符串）；默认值 0.2 来自 PLPreferences
            // 默认表（NSNumber 0.2）——stringValue 与 pickKey @"0.2" 相等，
            // ✓ 标记对齐（Task121 存储值比较口径）。
            @{@"key": @"fsr_rcas_sharpness",
              @"hasDetail": @YES,
              @"icon": @"wand.and.rays",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"-1", @"0.1", @"0.2", @"0.3", @"0.5", @"0.7", @"1"],
              @"pickList": @[
                  localize(@"preference.title.mg_fsr_rcas-0", nil),
                  localize(@"preference.title.mg_fsr_rcas-1", nil),
                  localize(@"preference.title.mg_fsr_rcas-2", nil),
                  localize(@"preference.title.mg_fsr_rcas-3", nil),
                  localize(@"preference.title.mg_fsr_rcas-4", nil),
                  localize(@"preference.title.mg_fsr_rcas-5", nil),
                  localize(@"preference.title.mg_fsr_rcas-6", nil)
              ]
            },
            // 帧率限制选项已移除：CADisplayLink 始终采用 30-120Hz 自适应范围，
            // 由屏幕硬件能力决定实际帧率（60Hz 设备仍为 60，120Hz ProMotion 设备可达 120）。
            // 不再提供"最大帧率限制 60FPS"开关，避免用户误关闭导致帧率被人为锁死。
            // 解锁帧率（关闭垂直同步）：三层联动关闭 VSync，让游戏帧率可超过屏幕刷新率。
            // 不限制 ProMotion 设备：60Hz 设备同样会被 VSync 锁在 60，也需要解锁。
            @{@"key": @"disable_game_vsync",
              @"hasDetail": @YES,
              @"icon": @"hare",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"performance_hud",
              @"hasDetail": @YES,
              @"icon": @"waveform.path.ecg",
              @"type": self.typeSwitch,
              @"enableCondition": ^BOOL(){
                  return [CAMetalLayer instancesRespondToSelector:@selector(developerHUDProperties)];
              }
            },
            @{@"key": @"fullscreen_airplay",
              @"hasDetail": @YES,
              @"icon": @"airplayvideo",
              @"type": self.typeSwitch,
              @"action": ^(BOOL enabled){
                  if (self.navigationController != nil) return;
                  if (UIApplication.sharedApplication.connectedScenes.count < 2) return;
                  if (enabled) {
                      [self.presentingViewController performSelector:@selector(switchToExternalDisplay)];
                  } else {
                      [self.presentingViewController performSelector:@selector(switchToInternalDisplay)];
                  }
              }
            },
            @{@"key": @"silence_other_audio",
              @"hasDetail": @YES,
              @"icon": @"speaker.slash",
              @"type": self.typeSwitch
            },
            @{@"key": @"silence_with_switch",
              @"hasDetail": @YES,
              @"icon": @"speaker.zzz",
              @"type": self.typeSwitch
            },
            @{@"key": @"allow_microphone",
              @"hasDetail": @YES,
              @"icon": @"mic",
              @"type": self.typeSwitch
            },
        ], @[
            // MobileGlues settings
            // 当渲染器选择为 MobileGlues 或 Vulkan 时，init_loadMobileGluesConfig()
            // 写入的 <POJAV_HOME>/MG/config.json 会被 MobileGlues 读取并生效。
            // Vulkan 渲染器的 OpenGL 回退使用 MobileGlues（对齐 Ynnyny 仓库）。
            // Auto 渲染器会被解析为 ANGLE，不会加载 MobileGlues。
            // Task 133：独立 "ANGLE ES 驱动" 开关已删除（用户指出与 GLES 后端
            // 重复冲突——且 MG 源码 iOS 分支的 ES 路径无视该配置、永远用内置
            // ANGLE 框架，属死配置）。ES/ANGLE 路径的唯一入口就是下面的
            // renderer_backend 选 "GLES 后端"，文案里已写明其经 ANGLE 翻译。
            @{@"icon": @"cpu"},
            // Task 132（MG 三端合并，用户明令的统一入口 + 原地悬浮浮窗）：
            // MobileGL 三后端（Vulkan 直连 / GLES 后端 / OpenGL 4.0 实验性）
            // 合并为本分区唯一的 pick 行——typePickField 点击原地弹出
            // UIAlertController actionSheet/popover 悬浮浮窗（openPicker
            // AtIndexPath，与 FSR 档位/下载源同款形态，绝不跳转二级页面）。
            // 读取经 getPreference 映射（有效渲染器为家族键原样返回，否则
            // 默认 Vulkan 直连）；写入经 setPreference 映射直写 video.renderer
            // （与渲染器行同一存储层，显式选择永远优先）。渲染器悬浮菜单里
            // 的三条独立后端条目已随本行退役（见 LauncherPreferences.m
            // rendererCandidates 的 Task132 注释）。
            @{@"key": @"renderer_backend",
              @"hasDetail": @YES,
              @"icon": @"cpu",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": getRendererFamilyKeys(),
              @"pickList": getRendererFamilyNames()
            },
            @{@"key": @"enable_no_error",
              @"hasDetail": @YES,
              @"icon": @"exclamationmark.triangle",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2"],
              @"pickList": @[
                  localize(@"preference.title.mg_enable_no_error-0", nil),
                  localize(@"preference.title.mg_enable_no_error-1", nil),
                  localize(@"preference.title.mg_enable_no_error-2", nil)
              ]
            },
            @{@"key": @"enable_ext_timer_query",
              @"hasDetail": @YES,
              @"icon": @"clock",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_ext_compute_shader",
              @"hasDetail": @YES,
              @"icon": @"cube.transparent",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_ext_direct_state_access",
              @"hasDetail": @YES,
              @"icon": @"directconnect",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"max_glsl_cache_size",
              @"hasDetail": @YES,
              @"icon": @"memorychip",
              @"type": self.typeSlider,
              @"min": @(0),
              @"max": @(256),
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"multidraw_mode",
              @"hasDetail": @YES,
              @"icon": @"square.stack.3d.down.dottedline",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2"],
              @"pickList": @[
                  localize(@"preference.title.mg_multidraw_mode-0", nil),
                  localize(@"preference.title.mg_multidraw_mode-1", nil),
                  localize(@"preference.title.mg_multidraw_mode-2", nil)
              ]
            },
            @{@"key": @"angle_depth_clear_fix_mode",
              @"hasDetail": @YES,
              @"icon": @"rectangle.3.group",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"custom_gl_version",
              @"hasDetail": @YES,
              @"icon": @"number",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"4.0", @"4.1", @"4.2", @"4.3", @"4.4", @"4.5", @"4.6"],
              @"pickList": @[
                  localize(@"preference.title.mg_custom_gl_version-0", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.0", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.1", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.2", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.3", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.4", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.5", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.6", nil)
              ]
            },
            // Task 83：fsr1_setting 行已移入上方"视频设置"分区（多渲染器通用
            // 化；存储键经重映射保持 mobileglues.fsr1_setting 不变）。
        ], @[
            // Control settings
            @{@"icon": @"gamecontroller"},
            
            // --- [Task 134] TouchController 模组支持（二级页面恢复） ---
            // Task 132 曾按当时的“严禁二级菜单”指令把本行改成 pick 浮窗；
            // 用户 Task 134 反馈该指令属于误判——恢复 43ef4ae 之前的原始
            // typeChildPane 形态（推入 TouchControllerPreferencesViewController，
            // 通信方式选择/震动/移动视角/关于等全部伴随行回到 pane 内，
            // 新增屏蔽控件开关也位于 pane 内）。存储键与读写路径不变。
            @{@"key": @"mod_touch_enable",
              @"icon": @"hand.point.up.left",
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"enableCondition": whenNotInGame,
              @"canDismissWithSwipe": @NO,
              @"class": NSClassFromString(@"TouchControllerPreferencesViewController")
            },
            // ------------------------------------------

            // --- [Task 134] 键位调整：二级页面入口恢复 ---
            // Task 133 曾按"严禁二级页面"指令改为 pick 浮窗；用户反馈该
            // 指令属于误判——恢复 typeChildPane 原始形态。推入动作经
            // openChildPaneAtIndexPath 的 custom_controls 特例（OverFullScreen
            // 全屏画布编辑器，Task62 同款含 setDefaultCtrl/getDefaultCtrl
            // 回调），与启动器主页/游戏内两个入口零差异。
            @{@"key": @"custom_controls",
              @"icon": @"gamecontroller.fill",
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"enableCondition": whenNotInGame,
              @"canDismissWithSwipe": @NO,
              @"class": CustomControlsViewController.class
            },

            // ---------------------------------------------

            // --- [Task 134] 手柄配置：二级页面入口恢复 ---
            // 同上误判恢复：typeChildPane 推入 LauncherPrefContCfgViewController
            // 按键映射编辑器（与 43ef4ae 之前完全一致）。
            @{@"key": @"default_gamepad_ctrl",
                @"icon": @"hammer",
                @"type": self.typeChildPane,
                @"enableCondition": whenNotInGame,
                @"canDismissWithSwipe": @NO,
                @"class": LauncherPrefContCfgViewController.class
            },
            @{@"key": @"custom_mouse_pointer",
                @"icon": @"cursorarrow",
                @"hasDetail": @YES,
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    [self openMousePointerPicker];
                }
            },
            @{@"key": @"hardware_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"reset_mouse_pointer",
                @"icon": @"arrow.counterclockwise",
                @"hasDetail": @YES,
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:localize(@"i18n_str_393", nil)];
                }
            },
            @{@"key": @"recording_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            
            // --- [重构] 双指呼出键盘控制 ---
            // 同样改为按钮+弹窗模式，彻底解决开关回弹问题
            @{@"key": @"two_finger_keyboard", 
              @"icon": @"keyboard", // 键盘图标
              @"hasDetail": @YES,
              @"type": self.typeButton, // 关键：改为 Button 类型
              
              @"action": ^void() {
                  // 1. 获取当前状态
                  BOOL isOn = getPrefBool(@"control.two_finger_keyboard");
                  
                  // 2. 构建弹窗
                  NSString *title = localize(@"preference.title.two_finger_keyboard", nil);
                  // 如果没有 localization，设置默认标题
                  if (!title || [title isEqualToString:@"preference.title.two_finger_keyboard"]) {
                      title = localize(@"i18n_str_394", nil);
                  }
                  
                  NSString *statusMsg = isOn ? localize(@"i18n_str_2053", nil) : localize(@"i18n_str_396", nil);
                  NSString *msg = [NSString stringWithFormat:localize(@"i18n_str_397", nil), statusMsg];
                  
                  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                  
                  // 3. 根据当前状态显示不同的按钮
                  if (!isOn) {
                      [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_398", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                          // 强制开启
                          setPrefBool(@"control.two_finger_keyboard", YES);
                          [weakSelf showSuccessMessage:localize(@"i18n_str_399", nil)];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  } else {
                      [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_400", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                          // 强制关闭
                          setPrefBool(@"control.two_finger_keyboard", NO);
                          [weakSelf showSuccessMessage:localize(@"i18n_str_401", nil)];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  }
                  
                  [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
                  
                  [weakSelf presentViewController:alert animated:YES completion:nil];
              }
            },
                        // Task229 (feedback #7, FCL-style auto-open input method switch,
            // SDL builds): when on, the FIRST StartTextInput of a game
            // session (the game-side text request: title-screen search box,
            // chat focus) auto-opens the launcher keyboard. Later
            // open/close cycles still run the full latch rules including
            // the #6 hard-suppression window after an explicit dismissal,
            // so this switch cannot resurrect the unclosable-keyboard bug.
            @{@"key": @"auto_keyboard_sdl",
              @"hasDetail": @YES,
              @"icon": @"keyboard.badge.ellipsis",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            // Task229 (feedback #2: sprint has no effect): vanilla's own
            // accessibility switch -- toggleSprint:true in options.txt makes
            // the sprint key latch (press once = keep running). The button
            // reads the current state from every instance options.txt and
            // writes the toggle to all of them (idempotent, instant).
            @{@"key": @"mc_toggle_sprint",
              @"hasDetail": @YES,
              @"icon": @"figure.run",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  // Current state = true if ANY instance has toggleSprint:true.
                  BOOL anyOn = NO;
                  for (NSString *p in [self ame229_allInstanceOptionsPaths]) {
                      for (NSString *ln in [self ame229_linesOfOptions:p] ?: @[]) {
                          if ([ln hasPrefix:@"toggleSprint:true"]) { anyOn = YES; break; }
                      }
                      if (anyOn) break;
                  }
                  UIAlertController *alert = [UIAlertController
                      alertControllerWithTitle:localize(@"ame229.sprint.title", nil)
                                       message:anyOn ? localize(@"ame229.sprint.on.desc", nil)
                                                     : localize(@"ame229.sprint.off.desc", nil)
                                preferredStyle:UIAlertControllerStyleAlert];
                  NSString *onTitle = localize(@"ame229.sprint.turn_on", nil);
                  NSString *offTitle = localize(@"ame229.sprint.turn_off", nil);
                  [alert addAction:[UIAlertAction actionWithTitle:anyOn ? offTitle : onTitle
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *a) {
                      BOOL enable = !anyOn;
                      NSInteger wrote = 0, total = 0;
                      for (NSString *p in [self ame229_allInstanceOptionsPaths]) {
                          total++;
                          if ([self ame229_writeToggleSprint:enable toOptions:p]) wrote++;
                      }
                      NSLog(@"[Settings] Task229 toggleSprint written %ld/%ld instance options.txt (enable=%d)",
                            (long)wrote, (long)total, (int)enable);
                      [self showSuccessMessage:[NSString stringWithFormat:
                          localize(@"ame229.sprint.result", nil), (long)wrote]];
                      [self.tableView reloadData];
                  }]];
                  [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                                             style:UIAlertActionStyleCancel handler:nil]];
                  [self presentViewController:alert animated:YES completion:nil];
              }
            },
            // Task229 (feedback #2: right shift relapsed): instance isolation
            // split options.txt per instance -- the 1.20.1 instance carries the
            // user's key_key.sneak:right.shift binding while the 26.3 instance
            // was born with vanilla defaults (left.shift), so the right-SHIFT
            // button stopped working there. One-way sync: the binding-richest
            // options.txt donates its key_key.* rows to every other instance
            // (only fills MISSING keys, never overwrites an explicit rebind).
            @{@"key": @"keybind_sync",
              @"hasDetail": @YES,
              @"icon": @"arrow.triangle.2.circlepath",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self ame229_syncKeybindsAcrossInstances];
              }
            },
// -----------------------------
            
            @{@"key": @"gesture_mouse",
                @"icon": @"cursorarrow.click",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"gesture_hotbar",
                @"icon": @"hand.tap",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"disable_haptics",
                @"icon": @"wave.3.left",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"slideable_hotbar",
                @"hasDetail": @YES,
                @"icon": @"slider.horizontal.below.rectangle",
                @"type": self.typeSwitch,
                // --- [修改] 添加禁用条件 ---
                @"enableCondition": ^BOOL(){
                    // 当 TouchController 启用时，禁用此选项（返回 NO 表示禁用/变灰）
                    return ![self.getPreference(@"control", @"mod_touch_enable") boolValue];
                }
            },
            @{@"key": @"press_duration",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.click.badge.clock",
                @"type": self.typeSlider,
                @"min": @(100),
                @"max": @(1000),
            },
            @{@"key": @"button_scale",
                @"hasDetail": @YES,
                @"icon": @"aspectratio",
                @"type": self.typeSlider,
                @"min": @(50), // 80?
                @"max": @(500)
            },
            @{@"key": @"mouse_scale",
                @"hasDetail": @YES,
                @"icon": @"arrow.up.left.and.arrow.down.right.circle",
                @"type": self.typeSlider,
                @"min": @(25),
                @"max": @(300)
            },
            @{@"key": @"mouse_speed",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.motionlines",
                @"type": self.typeSlider,
                @"min": @(25),
                @"max": @(300)
            },
            @{@"key": @"virtmouse_enable",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.rays",
                @"type": self.typeSwitch
            },
            @{@"key": @"gyroscope_enable",
                @"hasDetail": @YES,
                @"icon": @"gyroscope",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            },
            @{@"key": @"gyroscope_invert_x_axis",
                @"hasDetail": @YES,
                @"icon": @"arrow.left.and.right",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            },
            @{@"key": @"gyroscope_sensitivity",
                @"hasDetail": @YES,
                @"icon": @"move.3d",
                @"type": self.typeSlider,
                @"min": @(50),
                @"max": @(300),
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            }
        ], @[
        // Java tweaks
            @{@"icon": @"sparkles"},
            // --- [Task 134] 运行时管理：二级页面入口恢复 ---
            // 同上误判恢复：typeChildPane 推入 LauncherPrefManageJREViewController
            // （canDismissWithSwipe=YES 沿袭 43ef4ae 之前的原始形态）。
            @{@"key": @"manage_runtime",
                @"hasDetail": @YES,
                @"icon": @"cube",
                @"type": self.typeChildPane,
                @"canDismissWithSwipe": @YES,
                @"class": LauncherPrefManageJREViewController.class,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"java_args",
                @"hasDetail": @YES,
                @"icon": @"slider.vertical.3",
                @"type": self.typeTextField,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"env_variables",
                @"hasDetail": @YES,
                @"icon": @"terminal",
                @"type": self.typeTextField,
                @"enableCondition": whenNotInGame
            },
            // Task141：全局内存两行（java.auto_ram「自动调整内存分配」开关 +
            // java.allocated_memory「内存分配(MB)」滑条）按用户指令删除——
            // 启动内存现由当前实例的内存分配拉条决定
            //（实例管理 > 高级设置 > 内存分配；JavaLauncher/SurfaceVC 经
            // ame141_currentLaunchAllocMem 读取），全局行不再参与决策。
        ], @[
            // Debug settings - only recommended for developer use
            @{@"icon": @"ladybug"},
            // --- [Task 134] JIT 开启工具（LiveContainer 多工具方案） ---
            // 部分用户没有安装 StikDebug 而使用 SideStore/StosDebug/JITStreamer
            // 等其它工具——此前启动器固定跳 stikjit:// 导致"点了没反应、JIT
            // 永远开不了"。现提供工具选择：auto 沿用原自动判定（TrollStore
            // 检测 → apple-magnifier；iOS>=17.4 → stikjit；16.7-17.3.1 →
            // sidestore），其余选项强制走对应工具的 URL scheme
            // （waitJITEnabled 消费）。
            @{@"key": @"jit_enabler",
                @"hasDetail": @YES,
                @"icon": @"bolt.badge.clock",
                @"type": self.typePickField,
                @"enableCondition": whenNotInGame,
                @"pickKeys": @[
                    @"auto",
                    @"stikjit",
                    @"sidestore",
                    @"stosdebug",
                    @"jitstreamer",
                    @"trollstore",
                    @"manual"
                ],
                @"pickList": @[
                    localize(@"preference.debug.jit_enabler.auto", nil),
                    localize(@"preference.debug.jit_enabler.stikjit", nil),
                    localize(@"preference.debug.jit_enabler.sidestore", nil),
                    localize(@"preference.debug.jit_enabler.stosdebug", nil),
                    localize(@"preference.debug.jit_enabler.jitstreamer", nil),
                    localize(@"preference.debug.jit_enabler.trollstore", nil),
                    localize(@"preference.debug.jit_enabler.manual", nil)
                ]
            },
            // --- [Task 134] iOS 26 JS 脚本 JIT 开关 ---
            // 用户点名：提供关闭"iOS 26+ 启动游戏走 js 文件获取 JIT"的
            // 选项。关闭后 stikjit:// 请求不再附带 UniversalJIT26.js 的
            // script-data（纯调试器附加式 JIT）。注意：TXM 设备（系统级
            // 内存映射依赖脚本服务 brk）关闭后可能无法启动游戏，详情见
            // 行说明文案。
            @{@"key": @"jit26_script_disable",
                @"hasDetail": @YES,
                @"icon": @"scroll",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame,
                @"requestReload": @YES
            },
            @{@"key": @"debug_universal_script_jit",
                @"icon": @"scroll",
                @"type": self.typeSwitch,
                @"requestReload": @YES,
                @"enableCondition": ^BOOL(){
                    return DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) && whenNotInGame();
                },
            },
            @{@"key": @"debug_always_attached_jit",
                @"hasDetail": @YES,
                @"icon": @"app.connected.to.app.below.fill",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return getPrefBool(@"debug.debug_universal_script_jit") && whenNotInGame();
                },
            },
            @{@"key": @"debug_skip_wait_jit",
                @"hasDetail": @YES,
                @"icon": @"forward",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_hide_home_indicator",
                @"hasDetail": @YES,
                @"icon": @"iphone.and.arrow.forward",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return
                        self.splitViewController.view.safeAreaInsets.bottom > 0 ||
                        self.view.safeAreaInsets.bottom > 0;
                }
            },
            @{@"key": @"debug_ipad_ui",
                @"hasDetail": @YES,
                @"icon": @"ipad",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_auto_correction",
                @"hasDetail": @YES,
                @"icon": @"textformat.abc.dottedunderline",
                @"type": self.typeSwitch
            }
        ], @[
            // AI 助手 settings（Prisma AI Agent Phase 2）
            @{@"icon": @"sparkles"},
            @{@"key": @"provider_config",
              @"title": localize(@"ame193.misc.7", @"提供商配置"),
              @"icon": @"globe.asia.australia.fill",
              @"type": self.typeButton,
              @"action": ^void(){
                  AIProviderConfigViewController *vc = [[AIProviderConfigViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"session_list",
              @"title": localize(@"ame193.misc.8", @"会话列表"),
              @"icon": @"rectangle.stack.badge.person.crop",
              @"type": self.typeButton,
              @"action": ^void(){
                  AISessionListViewController *vc = [[AISessionListViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"safety_mode",
              @"title": localize(@"ame189.ai.safety_mode_title", nil),
              @"icon": @"hand.raised.fill",
              @"type": self.typePickField,
              // Task189：pickKeys 稳定 ID + pickList 本地化（Task132 存储值命中
              // pickKeys → 显示 pickList 的既有协议不变）
              @"pickKeys": @[
                  @"safe",
                  @"ask",
                  @"yolo"
              ],
              @"pickList": @[
                  localize(@"ame189.ai.safety_safe", nil),
                  localize(@"ame189.ai.safety_ask", nil),
                  localize(@"ame189.ai.safety_yolo", nil)
              ]
            },
            @{@"key": @"markdown_enabled",
              @"title": localize(@"ame193.misc.9", @"Markdown 渲染"),
              @"icon": @"textformat",
              @"type": self.typeSwitch
            },
            @{@"key": @"system_prompt",
              @"title": localize(@"ame193.ai.9", @"系统提示词"),
              @"icon": @"text.book.closed.fill",
              @"type": self.typeButton,
              @"action": ^void(){
                  AISystemPromptEditorViewController *vc = [[AISystemPromptEditorViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            }
        ]
    ];

    [super viewDidLoad];
    // Task 133：ame120 pick 标签包装器退役（悬浮弹窗打不开的根因修复）。
    //
    // 事故复盘（用户截图铁证：pick 行只剩 > 符号、选中项不再显示、
    // 点击完全无反应）：
    //   Task120 在 viewDidLoad 尾部用包装块【替换】self.typePickField，
    //   但 prefContents 数组在此前已按 init -> initViewCreation 设置的
    //   【基类块指针】构建完毕（数组字面量求值时捕获基类块 A，包装后
    //   属性变为 B）。PLPrefTableViewController 的渲染样式判定
    //   （item[@"type"] == self.typePickField）与 didSelectRowAtIndexPath
    //   的点击路由用的是同一套【指针比较】——A != B 全部失配：
    //     1. pick 行渲染回落 cellSubtitle 样式：选中值不再右侧显示，
    //        带详情说明的行——其说明文字挤到副标题位，行尾只剩 > DisclosureIndicator
    //        （观感 = "二级菜单入口"，实为死行）；
    //     2. 点击路由失配 -> 直接 return，悬浮弹窗完全打不开。
    //   这正是 Task129("FSR/下载源变成二级菜单入口无法切换")、Task131
    //   ("悬浮菜单无法使用")、Task132 三轮反馈的共同根因——之前误诊为
    //   iPad 紧凑菜单/呈现上下文/标签映射问题，修的都是别的层。
    //
    // 修复（用户指令：恢复首次二级菜单回归（Task120）之前的提交行为）：
    //   删除包装器，恢复指针一致性。其功能（存储值 -> pickList 本地化
    //   标签显示）已由 Task132 落地到基类 typePickField 块内部
    //   （PLPrefTableViewController.m 的 ame132 映射，含未命中回落），
    //   包装器自 Task132 起就是纯冗余。删除后所有 pick 行：
    //     - Value1 样式右侧显示当前选中项标签（比 Task120 之前的裸
    //       存储值显示更进一步）；
    //     - 点击原地弹出悬浮 actionSheet（iPhone）/popover（iPad 锚定行），
    //       ✓ 标记当前值——即 c71dcfa（Task120 之前）的原生弹窗行为。
    // 严禁再以任何形式在 items 构建之后替换 type* 块（同样的指针失配
    // 会立即复发）；如需扩展 pick 行渲染，一律改基类块内部。
    //
    // 适配自定义启动器背景：通过 BackgroundManager 将当前视图控制器透明化，
    // 让全局背景容器（图片/视频）能够透出显示。必须在 super viewDidLoad 之后调用，
    // 以确保 view 与 tableView 均已就绪。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 顶部 Hero 卡片：App 名 + 版本 + 设备信息（参照 Prisma-Design v1.2 L3 大卡片规范）
    // 与搜索栏一起包装为 tableHeaderView，搜索栏在上、Hero 卡片在下
    [self setupHeroHeader];

    // Apply transparent background if global background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        
        // Make separator visible on background
        self.tableView.separatorEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
    
    if (self.navigationController == nil) {
        self.tableView.alpha = 0.9;
    }
    if (NSProcessInfo.processInfo.isMacCatalystApp) {
        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeClose];
        closeButton.frame = CGRectOffset(closeButton.frame, 10, 10);
        [closeButton addTarget:self action:@selector(actionClose) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:closeButton];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(openCurseForgeAPIKeySettings)
                                                 name:@"OpenCurseForgeAPIKeySettings"
                                               object:nil];

    // Task224（#4）：界面风格切换时设置页自身随活重铺（可见状态下）；
    // 不可见时由 viewWillAppear/didAppear 的既有重铺路径覆盖。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_handleInterfaceStyleChanged:)
                                                 name:LGCInterfaceStyleChangedNotification
                                               object:nil];
}

// Task224（#4）：风格切换广播 → 设置页自身重铺（导航栏/模态底层/cell
// 表面全部随新风格重建）。
- (void)ame224_handleInterfaceStyleChanged:(NSNotification *)notification {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [self.tableView reloadData];
    NSLog(@"[ThemeOps] Task224 settings page re-applied after style change (resolved=%d)",
          (int)LGCResolvedInterfaceStyle());
}

// Task224（#19）：打开「界面缩放」实时滑条编辑器。
// Task225：ame224_openZoomEditor 已随独立缩放编辑页退役（滑条内联）。

#pragma mark - Hero Header（顶部 App 信息卡片）

- (NSString *)appName {
    // 优先使用 CFBundleDisplayName（用户可见名称），其次 CFBundleName，兜底 "Prisma"
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *name = info[@"CFBundleDisplayName"];
    if (name.length == 0) {
        name = info[@"CFBundleName"];
    }
    return name.length ? name : @"Prisma";
}

- (void)setupHeroHeader {
    // 父类 viewDidLoad 已将 searchController.searchBar 设置为 tableHeaderView
    // 这里取出 searchBar，与 Hero 卡片一起重新包装为新的 tableHeaderView
    // 注意：searchController 是父类 PLPrefTableViewController 的私有属性，子类无法直接访问，
    // 但父类已将 searchBar 设置为 tableView.tableHeaderView，可直接取出。
    UISearchBar *searchBar = nil;
    UIView *currentHeader = self.tableView.tableHeaderView;
    if ([currentHeader isKindOfClass:[UISearchBar class]]) {
        searchBar = (UISearchBar *)currentHeader;
    }
    [searchBar removeFromSuperview];

    // 让 searchBar 适配自定义背景（透明、文字色跟随系统）
    searchBar.barTintColor = [UIColor clearColor];
    searchBar.tintColor = accentColor();
    searchBar.backgroundImage = [UIImage new]; // 去掉默认背景
    if (@available(iOS 13.0, *)) {
        searchBar.searchTextField.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    }

    // ===== Hero 卡片（L3 大卡片：16pt 圆角 + 半透明背景 + 毛玻璃 + 浅边框 + 中阴影）=====
    UIView *heroCard = [[UIView alloc] init];
    // Task160：半透明白底/白边框/黑色下阴影退役——无壁纸时由
    // applyEffectToView 上新拟态规格表面色（cell 场景同款 flat），有壁纸时
    // 走毛玻璃管线；黑色单侧阴影与新拟态双阴影体系冲突，一并移除
    heroCard.layer.cornerRadius = 16;
    heroCard.layer.cornerCurve = kCACornerCurveContinuous;
    [[BackgroundManager sharedManager] applyEffectToView:heroCard];

    // Hero 图标（56x56，14pt 圆角，accentColor 纯色背景，白色 SF Symbol）
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.image = [UIImage systemImageNamed:@"cube.fill"];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;
    iconView.backgroundColor = accentColor();
    iconView.layer.cornerRadius = 14;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [heroCard addSubview:iconView];

    // 标题（App 名，17pt bold，labelColor）
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [self appName];
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    titleLabel.textColor = AmeCardPrimaryTextColor(); // Task160 规格主文字
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    [heroCard addSubview:titleLabel];

    // 副标题（第一行 App 版本，第二行 设备名 · iOS 系统版本）
    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *appVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
    NSString *deviceName = [HostManager GetModelName] ?: UIDevice.currentDevice.name ?: @"iPhone";
    NSString *systemVersion = UIDevice.currentDevice.systemVersion ?: @"";
    NSString *subtitle = [NSString stringWithFormat:@"v%@\n%@ · iOS %@", appVersion, deviceName, systemVersion];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitleLabel.textColor = AmeCardSecondaryTextColor(); // Task160 规格次要文字
    subtitleLabel.numberOfLines = 0;
    [heroCard addSubview:subtitleLabel];

    // 右侧 chevron（12x12，tertiary-labelColor）
    UIImageView *chevronView = [[UIImageView alloc] init];
    chevronView.image = [UIImage systemImageNamed:@"chevron.right"];
    chevronView.tintColor = [UIColor tertiaryLabelColor];
    chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [heroCard addSubview:chevronView];

    self.heroCard = heroCard;

    // Task218：Hero 卡片 = 关于页二级入口（用户指令：设置界面最上面的
    // 启动器卡片差不多是关于页的缩小版，让它成为关于页入口）。右侧
    // chevron 原本就是纯装饰，现在有了真实语义；按下动效见
    // ame218_heroCardTapped:（缩放 + 弹簧回弹）。
    heroCard.userInteractionEnabled = YES;
    UITapGestureRecognizer *ame218_heroTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(ame218_heroCardTapped:)];
    [heroCard addGestureRecognizer:ame218_heroTap];

    // ===== 容器视图：searchBar（上）+ heroCard（下）=====
    UIView *container = [[UIView alloc] init];
    [container addSubview:searchBar];
    [container addSubview:heroCard];

    // 启用 AutoLayout
    searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    chevronView.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        // searchBar：贴顶部、左右贴边
        [searchBar.topAnchor constraintEqualToAnchor:container.topAnchor],
        [searchBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [searchBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        // heroCard：左右 16pt 外边距，顶部距 searchBar 8pt，底部距容器 8pt
        [heroCard.topAnchor constraintEqualToAnchor:searchBar.bottomAnchor constant:8],
        [heroCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [heroCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [heroCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        // iconView：56x56，左侧 16pt、上下 16pt
        [iconView.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [iconView.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        // titleLabel：位于 iconView 右侧 14pt，顶部 18pt
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:18],
        [titleLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8],

        // subtitleLabel：紧跟 titleLabel 下方 2pt
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],

        // chevronView：12x12，右侧 16pt，垂直居中
        [chevronView.trailingAnchor constraintEqualToAnchor:heroCard.trailingAnchor constant:-16],
        [chevronView.centerYAnchor constraintEqualToAnchor:heroCard.centerYAnchor],
        [chevronView.widthAnchor constraintEqualToConstant:12],
        [chevronView.heightAnchor constraintEqualToConstant:12],
    ]];

    // UITableView 不会根据 AutoLayout 自动计算 tableHeaderView 高度，
    // 需要手动布局并设置 frame。使用 systemLayoutSizeFitting 计算合适高度。
    CGFloat width = self.tableView.bounds.size.width;
    if (width == 0) width = [UIScreen mainScreen].bounds.size.width;
    container.frame = CGRectMake(0, 0, width, 0);
    [container setNeedsLayout];
    [container layoutIfNeeded];
    CGFloat fittingHeight = [container systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    container.frame = CGRectMake(0, 0, width, fittingHeight);

    self.tableView.tableHeaderView = container;
}

/// Task218：Hero 卡片点击 -> 关于页（二级入口，与"关于"行同目的地）。
/// 按下动效：快速轻缩（0.97）+ 弹簧回弹，随后 push——整卡可点的体感
/// 与 cell 高亮不同，需要自己的按压反馈。
- (void)ame218_heroCardTapped:(UITapGestureRecognizer *)gesture {
    UIView *ame218_card = gesture.view;
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        ame218_card.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35 delay:0
                        usingSpringWithDamping:0.55 initialSpringVelocity:0.4
                        options:0 animations:^{
            ame218_card.transform = CGAffineTransformIdentity;
        } completion:nil];
        AboutViewController *ame218_about = [[AboutViewController alloc] init];
        [self.navigationController pushViewController:ame218_about animated:YES];
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"OpenCurseForgeAPIKeySettings" object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    // Task156：右侧边栏信息卡深链——滚动到目标行并高亮（一次性）。
    // prefContents 在 super 的加载流程完成后可用；搜索态下目标行必然
    // 在表内（深链键都是普通行），不做搜索态特判。
    // Task161（闪退根修）：本页分区默认折叠（PLPrefTable 的
    // prefSectionsVisible 默认 NO，numberOfRowsInSection 对折叠分区只返回
    // 1——表头行）。旧代码按 prefContents 的全量索引直接
    // scrollToRowAtIndexPath/selectRowAtIndexPath，折叠分区内 r>0 的索引
    // 越界 → UITableView 抛 NSInternalInconsistencyException → 闪退。
    // 装机实锤：启动器版本卡（Task217 起改路由 about）/ JIT 卡（jit_enabler）/
    // 内存两卡（memory_limit_help）全部命中；游戏版本卡（versionManager
    // 分支）与设备/系统卡（无深链键不滚动）不炸——与用户报告完全吻合。
    // 修复：命中目标行后先展开所在分区（与搜索结果点击的既有语义一致，
    // PLPrefTable didSelectRowAtIndexPath 的 filteredItems 分支同款），
    // 再滚动 + 高亮；并加行数防御（目标行不在当前可见行数内则只展开不选中）。
    if (self.ameDeepLinkKey.length > 0) {
        NSString *target = self.ameDeepLinkKey;
        self.ameDeepLinkKey = nil;  // 只消费一次，返回本页不再跳
        [self.tableView layoutIfNeeded];
        for (NSInteger s = 0; s < (NSInteger)self.prefContents.count; s++) {
            NSArray<NSDictionary *> *rows = self.prefContents[s];
            for (NSInteger r = 0; r < (NSInteger)rows.count; r++) {
                NSString *k = rows[r][@"key"];
                if (k != nil && [k isEqualToString:target]) {
                    NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
                    // Task161：目标分区若处于折叠态（visibility NO → 表内只
                    // 有 1 行表头），先展开再定位——否则下方两个 Row 调用
                    // 直接以越界索引崩掉。
                    if (s < (NSInteger)self.prefSectionsVisibility.count &&
                        !self.prefSectionsVisibility[s].boolValue) {
                        self.prefSectionsVisibility[s] = @YES;
                        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:s]
                                      withRowAnimation:UITableViewRowAnimationNone];
                        [self.tableView layoutIfNeeded];
                    }
                    // 行数防御：目标行必须落在当前表的实际行数内才滚动/选中。
                    NSInteger ame161_visibleRows =
                        [self.tableView numberOfRowsInSection:s];
                    if (r >= ame161_visibleRows) {
                        NSLog(@"[LauncherPrefs] Task161: deep-link row %ld beyond visible rows (%ld) in section %ld -- expanded only, no selection",
                              (long)r, (long)ame161_visibleRows, (long)s);
                        return;
                    }
                    [self.tableView scrollToRowAtIndexPath:ip
                                             atScrollPosition:UITableViewScrollPositionMiddle
                                                     animated:YES];
                    [self.tableView selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
                    // 短暂高亮后取消选中（系统 deselect 动画）
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [self.tableView deselectRowAtIndexPath:ip animated:YES];
                    });
                    NSLog(@"[LauncherPrefs] Task156: deep-linked to row '%@' (section %ld row %ld)", target, (long)s, (long)r);
                    return;
                }
            }
        }
        NSLog(@"[LauncherPrefs] Task156: deep-link target '%@' not found in prefContents (plain open)", target);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // 重新隐藏导航栏黑条（pop 回根页面时 topViewController == self）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
    }

    // Re-apply transparency when appearing (in case background was just set)
    // Task161：改走 makeViewControllerTransparent 单点（table 分支的
    // backgroundView = nil 之后 ame160 会重铺模态毛玻璃底；旧代码直接
    // nil 会把 glass 清掉）。
    if ([[BackgroundManager sharedManager] hasBackground]) {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        
        // Refresh cells to apply background styling
        [self.tableView reloadData];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // push 子页面时显示导航栏（子页面需要返回按钮）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
    if (self.navigationController == nil) {
        [self.presentingViewController performSelector:@selector(updatePreferenceChanges)];
    }
}

- (void)actionClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并将 tableView 背景置为透明、移除默认 backgroundView，确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Task161：不再手动 backgroundView = nil——模态毛玻璃底现在挂
    // tableView.backgroundView（table 控制器形态），清掉会整页回透壁纸。
    self.tableView.backgroundColor = [UIColor clearColor];
}

#pragma mark - Check For Update

// Task217：checkForUpdateFromSettings / showUpdateAlertWithTitle /
// showUpdateAvailableAlert 三方法随两个更新选项（check_update、
// auto_update_check）迁往 AboutViewController（关于页启动器更新区）。
// 本页不再持有更新入口；UpdateChecker import 保留给其他潜在调用方。

#pragma mark - Memory Limit Help

- (void)showMemoryLimitHelp {
    // Task212（用户定稿九号指令）：说明文案改版——两种权限各自的效果与预期
    // 分配量，并推荐付费开发者证书；按钮从 GetMoreRam（GitHub 仓库）改为
    // "付费开发者证书"（B 站视频教程 b23.tv/WtgrPJM）。
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"mem_help.title", @"关于内存限制")
                         message:localize(@"mem_help.message",
                             @"·扩展内存限制权限，使用GetMoreRAM开启\n"
                              "让iOS为启动器分配更多内存空间，通常能分配6GB内存\n\n"
                              "·扩展虚拟内存权限，开启方式见下\n"
                              "让iOS为启动器分配更多内存寻址，通常能分配7GB内存并提升稳定性\n\n"
                              "推荐使用付费开发者证书，安装软件自动开启上述权限且支持开启JIT")
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"mem_help.button", @"付费开发者证书")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:@"https://b23.tv/WtgrPJM"];
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - CurseForge API Key Settings

- (void)openCurseForgeAPIKeySettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 通过 UIScene 获取顶层 VC（不使用 keyWindow）
        UIViewController *topVC = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                topVC = windowScene.windows.firstObject.rootViewController;
                if (topVC) {
                    break;
                }
            }
        }
        if (!topVC) {
            // 退而求其次：取任意一个 UIWindowScene
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    topVC = windowScene.windows.firstObject.rootViewController;
                    if (topVC) {
                        break;
                    }
                }
            }
        }
        if (!topVC) {
            return;
        }

        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }

        CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [topVC presentViewController:nav animated:YES completion:nil];
    });
}

#pragma mark - UITableView Data Source Override

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

    // Task136：图标改用本体着色（去掉彩色圆角背景+白标的 iOS 设置风格）——
    // 原 section 配色改作图标本身的 tint，section header 行保持 accentColor
    [self applySettingsAppStyleToCell:cell indexPath:indexPath];

    // Apply background styling if global background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        // Set semi-transparent dark background for cells
        [[BackgroundManager sharedManager] applyEffectToCell:cell];

        // Task160：去掉文字黑色阴影（用户实测重影：每行文字带 shadowOffset
        // (0,1) 的黑影，看起来像"文字重叠两次"）——回归原生纯色：浅色模式
        // 黑色标题 + 灰色小字（label / secondaryLabel 语义色，深浅色自适应）
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.shadowColor = nil;
        cell.textLabel.shadowOffset = CGSizeZero;

        // Detail text：原生次要文字色（替代写死 0.8 灰 + 阴影）
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.shadowColor = nil;
        cell.detailTextLabel.shadowOffset = CGSizeZero;

        // Tint color for icons and accessories：使用主题强调色（accentColor）
        cell.tintColor = accentColor();

        // Handle specific cell types
        NSArray *subviews = cell.contentView.subviews;
        for (UIView *subview in subviews) {
            // Style sliders
            if ([subview isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)subview;
                slider.tintColor = accentColor();
                slider.thumbTintColor = [UIColor whiteColor];
            }

            // Style switches
            if ([subview isKindOfClass:[UISwitch class]]) {
                UISwitch *switchControl = (UISwitch *)subview;
                switchControl.onTintColor = accentColor();
            }

            // Style text fields
            if ([subview isKindOfClass:[UITextField class]]) {
                UITextField *textField = (UITextField *)subview;
                textField.textColor = [UIColor labelColor]; // Task91：文字与输入框底色同步主题化
                textField.backgroundColor = [UIColor tertiarySystemFillColor];
                textField.layer.cornerRadius = 8;
            }

            // Style labels
            if ([subview isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)subview;
                label.textColor = [UIColor labelColor]; // Task91
                // Task160：同步去阴影（重影修复）
                label.shadowColor = nil;
                label.shadowOffset = CGSizeZero;
            }
        }

        // Style the picker label if exists
        if (cell.accessoryView && [cell.accessoryView isKindOfClass:[UILabel class]]) {
            UILabel *pickerLabel = (UILabel *)cell.accessoryView;
            pickerLabel.textColor = [UIColor secondaryLabelColor]; // Task160：原生次要色（替代写死 0.8 灰）
        }
    } else {
        // Reset to default when no background
        cell.backgroundColor = [UIColor secondarySystemBackgroundColor];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.shadowColor = nil;
        cell.textLabel.shadowOffset = CGSizeZero;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.shadowColor = nil;
        cell.detailTextLabel.shadowOffset = CGSizeZero;
    }

    return cell;
}

/// Task136：设置项左侧 SF 图标改为"图标本体"——去掉彩色圆角背景与白色
/// 图标渲染，改为图标直接以原 section 配色着色（原底色 → 现在的 tint 色）。
/// 仅做视觉装饰，不改变 cell 数据或交互逻辑。
- (void)applySettingsAppStyleToCell:(UITableViewCell *)cell indexPath:(NSIndexPath *)indexPath {
    UIImageView *iconView = cell.imageView;
    if (!iconView) return;

    // 判断是否为 section header 行（row 0 且有 prefSections）
    // section header 行保持主题强调色，与组内项区分
    BOOL isSectionHeader = (indexPath.row == 0 && self.prefSections && !self.filteredItems);
    if (isSectionHeader) {
        // section header：恢复默认 tint（不加背景），让图标保持系统默认外观
        iconView.backgroundColor = [UIColor clearColor];
        iconView.layer.cornerRadius = 0;
        iconView.layer.masksToBounds = NO;
        // section header 图标用主题强调色（accentColor），与启动按钮/菜单选中态统一
        iconView.tintColor = accentColor();
        return;
    }

    // 获取当前项的数据
    NSDictionary *item = nil;
    if (self.filteredItems) {
        // 搜索结果模式
        item = self.filteredItems[indexPath.row];
    } else if (self.prefSections && indexPath.section < (NSInteger)self.prefContents.count) {
        NSArray *sectionItems = self.prefContents[indexPath.section];
        if (indexPath.row < (NSInteger)sectionItems.count) {
            item = sectionItems[indexPath.row];
        }
    }

    // 判断是否为危险操作项
    BOOL destructive = [item[@"destructive"] boolValue];

    // 图标着色 = 原 section 背景色（Task136：颜底白标 → 图标本体色）
    UIColor *iconColor = [self iconBackgroundColorForItem:item indexPath:indexPath destructive:destructive];

    // 获取图标名，用 UIImageSymbolConfiguration 重新渲染为合适大小
    NSString *iconName = item[@"icon"];
    UIImage *styledIcon = nil;
    if (iconName.length > 0) {
        // 用 UIImageSymbolConfiguration 控制图标大小
        // pointSize 20 适配默认 UITableViewCell imageView 的 29pt 尺寸
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20
                                                                                            weight:UIFontWeightMedium];
        styledIcon = [UIImage systemImageNamed:iconName withConfiguration:config];
        if (!styledIcon) {
            styledIcon = [UIImage systemImageNamed:iconName];
        }
    }

    if (styledIcon) {
        // 模板渲染 + tintColor：图标本体直接以 section 色显示（无背景块）
        iconView.image = styledIcon;
    }
    iconView.tintColor = iconColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;

    // 无背景块：清除原彩色圆角背景
    iconView.backgroundColor = [UIColor clearColor];
    iconView.layer.cornerRadius = 0;
    iconView.layer.masksToBounds = NO;
}

/// 根据设置项所属 section 与图标名返回图标着色（Task136 前为图标背景色，
/// 现作图标本体色）：destructive（危险操作）统一红色
- (UIColor *)iconBackgroundColorForItem:(NSDictionary *)item
                              indexPath:(NSIndexPath *)indexPath
                             destructive:(BOOL)destructive {
    // 危险操作项统一红色
    if (destructive) {
        return [UIColor systemRedColor];
    }

    // 搜索结果模式：按原所属 section 着色
    if (self.filteredItems) {
        NSNumber *origSection = item[@"__origSection"];
        if (origSection) {
            return [self colorForPreferenceSection:origSection.intValue];
        }
        return [UIColor systemBlueColor];
    }

    // 正常模式：按 section 着色
    return [self colorForPreferenceSection:indexPath.section];
}

/// section 索引 → 配色映射（参照 iOS 设置应用的模块色系）
/// general=蓝（通用设置）/ video=紫（显示）/ control=绿（控制）/ java=橙（运行时）/ debug=红（调试）
- (UIColor *)colorForPreferenceSection:(NSInteger)section {
    if (!self.prefSections || section >= (NSInteger)self.prefSections.count) {
        return [UIColor systemGrayColor];
    }
    NSString *sectionKey = self.prefSections[section];
    if ([sectionKey isEqualToString:@"general"]) {
        return [UIColor systemBlueColor];
    } else if ([sectionKey isEqualToString:@"video"]) {
        return [UIColor systemPurpleColor];
    } else if ([sectionKey isEqualToString:@"mobileglues"]) {
        return [UIColor systemIndigoColor];
    } else if ([sectionKey isEqualToString:@"control"]) {
        return [UIColor systemGreenColor];
    } else if ([sectionKey isEqualToString:@"java"]) {
        return [UIColor systemOrangeColor];
    } else if ([sectionKey isEqualToString:@"debug"]) {
        return [UIColor systemRedColor];
    }
    return [UIColor systemGrayColor];
}

#pragma mark - UITableView Delegate

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) { // Add to general section
        NSString *versionString = [NSString stringWithFormat:@"Amethyst iOS Remastered %@\n%@ on %@ (%s)\nPID: %d",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            UIDevice.currentDevice.completeOSVersion, [HostManager GetModelName], getenv("POJAV_DETECTEDINST"), getpid()];
        
        // Style footer for background if needed
        if ([[BackgroundManager sharedManager] hasBackground]) {
            // Footer text is handled by the table view, but we can ensure visibility
            // by making sure the section has appropriate styling
        }
        
        return versionString;
    }

    NSString *footer = NSLocalizedStringWithDefaultValue(([NSString stringWithFormat:@"preference.section.footer.%@", self.prefSections[section]]), @"Localizable", NSBundle.mainBundle, @" ", nil);
    if ([footer isEqualToString:@" "]) {
        return nil;
    }
    return footer;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    // Style section headers for background visibility
    if ([[BackgroundManager sharedManager] hasBackground]) {
        if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
            UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
            header.textLabel.textColor = [UIColor labelColor];
            // Task160：去文字阴影（重影修复）
            header.textLabel.shadowColor = nil;
            header.textLabel.shadowOffset = CGSizeZero;
            header.backgroundView = [[UIView alloc] init];
            header.backgroundView.backgroundColor = [UIColor clearColor];
        }
    }
}

/// 重写子页面跳转：为 CustomControlsViewController 设置必需的回调块
- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    // 特殊处理：键位调整界面需要 setDefaultCtrl / getDefaultCtrl 回调
    // Task 62 修复：此处曾经把编辑器包进 UINavigationController 再按默认样式呈现，
    // 引发两个 bug——
    //   1) 默认样式 = pageSheet，iPadOS 26 上是居中悬浮矩形，编辑器画布缩成
    //      “屏幕中间的正方形”而非铺满全屏；
    //   2) UIKit 会把容器子 VC 的 present 请求转发给容器本身，于是按钮编辑页
    //      (CCMenuViewController) 的 presentingViewController 是这个导航控制器
    //      而不是编辑器。actionEditFinish 完成时盲转型后向它发
    //      doUpdateButton:from:to: → “unrecognized selector” 闪退。
    // 键位调整是全屏画布编辑器，必须与另外两个入口（启动器主页 enterCustomControls、
    // 游戏内 actionOpenCustomControls）一致：OverFullScreen 直接呈现、不包导航控制器。
    if ([item[@"key"] isEqualToString:@"custom_controls"]) {
        CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.setDefaultCtrl = ^(NSString *name){
            setPrefObject(@"control.default_ctrl", name);
        };
        vc.getDefaultCtrl = ^{
            return getPrefObject(@"control.default_ctrl");
        };
        [self presentViewController:vc animated:YES completion:nil];
        return;
    }

    // 其他设置项走父类默认逻辑
    [super tableView:tableView openChildPaneAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    // Style section footers for background visibility
    if ([[BackgroundManager sharedManager] hasBackground]) {
        if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
            UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
            footer.textLabel.textColor = [UIColor secondaryLabelColor]; // Task160：原生次要色
            footer.textLabel.shadowColor = nil;
            footer.textLabel.shadowOffset = CGSizeZero;
            footer.backgroundView = [[UIView alloc] init];
            footer.backgroundView.backgroundColor = [UIColor clearColor];
        }
    }
}

@end
