//
//  AiProviderStore.m
//  Prisma
//

#import "AiProviderStore.h"

@implementation AiProviderStore {
    NSMutableArray<AiProvider *> *_providers;
    BOOL _loaded;
}

static NSString * const kSelectedProviderIdKey = @"ai.selected_provider_id";

+ (instancetype)sharedStore {
    static AiProviderStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiProviderStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _providers = [NSMutableArray array];
        _loaded = NO;
    }
    return self;
}

#pragma mark - 文件路径

/// Application Support/AI/ 目录路径（不存在则创建）。
/// ★ Task275（E-P2-7）：providers.json（含 apiKey）从 Documents/AI 迁出——
/// Info.plist 开了 UIFileSharingEnabled，Documents 经 USB/文件 App 直接可读
/// = 唯一明文外露的密钥（Task131 第三方凭据已上 Keychain 的纪律对齐）。
/// 旧路径一次性迁移（仅 providers.json；sessions.json 属 AiSessionStore 自管）。
- (NSString *)aiDirectoryPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *baseDir = [paths firstObject] ?: [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *aiDir = [baseDir stringByAppendingPathComponent:@"AI"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:aiDir]) {
        [fm createDirectoryAtPath:aiDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // 一次性迁移：旧 Documents/AI/providers.json → 新目录（新目录已有则清除外露副本）
    NSString *ame275_legacy = [[[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
        stringByAppendingPathComponent:@"AI"] stringByAppendingPathComponent:@"providers.json"];
    if ([fm fileExistsAtPath:ame275_legacy]) {
        NSString *ame275_modern = [aiDir stringByAppendingPathComponent:@"providers.json"];
        if (![fm fileExistsAtPath:ame275_modern]) {
            NSError *ame275_mvErr = nil;
            if ([fm moveItemAtPath:ame275_legacy toPath:ame275_modern error:&ame275_mvErr]) {
                NSLog(@"[AiProviderStore] Task275: providers.json migrated out of file-sharing-visible Documents (apiKey hardening)");
            } else {
                NSLog(@"[AiProviderStore] Task275: legacy providers.json move failed (%@) -- re-migrates next launch", ame275_mvErr.localizedDescription);
            }
        } else {
            [fm removeItemAtPath:ame275_legacy error:nil];
            NSLog(@"[AiProviderStore] Task275: stale exposed providers.json copy removed (modern copy present)");
        }
    }
    return aiDir;
}

- (NSString *)filePath {
    return [[self aiDirectoryPath] stringByAppendingPathComponent:@"providers.json"];
}

#pragma mark - 预设

+ (NSArray<NSDictionary *> *)defaultPresets {
    return @[
        @{
            @"name": @"DeepSeek",
            @"baseURL": @"https://api.deepseek.com/v1",
            @"model": @"deepseek-chat",
            @"apiKey": @"",
        },
        @{
            @"name": @"OpenAI",
            @"baseURL": @"https://api.openai.com/v1",
            @"model": @"gpt-4o-mini",
            @"apiKey": @"",
        },
        @{
            @"name": @"Ollama",
            @"baseURL": @"http://127.0.0.1:11434/v1",
            @"model": @"llama3",
            // 提示用户：Ollama 需在本机/同一局域网设备上运行服务
            @"apiKey": @"",
        },
    ];
}

#pragma mark - 加载 / 保存

- (NSMutableArray<AiProvider *> *)providers {
    [self loadIfNeeded];
    return _providers;
}

- (void)loadIfNeeded {
    if (_loaded) return;
    _loaded = YES;

    NSString *path = [self filePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSError *error = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [obj isKindOfClass:[NSArray class]]) {
            [_providers removeAllObjects];
            for (NSDictionary *dict in obj) {
                AiProvider *provider = [AiProvider providerWithDictionary:dict];
                if (provider) [_providers addObject:provider];
            }
            return;
        }
    }
    // 文件不存在或解析失败：用预设播种
    if (_providers.count == 0) {
        for (NSDictionary *dict in [[self class] defaultPresets]) {
            AiProvider *provider = [AiProvider providerWithDictionary:dict];
            if (provider) [_providers addObject:provider];
        }
        [self save];
    }
}

- (void)save {
    NSMutableArray *array = [NSMutableArray array];
    for (AiProvider *provider in _providers) {
        [array addObject:[provider toDictionary]];
    }
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:array options:NSJSONWritingPrettyPrinted error:&error];
    if (json && !error) {
        [json writeToFile:[self filePath] options:NSDataWritingAtomic error:nil];
    }
}

#pragma mark - CRUD

- (void)addProvider:(AiProvider *)provider {
    if (!provider) return;
    [_providers addObject:provider];
    [self save];
}

- (void)updateProvider:(AiProvider *)provider {
    if (!provider) return;
    for (NSInteger i = 0; i < _providers.count; i++) {
        if ([[_providers[i] identifier] isEqualToString:provider.identifier]) {
            _providers[i] = provider;
            break;
        }
    }
    [self save];
}

- (void)deleteProvider:(AiProvider *)provider {
    if (!provider) return;
    [_providers removeObject:provider];
    // 若删除的是当前选中项，清除选中
    if ([self.selectedProvider.identifier isEqualToString:provider.identifier]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedProviderIdKey];
    }
    [self save];
}

- (nullable AiProvider *)providerById:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    [self loadIfNeeded];
    for (AiProvider *provider in _providers) {
        if ([provider.identifier isEqualToString:identifier]) {
            return provider;
        }
    }
    return nil;
}

- (nullable AiProvider *)selectedProvider {
    // 关键修复（重启后误报"未配置供应商"）：必须先从磁盘加载 providers，
    // 否则启动早期 _providers 为空，providerById 恒返回 nil，导致空态误提示"未配置"。
    [self loadIfNeeded];
    NSString *sid = [[NSUserDefaults standardUserDefaults] stringForKey:kSelectedProviderIdKey];
    return [self providerById:sid];
}

- (void)setSelectedProvider:(AiProvider *)provider {
    [self loadIfNeeded];
    if (provider) {
        [[NSUserDefaults standardUserDefaults] setObject:provider.identifier forKey:kSelectedProviderIdKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedProviderIdKey];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end