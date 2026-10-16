//
//  AiFileTools.m
//  Prisma
//

#import "AiFileTools.h"
#import "LauncherPreferences.h"
#import "../utils.h"   // Task271-e：工具结果/错误文案 i18n 接线需要 localize()

static NSString * const kAiToolDomain = @"AiTool";

@interface AiFileTools ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiFileTools

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    if ([self.internalName isEqualToString:@"write_file"] || [self.internalName isEqualToString:@"edit_file"]) {
        return AiToolPermissionControlledWrite;
    }
    if ([self.internalName isEqualToString:@"delete_file"]) {
        return AiToolPermissionDangerousWrite;
    }
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"list_files"]) {
        return @"列出指定目录下的文件/子目录（不递归）。"
               "\n参数：path（string，可选，默认当前实例根目录）。"
               "\n返回 JSON 数组，每项含 name（名称）、type（file/dir）、size（字节）、modifiedUnixTS（修改时间戳），按名称排序。";
    }
    if ([self.internalName isEqualToString:@"read_file"]) {
        return @"读取文本文件内容。"
               "\n参数：path（string，必填）、maxChars（number，可选，默认 8000，超长截断）。"
               "\n返回文件文本内容；二进制文件返回「二进制文件不可读」。";
    }
    if ([self.internalName isEqualToString:@"grep_files"]) {
        return @"在文件中用正则表达式搜索匹配行。"
               "\n参数：path（string，可选，默认当前实例根目录）、pattern（string，必填，正则表达式）、"
               "recursive（boolean，可选，默认 NO）、maxResults（number，可选，默认 50）。"
               "\n返回 JSON 数组 {path, lineNumber, line}。";
    }
    if ([self.internalName isEqualToString:@"write_file"]) {
        return @"写文本文件（原子写入，自动创建父目录）。"
               "\n参数：path（string，必填）、content（string，必填）。"
               "\n返回「已写入（N 字符）」。覆盖已存在内容。";
    }
    if ([self.internalName isEqualToString:@"edit_file"]) {
        return @"精确替换文件中的一段文本。"
               "\n参数：path（string，必填）、oldText（string，必填）、newText（string，必填）。"
               "\n仅当 oldText 在文件中恰好出现 1 次时才替换，否则返回错误（出现 N 次）。";
    }
    if ([self.internalName isEqualToString:@"delete_file"]) {
        return @"删除文件（危险操作）。"
               "\n参数：path（string，必填）。"
               "\n出于安全考虑，仅允许删除文本类文件（.txt/.log/.json/.properties/.toml/.md/.cfg/.yml/.yaml/.xml/.xaml/.lang 等），不删除目录。"
               "\n返回「已删除」。";
    }
    return @"文件操作工具";
}

#pragma mark - 沙盒路径安全

/// 当前实例根目录（POJAV_GAME_DIR 或其回退）
+ (NSString *)currentGameRoot {
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return @(root);
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) {
        NSString *name = getPrefObject(@"general.game_directory");
        if (name.length == 0) name = @"default";
        return [NSString stringWithFormat:@"%s/instances/%@", home, name];
    }
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

/// 文件工具合法根目录：启动器目录（POJAV_HOME；未设置时回退 Documents 下的启动器目录，
/// 与 main.m 初始化逻辑一致——沙盒内即 Documents 本身，非沙盒为 Documents/AngelAuraAmethyst）。
/// instances/*（mods/saves/resourcepacks 等）均位于其下；
/// 经 realpath 归一化以匹配 POJAV_GAME_DIR 符号链接解析后的真实前缀，避免误判越界。
/// enhance-ai-agent Task 16：从「整个 App 沙盒」收紧为启动器目录，杜绝读写容器外文件。
+ (NSString *)sandboxRoot {
    NSString *root = nil;
    const char *homeEnv = getenv("POJAV_HOME");
    if (homeEnv && strlen(homeEnv) > 0) {
        root = @(homeEnv);
    } else {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        BOOL isNotSandboxed = [NSHomeDirectory().lastPathComponent isEqualToString:NSUserName()];
        root = isNotSandboxed ? [docs stringByAppendingPathComponent:@"AngelAuraAmethyst"] : docs;
    }
    if (root.length == 0) root = NSHomeDirectory();
    const char *rootStart = [root UTF8String];
    if (rootStart) {
        char *real = realpath(rootStart, NULL);
        if (real) {
            NSString *realRoot = @(real);
            free(real);
            return realRoot;
        }
    }
    return [root stringByStandardizingPath];
}

+ (nullable NSString *)resolveSafely:(NSString *)path {
    if (path.length == 0) return nil;
    NSString *stdRoot = [self sandboxRoot];

    BOOL usedGameDir = ([path rangeOfString:@"$GAMEDIR"].location != NSNotFound);
    NSString *worked = path;
    if (usedGameDir) {
        NSString *gameRoot = [self currentGameRoot];
        worked = [worked stringByReplacingOccurrencesOfString:@"$GAMEDIR" withString:(gameRoot.length ? gameRoot : stdRoot)];
    }

    NSString *joined;
    if (usedGameDir) {
        joined = worked; // 已被替换为物理绝对路径（在沙盒内）
    } else if ([worked hasPrefix:@"/"]) {
        // 绝对物理路径（可能是 getenv("POJAV_GAME_DIR") 直接返回的实例根，
        // 也可能是 /var/.../Documents/... 等沙盒内文件）。
        // 关键修复（list_files 越界）：此前把一切 "以 / 开头的路径" 都当作
        // "相对 Documents 拼接"，导致传入实例根的绝对路径被拼成 Documents/<容器绝对路径>，
        // 必然越界；也导致不给 path（默认取 currentGameRoot 绝对路径）时报越界。
        // 现在绝对路径原样使用，是否越界由下方基于容器根的检查统一裁决。
        joined = worked;
    } else {
        // 相对路径：相对当前实例根
        joined = [[self currentGameRoot] stringByAppendingPathComponent:worked];
    }

    // 标准化（去 ./ ..、解析符号链接），随后做沙盒越界检查
    NSString *std = [joined stringByResolvingSymlinksInPath];
    stdRoot = [stdRoot stringByResolvingSymlinksInPath];
    NSString *prefix = [stdRoot hasSuffix:@"/"] ? stdRoot : [stdRoot stringByAppendingString:@"/"];
    if (![std isEqualToString:stdRoot] && ![std hasPrefix:prefix]) {
        return nil; // 越界
    }
    return std;
}

#pragma mark - 执行分发

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([self.internalName isEqualToString:@"list_files"]) { [self performListFiles:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"read_file"])   { [self performReadFile:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"grep_files"])  { [self performGrepFiles:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"write_file"])  { [self performWriteFile:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"edit_file"])   { [self performEditFile:params completion:completion]; return; }
    if ([self.internalName isEqualToString:@"delete_file"]) { [self performDeleteFile:params completion:completion]; return; }

    NSError *err = [NSError errorWithDomain:kAiToolDomain code:404
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.tools.unknown_tool_fmt", nil), self.internalName]}];
    completion(nil, err);
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:kAiToolDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - list_files

- (void)performListFiles:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) path = [[self class] currentGameRoot];
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:localize(@"ai.tools.path_out_of_bounds", nil)]); return; }

    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resolved error:nil];
    if (!items) { completion(nil, [self errorWithCode:404 message:localize(@"ai.file.dir_not_found", nil)]); return; }

    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [resolved stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir]) continue;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
        long long size = isDir ? 0 : [attrs[NSFileSize] longLongValue];
        double ts = [attrs[NSFileModificationDate] timeIntervalSince1970];
        [entries addObject:@{
            @"name": name,
            @"type": isDir ? @"dir" : @"file",
            @"size": @(size),
            @"modifiedUnixTS": @(ts),
        }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    completion([self jsonStringFromObject:entries], nil);
}

#pragma mark - read_file

- (void)performReadFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:localize(@"ai.file.param_path_required", nil)]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:localize(@"ai.tools.path_out_of_bounds", nil)]); return; }

    NSUInteger maxChars = 8000;
    NSNumber *maxNum = params[@"maxChars"];
    if ([maxNum isKindOfClass:[NSNumber class]]) {
        NSInteger v = maxNum.integerValue;
        if (v > 0) maxChars = (NSUInteger)v;
    }

    NSData *data = [NSData dataWithContentsOfFile:resolved];
    if (!data) { completion(nil, [self errorWithCode:404 message:localize(@"ai.file.file_not_readable", nil)]); return; }

    // 二进制检测：包含 NUL 字节，或无法按 UTF-8 解码
    BOOL hasNull = [data rangeOfData:[NSData dataWithBytes:"\0" length:1] options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
    if (hasNull) { completion(localize(@"ai.file.binary_not_readable", nil), nil); return; }
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) {
        content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!content) { completion(localize(@"ai.file.binary_not_readable", nil), nil); return; }
    if (content.length > maxChars) {
        content = [NSString stringWithFormat:localize(@"ai.file.truncated_head_fmt", nil), (unsigned long)maxChars,
                   [content substringToIndex:maxChars]];
    }
    completion(content, nil);
}

#pragma mark - grep_files

- (void)performGrepFiles:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) path = [[self class] currentGameRoot];
    NSString *pattern = [params[@"pattern"] isKindOfClass:[NSString class]] ? params[@"pattern"] : nil;
    if (pattern.length == 0) { completion(nil, [self errorWithCode:400 message:localize(@"ai.file.pattern_required", nil)]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:localize(@"ai.tools.path_out_of_bounds", nil)]); return; }

    BOOL recursive = NO;
    NSNumber *recNum = params[@"recursive"];
    if ([recNum isKindOfClass:[NSNumber class]]) recursive = recNum.boolValue;

    NSUInteger maxResults = 50;
    NSNumber *maxNum = params[@"maxResults"];
    if ([maxNum isKindOfClass:[NSNumber class]] && maxNum.integerValue >= 0) maxResults = (NSUInteger)maxNum.integerValue;
    if (maxResults == 0) maxResults = 50;

    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&regexError];
    if (!regex) {
        completion(nil, [self errorWithCode:400 message:[NSString stringWithFormat:localize(@"ai.file.invalid_regex_fmt", nil), regexError.localizedDescription]]);
        return;
    }

    NSMutableArray *results = [NSMutableArray array];
    NSMutableArray *pendingDirs = [NSMutableArray arrayWithObject:resolved];
    NSFileManager *fm = [NSFileManager defaultManager];

    while (pendingDirs.count > 0 && results.count < maxResults) {
        NSString *dir = [pendingDirs lastObject];
        [pendingDirs removeLastObject];
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            if ([name hasPrefix:@"."]) continue;
            if (results.count >= maxResults) break;
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) {
                if (recursive) [pendingDirs addObject:full];
                continue;
            }
            NSData *data = [fm contentsAtPath:full];
            if (!data) continue;
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!text) continue;
            NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSUInteger lineNumber = 1;
            for (NSString *line in lines) {
                if (results.count >= maxResults) break;
                if ([regex numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)] > 0) {
                    [results addObject:@{
                        @"path": name,
                        @"lineNumber": @(lineNumber),
                        @"line": line,
                    }];
                }
                lineNumber++;
            }
        }
    }
    completion([self jsonStringFromObject:results], nil);
}

#pragma mark - write_file

- (void)performWriteFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    NSString *content = [params[@"content"] isKindOfClass:[NSString class]] ? params[@"content"] : @"";
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:localize(@"ai.file.param_path_required", nil)]); return; }
    if (![params[@"content"] isKindOfClass:[NSString class]]) {
        completion(nil, [self errorWithCode:400 message:localize(@"ai.file.param_content_required", nil)]); return;
    }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:localize(@"ai.tools.path_out_of_bounds", nil)]); return; }

    NSString *parentDir = [resolved stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) { completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:localize(@"ai.file.mkdir_failed_fmt", nil), dirError.localizedDescription]]); return; }

    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSError *writeError = nil;
    BOOL ok = [data writeToURL:[NSURL fileURLWithPath:resolved] options:NSDataWritingAtomic error:&writeError];
    if (!ok) {
        completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:localize(@"ai.file.write_failed_fmt", nil), writeError.localizedDescription]]);
        return;
    }
    completion([NSString stringWithFormat:localize(@"ai.file.written_fmt", nil), (unsigned long)content.length], nil);
}

#pragma mark - edit_file

- (void)performEditFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    NSString *oldText = [params[@"oldText"] isKindOfClass:[NSString class]] ? params[@"oldText"] : nil;
    NSString *newText = [params[@"newText"] isKindOfClass:[NSString class]] ? params[@"newText"] : @"";
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:localize(@"ai.file.param_path_required", nil)]); return; }
    if (oldText.length == 0) { completion(nil, [self errorWithCode:400 message:localize(@"ai.file.param_oldtext_required", nil)]); return; }
    if (![params[@"newText"] isKindOfClass:[NSString class]]) { completion(nil, [self errorWithCode:400 message:localize(@"ai.file.param_newtext_required", nil)]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:localize(@"ai.tools.path_out_of_bounds", nil)]); return; }

    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:resolved encoding:NSUTF8StringEncoding error:&readError];
    if (!content) { completion(nil, [self errorWithCode:404 message:localize(@"ai.file.read_failed", nil)]); return; }

    // 统计 oldText 出现次数
    NSUInteger occurrences = 0;
    NSRange searchRange = NSMakeRange(0, content.length);
    while (searchRange.location < content.length) {
        NSRange found = [content rangeOfString:oldText options:0 range:searchRange];
        if (found.location == NSNotFound) break;
        occurrences++;
        NSUInteger next = found.location + found.length;
        searchRange.location = next;
        searchRange.length = content.length - next;
    }
    if (occurrences != 1) {
        completion(nil, [self errorWithCode:422 message:[NSString stringWithFormat:localize(@"ai.file.oldtext_not_unique_fmt", nil), (unsigned long)occurrences]]);
        return;
    }

    NSString *newContent = [content stringByReplacingOccurrencesOfString:oldText withString:newText
                                                                 options:0 range:NSMakeRange(0, content.length)];
    NSData *data = [newContent dataUsingEncoding:NSUTF8StringEncoding];
    NSError *writeError = nil;
    if (![data writeToURL:[NSURL fileURLWithPath:resolved] options:NSDataWritingAtomic error:&writeError]) {
        completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:localize(@"ai.file.writeback_failed_fmt", nil), writeError.localizedDescription]]);
        return;
    }
    completion(localize(@"ai.file.modified", nil), nil);
}

#pragma mark - delete_file

/// 允许删除的文件扩展名白名单（文本类）
+ (NSSet<NSString *> *)deletableExtensions {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[@"txt", @"log", @"json", @"properties", @"toml", @"md", @"cfg",
                                     @"yml", @"yaml", @"xml", @"xaml", @"lang", @"ini", @"export",
                                     @"conf", @"gradle", @"fnf", @"more"]];
    });
    return set;
}

- (void)performDeleteFile:(NSDictionary *)params completion:(void(^)(NSString *, NSError *))completion {
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    if (path.length == 0) { completion(nil, [self errorWithCode:400 message:localize(@"ai.file.param_path_required", nil)]); return; }
    NSString *resolved = [[self class] resolveSafely:path];
    if (!resolved) { completion(nil, [self errorWithCode:403 message:localize(@"ai.tools.path_out_of_bounds", nil)]); return; }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:resolved isDirectory:&isDir]) {
        completion(nil, [self errorWithCode:404 message:localize(@"ai.file.file_not_found", nil)]); return;
    }
    if (isDir) {
        completion(nil, [self errorWithCode:403 message:localize(@"ai.file.dir_delete_denied", nil)]); return;
    }
    NSString *ext = [[resolved pathExtension] lowercaseString];
    if (![[[self class] deletableExtensions] containsObject:ext]) {
        completion(nil, [self errorWithCode:403 message:[NSString stringWithFormat:localize(@"ai.file.ext_delete_denied_fmt", nil), ext]]);
        return;
    }
    NSError *removeError = nil;
    if (![fm removeItemAtPath:resolved error:&removeError]) {
        completion(nil, [self errorWithCode:500 message:[NSString stringWithFormat:localize(@"ai.file.delete_failed_fmt", nil), removeError.localizedDescription]]);
        return;
    }
    completion(localize(@"ai.file.deleted", nil), nil);
}

#pragma mark - 工具

- (NSString *)jsonStringFromObject:(id)object {
    if (![NSJSONSerialization isValidJSONObject:object]) return @"[]";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return @"[]";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@end