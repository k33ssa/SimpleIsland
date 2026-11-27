import AppKit
import Combine
import SwiftUI
import IslandCore

/// Модуль «Vafa» — статус охраны приложений без VPN (отдельное приложение автора, github.com/k33ssa/vafa).
/// Vafa — НЕ VPN: она замораживает выбранные программы, пока VPN выключен.
///
/// По умолчанию выключен — включается из каталога виджетов («Мои приложения» → Vafa → «Добавить виджет»).
/// Пока выключен — ничего не слушает. Включён: `VafaModel` следит за `/usr/local/var/vpn-guard/status.json`
/// (FileWatcher, без опроса), охрана сработала → карточка «Vafa: VPN выключен — заморожено: …», компакт с замком и
/// красная живая точка, пока не вернётся; вернулось → короткая вспышка «всё снова работает».
@MainActor
public final class VafaIslandModule: IslandModule {
    nonisolated public static let moduleId = "vafa"
    public let id = VafaIslandModule.moduleId
    public let title = "Vafa"
    public let systemImage = "lock.shield.fill"
    public var providesTab: Bool { true }
    public var tabEnabledByDefault: Bool { false }
    public var expandedHeight: CGFloat { 172 }

    public let model: VafaModel
    private weak var context: ModuleContext?
    private var enabledSub: AnyCancellable?
    /// Что сейчас показано в компакте (заголовок, кто заморожен/заблокирован): `procs` меняется каждую секунду,
    /// а компакт — только при смене этого ключа.
    private var postedKey: String?
    static let activityId = "vafa.guard"

    public init(statusURL: URL = VafaPaths.statusFile) {
        model = VafaModel(statusURL: statusURL)
    }

    public func start(context: ModuleContext) {
        self.context = context
        model.onPhaseChange = { [weak self] old, new, status in self?.phaseChanged(from: old, to: new, status: status) }
        model.onStatusChange = { [weak self] status in
            guard let self, self.model.phase == .triggered, let ctx = self.context else { return }
            let key = Self.activityKey(status)
            guard key != self.postedKey else { return }
            self.postedKey = key
            Self.postActivity(status, ctx: ctx)
        }
        enabledSub = context.onEnabledChange { [weak self] on in
            if on { self?.model.start() } else { self?.disable() }
        }
        context.onSystemEvent { [weak self] e in
            guard let self else { return }
            switch e {
            case .willSleep, .screensDidSleep, .screenLocked, .sessionDidResignActive:
                self.model.pause()
            case .didWake, .screensDidWake, .screenUnlocked, .sessionDidBecomeActive:
                if context.system.isInteractive { self.model.resume() }
            default: break
            }
        }
        if context.isEnabled { model.start() }
    }

    public func stop() {
        disable()
        enabledSub = nil
        context = nil
    }

    private func disable() {
        model.stop()
        postedKey = nil
        guard let ctx = context else { return }
        Self.clear(ctx)
    }

    public func expandedView() -> AnyView? {
        AnyView(VafaTabView(model: model) { [weak self] in
            self?.context?.collapse()
            self?.context?.openWidgetCatalog(focus: VafaIslandModule.moduleId)
        })
    }

    // MARK: Реакция на смену фазы

    private func phaseChanged(from old: VafaPhase?, to new: VafaPhase, status: VafaStatus?) {
        guard let ctx = context else { return }
        postedKey = new == .triggered ? Self.activityKey(status) : nil
        Self.present(new, status: status, ctx: ctx, previous: old)
    }

    /// Ключ содержимого компакта: без счётчиков процессов.
    static func activityKey(_ status: VafaStatus?) -> String {
        headline(status) + "|" + (status?.blocked.map { "\($0.name):\($0.frozen > 0 ? "f" : "l")" }.joined(separator: ",") ?? "")
    }

    /// Показать фазу: компакт/точка/свечение; на переходах — карточка или вспышка. Общая для живого режима и снимков.
    static func present(_ phase: VafaPhase, status: VafaStatus?, ctx: ModuleContext, previous: VafaPhase?) {
        switch phase {
        case .triggered:
            postActivity(status, ctx: ctx)
            ctx.setStatusDot(IslandPalette.err, priority: 100)
            ctx.setGlow(VafaStyle.alarmColors)
            // Красная точка у выреза в полноэкранном — один раз на переход (просмотрели — погасла и не вернётся,
            // пока охрана снова не сработает).
            if previous != .triggered { ctx.setAttention(.error, text: "Vafa: VPN выключен — охрана сработала") }
            // Карточка — только на переходе в «сработала» (на старте приложения хватает компакта и точки).
            if let previous, previous != .triggered { ctx.showNotification(notification(status, ctx: ctx)) }
        case .ok, .checking, .stale, .notInstalled, .notRunning:
            clear(ctx)
            if previous == .triggered && (phase == .ok || phase == .checking) {
                ctx.flashHUD(backFlash(theme: ctx.theme), duration: 2.2)
            }
        }
    }

    static func clear(_ ctx: ModuleContext) {
        ctx.removeActivity(id: activityId)
        ctx.setStatusDot(nil)
        ctx.setGlow(nil)
        ctx.setAttention(nil)
    }

    static func postActivity(_ status: VafaStatus?, ctx: ModuleContext) {
        // Снежинка — сколько программ именно заморожено; ничего не заморожено, но запуск запрещён — замок и их число.
        let frozen = status?.frozenItems ?? []
        let blocked = status?.blocked ?? []
        let shown = frozen.isEmpty ? blocked : frozen
        let names = VafaStatus.list(shown.map(\.name))
        let spoken = "Vafa: \(headline(status))"
            + (names.isEmpty ? "" : (frozen.isEmpty ? ", запуск запрещён: " : ", заморожено: ") + names)
        ctx.post(IslandActivity(id: activityId, moduleId: moduleId, priority: 90, sideWidth: 64,
                                glowColors: VafaStyle.alarmColors) {
            VafaCompactLeading()
        } trailing: {
            VafaCompactTrailing(count: shown.count, frozen: !frozen.isEmpty)
        }.accessibility(spoken))
    }

    static func headline(_ status: VafaStatus?) -> String {
        status?.state == "down" || status?.vpn == false ? "VPN выключен" : "охрана сработала"
    }

    static func notification(_ status: VafaStatus?, ctx: ModuleContext) -> IslandNotification {
        let blocked = status?.blocked ?? []
        // Есть замороженные — называем их; нет — те, чей запуск запрещён.
        let frozen = blocked.filter { $0.frozen > 0 }
        let anyFrozen = !frozen.isEmpty
        let names = VafaStatus.list((anyFrozen ? frozen : blocked).map(\.name))
        let body: String
        if names.isEmpty { body = "Программы под охраной не запустятся, пока VPN выключен" }
        else { body = (anyFrozen ? "Заморожено: " : "Запуск запрещён: ") + names }
        return IslandNotification(id: "vafa.triggered", moduleId: moduleId, title: "Vafa: \(headline(status))",
                                  body: body, avatarColors: VafaStyle.alarmColors, systemImage: "lock.shield.fill",
                                  actions: [IslandNotificationAction("Показать", role: .primary) { ctx.openTab() }],
                                  duration: 8)
    }

    static func backFlash(theme: Theme) -> HUDEvent {
        let left = "Vafa", right = "всё снова работает"
        let side = max(VafaStyle.width(left, size: 12.5, weight: .bold, theme: theme) + 22,
                       VafaStyle.width(right, size: 12.5, weight: .semibold, theme: theme)) + 18
        var e = HUDEvent(kind: "vafa", sideWidth: max(120, side),
                         customLeading: AnyView(VafaFlashLeading(text: left)),
                         customTrailing: AnyView(VafaFlashNote(text: right)))
        e.accessibilityLabel = "Vafa: всё снова работает"
        return e
    }

    // MARK: Снимки

    public func snapshotStates() -> [ModuleSnapshot] {
        let snap = { (name: String, presentation: ModuleSnapshot.Presentation, status: VafaStatus?, previous: VafaPhase?,
                      installed: Bool) in
            ModuleSnapshot(name, presentation: presentation) { ctx in
                if presentation == .expanded,
                   let i = ctx.settings.data.tabs.firstIndex(where: { $0.id == VafaIslandModule.moduleId }) {
                    ctx.settings.data.tabs[i].enabled = true
                }
                // Снимки не зависят от того, стоит ли Vafa на этой машине.
                self.model.installMarkers = installed ? ["/"] : []
                self.model.apply(status)
                Self.present(self.model.phase, status: status, ctx: ctx, previous: previous)
                if presentation == .expanded { ctx.removeActivity(id: Self.activityId) }
            }
        }
        return [
            snap("triggered", .expanded, Self.mockTriggered, .ok, true),
            snap("triggered-compact", .compact, Self.mockTriggered, nil, true),
            snap("triggered-notification", .automatic, Self.mockTriggered, .ok, true),
            snap("ok", .expanded, Self.mockOK, nil, true),
            snap("ok-flash", .automatic, Self.mockOK, .triggered, true),
            snap("checking-grace", .expanded, Self.mockGrace, nil, true),
            snap("checking-country", .expanded, Self.mockUnsureCountry, nil, true),
            snap("not-running", .expanded, nil, nil, true),
            snap("not-installed", .expanded, nil, nil, false),
        ]
    }

    /// `unsure` в паузе GRACE: VPN пропал, маршрут через en0, сеть к Claude уже закрыта.
    public static var mockGrace: VafaStatus {
        var s = mockOK
        s.state = "unsure"; s.vpn = false; s.iface = "en0"; s.country = "DE"; s.net = "hold"
        return s
    }

    /// `unsure`: маршрут через туннель, но страна выхода не подтверждена.
    public static var mockUnsureCountry: VafaStatus {
        var s = mockOK
        s.state = "unsure"; s.vpn = false; s.country = ""; s.net = "hold"
        return s
    }

    public static var mockOK: VafaStatus {
        VafaStatus(state: "up", vpn: true, iface: "utun225", country: "DE", apps: [
            .init(path: "/Applications/Claude.app", procs: 28),
            .init(path: "/Applications/ChatGPT.app", procs: 6),
            .init(path: "/Applications/VLC.app"),
        ], cli: .init(path: VafaStatus.cliName, procs: 6))
    }

    public static var mockTriggered: VafaStatus {
        VafaStatus(state: "down", vpn: false, iface: "", country: "", apps: [
            .init(path: "/Applications/Claude.app", locked: true, procs: 28, frozen: 28),
            .init(path: "/Applications/ChatGPT.app", locked: true, procs: 6, frozen: 6),
            .init(path: "/Applications/VLC.app", locked: true),
        ], cli: .init(path: VafaStatus.cliName, locked: true, procs: 6, frozen: 6))
    }
}
