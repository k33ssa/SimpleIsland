import AudioToolbox
import CoreAudio
import Foundation
import IslandCore

// Эквалайзер по настоящему звуку (15.11, жалоба: «волна справа не соответствует звуку»). Как у Atoll: Core Audio
// process tap (macOS 14.2+) → своё приватное агрегатное устройство → блок ввода-вывода → полосы (`AudioSpectrum`).
// Не ScreenCaptureKit (нужна «Запись экрана» и значок записи в строке меню — так отказался boring.notch, #234) и не
// loopback-драйвер. Право — «Запись системного звука» (`IslandPermission.audioCapture`, NSAudioCaptureUsageDescription).
// Захват живёт, только пока: включено в настройках, играет, полоски видны и анимированы (`AudioLevelsFeed.hasDemand`:
// компакт/вкладка на экране, `islandMotion == .full`), Мак не спит. Пауза, сворачивание, сон, выход — tap и агрегат
// уничтожаются. Звук не пишется на диск и никуда не уходит: в памяти — только последние 2048 отсчётов для БПФ.

/// Чей звук слушать: процесс плеера из Now Playing (pid, bundle id); nil-поля — весь системный вывод.
struct AudioTapTarget: Equatable, Sendable {
    var pid: Int32?
    var bundleId: String?
}

/// Аудио-процесс Core Audio (`kAudioHardwarePropertyProcessObjectList`).
struct AudioProcessEntry: Equatable, Sendable {
    var object: AudioObjectID
    var pid: Int32
    var bundleId: String
}

/// Что именно захватывать.
enum AudioTapPlan: Equatable, Sendable {
    /// Только эти аудио-процессы (плеер и его помощники — Chrome Helper и т. п.), стерео-сведение.
    case processes([AudioObjectID])
    /// Весь системный вывод, кроме своих процессов.
    case global(excluding: [AudioObjectID])

    /// Выбор (чистая функция, самотест): процессы с тем же pid или bundle id плеера / его помощников
    /// (`com.google.Chrome.helper…`); у Safari звук идёт из `com.apple.WebKit.GPU`. Ничего не нашлось — весь вывод.
    static func choose(target: AudioTapTarget, processes: [AudioProcessEntry], ownPid: Int32) -> AudioTapPlan {
        let own = processes.filter { $0.pid == ownPid }.map(\.object)
        var match: [AudioObjectID] = []
        let b = target.bundleId ?? ""
        for p in processes where p.pid != ownPid {
            if let pid = target.pid, pid > 0, p.pid == pid { match.append(p.object); continue }
            guard !b.isEmpty else { continue }
            if p.bundleId == b || p.bundleId.hasPrefix(b + ".") { match.append(p.object); continue }
            if b == "com.apple.Safari", p.bundleId.hasPrefix("com.apple.WebKit.GPU") { match.append(p.object) }
        }
        return match.isEmpty ? .global(excluding: own) : .processes(match)
    }
}

/// Сведения о запущенном захвате.
struct AudioCaptureInfo: Equatable, Sendable {
    var sampleRate: Double
    /// Сколько ждать перед показом уровней, с: задержка вывода (Bluetooth ~0,15–0,25 с) минус длина буфера захвата.
    var displayDelay: Double
    var bufferFrames: Int
    var plan: AudioTapPlan
}

/// Приёмник отсчётов на потоке ввода-вывода: моно → полосы → на главный поток (не чаще 20 Гц).
final class AudioSampleSink: @unchecked Sendable {
    typealias Deliver = @Sendable (_ wide: [Float], _ compact: [Float], _ interval: Double, _ silentSeconds: Double,
                                   _ silent: Bool) -> Void
    private let deliver: Deliver
    private var spectrum: AudioSpectrum?
    private var channelsPerFrame = 2
    private var interleaved = true
    private var lastDelivery: UInt64 = 0

    init(deliver: @escaping Deliver) { self.deliver = deliver }

    /// Отладка (`--selftest-equalizer live`): сырые буферы — на потоке ввода-вывода, до спектра (там AGC, по нему
    /// громкость не сравнить). Задаётся до старта захвата. В приложении nil.
    var raw: ((_ buffers: UnsafeMutableAudioBufferListPointer, _ interleaved: Bool, _ channels: Int) -> Void)?

    /// До старта ввода-вывода (с очереди захвата).
    func prepare(sampleRate: Double, channels: Int, interleaved: Bool) {
        spectrum = AudioSpectrum(sampleRate: sampleRate)
        channelsPerFrame = max(1, channels)
        self.interleaved = interleaved
    }

    /// Буферы агрегата: поток tap — последний (до него могут идти входы подустройства). Только Float32.
    func consume(_ list: UnsafePointer<AudioBufferList>) {
        guard let sp = spectrum else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard abl.count > 0 else { return }
        raw?(abl, interleaved, channelsPerFrame)
        var fresh = false
        if interleaved {
            let buf = abl[abl.count - 1]
            let ch = max(1, Int(buf.mNumberChannels))
            guard let d = buf.mData else { return }
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            fresh = sp.process(interleaved: d.assumingMemoryBound(to: Float.self), frames: frames, channels: ch)
        } else {
            let n = min(channelsPerFrame, abl.count)
            var ptrs: [UnsafePointer<Float>] = []
            ptrs.reserveCapacity(n)
            var frames = Int.max
            for i in (abl.count - n)..<abl.count {
                guard let d = abl[i].mData else { return }
                ptrs.append(UnsafePointer(d.assumingMemoryBound(to: Float.self)))
                frames = min(frames, Int(abl[i].mDataByteSize) / MemoryLayout<Float>.size)
            }
            fresh = sp.process(planar: ptrs, frames: frames)
        }
        guard fresh else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = lastDelivery == 0 ? 0.085 : Double(now - lastDelivery) / 1e9
        lastDelivery = now
        deliver(sp.wide, sp.compact, interval, sp.silentSeconds, sp.lastWasSilent)
    }
}

/// Источник звука: настоящий (process tap) или заглушка самотеста. Методы зовутся с одной последовательной очереди.
protocol AudioCaptureBackend: AnyObject {
    func start(target: AudioTapTarget, sink: AudioSampleSink) throws -> AudioCaptureInfo
    func stop()
}

struct AudioCaptureError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
    init(_ what: String, _ st: OSStatus) { description = "\(what): \(st)" }
}

/// Core Audio process tap + приватное агрегатное устройство (схема insidegui/AudioCap).
final class ProcessTapBackend: AudioCaptureBackend, @unchecked Sendable {
    /// Желаемый буфер агрегата: 4096 кадров ≈ 85 мс при 48 кГц → ~12 пробуждений потока ввода-вывода в секунду
    /// (по умолчанию 512 — ~94/с, а бюджет компакта с музыкой — ≤ 15/с).
    static let preferredBufferFrames: UInt32 = 4096

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    var isRunning: Bool { procID != nil }

    func start(target: AudioTapTarget, sink: AudioSampleSink) throws -> AudioCaptureInfo {
        stop()
        do { return try startInner(target: target, sink: sink) } catch { stop(); throw error }
    }

    private func startInner(target: AudioTapTarget, sink: AudioSampleSink) throws -> AudioCaptureInfo {
        let plan = AudioTapPlan.choose(target: target, processes: Self.audioProcesses(), ownPid: getpid())
        let desc: CATapDescription
        switch plan {
        case .processes(let ids): desc = CATapDescription(stereoMixdownOfProcesses: ids)
        case .global(let ex): desc = CATapDescription(stereoGlobalTapButExcludeProcesses: ex)
        }
        desc.uuid = UUID()
        desc.name = "SimpleIsland EQ"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else { throw AudioCaptureError("tap", st) }
        tapID = tap

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt)
        guard st == noErr else { throw AudioCaptureError("format", st) }
        guard fmt.mFormatID == kAudioFormatLinearPCM, fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              fmt.mBitsPerChannel == 32 else { throw AudioCaptureError("формат tap не Float32") }

        let output = try Self.defaultOutputDevice()
        let outputUID = try Self.deviceUID(output)
        // Агрегат ТОЛЬКО из tap, без устройства вывода (18.11): у USB-карты со входом и выходом (AB17X) устройство в
        // составе открывало и её вход — оранжевый значок микрофона, пока играет музыка. Только из tap звук идёт
        // (проверено 18.11: «настоящий звук пошёл», вход процесса пуст). Не создался — прежний состав, а вход
        // устройства выключается для нашего IOProc (`disableDeviceInputStreams`).
        let tapList: [[String: Any]] = [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]
        let tapOnly: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SimpleIsland EQ",
            kAudioAggregateDeviceUIDKey: "SimpleIsland.EQ." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var withOutput = tapOnly
        withOutput[kAudioAggregateDeviceUIDKey] = "SimpleIsland.EQ." + UUID().uuidString
        withOutput[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
        withOutput[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        var agg = AudioObjectID(kAudioObjectUnknown)
        var withDevice = false
        st = AudioHardwareCreateAggregateDevice(tapOnly as CFDictionary, &agg)
        if st != noErr || agg == kAudioObjectUnknown {
            NSLog("SimpleIsland media: агрегат только из tap не создан (%d) — с устройством вывода", st)
            agg = AudioObjectID(kAudioObjectUnknown)
            withDevice = true
            st = AudioHardwareCreateAggregateDevice(withOutput as CFDictionary, &agg)
        }
        guard st == noErr, agg != kAudioObjectUnknown else { throw AudioCaptureError("aggregate", st) }
        aggregateID = agg

        let frames = Self.setBufferFrames(agg, wanted: Self.preferredBufferFrames)
        let rate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48_000
        sink.prepare(sampleRate: rate, channels: Int(fmt.mChannelsPerFrame),
                     interleaved: fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
        let delay = max(0, min(0.3, Self.outputLatency(output) - Double(frames) / rate))

        var proc: AudioDeviceIOProcID?
        // Очередь nil — блок прямо на потоке ввода-вывода HAL: без лишнего перехода на очередь (ещё ~12 пробуждений/с).
        // Работа в блоке — микросекунды (БПФ 2048 раз в ~85 мс), на главный поток — одна отправка на расчёт.
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, _, _, _ in
            sink.consume(input)
        }
        guard st == noErr, let proc else { throw AudioCaptureError("ioproc", st) }
        procID = proc
        if withDevice {
            Self.disableDeviceInputStreams(agg, proc: proc, deviceInputStreams: Self.streamCount(output, scope: kAudioObjectPropertyScopeInput))
        }
        st = AudioDeviceStart(agg, proc)
        guard st == noErr else { throw AudioCaptureError("start", st) }
        return AudioCaptureInfo(sampleRate: rate, displayDelay: delay, bufferFrames: Int(frames), plan: plan)
    }

    /// Сколько потоков у устройства в области (вход/выход).
    static func streamCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Выключить для нашего IOProc входные потоки устройства вывода в агрегате (его микрофон), оставить только tap.
    /// Входные потоки агрегата: сначала потоки устройства, потом tap. Без этого USB-карта со входом (AB17X) открывала
    /// микрофон — оранжевый значок macOS, пока играет музыка (18.11).
    static func disableDeviceInputStreams(_ agg: AudioObjectID, proc: AudioDeviceIOProcID, deviceInputStreams: Int) {
        guard deviceInputStreams > 0 else { return }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(agg, &a, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(agg, &a, 0, nil, &size, raw) == noErr else { return }
        let n = Int(usage.pointee.mNumberStreams)
        guard n > deviceInputStreams else { return }   // tap должен остаться
        // Входные потоки агрегата: сначала потоки устройства, последним — tap (проверено 18.11: так звук идёт и вход
        // устройства закрыт; наоборот — тишина). `consume` и так берёт последний буфер.
        withUnsafeMutablePointer(to: &usage.pointee.mStreamIsOn) { first in
            first.withMemoryRebound(to: UInt32.self, capacity: n) { on in
                for i in 0..<n { on[i] = i < deviceInputStreams ? 0 : 1 }
            }
        }
        let st = AudioObjectSetPropertyData(agg, &a, 0, nil, size, raw)
        NSLog("SimpleIsland media: вход устройства выключен для захвата (%d из %d потоков) — %d", deviceInputStreams, n, st)
    }

    /// Освободить всё (повторный вызов безопасен). Приватные tap и агрегат система уберёт и при выходе процесса.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    // MARK: Свойства Core Audio

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func audioProcesses() -> [AudioProcessEntry] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var pid: pid_t = 0
            var ps = UInt32(MemoryLayout<pid_t>.size)
            var a = address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(id, &a, 0, nil, &ps, &pid)
            var bundle: Unmanaged<CFString>?
            var bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var b = address(kAudioProcessPropertyBundleID)
            let st = AudioObjectGetPropertyData(id, &b, 0, nil, &bs, &bundle)
            let bid = st == noErr ? (bundle?.takeRetainedValue() as String?) ?? "" : ""
            return AudioProcessEntry(object: id, pid: pid, bundleId: bid)
        }
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard st == noErr, dev != kAudioObjectUnknown else { throw AudioCaptureError("output", st) }
        return dev
    }

    static func deviceUID(_ dev: AudioDeviceID) throws -> String {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid)
        guard st == noErr, let s = uid?.takeRetainedValue() as String? else { throw AudioCaptureError("uid", st) }
        return s
    }

    /// Буфер агрегата: желаемый, но в пределах допустимого диапазона. Возвращает установленный.
    static func setBufferFrames(_ dev: AudioDeviceID, wanted: UInt32) -> UInt32 {
        var range = AudioValueRange()
        var rs = UInt32(MemoryLayout<AudioValueRange>.size)
        var ra = address(kAudioDevicePropertyBufferFrameSizeRange)
        var frames = wanted
        if AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &range) == noErr, range.mMaximum > 0 {
            frames = UInt32(max(range.mMinimum, min(range.mMaximum, Double(wanted))))
        }
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var set = frames
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &set)
        var got: UInt32 = 0
        var gs = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(dev, &a, 0, nil, &gs, &got) == noErr, got > 0 { return got }
        return frames
    }

    /// Задержка вывода устройства, с (задержка + запас + буфер), по его частоте.
    static func outputLatency(_ dev: AudioDeviceID) -> Double {
        func u32(_ sel: AudioObjectPropertySelector) -> UInt32 {
            var a = address(sel, kAudioObjectPropertyScopeOutput)
            var v: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        var ra = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var rs = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &rate)
        guard rate > 0 else { return 0 }
        let frames = u32(kAudioDevicePropertyLatency) + u32(kAudioDevicePropertySafetyOffset) + u32(kAudioDevicePropertyBufferFrameSize)
        return Double(frames) / rate
    }
}

/// Жизненный цикл захвата (главный поток): когда создавать tap, когда уничтожать, что делать при сбое и «нулях».
@MainActor
final class LiveAudioController {
    enum State: Equatable {
        case idle
        case starting
        case running
        /// tap/агрегат не создались — до следующего «играет»/трека/включения — псевдополоски.
        case failed(String)
        /// Только точные нули дольше `silenceLimit` (нет права — tap молча отдаёт нули) — псевдополоски до следующего трека.
        case silent
    }

    let feed: AudioLevelsFeed
    private let backend: AudioCaptureBackend
    private let queue = DispatchQueue(label: "SimpleIsland.media.audiotap", qos: .utility)

    private(set) var state: State = .idle
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var info: AudioCaptureInfo?
    private var runningTarget: AudioTapTarget?
    private var generation = 0
    private var graceWork: DispatchWorkItem?
    /// Спрос пропал (компакт ↔ вкладка, перерисовка) — подождать столько, прежде чем рвать tap.
    var stopGrace: TimeInterval = 1.5
    var silenceLimit: Double = 4
    /// Самотест: операции заглушки — сразу, без очереди и задержек.
    var synchronous = false

    var enabled = false { didSet { if enabled != oldValue { if enabled { resetFailure() }; update() } } }
    var playing = false { didSet { if playing != oldValue { if playing { resetFailure() }; update() } } }
    var asleep = false { didSet { if asleep != oldValue { update() } } }
    var target: AudioTapTarget? { didSet { if target != oldValue { update() } } }
    private(set) var demand = false

    init(feed: AudioLevelsFeed, backend: AudioCaptureBackend) {
        self.feed = feed
        self.backend = backend
        demand = feed.hasDemand
        feed.onDemandChange = { [weak self] d in self?.demand = d; self?.update() }
    }

    var isActive: Bool { state == .starting || state == .running }
    var wants: Bool { enabled && playing && demand && !asleep && target != nil }

    /// Новый трек / пробуждение / смена устройства вывода — снять отметку сбоя/тишины.
    func resetFailure() {
        switch state {
        case .failed, .silent: state = .idle
        default: break
        }
    }

    /// Устройство вывода сменилось: агрегат привязан к нему — пересоздать.
    func outputDeviceChanged() {
        resetFailure()
        if isActive { stopNow(); update() }
    }

    private var lastWantsLog = ""
    func update() {
        let w = "enabled=\(enabled) playing=\(playing) demand=\(demand) asleep=\(asleep) target=\(target != nil) state=\(state)"
        if w != lastWantsLog { lastWantsLog = w; NSLog("SimpleIsland media: захват: %@", w) }
        if wants {
            graceWork?.cancel(); graceWork = nil
            switch state {
            case .idle: start()
            case .starting, .running:
                if target != runningTarget { stopNow(); start() }
            case .failed, .silent: break
            }
            return
        }
        guard isActive else { return }
        if enabled && playing && !asleep && target != nil && !demand && stopGrace > 0 && !synchronous {
            // Только пропал спрос: переход компакт ↔ вкладка — не рвать tap сразу.
            guard graceWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.graceWork = nil
                    if !self.wants && self.isActive { self.stopNow() }
                }
            }
            graceWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + stopGrace, execute: w)
        } else {
            stopNow()
        }
    }

    /// Остановить и освободить сразу (пауза, сон, выключение, выход).
    func stopNow() {
        graceWork?.cancel(); graceWork = nil
        guard isActive else { return }
        generation += 1
        state = .idle
        runningTarget = nil
        info = nil
        stops += 1
        feed.setIdle()
        let b = backend
        if synchronous { b.stop() } else { queue.async { b.stop() } }
    }

    private func start() {
        guard let t = target else { return }
        generation += 1
        let g = generation
        state = .starting
        runningTarget = t
        starts += 1
        let delayBox = DelayBox()
        let ref = WeakController(self)
        let sink = AudioSampleSink { wide, compact, interval, silentSeconds, silent in
            let deliver: @Sendable () -> Void = {
                MainActor.assumeIsolated {
                    ref.value?.deliver(g, wide: wide, compact: compact, interval: interval, silentSeconds: silentSeconds, silent: silent)
                }
            }
            let d = delayBox.value
            if d > 0.01 { DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: deliver) } else { DispatchQueue.main.async(execute: deliver) }
        }
        let b = backend
        let work: @Sendable () -> Void = {
            let result: Result<AudioCaptureInfo, Error> = Result { try b.start(target: t, sink: sink) }
            if case .success(let i) = result { delayBox.value = i.displayDelay }
            let finish: @Sendable () -> Void = { MainActor.assumeIsolated { self.started(g, result) } }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
        }
        if synchronous { work() } else { queue.async(execute: work) }
    }

    private func started(_ g: Int, _ r: Result<AudioCaptureInfo, Error>) {
        guard g == generation else {
            // Остановили, пока создавался: освободить то, что успело создаться.
            if case .success = r { let b = backend; if synchronous { b.stop() } else { queue.async { b.stop() } } }
            return
        }
        switch r {
        case .success(let i):
            info = i
            state = .running
            NSLog("SimpleIsland media: захват звука запущен")
        case .failure(let e):
            NSLog("SimpleIsland media: захват звука не запустился (%@) — псевдоэквалайзер", "\(e)")
            generation += 1
            state = .failed("\(e)")
            runningTarget = nil
            feed.setIdle()
            let b = backend
            if synchronous { b.stop() } else { queue.async { b.stop() } }
        }
    }

    /// Уровни с потока захвата (уже на главном). Самотест зовёт напрямую.
    func deliver(_ g: Int, wide: [Float], compact: [Float], interval: Double, silentSeconds: Double, silent: Bool) {
        guard g == generation, isActive else { return }
        if silentSeconds >= silenceLimit {
            // Нули слишком долго — права нет (или звук идёт мимо tap): освободить, показывать псевдополоски.
            stopNow()
            state = .silent
            NSLog("SimpleIsland media: захват звука — одни нули %.0f с (нет права «Запись системного звука»?) — псевдоэквалайзер", silentSeconds)
            return
        }
        // До первого настоящего звука нули не показываем (полоски лежали бы) — псевдоанимация, пока не пошло.
        if silent && !feed.isLive { return }
        if !feed.isLive { NSLog("SimpleIsland media: настоящий звук пошёл — полоски по звуку") }
        feed.publish(wide: wide, compact: compact, interval: interval)
    }

    /// Текущее поколение (самотест подаёт уровни «от захвата»).
    var currentGeneration: Int { generation }
}

private struct WeakController: @unchecked Sendable {
    weak var value: LiveAudioController?
    init(_ v: LiveAudioController) { value = v }
}

/// Задержка показа, известная после старта, — читается с потока захвата.
private final class DelayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Double = 0
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
