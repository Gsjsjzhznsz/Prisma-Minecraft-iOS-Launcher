#!/usr/bin/env python3
# Task312: i18n 批处理——
#   新增 7 键（×54 表）：regiongate.*（服务地区门：
#     title / message / ack1 / ack2 / ack3 / not_mainland / exit）
#   用户指令（2026-10-20）：明面上启动器不对中国大陆地区用户开放，
#   多角度检测命中即弹「服务地区声明」，下方「我不是大陆用户」按钮，
#   3 次提示后放行；弹窗链全键走 localize，54 表齐备。
# 机制与 task311_i18n.py 一致：append-if-missing + ALIAS 回退 + esc() 转义。
import os, re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

KEYS = {
  "regiongate.title": ("Service Region Notice", {
    'zh-Hans': "服务地区声明", 'zh-Hant': "服務地區聲明",
    'ja': "サービス提供地域に関するお知らせ", 'ko': "서비스 제공 지역 안내",
    'ru': "Уведомление о регионе обслуживания",
    'de': "Hinweis zum Serviceregion", 'fr': "Avis de zone de service",
    'es': "Aviso de región de servicio", 'pt-BR': "Aviso de região de serviço",
    'pt-PT': "Aviso de região de serviço", 'it': "Avviso sull'area di servizio",
    'nl': "Serviceregio-melding", 'pl': "Powiadomienie o regionie usługi",
    'tr': "Hizmet Bölgesi Bildirimi", 'vi': "Thông báo khu vực dịch vụ",
    'id': "Pemberitahuan Wilayah Layanan", 'ar': "إشعار منطقة الخدمة",
    'th': "ประกาศเขตพื้นที่ให้บริการ", 'uk': "Повідомлення про регіон обслуговування",
    'fi': "Palvelualueilmoitus", 'sv': "Serviceområde meddelande",
    'cs': "Oznámení o servisní oblasti", 'az': "Xidmət bölgəsi bildirişi",
  }),
  "regiongate.message": ("This launcher is not available to users in mainland China. It is a community project, unaffiliated with Mojang Studios, Microsoft, or NetEase (the mainland China publisher), and is not distributed or serviced in mainland China. If you are not a mainland China user, tap \"I am not a mainland user\" to continue.", {
    'zh-Hans': "本启动器不对中国大陆地区用户开放。本启动器为社区项目，与 Mojang Studios、Microsoft 及网易（中国大陆地区代理方）均无关联，也未在中国大陆地区进行分发或提供服务。若您不是中国大陆地区用户，请点击「我不是大陆用户」继续。",
    'zh-Hant': "本啟動器不對中國大陸地區使用者開放。本啟動器為社群專案，與 Mojang Studios、Microsoft 及網易（中國大陸地區代理方）均無關聯，也未在中國大陸地區進行散布或提供服務。若您不是中國大陸地區使用者，請點選「我不是大陸使用者」繼續。",
    'ja': "このランチャーは中国本土のユーザーには提供されていません。本ランチャーはコミュニティプロジェクトであり、Mojang Studios、Microsoft、および網易（中国本土代理店）とは無関係で、中国本土では配布・サービスを行っていません。中国本土のユーザーでない場合は、「私は本土ユーザーではありません」をタップして続行してください。",
    'ko': "이 런처는 중국 본토 사용자에게 제공되지 않습니다. 본 런처는 커뮤니티 프로젝트로, Mojang Studios, Microsoft 및 NetEase(중국 본토 퍼블리셔)와 무관하며 중국 본토에서 배포되거나 서비스를 제공하지 않습니다. 본토 사용자가 아니라면 '본토 사용자가 아닙니다'를 눌러 계속하세요.",
    'ru': "Этот лаунчер недоступен пользователям материкового Китая. Это проект сообщества, не связанный с Mojang Studios, Microsoft или NetEase (издателем в материковом Китае); он не распространяется и не обслуживается в материковом Китае. Если вы не пользователь из материкового Китая, нажмите «Я не пользователь материка», чтобы продолжить.",
    'de': "Dieser Launcher ist für Nutzer in Festlandchina nicht verfügbar. Es ist ein Community-Projekt ohne Verbindung zu Mojang Studios, Microsoft oder NetEase (dem Publisher für Festlandchina) und wird in Festlandchina nicht vertrieben oder unterstützt. Wenn Sie kein Nutzer aus Festlandchina sind, tippen Sie auf \"Ich bin kein Festland-Nutzer\", um fortzufahren.",
    'fr': "Ce lanceur n'est pas disponible pour les utilisateurs de Chine continentale. Il s'agit d'un projet communautaire, sans lien avec Mojang Studios, Microsoft ou NetEase (l'éditeur pour la Chine continentale), et n'est ni distribué ni pris en charge en Chine continentale. Si vous n'êtes pas un utilisateur de Chine continentale, appuyez sur « Je ne suis pas un utilisateur du continent » pour continuer.",
    'es': "Este launcher no está disponible para usuarios de China continental. Es un proyecto comunitario, sin afiliación con Mojang Studios, Microsoft ni NetEase (la editora de China continental), y no se distribuye ni ofrece servicio en China continental. Si no eres usuario de China continental, pulsa \"No soy usuario del continente\" para continuar.",
    'pt-BR': "Este launcher não está disponível para usuários da China continental. É um projeto comunitário, sem vínculo com Mojang Studios, Microsoft ou NetEase (a publicadora da China continental), e não é distribuído ou atendido na China continental. Se você não é um usuário da China continental, toque em \"Não sou usuário do continente\" para continuar.",
    'pt-PT': "Este launcher não está disponível para utilizadores da China continental. É um projeto comunitário, sem ligação à Mojang Studios, Microsoft ou NetEase (a editora da China continental), e não é distribuído ou suportado na China continental. Se não é utilizador da China continental, toque em \"Não sou utilizador do continente\" para continuar.",
    'it': "Questo launcher non è disponibile per gli utenti della Cina continentale. È un progetto della community, non affiliato a Mojang Studios, Microsoft o NetEase (l'editore per la Cina continentale), e non viene distribuito né supportato nella Cina continentale. Se non sei un utente della Cina continentale, tocca \"Non sono un utente del continente\" per continuare.",
    'nl': "Deze launcher is niet beschikbaar voor gebruikers in continentaal China. Het is een communityproject, niet gelieerd aan Mojang Studios, Microsoft of NetEase (de uitgever voor continentaal China), en wordt niet gedistribueerd of ondersteund in continentaal China. Als je geen gebruiker uit continentaal China bent, tik dan op \"Ik ben geen vastelandgebruiker\" om door te gaan.",
    'pl': "Ten launcher nie jest dostępny dla użytkowników z kontynentalnych Chin. To projekt społecznościowy, niezwiązany z Mojang Studios, Microsoft ani NetEase (wydawcą dla kontynentalnych Chin) i nie jest dystrybuowany ani obsługiwany w kontynentalnych Chinach. Jeśli nie jesteś użytkownikiem z kontynentalnych Chin, dotknij „Nie jestem użytkownikiem z kontynentu”, aby kontynuować.",
    'tr': "Bu başlatıcı, Çin anakarasındaki kullanıcılara sunulmamaktadır. Bu bir topluluk projesidir; Mojang Studios, Microsoft veya NetEase (Çin anakarası yayıncısı) ile bağlantısı yoktur ve Çin anakarasında dağıtılmaz veya hizmet vermez. Anakara Çin kullanıcısı değilseniz devam etmek için \"Ben anakara kullanıcısı değilim\" düğmesine dokunun.",
    'vi': "Trình khởi chạy này không dành cho người dùng tại Trung Quốc đại lục. Đây là dự án cộng đồng, không liên quan đến Mojang Studios, Microsoft hay NetEase (nhà phát hành tại Trung Quốc đại lục), và không được phân phối hay hỗ trợ tại Trung Quốc đại lục. Nếu bạn không phải người dùng từ đại lục, hãy nhấn \"Tôi không phải người dùng đại lục\" để tiếp tục.",
    'id': "Launcher ini tidak tersedia untuk pengguna di Tiongkok daratan. Ini adalah proyek komunitas, tidak berafiliasi dengan Mojang Studios, Microsoft, atau NetEase (penerbit untuk Tiongkok daratan), serta tidak didistribusikan atau dilayani di Tiongkok daratan. Jika Anda bukan pengguna dari daratan, ketuk \"Saya bukan pengguna daratan\" untuk melanjutkan.",
    'ar': "هذا المشغّل غير متاح للمستخدمين في الصين القارية. وهو مشروع مجتمعي، غير تابع لـ Mojang Studios أو Microsoft أو NetEase (الناشر في الصين القارية)، ولا يتم توزيعه أو تقديم خدمته في الصين القارية. إذا لم تكن مستخدمًا من الصين القارية، فاضغط على \"لست مستخدمًا من القارة\" للمتابعة.",
    'th': "ตัวเรียกใช้งานนี้ไม่เปิดให้ใช้งานสำหรับผู้ใช้ในจีนแผ่นดินใหญ่ เป็นโครงการชุมชนที่ไม่เกี่ยวข้องกับ Mojang Studios, Microsoft หรือ NetEase (ผู้จัดจำหน่ายในจีนแผ่นดินใหญ่) และไม่มีการจัดจำหน่ายหรือให้บริการในจีนแผ่นดินใหญ่ หากคุณไม่ใช่ผู้ใช้จากแผ่นดินใหญ่ แตะ \"ฉันไม่ใช่ผู้ใช้จากแผ่นดินใหญ่\" เพื่อดำเนินการต่อ",
    'uk': "Цей лаунчер недоступний для користувачів материкового Китаю. Це проєкт спільноти, не пов'язаний з Mojang Studios, Microsoft або NetEase (видавцем у материковому Китаї); він не поширюється і не обслуговується в материковому Китаї. Якщо ви не користувач з материкового Китаю, натисніть «Я не користувач материка», щоб продовжити.",
    'fi': "Tämä käynnistin ei ole käytettävissä manner-Kiinan käyttäjille. Se on yhteisöprojekti, jolla ei ole yhteyttä Mojang Studiosiin, Microsoftiin tai NetEaseen (manner-Kiinan julkaisijaan), eikä sitä jaeta tai tueta manner-Kiinassa. Jos et ole manner-Kiinan käyttäjä, napauta \"En ole manner-Kiinan käyttäjä\" jatkaaksesi.",
    'sv': "Denna startare är inte tillgänglig för användare i fastlands-Kina. Det är ett communityprojekt utan koppling till Mojang Studios, Microsoft eller NetEase (utgivaren i fastlands-Kina) och distribueras eller servas inte i fastlands-Kina. Om du inte är användare från fastlandet, tryck på \"Jag är inte fastlandsanvändare\" för att fortsätta.",
    'cs': "Tento spouštěč není k dispozici uživatelům v pevninské Číně. Jde o komunitní projekt, který nesouvisí s Mojang Studios, Microsoft ani NetEase (vydavatelem pro pevninskou Čínu) a není v pevninské Číně distribuován ani podporován. Pokud nejste uživatel z pevninské Číny, klepněte na „Nejsem uživatel z pevniny“ a pokračujte.",
    'az': "Bu başladıcı Çin materikindəki istifadəçilər üçün əlçatan deyil. Bu icma layihəsidir; Mojang Studios, Microsoft və ya NetEase (Çin materik nəşriyyatı) ilə əlaqəsi yoxdur və Çin materikində yayımlanmır və xidmət göstərmir. Materik Çin istifadəçisi deysinizsə, davam etmək üçün \"Mən materik istifadəçisi deyiləm\" düyməsinə toxunun.",
  }),
  "regiongate.ack1": ("Notice 1/3: please confirm your service region again.", {
    'zh-Hans': "提示 1/3：请再次确认您所在的服务地区。",
    'zh-Hant': "提示 1/3：請再次確認您所在的服務地區。",
    'ja': "お知らせ 1/3：お住まいのサービス提供地域を再度ご確認ください。",
    'ko': "안내 1/3: 서비스 제공 지역을 다시 한 번 확인해 주세요.",
    'ru': "Уведомление 1/3: пожалуйста, снова подтвердите ваш регион обслуживания.",
    'de': "Hinweis 1/3: Bitte bestätigen Sie Ihre Serviceregion erneut.",
    'fr': "Avis 1/3 : veuillez confirmer à nouveau votre zone de service.",
    'es': "Aviso 1/3: confirma de nuevo tu región de servicio.",
    'pt-BR': "Aviso 1/3: confirme novamente sua região de serviço.",
  }),
  "regiongate.ack2": ("Notice 2/3: continuing means you confirm that you are not a mainland China user.", {
    'zh-Hans': "提示 2/3：继续使用即表示您确认自己不属于中国大陆地区用户。",
    'zh-Hant': "提示 2/3：繼續使用即表示您確認自己不屬於中國大陸地區使用者。",
    'ja': "お知らせ 2/3：続行すると、あなたが中国本土のユーザーではないことを確認したものとみなされます。",
    'ko': "안내 2/3: 계속하면 중국 본토 사용자가 아님을 확인한 것으로 간주됩니다.",
    'ru': "Уведомление 2/3: продолжая, вы подтверждаете, что не являетесь пользователем из материкового Китая.",
    'de': "Hinweis 2/3: Das Fortfahren bedeutet, dass Sie bestätigen, kein Nutzer aus Festlandchina zu sein.",
    'fr': "Avis 2/3 : continuer signifie que vous confirmez ne pas être un utilisateur de Chine continentale.",
    'es': "Aviso 2/3: continuar implica que confirmas que no eres usuario de China continental.",
    'pt-BR': "Aviso 2/3: continuar significa que você confirma que não é um usuário da China continental.",
  }),
  "regiongate.ack3": ("Final notice (3/3): thank you for confirming. Continuing...", {
    'zh-Hans': "最终提示（3/3）：感谢您的确认，即将继续。",
    'zh-Hant': "最終提示（3/3）：感謝您的確認，即將繼續。",
    'ja': "最終のお知らせ（3/3）：ご確認ありがとうございます。続行します…",
    'ko': "최종 안내(3/3): 확인해 주셔서 감사합니다. 계속 진행합니다...",
    'ru': "Финальное уведомление (3/3): спасибо за подтверждение. Продолжаем...",
    'de': "Letzter Hinweis (3/3): Danke für Ihre Bestätigung. Fahre fort...",
    'fr': "Avis final (3/3) : merci de votre confirmation. Poursuite...",
    'es': "Aviso final (3/3): gracias por confirmar. Continuando...",
    'pt-BR': "Aviso final (3/3): obrigado por confirmar. Continuando...",
  }),
  "regiongate.not_mainland": ("I am not a mainland user", {
    'zh-Hans': "我不是大陆用户", 'zh-Hant': "我不是大陸使用者",
    'ja': "私は本土ユーザーではありません", 'ko': "본토 사용자가 아닙니다",
    'ru': "Я не пользователь материка",
    'de': "Ich bin kein Festland-Nutzer", 'fr': "Je ne suis pas un utilisateur du continent",
    'es': "No soy usuario del continente", 'pt-BR': "Não sou usuário do continente",
    'pt-PT': "Não sou utilizador do continente", 'it': "Non sono un utente del continente",
    'nl': "Ik ben geen vastelandgebruiker", 'pl': "Nie jestem użytkownikiem z kontynentu",
    'tr': "Ben anakara kullanıcısı değilim", 'vi': "Tôi không phải người dùng đại lục",
    'id': "Saya bukan pengguna daratan", 'ar': "لست مستخدمًا من القارة",
    'th': "ฉันไม่ใช่ผู้ใช้จากแผ่นดินใหญ่", 'uk': "Я не користувач материка",
    'fi': "En ole manner-Kiinan käyttäjä", 'sv': "Jag är inte fastlandsanvändare",
    'cs': "Nejsem uživatel z pevniny", 'az': "Mən materik istifadəçisi deyiləm",
  }),
  "regiongate.exit": ("Exit", {
    'zh-Hans': "退出", 'zh-Hant': "結束",
    'ja': "終了", 'ko': "종료", 'ru': "Выход",
    'de': "Beenden", 'fr': "Quitter", 'es': "Salir",
    'pt-BR': "Sair", 'pt-PT': "Sair", 'it': "Esci",
    'nl': "Afsluiten", 'pl': "Zakończ", 'tr': "Çıkış",
    'vi': "Thoát", 'id': "Keluar", 'ar': "خروج",
    'th': "ออก", 'uk': "Вихід", 'fi': "Lopeta",
    'sv': "Avsluta", 'cs': "Ukončit", 'az': "Çıxış",
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
    print("task312: tables=%d added=%d keys=%d" % (total_tables, added_total, len(KEYS)))
    if total_tables == 0:
        raise SystemExit("ERROR: no strings tables found")

if __name__ == '__main__':
    main()
