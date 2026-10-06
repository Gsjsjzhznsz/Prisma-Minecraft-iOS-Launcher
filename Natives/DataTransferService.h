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

#pragma mark - Task224：选择式导出 + 真并行压缩（清单第 12/13 项二轮）

/// 导出内容分区 id（ame224_sectionDefinitions 返回项的 "id" 字段）。
/// 选择 UI 与导出收集共用同一份分区口径：
///   worlds        当前实例 saves/
///   resourcepacks 当前实例 resourcepacks/ + shaderpacks/
///   mods          当前实例 mods/ + config/
///   screenshots   当前实例 screenshots/
///   servers       当前实例 servers.dat / servers.dat_old
///   instance      instances/ 整树（含其他实例；勾选后覆盖上面五个子分区）
///   launcher      启动器数据（accounts/、偏好、触控布局等根级内容，
///                 剔除 instances/、versions/、libraries/、assets/、
///                 java_runtimes/、Library/ 与运行期垃圾）
///   gamefiles     versions/ + libraries/ + assets/ + java_runtimes/
///                 （可重新下载，默认不勾选）
FOUNDATION_EXPORT NSString * const Ame224SectionIdWorlds;
FOUNDATION_EXPORT NSString * const Ame224SectionIdResourcePacks;
FOUNDATION_EXPORT NSString * const Ame224SectionIdMods;
FOUNDATION_EXPORT NSString * const Ame224SectionIdScreenshots;
FOUNDATION_EXPORT NSString * const Ame224SectionIdServers;
FOUNDATION_EXPORT NSString * const Ame224SectionIdInstance;
FOUNDATION_EXPORT NSString * const Ame224SectionIdLauncher;
FOUNDATION_EXPORT NSString * const Ame224SectionIdGameFiles;

/// 分区定义（静态、有序）：每项为 @{ @"id": …, @"icon": SF Symbol 名,
/// @"defaultOn": NSNumber }。标题由 UI 层用 key dataexport.section.<id>
/// 本地化渲染。运行期垃圾（latestlog*/hs_err*/哨兵）与符号链接永远剔除，
/// 且根级 Library/（内含指向实例目录的符号链接）整树跳过——旧实现曾把
/// 该链接当目录展开，实例数据被双份导出，是"无压缩也 1MB/s"的隐藏成因之一。
+ (NSArray<NSDictionary *> *)ame224_sectionDefinitions;

/// 后台快速扫描（只 stat 不读内容）：返回与 ame224_sectionDefinitions
/// 同序的 @{ @"id": …, @"files": NSNumber, @"bytes": NSNumber } 数组，
/// 外加末尾一项 @{ @"id": @"instance_full", … }（instance 分区若单独
/// 展示整树规模用；子分区间计数互斥不重复）。completion 在后台线程触发。
- (void)ame224_scanSectionsWithCompletion:(void(^)(NSArray<NSDictionary *> *stats, NSError *error))completion;

/// 导出进度（≤10Hz 合并上报；可在任意线程触发）。
/// phase：0=扫描收集 1=压缩/写入流水线 2=收尾（中央目录+EOCD）。
typedef void (^Ame224ExportProgressBlock)(NSUInteger phase,
                                          NSUInteger filesDone, NSUInteger filesTotal,
                                          unsigned long long bytesDone, unsigned long long bytesTotal,
                                          double bytesPerSecond,
                                          NSString *currentFile);

/// ★ Task224 速度根修：分区选择 + 3 路并行 deflate + 单写线程有序落盘。
/// 病历（2832c2b 装机反馈"10 秒 10MB，无压缩也一样慢"）：Task223 的
/// "并发读 + 串行写"仍把压缩留在串行写侧（UZKArchive 单句柄硬约束），
/// 压缩 CPU 时间与磁盘写完全串行；本方法改用自研 zip 写器：
///   - 3 个 worker（user-initiated 并发队列）各自流式读文件（4MB 块），
///     zlib raw deflate（windowBits=-15）+ CRC32 在 worker 内并行完成；
///   - 单写线程按条目顺序写 local header + 已压缩缓冲（zip 结构一致性），
///     > 64MB 的大文件由写线程直接流式压缩（内存上限 4MB 输入块 + 4MB
///     输出块 + data descriptor 收尾）；
///   - store（无压缩）模式：worker 并行预算 CRC32（顺带预热页缓存），
///     写线程 4MB 直通写盘，无每 64KB 的进度链路；
///   - worker 领先量按 192MB 预算信号量限深（内存上界）；
///   - 进度计数为原子量，10Hz 定时器合并上报，热循环零主线程派发。
/// 输出仍是标准 zip（minizip/UnzipKit 可读，导入链路不变），条目路径
/// 与旧版一致（相对 POJAV_HOME），含 UTF-8 名称位与大档 zip64 支持。
/// method 语义沿用 UZKCompressionMethod：0=None（store）、-1=Default
///（zlib level 6）、9=Best。cancelProgress 由调用方注册为下载任务的
/// rawTask（JRE 导入同款取消链路），置 cancelled 即协作式中止并清理
/// 临时文件；sectionIds 传勾选的分区 id（instance 勾选时自动覆盖五个
/// 实例子分区）。completion 在后台线程触发。
- (void)ame224_runBackupExportWithMethod:(NSInteger)method
                                sectionIds:(NSArray<NSString *> *)sectionIds
                             cancelProgress:(NSProgress *)cancelProgress
                                   progress:(nullable Ame224ExportProgressBlock)progress
                                 completion:(void(^)(NSString *tmpPath, NSError *error))completion;

/// 导出完成后呈现系统文件选择器（move 语义定落点）。可从任意最顶层
/// VC 调起（任务详情页 / 导出页均可）。
- (void)ame223_presentDestinationPickerForTmpPath:(NSString *)tmpPath
                                              from:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
