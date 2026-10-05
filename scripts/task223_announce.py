#!/usr/bin/env python3
"""Task223: append the round announcement (43rd entry) to announcements.json.
Follows the Task220 entry schema. Textual insertion via json module round-trip
with ensure_ascii=False + indent=1, matching the file's existing style.
"""
import json, collections

PATH = "/home/z/my-project/Amethyst-iOS-MyRemastered/announcements.json"
with open(PATH, encoding="utf-8") as f:
    data = json.load(f, object_pairs_hook=collections.OrderedDict)

anns = data["announcements"]
assert len(anns) == 42, f"expected 42 entries, got {len(anns)}"
assert anns[-1]["id"].startswith("task220-"), anns[-1]["id"]

entry = collections.OrderedDict([
    ("id", "task223-25item-round-upstream-sync-2026-10-05"),
    ("title", "25 项清单总攻：渲染/隔离/导出/欢迎向导/账号操作全修 + 上游同步"),
    ("date", "2026-10-05"),
    ("summary", "用户 25 项反馈清单整轮修复：VirGL 崩溃根因（arm64 EGLint 位宽）、ANGLE ES3.0 精度声明、后台渲染线程挂起（zink 黑屏/MG 卡死共用根修）、版本隔离迁移与模组路径自愈、TouchController 配置刷新、输入法连续输入掉键盘、文件夹浏览器、陶瓦联机公共服务器预检、导出二级入口与流水线提速、欢迎向导全面重做（壁纸/亮度自适应反色/zl2 焦点介绍/教练标记）、侧边栏方向性动画、关于页 Discord 与 GitHub Star、账号高级操作（改名/换肤/默认皮肤）、上游两周功能性更新择优同步（内存三连修/AI 页风格一致/Xcode 26 构建链）。"),
    ("content",
     "## Task223 二十五项清单总攻\n\n"
     "### 渲染与稳定性\n"
     "- **VirGL 崩溃根治**：virgl_server 把 EGLint 重定义为 intptr_t，arm64 上 64 位——"
     "ANGLE 按 32 位读属性对全部错位。改回 int32_t + surfaceless 回退 + 错误日志。\n"
     "- **ANGLE ES3.0 精度**：着色器头注入的 image2D 高精度声明需要 ES 3.10，ES 3.00 直接"
     "编译失败（非 SDL 版本报错根因）。条件编译修复。\n"
     "- **后台挂起统一根修**：iOS 禁止后台 GPU 提交（VK_ERROR_DEVICE_LOST "
     "BackgroundExecutionNotPermitted）。切后台时把渲染线程停在交换边界，回前台自愈恢复——"
     "zink 切后台黑屏与 MG 后台卡死共用此根。\n"
     "- **JIT 启动看门狗**：版本设置启动时 JIT 卡死概率性复现——三处 alert 改 animated:NO "
     "避免后台切换期主队列楔死，ame185 看门狗无条件续派。\n\n"
     "### 数据与实例\n"
     "- **版本隔离**：隔离迁移改为从当前 gameDir 迁移（此前只迁实例根，模组端崩溃/模组丢失"
     "双根因），模组路径自愈。\n"
     "- **导出重构**：抛弃会往上跑的悬浮菜单，改二级入口（借用版本下载界面显示进度）；"
     "速度根修——并行读 + 串行写流水线 + 多线程压缩（此前 10 秒 10MB）。\n"
     "- **文件夹浏览器**：新建真正的全功能浏览器（此前路由到只列 .json 的选择器 = 毛玻璃"
     "空壳），支持目录下钻、QL 预览与分享。\n\n"
     "### 界面与交互\n"
     "- **欢迎向导重做**：接入 Bing/用户预设壁纸、文字按壁纸亮度动态反色、数据步骤按钮化、"
     "zl2 风格灰屏圆圈焦点介绍（替换黑屏不可用版）、iPadOS 27 设计语言对齐、缺失元素补齐。\n"
     "- **启动遮罩**：同壁纸背景 + 自适应色。\n"
     "- **右侧栏动画**：crossDissolve 换方向性滑动过渡。\n"
     "- **TouchController**：安装时自动配置 + 设置项状态刷新（专用通知），用户手动关闭后"
     "不再被强制打开。\n"
     "- **输入法**：Stop 路径 resign 防抖 250ms + 组词期跳过，连续输入不再每次都要重开键盘。\n\n"
     "### 账号与社区\n"
     "- **账号高级操作**：第三方/微软登录行内可见菜单（抛弃长按）——微软支持改名与换肤，"
     "离线账号可选 Steve/Alex 原版默认皮肤。\n"
     "- **关于页**：QQ 群同行加 Discord 社区按钮；捐献旁加 GitHub Star 按钮（\"如果没钱可以"
     "点个 ⭐️ 支持一下\"）。\n"
     "- **README**：Discord 链接上移到显眼位置 + Star CTA；清除 air 遗留仓库引用。\n\n"
     "### 上游两周同步（第 24 项）\n"
     "- **内存三连修**：Task173 权威读数路径撤 1024 下限（3GB 设备防 jetsam）；自动内存"
     "双 entitlement 判定（memorystatus + increased-memory-limit）；带 memorystatus 权限"
     "不再压堆（jetsam 限额会被主动抬升，钳制反成低顶）。\n"
     "- **AI 会话页背景**：补上与其余 AI 页一致的液态玻璃风格层调用。\n"
     "- **构建链**：CI 升 macos-15 + 优先 Xcode 26（iOS 26 SDK 液态玻璃），SDKPATH 显式"
     "钉死防旧 SDK 残留；找不到 Xcode 26 自动回退保持可构建。\n"
     "- **评估未采纳**（留档）：上游新版 metallum agent 仍带非守护监控线程（会复现退出"
     "卡死崩溃，本地 E2E 探针实证），保留本仓守护补丁版；LWJGL 3.4.3 API 适配（本仓"
     "只发 333/341 两套 natives）；NG-GL4ES/Krypton 渲染器（未随仓发布）。\n\n"
     "陶瓦联机：启动前公共服务器预检 + 失败指引（15 秒 EasyTier 搜索超时根因）。"),
])

anns.append(entry)
with open(PATH, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
    f.write("\n")

print("appended; total:", len(anns))
