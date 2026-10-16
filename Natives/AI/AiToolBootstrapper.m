//
//  AiToolBootstrapper.m
//  Prisma
//

#import "AiToolBootstrapper.h"
#import "AiToolRegistry.h"

#import "AiInstancesTool.h"
#import "AiLogReader.h"
#import "AiCrashAnalyzer.h"
#import "AiFileTools.h"
#import "AiAskTool.h"
#import "AiAssetTools.h"
#import "AiSettingsTools.h"
#import "AiTodoTool.h"
#import "AiSleepTool.h"
#import "AiDownloadProbe.h"
#import "AiInstanceCreator.h"

@implementation AiToolBootstrapper

+ (void)registerBuiltinToolsIntoRegistry:(AiToolRegistry *)registry {
    if (!registry) return;

    // ===== 3a 阶段内置工具 =====

    // 实例/版本工具（list_instances、list_game_versions）
    [registry registerTool:[[AiInstancesTool alloc] initWithName:@"list_instances"]];
    [registry registerTool:[[AiInstancesTool alloc] initWithName:@"list_game_versions"]];

    // 日志读取工具（read_latest_log、read_crash_report）
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_latest_log"]];
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_crash_report"]];

    // 崩溃分析工具（match_known_errors）
    [registry registerTool:[[AiCrashAnalyzer alloc] init]];

    // 文件工具（list_files、read_file、grep_files、write_file、edit_file、delete_file）
    [registry registerTool:[[AiFileTools alloc] initWithName:@"list_files"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"read_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"grep_files"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"write_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"edit_file"]];
    [registry registerTool:[[AiFileTools alloc] initWithName:@"delete_file"]];

    // 交互问答工具（ask）
    [registry registerTool:[[AiAskTool alloc] init]];

    // ===== 以下为 3b 资源工具 =====

    // Modrinth 搜索工具（ExternalNetwork）
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_mods"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_resourcepacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_shaders"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_datapacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_modpacks"]];
    [registry registerTool:[[AiAssetSearchTool alloc] initWithName:@"search_worlds"]];

    // 资源安装 / 加载器工具（ControlledWrite）
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_mod"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_resourcepack"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_shader"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_datapack"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_game_version"]];
    [registry registerTool:[[AiAssetInstallTool alloc] initWithName:@"install_loader"]];

    // ===== enhance-ai-agent 新增工具 =====

    // 日志扩展（read_latest_log/read_crash_report 支持 instance 参数）
    [registry registerTool:[[AiLogReader alloc] initWithName:@"read_logs"]];

    // 下载进度查询（ReadOnly）
    [registry registerTool:[[AiDownloadProbe alloc] initWithName:@"check_downloads"]];

    // 设置工具（list/get 为 ReadOnly；set 为 ControlledWrite）
    [registry registerTool:[[AiSettingsTools alloc] initWithName:@"list_settings"]];
    [registry registerTool:[[AiSettingsTools alloc] initWithName:@"get_setting"]];
    [registry registerTool:[[AiSettingsTools alloc] initWithName:@"set_setting"]];

    // to-do 清单工具
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_create"]];
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_list"]];
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_update"]];
    [registry registerTool:[[AiTodoTool alloc] initWithName:@"todo_delete"]];

    // sleep（ReadOnly，无副作用）
    [registry registerTool:[[AiSleepTool alloc] init]];

    // 新建游戏目录实例（ControlledWrite）
    [registry registerTool:[[AiInstanceCreator alloc] init]];
}

@end