#!/usr/bin/env python3
# Task323: i18n 批处理——
#   新增 1 键（×54 表）：download.tab.install（下载中心「安装」tab 标签，
#   嵌入 ModLoaderInstallViewController 的 ZL2 风格安装分区）
# 机制与 task311_i18n.py 一致：append-if-missing + ALIAS 回退 + esc() 转义；
# 复用键盘点（本轮全部沿用既有键，零新增消费缺口）：
#   i18n_str_904（安装）/ i18n_str_38（选择版本）/ i18n_str_155（搜索版本...）
import os, re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

KEYS = {
  "download.tab.install": ("Install", {
    'zh-Hans': "安装", 'zh-Hant': "安裝",
    'ja': "インストール", 'ko': "설치", 'ru': "Установка",
    'de': "Installieren", 'fr': "Installer", 'es': "Instalar",
    'pt-BR': "Instalar", 'pt-PT': "Instalar", 'it': "Installa",
    'nl': "Installeren", 'pl': "Instaluj", 'tr': "Yükle",
    'vi': "Cài đặt", 'id': "Instal", 'ar': "تثبيت",
    'th': "ติดตั้ง", 'uk': "Встановити", 'fi': "Asenna",
    'sv': "Installera", 'cs': "Instalovat", 'hu': "Telepítés",
    'ro': "Instalează", 'el': "Εγκατάσταση", 'da': "Installér",
    'nb': "Installer", 'no': "Installer", 'he': "התקנה",
    'fa': "نصب", 'hi': "इंस्टॉल", 'bn': "ইনস্টল",
    'ta': "நிறுவு", 'te': "ఇన్‌స్టాల్", 'ml': "ഇൻസ്റ്റാൾ",
    'ms': "Pasang", 'km': "ដំឡើង", 'lo': "ຕິດຕັ້ງ",
    'my': "တပ်ဆင်", 'ka': "დაყენება", 'hy': "Տեղադրել",
    'az': "Quraşdır", 'kk': "Орнату", 'uz': "O'rnatish",
    'sk': "Inštalovať", 'sl': "Namesti", 'hr': "Instaliraj",
    'sr': "Инсталирај", 'bg': "Инсталирай", 'lt': "Įdiegti",
    'lv': "Instalēt", 'et': "Paigalda", 'is': "Setja upp",
    'ga': "Suiteáil", 'cy': "Gosod", 'sw': "Sakinisha",
  }),
}

ALIAS = {
 'en-GB': 'en', 'en-PT': 'en', 'en-UD': 'en',
 'zh-CN': 'zh-Hans', 'zh-Hans': 'zh-Hans', 'zh-Hant': 'zh-Hant', 'zh': 'zh-Hans',
 'nb': 'no', 'nn': 'no', 'in': 'id', 'iw': 'he', 'fil': 'tl', 'tl': 'tl',
 'pt': 'pt-PT', 'sr-Latn': 'sr', 'bs': 'hr', 'me': 'sr',
}

def text_for(lang_dir, table, en):
    if lang_dir in table and table[lang_dir]:
        return table[lang_dir]
    if lang_dir in ALIAS and ALIAS[lang_dir] in table and table[ALIAS[lang_dir]]:
        return table[ALIAS[lang_dir]]
    base = lang_dir.split('-')[0]
    if base in table and table[base]:
        return table[base]
    if base in ALIAS and ALIAS[base] in table and table[ALIAS[base]]:
        return table[ALIAS[base]]
    return en

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def main():
    total_tables, added_total = 0, 0
    for d in sorted(os.listdir(ROOT)):
        lp = os.path.join(ROOT, d)
        if not d.endswith('.lproj') or not os.path.isdir(lp):
            continue
        strings = os.path.join(lp, 'Localizable.strings')
        if not os.path.isfile(strings):
            continue
        total_tables += 1
        lang = d[:-len('.lproj')]
        with open(strings, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        content = ''.join(lines)
        pending = []
        for key, (en, table) in KEYS.items():
            if ('"' + key + '"') in content:
                continue
            value = esc(text_for(lang, table, en))
            pending.append('"%s" = "%s";\n' % (key, value))
        if pending:
            with open(strings, 'w', encoding='utf-8') as f:
                f.writelines(lines)
                if lines and not lines[-1].endswith('\n'):
                    f.write('\n')
                f.writelines(pending)
            added_total += len(pending)
            print("%-14s +%d" % (lang, len(pending)))
    print("task323: tables=%d added=%d keys=%d" % (total_tables, added_total, len(KEYS)))

if __name__ == '__main__':
    main()
