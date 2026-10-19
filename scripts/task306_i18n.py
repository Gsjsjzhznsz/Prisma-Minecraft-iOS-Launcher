#!/usr/bin/env python3
# Task306: register "ame306.jit.spawn_denied" into all Localizable.strings
# tables + fix zh-CN English residue of "ame302.jit.lc_guest" (task302 script
# lacked a 'zh-CN' alias so text_for('zh-CN') fell through to EN).
# Pattern follows task302_i18n_lc.py; reports parity.
import os, re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

KEY306 = "ame306.jit.spawn_denied"
KEY302 = "ame302.jit.lc_guest"

EN306 = ("Builtin JIT is unavailable with this install: the non-jailbroken sandbox "
         "denies spawning the JIT helper process (only TrollStore/jailbroken hosts "
         "may allow it). Just press Launch -- JIT is requested automatically via "
         "StikDebug; or enable JIT for the launcher manually inside StikDebug.")

ZH302 = ("LiveContainer 环境下无法使用内置 JIT：系统拒绝在此启动 JIT 助手进程（扩展注册与进程派生均被拒绝）。请改用 StikDebug / SideStore 开启——JIT 开启工具选“自动”，启动时会自动跳转。")

T306 = {
 'en': EN306,
 'zh-Hans': "当前安装方式无法使用内置 JIT：非越狱沙盒拒绝派生 JIT 辅助进程（仅 TrollStore / 越狱环境可能允许）。直接点“启动游戏”即可——JIT 会经 StikDebug 自动申请；也可在 StikDebug 应用内手动为启动器开启 JIT。",
 'zh-Hant': "目前安裝方式無法使用內建 JIT：非越獄沙盒拒絕衍生 JIT 輔助程序（僅 TrollStore / 越獄環境可能允許）。直接點「啟動遊戲」即可——JIT 會經 StikDebug 自動申請；也可在 StikDebug 應用內手動為啟動器開啟 JIT。",
 'ja': "このインストール形態では内蔵 JIT を利用できません：非脱獄のサンドボックスが JIT ヘルパープロセスの起動を拒否します（TrollStore / 脱獄環境のみ許可の可能性）。そのまま「起動」を押せば StikDebug 経由で自動的に JIT を申請します。StikDebug アプリ内で手動的に有効化することもできます。",
 'ko': "이 설치 방식에서는 내장 JIT를 사용할 수 없습니다: 비탈옥 샌드박스가 JIT 헬퍼 프로세스 실행을 거부합니다(TrollStore/탈옥 환경만 허용 가능). 그냥 '게임 시작'을 누르면 StikDebug를 통해 JIT가 자동으로 요청되며, StikDebug 앱에서 수동으로 활성화할 수도 있습니다.",
 'ru': "Встроенный JIT недоступен при такой установке: песочница без джейлбрейка запрещает запуск вспомогательного процесса JIT (возможен только на TrollStore/джейлбрейке). Просто нажмите «Запустить» — JIT будет запрошен автоматически через StikDebug, либо включите JIT вручную в приложении StikDebug.",
 'de': "Integriertes JIT ist mit dieser Installation nicht verfügbar: die Sandbox ohne Jailbreak verweigert das Starten des JIT-Hilfsprozesses (nur TrollStore/Jailbreak erlauben dies). Drücken Sie einfach „Starten“ – JIT wird automatisch über StikDebug angefordert; oder aktivieren Sie JIT manuell in der StikDebug-App.",
 'fr': "Le JIT intégré est indisponible avec cette installation : le bac à sable sans jailbreak refuse de lancer le processus assistant JIT (seuls TrollStore/jailbreak peuvent l'autoriser). Appuyez simplement sur « Lancer » — le JIT sera demandé automatiquement via StikDebug ; ou activez-le manuellement dans StikDebug.",
 'es': "El JIT integrado no está disponible con esta instalación: el sandbox sin jailbreak niega el inicio del proceso auxiliar JIT (solo TrollStore/jailbreak pueden permitirlo). Solo pulsa «Iniciar»: el JIT se solicitará automáticamente vía StikDebug; o actívalo manualmente dentro de StikDebug.",
 'pt-BR': "O JIT integrado não está disponível nesta instalação: o sandbox sem jailbreak nega a execução do processo auxiliar de JIT (apenas TrollStore/jailbreak podem permitir). Basta tocar em «Iniciar» — o JIT será solicitado automaticamente via StikDebug; ou ative-o manualmente no app StikDebug.",
 'pt-PT': "O JIT integrado não está disponível nesta instalação: a sandbox sem jailbreak recusa iniciar o processo auxiliar de JIT (apenas TrollStore/jailbreak o podem permitir). Basta premir «Iniciar» — o JIT será pedido automaticamente via StikDebug; ou ative-o manualmente na app StikDebug.",
 'it': "Il JIT integrato non è disponibile con questa installazione: il sandbox senza jailbreak nega l'avvio del processo helper JIT (solo TrollStore/jailbreak possono consentirlo). Premi semplicemente «Avvia»: il JIT verrà richiesto automaticamente tramite StikDebug; oppure attivalo manualmente nell'app StikDebug.",
 'nl': "Ingebouwde JIT is niet beschikbaar bij deze installatie: de sandbox zonder jailbreak weigert het JIT-hulpproces te starten (alleen TrollStore/jailbreak staan dit toe). Druk gewoon op «Starten» — JIT wordt automatisch via StikDebug aangevraagd; of schakel het handmatig in binnen StikDebug.",
 'pl': "Wbudowane JIT jest niedostępne przy tej instalacji: sandbox bez jailbreaku odmawia uruchomienia procesu pomocniczego JIT (tylko TrollStore/jailbreak mogą na to zezwolić). Po prostu naciśnij «Uruchom» — JIT zostanie automatycznie zamówiony przez StikDebug; albo włącz go ręcznie w aplikacji StikDebug.",
 'tr': "Bu kurulumda yerleşik JIT kullanılamıyor: jailbreak'siz sanal alan JIT yardımcı sürecini başlatmayı reddediyor (yalnızca TrollStore/jailbreak izin verebilir). Sadece 'Başlat'a dokunun — JIT, StikDebug üzerinden otomatik istenecek; ya da StikDebug uygulaması içinde elle etkinleştirin.",
 'vi': "JIT tích hợp không khả dụng với cách cài đặt này: sandbox không jailbreak từ chối khởi chạy tiến trình trợ lý JIT (chỉ TrollStore/jailbreak có thể cho phép). Chỉ cần nhấn «Khởi động» — JIT sẽ được tự động yêu cầu qua StikDebug; hoặc bật thủ công trong ứng dụng StikDebug.",
 'id': "JIT bawaan tidak tersedia dengan pemasangan ini: sandbox tanpa jailbreak menolak menjalankan proses pembantu JIT (hanya TrollStore/jailbreak yang dapat mengizinkan). Cukup tekan «Mulai» — JIT akan diminta otomatis lewat StikDebug; atau aktifkan secara manual di aplikasi StikDebug.",
 'ar': "JIT المدمج غير متاح مع طريقة التثبيت هذه: يرفض صندوق الحماية غير الجيلبريك تشغيل عملية مساعد JIT (TrollStore أو الجيلبريك فقط قد يسمحان بذلك). اضغط «تشغيل» فقط — سيُطلب JIT تلقائيًا عبر StikDebug؛ أو فعّله يدويًا داخل تطبيق StikDebug.",
 'th': "ไม่สามารถใช้ JIT ในตัวได้กับการติดตั้งนี้: แซนด์บ็อกซ์แบบไม่เจลเบรกปฏิเสธการเริ่มกระบวนการช่วย JIT (เฉพาะ TrollStore/เจลเบรกเท่านั้นที่อาจอนุญาต) เพียงกด «เริ่มเกม» — JIT จะถูกร้องขออัตโนมัติผ่าน StikDebug หรือเปิดเองในแอป StikDebug",
 'uk': "Вбудований JIT недоступний за такого встановлення: пісочниця без джейлбрейку відмовляє у запуску допоміжного процесу JIT (лише TrollStore/джейлбрейк можуть це дозволити). Просто натисніть «Запустити» — JIT буде автоматично запитано через StikDebug; або увімкніть його вручну у застосунку StikDebug.",
 'fi': "Sisäänrakennettu JIT ei ole käytettävissä tällä asennustavalla: jailbreakaton hiekkalaatikko estää JIT-avuprosessin käynnistyksen (vain TrollStore/jailbreak voi sallia sen). Paina vain «Käynnistä» — JIT pyydetään automaattisesti StikDebugin kautta; tai ota se käyttöön manuaalisesti StikDebug-sovelluksessa.",
 'sv': "Inbyggd JIT är inte tillgänglig med denna installation: sandboxen utan jailbreak nekar att starta JIT-hjälpprocessen (endast TrollStore/jailbreak kan tillåta det). Tryck bara på «Starta» — JIT begärs automatiskt via StikDebug; eller aktivera det manuellt i StikDebug-appen.",
 'cs': "Vestavěné JIT není s touto instalací k dispozici: sandbox bez jailbreaku odmítá spustit pomocný proces JIT (povolit jej může pouze TrollStore/jailbreak). Stačí stisknout «Spustit» — JIT bude automaticky vyžádán přes StikDebug; nebo jej povolte ručně v aplikaci StikDebug.",
 'az': "Bu quraşdırma ilə daxili JIT əlçatmazdır: jailbreaksiz sandbox JIT köməkçi prosesini işə salmaqdan imtina edir (yalnız TrollStore/jailbreak icazə verə bilər). Sadəcə «Başlat» düyməsinə basın — JIT StikDebug vasitəsilə avtomatik soruşulacaq; ya da StikDebug tətbiqində əl ilə aktivləşdirin.",
}

ALIAS = {
 'en-GB': 'en', 'en-PT': 'en', 'en-UD': 'en',
 'zh-CN': 'zh-Hans', 'zh-Hans': 'zh-Hans', 'zh-Hant': 'zh-Hant', 'zh': 'zh-Hans',
 'nb': 'no', 'nn': 'no', 'in': 'id', 'iw': 'he', 'fil': 'tl', 'tl': 'tl',
 'pt': 'pt-PT', 'sr-Latn': 'sr', 'bs': 'hr', 'me': 'sr',
}

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

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

def main():
    total, added, fixed302 = 0, 0, 0
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
        changed = False

        # (a) register ame306.jit.spawn_denied when absent
        if '"%s"' % KEY306 not in content:
            line = '"%s" = "%s";\n' % (KEY306, esc(text_for(lang, T306, EN306)))
            if not content.endswith('\n'):
                content += '\n'
            content += line
            added += 1
            changed = True

        # (b) fix zh tables' English residue of ame302.jit.lc_guest
        if lang in ('zh-CN', 'zh-Hans'):
            pat = re.compile(r'"%s" = "Builtin JIT is unavailable[^"]*";\n' % re.escape(KEY302))
            if pat.search(content):
                content = pat.sub('"%s" = "%s";\n' % (KEY302, esc(ZH302)), content)
                fixed302 += 1
                changed = True

        if changed:
            with open(strings, 'w', encoding='utf-8') as f:
                f.write(content)
    print('tables=%d added306=%d fixed302_zh=%d' % (total, added, fixed302))

if __name__ == '__main__':
    main()
