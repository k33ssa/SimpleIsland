import Foundation
import Network

/// Сеть «пропала / появилась» (NWPathMonitor, без дочерних процессов и опроса). VPN здесь не смотрим:
/// статус VPN даёт отдельный модуль (Vafa), решение пользователя 14.11.2026.
///
/// Против ложных вспышек: от `willSleep` до `didWake` + 6 с — тишина (Wi-Fi после сна переподключается);
/// «Нет сети» — только если так держится дольше 3 с; вернулась раньше — ни одной вспышки.
/// Сон/пробуждение приходят от модуля (`context.onSystemEvent`), своих подписок на NSWorkspace нет.
@MainActor
final class NetworkWatcher {
    var onNetwork: ((_ online: Bool, _ interface: String?) -> Void)?

    private var monitor: NWPathMonitor?
    private var online: Bool?
    private var interface: String?
    private let queue = DispatchQueue(label: "simpleisland.hud.network", qos: .utility)

    /// Тишина после пробуждения и дребезг «пропало».
    static let wakeQuiet: TimeInterval = 6
    static let lossDelay: TimeInterval = 3
    private var sleeping = false
    private var quietUntil = Date.distantPast
    private var quietEndWork: DispatchWorkItem?
    private var offlineWork: DispatchWorkItem?
    /// «Нет сети» показали — значит, при возврате покажем «Сеть есть».
    private var offlineAnnounced = false
    /// Для самотеста: подменить «сейчас».
    var now: () -> Date = Date.init

    var isQuiet: Bool { sleeping || now() < quietUntil }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let iface: String? = path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.wifi) ? "Wi-Fi"
                : path.usesInterfaceType(.cellular) ? "Сотовая" : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pathChanged(online: ok, interface: iface) } }
        }
        m.start(queue: queue)
        monitor = m
    }

    func willSleep() {
        sleeping = true
        quietEndWork?.cancel(); quietEndWork = nil
        offlineWork?.cancel(); offlineWork = nil
    }

    func didWake() {
        sleeping = false
        quietUntil = now().addingTimeInterval(Self.wakeQuiet)
        quietEndWork?.cancel()
        guard monitor != nil else { quietEndWork = nil; return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.quietEnded() } }
        quietEndWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeQuiet + 0.05, execute: w)
    }

    /// Тишина кончилась: если сети так и нет — это уже не переподключение, сообщить (после обычной задержки).
    func quietEnded() {
        quietEndWork = nil
        guard monitor != nil else { return }
        if online == false, !offlineAnnounced { scheduleOffline() }
    }

    private func scheduleOffline() {
        offlineWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.monitor != nil else { return }
                self.offlineWork = nil
                guard self.online == false, !self.isQuiet else { return }
                self.offlineAnnounced = true
                self.onNetwork?(false, nil)
            }
        }
        offlineWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lossDelay, execute: w)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        quietEndWork?.cancel(); quietEndWork = nil
        offlineWork?.cancel(); offlineWork = nil
        sleeping = false; quietUntil = .distantPast; offlineAnnounced = false
        online = nil; interface = nil
    }

    func pathChanged(online ok: Bool, interface iface: String?) {
        guard monitor != nil else { return }
        guard let was = online else { online = ok; interface = iface; return } // первое — без вспышки
        let changedIface = ok && was && iface != interface && iface != nil && interface != nil
        online = ok; interface = iface
        if isQuiet {
            // Сон/пробуждение: состояние запоминаем молча. Вернулась — «Сеть есть» уже не нужна.
            if ok { offlineAnnounced = false; offlineWork?.cancel(); offlineWork = nil }
            return
        }
        if !ok, was {
            scheduleOffline()
        } else if ok, !was {
            if let w = offlineWork {
                w.cancel(); offlineWork = nil // пропала на миг — ни одной вспышки
            } else if offlineAnnounced {
                offlineAnnounced = false
                onNetwork?(true, iface)
            }
        } else if changedIface {
            onNetwork?(true, iface)
        }
    }

    /// Для самотеста: запустить разбор без системы (как будто монитор работает).
    func startForTest() {
        guard monitor == nil else { return }
        monitor = NWPathMonitor() // не запущен: событий не будет
    }

    /// Отложенные дела (для самотеста «в покое ничего не ждёт»): дребезг «Нет сети» и конец тишины.
    var pendingWorkCount: Int { (offlineWork != nil ? 1 : 0) + (quietEndWork != nil ? 1 : 0) }
    var pendingLossCount: Int { offlineWork != nil ? 1 : 0 }
}
