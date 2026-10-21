//
//  PrismaUI.h
//  Amethyst
//
//  Task314：PrismaUI 设计系统伞头文件。
//
//  PrismaUI 是本启动器自研的 Fluent 2 设计语言原生实现（ObjC/UIKit，iOS 14+），
//  7.0 前端 UI 架构的唯一视觉事实源。决策取证与选型全过程见
//  docs/decisions/2026-10-21-ui-architecture-prisma-ui.md（要点：
//  fluentui-apple 官方库 0.37.0 起硬性 iOS 17+ 且全 Swift/SPM，与本工程
//  iOS 14 底线 + CMake 裸编构建链双重冲突，故按"同一设计语言、不同实现
//  载体"自研落地）。
//
//  分层：
//    令牌层  PrismaTheme        色板/字阶/圆角/间距/阴影 + 全局外观安装
//    组件层  PrismaFilledButton Fluent 2 实心按钮（filled/outline/subtle）
//            PrismaCardView     表面卡片
//            PrismaListCell     列表项单元格
//    增强层  AmeLiquidGlassView（Task252，iOS 26+ 材质，后续接入）
//
//  使用约定：
//    · 新屏一律经 PrismaUI 组件构建；存量 VC 按模块渐进迁移。
//    · 观感取值一律走 PrismaTheme 令牌，禁止散落硬编码色值/字号——
//      这是 7.0"全部改成"目标在 59 个 VC 上可持续的纪律前提。
//    · +[PrismaTheme install] 在 SceneDelegate willConnect 早期调用一次。
//

#import "PrismaTheme.h"
#import "PrismaFilledButton.h"
#import "PrismaCardView.h"
#import "PrismaListCell.h"
