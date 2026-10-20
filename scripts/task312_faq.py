#!/usr/bin/env python3
# Task312: help-faq.json 注入——
#   ① 下载速度慢的分诊与加速（对应"6.5.5 比 6.5.0 慢"的用户反馈）
#   ② 服务地区声明说明（明面不对大陆开放）
# 挂载在「故障排除」分类末尾，结构与既有条目一致（icon/title/description）。
import json
import io
import os

ITEMS = [
    {
        "icon": "speedometer",
        "title": "下载速度很慢怎么办？（6.5.5 比 6.5.0 慢）",
        "description": (
            "下载速度主要取决于下载源到你设备的网络路由，与启动器版本无关——"
            "我们对 6.5.0 → 6.5.5 的整条下载链路做过逐字节审计，下载引擎两个版本完全一致。\n\n"
            "加速方法：\n"
            "• 设置 → 下载设置 → 下载源：选「加载速度快优先」（启动器会实测竞速自动择优）"
            "或直接锁定 BMCLAPI（国内镜像，通常明显更快）；\n"
            "• 新版启动器已内置「吞吐量见证与自动换源」：同一批次下载中官方源实测过慢"
            "（低于 128 KB/s）会自动切镜像继续，无需手动干预；\n"
            "• 高峰时段官方源（piston-data.mojang.com）与镜像都可能拥塞，可稍后再试或换网络环境。"
        ),
    },
    {
        "icon": "globe",
        "title": "为什么启动时提示「不对中国大陆地区用户开放」？",
        "description": (
            "这是启动器的服务地区声明：本启动器不对中国大陆地区用户开放。"
            "Prisma 为社区项目，与 Mojang Studios、Microsoft 及网易（中国大陆地区代理方）均无关联，"
            "也未在中国大陆地区进行分发或提供服务。\n\n"
            "启动器通过设备地区 / 时区 / 运营商 / 语言 / IP 归属地多角度互证来判断，"
            "误判时点击弹窗中的「我不是大陆用户」即可继续（连续 3 次确认后本安装周期不再提示）；"
            "若确有需要，也可选择「退出」。"
        ),
    },
]

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "help-faq.json")
with open(PATH, "r", encoding="utf-8") as f:
    data = json.load(f)

for cat in data["categories"]:
    if cat.get("name") == "故障排除":
        existing = {it["title"] for it in cat["items"]}
        added = 0
        for it in ITEMS:
            if it["title"] not in existing:
                cat["items"].append(it)
                added += 1
        print("故障排除: +%d items (total %d)" % (added, len(cat["items"])))
        break
else:
    raise SystemExit("ERROR: 故障排除 category not found")

with io.open(PATH, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("task312-faq: done")
