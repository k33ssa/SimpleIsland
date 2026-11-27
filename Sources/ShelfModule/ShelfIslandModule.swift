import SwiftUI
import IslandCore

/// Модуль «Полка» (макет 04): файлы, брошенные на остров, — на полку или в цель (AirDrop, «Поделиться», ZIP,
/// конвертер, распознавание текста, вырезание фона, свои скрипты/Shortcuts). Контракт — docs/ARCHITECTURE.md.
/// Права не нужны: всё локально, без сети; AirDrop и «Поделиться» — системные службы.
@MainActor
public final class ShelfIslandModule: IslandModule {
    public let id = "shelf"
    public let title = "Полка"
    public let systemImage = "tray.fill"
    public var providesTab: Bool { true }
    public var acceptsFileDrops: Bool { true }
    public var expandedHeight: CGFloat { ShelfExpandedView.contentHeight }

    let model: ShelfModel
    private weak var context: ModuleContext?
    /// Пустой центр для вьюхи до `start` (снимки без привязки).
    private let fallbackIsland = IslandStateCenter()

    public init() { model = ShelfModel() }

    public func start(context: ModuleContext) {
        self.context = context
        model.start(context)
    }

    public func stop() {
        model.stop()
        context?.activities.removeAll(moduleId: id)
        context = nil
    }

    /// Бросок мимо плиток (или в компакте) — на полку.
    public func handleDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        model.acceptDropped(files, on: .shelf)
        return true
    }

    /// Папка приёма обещаний/картинок: `Shelf/incoming/<uuid>` — своя на каждый бросок (ядро берёт её один раз).
    public var dropIncomingDirectory: URL { model.newIncomingDir() }

    public func expandedView() -> AnyView? {
        AnyView(ShelfExpandedView(model: model, island: model.context?.island ?? fallbackIsland))
    }

    public func settingsView() -> AnyView? { AnyView(ShelfSettingsView(model: model)) }

    public func snapshotStates() -> [ModuleSnapshot] {
        [
            ModuleSnapshot("drag-target", presentation: .expanded) { ctx in
                self.model.attach(ctx)
                self.model.applyMock(items: ShelfModel.mockItems(), dragging: true, hot: .airdrop,
                                     summary: "2 файла · 14,2 МБ")
                ctx.setGlow([Color(hex: "#4AA8FF"), Color(hex: "#1D4FD8")])
            },
            ModuleSnapshot("shelf", presentation: .expanded) { ctx in
                self.model.attach(ctx)
                let items = ShelfModel.mockItems()
                self.model.applyMock(items: items, selection: [items[1].id])
            },
            ModuleSnapshot("empty", presentation: .expanded) { ctx in
                self.model.attach(ctx)
                self.model.applyMock(items: [])
            },
            ModuleSnapshot("processing", presentation: .expanded) { ctx in
                self.model.attach(ctx)
                self.model.applyMock(items: ShelfModel.mockItems(),
                                     busy: .init(target: .text, progress: 0.42, count: 1))
            },
            ModuleSnapshot("processing-compact", presentation: .compact) { ctx in
                self.model.attach(ctx)
                self.model.applyMock(items: ShelfModel.mockItems(),
                                     busy: .init(target: .text, progress: 0.42, count: 1))
                ctx.post(ShelfModel.activity(model: self.model, moduleId: self.id))
            },
            ModuleSnapshot("done-notification") { ctx in
                self.model.attach(ctx)
                ctx.notifications.show(IslandNotification(
                    moduleId: self.id, title: "Скопировано 12 строк", source: "Текст",
                    body: "Лабораторная работа № 4. Измерение сопротивления",
                    avatarColors: ShelfTarget.text.gradient ?? [], systemImage: "text.viewfinder",
                    duration: nil))
            },
        ]
    }
}
