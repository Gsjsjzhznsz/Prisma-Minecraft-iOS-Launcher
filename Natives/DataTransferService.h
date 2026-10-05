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

#pragma mark - Task223：二级入口 + 版本下载任务体系的导出（清单第 12/13 项）

/// 导出跳过规则（latestlog*/hs_err*/会话哨兵等运行期垃圾）。
/// 供 DataExportViewController 的预检扫描复用同一份排除清单。
- (BOOL)ame217_shouldSkipExportEntry:(NSString *)fileName;

/// ★ Task223 速度根修：并发读 + 串行写流水线导出。
/// 病历（2832c2b 装机反馈“10 秒才 10MB，无压缩也很久”）：旧实现
/// 串行“整读单文件 → UZK 写入 → 下一文件”——读 IO 与压缩写串行等待，
/// 小文件场景每文件固定开销占主导（文件枚举器 + 全量 NSData 读 +
/// UZK 每条目提交），实测吞吐 ~1MB/s。
/// 新实现：4 路并发读（dispatch_group + 信号量限深，在飞上限
/// max(8, 64MB/平均文件)）→ 有序缓冲 → 单线程串行 zip 写入
///（UZKArchive 非线程安全，写侧串行是硬约束），读写在稳态下重叠。
/// 进度回调（done/total/writtenBytes）与阶段推进（0=collect 完成、
/// 1=compress 进行中）均可在任意线程触发；completion 在后台线程。
- (void)ame223_runPipelinedBackupExportWithMethod:(NSInteger)method
                                          progress:(void(^)(NSUInteger done, NSUInteger total, unsigned long long writtenBytes))progress
                                      stageAdvance:(void(^)(NSUInteger stage))stageAdvance
                                        completion:(void(^)(NSString *tmpPath, NSError *error))completion;

/// 导出完成后呈现系统文件选择器（move 语义定落点）。可从任意最顶层
/// VC 调起（任务详情页 / 导出页均可）。
- (void)ame223_presentDestinationPickerForTmpPath:(NSString *)tmpPath
                                              from:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
