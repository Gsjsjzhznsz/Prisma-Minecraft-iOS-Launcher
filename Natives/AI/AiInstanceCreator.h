//
//  AiInstanceCreator.h
//  Prisma
//
//  create_instance 工具（enhance-ai-agent Task 12.2）：
//  在 <POJAV_HOME>/instances/ 下创建同名目录、切换为当前游戏目录（复刻
//  VersionManagerViewController switchGameDirTo 逻辑：重建 POJAV_GAME_DIR
//  符号链接 + toggleIsolatedPref + PLProfiles updateCurrent）、注册并选中
//  profile，post ReloadProfileList。返回完整路径。
//
//  可选 mcVersion/loader 仅写入 profile 的备注性字段（lastVersionId 不预设，
//  版本安装由 install_game_version / install_loader 完成）。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiInstanceCreator : NSObject <AiTool>
@end

NS_ASSUME_NONNULL_END
