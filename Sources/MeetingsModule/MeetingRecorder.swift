import AVFoundation
import Foundation
import UniformTypeIdentifiers

// Запись встречи нативно. Как в веб-версии Sten (MediaRecorder, кусок каждые 2 с → POST /chunks), только формат —
// фрагментированный MP4 с AAC (так пишет Safari: `audio/mp4`, который фронтенд Sten тоже предлагает). Первый кусок —
// заголовок (init-сегмент) + первые 2 с, дальше — самостоятельные фрагменты moof+mdat: склейка всех кусков — обычный
// файл .mp4, его читают afinfo/ffprobe (проверено 16.11 на 10 с синуса). Та же склейка лежит на диске — запасной путь
// (POST /audio файлом), если куски не дошли.

/// Кодирует PCM (моно, Float32, `sampleRate`) в AAC и режет на фрагменты MP4 (HLS-профиль AVAssetWriter).
/// Потокобезопасен: всё — на своей очереди. `onSegment` — с потока AVAssetWriter (данные, это ли заголовок).
public final class FMP4Segmenter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    public let sampleRate: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private let queue = DispatchQueue(label: "local.simpleisland.meetings.segmenter", qos: .userInitiated)
    private var position: Int64 = 0
    private var finished = false
    private let onSegment: @Sendable (Data, Bool) -> Void
    /// Сколько буферов не принято (кодировщик не успевал) — для журнала/самотеста.
    public private(set) var dropped = 0

    public init(sampleRate: Double = 48000, segmentSeconds: Double = 2, bitRate: Int = 64000, realTime: Bool = true,
                onSegment: @escaping @Sendable (Data, Bool) -> Void) throws {
        self.sampleRate = sampleRate
        self.onSegment = onSegment
        writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1000)
        writer.initialSegmentStartTime = .zero
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = realTime
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard let fmt else { throw StenError.badResponse }
        format = fmt
        super.init()
        writer.delegate = self
        guard writer.canAdd(input) else { throw NSError(domain: "FMP4Segmenter", code: 1) }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "FMP4Segmenter", code: 2)
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Секунд звука принято.
    public var seconds: Double { queue.sync { Double(position) / sampleRate } }

    /// Отдать отсчёты (копируются).
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return }
            if !input.isReadyForMoreMediaData && !input.expectsMediaDataInRealTime {
                // Самотест (не реальное время): подождать кодировщик.
                var spins = 0
                while !input.isReadyForMoreMediaData && spins < 2000 { usleep(500); spins += 1 }
            }
            guard input.isReadyForMoreMediaData, let sb = makeBuffer(samples) else { dropped += 1; return }
            if input.append(sb) { position += Int64(samples.count) } else { dropped += 1 }
        }
    }

    /// Дописать последний фрагмент; `done` — после того, как он отдан в `onSegment` (с очереди писателя).
    public func finish(_ done: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard !finished else { done(nil); return }
            finished = true
            guard writer.status == .writing else { done(writer.error); return }
            input.markAsFinished()
            // `delegate` у AVAssetWriter — слабая ссылка: держим себя до конца, иначе владелец, отпустивший
            // кодировщик после stop, терял последний фрагмент (самотест 16.11: 4 с из 5). Плюс 0,3 с запаса на случай,
            // если делегат отдаёт фрагмент после колбэка finishWriting.
            writer.finishWriting { [self] in
                let err = writer.status == .completed ? nil : writer.error
                queue.asyncAfter(deadline: .now() + 0.3) { withExtendedLifetime(self) { done(err) } }
            }
        }
    }

    private func makeBuffer(_ samples: [Float]) -> CMSampleBuffer? {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let st = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                          offsetIntoDestination: 0, dataLength: bytes) }
        guard st == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(sampleRate)),
                                        decodeTimeStamp: .invalid)
        var size = 4
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format, sampleCount: samples.count, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                             sampleBufferOut: &sb)
        return sb
    }

    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                            segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        onSegment(segmentData, segmentType == .initialization)
    }
}

/// Микрофон → 48 кГц моно → `FMP4Segmenter`. Уровень — на главный поток ~10 раз в секунду (буфер 100 мс).
/// Смена устройства (подключили AirPods) — движок перезапускается с новым форматом, время записи непрерывное.
public final class MicRecorder: @unchecked Sendable {
    public static let sampleRate: Double = 48000
    private let engine = AVAudioEngine()
    private let segmenter: FMP4Segmenter
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicRecorder.sampleRate,
                                          channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var running = false
    /// Уровень 0…1 (главный поток).
    public var onLevel: (@MainActor (Float) -> Void)?
    /// Микрофон пропал / движок не перезапустился (главный поток).
    public var onFailure: (@MainActor (String) -> Void)?

    public init(segmenter: FMP4Segmenter) { self.segmenter = segmenter }

    public func start() throws {
        try installTapAndStart()
        running = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartAfterConfigChange()
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "MicRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Микрофон не найден"])
        }
        // Моно: берём первый канал (у микрофона он и есть), дальше — пересчёт частоты конвертером.
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1,
                                 interleaved: false)!
        lock.lock(); converter = AVAudioConverter(from: mono, to: outFormat); lock.unlock()
        let frames = AVAudioFrameCount(inFormat.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: frames, format: inFormat) { [weak self] buf, _ in
            self?.process(buf, monoFormat: mono)
        }
        engine.prepare()
        try engine.start()
    }

    private func restartAfterConfigChange() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try installTapAndStart() }
        catch {
            let msg = (error as NSError).localizedDescription
            MainActor.assumeIsolated { onFailure?("Микрофон пропал: \(msg)") }
        }
    }

    private func process(_ buf: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buf.frameLength) else { return }
        mono.frameLength = buf.frameLength
        mono.floatChannelData![0].update(from: ch[0], count: n)
        lock.lock(); let conv = converter; lock.unlock()
        guard let conv else { return }
        let ratio = outFormat.sampleRate / monoFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(n) * ratio) + 64)
        else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return mono
        }
        let m = Int(out.frameLength)
        guard m > 0, let p = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: p, count: m))
        segmenter.append(samples)
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(m)).squareRoot()
        // −50 дБ → 0, −10 дБ → 1.
        let db = 20 * log10(max(rms, 1e-6))
        let level = max(0, min(1, (db + 50) / 40))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onLevel?(level) }
        }
    }

    /// Остановить микрофон и дописать последний фрагмент.
    public func stop(_ done: @escaping @Sendable (Error?) -> Void) {
        running = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        segmenter.finish(done)
    }
}
