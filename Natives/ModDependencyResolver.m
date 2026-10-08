//
//  ModDependencyResolver.m
//  模组依赖（前置）自动解析
//
//  依赖字段结构（两侧不同，此处统一归一化）：
//
//    Modrinth  GET /project/{id}/version 的每一项：
//      "dependencies": [
//        { "version_id": "xxx", "project_id": "yyy",
//          "file_name": null, "dependency_type": "required" }
//      ]
//      dependency_type ∈ required / optional / incompatible / embedded
//
//    CurseForge GET /mods/{id}/files/{fid} 的 data：
//      "dependencies": [ { "modId": 394468, "relationType": 3 } ]
//      relationType: 1=Embedded 2=Optional 3=Required 4=Tool
//                    5=Incompatible 6=Include
//
//  只自动安装 required；optional 收集起来交给 UI 提示。incompatible /
//  embedded / tool 不处理（前者是冲突声明，后两者随包自带或非模组）。
//
//  Task227 移植说明：上游 bc5ce914bc + 7df2a696（sharedAPI→本仓
//  sharedInstance）+ 5f58492/CMake（本仓 Natives 为 folder 引用无需注册）
//  + c479738（import 子目录前缀已带）。
//

#import "ModDependencyResolver.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"

/// 同时进行的前置查询数。ZL2 用 4，这里保持一致：
/// 太低会让链式依赖解析很慢，太高容易触发源站限流。
static const NSInteger kMaxConcurrentLookups = 4;

/// 最多解析多少个项目。ZL2 的 MAX_DEPENDENCY_PROJECTS = 64。
/// 超出即停止并在 plan.truncated 里列出，避免恶意/异常的依赖图把
/// 启动器拖死（环形依赖也靠这个上限兜底）。
static const NSInteger kMaxProjects = 64;

/// 最大解析深度。正常模组链很少超过 6 层，超出视为异常依赖图。
static const NSInteger kMaxDepth = 8;

#pragma mark -

@implementation ModDependencyItem
- (NSString *)description {
    return [NSString stringWithFormat:@"<ModDependencyItem src=%ld project=%@ kind=%ld>",
            (long)self.apiSource, self.projectId ?: @"?", (long)self.kind];
}
@end

#pragma mark -

@implementation ModDependencyPlan
- (instancetype)init {
    if ((self = [super init])) {
        _required = @[];
        _optional = @[];
        _skippedAlreadyInstalled = @[];
        _truncated = @[];
    }
    return self;
}
@end

#pragma mark -

@interface ModDependencyResolver ()
@property(nonatomic, strong) dispatch_queue_t stateQueue;   /* 保护 visited/collected */
@property(nonatomic, strong) NSMutableSet<NSString *> *visitedKeys;
@property(nonatomic, strong) NSMutableArray<ModDependencyItem *> *collectedRequired;
@property(nonatomic, strong) NSMutableArray<ModDependencyItem *> *collectedOptional;
@property(nonatomic, strong) NSMutableArray<NSString *> *truncatedIds;
@end

@implementation ModDependencyResolver

+ (instancetype)sharedResolver {
    static ModDependencyResolver *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ModDependencyResolver alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _stateQueue = dispatch_queue_create("ame.mod.dependency.resolver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - 入口

- (void)resolveDependenciesFromVersionDetail:(NSDictionary *)versionDetail
                                   apiSource:(NSInteger)apiSource
                        installedProjectIds:(NSSet<NSString *> *)installedProjectIds
                                      loader:(NSString *)loader
                                 gameVersion:(NSString *)gameVersion
                                  completion:(void (^)(ModDependencyPlan *, NSError *))completion {
    if (!completion) return;

    if (![versionDetail isKindOfClass:[NSDictionary class]]) {
        // 没有版本详情时不要报错阻塞下载，给空计划即可。
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([[ModDependencyPlan alloc] init], nil);
        });
        return;
    }

    // 每次解析重置状态。resolver 是单例，但解析过程是「一次调用一批」，
    // 不共享状态；若将来要并发解析多个主模组，需要改成实例化而非单例。
    self.visitedKeys = [NSMutableSet new];
    self.collectedRequired = [NSMutableArray new];
    self.collectedOptional = [NSMutableArray new];
    self.truncatedIds = [NSMutableArray new];

    NSSet<NSString *> *installed = installedProjectIds ?: [NSSet set];
    NSString *key = [self dependencyKeyForProjectId:[self projectIdFromVersionDetail:versionDetail apiSource:apiSource]];
    if (key) [self.visitedKeys addObject:key];   // 主模组自身也标记，防止依赖环回到自己

    [self expandFromVersionDetail:versionDetail
                        apiSource:apiSource
                       installed:installed
                           loader:loader
                      gameVersion:gameVersion
                            depth:0
                       completion:^(NSError *error) {
        ModDependencyPlan *plan = [[ModDependencyPlan alloc] init];
        plan.required = [self.collectedRequired copy];
        plan.optional = [self.collectedOptional copy];
        plan.skippedAlreadyInstalled = [installed.allObjects copy];
        plan.truncated = [self.truncatedIds copy];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(plan, error); });
    }];
}

#pragma mark - 递归展开

/// 从一份版本详情取出直接依赖，逐个处理（必要时继续向下展开）。
- (void)expandFromVersionDetail:(NSDictionary *)detail
                      apiSource:(NSInteger)apiSource
                     installed:(NSSet<NSString *> *)installed
                         loader:(NSString *)loader
                    gameVersion:(NSString *)gameVersion
                          depth:(NSInteger)depth
                     completion:(void (^)(NSError *))completion {
    if (depth >= kMaxDepth) {
        [self noteTruncated:@"(max depth reached)"];
        completion(nil);
        return;
    }
    if (self.collectedRequired.count >= (NSUInteger)kMaxProjects) {
        [self noteTruncated:@"(max project count reached)"];
        completion(nil);
        return;
    }

    NSArray<ModDependencyItem *> *direct = [self parseDependenciesFromDetail:detail apiSource:apiSource];
    if (direct.count == 0) {
        completion(nil);
        return;
    }

    // 逐个处理：已访问/已安装的跳过，新项目入队后按需继续展开版本详情。
    NSMutableArray<ModDependencyItem *> *toProcess = [NSMutableArray new];
    for (ModDependencyItem *dep in direct) {
        NSString *depKey = [self dependencyKeyForProjectId:dep.projectId];
        if (depKey == nil) continue;

        @synchronized (self.visitedKeys) {
            if ([self.visitedKeys containsObject:depKey]) continue;   // 环 / 重复
            [self.visitedKeys addObject:depKey];
        }
        if (dep.projectId.length > 0 && [installed containsObject:dep.projectId]) {
            continue;   // 已安装同项目（任一版本）→ 不重复装
        }
        if (dep.kind == ModDependencyKindRequired) {
            @synchronized (self.collectedRequired) {
                [self.collectedRequired addObject:dep];
            }
        } else {
            @synchronized (self.collectedOptional) {
                [self.collectedOptional addObject:dep];
            }
        }
        if (dep.kind == ModDependencyKindRequired) [toProcess addObject:dep];
    }

    if (toProcess.count == 0) {
        completion(nil);
        return;
    }

    // 并发上限：分批查版本详情。
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t sem = dispatch_semaphore_create(kMaxConcurrentLookups);
    __block NSError *firstError = nil;

    for (ModDependencyItem *dep in toProcess) {
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        dispatch_group_enter(group);
        [self fetchVersionDetailForDependency:dep
                                       loader:loader
                                  gameVersion:gameVersion
                                   completion:^(NSDictionary *detail2, NSError *error) {
            if (error && firstError == nil) firstError = error;
            if ([detail2 isKindOfClass:[NSDictionary class]]) {
                // 继续向下展开。用同一把信号量串行化，深度由 depth+1 控制。
                [self expandFromVersionDetail:detail2
                                    apiSource:dep.apiSource
                                   installed:installed
                                       loader:loader
                                  gameVersion:gameVersion
                                        depth:depth + 1
                                   completion:^(NSError *e2) {
                    if (e2 && firstError == nil) firstError = e2;
                    dispatch_semaphore_signal(sem);
                    dispatch_group_leave(group);
                }];
            } else {
                dispatch_semaphore_signal(sem);
                dispatch_group_leave(group);
            }
        }];
    }

    dispatch_group_notify(group, self.stateQueue, ^{
        completion(firstError);
    });
}

#pragma mark - 取依赖

/// 从版本详情里取出直接依赖（归一化两种源的字段）。
- (NSArray<ModDependencyItem *> *)parseDependenciesFromDetail:(NSDictionary *)detail apiSource:(NSInteger)apiSource {
    NSMutableArray<ModDependencyItem *> *out = [NSMutableArray new];
    id deps = detail[@"dependencies"];
    if (![deps isKindOfClass:[NSArray class]]) return out;

    // Task229 (defense in depth for feedback #4): apiSource arriving as 0
    // (unset) routes Modrinth payloads into the CurseForge branch below --
    // exactly the Task229-E1 root cause. E1 fixes the producer; this sniff
    // guards against any future producer forgetting the flag: if the caller
    // did not declare Modrinth (1), inspect the first dependency entry's
    // shape -- Modrinth entries carry "project_id" / "dependency_type" keys,
    // CurseForge entries carry "modId" / "relationType".
    if (apiSource != 1) {
        for (id ame229_probe in (NSArray *)deps) {
            if (![ame229_probe isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *ame229_d = ame229_probe;
            BOOL ame229_mrShape = (ame229_d[@"project_id"] != nil ||
                                   ame229_d[@"dependency_type"] != nil);
            BOOL ame229_cfShape = (ame229_d[@"modId"] != nil ||
                                   ame229_d[@"relationType"] != nil);
            if (ame229_mrShape && !ame229_cfShape) {
                apiSource = 1;
            }
            break;   // one entry is enough to decide
        }
    }

    for (id raw in (NSArray *)deps) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = raw;
        ModDependencyItem *item = [[ModDependencyItem alloc] init];
        item.apiSource = apiSource;

        if (apiSource == 1) {
            // Modrinth
            item.projectId = [d[@"project_id"] isKindOfClass:[NSString class]] ? d[@"project_id"] : nil;
            item.versionId = [d[@"version_id"] isKindOfClass:[NSString class]] ? d[@"version_id"] : nil;
            NSString *type = [d[@"dependency_type"] isKindOfClass:[NSString class]] ? d[@"dependency_type"] : @"";
            if ([type isEqualToString:@"required"]) {
                item.kind = ModDependencyKindRequired;
            } else if ([type isEqualToString:@"optional"]) {
                item.kind = ModDependencyKindOptional;
            } else {
                continue;   // incompatible / embedded / 未知 → 不处理
            }
            // Modrinth 有时只给 version_id 不给 project_id，此时无法按项目去重，
            // 也无法查可选版本；跳过而不是瞎猜。
            if (item.projectId.length == 0) continue;
        } else {
            // CurseForge：modId 是数字，relationType 是枚举
            id modId = d[@"modId"];
            if (![modId respondsToSelector:@selector(description)]) continue;
            item.projectId = [modId description];
            NSInteger rel = [d[@"relationType"] integerValue];
            if (rel == 3) {
                item.kind = ModDependencyKindRequired;
            } else if (rel == 2) {
                item.kind = ModDependencyKindOptional;
            } else {
                continue;   // 1=Embedded 4=Tool 5=Incompatible 6=Include
            }
        }
        [out addObject:item];
    }
    return out;
}

#pragma mark - 查版本详情

/// 拉某个依赖项目的「可用版本详情」，用于继续向下解析。
/// 优先用 versionId 直取（Modrinth），否则按 loader/gameVersion 过滤取最新。
- (void)fetchVersionDetailForDependency:(ModDependencyItem *)dep
                                 loader:(NSString *)loader
                            gameVersion:(NSString *)gameVersion
                             completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!completion) return;

    // 两个源都用 getVersionsForModWithID:（已存在），拿到 ModVersion 列表后
    // 挑一个与本实例兼容的，取其 rawDictionary 作为 version detail 继续展开。
    void (^handle)(NSArray<ModVersion *> *, NSError *) = ^(NSArray<ModVersion *> *versions, NSError *error) {
        if (error || versions.count == 0) {
            completion(nil, error);
            return;
        }
        ModVersion *picked = nil;
        // 优先精确匹配 gameVersions + loaders；都不匹配时退回第一个版本
        // （宁可多装一个可能不兼容的前置，也好过整条依赖链断掉不提示）。
        for (ModVersion *v in versions) {
            if (gameVersion.length > 0 && ![v.gameVersions containsObject:gameVersion]) continue;
            if (loader.length > 0 && v.loaders.count > 0) {
                NSString *lowered = loader.lowercaseString;
                BOOL loaderOK = NO;
                for (NSString *l in v.loaders) {
                    if ([[l lowercaseString] containsString:lowered] ||
                        [lowered containsString:[l lowercaseString]]) { loaderOK = YES; break; }
                }
                if (!loaderOK) continue;
            }
            picked = v;
            break;
        }
        if (picked == nil) picked = versions.firstObject;
        completion(picked.rawDictionary, nil);
    };

    if (dep.apiSource == 1) {
        [[ModrinthAPI sharedInstance] getVersionsForModWithID:dep.projectId completion:handle];
    } else {
        [[CurseForgeAPI sharedInstance] getVersionsForModWithID:dep.projectId completion:handle];
    }
}

#pragma mark - 工具

- (NSString *)dependencyKeyForProjectId:(NSString *)projectId {
    if (projectId.length == 0) return nil;
    return projectId;
}

- (NSString *)projectIdFromVersionDetail:(NSDictionary *)detail apiSource:(NSInteger)apiSource {
    id pid = detail[@"project_id"];
    if ([pid isKindOfClass:[NSString class]] && [pid length] > 0) return pid;
    // Modrinth 的 version 详情里项目 id 也可能只在 "project_id"；
    // CurseForge 的文件详情用 "modId"。
    id modId = detail[@"modId"];
    if ([modId respondsToSelector:@selector(description)]) return [modId description];
    return nil;
}

- (void)noteTruncated:(NSString *)what {
    @synchronized (self.truncatedIds) {
        [self.truncatedIds addObject:what];
    }
}

@end
