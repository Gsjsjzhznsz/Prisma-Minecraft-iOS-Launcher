#!/usr/bin/env python3
# Task307: register "ame307.crash.switch_gles" into all Localizable.strings
# tables. Pattern follows task306_i18n.py; reports parity.
# Context: MoltenVK crash inside MobileGlues DirectVulkan backend (shader
# pipeline init, null deref). The crash dialog (SceneDelegate ame273 alert)
# gains a one-tap "switch to GLES backend" recovery action when the report
# headline points at libMoltenVK.dylib.
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

KEY307 = "ame307.crash.switch_gles"

EN307 = "Switch to GLES backend (bypass MoltenVK)"

T307 = {
 'en': EN307,
 'zh-Hans': "一键切换 GLES 后端（绕开 MoltenVK）",
 'zh-Hant': "一鍵切換 GLES 後端（繞開 MoltenVK）",
 'ja': "GLES バックエンドに切り替える（MoltenVK を回避）",
 'ko': "GLES 백엔드로 전환 (MoltenVK 우회)",
 'ru': "Переключить на бэкенд GLES (в обход MoltenVK)",
 'de': "Auf GLES-Backend umschalten (MoltenVK umgehen)",
 'fr': "Passer au backend GLES (contourner MoltenVK)",
 'es': "Cambiar al backend GLES (evitar MoltenVK)",
 'pt-BR': "Alternar para o backend GLES (evitar o MoltenVK)",
 'pt-PT': "Mudar para o backend GLES (contornar o MoltenVK)",
 'it': "Passa al backend GLES (aggira MoltenVK)",
 'nl': "Overschakelen naar GLES-backend (MoltenVK omzeilen)",
 'pl': "Przełącz na backend GLES (ominąć MoltenVK)",
 'tr': "GLES arka ucuna geç (MoltenVK'yi atla)",
 'vi': "Chuyển sang backend GLES (bỏ qua MoltenVK)",
 'id': "Beralih ke backend GLES (hindari MoltenVK)",
 'ar': "التبديل إلى خلفية GLES (تجاوز MoltenVK)",
 'th': "สลับไปยังแบ็กเอนด์ GLES (หลีกเลี่ยง MoltenVK)",
 'uk': "Переключити на бекенд GLES (в обхід MoltenVK)",
 'fi': "Vaihda GLES-taustajärjestelmään (ohittaen MoltenVK)",
 'sv': "Växla till GLES-bakände (undvik MoltenVK)",
 'cs': "Přepnout na backend GLES (obejít MoltenVK)",
 'az': "GLES backendinə keç (MoltenVK-dan yan keç)",
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
    total, added = 0, 0
    for d in sorted(os.listdir(ROOT)):
        lp = os.path.join(ROOT, d)
        if not d.endswith('.lproj') or not os.path.isdir(lp):
            continue
        strings = os.path.join(lp, 'Localizable.strings')
        if not os.path.isfile(strings):
            continue
        total += 1
        lang = d[:-len('.lproj')]
        with open(strings, 'r', encoding='utf-8') as f:
            content = f.read()
        if ('"' + KEY307 + '"') in content:
            continue
        value = esc(text_for(lang, T307, EN307))
        entry = '"%s" = "%s";\n' % (KEY307, value)
        with open(strings, 'a', encoding='utf-8') as f:
            if not content.endswith('\n'):
                f.write('\n')
            f.write(entry)
        added += 1
    print("task307: tables=%d added=%d (key=%s)" % (total, added, KEY307))
    if total == 0 or added == 0:
        print("task307: WARNING -- nothing added (already present or no tables found)")

if __name__ == '__main__':
    main()
