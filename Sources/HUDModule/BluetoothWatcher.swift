import AppKit
import IOBluetooth
import CoreBluetooth
import IOKit
import IslandCore

/// Подключение наушников/колонок (IOBluetooth-уведомления о подключении, не опрос).
/// Bluetooth — право TCC: без `NSBluetoothAlwaysUsageDescription` в Info.plist обращение к Bluetooth убивает
/// процесс, поэтому без ключа (напр. `swift run`) и без разрешения мы IOBluetooth не трогаем вообще.
@MainActor
final class BluetoothWatcher: NSObject {
    enum Access: Equatable {
        case granted
        /// Ещё не спрашивали — спросим по кнопке «Разрешить…».
        case notDetermined
        case denied
        /// Нет ключа в Info.plist (сборка без .app) — Bluetooth недоступен.
        case unavailable
    }

    var onConnect: ((_ name: String, _ battery: HeadphonesBattery?) -> Void)?
    /// Заряд узнали позже (через `system_profiler`) — обновить уже показанную карточку.
    var onBattery: ((_ name: String, _ battery: HeadphonesBattery) -> Void)?
    var onDisconnect: ((_ name: String) -> Void)?
    var onAccessChange: ((Access) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    /// Устройства, подключённые на момент регистрации уведомлений: регистрация сразу присылает их — это не
    /// новость, карточку не показываем. Устройство уходит из списка, когда отключилось. Вместо прежнего «окна 2 с
    /// после регистрации»: оно глушило настоящие подключения сразу после пробуждения (AirPods при открытии крышки).
    private(set) var baseline: Set<String> = []
    private var requester: CBCentralManager?
    private var pendingBattery: [String: DispatchWorkItem] = [:]
    /// Через сколько после подключения читать заряд (он появляется не сразу).
    var batteryDelay: TimeInterval = 1.2
    /// Запасной путь заряда: `system_profiler` (по событию подключения, не чаще раза в минуту).
    let profiler: BluetoothProfiler

    var isRunning: Bool { connectNote != nil }
    /// Ждут чтения заряда (для самотеста и `pendingWork`).
    var pendingCount: Int { pendingBattery.count }

    /// `profiler` — свой для самотеста (nil — настоящий `system_profiler`).
    init(profiler: BluetoothProfiler? = nil) {
        self.profiler = profiler ?? BluetoothProfiler()
        super.init()
    }

    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    static var access: Access {
        guard hasUsageDescription else { return .unavailable }
        switch CBManager.authorization {
        case .allowedAlways: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func start() {
        guard connectNote == nil, Self.access == .granted else { return }
        register()
    }

    /// Запомнить уже подключённые устройства и подписаться на подключения.
    private func register() {
        resetBaseline(Self.connectedKeys())
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    private func unregisterNotes() {
        connectNote?.unregister()
        connectNote = nil
        for n in disconnectNotes.values { n.unregister() }
        disconnectNotes.removeAll()
    }

    func stop() {
        unregisterNotes()
        baseline = []
        for w in pendingBattery.values { w.cancel() }
        pendingBattery.removeAll()
        profiler.cancel()
        requester = nil
    }

    /// После сна / смены экранов / возврата сессии: зарегистрировать уведомления заново (система могла их
    /// потерять). Отложенные карточки подключения и запущенный `system_profiler` **не трогаем**: AirPods часто
    /// подключаются в первые секунды после открытия крышки, и их карточка не должна теряться.
    func rewire() {
        guard isRunning else { return }
        unregisterNotes()
        register()
    }

    /// Новый список «уже подключённых» (регистрация). Отложенные карточки не отменяет. Открыто для самотеста.
    func resetBaseline(_ keys: Set<String>) { baseline = keys }

    /// Адреса подключённых сопряжённых устройств. Только при выданном праве (иначе IOBluetooth убивает процесс).
    static func connectedKeys() -> Set<String> {
        guard access == .granted, let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return Set(list.filter { $0.isConnected() }.map(key(for:)))
    }

    static func key(for d: IOBluetoothDevice) -> String { d.addressString ?? d.name ?? "?" }

    /// Кнопка «Разрешить…»: не спрашивали — системный запрос (через CoreBluetooth); отказано — открыть настройки.
    /// Не молчит (ядро, `Permissions.plan/followUp`): из оболочки — карточка «Перезапустить», запрещено — раздел
    /// настроек и карточка «где включить», окно не показалось / отказ — то же после ответа.
    func requestAccess() {
        let p = IslandPermission.bluetooth
        switch Permissions.plan(p, status: Permissions.status(p), canRequest: Permissions.canRequest(p),
                                launch: LaunchKind.current) {
        case .granted:
            break
        case .systemPrompt:
            requestStarted = Date()
            requester = CBCentralManager(delegate: self, queue: .main)
        case .guide(let g):
            Permissions.showGuide(g, for: p, moduleId: "hud")
        }
    }
    /// Когда показали системный запрос (nil — не показывали): после ответа «нет» — подсказка.
    private var requestStarted: Date?

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = Self.key(for: device)
        if disconnectNotes[key] == nil {
            disconnectNotes[key] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        }
        guard Self.isAudio(device), let name = device.name else { return }
        deviceConnected(key: key, name: name, address: device.addressString) {
            Self.battery(device: device, name: name)
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = Self.key(for: device)
        disconnectNotes[key]?.unregister()
        disconnectNotes[key] = nil
        deviceDisconnected(key: key, name: device.name, isAudio: Self.isAudio(device))
    }

    /// Подключилось аудио-устройство (логика без IOBluetooth — открыта для самотеста). Уже подключённое при
    /// регистрации — мимо. Иначе через `batteryDelay` читаем заряд: есть — карточка с зарядом; нет — карточка
    /// сразу без заряда, а `system_profiler` (если ответит) обновит её на месте (`onBattery`).
    func deviceConnected(key: String, name: String, address: String?, readBattery: @escaping () -> HeadphonesBattery?) {
        guard !baseline.contains(key) else { return }
        pendingBattery[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingBattery[key] = nil
                if let b = readBattery() { self.onConnect?(name, b); return }
                self.onConnect?(name, nil)
                self.profiler.fetch { [weak self] list in
                    guard let self, let b = BluetoothProfiler.find(in: list, name: name, address: address) else { return }
                    self.onBattery?(name, b)
                }
            }
        }
        pendingBattery[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + batteryDelay, execute: work)
    }

    /// Отключилось устройство (логика без IOBluetooth — открыта для самотеста).
    func deviceDisconnected(key: String, name: String?, isAudio: Bool) {
        baseline.remove(key)
        pendingBattery[key]?.cancel(); pendingBattery[key] = nil
        guard isAudio, let name else { return }
        onDisconnect?(name)
    }

    /// Аудио-устройство (наушники, колонки): major class 0x04.
    static func isAudio(_ d: IOBluetoothDevice) -> Bool {
        d.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
    }

    // MARK: Заряд — best effort

    /// 1) приватные `batteryPercent*` у IOBluetoothDevice (0 = нет данных); 2) IORegistry
    /// `AppleDeviceManagementHIDEventService` → `BatteryPercent` по имени. Ничего — nil (показываем без заряда).
    static func battery(device: IOBluetoothDevice, name: String) -> HeadphonesBattery? {
        func pct(_ sel: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(sel)),
                  let n = device.value(forKey: sel) as? NSNumber else { return nil }
            let v = n.intValue
            return (1...100).contains(v) ? v : nil
        }
        var b = HeadphonesBattery(left: pct("batteryPercentLeft"), right: pct("batteryPercentRight"),
                                  caseLevel: pct("batteryPercentCase"), single: pct("batteryPercentSingle"))
        if b.isEmpty, let v = registryBattery(name: name) { b.single = v }
        return b.isEmpty ? nil : b
    }

    static func registryBattery(name: String) -> Int? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var result: Int?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard result == nil,
                  let product = IORegistryEntryCreateCFProperty(s, "Product" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String, product == name,
                  let pct = IORegistryEntryCreateCFProperty(s, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int, (1...100).contains(pct) else { continue }
            result = pct
        }
        return result
    }
}

extension BluetoothWatcher: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            let a = Self.access
            if a != .notDetermined { requester = nil }
            if a != .notDetermined, let t0 = requestStarted {
                requestStarted = nil
                let p = IslandPermission.bluetooth
                // Bluetooth выключен / не поддерживается: быстрый ответ — не «окно не показалось», настройки прав не
                // открываем (только карточка, и то лишь при настоящем запрете).
                let radioOff = central.state == .poweredOff || central.state == .unsupported
                if case .guide(var g) = Permissions.followUp(p, after: Permissions.status(p),
                                                             elapsed: Date().timeIntervalSince(t0), launch: LaunchKind.current),
                   !radioOff || a == .denied {
                    if radioOff, g == .noAnswer { g = .declined }
                    Permissions.showGuide(g, for: p, moduleId: "hud")
                }
            }
            onAccessChange?(a)
        }
    }
}

/// Заряд наушников через `system_profiler SPBluetoothDataType -json` — публичная утилита Apple, приватных
/// entitlements не нужно (docs/TECH.md §4, путь 3). Только по событию подключения, через `ManagedProcess`,
/// с тайм-аутом и **не чаще раза в минуту** (в пределах `minInterval` — прошлый ответ из памяти: колонка, которая
/// переподключается по кругу, не запускает его каждый раз). Несколько запросов во время одного запуска получают
/// один ответ. Ответ готов, когда пришла закрывающая `}` верхнего уровня и JSON разобрался (у `system_profiler`
/// она последняя и без перевода строки — приходит по EOF), а не «через 0,15 с после выхода»: под нагрузкой хвост
/// вывода может прийти позже события выхода.
@MainActor
final class BluetoothProfiler {
    struct Entry: Equatable {
        var name: String
        var address: String
        var battery: HeadphonesBattery
    }

    let executable: String
    /// Аргументы (самотест подставляет свои).
    var arguments: [String]
    var timeout: TimeInterval = 4
    /// Не чаще раза в `minInterval` (docs/TECH.md §4 — раз в минуту).
    var minInterval: TimeInterval = 60
    /// Процесс вышел, а закрывающей `}` нет — подождать хвост вывода не дольше этого.
    var tailGrace: TimeInterval = 1
    /// Сколько раз запускали процесс (для самотеста).
    private(set) var runCount = 0
    private var process: ManagedProcess?
    private var output: [String] = []
    private var waiters: [([Entry]) -> Void] = []
    private var timeoutWork: DispatchWorkItem?
    private var tailWork: DispatchWorkItem?
    private var last: (at: Date, list: [Entry])?

    var isRunning: Bool { process != nil }

    init(executable: String = "/usr/sbin/system_profiler", arguments: [String] = ["SPBluetoothDataType", "-json"]) {
        self.executable = executable; self.arguments = arguments
    }

    func fetch(_ done: @escaping ([Entry]) -> Void) {
        if process == nil, let last, Date().timeIntervalSince(last.at) < minInterval {
            done(last.list)
            return
        }
        waiters.append(done)
        guard process == nil else { return }
        output = []
        runCount += 1
        let p = ManagedProcess(executable: executable, arguments: arguments)
        // Обработчики проверяют, что процесс всё ещё наш: ответ мог быть готов внутри обработчика строки старого
        // процесса, а ожидающий — тут же запустить новый; строки старого в вывод нового не попадут.
        p.onLine = { [weak self, weak p] line in
            guard let self, let p, self.process === p else { return }
            self.output.append(line)
            // Закрывающая `}` верхнего уровня — без отступа (вложенные с отступом JSON не разбираем).
            if line == "}", let list = Self.complete(self.output) { self.finish(list) }
        }
        p.onExit = { [weak self, weak p] _ in
            guard let self, let p, self.process === p else { return }
            if let list = Self.complete(self.output) { self.finish(list); return }
            // Хвост ещё в пути (строки идут через главную очередь отдельно от события выхода) — подождать.
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish(nil) } }
            self.tailWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + self.tailGrace, execute: w)
        }
        process = p
        guard p.start() else { finish(nil); return }
        let t = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish(nil) } }
        timeoutWork = t
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: t)
    }

    /// Вывод — целый JSON с `SPBluetoothDataType` (nil — ещё не весь или мусор).
    nonisolated static func complete(_ lines: [String]) -> [Entry]? {
        let data = Data(lines.joined(separator: "\n").utf8)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["SPBluetoothDataType"] != nil else { return nil }
        return parse(data)
    }

    private func finish(_ ready: [Entry]?) {
        timeoutWork?.cancel(); timeoutWork = nil
        tailWork?.cancel(); tailWork = nil
        let p = process
        process = nil
        p?.stop(grace: 0.5)
        let list = ready ?? Self.parse(Data(output.joined(separator: "\n").utf8))
        output = []
        last = (Date(), list)
        let w = waiters
        waiters = []
        for f in w { f(list) }
    }

    /// Остановить без ответа (stop модуля). Ответ из памяти забыть не нужно — он про устройства, не про модуль.
    func cancel() {
        timeoutWork?.cancel(); timeoutWork = nil
        tailWork?.cancel(); tailWork = nil
        let p = process
        process = nil
        p?.stop(grace: 0.5)
        output = []
        waiters = []
    }

    /// Разбор JSON: `SPBluetoothDataType[].device_connected[] { "<имя>": { device_address, device_batteryLevel* } }`.
    nonisolated static func parse(_ data: Data) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [Entry] = []
        for item in items {
            guard let connected = item["device_connected"] as? [[String: Any]] else { continue }
            for dev in connected {
                for (name, v) in dev {
                    guard let info = v as? [String: Any] else { continue }
                    func pct(_ k: String) -> Int? {
                        guard let s = info[k] as? String,
                              let n = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))),
                              (1...100).contains(n) else { return nil }
                        return n
                    }
                    let b = HeadphonesBattery(left: pct("device_batteryLevelLeft"), right: pct("device_batteryLevelRight"),
                                              caseLevel: pct("device_batteryLevelCase"), single: pct("device_batteryLevelMain"))
                    guard !b.isEmpty else { continue }
                    out.append(Entry(name: name, address: (info["device_address"] as? String) ?? "", battery: b))
                }
            }
        }
        return out
    }

    /// Найти устройство: по адресу (формат у IOBluetooth «aa-bb-…», у system_profiler «AA:BB:…»), иначе по имени.
    nonisolated static func find(in list: [Entry], name: String, address: String?) -> HeadphonesBattery? {
        func norm(_ s: String) -> String { s.uppercased().filter { $0.isHexDigit } }
        if let a = address.map(norm), !a.isEmpty, let e = list.first(where: { norm($0.address) == a }) { return e.battery }
        return list.first { $0.name == name }?.battery
    }
}
