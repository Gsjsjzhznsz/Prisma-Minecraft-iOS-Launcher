//
//  DataTransferService.h
//  Amethyst
//
//  Task217：数据导出/导入服务（包名迁移配套）。
//
//  背景：iOS 应用的数据容器按包名隔离——包名一旦变更（本仓库历史：
//  com.air-devs.air → com.air-devs.prisma → com.prisma-devs.prisma →
//  com.air-devs → Task218 起临时 com.air-devs.air（上游同款，原地更新通道），最终目标 com.prisma-devs），新包名应用无法
//  访问旧容器，游戏数据/账户/设置全部"原地丢失"。
//
//  迁移链路：旧包名版本导出全量备份（zip）→ 文件 App / iCloud 任意位置
//  → 新包名版本从备份文件直接导入（合并落回 POJAV_HOME）→ 重启生效。
//
//  导出范围 = POJAV_HOME 全量（实例/版本/存档/模组/账户 accounts/、
//  全局与实例级 launcher_preferences*、触控布局、MG 配置等），
//  仅剔除运行期垃圾（latestlog* / hs_err_pid* / .ame217_session 哨兵）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DataTransferService : NSObject

+ (instancetype)sharedService;

/// 导出 POJAV_HOME 全量数据为 zip 备份，落点由用户经系统文件选择器决定
/// （"文件"App / iCloud / On My iPhone 任意位置）。presenter 用于弹
/// 进度框与文件选择器；整个流程可在任意线程发起，UI 弹窗自动切主线程。
- (void)exportDataFromViewController:(UIViewController *)presenter;

/// 从用户选择的备份 zip 直接导入：安全域拷贝 → 临时目录解压（含
/// zip-slip 路径净化）→ 逐文件合并回 POJAV_HOME（同名覆盖）。完成后
/// 提示重启启动器（偏好/账户/档案在内存中有缓存）。
- (void)importDataFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
