import AppKit
import IslandCore
import SwiftUI

// Режим уборки (макет 12, состояния 01–02б): полупрозрачная панель над строкой меню основного экрана — только на
// время режима. Рамки вокруг значков, наведение — оранжевая рамка и имя, щелчок — карточка «что сделать?» под
// значком. ⏎ — вариант по умолчанию («Убрать в остров»), ↑/↓ — выбор, ←/→ — соседний значок, Esc — назад/выход.
// Остальной экран притушен, щелчок мимо — выход без изменений. Остров на время режима — ровно вырез
// (`holdCollapsed`, MenuBarModel.startCleanup), плашка режима — под строкой меню левее выреза (`CleanupLayout`).

/// Панель режима уборки: уровень строки значков + 1 (над значками, под островом и выпадающими меню).
final class CleanupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Не даём системе сдвинуть панель под строку меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class CleanupOverlayController {
    private weak var model: MenuBarModel?
    private var panel: CleanupPanel?
    private var keyMonitor: Any?

    init(model: MenuBarModel) { self.model = model }

    func show() {
        guard panel == nil, let model, let screen = NSScreen.screens.first else { return }
        let menuH = max(24, screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        let p = CleanupPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.becomesKeyOnlyIfNeeded = false
        p.isMovable = false
        p.setAccessibilityLabel("Уборка строки меню")
        let theme = model.context?.theme ?? .obsidian
        let root = CleanupOverlayView(model: model, size: screen.frame.size, menuBarHeight: menuH,
                                      notch: MenuBarScanner.notchRect())
            .environment(\.islandTheme, theme)
        p.contentView = NSHostingView(rootView: root)
        p.setFrame(screen.frame, display: false)
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            let window = e.window
            let isRepeat = e.isARepeat
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, window === panel, let model = self.model else { return false }
                return model.handleKey(code, isRepeat: isRepeat)
            }
            return handled ? nil : e
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }
}

// MARK: - Вид оверлея

enum MenuBarStyle {
    static let dim = Color(red: 4 / 255, green: 3 / 255, blue: 10 / 255).opacity(0.42)
    /// Подсветка значков на настоящей строке меню — акцент темы. Тёмный акцент (paper) на тёмной строке не виден —
    /// у него светлая обводка (`highlightHalo`).
    static func highlight(_ theme: Theme) -> Color { theme.accentColor }
    static func highlightHalo(_ theme: Theme) -> Color? {
        (NSColor(hex: theme.accent)?.luminance ?? 1) < 0.3 ? Color.white.opacity(0.85) : nil
    }
    /// Текст на заливке акцентом: тёмный на светлом акценте, белый на тёмном.
    static func onAccent(_ theme: Theme) -> Color {
        let c = NSColor(hex: theme.accent) ?? .orange
        return c.luminance > 0.45 ? Color(hex: "#1A0700") : .white
    }

    static func red(_ theme: Theme) -> Color { theme.isLight ? Color(hex: "#C0263F") : Color(hex: "#FF8AA0") }

    /// Ширина текста шрифтом темы.
    @MainActor static func width(_ text: String, size: CGFloat, weight: NSFont.Weight, theme: Theme) -> CGFloat {
        let font: NSFont = theme.font.family == .mono
            ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

struct CleanupOverlayView: View {
    @ObservedObject var model: MenuBarModel
    var size: CGSize
    var menuBarHeight: CGFloat
    var notch: CGRect?
    @Environment(\.islandTheme) private var theme

    /// Подсветка поверх настоящей строки меню — акцент темы (тёмный — со светлой обводкой).
    private var accent: Color { MenuBarStyle.highlight(theme) }

    var body: some View {
        let inv = model.inventory
        let st = model.cleanup
        ZStack(alignment: .topLeading) {
            // Ловушка щелчков: мимо значков — выход (или закрыть карточку).
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { model.backgroundClick() }
                .accessibilityHidden(true)
            MenuBarStyle.dim
                .frame(width: size.width, height: max(0, size.height - menuBarHeight))
                .position(x: size.width / 2, y: menuBarHeight + (size.height - menuBarHeight) / 2)
                .allowsHitTesting(false)
            if let r = region(inv.visible) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(accent.opacity(0.55), lineWidth: 1))
                    .shadow(color: accent.opacity(0.18), radius: 14)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
            ForEach(inv.visible) { item in
                let r = itemRect(item)
                ItemFrameView(hovered: st.hoveredKey == item.key && !st.cardOpen, selected: st.selectedKey == item.key)
                    .frame(width: r.width, height: r.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.click(item.key) }
                    .onHover { on in model.hover(on ? item.key : nil) }
                    .position(x: r.midX, y: r.midY)
                    .accessibilityElement()
                    .accessibilityLabel(item.displayName)
                    .accessibilityAddTraits(.isButton)
            }
            if let h = st.hoveredKey, !st.cardOpen, let item = inv.item(key: h), item.section == .visible {
                CleanupTip(name: item.displayName)
                    .fixedSize()
                    .position(x: min(max(itemRect(item).midX, 120), size.width - 120), y: menuBarHeight + 19)
                    .allowsHitTesting(false)
            }
            // Плашка режима — сразу под строкой меню, левее выреза и значков: справа под значками место для подсказки
            // и карточки, а остров на время уборки сжат ровно до выреза (`holdCollapsed`, 15.11) и значков не
            // закрывает. Раньше плашка висела под вырезом на +42 pt и перекрывала карточки значков у выреза.
            let plate = CleanupLayout.plate(screenWidth: size.width, menuBarHeight: menuBarHeight, notch: notch,
                                            iconsMinX: region(inv.visible)?.minX)
            CleanupHintRow(visibleCount: inv.visible.count, notchItems: inv.underNotch, selectedKey: st.selectedKey, model: model)
                .fixedSize()
                .frame(width: plate.width, alignment: .topTrailing)
                .offset(x: plate.minX, y: plate.minY)
            if let sel = st.selectedKey, let item = inv.item(key: sel), let card = model.card(for: sel) {
                let w: CGFloat = 330
                let cx = item.section == .visible ? itemRect(item).midX : plate.maxX - min(plate.width, 420) / 2
                let left = min(max(cx - w / 2, 24), size.width - w - 24)
                CleanupCardView(item: item, card: card, state: st, icon: MenuBarIconView(item: item, model: model, size: 18),
                                nubX: cx - left, attached: item.section == .visible, model: model)
                    .frame(width: w)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: left, y: item.section == .visible ? menuBarHeight : plate.minY + 128)
            }
            if let s = model.status {
                CleanupStatusPill(text: s)
                    .fixedSize()
                    .position(x: size.width / 2, y: size.height - 120)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Рамка значка в координатах панели (основной экран: CG и локальные совпадают).
    private func itemRect(_ item: MenuBarItem) -> CGRect {
        CGRect(x: item.frame.minX + 1, y: 5, width: max(10, item.frame.width - 2), height: max(16, menuBarHeight - 10))
    }

    private func region(_ items: [MenuBarItem]) -> CGRect? {
        guard let l = items.map(\.frame.minX).min(), let r = items.map(\.frame.maxX).max() else { return nil }
        return CGRect(x: l - 4, y: 2, width: r - l + 8, height: max(20, menuBarHeight - 4))
    }
}

/// Где плашка «Уборка · N значков»: под строкой меню, правый край — левее выреза и левее самого левого значка
/// (на 16 pt). Ширина — до 640 pt, но не за левый край экрана. Значки строки меню и место под ними (подсказка у
/// значка, карточка) плашка не перекрывает.
enum CleanupLayout {
    static let plateMaxWidth: CGFloat = 640
    static let gap: CGFloat = 16

    static func plate(screenWidth: CGFloat, menuBarHeight: CGFloat, notch: CGRect?, iconsMinX: CGFloat?) -> CGRect {
        var right = min(notch?.minX ?? .infinity, iconsMinX ?? .infinity)
        if !right.isFinite { right = screenWidth / 2 + plateMaxWidth / 2 }
        right = min(screenWidth - gap, max(right - gap, 320 + gap))
        let width = min(plateMaxWidth, right - gap)
        return CGRect(x: right - width, y: menuBarHeight + 8, width: width, height: 120)
    }
}

/// Рамка вокруг значка: пунктир у всех, наведение — цвет акцента, выбранный — заливка.
struct ItemFrameView: View {
    var hovered: Bool
    var selected: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let hl = MenuBarStyle.highlight(theme)
        ZStack {
            shape.fill(hl.opacity(selected ? 0.34 : hovered ? 0.28 : 0.001))
            if hovered || selected {
                if let halo = MenuBarStyle.highlightHalo(theme) { shape.inset(by: -1.5).stroke(halo, lineWidth: 1.5) }
                shape.stroke(hl, lineWidth: 1.5)
            } else {
                shape.stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .shadow(color: hl.opacity(hovered ? 0.55 : 0), radius: 7)
    }
}

/// «Ollama · щёлкни, чтобы убрать».
struct CleanupTip: View {
    var name: String
    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Text("· щёлкни, чтобы убрать").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.86)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
    }
}

/// Под островом: подсказка и значки, которые прячет вырез (их рамок не видно — щелчок по фишке).
struct CleanupHintRow: View {
    var visibleCount: Int
    var notchItems: [MenuBarItem]
    var selectedKey: String?
    @ObservedObject var model: MenuBarModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                CleanupCompactLeading()
                CleanupCompactTrailing(visible: visibleCount, notch: notchItems.count)
            }
            HStack(spacing: 6) {
                Text("Щёлкни значок, чтобы убрать").foregroundStyle(.white.opacity(0.8))
                Text("·").foregroundStyle(.white.opacity(0.35))
                KeyCap("Esc")
                Text("— выйти").foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 13, weight: .semibold))
            if !notchItems.isEmpty {
                HStack(spacing: 6) {
                    Text("Под вырезом:").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: "#FFCF70"))
                    ForEach(notchItems.prefix(6)) { item in
                        Button { model.click(item.key) } label: {
                            HStack(spacing: 5) {
                                MenuBarIconView(item: item, model: model, size: 13)
                                Text(item.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Capsule().fill(selectedKey == item.key ? theme.accentColor.opacity(0.45) : Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.displayName), под вырезом")
                    }
                    if notchItems.count > 6 {
                        Text("+\(notchItems.count - 6)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.78)))
        .environment(\.islandTheme, theme.isLight ? .obsidian : theme)
    }
}

struct CleanupStatusPill: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.86)))
    }
}

/// Клавиша: «⏎», «Esc», «↑».
struct KeyCap: View {
    var text: String
    var on = false
    @Environment(\.islandTheme) private var theme
    init(_ text: String, on: Bool = false) { self.text = text; self.on = on }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(on ? MenuBarStyle.onAccent(theme) : theme.primary)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(on ? theme.accentColor : theme.primary.opacity(0.12)))
            .accessibilityHidden(true)
    }
}

// MARK: - Карточка подтверждения

struct CleanupCardView: View {
    var item: MenuBarItem
    var card: CleanupCard
    var state: CleanupState
    var icon: MenuBarIconView
    /// Где «язычок» над значком (от левого края карточки).
    var nubX: CGFloat
    /// Карточка «приклеена» к строке меню (под значком) — с ушами, как остров; иначе (значок из-под выреза,
    /// карточка под подсказкой) — отдельная, скруглённая со всех сторон.
    var attached = true
    var model: MenuBarModel?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.primary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.confirmingQuit ? "Выйти из \(item.displayName)?" : card.title)
                        .font(theme.font(14.5, .bold)).foregroundStyle(theme.primary).lineLimit(1)
                    Text(state.confirmingQuit ? "несохранённое может пропасть" : card.subtitle)
                        .font(theme.font(11.5, .semibold)).foregroundStyle(theme.tertiary).lineLimit(1)
                }
            }
            .padding(EdgeInsets(top: 2, leading: 6, bottom: 10, trailing: 6))
            if state.confirmingQuit {
                OptionRow(symbol: "power", title: "Выйти", detail: "\(item.displayName) закроется, значок пропадёт",
                          on: true, destructive: true, key: "⏎") { model?.run(.perform(key: item.key, option: .quit, remember: true)) }
                OptionRow(symbol: "arrow.uturn.backward", title: "Назад", detail: "ничего не делать", on: false,
                          destructive: false, key: "Esc") { _ = model?.handleKey(53) }
            } else {
                ForEach(Array(card.options.enumerated()), id: \.offset) { i, opt in
                    OptionRow(symbol: opt.symbol, title: opt.title, detail: card.details.indices.contains(i) ? card.details[i] : "",
                              on: i == state.optionIndex, destructive: opt.isDestructive, key: i == state.optionIndex ? "⏎" : nil) {
                        model?.choose(i)
                    }
                }
                if let note = card.note {
                    Text(note).font(theme.font(11.5, .semibold)).foregroundStyle(theme.tertiary)
                        .padding(.horizontal, 10).padding(.top, 6)
                }
                if card.showsRemember {
                    Button { model?.cleanup.remember.toggle() } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(state.remember ? theme.accentColor : theme.primary.opacity(0.12))
                                .frame(width: 15, height: 15)
                                .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(MenuBarStyle.onAccent(theme)).opacity(state.remember ? 1 : 0))
                            Text("Помнить после перезапуска \(item.displayName)")
                                .font(theme.font(11.5, .semibold)).foregroundStyle(theme.tertiary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            KeyCap("Space").scaleEffect(0.85)
                        }
                        .padding(EdgeInsets(top: 9, leading: 10, bottom: 0, trailing: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Помнить после перезапуска \(item.displayName)")
                    .accessibilityValue(state.remember ? "включено" : "выключено")
                }
            }
            Rectangle().fill(theme.primary.opacity(0.08)).frame(height: 1).padding(.top, 8)
            HStack(spacing: 5) {
                KeyCap("⏎").scaleEffect(0.9)
                Text("— подтвердить")
                Text("·").foregroundStyle(theme.primary.opacity(0.25))
                KeyCap("Esc").scaleEffect(0.9)
                Text(state.confirmingQuit ? "— назад" : "— отмена")
                Spacer(minLength: 4)
                if !state.confirmingQuit && card.options.count > 1 { KeyCap("↑").scaleEffect(0.9); KeyCap("↓").scaleEffect(0.9) }
            }
            .font(theme.font(11.5, .semibold))
            .foregroundStyle(theme.tertiary)
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 2, trailing: 8))
        }
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
        .background {
            GeometryReader { g in
                if attached {
                    IslandBackground(metrics: IslandMetrics(width: g.size.width, height: g.size.height, cornerRadius: 22,
                                                            earRadius: 12),
                                     coreHeight: 0, showRim: false)
                        .frame(width: g.size.width + 24, height: g.size.height)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                } else {
                    IslandBackground(metrics: IslandMetrics(width: g.size.width, height: g.size.height, cornerRadius: 22,
                                                            earRadius: 0),
                                     coreHeight: 0, showRim: false)
                        .frame(width: g.size.width, height: g.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Capsule().fill(MenuBarStyle.highlight(theme)).frame(width: 34, height: 3)
                .shadow(color: MenuBarStyle.highlight(theme), radius: 5)
                .offset(x: nubX - 17, y: -1)
                .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        .contentShape(Rectangle())
        .onTapGesture {}   // щелчок по карточке не закрывает режим
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
    }
}

struct OptionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var on: Bool
    var destructive: Bool
    var key: String?
    var action: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let red = MenuBarStyle.red(theme)
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(destructive ? red : on ? IslandPalette.warmText(theme) : theme.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(theme.font(13.5, .semibold)).foregroundStyle(destructive ? red : theme.primary)
                    Text(detail).font(theme.font(11.5, .medium)).foregroundStyle(theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let key { KeyCap(key, on: on) }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background {
                let s = RoundedRectangle(cornerRadius: 13, style: .continuous)
                s.fill(on ? theme.accentColor.opacity(0.20) : Color.clear)
                    .overlay(s.stroke(theme.accentColor.opacity(on ? 0.85 : 0), lineWidth: 1.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 3)
        .accessibilityLabel("\(title): \(detail)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Компакт во время уборки

struct CleanupCompactLeading: View {
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paintbrush.pointed.fill").font(.system(size: 11, weight: .bold))
            Text("Уборка").font(theme.font(12.5, .bold))
        }
        .foregroundStyle(IslandPalette.warmText(theme))
        .lineLimit(1)
        .fixedSize()
    }
}

struct CleanupCompactTrailing: View {
    var visible: Int
    var notch: Int
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 4) {
            Text(MenuBarText.icons(visible)).foregroundStyle(theme.tertiary)
            if notch > 0 { Text("· +\(notch) под вырезом").foregroundStyle(IslandPalette.readable(Color(hex: "#FFCF70"), on: theme)) }
        }
        .font(theme.font(12, .bold))
        .lineLimit(1)
        .fixedSize()
    }
}
