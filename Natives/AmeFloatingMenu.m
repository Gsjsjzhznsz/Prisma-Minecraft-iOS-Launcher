//
//  AmeFloatingMenu.m
//  Amethyst
//
//  Task237：统一悬浮菜单（液态玻璃风格 = 全自定义组件；原生风格 = 旧版
//  原生弹窗零魔改直呈现）。设计要点见 AmeFloatingMenu.h 头注释。
//
//  渲染层次（自下而上）：
//    panel.backgroundColor（明暗自适应半透明实底——磨砂在本进程 Metal
//    游戏画面上不合成时它独立承载可读性，Task228/230/236 三轮教训）
//    → UIVisualEffectView（SystemMaterial，index 0 子视图，自带圆角裁剪）
//    → 内容（标题/正文/镜像输入框/菜单行 + 分隔发丝线）
//    → 发丝描边覆盖环（最上层，不参与命中）
//  文字恒在磨砂之上——“打开只有玻璃没有字”的构造性根除。
//
//  ★ Task245（IMG_0380 用户定案“这透视有问题吧”）：快照磨砂显示改
//    【窗口对位真透视】——快照按窗口几何 1:1 铺进面板圆角裁剪容器
//    （面板下每个像素 = 面板后方真实背景内容）+ 二次柔化 + tint；
//    AspectFill 居中裁剪的“假透视”（显示整屏中心放大裁切，几何错位）
//    退役。专属域 = 输入类弹窗（中央路由接管）与 Metal 游戏面菜单
//    （统一菜单呈现器 Task245 域分轨），启动器内选择菜单已回归系统
//    原生液态玻璃直出。
//

#import "AmeFloatingMenu.h"
#import "LiquidGlassCompat.h"
#import "BackgroundManager.h"   // ★ Task238：菜单树描边豁免（字体重叠根治）
#import "LauncherPreferences.h" // ★ Task250：accentColor()（菜单行符号 tint 跟随主题强调色）
#import "AmeLiquidGlassView.h"  // ★ Task252：TG LegacyGlassView 配方接管面板玻璃
#import "SurfaceViewController.h" // ★ Task252：+surface 判定游戏域（快照供料 vs 实况采样）
#import <CoreImage/CoreImage.h>   // ★ Task277：快照磨砂材质化（高斯+饱和度，Apple 材质观感）

#pragma mark - 前向声明与工具

@interface Ame237MenuActionMirror : NSObject
@property (nonatomic, strong, nullable) UIAlertAction *orig;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, assign) NSInteger style;   // 0 default / 1 cancel / 2 destructive
@property (nonatomic, copy, nullable) void (^handler)(UIAlertAction *action);
@property (nonatomic, assign) BOOL enabled;
@end

@implementation Ame237MenuActionMirror
@end

/// 动态明暗颜色：深色模式 = 白 alpha；浅色模式 = 黑 alpha。
static UIColor *Ame237Dyn(CGFloat darkWhiteAlpha, CGFloat lightBlackAlpha) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:1.0 alpha:darkWhiteAlpha]
            : [UIColor colorWithWhite:0.0 alpha:lightBlackAlpha];
    }];
}

/// 面板防御性实底：深色 = 近黑 55%；浅色 = 白 80%（磨砂失效时仍是一块
/// 可读面板——绝不是“透明面板 + 悬浮文字”）。
static UIColor *Ame237PanelBase(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:0.02 alpha:0.55]
            : [UIColor colorWithWhite:1.0 alpha:0.80];
    }];
}

/// ★ Task239：原生玻璃（UIGlassEffect）面板底——比 Task237 防御底更通透
///   （真玻璃自带磨砂与折光，厚底会把它闷成实心板）；仍保留中等浓度
///   兑底（玻璃在个别进程环境渲染异常时面板不会变成“透明 + 悬浮文字”）。
static UIColor *Ame239GlassPanelBase(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:0.02 alpha:0.30]
            : [UIColor colorWithWhite:1.0 alpha:0.58];
    }];
}

static CGFloat Ame237TextHeight(NSString *text, UIFont *font, CGFloat width) {
    if (text.length == 0) return 0.0;
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:text
                                                             attributes:@{NSFontAttributeName: font}];
    CGRect r = [s boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                               context:nil];
    return ceil(r.size.height);
}

/// ★ Task243：keyWindow 重度降采样快照（自绘磨砂原料；与游戏内主菜单
///   SurfaceViewController+Navigation 的同名机制同源）。0.18x scale 抓帧
///   = 抓帧即模糊；afterScreenUpdates:NO 不触发屏幕更新；异常/参数缺失
///   返回 nil（调用方回退深色底护栏）。
static UIImage *Ame243BlurredKeyWindowSnapshot(UIView *hostView) {
    UIWindow *ame243_win = hostView.window;
    if (ame243_win == nil || ame243_win.bounds.size.width < 40.0 ||
        ame243_win.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame243_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame243_fmt.scale = 0.18;
        ame243_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame243_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame243_win.bounds.size
                                                   format:ame243_fmt];
        return [ame243_r imageWithActions:^(UIGraphicsImageRendererContext *ame243_rc) {
            [ame243_win drawViewHierarchyInRect:ame243_win.bounds
                             afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame243_e) {
        return nil;
    }
}

/// ★ Task252：TG 玻璃供料快照（0.5x 抓帧——TG 滤镜栈自帶 r=2 微模糊与
///   colorMatrix，原料需要保留真实细节供边缘网格折射；与 0.18x
///   "抓帧即模糊"旧路不同源）。
static UIImage *Ame252GlassFeedSnapshot(UIView *hostView) {
    if (hostView == nil || hostView.window == nil ||
        hostView.bounds.size.width < 40.0 ||
        hostView.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame252_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame252_fmt.scale = 0.5;
        ame252_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame252_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:hostView.bounds.size
                                                   format:ame252_fmt];
        return [ame252_r imageWithActions:^(UIGraphicsImageRendererContext *ame252_rc) {
            [hostView drawViewHierarchyInRect:hostView.bounds
                           afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame252_e) {
        return nil;
    }
}

/// ★ Task246：动态背景重抓——呈现中面板背后的真实背景内容重渲染。
///   与 Ame243 的关键差异：源不是 keyWindow（会把自家面板/遮罩一起拍进去
///   = 自噬），而是【正在呈现方的 view】（OverFullScreen 呈现下呈现方
///   视图仍在窗口层级内、且位于本组件之下 = 纯背景内容，无自噬面）；
///   0.18x 抓帧即模糊。异常/参数缺失返回 nil（调用方保留上一张有效图）。
static UIImage *Ame246PresenterViewSnapshot(UIView *hostView) {
    if (hostView == nil || hostView.window == nil ||
        hostView.bounds.size.width < 40.0 ||
        hostView.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame246_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame246_fmt.scale = 0.18;
        ame246_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame246_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:hostView.bounds.size
                                                   format:ame246_fmt];
        return [ame246_r imageWithActions:^(UIGraphicsImageRendererContext *ame246_rc) {
            [hostView drawViewHierarchyInRect:hostView.bounds
                           afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame246_e) {
        return nil;
    }
}

static UIImage *Ame245SoftenSnapshot(UIImage *ame245_img);

/// ★ Task277（"优化伪液态玻璃的玻璃感"·磨砂材质化）：0.18x 抓帧成品再过
///   【材质滤镜链】——CIGaussianBlur（r≈6 @0.18x ≈ 33pt 有效半径，标准磨砂
///   观感）+ CIColorControls（saturation 1.5、brightness +0.02，Apple 材质
///   的"提鲜"特征：玻璃不只是糊，还把背景色彩饱和度抬起来）。旧纯两次降
///   采样的"糊"没有饱和度与光感 = 用户口中的"伪"。
///   CIContext 复用（单例，创建成本高）；CoreImage 链任何异常/失败回退旧
///   两次降采样路径，绝不阻断观感。IMG_0380 的"透视见底"另一半修复位不动。
static CIContext *Ame277SharedCIContext(void) {
    static CIContext *ame277_ctx = nil;
    static dispatch_once_t ame277_once;
    dispatch_once(&ame277_once, ^{
        ame277_ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return ame277_ctx;
}

static UIImage *Ame277MaterializeSnapshot(UIImage *ame277_img) {
    if (ame277_img == nil) return nil;
    @try {
        CIImage *ame277_ci = [CIImage imageWithCGImage:ame277_img.CGImage];
        if (ame277_ci == nil) return Ame245SoftenSnapshot(ame277_img);
        CIFilter *ame277_blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [ame277_blur setValue:ame277_ci forKey:kCIInputImageKey];
        [ame277_blur setValue:@6.0 forKey:kCIInputRadiusKey];
        CIImage *ame277_blurred = ame277_blur.outputImage;
        if (ame277_blurred != nil) {
            CIFilter *ame277_color = [CIFilter filterWithName:@"CIColorControls"];
            [ame277_color setValue:ame277_blurred forKey:kCIInputImageKey];
            // ★ Task278：提鲜再抬一档（saturation 1.5→1.6、brightness
            //   +0.02→+0.03）——装机复核“玻璃感不是很好”：饱和度是玻璃材质
            //   “透光感”的主载，1.5 在低饱和壁纸上仍偏灰；0.03 亮度抬升补
            //   足白色填充对背底亮度的吃掉量。
            [ame277_color setValue:@1.6 forKey:@"inputSaturation"];
            [ame277_color setValue:@0.03 forKey:@"inputBrightness"];
            [ame277_color setValue:@1.0 forKey:@"inputContrast"];
            ame277_blurred = ame277_color.outputImage;
        }
        if (ame277_blurred != nil) {
            // 高斯核边缘外扩：裁回原幅面（否则四周发白/整体位移）。
            ame277_blurred = [ame277_blurred imageByCroppingToRect:ame277_ci.extent];
            CGImageRef ame277_cg = [Ame277SharedCIContext()
                createCGImage:ame277_blurred fromRect:ame277_blurred.extent];
            if (ame277_cg != NULL) {
                UIImage *ame277_out = [UIImage imageWithCGImage:ame277_cg
                                                          scale:ame277_img.scale
                                                    orientation:UIImageOrientationUp];
                CGImageRelease(ame277_cg);
                if (ame277_out != nil) return ame277_out;
            }
        }
    } @catch (NSException *ame277_e) {
        NSLog(@"[AmeMenu] Task277: materialize filter chain failed (%@) -- legacy soften fallback", ame277_e.name);
    }
    return Ame245SoftenSnapshot(ame277_img);
}

/// ★ Task245：二次柔化——0.18x 抓帧成品再半分辨率重渲染一次（位图像素
///   再减半），窗口对位 1:1 上采样后背景轮廓不可辨认 = 标准磨砂观感；
///   IMG_0380 的“透视见底”一半来自 AspectFill 裁剪几何错位，另一半就
///   是柔化不足。失败（理论不可达）退回原快照，不阻断观感。
///   ★ Task277：本函数退役为 Task277 材质链的【异常回退层】——磨砂成品
///   统一经 Ame277MaterializeSnapshot（高斯+饱和度材质观感），此处仅保留
///   纯降采样实现供回退与无 CI 环境兜底。
static UIImage *Ame245SoftenSnapshot(UIImage *ame245_img) {
    if (ame245_img == nil) return nil;
    @try {
        CGSize ame245_sz = ame245_img.size;
        if (ame245_sz.width < 1.0 || ame245_sz.height < 1.0) return ame245_img;
        UIGraphicsImageRendererFormat *ame245_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame245_fmt.scale = 0.5;
        ame245_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame245_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame245_sz
                                                   format:ame245_fmt];
        UIImage *ame245_soft =
            [ame245_r imageWithActions:^(UIGraphicsImageRendererContext *ame245_rc) {
                [ame245_img drawInRect:CGRectMake(0, 0, ame245_sz.width, ame245_sz.height)];
            }];
        return ame245_soft ?: ame245_img;
    } @catch (NSException *ame245_e) {
        return ame245_img;
    }
}

/// ★ Task244：快照有效性护栏——全黑帧检测。opaque=YES 的渲染器在抓帧
///   失败/异常时的病态产物是纯黑图（非 nil），直接上屏就是黑面板。
///   降采样到 1x1 读平均色：总亮度低于约 2.5% 视为无效帧。
static BOOL Ame244SnapshotLooksValid(UIImage *ame244_img) {
    if (ame244_img == nil || ame244_img.size.width < 1.0 ||
        ame244_img.size.height < 1.0) return NO;
    CGImageRef ame244_cg = ame244_img.CGImage;
    if (ame244_cg == NULL) return NO;
    unsigned char ame244_px[4] = {0, 0, 0, 0};
    CGColorSpaceRef ame244_cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ame244_ctx = CGBitmapContextCreate(ame244_px, 1, 1, 8, 4,
        ame244_cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(ame244_cs);
    if (ame244_ctx == NULL) return NO;
    CGContextDrawImage(ame244_ctx, CGRectMake(0, 0, 1, 1), ame244_cg);
    CGContextRelease(ame244_ctx);
    int ame244_sum = (int)ame244_px[0] + (int)ame244_px[1] + (int)ame244_px[2];
    return ame244_sum > 19;   // 平均每通道 > ~6/255
}

/// ★ Task244：快照磨砂上的可读性 tint——快照不透明，panel 底色被它盖住
///   无法再压暗，压暗层必须浮在快照【之上】、内容之下。深色 = 黑 0.40
///   （暗玻璃）；浅色 = 白 0.42（奶白玻璃，labelColor 黑字可读）。
///   ★ Task263（反馈 5）：tint alpha 随 LGCPseudoGlassTransparency() 映射，
///   0.5 精确回既有锚点（深 0.40 / 浅 0.42）；1.0 最透 / 0.0 最闷。
///   ★ Task276（"滑块无效"三连根修之二）：梯度拉宽到 ±0.25/±0.275
///   （0.0 最闷 = 深 0.65/浅 0.70；1.0 最透 = 深 0.15/浅 0.15）——首轮
///   ±0.15/±0.20 梯度装机实测不可分辨；provider 内延迟求值（每次深浅
///   色切换读最新值），在屏面板重铺由通知监听驱动（viewDidLoad 注册）。
static UIColor *Ame244SnapshotTint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
        CGFloat ame263_t = LGCPseudoGlassTransparency();
        CGFloat ame263_a = (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? 0.40 - 0.50 * (ame263_t - 0.5)    // 0.65(最闷)..0.15(最透)，0.5→0.40
            : 0.42 - 0.55 * (ame263_t - 0.5);   // 0.70..0.15，0.5→0.42
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:0.0 alpha:ame263_a]
            : [UIColor colorWithWhite:1.0 alpha:ame263_a];
    }];
}

#pragma mark - 菜单行控件（图标 + 标题；自带按压反馈；头文件公开供游戏内菜单共用）

#pragma mark - Task271 行滚动区专用 ScrollView（D1 根修）

@implementation Ame237Scroll
// 菜单行 UIControl 铺满滚动区：基类对 UIControl 拒绝取消跟踪 + 
// delaysContentTouches=NO = 拖动永远在行上开始且永不转入滚动（伪玻璃档
// “选择太多被隐藏无法滑动”根因）。统一放行：拖动即取消行跟踪进入滚动，
// 轻点仍直发行高亮与 TouchUpInside（即时按压反馈保留）。
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return YES;
}
@end

@implementation Ame237MenuRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _showsIcon = YES;
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.userInteractionEnabled = NO;
        _rowLabel = [[UILabel alloc] init];
        _rowLabel.font = [UIFont systemFontOfSize:16];
        _rowLabel.textAlignment = NSTextAlignmentLeft;
        _rowLabel.userInteractionEnabled = NO;
        [self addSubview:_iconView];
        [self addSubview:_rowLabel];
    }
    return self;
}

- (void)ame237_configureWithIcon:(nullable UIImage *)icon
                           title:(NSString *)title
                       textColor:(UIColor *)textColor
                     symbolTint:(UIColor *)symbolTint
                        emphasis:(BOOL)emphasis {
    self.iconView.image = icon;
    self.iconView.tintColor = symbolTint;
    self.rowLabel.text = title;
    self.rowLabel.textColor = textColor;
    self.rowLabel.font = emphasis
        ? [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]
        : [UIFont systemFontOfSize:16];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat iconW = 24.0;
    CGFloat iconX = 22.0;
    BOOL iconVisible = self.showsIcon && (self.iconView.image != nil);
    self.iconView.hidden = !iconVisible;
    if (iconVisible) {
        self.iconView.frame = CGRectMake(iconX, (self.bounds.size.height - iconW) / 2.0, iconW, iconW);
        CGFloat labelX = iconX + iconW + 12.0;
        self.rowLabel.frame = CGRectMake(labelX, 0.0,
                                         MAX(0.0, self.bounds.size.width - labelX - 18.0),
                                         self.bounds.size.height);
    } else {
        // 无符号/隐藏图标：标题占满行宽，不留图标空位
        self.rowLabel.frame = CGRectMake(iconX, 0.0,
                                         MAX(0.0, self.bounds.size.width - iconX - 18.0),
                                         self.bounds.size.height);
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.10 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97) : CGAffineTransformIdentity;
    } completion:nil];
    self.backgroundColor = highlighted ? Ame237Dyn(0.12, 0.06) : nil;
}

@end

#pragma mark - 玻璃悬浮菜单视图控制器

@interface Ame237GlassMenuViewController : UIViewController
@property (nonatomic, copy, nullable) NSString *ame237_title;
@property (nonatomic, copy, nullable) NSString *ame237_message;
@property (nonatomic, copy) NSArray<Ame237MenuActionMirror *> *ame237_actions;
@property (nonatomic, copy) NSArray<UITextField *> *ame237_alertFields;
@property (nonatomic, assign) BOOL ame237_animated;
@property (nonatomic, assign) BOOL ame237_dismissing;
@property (nonatomic, assign) BOOL ame237_didEntrance;
@property (nonatomic, assign) CGFloat ame237_kbShift;
/// ★ Task246：动态背景刷新驱动（呈现期间 8Hz 重抓磨砂原料——背景内容
///   变化（滚动/动画/状态更新）在 ≤125ms 内跟上；“伪液态玻璃背景不随
///   背景变化”根治）。display link 主线程调度，抓帧 0.18x + 二次柔化
///   总成本单帧 <1ms 量级，无性能面。
@property (nonatomic, strong, nullable) CADisplayLink *ame246_refreshLink;
/// ★ Task242：未选中实质动作而关闭面板（dim 点按/cancel 项）时的回调
///   （统一菜单呈现器分轨呈现的取消语义接线，见 .h 变体注释）。
@property (nonatomic, copy, nullable) void (^ame237_onDismiss)(void);
/// ★ Task247（T9）：镜像源 alert 反向引用（动态 message 更新/外部关闭的
///   定位锚——联机进度弹窗等“present 后持续更新内容”的 alert 在玻璃
///   镜像下的同步通路；weak 不延长 alert 生命周期）。
@property (nonatomic, weak, nullable) UIAlertController *ame237_sourceAlert;
/// ★ Task243：呈现前的 keyWindow 重度降采样快照（自绘磨砂原料）。
///   Metal 游戏层上 UIVisualEffectView 不合成（Task228/230/236 三轮装机
///   实锤），游戏内弹层（分辨率调整等）玻璃档只剩深色底 = 黑面板。
///   呈现入口在 present 动画开始前抓帧传入，viewDidLoad 插入面板
///   blurView 之下：Metal 上承载毛玻璃观感；启动器内 blur 合成时它
///   参与下层采样，观感不劣化。
@property (nonatomic, strong, nullable) UIImage *ame243_snapshotImage;
/// ★ Task245：窗口对位磨砂容器/快照引用（ame237_layout 帧刷新用——
///   面板挪位/旋转/键盘避让后快照与窗口几何保持 1:1 对位）。
@property (nonatomic, strong, nullable) UIView *ame245_frostClip;
@property (nonatomic, strong, nullable) UIImageView *ame245_frostSnap;
/// ★ Task252：TG LegacyGlassView 配方玻璃面板（玻璃家族档 + 支持时接管
///   blurView/快照磨砂/描边三件套；游戏域 = 快照供料模式，启动器域 =
///   实况 backdrop 采样）。选项零改动——仅换渲染材质。
@property (nonatomic, strong, nullable) AmeLiquidGlassView *ame252_glass;
/// ★ Task252：YES = 快照供料模式（游戏域，8Hz 持续供料）；NO = 实况模式
///   （CABackdropLayer 直采窗口内容，无需重抓）。
@property (nonatomic, assign) BOOL ame252_glassSnapshotMode;

@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *borderOverlay;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) NSMutableArray<UITextField *> *mirrorFields;
@property (nonatomic, strong) UIScrollView *rowsScroll;
@property (nonatomic, strong) NSMutableArray<Ame237MenuRow *> *rows;
@property (nonatomic, strong) NSMutableArray<UIView *> *separators;
@end

@implementation Ame237GlassMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = YES;

    // ★ Task238（用户：“修复字体与选项文本重叠问题”）：本组件的全部文字
    //   （标题/正文/菜单行）住在自控的磨砂面板上——不再叠加全局壁纸描边
    //   （四方向深色拷贝 + 不透明垫底在半透明玻璃面板上就是“文字双层/
    //   重叠”的观感）。豁免整棵树：拷贝与染白都不作用于本菜单。
    ame230_setViewTreeStrokeExempt(self.view, YES);

    // 遮罩（点击 = 取消/关闭；与游戏内菜单同语义）
    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
    self.dimView.userInteractionEnabled = YES;
    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(ame237_dimTapped)];
    [self.dimView addGestureRecognizer:dimTap];
    [self.view addSubview:self.dimView];

    // 悬浮面板（防御性实底 + 毛玻璃 + 阴影）
    self.panel = [[UIView alloc] init];
    // ★ Task239（用户指令：“请用 iOS 26 原生液态玻璃 API 重写所有悬浮菜单
    //   …使用 UIGlassEffect（UIKit）实现真正的液态玻璃弹窗”）：玻璃风格下
    //   底色分两档——原生玻璃用通透底（真玻璃自带磨砂折光），材质回退
    //   保留 Task237 厚防御底（磨砂不合成时独立承载可读性）。
    self.panel.backgroundColor = LGCNativeGlassEngaged() ? Ame239GlassPanelBase()
                                                         : Ame237PanelBase();
    self.panel.layer.cornerRadius = 26.0;
    self.panel.layer.cornerCurve = kCACornerCurveContinuous;
    self.panel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panel.layer.shadowOpacity = 0.32;
    self.panel.layer.shadowRadius = 26.0;
    self.panel.layer.shadowOffset = CGSizeMake(0, 12);
    self.panel.clipsToBounds = NO;
    [self.view addSubview:self.panel];

    // ★ Task239：材质选择——玻璃风格优先【系统原生 UIGlassEffect】（iOS 26+，
    //   真液态玻璃：磨砂 + 折光 + 边缘高光一体的系统材质）；取不到
    //   （<iOS 26 / Task244 默认退役；AME239_FORCE_SYSTEM_GLASS=1 诊断
    //   才回取）回退 SystemMaterial
    //   磨砂（Task237 路径，装机验证可读）。原生风格不经过本组件——中央
    //   路由（ame237_hook_presentViewController）直通旧版系统弹窗。
    UIVisualEffect *ame239_effect = nil;
    if (LGCIsGlassStyleActive()) {
        ame239_effect = LGCNativeGlassEffect();
    }
    if (ame239_effect == nil) {
        ame239_effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:ame239_effect];
    self.blurView.userInteractionEnabled = NO;
    self.blurView.layer.cornerRadius = 26.0;
    self.blurView.layer.cornerCurve = kCACornerCurveContinuous;
    self.blurView.layer.masksToBounds = YES;
    [self.panel addSubview:self.blurView];   // index 0：恒在全部内容之下
    // ★ Task243：自绘磨砂层（呈现入口传入的 keyWindow 快照）。
    // ★ Task244（IMG_0379：26.3/27.0.1 弹窗恒纯黑定案）：UIGlassEffect 在
    //   本进程渲染为不透明黑块，把垫在它下面的快照整体盖死——层序改定
    //   【快照即成品磨砂】：有效性护栏（全黑帧视为抓帧失败）→ tint 浮
    //   其上（可读性，底色在快照下已无法压暗）→ 系统材质层整体隐藏
    //   （无论玻璃还是 SystemMaterial——快照已是成品磨砂，多叠一层只
    //   会再次引入“黑块/过糊”变量）。快照无效时回退材质磨砂护栏不变。
    UIImage *ame244_snapImg = self.ame243_snapshotImage;
    if (ame244_snapImg != nil && !Ame244SnapshotLooksValid(ame244_snapImg)) {
        NSLog(@"[AmeMenu] Task244: keyWindow snapshot blank (capture failure), fallback to material blur");
        ame244_snapImg = nil;
    }
    // ★ Task252：TG LegacyGlassView 配方接管（玻璃家族档 + 运行时支持）。
    //   启动器域 = 实况模式（CABackdropLayer 直采，零重抓开销）；游戏域 =
    //   快照供料（首帧沿用既有快照，8Hz 内升级 0.5x）。选项零改动：
    //   本分支只换面板渲染材质，呈现路由/命中/动画/动作链全不动。
    // ★ Task277：会话闸入列（Task260 双闸语义对齐）——<26 会话（老绘制链）
    //   上 TG backdrop 引擎 = Task260 病历崩溃面；镜像面板此前只查玻璃族
    //   档不查会话 = 游戏菜单面板有闸、镜像面板没闸的双标。闸内回退
    //   244/245 快照磨砂（前-252 世代配方，全版本安全）。
    GameSurfaceView *ame252_surface = [SurfaceViewController surface];
    BOOL ame252_overGame = (ame252_surface != nil && ame252_surface.window != nil);
    BOOL ame252_glassActive = LGCIsGlassStyleActive() &&
                              LGCGameSessionGlassAllowed() &&
                              [AmeLiquidGlassView ame252_isSupported];
    if (ame252_glassActive) {
        BOOL ame252_dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        self.ame252_glass = [AmeLiquidGlassView ame252_glassViewWithCornerRadius:26.0
                                                                          isDark:ame252_dark];
        if (self.ame252_glass != nil) {
            self.ame252_glass.frame = self.panel.bounds;
            self.ame252_glass.autoresizingMask =
                UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.panel insertSubview:self.ame252_glass atIndex:0];
            self.ame252_glassSnapshotMode = ame252_overGame;
            if (ame252_overGame) {
                // 首帧供料（0.18x 旧快照即用；8Hz tick 以 0.5x 跟进升级）
                self.ame252_glass.ame252_backdropSnapshot = ame244_snapImg;
            }
            // 面板底色退场：TG .panel 填充（玻璃内部）独立承载可读性；
            //   底色若保留会被 backdrop 一并采样（双层叠加 = 过闷）。
            //   防御面不丢：填充深色 0.85 / 浅色 0.70 即 TG 同款防御底。
            self.panel.backgroundColor = nil;
            self.blurView.hidden = YES;   // 系统材质层退场（TG 描边在玻璃内）
        } else {
            ame252_glassActive = NO;   // 构造失败（理论不可达）→ 旧管线
        }
    }
    if (!ame252_glassActive && ame244_snapImg != nil) {
        // ★ Task245（IMG_0380 用户定案“透视有问题”）：旧摆法 AspectFill
        //   居中裁剪 = 显示的是整屏快照的中心放大裁切，弹窗背后根本不是
        //   这个内容，几何错位的“假透视”。改【窗口对位真透视】：快照按
        //   窗口几何 1:1 铺进面板圆角裁剪容器（帧 = 窗口矩形映射到面板
        //   坐标，OverFullScreen 呈现下 self.view 即窗口大小），面板下每
        //   个像素 = 面板后方真实背景内容，叠二次柔化 + tint = 标准“背景
        //   折射”磨砂观感；面板挪位（键盘避让/旋转）由 ame237_layout 同
        //   步刷新帧。裁剪容器自担圆角裁剪（panel clipsToBounds=NO 为
        //   阴影保留，不能依赖面板裁剪；tint 一并收编进容器，方角溢出
        //   与旧 tint 独立设圆角的双份几何一并消除）。
        UIView *ame245_clip = [[UIView alloc] initWithFrame:self.panel.bounds];
        ame245_clip.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ame245_clip.layer.cornerRadius = 26.0;
        ame245_clip.layer.cornerCurve = kCACornerCurveContinuous;
        ame245_clip.layer.masksToBounds = YES;
        ame245_clip.userInteractionEnabled = NO;
        // ★ Task277（玻璃感三件之三·发丝描边）：玻璃边缘的光学定义——
        //   面板轮廓从"贴图感"变"玻璃片感"。0.75pt，深色白 0.16 / 浅色白
        //   0.45（TG rim 同源浓度档；瞬时面板按构建时 trait 取值即可）。
        {
            BOOL ame277_dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
            ame245_clip.layer.borderWidth = 0.75;
            ame245_clip.layer.borderColor =
                [UIColor colorWithWhite:1.0 alpha:(ame277_dark ? 0.16 : 0.45)].CGColor;
        }

        UIImageView *ame245_snap = [[UIImageView alloc] initWithFrame:
            CGRectMake(-self.panel.frame.origin.x, -self.panel.frame.origin.y,
                       self.view.bounds.size.width, self.view.bounds.size.height)];
        ame245_snap.image = Ame277MaterializeSnapshot(ame244_snapImg);
        ame245_snap.contentMode = UIViewContentModeScaleToFill;
        ame245_snap.userInteractionEnabled = NO;
        [ame245_clip addSubview:ame245_snap];

        UIView *ame244_tint = [[UIView alloc] initWithFrame:self.panel.bounds];
        ame244_tint.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ame244_tint.backgroundColor = Ame244SnapshotTint();
        ame244_tint.userInteractionEnabled = NO;
        ame244_tint.tag = 244;   // ★ Task276：通知重铺定位锚（viewWithTag）
        [ame245_clip addSubview:ame244_tint];

        // ★ Task277（玻璃感三件之二·顶部光泽线）：iOS 玻璃材质的顶缘受光
        //   特征——白色线性渐变自顶部快速衰减，深色 0.10/浅色 0.16 起点，
        //   32% 高度衰减到零。浮于 tint 之上、内容之下；梯度色随深浅色
        //   动态提供（dynamic provider CGColor 首帧解析，深浅切换由
        //   ame244 tint 同款重铺面覆盖；光泽层无状态，零维护成本）。
        UIView *ame277_sheenHost = [[UIView alloc] initWithFrame:
            CGRectMake(0.0, 0.0, self.panel.bounds.size.width,
                       self.panel.bounds.size.height * 0.32)];
        ame277_sheenHost.userInteractionEnabled = NO;
        ame277_sheenHost.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        CAGradientLayer *ame277_sheen = [CAGradientLayer layer];
        ame277_sheen.frame = ame277_sheenHost.bounds;
        ame277_sheen.colors = @[(id)[UIColor colorWithDynamicProvider:
                                     ^UIColor * (UITraitCollection *tc) {
            return [UIColor colorWithWhite:1.0
                                     alpha:(tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? 0.10 : 0.16];
        }].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        ame277_sheen.locations = @[@0.0, @1.0];
        ame277_sheen.startPoint = CGPointMake(0.5, 0.0);
        ame277_sheen.endPoint = CGPointMake(0.5, 1.0);
        ame277_sheen.name = @"ame277_sheen";
        [ame277_sheenHost.layer addSublayer:ame277_sheen];
        [ame245_clip addSubview:ame277_sheenHost];

        // ★ Task278（“玻璃感”快照路径同步·底部景深内影）：与 TG 玻璃面
        //   同配方——黑色渐变自底缘向上 24% 内衰减到零（深 0.14 / 浅 0.08），
        //   玻璃片厚度暗部线索；autoresizing 宽高随 clip，零维护。
        {
            BOOL ame278_dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
            UIView *ame278_depthHost = [[UIView alloc] initWithFrame:
                CGRectMake(0.0, self.panel.bounds.size.height * 0.76,
                           self.panel.bounds.size.width,
                           self.panel.bounds.size.height * 0.24)];
            ame278_depthHost.userInteractionEnabled = NO;
            ame278_depthHost.autoresizingMask =
                UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
            CAGradientLayer *ame278_depth = [CAGradientLayer layer];
            ame278_depth.frame = ame278_depthHost.bounds;
            ame278_depth.name = @"ame278_depth";
            ame278_depth.startPoint = CGPointMake(0.5, 0.0);
            ame278_depth.endPoint = CGPointMake(0.5, 1.0);
            ame278_depth.colors = @[(id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
                (id)[UIColor colorWithWhite:0.0 alpha:(ame278_dark ? 0.14 : 0.08)].CGColor];
            ame278_depth.locations = @[@0.0, @1.0];
            [ame278_depthHost.layer addSublayer:ame278_depth];
            [ame245_clip addSubview:ame278_depthHost];
        }

        self.ame245_frostClip = ame245_clip;
        self.ame245_frostSnap = ame245_snap;
        [self.panel insertSubview:ame245_clip belowSubview:self.blurView];
        self.blurView.hidden = YES;   // 快照成品磨砂上岗，系统材质层退场
    }
    NSLog(@"[AmeMenu] Task252 menu material: %@ (style=%@, background=%@)",
          ame252_glassActive ? (self.ame252_glassSnapshotMode ? @"TG liquid glass (snapshot feed)"
                                                              : @"TG liquid glass (live backdrop)")
          : (LGCNativeGlassEngaged() ? @"native UIGlassEffect (force-enabled, diagnostic)"
                                     : @"SystemMaterial fallback"),
          LGCIsGlassStyleActive() ? @"glass" : @"native",
          ame244_snapImg != nil ? @"frost-snapshot+tint" : @"material-blur");

    // 内容
    if (self.ame237_title.length > 0) {
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.text = self.ame237_title;
        self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.numberOfLines = 0;
        [self.panel addSubview:self.titleLabel];
    }
    if (self.ame237_message.length > 0) {
        self.messageLabel = [[UILabel alloc] init];
        self.messageLabel.text = self.ame237_message;
        self.messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        self.messageLabel.textColor = [UIColor secondaryLabelColor];
        self.messageLabel.textAlignment = NSTextAlignmentCenter;
        self.messageLabel.numberOfLines = 0;
        [self.panel addSubview:self.messageLabel];
    }

    // 镜像输入框（alert 自有字段仅作数据源；本组件字段负责交互并双向同步）
    self.mirrorFields = [NSMutableArray array];
    for (UITextField *src in self.ame237_alertFields) {
        if (![src isKindOfClass:[UITextField class]]) continue;
        UITextField *f = [[UITextField alloc] init];
        f.font = [UIFont systemFontOfSize:15];
        f.textColor = [UIColor labelColor];
        f.placeholder = src.placeholder;
        f.text = src.text;
        f.secureTextEntry = src.secureTextEntry;
        f.keyboardType = src.keyboardType;
        f.autocapitalizationType = src.autocapitalizationType;
        f.autocorrectionType = src.autocorrectionType;
        f.clearButtonMode = src.clearButtonMode;
        f.returnKeyType = src.returnKeyType;
        f.tag = src.tag;
        f.backgroundColor = Ame237Dyn(0.12, 0.06);
        f.layer.cornerRadius = 10.0;
        f.layer.borderWidth = 0.5;
        f.layer.borderColor = Ame237Dyn(0.25, 0.12).CGColor;
        f.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *leftPad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
        f.leftView = leftPad;
        f.leftViewMode = UITextFieldViewModeAlways;
        f.rightViewMode = UITextFieldViewModeAlways;
        [f addTarget:self action:@selector(ame237_fieldChanged:)
            forControlEvents:UIControlEventEditingChanged];
        [self.mirrorFields addObject:f];
        [self.panel addSubview:f];
    }

    // 菜单行（唯一滚动区；高度足够时禁用滚动 = 平铺）
    // ★ Task271（271-b D1）：Ame237Scroll = touchesShouldCancel 放行子类，
    //   UIControl 行铺满滚动区时拖动也能起滚（否则行区无空白起拖点）。
    self.rowsScroll = [[Ame237Scroll alloc] init];
    self.rowsScroll.showsVerticalScrollIndicator = NO;
    self.rowsScroll.delaysContentTouches = NO;
    self.rowsScroll.layer.cornerRadius = 16.0;
    self.rowsScroll.layer.masksToBounds = YES;
    [self.panel addSubview:self.rowsScroll];

    self.rows = [NSMutableArray array];
    self.separators = [NSMutableArray array];
    NSUInteger idx = 0;
    for (Ame237MenuActionMirror *m in self.ame237_actions) {
        Ame237MenuRow *row = [[Ame237MenuRow alloc] init];
        BOOL checked = (m.title.length > 0 && [m.title hasPrefix:@"\u2713"]);
        NSString *norm = [AmeFloatingMenu iconNameForTitle:m.title];
        NSString *iconName = checked ? @"checkmark.circle.fill" : norm;
        if (iconName == nil) {
            iconName = (m.style == 2) ? @"exclamationmark.circle"
                     : (m.style == 1) ? @"xmark.circle"
                     : @"circle.dotted";
        }
        UIImage *icon = [AmeFloatingMenu symbolImageForName:iconName];
        UIColor *textColor = (m.style == 2) ? [UIColor systemRedColor] : [UIColor labelColor];
        // ★ Task250（反馈 5：恢复主题强调色适配）：符号 tint 从硬编码
        //   systemBlueColor 改为主题强调色（accentColor()，与设置页/右栏
        //   启动按钮同源）——伪玻璃档全接管后本面板是用户最高频的菜单面，
        //   主题色必须跟随；destructive 红/取消灰语义不变。
        UIColor *symbolTint = (m.style == 2) ? [UIColor systemRedColor]
                            : (m.style == 1) ? [UIColor secondaryLabelColor]
                            : accentColor();
        [row ame237_configureWithIcon:icon
                                title:(m.title.length > 0 ? m.title : @"")
                            textColor:textColor
                          symbolTint:symbolTint
                             emphasis:(m.style == 1 || checked)];
        row.tag = (NSInteger)idx;
        row.enabled = m.enabled;
        row.alpha = m.enabled ? 1.0 : 0.4;
        [row addTarget:self action:@selector(ame237_rowTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [self.rowsScroll addSubview:row];
        [self.rows addObject:row];
        if (idx + 1 < self.ame237_actions.count) {
            UIView *sep = [[UIView alloc] init];
            sep.backgroundColor = Ame237Dyn(0.16, 0.10);
            sep.userInteractionEnabled = NO;
            [self.rowsScroll addSubview:sep];
            [self.separators addObject:sep];
        }
        idx++;
    }

    // 发丝描边覆盖环（最上层；空心底环不遮内容、不参与命中）
    self.borderOverlay = [[UIView alloc] init];
    self.borderOverlay.backgroundColor = [UIColor clearColor];
    self.borderOverlay.layer.cornerRadius = 26.0;
    self.borderOverlay.layer.cornerCurve = kCACornerCurveContinuous;
    self.borderOverlay.layer.borderWidth = 0.75;
    self.borderOverlay.layer.borderColor = Ame237Dyn(0.30, 0.10).CGColor;
    self.borderOverlay.userInteractionEnabled = NO;
    // ★ Task252：TG 玻璃接管时自带 0.8pt 描边环，旧发丝环退场。
    self.borderOverlay.hidden = (self.ame252_glass != nil);
    [self.panel addSubview:self.borderOverlay];

    // 入场初始态（viewDidAppear 前不可见——无动画路径在此直接摆正）
    if (self.ame237_animated) {
        self.dimView.alpha = 0.0;
        self.panel.alpha = 0.0;
        self.panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } else {
        self.dimView.alpha = 1.0;
        self.panel.alpha = 1.0;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame237_keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame237_keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
    // ★ Task276：伪玻璃透明度变化 → 在屏面板快照 tint 即时重铺
    //（TG 玻璃填充层由 AmeLiquidGlassView 自监听重铺，两路同源通知）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame263TransparencyChanged:)
                                                 name:LGCPseudoGlassTransparencyChangedNotification
                                               object:nil];
}

/// ★ Task276：滑条拖动 → 在屏快照磨砂面板 tint 即时重铺（tag 244 定位）。
- (void)ame263TransparencyChanged:(NSNotification *)note {
    UIView *ame263_tint = [self.ame245_frostClip viewWithTag:244];
    if (ame263_tint != nil) ame263_tint.backgroundColor = Ame244SnapshotTint();
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.ame246_refreshLink invalidate];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self ame237_layout];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.ame237_didEntrance) return;
    self.ame237_didEntrance = YES;
    if (self.ame237_animated) {
        [UIView animateWithDuration:0.20 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.dimView.alpha = 1.0;
        } completion:nil];
        [UIView animateWithDuration:0.38 delay:0
             usingSpringWithDamping:0.80 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.panel.alpha = 1.0;
            self.panel.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        self.dimView.alpha = 1.0;
        self.panel.alpha = 1.0;
        self.panel.transform = CGAffineTransformIdentity;
    }
    // ★ Task246：呈现完成后启动动态背景重抓（8Hz；背景变化/面板挪位后
    //   磨砂原料持续跟上）。逐帧窗口快照会把自家面板拍进去（自噬），
    //   重抓源 = presentingViewController.view（OverFullScreen 下恒在
    //   本组件之下，纯背景内容）。
    [self ame246_startBackgroundRefresh];
    if (self.mirrorFields.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.mirrorFields.firstObject becomeFirstResponder];
        });
    }
}

#pragma mark - Task246 动态背景重抓

/// ★ Task252：深浅色切换实时跟随（动态填充色自随系统；描边浓度手动重刷）。
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.ame252_glass != nil && previousTraitCollection != nil &&
        previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        BOOL ame252_dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        self.ame252_glass.ame252_dark = ame252_dark;
    }
}

- (void)ame246_startBackgroundRefresh {
    // ★ Task252：TG 玻璃实况模式下 CABackdropLayer 直采窗口内容，无需重抓；
    //   快照供料模式（游戏域）仍需 8Hz 供料。
    if (self.ame252_glass != nil && !self.ame252_glassSnapshotMode) return;
    if (self.ame246_refreshLink != nil) return;
    CADisplayLink *ame246_link = [CADisplayLink
        displayLinkWithTarget:self
                     selector:@selector(ame246_refreshTick)];
    if (@available(iOS 10.0, *)) {
        ame246_link.preferredFramesPerSecond = 8;   // 8Hz：磨砂观感足够连贯，功耗可忽略
    }
    [ame246_link addToRunLoop:[NSRunLoop mainRunLoop]
                      forMode:NSRunLoopCommonModes];
    self.ame246_refreshLink = ame246_link;
    NSLog(@"[AmeMenu] Task246 dynamic frost refresh engaged (8Hz, presenter-view source)");
}

- (void)ame246_stopBackgroundRefresh {
    [self.ame246_refreshLink invalidate];
    self.ame246_refreshLink = nil;
}

- (void)ame246_refreshTick {
    // ★ Task275（P1-b3）：离窗自停——外部 dismiss（未走 ame237_dismissWithAction 的
    //   路径，如被父链 dismiss/游戏退出链式收口）后 view.window==nil 仅 early-return
    //   不停链 = displayLink target:self 强持 self，dealloc 永不可达，8Hz 快照空转
    //   永久泄 VC+runloop 源（ame247/ame250 同款护栏平移）。
    if (self.view.window == nil) {
        NSLog(@"[AmeMenu] Task275: frost refresh link self-stopped (window detached)");
        [self ame246_stopBackgroundRefresh];
        return;
    }
    // ★ Task252：TG 玻璃分支——快照供料模式以 0.5x 原料持续喂 glass
    //   （滤镜栈自带微模糊+colorMatrix，原料保留真实细节供边缘折射）；
    //   实况模式无需重抓（链接在 start 处已短路，此为兑底）。
    if (self.ame252_glass != nil) {
        if (self.ame237_dismissing || !self.ame252_glassSnapshotMode) return;
        UIView *ame252_bg = self.presentingViewController.view;
        if (ame252_bg == nil || ame252_bg.window == nil) return;
        UIImage *ame252_fresh = Ame252GlassFeedSnapshot(ame252_bg);
        if (ame252_fresh != nil && !Ame244SnapshotLooksValid(ame252_fresh)) return;
        if (ame252_fresh != nil) {
            self.ame252_glass.ame252_backdropSnapshot = ame252_fresh;
        }
        return;
    }
    if (self.ame237_dismissing || self.ame245_frostSnap == nil) return;
    UIView *ame246_bg = self.presentingViewController.view;
    UIWindow *ame246_win = self.view.window;
    if (ame246_bg == nil || ame246_bg.window == nil || ame246_win == nil) return;
    // 几何一致性护栏：呈现方视图与窗口不同大（理论边缘）时映射不再
    // 1:1，保持首帧窗口快照不动（宁旧勿错位）。
    if (fabs(ame246_bg.bounds.size.width - ame246_win.bounds.size.width) > 1.0 ||
        fabs(ame246_bg.bounds.size.height - ame246_win.bounds.size.height) > 1.0) return;
    UIImage *ame246_fresh = Ame246PresenterViewSnapshot(ame246_bg);
    // 全黑帧护栏（Metal 游戏面 drawViewHierarchy 不渲染内容）：保留上一张
    // 有效图，绝不降级为黑磨砂（Task244 家族护栏同源）。
    if (!Ame244SnapshotLooksValid(ame246_fresh)) return;
    self.ame245_frostSnap.image = Ame277MaterializeSnapshot(ame246_fresh);
}

#pragma mark - 布局（纯 frame：无 Auto Layout 约束竞态）

- (void)ame237_layout {
    CGFloat bw = self.view.bounds.size.width;
    CGFloat bh = self.view.bounds.size.height;
    if (bw < 40.0 || bh < 40.0) return;
    CGFloat W = MIN(bw - 56.0, 342.0);
    CGFloat textW = W - 44.0;

    BOOL hasHeader = (self.titleLabel != nil || self.messageLabel != nil || self.mirrorFields.count > 0);
    CGFloat y = hasHeader ? 20.0 : 14.0;

    if (self.titleLabel != nil) {
        CGFloat h = Ame237TextHeight(self.ame237_title, self.titleLabel.font, textW);
        self.titleLabel.frame = CGRectMake(22.0, y, textW, h);
        y += h + 6.0;
    }
    if (self.messageLabel != nil) {
        CGFloat h = Ame237TextHeight(self.ame237_message, self.messageLabel.font, textW);
        self.messageLabel.frame = CGRectMake(22.0, y, textW, h);
        y += h + 4.0;
    }
    if (self.mirrorFields.count > 0) {
        if (self.titleLabel != nil || self.messageLabel != nil) y += 8.0;
        for (NSUInteger i = 0; i < self.mirrorFields.count; i++) {
            UITextField *f = self.mirrorFields[i];
            f.frame = CGRectMake(22.0, y, textW, 38.0);
            y += 38.0 + ((i + 1 < self.mirrorFields.count) ? 8.0 : 0.0);
        }
        y += 14.0;
    }

    CGFloat rowsTop = y;
    NSUInteger n = self.rows.count;
    CGFloat rowsH = n * 50.0 + (n > 1 ? (n - 1) * 0.5 : 0.0);
    CGFloat bottomInset = 10.0;
    CGFloat contentH = rowsTop + rowsH + bottomInset;
    CGFloat maxH = floor(bh * 0.72);
    CGFloat panelH = MIN(contentH, maxH);
    // ★ Task271（271-b D3）：标题/输入区过高时保证行区最小可用视口——
    //   旧钳制 rowsAvail<50 时只补回 10pt inset，长标题+多输入框+小窗口
    //   （iPad 分屏/窗口模式）会塌缩到 0：全部行隐藏且无法滚动。
    CGFloat rowsAvail = panelH - rowsTop - bottomInset;
    if (rowsAvail < 100.0) {
        CGFloat ame271_want = MIN(bh - 24.0, rowsTop + 110.0 + bottomInset);
        panelH = MAX(panelH, MIN(ame271_want, contentH));
        rowsAvail = MAX(0.0, panelH - rowsTop - bottomInset);
    }

    self.panel.frame = CGRectMake((bw - W) / 2.0, (bh - panelH) / 2.0, W, panelH);
    if (self.ame237_kbShift > 0.0) {
        self.panel.frame = CGRectOffset(self.panel.frame, 0.0, -self.ame237_kbShift);
    }
    // ★ Task252：TG 玻璃供料对位（窗口对位真透视，与下方 frostSnap 同源几何）
    //   + 确定性阴影路径（底色已置 nil，阴影由玻璃内容派生需显式定形）。
    if (self.ame252_glass != nil) {
        if (self.ame252_glassSnapshotMode) {
            self.ame252_glass.ame252_backdropSourceRect =
                CGRectMake(-self.panel.frame.origin.x, -self.panel.frame.origin.y, bw, bh);
        }
        self.panel.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:self.panel.bounds
                                       cornerRadius:26.0].CGPath;
    }
    self.blurView.frame = self.panel.bounds;
    // ★ Task245：窗口对位磨砂帧刷新（面板挪位/旋转/键盘避让后，快照与
    //   窗口几何保持 1:1 对位——“玻璃折射”不随面板位移错位；首次布局
    //   时 viewDidLoad 阶段的临时帧也在此修正，先于 CA 提交无闪烁）。
    if (self.ame245_frostSnap != nil) {
        self.ame245_frostSnap.frame =
            CGRectMake(-self.panel.frame.origin.x, -self.panel.frame.origin.y,
                       bw, bh);
    }
    self.borderOverlay.frame = self.panel.bounds;
    self.rowsScroll.frame = CGRectMake(0.0, rowsTop, W, rowsAvail);
    self.rowsScroll.contentSize = CGSizeMake(W, rowsH);
    self.rowsScroll.scrollEnabled = (rowsH > rowsAvail + 0.5);
    // ★ Task271（271-b D5）：可滚时给出指示器/可达性暗示（旧版恒隐藏 =
    //   用户无从得知折叠区外还有条目）。
    self.rowsScroll.showsVerticalScrollIndicator = self.rowsScroll.isScrollEnabled;
    if (self.rowsScroll.isScrollEnabled && self.rowsScroll.contentOffset.y > rowsH - rowsAvail) {
        self.rowsScroll.contentOffset = CGPointMake(0.0, MAX(0.0, rowsH - rowsAvail));
    }

    CGFloat ry = 0.0;
    for (NSUInteger i = 0; i < n; i++) {
        Ame237MenuRow *row = self.rows[i];
        row.frame = CGRectMake(0.0, ry, W, 50.0);
        ry += 50.0;
        if (i < self.separators.count) {
            UIView *sep = self.separators[i];
            sep.frame = CGRectMake(22.0, ry, W - 44.0, 0.5);
            ry += 0.5;
        }
    }

    static int ame237_layoutLog = 0;
    ame237_layoutLog++;
    if (ame237_layoutLog <= 5 || ame237_layoutLog % 25 == 0) {
        NSLog(@"[AmeMenu] Task237 panel layout #%d (panel=%@ rows=%lu avail=%.0f scroll=%d)",
              ame237_layoutLog, NSStringFromCGRect(self.panel.frame),
              (unsigned long)n, (double)rowsAvail, (int)self.rowsScroll.isScrollEnabled);
    }
}

#pragma mark - 键盘避让

- (void)ame237_keyboardWillShow:(NSNotification *)note {
    if (self.view.window == nil) return;
    NSValue *frameValue = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    NSNumber *durationValue = note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) return;
    CGRect kbFrame = [frameValue CGRectValue];
    CGFloat kbTop = [self.view convertRect:kbFrame fromView:nil].origin.y;
    if (kbTop <= 0.0) return;
    CGFloat overlap = CGRectGetMaxY(self.panel.frame) - kbTop + 12.0;
    if (overlap <= 0.0 || self.ame237_kbShift > 0.0) return;
    self.ame237_kbShift = overlap;
    NSTimeInterval dur = durationValue ? durationValue.doubleValue : 0.25;
    [UIView animateWithDuration:dur delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.panel.frame = CGRectOffset(self.panel.frame, 0.0, -overlap);
        // ★ Task246：磨砂快照帧随面板位移动画同步走位（窗口对位 1:1 不
        //   在动画期间脱钩——“背景不随窗口位置变化”根治的动画侧）。
        self.ame245_frostSnap.frame =
            CGRectMake(-self.panel.frame.origin.x, -self.panel.frame.origin.y,
                       self.view.bounds.size.width, self.view.bounds.size.height);
    } completion:nil];
}

- (void)ame237_keyboardWillHide:(NSNotification *)note {
    if (self.view.window == nil) return;
    if (self.ame237_kbShift <= 0.0) return;
    CGFloat shift = self.ame237_kbShift;
    self.ame237_kbShift = 0.0;
    NSNumber *durationValue = note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
    NSTimeInterval dur = durationValue ? durationValue.doubleValue : 0.25;
    [UIView animateWithDuration:dur delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.panel.frame = CGRectOffset(self.panel.frame, 0.0, shift);
        // ★ Task246：归位侧同帧跟踪（与 show 侧对称）。
        self.ame245_frostSnap.frame =
            CGRectMake(-self.panel.frame.origin.x, -self.panel.frame.origin.y,
                       self.view.bounds.size.width, self.view.bounds.size.height);
    } completion:nil];
}

#pragma mark - 交互

- (void)ame237_fieldChanged:(UITextField *)mirrorField {
    NSUInteger i = [self.mirrorFields indexOfObject:mirrorField];
    if (i != NSNotFound && i < self.ame237_alertFields.count) {
        UITextField *src = self.ame237_alertFields[i];
        if ([src isKindOfClass:[UITextField class]]) src.text = mirrorField.text;
    }
}

- (void)ame237_syncAllFields {
    NSUInteger n = MIN(self.mirrorFields.count, self.ame237_alertFields.count);
    for (NSUInteger i = 0; i < n; i++) {
        UITextField *src = self.ame237_alertFields[i];
        if ([src isKindOfClass:[UITextField class]]) src.text = self.mirrorFields[i].text;
    }
}

/// ★ Task247（T9）：镜像面板 message 动态更新（重跑布局，面板高度随文本
///   自适应；首次建面板时 message 为空未建标签的场景仅更新数据源，不
///   补建标签——进度弹窗带初始 message 建面板，标签恒在场）。
- (void)ame247_updateMessage:(nullable NSString *)message {
    self.ame237_message = message;
    if (self.messageLabel != nil) {
        self.messageLabel.text = message ?: @"";
        self.messageLabel.hidden = (message.length == 0);
    }
    if (self.viewLoaded) [self ame237_layout];
}

- (void)ame237_rowTapped:(Ame237MenuRow *)sender {
    if (self.ame237_dismissing) return;
    NSInteger i = sender.tag;
    if (i < 0 || (NSUInteger)i >= self.ame237_actions.count) return;
    [self ame237_dismissWithAction:self.ame237_actions[i]];
}

- (void)ame237_dimTapped {
    if (self.ame237_dismissing) return;
    Ame237MenuActionMirror *cancel = nil;
    for (Ame237MenuActionMirror *m in self.ame237_actions) {
        if (m.style == 1) { cancel = m; break; }
    }
    [self ame237_dismissWithAction:cancel];
}

- (void)ame237_dismissWithAction:(nullable Ame237MenuActionMirror *)action {
    if (self.ame237_dismissing) return;
    self.ame237_dismissing = YES;
    [self ame246_stopBackgroundRefresh];   // Task246：退场即停重抓
    [self ame237_syncAllFields];
    [self.view endEditing:YES];
    void (^finish)(void) = ^{
        [self dismissViewControllerAnimated:NO completion:^{
            if (action != nil && action.handler != nil) {
                action.handler(action.orig);
            }
            // ★ Task242：未选中实质动作（dim 点按 = nil；cancel 项 = style 1）
            //   而关闭 → 回调 onDismiss（取消语义；实质动作关闭不回调）。
            if (self.ame237_onDismiss) {
                BOOL ame242_fired = (action != nil && action.style != 1);
                if (!ame242_fired) self.ame237_onDismiss();
            }
        }];
    };
    if (self.ame237_animated) {
        [UIView animateWithDuration:0.18 delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            self.dimView.alpha = 0.0;
            self.panel.alpha = 0.0;
            self.panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
        } completion:^(BOOL finished) {
            finish();
        }];
    } else {
        finish();
    }
}

@end

#pragma mark - 图标启发式（标题语义 → SF Symbol）

@implementation AmeFloatingMenu

/// ★ Task277：材质链跨文件导出（游戏内菜单 +Navigation 共用同一配方；
///   Ame277MaterializeSnapshot 为本文件静态函数，见文件头部）。
+ (UIImage *)ame277_materializeSnapshot:(UIImage *)snapshot {
    return Ame277MaterializeSnapshot(snapshot);
}

+ (NSString *)iconNameForTitle:(NSString *)title {
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return nil;
    // 归一化：剥 ✓ 与空白，小写
    static NSCharacterSet *trim = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trim = [NSCharacterSet characterSetWithCharactersInString:@"\u2713\u00a0 \t"];
    });
    NSString *t = [[title stringByTrimmingCharactersInSet:trim] lowercaseString];
    if (t.length == 0) return nil;

    // 有序规则表（含 CJK 关键词子串匹配 / 短 ASCII 词精确匹配）
    static NSArray<NSArray<NSString *> *> *rules = nil;
    static dispatch_once_t rulesOnce;
    dispatch_once(&rulesOnce, ^{
        rules = @[
            @[@"\u53d6\u6d88", @"xmark.circle"],            // 取消
            @[@"cancel", @"xmark.circle"],
            @[@"\u5173\u95ed", @"xmark.circle"],            // 关闭
            @[@"\u5220\u9664", @"trash.fill"],              // 删除
            @[@"delete", @"trash.fill"],
            @[@"\u79fb\u9664", @"trash.fill"],              // 移除
            @[@"remove", @"trash.fill"],
            @[@"\u6e05\u9664", @"trash.fill"],              // 清除
            @[@"\u786e\u5b9a", @"checkmark.circle.fill"],   // 确定
            @[@"\u786e\u8ba4", @"checkmark.circle.fill"],   // 确认
            @[@"\u597d\u7684", @"checkmark.circle.fill"],   // 好的
            @[@"\u4fdd\u5b58", @"square.and.arrow.down"],   // 保存
            @[@"save", @"square.and.arrow.down"],
            @[@"\u5206\u4eab", @"square.and.arrow.up"],     // 分享
            @[@"share", @"square.and.arrow.up"],
            @[@"\u590d\u5236", @"doc.on.doc"],              // 复制
            @[@"copy", @"doc.on.doc"],
            @[@"\u62f7\u8d1d", @"doc.on.doc"],              // 拷贝
            @[@"\u7f16\u8f91", @"pencil"],                  // 编辑
            @[@"edit", @"pencil"],
            @[@"\u91cd\u547d\u540d", @"pencil"],            // 重命名
            @[@"rename", @"pencil"],
            @[@"\u4e0b\u8f7d", @"arrow.down.circle"],       // 下载
            @[@"download", @"arrow.down.circle"],
            @[@"\u6253\u5f00", @"folder"],                  // 打开
            @[@"open", @"folder"],
            @[@"\u6d4f\u89c8", @"safari"],                  // 浏览（浏览器打开）
            @[@"browser", @"safari"],
            @[@"\u66f4\u591a", @"ellipsis.circle"],         // 更多
            @[@"more", @"ellipsis.circle"],
            @[@"\u9000\u51fa", @"power"],                   // 退出
            @[@"quit", @"power"],
            @[@"exit", @"power"],
            @[@"\u5f3a\u5236\u5173\u95ed", @"power"],      // 强制关闭
            @[@"force close", @"power"],
            @[@"\u767b\u5f55", @"person.crop.circle"],      // 登录
            @[@"login", @"person.crop.circle"],
            @[@"log in", @"person.crop.circle"],
            @[@"\u5e2e\u52a9", @"questionmark.circle"],     // 帮助
            @[@"help", @"questionmark.circle"],
            @[@"\u662f", @"checkmark.circle.fill"],         // 是
            @[@"yes", @"checkmark.circle.fill"],
            @[@"\u5426", @"xmark.circle"],                  // 否
            @[@"no", @"xmark.circle"],
            @[@"ok", @"checkmark.circle.fill"],
            @[@"done", @"checkmark.circle.fill"],
        ];
    });

    for (NSArray<NSString *> *r in rules) {
        NSString *kw = r[0];
        BOOL isCJK = ([kw lengthOfBytesUsingEncoding:NSUTF8StringEncoding] != kw.length);
        if (isCJK || kw.length > 5) {
            if ([t containsString:kw]) return r[1];
        } else {
            if ([t isEqualToString:kw]) return r[1];
        }
    }
    return nil;
}

+ (UIImage *)symbolImageForName:(NSString *)name {
    if (name.length == 0) return nil;
    UIImage *img = [UIImage systemImageNamed:name];
    if (img == nil) img = [UIImage systemImageNamed:@"circle"];
    if (img == nil) return nil;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIFontWeightMedium];
    UIImage *scaled = [img imageByApplyingSymbolConfiguration:cfg];
    return scaled ?: img;
}

+ (BOOL)presentGlassMenuForAlert:(UIAlertController *)alert
                   fromPresenter:(UIViewController *)presenter
                         animated:(BOOL)animated
                       completion:(nullable void (^)(void))completion {
    // ★ Task242：旧四参变体转发（无取消语义，中央路由弹窗接管沿用）。
    return [self presentGlassMenuForAlert:alert fromPresenter:presenter
                                 animated:animated completion:completion
                                onDismiss:nil];
}

+ (BOOL)presentGlassMenuForAlert:(UIAlertController *)alert
                   fromPresenter:(UIViewController *)presenter
                         animated:(BOOL)animated
                       completion:(nullable void (^)(void))completion
                        onDismiss:(nullable void (^)(void))onDismiss {
    if (![alert isKindOfClass:[UIAlertController class]]) return NO;
    if (presenter == nil) return NO;
    // ★ Task277（"连点卡出伪玻璃"·busy 守卫）：呈现方顶端已有控制器在屏/
    //    在收（连点双触发/重入窗口收尾期）时不再镜像——镜像叠镜像 = 面板
    //    卡死/双面板；回 NO 走中央路由原生直通（UIKit 既有语义自行裁决）。
    //    Task271 的 AmeNativeMenu（统一菜单呈现器）busy 重试护栏同族，此处是镜像侧对位。
    if (presenter.presentedViewController != nil) {
        NSLog(@"[AmeMenu] Task277: presenter busy (presented=%@) -- mirror skipped, native passthrough",
              NSStringFromClass(presenter.presentedViewController.class));
        return NO;
    }

    // 镜像动作（UIAlertAction 无公有读取口，走 KVC；任何异常整体回退原生）
    NSMutableArray<Ame237MenuActionMirror *> *mirrors = [NSMutableArray array];
    @try {
        for (UIAlertAction *a in alert.actions) {
            if (![a isKindOfClass:[UIAlertAction class]]) continue;
            Ame237MenuActionMirror *m = [[Ame237MenuActionMirror alloc] init];
            m.orig = a;
            id titleObj = [a valueForKey:@"title"];
            if ([titleObj isKindOfClass:[NSString class]]) m.title = titleObj;
            id styleObj = [a valueForKey:@"style"];
            if ([styleObj isKindOfClass:[NSNumber class]]) m.style = [(NSNumber *)styleObj integerValue];
            id handlerObj = [a valueForKey:@"handler"];
            if (handlerObj != nil) m.handler = handlerObj;
            id enabledObj = [a valueForKey:@"enabled"];
            if ([enabledObj isKindOfClass:[NSNumber class]]) {
                m.enabled = [(NSNumber *)enabledObj boolValue];
            } else {
                m.enabled = YES;
            }
            [mirrors addObject:m];
        }
    } @catch (NSException *e) {
        NSLog(@"[AmeMenu] Task237 action mirror failed (%@) -- native passthrough", e.name);
        return NO;
    }
    if (mirrors.count == 0) return NO;

    Ame237GlassMenuViewController *menu = [[Ame237GlassMenuViewController alloc] init];
    menu.ame237_title = alert.title;
    menu.ame237_message = alert.message;
    menu.ame237_actions = [mirrors copy];
    menu.ame237_alertFields = [alert.textFields copy];
    menu.ame237_sourceAlert = alert;   // ★ Task247（T9）：动态通路定位锚
    menu.ame237_animated = animated;
    // ★ Task242：取消语义接线（未选实质动作关闭 → onDismiss，见 .h；
    //   调用方 = 统一菜单呈现器玻璃档分轨）。
    menu.ame237_onDismiss = onDismiss;
    // ★ Task243：present 动画开始前抓帧（此时 presenter 的窗口内容仍是
    //   呈现前的画面，无自噬风险）——重度降采样快照作为面板自绘磨砂。
    //   抓帧失败（nil）保持面板深色底现状；桌面/普通窗口上系统磨砂
    //   本就合成，快照叠加观感中性。
    menu.ame243_snapshotImage = Ame243BlurredKeyWindowSnapshot(presenter.view);
    // 注：presenter.view 为 nil（理论边缘）时函数内 hostView.window == nil
    // 直接返回 nil，面板走深色底护栏——无需额外兜底分支（类方法内 self
    // 是 Class 不能写 self.view，Task 243 CI r1 实证）。
    menu.modalPresentationStyle = UIModalPresentationOverFullScreen;
    menu.modalPresentationCapturesStatusBarAppearance = NO;

    // 本组件自带入场/退场动画——UIKit 侧恒无动画呈现，避免双重转场
    [presenter presentViewController:menu animated:NO completion:^{
        if (completion != nil) completion();
    }];

    static int replacedCount = 0;
    replacedCount++;
    if (replacedCount <= 5 || replacedCount % 25 == 0) {
        NSLog(@"[AmeMenu] Task237 glass menu replaced native alert #%d (alertStyle=%ld actions=%lu fields=%lu title=%@)",
              replacedCount, (long)alert.preferredStyle, (unsigned long)mirrors.count,
              (unsigned long)alert.textFields.count, alert.title);
    }
    return YES;
}

#pragma mark - Task247 镜像 alert 动态通路

// 沿场景呈现链查找 sourceAlert 匹配的已上屏镜像面板。
+ (nullable Ame237GlassMenuViewController *)ame247_findMirrorForAlert:(UIAlertController *)alert {
    if (alert == nil) return nil;
    for (UIScene *ame247_scene in UIApplication.sharedApplication.connectedScenes) {
        if (![ame247_scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *ame247_win in ((UIWindowScene *)ame247_scene).windows) {
            if (!ame247_win.isKeyWindow) continue;
            UIViewController *ame247_vc = ame247_win.rootViewController;
            while (ame247_vc != nil) {
                if ([ame247_vc isKindOfClass:[Ame237GlassMenuViewController class]] &&
                    ((Ame237GlassMenuViewController *)ame247_vc).ame237_sourceAlert == alert) {
                    return (Ame237GlassMenuViewController *)ame247_vc;
                }
                ame247_vc = ame247_vc.presentedViewController;
            }
        }
    }
    return nil;
}

+ (BOOL)ame247_setMessage:(nullable NSString *)message forMirroredAlert:(UIAlertController *)alert {
    Ame237GlassMenuViewController *ame247_mirror = [self ame247_findMirrorForAlert:alert];
    if (ame247_mirror == nil) return NO;
    [ame247_mirror ame247_updateMessage:message];
    return YES;
}

+ (BOOL)ame247_dismissMirroredAlert:(UIAlertController *)alert
                         completion:(nullable void (^)(void))completion {
    Ame237GlassMenuViewController *ame247_mirror = [self ame247_findMirrorForAlert:alert];
    if (ame247_mirror == nil) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 复用面板自身退场（含入场动画对称的退出动画 + dismissViewControllerAnimated）；
        // 完成/超时双保险后再回调，避免调用方在退场进行中 present 新面板被 UIKit 吞掉。
        __block BOOL ame247_done = NO;
        void (^ame247_finish)(void) = ^() {
            if (ame247_done) return;
            ame247_done = YES;
            if (completion != nil) completion();
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ame247_finish);
        [ame247_mirror ame237_dismissWithAction:nil];
    });
    return YES;
}

/// ★ Task263：呈现者是否处于游戏内渲染面（Metal）域——沿
/// presentingViewController/parentViewController 双链上溯（呈现不改变
/// parent，呈现链用 presenting；容器嵌入用 parent），命中
/// SurfaceViewController/JavaGUIViewController 族即游戏域。
/// 与 AmeNativeMenu.ame245_anchorInsideGameSurface（视图 responder 链）
/// 同语义、不同入口：本钩子手里是呈现者 VC 而非锚点视图。
/// （★ CI r1 修正：方法必须在 AmeFloatingMenu @implementation 内——远端
///   文件结构里 '#pragma mark - 中央路由钩子' 在 @end 之后，照旧基线插在
///   pragma 与 @implementation 之间会游离在任何 implementation 外 = 编译雷）
+ (BOOL)ame263_presenterInsideGameSurface:(UIViewController *)vc {
    UIViewController *ame263_r = vc;
    int ame263_hop = 0;
    while (ame263_r != nil && ame263_hop++ < 8) {
        NSString *ame263_cls = NSStringFromClass(ame263_r.class);
        if ([ame263_cls hasPrefix:@"SurfaceViewController"] ||
            [ame263_cls hasPrefix:@"JavaGUIViewController"]) {
            return YES;
        }
        UIViewController *ame263_next = ame263_r.presentingViewController ?: ame263_r.parentViewController;
        if (ame263_next == ame263_r) break;
        ame263_r = ame263_next;
    }
    return NO;
}

@end

#pragma mark - 中央路由钩子（安装于 UIKit+hook.m）

@implementation UIViewController (Ame237FloatingMenuRouter)

- (void)ame237_hook_presentViewController:(UIViewController *)viewControllerToPresent
                                 animated:(BOOL)flag
                               completion:(nullable void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]] && LGCIsGlassStyleActive()) {
        @try {
            // ★ Task263（反馈 4）接管域收窄 + ★ Task276（用户 2026-10-17：
            //   "在选择为液态玻璃的情况下多次点击会卡出伪液态玻璃"）最终
            //   收窄——装机日志 1015 23:35 实锤真玻璃档下启动器内确认弹窗
            //   （确认删除/版本隔离）被整体替换成魔改磨砂面板（= 用户口中
            //   的"伪液态玻璃"），Task263 首轮收窄保留的 textFields>0 全局
            //   条件仍是残留缺口：启动器内带输入框的 alert（版本隔离命名/
            //   添加服务器等）同样被替换。系统磨砂不合成实锤（Task228/230/
            //   236）全部在 Metal 域——输入类弹窗的接管价值只在游戏内存在。
            //   收窄后真玻璃档接管域仅剩：
            //   ① Metal 游戏面（含其中的输入类弹窗——inGame 已全覆盖）
            //   伪玻璃档（pseudo_glass）维持全接管不动（该档定义如此）。
            UIAlertController *ame263_alert = (UIAlertController *)viewControllerToPresent;
            // ★ Task277（"液态玻璃档卡出伪玻璃"会话闸收口）：ame263_presenter-
            //    InsideGameSurface 的 in-game 接管此前不受 Task260 会话闸约束
            //    ——<26 会话（老绘制链）里菜单面板已按闸回退原生，弹窗却被本
            //    hook 照旧替换成磨砂/玻璃镜像 = 同屏两种体系混搭（用户观感 =
            //    "从液态玻璃卡出伪液态玻璃"），且镜像的 TG 分支在老绘制链上
            //    就是 Task260 病历的崩溃面。统一：会话闸不放行 = 一律原生。
            BOOL ame277_sessionGate = LGCGameSessionGlassAllowed();
            BOOL ame277_domainHit = LGCIsPseudoGlassStyleActive() ||
                                    [AmeFloatingMenu ame263_presenterInsideGameSurface:self];
            if (ame277_domainHit && !ame277_sessionGate) {
                NSLog(@"[AmeMenu] Task277: in-game alert replacement blocked by session gate (MC major <26) -- native passthrough");
            }
            BOOL ame263_shouldReplace = ame277_sessionGate && ame277_domainHit;
            if (ame263_shouldReplace &&
                [AmeFloatingMenu presentGlassMenuForAlert:ame263_alert
                                            fromPresenter:self
                                                 animated:flag
                                               completion:completion]) {
                return;
            }
        } @catch (NSException *e) {
            NSLog(@"[AmeMenu] Task237 router exception (%@) -- native passthrough", e.name);
        }
    }
    // 原生直通（交换后 = 原实现）
    [self ame237_hook_presentViewController:viewControllerToPresent animated:flag completion:completion];
}

// ★ Task275（P1-b1）：玻璃镜像 dismiss 断链根修——Task237 只接管了 present，dismiss
// 仍直透：玻璃档下 [alert dismissViewControllerAnimated:] 打在从未上屏的源 alert
// 上（presented/presenting 全 nil = UIKit 静默 no-op），真正上屏的镜像面板永不关
// 闭 + completion 内后续流程全部死亡（RightPanel JIT 等待四路/WorldsManager 导入
// 队列/DataTransfer 进度框/BingWallpaper HUD 等 10 处实锤；仓内先例 =
// MultiplayerViewController 1922 同病理注释）。命中“源 alert 且镜像在屏”时改道
// ame247_dismissMirroredAlert（含字段回写/停链/完成双保险），其余零开销直透。
- (BOOL)ame237_hook_dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    if ([self isKindOfClass:[UIAlertController class]] && LGCIsGlassStyleActive()) {
        UIAlertController *ame275_alert = (UIAlertController *)self;
        UIViewController *ame275_mirror = [AmeFloatingMenu ame247_findMirrorForAlert:ame275_alert];
        if (ame275_mirror != nil) {
            NSLog(@"[AmeMenu] Task275: mirrored alert dismiss re-routed to glass mirror");
            [AmeFloatingMenu ame247_dismissMirroredAlert:ame275_alert completion:completion];
            return YES;
        }
    }
    // 原生直通（交换后 = 原实现）
    return [self ame237_hook_dismissViewControllerAnimated:flag completion:completion];
}

@end
