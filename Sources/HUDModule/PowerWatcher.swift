import Foundation
import IOKit.ps

/// Состояние батареи (что важно для вспышек).
struct PowerSnapshot: Equatable {
    var hasBattery: Bool
    var onAC: Bool
    var isCharging: Bool
    var isCharged: Bool
    var percent: Int
    var minutesToFull: Int?
    var minutesToEmpty: Int?
}

enum PowerEvent: Equatable {
    case pluggedIn, unplugged, charged, low(Int)
    /// Вскоре после подключения система досчитала время до полной или перешла в «заряжается» — обновить вспышку.
    case chargingDetails
}

/// Источники питания: IOPS-уведомление (без прав), приходит на любое изменение — сравниваем со снимком.
@MainActor
final class PowerWatcher {
    var onEvent: ((PowerEvent, PowerSnapshot) -> Void)?
    private(set) var last: PowerSnapshot?
    private var source: CFRunLoopSource?
    /// Когда подключили зарядку и показали ли уже уточнение (одно на подключение).
    private var pluggedAt: Date?
    /// Окно, в которое ждём от IOPS время до полной (сразу после подключения там обычно −1).
    static let detailsWindow: TimeInterval = 10

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        last = Self.read()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let w = Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { w.changed() }
        }, ctx)?.takeRetainedValue() else { return }
        // commonModes: события питания не ждут, пока закроют меню или закончат перетаскивание.
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); CFRunLoopSourceInvalidate(s) }
        source = nil
        pluggedAt = nil
    }

    private func changed() {
        guard let now = Self.read() else { return }
        handle(now, at: Date())
    }

    /// Новый снимок → события. Открыто для самотеста.
    func handle(_ now: PowerSnapshot, at time: Date) {
        let old = last
        var events = Self.diff(old: old, new: now)
        last = now
        if events.contains(.pluggedIn) {
            // Время до полной уже есть и зарядка идёт — уточнять нечего.
            pluggedAt = now.isCharging && HUDFlashes.plausibleMinutes(now.minutesToFull) != nil ? nil : time
        } else if !now.onAC {
            pluggedAt = nil
        } else if let t = pluggedAt, let old {
            if time.timeIntervalSince(t) > Self.detailsWindow {
                pluggedAt = nil
            } else if Self.gainedDetails(old: old, new: now) {
                pluggedAt = nil
                events.append(.chargingDetails)
            }
        }
        for e in events { onEvent?(e, now) }
    }

    /// Появилось то, чего не было в первой вспышке: зарядка пошла или время до полной стало известно.
    nonisolated static func gainedDetails(old: PowerSnapshot, new: PowerSnapshot) -> Bool {
        let hadTime = old.isCharging && HUDFlashes.plausibleMinutes(old.minutesToFull) != nil
        let hasTime = new.isCharging && HUDFlashes.plausibleMinutes(new.minutesToFull) != nil
        return (new.isCharging && !old.isCharging) || (hasTime && !hadTime)
    }

    /// Какие события поднять при переходе old → new. Пороги «мало заряда» — 20 % и 10 % (на батарее).
    nonisolated static func diff(old: PowerSnapshot?, new: PowerSnapshot) -> [PowerEvent] {
        guard let old, new.hasBattery else { return [] }
        var out: [PowerEvent] = []
        if !old.onAC && new.onAC { out.append(.pluggedIn) }
        if old.onAC && !new.onAC { out.append(.unplugged) }
        if new.onAC && old.onAC && !old.isCharged && new.isCharged { out.append(.charged) }
        if !new.onAC {
            for t in [20, 10] where old.percent > t && new.percent <= t { out.append(.low(new.percent)); break }
        }
        return out
    }

    nonisolated static func read() -> PowerSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            let full = d[kIOPSTimeToFullChargeKey] as? Int
            let empty = d[kIOPSTimeToEmptyKey] as? Int
            return PowerSnapshot(hasBattery: true,
                                 onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                                 isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                 isCharged: d[kIOPSIsChargedKey] as? Bool ?? false,
                                 percent: min(100, Swift.max(0, pct)),
                                 minutesToFull: (full ?? -1) > 0 ? full : nil,
                                 minutesToEmpty: (empty ?? -1) > 0 ? empty : nil)
        }
        return PowerSnapshot(hasBattery: false, onAC: true, isCharging: false, isCharged: false, percent: 100,
                             minutesToFull: nil, minutesToEmpty: nil)
    }
}
