#!/usr/bin/env python3
# Task303: register "ame303.copy_failed" + "ame303.manifest_missing" into all
# Localizable.strings tables. Pattern follows task302_i18n_lc.py: real
# translations for major languages, English fallback for the rest.
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

KEYS = [
    "ame303.copy_failed",
    "ame303.manifest_missing",
]

EN = {
    "ame303.copy_failed":
        "Could not write the version file for renamed instance \"%@\": copying "
        "the local copy failed. Free up storage space and try again.",
    "ame303.manifest_missing":
        "Could not resolve version \"%@\": the remote version manifest is not "
        "loaded yet and no local copy exists to duplicate from. Check your "
        "network connection and try again.",
}

T = {
 "ame303.copy_failed": {
  'zh-Hans': "无法为重命名实例“%@”写入版本文件：复制本地副本失败。请清理存储空间后重试。",
  'zh-Hant': "無法為重新命名實例「%@」寫入版本檔案：複製本機副本失敗。請清理儲存空間後重試。",
  'ja': "名前を変更したインスタンス「%@」のバージョンファイルを書き込めませんでした：ローカルコピーの複製に失敗しました。ストレージを空けてから再試行してください。",
  'ko': "이름을 바꾼 인스턴스 \"%@\"의 버전 파일을 쓸 수 없습니다: 로컬 사본 복제에 실패했습니다. 저장 공간을 확보한 후 다시 시도하세요.",
  'ru': "Не удалось записать файл версии для переименованного экземпляра «%@»: не удалось скопировать локальную копию. Освободите место и повторите попытку.",
  'de': "Versionsdatei für umbenannte Instanz „%@“ konnte nicht geschrieben werden: Kopieren der lokalen Kopie fehlgeschlagen. Speicherplatz freigeben und erneut versuchen.",
  'fr': "Impossible d’écrire le fichier de version pour l’instance renommée « %@ » : échec de la copie locale. Libérez de l’espace et réessayez.",
  'es': "No se pudo escribir el archivo de versión de la instancia renombrada «%@»: falló la copia local. Libera espacio e inténtalo de nuevo.",
  'it': "Impossibile scrivere il file di versione per l’istanza rinominata «%@»: copia della copia locale non riuscita. Libera spazio e riprova.",
  'pt-BR': "Não foi possível gravar o arquivo de versão da instância renomeada \"%@\": falha ao copiar a cópia local. Libere espaço e tente novamente.",
  'pt-PT': "Não foi possível gravar o ficheiro de versão da instância renomeada \"%@\": falha ao copiar a cópia local. Libere espaço e tente novamente.",
  'vi': "Không thể ghi tệp phiên bản cho thực thể đã đổi tên \"%@\": sao chép bản sao cục bộ thất bại. Hãy giải phóng dung lượng rồi thử lại.",
  'id': "Tidak dapat menulis file versi untuk instance yang diganti nama \"%@\": penyalinan salinan lokal gagal. Bersihkan ruang penyimpanan lalu coba lagi.",
  'th': "ไม่สามารถเขียนไฟล์เวอร์ชันสำหรับอินสแตนซ์ที่เปลี่ยนชื่อ \"%@\" ได้: การคัดลอกสำเนาในเครื่องล้มเหลว โปรดเคลียร์พื้นที่จัดเก็บแล้วลองอีกครั้ง",
  'ar': "تعذر كتابة ملف الإصدار للمثال المُعاد تسميته \"%@\": فشل نسخ النسخة المحلية. حرّر مساحة التخزين وحاول مرة أخرى.",
  'uk': "Не вдалося записати файл версії для перейменованого екземпляра «%@»: не вдалося скопіювати локальну копію. Звільніть місце та спробуйте ще раз.",
  'tr': "Yeniden adlandırılan örnek \"%@\" için sürüm dosyası yazılamadı: yerel kopya çoğaltılamadı. Depolama alanını boşaltıp tekrar deneyin.",
  'pl': "Nie można zapisać pliku wersji dla zmienionej nazwy instancji „%@”: kopiowanie kopii lokalnej nie powiodło się. Zwolnij miejsce i spróbuj ponownie.",
  'nl': "Kan versiebestand voor hernoemde instantie \"%@\" niet schrijven: kopiëren van lokale kopie mislukt. Maak opslagruimte vrij en probeer opnieuw.",
 },
 "ame303.manifest_missing": {
  'zh-Hans': "无法解析版本“%@”：远端版本清单尚未加载，且本地没有可复制的版本文件。请检查网络连接后重试。",
  'zh-Hant': "無法解析版本「%@」：遠端版本清單尚未載入，且本機沒有可複製的版本檔案。請檢查網路連線後重試。",
  'ja': "バージョン「%@」を解決できませんでした：リモートのバージョンマニフェストがまだ読み込まれておらず、複製元のローカルファイルもありません。ネットワーク接続を確認して再試行してください。",
  'ko': "버전 \"%@\"을(를) 확인할 수 없습니다: 원격 버전 매니페스트가 아직 로드되지 않았고 복제할 로컬 파일도 없습니다. 네트워크 연결을 확인한 후 다시 시도하세요.",
  'ru': "Не удалось разрешить версию «%@»: удалённый манифест версий ещё не загружен, а локальной копии для дублирования нет. Проверьте сетевое подключение и повторите попытку.",
  'de': "Version „%@“ konnte nicht aufgelöst werden: Das remote Versionsmanifest ist noch nicht geladen und es existiert keine lokale Kopie zum Duplizieren. Netzwerkverbindung prüfen und erneut versuchen.",
  'fr': "Impossible de résoudre la version « %@ » : le manifeste de versions distant n’est pas encore chargé et aucune copie locale n’existe pour la duplication. Vérifiez la connexion réseau et réessayez.",
  'es': "No se pudo resolver la versión «%@»: el manifiesto remoto de versiones aún no está cargado y no existe una copia local de la que duplicar. Comprueba la conexión e inténtalo de nuevo.",
  'it': "Impossibile risolvere la versione «%@»: il manifesto remoto delle versioni non è ancora caricato e non esiste una copia locale da duplicare. Verifica la connessione e riprova.",
  'pt-BR': "Não foi possível resolver a versão \"%@\": o manifesto remoto de versões ainda não foi carregado e não há cópia local para duplicar. Verifique a conexão e tente novamente.",
  'pt-PT': "Não foi possível resolver a versão \"%@\": o manifesto remoto de versões ainda não foi carregado e não há cópia local para duplicar. Verifique a ligação e tente novamente.",
  'vi': "Không thể phân giải phiên bản \"%@\": danh mục phiên bản từ xa chưa được tải và không có bản sao cục bộ để nhân bản. Kiểm tra kết nối mạng rồi thử lại.",
  'id': "Tidak dapat menyelesaikan versi \"%@\": manifest versi jarak jauh belum dimuat dan tidak ada salinan lokal untuk diduplikasi. Periksa koneksi jaringan lalu coba lagi.",
  'th': "แก้ไขเวอร์ชัน \"%@\" ไม่สำเร็จ: ยังไม่ได้โหลดรายการเวอร์ชันจากระยะไกล และไม่มีไฟล์ในเครื่องสำหรับคัดลอก โปรดตรวจสอบการเชื่อมต่อเครือข่ายแล้วลองอีกครั้ง",
  'ar': "تعذر تحديد الإصدار \"%@\": لم يتم تحميل قائمة الإصدارات البعيدة بعد، ولا توجد نسخة محلية للنسخ منها. تحقق من اتصال الشبكة وحاول مرة أخرى.",
  'uk': "Не вдалося розв'язати версію «%@»: віддалений маніфест версій ще не завантажено, а локальної копії для дублювання немає. Перевірте мережу та спробуйте ще раз.",
  'tr': "\"%@\" sürümü çözümlenemedi: uzak sürüm manifestosu henüz yüklenmedi ve çoğaltılacak yerel kopya yok. Ağ bağlantısını kontrol edip tekrar deneyin.",
  'pl': "Nie można rozpoznać wersji „%@”: zdalny manifest wersji nie został jeszcze wczytany, a nie ma lokalnej kopii do zduplikowania. Sprawdź połączenie sieciowe i spróbuj ponownie.",
  'nl': "Kan versie \"%@\" niet herleiden: het externe versiemanifest is nog niet geladen en er is geen lokale kopie om te dupliceren. Controleer de netwerkverbinding en probeer opnieuw.",
 },
}

ALIAS = {
 'en-GB': 'en', 'en-PT': 'en', 'en-UD': 'en',
 'zh-Hans': 'zh-Hans', 'zh-Hant': 'zh-Hant', 'zh': 'zh-Hans',
 'nb': 'no', 'nn': 'no', 'in': 'id', 'iw': 'he', 'fil': 'tl', 'tl': 'tl',
 'pt': 'pt-PT', 'sr-Latn': 'sr', 'bs': 'hr', 'me': 'sr',
}

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def text_for(key, lang):
    table = T[key]
    if lang in table:
        return table[lang]
    if lang in ALIAS and ALIAS[lang] in table:
        return table[ALIAS[lang]]
    base = lang.split('-')[0]
    if base in table:
        return table[base]
    return EN[key]

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
        need = [k for k in KEYS if '"%s"' % k not in content]
        if not need:
            skipped += 1
            continue
        lang = d[:-len('.lproj')]
        lines = ''.join('"%s" = "%s";\n' % (k, esc(text_for(k, lang))) for k in need)
        with open(strings, 'a', encoding='utf-8') as f:
            if content and not content.endswith('\n'):
                f.write('\n')
            f.write(lines)
        added += 1
    print('tables=%d added=%d already-present=%d' % (total, added, skipped))

if __name__ == '__main__':
    main()
