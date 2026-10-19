#!/usr/bin/env python3
# Task302: register "ame302.jit.lc_guest" into all Localizable.strings tables.
# Pattern follows task301 residual i18n: real translations for major languages,
# English fallback for the rest. Reports parity.
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')
KEY = "ame302.jit.lc_guest"

EN = ("Builtin JIT is unavailable inside LiveContainer: the system refuses to spawn "
      "the JIT helper process here (extension registration and process exec are both "
      "denied). Enable JIT via StikDebug or SideStore instead -- set the JIT enabler "
      "to Auto and the launcher will hand off automatically at launch.")

T = {
 'en': EN,
 'zh-Hans': "LiveContainer 环境下无法使用内置 JIT：系统拒绝在此启动 JIT 助手进程（扩展注册与进程派生均被拒绝）。请改用 StikDebug / SideStore 开启——JIT 开启工具选“自动”，启动时会自动跳转。",
 'zh-Hant': "LiveContainer 環境下無法使用內建 JIT：系統拒絕在此啟動 JIT 助手程序（擴充註冊與程序衍生均被拒絕）。請改用 StikDebug / SideStore 開啟——JIT 開啟工具選「自動」，啟動時會自動跳轉。",
 'ja': "LiveContainer 環境では内蔵 JIT を利用できません：システムが JIT ヘルパープロセスの起動を拒否します（拡張登録とプロセス実行の両方が拒否）。StikDebug / SideStore で JIT を有効にしてください（JIT ツールを「自動」に設定すると起動時に自動で連携します）。",
 'ko': "LiveContainer 환경에서는 내장 JIT를 사용할 수 없습니다: 시스템이 JIT 헬퍼 프로세스 실행을 거부합니다(확장 등록과 프로세스 실행 모두 거부). StikDebug / SideStore로 JIT를 활성화하세요(JIT 도구를 '자동'으로 설정하면 시작 시 자동으로 연동됩니다).",
 'ru': "Встроенный JIT недоступен внутри LiveContainer: система запрещает запуск вспомогательного процесса JIT (отказано и в регистрации расширения, и в запуске процесса). Включите JIT через StikDebug или SideStore — выберите «Авто» в инструменте JIT для автоматического перехода при запуске.",
 'de': "Integriertes JIT ist in LiveContainer nicht verfügbar: Das System verweigert das Starten des JIT-Hilfsprozesses (sowohl Erweiterungsregistrierung als auch Prozessstart werden abgelehnt). Aktivieren Sie JIT über StikDebug oder SideStore – stellen Sie das JIT-Tool auf „Automatisch“, dann übergibt der Launcher beim Start automatisch.",
 'fr': "Le JIT intégré est indisponible dans LiveContainer : le système refuse de lancer le processus assistant JIT (l'enregistrement d'extension et l'exécution de processus sont tous deux refusés). Activez le JIT via StikDebug ou SideStore — réglez l'outil JIT sur « Auto » pour un transfert automatique au lancement.",
 'es': "El JIT integrado no está disponible en LiveContainer: el sistema rechaza iniciar el proceso auxiliar JIT (se deniegan tanto el registro de extensiones como la ejecución de procesos). Active el JIT con StikDebug o SideStore: ponga la herramienta JIT en «Auto» para el traspaso automático al iniciar.",
 'it': "Il JIT integrato non è disponibile in LiveContainer: il sistema rifiuta di avviare il processo helper JIT (sia la registrazione dell'estensione che l'esecuzione dei processi sono negate). Abilita il JIT tramite StikDebug o SideStore: imposta lo strumento JIT su «Auto» per il passaggio automatico all'avvio.",
 'pt-BR': "O JIT integrado não está disponível no LiveContainer: o sistema se recusa a iniciar o processo auxiliar de JIT (o registro de extensão e a execução de processos são negados). Ative o JIT via StikDebug ou SideStore — defina a ferramenta JIT como «Auto» para a transferência automática ao iniciar.",
 'pt-PT': "O JIT integrado não está disponível no LiveContainer: o sistema recusa-se a iniciar o processo auxiliar de JIT (o registo de extensões e a execução de processos são negados). Ative o JIT via StikDebug ou SideStore — defina a ferramenta JIT como «Auto» para a transferência automática ao iniciar.",
 'nl': "Ingebouwde JIT is niet beschikbaar in LiveContainer: het systeem weigert het JIT-hulpproces te starten (zowel extensieregistratie als het starten van processen worden geweigerd). Gebruik StikDebug of SideStore om JIT in te schakelen — zet de JIT-tool op 'Automatisch' voor automatische overdracht bij het starten.",
 'pl': "Wbudowane JIT jest niedostępne w LiveContainer: system odmawia uruchomienia procesu pomocniczego JIT (zarówno rejestracja rozszerzeń, jak i uruchamianie procesów są odrzucane). Włącz JIT przez StikDebug lub SideStore — ustaw narzędzie JIT na «Auto», aby automatycznie przekazywać przy starcie.",
 'tr': "LiveContainer içinde yerleşik JIT kullanılamıyor: sistem JIT yardımcı sürecini başlatmayı reddediyor (uzantı kaydı ve süreç başlatma ikisi de reddedildi). JIT'yi StikDebug veya SideStore ile etkinleştirin — otomatik geçiş için JIT aracını 'Otomatik' yapın.",
 'vi': "JIT tích hợp không khả dụng trong LiveContainer: hệ thống từ chối khởi chạy tiến trình trợ lý JIT (cả đăng ký tiện ích và thực thi tiến trình đều bị từ chối). Hãy bật JIT qua StikDebug hoặc SideStore — đặt công cụ JIT thành 'Tự động' để tự động chuyển tiếp khi khởi động.",
 'id': "JIT bawaan tidak tersedia di dalam LiveContainer: sistem menolak menjalankan proses pembantu JIT (baik pendaftaran ekstensi maupun eksekusi proses ditolak). Aktifkan JIT melalui StikDebug atau SideStore — atur alat JIT ke 'Otomatis' agar berpindah otomatis saat memulai.",
 'ms': "JIT terbina dalam tidak tersedia dalam LiveContainer: sistem menolak menjalankan proses pembantu JIT (pendaftaran sambungan dan pelaksanaan proses kedua-duanya ditolak). Aktifkan JIT melalui StikDebug atau SideStore — tetapkan alat JIT kepada 'Auto' untuk serahan automatik semasa mula.",
 'th': "ไม่สามารถใช้ JIT ในตัวภายใน LiveContainer ได้: ระบบปฏิเสธการเริ่มกระบวนการช่วย JIT (ทั้งการลงทะเบียนส่วนขยายและการเรียกใช้กระบวนการถูกปฏิเสธ) เปิดใช้ JIT ผ่าน StikDebug หรือ SideStore — ตั้งเครื่องมือ JIT เป็น 'อัตโนมัติ' เพื่อส่งต่ออัตโนมัติเมื่อเริ่มเกม",
 'uk': "Вбудований JIT недоступний у LiveContainer: система відмовляє у запуску допоміжного процесу JIT (відмовлено як у реєстрації розширення, так і у запуску процесу). Увімкніть JIT через StikDebug або SideStore — оберіть «Авто» в інструменті JIT для автоматичного переходу під час запуску.",
 'cs': "Vestavěné JIT není v LiveContainer k dispozici: systém odmítá spustit pomocný proces JIT (registrace rozšíření i spouštění procesů jsou zamítnuty). Povolte JIT přes StikDebug nebo SideStore — nastavte nástroj JIT na «Auto» pro automatický přechod při spuštění.",
 'ar': "JIT المدمج غير متاح داخل LiveContainer: يرفض النظام تشغيل عملية مساعد JIT (يُرفض كل من تسجيل الإضافة وتنفيذ العمليات). فعّل JIT عبر StikDebug أو SideStore — اضبط أداة JIT على «تلقائي» للتحويل التلقائي عند التشغيل.",
 'fa': "JIT داخلی در LiveContainer در دسترس نیست: سیستم از راه‌اندازی فرایند کمکی JIT خودداری می‌کند (هم ثبت افزونه و هم اجرای فرایند رد می‌شود). JIT را از طریق StikDebug یا SideStore فعال کنید — ابزار JIT را روی «خودکار» بگذارید تا هنگام راه‌اندازی به‌طور خودکار منتقل شود.",
 'hi': "LiveContainer के अंदर बिल्ट-इन JIT उपलब्ध नहीं है: सिस्टम JIT हेल्पर प्रोसेस शुरू करने से इनकार करता है (एक्सटेंशन पंजीकरण और प्रोसेस निष्पादन दोनों अस्वीकृत)। StikDebug या SideStore से JIT सक्रिय करें — स्वतः हस्तांतरण के लिए JIT टूल को 'ऑटो' पर सेट करें।",
 'he': "JIT מובנה אינו זמין בתוך LiveContainer: המערכת מסרבת להריץ את תהליך עוזר ה-JIT (גם רישום הרחבה וגם הרצת תהליכים נדחים). הפעל JIT דרך StikDebug או SideStore — הגדר את כלי ה-JIT ל«אוטומטי» למסירה אוטומטית בעת ההפעלה.",
 'hu': "A beépített JIT nem érhető el a LiveContainerban: a rendszer megtagadja a JIT-segédfolyamat indítását (a bővítményregisztráció és a folyamatindítás is elutasított). Kapcsolja be a JIT-t StikDebug vagy SideStore segítségével — állítsa a JIT-eszközt „Automatikus”-ra az automatikus átadáshoz.",
 'fi': "Sisäänrakennettu JIT ei ole käytettävissä LiveContainerissa: järjestelmä kieltää JIT-avuprosessin käynnistyksen (sekä laajennuksen rekisteröinti että prosessien suorittaminen on estetty). Ota JIT käyttöön StikDebug- tai SideStore-sovelluksella — aseta JIT-työkalu arvoon «Automaattinen» automaattista siirtymää varten.",
 'sv': "Inbyggd JIT är inte tillgänglig i LiveContainer: systemet vägrar starta JIT-hjälpprocessen (både tilläggsregistrering och processkörning nekas). Aktivera JIT via StikDebug eller SideStore — ställ in JIT-verktyget på «Automatisk» för automatisk överlämning vid start.",
 'da': "Indbygget JIT er ikke tilgængelig i LiveContainer: systemet nægter at starte JIT-hjælpeprocessen (både udvidelsesregistrering og proceskørsel nægtes). Aktivér JIT via StikDebug eller SideStore — indstil JIT-værktøjet til «Automatisk» for automatisk overdragelse ved start.",
 'no': "Innebygd JIT er ikke tilgjengelig i LiveContainer: systemet nekter å starte JIT-hjelpeprosessen (både utvidelsesregistrering og prosjekjøring nektes). Aktiver JIT via StikDebug eller SideStore — sett JIT-verktøyet til «Automatisk» for automatisk overføring ved oppstart.",
 'el': "Η ενσωματωμένη JIT δεν είναι διαθέσιμη στο LiveContainer: το σύστημα αρνείται την εκκίνηση της βοηθητικής διεργασίας JIT (τότε η καταχώρηση επέκτασης όσο και η εκτέλεση διεργασιών απορρίπτονται). Ενεργοποιήστε τη JIT μέσω StikDebug ή SideStore — ορίστε το εργαλείο JIT σε «Αυτόματο» για αυτόματη μετάβαση κατά την εκκίνηση.",
 'ro': "JIT-ul integrat nu este disponibil în LiveContainer: sistemul refuză lansarea procesului asistent JIT (atât înregistrarea extensiilor, cât și executarea proceselor sunt refuzate). Activați JIT prin StikDebug sau SideStore — setați instrumentul JIT pe «Auto» pentru predare automată la pornire.",
 'bg': "Вграденият JIT не е наличен в LiveContainer: системата отказва стартиране на помощния процес на JIT (отказани са както регистрацията на разширение, така и изпълнението на процеси). Активирайте JIT чрез StikDebug или SideStore — задайте инструмента JIT на «Авто» за автоматично предаване при стартиране.",
 'sk': "Vstavané JIT nie je v LiveContainer k dispozícii: systém odmieta spustiť pomocný proces JIT (registrácia rozšírení aj spúšťanie procesov sú zamietnuté). Povoľte JIT cez StikDebug alebo SideStore — nastavte nástroj JIT na «Auto» pre automatický prechod pri spustení.",
 'hr': "Ugrađeni JIT nije dostupan u LiveContaineru: sustach odbija pokrenuti JIT pomoćni proces (i registracija proširenja i pokretanje procesa odbijeni su). Omogućite JIT putem StikDebug ili SideStore — postavite JIT alat na «Auto» za automatski prijenos pri pokretanju.",
 'sr': "Уграђени JIT није доступан у LiveContainer-у: систем одбија да покрене JIT помоћни процес (и регистрација проширења и покретање процеса су одбијени). Омогућите JIT преко StikDebug или SideStore — поставите JIT алат на «Ауто» за аутоматски пренос при покретању.",
 'bn': "LiveContainer-এর ভিতরে বিল্ট-ইন JIT অনুপলব্ধ: সিস্টেম JIT হেল্পার প্রসেস চালু করতে অস্বীকার করে (এক্সটেনশন নিবন্ধন এবং প্রসেস নিষ্পাদন উভয়ই অস্বীকৃত)। StikDebug বা SideStore দিয়ে JIT সক্রিয় করুন — স্বয়ংক্রিয় হস্তান্তরের জন্য JIT টুল 'অটো'-তে সেট করুন।",
 'ta': "LiveContainer க்குள் உள்ளமைக்கப்பட்ட JIT கிடைக்கவில்லை: கணினி JIT உதவி செயல்முறையைத் தொடங்க மறுக்கிறது (நீட்டிப்பு பதிவு மற்றும் செயல்முறை இயக்கம் இரண்டும் மறுக்கப்படுகிறது). StikDebug அல்லது SideStore மூலம் JIT ஐ இயக்கவும் — தானியங்கு மாற்றத்திற்கு JIT கருவியை 'தானியங்கி' ஆக அமைக்கவும்.",
 'te': "LiveContainer లో బిల్ట్-ఇన్ JIT అందుబాటులో లేదు: సిస్టమ్ JIT హెల్పర్ ప్రాసెస్‌ను ప్రారంభించడానికి నిరాకరిస్తుంది (ఎక్స్‌టెన్షన్ నమోదు మరియు ప్రాసెస్ ఎగ్జిక్యూషన్ రెండూ తిరస్కరించబడ్డాయి). StikDebug లేదా SideStore ద్వారా JIT ప్రారంభించండి — స్వయంచాలక బదిలీ కోసం JIT సాధనాన్ని 'ఆటో'కి సెట్ చేయండి.",
 'sw': "JIT iliyojengwa ndani haipatikani ndani ya LiveContainer: mfumo unakataa kuanzisha mchakato msaidizi wa JIT (usajili wa ugani na utekelezaji wa michakato vyote vimekataliwa). Washa JIT kupitia StikDebug au SideStore — weka zana ya JIT kwa 'Auto' kwa uhamishaji wa kiotomatiki unapozindua.",
 'my': "LiveContainer အတွင်း တပ်ဆင်ထားသော JIT ကို မရနိုင်ပါ: စက်သည် JIT ကူညီသည့် process ကို စတင်ခြင်းကို ငြင်းပယ်သည် (extension မှတ်ပုံတင်ခြင်းနှင့် process လည်ပတ်ခြင်း နှစ်ခုစလုံး ပယ်ခံရသည်)။ StikDebug သို့မဟုတ် SideStore မှတဆင့် JIT ကို ဖွင့်ပါ — စတင်သည့်အခါ အလိုအလျောက် လွှဲပြောင်းရန် JIT tool ကို 'Auto' သို့ ချိန်ညှိပါ။",
 'km': "JIT ដែលបានបង្កប់ពុំអាចប្រើបានក្នុង LiveContainer៖ ប្រព័ន្ធបដិសេធក្នុងការចាប់ផ្តើមដំណើរការជំនួយ JIT (ទាំងការចុះឈ្មោះផ្នែកបន្ថែម និងការប្រតិបត្តិដំណើរការត្រូវបានបដិសេធ)។ បើក JIT តាមរយៈ StikDebug ឬ SideStore — កំណត់ឧបករណ៍ JIT ទៅ «ស្វ័យប្រវត្តិ» សម្រាប់ការផ្ទេរស្វ័យប្រវត្តិពេលចាប់ផ្តើម។",
 'az': "LiveContainer daxilində quraşdırılmış JIT əlçatmazdır: sistem JIT köməkçi prosesini işə salmaqdan imtina edir (həm genişlənmə qeydiyyatı, həm də prosesin icrası rədd edilir). StikDebug və ya SideStore ilə JIT-ni aktivləşdirin — avtomatik keçid üçün JIT alətini «Avtomatik»ə qoyun.",
 'kk': "LiveContainer ішінде құрастырылған JIT қолжетімсіз: жүйе JIT көмекші процесін іске қосудан бас тартады (кеңейту тіркеуі де, процесті орындау да қабылданбайды). StikDebug немесе SideStore арқылы JIT-ті қосыңыз — іске қосу кезінде автоматты ауысу үшін JIT құралын «Авто» етіп орнатыңыз.",
 'uz': "LiveContainer ichida o'rnatilgan JIT mavjud emas: tizim JIT yordamchi jarayonini ishga tushirishni rad etadi (kengaytirishni ro'yxatga olish ham, jarayonni bajarish ham rad etiladi). StikDebug yoki SideStore orqali JIT-ni yoqing — ishga tushirishda avtomatik o'tish uchun JIT vositasini «Avto» qilib qo'ying.",
 'ka': "ჩაშენებული JIT მიუწვდომელია LiveContainer-ში: სისტემა უარს ამბობს JIT-ის დამხმარე პროცესის გაშვებაზე (უარყოფილია როგორც გაფართოების რეგისტრაცია, ისე პროცესის გაშვება). ჩართეთ JIT StikDebug-ის ან SideStore-ის საშუალებით — დააყენეთ JIT ინსტრუმენტი «ავტო»-ზე ავტომატური გადასვლისთვის.",
 'hy': "Ներկառուցված JIT-ը հասանելի չէ LiveContainer-ում՝ համակարգը մերժում է JIT օժանդակ պրոցեսի գործարկումը (մերժված են և' ընդլայնման գրանցումը, և' պրոցեսի կատարումը)։ Միացրեք JIT-ը StikDebug-ի կամ SideStore-ի միջոցով — ավտոմատ անցման համար սահմանեք JIT գործիքը «Ավտո»։",
 'et': "Sisseehitatud JIT pole LiveContaineris saadaval: süsteem keeldub JIT-abiprotsessi käivitamisest (nii laienduse registreerimine kui ka protsesside käivitamine on keelatud). Lubage JIT StikDebug'i või SideStore'i kaudu — seadke JIT-tööriist olekule «Automaatne» automaatseks üleminekuks käivitamisel.",
 'lv': "Iebūvētais JIT nav pieejams LiveContainer: sistēma atsakās palaist JIT palīgprocesu (tiek atteikta gan paplašinājuma reģistrācija, gan procesu izpilde). Iespējojiet JIT caur StikDebug vai SideStore — iestatiet JIT rīku uz «Auto», lai startēšanas laikā automātiski pārietu.",
 'lt': "Integruotas JIT neprieinamas LiveContainer aplinkoje: sistema atsisako paleisti JIT pagalbinį procesą (atmetama ir plėtinių registracija, ir procesų vykdymas). Įjunkite JIT per StikDebug arba SideStore — nustatykite JIT įrankį į «Auto» automatiniam perėjimui paleisties metu.",
 'sl': "Vgrajeni JIT ni na voljo v LiveContainerju: sistem zavrne zagon JIT pomožnega procesa (tako registracija razširitev kot zagon procesov sta zavrnjena). Omogočite JIT prek StikDebug ali SideStore — nastavite orodje JIT na «Samodejno» za samodejni prehod ob zagonu.",
 'sk2': "",  # placeholder (unused)
 'ur': "LiveContainer کے انداز بلٹ-ان JIT دستیاب نہیں: سسٹم JIT ہیلپر پروسیس شروع کرنے سے انکار کرتا ہے (ایکسٹینشن رجسٹریشن اور پروسیس اجرا دونوں مسترد)۔ StikDebug یا SideStore کے ذریعے JIT فعال کریں — خودکار منتقلی کے لیے JIT ٹول کو 'آٹو' پر سیٹ کریں۔",
 'ne': "LiveContainer भित्र बिल्ट-इन JIT उपलब्ध छैन: प्रणालीले JIT हेल्पर प्रोसेस सुरु गर्न अस्वीकार गर्छ (एक्सटेन्सन दर्ता र प्रोसेस कार्यान्वयन दुवै अस्वीकृत)। StikDebug वा SideStore बाट JIT सक्रिय गर्नुहोस् — स्वचालित हस्तान्तरणका लागि JIT उपकरण 'अटो' मा सेट गर्नुहोस्।",
 'si': "LiveContainer තුළ බිල්ට්-ඉන් JIT ලබාගත නොහැක: පද්ධතිය JIT සහායක ක්‍රියාවලිය ආරම්භ කිරීම ප්‍රතික්ෂේප කරයි (දිගු ලියාපදිංචිය සහ ක්‍රියාවලි ක්‍රියාත්මක කිරීම දෙකම ප්‍රතික්ෂේපිතයි). StikDebug හෝ SideStore හරහා JIT සක්‍රීය කරන්න — ස්වයංක්‍රීය මාරුව සඳහා JIT මෙවලම 'ස්වයංක්‍රීය' ලෙස සකසන්න.",
 'lo': "JIT ໃນຕົວບໍ່ສາມາດໃຊ້ໄດ້ໃນ LiveContainer: ລະບົບປະຕິເສດການເລີ່ມຂະບວນການຊ່ວຍ JIT (ທັງການລົງທະບຽນ extension ແລະ ການປະຕິບັດຂະບວນການຖືກປະຕິເສດ)। ເປີດໃຊ້ JIT ຜ່ານ StikDebug ຫຼື SideStore — ຕັ້ງເຄື່ອງມື JIT ເປັນ 'ອັດຕະໂນມັດ' ເພື່ອສົ່ງຕໍ່ອັດຕະໂນມັດເມື່ອເລີ່ມເກມ.",
 'mn': "LiveContainer дотор суурин JIT ашиглах боломжгүй: систем нь JIT туслах процессыг эхлүүлэхээс татгалздаг (өргөтгөлийн бүртгэл болон процесс гүйцэтгэл хоёулаа татгалзагдсан). StikDebug эсвэл SideStore-оос JIT-г идэвхжүүлнэ үү — эхлүүлэх үед автоматаар шилжүүлэхийн тулд JIT хэрэгслийг «Авто» болгоно уу.",
}

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

# alias map for lproj dir name -> dict key
ALIAS = {
 'en-GB': 'en', 'en-PT': 'en', 'en-UD': 'en',
 'zh-Hans': 'zh-Hans', 'zh-Hant': 'zh-Hant', 'zh': 'zh-Hans',
 'nb': 'no', 'nn': 'no', 'in': 'id', 'iw': 'he', 'fil': 'tl', 'tl': 'tl',
 'pt': 'pt-PT', 'sr-Latn': 'sr', 'bs': 'hr', 'me': 'sr',
}

def text_for(lang_dir):
    if lang_dir in T and T[lang_dir]:
        return T[lang_dir]
    if lang_dir in ALIAS and ALIAS[lang_dir] in T and T[ALIAS[lang_dir]]:
        return T[ALIAS[lang_dir]]
    base = lang_dir.split('-')[0]
    if base in T and T[base]:
        return T[base]
    return EN

def main():
    total, added, skipped = 0, 0, 0
    for d in sorted(os.listdir(ROOT)):
        lp = os.path.join(ROOT, d)
        if not d.endswith('.lproj') or not os.path.isdir(lp):
            continue
        strings = os.path.join(lp, 'Localizable.strings')
        if not os.path.isfile(strings):
            continue
        total += 1
        with open(strings, 'r', encoding='utf-8') as f:
            content = f.read()
        if '"%s"' % KEY in content:
            skipped += 1
            continue
        lang = d[:-len('.lproj')]
        line = '"%s" = "%s";\n' % (KEY, esc(text_for(lang)))
        with open(strings, 'a', encoding='utf-8') as f:
            if not content.endswith('\n'):
                f.write('\n')
            f.write(line)
        added += 1
    print('tables=%d added=%d already-present=%d' % (total, added, skipped))

if __name__ == '__main__':
    main()
