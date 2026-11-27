import AppKit
import AgentsModule
import HUDModule
import MediaModule
import ShelfModule
import TodayModule
import VafaModule   // --- catalog ---
import MenuBarModule   // --- menubar ---
#if SIMPLEISLAND_MEETINGS
import MeetingsModule   // --- meetings ---
#endif

// Точка входа. Порядок: хук агентов (без GUI) → самотесты модулей и ядра → `--snapshot <каталог>` (режим снимков,
// без окна и доступа к экрану) → обычный запуск.
let arguments = CommandLine.arguments

// Самотесты и снимки — процесс AppKit без окон. Самотест «Медиа» висел в `RunLoop.run(until:)` минутами (14.11:
// 2 зависания из 8 прогонов; с `-NSAppSleepDisabled YES` — 0 из 5, с этой строкой — 0 из 15) — похоже, App Nap.
// Хук агентов (`--hook`) сюда не попадает — он короткий и без цикла.
let batchActivity: NSObjectProtocol? = arguments.contains(where: { $0.hasPrefix("--selftest-") || $0 == "--snapshot" })
    ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "SimpleIsland selftest/snapshot")
    : nil

// Отладка: `--debug-send "<команда>"` — команда живому приложению, запущенному с SIMPLEISLAND_DEBUG=1
// (DebugControl.swift; без этой переменной приложение такие уведомления не слушает).
if let i = arguments.firstIndex(of: "--debug-send"), i + 1 < arguments.count {
    exit(DebugControl.send(arguments[i + 1]))
}

// Агенты: `--hook <Событие>` (хук Claude Code/Codex, без GUI) и `--selftest-agents`. Хук — раньше всего.
if let code = AgentsCLI.handle(arguments) { exit(code) }

// --selftest-today [--net] — самотест модуля «Сегодня» (без GUI и без прав).
if arguments.contains("--selftest-today") {
    let code = MainActor.assumeIsolated { TodaySelfTest.run(network: arguments.contains("--net")) }
    exit(code)
}

// Самотест модуля HUD (без окна): `SimpleIsland --selftest-hud`.
if arguments.contains("--selftest-hud") {
    exit(MainActor.assumeIsolated { HUDSelfTest.run(arguments) })
}

// --- shelf --- самотест Полки без экрана: zip, конвертер, OCR, вырезание фона, скрипты.
if arguments.contains("--selftest-shelf") {
    exit(MainActor.assumeIsolated { ShelfSelfTest.run(arguments) })
}

// --- media --- самотест модуля «Медиа» (без экрана и прав): --selftest-media [net] [live]
if let i = arguments.firstIndex(of: "--selftest-media") {
    exit(MainActor.assumeIsolated { MediaSelfTest.run(arguments: Array(arguments[(i + 1)...])) })
}

// --- equalizer --- эквалайзер Музыки и свои пресеты: --selftest-equalizer [live] (live — на настоящей Музыке,
// состояние возвращается; звук меряется, только если она уже играет).
if let i = arguments.firstIndex(of: "--selftest-equalizer") {
    exit(MainActor.assumeIsolated { MusicEqualizerSelfTest.run(arguments: Array(arguments[(i + 1)...])) })
}

// Отладка «Медиа»: кадры анимаций текста в PNG через CARenderer — `--render-lyrics-frames <каталог> [тема]`.
if let i = arguments.firstIndex(of: "--render-lyrics-frames") {
    exit(MainActor.assumeIsolated { LyricsDebugRender.run(Array(arguments[(i + 1)...])) })
}

// Отладка текстов: каскад острова с разбором по источникам — `--lyrics-lookup "<название>" "<исполнитель>" …`.
if let i = arguments.firstIndex(of: "--lyrics-lookup") {
    exit(LyricsLookupCLI.run(Array(arguments[(i + 1)...])))
}

// --- settings: самотесты настроек/онбординга без GUI
if arguments.contains("--selftest-settings") {
    exit(MainActor.assumeIsolated { SettingsSelfTest.run() })
}

// --- catalog --- самотест Vafa (файл статуса — во временном каталоге) и каталога виджетов
if arguments.contains("--selftest-vafa") {
    exit(MainActor.assumeIsolated { VafaSelfTest.run() })
}
if arguments.contains("--selftest-catalog") {
    exit(MainActor.assumeIsolated { WidgetCatalogSelfTest.run() })
}

// --- menubar --- самотест «Строки меню»: инвентарь на снимке слоя 25, разделы, настройки, карточка и клавиши —
// без событий в систему и без разделителя в настоящей строке меню.
if arguments.contains("--selftest-menubar") {
    exit(MainActor.assumeIsolated { MenuBarSelfTest.run(live: arguments.contains("--live")) })
}

// --- meetings --- самотест «Встреч» (поддельный Sten на 127.0.0.1, сессия в памяти, звук — синус через fMP4) и
// отладочная загрузка файла от имени вошедшей сессии виджета: `--meetings-upload <файл> [--meetings-server <адрес>]`.
#if SIMPLEISLAND_MEETINGS
if arguments.contains("--selftest-meetings") {
    exit(MainActor.assumeIsolated { MeetingsSelfTest.run() })
}
if let code = MainActor.assumeIsolated({ MeetingsCLI.handle(arguments) }) { exit(code) }
#endif

// `--selftest-core <screens|sleep|motion|rebuild [N]|loop|utils|a11y|all>` — самотесты ядра без окон на экране.
if let i = arguments.firstIndex(of: "--selftest-core") {
    let code = MainActor.assumeIsolated { CoreSelfTest.run(Array(arguments[(i + 1)...])) }
    exit(code)
}

if let options = SnapshotRunner.parse(arguments) {
    let code = MainActor.assumeIsolated { SnapshotRunner.run(options) }
    exit(code)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
