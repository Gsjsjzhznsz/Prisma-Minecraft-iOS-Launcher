#!/usr/bin/env python3
# Task310: register 18 i18n keys into all Localizable.strings tables.
# Pattern follows task307_i18n.py (main languages translated, rest EN fallback).
# Scope: 控件三分类页 (dl.controls.*) + 手柄连接 toast/守卫 (controller.*)
#        + Switch 布局/滚轮速度设置行 (preference.title/detail.*)
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

# key -> (EN, {lang: text})
KEYS = {
  "dl.controls.cat.official": ("Featured", {
    'zh-Hans': "官方精选", 'zh-Hant': "官方精選",
    'ja': "公式セレクト", 'ko': "공식 추천", 'ru': "Избранное",
    'de': "Empfohlen", 'fr': "Sélection officielle", 'es': "Destacados",
    'pt-BR': "Selecionados", 'pt-PT': "Selecionados", 'it': "In evidenza",
    'nl': "Aanbevolen", 'pl': "Polecane", 'tr': "Öne çıkanlar",
    'vi': "Tuyển chọn", 'id': "Pilihan", 'ar': "مختارات",
    'th': "คัดสรร", 'uk': "Вибране", 'fi': "Valikoidut",
    'sv': "Utvalda", 'cs': "Doporučené", 'az': "Seçilmiş",
  }),
  "dl.controls.cat.community": ("Community", {
    'zh-Hans': "社区", 'zh-Hant': "社群",
    'ja': "コミュニティ", 'ko': "커뮤니티", 'ru': "Сообщество",
    'de': "Community", 'fr': "Communauté", 'es': "Comunidad",
    'pt-BR': "Comunidade", 'pt-PT': "Comunidade", 'it': "Community",
    'nl': "Community", 'pl': "Społeczność", 'tr': "Topluluk",
    'vi': "Cộng đồng", 'id': "Komunitas", 'ar': "المجتمع",
    'th': "ชุมชน", 'uk': "Спільнота", 'fi': "Yhteisö",
    'sv': "Community", 'cs': "Komunita", 'az': "İcma",
  }),
  "dl.controls.cat.local": ("On this device", {
    'zh-Hans': "本地", 'zh-Hant': "本機",
    'ja': "この端末内", 'ko': "기기 내", 'ru': "На устройстве",
    'de': "Auf dem Gerät", 'fr': "Sur l'appareil", 'es': "En el dispositivo",
    'pt-BR': "No dispositivo", 'pt-PT': "No dispositivo", 'it': "Sul dispositivo",
    'nl': "Op dit apparaat", 'pl': "Na urządzeniu", 'tr': "Bu cihazda",
    'vi': "Trên máy này", 'id': "Di perangkat", 'ar': "على الجهاز",
    'th': "ในเครื่องนี้", 'uk': "На пристрої", 'fi': "Laitteella",
    'sv': "På enheten", 'cs': "V zařízení", 'az': "Bu cihazda",
  }),
  "dl.controls.community.empty": ("No community layouts yet — publish yours!", {
    'zh-Hans': "社区布局虚位以待——发布你的布局，让更多玩家用上！",
    'zh-Hant': "社群佈局虛位以待——發佈你的佈局，讓更多玩家用上！",
    'ja': "コミュニティレイアウトはまだありません — あなたのレイアウトを公開しよう！",
    'ko': "커뮤니티 레이아웃이 아직 없습니다 — 여러분의 레이아웃을 공유해보세요!",
    'ru': "Пользовательских раскладок пока нет — опубликуйте свою!",
  }),
  "dl.controls.community.empty.tap": ("Tap to publish your layout", {
    'zh-Hans': "点按发布你的布局", 'zh-Hant': "點按發佈你的佈局",
    'ja': "タップしてレイアウトを公開", 'ko': "눌러서 레이아웃 게시",
    'ru': "Нажмите, чтобы опубликовать",
  }),
  "dl.controls.local.empty": ("No layouts on this device yet — download from Featured or create one in the editor", {
    'zh-Hans': "本地暂无控件布局——可从官方精选下载，或在控件编辑器中创建",
    'zh-Hant': "本機暫無控件佈局——可從官方精選下載，或在控件編輯器中建立",
    'ja': "端末内にレイアウトがありません — 公式セレクトからダウンロードするか、エディタで作成してください",
    'ko': "기기에 레이아웃이 없습니다 — 공식 추천에서 다운로드하거나 에디터에서 만들어보세요",
    'ru': "На устройстве пока нет раскладок — скачайте из «Избранного» или создайте в редакторе",
  }),
  "dl.controls.local.file.sub": ("version %@ · %.1f KB", {
    'zh-Hans': "版本 %@ · %.1f KB", 'zh-Hant': "版本 %@ · %.1f KB",
    'ja': "バージョン %@ · %.1f KB", 'ko': "버전 %@ · %.1f KB",
    'ru': "версия %@ · %.1f КБ",
  }),
  "dl.controls.local.upload": ("Upload to Community", {
    'zh-Hans': "上传到社区", 'zh-Hant': "上傳到社群",
    'ja': "コミュニティにアップロード", 'ko': "커뮤니티에 업로드",
    'ru': "Опубликовать в сообществе",
  }),
  "dl.controls.local.delete": ("Delete", {
    'zh-Hans': "删除", 'zh-Hant': "刪除", 'ja': "削除", 'ko': "삭제",
    'ru': "Удалить", 'de': "Löschen", 'fr': "Supprimer", 'es': "Eliminar",
  }),
  "dl.controls.local.delete.confirm": ("Remove %@ from controlmap/? This cannot be undone.", {
    'zh-Hans': "将从 controlmap/ 移除 %@，确认删除？此操作不可撤销。",
    'zh-Hant': "將從 controlmap/ 移除 %@，確定刪除？此操作不可復原。",
    'ja': "controlmap/ から %@ を削除しますか？この操作は元に戻せません。",
    'ko': "controlmap/에서 %@를 삭제할까요? 되돌릴 수 없습니다.",
    'ru': "Удалить %@ из controlmap/? Действие необратимо.",
  }),
  "dl.controls.local.deleted": ("Deleted", {
    'zh-Hans': "已删除", 'zh-Hant': "已刪除", 'ja': "削除しました",
    'ko': "삭제됨", 'ru': "Удалено",
  }),
  "dl.controls.local.delete.active": ("This is the active default layout — switch to another layout in the editor first", {
    'zh-Hans': "这是当前使用的默认布局——请先在控件编辑器中切换到其他布局再删除",
    'zh-Hant': "這是目前使用的預設佈局——請先在控件編輯器中切換到其他佈局再刪除",
    'ja': "使用中のデフォルトレイアウトです — エディタで他のレイアウトに切り替えてから削除してください",
    'ko': "현재 사용 중인 기본 레이아웃입니다 — 에디터에서 다른 레이아웃으로 전환한 후 삭제하세요",
    'ru': "Это текущая раскладка по умолчанию — сначала выберите другую в редакторе",
  }),
  "controller.toast.connected": ("Controller connected: %@\nVirtual mouse enabled", {
    'zh-Hans': "手柄已连接：%@\n虚拟鼠标已启用", 'zh-Hant': "手把已連線：%@\n虛擬滑鼠已啟用",
    'ja': "コントローラー接続：%@\nバーチャルマウス有効", 'ko': "컨트롤러 연결됨: %@\n가상 마우스 활성화",
    'ru': "Геймпад подключён: %@\nВиртуальная мышь включена",
    'de': "Controller verbunden: %@\nVirtuelle Maus aktiv",
    'fr': "Manette connectée : %@\nSouris virtuelle activée",
    'es': "Mando conectado: %@\nRatón virtual activado",
  }),
  "controller.profile.unsupported": ("Controller \"%@\" has no full gamepad profile — pair both Joy-Con halves and retry", {
    'zh-Hans': "手柄「%@」未提供完整档案——单边 Joy-Con 请成对连接后再试",
    'zh-Hant': "手把「%@」未提供完整檔案——單邊 Joy-Con 請成對連線後再試",
    'ja': "コントローラー「%@」は完全なプロファイルを提供していません — Joy-Con は左右をペアにして接続してください",
    'ko': "컨트롤러 '%@'에 전체 게임패드 프로필이 없습니다 — 조이콘은 좌우를 페어로 연결하세요",
    'ru': "Геймпад «%@» не предоставил полный профиль — подключите оба Joy-Con парой",
  }),
  "preference.title.nintendo_layout": ("Nintendo layout (A↔B / X↔Y swap)", {
    'zh-Hans': "Switch/任天堂键位（A↔B、X↔Y 交换）",
    'zh-Hant': "Switch/任天堂鍵位（A↔B、X↔Y 交換）",
    'ja': "任天堂レイアウト（A↔B / X↔Y 入れ替え）",
    'ko': "닌텐도 레이아웃 (A↔B / X↔Y 교체)",
    'ru': "Раскладка Nintendo (A↔B / X↔Y)",
    'de': "Nintendo-Layout (A↔B / X↔Y tauschen)",
    'fr': "Disposition Nintendo (échanger A↔B / X↔Y)",
    'es': "Distribución Nintendo (intercambiar A↔B / X↔Y)",
  }),
  "preference.detail.nintendo_layout": ("For Switch/Pro/Joy-Con controllers whose printed labels are reversed: swap A↔B and X↔Y before mapping, so the button printed \"A\" acts as A", {
    'zh-Hans': "Switch/Pro/Joy-Con 的键面印刷与标准位置相反时开启：面键 A↔B、X↔Y 交换后再查映射，按印刷 \"A\" 即 A 的功能（跳跃等）",
    'zh-Hant': "Switch/Pro/Joy-Con 的鍵面印刷與標準位置相反時開啟：面鍵 A↔B、X↔Y 交換後再查映射，按印刷 \"A\" 即 A 的功能（跳躍等）",
    'ja': "Switch/Pro/Joy-Con など刻印が標準位置と逆のコントローラー向け：面ボタン A↔B、X↔Y を入れ替えてからマッピングするため、刻印「A」で A の動作（ジャンプなど）になります",
    'ko': "Switch/Pro/Joy-Con처럼 표기가 표준 위치와 반대인 컨트롤러용: A↔B, X↔Y를 교환한 뒤 매핑하므로 'A'로 인쇄된 버튼이 A 기능(점프 등)을 수행합니다",
    'ru': "Для контроллеров Switch/Pro/Joy-Con с обратной маркировкой: A↔B и X↔Y меняются местами перед маппингом — кнопка «A» выполняет функцию A",
  }),
  "preference.title.scroll_speed": ("Simulated wheel speed (%)", {
    'zh-Hans': "模拟滚轮速度 (%)", 'zh-Hant': "模擬滾輪速度 (%)",
    'ja': "模擬ホイール速度 (%)", 'ko': "가상 휠 속도 (%)",
    'ru': "Скорость виртуального колеса (%)",
    'de': "Simuliertes Radtempo (%)", 'fr': "Vitesse de molette simulée (%)",
    'es': "Velocidad de rueda simulada (%)",
  }),
  "preference.detail.scroll_speed": ("Scroll step multiplier for on-screen scroll buttons and gamepad scroll keys; a real mouse wheel is unaffected", {
    'zh-Hans': "触屏布局滚动按钮与手柄滚动键的滚轮步进倍率；真鼠标滚轮不受影响",
    'zh-Hant': "觸屏佈局滾動按鈕與手把滾動鍵的滾輪步進倍率；真滑鼠滾輪不受影響",
    'ja': "画面上のスクロールボタンとコントローラーのスクロールキーのステップ倍率。実マウスのホイールには影響しません",
    'ko': "화면 스크롤 버튼과 컨트롤러 스크롤 키의 스텝 배율입니다. 실제 마우스 휠에는 영향이 없습니다",
    'ru': "Множитель шага прокрутки для экранных кнопок и клавиш геймпада; колесо настоящей мыши не затронуто",
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
    # 注意：翻译表里已用 \\n 书写 toast 多行（objc format 前已是真反斜杠+n）；
    # 这里再做标准转义（引号/反斜杠），保证落表内容合法。
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
            content = f.read()
        pending = []
        for key, (en, table) in KEYS.items():
            if ('"' + key + '"') in content:
                continue
            value = esc(text_for(lang, table, en))
            pending.append('"%s" = "%s";\n' % (key, value))
        if pending:
            with open(strings, 'a', encoding='utf-8') as f:
                if not content.endswith('\n'):
                    f.write('\n')
                f.writelines(pending)
            added_total += len(pending)
    print("task310: tables=%d added=%d keys=%d" % (total_tables, added_total, len(KEYS)))
    if total_tables == 0:
        raise SystemExit("ERROR: no strings tables found")

if __name__ == '__main__':
    main()
