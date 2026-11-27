import AppKit
import IslandCore

/// Свой пресет эквалайзера (16.11, «добавлять свой режим, в котором меняем по частотам чёрточки»): 10 полос
/// Apple Music (32 Гц…16 кГц) и предусилитель, ±12 дБ. Хранится в настройках острова (`MediaPrefs.customEQ`) и
/// заводится в «Музыке» как обычный пресет (`make new EQ preset`) — переживает перезапуск «Музыки» и её сброс.
struct CustomEQPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var preamp: Double
    /// Ровно `bandCount` значений, дБ.
    var bands: [Double]

    static let bandCount = 10
    static let range: ClosedRange<Double> = -12...12
    /// Частоты полос «Музыки», Гц.
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    init(id: String = UUID().uuidString, name: String, preamp: Double = 0, bands: [Double] = Array(repeating: 0, count: 10)) {
        self.id = id; self.name = name; self.preamp = Self.clamp(preamp)
        self.bands = Self.normalized(bands)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        preamp = Self.clamp((try? c.decode(Double.self, forKey: .preamp)) ?? 0)
        bands = Self.normalized((try? c.decode([Double].self, forKey: .bands)) ?? [])
    }

    /// Значение по индексу ползунка: 0 — предусилитель, 1…10 — полосы.
    subscript(slider i: Int) -> Double {
        get { i == 0 ? preamp : bands[i - 1] }
        set { if i == 0 { preamp = Self.clamp(newValue) } else if (1...Self.bandCount).contains(i) { bands[i - 1] = Self.clamp(newValue) } }
    }

    static func clamp(_ v: Double) -> Double { v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : 0 }
    static func normalized(_ b: [Double]) -> [Double] {
        (0..<bandCount).map { $0 < b.count ? clamp(b[$0]) : 0 }
    }

    /// Шаг ползунка 0,5 дБ; около нуля (±0,4) — прилипает к 0.
    static func snapped(_ v: Double) -> Double {
        let c = clamp(v)
        if abs(c) < 0.4 { return 0 }
        return (c * 2).rounded() / 2
    }

    /// Положение ползунка по вертикали → дБ: `y` от верха дорожки высотой `h` (верх +12, низ −12).
    static func value(atY y: CGFloat, height h: CGFloat) -> Double {
        guard h > 0 else { return 0 }
        let t = Double(max(0, min(1, y / h)))
        return snapped(range.upperBound - t * (range.upperBound - range.lowerBound))
    }

    static func y(of v: Double, height h: CGFloat) -> CGFloat {
        CGFloat((range.upperBound - clamp(v)) / (range.upperBound - range.lowerBound)) * h
    }

    /// Подпись значения: «+3», «−4,5», «0» (минус — типографский).
    static func format(_ v: Double) -> String {
        let r = (v * 2).rounded() / 2
        if r == 0 { return "0" }
        let body = r == r.rounded() ? String(Int(abs(r))) : String(format: "%.1f", abs(r)).replacingOccurrences(of: ".", with: ",")
        return (r > 0 ? "+" : "−") + body
    }
}

/// Встроенный эквалайзер приложения «Музыка» через AppleScript (15.11, «а что делает-то эквалайзер»): вкл/выкл
/// (`EQ enabled`), текущий пресет (`current EQ preset`), список пресетов (`EQ presets`). У Spotify и браузеров
/// своего эквалайзера в AppleScript нет — вкладка говорит об этом прямо.
///
/// 16.11 — свои пресеты (`CustomEQPreset`): создаются/правятся/переименовываются/удаляются только свои (имена из
/// настроек острова); встроенные пресеты Apple только читаются (в AppleScript у всех `modifiable = true`, поэтому
/// «своё» — только то, что записано у нас). Правки полос копятся и уходят одним скриптом не чаще раза в `debounce`
/// (osascript дорогой), последняя правка не теряется: в скрипт идёт полное текущее состояние пресета, а конец
/// перетаскивания шлёт сразу (`flush`).
///
/// Всё AppleScript — на потоке `ScriptSource` (NSAppleScript не потокобезопасен, ответ плеера может ждаться долго).
/// Пока «Музыка» не запущена, скрипт не шлём: `tell application` её запустил бы. Опроса нет: чтение — при открытии
/// вкладки, смене трека и после своей команды.
@MainActor
final class MusicEqualizer: ObservableObject {
    enum Access: Equatable {
        /// Ещё не проверяли.
        case unknown
        /// «Музыка» не запущена — менять нечего.
        case notRunning
        /// Права «Автоматизация → Музыка» ещё не спрашивали.
        case needsPermission
        /// Запрещено — кнопка ведёт в Системные настройки.
        case denied
        case ready
    }

    /// Снимок состояния эквалайзера «Музыки».
    struct Snapshot: Equatable {
        var enabled: Bool
        var current: String?
        var presets: [String]
        /// Предусилитель и 10 полос текущего пресета (nil — не прочитали).
        var currentBands: [Double]? = nil
        /// «Настройка вручную» (Manual) — редактируемый пресет самой «Музыки» (его крутят в окне эквалайзера):
        /// имя по локали и полосы (предусилитель + 10).
        var manualName: String? = nil
        var manualBands: [Double]? = nil
    }

    /// id «Настройки вручную» в редакторе (не свой пресет: в настройках острова не хранится, имя не меняется).
    nonisolated static let manualId = "music-manual"
    /// Как «Музыка» называет ручной пресет в разных локалях.
    nonisolated static let manualNames: Set<String> = ["Manual", "Ручной", "Вручную", "Настройка вручную"]

    @Published private(set) var access: Access = .unknown
    /// «Музыка» отклонила последнюю команду эквалайзера (18.11: `set EQ enabled` → −10006): текст для виджета.
    /// Снимается первой успешной командой.
    @Published private(set) var refused: String?
    @Published private(set) var state: Snapshot?
    /// Пресет, выбранный кнопкой, пока «Музыка» не ответила (подсветка сразу, без ожидания).
    @Published private(set) var pending: String?
    /// Свои пресеты (порядок — как добавлены).
    @Published private(set) var customs: [CustomEQPreset] = []
    /// «Настройка вручную» «Музыки» — правится тем же редактором напрямую (16.11, «ищу полосы у Настройки вручную»).
    @Published private(set) var manual: CustomEQPreset?
    /// Открыт редактор этого своего пресета (id; nil — сетка пресетов). Здесь, а не в @State вью, — чтобы снимок
    /// мог показать редактор.
    @Published var editing: String?
    /// Полоса под курсором / в перетаскивании (0 — предусилитель): показывает значение в дБ.
    @Published var hotSlider: Int?

    /// Для снимков и самотеста: подменить ответ.
    var isMock = false
    /// Задержка отправки правок полос, с.
    var debounce: TimeInterval = 0.12
    /// Куда сохранять свои пресеты (модуль подставляет `MediaModel.prefs.customEQ`).
    var store: (load: () -> [CustomEQPreset], save: ([CustomEQPreset]) -> Void)? {
        didSet { if let s = store { customs = s.load() } }
    }
    /// Самотест: вместо AppleScript — сюда (скрипт целиком). nil — настоящий запуск.
    var scriptSink: ((String) -> Void)?
    /// Сколько скриптов правок ушло (самотест дебаунса).
    private(set) var syncCount = 0

    private var dirty: [String] = []   // id своих пресетов с неотправленными правками
    private var dirtySelect = false
    private var flushItem: DispatchWorkItem?
    private var inFlight = 0

    nonisolated static let bundleId = "com.apple.Music"   // MediaApps.music
    nonisolated static let separator = "\u{1F}"   // разделитель полей (Unit Separator), в названиях не встречается
    nonisolated static let sectionSeparator = "\u{1E}"   // Record Separator: пресеты | полосы текущего

    /// Скрипт чтения: «вкл» · текущий · пресеты через US, затем RS и «предусилитель;полоса1;…;полоса10» текущего.
    nonisolated static let readScript = """
        tell application id "com.apple.Music"
            set sep to (ASCII character 31)
            set en to EQ enabled
            set cur to ""
            set bs to ""
            try
                set p to current EQ preset
                set cur to name of p
                set bs to ((preamp of p) as text) & ";" & ((band 1 of p) as text) & ";" & ((band 2 of p) as text) & ";" & ((band 3 of p) as text) & ";" & ((band 4 of p) as text) & ";" & ((band 5 of p) as text) & ";" & ((band 6 of p) as text) & ";" & ((band 7 of p) as text) & ";" & ((band 8 of p) as text) & ";" & ((band 9 of p) as text) & ";" & ((band 10 of p) as text)
            end try
            set ms to ""
            try
                set m to EQ preset 1
                set ms to (name of m) & sep & ((preamp of m) as text) & ";" & ((band 1 of m) as text) & ";" & ((band 2 of m) as text) & ";" & ((band 3 of m) as text) & ";" & ((band 4 of m) as text) & ";" & ((band 5 of m) as text) & ";" & ((band 6 of m) as text) & ";" & ((band 7 of m) as text) & ";" & ((band 8 of m) as text) & ";" & ((band 9 of m) as text) & ";" & ((band 10 of m) as text)
            end try
            set ps to name of every EQ preset
            set AppleScript's text item delimiters to sep
            set out to (en as text) & sep & cur & sep & (ps as text) & (ASCII character 30) & bs & (ASCII character 30) & ms
            set AppleScript's text item delimiters to ""
            return out
        end tell
        """

    /// Разбор ответа `readScript`. nil — ответ не похож на наш (ошибка, пусто).
    nonisolated static func parse(_ s: String) -> Snapshot? {
        let sections = s.components(separatedBy: sectionSeparator)
        let parts = sections[0].components(separatedBy: separator)
        guard parts.count >= 2 else { return nil }
        let flag = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard flag == "true" || flag == "false" else { return nil }
        let cur = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let presets = parts.dropFirst(2).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let bands = sections.count > 1 ? parseBands(sections[1]) : nil
        var snap = Snapshot(enabled: flag == "true", current: cur.isEmpty ? nil : cur, presets: presets, currentBands: bands)
        // Третья секция: первый пресет «Музыки» (имя US полосы) — если это «Настройка вручную».
        if sections.count > 2 {
            let m = sections[2].components(separatedBy: separator)
            let name = m[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if m.count > 1, manualNames.contains(name), let b = parseBands(m[1]) { snap.manualName = name; snap.manualBands = b }
        }
        return snap
    }

    /// «0,0;1,04999;…» (AppleScript пишет числа по локали — запятая или точка) → 11 чисел или nil.
    nonisolated static func parseBands(_ s: String) -> [Double]? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ";")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
        return v.count == CustomEQPreset.bandCount + 1 ? v : nil
    }

    /// Строка AppleScript в кавычках (кавычки и обратная косая — экранируются).
    nonisolated static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Число для исходника AppleScript — всегда с точкой (литерал не зависит от локали).
    nonisolated static func number(_ v: Double) -> String {
        let r = (CustomEQPreset.clamp(v) * 100).rounded() / 100
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), r)
    }

    nonisolated static func selectScript(_ preset: String) -> String {
        """
        tell application id "com.apple.Music"
            set current EQ preset to EQ preset \(quoted(preset))
            set EQ enabled to true
        end tell
        """
    }

    nonisolated static func enableScript(_ on: Bool) -> String {
        "tell application id \"com.apple.Music\" to set EQ enabled to \(on ? "true" : "false")"
    }

    /// Свой пресет → «Музыка»: нет — создать со всеми полосами; есть — переписать все 11 значений (полное состояние,
    /// а не разница: потерянная по дороге правка следующей отправкой восстановится). `select` — сделать текущим и
    /// включить эквалайзер.
    nonisolated static func syncScript(_ p: CustomEQPreset, select: Bool) -> String {
        let q = quoted(p.name)
        let props = (["name:\(q)", "preamp:\(number(p.preamp))"]
                     + p.bands.enumerated().map { "band \($0.offset + 1):\(number($0.element))" }).joined(separator: ", ")
        let sets = (["set preamp of e to \(number(p.preamp))"]
                    + p.bands.enumerated().map { "set band \($0.offset + 1) of e to \(number($0.element))" })
            .map { "        " + $0 }.joined(separator: "\n")
        return """
        tell application id "com.apple.Music"
            if exists EQ preset \(q) then
                set e to EQ preset \(q)
        \(sets)
            else
                set e to make new EQ preset with properties {\(props)}
            end if
        \(select ? "    set current EQ preset to e\n    set EQ enabled to true" : "")
        end tell
        """
    }

    nonisolated static func renameScript(_ old: String, _ new: String) -> String {
        """
        tell application id "com.apple.Music"
            if exists EQ preset \(quoted(old)) then set name of EQ preset \(quoted(old)) to \(quoted(new))
        end tell
        """
    }

    /// Удалить свой пресет. Если он текущий — сначала текущим ставится первый пресет «Музыки» («Вручную»).
    nonisolated static func deleteScript(_ name: String) -> String {
        """
        tell application id "com.apple.Music"
            if exists EQ preset \(quoted(name)) then
                try
                    if name of current EQ preset is \(quoted(name)) then set current EQ preset to EQ preset 1
                end try
                delete EQ preset \(quoted(name))
            end if
        end tell
        """
    }

    /// Пресеты Apple по порядку для сетки: свои — не здесь (у них свой ряд), «Ручной» (Manual) — в конце.
    static func gridOrder(_ presets: [String], excluding own: Set<String> = []) -> [String] {
        let manual = manualNames
        let apple = presets.filter { !own.contains($0) }
        return apple.filter { !manual.contains($0) } + apple.filter { manual.contains($0) }
    }

    /// Свободное имя: «Свой», «Свой 2»… — не совпадает ни с пресетами «Музыки», ни со своими.
    static func uniqueName(_ base: String, taken: [String]) -> String {
        let t = Set(taken.map { $0.lowercased() })
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Свой" : base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains(b.lowercased()) { return b }
        var i = 2
        while t.contains("\(b) \(i)".lowercased()) { i += 1 }
        return "\(b) \(i)"
    }

    /// Подсвечен ли пресет: выбранный кнопкой (ждём ответа) или текущий у «Музыки» при включённом эквалайзере.
    func isSelected(_ preset: String) -> Bool {
        if let p = pending { return p == preset }
        guard let s = state, s.enabled else { return false }
        return s.current == preset
    }

    func custom(_ id: String) -> CustomEQPreset? { customs.first { $0.id == id } }
    /// Что можно править редактором: свой пресет или «Настройка вручную».
    func editable(_ id: String) -> CustomEQPreset? { id == Self.manualId ? manual : custom(id) }
    /// id редактируемого пресета по имени (свой или ручной «Музыки»); встроенные — nil.
    func editableId(name: String) -> String? {
        if let c = customs.first(where: { $0.name == name }) { return c.id }
        return manual?.name == name ? Self.manualId : nil
    }
    func isCustom(name: String) -> Bool { customs.contains { $0.name == name } }
    var customNames: Set<String> { Set(customs.map(\.name)) }

    // MARK: Действия

    /// Свои пресеты из настроек заново: `store` задаётся при создании модуля, а настройки «Медиа» читаются позже
    /// (`MediaModel.start`) — без этого после перезапуска острова ряд своих был бы пуст. Зовётся при открытии вкладки.
    func reloadCustoms() {
        guard !isMock, dirty.isEmpty, let s = store else { return }
        let l = s.load()
        if l != customs { customs = l }
    }

    /// Перечитать (при открытии вкладки, смене трека, после своей команды). Права не спрашивает.
    func refresh() {
        guard !isMock else { return }
        guard ScriptSource.isRunning(Self.bundleId) else { setAccess(.notRunning); return }
        ScriptSource.perform {
            let st = ScriptSource.automationStatus(Self.bundleId, ask: false)
            var snap: Snapshot?
            if st == noErr, let d = ScriptSource.run(Self.readScript).descriptor?.stringValue { snap = Self.parse(d) }
            let access: Access = st == noErr ? .ready
                : st == OSStatus(errAEEventNotPermitted) ? .denied
                : st == OSStatus(procNotFound) ? .notRunning : .needsPermission
            let box = UncheckedBox(snap)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.setAccess(access)
                    if let s = box.value { self.apply(s) }
                    if access == .ready, box.value != nil, self.inFlight == 0 { self.pending = nil }
                }
            }
        }
    }

    /// Новый снимок «Музыки». Если текущий — свой пресет и его полосы поменяли в самой «Музыке» (окно эквалайзера),
    /// правда — у «Музыки»: забрать её значения (только когда своих неотправленных правок нет).
    func apply(_ s: Snapshot) {
        if s != state { state = s }
        if !dirty.contains(Self.manualId), inFlight == 0 {
            let m = s.manualName.flatMap { n in s.manualBands.map { CustomEQPreset(id: Self.manualId, name: n, preamp: $0[0], bands: Array($0.dropFirst())) } }
            if m != manual { manual = m }
        }
        guard dirty.isEmpty, inFlight == 0, let cur = s.current, let b = s.currentBands,
              let i = customs.firstIndex(where: { $0.name == cur }) else { return }
        let fromMusic = CustomEQPreset(id: customs[i].id, name: cur, preamp: b[0], bands: Array(b.dropFirst()))
        if zip([fromMusic.preamp] + fromMusic.bands, [customs[i].preamp] + customs[i].bands).contains(where: { abs($0 - $1) > 0.05 }) {
            customs[i] = fromMusic
            saveCustoms()
        }
    }

    /// «Разрешить»: окно macOS, а если уже запрещено — раздел настроек и карточка «где включить» (ядро).
    func requestAccess() {
        Task { @MainActor [weak self] in
            let s = await Permissions.requestFromUser(.automation(bundleId: Self.bundleId), moduleId: "media")
            if s == .granted { self?.refresh() }
        }
    }

    func setEnabled(_ on: Bool) {
        if isMock { state?.enabled = on; send(Self.enableScript(on)); return }
        guard access == .ready else { return }
        state?.enabled = on
        run(Self.enableScript(on))
    }

    func select(_ preset: String) {
        if let c = customs.first(where: { $0.name == preset }) { selectCustom(c.id); return }
        if isMock { state?.current = preset; state?.enabled = true; send(Self.selectScript(preset)); return }
        guard access == .ready else { return }
        pending = preset
        run(Self.selectScript(preset))
    }

    // MARK: Свои пресеты

    /// «+ Свой»: новый пресет со значениями текущего пресета «Музыки» (если прочитаны), иначе ровный; сразу текущий.
    @discardableResult
    func addCustom(name: String = "Свой", from bands: [Double]? = nil) -> String? {
        guard isMock || access == .ready else { return nil }
        let src = bands ?? state?.currentBands
        let n = Self.uniqueName(name, taken: (state?.presets ?? []) + customs.map(\.name))
        let p = CustomEQPreset(name: n, preamp: src?.first ?? 0, bands: src.map { Array($0.dropFirst()) } ?? [])
        customs.append(p)
        saveCustoms()
        selectCustom(p.id)
        return p.id
    }

    /// Сделать свой пресет текущим (заодно досоздать в «Музыке», если его там нет — например, после её сброса).
    func selectCustom(_ id: String) {
        if id == Self.manualId { if let n = manual?.name { select(n) }; return }
        guard let p = custom(id) else { return }
        dirty.removeAll { $0 == id }
        if isMock {
            state?.current = p.name; state?.enabled = true
            if state.map({ !$0.presets.contains(p.name) }) == true { state?.presets.append(p.name) }
            state?.currentBands = [p.preamp] + p.bands
            send(Self.syncScript(p, select: true)); return
        }
        guard access == .ready else { return }
        pending = p.name
        run(Self.syncScript(p, select: true))
    }

    /// Ползунок: 0 — предусилитель, 1…10 — полосы. Значение — сразу в модели (ползунок отзывчивый), в «Музыку» —
    /// через `debounce`. Встроенные пресеты не трогаются: id — только своих.
    func setValue(_ id: String, slider: Int, to v: Double) {
        guard (0...CustomEQPreset.bandCount).contains(slider) else { return }
        let nv = CustomEQPreset.clamp(v)
        if id == Self.manualId {
            guard var m = manual, m[slider: slider] != nv else { return }
            m[slider: slider] = nv
            manual = m
            if state?.current == m.name { state?.currentBands = [m.preamp] + m.bands }
            markDirty(id)
            return
        }
        guard let i = customs.firstIndex(where: { $0.id == id }) else { return }
        guard customs[i][slider: slider] != nv else { return }
        customs[i][slider: slider] = nv
        if state?.current == customs[i].name { state?.currentBands = [customs[i].preamp] + customs[i].bands }
        markDirty(id)
    }

    /// Все полосы в 0.
    func resetAll(_ id: String) {
        if id == Self.manualId {
            guard var m = manual else { return }
            m.preamp = 0; m.bands = Array(repeating: 0, count: CustomEQPreset.bandCount)
            manual = m
            markDirty(id); flush(); return
        }
        guard let i = customs.firstIndex(where: { $0.id == id }) else { return }
        customs[i].preamp = 0
        customs[i].bands = Array(repeating: 0, count: CustomEQPreset.bandCount)
        markDirty(id)
        flush()
    }

    func rename(_ id: String, to newName: String) {
        guard let i = customs.firstIndex(where: { $0.id == id }) else { return }
        let old = customs[i].name
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        let others = (state?.presets ?? []).filter { $0 != old } + customs.filter { $0.id != id }.map(\.name)
        let n = Self.uniqueName(trimmed, taken: others)
        guard n != old else { return }
        customs[i].name = n
        if state?.current == old { state?.current = n }
        if let j = state?.presets.firstIndex(of: old) { state?.presets[j] = n }
        if pending == old { pending = n }
        saveCustoms()
        if isMock { send(Self.renameScript(old, n)); return }
        guard access == .ready else { return }
        run(Self.renameScript(old, n))
    }

    func delete(_ id: String) {
        guard let i = customs.firstIndex(where: { $0.id == id }) else { return }
        let p = customs.remove(at: i)
        dirty.removeAll { $0 == id }
        if editing == id { editing = nil }
        saveCustoms()
        state?.presets.removeAll { $0 == p.name }
        if isMock { if state?.current == p.name { state?.current = state?.presets.first }; send(Self.deleteScript(p.name)); return }
        guard access == .ready else { return }
        run(Self.deleteScript(p.name))
    }

    /// Отправить накопленные правки сейчас (конец перетаскивания, закрытие редактора/вкладки).
    func flush() {
        flushItem?.cancel(); flushItem = nil
        let ids = dirty
        dirty = []
        guard !ids.isEmpty else { return }
        if ids.contains(where: { $0 != Self.manualId }) { saveCustoms() }   // «Настройка вручную» — не наша, не храним
        for id in ids {
            guard let p = editable(id) else { continue }
            syncCount += 1
            if isMock || scriptSink != nil { send(Self.syncScript(p, select: false)); continue }
            guard access == .ready else { continue }
            run(Self.syncScript(p, select: false), reread: false)
        }
    }

    var hasPendingEdits: Bool { !dirty.isEmpty }

    private func markDirty(_ id: String) {
        if !dirty.contains(id) { dirty.append(id) }
        guard flushItem == nil else { return }   // окно уже идёт: правки копятся, уйдут одним скриптом
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flushItem = nil; self?.flush() } }
        flushItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: w)
    }

    private func saveCustoms() { store?.save(customs) }

    func openMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { [weak self] in self?.refresh() } }
            }
        }
    }

    func mock(_ s: Snapshot?, access: Access, customs: [CustomEQPreset]? = nil) {
        isMock = true
        state = s
        manual = s.flatMap { s in s.manualName.flatMap { n in s.manualBands.map {
            CustomEQPreset(id: Self.manualId, name: n, preamp: $0[0], bands: Array($0.dropFirst())) } } }
        self.access = access
        pending = nil
        if let customs { self.customs = customs }
    }

    private func send(_ script: String) { scriptSink?(script) }

    private func run(_ script: String, reread: Bool = true) {
        if let sink = scriptSink { sink(script); return }
        inFlight += 1
        ScriptSource.perform {
            let err = ScriptSource.run(script).errorNumber
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.inFlight -= 1
                    var why: String?
                    if let e = err, e == -10006 {
                        why = "Музыка сейчас не даёт менять эквалайзер. Так бывает, когда трек играет в Dolby Atmos / пространственном звуке — выключи их в Музыке: Настройки → Воспроизведение."
                    } else if let e = err {
                        why = "Музыка не выполнила команду эквалайзера (код \(e))."
                    }
                    if why != self.refused { self.refused = why }
                    if reread || self.inFlight == 0 { self.refresh() }
                }
            }
        }
    }

    private func setAccess(_ a: Access) { if access != a { access = a } }
}
