import Foundation
import CoreGraphics
import ObjectiveC

/// Яркость встроенного дисплея — приватный DisplayServices через dlopen/dlsym (docs/TECH.md §3).
/// Нет фреймворка/символа/встроенного дисплея — `isAvailable == false`, клавиши отдаём системе.
final class DisplayBrightness: @unchecked Sendable {
    static let shared = DisplayBrightness()

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    /// Автояркость («Автоматически настраивать яркость») = компенсация внешнего света.
    private typealias HasALCFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias ALCEnabledFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32

    private let getFn: GetFn?
    private let setFn: SetFn?
    private let canFn: CanFn?
    private let hasALCFn: HasALCFn?
    private let alcEnabledFn: ALCEnabledFn?

    private init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        getFn = sym("DisplayServicesGetBrightness", GetFn.self)
        setFn = sym("DisplayServicesSetBrightness", SetFn.self)
        canFn = sym("DisplayServicesCanChangeBrightness", CanFn.self)
        hasALCFn = sym("DisplayServicesHasAmbientLightCompensation", HasALCFn.self)
        alcEnabledFn = sym("DisplayServicesAmbientLightCompensationEnabled", ALCEnabledFn.self)
    }

    var hasSymbols: Bool { getFn != nil && setFn != nil }

    /// Встроенный дисплей (если он сейчас онлайн — крышка открыта).
    static func builtinDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    var isAvailable: Bool {
        guard hasSymbols, let d = Self.builtinDisplay() else { return false }
        if let can = canFn { return can(d) }
        return get() != nil
    }

    func get() -> Double? {
        guard let f = getFn, let d = Self.builtinDisplay() else { return nil }
        var b: Float = 0
        return f(d, &b) == 0 ? Double(b) : nil
    }

    @discardableResult
    func set(_ v: Double) -> Bool {
        guard let f = setFn, let d = Self.builtinDisplay() else { return false }
        return f(d, Float(HUDFlashes.clampN(v))) == 0
    }

    /// Включена ли автояркость встроенного экрана. nil — не читается (нет символов, датчика или экрана):
    /// тогда подписи «авто» нет. Чтение дешёвое — только в момент вспышки, без подписок.
    /// Проверено 14.11.2026 на этом Маке: символы есть, датчик есть, rc 0, значение false (автояркость
    /// здесь, видимо, выключена); случай «включена» вживую не проверен.
    var isAutoBrightness: Bool? {
        guard let has = hasALCFn, let en = alcEnabledFn, let d = Self.builtinDisplay(), has(d) else { return nil }
        var on = false
        return en(d, &on) == 0 ? on : nil
    }
}

/// Подсветка клавиатуры — приватный CoreBrightness `KeyboardBrightnessClient` (docs/TECH.md §3).
/// Если класса/селекторов нет — честно `isAvailable == false`.
final class KeyboardBacklight: @unchecked Sendable {
    static let shared = KeyboardBacklight()

    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private let client: NSObject?
    private let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
    private(set) var keyboardID: UInt64 = 1
    let loadNote: String

    private init() {
        guard let b = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"), b.load() else {
            client = nil; loadNote = "CoreBrightness не загрузился"; return
        }
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            client = nil; loadNote = "нет класса KeyboardBrightnessClient"; return
        }
        let c = cls.init()
        guard c.responds(to: getSel), c.responds(to: setSel) else {
            client = nil; loadNote = "нет селекторов яркости клавиатуры"; return
        }
        client = c
        // Идентификатор встроенной клавиатуры: если есть список — берём первый, иначе 1 (как boring.notch).
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if c.responds(to: idsSel), let arr = c.perform(idsSel)?.takeRetainedValue() as? [NSNumber], let first = arr.first {
            keyboardID = first.uint64Value
        }
        loadNote = "ok"
    }

    var isAvailable: Bool { client != nil && get() != nil }

    func get() -> Double? {
        guard let c = client, let imp = c.method(for: getSel) else { return nil }
        let f = unsafeBitCast(imp, to: GetFn.self)
        let v = f(c, getSel, keyboardID)
        return v.isFinite && v >= 0 && v <= 1.0001 ? Double(v) : nil
    }

    @discardableResult
    func set(_ v: Double) -> Bool {
        guard let c = client, let imp = c.method(for: setSel) else { return false }
        let f = unsafeBitCast(imp, to: SetFn.self)
        return f(c, setSel, Float(HUDFlashes.clampN(v)), keyboardID)
    }
}

extension HUDFlashes {
    /// То же, что `clamp`, но без привязки к главному актору.
    nonisolated static func clampN(_ v: Double) -> Double { min(1, max(0, v.isFinite ? v : 0)) }
}
