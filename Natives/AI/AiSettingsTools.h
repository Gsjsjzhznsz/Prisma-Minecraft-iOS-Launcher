//
//  AiSettingsTools.h
//  Prisma
//
//  设置读写工具（enhance-ai-agent Task 10）：
//  - list_settings（READ_ONLY）：返回可用设置键/取值说明表
//  - get_setting（READ_ONLY）：读取指定键的全局值与实例生效值
//  - set_setting（CONTROLLED_WRITE）：修改全局或实例设置，写后广播刷新通知
//
//  键分为两类：
//  - 全局键：LauncherPreferences（getPrefObject/setPrefObject）
//  - 实例键：PLProfiles profile 字段（renderer/graphicsApi/javaArgs 等，回退全局同名偏好）
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiSettingsTools : NSObject <AiTool>

/// internalName 支持：list_settings / get_setting / set_setting
- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
