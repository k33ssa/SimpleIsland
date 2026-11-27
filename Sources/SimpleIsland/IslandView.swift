import SwiftUI
import UniformTypeIdentifiers
import IslandCore

/// Корневая вьюха панели: свечение и сам остров (форма + материал + контент). Вторая активность — значком внутри
/// правого уха (за пределы острова ничего не выносится, UX 15.11).
/// Все размеры морфятся одной пружиной темы; контент проявляется с задержкой 60 мс.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: SimpleIslandSettings
    @ObservedObject var themes: ThemeStore
    @ObservedObject var activities: ActivityCenter
    @ObservedObject var hud: HUDCenter
    @ObservedObject var notifications: IslandNotifications
    @ObservedObject var island: IslandStateCenter
    /// Прогресс интерактивного свайпа — отдельный объект: на кадр жеста пересчитывается только эта вьюха.
    @ObservedObject var swipe: IslandSwipeState
    /// «Потянуть» мышью/трекпадом с нажатием: жест начат (дальше — `model.pull`).
    @State private var pullActive = false

    init(model: IslandModel) {
        self.model = model
        settings = model.env.settings
        themes = model.env.themes
        activities = model.env.activities
        hud = model.env.hud
        notifications = model.env.notifications
        island = model.env.island
        swipe = model.swipe
    }

    var body: some View {
        let theme = settings.data.applying(to: themes.current)
        let p = model.presentation
        // Интерактивный свайп: форма — между покоем и раскрытым, контент обоих слоёв — по прогрессу.
        let progress = swipe.progress
        let m = model.currentMetrics
        let target: IslandMetrics? = progress == nil ? nil : model.metrics(for: .expanded)
        let g = model.geometry

        ZStack(alignment: .top) {
            glow(theme: theme, p: p, m: m)

            // Фон и контент — одна зона нажатия по форме острова: клик по обложке, эквалайзеру или тексту
            // уведомления тоже раскрывает остров. Кнопки и вкладки внутри перехватывают своё нажатие сами.
            ZStack(alignment: .top) {
                IslandBackground(metrics: m, coreHeight: g.hasNotch ? g.notchHeight : 0,
                                 highlighted: (model.hovering && p != .expanded) || island.isDropTargeted,
                                 showEdge: p != .idle || model.hovering,
                                 showRim: p != .idle,
                                 animateRim: p == .expanded)
                    .frame(width: m.outerWidth, height: m.height)

                hudFill(p, m: m, theme: theme)

                content(p, m: m, theme: theme, progress: progress, target: target)
                    .frame(width: m.width, height: m.height, alignment: .top)
                    .clipShape(IslandShape(m, theme: theme))
            }
            .frame(width: m.outerWidth, height: m.height, alignment: .top)
            .contentShape(IslandShape(m, theme: theme))
            .onTapGesture { tapIsland(p) }
            // «Потянуть»: нажал и тянешь вниз — раскрыть; в раскрытом тянешь вверх за верхнюю строку — свернуть.
            // Жесты кнопок, перемотки и перетаскивания файлов внутри острова важнее (дочерние жесты побеждают).
            .gesture(pullGesture(p, topRow: g.notchHeight + 14))
            .modifier(FileDropTarget(model: model))
            // VoiceOver: один контейнер «SimpleIsland: <что показывает>», кнопки и вкладки — внутри.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(IslandAccessibility.label(model))
            .accessibilityHint(IslandAccessibility.hint(model))
            .accessibilityAction(named: p == .expanded ? "Свернуть" : "Раскрыть") {
                if p == .expanded { model.collapse() } else { tapIsland(p) }
            }
        }
        .padding(.top, g.topOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // «Уменьшить движение»/энергосбережение — короткое затухание без пружинного перелёта; окно не видно — без
        // анимации вовсе (`IslandMotion`).
        // Во время свайпа — короткая «интерактивная» пружина: форма идёт за пальцами, сглаживая шаг событий; на
        // отпускании прогресс снимается вместе со сменой `expanded` — досводит пружина темы.
        .animation(progress != nil ? .interactiveSpring(response: 0.12, dampingFraction: 0.9)
                                   : model.motion.animation(theme.springAnimation), value: m)
        .environment(\.islandTheme, theme)
        .environment(\.islandMotion, model.motion)
        .environment(\.islandArtworkColors, artworkColors(theme: theme, p: p))   // --- media2 ---
    }

    // --- media2 ---
    /// Цвета обложки для фона темы с `background.source = artwork` («Хамелеон»): только канал обложки
    /// (`ModuleContext.setArtworkColors`, задаёт «Медиа»), не свечение — свечение ставят и полка, и агенты.
    /// Раскрыт (любая вкладка) и компакт — цвета играющего; в покое — нет (остров сливается с вырезом).
    private func artworkColors(theme: Theme, p: IslandPresentation) -> [Color]? {
        guard theme.background.source == .artwork, p != .idle else { return nil }
        return activities.artworkColors
    }
    // --- /media2 ---

    private func pullGesture(_ p: IslandPresentation, topRow: CGFloat) -> some Gesture {
        // Верх острова не двигается при росте формы — сдвиг по y в своих координатах честный.
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { v in
                guard settings.data.swipeGestures else { return }
                if !pullActive {
                    // В раскрытом — только за верхнюю строку (ниже — содержимое вкладки).
                    guard p != .expanded || v.startLocation.y <= topRow else { return }
                    pullActive = true
                    model.pull(translation: v.translation.height, phase: .began)
                } else {
                    model.pull(translation: v.translation.height, phase: .changed)
                }
            }
            .onEnded { v in
                if pullActive { model.pull(translation: v.translation.height, phase: .ended) }
                pullActive = false
            }
    }

    private func tapIsland(_ p: IslandPresentation) {
        if p != .expanded { model.expandFromCurrent() }
    }

    // MARK: Свечение

    @ViewBuilder
    private func glow(theme: Theme, p: IslandPresentation, m: IslandMetrics) -> some View {
        // Чистый чёрный: в компакте без ореола — цветной свет у кромки делает остров на вид серее выреза.
        let factor: Double = p == .expanded ? 1 : (p == .compact && !theme.isPureBlack ? 0.35 : 0)
        let colors: [Color]? = {
            switch theme.glow.source {
            case .none: return nil
            case .fixed: return theme.glowColors
            case .artwork: return p == .expanded ? activities.glow(tab: model.currentTab?.id)
                                                 : settings.data.compactGlow(in: activities)   // по ушам (settings)
            }
        }()
        if let colors, factor > 0, settings.data.glowIntensity > 0 {
            IslandGlow(colors: colors, metrics: m,
                       opacity: theme.glow.opacity * factor * settings.data.glowIntensity,
                       radius: theme.glow.radius)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    // MARK: Заливка HUD

    /// HUD «Заливка» (зарядка, стиль «Заливка» у громкости/яркости/подсветки) — отдельным слоем во всю форму острова,
    /// с ушами и скруглениями, а не в рамке контента (16.11: слева/справа оставалась чёрная кромка — уши
    /// `earRadius` лежат за `m.width`). Шкала идёт по видимым крыльям, вырез пропускается (`HUDFillBackground`).
    @ViewBuilder
    private func hudFill(_ p: IslandPresentation, m: IslandMetrics, theme: Theme) -> some View {
        if p == .hud, let e = hud.current, let v = e.value, (e.style ?? settings.data.hudStyle) == .fill {
            let g = model.geometry
            HUDFillBackground(value: v, tint: e.tint, notch: g.hasNotch ? g.gap : 0, ear: m.earRadius)
                .frame(width: m.outerWidth, height: m.height)
                .clipShape(IslandShape(m, theme: theme))
                .id("hudfill-\(e.kind)")
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    // MARK: Контент

    @ViewBuilder
    private func content(_ p: IslandPresentation, m: IslandMetrics, theme: Theme,
                         progress: CGFloat?, target: IslandMetrics?) -> some View {
        let g = model.geometry
        let side = max(0, (m.width - g.gap) / 2)
        ZStack(alignment: .top) {
            // Свёрнутый слой: во время свайпа — то, что было до раскрытия, гаснет к середине хода.
            restContent(progress == nil ? p : model.restingPresentation, side: side, theme: theme)
                .opacity(progress.map { Double(max(0, 1 - $0 * 2.2)) } ?? 1)

            // Раскрытая вкладка — одна ветка и в жесте, и раскрытой: на отпускании не пересоздаётся. Во время жеста
            // свёрстана в конечном размере (вход не меняется по кадрам) и обрезана формой; проявляется по прогрессу.
            if p == .expanded || progress != nil {
                let tm = target ?? m
                ExpandedContent(model: model, gap: g.gap, side: max(0, (tm.width - g.gap) / 2), hudEvent: hud.current)
                    .frame(width: tm.width, height: tm.height, alignment: .top)
                    .modifier(SwipeReveal(progress: progress, fit: tm.width > 0 ? m.width / tm.width : 1))
                    .transition(Self.contentTransition)
            }

            hoverHint(p, theme: theme)
        }
    }

    /// Свёрнутые состояния (покой, компакт, HUD, уведомление); у раскрытого — пусто (он в `content`).
    @ViewBuilder
    private func restContent(_ p: IslandPresentation, side: CGFloat, theme: Theme) -> some View {
        let g = model.geometry
        ZStack(alignment: .top) {
            switch p {
            case .idle:
                IdleContent(dot: model.calm ? nil : activities.idleDot, gap: g.gap, side: side, height: g.notchHeight)
                    .transition(Self.contentTransition)
            case .compact:
                if let a = settings.data.compactEars(in: activities) {   // уши с учётом назначений (settings)
                    let second = model.secondaryActivity
                    EarsLayout(notchGap: g.gap, sideWidth: side, inset: 10) { a.leading } trailing: {
                        HStack(spacing: SecondaryMark.width - SecondaryMark.size) {
                            a.trailing
                            if let second { secondaryMark(second, theme: theme) }
                        }
                    }
                        .frame(height: g.notchHeight)
                        .id("compact-\(a.id)")
                        .transition(Self.contentTransition)
                }
            case .hud:
                if let e = hud.current {
                    let style = e.style ?? settings.data.hudStyle
                    ZStack {
                        EarsLayout(notchGap: g.gap, sideWidth: side, inset: 12) {
                            HUDLeading(event: e, onFill: style == .fill && e.value != nil)
                        } trailing: {
                            HUDTrailing(event: e, style: style)
                        }
                    }
                    .frame(height: g.notchHeight)
                    .id("hud-\(e.kind)")
                    .transition(Self.contentTransition)
                }
            case .notification:
                if let n = notifications.current {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: g.notchHeight + 4)
                        NotificationRow(notification: n) { action in
                            action.handler()
                            notifications.dismiss(id: n.id)
                        }
                        .padding(.horizontal, 16)
                    }
                    .id("notif-\(n.id)")
                    .transition(Self.contentTransition)
                }
            case .expanded:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func hoverHint(_ p: IslandPresentation, theme: Theme) -> some View {
            if model.hovering && model.showsHoverHint && (p == .idle || p == .compact) {
                // Строка подсказки под вырезом (макет 02, состояние 06). Цвет — из темы: на светлых видно.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    let dropping = island.isFileDragActive && model.env.dropModule(preferring: nil) != nil
                    HStack(spacing: 5) {
                        Image(systemName: dropping ? "tray.and.arrow.down.fill" : "arrow.down.to.line")
                            .font(.system(size: 10, weight: .bold))
                        Text(dropping ? "отпусти — положу на полку" : "потяни или щёлкни")
                            .font(theme.font(11.5, .semibold))
                    }
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .frame(height: IslandModel.hintRowHeight - 4)
                    .padding(.bottom, 4)
                }
                .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
            }
    }

    static let contentTransition: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
        removal: .opacity.animation(.easeIn(duration: 0.08))
    )

    // MARK: Вторая активность — значок в ухе

    /// Клик (и действие VoiceOver) по значку: поднять вторую активность главной; если уши заняты назначениями
    /// и она в них не попадает — открыть её вкладку.
    private func raiseSecondary(_ a: IslandActivity) {
        if !activities.raiseSecondary(a, left: settings.data.leftEarModule, right: settings.data.rightEarModule) {
            model.expand(tab: a.opensTab ?? a.moduleId)
        }
    }

    /// Кружок 18 pt у внешнего края правого уха: `bubble` активности (обложка, кольцо, значок агента), иначе значок
    /// её модуля. Внутри формы острова — ничего не торчит наружу.
    private func secondaryMark(_ a: IslandActivity, theme: Theme) -> some View {
        let d = SecondaryMark.size
        let symbol = model.env.modules.first { $0.id == a.moduleId }?.systemImage ?? "circle.fill"
        return ZStack {
            Circle().fill(theme.primary.opacity(theme.isLight ? 0.08 : 0.12))
            if let b = a.bubble {
                b.frame(width: d - 4, height: d - 4).clipShape(Circle())
            } else {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(theme.secondary)
            }
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .onTapGesture { raiseSecondary(a) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ещё: \(IslandAccessibility.activityText(a, env: model.env))")
        .accessibilityHint("Сделать главной")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { raiseSecondary(a) }
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

/// Покой: остров = вырез, справа только «живая точка».
private struct IdleContent: View {
    var dot: Color?
    var gap: CGFloat
    var side: CGFloat
    var height: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: side + gap)
            ZStack { if let dot { StatusDot(dot) } }
                .frame(width: side, height: height)
        }
        .frame(height: height)
    }
}

/// Раскрытый остров: верхняя строка (вкладки слева, служебное справа, центр — под вырезом) и вкладка.
private struct ExpandedContent: View {
    @ObservedObject var model: IslandModel
    var gap: CGFloat
    var side: CGFloat
    /// HUD-вспышка в раскрытом виде — коротко в правой части верхней строки, контент не трогаем.
    var hudEvent: HUDEvent?
    @Environment(\.islandTheme) private var theme
    @ObservedObject private var settings: SimpleIslandSettings

    init(model: IslandModel, gap: CGFloat, side: CGFloat, hudEvent: HUDEvent?) {
        self.model = model; self.gap = gap; self.side = side; self.hudEvent = hudEvent
        settings = model.env.settings
    }

    var body: some View {
        let tabs = model.env.enabledTabModules
        let current = model.currentTab
        let pad = TabBarLayout.edgePadding
        let sideWidth = max(0, side - pad - 8)
        // Под вкладки справа — что остаётся до кнопок «+» и настроек (и зазор 10 перед ними).
        let rightCap = max(0, sideWidth - TabBarLayout.trailingButtonsWidth - 10)
        // Сторона выреза каждой вкладки — из настроек («Раскладка»: слева / справа от выреза).
        let sideOf = Dictionary(settings.data.tabs.map { ($0.id, $0.side) }, uniquingKeysWith: { a, _ in a })
        let plan = TabBarLayout.plan(leftIds: tabs.map(\.id).filter { sideOf[$0] != .right },
                                     rightIds: tabs.map(\.id).filter { sideOf[$0] == .right },
                                     selected: current?.id,
                                     selectedWidths: TabBarLayout.selectedWidths(title: current?.title ?? ""),
                                     left: sideWidth, right: rightCap, inline: !model.geometry.hasNotch)
        let byId = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: TabBarLayout.spacing) {
                    ForEach(plan.left.compactMap { byId[$0] }, id: \.id) { t in tabPill(t, current: current) }
                    if plan.inline {
                        // Без выреза — правая группа сразу за левой, через черту.
                        if !plan.left.isEmpty && !plan.right.isEmpty {
                            Capsule().fill(theme.tertiary.opacity(0.5)).frame(width: 1, height: 14)
                        }
                        ForEach(plan.right.compactMap { byId[$0] }, id: \.id) { t in tabPill(t, current: current) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: sideWidth, alignment: .leading)
                .padding(.leading, pad)
                Color.clear.frame(width: gap + 16)
                HStack(spacing: 10) {
                    if let e = hudEvent {
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            HUDLeading(event: HUDEvent(kind: e.kind, systemImage: e.systemImage, tint: e.tint,
                                                       customLeading: e.customLeading))
                            HUDTrailing(event: e, style: (e.style ?? settings.data.hudStyle) == .fill ? .thread
                                                          : (e.style ?? settings.data.hudStyle))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(3)
                        .id("hud-\(e.kind)")
                        .transition(.opacity)
                    } else {
                        let rightRow = plan.inline ? [] : plan.right
                        if !rightRow.isEmpty || !plan.overflow.isEmpty {
                            HStack(spacing: TabBarLayout.spacing) {
                                ForEach(rightRow.compactMap { byId[$0] }, id: \.id) { t in tabPill(t, current: current) }
                                if !plan.overflow.isEmpty { overflowMenu(plan.overflow.compactMap { byId[$0] }) }
                            }
                            .layoutPriority(2)
                        }
                        // --- agents2 --- сводка модуля в правом верху его вкладки (макет 05) — поверх свободного места
                        // после вкладок справа: на раскладку не влияет (18.11: при открытии «Агентов» её слот сдвигал
                        // вкладки и кнопки влево); не влезла — обрезается.
                        // Не влезает целиком в свободное место — не показывается (18.11: налезала на вкладку).
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            .overlay(alignment: .trailing) {
                                if let header = current?.headerTrailingView() {
                                    ViewThatFits(in: .horizontal) {
                                        header.lineLimit(1).fixedSize()
                                        Color.clear.frame(width: 0, height: 0)
                                    }
                                    .id("header-\(current?.id ?? "")")
                                }
                            }
                    }
                    // --- catalog --- «+» — каталог виджетов. Подписи «Добавить виджет» больше нет (15.11: «плюс то
                    // же самое делает») — её место отдано вкладкам справа; название — в подсказке и для VoiceOver.
                    // Замок (16.11): держать остров раскрытым — не сворачивать по уходу курсора и клику мимо.
                    // Вспышка HUD (громкость/яркость) в верхней строке — замок (если не заперт) и «+» уступают ей место:
                    // иначе значок уезжал под вырез, а «100» обрезалось до «1…» (16.11).
                    if hudEvent == nil || model.locked {
                        IslandButton(systemImage: model.locked ? "lock.fill" : "lock.open", style: model.locked ? .accent : .plain,
                                     height: 24, accessibilityLabel: model.locked ? "Отпереть остров" : "Запереть остров раскрытым",
                                     accessibilityHint: model.locked ? "Остров снова будет сворачиваться сам"
                                                                     : "Остров не свернётся, пока не отопрёшь") { model.toggleLock() }
                            .help(model.locked ? "Заперт: не сворачивается сам. Нажми, чтобы отпереть"
                                               : "Запереть раскрытым")
                    }
                    if hudEvent == nil {
                        IslandButton(systemImage: "plus", style: .solid, height: 24, accessibilityLabel: "Добавить виджет",
                                     accessibilityHint: "Открыть каталог виджетов") { openCatalog() }
                            .help("Добавить виджет")
                    }
                    IslandButton(systemImage: "slider.horizontal.3", height: 24, accessibilityLabel: "Настройки SimpleIsland",
                                 accessibilityHint: "Открыть окно настроек") { model.onOpenSettings() }
                        .help("Настройки")
                }
                .frame(width: sideWidth, alignment: .trailing)
                .padding(.trailing, pad)
                .animation(.easeOut(duration: 0.15), value: hudEvent?.kind)
            }
            .frame(height: model.geometry.notchHeight)

            Group {
                if let current {
                    (current.expandedView() ?? AnyView(ModulePlaceholderView(title: current.title, systemImage: current.systemImage)))
                        .id(current.id)
                } else {
                    ModulePlaceholderView(title: "Нет вкладок", systemImage: "square.dashed",
                                          note: "Включи вкладки в настройках → Раскладка")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .padding(.top, 14)
            .padding(.horizontal, pad)
            .padding(.bottom, pad)
        }
    }
}

// --- catalog ---
private extension ExpandedContent {
    func tabPill(_ t: IslandModule, current: IslandModule?) -> some View {
        let sel = t.id == current?.id
        return Pill(t.title, systemImage: t.systemImage, selected: sel)
            // Невыбранные — значок своего размера; остаток ширины — выбранной (её подпись).
            .fixedSize(horizontal: !sel, vertical: false)
            .layoutPriority(sel ? 1 : 0)
            .onTapGesture { model.selectedTab = t.id }
            .accessibilityAction { model.selectedTab = t.id }
    }

    /// «⋯» — вкладки, что не влезли в свою сторону выреза.
    @ViewBuilder func overflowMenu(_ rest: [IslandModule]) -> some View {
        if model.env.isSnapshot {
            // ImageRenderer не рисует Menu (жёлтая заглушка) — в снимках только значок.
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.tertiary)
                .frame(width: TabBarLayout.moreWidth, height: Pill.height)
        } else {
            overflowMenuLive(rest)
        }
    }

    func overflowMenuLive(_ rest: [IslandModule]) -> some View {
        Menu {
            ForEach(rest, id: \.id) { t in
                Button { model.selectedTab = t.id } label: { Label(t.title, systemImage: t.systemImage) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.tertiary)
                .frame(width: TabBarLayout.moreWidth, height: Pill.height)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ещё вкладки: " + rest.map(\.title).joined(separator: ", "))
        .accessibilityLabel("Ещё вкладки")
    }

    /// Свернуть остров и открыть каталог виджетов (в режиме снимков — ничего).
    func openCatalog() {
        guard !model.env.isSnapshot else { return }
        model.collapse()
        WidgetCatalogWindow.shared.show(env: model.env)
    }
}

/// Приём файлов, брошенных на остров (в любом состоянии, и в компакте). Вьюха вкладки может перехватить бросок
/// своим `.onDrop`; иначе файлы уходят модулю с `acceptsFileDrops` (открытая вкладка → первый принимающий).
private struct FileDropTarget: ViewModifier {
    @ObservedObject var model: IslandModel

    func body(content: Content) -> some View {
        // --- shelf --- в снимках без onDrop: ImageRenderer рисует drop-зону жёлтой заглушкой.
        if !model.env.isSnapshot, model.env.dropModule(preferring: nil) != nil {
            // --- shelfbar --- не только file-url: обещания файла (миниатюра снимка экрана), картинки, file://.
            // Подсветка — только если из перетаскиваемого выйдет файл (сетевая ссылка, текст — нет).
            content.onDrop(of: DragPasteboard.dropUTTypes, isTargeted: Binding(
                get: { model.env.island.isDropTargeted },
                set: { model.env.island.setDropTargeted($0 && DragPasteboard.isFileLike(NSPasteboard(name: .drag))) }
            )) { providers in deliver(providers) }
        } else {
            content
        }
    }

    private func deliver(_ providers: [NSItemProvider]) -> Bool {
        let env = model.env
        let tab = model.expanded ? model.currentTab?.id : nil
        guard let module = env.dropModule(preferring: tab) else { return false }
        let target = module.id
        // --- shelfbar --- бросок читается из drag-буфера: обещания выполняются только во время броска.
        let pb = NSPasteboard(name: .drag)
        if DragPasteboard.inspectTypes(pb).isFileLike {
            // --- shelfshot --- забрать до возврата из броска; ничего не взяли — false: источник (миниатюра снимка
            // экрана) сохранит своё как обычно, а не будет считать файл доставленным.
            return DragPasteboard.accept(pb, providers: providers, into: module.dropIncomingDirectory) { r in
                if !r.files.isEmpty { _ = env.module(id: target)?.handleDrop(r.files) }
                if let p = r.problem {
                    var n = IslandNotification(
                        moduleId: target, title: p.title, source: env.module(id: target)?.title, body: p.detail,
                        avatarColors: [IslandPalette.err, Color(hex: "#B4233C")],
                        systemImage: "exclamationmark.triangle.fill", duration: 10)
                    n.bodyLines = 3
                    env.notifications.post(n)
                }
            }
        }
        // --- /shelfbar ---
        let box = URLBox()
        let group = DispatchGroup()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = box.urls
                guard !urls.isEmpty else { return }
                _ = env.module(id: target)?.handleDrop(urls)
            }
        }
        return true
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func append(_ u: URL) { lock.lock(); items.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}
