import AppKit
import Darwin

// Кнопки «Разрешить…» не молчат (14.11.2026, жалоба: «по нажатию „Разрешить календарь“ ничего не отправляется»).
// Две причины тишины: 1) запущенный из оболочки процесс для macOS (TCC) не «ответственный» — запрос уходит от
// имени родителя (bash → терминал/агент), окно не появляется, ответ «нет» приходит сразу; 2) карточка
// «Нужен доступ» в раскрытом острове ждала сворачивания. Здесь — решение «окно macOS / Системные настройки +
// карточка / перезапуск» чистыми функциями (самотест `--selftest-core perms`) и сам показ подсказки.

/// Как запущен процесс — от этого зависит, у кого macOS спрашивает права.
public enum LaunchKind: Equatable, Sendable {
    /// Открыт из Finder/Dock/`open` (LaunchServices): за права отвечает сам.
    case app
    /// Запущен другим процессом (оболочка, скрипт, терминал): за права отвечает родитель. `bundled` — бинарник
    /// лежит в `.app`, и его можно перезапустить через `open`.
    case child(bundled: Bool)

    public var isApp: Bool { self == .app }
    public var canRelaunch: Bool { self == .child(bundled: true) }

    /// Решение без побочных эффектов (самотест). `responsiblePid` — от
    /// `responsibility_get_pid_responsible_for_pid` (nil — функции нет): сам себе ответственный → приложение.
    /// Без неё — по родителю: у открытого через LaunchServices родитель launchd (pid 1).
    public static func detect(pid: pid_t, parentPid: pid_t, responsiblePid: pid_t?, bundlePath: String) -> LaunchKind {
        let bundled = bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/")
        if let r = responsiblePid, r > 0 { return r == pid ? .app : .child(bundled: bundled) }
        return parentPid == 1 ? .app : .child(bundled: bundled)
    }

    /// Этот процесс (считается один раз: способ запуска не меняется).
    public static let current: LaunchKind = {
        let pid = getpid()
        return detect(pid: pid, parentPid: getppid(), responsiblePid: responsiblePid(of: pid),
                      bundlePath: Bundle.main.bundlePath)
    }()

    /// Ответственный за процесс (TCC). Функция системная, но не в заголовках — берём через dlsym; нет — nil.
    public static func responsiblePid(of pid: pid_t) -> pid_t? {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        let r = unsafeBitCast(sym, to: Fn.self)(pid)
        return r > 0 ? r : nil
    }
}

/// Что сказать пользователю, если права нет и окна macOS не будет (или оно уже было).
public enum PermissionGuide: Equatable, Sendable {
    /// Запрещено раньше (или ограничено) — macOS второй раз не спросит, только переключатель в настройках.
    case deniedBefore
    /// Спросить нельзя: в Info.plist нет строки объяснения (отладочный бинарник) — только настройки.
    case cannotAsk
    /// Спросили, ответ «нет» пришёл сразу — окно не показалось.
    case noAnswer
    /// Окно было, ответили «Не разрешать».
    case declined
    /// Окно Универсального доступа показано (в нём своя кнопка) — дальше галочка в настройках.
    case accessibilityPrompted
    /// Автоматизация: приложение-цель не запущено, macOS спросит, когда оно будет запущено.
    case targetNotRunning
    /// Запущено не как приложение (из оболочки) — права спрашивают у родителя; нужен перезапуск.
    case relaunch(canRelaunch: Bool)

    /// Открывать ли раздел Системных настроек сразу (вместе с карточкой). После настоящего отказа в окне macOS
    /// («Не разрешать») — нет: человек только что сказал «нет», настройки поверх раздражают; карточка с кнопкой.
    public var opensSettings: Bool {
        switch self {
        case .deniedBefore, .cannotAsk, .noAnswer: return true
        case .declined, .accessibilityPrompted, .targetNotRunning, .relaunch: return false
        }
    }

    /// Заголовок и текст карточки (до ~110 знаков — три строки).
    public func text(for p: IslandPermission) -> (title: String, body: String) {
        switch self {
        case .deniedBefore, .cannotAsk, .noAnswer, .declined:
            let why: String
            switch self {
            case .deniedBefore: why = "Доступ запрещён раньше — macOS больше не спросит."
            case .cannotAsk: why = "Окно macOS здесь не покажется."
            case .noAnswer: why = "Окно macOS не появилось."
            default: why = "Доступ не выдан."
            }
            return ("Включите SimpleIsland: \(p.paneTitle)",
                    "\(why) Настройки → Конфиденциальность и безопасность → \(p.paneTitle).")
        case .accessibilityPrompted:
            return ("Включите: Универсальный доступ",
                    "В окне macOS нажмите «Открыть Системные настройки» и включите SimpleIsland в списке.")
        case .targetNotRunning:
            return ("Нужен запущенный \(p.targetName)",
                    "Запустите \(p.targetName) и нажмите «Разрешить» ещё раз — macOS спросит сама.")
        case .relaunch(let can):
            return ("Права не запросить: \(p.paneTitle)",
                    can ? "macOS спрашивает права только у приложения, открытого из Finder/Dock. Перезапустите SimpleIsland обычным способом."
                        : "macOS спрашивает права только у приложения из Finder/Dock. Соберите и откройте SimpleIsland.app (scripts/build-app.sh).")
        }
    }
}

/// Шаг по нажатию «Разрешить…».
public enum PermissionStep: Equatable, Sendable {
    case granted
    /// Показать системное окно macOS.
    case systemPrompt
    /// Окна не будет — карточка (и, если `opensSettings`, раздел Системных настроек).
    case guide(PermissionGuide)
}

public extension IslandPermission {
    /// Название раздела в «Конфиденциальность и безопасность».
    var paneTitle: String {
        switch self {
        case .accessibility: return "Универсальный доступ"
        case .automation: return "Автоматизация"
        case .calendars: return "Календари"
        case .reminders: return "Напоминания"
        case .camera: return "Камера"
        case .microphone: return "Микрофон"
        case .bluetooth: return "Bluetooth"
        // Раздел «Запись экрана и системного аудио», список «Только системное аудио» (полное имя не влезает в карточку).
        case .audioCapture: return "Запись экрана"
        }
    }

    /// Приложение-цель автоматизации («Music», «System Events»); для остальных — название права.
    var targetName: String {
        if case .automation(let id) = self { return Self.appName(id) }
        return title
    }
}

/// Подсказка «где включить право» для показа в острове.
public struct PermissionGuideCard: Sendable {
    public var permission: IslandPermission
    public var guide: PermissionGuide
    public var moduleId: String
    public var title: String
    public var body: String
    /// Ответ на нажатие кнопки: остров сворачивается, карточка — вне очереди. false — сама по себе (проверка прав
    /// при старте модуля): обычная очередь, остров не трогаем.
    public var interactive: Bool

    public init(permission: IslandPermission, guide: PermissionGuide, moduleId: String = "core", interactive: Bool = true) {
        self.permission = permission; self.guide = guide; self.moduleId = moduleId; self.interactive = interactive
        (title, body) = guide.text(for: permission)
        if !interactive, guide.isRelaunch { title = "SimpleIsland запущен не как приложение" }
    }

    /// Id карточки: одна общая на «запущен не как приложение» при старте, иначе — на право.
    public var notificationId: String {
        !interactive && guide.isRelaunch ? "permission.guide.launch" : "permission.guide.\(permission.title)"
    }

    /// Карточка уведомления: три строки, 25 с, кнопка по случаю («Перезапустить» / «Открыть настройки»).
    @MainActor
    public func notification() -> IslandNotification {
        let p = permission
        var actions: [IslandNotificationAction] = []
        switch guide {
        case .relaunch(let can):
            if can { actions.append(IslandNotificationAction("Перезапустить", role: .primary) { AppRelauncher.relaunch() }) }
        case .targetNotRunning:
            break
        default:
            actions.append(IslandNotificationAction("Открыть настройки", role: .primary) { Permissions.openSettings(p) })
        }
        var n = IslandNotification(id: notificationId, moduleId: moduleId, title: title,
                                   source: nil, body: body, systemImage: guide.isRelaunch ? "arrow.clockwise" : "lock.shield",
                                   actions: actions, duration: 25)
        n.bodyLines = 3
        return n
    }
}

extension PermissionGuide {
    var isRelaunch: Bool { if case .relaunch = self { return true }; return false }
}

/// Куда показывать подсказки. Ставит приложение (AppDelegate: свернуть остров и показать карточку вне очереди);
/// nil (самотесты, снимки) — только журнал.
@MainActor
public enum PermissionGuideCenter {
    public static var presenter: ((PermissionGuideCard) -> Void)?
    /// Последняя показанная подсказка (самотест).
    public private(set) static var last: PermissionGuideCard?
    /// Общая карточка «запущен не как приложение» уже была в этом запуске.
    public static var launchCardShown = false

    public static func present(_ card: PermissionGuideCard) {
        last = card
        NSLog("SimpleIsland: право «%@» — %@: %@", card.permission.title, card.title, card.body)
        presenter?(card)
    }
}

public extension Permissions {
    /// Порог «ответ пришёл сразу»: человек за такое время окно не прочтёт — значит, окна не было.
    nonisolated static let instantAnswer: TimeInterval = 0.5

    /// До запроса: есть / окно macOS / подсказка. Чистая функция (самотест).
    nonisolated static func plan(_ p: IslandPermission, status: PermissionStatus, canRequest: Bool,
                                 launch: LaunchKind) -> PermissionStep {
        if status == .granted { return .granted }
        // Не приложение — окно macOS ушло бы от имени родителя (или право получил бы терминал): не спрашиваем.
        if !launch.isApp { return .guide(.relaunch(canRelaunch: launch.canRelaunch)) }
        switch status {
        case .granted: return .granted
        case .denied: return .guide(.deniedBefore)
        case .notDetermined: return canRequest ? .systemPrompt : .guide(.cannotAsk)
        case .unknown:
            if case .automation = p { return .guide(.targetNotRunning) }
            return canRequest ? .systemPrompt : .guide(.cannotAsk)
        }
    }

    /// После системного запроса — по свежему статусу (`authorizationStatus`, а не только ответу запроса).
    nonisolated static func followUp(_ p: IslandPermission, after: PermissionStatus, elapsed: TimeInterval,
                                     launch: LaunchKind) -> PermissionStep {
        if after == .granted { return .granted }
        if !launch.isApp { return .guide(.relaunch(canRelaunch: launch.canRelaunch)) }
        if case .accessibility = p { return .guide(.accessibilityPrompted) }
        if case .automation = p, after == .unknown { return .guide(.targetNotRunning) }
        return .guide(elapsed < instantAnswer ? .noAnswer : .declined)
    }

    /// Нажатие «Разрешить…»: окно macOS, если оно возможно; права так и нет — раздел Системных настроек и
    /// карточка в острове «что включить и где»; запущено не как приложение — карточка с «Перезапустить».
    /// Никогда не молчит. Возвращает итоговый статус.
    @discardableResult
    static func requestFromUser(_ p: IslandPermission, moduleId: String = "core") async -> PermissionStatus {
        let launch = LaunchKind.current
        var step = plan(p, status: status(p), canRequest: canRequest(p), launch: launch)
        if step == .systemPrompt {
            let t0 = Date()
            let answer = await request(p)
            let after = answer == .granted ? .granted : status(p)
            step = followUp(p, after: after, elapsed: Date().timeIntervalSince(t0), launch: launch)
        }
        switch step {
        case .granted: return .granted
        case .systemPrompt: return status(p)   // не бывает: followUp окна не просит
        case .guide(let g):
            showGuide(g, for: p, moduleId: moduleId)
            return status(p)
        }
    }

    /// Показать подсказку (и открыть раздел настроек, если она это предполагает). `interactive: false` — не ответ на
    /// нажатие (старт модуля): настроек не открываем, остров не сворачиваем, карточка в обычной очереди.
    static func showGuide(_ g: PermissionGuide, for p: IslandPermission, moduleId: String = "core", interactive: Bool = true) {
        if interactive, g.opensSettings { openSettings(p) }
        PermissionGuideCenter.present(PermissionGuideCard(permission: p, guide: g, moduleId: moduleId, interactive: interactive))
    }

    /// Старт из оболочки: модули при включении проверяют права — показать ОДНУ общую карточку «перезапустите» за
    /// запуск (а не по одной на модуль и право). true — показана сейчас.
    @discardableResult
    static func noteNotLaunchedAsApp(_ p: IslandPermission, moduleId: String) -> Bool {
        guard !PermissionGuideCenter.launchCardShown else { return false }
        PermissionGuideCenter.launchCardShown = true
        showGuide(.relaunch(canRelaunch: LaunchKind.current.canRelaunch), for: p, moduleId: moduleId, interactive: false)
        return true
    }
}

/// Перезапуск «как приложение»: после выхода этого процесса `open -n` своего `.app` (LaunchServices — тогда
/// новый процесс сам себе ответственный, и macOS спросит права у SimpleIsland). Помощник — `/bin/sh` в своей
/// сессии: ждёт, пока этот pid завершится (до 30 с, зомби = завершился), и только тогда открывает — двух экземпляров не будет; не
/// дождался (выход отменили) — ничего не открывает.
@MainActor
public enum AppRelauncher {
    /// Свой `.app` (nil — отладочный бинарник без бандла).
    public static var bundleURL: URL? {
        let u = Bundle.main.bundleURL
        return u.pathExtension == "app" ? u : nil
    }

    /// Скрипт помощника (чистая функция, самотест): `$1` — путь к `.app`.
    /// Процесс считается вышедшим, когда `ps` его не знает или он зомби (`Z`: `kill -0` зомби видит живым, а
    /// родитель-оболочка может не забрать его сразу). Ждём до `tries × 0,1 с` (по умолчанию 30 с: долгий
    /// `applicationWillTerminate`); не дождались — не открываем (два экземпляра хуже, чем ни одного + журнал).
    nonisolated public static func helperScript(waitingFor pid: pid_t, tries: Int = 300) -> String {
        "i=0; while :; do s=$(/bin/ps -o stat= -p \(pid) 2>/dev/null); case \"$s\" in ''|Z*) break;; esac; i=$((i+1)); [ $i -gt \(tries) ] && exit 1; /bin/sleep 0.1; done; exec /usr/bin/open -n \"$1\""
    }

    /// Запустить помощника и выйти. false — нечего перезапускать или помощник не запустился (тогда не выходим).
    @discardableResult
    public static func relaunch() -> Bool {
        guard let app = bundleURL else { return false }
        let script = helperScript(waitingFor: getpid())
        guard spawnDetached(["/bin/sh", "-c", script, "sh", app.path]) else {
            NSLog("SimpleIsland: перезапуск не удался — помощник не запустился")
            return false
        }
        NSLog("SimpleIsland: перезапуск через open -n %@", app.path)
        NSApp.terminate(nil)
        return true
    }

    /// posix_spawn в новой сессии (не в группе процессов приложения: при выходе её не гасят), stdin/out/err —
    /// /dev/null, остальные дескрипторы закрыты.
    nonisolated public static func spawnDetached(_ argv: [String]) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for a in cargs { free(a) } }
        var pid: pid_t = 0
        let r = posix_spawn(&pid, argv[0], &fa, &attr, &cargs, environ)
        return r == 0
    }
}
