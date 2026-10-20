#import "RegionGate.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import <objc/message.h>

// Task312：服务地区门。设计契约见 RegionGate.h 头注释。

#pragma mark - 检测角度

/// 角度 1：设备地区（强信号）。regionCode == "CN"。
static BOOL ame312_isCNRegion(void) {
    NSString *region = [NSLocale.currentLocale objectForKey:NSLocaleCountryCode];
    if (!region.length) region = NSLocale.currentLocale.regionCode;
    BOOL cn = [region isEqualToString:@"CN"];
    NSLog(@"[RegionGate] ame312: region=%@ -> cn=%d", region ?: @"(nil)", cn);
    return cn;
}

/// 角度 2：时区（中信号）。Asia/Shanghai / Asia/Urumqi 及历史别名。
static BOOL ame312_isCNTimezone(void) {
    NSString *tz = NSTimeZone.localTimeZone.name ?: @"";
    NSArray<NSString *> *cnZones = @[@"Asia/Shanghai", @"Asia/Urumqi", @"Asia/Chongqing",
                                     @"Asia/Harbin", @"Asia/Kashgar", @"PRC"];
    BOOL cn = [cnZones containsObject:tz];
    NSLog(@"[RegionGate] ame312: timezone=%@ -> cn=%d", tz, cn);
    return cn;
}

/// 角度 3：语言（中信号，仅互证不作独立判据）。
static BOOL ame312_isZhHansLanguage(void) {
    NSString *lang = NSLocale.preferredLanguages.firstObject ?: @"";
    BOOL cn = [lang hasPrefix:@"zh-Hans"] || [lang isEqualToString:@"zh-CN"] || [lang isEqualToString:@"zh"];
    NSLog(@"[RegionGate] ame312: language=%@ -> zhHans=%d", lang, cn);
    return cn;
}

/// 角度 4：运营商 MCC（强信号）。mobileCountryCode == "460"（中国大陆）。
/// CoreTelephony weak_framework 容错：类缺失/异常一律返回 NO，绝不带走启动。
static BOOL ame312_isCNCarrier(void) {
    BOOL cn = NO;
    @try {
        Class infoClass = NSClassFromString(@"CTTelephonyNetworkInfo");
        if (!infoClass) {
            NSLog(@"[RegionGate] ame312: CoreTelephony unavailable -> carrier=unknown");
            return NO;
        }
        id info = [[infoClass alloc] init];
        SEL serviceSEL = NSSelectorFromString(@"serviceSubscribersWithCellularProviders");
        NSDictionary<NSString *, id> *subscribers = nil;
        if ([info respondsToSelector:serviceSEL]) {
            // iOS 12+：serviceSubscribersWithCellularProviders（值为 CTCarrier）
            subscribers = ((NSDictionary<NSString *, id> * (*)(id, SEL))objc_msgSend)(info, serviceSEL);
        }
        if (!subscribers.count) {
            // iOS 11 及以下回退：subscriberCellularProvider
            SEL providerSEL = NSSelectorFromString(@"subscriberCellularProvider");
            if ([info respondsToSelector:providerSEL]) {
                id carrier = ((id (*)(id, SEL))objc_msgSend)(info, providerSEL);
                if (carrier) subscribers = @{ @"c": carrier };
            }
        }
        for (id carrier in subscribers.allValues) {
            SEL mccSEL = NSSelectorFromString(@"mobileCountryCode");
            if ([carrier respondsToSelector:mccSEL]) {
                NSString *mcc = ((NSString * (*)(id, SEL))objc_msgSend)(carrier, mccSEL);
                NSLog(@"[RegionGate] ame312: carrier mcc=%@", mcc ?: @"(nil)");
                if ([mcc isEqualToString:@"460"]) { cn = YES; break; }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[RegionGate] ame312: carrier probe failed (%@) -> ignore", e.name);
    }
    return cn;
}

/// 角度 5：IP 归属地（强信号，异步）。候选端点链式探测，全部失败不误伤。
static void ame312_ipProbeCountryCode(void (^done)(BOOL isCN, NSString *countryCode)) {
    // 三个免 key HTTPS 端点：country_code / countryCode 字段名各异，统一归一。
    NSArray<NSString *> *endpoints = @[
        @"https://ipapi.co/json/",
        @"https://ipwho.is/",
        @"https://freeipapi.com/api/json",
    ];
    __block void (^chain)(NSUInteger) = nil;
    chain = ^(NSUInteger idx) {
        if (idx >= endpoints.count) {
            NSLog(@"[RegionGate] ame312: ip probe all failed -> treat as unknown (no gate)");
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, nil); });
            return;
        }
        NSURL *url = [NSURL URLWithString:endpoints[idx]];
        NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url
                                                               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            NSString *code = nil;
            if (data && !error) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                code = json[@"country_code"] ?: json[@"countryCode"];
                if (![code isKindOfClass:NSString.class]) code = nil;
            }
            NSLog(@"[RegionGate] ame312: ip probe %@ -> %@ (%@)", url.host, code ?: @"(fail)",
                  error.localizedDescription ?: @"ok");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (code.length > 0) done([code isEqualToString:@"CN"], code);
                else chain(idx + 1);
            });
        }];
        [task resume];
    };
    chain(0);
}

#pragma mark - 呈现链（3 次提示后放行）

// ★ Task313：会话内兜底计数。Task312 的 confirm_count 曾因键未注册而
//   写入静默失败（PLPreferences "只写已注册键"设计），读恒 0 → 弹窗
//   永远卡 2/3。键注册已根修（PLPreferences.m regiongate section），
//   此内存计数再兜一层：只要用户在本次会话内点了 3 次，无论如何都
//   放行——持久化哪怕再因任何原因失效，门也绝不把人锁死。
static NSInteger ame312_fallbackCount = 0;

/// 当前有效确认次数 = max(持久化值, 会话内兜底值)。
static NSInteger ame312_effectiveCount(void) {
    NSInteger persisted = getPrefInt(@"regiongate.confirm_count");
    return (persisted > ame312_fallbackCount) ? persisted : ame312_fallbackCount;
}

/// 找最顶层可呈现 VC（异步补弹时 root 可能已被欢迎向导/主界面覆盖）。
static UIViewController *ame312_topmost(UIViewController *vc) {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

/// 第 index 次（1..3）确认弹窗。「退出」= exit(0)；「我不是大陆用户」= 计数 +1。
static void ame312_presentPrompt(UIViewController *base, NSInteger index, void (^finish)(void)) {
    UIViewController *host = ame312_topmost(base);
    NSString *ackKey = (index == 1) ? @"regiongate.ack1"
                     : (index == 2) ? @"regiongate.ack2"
                                    : @"regiongate.ack3";
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@",
                         localize(@"regiongate.message", nil),
                         localize(ackKey, nil)];
    UIAlertController *alert = [UIAlertController
                                alertControllerWithTitle:localize(@"regiongate.title", nil)
                                message:message
                                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"regiongate.exit", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) {
        NSLog(@"[RegionGate] ame312: user chose EXIT at prompt %ld -- terminating", (long)index);
        exit(0);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"regiongate.not_mainland", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        // Task313：以 effectiveCount（持久化 ∨ 内存兜底）为基准递增，
        // 持久化写入失败不再能卡死门（内存计数必然推进）。
        NSInteger count = ame312_effectiveCount() + 1;
        setPrefObject(@"regiongate.confirm_count", @(count)); // 尽力持久化
        ame312_fallbackCount = count;                        // 兜底必然生效
        NSLog(@"[RegionGate] ame312: 'not mainland' confirmed (%ld/3, persisted=%ld)",
              (long)count, (long)getPrefInt(@"regiongate.confirm_count"));
        if (count >= 3) {
            setPrefBool(@"regiongate.passed", YES);
            NSLog(@"[RegionGate] ame312: gate PASSED after %ld confirmations -- releasing", (long)count);
            finish();
        } else {
            ame312_presentPrompt(base, count + 1, finish);
        }
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

@implementation RegionGate

+ (void)runGateFromViewController:(UIViewController *)presenter
                       completion:(void (^)(void))completion {
    // 已放行（历史安装周期内已确认满 3 次）→ 零开销直通
    if (getPrefBool(@"regiongate.passed")) {
        NSLog(@"[RegionGate] ame312: already passed previously -> direct release");
        completion();
        return;
    }

    // —— 多角度同步检测 ——
    BOOL regionCN  = ame312_isCNRegion();
    BOOL tzCN      = ame312_isCNTimezone();
    BOOL langZh    = ame312_isZhHansLanguage();
    BOOL carrierCN = ame312_isCNCarrier();
    // 命中规则：强信号任一（地区 / 运营商），或 中信号组合互证（时区×语言）
    BOOL flagged = regionCN || carrierCN || (tzCN && langZh);
    NSInteger ame312_prevCount = ame312_effectiveCount();
    NSLog(@"[RegionGate] ame312: sync signals region=%d tz=%d lang=%d carrier=%d -> flagged=%d (prevCount=%ld)",
          regionCN, tzCN, langZh, carrierCN, flagged, (long)ame312_prevCount);

    void (^runPromptChain)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ame312_presentPrompt(presenter, ame312_prevCount + 1, completion);
        });
    };

    if (flagged) {
        runPromptChain();
        return;
    }

    // —— 异步兜底：IP 归属地探测（同步未命中时的第 5 角度）——
    // 仅当 IP==CN 且至少一个中/强信号互证时补弹（防旅行者/漫游误伤：
    // 纯 IP 命中无互证只记日志不上门）。
    completion();
    ame312_ipProbeCountryCode(^(BOOL isCN, NSString *countryCode) {
        BOOL corroborated = tzCN || langZh || carrierCN || regionCN;
        if (isCN && corroborated) {
            NSInteger count = ame312_effectiveCount();
            if (count >= 3) return; // 探测期间用户已在别处确认满，静默
            NSLog(@"[RegionGate] ame312: async ip=CN + corroboration -> late gate (count=%ld)", (long)count);
            ame312_presentPrompt(presenter, count + 1, ^{ /* 异步补弹不回串启动链 */ });
        }
    });
}

@end
