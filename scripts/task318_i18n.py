#!/usr/bin/env python3
# Task318: i18n 批处理 —— ame318.* 插件中心 60 键（×54 表）。
#   · 四表硬要求（task250 门）：en / zh-Hans / zh-Hant 全量实译，zh-CN 走 ALIAS；
#   · 其余主语言给到常用键，长尾走 en 兜底（task312 机制同款）。
# 机制与 task312_i18n.py 一致：append-if-missing + ALIAS 回退 + esc() 转义。
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Natives', 'resources')

# key -> (en, {lang: text})；zh-CN 经 ALIAS 取 zh-Hans。
KEYS = {
  "ame318.page.title": ("Plugins", {
    'zh-Hans': "插件", 'zh-Hant': "外掛起動器元件", 'ja': "プラグイン", 'ko': "플러그인",
    'ru': "Плагины", 'de': "Plugins", 'fr': "Plugins", 'es': "Complementos",
    'pt-BR': "Plugins", 'pt-PT': "Plugins", 'it': "Plugin", 'nl': "Plug-ins",
    'pl': "Wtyczki", 'tr': "Eklentiler", 'vi': "Plugin", 'id': "Plugin",
  }),
  "ame318.list.section.installed": ("Installed", {
    'zh-Hans': "已安装", 'zh-Hant': "已安裝", 'ja': "インストール済み", 'ko': "설치됨",
    'ru': "Установлено", 'de': "Installiert", 'fr': "Installés", 'es': "Instalados",
    'pt-BR': "Instalados", 'pt-PT': "Instalados", 'it': "Installati", 'nl': "Geïnstalleerd",
    'pl': "Zainstalowane", 'tr': "Yüklü", 'vi': "Đã cài đặt", 'id': "Terpasang",
  }),
  "ame318.list.repo": ("Plugin Repository", {
    'zh-Hans': "插件仓库", 'zh-Hant': "插件倉庫", 'ja': "プラグインリポジトリ", 'ko': "플러그인 저장소",
    'ru': "Репозиторий плагинов", 'de': "Plugin-Repository", 'fr': "Dépôt de plugins", 'es': "Repositorio de plugins",
    'pt-BR': "Repositório de plugins", 'pt-PT': "Repositório de plugins", 'it': "Repository dei plugin", 'nl': "Pluginrepository",
    'pl': "Repozytorium wtyczek", 'tr': "Eklenti Deposu", 'vi': "Kho plugin", 'id': "Repositori Plugin",
  }),
  "ame318.list.repo_detail": ("Browse bundled plugins", {
    'zh-Hans': "浏览内置插件", 'zh-Hant': "瀏覽內建插件", 'ja': "内蔵プラグインを閲覧", 'ko': "내장 플러그인 탐색",
  }),
  "ame318.list.import": ("Import plugin pack", {
    'zh-Hans': "导入插件包", 'zh-Hant': "匯入插件包", 'ja': "プラグインパッケージを導入", 'ko': "플러그인 패키지 가져오기",
  }),
  "ame318.list.empty": ("No plugins installed yet", {
    'zh-Hans': "尚未安装任何插件", 'zh-Hant': "尚未安裝任何插件", 'ja': "プラグインが未インストールです", 'ko': "설치된 플러그인이 없습니다",
  }),
  "ame318.list.empty_hint": ("Install from the repository or import a .zip pack", {
    'zh-Hans': "从插件仓库一键安装，或导入 .zip 插件包", 'zh-Hant': "從插件倉庫一鍵安裝，或匯入 .zip 插件包",
  }),
  "ame318.list.state.on": ("Running", {
    'zh-Hans': "运行中", 'zh-Hant': "執行中", 'ja': "実行中", 'ko': "실행 중", 'ru': "Работает",
    'de': "Läuft", 'fr': "Actif", 'es': "En ejecución",
  }),
  "ame318.list.state.enabled": ("Enabled", {
    'zh-Hans': "已启用", 'zh-Hant': "已啟用", 'ja': "有効", 'ko': "활성화됨", 'ru': "Включён",
    'de': "Aktiviert", 'fr': "Activé", 'es': "Activado",
  }),
  "ame318.list.state.off": ("Disabled", {
    'zh-Hans': "已停用", 'zh-Hant': "已停用", 'ja': "無効", 'ko': "비활성화됨", 'ru': "Отключён",
    'de': "Deaktiviert", 'fr': "Désactivé", 'es': "Desactivado",
  }),
  "ame318.list.state.error": ("Failed to start", {
    'zh-Hans': "启动失败", 'zh-Hant': "啟動失敗", 'ja': "起動に失敗", 'ko': "시작 실패",
  }),
  "ame318.detail.enabled": ("Enable plugin", {
    'zh-Hans': "启用插件", 'zh-Hant': "啟用插件", 'ja': "プラグインを有効化", 'ko': "플러그인 활성화",
    'ru': "Включить плагин", 'de': "Plugin aktivieren", 'fr': "Activer le plugin", 'es': "Activar plugin",
  }),
  "ame318.detail.state": ("Status", {
    'zh-Hans': "运行状态", 'zh-Hant': "執行狀態", 'ja': "状態", 'ko': "상태", 'ru': "Состояние",
    'de': "Status", 'fr': "État", 'es': "Estado",
  }),
  "ame318.detail.state.running": ("Running", {
    'zh-Hans': "运行中", 'zh-Hant': "執行中", 'ja': "実行中", 'ko': "실행 중",
  }),
  "ame318.detail.state.stopped": ("Stopped", {
    'zh-Hans': "已停止", 'zh-Hant': "已停止", 'ja': "停止中", 'ko': "중지됨",
  }),
  "ame318.detail.state.pending": ("Enabled, starting…", {
    'zh-Hans': "已启用，正在启动…", 'zh-Hant': "已啟用，正在啟動…", 'ja': "有効、起動中…", 'ko': "활성화됨, 시작 중…",
  }),
  "ame318.detail.state.failed_fmt": ("Failed: %@", {
    'zh-Hans': "启动失败：%@", 'zh-Hant': "啟動失敗：%@", 'ja': "起動失敗：%@", 'ko': "시작 실패: %@",
  }),
  "ame318.detail.section.perms": ("Permissions (live)", {
    'zh-Hans': "权限（实时生效）", 'zh-Hant': "權限（即時生效）", 'ja': "権限（リアルタイム適用）", 'ko': "권한(실시간 적용)",
    'ru': "Разрешения (применяются сразу)", 'de': "Berechtigungen (sofort wirksam)",
  }),
  "ame318.detail.section.danger": ("Danger zone", {
    'zh-Hans': "危险区", 'zh-Hant': "危險區", 'ja': "危険な操作", 'ko': "위험 구역",
    'ru': "Опасная зона", 'de': "Gefahrenbereich", 'fr': "Zone de danger", 'es': "Zona de peligro",
  }),
  "ame318.detail.uninstall": ("Uninstall plugin", {
    'zh-Hans': "卸载插件", 'zh-Hant': "解除安裝插件", 'ja': "プラグインを削除", 'ko': "플러그인 제거",
    'ru': "Удалить плагин", 'de': "Plugin deinstallieren", 'fr': "Désinstaller le plugin", 'es': "Desinstalar plugin",
  }),
  "ame318.detail.uninstall.confirm.title": ("Uninstall plugin?", {
    'zh-Hans': "卸载插件？", 'zh-Hant': "解除安裝插件？", 'ja': "プラグインを削除しますか？", 'ko': "플러그인을 제거할까요?",
  }),
  "ame318.detail.uninstall.confirm.msg": ("\"%@\" and all its data and grants will be removed. This cannot be undone.", {
    'zh-Hans': "将删除「%@」及其全部数据与授权记录，不可恢复。", 'zh-Hant': "將刪除「%@」及其全部資料與授權紀錄，不可復原。",
  }),
  "ame318.detail.no_description": ("No description.", {
    'zh-Hans': "暂无简介。", 'zh-Hant': "暫無簡介。", 'ja': "説明はありません。", 'ko': "설명이 없습니다.",
  }),
  "ame318.perm.unknown": ("Unknown permission", {
    'zh-Hans': "未知权限", 'zh-Hant': "未知權限", 'ja': "不明な権限", 'ko': "알 수 없는 권한",
  }),
  "ame318.perm.events": ("Subscribe to launcher events", {
    'zh-Hans': "订阅启动器事件", 'zh-Hant': "訂閱啟動器事件", 'ja': "ランチャーイベントの購読", 'ko': "런처 이벤트 구독",
  }),
  "ame318.perm.events.detail": ("Receive game launch/exit and boot callbacks.", {
    'zh-Hans': "接收游戏启动/退出、启动器启动等事件回调。", 'zh-Hant': "接收遊戲啟動/退出、啟動器啟動等事件回呼。",
  }),
  "ame318.perm.notify": ("Show toast messages", {
    'zh-Hans': "弹出提示横幅", 'zh-Hant': "彈出提示橫幅", 'ja': "トースト表示", 'ko': "토스트 표시",
  }),
  "ame318.perm.notify.detail": ("Allow the plugin to show toast messages.", {
    'zh-Hans': "允许插件显示 toast 提示。", 'zh-Hant': "允許插件顯示 toast 提示。",
  }),
  "ame318.perm.profile.read": ("Read instance config", {
    'zh-Hans': "读取实例配置", 'zh-Hant': "讀取實例設定", 'ja': "インスタンス設定の読み取り", 'ko': "인스턴스 설정 읽기",
  }),
  "ame318.perm.profile.read.detail": ("Read the instance list and profile values.", {
    'zh-Hans': "允许读取实例列表与当前实例配置项。", 'zh-Hant': "允許讀取實例列表與目前實例設定項。",
  }),
  "ame318.perm.profile.write": ("Modify instance config", {
    'zh-Hans': "修改实例配置", 'zh-Hant': "修改實例設定", 'ja': "インスタンス設定の変更", 'ko': "인스턴스 설정 변경",
  }),
  "ame318.perm.profile.write.detail": ("High risk: plugin can rewrite memory / JVM args.", {
    'zh-Hans': "高危：允许插件改写内存、JVM 参数等启动配置。", 'zh-Hant': "高危：允許插件改寫記憶體、JVM 參數等啟動設定。",
  }),
  "ame318.perm.renderer.read": ("Read renderer setting", {
    'zh-Hans': "读取渲染器设置", 'zh-Hant': "讀取渲染器設定", 'ja': "レンダラー設定の読み取り", 'ko': "렌더러 설정 읽기",
  }),
  "ame318.perm.renderer.read.detail": ("Read the current renderer and available options.", {
    'zh-Hans': "允许读取当前渲染器与可用渲染器列表。", 'zh-Hant': "允許讀取目前渲染器與可用渲染器列表。",
  }),
  "ame318.perm.renderer.write": ("Change renderer", {
    'zh-Hans': "修改渲染器", 'zh-Hant': "修改渲染器", 'ja': "レンダラーの変更", 'ko': "렌더러 변경",
  }),
  "ame318.perm.renderer.write.detail": ("High risk: plugin can switch renderers (candidate whitelist only).", {
    'zh-Hans': "高危：允许插件切换渲染器（仅限候选白名单）。", 'zh-Hant': "高危：允許插件切換渲染器（僅限候選白名單）。",
  }),
  "ame318.perm.theme.write": ("Override UI theme", {
    'zh-Hans': "修改界面主题", 'zh-Hant': "修改介面主題", 'ja': "UIテーマの上書き", 'ko': "UI 테마 변경",
  }),
  "ame318.perm.theme.write.detail": ("Allow the plugin to override UI color tokens.", {
    'zh-Hans': "允许插件覆盖界面颜色令牌。", 'zh-Hant': "允許插件覆蓋介面顏色令牌。",
  }),
  "ame318.perm.files.plugin": ("Plugin-private storage", {
    'zh-Hans': "插件私有目录读写", 'zh-Hant': "插件私有目錄讀寫", 'ja': "プラグイン専用ストレージ", 'ko': "플러그인 전용 저장소",
  }),
  "ame318.perm.files.plugin.detail": ("Read/write the plugin's own data folder only.", {
    'zh-Hans': "仅允许插件读写自己的数据目录。", 'zh-Hant': "僅允許插件讀寫自己的資料目錄。",
  }),
  "ame318.repo.title": ("Plugin Repository", {
    'zh-Hans': "插件仓库", 'zh-Hant': "插件倉庫", 'ja': "プラグインリポジトリ", 'ko': "플러그인 저장소",
  }),
  "ame318.repo.empty": ("Repository is empty", {
    'zh-Hans': "仓库为空", 'zh-Hant': "倉庫為空", 'ja': "リポジトリは空です", 'ko': "저장소가 비어 있습니다",
  }),
  "ame318.repo.unnamed": ("Unnamed plugin", {
    'zh-Hans': "未命名插件", 'zh-Hant': "未命名插件", 'ja': "名称未プラグイン", 'ko': "이름 없는 플러그인",
  }),
  "ame318.repo.no_perms": ("no special permissions", {
    'zh-Hans': "无特殊权限", 'zh-Hant': "無特殊權限", 'ja': "特別な権限なし", 'ko': "특별한 권한 없음",
  }),
  "ame318.repo.confirm.title": ("Install plugin?", {
    'zh-Hans': "安装插件？", 'zh-Hant': "安裝插件？", 'ja': "プラグインをインストールしますか？", 'ko': "플러그인을 설치할까요?",
  }),
  "ame318.repo.confirm.msg": ("\"%@\" requires: %@. You can adjust grants anytime in plugin details.", {
    'zh-Hans': "「%@」要求以下权限：%@。安装后可在插件详情中随时调整。",
    'zh-Hant': "「%@」要求以下權限：%@。安裝後可在插件詳情中隨時調整。",
  }),
  "ame318.repo.install": ("Install", {
    'zh-Hans': "安装", 'zh-Hant': "安裝", 'ja': "インストール", 'ko': "설치", 'ru': "Установить",
    'de': "Installieren", 'fr': "Installer", 'es': "Instalar",
  }),
  "ame318.repo.reinstall": ("Reinstall", {
    'zh-Hans': "重新安装", 'zh-Hant': "重新安裝", 'ja': "再インストール", 'ko': "재설치",
  }),
  "ame318.toast.installed": ("Installed \"%@\"", {
    'zh-Hans': "已安装「%@」", 'zh-Hant': "已安裝「%@」",
  }),
  "ame318.toast.install_failed": ("Install failed: %@", {
    'zh-Hans': "安装失败：%@", 'zh-Hant': "安裝失敗：%@",
  }),
  "ame318.toast.uninstalled": ("Uninstalled \"%@\"", {
    'zh-Hans': "已卸载「%@」", 'zh-Hant': "已解除安裝「%@」",
  }),
  "ame318.error.manifest_incomplete": ("Invalid manifest (missing id/name/version).", {
    'zh-Hans': "清单无效（缺少 id/name/version）。", 'zh-Hant': "清單無效（缺少 id/name/version）。",
  }),
  "ame318.error.bad_id": ("Invalid plugin id (allowed: letters, digits, dot, dash, underscore).", {
    'zh-Hans': "插件 id 不合法（仅字母/数字/点/横线/下划线）。", 'zh-Hant': "插件 id 不合法（僅字母/數字/點/橫線/底線）。",
  }),
  "ame318.error.unknown_perm": ("Unknown permission '%@' in manifest.", {
    'zh-Hans': "清单含未知权限「%@」，拒绝安装。", 'zh-Hant': "清單含未知權限「%@」，拒絕安裝。",
  }),
  "ame318.error.zip_unreadable": ("Cannot read plugin pack (.zip).", {
    'zh-Hans': "无法读取插件包（.zip）。", 'zh-Hant': "無法讀取插件包（.zip）。",
  }),
  "ame318.error.pack_too_large": ("Pack exceeds size or entry limits.", {
    'zh-Hans': "插件包超出大小或条目数上限。", 'zh-Hant': "插件包超出大小或條目數上限。",
  }),
  "ame318.error.unsafe_path": ("Pack contains unsafe paths.", {
    'zh-Hans': "插件包含不安全路径，拒绝安装。", 'zh-Hant': "插件包含不安全路徑，拒絕安裝。",
  }),
  "ame318.error.no_manifest": ("manifest.json not found in pack root.", {
    'zh-Hans': "包内未找到 manifest.json。", 'zh-Hant': "包內未找到 manifest.json。",
  }),
  "ame318.error.entry_missing": ("Entry file %@ not found in pack.", {
    'zh-Hans': "包内未找到入口文件 %@。", 'zh-Hant': "包內未找到入口檔案 %@。",
  }),
  "ame318.error.extract_failed": ("Extraction failed.", {
    'zh-Hans': "解包失败。", 'zh-Hant': "解包失敗。",
  }),
  "ame318.error.replace_failed": ("Existing plugin is busy; reinstall failed.", {
    'zh-Hans': "旧插件目录占用，覆盖失败。", 'zh-Hant': "舊插件目錄佔用，覆蓋失敗。",
  }),
  "ame318.error.entry_unreadable": ("Cannot read entry %@.", {
    'zh-Hans': "入口文件 %@ 读取失败。", 'zh-Hant': "入口檔案 %@ 讀取失敗。",
  }),
  "home.tile.ai": ("AI Assistant", {
    'zh-Hans': "AI 助手", 'zh-Hant': "AI 助手", 'ja': "AI アシスタント", 'ko': "AI 어시스턴트",
    'ru': "ИИ-ассистент", 'de': "KI-Assistent", 'fr': "Assistant IA", 'es': "Asistente IA",
  }),
  "preference.detail.plugins": ("Manage plugins, permissions and the plugin repository", {
    'zh-Hans': "管理插件、权限与插件仓库", 'zh-Hant': "管理插件、權限與插件倉庫",
    'ja': "プラグイン・権限・リポジトリを管理", 'ko': "플러그인, 권한, 저장소 관리",
  }),
}

ALIAS = {
 'en-GB': 'en', 'en-PT': 'en', 'en-UD': 'en', 'lol': 'en',
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
    print("task318: tables=%d added=%d keys=%d" % (total_tables, added_total, len(KEYS)))
    if total_tables == 0:
        raise SystemExit("ERROR: no strings tables found")

if __name__ == '__main__':
    main()
