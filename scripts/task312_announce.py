#!/usr/bin/env python3
# Task312: 公告注入——
#   ① 服务地区声明（明面不对大陆开放，3 次确认后放行）
#   ② 6.5.5 vs 6.5.0 下载速度说明（全链审计定性 + ame312 自动换源）
# 单一事实源 = 根目录 announcements.json；website/src/data 与
# website/public 为构建快照，一并同步保持一致。
import json
import io
import os

ENTRY = {
    "id": "region-notice-and-download-speed-2026-10-20",
    "title": "服务地区声明：不对中国大陆地区用户开放 · 6.5.5 下载速度说明",
    "date": "2026-10-20",
    "summary": "明面声明：本启动器不对中国大陆地区用户开放，应用内将通过多角度检测弹出服务地区声明（「我不是大陆用户」按钮，3 次确认后放行）。另：6.5.5 下载链路与 6.5.0 逐字节一致，变慢源于官方源路由劣化，已新增下载吞吐量见证与低速自动换镜像。",
    "content": (
        "## 服务地区声明\n\n"
        "**本启动器不对中国大陆地区用户开放。** Prisma 为社区项目，与 Mojang Studios、Microsoft 及网易（中国大陆地区代理方）均无关联，也**未在中国大陆地区进行分发或提供服务**。\n\n"
        "- 启动器会在本机进行**多角度检测**（设备地区 / 时区 / 运营商 / 语言 / IP 归属地，多信号互证才会触发，探测失败不误伤）\n"
        "- 疑似大陆用户时会弹出「服务地区声明」弹窗，下方提供**「我不是大陆用户」**按钮\n"
        "- **连续 3 次确认后放行**，此后本安装周期不再打扰；弹窗中的「退出」按钮可随时离开\n"
        "- 本声明亦已同步至 README 与官网\n\n"
        "## 6.5.5 下载速度说明\n\n"
        "有用户反馈「6.5.5 下载速度比 6.5.0 慢多了」。我们对两个版本之间的**整条下载链路做了逐字节审计**（版本清单候选链 / 镜像中心 / 资源下载引擎 / Forge 安装器 / 控件仓库源），结论：**下载引擎在两个版本之间完全一致，不存在代码层面的速度回归**。\n\n"
        "变慢的真实原因：官方源（piston-data / piston-meta.mojang.com）到部分地区路由劣化。而旧逻辑只在下载**彻底失败**后才会轮换到 BMCLAPI 镜像——「慢而不断」的官方源永远不会触发轮换，只能一直爬。\n\n"
        "已新增修复（下个版本起生效）：**下载吞吐量见证与自动换源**——同一下载批次内按源统计实际吞吐（大文件样本），官方源平均低于 128 KB/s 即自动切到镜像优先继续本批下载；镜像也被证实慢时回退官方。全程日志留痕（`[MCDL] ame312`），不改用户手动选择的下载源偏好。\n\n"
        "手动加速：设置 → 下载设置 → 下载源，可选「加载速度快优先」（实测竞速自动择优）或直接锁定 BMCLAPI。\n\n"
        "---\n\n"
        "Region Notice: **This launcher is NOT available to users in mainland China.** It is a community project unaffiliated with Mojang Studios, Microsoft, or NetEase, and is not distributed or serviced in mainland China. The app shows a \"Service Region Notice\" with an \"I am not a mainland user\" button; the gate releases after 3 confirmations.\n\n"
        "Download speed: the 6.5.0 -> 6.5.5 download chain is byte-identical (full audit). Slowdowns come from degraded routes to Mojang's official CDN. A throughput witness + auto mirror failover ships next release; you can also set Settings -> Download -> Source to \"speed-first\" or BMCLAPI."
    ),
    "priority": "normal",
    "action_url": "",
    "action_title": "",
    "image_url": "",
    "pin": True,
}

PATHS = [
    "announcements.json",
    "website/src/data/announcements.json",
    "website/public/announcements.json",
]

BASE = os.path.dirname(os.path.abspath(__file__))

for rel in PATHS:
    p = os.path.join(BASE, "..", rel)
    p = os.path.normpath(p)
    if not os.path.isfile(p):
        print("skip (missing):", rel)
        continue
    with open(p, "r", encoding="utf-8") as f:
        data = json.load(f)
    lst = data["announcements"] if isinstance(data, dict) else data
    before = len(lst)
    lst[:] = [a for a in lst if a.get("id") != ENTRY["id"]]
    lst.insert(0, ENTRY)
    with io.open(p, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("%s: %d -> %d entries" % (rel, before, len(lst)))
print("task312-announce: done")
