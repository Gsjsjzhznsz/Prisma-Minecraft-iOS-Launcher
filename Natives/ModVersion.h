#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModVersion : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *versionNumber;
@property (nonatomic, copy, readonly) NSString *datePublished; // ISO 8601 string
@property (nonatomic, copy, readonly) NSArray<NSString *> *gameVersions;
@property (nonatomic, copy, readonly) NSArray<NSString *> *loaders;
@property (nonatomic, copy, readonly, nullable) NSDictionary *primaryFile; // The first file in the files array
// 发布类型（Modrinth: release/beta/alpha；CurseForge: 1=release/2=beta/3=alpha）
// 用于版本行显示发布类型徽章（参照 FCL/ZL2 的 Release/Beta/Alpha 标签）
@property (nonatomic, copy, readonly) NSString *versionType;

// 资源来源 API（1=Modrinth, 2=CurseForge）
@property (nonatomic, assign) NSInteger apiSource;
// 文件大小（字节）
@property (nonatomic, strong, nullable) NSNumber *fileSize;
// CurseForge file ID
@property (nonatomic, copy, nullable) NSString *fileId;
// CurseForge project ID
@property (nonatomic, copy, nullable) NSString *projectId;
// ★ Task227（issue #10 重做）：原始版本字典（依赖列表在 dependencies[] 里，
// 现有字段都是拍平后的，取不到——上游 bc5ce914bc 同款）。
@property (nonatomic, copy, nullable) NSDictionary *rawDictionary;

- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;

@end

NS_ASSUME_NONNULL_END
