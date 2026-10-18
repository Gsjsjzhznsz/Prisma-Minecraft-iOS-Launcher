//
// PrivilegePluginRegistry.m — Task296 第三方权限插件宿主实现
//
// 设计红线（与 .h 注释互为表里）：
//   1. 主仓库零漏洞代码：本文件只有 dlopen/dlsym/状态机，无任何利用逻辑。
//   2. 默认关闭 + 明示同意：无同意只做"文件存在性 + Mach-O 魔数"探测，
//      绝不 dlopen（不执行任何插件代码）。
//   3. 单次挂载：进程内 acquire 最多一次，失败不重试（内核态操作重试 =
//      整机 panic 风险，契约明令禁止）。
//   4. 零阻塞降级：任何失败都不阻断启动，行为与无插件时完全一致
//      （TrollStore entitlements / StikJIT 深链不受影响）。
//   5. 诊断日志 [ame296] 前缀全量落 latestlog（对齐装机三报取证口径）。
//

#import "PrivilegePluginRegistry.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/swap.h>
#import <UIKit/UIKit.h>

// 已知候选文件名前缀（大小写不敏感；白名单外一律无视）
static NSString * const ame296_prefixes[] = { @"privilegeplugin", @"dsplugin" };
#define AME296_PREFIX_COUNT 2

static BOOL ame296_selfRegistered = NO;   // 插件 constructor 自注册标记
static BOOL ame296_acquireAttempted = NO; // 单次挂载闸（进程级）

void privilege_plugin_self_register(void) {
    ame296_selfRegistered = YES;
    NSLog(@"[ame296] plugin constructor self-register observed");
}

@interface PrivilegePluginRegistry ()
@property (nonatomic, assign) PPHostState state;
@property (nonatomic, assign) pp_caps_t acquiredCaps;
@property (nonatomic, copy, nullable) NSString *lastError;
/// 已校验通过的插件句柄（dlopen 结果；同意前为 NULL）
@property (nonatomic, assign) void *pluginHandle;
/// 六函数指针（符号校验通过后填充）
@property (nonatomic, assign) int (*fnABI)(void);
@property (nonatomic, assign) pp_caps_t (*fnCaps)(void);
@property (nonatomic, assign) int (*fnSupported)(void);
@property (nonatomic, assign) int (*fnAcquire)(pp_caps_t, char *, int);
@property (nonatomic, assign) int (*fnStatus)(void);
@property (nonatomic, assign) void (*fnRelease)(void);
- (BOOL)userConsentedBool;
@end

@implementation PrivilegePluginRegistry

+ (instancetype)shared {
    static PrivilegePluginRegistry *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = PPHostStateAbsent;
        [self ame296_refreshState];
    }
    return self;
}

#pragma mark - 探测（无副作用 / 有副作用两档）

/// 文件存在 + Mach-O dylib 魔数校验（不执行任何代码）
+ (BOOL)ame296_fileLooksLikeDylib:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:sizeof(struct mach_header_64)];
    [fh closeFile];
    if (head.length < sizeof(struct mach_header_64)) return NO;
    struct mach_header_64 mh;
    memcpy(&mh, head.bytes, sizeof(mh));
    if (mh.magic != MH_MAGIC_64 && mh.magic != MH_CIGAM_64) return NO;
    if (mh.magic == MH_CIGAM_64) mh.filetype = OSSwapInt32(mh.filetype);
    return mh.filetype == MH_DYLIB;
}

/// 白名单扫描：返回第一个匹配的插件路径（bundle 根 + Frameworks/）
+ (NSString *)ame296_scanPluginPath {
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    NSArray<NSString *> *dirs = @[ bundle, [bundle stringByAppendingPathComponent:@"Frameworks"] ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            if (![item.pathExtension isEqualToString:@"dylib"]) continue;
            NSString *lower = item.lowercaseString;
            for (int i = 0; i < AME296_PREFIX_COUNT; i++) {
                if ([lower hasPrefix:ame296_prefixes[i]]) {
                    NSString *path = [dir stringByAppendingPathComponent:item];
                    if ([self ame296_fileLooksLikeDylib:path]) return path;
                }
            }
        }
    }
    return nil;
}

/// 刷新状态（卡片/诊断共用）。无同意时不 dlopen、不执行插件代码。
- (void)ame296_refreshState {
    // TrollStore 短路：no-sandbox 已足，插件整链路 no-op
    if (getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        self.state = PPHostStateTSFull;
        return;
    }
    NSString *path = [self.class ame296_scanPluginPath];
    if (!path && ame296_selfRegistered) {
        // 自注册在场但白名单未命中：仍按存在性展示，等同意后细查
        self.state = self.pluginHandle ? PPHostStateReady : PPHostStateNoConsent;
        return;
    }
    if (!path) {
        self.state = (self.pluginHandle || self.fnAcquire) ? PPHostStateReady : PPHostStateAbsent;
        return;
    }
    if ([self userConsentedBool]) {
        if ([self ame296_loadPluginAtPath:path]) {
            self.state = self.acquiredCaps ? PPHostStateAcquired : PPHostStateReady;
        } else {
            self.state = PPHostStateInvalid;
        }
    } else {
        self.state = PPHostStateNoConsent;
    }
}

- (BOOL)userConsentedBool {
    return [getPrefObject(@"privilege_plugin.enabled") boolValue];
}

/// dlopen + 六符号强校验（任一缺失即 invalid，dlclose 弃置）
- (BOOL)ame296_loadPluginAtPath:(NSString *)path {
    if (self.pluginHandle) return (self.fnABI != NULL);
    NSLog(@"[ame296] dlopen %@ (consent=ON)", path.lastPathComponent);
    void *h = dlopen(path.fileSystemRepresentation, RTLD_LOCAL | RTLD_LAZY);
    if (!h) {
        self.lastError = [NSString stringWithUTF8String:dlerror() ?: "dlopen failed"];
        NSLog(@"[ame296] dlopen failed: %@", self.lastError);
        return NO;
    }
    int (*abi)(void) = (int (*)(void))dlsym(h, "pp_plugin_abi_version");
    pp_caps_t (*caps)(void) = (pp_caps_t (*)(void))dlsym(h, "pp_plugin_capabilities");
    int (*supported)(void) = (int (*)(void))dlsym(h, "pp_plugin_environment_supported");
    int (*acquire)(pp_caps_t, char *, int) = (int (*)(pp_caps_t, char *, int))dlsym(h, "pp_plugin_acquire");
    int (*status)(void) = (int (*)(void))dlsym(h, "pp_plugin_status");
    void (*release)(void) = (void (*)(void))dlsym(h, "pp_plugin_release");
    if (!abi || !caps || !supported || !acquire || !status || !release) {
        NSLog(@"[ame296] symbol validation failed -- not a PP-ABI dylib");
        self.lastError = @"ABI symbols missing";
        dlclose(h);
        return NO;
    }
    if (abi() != PP_ABI_VERSION) {
        NSLog(@"[ame296] ABI mismatch: plugin=%d host=%d", abi(), PP_ABI_VERSION);
        self.lastError = @"ABI version mismatch";
        dlclose(h);
        return NO;
    }
    self.pluginHandle = h;
    self.fnABI = abi; self.fnCaps = caps; self.fnSupported = supported;
    self.fnAcquire = acquire; self.fnStatus = status; self.fnRelease = release;
    NSLog(@"[ame296] plugin loaded, caps=0x%llx", (unsigned long long)caps());
    return YES;
}

#pragma mark - 公开接口

- (BOOL)probePluginPresence {
    [self ame296_refreshState];
    return (self.state == PPHostStateNoConsent || self.state == PPHostStateReady ||
            self.state == PPHostStateAcquired || self.state == PPHostStateInvalid);
}

- (BOOL)userConsented {
    return [self userConsentedBool];
}

- (void)setUserConsented:(BOOL)on {
    setPrefObject(@"privilege_plugin.enabled", on ? @YES : @NO);
    NSLog(@"[ame296] user consent -> %@", on ? @"ON" : @"OFF");
    self.pluginHandle = NULL;
    [self ame296_refreshState];
}

- (NSString *)localizedStateSummary {
    switch (self.state) {
        case PPHostStateTSFull:    return localize(@"ame296.pp.state.ts", nil);
        case PPHostStateAbsent:    return localize(@"ame296.pp.state.absent", nil);
        case PPHostStateNoConsent: return localize(@"ame296.pp.state.noconsent", nil);
        case PPHostStateReady:     return localize(@"ame296.pp.state.ready", nil);
        case PPHostStateAcquired:  return localize(@"ame296.pp.state.acquired", nil);
        case PPHostStateFailed:    return localize(@"ame296.pp.state.failed", nil);
        case PPHostStateInvalid:   return localize(@"ame296.pp.state.invalid", nil);
    }
    return localize(@"ame296.pp.state.absent", nil);
}

- (void)acquireForGameSession {
    // 单次闸：本进程内绝不重试（内核态操作重试 = panic 风险，契约红线）
    if (ame296_acquireAttempted) {
        NSLog(@"[ame296] acquire skipped (already attempted this process)");
        return;
    }
    ame296_acquireAttempted = YES;
    [self ame296_refreshState];

    if (self.state == PPHostStateTSFull) {
        NSLog(@"[ame296] acquire skipped (no-sandbox already present)");
        return;
    }
    if (!self.userConsented) {
        NSLog(@"[ame296] acquire skipped (no consent)");
        return;
    }
    NSString *path = [self.class ame296_scanPluginPath];
    if (!path || ![self ame296_loadPluginAtPath:path]) {
        self.state = path ? PPHostStateInvalid : PPHostStateAbsent;
        NSLog(@"[ame296] acquire aborted (plugin %@)", path ? @"invalid" : @"absent");
        return;
    }
    if (self.fnSupported() != 1) {
        self.state = PPHostStateInvalid;
        self.lastError = localize(@"ame296.pp.err.unsupported", nil);
        NSLog(@"[ame296] acquire aborted (plugin reports unsupported environment: %d)", self.fnSupported());
        return;
    }
    pp_caps_t want = self.fnCaps() & (PP_CAP_FILESYSTEM | PP_CAP_IOKIT_GPU | PP_CAP_MEM_WALL);
    if (want == 0) {
        self.state = PPHostStateInvalid;
        self.lastError = localize(@"ame296.pp.err.nocaps", nil);
        NSLog(@"[ame296] acquire aborted (no consumable caps)");
        return;
    }

    NSLog(@"[ame296] acquire begin caps=0x%llx", (unsigned long long)want);
    char errBuf[512] = {0};
    int rc = self.fnAcquire(want, errBuf, sizeof(errBuf));
    if (rc == PP_ACQUIRE_OK && self.fnStatus() == PP_STATUS_ACQUIRED) {
        self.acquiredCaps = want;
        self.state = PPHostStateAcquired;
        NSLog(@"[ame296] acquire OK caps=0x%llx", (unsigned long long)want);
    } else {
        self.state = PPHostStateFailed;
        self.lastError = errBuf[0] ? [NSString stringWithUTF8String:errBuf]
                                   : [NSString stringWithFormat:@"rc=%d", rc];
        NSLog(@"[ame296] acquire FAILED rc=%d err=%@ -- continuing without plugin caps", rc, self.lastError);
    }
}

- (NSString *)lastError {
    return _lastError ?: @"";
}

@end
