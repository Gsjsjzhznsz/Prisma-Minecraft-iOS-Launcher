#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task 239 验证脚本：第 9 轮反馈的 3 项修复静态验证。
A. 全部游戏启动崩溃根修（game.gear.docked.left KVC 炸弹 → docked_left 键名对齐
   + PLPreferences 安全路径行走，Task142/143/239 家族整类根除）
B. iOS 26 原生液态玻璃 API 接入（用户指令：UIGlassEffect 真玻璃，禁 UIAlertController 魔改；
   玻璃风格 = 原生玻璃/材质回退双档，原生风格 = 旧版系统弹窗直通）
C. 字体重叠第八轮收尾（==0 缩字镜像纳入 + 富文本段落继承 + 截断模式尊重 + 测量段落一致）
D. 括号配平（所有修改文件）
"""
import sys, re

BASE = "/home/z/my-project/Amethyst-iOS-MyRemastered/Natives/"
LGC_H = "/home/z/my-project/Amethyst-iOS-MyRemastered/Natives/LiquidGlassCompat.h"
results = []

def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))

def rd(p):
    with open(BASE + p, "r", encoding="utf-8") as f:
        return f.read()

def rdh(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def code_lines(src):
    """去掉注释行/行尾注释后的代码行拼接（字符串内的 // 不受影响——
    仅用于键名/选择器存活检查，注释里的历史键名允许作为病历保留）。"""
    out = []
    for ln in src.splitlines():
        # 先剥行内字符串，再找 // 行尾注释，避免 https:// 误判
        stripped = re.sub(r'"(\\.|[^"\\])*"', '""', ln)
        idx = stripped.find('//')
        if idx >= 0 and stripped.find('"', 0, idx) == -1:
            ln = ln[:idx]
        if ln.strip():
            out.append(ln)
    return '\n'.join(out)

# ---------- A. 启动崩溃根修 ----------
gmov = rd("GameMenuOverlayView.m")
prefs = rd("PLPreferences.m")

check("A1 致命键名已换（game.gear.docked.left KVC 炸弹退役）",
      'kAme227DockedSidePref = @"game.gear.docked_left"' in gmov and
      'game.gear.docked.left"' not in code_lines(gmov),
      "valueForKeyPath 语义下旧键 = game→gear→docked(布尔)→left 必炸（注释里的病历记载除外）")
check("A2 键名与 PLPreferences 注册默认值一致",
      '"docked_left": @NO' in prefs,
      "读取键 = 注册键（Task238 注册了 docked_left 但读了 docked.left）")
check("A3 PLPreferences 安全路径行走（getObject）",
      "Ame239_SafeValueForPath(key, self.instancePref)" in prefs and
      "Ame239_SafeValueForPath(key, self.globalPref)" in prefs,
      "中间跳非字典 = nil，不再抛 NSUnknownKeyException")
check("A4 安全行走逐跳 NSDictionary 校验",
      "if (![current isKindOfClass:[NSDictionary class]]) return nil;" in prefs,
      "布尔/标量/数组中间跳全部安全返回")
check("A5 setValue:forKeyPath 写入包裹 @try/@catch",
      prefs.count("@catch (NSException *ame239_e)") >= 2,
      "写入路径异常也不再炸进程（实例 + 全局双写点）")
check("A6 存在性检查不再用裸 valueForKeyPath",
      "[self.instancePref valueForKeyPath:key]" not in prefs and
      "[self.globalPref valueForKeyPath:key]" not in prefs,
      "getter/setter 的 KVC 下降全部收口到安全行走")

# ---------- B. iOS 26 原生液态玻璃 ----------
lgh = rdh(LGC_H)
lgc = rd("LiquidGlassCompat.m")
fm = rd("AmeFloatingMenu.m")
nav = rd("SurfaceViewController+Navigation.m")

check("B1 LGCNativeGlassEffect 工厂（头文件声明）",
      "LGCNativeGlassEffect(void)" in lgh and "LGCNativeGlassEngaged(void)" in lgh,
      "真系统 UIGlassEffect 的统一入口")
check("B1b 声明用 C 函数合法可空形式（CI r1 教训锁定）",
      "UIVisualEffect * _Nullable LGCNativeGlassEffect(void);" in lgh and
      "nullable UIVisualEffect *LGCNativeGlassEffect" not in lgh,
      "非下划线 nullable 前缀 = ObjC 方法/属性专属，C 函数声明处 clang 报 unknown type name 并丢弃声明")
check("B2 编译期 SDK 门控（__IPHONE_26_0 直接声明 + 老 SDK 运行时回退）",
      "#if defined(__IPHONE_26_0)" in lgc and "NSClassFromString(@\"UIGlassEffect\")" in lgc,
      "CI 实锤 Xcode 26.3/iOS 26.2 SDK；regularEffect 幻影选择器退役")
check("B3 诊断开关 AME239_NO_SYSTEM_GLASS=1（装机侧一键退回材质）",
      "AME239_NO_SYSTEM_GLASS" in lgc,
      "Task228 黑屏观察若复现，无需重编译即可分诊")
check("B4 应用内悬浮菜单（账号设置等全部弹窗）接原生玻璃",
      "ame239_effect = LGCNativeGlassEffect();" in fm and
      "SystemMaterial fallback" in fm,
      "玻璃风格优先 UIGlassEffect；取不到回退 SystemMaterial 磨砂")
check("B5 菜单面板底色双档（原生玻璃 0.30/0.58 通透档）",
      "Ame239GlassPanelBase()" in fm and "alpha:0.30" in fm and "alpha:0.58" in fm,
      "真玻璃自带磨砂折光，厚底会闷成实心板")
check("B6 面板底色分档选择（玻璃=通透档 / 回退=Task237 厚底）",
      "LGCNativeGlassEngaged() ? Ame239GlassPanelBase()" in fm,
      "Ame237PanelBase 保留为材质回退档")
check("B7 材质锚点日志（装机可检索）",
      "[AmeMenu] Task239 menu material:" in fm,
      "下一轮装机日志直接读出玻璃/回退路径")
check("B8 游戏内菜单面板接原生玻璃",
      "ame239_gmEffect = LGCNativeGlassEffect();" in nav and
      "native UIGlassEffect" in nav,
      "玻璃风格下游戏内菜单同走真玻璃")
check("B9 齿轮悬浮球磨砂层升级原生玻璃",
      "ame239_gearEffect = LGCNativeGlassEffect();" in gmov,
      "0.55 深色底 + 发丝描边保留（渲染异常时仍是可见深色球）")
check("B10 原生风格路径零改动（旧版系统弹窗直通）",
      "LGCIsGlassStyleActive()" in fm and "presentGlassMenuForAlert" in fm,
      "中央路由原生分支不经新材质；玻璃风格下 UIAlertController 永不上屏")
check("B11 新工厂声明式初始化（编译器完整类型检查，非 objc_msgSend 裸调）",
      "UIGlassEffect *ame239_glass = [[UIGlassEffect alloc] init];" in lgc,
      "SDK 26.2 直接声明；Task228 的 regularEffect 探测仅存于旧 opt-in 实验路径（默认关闭）")

# ---------- C. 字体重叠第八轮收尾 ----------
bgm = rd("BackgroundManager.m")

check("C1 拷贝段落样式继承本体富文本属性",
      "attribute:NSParagraphStyleAttributeName" in bgm and
      "mutableCopy];" in bgm and "ame239_bodyPS" in bgm,
      "lineSpacing/lineHeight 等行距几何与本体同源（裸样式重建 = 错行残留）")
check("C2 本体自带段落时对齐不覆盖（字符串内段落优先于 label 属性）",
      "ame233_ps.alignment = ame232_label.textAlignment;" in bgm,
      "仅裸文本分支才用 label 对齐")
check("C3 单行截断模式尊重本体（Middle/Head 不再强制 Tail）",
      "ame232_label.lineBreakMode == NSLineBreakByWordWrapping ||" in bgm and
      "ame232_label.lineBreakMode == NSLineBreakByCharWrapping) {" in bgm,
      "截断位置错位 = 单行场景残留重叠")
check("C4 ==0 不限行标签纳入缩字镜像",
      "ame232_label.numberOfLines != 1 && ame235_scaledFont == nil" in bgm,
      "此前 ==0 + 缩字两个分支都进不去，拷贝恒原字号溢出")
check("C5 二分测量段落与绘制段落同源",
      "ame239_measurePS = [ame233_ps copy]" in bgm,
      "测量/绘制同一套行距几何，二分结果与拷贝实际高度一致")

# ---------- D. 括号配平 ----------
def balanced(name, src):
    # 粗配平：先剥字符串（避免 https:// 里的 // 被当注释吃掉引号），
    # 再剥注释，最后数大括号圆括号
    s = re.sub(r'"(\\.|[^"\\])*"', '""', src)
    s = re.sub(r"'(\\.|[^'\\])*'", "''", s)
    s = re.sub(r'//[^\n]*', '', s)
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    check("D:%s" % name, s.count("{") == s.count("}") and s.count("(") == s.count(")"),
          "{} %d/%d () %d/%d" % (s.count("{"), s.count("}"), s.count("("), s.count(")")))

balanced("GameMenuOverlayView.m", gmov)
balanced("PLPreferences.m", prefs)
balanced("LiquidGlassCompat.m", lgc)
balanced("AmeFloatingMenu.m", fm)
balanced("SurfaceViewController+Navigation.m", nav)
balanced("BackgroundManager.m", bgm)

# ---------- 汇总 ----------
fails = [r for r in results if not r[1]]
for name, ok, detail in results:
    print("%s  %s %s" % ("PASS" if ok else "FAIL", name, ("-- " + detail) if (detail and not ok) else ""))
print()
print("%d/%d checks passed" % (len(results) - len(fails), len(results)))
sys.exit(1 if fails else 0)
