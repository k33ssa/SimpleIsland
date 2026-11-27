import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import IslandCore

// «Раскладка» (макет 08-editor): живое превью острова, вкладки перетаскиванием, уши компакта, библиотека модулей,
// справа — инспектор «Остров целиком» (форма, физика, наведение, свечение, жесты, правила) или выбранного модуля.

struct LayoutEditorSection: View {
    let env: AppEnvironment
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var settings: SimpleIslandSettings
    @Environment(\.settingsPalette) private var p

    init(env: AppEnvironment, nav: SettingsNavigation) {
        self.env = env; self.nav = nav; settings = env.settings
    }

    var body: some View {
        SettingsHeader(title: "Раскладка", subtitle: "Тащи модули в уши и вкладки. Всё меняется вживую — остров сверху уже такой.")
        SettingsIslandPreview(env: env, nav: nav)
        VStack(alignment: .leading, spacing: 8) {
            SettingsLabel("Вкладки раскрытого острова — порядок перетаскиванием")
            TabOrderList(env: env, nav: nav, settings: settings)
        }
        VStack(alignment: .leading, spacing: 8) {
            // --- catalog --- кнопка каталога виджетов (окно — WidgetCatalogWindow.swift)
            HStack(alignment: .center) {
                SettingsLabel("Библиотека модулей")
                SettingsButton(title: "Каталог виджетов…", systemImage: "square.grid.2x2", style: .accent, height: 28) {
                    WidgetCatalogWindow.shared.show(env: env)
                }
            }
            ModuleLibrary(env: env, nav: nav)
        }
    }
}

// MARK: - Порядок вкладок

/// Перестановка вкладки `id` на место `target` (общая для перетаскивания и самотеста). Вкладка встаёт на сторону
/// выреза, где стоит `target` (тащить можно и между секциями «Слева / Справа от выреза»).
enum TabOrder {
    static func move(_ tabs: inout [TabSetting], id: String, before target: String) {
        TabArrangement.move(&tabs, id: id, before: target)
    }
}

/// Вкладки раскрытого острова двумя секциями — «Слева от выреза» и «Справа от выреза» (16.11). Перетаскивание —
/// внутри секции и между ними (на строку — встать перед ней, на заголовок — в начало секции, под последнюю строку
/// или в пустую секцию — в конец), стрелка у строки переносит на другую сторону.
private struct TabOrderList: View {
    let env: AppEnvironment
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var settings: SimpleIslandSettings
    @StateObject private var drag = TabDragState()
    @Environment(\.settingsPalette) private var p
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(.left)
            section(.right)
        }
    }

    private func section(_ side: TabSide) -> some View {
        let tabs = TabArrangement.tabs(settings.data.tabs, on: side)
        return VStack(alignment: .leading, spacing: 6) {
            header(side, count: tabs.filter(\.enabled).count)
                .liveOnly(isSnapshot) { v in
                    v.onDrop(of: [UTType.plainText], delegate: TabSectionDropDelegate(side: side, atStart: true,
                                                                                      drag: drag, settings: settings))
                }
            if tabs.isEmpty {
                placeholder(side)
                    .liveOnly(isSnapshot) { v in
                        v.onDrop(of: [UTType.plainText], delegate: TabSectionDropDelegate(side: side, atStart: false,
                                                                                          drag: drag, settings: settings))
                    }
            } else {
                ForEach(tabs) { tab in
                    row(tab)
                        .liveOnly(isSnapshot) { v in
                            v.onDrag {
                                drag.begin(tab.id)
                                return NSItemProvider(object: tab.id as NSString)
                            }
                            .onDrop(of: [UTType.plainText], delegate: TabDropDelegate(target: tab.id, drag: drag,
                                                                                       settings: settings))
                            .contextMenu { menu(tab) }
                        }
                }
                // Под последней строкой — бросок «в конец секции».
                Color.clear.frame(height: 6).contentShape(Rectangle())
                    .liveOnly(isSnapshot) { v in
                        v.onDrop(of: [UTType.plainText], delegate: TabSectionDropDelegate(side: side, atStart: false,
                                                                                          drag: drag, settings: settings))
                    }
            }
        }
    }

    private func header(_ side: TabSide, count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: side == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink3)
            Text(side.title).font(p.font(12.5, .semibold)).foregroundStyle(p.ink2)
            Text("\(count)").font(p.font(11, .bold)).foregroundStyle(p.ink4)
                .padding(.horizontal, 6).frame(height: 17)
                .background(Capsule().fill(p.card.opacity(1.2)))
            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(side.title), вкладок: \(count)")
    }

    private func placeholder(_ side: TabSide) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .semibold))
            Text("Перетащи сюда вкладку").font(p.font(12.5, .medium))
        }
        .foregroundStyle(p.ink4)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(p.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
    }

    private func row(_ tab: TabSetting) -> some View {
        let m = env.module(id: tab.id)
        let selected = nav.selectedModule == tab.id
        let idx = settings.data.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .bold)).foregroundStyle(p.ink4)
            Image(systemName: m?.systemImage ?? "square").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(p.ink).frame(width: 18)
            Text(m?.title ?? tab.id).font(p.font(13.5, .semibold)).foregroundStyle(p.ink)
            Text(SettingsModuleStyle.note(tab.id)).font(p.font(12, .medium)).foregroundStyle(p.ink4).lineLimit(1)
            Spacer(minLength: 8)
            flipButton(tab)
            SettingsToggle(isOn: Binding(get: { settings.data.tabs[idx].enabled },
                                         set: { settings.data.tabs[idx].enabled = $0 }))
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.card.opacity(1.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? p.accent : .clear, lineWidth: 1.5))
        .opacity(drag.id == tab.id ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { nav.selectedModule = selected ? nil : tab.id; nav.previewCompact = false }
    }

    /// Стрелка «перенести на другую сторону выреза» — для тех, кому неудобно тащить.
    private func flipButton(_ tab: TabSetting) -> some View {
        let title = tab.side == .left ? "Перенести направо от выреза" : "Перенести налево от выреза"
        return Button { flip(tab.id) } label: {
            Image(systemName: tab.side == .left ? "arrow.right" : "arrow.left")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(p.ink3)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.card.opacity(1.4)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(p.hair, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func menu(_ tab: TabSetting) -> some View {
        let same = TabArrangement.tabs(settings.data.tabs, on: tab.side)
        Button("Выше") { step(tab.id, -1) }.disabled(same.first?.id == tab.id)
        Button("Ниже") { step(tab.id, 1) }.disabled(same.last?.id == tab.id)
        Button(tab.side == .left ? "Направо от выреза" : "Налево от выреза") { flip(tab.id) }
        Divider()
        Button("В левое ухо") { settings.data.leftEarModule = tab.id }
        Button("В правое ухо") { settings.data.rightEarModule = tab.id }
    }

    private func step(_ id: String, _ d: Int) {
        withAnimation(.easeOut(duration: 0.18)) { TabArrangement.step(&settings.data.tabs, id: id, by: d) }
    }

    private func flip(_ id: String) {
        withAnimation(.easeOut(duration: 0.18)) { TabArrangement.flip(&settings.data.tabs, id: id) }
    }
}

/// Какую вкладку тащат. Сбрасывается броском на строку или (бросили мимо, отменили, бросили на ухо) — когда
/// кнопка мыши отпущена: проверка раз в 0,2 с только пока идёт перетаскивание.
@MainActor
final class TabDragState: ObservableObject {
    @Published private(set) var id: String?
    private var watching = false
    private var releasedChecks = 0

    func begin(_ id: String) {
        self.id = id
        releasedChecks = 0
        if !watching { watching = true; watch() }
    }

    func end() { if id != nil { id = nil } }

    private func watch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.id != nil else { self.watching = false; return }
                // Две проверки подряд с отпущенной кнопкой — бросок (performDrop) уже точно прошёл.
                self.releasedChecks = NSEvent.pressedMouseButtons & 1 == 0 ? self.releasedChecks + 1 : 0
                if self.releasedChecks >= 2 { self.end(); self.watching = false } else { self.watch() }
            }
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: String
    let drag: TabDragState
    let settings: SimpleIslandSettings

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let d = drag.id, d != target else { return }
            withAnimation(.easeOut(duration: 0.18)) { TabOrder.move(&settings.data.tabs, id: d, before: target) }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { drag.id == nil ? DropProposal(operation: .forbidden) : DropProposal(operation: .move) }
    }
    /// Принимаем только вкладку из этого списка; чип библиотеки на строку вкладки — не бросок.
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let wasTab = drag.id != nil
            drag.end()
            return wasTab
        }
    }
    func dropExited(info: DropInfo) {}
}

/// Бросок на заголовок секции (в начало стороны), под последнюю строку или в пустую секцию (в конец стороны).
private struct TabSectionDropDelegate: DropDelegate {
    let side: TabSide
    let atStart: Bool
    let drag: TabDragState
    let settings: SimpleIslandSettings

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let d = drag.id else { return }
            let tabs = settings.data.tabs
            let same = TabArrangement.tabs(tabs, on: side)
            if atStart, let first = same.first {
                guard first.id != d else { return }
                withAnimation(.easeOut(duration: 0.18)) { TabArrangement.move(&settings.data.tabs, id: d, before: first.id) }
            } else {
                guard same.last?.id != d else { return }
                withAnimation(.easeOut(duration: 0.18)) { TabArrangement.moveToEnd(&settings.data.tabs, id: d, side: side) }
            }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { drag.id == nil ? DropProposal(operation: .forbidden) : DropProposal(operation: .move) }
    }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let wasTab = drag.id != nil
            drag.end()
            return wasTab
        }
    }
}

// MARK: - Библиотека

private struct ModuleLibrary: View {
    let env: AppEnvironment
    @ObservedObject var nav: SettingsNavigation
    @Environment(\.settingsPalette) private var p
    @Environment(\.isSnapshot) private var isSnapshot

    /// Что будет (макет 08): пока не модули, а обещания — чипы пунктиром.
    static let upcoming: [(String, String)] = [
        ("Таймер / помодоро", "timer"), ("Погода", "cloud"), ("Нагрузка", "cpu"), ("Пинг сервера", "globe"),
        ("Буфер", "doc.on.clipboard"), ("Зеркало", "camera"), ("Telegram", "paperplane"),
        ("CI / GitHub", "arrow.triangle.branch"), ("Свой скрипт…", "terminal"), ("Shortcuts…", "plus"),
    ]

    var body: some View {
        FlowRows(spacing: 8) {
            ForEach(env.modules, id: \.id) { m in
                chip(m.title, m.systemImage, installed: true)
                    .liveOnly(isSnapshot || !m.providesTab) { $0.onDrag { NSItemProvider(object: m.id as NSString) } }
                    .onTapGesture { nav.section = .module(m.id) }
                    .help("Перетащи на ухо в превью или открой настройки модуля")
            }
            ForEach(Self.upcoming, id: \.0) { u in
                chip(u.0, u.1, installed: false).help("Скоро")
            }
        }
    }

    private func chip(_ title: String, _ icon: String, installed: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).font(p.font(12.5, .semibold)).lineLimit(1)
            if !installed { Text("скоро").font(p.font(10, .bold)).foregroundStyle(p.ink4) }
        }
        .foregroundStyle(installed ? p.ink2 : p.ink3)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(installed ? p.card.opacity(1.2) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(p.hair, style: StrokeStyle(lineWidth: 1, dash: installed ? [] : [4, 3])))
        .contentShape(Rectangle())
    }
}

/// Перенос чипов по строкам.
struct FlowRows: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > w { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Живое превью

/// Отдельное окружение превью: те же настройки, темы и модули (их вкладки — настоящие), но свои центры —
/// заглушки активностей превью не попадают в настоящий остров.
@MainActor
final class SettingsPreviewHolder: ObservableObject {
    let env: AppEnvironment
    let model: IslandModel
    let source: AppEnvironment
    private var bag = Set<AnyCancellable>()

    init(source: AppEnvironment, nav: SettingsNavigation) {
        self.source = source
        env = AppEnvironment(settings: source.settings, themes: source.themes, modules: source.modules,
                             isSnapshot: source.isSnapshot)
        model = IslandModel(env: env, geometry: source.isSnapshot ? .mockNotch : Self.realNotch())
        model.onOpenSettings = {}
        source.activities.$activities
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncActivities() } } }
            .store(in: &bag)
        source.activities.$ambientGlows
            .sink { [weak self] glows in
                for (id, c) in glows { self?.env.activities.setAmbientGlow(c, for: id) }
            }
            .store(in: &bag)
        source.settings.$data
            .map { [$0.leftEarModule ?? "", $0.rightEarModule ?? ""] }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncActivities() } } }
            .store(in: &bag)
        // Модель превью следует за редактором: компакт/раскрытый и выбранная вкладка.
        Publishers.CombineLatest3(nav.$previewCompact, nav.$selectedModule, source.settings.$data.map(\.tabs))
            .sink { [weak self] compact, selected, _ in self?.follow(compact: compact, selected: selected) }
            .store(in: &bag)
        syncActivities()
        if env.activities.ambientGlows["media"] == nil {
            env.activities.setAmbientGlow(ArtworkView.glowColors(for: .warm), for: "media")
        }
    }

    /// Вырез этого Мака (185×32 и т. п.), если есть экран с вырезом; иначе — как в макетах 186×38.
    static func realNotch() -> IslandGeometry {
        for screen in NSScreen.screens {
            if let g = IslandGeometry.detect(screen, floatingAllowed: false), g.hasNotch {
                return IslandGeometry(notchWidth: g.notchWidth, notchHeight: g.notchHeight, hasNotch: true,
                                      topOffset: 0, centerX: 0, screenTop: 0)
            }
        }
        return .mockNotch
    }

    private func follow(compact: Bool, selected: String?) {
        let tabs = env.enabledTabModules
        let tab = selected.flatMap { id in tabs.first { $0.id == id }?.id } ?? tabs.first?.id
        if model.expanded == compact { model.expanded = !compact }
        if model.selectedTab != tab { model.selectedTab = tab }
    }

    /// Активности превью: настоящие + заглушки для модулей в ушах (и медиа, если ничего нет).
    func syncActivities() {
        let real = source.activities.activities
        for a in env.activities.activities { env.activities.remove(id: a.id) }
        for a in real { env.activities.post(a) }
        let d = source.settings.data
        var need = [d.leftEarModule, d.rightEarModule].compactMap { $0 }
        if real.isEmpty && need.isEmpty { need = ["media"] }
        if real.isEmpty, !need.contains("media"), d.leftEarModule == nil || d.rightEarModule == nil { need.insert("media", at: 0) }
        for (i, id) in need.enumerated() where env.activities.topActivity(moduleId: id) == nil {
            env.activities.post(Self.standIn(for: id, title: source.module(id: id)?.title ?? id,
                                             systemImage: source.module(id: id)?.systemImage ?? "square",
                                             priority: -1 - i))
        }
    }

    /// Похоже на то, что модуль покажет в ушах (мок, только для превью).
    static func standIn(for id: String, title: String, systemImage: String, priority: Int) -> IslandActivity {
        IslandActivity(id: "preview.\(id)", moduleId: id, priority: priority, sideWidth: id == "media" ? 56 : 74,
                       glowColors: id == "media" ? ArtworkView.glowColors(for: .warm) : nil) {
            PreviewEar(id: id, systemImage: systemImage, leading: true)
        } trailing: {
            PreviewEar(id: id, systemImage: systemImage, leading: false)
        }
    }
}

struct PreviewEar: View {
    var id: String
    var systemImage: String
    var leading: Bool
    @Environment(\.islandTheme) private var theme
    var body: some View {
        switch (id, leading) {
        case ("media", true): ArtworkView(cornerRadius: 6).frame(width: 22, height: 22)
        case ("media", false): Visualizer(bars: 5)
        case ("agents", true): label("terminal.fill", "2", IslandPalette.okText(theme))
        case ("agents", false): HStack(spacing: 5) { StatusDot(IslandPalette.warn); text("ждёт", IslandPalette.warmText(theme)) }
        case ("today", true): label("calendar", "15:00", theme.primary)
        case ("today", false): text("12 мин", IslandPalette.warmText(theme))
        case ("shelf", true): label("tray.full.fill", "3", theme.primary)
        case ("shelf", false): Ring(value: 0.68, lineWidth: 3, tint: IslandPalette.warn).frame(width: 18, height: 18)
        default: Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
        }
    }
    private func label(_ icon: String, _ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 12, weight: .bold)); text(t, c) }.foregroundStyle(c)
    }
    private func text(_ t: String, _ c: Color) -> some View {
        Text(t).font(theme.font(12, .bold)).foregroundStyle(c).monospacedDigit().lineLimit(1)
    }
}

/// Сцена с настоящим `IslandRootView` в миниатюре: раскрытый на выбранной вкладке или компакт с ушами.
struct SettingsIslandPreview: View {
    let env: AppEnvironment
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var settings: SimpleIslandSettings
    @StateObject private var holder: SettingsPreviewHolder
    @Environment(\.settingsPalette) private var p

    init(env: AppEnvironment, nav: SettingsNavigation) {
        self.env = env; self.nav = nav; settings = env.settings
        _holder = StateObject(wrappedValue: SettingsPreviewHolder(source: env, nav: nav))
    }

    var body: some View {
        let model = holder.model
        let compact = nav.previewCompact
        let m = model.currentMetrics
        GeometryReader { g in
            let avail = g.size.width - 48
            let scale = compact ? 1.6 : Self.scale(m, avail: avail)
            let islandH = m.height * scale
            ZStack(alignment: .top) {
                stageBackground
                menuBar
                IslandRootView(model: model)
                    .overlay(alignment: .top) {
                        // Выбран «остров целиком» — обводка акцентом, как выделение в макете 08.
                        if !compact && nav.selectedModule == nil {
                            IslandShape(m).stroke(p.accent.opacity(0.9), lineWidth: 1.5 / max(scale, 0.1))
                                .frame(width: m.outerWidth, height: m.height)
                        }
                    }
                    .frame(width: max(m.outerWidth + 160, 700), height: m.height + 90)
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: g.size.width, height: islandH + 20, alignment: .top)
                    .clipped()
                    .allowsHitTesting(false)
                UnevenRoundedRectangle(bottomLeadingRadius: 10 * scale, bottomTrailingRadius: 10 * scale)
                    .fill(Color.black)
                    .frame(width: model.geometry.notchWidth * scale, height: model.geometry.notchHeight * scale)
                if !compact {
                    handles(width: m.width * scale, y: islandH / 2, total: g.size.width, scale: scale)
                }
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    // Слоты ушей — в обоих режимах (в раскрытом по бокам от размера), как плашки ушей в макете 08.
                    if compact {
                        EarSlots(env: env, settings: settings, earWidth: m.width)
                    } else {
                        HStack(spacing: 12) {
                            EarSlot(env: env, settings: settings, leading: true)
                            Text("\(Int(m.width)) × \(Int(m.height)) pt")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(hex: "#FFB36E"))
                                .fixedSize()
                            EarSlot(env: env, settings: settings, leading: false)
                        }
                    }
                    HStack {
                        // Сцена превью всегда тёмная: цвета тёмные, шрифт — темы.
                        SettingsSegmented(options: [(false, "Раскрытый"), (true, "Компакт · уши")],
                                          selection: $nav.previewCompact)
                            .frame(width: 230)
                            .environment(\.settingsPalette, SettingsPalette(theme: p.theme.isLight ? .obsidian : p.theme))
                        Spacer()
                        if !compact, let tab = model.currentTab {
                            Text("вкладка: \(tab.title)").font(p.font(11.5, .semibold)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(height: compact ? 230 : m.height * Self.scale(m, avail: 700) + 104)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.hair))
    }

    /// Раскрытый остров уменьшается под ширину сцены и не выше ~200 pt (превью не сдвигает список вниз).
    static func scale(_ m: IslandMetrics, avail: CGFloat) -> CGFloat {
        min(1, avail / max(1, m.outerWidth), 200 / max(1, m.height))
    }

    private var stageBackground: some View {
        ZStack {
            Color(hex: "#120C1E")
            RadialGradient(colors: [Color(hex: "#FF6A3D").opacity(0.33), .clear], center: UnitPoint(x: 0.3, y: 1),
                           startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(hex: "#C2187A").opacity(0.33), .clear], center: UnitPoint(x: 0.8, y: 0.9),
                           startRadius: 0, endRadius: 380)
        }
    }

    private var menuBar: some View {
        HStack {
            Text("Finder")
            Spacer()
            Text("22:30").monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    /// Ручки по бокам: тянуть — ширина раскрытого острова.
    private func handles(width: CGFloat, y: CGFloat, total: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            WidthHandle(settings: settings, side: -1, scale: scale)
                .position(x: total / 2 - (width / 2 + 2), y: y)
            WidthHandle(settings: settings, side: 1, scale: scale)
                .position(x: total / 2 + (width / 2 + 2), y: y)
        }
        .frame(width: total, height: y * 2 + 20, alignment: .topLeading)
    }
}

/// Ручка ширины: тянуть влево/вправо — ширина раскрытого острова (шаг 10 pt, 520…900).
private struct WidthHandle: View {
    @ObservedObject var settings: SimpleIslandSettings
    var side: CGFloat
    var scale: CGFloat
    @State private var startWidth: Double?
    @Environment(\.settingsPalette) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(p.accent, lineWidth: 2))
            .frame(width: 10, height: 10)
            .padding(6)
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged(changed).onEnded { _ in startWidth = nil })
            .pointerStyle(.columnResize)   // курсор-стрелки без пар push/pop, не «залипает»
    }

    private func changed(_ v: DragGesture.Value) {
        let start = startWidth ?? settings.data.expandedWidth
        if startWidth == nil { startWidth = start }
        let delta = Double(side * v.translation.width * 2 / max(scale, 0.1))
        settings.data.expandedWidth = min(900, max(520, ((start + delta) / 10).rounded() * 10))
    }
}

/// Слоты ушей под компактом: щёлкни — выбери модуль, или брось чип модуля из библиотеки.
private struct EarSlots: View {
    let env: AppEnvironment
    @ObservedObject var settings: SimpleIslandSettings
    var earWidth: CGFloat
    @Environment(\.settingsPalette) private var p

    var body: some View {
        HStack(spacing: 14) {
            EarSlot(env: env, settings: settings, leading: true)
            Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.35))
            EarSlot(env: env, settings: settings, leading: false)
        }
    }
}

private struct EarSlot: View {
    let env: AppEnvironment
    @ObservedObject var settings: SimpleIslandSettings
    var leading: Bool
    @State private var picking = false
    @State private var targeted = false
    @Environment(\.settingsPalette) private var p
    @Environment(\.isSnapshot) private var isSnapshot

    private var assigned: String? { leading ? settings.data.leftEarModule : settings.data.rightEarModule }

    var body: some View {
        let title = assigned.map { "\(env.module(id: $0)?.title ?? $0) · \(SettingsModuleStyle.earPart($0, leading: leading))" }
            ?? "авто"
        HStack(spacing: 6) {
            Image(systemName: assigned.flatMap { env.module(id: $0)?.systemImage } ?? "sparkles")
                .font(.system(size: 11, weight: .semibold))
            Text("\(leading ? "Левое" : "Правое") ухо: \(title)").font(p.font(11.5, .semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
        }
        .foregroundStyle(.white.opacity(assigned == nil ? 0.6 : 0.92))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(targeted ? p.accent.opacity(0.25) : Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(targeted || assigned != nil ? p.accent.opacity(0.9) : Color.white.opacity(0.18),
                                        style: StrokeStyle(lineWidth: 1.2, dash: assigned == nil ? [4, 3] : [])))
        .contentShape(Capsule())
        .onTapGesture { picking = true }
        .liveOnly(isSnapshot) { v in
            v.onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
                guard let pr = providers.first else { return false }
                _ = pr.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let id = obj as? String else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { set(id) } }
                }
                return true
            }
            .popover(isPresented: $picking, arrowEdge: .bottom) { picker }
        }
    }

    private func set(_ id: String?) {
        guard id == nil || env.module(id: id!)?.providesTab == true else { return }   // HUD и т. п. — без активности в ушах
        if leading { settings.data.leftEarModule = id } else { settings.data.rightEarModule = id }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            option(nil, "Авто — как у главной активности", "sparkles")
            Divider().padding(.vertical, 3)
            ForEach(env.modules.filter(\.providesTab), id: \.id) { m in   // у HUD нет компакт-активности
                option(m.id, "\(m.title) · \(SettingsModuleStyle.earPart(m.id, leading: leading))", m.systemImage)
            }
        }
        .padding(8)
        .frame(width: 270)
    }

    private func option(_ id: String?, _ title: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18)
            Text(title)
            Spacer()
            if assigned == id { Image(systemName: "checkmark").foregroundStyle(p.accent) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture { set(id); picking = false }
    }
}

// MARK: - Инспектор

enum PhysicsPreset: String, CaseIterable {
    case soft, spring, snappy, custom
    var title: String {
        switch self {
        case .soft: return "Мягко"
        case .spring: return "Пружина"
        case .snappy: return "Резко"
        case .custom: return "Своя"
        }
    }
    /// (response, damping); nil — значения темы.
    var values: (Double, Double)? {
        switch self {
        case .soft: return (0.55, 0.92)
        case .snappy: return (0.28, 0.96)
        case .spring, .custom: return nil
        }
    }

    static func detect(_ d: SettingsData) -> PhysicsPreset {
        guard let r = d.springResponse, let dm = d.springDamping else {
            return d.springResponse == nil && d.springDamping == nil ? .spring : .custom
        }
        for p in [PhysicsPreset.soft, .snappy] {
            if let v = p.values, abs(v.0 - r) < 0.001, abs(v.1 - dm) < 0.001 { return p }
        }
        return .custom
    }

    func apply(to d: inout SettingsData, theme: Theme) {
        switch self {
        case .spring: d.springResponse = nil; d.springDamping = nil
        case .soft, .snappy: d.springResponse = values!.0; d.springDamping = values!.1
        case .custom:
            // Своя — от текущих значений; если они совпали с пресетом, чуть сдвинуть, чтобы было видно «Своя».
            let wasPreset = [.soft, .snappy].contains(Self.detect(d))
            d.springResponse = d.springResponse ?? theme.spring.response
            d.springDamping = (d.springDamping ?? theme.spring.damping) - (wasPreset ? 0.02 : 0)
        }
    }
}

struct SettingsInspector: View {
    let env: AppEnvironment
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var settings: SimpleIslandSettings
    @ObservedObject var themes: ThemeStore
    @Environment(\.settingsPalette) private var p

    init(env: AppEnvironment, nav: SettingsNavigation) {
        self.env = env; self.nav = nav; settings = env.settings; themes = env.themes
    }

    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 16) {
                if let id = nav.selectedModule, let m = env.module(id: id) {
                    moduleInspector(m)
                } else {
                    wholeIsland
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
    }

    // MARK: Остров целиком

    @ViewBuilder private var wholeIsland: some View {
        let base = themes.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SettingsIconTile(systemImage: "square.stack.3d.up.fill", colors: [Color(hex: "#FFB36E"), Color(hex: "#FF3D7F")])
                Text("Остров целиком").font(p.font(15, .bold)).foregroundStyle(p.ink)
            }
            Text("Форма, физика, жесты и правила — общие для всех модулей. Чтобы настроить модуль, выбери его слот.")
                .font(p.font(12)).foregroundStyle(p.ink3).fixedSize(horizontal: false, vertical: true)
        }
        group("Форма") {
            SettingsSlider(title: "Ширина раскрытого", value: $settings.data.expandedWidth, range: 520...900, step: 10,
                           format: { "\(Int($0)) pt" })
            SettingsSlider(title: "Скругление", value: bind(\.cornerRadius, base.shape.cornerRadius), range: 12...60, step: 1,
                           format: { "\(Int($0)) pt" })
            SettingsSlider(title: "Уши (сопряжение)", value: bind(\.earRadius, base.shape.earRadius), range: 0...30, step: 1,
                           format: { "\(Int($0)) pt" })
            SettingsSlider(title: "Скругление компакта", value: bind(\.compactCornerRadius, base.shape.compactCornerRadius),
                           range: 6...24, step: 1, format: { "\(Int($0)) pt" })
        }
        group("Физика") {
            SettingsSegmented(options: PhysicsPreset.allCases.map { ($0, $0.title) },
                              selection: Binding(get: { PhysicsPreset.detect(settings.data) },
                                                 set: { $0.apply(to: &settings.data, theme: base) }))
            SettingsSlider(title: "Перелёт", value: Binding(
                get: { 1 - (settings.data.springDamping ?? base.spring.damping) },
                set: { settings.data.springDamping = 1 - $0; if settings.data.springResponse == nil { settings.data.springResponse = base.spring.response } }),
                range: 0...0.6, step: 0.01, format: { String(format: "%.2f", $0) })
            SettingsSlider(title: "Скорость пружины", value: Binding(
                get: { settings.data.springResponse ?? base.spring.response },
                set: { settings.data.springResponse = $0; if settings.data.springDamping == nil { settings.data.springDamping = base.spring.damping } }),
                range: 0.2...0.9, step: 0.01, format: { String(format: "%.2f с", $0) })
        }
        group("Наведение и свечение") {
            SettingsSlider(title: "Задержка наведения", value: $settings.data.hoverDelay, range: 0...1, step: 0.01,  // как в «Жестах»
                           format: { "\(Int(($0 * 1000).rounded())) мс" })
            SettingsSlider(title: "Свечение под островом", value: $settings.data.glowIntensity, range: 0...1.5, step: 0.05,
                           format: { "\(Int(($0 * 100).rounded())) %" })
        }
        group("Жесты") { GestureTiles(settings: settings, columns: 2, limit: 4) }
        group("Правила") {
            SettingsToggleRow(title: "Прятать в полноэкранном", isOn: $settings.data.hideInFullscreen)
            SettingsToggleRow(title: "Прятать при показе экрана", isOn: $settings.data.hideWhileScreenSharing)
            SettingsToggleRow(title: "Отклик трекпада", isOn: $settings.data.swipeGestures)
            SettingsToggleRow(title: "Каплей на внешнем мониторе", isOn: $settings.data.floatingOnNotchlessScreens)
        }
        if hasOverrides {
            SettingsButton(title: "Вернуть значения темы", systemImage: "arrow.uturn.backward", style: .quiet, height: 26) {
                settings.data.cornerRadius = nil; settings.data.earRadius = nil; settings.data.compactCornerRadius = nil
                settings.data.springResponse = nil; settings.data.springDamping = nil
            }
        }
    }

    private var hasOverrides: Bool {
        let d = settings.data
        return d.cornerRadius != nil || d.earRadius != nil || d.compactCornerRadius != nil
            || d.springResponse != nil || d.springDamping != nil
    }

    // MARK: Модуль

    @ViewBuilder private func moduleInspector(_ m: IslandModule) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            Text("Остров целиком").font(p.font(12, .semibold))
        }
        .foregroundStyle(p.accent)
        .contentShape(Rectangle())
        .onTapGesture { nav.selectedModule = nil }
        HStack(spacing: 8) {
            SettingsIconTile(systemImage: m.systemImage, colors: SettingsModuleStyle.color(m.id))
            Text(m.title).font(p.font(15, .bold)).foregroundStyle(p.ink)
        }
        if let i = settings.data.tabs.firstIndex(where: { $0.id == m.id }) {
            group("Вкладка") {
                SettingsToggleRow(title: "Показывать вкладку", isOn: $settings.data.tabs[i].enabled)
            }
        }
        group("Уши компакта") {
            SettingsToggleRow(title: "Левое ухо: \(SettingsModuleStyle.earPart(m.id, leading: true))",
                              isOn: Binding(get: { settings.data.leftEarModule == m.id },
                                            set: { settings.data.leftEarModule = $0 ? m.id : nil }))
            SettingsToggleRow(title: "Правое ухо: \(SettingsModuleStyle.earPart(m.id, leading: false))",
                              isOn: Binding(get: { settings.data.rightEarModule == m.id },
                                            set: { settings.data.rightEarModule = $0 ? m.id : nil }))
        }
        group("Настройки модуля") {
            if let v = m.settingsView() { v } else {
                Text("Пока нечего настраивать.").font(p.font(12)).foregroundStyle(p.ink3)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsLabel(title)
            content()
        }
    }

    private func bind(_ kp: WritableKeyPath<SettingsData, Double?>, _ fallback: Double) -> Binding<Double> {
        Binding(get: { settings.data[keyPath: kp] ?? fallback }, set: { settings.data[keyPath: kp] = $0 })
    }
}
