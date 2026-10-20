#import "ControlRepoViewController.h"
#import "AmeNativeMenu.h"       // ★ Task240：菜单全面系统原生 UIMenu 化
#import "NMToast.h"
#import "utils.h"
#import "LauncherPreferences.h"
#include <stdlib.h>  // getenv（POJAV_HOME；显式包含，不依赖伞头传递）

// ============================================================================
// Task189：下载源镜像链（国内可达性专项）。
// 病历：Task188 上线 raw.githubusercontent 主源 + jsDelivr 回退——真机日志
// 实测主源在国內裸连基本不可达，cdn.jsdelivr.net 也间歇性被重置；用户实测
// “下载版本错误/无法使用”。本轮改为六源镜像链 + 粘性记忆：
//   1. ghfast.top（GitHub 反代，国内直连快）
//   2. gh-proxy.com（GitHub 反代）
//   3. fastly.jsdelivr.net（jsDelivr Fastly 边缘）
//   4. gcore.jsdelivr.net（jsDelivr GCore 边缘）
//   5. cdn.jsdelivr.net（jsDelivr 主域）
//   6. raw.githubusercontent.com（官方直连，海外/代理环境）
// 策略：从上次成功源（偏好 controlrepo.mirror_idx）开始依序尝试，任一成功
// 即记住该源（粘性，下次直接从它开始）；全部失败才报错。单源超时 10s。
// 索引结构见仓库 controls/index.json：
//   { "version": 1, "layouts": [ { id/name/author/description/file/version/size } ] }
// 布局文件为编辑器 layoutDictionary 同构 JSON（mControlDataList 等键，
// dynamicX/dynamicY 相对定位表达式 => 分辨率无关、跨设备可分享）。
// ============================================================================
static NSString *const kTask189RepoOwner = @"Gsjsjzhznsz";
static NSString *const kTask189RepoName = @"Prisma-Minecraft-iOS-Launcher";
static NSString *const kTask189RepoRef = @"main";
static NSString *const kTask189RepoDir = @"controls";

/// 镜像链长度与顺序（Task189）。0-1=GitHub 反代（前缀拼接），
/// 2-4=jsDelivr（Fastly/GCore/主域），5=官方直连（兜底）。
static NSInteger const kTask189MirrorCount = 6;

static NSString *task189_mirrorURL(NSInteger idx, NSString *relPath) {
    static NSString *const kProxies[2] = { @"https://ghfast.top/", @"https://gh-proxy.com/" };
    static NSString *const kJsDelivr[3] = { @"fastly", @"gcore", @"cdn" };
    NSString *raw = [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/%@/%@/%@",
                       kTask189RepoOwner, kTask189RepoName, kTask189RepoRef, kTask189RepoDir, relPath];
    if (idx >= 0 && idx < 2) {
        return [NSString stringWithFormat:@"%@%@", kProxies[idx], raw];
    }
    if (idx >= 2 && idx < 5) {
        return [NSString stringWithFormat:@"https://%@.jsdelivr.net/gh/%@/%@@%@/%@/%@",
                kJsDelivr[idx - 2], kTask189RepoOwner, kTask189RepoName, kTask189RepoRef, kTask189RepoDir, relPath];
    }
    return raw;  // idx 5：官方直连（兜底）
}

@interface ControlRepoViewController ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *layouts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *localVersions;  // id -> 本地已装版本（触屏布局）
// ★ Task311（手柄控件）：本地已装手柄映射角标（controlmap/gamepads/ 扫描，
//   id -> 版本；与触屏 localVersions 分表——两目录同名文件互不串号）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *localGamepadVersions;
@property (nonatomic, strong) NSHashTable *downloading;  // 正在下载的 id 集合（去重点击）
@property (nonatomic, assign) BOOL loadFailed;
// ★ Task310（控件三分类页）→ Task311（四分类）：0=官方精选 1=社区 2=手柄 3=本地。
//   仓库 index.json 的 layouts[] 条目 category 字段（official/community/gamepad，
//   缺省按 official 兼容旧索引）；手柄页 = category:gamepad 仓库条目，下载落盘
//   controlmap/gamepads/<id>.json（手柄配置弹窗“当前”文件选择器同目录可直接选用）；
//   本地页扫 controlmap/ 全部 .json（触屏布局，语义不变）。
@property (nonatomic, strong) UISegmentedControl *categorySegment;
@property (nonatomic, assign) NSInteger selectedCategory;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredLayouts;      // 官方/社区/手柄过滤结果
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *localLayouts; // 本地布局 {name, version, size}
@end

// ============================================================================
// ★ Task230（反馈 #13：控件仓库——允许任何人上传控件 + 下载时静默检查
//   恶意代码）：布局是纯数据 JSON（无代码执行面），"恶意"向量是结构性
//   的——超大文件（解析 DoS）、海量按钮（渲染/内存压垮）、超长字符串
//   （UI 溢出/注入显示层）、键码离谱值（触发越界查表）、内嵌 URL（钓鱼
//   跳转）。ame230_layoutSafetyCheck 全量覆盖，下载/导入静默执行，未过
//   检即拒装并留痕。
// ============================================================================
static BOOL ame230_stringSafe(NSString *s) {
    if (s.length > 256) return NO;
    NSRange ame230_r = [s rangeOfString:@"http://" options:NSCaseInsensitiveSearch];
    if (ame230_r.location != NSNotFound) return NO;
    ame230_r = [s rangeOfString:@"https://" options:NSCaseInsensitiveSearch];
    if (ame230_r.location != NSNotFound) return NO;
    return YES;
}

static BOOL ame230_nodeSafe(id node, int depth, NSUInteger *btnCount, NSString **reason) {
    if (depth > 8) { *reason = @"nesting too deep"; return NO; }
    if ([node isKindOfClass:[NSString class]]) {
        if (!ame230_stringSafe(node)) { *reason = @"unsafe string"; return NO; }
        return YES;
    }
    if ([node isKindOfClass:[NSNumber class]]) return YES;
    if ([node isKindOfClass:[NSDictionary class]]) {
        // 按钮节点：keycodes 数组必须 4 个 [-20, 400] 整数
        NSArray *kc = [(NSDictionary *)node objectForKey:@"keycodes"];
        if ([kc isKindOfClass:[NSArray class]]) {
            (*btnCount)++;
            if (kc.count > 4) { *reason = @"keycodes > 4"; return NO; }
            for (id k in kc) {
                if (![k isKindOfClass:[NSNumber class]]) { *reason = @"keycode not number"; return NO; }
                NSInteger v = [k integerValue];
                if (v < -20 || v > 400) { *reason = @"keycode out of range"; return NO; }
            }
        }
        for (NSString *k in [(NSDictionary *)node allKeys]) {
            if (!ame230_stringSafe(k)) { *reason = @"unsafe key"; return NO; }
            if (!ame230_nodeSafe([(NSDictionary *)node objectForKey:k], depth + 1, btnCount, reason)) return NO;
        }
        return YES;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) {
            if (!ame230_nodeSafe(v, depth + 1, btnCount, reason)) return NO;
        }
        return YES;
    }
    return YES;  // NSNull 等
}

/// 布局安全检查（静默版恶意代码检查）。返回 YES = 安全。
static BOOL ame230_layoutSafetyCheck(NSData *raw, id jsonObj, NSString **reasonOut) {
    NSString *ame230_reason = nil;
    do {
        if (raw.length > 2 * 1024 * 1024) { ame230_reason = @"file > 2MB"; break; }
        if (![jsonObj isKindOfClass:[NSDictionary class]] ||
            ![[jsonObj objectForKey:@"mControlDataList"] isKindOfClass:[NSArray class]]) {
            ame230_reason = @"not a control layout"; break;
        }
        NSUInteger ame230_btns = 0;
        if (!ame230_nodeSafe(jsonObj, 0, &ame230_btns, &ame230_reason)) break;
        if (ame230_btns > 400) { ame230_reason = @"too many buttons"; break; }
        if (reasonOut) *reasonOut = nil;
        return YES;
    } while (0);
    if (reasonOut) *reasonOut = ame230_reason;
    return NO;
}

/// ★ Task232（反馈 #15）：下载前安全扫描——收集【全部】问题（非首错即止），
/// 返回本地化的问题描述列表；空数组 = 干净。规则同 Task230 检查（体积/
/// 按钮数/键码范围/字符串长度/内嵌 URL/嵌套深度），误报侧修正：
/// 4MB 上限（出厂布局 PrettyPrinted 可近 2MB）、键码下界 -12（特殊键全系）。
static NSArray<NSString *> *ame232_layoutSafetyIssues(NSData *raw, id jsonObj) {
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    if (raw.length > 4 * 1024 * 1024) {
        [issues addObject:[NSString stringWithFormat:localize(@"ame232.repo.issue.size", nil),
                           (double)raw.length / 1048576.0, 4.0]];
    }
    if (![jsonObj isKindOfClass:[NSDictionary class]] ||
        ![[jsonObj objectForKey:@"mControlDataList"] isKindOfClass:[NSArray class]]) {
        [issues addObject:localize(@"ame232.repo.issue.shape", nil)];
        return issues;   // 结构不对，后续规则无从谈起
    }
    __block NSUInteger btns = 0;
    __block NSMutableArray<NSString *> *detail = [NSMutableArray array];
    __block void (^walk)(id, int) = ^(id node, int depth) {
        if (depth > 8) {
            [detail addObject:localize(@"ame232.repo.issue.depth", nil)];
            return;
        }
        if ([node isKindOfClass:[NSDictionary class]]) {
            if (node[@"keycodes"] != nil) btns++;
            for (NSString *k in [node allKeys]) {
                id v = node[k];
                if ([k isKindOfClass:[NSString class]] && [k isEqualToString:@"name"] &&
                    [v isKindOfClass:[NSString class]] && [(NSString *)v length] > 256) {
                    [detail addObject:localize(@"ame232.repo.issue.strlen", nil)];
                }
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 256 &&
                    ![k isEqualToString:@"name"]) {
                    [detail addObject:localize(@"ame232.repo.issue.strlen", nil)];
                }
                if ([v isKindOfClass:[NSString class]] &&
                    ([(NSString *)v containsString:@"http://"] || [(NSString *)v containsString:@"https://"])) {
                    [detail addObject:localize(@"ame232.repo.issue.url", nil)];
                }
                if ([k isEqualToString:@"keycodes"] && [v isKindOfClass:[NSArray class]]) {
                    for (id kc in (NSArray *)v) {
                        if (![kc isKindOfClass:[NSNumber class]]) continue;
                        int iv = [(NSNumber *)kc intValue];
                        if (iv < -12 || iv > 400) {
                            [detail addObject:[NSString stringWithFormat:localize(@"ame232.repo.issue.keycode", nil), iv]];
                        }
                    }
                }
                walk(v, depth + 1);
            }
        } else if ([node isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)node) walk(v, depth + 1);
        }
    };
    walk(jsonObj, 0);
    if (btns > 400) {
        [issues addObject:[NSString stringWithFormat:localize(@"ame232.repo.issue.buttons", nil),
                           (unsigned long)btns, 400]];
    }
    // 明细去重（同一类问题可能重复出现，列一次即可）
    for (NSString *d in [NSSet setWithArray:detail]) {
        [issues addObject:d];
    }
    return issues;
}

@implementation ControlRepoViewController

/// Task232（反馈 #15）：下载落盘安装（直通与"仍要下载"确认两路共用）。
- (void)ame232_installDownloadedLayout:(NSString *)layoutId data:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *dir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
        ame188_ensureDirectoryHealed(dir);
        NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", layoutId]];
        if (![data writeToFile:dest options:NSDataWritingAtomic error:nil]) {
            [NMToast showMessage:localize(@"custom_controls.repo.download.failed", nil)];
            return;
        }
        NSLog(@"[ControlRepo] Task232: layout saved -> %@", dest);
        [self scanLocalVersions];
        [NMToast showMessage:[NSString stringWithFormat:localize(@"custom_controls.repo.download.done", nil), layoutId]];
        if (self.whenLayoutDownloaded) self.whenLayoutDownloaded(layoutId);
    });
}

/// ★ Task311（手柄控件）：手柄映射下载落盘安装。落盘 controlmap/gamepads/
/// <id>.json——与启动器内建 generateAndSaveDefaultControlForGamepad 及
/// 手柄配置弹窗「当前」文件选择器（LauncherPrefContCfgViewController
/// actionOpenFilePicker）同目录，装完即可在该弹窗里选用，无需重启。
- (void)ame311_installDownloadedGamepad:(NSString *)layoutId data:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *dir = [NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("POJAV_HOME")];
        ame188_ensureDirectoryHealed(dir);
        NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", layoutId]];
        if (![data writeToFile:dest options:NSDataWritingAtomic error:nil]) {
            [NMToast showMessage:localize(@"custom_controls.repo.download.failed", nil)];
            return;
        }
        NSLog(@"[ControlRepo] Task311: gamepad map saved -> %@", dest);
        [self scanLocalVersions];   // 手柄角标表同轮刷新
        [NMToast showMessage:[NSString stringWithFormat:localize(@"custom_controls.repo.download.gamepad.done", nil), layoutId]];
        if (self.whenLayoutDownloaded) self.whenLayoutDownloaded(layoutId);
    });
}

- (NSInteger)task189_stickyMirror {
    NSInteger idx = [getPrefObject(@"controlrepo.mirror_idx") integerValue];
    if (idx < 0 || idx >= kTask189MirrorCount) idx = 0;
    return idx;
}

- (void)task189_rememberMirror:(NSInteger)idx {
    setPrefObject(@"controlrepo.mirror_idx", @(idx));
}

/// Task189：按镜像链拉取（索引与布局文件共用）。从粘性源开始环形尝试，
/// 全部失败才回调错误；成功即记忆源并回调数据。
/// 注意 tryNext 是【递归块】：必须 __block 声明（块内自引用，无 __block 时
/// 捕获的是未赋值的副本，首个镜像失败即空块调用闪退）。
- (void)fetchRepoFile:(NSString *)relPath completion:(void (^)(NSData *, NSError *))completion {
    NSInteger start = [self task189_stickyMirror];
    __block NSInteger tried = 0;
    __weak typeof(self) weakSelf = self;
    __block void (^tryNext)(NSError *) = nil;
    tryNext = ^(NSError *lastErr) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (tried >= kTask189MirrorCount) {
            completion(nil, lastErr ?: [NSError errorWithDomain:@"ControlRepo" code:-1
                                               userInfo:@{NSLocalizedDescriptionKey:@"all mirrors failed"}]);
            return;
        }
        NSInteger idx = (start + tried) % kTask189MirrorCount;
        tried++;
        NSString *url = task189_mirrorURL(idx, relPath);
        [strongSelf fetchOneURL:url completion:^(NSData *data, NSError *err) {
            typeof(self) strongSelf2 = weakSelf;
            if (data && !err) {
                [strongSelf2 task189_rememberMirror:idx];
                if (idx != start) {
                    NSLog(@"[ControlRepo] Task189: mirror #%ld won (sticky updated from #%ld)", (long)idx, (long)start);
                }
                completion(data, nil);
                return;
            }
            NSLog(@"[ControlRepo] Task189: mirror #%ld failed for %@ (%@)", (long)idx, relPath,
                  err.localizedDescription ?: @"unknown");
            tryNext(err);
        }];
    };
    tryNext(nil);
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _layouts = [NSMutableArray array];
        _localVersions = [NSMutableDictionary dictionary];
        _localGamepadVersions = [NSMutableDictionary dictionary];   // ★ Task311：手柄映射角标
        _downloading = [NSHashTable weakObjectsHashTable];
        _localLayouts = [NSMutableArray array];   // ★ Task310：本地页数据源
        _filteredLayouts = @[];
    }
    return self;
}

#pragma mark - Task310：控件三分类页（官方精选 / 社区 / 本地）

/// 按当前分类过滤仓库布局（index.json 条目 category 字段；缺省 = official
/// 兼容旧索引，旧缓存/镜像未更新也不空窗）。Task311：手柄页过滤 category:gamepad。
- (void)ame310_rebuildFilteredLayouts {
    NSString *want = (self.selectedCategory == 1) ? @"community"
                    : (self.selectedCategory == 2) ? @"gamepad" : @"official";
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *e in self.layouts) {
        NSString *cat = [e[@"category"] isKindOfClass:[NSString class]] ? e[@"category"] : @"official";
        if ([cat isEqualToString:want]) [out addObject:e];
    }
    self.filteredLayouts = out;
}

/// 本地 controlmap/ 全量布局清单（本地页数据源）。与 scanLocalVersions
/// 同一次目录遍历填充（见该方法），此处仅复位容器。
- (void)ame310_scanLocalLayouts {
    [self.localLayouts removeAllObjects];
    NSString *dir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString *p = [dir stringByAppendingPathComponent:f];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;   // 损坏文件不上榜（与旧 badge 口径一致）
        id v = [obj objectForKey:@"version"];
        NSString *ver = [v isKindOfClass:[NSString class]] ? v :
                        ([v respondsToSelector:@selector(stringValue)] ? [v stringValue] : nil);
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        [self.localLayouts addObject:@{
            @"name": [f stringByDeletingPathExtension],
            @"version": ver ?: @"",
            @"size": attrs[NSFileSize] ?: @0,
        }];
    }
    [self.localLayouts sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
}

- (void)ame310_categoryChanged:(UISegmentedControl *)seg {
    self.selectedCategory = seg.selectedSegmentIndex;
    if (self.selectedCategory == 3) [self ame310_scanLocalLayouts];   // 切到本地页时重扫（可能刚下载/刚删）
    else [self ame310_rebuildFilteredLayouts];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"custom_controls.repo.title", nil);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(refreshRepo:)];
    // ★ Task230（反馈 #13）：上传入口——任何人都可把已安装布局上传到
    //   仓库（元信息表单 + 安全检查 + 分享/GitHub 提交双通道）。
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:localize(@"ame230.repo.upload", nil)
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(ame230_uploadTapped:)];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refreshRepo:)
                  forControlEvents:UIControlEventValueChanged];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;
    // ★ Task310（控件三分类页）→ Task311（四分类）：顶部四分类分段控件
    //   （官方精选/社区/手柄/本地）。手柄页 = 仓库 gamepad 控件映射下载区。
    //   frame 定宽 + autoresizing 宽度弹窗——tableHeaderView 约束宽度不随
    //   tableView 自适应的经典坑，autoresizingMask 一行解。
    UIView *ame310_hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 48)];
    ame310_hdr.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.categorySegment = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"dl.controls.cat.official", nil),
        localize(@"dl.controls.cat.community", nil),
        localize(@"dl.controls.cat.gamepad", nil),
        localize(@"dl.controls.cat.local", nil)]];
    self.categorySegment.selectedSegmentIndex = 0;
    self.categorySegment.frame = CGRectMake(12, 8, self.view.bounds.size.width - 24, 32);
    self.categorySegment.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.categorySegment addTarget:self action:@selector(ame310_categoryChanged:)
                  forControlEvents:UIControlEventValueChanged];
    [ame310_hdr addSubview:self.categorySegment];
    self.tableView.tableHeaderView = ame310_hdr;
    [self scanLocalVersions];
    [self fetchIndex];
}

/// Task230：上传入口点击 → 选已安装布局 → 填元信息 → 安全检查 → 提交。
- (void)ame230_uploadTapped:(id)sender {
    [ControlRepoViewController ame230_presentUploadFlowFrom:self preselect:nil];
}

/// 扫描本地 controlmap/ 的同名文件，计算"已下载/可更新"角标数据。
/// 仓库 id 与本地文件名一一对应（<id>.json），版本对比用仓库条目的
/// version 字段与本地无版本信息（旧文件）的区分。
- (void)scanLocalVersions {
    [self.localVersions removeAllObjects];
    NSString *dir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString *stem = [f stringByDeletingPathExtension];
        // 读取本地文件的 version 字段（存在才有），无则记为 "?"（已下载旧版）
        NSString *p = [dir stringByAppendingPathComponent:f];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        id v = [(NSDictionary *)obj objectForKey:@"version"];
        self.localVersions[stem] = [v isKindOfClass:[NSString class]] ? v :
                                   ([v respondsToSelector:@selector(stringValue)] ? [v stringValue] : @"?");
    }
    // ★ Task311（手柄控件）：同口径扫描 controlmap/gamepads/——手柄页角标
    //   （已下载/可更新）数据源。与触屏分表，两目录同名文件互不串号。
    [self.localGamepadVersions removeAllObjects];
    NSString *ame311_gpDir = [NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("POJAV_HOME")];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:ame311_gpDir error:nil] ?: @[]) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString *p = [ame311_gpDir stringByAppendingPathComponent:f];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        id v = [(NSDictionary *)obj objectForKey:@"version"];
        self.localGamepadVersions[[f stringByDeletingPathExtension]] =
            [v isKindOfClass:[NSString class]] ? v :
            ([v respondsToSelector:@selector(stringValue)] ? [v stringValue] : @"?");
    }
    // ★ Task310：同一次遍历口径复用——本地三分类页数据源同步刷新
    [self ame310_scanLocalLayouts];
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)refreshRepo:(id)sender {
    [self fetchIndex];
}

- (void)fetchIndex {
    [self.refreshControl beginRefreshing];
    [self fetchRepoFile:@"index.json" completion:^(NSData *data, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            if (!data || error) {
                NSLog(@"[ControlRepo] Task189: index fetch failed (all mirrors): %@", error.localizedDescription ?: @"unknown");
                self.loadFailed = YES;
                [self.layouts removeAllObjects];
                [self ame310_rebuildFilteredLayouts];   // ★ Task310：错误分支同步清空过滤视图
                [self.tableView reloadData];
                return;
            }
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *arr = ([obj isKindOfClass:[NSDictionary class]]) ? obj[@"layouts"] : nil;
            if (![arr isKindOfClass:[NSArray class]]) {
                NSLog(@"[ControlRepo] Task189: index JSON invalid (no layouts array)");
                self.loadFailed = YES;
                [self.layouts removeAllObjects];
                [self ame310_rebuildFilteredLayouts];   // ★ Task310：错误分支同步清空过滤视图
                [self.tableView reloadData];
                return;
            }
            self.loadFailed = NO;
            [self.layouts removeAllObjects];
            for (NSDictionary *e in arr) {
                if ([e isKindOfClass:[NSDictionary class]] && [e[@"id"] isKindOfClass:[NSString class]]) {
                    [self.layouts addObject:e];
                }
            }
            NSLog(@"[ControlRepo] Task189: index loaded via mirror chain, %lu layouts", (unsigned long)self.layouts.count);
            // ★ Task310：按当前分类重建过滤视图（官方精选/社区）
            [self ame310_rebuildFilteredLayouts];
            [self scanLocalVersions];
        });
    }];
}

- (void)fetchOneURL:(NSString *)urlString completion:(void (^)(NSData *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { completion(nil, [NSError errorWithDomain:@"ControlRepo" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"invalid url"}]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    // Task189：镜像链单源超时收紧到 12s（六源最坏 72s；旧 20s 只有两源时代的值）
    req.timeoutInterval = 12.0;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { completion(nil, error); return; }
        if ([resp isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)resp statusCode] >= 400) {
            completion(nil, [NSError errorWithDomain:@"ControlRepo" code:[(NSHTTPURLResponse *)resp statusCode]
                                          userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"HTTP %ld", (long)[(NSHTTPURLResponse *)resp statusCode]]}]);
            return;
        }
        completion(data, nil);
    }];
    [task resume];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // ★ Task310：三分类行数 → Task311：四分类——本地页(3)走 localLayouts，
    //   官方/社区/手柄(0/1/2)走过滤视图。空态统一占位 1 行（占位文案在 cellForRow 内区分分类）。
    if (self.selectedCategory == 3) {
        return self.localLayouts.count == 0 ? 1 : self.localLayouts.count;
    }
    return self.loadFailed ? 1 : (self.filteredLayouts.count == 0 ? 1 : self.filteredLayouts.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"Task188RepoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.numberOfLines = 0;
    }
    if (self.selectedCategory == 3) {
        // ★ Task310：本地页（Task311 起索引 3）。空态 = 引导去官方精选/编辑器；有数据 = 布局清单。
        if (self.localLayouts.count == 0) {
            cell.textLabel.text = localize(@"dl.controls.local.empty", nil);
            cell.detailTextLabel.text = @"";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        NSDictionary *e = self.localLayouts[indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%@", e[@"name"]];
        NSString *ver = [e[@"version"] isKindOfClass:[NSString class]] && [(NSString *)e[@"version"] length] > 0
                        ? e[@"version"] : @"?";
        double kb = [(NSNumber *)e[@"size"] doubleValue] / 1024.0;
        cell.detailTextLabel.text = [NSString stringWithFormat:localize(@"dl.controls.local.file.sub", nil), ver, kb];
        cell.accessoryType = UITableViewCellAccessoryDetailButton;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (self.loadFailed || self.filteredLayouts.count == 0) {
        // ★ Task310：官方/社区空态区分——社区空 = 上传 CTA（点击可发布）。
        if (!self.loadFailed && self.selectedCategory == 1) {
            cell.textLabel.text = localize(@"dl.controls.community.empty", nil);
            cell.detailTextLabel.text = localize(@"dl.controls.community.empty.tap", nil);
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
        cell.textLabel.text = self.loadFailed ? localize(@"custom_controls.repo.fetch.failed", nil)
                                              : localize(@"custom_controls.repo.empty", nil);
        cell.detailTextLabel.text = self.loadFailed ? localize(@"custom_controls.repo.retry_hint", nil) : @"";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *e = self.filteredLayouts[indexPath.row];
    cell.textLabel.text = [e[@"name"] isKindOfClass:[NSString class]] ? e[@"name"] : e[@"id"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    NSString *author = [e[@"author"] isKindOfClass:[NSString class]] ? e[@"author"] : @"?";
    NSString *desc = [e[@"description"] isKindOfClass:[NSString class]] ? e[@"description"] : @"";
    NSString *ver = [e[@"version"] isKindOfClass:[NSString class]] ? e[@"version"] : @"1.0";
    NSMutableString *sub = [NSMutableString string];
    // ★ Task311：角标分表——gamepad 条目查手柄映射安装表，触屏条目查原表。
    NSString *ame311_cat = [e[@"category"] isKindOfClass:[NSString class]] ? e[@"category"] : @"official";
    NSString *local = [ame311_cat isEqualToString:@"gamepad"] ? self.localGamepadVersions[e[@"id"]]
                                                              : self.localVersions[e[@"id"]];
    if (local != nil) {
        [sub appendFormat:@"%@", [NSString stringWithFormat:localize(@"custom_controls.repo.installed", nil), local]];
        if (![local isEqualToString:ver]) {
            [sub appendFormat:@" · %@", [NSString stringWithFormat:localize(@"custom_controls.repo.update_available", nil), ver]];
        }
    } else {
        [sub appendString:[NSString stringWithFormat:localize(@"custom_controls.repo.author", nil), author]];
    }
    if (desc.length > 0) [sub appendFormat:@"\n%@", desc];
    cell.detailTextLabel.text = sub;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // ★ Task310：本地页点击（Task311 起索引 3）—— 动作单（上传到社区 / 删除）。
    if (self.selectedCategory == 3) {
        if (self.localLayouts.count == 0) return;
        NSDictionary *e = self.localLayouts[indexPath.row];
        NSString *name = e[@"name"];
        NSString *fileName = [name stringByAppendingPathExtension:@"json"];
        // ★ Task310：当前默认布局禁删——删了它游戏启动即无控件可用
        //（control.default_ctrl 指向的文件是 LoadControlFile 的主源）。
        if ([fileName isEqualToString:getPrefObject(@"control.default_ctrl")]) {
            [NMToast showMessage:localize(@"dl.controls.local.delete.active", nil)];
            return;
        }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:localize(@"dl.controls.local.upload", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [ControlRepoViewController ame230_presentUploadFlowFrom:self preselect:fileName];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:localize(@"dl.controls.local.delete", nil)
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *a) {
            NSString *msg = [NSString stringWithFormat:localize(@"dl.controls.local.delete.confirm", nil), fileName];
            UIAlertController *confirm = [UIAlertController alertControllerWithTitle:fileName
                                                                             message:msg
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:localize(@"ame232.repo.check.cancel", nil)
                                                       style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:localize(@"dl.controls.local.delete", nil)
                                                       style:UIAlertActionStyleDestructive
                                                     handler:^(UIAlertAction *a2) {
                NSString *dir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
                NSString *path = [dir stringByAppendingPathComponent:fileName];
                NSError *delErr = nil;
                if ([[NSFileManager defaultManager] removeItemAtPath:path error:&delErr]) {
                    NSLog(@"[ControlRepo] Task310: local layout %@ deleted", fileName);
                    [NMToast showMessage:localize(@"dl.controls.local.deleted", nil)];
                    [self scanLocalVersions];   // 同步刷新 localVersions + localLayouts + 角标
                } else {
                    NSLog(@"[ControlRepo] Task310: delete %@ failed: %@", fileName, delErr.localizedDescription ?: @"?");
                    [NMToast showMessage:[NSString stringWithFormat:@"%@: %@", localize(@"dl.controls.local.delete", nil), delErr.localizedDescription ?: @"error"]];
                }
            }]];
            [self presentViewController:confirm animated:YES completion:nil];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:localize(@"ame232.repo.check.cancel", nil)
                                                  style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = tableView;
        sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    // ★ Task310：官方/社区空态行 —— 社区空态行点击直达上传流程；
    //   加载失败行点击重拉索引（原行为）。
    if (self.loadFailed || self.filteredLayouts.count == 0) {
        if (!self.loadFailed && self.selectedCategory == 1) {
            [ControlRepoViewController ame230_presentUploadFlowFrom:self preselect:nil];
            return;
        }
        if (self.loadFailed) [self fetchIndex];
        return;
    }
    NSDictionary *e = self.filteredLayouts[indexPath.row];
    NSString *layoutId = e[@"id"];
    // ★ Task311：gamepad 条目分流——校验/安装路径/提示全部走手柄映射管线
    //  （落盘 controlmap/gamepads/<id>.json，触屏管线落 controlmap/ 不变）。
    NSString *ame311_cat = [e[@"category"] isKindOfClass:[NSString class]] ? e[@"category"] : @"official";
    BOOL ame311_isGamepad = [ame311_cat isEqualToString:@"gamepad"];
    if ([self.downloading containsObject:layoutId]) return;  // 防连点
    [self.downloading addObject:layoutId];
    NSString *file = [e[@"file"] isKindOfClass:[NSString class]] ? e[@"file"] :
                     [NSString stringWithFormat:ame311_isGamepad ? @"gamepads/%@.json" : @"layouts/%@.json", layoutId];
    NSLog(@"[ControlRepo] Task189: downloading layout %@ (%@) via mirror chain", layoutId, file);
    [self fetchRepoFile:file completion:^(NSData *data, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.downloading removeObject:layoutId];
            if (!data || error) {
                NSLog(@"[ControlRepo] Task188: layout download failed: %@", error.localizedDescription ?: @"unknown");
                [NMToast showMessage:[NSString stringWithFormat:@"%@\n%@", localize(@"custom_controls.repo.download.failed", nil), error.localizedDescription ?: @""]];
                return;
            }
            if (ame311_isGamepad) {
                // ★ Task311（手柄控件）：手柄映射校验——顶层 dict 且
                //   mGameMappingList / mMenuMappingList 至少一个为数组
                //   （与 generateAndSaveDefaultControlForGamepad / ControllerInput
                //   initKeycodeTable 消费口径同构），拦截 CDN/代理污染的 HTML 页；
                //   体积上限 256KB（手柄映射实测 ~3KB，留百倍余量）。
                //   ame232 触屏安全扫描不适用（schema 不同：无 mControlDataList/
                //   按钮形状树；手柄映射是纯 键码表，无脚本执行面）。
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                BOOL ame311_valid = [obj isKindOfClass:[NSDictionary class]] &&
                    ([[obj objectForKey:@"mGameMappingList"] isKindOfClass:[NSArray class]] ||
                     [[obj objectForKey:@"mMenuMappingList"] isKindOfClass:[NSArray class]]);
                if (!ame311_valid || data.length > 256 * 1024) {
                    NSLog(@"[ControlRepo] Task311: gamepad map invalid (valid=%d, len=%lu)",
                          (int)ame311_valid, (unsigned long)data.length);
                    [NMToast showMessage:localize(@"custom_controls.repo.download.gamepad.invalid", nil)];
                    return;
                }
                [self ame311_installDownloadedGamepad:layoutId data:data];
                return;
            }
            // 校验：必须是 layoutDictionary 同构（顶层 dict + mControlDataList 数组），
            // 拦截被 CDN/代理污染的 HTML 错误页等。
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![obj isKindOfClass:[NSDictionary class]] ||
                ![[obj objectForKey:@"mControlDataList"] isKindOfClass:[NSArray class]]) {
                NSLog(@"[ControlRepo] Task188: layout JSON invalid (not a control layout)");
                [NMToast showMessage:localize(@"custom_controls.repo.download.invalid", nil)];
                return;
            }
            // ★ Task232（反馈 #15）：安全检查从"上传拦截 + 下载静默拦截"
            //   改为"下载时扫描 + 列出问题 + 询问是否继续"。检查算法同时
            //   按用户反馈收紧误报（正常默认控件不再误伤）：体积上限 2MB
            //   → 4MB（5652 行的出厂布局 PrettyPrinted 接近 2MB）；键码
            //   下界放宽到 -12（SPECIALBTN_KEYBOARD..MENU 全系合法）。
            NSArray<NSString *> *ame232_issues = ame232_layoutSafetyIssues(data, obj);
            if (ame232_issues.count > 0) {
                NSLog(@"[ControlRepo] Task232: layout %@ flagged with %lu issue(s): %@",
                      layoutId, (unsigned long)ame232_issues.count, ame232_issues);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSMutableString *ame232_msg = [NSMutableString string];
                    for (NSString *ame232_it in ame232_issues) {
                        if (ame232_msg.length > 0) [ame232_msg appendString:@"\n"];
                        [ame232_msg appendFormat:@"· %@", ame232_it];
                    }
                    UIAlertController *ame232_alert = [UIAlertController
                        alertControllerWithTitle:localize(@"ame232.repo.check.title", nil)
                                         message:ame232_msg
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [ame232_alert addAction:[UIAlertAction
                        actionWithTitle:localize(@"ame232.repo.check.cancel", nil)
                                  style:UIAlertActionStyleCancel
                                handler:nil]];
                    [ame232_alert addAction:[UIAlertAction
                        actionWithTitle:localize(@"ame232.repo.check.continue", nil)
                                  style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *a) {
                            [self ame232_installDownloadedLayout:layoutId data:data];
                        }]];
                    [self presentViewController:ame232_alert animated:YES completion:nil];
                });
                return;
            }
            NSLog(@"[ControlRepo] Task232: layout %@ passed safety scan", layoutId);
            [self ame232_installDownloadedLayout:layoutId data:data];
        });
    }];
}

#pragma mark - Task255：自动检查控件更新（启动链静默检查）

// ★ Task255（清单 8）：开关 control.auto_control_update_check=ON 时启动后
//   静默拉仓库 index.json（复用 Task189 六源镜像链，顺序尝试），与本地
//   controlmap/<id>.json 顶层 version 字段对比；发现可更新布局 → toast
//   提示（不自动下载——下载属用户显式动作，在控件仓库页自取）。静态一次
//   性守卫（ame125 启动器更新检查同款），失败静默（不打扰）。
+ (void)autoCheckControlUpdatesOnce {
    static BOOL ame255_checked = NO;
    if (ame255_checked) return;
    ame255_checked = YES;
    if (!getPrefBool(@"auto_control_update_check")) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 本地版本表（scanLocalVersions 同口径）
        NSMutableDictionary<NSString *, NSString *> *local = [NSMutableDictionary dictionary];
        NSString *dir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
            if (![f.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
            NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
            if (!d) continue;
            id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (![obj isKindOfClass:[NSDictionary class]]) continue;
            id v = obj[@"version"];
            local[[f stringByDeletingPathExtension]] =
                [v isKindOfClass:[NSString class]] ? v :
                ([v respondsToSelector:@selector(stringValue)] ? [v stringValue] : @"?");
        }
        // 六源镜像链顺序拉 index（无粘性状态，从 0 试起）
        __block NSData *ame255_index = nil;
        for (NSInteger ame255_i = 0; ame255_i < kTask189MirrorCount && ame255_index == nil; ame255_i++) {
            NSURL *ame255_url = [NSURL URLWithString:task189_mirrorURL(ame255_i, @"index.json")];
            if (ame255_url == nil) continue;
            NSMutableURLRequest *ame255_req = [NSMutableURLRequest requestWithURL:ame255_url];
            ame255_req.timeoutInterval = 10.0;
            ame255_req.HTTPMethod = @"GET";
            dispatch_semaphore_t ame255_sem = dispatch_semaphore_create(0);
            [[[NSURLSession sharedSession] dataTaskWithRequest:ame255_req
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSHTTPURLResponse *hresp = (NSHTTPURLResponse *)resp;
                if (err == nil && data.length > 0 &&
                    hresp.statusCode >= 200 && hresp.statusCode < 300) {
                    ame255_index = data;
                }
                dispatch_semaphore_signal(ame255_sem);
            }] resume];
            dispatch_semaphore_wait(ame255_sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)));
        }
        if (ame255_index == nil) {
            NSLog(@"[ControlRepo] Task255: auto update check skipped (index unreachable on all mirrors)");
            return;
        }
        id ame255_obj = [NSJSONSerialization JSONObjectWithData:ame255_index options:0 error:nil];
        NSArray *ame255_arr = ([ame255_obj isKindOfClass:[NSDictionary class]]) ? ame255_obj[@"layouts"] : nil;
        if (![ame255_arr isKindOfClass:[NSArray class]]) return;
        NSMutableArray<NSString *> *ame255_updatable = [NSMutableArray array];
        for (NSDictionary *e in ame255_arr) {
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            NSString *ame255_id = e[@"id"];
            NSString *ame255_repoVer = [e[@"version"] isKindOfClass:[NSString class]] ? e[@"version"] :
                ([e[@"version"] respondsToSelector:@selector(stringValue)] ? [e[@"version"] stringValue] : nil);
            if (ame255_id.length == 0 || ame255_repoVer.length == 0) continue;
            NSString *ame255_localVer = local[ame255_id];
            if (ame255_localVer == nil) continue;                       // 未下载：非"更新"语义
            if ([ame255_localVer isEqualToString:ame255_repoVer]) continue;
            if ([ame255_localVer isEqualToString:@"?"]) {               // 旧文件无版本字段：无法判代
                NSLog(@"[ControlRepo] Task255: layout '%@' local version unknown (legacy file) -- skipped", ame255_id);
                continue;
            }
            [ame255_updatable addObject:ame255_id];
        }
        if (ame255_updatable.count == 0) {
            NSLog(@"[ControlRepo] Task255: auto update check done -- all local layouts up to date");
            return;
        }
        NSString *ame255_msg = [NSString stringWithFormat:
            localize(@"custom_controls.repo.auto_update_found", @"检测到 %lu 个控件布局有更新（%@），可在控件仓库页下载"),
            (unsigned long)ame255_updatable.count,
            [ame255_updatable componentsJoinedByString:@", "]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NMToast showMessage:ame255_msg];
        });
        NSLog(@"[ControlRepo] Task255: auto update check found %lu updatable: %@",
              (unsigned long)ame255_updatable.count, ame255_updatable);
    });
}

#pragma mark - Task230：上传流程（反馈 #13）

/// Task230：已安装布局清单（controlmap/ 下全部 .json，排除 gamepads 子目录）。
+ (NSArray<NSString *> *)ame230_installedLayoutFileNames {
    NSString *dir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        if ([f hasSuffix:@".json"]) [out addObject:f];
    }
    return out;
}

/// ★ Task311（手柄控件）：已安装手柄映射清单（controlmap/gamepads/ 下全部
/// .json）——上传选择器与触屏布局并列，手柄映射也能进仓库生态。
+ (NSArray<NSString *> *)ame311_installedGamepadFileNames {
    NSString *dir = [NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("POJAV_HOME")];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        if ([f hasSuffix:@".json"]) [out addObject:f];
    }
    return out;
}

/// Task230：上传主流程（仓库页与控件编辑器共用）。
///   ① 选已安装布局（preselect 非空则跳过）；
///   ② 填写元信息（名称/作者/描述——详细信息即仓库条目字段）；
///   ③ 同款安全检查（上传侧也拦截——不把危险件送进仓库）；
///   ④ 双通道提交：系统分享（导出提交文件，任意渠道发给维护者）或
///      GitHub 网页建文件深链（预填路径+内容，登录用户一键提 PR）。
+ (void)ame230_presentUploadFlowFrom:(UIViewController *)presenter preselect:(NSString *)preselect {
    // ★ Task311：fillForm 增加 isGamepad 维度——手柄映射与触屏布局共用表单，
    //   提交分流在 ame230_finishUploadFrom（目录/文件路径/category 元数据）。
    void (^fillForm)(NSString *, BOOL) = ^(NSString *fileName, BOOL isGamepad) {
        UIAlertController *form = [UIAlertController
            alertControllerWithTitle:localize(@"ame230.repo.upload.form.title", nil)
                             message:[NSString stringWithFormat:localize(@"ame230.repo.upload.form.message", nil), fileName]
                      preferredStyle:UIAlertControllerStyleAlert];
        [form addTextFieldWithConfigurationHandler:^(UITextField *t) {
            t.placeholder = localize(@"ame230.repo.upload.name", nil);
            t.text = fileName.stringByDeletingPathExtension;
        }];
        [form addTextFieldWithConfigurationHandler:^(UITextField *t) {
            t.placeholder = localize(@"ame230.repo.upload.author", nil);
        }];
        [form addTextFieldWithConfigurationHandler:^(UITextField *t) {
            t.placeholder = localize(@"ame230.repo.upload.desc", nil);
        }];
        [form addAction:[UIAlertAction actionWithTitle:localize(@"global.share", nil)
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [ControlRepoViewController ame230_finishUploadFrom:presenter
                                                      fileName:fileName
                                                          name:form.textFields[0].text
                                                        author:form.textFields[1].text
                                                     depiction:form.textFields[2].text
                                                    viaGitHub:NO
                                                    isGamepad:isGamepad];
        }]];
        [form addAction:[UIAlertAction actionWithTitle:localize(@"ame230.repo.upload.github", nil)
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [ControlRepoViewController ame230_finishUploadFrom:presenter
                                                      fileName:fileName
                                                          name:form.textFields[0].text
                                                        author:form.textFields[1].text
                                                     depiction:form.textFields[2].text
                                                    viaGitHub:YES
                                                    isGamepad:isGamepad];
        }]];
        [form addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                                 style:UIAlertActionStyleCancel handler:nil]];
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            form.popoverPresentationController.sourceView = presenter.view;
            form.popoverPresentationController.sourceRect = CGRectMake(presenter.view.bounds.size.width / 2.0,
                                                                       presenter.view.bounds.size.height / 2.0, 1, 1);
        }
        [presenter presentViewController:form animated:YES completion:nil];
    };

    if (preselect.length > 0) { fillForm(preselect, NO); return; }
    NSArray<NSString *> *installed = [self ame230_installedLayoutFileNames];
    NSArray<NSString *> *ame311_gamepads = [self ame311_installedGamepadFileNames];
    if (installed.count == 0 && ame311_gamepads.count == 0) {
        [NMToast showMessage:localize(@"ame230.repo.upload.no_layouts", nil)];
        return;
    }
    // ★ Task240：换装系统原生 UIMenu（旧 actionSheet 退役）。
    //   ★ Task311：手柄映射与触屏布局并列可选——手柄项尾部带分类标签区分。
    NSMutableArray<NSDictionary *> *ame240_items = [NSMutableArray array];
    for (NSString *f in installed) {
        [ame240_items addObject:@{
            @"title": f.stringByDeletingPathExtension,
            @"handler": ^{ fillForm(f, NO); },
        }];
    }
    for (NSString *f in ame311_gamepads) {
        [ame240_items addObject:@{
            @"title": [NSString stringWithFormat:@"%@ · %@", f.stringByDeletingPathExtension,
                       localize(@"dl.controls.cat.gamepad", nil)],
            @"handler": ^{ fillForm(f, YES); },
        }];
    }
    [AmeNativeMenu ame240_presentMenuWithTitle:localize(@"ame230.repo.upload.pick", nil)
                                     dictItems:ame240_items
                                    sourceView:presenter.view];
}

/// Task230：上传收尾——安全检查 → 提交文件生成 → 分享 / GitHub 深链。
/// ★ Task311：新增 isGamepad 维度——手柄映射提交读 gamepads 目录、
///   file 字段指 gamepads/、带 category:gamepad 元数据、GitHub 深链指
///   controls/gamepads 目录（触屏路径行为不变）。
+ (void)ame230_finishUploadFrom:(UIViewController *)presenter
                       fileName:(NSString *)fileName
                           name:(NSString *)name
                         author:(NSString *)author
                      depiction:(NSString *)depiction
                     viaGitHub:(BOOL)viaGitHub
                      isGamepad:(BOOL)isGamepad {
    NSString *dir = isGamepad
        ? [NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("POJAV_HOME")]
        : [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
    NSString *src = [dir stringByAppendingPathComponent:fileName];
    NSData *raw = [NSData dataWithContentsOfFile:src];
    // ★ Task232（反馈 #15）：上传免检——用户指令（连默认控件都过不了
    //   检查 = 算法对正常布局误报）。安全职责全部移到下载侧的
    //   扫描 + 询问流程（见 ame232_layoutSafetyIssues）。
    if (raw == nil) {
        NSLog(@"[ControlRepo] Task232: upload source unreadable: %@", fileName);
        [NMToast showMessage:localize(@"ame230.repo.upload.invalid", nil)];
        return;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    // 提交文件：元信息包裹布局（维护者合入 controls/index.json + layouts/）
    NSString *ame230_id = fileName.stringByDeletingPathExtension;
    NSMutableDictionary *ame311_submission = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id": ame230_id,
        @"name": name.length > 0 ? name : ame230_id,
        @"author": author.length > 0 ? author : @"anonymous",
        @"description": depiction.length > 0 ? depiction : @"",
        @"version": @"1",
        @"file": [NSString stringWithFormat:isGamepad ? @"gamepads/%@.json" : @"layouts/%@.json", ame230_id],
        @"layout": obj,
    }];
    if (isGamepad) ame311_submission[@"category"] = @"gamepad";   // ★ Task311：手柄条目进仓库手柄分类
    NSDictionary *submission = ame311_submission;
    NSData *out = [NSJSONSerialization dataWithJSONObject:submission options:NSJSONWritingPrettyPrinted error:nil];
    if (out == nil) {
        [NMToast showMessage:localize(@"ame230.repo.upload.invalid", nil)];
        return;
    }
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"prisma-control-upload-%@.json", ame230_id]];
    [out writeToFile:tmp options:NSDataWritingAtomic error:nil];
    NSLog(@"[ControlRepo] Task230: upload submission ready (%lu bytes, safety-passed) via %@",
          (unsigned long)out.length, viaGitHub ? @"GitHub link" : @"share sheet");
    if (viaGitHub) {
        // ★ Task233（反馈：分享控件到 GitHub 无法打开网页）：内容永远先复制
        //   剪贴板（网页预填缺失直接粘贴，任何网络/长度条件下都不丢内容）。
        //   ★ Task234（反馈：网页能打开了，但显示 "Looks like something
        //   went wrong!"——GitHub 通用 500 错误页）：Task233 版仍带两枚查询
        //   参数——filename=（%2F 编码完整路径）与 value=（≤6000 字符全量
        //   JSON 预填）。取证定案：① filename 带斜杠是 isaacs/github#1527
        //   实锤的已知 bug（“指定 filename 时目录上跳一级”）；② /new 编辑
        //   器对大载荷 value 的服务端渲染会 500。本轮【零查询参数】终案：
        //   目录前缀进 URL 路径（/new/main/controls/layouts/community——
        //   建文件页原生的目录预导航，文件名框自动带出目录前缀，纯 ASCII
        //   常量、URLString 永不失败），内容只走剪贴板，提示语带出应补的
        //   文件名（用户只补 id.json 一段）。
        NSString *json = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
        UIPasteboard.generalPasteboard.string = json ?: @"";
        NSLog(@"[ControlRepo] Task233: submission JSON (%lu bytes) copied to clipboard", (unsigned long)out.length);
        NSString *ame234_base = [NSString stringWithFormat:
            @"https://github.com/%@/%@/new/%@/%@",
            kTask189RepoOwner, kTask189RepoName, kTask189RepoRef,
            isGamepad ? @"controls/gamepads" : @"controls/layouts/community"];
        NSURL *ame233_url = [NSURL URLWithString:ame234_base];
        if (ame233_url != nil) {
            [[UIApplication sharedApplication] openURL:ame233_url options:@{}
                                     completionHandler:^(BOOL ame233_success) {
                NSLog(@"[ControlRepo] Task233 GitHub openURL success=%d (urlLen=%lu)",
                      (int)ame233_success, (unsigned long)ame234_base.length);
                if (!ame233_success) {
                    [NMToast showMessage:localize(@"ame233.repo.open_fail", nil)];
                }
            }];
        } else {
            // 理论不可达（纯 ASCII 常量 URL），防御性兜底：剪贴板仍持有全部内容
            NSLog(@"[ControlRepo] Task234 GitHub URL nil (len=%lu) -- clipboard fallback only",
                  (unsigned long)ame234_base.length);
            [NMToast showMessage:localize(@"ame233.repo.open_fail", nil)];
        }
        [NMToast showMessage:[NSString stringWithFormat:localize(@"ame230.repo.upload.github_hint", nil), ame230_id]];
    } else {
        UIActivityViewController *avc = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:tmp]]
             applicationActivities:nil];
        avc.popoverPresentationController.sourceView = presenter.view;
        avc.popoverPresentationController.sourceRect = presenter.view.bounds;
        [presenter presentViewController:avc animated:YES completion:nil];
    }
}

@end
