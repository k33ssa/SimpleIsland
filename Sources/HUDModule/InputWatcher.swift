import AppKit
import Carbon.HIToolbox

/// Раскладка (TIS, распределённое уведомление, без прав) и Caps Lock (монитор flagsChanged — события
/// клавиатуры другим приложениям видны только с Универсальным доступом; без него молчит, не падает).
@MainActor
final class InputWatcher {
    var onLayout: ((_ from: String?, _ to: String) -> Void)?
    var onCaps: ((Bool) -> Void)?

    private(set) var layoutCode: String?
    private(set) var capsOn = false
    private var layoutObserver: NSObjectProtocol?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var watchesLayout: Bool { layoutObserver != nil }
    var watchesCaps: Bool { globalMonitor != nil || localMonitor != nil }

    func startLayout() {
        guard layoutObserver == nil else { return }
        layoutCode = Self.currentLayoutCode()
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutChanged() }
        }
    }

    func stopLayout() {
        if let o = layoutObserver { DistributedNotificationCenter.default().removeObserver(o) }
        layoutObserver = nil
    }

    func startCaps() {
        guard globalMonitor == nil else { return }
        capsOn = Self.capsLockState()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let on = e.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.capsChanged(on) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let on = e.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.capsChanged(on) }
            return e
        }
    }

    func stopCaps() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil; localMonitor = nil
    }

    func stop() { stopLayout(); stopCaps() }

    /// После сна / смены экранов / возврата сессии: подписки заново, раскладку и Caps Lock перечитать молча
    /// (сменили во сне или на экране входа — вспышки не будет, следующая смена сравнится с правильным значением).
    func rewire() {
        if watchesLayout { stopLayout(); startLayout() }
        if watchesCaps { stopCaps(); startCaps() }
    }

    private func layoutChanged() {
        // Уведомление приходит пачкой и при смене «на ту же» — поднимаем вспышку только при реальной смене.
        guard let code = Self.currentLayoutCode(), code != layoutCode else { return }
        let old = layoutCode
        layoutCode = code
        onLayout?(old, code)
    }

    private func capsChanged(_ on: Bool) {
        guard on != capsOn else { return }
        capsOn = on
        onCaps?(on)
    }

    static func capsLockState() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }

    /// Короткий код текущей раскладки: «RU», «EN»… (по языку источника ввода).
    static func currentLayoutCode() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        var langs: [String] = []
        if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
            langs = (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
        }
        var sourceID = ""
        if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
            sourceID = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        return shortCode(languages: langs, sourceID: sourceID)
    }

    /// Чистая функция для самотеста.
    nonisolated static func shortCode(languages: [String], sourceID: String) -> String? {
        if let l = languages.first, !l.isEmpty {
            let base = l.split(separator: "-").first.map(String.init) ?? l
            return String(base.prefix(2)).uppercased()
        }
        let tail = sourceID.split(separator: ".").last.map(String.init) ?? ""
        if tail.isEmpty { return nil }
        if ["ABC", "US", "British", "Australian", "Canadian"].contains(tail) { return "EN" }
        return String(tail.prefix(2)).uppercased()
    }
}
