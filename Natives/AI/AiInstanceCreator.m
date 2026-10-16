//
//  AiInstanceCreator.m
//  Prisma
//

#import "AiInstanceCreator.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "../utils.h"   // Task271-e：结果/错误文案 i18n 接线需要 localize()

@implementation AiInstanceCreator

- (NSString *)name {
    return @"create_instance";
}

- (AiToolPermission)permission {
    return AiToolPermissionControlledWrite;
}

- (NSString *)summary {
    return @"新建游戏目录（实例）并切换为当前目录。"
           "\n参数：name（string，必填，目录名，推荐「MC版本 加载器 YYYY.MM.DD」格式，如「1.20.1 Fabric 2026.08.26」）、"
           "mcVersion（string，可选）、loader（string，可选）。"
           "\n行为：在 instances/ 下创建目录 → 切换当前游戏目录（重建符号链接）→ 注册并选中同名 profile。"
           "\n返回实例完整路径。后续 install_* 的 instance 参数传该目录名即可。"
           "\n边界：目录已存在时直接切换不报错（幂等）。";
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : @"";
    if (name.length == 0) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.instance.param_name_required", nil)}]);
        return;
    }
    // 目录名安全化：去掉路径分隔符（与 VersionManagerViewController 创建目录一致直接拼接，
    // 这里额外剥离分隔符防止「../」逃逸出 instances/）
    NSArray *parts = [name componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@"/\\:"]];
    name = [parts componentsJoinedByString:@"_"];
    if (name.length == 0) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.instance.name_invalid", nil)}]);
        return;
    }

    const char *homeEnv = getenv("POJAV_HOME");
    NSString *home = (homeEnv && strlen(homeEnv) > 0) ? [NSString stringWithUTF8String:homeEnv] : nil;
    if (home.length == 0) {
        home = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    }

    // 1. 创建实例目录（幂等）
    NSString *instancePath = [home stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"instances/%@", name]];
    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:instancePath
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&dirError]) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:500
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:localize(@"ai.instance.mkdir_failed_fmt", nil), dirError.localizedDescription ?: localize(@"resman.common.unknown_error", nil)]}]);
        return;
    }

    // 2. 切换当前游戏目录（复刻 LauncherPrefGameDirViewController.changeSelectionTo / VersionManagerViewController.switchGameDirTo）
    setPrefObject(@"general.game_directory", name);
    const char *gameDirEnv = getenv("POJAV_GAME_DIR");
    NSString *lasmPath = (gameDirEnv && strlen(gameDirEnv) > 0) ? [NSString stringWithUTF8String:gameDirEnv] : nil;
    if (lasmPath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:lasmPath error:nil];
        NSError *linkError = nil;
        BOOL linkOK = [[NSFileManager defaultManager] createSymbolicLinkAtPath:lasmPath
                                                         withDestinationPath:instancePath
                                                                       error:&linkError];
        if (!linkOK) {
            completion(nil, [NSError errorWithDomain:@"AiTool" code:500
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:localize(@"ai.instance.symlink_failed_fmt", nil), linkError.localizedDescription ?: localize(@"resman.common.unknown_error", nil)]}]);
            return;
        }
        [[NSFileManager defaultManager] changeCurrentDirectoryPath:lasmPath];
    }
    toggleIsolatedPref(NO);
    [PLProfiles updateCurrent];

    // 3. 注册并选中同名 profile（mcVersion/loader 仅作备注写入 userInfo 字段）
    NSMutableDictionary *prof = [[PLProfiles current].profiles[name] mutableCopy];
    if (!prof) prof = [NSMutableDictionary dictionary];
    if (!prof[@"name"]) prof[@"name"] = name;
    if (!prof[@"gameDir"]) prof[@"gameDir"] = @".";
    prof[@"type"] = @"custom";
    prof[@"created"] = [[NSDate date] description];
    NSString *mcVersion = [params[@"mcVersion"] isKindOfClass:[NSString class]] ? params[@"mcVersion"] : @"";
    NSString *loader = [params[@"loader"] isKindOfClass:[NSString class]] ? params[@"loader"] : @"";
    if (mcVersion.length > 0) prof[@"aiMcVersion"] = mcVersion;
    if (loader.length > 0) prof[@"aiLoader"] = loader;
    [[PLProfiles current] saveProfile:prof withName:name];
    [PLProfiles current].selectedProfileName = name;

    // 4. 广播刷新
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];

    NSString *note = @"";
    if (mcVersion.length > 0 || loader.length > 0) {
        note = [NSString stringWithFormat:localize(@"ai.instance.note_fmt", nil),
                mcVersion.length > 0 ? mcVersion : localize(@"ai.instance.unspecified", nil), loader.length > 0 ? loader : localize(@"ai.instance.no_loader", nil)];
    }
    completion([NSString stringWithFormat:localize(@"ai.instance.created_fmt", nil),
                name, instancePath, note], nil);
}

@end
