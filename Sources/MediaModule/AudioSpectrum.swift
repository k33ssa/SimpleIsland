import Accelerate
import Foundation

/// Полосы эквалайзера из звука: моно-сумма каналов → кольцевой буфер 2048 отсчётов → окно Ханна → вещественное
/// БПФ (vDSP) → мощность в 24 полосах с логарифмическими краями 40 Гц…16 кГц (сумма мощности по бинам — «розовый»
/// шум даёт ровные полосы) и в 5 укрупнённых полосах компакта → дБ → автоусиление (AGC: опора = пик, быстро вверх,
/// медленно вниз, диапазон 48 дБ) → сглаживание (атака быстрая, спад ~0,25 с).
///
/// Живёт на одном потоке (поток ввода-вывода захвата): без блокировок и без выделения памяти на каждом буфере.
/// Расчёт — не чаще `maxRate` раз в секунду (≤ 20 Гц) и не чаще прихода буферов. Ничего не хранит, кроме последних
/// 2048 отсчётов, — звук не пишется никуда.
final class AudioSpectrum {
    static let fftSize = 2048
    static let wideCount = 24
    static let compactCount = 5
    static let lowHz = 40.0
    static let highHz = 16_000.0
    /// Группы широких полос для компакта: 40–150, 150–500, 500–1,6 к, 1,6–5,2 к, 5,2–16 кГц (~1,8 октавы).
    static let compactGroups: [Range<Int>] = [0..<5, 5..<10, 10..<15, 15..<20, 20..<24]

    let sampleRate: Double
    let maxRate: Double
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var ring: [Float]
    private var ringPos = 0
    /// Моно-сумма текущего буфера (растёт только при первом большом буфере).
    private var mono: [Float] = []
    private var filled = 0
    private var sinceLast = 0
    private let hop: Int
    private var window: [Float]
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    /// Края полос в бинах: полоса k — бины `edges[k]..<edges[k+1]`.
    private(set) var edges: [Int]
    private var widePow: [Float]
    private var compactPow: [Float]
    private var wideNorm: Normalizer
    private var compactNorm: Normalizer

    /// Последние уровни 0…1.
    private(set) var wide: [Float]
    private(set) var compact: [Float]
    /// Последний расчёт пришёлся на точные нули (нет права — tap отдаёт нули; или пауза в самом источнике).
    private(set) var lastWasSilent = true
    /// Сколько секунд подряд приходят точные нули.
    private(set) var silentSeconds: Double = 0
    /// Сколько расчётов сделано (самотест: ≤ 20 в секунду).
    private(set) var analyses = 0

    init(sampleRate: Double, maxRate: Double = 20) {
        self.sampleRate = max(8000, sampleRate)
        self.maxRate = maxRate
        let n = Self.fftSize
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        ring = Array(repeating: 0, count: n)
        hop = max(256, Int(self.sampleRate / maxRate))
        window = Array(repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        frame = Array(repeating: 0, count: n)
        real = Array(repeating: 0, count: n / 2)
        imag = Array(repeating: 0, count: n / 2)
        power = Array(repeating: 0, count: n / 2)
        edges = Self.bandEdges(sampleRate: self.sampleRate, fftSize: n, bands: Self.wideCount)
        widePow = Array(repeating: 0, count: Self.wideCount)
        compactPow = Array(repeating: 0, count: Self.compactCount)
        wideNorm = Normalizer(count: Self.wideCount)
        compactNorm = Normalizer(count: Self.compactCount)
        wide = Array(repeating: 0, count: Self.wideCount)
        compact = Array(repeating: 0, count: Self.compactCount)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Края полос (в бинах), логарифмически от `lowHz` до `highHz`; каждая полоса — хотя бы один бин, края растут.
    static func bandEdges(sampleRate: Double, fftSize: Int, bands: Int) -> [Int] {
        let binHz = sampleRate / Double(fftSize)
        let top = min(highHz, sampleRate / 2 * 0.95)
        var e: [Int] = []
        for k in 0...bands {
            let f = lowHz * pow(top / lowHz, Double(k) / Double(bands))
            var b = Int((f / binHz).rounded())
            b = max(1, min(fftSize / 2 - 1, b))
            if let last = e.last, b <= last { b = min(fftSize / 2, last + 1) }
            e.append(b)
        }
        return e
    }

    /// Центр полосы, Гц (самотест).
    func centerHz(ofWideBand k: Int) -> Double {
        let binHz = sampleRate / Double(Self.fftSize)
        return sqrt(Double(edges[k]) * Double(edges[k + 1])) * binHz
    }

    /// Чередующиеся отсчёты (`channels` каналов). true — посчитаны новые уровни.
    @discardableResult
    func process(interleaved p: UnsafePointer<Float>, frames: Int, channels: Int) -> Bool {
        guard frames > 0, channels > 0 else { return false }
        mix(frames: frames, channels: (0..<channels).map { (p + $0, channels) })
        return advance(frames: frames)
    }

    /// Отдельные каналы (неперемежённый формат): `buffers[c]` — канал c.
    @discardableResult
    func process(planar buffers: [UnsafePointer<Float>], frames: Int) -> Bool {
        guard frames > 0, !buffers.isEmpty else { return false }
        mix(frames: frames, channels: buffers.map { ($0, 1) })
        return advance(frames: frames)
    }

    /// Моно-сумма каналов (vDSP, с шагом) → в кольцо (memcpy, с переносом через конец).
    private func mix(frames: Int, channels: [(UnsafePointer<Float>, Int)]) {
        if mono.count < frames { mono = Array(repeating: 0, count: frames) }
        var inv = 1 / Float(channels.count)
        let n = Self.fftSize
        mono.withUnsafeMutableBufferPointer { m in
            let mp = m.baseAddress!
            let len = vDSP_Length(frames)
            vDSP_vsmul(channels[0].0, vDSP_Stride(channels[0].1), &inv, mp, 1, len)
            for c in channels.dropFirst() {
                vDSP_vsma(c.0, vDSP_Stride(c.1), &inv, mp, 1, mp, 1, len)
            }
            // В кольцо — только последние n отсчётов.
            var src = mp
            var count = frames
            if count > n { src += count - n; count = n }
            ring.withUnsafeMutableBufferPointer { r in
                let first = min(count, n - ringPos)
                (r.baseAddress! + ringPos).update(from: src, count: first)
                if count > first { r.baseAddress!.update(from: src + first, count: count - first) }
            }
            ringPos = (ringPos + count) % n
        }
    }

    private func advance(frames: Int) -> Bool {
        filled = min(Self.fftSize, filled + frames)
        sinceLast += frames
        guard sinceLast >= hop else { return false }
        let dt = Double(sinceLast) / sampleRate
        sinceLast = 0
        analyze(dt: dt)
        return true
    }

    private func analyze(dt: Double) {
        analyses += 1
        let n = Self.fftSize
        // Кольцо → по порядку времени, с окном.
        ring.withUnsafeBufferPointer { r in
            frame.withUnsafeMutableBufferPointer { f in
                let tail = n - ringPos
                f.baseAddress!.update(from: r.baseAddress! + ringPos, count: tail)
                if ringPos > 0 { (f.baseAddress! + tail).update(from: r.baseAddress!, count: ringPos) }
            }
        }
        var peak: Float = 0
        vDSP_maxmgv(frame, 1, &peak, vDSP_Length(n))
        if peak == 0 {
            silentSeconds += dt
            lastWasSilent = true
        } else {
            silentSeconds = 0
            lastWasSilent = false
        }
        frame.withUnsafeMutableBufferPointer { f in
            vDSP_vmul(f.baseAddress!, 1, window, 1, f.baseAddress!, 1, vDSP_Length(n))
        }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Бин 0: в imag упакован Найквист — не нужен (полосы с 40 Гц).
                split.imagp[0] = 0
                power.withUnsafeMutableBufferPointer { pw in
                    vDSP_zvmags(&split, 1, pw.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        // Масштаб: zrip даёт 2× амплитуду; окно Ханна (норм.) — ещё ~½. Для полного синуса пик бина ~(n/2)² —
        // нормируем так, чтобы полномасштабный синус давал ~0 дБ.
        let scale = 1 / Float(n * n / 4)
        for k in 0..<Self.wideCount {
            var sum: Float = 0
            power.withUnsafeBufferPointer { pw in
                vDSP_sve(pw.baseAddress! + edges[k], 1, &sum, vDSP_Length(edges[k + 1] - edges[k]))
            }
            widePow[k] = sum * scale
        }
        for (g, r) in Self.compactGroups.enumerated() {
            var s: Float = 0
            for k in r { s += widePow[k] }
            compactPow[g] = s
        }
        let silent = lastWasSilent
        wideNorm.step(power: widePow, dt: dt, silent: silent, out: &wide)
        compactNorm.step(power: compactPow, dt: dt, silent: silent, out: &compact)
    }

    /// Автоусиление и сглаживание одного набора полос.
    struct Normalizer {
        /// Опорный уровень (пик), дБ: вверх — сразу, вниз — `refFallDbPerSec`.
        var ref: Float = -30
        var smooth: [Float]
        private var db: [Float]
        static let rangeDb: Float = 48
        static let refFallDbPerSec: Float = 6
        /// Ниже этого опора не опускается: тихий шум не раздувается до полной высоты.
        static let refFloorDb: Float = -50
        static let releaseSeconds: Double = 0.25
        static let attack: Float = 0.75

        init(count: Int) { smooth = Array(repeating: 0, count: count); db = Array(repeating: -200, count: count) }

        mutating func step(power: [Float], dt: Double, silent: Bool, out: inout [Float]) {
            var maxDb: Float = -200
            for i in power.indices {
                let d = 10 * log10(max(power[i], 1e-20))
                db[i] = d
                if d > maxDb { maxDb = d }
            }
            if maxDb > ref { ref = maxDb } else { ref = max(Self.refFloorDb, ref - Self.refFallDbPerSec * Float(dt)) }
            let rel = Float(1 - exp(-dt / Self.releaseSeconds))
            for i in power.indices {
                let target: Float = silent ? 0 : min(1, max(0, (db[i] - (ref - Self.rangeDb)) / Self.rangeDb))
                // Кривая: середина диапазона громче на глаз (полоски не «лежат» на средних уровнях).
                let shaped = target * target * (3 - 2 * target)
                let prev = smooth[i]
                smooth[i] = shaped > prev ? prev + (shaped - prev) * Self.attack : prev + (shaped - prev) * rel
                out[i] = smooth[i]
            }
        }
    }
}
