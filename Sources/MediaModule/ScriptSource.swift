import AppKit
import Foundation

/// Запасной источник: Музыка и Spotify через их уведомления и AppleScript (docs/TECH.md §1, «Фолбэк»).
/// * Уведомления (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`) — бесплатно и без прав:
///   название, исполнитель, альбом, длительность, играет ли.
/// * Позиция, обложка, лайк, управление — AppleScript, нужно разрешение «Автоматизация» (Apple Events).
///   Без него показываем то, что дали уведомления, и состояние «нужно разрешение».
/// * Не запущенное приложение скриптом не трогаем (иначе AppleScript его запустит). Опроса нет.
@MainActor
final class ScriptSource {
    var onUpdate: ((NowPlaying?) -> Void)?
    var onArtwork: ((String, Data) -> Void)?
    /// bundleId → нужно ли разрешение (true — отказано или ещё не спрашивали).
    var onPermission: ((String, Bool) -> Void)?
    /// Музыка: лайк текущего трека (nil — неизвестно).
    var onLiked: ((Bool?) -> Void)?
    /// Следующий трек (bundleId, ключ текущего трека, название следующего; nil — неизвестен). Музыка: только без
    /// перемешивания и повтора одной песни — по порядку `current playlist`. Очередь «Далее» (Up Next) AppleScript
    /// не видна — если в неё что-то добавлено, подпись может не совпасть. Spotify очередь не отдаёт — всегда nil.
    /// Спрашивается отдельным скриптом (`musicNextScript`, поиск по плейлисту) — раз на трек и при открытии вкладки
    /// (`refreshNext`: перемешивание/повтор могли переключить без смены трека), а не на каждое событие Музыки.
    var onNext: ((String, String, String?) -> Void)?
    /// Для какого трека (bundle → trackKey) уже спрашивали «Далее».
    private var nextKeys: [String: String] = [:]
    /// Сколько раз запускали скрипт «Далее» (самотест: не на каждое событие).
    private(set) var nextLoads = 0
    /// Самотест: вместо AppleScript (bundle, trackKey).
    var nextLoaderForTest: ((String, String) -> Void)?

    private(set) var apps: [String] = []
    private var states: [String: NowPlaying] = [:]
    private var updatedAt: [String: Date] = [:]
    private var artworkKeys: [String: String] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false

    /// Весь AppleScript (NSAppleScript, AEDeterminePermission…) — строго в одном своём потоке с run loop:
    /// NSAppleScript не потокобезопасен, а последовательная очередь GCD может менять потоки. Главный поток не
    /// годится — ответ зависшего плеера ждётся до 2 мин. В покое поток спит в run loop без таймеров.
    nonisolated private static let queue = ScriptThread(name: "simpleisland.media.applescript")

    /// Выполнить на потоке AppleScript (вкладки браузера для превью YouTube).
    nonisolated static func perform(_ block: @escaping @Sendable () -> Void) { queue.async(block) }

    func start(apps: [String]) {
        stop()
        self.apps = apps
        running = true
        let dnc = DistributedNotificationCenter.default()
        let names = [(MediaApps.music, "com.apple.Music.playerInfo"),
                     (MediaApps.spotify, "com.spotify.client.PlaybackStateChanged")]
        for (bundle, name) in names where apps.contains(bundle) {
            let o = dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = UncheckedBox(note.userInfo ?? [:])
                MainActor.assumeIsolated { self?.handleNotification(bundle: bundle, info: info.value) }
            }
            observers.append((dnc, o))
        }
        let wnc = NSWorkspace.shared.notificationCenter
        let o = wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundle, self.apps.contains(bundle) else { return }
                self.states[bundle] = nil
                self.publish()
            }
        }
        observers.append((wnc, o))
        for b in apps where Self.isRunning(b) { refresh(b) }
    }

    func stop() {
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
        running = false
        states = [:]
        // Иначе после повторного start() тот же трек остался бы без обложки: ключ совпал бы, загрузки не было бы.
        artworkKeys = [:]
        nextKeys = [:]
    }

    static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // MARK: Разрешение «Автоматизация»

    /// noErr — можно; -1743 — запрещено; -1744 — ещё не спрашивали; -600 — приложение не запущено.
    nonisolated static func automationStatus(_ bundleId: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    /// Спросить разрешение (системный диалог). Если уже запрещено — открыть раздел Системных настроек.
    static func requestAutomation(_ bundleId: String, completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let st = automationStatus(bundleId, ask: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if st == noErr { completion(true); return }
                    if st == OSStatus(errAEEventNotPermitted) { openAutomationSettings() }
                    completion(false)
                }
            }
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Чтение

    private func handleNotification(bundle: String, info: [AnyHashable: Any]) {
        guard running else { return }
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            states[bundle] = nil
            publish()
            return
        }
        var n = states[bundle] ?? NowPlaying(title: "")
        let name = (info["Name"] as? String) ?? ""
        if !name.isEmpty {
            let changed = name != n.title || (info["Artist"] as? String ?? "") != n.artist
            n.title = name
            n.artist = (info["Artist"] as? String) ?? ""
            n.album = (info["Album"] as? String) ?? ""
            if changed { n.elapsed = 0; n.timestamp = Date(); n.artworkId = nil; n.badge = nil; n.liveFlag = false }
        }
        let ms = (info["Total Time"] as? NSNumber) ?? (info["Duration"] as? NSNumber)
        if let ms { n.duration = ms.doubleValue / 1000; if n.duration > 0 { n.liveFlag = false } }
        if let pos = info["Playback Position"] as? NSNumber { n.elapsed = pos.doubleValue; n.timestamp = Date() }
        else if n.isPlaying != (state == "Playing") { n.elapsed = n.position(); n.timestamp = Date() }
        n.isPlaying = state == "Playing"
        n.rate = 1
        n.bundleId = bundle
        n.appName = appDisplayName(bundleId: bundle, pid: nil)
        n.viaScript = true
        if n.title.isEmpty { return }
        states[bundle] = n
        updatedAt[bundle] = Date()
        publish()
        refresh(bundle)
    }

    /// Дочитать позицию/обложку AppleScript-ом (только если приложение запущено и разрешение уже есть).
    func refresh(_ bundle: String) {
        guard running, Self.isRunning(bundle) else { return }
        Self.queue.async { [weak self] in
            let st = Self.automationStatus(bundle, ask: false)
            guard st == noErr else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onPermission?(bundle, st != OSStatus(procNotFound)) } }
                return
            }
            let source = bundle == MediaApps.music ? Self.musicReadScript : Self.spotifyReadScript
            // Момент замера `player position` — середина вызова, а не приход ответа на главный поток: под нагрузкой
            // AppleScript и переход на главную очередь занимают сотни мс, и позиция отставала бы на столько же.
            let t0 = Date()
            let result = Self.run(source)
            let sampled = t0.addingTimeInterval(Date().timeIntervalSince(t0) / 2)
            let parsed = result.descriptor.map { Self.parseList($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onPermission?(bundle, result.errorNumber == -1743)
                    if let parsed { self.apply(bundle: bundle, fields: parsed, sampledAt: sampled) }
                }
            }
        }
    }

    private func apply(bundle: String, fields: [String], sampledAt: Date = Date()) {
        guard running else { return }
        guard let state = fields.first, state != "stopped", fields.count >= 6 else {
            states[bundle] = nil; publish(); return
        }
        var n = states[bundle] ?? NowPlaying(title: "")
        n.title = fields[1]; n.artist = fields[2]; n.album = fields[3]
        let dur = Double(fields[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        n.duration = bundle == MediaApps.spotify ? dur / 1000 : dur
        // `duration of current track` = missing value — радиостанция / URL-трек: настоящий поток.
        n.liveFlag = n.duration <= 0 && fields[4].trimmingCharacters(in: .whitespaces) == "missing value"
        n.elapsed = Double(fields[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        n.timestamp = sampledAt
        n.isPlaying = state == "playing"
        n.rate = 1
        n.bundleId = bundle
        n.appName = appDisplayName(bundleId: bundle, pid: nil)
        n.viaScript = true
        if bundle == MediaApps.music {
            let liked = fields.count > 6 ? fields[6] : ""
            onLiked?(liked == "true" ? true : liked == "false" ? false : nil)
            let kind = fields.count > 7 ? fields[7].lowercased() : ""
            n.badge = kind.contains("lossless") ? "Lossless" : nil
        }
        guard !n.title.isEmpty else { return }
        let artKey = "\(bundle)|\(n.trackKey)"
        n.artworkId = artworkKeys[bundle] == artKey ? n.artworkId : nil
        states[bundle] = n
        updatedAt[bundle] = Date()
        publish()
        // После publish: модель уже знает этот трек и примет «Далее» для него. Раз на трек — не на паузу/игру.
        if bundle == MediaApps.music, nextKeys[bundle] != n.trackKey { loadNext(bundle: bundle) }
        if artworkKeys[bundle] != artKey {
            artworkKeys[bundle] = artKey
            loadArtwork(bundle: bundle, key: artKey, spotifyURL: bundle == MediaApps.spotify && fields.count > 6 ? fields[6] : nil)
        }
    }

    /// Перечитать «Далее» для текущего трека (вкладка открылась: перемешивание/повтор могли переключить без смены
    /// трека, а Музыка об этом не сообщает).
    func refreshNext() {
        guard running, apps.contains(MediaApps.music), states[MediaApps.music] != nil else { return }
        loadNext(bundle: MediaApps.music)
    }

    /// Прочитать обложку текущего трека заново (модель её потеряла или не получила): забыть, что уже загружали, и
    /// дочитать — `apply` запустит `loadArtwork`. Частоту ограничивает модель (`MediaModel.requestArtwork`).
    func reloadArtwork(_ bundle: String) {
        guard running else { return }
        artworkKeys[bundle] = nil
        artworkReloads += 1
        refresh(bundle)
    }
    private(set) var artworkReloads = 0

    /// Забыть, для каких треков спрашивали «Далее» (модель: сменился показанный трек — спросить заново).
    func forgetNext() { nextKeys = [:] }

    private func loadNext(bundle: String) {
        guard let n = states[bundle] else { return }
        let key = n.trackKey, title = n.title
        nextKeys[bundle] = key
        nextLoads += 1
        if let t = nextLoaderForTest { t(bundle, key); return }
        guard Self.isRunning(bundle) else { return }   // скрипт не должен запускать Музыку
        Self.queue.async { [weak self] in
            let r = Self.run(Self.musicNextScript)
            let f = r.descriptor.map { Self.parseList($0) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Ответ — про тот трек, для которого спрашивали (название текущего — первым полем).
                    guard let self, self.states[bundle]?.trackKey == key, f.count >= 2, f[0] == title else { return }
                    self.onNext?(bundle, key, Self.parseNext(f[1]))
                }
            }
        }
    }

    /// Самотест: строка AppleScript-чтения, как от `refresh` (без Музыки).
    func simulateRead(bundle: String, fields: [String]) {
        running = true
        if !apps.contains(bundle) { apps.append(bundle) }
        apply(bundle: bundle, fields: fields)
    }

    nonisolated static let artworkSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    private func loadArtwork(bundle: String, key: String, spotifyURL: String?) {
        let id = "script-" + String(UInt64(bitPattern: Int64(key.hashValue)), radix: 16)
        if let s = spotifyURL, let url = URL(string: s), url.scheme == "https" {
            // Без дискового кеша (`URLSession.shared` складывал обложки в Caches/…/Cache.db).
            Self.artworkSession.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, !data.isEmpty else { return }
                let box = UncheckedBox(data)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliverArtwork(bundle: bundle, key: key, id: id, data: box.value) } }
            }.resume()
            return
        }
        guard bundle == MediaApps.music else { return }
        Self.queue.async { [weak self] in
            let r = Self.run("tell application \"Music\" to get raw data of artwork 1 of current track")
            guard let data = r.descriptor?.data, !data.isEmpty else { return }
            let box = UncheckedBox(data)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliverArtwork(bundle: bundle, key: key, id: id, data: box.value) } }
        }
    }

    private func deliverArtwork(bundle: String, key: String, id: String, data: Data) {
        guard artworkKeys[bundle] == key, var n = states[bundle] else { return }
        onArtwork?(id, data)
        n.artworkId = id
        states[bundle] = n
        publish()
    }

    /// Что показать: играющее; иначе — обновлённое последним.
    private func publish() {
        let best = states.values.filter { !$0.title.isEmpty }.sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            return (updatedAt[a.bundleId ?? ""] ?? .distantPast) > (updatedAt[b.bundleId ?? ""] ?? .distantPast)
        }.first
        onUpdate?(best)
    }

    // MARK: Команды

    /// `fastForward`/`rewind`/`resume` — только Музыка (удержание ⏭/⏮); `step` — сдвиг позиции на ± с (Spotify).
    enum Command: Equatable { case toggle, play, pause, next, prev, seek(Double), like, fastForward, rewind, resume, step(Double), reveal }

    func send(_ c: Command, to bundle: String) {
        guard Self.isRunning(bundle) else { return }
        let app = bundle == MediaApps.music ? "Music" : "Spotify"
        let body: String
        switch c {
        case .toggle: body = "playpause"
        case .play: body = "play"
        case .pause: body = "pause"
        case .next: body = "next track"
        case .prev: body = "previous track"
        case .seek(let t): body = "set player position to \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), t))"
        case .fastForward, .rewind, .resume:
            guard bundle == MediaApps.music else { return }
            body = c == .fastForward ? "fast forward" : (c == .rewind ? "rewind" : "resume")
        case .step(let d):
            body = "set player position to (player position \(d < 0 ? "-" : "+") \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), abs(d))))"
        case .reveal:
            // Показать играющий трек в его приложении (клик по обложке, 16.11).
            body = bundle == MediaApps.music ? "activate\nreveal current track" : "activate"
        case .like:
            guard bundle == MediaApps.music else { return }
            body = """
            try
                set favorited of current track to not (favorited of current track)
            on error
                set loved of current track to not (loved of current track)
            end try
            """
        }
        let source = "tell application \"\(app)\"\n\(body)\nend tell"
        Self.queue.async { [weak self] in
            let r = Self.run(source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if r.errorNumber == -1743 || r.errorNumber == -1744 { self.onPermission?(bundle, true) }
                    self.refresh(bundle)
                }
            }
        }
    }

    // MARK: AppleScript

    nonisolated static let musicReadScript = """
    tell application "Music"
        set pst to player state as string
        if pst is "stopped" then return {pst}
        set t to current track
        set fav to ""
        try
            set fav to (favorited of t) as string
        on error
            try
                set fav to (loved of t) as string
            end try
        end try
        set k to ""
        try
            set k to kind of t
        end try
        return {pst, name of t, artist of t, album of t, (duration of t) as string, (player position) as string, fav, k}
    end tell
    """

    /// «Далее» Музыки: {название текущего, название следующего}; при перемешивании и повторе одной песни —
    /// пусто (порядок неизвестен). Поиск по плейлисту (`whose`) — отдельно от чтения состояния: раз на трек.
    nonisolated static let musicNextScript = """
    tell application "Music"
        if player state is stopped then return {"", ""}
        set t to current track
        set nx to ""
        try
            if (shuffle enabled) is false and ((song repeat) as string) is not "one" then
                set pl to current playlist
                set tid to persistent ID of t
                set i to index of (first track of pl whose persistent ID is tid)
                set c to count of tracks of pl
                if i < c then
                    set nx to name of track (i + 1) of pl
                else if ((song repeat) as string) is "all" and c > 1 then
                    set nx to name of track 1 of pl
                end if
            end if
        end try
        return {name of t, nx}
    end tell
    """

    /// Поле «следующий трек» из ответа Музыки: пусто — неизвестно.
    nonisolated static func parseNext(_ field: String) -> String? {
        let t = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    nonisolated static let spotifyReadScript = """
    tell application "Spotify"
        set pst to player state as string
        if pst is "stopped" then return {pst}
        set t to current track
        return {pst, name of t, artist of t, album of t, (duration of t) as string, (player position) as string, artwork url of t}
    end tell
    """

    struct ScriptResult: @unchecked Sendable {
        var descriptor: NSAppleEventDescriptor?
        var errorNumber: Int?
    }

    /// Опора позиции Музыки. `player position` у Музыки обновляется ступеньками раз в ~1,02 с (замер 16.11: 40 чтений
    /// по 0,25 с — значение стоит и прыгает на 1,024), поэтому одно чтение отстаёт на 0…1 с. Ловим ступеньку: читаем
    /// заранее скомпилированный `{player position, name of current track}` каждые 60 мс (не держа поток AppleScript),
    /// пока значение не сменится; момент смены — между двумя чтениями (±40 мс), позиция в нём — новое значение.
    /// Чтение дольше `maxPositionSpan` или нет смены за 1,6 с — без результата. Только чтение.
    nonisolated(unsafe) private static var positionScript: NSAppleScript?
    nonisolated static let maxPositionSpan: TimeInterval = 0.08
    nonisolated static let positionPollInterval: TimeInterval = 0.06

    struct PositionRead: Sendable { var pos: Double; var mid: Date; var span: TimeInterval; var title: String }

    /// Одно чтение позиции (на потоке AppleScript).
    nonisolated private static func readPosition() -> PositionRead? {
        if positionScript == nil {
            let sc = NSAppleScript(source: "tell application \"Music\" to {player position, name of current track}")
            var err: NSDictionary?
            if sc?.compileAndReturnError(&err) == true { positionScript = sc }
        }
        guard let sc = positionScript else { return nil }
        var err: NSDictionary?
        let t0 = Date()
        let d = sc.executeAndReturnError(&err)
        let span = Date().timeIntervalSince(t0)
        guard err == nil else { return nil }
        let f = parseList(d)
        guard f.count >= 2, let pos = Double(f[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return PositionRead(pos: pos, mid: t0.addingTimeInterval(span / 2), span: span, title: f[1])
    }

    /// Ступенька между двумя чтениями того же трека: позиция — новое значение, момент — между серединами чтений.
    /// Без смены, другой трек, прыжок назад или больше 1,5 с (перемотка) — nil.
    nonisolated static func step(prev p: PositionRead, cur r: PositionRead) -> (pos: Double, at: Date)? {
        guard r.title == p.title, r.pos > p.pos, r.pos - p.pos < 1.5, r.mid > p.mid else { return nil }
        return (r.pos, Date(timeIntervalSince1970: (p.mid.timeIntervalSince1970 + r.mid.timeIntervalSince1970) / 2))
    }

    /// Найти ступеньку `player position`: (позиция, момент, название) или nil.
    func samplePosition(_ bundle: String, completion: @escaping @MainActor (_ position: Double, _ at: Date, _ title: String) -> Void,
                        failed: @escaping @MainActor () -> Void = {}) {
        guard running, bundle == MediaApps.music, Self.isRunning(bundle) else { return }
        let start = Date()
        @Sendable func fail() { DispatchQueue.main.async { MainActor.assumeIsolated { failed() } } }
        @Sendable func step(_ prev: PositionRead?) {
            Self.queue.async {
                guard Self.automationStatus(bundle, ask: false) == noErr, let r = Self.readPosition(),
                      r.span <= Self.maxPositionSpan else { fail(); return }
                if let p = prev, r.title == p.title, r.pos != p.pos {
                    guard let st = Self.step(prev: p, cur: r) else { fail(); return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(st.pos, st.at, r.title) } }
                    return
                }
                guard Date().timeIntervalSince(start) < 1.6 else { fail(); return }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.positionPollInterval) { step(r) }
            }
        }
        step(nil)
    }

    nonisolated static func run(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else { return ScriptResult(descriptor: nil, errorNumber: -1) }
        var err: NSDictionary?
        let d = script.executeAndReturnError(&err)
        if let err {
            return ScriptResult(descriptor: nil, errorNumber: (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1)
        }
        return ScriptResult(descriptor: d, errorNumber: nil)
    }

    nonisolated static func parseList(_ d: NSAppleEventDescriptor) -> [String] {
        guard d.numberOfItems > 0 else { return [d.stringValue ?? ""] }
        return (1...d.numberOfItems).map { d.atIndex($0)?.stringValue ?? "" }
    }
}

/// Поток с собственным run loop для AppleScript: блоки выполняются по очереди, всегда в этом потоке.
final class ScriptThread: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInitiated
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // Порт без событий держит run loop открытым; в покое поток спит, не просыпаясь.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true { autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) } }
    }

    func async(_ block: @escaping @Sendable () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    var isCurrent: Bool { Thread.current === self }
}
