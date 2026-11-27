import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import IOKit.pwr_mgt
import IslandCore

// Быстрые тумблеры: «Не спать», тёмная тема, микрофон, зеркало, чистый стол, «Не беспокоить» (ярлык).

enum ToggleKind: String, CaseIterable, Identifiable, Sendable {
    case focus, awake, cleanDesk, mirror, mic, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .focus: return "Тишина"
        case .awake: return "Не спать"
        case .cleanDesk: return "Стрим"
        case .mirror: return "Зеркало"
        case .mic: return "Микрофон"
        case .dark: return "Тёмная"
        }
    }
    var symbol: String {
        switch self {
        case .focus: return "moon"
        case .awake: return "cup.and.saucer"
        case .cleanDesk: return "eye"
        case .mirror: return "camera"
        case .mic: return "mic"
        case .dark: return "circle.lefthalf.filled"
        }
    }
    var help: String {
        switch self {
        case .focus: return "Не беспокоить — через ярлык «Быстрых команд»"
        case .awake: return "Не давать Маку и экрану засыпать"
        case .cleanDesk: return "Чистый стол для стрима: спрятать значки рабочего стола (Finder перезапустится)"
        case .mirror: return "Зеркало: камера прямо в плитке"
        case .mic: return "Выключить микрофон (громкость входа 0)"
        case .dark: return "Тёмное оформление macOS"
        }
    }
}

/// Какое разрешение просить у пользователя.
enum TodayPermission: String, Sendable {
    case calendar, automation, camera
    var title: String {
        switch self {
        case .calendar: return "Календарь"
        case .automation: return "Автоматизация → System Events"
        case .camera: return "Камера"
        }
    }
    var shortTitle: String {
        switch self {
        case .calendar: return "Календарь"
        case .automation: return "Автоматизация"
        case .camera: return "Камера"
        }
    }
    var settingsURL: URL {
        let pane: String
        switch self {
        case .calendar: pane = "Privacy_Calendars"
        case .automation: pane = "Privacy_Automation"
        case .camera: pane = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
    func openSettings() { NSWorkspace.shared.open(settingsURL) }
    /// То же право в ядре (для `Permissions.requestFromUser`).
    var islandPermission: IslandPermission {
        switch self {
        case .calendar: return .calendars
        case .automation: return .automation(bundleId: "com.apple.systemevents")
        case .camera: return .camera
        }
    }
}

// MARK: - Запуск системных утилит (через ManagedProcess, с тайм-аутом)

/// osascript, defaults, killall, shortcuts — разовые запуски через `ManagedProcess.runCollecting`: своя группа
/// процессов, гашение по тайм-ауту и при выходе/падении приложения, вывод — через файлы (большой stderr не вешает).
enum Shell {
    struct Result: Sendable { var code: Int32; var out: String; var err: String }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) async -> Result {
        let r = await ManagedProcess.runCollecting(path, args, timeout: timeout)
        return Result(code: r.launchFailed ? -1 : r.status, out: r.stdout,
                      err: r.timedOut ? "не ответил за \(Int(timeout)) с" : r.stderr)
    }
}

// MARK: - Не спать

/// IOPMAssertion «не гасить экран» — держим, пока тумблер включён; снимаем в stop().
@MainActor
final class AwakeAssertion {
    private var id: IOPMAssertionID = 0
    var isOn: Bool { id != 0 }

    @discardableResult
    func set(_ on: Bool) -> Bool {
        if on, id == 0 {
            var newId: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "SimpleIsland: «Не спать»" as CFString, &newId)
            guard rc == kIOReturnSuccess else { return false }
            id = newId
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
        return true
    }
}

// MARK: - Тёмная тема

enum DarkMode {
    static var isOn: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }
    static let changed = Notification.Name("AppleInterfaceThemeChangedNotification")

    enum SetResult: Sendable { case ok, needsPermission, failed(String) }

    /// System Events — нужно право «Автоматизация» (первый раз macOS спросит сама; отказ → -1743).
    static func set(_ dark: Bool) async -> SetResult {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark ? "true" : "false")"
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 60)
        if r.code == 0 { return .ok }
        if r.err.contains("-1743") || r.err.contains("-1744") || r.err.localizedCaseInsensitiveContains("not authorized") {
            return .needsPermission
        }
        return .failed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Только чтение через System Events — чтобы macOS спросила право «Автоматизация» (кнопка в настройках).
    /// Ничего не меняет.
    static func probeAccess() async -> SetResult {
        let r = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get dark mode of appearance preferences"], timeout: 60)
        if r.code == 0 { return .ok }
        if r.err.contains("-1743") || r.err.contains("-1744") || r.err.localizedCaseInsensitiveContains("not authorized") {
            return .needsPermission
        }
        return .failed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Микрофон (громкость входа)

enum MicControl {
    static func defaultInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    private static func address(_ sel: AudioObjectPropertySelector, _ el: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeInput, mElement: el)
    }

    /// Элементы с настраиваемой громкостью входа: главный, иначе по каналам.
    static func volumeElements(_ dev: AudioDeviceID) -> [UInt32] {
        func settable(_ el: UInt32) -> Bool {
            var a = address(kAudioDevicePropertyVolumeScalar, el)
            guard AudioObjectHasProperty(dev, &a) else { return false }
            var s: DarwinBoolean = false
            return AudioObjectIsPropertySettable(dev, &a, &s) == noErr && s.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...8).filter(settable)
    }

    static func volume(_ dev: AudioDeviceID) -> Float? {
        let els = volumeElements(dev)
        guard !els.isEmpty else { return nil }
        var sum: Float = 0
        for el in els {
            var a = address(kAudioDevicePropertyVolumeScalar, el)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
            sum += v
        }
        return sum / Float(els.count)
    }

    @discardableResult
    static func setVolume(_ dev: AudioDeviceID, _ value: Float) -> Bool {
        let els = volumeElements(dev)
        guard !els.isEmpty else { return false }
        var ok = true
        for el in els {
            var a = address(kAudioDevicePropertyVolumeScalar, el)
            var v = Float32(max(0, min(1, value)))
            ok = ok && AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        }
        return ok
    }

    static func isMuted(_ dev: AudioDeviceID) -> Bool? {
        var a = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v != 0
    }

    @discardableResult
    static func setMuted(_ dev: AudioDeviceID, _ on: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var v: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    /// Включить обратно: громкость `volume` и снять mute. true — хоть что-то получилось.
    @discardableResult
    static func restore(_ dev: AudioDeviceID, volume: Float) -> Bool {
        let volOK = setVolume(dev, volume > 0.001 ? volume : 0.75)
        let muteOK = setMuted(dev, false)
        return volOK || muteOK
    }

    /// Выключен ли микрофон сейчас: громкость входа 0 или mute.
    static func isOff() -> Bool {
        guard let d = defaultInput() else { return false }
        if let v = volume(d), v <= 0.001 { return true }
        return isMuted(d) ?? false
    }
}

/// Выключатель микрофона для модели: системный (`MicControl`) или поддельный в самотесте.
@MainActor
protocol MicSwitch: AnyObject {
    func defaultInput() -> AudioDeviceID?
    func volume(_ dev: AudioDeviceID) -> Float?
    func setVolume(_ dev: AudioDeviceID, _ value: Float) -> Bool
    func setMuted(_ dev: AudioDeviceID, _ on: Bool) -> Bool
    @discardableResult func restore(_ dev: AudioDeviceID, volume: Float) -> Bool
    func isOff() -> Bool
}

@MainActor
final class SystemMic: MicSwitch {
    func defaultInput() -> AudioDeviceID? { MicControl.defaultInput() }
    func volume(_ dev: AudioDeviceID) -> Float? { MicControl.volume(dev) }
    func setVolume(_ dev: AudioDeviceID, _ value: Float) -> Bool { MicControl.setVolume(dev, value) }
    func setMuted(_ dev: AudioDeviceID, _ on: Bool) -> Bool { MicControl.setMuted(dev, on) }
    func restore(_ dev: AudioDeviceID, volume: Float) -> Bool { MicControl.restore(dev, volume: volume) }
    func isOff() -> Bool { MicControl.isOff() }
}

// MARK: - Чистый стол (значки рабочего стола)

enum CleanDesk {
    /// Значки скрыты, если `com.apple.finder CreateDesktop` = false (по умолчанию ключа нет — значки видны).
    static var iconsHidden: Bool {
        guard let v = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) else { return false }
        if let b = v as? Bool { return !b }
        if let n = v as? NSNumber { return !n.boolValue }
        if let s = v as? String { return ["0", "false", "no"].contains(s.lowercased()) }
        return false
    }

    /// Записать ключ и перезапустить Finder (только после подтверждения пользователя).
    static func setIconsHidden(_ hidden: Bool) async -> Bool {
        let w = await Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        guard w.code == 0 else { return false }
        _ = await Shell.run("/usr/bin/killall", ["Finder"])
        return true
    }
}

// MARK: - Не беспокоить (через ярлык «Быстрых команд»)

enum FocusShortcut {
    /// Имена ярлыков, которые ищем, если в настройках имя не задано.
    static let candidates = ["Не беспокоить", "Тишина", "Do Not Disturb", "Set Focus", "Toggle Focus", "Фокусирование", "DND",
                             "Вкл./выкл. фокусирование"]
    /// Части имени, по которым ярлык фокуса узнаётся, если точного совпадения нет (27.11: у пользователя ярлык
    /// «Вкл./выкл. фокусирование» — точный список его не знал, и «Тишина» не показывалась вовсе).
    static let fragments = ["фокус", "focus", "беспокоить", "disturb", "dnd", "тишин"]

    static func pick(from names: [String], preferred: String) -> String? {
        let p = preferred.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { return names.first { $0.caseInsensitiveCompare(p) == .orderedSame } }
        for c in candidates { if let n = names.first(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { return n } }
        return names.first { n in fragments.contains { n.lowercased().contains($0) } }
    }

    static func list() async -> [String] {
        let r = await Shell.run("/usr/bin/shortcuts", ["list"], timeout: 10)
        guard r.code == 0 else { return [] }
        return r.out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func run(_ name: String) async -> Bool {
        await Shell.run("/usr/bin/shortcuts", ["run", name], timeout: 30).code == 0
    }
}

// MARK: - Зеркало (камера)

@MainActor
final class CameraMirror: ObservableObject {
    enum State: Equatable { case off, starting, running, needsPermission, noCamera }
    @Published private(set) var state: State = .off
    let session = AVCaptureSession()
    /// Номер запуска: ответ на системный запрос, пришедший после stop() (вкладку закрыли, пока
    /// пользователь жал «Разрешить»), камеру не включает.
    private var generation = 0
    private let queue = DispatchQueue(label: "SimpleIsland.today.mirror")
    private var configured = false

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var canAskSystem: Bool { Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil }

    /// Кнопка «Разрешить…» в настройках: пока к камере не обращались, раздел «Камера» пуст — сначала системный
    /// запрос (если в Info.plist есть строка), иначе — Системные настройки. Камеру не включает.
    /// Через ядро: права так и нет — раздел «Камера» и карточка «что включить и где», из оболочки — «Перезапустить».
    static func requestAccessOrOpenSettings(completion: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            _ = await Permissions.requestFromUser(.camera, moduleId: "today")
            completion()
        }
    }

    func start() {
        switch Self.authorization {
        case .authorized: run()
        case .notDetermined where Self.canAskSystem:
            state = .starting
            generation &+= 1
            let gen = generation
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.state == .starting, self.generation == gen else { return }   // уже выключили
                        if granted { self.run() } else { self.state = .needsPermission }
                    }
                }
            }
        default:
            state = .needsPermission
        }
    }

    private func run() {
        if !configured {
            guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev),
                  session.canAddInput(input) else { state = .noCamera; return }
            session.beginConfiguration()
            session.sessionPreset = .medium
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }
        state = .running
        let s = session
        queue.async { if !s.isRunning { s.startRunning() } }
    }

    func stop() {
        generation &+= 1
        if state == .running || state == .starting { state = .off }
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }
}
