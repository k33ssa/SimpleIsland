import AppKit
import SwiftUI
import IslandCore

/// Редактор своего пресета (16.11, «свой режим, в котором меняем по частотам чёрточки»): предусилитель + 10 полос
/// «Музыки». Каждая полоса — вертикальная дорожка с «чёрточкой»-ручкой: тянуть мышью, колесо/трекпад и ↑/↓ над
/// полосой (⇧ — по 3 дБ), двойной клик — 0. Значение в дБ — над полосой при наведении и перетаскивании. Линия через
/// ручки — форма АЧХ. Значения сразу в модели, в «Музыку» — с дебаунсом (`MusicEqualizer.setValue`), конец
/// перетаскивания — сразу (`flush`).
struct EqualizerBandsEditor: View {
    @ObservedObject var music: MusicEqualizer
    let presetId: String
    /// Удержание раскрытого острова на время перетаскивания (курсор может уйти за край).
    var hold: (Bool) -> Void = { _ in }

    @Environment(\.islandTheme) private var theme
    @Environment(\.islandMotion) private var motion
    @State private var dragging: Int?
    @State private var scrollMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var scrollAccum: CGFloat = 0

    static let sliders = CustomEQPreset.bandCount + 1
    static let valueHeight: CGFloat = 15
    static let labelHeight: CGFloat = 14

    var body: some View {
        let preset = music.editable(presetId)
        GeometryReader { g in
            let preampW: CGFloat = 40
            let sepW: CGFloat = 12
            let colW = (g.size.width - preampW - sepW) / CGFloat(CustomEQPreset.bandCount)
            let trackTop = Self.valueHeight + 2
            let trackH = max(20, g.size.height - trackTop - Self.labelHeight - 4)
            ZStack(alignment: .topLeading) {
                grid(width: g.size.width, top: trackTop, height: trackH, preampW: preampW, sepW: sepW)
                if let p = preset {
                    curve(p, top: trackTop, height: trackH, x0: preampW + sepW, colW: colW)
                }
                HStack(spacing: 0) {
                    column(0, preset: preset, width: preampW, trackH: trackH)
                    Rectangle().fill(theme.primary.opacity(0.08)).frame(width: 1, height: trackH)
                        .padding(.top, trackTop).frame(width: sepW, alignment: .top)
                    ForEach(1..<Self.sliders, id: \.self) { i in column(i, preset: preset, width: colW, trackH: trackH) }
                }
            }
        }
        .onDisappear { removeMonitors(); music.flush(); if dragging != nil { hold(false) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Полосы эквалайзера")
    }

    // MARK: Фон: сетка 0 / ±6 / ±12

    private func grid(width: CGFloat, top: CGFloat, height: CGFloat, preampW: CGFloat, sepW: CGFloat) -> some View {
        Canvas { ctx, _ in
            for (db, a) in [(12.0, 0.05), (6.0, 0.05), (0.0, 0.16), (-6.0, 0.05), (-12.0, 0.05)] {
                let y = top + CustomEQPreset.y(of: db, height: height)
                var p = Path()
                p.move(to: CGPoint(x: preampW + sepW - 2, y: y)); p.addLine(to: CGPoint(x: width, y: y))
                ctx.stroke(p, with: .color(theme.primary.opacity(a)),
                           style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [2, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    /// Линия АЧХ через ручки полос (сглаженная), под ней — лёгкая заливка до нуля.
    private func curve(_ p: CustomEQPreset, top: CGFloat, height: CGFloat, x0: CGFloat, colW: CGFloat) -> some View {
        let pts = p.bands.enumerated().map { CGPoint(x: x0 + colW * (CGFloat($0.offset) + 0.5),
                                                      y: top + CustomEQPreset.y(of: $0.element, height: height)) }
        let zeroY = top + CustomEQPreset.y(of: 0, height: height)
        return Canvas { ctx, _ in
            guard pts.count > 1 else { return }
            var line = Path()
            line.move(to: pts[0])
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                let mx = (a.x + b.x) / 2
                line.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
            }
            var fill = line
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: zeroY))
            fill.addLine(to: CGPoint(x: pts[0].x, y: zeroY))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(theme.accentColor.opacity(0.10)))
            ctx.stroke(line, with: .color(theme.accentColor.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .allowsHitTesting(false)
    }

    // MARK: Полоса

    private func column(_ i: Int, preset: CustomEQPreset?, width: CGFloat, trackH: CGFloat) -> some View {
        let v = preset?[slider: i] ?? 0
        let hot = music.hotSlider == i || dragging == i
        let label = i == 0 ? "пред." : CustomEQPreset.labels[i - 1]
        let knobY = CustomEQPreset.y(of: v, height: trackH)
        let zeroY = CustomEQPreset.y(of: 0, height: trackH)
        let spring = motion.animation(.spring(response: theme.spring.response * 0.6, dampingFraction: max(0.6, theme.spring.damping)))
        return VStack(spacing: 2) {
            Text(CustomEQPreset.format(v) + " дБ")
                .font(theme.font(10.5, .bold)).monospacedDigit()
                .foregroundStyle(v == 0 ? theme.secondary : theme.primary)
                .lineLimit(1).fixedSize()
                .opacity(hot ? 1 : 0)
                .frame(height: Self.valueHeight)
            ZStack(alignment: .top) {
                // Дорожка
                Capsule().fill(theme.controlFillColor).frame(width: 2, height: trackH)
                // Заливка от нуля до значения
                Capsule().fill(theme.accentColor.opacity(hot ? 0.9 : 0.6))
                    .frame(width: 2, height: max(0, abs(knobY - zeroY)))
                    .offset(y: min(knobY, zeroY))
                // Чёрточка-ручка
                Capsule()
                    .fill(hot ? theme.accentColor : theme.primary.opacity(v == 0 ? 0.7 : 0.95))
                    .frame(width: hot ? 20 : 16, height: hot ? 5 : 4)
                    .shadow(color: hot ? theme.accentColor.opacity(0.5) : .clear, radius: 4)
                    .offset(y: knobY - (hot ? 2.5 : 2))
            }
            .frame(width: width, height: trackH, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragging != i { dragging = i; hold(true) }
                        music.setValue(presetId, slider: i, to: CustomEQPreset.value(atY: g.location.y, height: trackH))
                    }
                    .onEnded { _ in
                        dragging = nil
                        music.flush()
                        hold(false)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { music.setValue(presetId, slider: i, to: 0); music.flush() })
            .onHover { inside in
                if inside { music.hotSlider = i; installMonitors() }
                else if music.hotSlider == i { music.hotSlider = nil; removeMonitors() }
            }
            Text(label)
                .font(theme.font(10, hot ? .bold : .semibold)).lineLimit(1).fixedSize()
                .foregroundStyle(hot ? theme.primary : theme.tertiary)
                .frame(height: Self.labelHeight)
        }
        .frame(width: width)
        .animation(spring, value: hot)
        .help(i == 0 ? "Предусилитель — общий уровень" : "\(label) Гц: тяните, колесо или ↑/↓; двойной клик — 0")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(i == 0 ? "Предусилитель" : "\(label) герц")
        .accessibilityValue("\(CustomEQPreset.format(v)) децибел")
        .accessibilityAdjustableAction { dir in
            music.setValue(presetId, slider: i, to: v + (dir == .increment ? 1 : -1))
        }
    }

    // MARK: Колесо и стрелки над полосой

    /// Пока курсор над полосой: колесо/трекпад и ↑/↓ меняют её (монитор событий только своего процесса, снимается
    /// при уходе курсора и закрытии редактора). Стрелки — когда остров принял клавиатуру (редактор её просит) и
    /// фокус не в поле имени.
    private func installMonitors() {
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                let box = UncheckedBox(e)
                return MainActor.assumeIsolated { handleScroll(box.value) } ? nil : e
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                let box = UncheckedBox(e)
                return MainActor.assumeIsolated { handleKey(box.value) } ? nil : e
            }
        }
    }

    private func removeMonitors() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        scrollAccum = 0
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        guard let i = music.hotSlider, let p = music.editable(presetId) else { return false }
        // Колесо мыши — построчно (1 щелчок = 0,5 дБ), трекпад — точные пиксели (~10 pt = 0,5 дБ).
        let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 10 : e.scrollingDeltaY
        let dir: CGFloat = e.isDirectionInvertedFromDevice ? -1 : 1
        scrollAccum += d * dir
        let steps = (scrollAccum).rounded(.towardZero)
        guard steps != 0 else { return true }
        scrollAccum -= steps
        music.setValue(presetId, slider: i, to: CustomEQPreset.snapped(p[slider: i] + Double(steps) * 0.5))
        return true
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let i = music.hotSlider, let p = music.editable(presetId) else { return false }
        if e.window?.firstResponder is NSText { return false }   // печатают имя
        let step = e.modifierFlags.contains(.shift) ? 3.0 : 0.5
        switch e.keyCode {
        case 126: music.setValue(presetId, slider: i, to: CustomEQPreset.snapped(p[slider: i] + step))
        case 125: music.setValue(presetId, slider: i, to: CustomEQPreset.snapped(p[slider: i] - step))
        case 51, 117: music.setValue(presetId, slider: i, to: 0); music.flush()   // ⌫ — в 0
        default: return false
        }
        return true
    }
}

/// Строка редактора: «‹ Пресеты» · имя (правится на месте) · «Сбросить» · удалить (два нажатия) · вкл/выкл.
struct EqualizerEditorHeader: View {
    @ObservedObject var music: MusicEqualizer
    let presetId: String
    var close: () -> Void

    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var name = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let enabled = music.state?.enabled == true
        HStack(spacing: 8) {
            IslandButton("Пресеты", systemImage: "chevron.left", height: 22, accessibilityLabel: "Назад к пресетам") {
                commitName(); close()
            }
            .fixedSize()
            if presetId == MusicEqualizer.manualId {
                // Ручной пресет «Музыки»: имя не меняется, удалить нельзя — правятся только полосы.
                HStack(spacing: 6) {
                    Text(music.editable(presetId)?.name ?? "").font(theme.font(13, .bold)).foregroundStyle(theme.primary)
                        .lineLimit(1)
                    Text("пресет Музыки").font(theme.font(11, .medium)).foregroundStyle(theme.tertiary).lineLimit(1)
                }
                .padding(.horizontal, 8)
            } else if isSnapshot {
                // Снимок рисуется без окна: NSTextField там — жёлтая заглушка; имя — текстом.
                Text(music.editable(presetId)?.name ?? "").font(theme.font(13, .bold)).foregroundStyle(theme.primary)
                    .lineLimit(1).padding(.horizontal, 8)
            } else {
            TextField("", text: $name, prompt: Text("Имя пресета").foregroundStyle(theme.tertiary))
                .textFieldStyle(.plain)
                .font(theme.font(13, .bold)).foregroundStyle(theme.primary)
                .focused($nameFocused)
                .onSubmit { commitName(); nameFocused = false }
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 7).fill(nameFocused ? theme.controlFillColor : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(nameFocused ? theme.accentColor.opacity(0.7) : .clear))
                .frame(maxWidth: 190)
                .help("Имя пресета — так он будет называться и в Музыке")
                .accessibilityLabel("Имя пресета")
            }
            Spacer(minLength: 4)
            IslandButton("Сбросить", systemImage: "arrow.counterclockwise", height: 22,
                         accessibilityLabel: "Сбросить все полосы в ноль") { music.resetAll(presetId) }
                .fixedSize()
            if presetId != MusicEqualizer.manualId {
            IslandButton(confirmDelete ? "Удалить?" : nil, systemImage: "trash", style: confirmDelete ? .destructive : .plain,
                         height: 22, accessibilityLabel: confirmDelete ? "Подтвердить удаление" : "Удалить пресет") {
                if confirmDelete { music.delete(presetId); close() }
                else {
                    confirmDelete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDelete = false }
                }
            }
            .fixedSize()
            }
            IslandButton(enabled ? "Включён" : "Выключен", systemImage: enabled ? "checkmark" : "power",
                         style: enabled ? .accent : .plain, height: 22,
                         accessibilityLabel: "Эквалайзер Музыки \(enabled ? "включён" : "выключен")",
                         accessibilityHint: enabled ? "Выключить" : "Включить") { music.setEnabled(!enabled) }
                .fixedSize()
        }
        .onAppear { name = music.editable(presetId)?.name ?? "" }
        .onChange(of: music.editable(presetId)?.name) { n in if !nameFocused, let n { name = n } }
        .onChange(of: nameFocused) { f in if !f { commitName() } }
        .onDisappear { commitName() }
    }

    private func commitName() {
        guard presetId != MusicEqualizer.manualId, let cur = music.editable(presetId)?.name else { return }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { name = cur; return }
        if t != cur { music.rename(presetId, to: t) }
        name = music.editable(presetId)?.name ?? t
    }
}
