import SwiftUI
import IslandCore

/// Модуль «Сегодня» (макет 03): следующая встреча, погода, нагрузка, батареи, буфер обмена, быстрые тумблеры.
/// Контракт — docs/ARCHITECTURE.md. Собирается отдельно:
///   swift build --target TodayModule --scratch-path .build-today
@MainActor
public final class TodayIslandModule: IslandModule {
    public let id = TodayModel.moduleId
    public let title = "Сегодня"
    public let systemImage = "calendar"
    public var providesTab: Bool { true }
    public var expandedHeight: CGFloat {
        TodayLayout.height(rows: TodayLayout.rows(model.prefs.enabledTiles).count)
    }

    let model = TodayModel()

    public init() {}

    public func start(context: ModuleContext) {
        model.start(context: context)
    }

    public func stop() {
        model.stop()
    }

    public func expandedView() -> AnyView? {
        AnyView(TodayView(model: model))
    }

    public func settingsView() -> AnyView? {
        AnyView(TodaySettingsView(model: model))
    }

    public func snapshotStates() -> [ModuleSnapshot] {
        [
            ModuleSnapshot("full-day", presentation: .expanded) { _ in TodayMocks.apply(.fullDay, to: self.model) },
            ModuleSnapshot("no-calendar", presentation: .expanded) { _ in TodayMocks.apply(.noCalendar, to: self.model) },
            ModuleSnapshot("offline", presentation: .expanded) { _ in TodayMocks.apply(.offline, to: self.model) },
            ModuleSnapshot("overlap", presentation: .expanded) { _ in TodayMocks.apply(.overlap, to: self.model) },
            ModuleSnapshot("toggle-permission", presentation: .expanded) { _ in TodayMocks.apply(.needsAutomation, to: self.model) },
            ModuleSnapshot("compact-meeting", presentation: .compact) { ctx in
                TodayMocks.apply(.fullDay, to: self.model)
                if let e = TodayMocks.meeting(now: self.model.now) {
                    ctx.post(TodayModel.meetingActivity(e, staticCountdown: "4:12"))
                }
            },
        ]
    }
}
