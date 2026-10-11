import SwiftUI

/// Playdock's own small localization layer. This is a SwiftPM executable built with Command Line
/// Tools only (no Xcode project), and `Package.swift` deliberately `exclude`s the `Resources`
/// folder from the target - so the usual `.lproj`/`String(localized:)` bundle machinery isn't
/// wired up and can't be relied on here. Instead every user-facing string is looked up by its
/// English source text as the key, against an in-memory table per language, falling back to the
/// key itself (i.e. English) for anything not yet translated. That means a partially-translated
/// language still renders - it just shows English for the gaps - rather than showing raw keys.
///
/// Call sites use the free `L(_:)` function: `Text(L("Settings"))`. A view that needs to re-render
/// when the language changes reads `@AppStorage(AppLanguage.storageKey)` the same way views
/// already read `PlaydockSkin.storageKey` for the active skin - `L(_:)` itself just reads
/// `UserDefaults` directly, so the `@AppStorage` is purely the redraw trigger.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case french = "fr"
    case spanish = "es"
    case german = "de"
    case japanese = "ja"
    case portuguese = "pt"

    var id: String { rawValue }

    static let storageKey = "com.exedock.language"

    /// Each language's name written in that language itself (an endonym), the convention every
    /// real app's language picker follows - "Deutsch", not "German".
    var endonym: String {
        switch self {
        case .system: return L("System")
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        case .french: return "Français"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .japanese: return "日本語"
        case .portuguese: return "Português"
        }
    }

    /// The English name, shown as a subtitle under the endonym so someone who can't yet read the
    /// endonym can still find their language.
    var englishName: String {
        switch self {
        case .system: return L("Match your Mac")
        case .english: return "English"
        case .chineseSimplified: return "Chinese (Simplified)"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .japanese: return "Japanese"
        case .portuguese: return "Portuguese"
        }
    }
}

/// Look up `key` (its own English text) in the active language's table. Falls back to English,
/// then to the key itself, so nothing ever renders blank or as a raw identifier.
func L(_ key: String) -> String {
    Localization.string(key)
}

/// `L(_:)` with `String(format:)` applied - `LF("Version %@", "1.2.0")`.
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.string(key), arguments: arguments)
}

enum Localization {
    /// What the user picked, verbatim - `.system` included.
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "") ?? .system
    }

    /// The language actually used to render, resolving `.system` against the Mac's own preferred
    /// languages - the first one Playdock has a table for, else English.
    static var active: AppLanguage {
        let picked = selected
        guard picked == .system else { return picked }
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh-hans") || lower == "zh" || lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") {
                return .chineseSimplified
            }
            if let match = AppLanguage.allCases.first(where: { candidate in
                guard candidate != .system else { return false }
                return lower == candidate.rawValue.lowercased() || lower.hasPrefix(candidate.rawValue.lowercased() + "-")
            }) {
                return match
            }
        }
        return .english
    }

    static func string(_ key: String) -> String {
        let language = active
        if language == .english { return key }
        return tables[language]?[key] ?? key
    }

    /// Picks the singular or plural key by `count`, then substitutes it - keeps plural handling
    /// out of call sites without pulling in a full ICU plural engine (none of the shipping
    /// languages here need more than a two-form singular/plural split for the one place this is
    /// used, the game count).
    static func plural(_ count: Int, singular: String, plural pluralKey: String) -> String {
        String(format: string(count == 1 ? singular : pluralKey), count)
    }

    // MARK: - Tables

    /// English is the key set itself - every other table only needs the keys it actually
    /// translates; anything missing falls through to English automatically. Populated one
    /// language at a time as each table is added below.
    private static let tables: [AppLanguage: [String: String]] = [
        .chineseSimplified: chineseSimplified,
        .french: french,
        .spanish: spanish,
    ]

    private static let chineseSimplified: [String: String] = [
        "System": "系统",
        "Match your Mac": "跟随系统",
        "Settings": "设置",
        "Done": "完成",
        "Close": "关闭",
        "Cancel": "取消",
        "Refresh": "刷新",
        "Add Game": "添加游戏",
        "Sort": "排序",
        "Name": "名称",
        "Recently Updated": "最近更新",
        "Search your games": "搜索游戏",
        "No games installed": "未安装游戏",
        "%lld game": "%lld 个游戏",
        "%lld games": "%lld 个游戏",
        "General": "通用",
        "Appearance": "外观",
        "Personalization": "个性化",
        "Library": "游戏库",
        "Games & Data": "游戏与数据",
        "Language": "语言",
        "Diagnostics": "诊断",
        "About": "关于",
        "Advanced Mode": "高级模式",
        "Adds a settings button to each game so you can fine-tune its engine and graphics settings individually. Most people never need this.": "为每个游戏添加设置按钮，便于单独调整其引擎和图形设置。大多数人无需使用。",
        "Show Floating Steam Icon": "显示悬浮 Steam 图标",
        "The double-click-to-open-Steam icon in the corner of the grid. Turn off to collapse it to a small tab on the edge (still there, just out of the way).": "网格角落中双击打开 Steam 的图标。关闭后会收拢为边缘的小标签（仍然可用，只是不碍事）。",
        "Preview With Sample Games": "使用示例游戏预览",
        "Adds well-known games (real art and ratings, nothing installed) so you can see how the grid looks. Turn off to remove them.": "添加一些知名游戏（真实封面和评分，并未实际安装），以便查看网格效果。关闭即可移除。",
        "UI Size": "界面大小",
        "Look": "风格",
        "Layout": "布局",
        "Card Art": "卡片封面",
        "Banner": "横幅",
        "Box Art": "竖版封面",
        "Follows your Mac's light or dark appearance automatically.": "自动跟随系统的浅色或深色外观。",
        "Run Setup Wizard Again": "重新运行设置向导",
        "Every control here is drawn in the look you pick, so this screen is a live preview of it.": "此处的每个控件都会以所选风格绘制，因此本页即为其实时预览。",
        "Default Sort": "默认排序",
        "Opening Screen": "启动页面",
        "Steam": "Steam",
        "C: Drive": "C: 盘",
        "Which screen Playdock opens to.": "Playdock 启动时打开的页面。",
        "Hard Refresh Game Info": "强制刷新游戏信息",
        "Re-downloads every game's art, description, and details from Steam. Use this if a game shows the wrong or missing art.": "从 Steam 重新下载每个游戏的封面、简介和详情。若游戏封面错误或缺失，请使用此功能。",
        "Refreshing…": "正在刷新…",
        "Refresh complete.": "刷新完成。",
        "Last refreshed %@": "上次刷新：%@",
        "Never refreshed": "从未刷新",
        "Check for Engine Updates": "检查引擎更新",
        "Checking…": "正在检查…",
        "Downloading…": "正在下载…",
        "Download Update": "下载更新",
        "Engine": "引擎",
        "Graphics": "图形",
        "Sync": "同步",
        "Wine engine": "Wine 引擎",
        "These are the same engines already downloaded by Sikarugir Creator.": "这些引擎与 Sikarugir Creator 已下载的引擎相同。",
        "Fast Sync (ESYNC + MSYNC)": "快速同步（ESYNC + MSYNC）",
        "Playdock's Wine engine comes from Sikarugir's public releases. Checking never downloads anything by itself.": "Playdock 的 Wine 引擎来自 Sikarugir 的公开发布。检查本身不会下载任何内容。",
        "Open Logs Folder": "打开日志文件夹",
        "Open Crash Reports": "打开崩溃报告",
        "Every launch writes its own log here, plus a record of background checks. If something's not working, look here first.": "每次启动都会在此写入日志，以及后台检查记录。如遇问题，请先查看此处。",
        "Choose the language Playdock's interface uses.": "选择 Playdock 界面使用的语言。",
        "Changes apply immediately.": "更改立即生效。",
        "Some text may stay in English until its translation is finished.": "部分文本在翻译完成前可能仍显示英文。",
        "Version %@": "版本 %@",
        "Built on the Sikarugir engine.": "基于 Sikarugir 引擎构建。",
        "Contact": "联系方式",
        "A Mac dashboard for the Windows games you run through Wine.": "用于管理通过 Wine 运行的 Windows 游戏的 Mac 面板。",
    ]

    private static let french: [String: String] = [
        "System": "Système",
        "Match your Mac": "Suivre le Mac",
        "Settings": "Réglages",
        "Done": "Terminé",
        "Close": "Fermer",
        "Cancel": "Annuler",
        "Refresh": "Actualiser",
        "Add Game": "Ajouter un jeu",
        "Sort": "Trier",
        "Name": "Nom",
        "Recently Updated": "Récemment mis à jour",
        "Search your games": "Rechercher un jeu",
        "No games installed": "Aucun jeu installé",
        "%lld game": "%lld jeu",
        "%lld games": "%lld jeux",
        "General": "Général",
        "Appearance": "Apparence",
        "Personalization": "Personnalisation",
        "Library": "Bibliothèque",
        "Games & Data": "Jeux et données",
        "Language": "Langue",
        "Diagnostics": "Diagnostics",
        "About": "À propos",
        "Advanced Mode": "Mode avancé",
        "Adds a settings button to each game so you can fine-tune its engine and graphics settings individually. Most people never need this.": "Ajoute un bouton de réglages à chaque jeu pour ajuster individuellement son moteur et ses options graphiques. La plupart des gens n'en ont pas besoin.",
        "Show Floating Steam Icon": "Afficher l'icône Steam flottante",
        "The double-click-to-open-Steam icon in the corner of the grid. Turn off to collapse it to a small tab on the edge (still there, just out of the way).": "L'icône dans le coin de la grille qui ouvre Steam d'un double-clic. Désactivez-la pour la réduire à un petit onglet sur le bord (toujours là, mais discret).",
        "Preview With Sample Games": "Aperçu avec des jeux d'exemple",
        "Adds well-known games (real art and ratings, nothing installed) so you can see how the grid looks. Turn off to remove them.": "Ajoute des jeux connus (vraies jaquettes et notes, rien d'installé) pour voir le rendu de la grille. Désactivez pour les retirer.",
        "UI Size": "Taille de l'interface",
        "Look": "Style",
        "Layout": "Disposition",
        "Card Art": "Illustration des cartes",
        "Banner": "Bannière",
        "Box Art": "Jaquette",
        "Follows your Mac's light or dark appearance automatically.": "Suit automatiquement l'apparence claire ou sombre de votre Mac.",
        "Run Setup Wizard Again": "Relancer l'assistant de configuration",
        "Every control here is drawn in the look you pick, so this screen is a live preview of it.": "Chaque contrôle ici est dessiné dans le style choisi : cet écran en est donc un aperçu en direct.",
        "Default Sort": "Tri par défaut",
        "Opening Screen": "Écran d'ouverture",
        "Steam": "Steam",
        "C: Drive": "Disque C:",
        "Which screen Playdock opens to.": "L'écran sur lequel Playdock s'ouvre.",
        "Hard Refresh Game Info": "Forcer l'actualisation des infos",
        "Re-downloads every game's art, description, and details from Steam. Use this if a game shows the wrong or missing art.": "Retélécharge depuis Steam la jaquette, la description et les détails de chaque jeu. À utiliser si une jaquette est absente ou erronée.",
        "Refreshing…": "Actualisation…",
        "Refresh complete.": "Actualisation terminée.",
        "Last refreshed %@": "Dernière actualisation : %@",
        "Never refreshed": "Jamais actualisé",
        "Check for Engine Updates": "Rechercher des mises à jour du moteur",
        "Checking…": "Vérification…",
        "Downloading…": "Téléchargement…",
        "Download Update": "Télécharger la mise à jour",
        "Engine": "Moteur",
        "Graphics": "Graphismes",
        "Sync": "Synchronisation",
        "Wine engine": "Moteur Wine",
        "These are the same engines already downloaded by Sikarugir Creator.": "Ce sont les mêmes moteurs que ceux déjà téléchargés par Sikarugir Creator.",
        "Fast Sync (ESYNC + MSYNC)": "Synchro rapide (ESYNC + MSYNC)",
        "Playdock's Wine engine comes from Sikarugir's public releases. Checking never downloads anything by itself.": "Le moteur Wine de Playdock provient des versions publiques de Sikarugir. La vérification ne télécharge rien par elle-même.",
        "Open Logs Folder": "Ouvrir le dossier des journaux",
        "Open Crash Reports": "Ouvrir les rapports de plantage",
        "Every launch writes its own log here, plus a record of background checks. If something's not working, look here first.": "Chaque lancement écrit son journal ici, ainsi qu'un relevé des vérifications en arrière-plan. En cas de problème, commencez par là.",
        "Choose the language Playdock's interface uses.": "Choisissez la langue de l'interface de Playdock.",
        "Changes apply immediately.": "Les changements s'appliquent immédiatement.",
        "Some text may stay in English until its translation is finished.": "Certains textes peuvent rester en anglais tant que leur traduction n'est pas terminée.",
        "Version %@": "Version %@",
        "Built on the Sikarugir engine.": "Basé sur le moteur Sikarugir.",
        "Contact": "Contact",
        "A Mac dashboard for the Windows games you run through Wine.": "Un tableau de bord Mac pour les jeux Windows lancés via Wine.",
    ]

    private static let spanish: [String: String] = [
        "System": "Sistema",
        "Match your Mac": "Seguir al Mac",
        "Settings": "Ajustes",
        "Done": "Listo",
        "Close": "Cerrar",
        "Cancel": "Cancelar",
        "Refresh": "Actualizar",
        "Add Game": "Añadir juego",
        "Sort": "Ordenar",
        "Name": "Nombre",
        "Recently Updated": "Actualizados recientemente",
        "Search your games": "Busca tus juegos",
        "No games installed": "No hay juegos instalados",
        "%lld game": "%lld juego",
        "%lld games": "%lld juegos",
        "General": "General",
        "Appearance": "Apariencia",
        "Personalization": "Personalización",
        "Library": "Biblioteca",
        "Games & Data": "Juegos y datos",
        "Language": "Idioma",
        "Diagnostics": "Diagnóstico",
        "About": "Acerca de",
        "Advanced Mode": "Modo avanzado",
        "Adds a settings button to each game so you can fine-tune its engine and graphics settings individually. Most people never need this.": "Añade un botón de ajustes a cada juego para afinar su motor y sus opciones gráficas por separado. La mayoría de la gente no lo necesita.",
        "Show Floating Steam Icon": "Mostrar icono flotante de Steam",
        "The double-click-to-open-Steam icon in the corner of the grid. Turn off to collapse it to a small tab on the edge (still there, just out of the way).": "El icono de la esquina de la cuadrícula que abre Steam con doble clic. Desactívalo para reducirlo a una pestaña pequeña en el borde (sigue ahí, pero sin molestar).",
        "Preview With Sample Games": "Vista previa con juegos de ejemplo",
        "Adds well-known games (real art and ratings, nothing installed) so you can see how the grid looks. Turn off to remove them.": "Añade juegos conocidos (carátulas y valoraciones reales, nada instalado) para ver cómo queda la cuadrícula. Desactívalo para quitarlos.",
        "UI Size": "Tamaño de la interfaz",
        "Look": "Estilo",
        "Layout": "Distribución",
        "Card Art": "Arte de las tarjetas",
        "Banner": "Banner",
        "Box Art": "Carátula",
        "Follows your Mac's light or dark appearance automatically.": "Sigue automáticamente el aspecto claro u oscuro de tu Mac.",
        "Run Setup Wizard Again": "Volver a ejecutar el asistente",
        "Every control here is drawn in the look you pick, so this screen is a live preview of it.": "Cada control aquí se dibuja con el estilo que elijas, así que esta pantalla es una vista previa en vivo.",
        "Default Sort": "Orden predeterminado",
        "Opening Screen": "Pantalla de inicio",
        "Steam": "Steam",
        "C: Drive": "Disco C:",
        "Which screen Playdock opens to.": "La pantalla con la que se abre Playdock.",
        "Hard Refresh Game Info": "Recargar la información de los juegos",
        "Re-downloads every game's art, description, and details from Steam. Use this if a game shows the wrong or missing art.": "Vuelve a descargar de Steam la carátula, la descripción y los detalles de cada juego. Úsalo si un juego muestra una imagen incorrecta o no la muestra.",
        "Refreshing…": "Actualizando…",
        "Refresh complete.": "Actualización completada.",
        "Last refreshed %@": "Última actualización: %@",
        "Never refreshed": "Sin actualizar nunca",
        "Check for Engine Updates": "Buscar actualizaciones del motor",
        "Checking…": "Comprobando…",
        "Downloading…": "Descargando…",
        "Download Update": "Descargar actualización",
        "Engine": "Motor",
        "Graphics": "Gráficos",
        "Sync": "Sincronización",
        "Wine engine": "Motor Wine",
        "These are the same engines already downloaded by Sikarugir Creator.": "Son los mismos motores que ya descargó Sikarugir Creator.",
        "Fast Sync (ESYNC + MSYNC)": "Sincronización rápida (ESYNC + MSYNC)",
        "Playdock's Wine engine comes from Sikarugir's public releases. Checking never downloads anything by itself.": "El motor Wine de Playdock proviene de las versiones públicas de Sikarugir. Comprobar no descarga nada por sí solo.",
        "Open Logs Folder": "Abrir la carpeta de registros",
        "Open Crash Reports": "Abrir los informes de fallos",
        "Every launch writes its own log here, plus a record of background checks. If something's not working, look here first.": "Cada arranque escribe su propio registro aquí, junto con un historial de comprobaciones en segundo plano. Si algo falla, mira aquí primero.",
        "Choose the language Playdock's interface uses.": "Elige el idioma que usa la interfaz de Playdock.",
        "Changes apply immediately.": "Los cambios se aplican de inmediato.",
        "Some text may stay in English until its translation is finished.": "Puede que algún texto siga en inglés hasta que se termine su traducción.",
        "Version %@": "Versión %@",
        "Built on the Sikarugir engine.": "Basado en el motor Sikarugir.",
        "Contact": "Contacto",
        "A Mac dashboard for the Windows games you run through Wine.": "Un panel de Mac para los juegos de Windows que ejecutas con Wine.",
    ]
}
