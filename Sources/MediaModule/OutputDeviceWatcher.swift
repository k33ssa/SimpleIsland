import CoreAudio
import Foundation

/// Устройство вывода по умолчанию (CoreAudio, публично, без прав). Слушатель смены устройства на system object;
/// снимается в `stop()`. Без опроса.
@MainActor
final class OutputDeviceWatcher {
    var onChange: ((OutputDevice?) -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish() } }
        }
        let st = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if st == noErr { listener = block }
        publish()
    }

    func stop() {
        if let l = listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, l)
        }
        listener = nil
    }

    private func publish() { onChange?(Self.current()) }

    nonisolated static func current() -> OutputDevice? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }

        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameOK = withUnsafeMutablePointer(to: &name) { p in
            AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nsize, p) == noErr
        }
        let title = nameOK ? (name?.takeRetainedValue() as String?) ?? "" : ""

        let kind = Self.kind(dev)
        return OutputDevice(name: title.isEmpty ? "Вывод звука" : title, kind: kind)
    }
}

extension OutputDeviceWatcher {
    /// Задержка вывода устройства по умолчанию, с: задержка устройства + запас (safety offset) + буфер + задержка
    /// потока (CoreAudio, выход). AirPods/Bluetooth — обычно 0,1–0,3 с, AirPlay — до 2 с, встроенные — сотые.
    /// nil — не прочиталось.
    nonisolated static func outputLatency() -> Double? {
        func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                    _ v: inout T) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<T>.size)
            return withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &s, $0) == noErr }
        }
        var dev = AudioObjectID(0)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                  kAudioObjectPropertyScopeGlobal, &dev), dev != 0 else { return nil }
        var rate = Float64(0)
        guard get(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate), rate > 0 else { return nil }
        var lat = UInt32(0), safety = UInt32(0), buffer = UInt32(0), stream = UInt32(0)
        _ = get(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &lat)
        _ = get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &safety)
        _ = get(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, &buffer)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        if AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &ids) == noErr, let s = ids.first {
                _ = get(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &stream)
            }
        }
        return Double(lat) / rate + Double(safety) / rate + Double(buffer) / rate + Double(stream) / rate
    }
}

/// Устройство вывода для меню чипа: всё, что CoreAudio сообщает с выходными каналами.
struct OutputDeviceEntry: Equatable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var kind: OutputDevice.Kind
    var outputChannels: Int
    /// `kAudioDevicePropertyDeviceCanBeDefaultDevice` (выход): 0 — системным выходом его не сделать.
    var canBeDefault: Bool
}

/// Пункт меню устройства вывода (чистые данные — для самотеста).
struct OutputMenuItem: Equatable {
    var id: AudioObjectID
    var title: String
    var systemImage: String
    var isCurrent: Bool
}

extension OutputDeviceWatcher {
    /// Список для меню: только с выходными каналами, которые можно сделать выходом по умолчанию; без своих
    /// агрегатов захвата («SimpleIsland.EQ.…»); текущее — первым, остальные по имени; одинаковые имена — с номером.
    nonisolated static func menuItems(_ all: [OutputDeviceEntry], defaultID: AudioObjectID?) -> [OutputMenuItem] {
        let usable = all.filter { $0.outputChannels > 0 && $0.canBeDefault && !$0.uid.hasPrefix("SimpleIsland.") }
        let sorted = usable.sorted { a, b in
            if (a.id == defaultID) != (b.id == defaultID) { return a.id == defaultID }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var seen: [String: Int] = [:]
        return sorted.map { e in
            let n = (seen[e.name] ?? 0) + 1
            seen[e.name] = n
            let title = n > 1 ? "\(e.name) (\(n))" : e.name
            return OutputMenuItem(id: e.id, title: title,
                                  systemImage: OutputDevice(name: e.name, kind: e.kind).systemImage,
                                  isCurrent: e.id == defaultID)
        }
    }

    nonisolated static func defaultOutputID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    /// Все устройства CoreAudio (`kAudioHardwarePropertyDevices`) с числом выходных каналов.
    nonisolated static func allDevices() -> [OutputDeviceEntry] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = outputChannels(id)
            guard ch > 0 else { return nil }
            return OutputDeviceEntry(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                                     name: string(id, kAudioObjectPropertyName) ?? "Устройство",
                                     kind: kind(id), outputChannels: ch, canBeDefault: canBeDefault(id))
        }
    }

    /// Сделать устройство системным выходом по умолчанию. Слушатель `start()` обновит чип сам.
    @discardableResult
    nonisolated static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = id
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioObjectID>.size), &dev)
        if st != noErr { NSLog("SimpleIsland media: выход по умолчанию не сменился (%d)", st) }
        return st == noErr
    }

    private nonisolated static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let ok = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(id, &a, 0, nil, &s, $0) == noErr }
        guard ok, let str = v?.takeRetainedValue() as String?, !str.isEmpty else { return nil }
        return str
    }

    private nonisolated static func outputChannels(_ id: AudioObjectID) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                           mScope: kAudioObjectPropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func canBeDefault(_ id: AudioObjectID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                           mScope: kAudioObjectPropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var v = UInt32(1)
        var s = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr else { return true }
        return v != 0
    }

    nonisolated static func kind(_ id: AudioObjectID) -> OutputDevice.Kind {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var t = UInt32(0)
        var s = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &a, 0, nil, &s, &t)
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }
}
