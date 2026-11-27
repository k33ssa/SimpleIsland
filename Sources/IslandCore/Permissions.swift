import AppKit
import ApplicationServices
import AVFoundation
import CoreBluetooth
import EventKit
import SwiftUI

// Права (TCC) — запрашивать при ВКЛЮЧЕНИИ модуля, а не при старте приложения (грабли S3: Atoll спрашивал
// «Developer Tools» на каждом запуске, даже при выключенных функциях). Проверка статуса системного окна
// не показывает; окно — только из `request`/`ensurePermission`.

/// Право, которое может понадобиться модулю.
public enum IslandPermission: Hashable, Sendable {
    /// Универсальный доступ: event tap медиаклавиш (HUD), чтение окон.
    case accessibility
    /// Автоматизация (Apple Events) конкретного приложения: `bundleId` — "com.apple.Music", "com.spotify.client"…
    case automation(bundleId: String)
    case calendars
    case reminders
    case camera
    case microphone
    case bluetooth
    /// «Запись системного звука» (macOS 14.2+, Core Audio process tap): эквалайзер по настоящему звуку в Медиа.
    /// Только уровни полос в памяти — ничего не пишется на диск и никуда не отправляется.
    case audioCapture

    /// Название по-русски, как в Системных настройках.
    public var title: String {
        switch self {
        case .accessibility: return "Универсальный доступ"
        case .automation(let id): return "Автоматизация (\(Self.appName(id)))"
        case .calendars: return "Календари"
        case .reminders: return "Напоминания"
        case .camera: return "Камера"
        case .microphone: return "Микрофон"
        case .bluetooth: return "Bluetooth"
        case .audioCapture: return "Запись системного звука"
        }
    }

    /// Панель «Конфиденциальность и безопасность» в Системных настройках.
    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        case .calendars: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        // Список «Только запись системного звука» — в разделе «Запись экрана и системного звука».
        case .audioCapture: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Ключ Info.plist с объяснением для системного окна. Без него TCC убивает процесс при запросе (камера,
    /// микрофон, Bluetooth, календари, напоминания). Автоматизация без ключа не падает — ключ не требуется.
    public var usageDescriptionKey: String? {
        switch self {
        case .accessibility, .automation: return nil
        case .calendars: return "NSCalendarsFullAccessUsageDescription"
        case .reminders: return "NSRemindersFullAccessUsageDescription"
        case .camera: return "NSCameraUsageDescription"
        case .microphone: return "NSMicrophoneUsageDescription"
        case .bluetooth: return "NSBluetoothAlwaysUsageDescription"
        case .audioCapture: return "NSAudioCaptureUsageDescription"
        }
    }

    static func appName(_ bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleId
    }
}

public enum PermissionStatus: String, Sendable {
    case granted
    case denied
    /// Ещё не спрашивали — `request` покажет системное окно.
    case notDetermined
    /// Определить нельзя (напр. приложение для автоматизации не запущено и не установлено).
    case unknown

    public var title: String {
        switch self {
        case .granted: return "разрешено"
        case .denied: return "запрещено"
        case .notDetermined: return "не запрошено"
        case .unknown: return "неизвестно"
        }
    }
}

/// Проверка и запрос прав. Все вызовы — с главного потока; `request` — `async`.
@MainActor
public enum Permissions {
    /// Текущий статус без системного окна.
    public static func status(_ p: IslandPermission) -> PermissionStatus {
        switch p {
        case .accessibility:
            // Система не отличает «запрещено» от «не спрашивали» — помним сами, что окно уже показывали.
            if AXIsProcessTrusted() { return .granted }
            return accessibilityWasRequested ? .denied : .notDetermined
        case .automation(let id):
            return automationStatus(id, ask: false)
        case .calendars:
            return ekStatus(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return ekStatus(EKEventStore.authorizationStatus(for: .reminder))
        case .camera:
            return avStatus(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return avStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .audioCapture:
            return AudioCaptureTCC.status()
        }
    }

    /// Запросить право (системное окно, если ещё не спрашивали). Звать из действия пользователя / при включении
    /// модуля. Для Универсального доступа система окна-разрешения не даёт — откроется запрос с кнопкой
    /// «Открыть Системные настройки».
    public static func request(_ p: IslandPermission) async -> PermissionStatus {
        let current = status(p)
        if current == .granted { return .granted }
        // Ключа объяснения нет в Info.plist (debug-бинарник, или право в `.app` не заявлено — например, микрофон
        // и напоминания сейчас не используются) — не спрашивать: TCC убил бы процесс.
        guard canRequest(p) else {
            NSLog("SimpleIsland: право «%@» не запрошено — в Info.plist нет %@", p.title, p.usageDescriptionKey ?? "")
            return .unknown
        }
        switch p {
        case .accessibility:
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(opts)
            accessibilityWasRequested = true
            return trusted ? .granted : .denied
        case .automation(let id):
            // Приложение не запущено — спросить нельзя (procNotFound): не спрашиваем, ждём его запуска.
            if current == .unknown { return .unknown }
            // AEDeterminePermissionToAutomateTarget блокирует поток до ответа пользователя — только в фоне.
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: automationStatus(id, ask: true))
                }
            }
        case .calendars:
            let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
            return granted ? .granted : .denied
        case .reminders:
            let granted = (try? await EKEventStore().requestFullAccessToReminders()) ?? false
            return granted ? .granted : .denied
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .bluetooth:
            // Окно появляется при создании менеджера; ответ — в делегате.
            return await BluetoothAuthorizer.request()
        case .audioCapture:
            return await AudioCaptureTCC.request()
        }
    }

    /// Можно ли показать системный запрос: есть ли в Info.plist ключ объяснения (если он нужен).
    public static func canRequest(_ p: IslandPermission) -> Bool {
        guard let key = p.usageDescriptionKey else { return true }
        return Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    /// Показывали ли уже системный запрос Универсального доступа (через `request`). Хранится в UserDefaults:
    /// после первого раза `status(.accessibility)` без галочки — `.denied`, и `ensurePermission` не дёргает
    /// систему на каждом запуске, а `PermissionRow` предлагает «Открыть настройки».
    public static var accessibilityWasRequested: Bool {
        get { UserDefaults.standard.bool(forKey: accessibilityRequestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: accessibilityRequestedKey) }
    }
    private static let accessibilityRequestedKey = "permissions.accessibilityRequested"

    /// Открыть нужную панель Системных настроек.
    public static func openSettings(_ p: IslandPermission) {
        NSWorkspace.shared.open(p.settingsURL)
    }

    // MARK: Внутреннее

    private static func ekStatus(_ s: EKAuthorizationStatus) -> PermissionStatus {
        if s == .fullAccess { return .granted }
        if s == .notDetermined { return .notDetermined }
        if s == .writeOnly || s == .denied || s == .restricted { return .denied }
        return .unknown
    }

    private static func avStatus(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    nonisolated static func automationStatus(_ bundleId: String, ask: Bool) -> PermissionStatus {
        var desc = AEAddressDesc()
        let bytes = Array(bundleId.utf8)
        let created = bytes.withUnsafeBufferPointer { buf in
            AECreateDesc(DescType(typeApplicationBundleID), buf.baseAddress, buf.count, &desc)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&desc) }
        // Конкретное событие («core»/«getd» — чтение свойства, как `get name of current track`), а не typeWildCard:
        // с подстановкой система на части версий не показывает запрос и отвечает «нужно согласие».
        // Разрешение в TCC — на приложение целиком, так что событие годится для любого скрипта модуля.
        let r = AEDeterminePermissionToAutomateTarget(&desc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
        switch r {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown   // procNotFound (-600): приложение не запущено
        }
    }
}

/// «Запись системного звука» (`kTCCServiceAudioCapture`). Публичного API проверки/запроса у Apple нет: без права
/// process tap молча отдаёт нули. Как в insidegui/AudioCap — функции TCC.framework `TCCAccessPreflight` (0 —
/// разрешено, 1 — запрещено, иначе — не спрашивали) и `TCCAccessRequest` через dlsym. Нет символов — помним сами,
/// спрашивали ли (тогда окно macOS появится при первом запуске захвата), статус `.unknown`/`.notDetermined`.
@MainActor
enum AudioCaptureTCC {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let requestedKey = "permissions.audioCaptureRequested"

    static var wasRequested: Bool {
        get { UserDefaults.standard.bool(forKey: requestedKey) }
        set { UserDefaults.standard.set(newValue, forKey: requestedKey) }
    }

    static func status() -> PermissionStatus {
        guard let h = handle, let sym = dlsym(h, "TCCAccessPreflight") else {
            return wasRequested ? .unknown : .notDetermined
        }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    static func request() async -> PermissionStatus {
        wasRequested = true
        guard let h = handle, let sym = dlsym(h, "TCCAccessRequest") else { return .unknown }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        return await withCheckedContinuation { cont in
            fn(service, nil) { granted in cont.resume(returning: granted ? .granted : .denied) }
        }
    }
}

/// Запрос Bluetooth: окно системы появляется при создании `CBCentralManager`, ответ — `centralManagerDidUpdateState`.
@MainActor
private final class BluetoothAuthorizer: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var cont: CheckedContinuation<PermissionStatus, Never>?
    private static var active: BluetoothAuthorizer?

    static func request() async -> PermissionStatus {
        await withCheckedContinuation { c in
            let a = BluetoothAuthorizer()
            a.cont = c
            active = a
            a.manager = CBCentralManager(delegate: a, queue: .main)
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard CBManager.authorization != .notDetermined else { return }
            let s: PermissionStatus = CBManager.authorization == .allowedAlways ? .granted : .denied
            cont?.resume(returning: s); cont = nil
            manager = nil
            Self.active = nil
        }
    }
}

public extension ModuleContext {
    /// Статус права без системного окна.
    func permissionStatus(_ p: IslandPermission) -> PermissionStatus { Permissions.status(p) }

    /// Права при включении модуля (звать из `onEnabledChange` и из `start`, если `isEnabled`). Уже есть →
    /// `.granted`. Модуль выключен (`isEnabled == false`) → только статус, без окон. Не спрашивали → системное
    /// окно (Универсальный доступ — один раз за всё время, дальше `.denied`). Запрещено → карточка в острове
    /// «Нужен доступ: …» с `reason` и кнопкой «Открыть настройки» — не чаще раза за запуск на модуль и право.
    /// Автоматизация, когда приложение не запущено (`.unknown`), — ни окна, ни карточки: спросить при его запуске.
    /// В режиме снимков ничего не делает.
    @discardableResult
    func ensurePermission(_ p: IslandPermission, reason: String) async -> PermissionStatus {
        guard !isSnapshot else { return .unknown }
        var s = Permissions.status(p)
        guard s != .granted, isEnabled else { return s }
        // Запущено не как приложение (из оболочки): окно macOS ушло бы от имени родителя — не спрашиваем. Одна общая
        // карточка «перезапустите» на запуск, в обычной очереди, остров не сворачивается.
        if !LaunchKind.current.isApp {
            Permissions.noteNotLaunchedAsApp(p, moduleId: moduleId)
            return s
        }
        if s == .notDetermined { s = await Permissions.request(p) }
        if s == .unknown, case .automation = p { return s }
        let cardId = permissionCardId(p)   // --- misc2 --- было: литерал "permission.<модуль>.<право>"
        if s != .granted, PermissionCards.shown.insert(cardId).inserted {
            showNotification(IslandNotification(
                id: cardId, moduleId: moduleId,
                title: "Нужен доступ: \(p.title)", source: "SimpleIsland", body: reason,
                systemImage: "lock.shield", actions: [
                    IslandNotificationAction("Открыть настройки", role: .primary) { Permissions.openSettings(p) },
                ], duration: 12))
        }
        return s
    }

    /// Открыть панель Системных настроек для права.
    func openPrivacySettings(_ p: IslandPermission) { Permissions.openSettings(p) }

    // --- misc2 ---
    /// Id карточки «Нужен доступ» модуля для права.
    func permissionCardId(_ p: IslandPermission) -> String { "permission.\(moduleId).\(p.title)" }

    /// Убрать карточку «Нужен доступ» (показанную или в очереди): модуль показал просьбу на месте — в своей
    /// открытой вкладке, — и вторая просьба после сворачивания острова не нужна.
    func dismissPermissionCard(_ p: IslandPermission) { notifications.dismiss(id: permissionCardId(p)) }
    // --- /misc2 ---
}

/// Какие карточки «Нужен доступ» уже показаны в этом запуске.
@MainActor
enum PermissionCards {
    static var shown = Set<String>()
}

/// Строка «право — статус — кнопка» для `settingsView()` модуля.
public struct PermissionRow: View {
    var permission: IslandPermission
    var reason: String
    @State private var status: PermissionStatus = .unknown
    @Environment(\.islandTheme) private var theme

    public init(_ permission: IslandPermission, reason: String) {
        self.permission = permission; self.reason = reason
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted ? "checkmark.shield.fill" : "lock.shield")
                .foregroundStyle(status == .granted ? IslandPalette.ok : IslandPalette.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .semibold))
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(status.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if status != .granted {
                Button(status == .notDetermined ? "Разрешить" : "Открыть настройки") {
                    // Окно macOS, а если права так и нет — раздел настроек и карточка «где включить» (не молчит).
                    Task { @MainActor in status = await Permissions.requestFromUser(permission) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(permission.title): \(status.title)")
        .onAppear { status = Permissions.status(permission) }
    }
}
