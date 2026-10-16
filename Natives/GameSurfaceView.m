#import "GameSurfaceView.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

// ★ Task248（⑤ Vulkan 渲染下 FPS 识别卡在 60 根修）：
//
// 病历：Vulkan 路径（MoltenVK / MobileGL-DirectVulkan）不经过
// pojavSwapBuffers（FPS 计数器的 GL 路径递增点），SurfaceViewController 用
// CADisplayLink fallback 每帧递增计数器（PLDisplayLinkTarget.displayLinkTick
// → pojavIncrementFpsCounter）。但 CADisplayLink 的节奏是【屏幕刷新节奏】
// ——60Hz 设备恒 60Hz，与游戏真实帧率完全无关：游戏 20fps 显示 60、
// 游戏 90fps 也显示 60（用户实测"FPS 识别卡在 60"）。
//
// 根修：真实的 present/acquire 计数点。MoltenVK 的 vkQueuePresentKHR 最终
// 调用 CAMetalLayer 的公开 API nextDrawable（swapchain 图像获取，每渲染
// 帧恰一次）——把游戏表面 layer 换成本子类，override nextDrawable 在
// Vulkan 路径判定下递增计数器，FPS 数字第一次等于游戏真实帧率。
// GL 路径（ANGLE/gl4es/MobileGlues-GLES 同样走 CAMetalLayer.nextDrawable）
// 由 pojavIsActualVulkanPath()（clientAPI == GLFW_NO_API）闸门排除，计数
// 仍由 pojavSwapBuffers 独占——双重计数零风险。displayLink 的 FPS 递增
// 分支同步退役（Gyro/Controller tick 保留）。
@interface Ame248FPSMetalLayer : CAMetalLayer
@end

@implementation Ame248FPSMetalLayer

- (nullable id<CAMetalDrawable>)nextDrawable {
    // ★ Task249（用户反馈 4：Vulkan 渲染下切后台卡死 根修）：Metal 呈现边界
    //   停靠点。病历：Task223 的后台驻车点只有 gl_swap 一处（gl_bridge.m）
    //   ——Vulkan（MoltenVK）/Metallum 原生 Metal 会话不经过 gl_swap，
    //   resign 后渲染线程继续向 Metal 提交命令缓冲：iOS 26/27 后台 GPU
    //   提交被禁，挂起的提交在恢复时超时 = 回前台整链楔死（"切后台卡死"，
    //   装机日志 latestlog.old 的 GL 会话有 "PARKED at gl_swap"，Vulkan 会
    //   话则无任何 PARKED 行 = 停靠点缺席实锤）。修法：在 nextDrawable 入口
    //   挂同一 ame223 停车闸（utils.h 公开 API，mutex+cond 多等待者安全），
    //   驻车时渲染线程在【获取下一帧之前】冻结 = 后台零 GPU 提交，与
    //   gl_swap 停靠语义完全对齐；前台态快路径 = 一次锁检查立即返回。
    //   GL 会话同样无害：gl_swap 先行停靠时 nextDrawable 永远不会到达。
    ame223_bg_park_wait("metal_nextDrawable");
    // 每帧 swapchain 图像获取 = Vulkan 真实帧事件（MoltenVK present 内部
    // 必经点）。非 Vulkan 路径不计数（pojavSwapBuffers 独占）。
    if (pojavIsActualVulkanPath()) {
        pojavIncrementFpsCounter();
    }
    return [super nextDrawable];
}

@end

@implementation GameSurfaceView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.layer.drawsAsynchronously = YES;
    self.layer.opaque = YES;
    // ★ Task267：drawable 失效/窗口换形间隙的背景兜底——CAMetalLayer 的
    //   backgroundColor 默认 nil，短暂无内容呈现时透出窗口第 0 层壁纸
    //   （用户反馈"切小窗露出底下的壁纸"的次级暴露面）。取 touchView
    //   同款深色，观感与启动期一致。
    self.layer.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1.0].CGColor;

    return self;
}

+ (Class)layerClass {
    // Task 124（MobileGL 崩溃根治）：必须用"有效渲染器"（ame_effective_renderer，
    // 含 MobileGL 后端选项覆盖）判定，而不是裸读 profile 渲染器。
    // 事故链（1d4ff3a9 装机日志）：用户 profile=zink -> 这里返回了普通 CALayer；
    // 旧 Task113 的 mobilegl_vulkan 开关却把实际渲染器覆盖成 libMobileGL.dylib
    // (DirectVulkan) -> MobileGL 内部 MoltenVK 在 swapchain 创建时向该层发送
    // naturalDrawableSizeMVK（MoltenVK 挂在 CAMetalLayer 上的 category 方法）
    // -> 普通CALayer 无此方法 -> NSInvalidArgumentException，进程终止。
    // 修复：layerClass 与 JavaLauncher 的 AMETHYST_RENDERER 解析同源（单一
    // 事实源 ame_effective_renderer），MobileGL / Mithril 一律 CAMetalLayer。
    NSString *renderer = ame_effective_renderer();
    if ([renderer hasPrefix:@"libOSMesa"]) {
        // zink/OSMesa：呈现走 CGImage contents（CPU 侧回读），无需 Metal 层。
        return CALayer.class;
    }
    // 其余全部 CAMetalLayer：MobileGL(DirectVulkan 内部 MoltenVK 直呈 Metal 层，
    // DirectGLES 同样支持 CAMetalLayer native window)、Mithril、MoltenVK、
    // ANGLE/MobileGlues/LTW（EGL -> Metal）。
    // ★ Task248（⑤）：CAMetalLayer 子类（nextDrawable 计数）——签名兼容，
    // MoltenVK/ANGLE 的 layer 属性写入面不变。
    return Ame248FPSMetalLayer.class;
}

@end
