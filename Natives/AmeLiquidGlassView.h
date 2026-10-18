//
//  AmeLiquidGlassView.h
//  Amethyst
//
//  ★ Task252（用户指令："现在的启动器自己搓了一个伪液态玻璃，十分劣质，
//    换成tg的，只是把ui换掉，选项啥的都不变"）：
//    Telegram iOS 开源客户端 LegacyGlassView 配方的 1:1 ObjC 移植
//    （TelegramMessenger/Telegram-iOS @ f1dd7a2d，submodules/TelegramUI/
//    Components/GlassBackgroundComponent/Sources/LegacyGlassView.swift +
//    MeshTransform/Sources/GenerateMesh.swift）。研究笔记与源码快照：
//    /home/z/my-project/research/tg-glass/（RESEARCH_NOTES.md）。
//
//    配方（全部私有 API 走 NSClassFromString/selector 运行时解析，缺失即
//    +ame252_isSupported = NO，调用方保留旧管线零回归）：
//      1) CABackdropLayer（"CA"+"BackdropLayer"，UIVisualEffectView 同款
//         引擎本体）——实况采样本视图背后的窗口内容；
//      2) CAFilter "colorMatrix"（TG 玻璃矩阵，强饱和+提亮，
//         inputBackdropAware=1）+ CAFilter "gaussianBlur"（inputRadius 2，
//         TG LegacyGlassView .normal 档同值）；
//      3) CALayer.meshTransform（"CAMutable"+"MeshTransform"）——
//         GenerateMesh 移植：圆角矩形 SDF + 梯度法线 + 边缘线性衰减 +
//         贝塞尔缓动（TG 控制点原值）+ 2pt 外圈增强，位移 20pt、
//         折射带宽 min(12, radius)、角分辨率 12 —— 边缘"透镜折射"；
//      4) TG .panel 面板填充（浅色 white@0.70 / 深色 11%white@0.85）+
//         0.8pt 发丝描边（浅 0.60 / 深 0.15，TG generateLegacyGlassImage
//         分支值）。
//
//    双模（本仓库特有，TG 无此分叉——Metal 游戏层上系统 backdrop 不合成
//    是 Task228/230/236 三轮装机实锤）：
//      - 实况模式（默认）：CABackdropLayer 采样，启动器域使用；
//      - 快照供料模式：ame252_backdropSnapshot 传入抓帧图像，
//        ame252_backdropSourceRect 声明图像覆盖的几何（本视图坐标系，
//        窗口对位真透视），同一滤镜栈/网格作用于图像内容——游戏域
//        （TVC/MVC/游戏内菜单）由调用方既有 8Hz display link 持续供料。
//
//    调用方接线（Task252 范围）：AmeFloatingMenu 弹窗面板、游戏内菜单
//    面板（SurfaceViewController+Navigation）。MultiplayerViewController /
//    TerracottaViewController 的整页磨砂用 +ame252_glassFilters 材料
//    升级（整页无形状，网格/描边不适用）。
//
//    选项不变声明：本视图只换"渲染材质"，不读不写任何设置键；
//    prisma.interface_style 四档、透明度/模糊拉条行为原样。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Telegram LegacyGlassView 配方玻璃视图（Task252）。
/// 宿主把本视图插到面板内容之下（index 0），面板自身底色在玻璃激活时
/// 置 nil（玻璃自带 TG .panel 填充承载可读性，底色若在其后会被
/// backdrop 一并采样）。
@interface AmeLiquidGlassView : UIView

/// 运行时支持判定：CABackdropLayer / CAMutableMeshTransform / CAFilter
/// 三件全在才 YES（理论 iOS 14+ 全真机命中；模拟器越狱壳缺失时自动
/// 回退旧管线）。
+ (BOOL)ame252_isSupported;

/// 构造：圆角 radius（网格随尺寸/圆角重建）、深浅色 isDark。
/// 不支持时返回 nil（调用方走旧管线）。
+ (nullable AmeLiquidGlassView *)ame252_glassViewWithCornerRadius:(CGFloat)radius
                                                           isDark:(BOOL)isDark;

/// 圆角（重建网格 + 描边）。
@property (nonatomic, assign) CGFloat ame252_cornerRadius;
/// 深浅色（重建描边浓度；TG 深浅共用同一滤镜矩阵）。
@property (nonatomic, assign, getter=ame252_isDark) BOOL ame252_dark;

/// 快照供料模式（游戏域）：非 nil 时源层由 CABackdropLayer 切换为
/// 图像层（同一滤镜栈）。传回 nil 恢复实况模式。
@property (nonatomic, strong, nullable) UIImage *ame252_backdropSnapshot;
/// 快照图像覆盖的几何（本视图坐标系）：窗口对位真透视由调用方计算
/// （面板挪位/旋转后同步刷新，Ame248 对位同源）。
@property (nonatomic, assign) CGRect ame252_backdropSourceRect;

/// TG 玻璃滤镜组（colorMatrix + gaussianBlur）：整页磨砂材料升级用
/// （MultiplayerViewController / TerracottaViewController 快照图层
/// layer.filters 直接挂载；内容滤镜作用于图层自身内容，Metal 场景
/// 不采样 backdrop，无合成问题）。
+ (nullable NSArray *)ame252_glassFilters;

/// ★ Task289：整页壁纸磨砂滤镜（BackgroundManager TG 层专用，按强度定制）。
/// 与面板配方 ame252_glassFilters 两点本质区别：
/// ① 无 colorMatrix——TG 面板饱和度矩阵服务小面积面板的"玻璃体感"，
///    作用在全幅壁纸上 = 整页色彩漂移（装机实锤"壁纸看起来很奇怪"）；
/// ② gaussianBlur 半径随磨砂强度线性缩放（强度 0 已由调用方整层跳过；
///    本函数半径下限 1.5 防止"装了层却零模糊"的空转档）。
/// 每次调用新建 CAFilter 实例（滑杆逐 tick 重铺各自持有，不共享缓存）。
+ (nullable NSArray *)ame252_frostFiltersWithIntensity:(CGFloat)intensity;

@end

NS_ASSUME_NONNULL_END
