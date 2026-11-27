import Foundation
import CoreAudio
import AudioToolbox

/// Громкость и mute текущего устройства вывода (CoreAudio, публичное API, без прав).
/// Слушатели висят на system object (смена устройства) и на самом устройстве; при смене устройства —
/// снимаются со старого и вешаются на новое (у boring.notch этого нет, docs/TECH.md §2).
@MainActor
final class AudioWatcher {
    struct State: Equatable {
        var device: AudioObjectID
        var name: String
        var volume: Double
        var muted: Bool
    }
    enum Reason { case volume, device }

    /// Что-то поменялось (уже на главном потоке, склеено в одно событие за проход цикла).
    var onChange: ((State, Reason) -> Void)?

    private(set) var boundDevice: AudioObjectID = 0
    private(set) var state: State?
    private var running = false
    /// Активные слушатели устройства: (объект, адрес). Для проверки «сняли ли всё».
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var systemListener = false
    private var pending: Reason?
    /// Программный mute для устройств без свойства mute: уровень до приглушения.
    private var softMuteLevel: Double?

    private lazy var deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.schedule(.volume) }
    }
    private lazy var systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated {
            guard let self, self.running else { return }
            self.rebind(to: Self.defaultOutputDevice())
            self.schedule(.device)
        }
    }

    var listenerCount: Int { deviceListeners.count + (systemListener ? 1 : 0) }
    /// Сколько раз система не сняла слушатель (код возврата ≠ noErr, объект при этом жив). Для самотеста: 0.
    private(set) var removeFailures = 0

    func start() {
        guard !running else { return }
        running = true
        var a = Self.addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, systemBlock) == noErr {
            systemListener = true
        }
        rebind(to: Self.defaultOutputDevice())
        state = read()
    }

    func stop() {
        guard running else { return }
        running = false
        unbindDevice()
        if systemListener {
            var a = Self.addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
            if AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, systemBlock) != noErr {
                removeFailures += 1
            }
            systemListener = false
        }
        pending = nil
    }

    /// Сколько раз слушатели перевешивали по системному событию (для самотеста).
    private(set) var rewireCount = 0

    /// После сна / смены экранов / возврата сессии: устройство вывода могло смениться, пока мы спали (AirPods
    /// ушли, подключили HDMI), а уведомление о смене — потеряться. Снять слушатели и повесить заново на текущее
    /// устройство (и на system object), состояние перечитать молча — без вспышки.
    func rewire() {
        guard running else { return }
        rewireCount += 1
        unbindDevice()
        if systemListener {
            var a = Self.addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
            if AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, systemBlock) != noErr {
                removeFailures += 1
            }
            systemListener = false
        }
        var a = Self.addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, systemBlock) == noErr {
            systemListener = true
        }
        rebind(to: Self.defaultOutputDevice())
        pending = nil
        state = read()
    }

    /// Перевесить слушатели на устройство `dev` (снять со старого). Открыто для самотеста.
    func rebind(to dev: AudioObjectID) {
        guard dev != boundDevice || deviceListeners.isEmpty else { return }
        unbindDevice()
        boundDevice = dev
        softMuteLevel = nil
        guard dev != 0 else { return }
        var addresses = [Self.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)]
        if Self.has(dev, Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)) {
            addresses.append(Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput))
        } else {
            // Устройства без main-элемента (часть USB/HDMI): слушать каналы 1 и 2.
            for ch in [UInt32(1), 2] {
                addresses.append(Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch))
            }
        }
        for var a in addresses where Self.has(dev, a) {
            if AudioObjectAddPropertyListenerBlock(dev, &a, .main, deviceBlock) == noErr {
                deviceListeners.append((dev, a))
            }
        }
    }

    private func unbindDevice() {
        for (obj, addr) in deviceListeners {
            var a = addr
            // Устройство отключили — слушатель ушёл вместе с ним, это не утечка.
            if AudioObjectRemovePropertyListenerBlock(obj, &a, .main, deviceBlock) != noErr, Self.allDevices().contains(obj) {
                removeFailures += 1
            }
        }
        deviceListeners.removeAll()
        boundDevice = 0
    }

    /// Склеить пачку уведомлений (громкость по каналам, mute) в одно событие.
    private func schedule(_ r: Reason) {
        if pending == .device { return }
        let first = pending == nil
        pending = r
        guard first else { return }
        // Чтение — вне главного потока (25.11: USB-карта отвечает ~130 мс на вызов, имя+громкость+mute ≈ 400 мс в
        // главном потоке на каждое изменение — остров не перерисовывался и не принимал клавиши, «визуально лагает»).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.pending != nil else { return }
                let dev = self.boundDevice != 0 ? self.boundDevice : Self.defaultOutputDevice()
                guard dev != 0 else { self.pending = nil; return }
                let soft = self.softMuteLevel
                let knownName = self.state?.device == dev ? self.state?.name : nil
                Self.readQueue.async {
                    let name = knownName ?? Self.name(dev) ?? "Звук"
                    let vol = soft ?? Self.volume(dev) ?? 0
                    let muted = soft != nil || (Self.muted(dev) ?? false)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { [weak self] in
                            guard let self, self.running, let reason = self.pending else { return }
                            self.pending = nil
                            let s = State(device: dev, name: name, volume: vol, muted: muted)
                            let old = self.state
                            self.state = s
                            if reason == .device || old == nil || old!.volume != s.volume || old!.muted != s.muted
                                || old!.device != s.device {
                                self.onChange?(s, reason == .device || old?.device != s.device ? .device : .volume)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Чтение / запись

    func read() -> State? {
        let dev = boundDevice != 0 ? boundDevice : Self.defaultOutputDevice()
        guard dev != 0 else { return nil }
        let soft = softMuteLevel != nil
        return State(device: dev, name: Self.name(dev) ?? "Звук",
                     volume: soft ? softMuteLevel! : (Self.volume(dev) ?? 0),
                     muted: soft || (Self.muted(dev) ?? false))
    }

    /// Можно ли менять громкость устройства (иначе клавишу пропускаем системе).
    func canSetVolume() -> Bool {
        let dev = boundDevice != 0 ? boundDevice : Self.defaultOutputDevice()
        guard dev != 0 else { return false }
        if Self.settable(dev, Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)) { return true }
        return Self.settable(dev, Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1))
    }

    @discardableResult
    func setVolume(_ v: Double) -> Bool {
        let dev = boundDevice != 0 ? boundDevice : Self.defaultOutputDevice()
        guard dev != 0 else { return false }
        var f = Float32(HUDFlashes.clamp(v))
        var ok = false
        var a = Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        if Self.settable(dev, a) {
            ok = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &f) == noErr
        } else {
            for ch in [UInt32(1), 2] {
                var c = Self.addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch)
                if Self.settable(dev, c),
                   AudioObjectSetPropertyData(dev, &c, 0, nil, UInt32(MemoryLayout<Float32>.size), &f) == noErr { ok = true }
            }
        }
        if ok, softMuteLevel != nil { softMuteLevel = nil }
        return ok
    }

    @discardableResult
    func setMuted(_ m: Bool) -> Bool {
        let dev = boundDevice != 0 ? boundDevice : Self.defaultOutputDevice()
        guard dev != 0 else { return false }
        var a = Self.addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        if Self.settable(dev, a) {
            var v: UInt32 = m ? 1 : 0
            return AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &v) == noErr
        }
        // Нет свойства mute — программный: запомнить уровень и поставить 0.
        if m {
            guard softMuteLevel == nil else { return true }
            let level = Self.volume(dev) ?? 0
            guard setVolume(0) else { return false }
            softMuteLevel = level
            schedule(.volume)
            return true
        } else {
            guard let level = softMuteLevel else { return true }
            softMuteLevel = nil
            return setVolume(level)
        }
    }

    // MARK: CoreAudio

    nonisolated static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                                 _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    nonisolated static func has(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        return AudioObjectHasProperty(obj, &a)
    }

    nonisolated static func settable(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        guard AudioObjectHasProperty(obj, &a) else { return false }
        var s: DarwinBoolean = false
        return AudioObjectIsPropertySettable(obj, &a, &s) == noErr && s.boolValue
    }

    nonisolated static func defaultOutputDevice() -> AudioObjectID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var d = AudioObjectID(0)
        var s = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d) == noErr else { return 0 }
        return d
    }

    /// Поставить громкость устройства и дожать до соседней ступени в сторону `up` (у USB-карт ступени грубые: значение
    /// округляется назад). Вне главного потока: у USB-карты каждый вызов ~130 мс (замер 25.11, AB17X). Итог — что стало.
    nonisolated static func applyVolume(_ dev: AudioObjectID, target v: Double, from base: Double, up: Bool) -> Double? {
        func set(_ x: Double) {
            var f = Float32(min(1, max(0, x)))
            var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
            if AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &f) != noErr {
                for ch in [UInt32(1), 2] {
                    var c = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch)
                    _ = AudioObjectSetPropertyData(dev, &c, 0, nil, UInt32(MemoryLayout<Float32>.size), &f)
                }
            }
        }
        let moved: (Double) -> Bool = { up ? $0 > base + 0.001 : $0 < base - 0.001 }
        set(v)
        var now = volume(dev)
        if let n = now, !moved(n), v != base {
            var t = v
            for _ in 0..<16 {
                t += up ? 1.0 / 64 : -1.0 / 64
                guard t >= 0, t <= 1.0001 else { break }
                set(t)
                now = volume(dev)
                if let n2 = now, moved(n2) { break }
            }
        }
        return now
    }

    nonisolated static let readQueue = DispatchQueue(label: "local.simpleisland.hud.audioread", qos: .userInitiated)

    nonisolated static func volume(_ dev: AudioObjectID) -> Double? {
        var f = Float32(0)
        var s = UInt32(MemoryLayout<Float32>.size)
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(dev, &a), AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &f) == noErr { return Double(f) }
        var c = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1)
        s = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(dev, &c), AudioObjectGetPropertyData(dev, &c, 0, nil, &s, &f) == noErr { return Double(f) }
        return nil
    }

    nonisolated static func muted(_ dev: AudioObjectID) -> Bool? {
        var v = UInt32(0)
        var s = UInt32(4)
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(dev, &a), AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr else { return nil }
        return v != 0
    }

    nonisolated static func name(_ obj: AudioObjectID) -> String? {
        var a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    nonisolated static func transport(_ dev: AudioObjectID) -> UInt32? {
        var v = UInt32(0)
        var s = UInt32(4)
        var a = addr(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr else { return nil }
        return v
    }

    /// Все устройства (для поиска входных и для самотеста).
    nonisolated static func allDevices() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var s = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s) == noErr, s > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(s) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &ids) == noErr else { return [] }
        return ids
    }

    /// Есть ли у устройства потоки в данной области (вход/выход).
    nonisolated static func hasStreams(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var a = addr(kAudioDevicePropertyStreams, scope)
        var s = UInt32(0)
        return AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &s) == noErr && s > 0
    }
}

/// Шаг громкости/яркости: 1/16, с ⌥⇧ — 1/64; значение прилипает к сетке шага, как у системы.
enum HUDStep {
    static func apply(_ v: Double, up: Bool, fine: Bool) -> Double {
        let n = fine ? 64.0 : 16.0
        let cur = (v * n).rounded()
        // Если значение между делениями (поменяли ползунком) — первый шаг доводит до ближайшего деления.
        let exact = abs(v * n - cur) < 0.01
        var next: Double
        if up { next = exact ? cur + 1 : ceil(v * n) } else { next = exact ? cur - 1 : floor(v * n) }
        next = min(n, max(0, next))
        return next / n
    }
}
