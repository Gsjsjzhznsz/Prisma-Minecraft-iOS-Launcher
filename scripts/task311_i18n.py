#!/usr/bin/env python3
# Task311: i18n 批处理——
#   新增 6 键（×54 表）：dl.controls.cat.gamepad + 手柄下载 toast 2 键 +
#                       controller_configurator 三类型键名（Xbox/PlayStation/
#                       Switch 为品牌名，全语言同文；36 表此前缺 xbox/playstation
#                       一并补齐，消除裸键回退显示）
#   移除 2 键：设置页 nintendo_layout 行退役后的孤儿键
#              （preference.title/detail.nintendo_layout）
# 机制与 task310_i18n.py 一致：append-if-missing + ALIAS 回退 + esc() 转义；
# 移除为行级过滤（键均为单行，含转义引号也单行，54 表已验证）。
import os, re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

KEYS = {
  "dl.controls.cat.gamepad": ("Gamepad", {
    'zh-Hans': "手柄", 'zh-Hant': "手把",
    'ja': "ゲームパッド", 'ko': "게임패드", 'ru': "Геймпад",
    'de': "Gamepad", 'fr': "Manette", 'es': "Mando",
    'pt-BR': "Controle", 'pt-PT': "Comando", 'it': "Gamepad",
    'nl': "Gamepad", 'pl': "Kontroler", 'tr': "Oyun kumandası",
    'vi': "Tay cầm", 'id': "Gamepad", 'ar': "ذراع التحكم",
    'th': "เกมแพด", 'uk': "Геймпад", 'fi': "Peliohjain",
    'sv': "Gamepad", 'cs': "Gamepad", 'az': "Oyun paneli",
  }),
  "custom_controls.repo.download.gamepad.done": ("Gamepad mapping %@ installed — select it in Controller Config", {
    'zh-Hans': "手柄映射 %@ 已安装——在「手柄配置」中即可选用",
    'zh-Hant': "手把映射 %@ 已安裝——在「手把配置」中即可選用",
    'ja': "ゲームパッドマップ %@ をインストールしました —「コントローラー設定」で選択できます",
    'ko': "게임패드 매핑 %@ 설치됨 — '컨트롤러 설정'에서 선택하세요",
    'ru': "Геймпад-маппинг %@ установлен — выберите его в настройках контроллера",
    'de': "Gamepad-Mapping %@ installiert — in der Controller-Konfiguration auswählen",
    'fr': "Mapping manette %@ installé — sélectionnez-le dans la configuration manette",
    'es': "Mapeo de mando %@ instalado: selecciónalo en Configuración del mando",
    'pt-BR': "Mapeamento de controle %@ instalado — selecione em Config. de controle",
  }),
  "custom_controls.repo.download.gamepad.invalid": ("Not a valid gamepad mapping file", {
    'zh-Hans': "不是有效的手柄映射文件",
    'zh-Hant': "不是有效的手把映射檔案",
    'ja': "有効なゲームパッドマップファイルではありません",
    'ko': "유효한 게임패드 매핑 파일이 아닙니다",
    'ru': "Недействительный файл маппинга геймпада",
    'de': "Keine gültige Gamepad-Mapping-Datei",
    'fr': "Fichier de mapping manette invalide",
    'es': "No es un archivo de mapeo de mando válido",
    'pt-BR': "Não é um arquivo de mapeamento de controle válido",
  }),
  # 品牌名全语言同文——36 张缺表一并补齐（消除裸键显示），18 张已有表自动跳过
  "controller_configurator.title.type.nintendo": ("Switch", {}),
  "controller_configurator.title.type.xbox": ("Xbox", {}),
  "controller_configurator.title.type.playstation": ("PlayStation", {}),
}

# 设置页行退役 → 孤儿键全表移除
REMOVE_KEYS = ["preference.title.nintendo_layout", "preference.detail.nintendo_layout"]

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
    total_tables, added_total, removed_total = 0, 0, 0
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
        # —— 移除孤儿键（行级过滤）——
        kept, removed_here = [], 0
        for ln in lines:
            drop = False
            for rk in REMOVE_KEYS:
                if ln.startswith('"%s"' % rk) and re.match(r'^"%s"\s*=' % re.escape(rk), ln):
                    drop = True
                    break
            if drop: removed_here += 1
            else: kept.append(ln)
        # —— 新增缺失键（append-if-missing）——
        content = ''.join(kept)
        pending = []
        for key, (en, table) in KEYS.items():
            if ('"' + key + '"') in content:
                continue
            value = esc(text_for(lang, table, en))
            pending.append('"%s" = "%s";\n' % (key, value))
        if removed_here or pending:
            with open(strings, 'w', encoding='utf-8') as f:
                f.writelines(kept)
                if pending and kept and not kept[-1].endswith('\n'):
                    f.write('\n')
                f.writelines(pending)
            added_total += len(pending)
            removed_total += removed_here
            print("%-14s +%d -%d" % (lang, len(pending), removed_here))
    print("task311: tables=%d added=%d removed=%d keys_add=%d keys_rm=%d" %
          (total_tables, added_total, removed_total, len(KEYS), len(REMOVE_KEYS)))
    if total_tables == 0:
        raise SystemExit("ERROR: no strings tables found")

if __name__ == '__main__':
    main()
