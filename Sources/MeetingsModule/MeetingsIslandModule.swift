import AppKit
import Combine
import SwiftUI
import IslandCore

/// Модуль «Встречи» — Sten («протокол встреч»): запись встречи с микрофона, итог, решения и задачи по людям.
///
/// По умолчанию выключен — включается из каталога виджетов. Пока выключен — ни запросов, ни микрофона.
/// Включён: вход один раз (cookie в Keychain), запись кусками fMP4 на /chunks как в веб-версии, опрос /status —
/// только пока какая-то встреча обрабатывается (бэкофф 2→15 с, пауза во сне), список — при открытии вкладки.
/// Запись — красная точка и таймер в ушах острова; протокол готов — карточка «Протокол готов» с «Открыть».
@MainActor
public final class MeetingsIslandModule: IslandModule {
    nonisolated public static let moduleId = "meetings"
    public let id = MeetingsIslandModule.moduleId
    public let title = "Встречи"
    public let systemImage = "person.2.wave.2.fill"
    public var providesTab: Bool { true }
    public var tabEnabledByDefault: Bool { false }
    /// Протокол выше списка: люди с задачами не помещаются в 214 pt.
    public var expandedHeight: CGFloat { model.selected == nil ? 214 : 270 }

    public let model: MeetingsModel
    private weak var context: ModuleContext?
    private var enabledSub: AnyCancellable?
    private var selectedSub: AnyCancellable?
    static let recordingActivity = "meetings.recording"
    static let processingActivity = "meetings.processing"

    public init(store: StenSessionStore? = nil) {
        model = MeetingsModel(store: store ?? FileSessionStore())
    }

    public func start(context: ModuleContext) {
        self.context = context
        if let saved = context.loadSettings(MeetingsPrefs.self) {
            // Модель создана до загрузки настроек: подхватить сохранённый сервер/имя/хвосты отправки.
            model.applySaved(saved)
        }
        model.saveHandler = { [weak context] p in context?.saveSettings(p) }
        model.onRecordingChange = { [weak self] in self?.updateActivities() }
        model.onProcessingChange = { [weak self] in self?.updateActivities() }
        model.onReady = { [weak self] m in self?.ready(m) }
        selectedSub = model.$selected.removeDuplicates().dropFirst().sink { [weak context] _ in
            DispatchQueue.main.async { context?.invalidateLayout() }
        }
        enabledSub = context.onEnabledChange { [weak self] on in
            guard let self else { return }
            if on { self.enable() } else { self.disable() }
        }
        context.onSystemEvent { [weak self] e in
            guard let self else { return }
            switch e {
            case .willSleep:
                // Сон: микрофон всё равно остановится — дописать и отправить, что есть; опрос — на паузу.
                Task { await self.model.stopRecording() }
                self.model.pausePolling()
            case .screensDidSleep, .sessionDidResignActive:
                self.model.pausePolling()
            // Разблокировка тоже (25.11): проснулись на экране блокировки — тогда ещё не «интерактивно», а
            // `.screenUnlocked` раньше не ловили — опрос стоял на паузе вечно, кольцо обработки крутилось бесконечно.
            case .didWake, .screensDidWake, .sessionDidBecomeActive, .screenUnlocked:
                if context.system.isInteractive { self.model.resumePolling() }
            default: break
            }
        }
        if context.isEnabled { enable() }
    }

    private func enable() {
        model.cleanupOldRecordings()
        if !model.prefs.pending.isEmpty { Task { await model.retryPending() } }
    }

    private func disable() {
        Task { await model.shutdown() }
        guard let ctx = context else { return }
        ctx.removeActivity(id: Self.recordingActivity)
        ctx.removeActivity(id: Self.processingActivity)
        ctx.setStatusDot(nil)
    }

    public func stop() {
        disable()
        enabledSub = nil
        context = nil
    }

    public func expandedView() -> AnyView? {
        AnyView(MeetingsTabView(model: model) { [weak self] wants in self?.context?.requestKeyboard(wants) })
    }

    public func settingsView() -> AnyView? { AnyView(MeetingsSettingsView(model: model)) }

    // MARK: Компакт и карточки

    func updateActivities() {
        guard let ctx = context else { return }
        Self.present(model: model, ctx: ctx)
    }

    static func present(model: MeetingsModel, ctx: ModuleContext) {
        if model.record != .idle {
            let start = model.recordStart
            ctx.post(IslandActivity(id: recordingActivity, moduleId: moduleId, priority: 70, sideWidth: 64,
                                    glowColors: MeetingsStyle.recColors) {
                MeetingsCompactLeading()
            } trailing: {
                MeetingsCompactTrailing(start: start)
            }.accessibility(model.record == .recording ? "Идёт запись встречи" : "Запись встречи отправляется"))
            ctx.setStatusDot(IslandPalette.err, priority: 60)
        } else {
            ctx.removeActivity(id: recordingActivity)
            ctx.setStatusDot(nil)
        }
        if model.record == .idle, let (_, s) = model.processing.min(by: { $0.key < $1.key }) {
            let pct = s.percent
            ctx.post(IslandActivity(id: processingActivity, moduleId: moduleId, priority: 25, sideWidth: 60) {
                MeetingsProcessingLeading()
            } trailing: {
                MeetingsProcessingTrailing(percent: pct)
            }.accessibility("Sten обрабатывает встречу" + (pct.map { ", \(Int($0)) %" } ?? "")))
        } else {
            ctx.removeActivity(id: processingActivity)
        }
    }

    private func ready(_ m: StenMeeting) {
        guard let ctx = context else { return }
        ctx.showNotification(Self.readyNotification(m, ctx: ctx, model: model))
        ctx.setAttention(.done, text: "Протокол готов: \(m.title)")
    }

    static func readyNotification(_ m: StenMeeting, ctx: ModuleContext, model: MeetingsModel) -> IslandNotification {
        IslandNotification(id: "meetings.ready.\(m.id)", moduleId: moduleId, title: "Протокол готов",
                           source: "Sten", body: m.title, avatarColors: MeetingsStyle.gradient,
                           systemImage: "person.2.wave.2.fill",
                           actions: [IslandNotificationAction("Открыть", role: .primary) {
                               model.open(m.id)
                               ctx.openTab()
                           }],
                           duration: 8)
    }

    // MARK: Снимки

    public func snapshotStates() -> [ModuleSnapshot] {
        let snap = { (name: String, presentation: ModuleSnapshot.Presentation, apply: @escaping (ModuleContext) -> Void) in
            ModuleSnapshot(name, presentation: presentation) { ctx in
                if let i = ctx.settings.data.tabs.firstIndex(where: { $0.id == Self.moduleId }) {
                    ctx.settings.data.tabs[i].enabled = true
                }
                apply(ctx)
            }
        }
        let now = Date()
        let list = Self.mockMeetings(now: now)
        return [
            snap("login", .expanded) { _ in self.model.mock(auth: .loggedOut) },
            snap("login-error", .expanded) { _ in
                self.model.mock(auth: .loggedOut, authMessage: "Неверное имя или пароль")
            },
            snap("empty", .expanded) { _ in self.model.mock(auth: .loggedIn("Илья")) },
            snap("list", .expanded) { _ in
                self.model.mock(auth: .loggedIn("Илья"), meetings: list,
                                processing: [list[0].id: StenStatus(status: "processing", percent: 42, label: "Распознаю речь…", step: 1)])
            },
            snap("recording", .expanded) { _ in
                var l = list; l.insert(StenMeeting(id: 99, title: "Встреча 2026-11-16 15:42", createdAt: now, status: "recording"), at: 0)
                self.model.mock(auth: .loggedIn("Илья"), meetings: l, record: .recording,
                                recordStart: now.addingTimeInterval(-754))
            },
            snap("report", .expanded) { _ in
                self.model.mock(auth: .loggedIn("Илья"), meetings: list, selected: list[1].id, report: Self.mockReport)
            },
            snap("report-processing", .expanded) { _ in
                self.model.mock(auth: .loggedIn("Илья"), meetings: list,
                                processing: [list[0].id: StenStatus(status: "processing", percent: 67, label: "Собираю итог…", step: 2)],
                                selected: list[0].id)
            },
            snap("compact-recording", .compact) { ctx in
                self.model.mock(auth: .loggedIn("Илья"), meetings: list, record: .recording,
                                recordStart: now.addingTimeInterval(-754))
                Self.present(model: self.model, ctx: ctx)
            },
            snap("compact-processing", .compact) { ctx in
                self.model.mock(auth: .loggedIn("Илья"), meetings: list,
                                processing: [list[0].id: StenStatus(status: "processing", percent: 42)])
                Self.present(model: self.model, ctx: ctx)
            },
            snap("ready-notification", .automatic) { ctx in
                self.model.mock(auth: .loggedIn("Илья"), meetings: list)
                ctx.showNotification(Self.readyNotification(list[1], ctx: ctx, model: self.model))
            },
        ]
    }

    static func mockMeetings(now: Date) -> [StenMeeting] {
        [StenMeeting(id: 141, title: "Планёрка по релизу", createdAt: now.addingTimeInterval(-1500), status: "processing"),
         StenMeeting(id: 138, title: "Созвон с дизайнерами", createdAt: now.addingTimeInterval(-6 * 3600), status: "consensus"),
         StenMeeting(id: 131, title: "Разбор обратной связи", createdAt: now.addingTimeInterval(-30 * 3600), status: "ready"),
         StenMeeting(id: 127, title: "Встреча 2026-11-12 10:00", createdAt: now.addingTimeInterval(-4 * 86400), status: "error")]
    }

    /// Вымышленные люди и задачи (как в макетах).
    static var mockReport: StenReport {
        StenReport(json: [
            "available": true,
            "title": "Созвон с дизайнерами",
            "summary": "Обсудили новую вкладку «Встречи»: запись прямо из острова и протокол с задачами по людям.",
            "outcome": "Макет утверждён, к пятнице — первая сборка для проверки на живом сервере.",
            "participants": [["speaker": "Анна", "role": "дизайн"], ["speaker": "Максим", "role": "сервер"],
                             ["speaker": "Илья", "role": "приложение"], ["speaker": "Лена"]],
            "decisions": [["text": "Компакт при записи — красная точка и таймер", "initiator": "Анна"],
                          ["text": "Куски по 2 с, как в вебе", "initiator": "Максим"]],
            "tasks": [["text": "Нарисовать пустое состояние списка", "assignee": "Анна", "due": "среда"],
                      ["text": "Отдавать прогресс обработки в процентах", "assignee": "Максим"],
                      ["text": "Собрать модуль и самотест", "assignee": "Илья", "due": "пятница"],
                      ["text": "Проверить запись на AirPods", "assignee": "Илья и Анна"],
                      ["text": "Решить, где хранить старые записи"]],
        ] as [String: Any])
    }
}

extension MeetingsModel {
    /// Подхватить сохранённые настройки (сервер, имя, хвосты) после создания модели.
    func applySaved(_ p: MeetingsPrefs) {
        let handler = saveHandler
        saveHandler = nil
        if p.server != prefs.server { setServer(p.server) }
        updatePrefs { $0 = p }
        if client.cookie != nil, case .loggedIn(let n) = auth, n.isEmpty, let name = p.userName {
            setLoggedInName(name)
        }
        saveHandler = handler
    }
}
