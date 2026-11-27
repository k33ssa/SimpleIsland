import AppKit
import SwiftUI
import UniformTypeIdentifiers
import IslandCore

// Вкладка «Полка» — макет design/mockups/04-shelf.html: строка-заголовок, 8 плиток-целей, ряд файлов полки.

struct ShelfExpandedView: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject var island: IslandStateCenter
    @Environment(\.islandTheme) private var theme

    static let headerHeight: CGFloat = 18
    static let tilesHeight: CGFloat = 100
    static let rowHeight: CGFloat = 56
    static let contentHeight: CGFloat = headerHeight + 10 + tilesHeight + 14 + rowHeight

    var body: some View {
        let dragging = model.mockDragging || island.isFileDragActive
        VStack(spacing: 0) {
            header(dragging: dragging)
                .frame(height: Self.headerHeight)
            HStack(spacing: 8) {
                ForEach(model.prefs.visibleTargets) { t in
                    TargetTile(model: model, target: t, dragging: dragging)
                }
            }
            .frame(height: Self.tilesHeight)
            .padding(.top, 10)
            ShelfRow(model: model)
                .frame(height: Self.rowHeight)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func header(dragging: Bool) -> some View {
        HStack(spacing: 10) {
            Text(dragging ? "Отпусти, куда отправить" : "Брось файлы на цель — или выбери на полке")
                .font(theme.font(13, .bold))
                .foregroundStyle(theme.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Group {
                if let b = model.busy {
                    Text(b.target.busyTitle + (b.progress.map { " \(Int($0 * 100))%" } ?? ""))
                        .foregroundStyle(IslandPalette.readable(b.target.tint, on: theme))
                } else if dragging, let s = model.dragSummary {
                    Text(s).foregroundStyle(theme.tertiary)
                } else if !model.selection.isEmpty {
                    Text("выбрано \(model.selection.count) · щёлкни цель").foregroundStyle(theme.tertiary)
                } else if !model.items.isEmpty {
                    Text("⌥-щелчок — убрать с полки").foregroundStyle(theme.tertiary)
                }
            }
            .font(theme.font(12, .semibold))
            .lineLimit(1)
        }
    }
}

// MARK: - Плитка цели

struct TargetTile: View {
    @ObservedObject var model: ShelfModel
    var target: ShelfTarget
    var dragging: Bool
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let hot = model.hotTarget == target
        let busy = model.busy?.target == target ? model.busy : nil
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 8) {
            TargetIcon(target: target, size: 40, busy: busy)
            VStack(spacing: 2) {
                Text(target.title)
                    .font(theme.font(11.5, .semibold))
                    .foregroundStyle(hot ? theme.primary : theme.secondary)
                Text(subtitle(busy: busy))
                    .font(theme.font(10, .semibold))
                    .foregroundStyle(hot ? IslandPalette.readable(target.tint, on: theme).opacity(0.95) : theme.tertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if hot {
                shape.fill(RadialGradient(colors: [target.tint.opacity(theme.isLight ? 0.3 : 0.45),
                                                   target.tint.opacity(0.06)],
                                          center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 70))
            } else if !dragging {
                shape.fill(theme.controlFillColor)
            }
        }
        .overlay {
            if hot {
                shape.strokeBorder(target.tint.opacity(0.9), lineWidth: 1.5)
            } else if dragging {
                shape.strokeBorder(theme.primary.opacity(theme.isLight ? 0.22 : 0.16),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .background {
            if hot {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .strokeBorder(target.tint.opacity(0.25), lineWidth: 1)
                    .padding(-5)
                    .shadow(color: target.tint.opacity(0.45), radius: 14)
            }
        }
        .background {
            if !isSnapshot { TileAnchor { model.setAnchor($0, for: target) } }
        }
        .scaleEffect(hot ? 1.04 : 1)
        .offset(y: hot ? -2 : 0)
        .zIndex(hot ? 1 : 0)
        // Пружина — только при полном движении; «Уменьшить движение» — короткое затухание; остров не виден — без анимации.
        .animation(motion.animation(.spring(response: 0.28, dampingFraction: 0.7)), value: hot)
        .contentShape(shape)
        .onTapGesture { model.tap(target) }
        .modifier(TileDrop(model: model, target: target, enabled: !isSnapshot))
        .help(target.settingsTitle)
    }

    private func subtitle(busy: ShelfModel.Busy?) -> String {
        if let busy { return busy.progress.map { "\(Int($0 * 100))%" } ?? target.busyTitle }
        switch target {
        case .shelf: return ShelfFormat.ttl(model.prefs.ttlHours)
        case .airdrop: return "рядом"
        case .share: return "чаты, почта"
        case .zip: return "в ZIP"
        case .convert:
            switch model.prefs.convertFormat {
            case .auto: return "PDF → PNG"
            default: return "→ \(model.prefs.convertFormat.title)"
            }
        case .text: return "распознать"
        case .cutout: return "вырезать"
        case .custom: return "скрипты"
        }
    }
}

/// Приём броска на плитку (подсветка — `hotTarget`). В снимках выключен: ImageRenderer рисует drop-зону заглушкой.
private struct TileDrop: ViewModifier {
    @ObservedObject var model: ShelfModel
    var target: ShelfTarget
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: DragPasteboard.dropUTTypes, isTargeted: Binding(
                get: { model.hotTarget == target },
                set: { on in
                    if on { model.hotTarget = target } else if model.hotTarget == target { model.hotTarget = nil }
                }
            )) { providers in model.drop(providers, on: target) }
        } else {
            content
        }
    }
}

/// Значок цели: градиентный квадрат (или нейтральный), при работе — кольцо прогресса вокруг.
struct TargetIcon: View {
    var target: ShelfTarget
    var size: CGFloat
    var busy: ShelfModel.Busy?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let r = size * 0.33
        ZStack {
            if let g = target.gradient {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(LinearGradient(colors: g, startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(theme.primary.opacity(0.1))
            }
            if let busy {
                BusyRing(progress: busy.progress, tint: target.gradient == nil ? theme.primary : .white, lineWidth: 3)
                    .frame(width: size * 0.6, height: size * 0.6)
            } else {
                Image(systemName: target.systemImage)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(target.gradient == nil ? theme.primary : .white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Кольцо: с процентами — дуга по значению, без — крутится (только пока видно и не в снимке).
struct BusyRing: View {
    var progress: Double?
    var tint: Color
    var lineWidth: CGFloat
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if let progress {
            Ring(value: max(0.04, progress), lineWidth: lineWidth, tint: tint)
        } else if !isSnapshot && motion.allowsContinuousAnimation {
            // Вращение по времени — только при полном движении и пока видно (`.off` — окно скрыто/сон: ни кадра).
            // Вращение — Core Animation (`SpinningRing`): в процессе ни кадра (было TimelineView 30 к/с).
            SpinningRing(track: theme.primary.opacity(0.15), arc: tint, lineWidth: lineWidth, fraction: 0.28, period: 0.9)
        } else {
            Ring(value: 0.28, lineWidth: lineWidth, tint: tint)
        }
    }
}

/// Невидимая NSView под плиткой — к ней крепятся меню «Поделиться» и «Свои действия».
private struct TileAnchor: NSViewRepresentable {
    var onView: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        onView(v)          // слабая ссылка в NSMapTable, не @Published — можно сразу
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Ряд полки

struct ShelfRow: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text("На полке · \(model.items.count)".uppercased())
                .font(theme.font(10.5, .semibold))
                .tracking(0.5)
                .foregroundStyle(theme.tertiary)
                .lineLimit(1)
                .fixedSize()
            if model.items.isEmpty {
                emptyHint
            } else {
                cards
                IslandButton("Всё через AirDrop", systemImage: "dot.radiowaves.left.and.right", height: 28) {
                    model.shareAllViaAirDrop()
                }
                .fixedSize()
                .help("Отправить всё с полки через AirDrop")
                IslandButton(systemImage: "xmark", height: 28) { model.clear() }
                    .help("Очистить полку (файлы уйдут в Корзину)")
            }
        }
    }

    @ViewBuilder private var cards: some View {
        // ImageRenderer не рисует NSScrollView — в снимке просто ряд. Вживую ряд ленивый: миниатюры грузятся для
        // показанных карточек и забываются для ушедших (в памяти — только кэш с лимитом).
        Group {
            if isSnapshot {
                HStack(spacing: 6) {
                    ForEach(model.items) { item in ShelfCard(model: model, item: item) }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(model.items) { item in
                            ShelfCard(model: model, item: item)
                                .onAppear { model.thumbnailAppeared(item) }
                                .onDisappear { model.thumbnailDisappeared(item) }
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        // Не влезшая карточка уходит в прозрачность, а не обрубается краем (подсказка «листай»).
        .mask(HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 18)
        })
    }

    private var emptyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 13, weight: .semibold))
            Text("Пусто — брошенные на остров файлы полежат здесь \(ttlPhrase)")
                .font(theme.font(11.5, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(theme.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(theme.primary.opacity(theme.isLight ? 0.2 : 0.14), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
    }

    private var ttlPhrase: String {
        let h = model.prefs.ttlHours
        if h <= 0 { return "без срока" }
        if h % 24 == 0 { let d = h / 24; return d == 1 ? "сутки" : "\(d) \(ShelfFormat.plural(d, "день", "дня", "дней"))" }
        return "\(h) ч"
    }
}

struct ShelfCard: View {
    @ObservedObject var model: ShelfModel
    var item: ShelfItem
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let selected = model.selection.contains(item.id)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 7) {
            FileThumb(item: item, image: model.thumbnails[item.id])
                .frame(width: 28, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                // Как в макете: имя без расширения («скрин 14.11»), обрезка в конце; полное имя — в подсказке.
                Text(item.displayName)
                    .font(theme.font(11.5, .semibold))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                // Широкий (моноширинный) шрифт: возраст уступает место размеру, а не обрезается до «3…».
                ViewThatFits(in: .horizontal) {
                    Text("\(ShelfFormat.size(item.size)) · \(ShelfFormat.age(item.addedAt))")
                    Text(ShelfFormat.size(item.size))
                }
                .font(theme.font(10, .semibold))
                .foregroundStyle(theme.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(width: 124, height: 56)
        .background(shape.fill(selected ? theme.accentColor.opacity(0.16) : theme.controlFillColor))
        .overlay { if selected { shape.strokeBorder(theme.accentColor.opacity(0.8), lineWidth: 1.5) } }
        .contentShape(shape)
        // Один обработчик без ожидания двойного щелчка: модификаторы и число щелчков берутся из самого события
        // мыши (`NSApp.currentEvent` — это mouseUp щелчка), а не из текущего состояния клавиатуры спустя 0,5 с.
        .onTapGesture {
            let e = NSApp.currentEvent
            let mouse = e.map { [.leftMouseUp, .leftMouseDown].contains($0.type) } ?? false
            if mouse, e?.modifierFlags.contains(.option) == true {
                model.remove([item.id])
            } else if mouse, (e?.clickCount ?? 1) >= 2 {
                model.toggleSelection(item)          // вернуть выбор, изменённый первым щелчком
                model.open(item)
            } else {
                model.toggleSelection(item)
            }
        }
        .onDrag {
            NSItemProvider(contentsOf: model.url(for: item)) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Открыть") { model.open(item) }
            Button("Показать в Finder") { model.reveal(item) }
            Divider()
            Button("Убрать с полки") { model.remove([item.id]) }
        }
        .help("\(item.name)\nЩелчок — выбрать, двойной — открыть, ⌥-щелчок — убрать, тащи наружу — забрать")
    }
}

/// Миниатюра: QuickLook → значок типа; в снимках — плейсхолдеры.
struct FileThumb: View {
    var item: ShelfItem
    var image: NSImage?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let art = item.mockArt {
                switch art {
                case .warm: ArtworkView(cornerRadius: 7, placeholder: .warm)
                case .sea: ArtworkView(cornerRadius: 7, placeholder: .sea)
                case .violet: ArtworkView(cornerRadius: 7, placeholder: .violet)
                case .document: DocumentThumb(ext: (item.name as NSString).pathExtension)
                }
            } else if item.isDirectory {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().aspectRatio(contentMode: .fit)
            } else {
                let t = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
                Image(nsImage: NSWorkspace.shared.icon(for: t)).resizable().aspectRatio(contentMode: .fit)
            }
        }
    }
}

/// Нарисованный «лист» (без чужих значков) — для мок-документа.
private struct DocumentThumb: View {
    var ext: String
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(hex: "#E5E7EE")], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 3) {
                ForEach([0.8, 1, 0.6, 0.9], id: \.self) { w in
                    Capsule().fill(Color(hex: "#C9CDD6")).frame(width: 20 * w, height: 2.5)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 7)
            Text(ext.uppercased())
                .font(.system(size: 6.5, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#2563EB")))
                .padding(.bottom, 4)
        }
    }
}

// MARK: - Компакт: «Распознаю… 40%»

/// Левое «ухо»: значок цели и процент (если известен) — чтобы ухо не пустовало.
struct BusyLeading: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.islandTheme) private var theme
    var body: some View {
        if let b = model.busy {
            HStack(spacing: 7) {
                TargetIcon(target: b.target, size: 22, busy: nil)
                if let p = b.progress {
                    Text("\(Int(p * 100))%")
                        .font(theme.font(12, .bold))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .fixedSize()
                } else if b.count > 1 {
                    Text("×\(b.count)")
                        .font(theme.font(12, .bold))
                        .foregroundStyle(theme.secondary)
                        .fixedSize()
                }
            }
        }
    }
}

struct BusyTrailing: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.islandTheme) private var theme
    var body: some View {
        if let b = model.busy {
            HStack(spacing: 6) {
                Text(b.target.busyTitle)
                    .font(theme.font(12, .bold))
                    .monospacedDigit()
                    .foregroundStyle(IslandPalette.readable(b.target.tint, on: theme))
                    .lineLimit(1)
                    .fixedSize()
                BusyRing(progress: b.progress, tint: IslandPalette.readable(b.target.tint, on: theme), lineWidth: 2.5)
                    .frame(width: 15, height: 15)
            }
        }
    }
}

struct BusyBubble: View {
    @ObservedObject var model: ShelfModel
    var body: some View {
        if let b = model.busy {
            BusyRing(progress: b.progress, tint: b.target.tint, lineWidth: 3.5)
        }
    }
}
