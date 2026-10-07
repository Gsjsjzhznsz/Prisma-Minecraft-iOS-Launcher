#!/usr/bin/env python3
"""Task226: append new i18n keys to all 4 Localizable.strings (four-way parity).
Keys: coachmarks next/done (missing = raw-key display on the button) + two new
marks (downloads/versions) + dependency-download strings (issue #10)."""
import io

BASE = '/home/z/my-project/Amethyst-iOS-MyRemastered/Natives/resources'

ADDITIONS = {
    'en': {
        'coachmarks.next': 'Next',
        'coachmarks.done': 'Get Started',
        'coachmarks.downloads.title': 'Downloads & Mods',
        'coachmarks.downloads.body': 'Search mods, shaders and resource packs here. Required mod dependencies are offered for download automatically after install.',
        'coachmarks.versions.title': 'Versions & Isolation',
        'coachmarks.versions.body': 'Manage game versions. Per-version isolation keeps saves and mods separate; appearance and scaling live in Launcher Settings.',
        'ame226.deps.title': 'Required Dependencies',
        'ame226.deps.message': 'This mod needs the following required dependencies. Download them all now?\\n\\n%@',
        'ame226.deps.download_all': 'Download All',
        'ame226.deps.downloading': 'Downloading Dependencies',
        'ame226.deps.progress': 'Dependency %ld of %ld\\u2026',
        'ame226.deps.done': 'All dependencies installed.',
    },
    'zh-Hans': {
        'coachmarks.next': '下一步',
        'coachmarks.done': '开始使用',
        'coachmarks.downloads.title': '下载与模组',
        'coachmarks.downloads.body': '在这里搜索模组、光影与资源包。安装后必需依赖会自动提示一键下载。',
        'coachmarks.versions.title': '版本与隔离',
        'coachmarks.versions.body': '管理游戏版本。版本隔离让存档与模组互不干扰；外观与缩放设置在启动器设置中。',
        'ame226.deps.title': '必需依赖',
        'ame226.deps.message': '这个模组需要以下必需依赖，现在一并下载吗？\\n\\n%@',
        'ame226.deps.download_all': '全部下载',
        'ame226.deps.downloading': '正在下载依赖',
        'ame226.deps.progress': '依赖 %ld / %ld\\u2026',
        'ame226.deps.done': '全部依赖已安装。',
    },
    'zh-Hant': {
        'coachmarks.next': '下一步',
        'coachmarks.done': '開始使用',
        'coachmarks.downloads.title': '下載與模組',
        'coachmarks.downloads.body': '在這裡搜尋模組、光影與資源包。安裝後必需依賴會自動提示一鍵下載。',
        'coachmarks.versions.title': '版本與隔離',
        'coachmarks.versions.body': '管理遊戲版本。版本隔離讓存檔與模組互不干擾；外觀與縮放設定在啟動器設定中。',
        'ame226.deps.title': '必需依賴',
        'ame226.deps.message': '這個模組需要以下必需依賴，現在一併下載嗎？\\n\\n%@',
        'ame226.deps.download_all': '全部下載',
        'ame226.deps.downloading': '正在下載依賴',
        'ame226.deps.progress': '依賴 %ld / %ld\\u2026',
        'ame226.deps.done': '全部依賴已安裝。',
    },
    'zh-CN': {
        'coachmarks.next': '下一步',
        'coachmarks.done': '开始使用',
        'coachmarks.downloads.title': '下载与模组',
        'coachmarks.downloads.body': '在这里搜索模组、光影与资源包。安装后必需依赖会自动提示一键下载。',
        'coachmarks.versions.title': '版本与隔离',
        'coachmarks.versions.body': '管理游戏版本。版本隔离让存档与模组互不干扰；外观与缩放设置在启动器设置中。',
        'ame226.deps.title': '必需依赖',
        'ame226.deps.message': '这个模组需要以下必需依赖，现在一并下载吗？\\n\\n%@',
        'ame226.deps.download_all': '全部下载',
        'ame226.deps.downloading': '正在下载依赖',
        'ame226.deps.progress': '依赖 %ld / %ld\\u2026',
        'ame226.deps.done': '全部依赖已安装。',
    },
}

for lang, kvs in ADDITIONS.items():
    path = f'{BASE}/{lang}.lproj/Localizable.strings'
    with io.open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    existing_keys = set()
    for line in content.split('\n'):
        if line.startswith('"') and '" = "' in line:
            existing_keys.add(line.split('"')[1])
    added, skipped = [], []
    block = []
    for k, v in kvs.items():
        if k in existing_keys:
            skipped.append(k)
            continue
        block.append(f'"{k}" = "{v}";')
        added.append(k)
    if block:
        if not content.endswith('\n'):
            content += '\n'
        content += '\n' + '\n'.join(block) + '\n'
        with io.open(path, 'w', encoding='utf-8') as f:
            f.write(content)
    print(f'[{lang}] added {len(added)}, skipped {len(skipped)}: {skipped}')

# four-way parity check
keys_per_lang = {}
for lang in ADDITIONS:
    path = f'{BASE}/{lang}.lproj/Localizable.strings'
    ks = set()
    for line in io.open(path, encoding='utf-8'):
        if line.startswith('"') and '" = "' in line:
            ks.add(line.split('"')[1])
    keys_per_lang[lang] = ks
base = keys_per_lang['en']
for lang, ks in keys_per_lang.items():
    missing = base - ks
    extra = ks - base
    print(f'[{lang}] vs en: missing={len(missing)} extra={len(extra)}')
    if missing:
        print('  missing keys:', sorted(missing)[:10])
