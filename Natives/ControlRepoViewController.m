#import "ControlRepoViewController.h"
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *localVersions;  // id -> 本地已装版本
@property (nonatomic, strong) NSHashTable *downloading;  // 正在下载的 id 集合（去重点击）
@property (nonatomic, assign) BOOL loadFailed;
@end

@implementation ControlRepoViewController

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
        _downloading = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"custom_controls.repo.title", nil);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(refreshRepo:)];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refreshRepo:)
                  forControlEvents:UIControlEventValueChanged];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;
    [self scanLocalVersions];
    [self fetchIndex];
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
                [self.tableView reloadData];
                return;
            }
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *arr = ([obj isKindOfClass:[NSDictionary class]]) ? obj[@"layouts"] : nil;
            if (![arr isKindOfClass:[NSArray class]]) {
                NSLog(@"[ControlRepo] Task189: index JSON invalid (no layouts array)");
                self.loadFailed = YES;
                [self.layouts removeAllObjects];
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
    return self.loadFailed ? 1 : (self.layouts.count == 0 ? 1 : self.layouts.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"Task188RepoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.numberOfLines = 0;
    }
    if (self.loadFailed || self.layouts.count == 0) {
        cell.textLabel.text = self.loadFailed ? localize(@"custom_controls.repo.fetch.failed", nil)
                                              : localize(@"custom_controls.repo.empty", nil);
        cell.detailTextLabel.text = self.loadFailed ? localize(@"custom_controls.repo.retry_hint", nil) : @"";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *e = self.layouts[indexPath.row];
    cell.textLabel.text = [e[@"name"] isKindOfClass:[NSString class]] ? e[@"name"] : e[@"id"];
    NSString *author = [e[@"author"] isKindOfClass:[NSString class]] ? e[@"author"] : @"?";
    NSString *desc = [e[@"description"] isKindOfClass:[NSString class]] ? e[@"description"] : @"";
    NSString *ver = [e[@"version"] isKindOfClass:[NSString class]] ? e[@"version"] : @"1.0";
    NSMutableString *sub = [NSMutableString string];
    NSString *local = self.localVersions[e[@"id"]];
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
    if (self.loadFailed || self.layouts.count == 0) {
        if (self.loadFailed) [self fetchIndex];
        return;
    }
    NSDictionary *e = self.layouts[indexPath.row];
    NSString *layoutId = e[@"id"];
    if ([self.downloading containsObject:layoutId]) return;  // 防连点
    [self.downloading addObject:layoutId];
    NSString *file = [e[@"file"] isKindOfClass:[NSString class]] ? e[@"file"] :
                     [NSString stringWithFormat:@"layouts/%@.json", layoutId];
    NSLog(@"[ControlRepo] Task189: downloading layout %@ (%@) via mirror chain", layoutId, file);
    [self fetchRepoFile:file completion:^(NSData *data, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.downloading removeObject:layoutId];
            if (!data || error) {
                NSLog(@"[ControlRepo] Task188: layout download failed: %@", error.localizedDescription ?: @"unknown");
                [NMToast showMessage:[NSString stringWithFormat:@"%@\n%@", localize(@"custom_controls.repo.download.failed", nil), error.localizedDescription ?: @""]];
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
            NSString *dir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
            ame188_ensureDirectoryHealed(dir);
            NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", layoutId]];
            if (![data writeToFile:dest options:NSDataWritingAtomic error:nil]) {
                [NMToast showMessage:localize(@"custom_controls.repo.download.failed", nil)];
                return;
            }
            NSLog(@"[ControlRepo] Task189: layout saved -> %@", dest);
            [self scanLocalVersions];
            [NMToast showMessage:[NSString stringWithFormat:localize(@"custom_controls.repo.download.done", nil), layoutId]];
            if (self.whenLayoutDownloaded) self.whenLayoutDownloaded(layoutId);
        });
    }];
}

@end
