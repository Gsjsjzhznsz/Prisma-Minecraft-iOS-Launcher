#import "ModVersion.h"
#import "PLMirrorCenter.h"

@interface ModVersion ()
- (instancetype)parseCurseForgeDictionary:(NSDictionary *)dictionary;
@end

@implementation ModVersion

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        if (![dictionary isKindOfClass:[NSDictionary class]]) {
            return nil;
        }

        // CurseForge file 格式适配（识别 gameVersions/downloadUrl/fileLength/fileDate/id/modId 字段）
        if (dictionary[@"gameVersions"] != nil && dictionary[@"downloadUrl"] != nil) {
            return [self parseCurseForgeDictionary:dictionary];
        }

        _name = [dictionary[@"name"] isKindOfClass:[NSString class]] ? dictionary[@"name"] : @"Unknown Name";
        _versionNumber = [dictionary[@"version_number"] isKindOfClass:[NSString class]] ? dictionary[@"version_number"] : @"Unknown Version";
        _datePublished = [dictionary[@"date_published"] isKindOfClass:[NSString class]] ? dictionary[@"date_published"] : @"";
        _gameVersions = [dictionary[@"game_versions"] isKindOfClass:[NSArray class]] ? dictionary[@"game_versions"] : @[];
        _loaders = [dictionary[@"loaders"] isKindOfClass:[NSArray class]] ? dictionary[@"loaders"] : @[];
        // 发布类型（Modrinth: release/beta/alpha）
        _versionType = [dictionary[@"version_type"] isKindOfClass:[NSString class]] ? dictionary[@"version_type"] : @"release";

        NSArray *files = [dictionary[@"files"] isKindOfClass:[NSArray class]] ? dictionary[@"files"] : @[];
        _primaryFile = [files firstObject];
        // ★ Task227：原始字典留存（dependencies[] 只在原文里——两个源都是）
        _rawDictionary = [dictionary copy];
    }
    return self;
}

- (instancetype)parseCurseForgeDictionary:(NSDictionary *)dictionary {
    _apiSource = 2; // CurseForge
    // 文件名
    NSString *fileName = dictionary[@"fileName"];
    // 发布类型（CurseForge: 1=release, 2=beta, 3=alpha）
    NSInteger releaseType = [dictionary[@"releaseType"] integerValue];
    if (releaseType == 2) {
        _versionType = @"beta";
    } else if (releaseType == 3) {
        _versionType = @"alpha";
    } else {
        _versionType = @"release";
    }
    // 文件大小
    if (dictionary[@"fileLength"]) {
        _fileSize = dictionary[@"fileLength"];
    }
    // 发布时间（fileDate 格式：ISO8601，存储为字符串以与 Modrinth 路径保持一致）
    NSString *dateStr = dictionary[@"fileDate"];
    if (dateStr) {
        _datePublished = dateStr;
    }
    // file ID 和 project ID
    _fileId = [dictionary[@"id"] stringValue];
    _projectId = [dictionary[@"modId"] stringValue];
    // gameVersions 数组（包含游戏版本和加载器）
    NSArray *gameVersions = dictionary[@"gameVersions"];
    NSString *gameVer = nil;
    NSMutableArray *loaders = [NSMutableArray array];
    NSMutableArray *gameVerArr = [NSMutableArray array];
    for (NSString *v in gameVersions) {
        // Task181（CF 资源详细页加载器筛选过滤光根修）：
        // 病历（afa23a6 装机，用户实测"需要在资源详细页点加载器中的全部
        // 才能显示资源"）：CF 的 gameVersions 里加载器标签是首字母大写
        // 原文（"Fabric"/"Forge"/...），旧代码原样存储；而
        // ModVersionViewController 的筛选比较用
        // [loaders containsObject:selectedLoader.lowercaseString]（"fabric"）
        // ——containsObject 精确比较，"Fabric" != "fabric" → CF 源下选中
        // 任何加载器都会过滤掉【全部】文件，只有"全部"chip 能显示。
        // Modrinth 的 loaders 字段本就是小写，所以 Modrinth 源正常。
        // 修法：统一小写存储（显示层 processFilters 会 capitalizedString，
        // preferred 置顶比较也是 lowercaseString，两处同时恢复）；
        // 顺手补 LiteLoader 前缀（老 CF 文件带此标签，否则会漏进版本 chips）。
        if ([v hasPrefix:@"Fabric"] || [v hasPrefix:@"Forge"] || [v hasPrefix:@"NeoForge"] ||
            [v hasPrefix:@"Quilt"] || [v hasPrefix:@"LiteLoader"]) {
            [loaders addObject:[v lowercaseString]];
        } else if ([v containsString:@"."]) {
            if (gameVer == nil) {
                gameVer = v;
            }
            [gameVerArr addObject:v];
        }
    }
    _gameVersions = [gameVerArr copy];
    _loaders = [loaders copy];
    _name = [NSString stringWithFormat:@"%@ (%@)", fileName ?: @"", gameVer ?: @""];
    _versionNumber = _fileId;
    // hashes（algo 1 = SHA1）
    NSString *sha1 = nil;
    NSArray *hashes = dictionary[@"hashes"];
    for (NSDictionary *h in hashes) {
        if ([h[@"algo"] integerValue] == 1) {
            sha1 = h[@"value"];
        }
    }
    // 构造 primaryFile 以兼容 Modrinth 格式读取（url/filename/hashes）
    NSMutableDictionary *pf = [NSMutableDictionary dictionary];
    if (dictionary[@"downloadUrl"]) {
        // Task173：CF 下载 URL 镜像解析（整合包 CF 源不可用的根因）。
        // ModrinthAPI 的 MRAMirrorResolvedURL 一直在做这件事（cdn.modrinth.com → MCIM
        // 镜像），CF 路径漏了：raw edge.forgecdn.net 在镜像策略开启
        // 的设备上不可达 → 模组/整合包版本丰页下载全挂（搜索/版本
        // 列表都是好的）。与 CurseForgeAPI.downloadURLForFile 同款
        // （PLMirrorCenter AssetDownload 策略：forgecdn → MCIM 镜像；官方优先档不重写）。
        NSString *ame173_url = [PLMirrorCenter preferredURLForOriginalURL:
            [NSURL URLWithString:dictionary[@"downloadUrl"]]
            resourceType:PLMirrorResourceTypeAssetDownload].absoluteString;
        pf[@"url"] = ame173_url ?: dictionary[@"downloadUrl"];
    }
    if (fileName) {
        pf[@"filename"] = fileName;
    }
    pf[@"primary"] = @(YES);
    if (sha1) {
        pf[@"hashes"] = @{ @"sha1": sha1 };
    }
    _primaryFile = [pf copy];
        // ★ Task227：原始字典留存（CF 的 dependencies[] 在原文里）
    _rawDictionary = [dictionary copy];
return self;
}

@end
