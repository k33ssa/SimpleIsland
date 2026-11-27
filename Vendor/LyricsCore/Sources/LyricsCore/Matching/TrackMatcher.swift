import Foundation

/// Оценка совпадения запроса с кандидатом провайдера.
public struct MatchEvaluation: Sendable, Equatable {
    public var score: Double
    public var title: Double
    public var artist: Double
    /// `nil`, если у одной из сторон нет длительности.
    public var duration: Double?
    public var album: Double?
    public var versionPenalty: Double
    /// Значимые теги, которые есть только у одной из сторон.
    public var versionMismatch: Set<VersionTag>
    public var isrcMatch: Bool
    public var accepted: Bool
    public var rejectReason: String?
    /// Расхождение длительностей в секундах (`nil`, если у одной из сторон её нет).
    public var durationDelta: TimeInterval? = nil
}

/// Разбор кандидатов на принятых, «почти совпадения» и отвергнутых — с причинами.
public struct MatchTriage: Sendable {
    public typealias Entry = (candidate: TrackCandidate, evaluation: MatchEvaluation)
    public var accepted: [Entry] = []
    /// Не прошли порог, но то же название и исполнитель, а длительность отличается в допустимых для near-miss пределах.
    public var nearMisses: [(candidate: TrackCandidate, evaluation: MatchEvaluation, reason: String)] = []
    public var total = 0
    public var rejectedByDuration = 0
    public var rejectedByTitleOrArtist = 0
    public var rejectedOther = 0

    /// «кандидатов: 5, отвергнуты по длительности: 2, по названию/исполнителю: 3».
    public var summary: String {
        var parts = ["кандидатов: \(total)"]
        if !accepted.isEmpty { parts.append("принято: \(accepted.count)") }
        if rejectedByDuration > 0 { parts.append("отвергнуты по длительности: \(rejectedByDuration)") }
        if rejectedByTitleOrArtist > 0 { parts.append("по названию/исполнителю: \(rejectedByTitleOrArtist)") }
        if rejectedOther > 0 { parts.append("по низкой уверенности: \(rejectedOther)") }
        if !nearMisses.isEmpty { parts.append("почти совпадений: \(nearMisses.count)") }
        return parts.joined(separator: ", ")
    }
}

/// Сопоставление трека: нормализация, допуск длительности, score и отказ при низкой уверенности.
public struct TrackMatcher: Sendable {
    public struct Config: Sendable {
        /// В пределах допуска длительность считается совпавшей.
        public var durationTolerance: TimeInterval = 2.5
        /// Дальше этого расхождения кандидат отвергается (это другая запись).
        public var durationHardLimit: TimeInterval = 8
        public var minScore: Double = 0.74
        /// Порог выше, когда длительности нет и проверить версию нечем.
        public var minScoreWithoutDuration: Double = 0.82
        /// 0.62 → 0.7 (15.11.2026): «love» ~ «love story» (0.66) проходило по названию.
        public var minTitle: Double = 0.7
        /// 0.45 → 0.6 (15.11.2026): «drake» ~ «blake» (0.6 по Левенштейну) проходило как тот же исполнитель.
        /// Разные написания одного имени (кириллица/латиница) сравниваются через `TextNormalizer.latinSkeleton`.
        public var minArtist: Double = 0.62
        /// Near-miss: длительность может отличаться не более чем на столько секунд…
        public var nearMissDurationSeconds: TimeInterval = 40
        /// …или не более чем на такую долю длительности запроса (достаточно любого из двух условий).
        public var nearMissDurationRatio: Double = 0.25
        /// Near-miss: нормализованное название и исполнитель должны совпасть не хуже этого.
        public var nearMissMinTitle: Double = 0.9
        public var nearMissMinArtist: Double = 0.8
        public var significantVersionPenalty: Double = 0.22
        public var minorVersionPenalty: Double = 0.015
        public init() {}
        public init(durationTolerance: TimeInterval, durationHardLimit: TimeInterval) {
            self.durationTolerance = durationTolerance
            self.durationHardLimit = durationHardLimit
        }
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    public func evaluate(_ query: TrackQuery, _ cand: TrackCandidate) -> MatchEvaluation {
        // 1. ISRC — сильнейший сигнал
        if let q = query.isrc, let c = cand.isrc, q == c {
            return MatchEvaluation(score: 1, title: 1, artist: 1, duration: nil, album: nil, versionPenalty: 0,
                                   versionMismatch: [], isrcMatch: true, accepted: true, rejectReason: nil)
        }
        let qt = TextNormalizer.parseTitle(query.title)
        let ct = TextNormalizer.parseTitle(cand.title)

        // 2. название
        var titleScore = TextNormalizer.similarity(qt.base, ct.base)
        // запасной вариант: сравнение без вырезаний (если разбор унёс лишнее)
        titleScore = max(titleScore, TextNormalizer.similarity(TextNormalizer.fold(query.title), TextNormalizer.fold(cand.title)))

        // 3. исполнители: в запросе — основной + приглашённые из названия; у кандидата — то же
        var qArtists = TextNormalizer.splitArtists(query.artist)
        for f in qt.featured where !qArtists.contains(f) { qArtists.append(f) }
        var cArtists = cand.artists.flatMap { TextNormalizer.splitArtists($0) }
        for f in ct.featured where !cArtists.contains(f) { cArtists.append(f) }
        let artistScore = artistSimilarity(qArtists, cArtists,
                                           qWhole: TextNormalizer.fold(query.artist),
                                           cWhole: TextNormalizer.fold(cand.artists.joined(separator: " ")))

        // 4. длительность
        var durScore: Double?
        var hardFail = false
        if let qd = query.duration, let cd = cand.duration {
            let delta = abs(qd - cd)
            if delta <= config.durationTolerance {
                durScore = 1 - 0.1 * (delta / max(config.durationTolerance, 0.001))
            } else if delta <= config.durationHardLimit {
                let span = config.durationHardLimit - config.durationTolerance
                durScore = 0.9 * (1 - (delta - config.durationTolerance) / max(span, 0.001))
            } else {
                durScore = 0
                hardFail = true
            }
        }

        // 5. альбом (слабый сигнал)
        var albumScore: Double?
        if let qa = query.album, let ca = cand.album, !qa.isEmpty, !ca.isEmpty {
            let a = TextNormalizer.parseTitle(qa).base, b = TextNormalizer.parseTitle(ca).base
            albumScore = TextNormalizer.similarity(a, b)
        }

        // 6. версия: значимые теги только с одной стороны — штраф; второстепенные — почти нет
        let mismatch = qt.tags.symmetricDifference(ct.tags)
        let significant = mismatch.filter { $0.isSignificant }
        let minor = mismatch.filter { !$0.isSignificant }
        let penalty = min(0.45, Double(significant.count) * config.significantVersionPenalty)
            + min(0.05, Double(minor.count) * config.minorVersionPenalty)

        // 7. итог
        var wsum = 0.45 + 0.30, acc = 0.45 * titleScore + 0.30 * artistScore
        if let d = durScore { wsum += 0.20; acc += 0.20 * d }
        if let a = albumScore { wsum += 0.05; acc += 0.05 * a }
        let score = max(0, min(1, acc / wsum - penalty))

        var accepted = true
        var reason: String?
        let threshold = durScore == nil ? config.minScoreWithoutDuration : config.minScore
        if hardFail { accepted = false; reason = "длительность отличается более чем на \(Int(config.durationHardLimit)) с" }
        else if titleScore < config.minTitle { accepted = false; reason = "название не совпадает" }
        else if !qArtists.isEmpty && !cArtists.isEmpty && artistScore < config.minArtist { accepted = false; reason = "исполнитель не совпадает" }
        // У кандидата нет исполнителя (пустое поле в базе) — проверить, что это та же песня, нечем, кроме длительности.
        else if !qArtists.isEmpty && cArtists.isEmpty && durScore == nil { accepted = false; reason = "исполнитель не совпадает (у записи его нет, длительности нет)" }
        else if score < threshold { accepted = false; reason = "низкая уверенность (\(String(format: "%.2f", score)))" }

        return MatchEvaluation(score: score, title: titleScore, artist: artistScore, duration: durScore, album: albumScore,
                               versionPenalty: penalty, versionMismatch: significant, isrcMatch: false,
                               accepted: accepted, rejectReason: reason,
                               durationDelta: (query.duration != nil && cand.duration != nil) ? abs(query.duration! - cand.duration!) : nil)
    }

    /// Причина, по которой отвергнутый кандидат всё же годится как «почти совпадение», либо `nil`.
    /// Правило: название и исполнитель совпадают после нормализации, отличия версии (live/remix/…) нет,
    /// а отвергнут он только из-за длительности, которая отличается не более чем на 40 с или 25 %.
    /// Такой текст нельзя подставлять как лучший (может быть другая версия записи), но можно предложить на выбор.
    public func nearMissReason(_ query: TrackQuery, _ ev: MatchEvaluation) -> String? {
        guard !ev.accepted, !ev.isrcMatch, let delta = ev.durationDelta, let qd = query.duration, delta > config.durationHardLimit else { return nil }
        guard ev.title >= config.nearMissMinTitle, ev.artist >= config.nearMissMinArtist, ev.versionMismatch.isEmpty else { return nil }
        guard delta <= config.nearMissDurationSeconds || delta <= config.nearMissDurationRatio * qd else { return nil }
        return "длительность отличается на \(Int(delta.rounded())) с"
    }

    /// Делит кандидатов на принятых (по убыванию score), почти совпадения и отвергнутых.
    public func triage(_ query: TrackQuery, _ candidates: [TrackCandidate]) -> MatchTriage {
        var t = MatchTriage()
        t.total = candidates.count
        for (cand, ev) in rank(query, candidates) {
            if ev.accepted { t.accepted.append((cand, ev)); continue }
            if let reason = nearMissReason(query, ev) {
                let full = cand.duration.map { "\(reason) (\(Int($0.rounded())) с вместо \(Int((query.duration ?? 0).rounded())) с)" } ?? reason
                t.nearMisses.append((cand, ev, full))
            } else if ev.durationDelta != nil, let r = ev.rejectReason, r.hasPrefix("длительность") {
                t.rejectedByDuration += 1
            } else if let r = ev.rejectReason, r.hasPrefix("название") || r.hasPrefix("исполнитель") {
                t.rejectedByTitleOrArtist += 1
            } else {
                t.rejectedOther += 1
            }
        }
        // near-miss: ближе по длительности — раньше
        t.nearMisses.sort { ($0.evaluation.durationDelta ?? 999) < ($1.evaluation.durationDelta ?? 999) }
        return t
    }

    /// Лучшие кандидаты по убыванию score (отвергнутые — в конце, с `accepted == false`).
    public func rank(_ query: TrackQuery, _ candidates: [TrackCandidate]) -> [(candidate: TrackCandidate, evaluation: MatchEvaluation)] {
        candidates.map { ($0, evaluate(query, $0)) }
            .sorted { a, b in
                if a.1.accepted != b.1.accepted { return a.1.accepted }
                if a.1.score != b.1.score { return a.1.score > b.1.score }
                return (a.0.duration.map { abs($0 - (query.duration ?? $0)) } ?? 99) < (b.0.duration.map { abs($0 - (query.duration ?? $0)) } ?? 99)
            }
    }

    // MARK: -

    private func artistSimilarity(_ q: [String], _ c: [String], qWhole: String, cWhole: String) -> Double {
        if q.isEmpty || c.isEmpty { return 0.5 }   // нет данных — нейтрально
        func fraction(_ a: [String], in b: [String]) -> Double {
            var sum = 0.0
            for x in a {
                let best = b.map { TextNormalizer.similarity(x, $0) }.max() ?? 0
                sum += best >= 0.85 ? 1 : best * 0.8
            }
            return sum / Double(a.count)
        }
        let whole = TextNormalizer.similarity(qWhole, cWhole)
        return max(whole, fraction(q, in: c), fraction(c, in: q) * 0.95)
    }
}
