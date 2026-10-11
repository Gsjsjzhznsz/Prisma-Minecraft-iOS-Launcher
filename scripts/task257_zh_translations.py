#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Task 257（清单 7）中文补全译表：key -> (简体, 繁體)。
仅覆盖 task257_zh_l10n_sweep.py 扫出的"三表值==en 原文"键；
语言中立键（渲染器/手柄品牌名、JIT 工具名、格式占位等）刻意不收录。
zh-Hant 用语对齐表内既有主流惯例（網路/資料/記憶體/佈局/滑鼠/實例/渲染器，
連線對齊 i18n_str_989；套用/匯出/匯入/金鑰/圖示為正體惯用）。
"""

TRANSLATIONS = {
    "mp.ingame.status.network_id": ("网络 ID", "網路 ID"),
    "mp.room.network_id": ("网络 ID", "網路 ID"),
    "preference.title.auto_control_update_check": ("自动检查控件更新", "自動檢查控件更新"),
    "preference.detail.auto_control_update_check": (
        "启动后静默检查控件仓库，已安装的控件布局有更新时通知你",
        "啟動後靜默檢查控件倉庫，已安裝的控件佈局有更新時通知你"),
    "terracotta.stage.retry": ("正在重试连接房主（第 %lu/2 次）…", "正在重試連線房主（第 %lu/2 次）…"),
    "home.tile.cleanup": ("清理垃圾", "清理垃圾"),
    "preference.profile.jvm_follow_global": ("跟随全局设置", "跟隨全局設定"),
    "preference.detail.auto_keyboard_sdl": (
        "游戏中文本框需要输入时自动启用 SDL 软键盘",
        "遊戲中文本框需要輸入時自動啟用 SDL 軟鍵盤"),
    "preference.detail.mc_toggle_sprint": (
        "在每个实例的 options.txt 中切换疾跑锁存（按一次，持续疾跑）",
        "在每個實例的 options.txt 中切換疾跑鎖存（按一次，持續疾跑）"),
    "preference.title.confirm.mc_toggle_sprint": ("将疾跑切换应用到所有实例？", "將疾跑切換套用到所有實例？"),
    "preference.title.done.mc_toggle_sprint": ("疾跑切换已应用", "疾跑切換已套用"),
    "preference.detail.keybind_sync": (
        "将启动器的按键绑定设置同步到每个实例的 options.txt",
        "將啟動器的按鍵綁定設定同步到每個實例的 options.txt"),
    "preference.title.confirm.keybind_sync": ("将按键绑定同步到所有实例？", "將按鍵綁定同步到所有實例？"),
    "preference.title.done.keybind_sync": ("按键绑定已同步", "按鍵綁定已同步"),
    "preference.title.confirm.curseforge_api_key": ("保存 CurseForge API 密钥？", "保存 CurseForge API 金鑰？"),
    "preference.title.done.curseforge_api_key": ("API 密钥已保存", "API 金鑰已保存"),
    "preference.title.confirm.custom_appicon": ("应用所选的应用图标？", "套用所選的應用圖示？"),
    "preference.title.done.custom_appicon": ("应用图标已更改", "應用圖示已更改"),
    "preference.title.confirm.launcher_background": ("应用所选的背景？", "套用所選的背景？"),
    "preference.title.done.launcher_background": ("背景已更改", "背景已更改"),
    "preference.title.confirm.reset_warnings": ("重置所有警告？", "重置所有警告？"),
    "preference.title.confirm.memory_limit_help": ("应用内存限制？", "套用記憶體限制？"),
    "preference.title.done.memory_limit_help": ("内存限制已更新", "記憶體限制已更新"),
    "preference.title.confirm.data_export": ("导出启动器数据？", "匯出啟動器資料？"),
    "preference.title.done.data_export": ("导出完成", "匯出完成"),
    "preference.title.confirm.data_import": ("导入启动器数据？这可能覆盖现有数据。", "匯入啟動器資料？這可能覆蓋現有資料。"),
    "preference.title.done.data_import": ("导入完成", "匯入完成"),
    "preference.title.confirm.about": ("打开关于页？", "打開關於頁？"),
    "preference.title.done.about": ("关于页已打开", "關於頁已打開"),
    "preference.title.confirm.custom_mouse_pointer": ("应用自定义指针？", "套用自訂滑鼠指標？"),
    "preference.title.done.custom_mouse_pointer": ("指针已更新", "滑鼠指標已更新"),
    "preference.title.confirm.reset_mouse_pointer": ("将指针重置为默认？", "將滑鼠指標重設為預設？"),
    "preference.title.done.reset_mouse_pointer": ("指针已重置", "滑鼠指標已重設"),
    "preference.title.confirm.two_finger_keyboard": ("启用双指键盘手势？", "啟用雙指鍵盤手勢？"),
    "preference.title.done.two_finger_keyboard": ("手势已更新", "手勢已更新"),
    "preference.title.enable_no_error": ("GL 无错误模式", "GL 無錯誤模式"),
}
