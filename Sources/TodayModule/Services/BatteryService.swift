import Foundation
import IOKit
import IOKit.ps

struct BatteryItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case mac, mouse, keyboard, trackpad, headphones, other }
    var id: String
    var name: String
    var kind: Kind
    var level: Double        // 0…1
    var charging = false

    var symbol: String {
        switch kind {
        case .mac: return charging ? "bolt.fill" : "laptopcomputer"
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .headphones: return "headphones"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Батарея Mac (IOPS, событие) + Bluetooth-устройства (IORegistry `BatteryPercent`, если устройство его отдаёт).
enum Batteries {
    static func mac() -> BatteryItem? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return BatteryItem(id: "mac", name: "MacBook", kind: .mac, level: Double(cur) / Double(max), charging: charging)
        }
        return nil
    }

    /// Мышь/клавиатура/трекпад Apple (и наушники, если отдают) — `AppleDeviceManagementHIDEventService.BatteryPercent`.
    /// Встроенная клавиатура/трекпад (`Built-In`) пропускаются. AirPods обычно сюда не попадают — тогда их нет в списке.
    static func bluetooth() -> [BatteryItem] {
        var out: [BatteryItem] = []
        var seen = Set<String>()
        for cls in ["AppleDeviceManagementHIDEventService", "IOAppleBluetoothHIDDriver"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            while case let s = IOIteratorNext(it), s != 0 {
                defer { IOObjectRelease(s) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let p = props?.takeRetainedValue() as? [String: Any] else { continue }
                if let item = item(from: p), !seen.contains(item.id) {
                    seen.insert(item.id); out.append(item)
                }
            }
        }
        return out
    }

    /// Разбор свойств одного узла IORegistry (отдельно — для самотеста).
    static func item(from p: [String: Any]) -> BatteryItem? {
        if (p["Built-In"] as? Bool) == true { return nil }
        guard let pct = (p["BatteryPercent"] as? Int) ?? (p["BatteryPercent"] as? NSNumber)?.intValue, pct > 0 else { return nil }
        let product = (p["Product"] as? String) ?? "Устройство"
        let addr = (p["DeviceAddress"] as? String) ?? (p["SerialNumber"] as? String) ?? product
        let lower = product.lowercased()
        let kind: BatteryItem.Kind
        let name: String
        if lower.contains("mouse") { kind = .mouse; name = "Мышь" }
        else if lower.contains("trackpad") { kind = .trackpad; name = "Трекпад" }
        else if lower.contains("keyboard") { kind = .keyboard; name = "Клавиатура" }
        else if lower.contains("airpods") || lower.contains("beats") || lower.contains("headphone") { kind = .headphones; name = product.contains("AirPods") ? "AirPods" : product }
        else { kind = .other; name = product }
        return BatteryItem(id: "bt.\(addr)", name: name, kind: kind, level: Double(min(100, pct)) / 100)
    }
}

/// Событие «изменились источники питания» (без опроса). Колбэк C-шный — пересылаем в NotificationCenter.
@MainActor
final class PowerSourceWatcher {
    nonisolated static let changed = Notification.Name("SimpleIsland.today.powerSourcesChanged")
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    func start(_ handler: @escaping @MainActor () -> Void) {
        guard source == nil else { return }
        let cb: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: PowerSourceWatcher.changed, object: nil)
        }
        if let src = IOPSNotificationCreateRunLoopSource(cb, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        observer = NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        source = nil
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
    }
}
