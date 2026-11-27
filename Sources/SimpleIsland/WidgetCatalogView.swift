import AppKit
import SwiftUI
import IslandCore
import VafaModule

// --- catalog --- Вид каталога виджетов по макету 11-catalog: «стекло» острова, поиск, категории, крупная карточка
// Vafa, сетка встроенных модулей, строка «Ещё от автора». Цвета — из темы через SettingsPalette (светлые темы —
// светлое стекло). Без NSView-обёрток, кроме подложки-размытия и поля поиска в живом окне (снимки их не рисуют).

struct WidgetCatalogView: View {
    @ObservedObject var state: WidgetCatalogState
    @ObservedObject var settings: SimpleIslandSettings
    var onClose: () -> Void
    @Environment(\.settingsPalette) private var p
    @Environment(\.isSnapshot) private var isSnapshot

    static let width: CGFloat = 1060

    init(state: WidgetCatalogState, onClose: @escaping () -> Void) {
        self.state = state; self.onClose = onClose; settings = state.env.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            categories.padding(.top, 16)
            let entries = state.visibleEntries
            if state.showsVafa {
                VafaFeatureCard(state: state).padding(.top, 16)
            }
            if !entries.isEmpty {
                HStack {
                    Text("Встроенные виджеты".uppercased())
                    Spacer()
                    Text("\(state.onIslandCount) из \(entries.count) на острове".uppercased())
                }
                .font(p.font(11.5, .bold)).tracking(0.9).foregroundStyle(p.ink4)
                .padding(.horizontal, 2).padding(.top, 18).padding(.bottom, 10)
                // Сетка 4 колонки (VStack/HStack, а не LazyVGrid: ImageRenderer снимков рисует её надёжно).
                VStack(spacing: 10) {
                    ForEach(Array(stride(from: 0, to: entries.count, by: 4)), id: \.self) { start in
                        HStack(spacing: 10) {
                            ForEach(start..<start + 4, id: \.self) { i in
                                if i < entries.count { CatalogCard(entry: entries[i], on: state.isOnIsland(entries[i].id), state: state) }
                                else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if state.showsMore {
                MoreFromAuthor(open: { state.openURL(WidgetCatalogData.screenTabURL) }).padding(.top, 14)
            }
            if entries.isEmpty && !state.showsVafa && !state.showsMore {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold)).foregroundStyle(p.ink4)
                    Text("Ничего не нашлось").font(p.font(14, .semibold)).foregroundStyle(p.ink2)
                    Text("Попробуйте другое слово или категорию «Все».").font(p.font(12.5)).foregroundStyle(p.ink3)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .padding(.top, 24).padding(.horizontal, 26).padding(.bottom, 22)
        .frame(width: Self.width, alignment: .topLeading)
        .background(CatalogGlass(light: p.light, isSnapshot: isSnapshot))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(p.light ? Color.black.opacity(0.08) : Color.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 14) {
            Text("Добавить виджет").font(p.font(22, .bold)).foregroundStyle(p.ink)
            Spacer(minLength: 12)
            SearchField(query: $state.query, isSnapshot: isSnapshot)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(p.ink3)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(p.ink.opacity(p.light ? 0.07 : 0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Закрыть каталог")
        }
    }

    private var categories: some View {
        HStack(spacing: 6) {
            ForEach(CatalogCategory.allCases) { c in
                let on = state.category == c
                Text(c.title)
                    .font(p.font(12.5, .semibold))
                    .foregroundStyle(on ? (p.light ? Color.white : Color.black) : p.ink3)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(on ? p.ink : p.ink.opacity(p.light ? 0.05 : 0.05)))
                    .contentShape(Capsule())
                    .onTapGesture { state.category = c }   // снимает и подсветку `focus`
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel("Категория \(c.title)")
            }
        }
    }
}

// MARK: - Подложка «стекло»

private struct CatalogGlass: View {
    var light: Bool
    var isSnapshot: Bool
    var body: some View {
        ZStack {
            if !isSnapshot { VisualEffectBlur(material: .hudWindow, light: light) }
            // Как в макете: rgba(16,14,22,.86) поверх размытия; светлая тема — молочное стекло.
            (light ? Color(hex: "#F7F6F3").opacity(0.90) : Color(hex: "#100E16").opacity(0.86))
        }
    }
}

/// Размытие того, что под окном (только в живом окне).
private struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var light: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
}

// MARK: - Поиск

private struct SearchField: View {
    @Binding var query: String
    var isSnapshot: Bool
    @Environment(\.settingsPalette) private var p
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink4)
            if isSnapshot {
                Text(query.isEmpty ? Self.placeholder : query).font(p.font(13)).foregroundStyle(query.isEmpty ? p.ink4 : p.ink)
                Spacer(minLength: 0)
            } else {
                TextField("", text: $query, prompt: Text(Self.placeholder).foregroundColor(p.ink4))
                    .textFieldStyle(.plain)
                    .font(p.font(13))
                    .foregroundStyle(p.ink)
                    .focused($focused)
                    .onAppear { focused = true }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(p.ink4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 300, height: 34)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.ink.opacity(p.light ? 0.06 : 0.07)))
    }

    static let placeholder = "Найти: музыка, погода, файлы…"
}

// MARK: - Кнопки

/// Кнопка-капсула каталога: `solid` — контрастная (белая на тёмном, чёрная на светлом), `plain` — тихая,
/// `added` — зелёная «На острове ✓».
struct CatalogButton: View {
    enum Style { case solid, plain, added }
    var title: String
    var systemImage: String?
    var style: Style = .solid
    var height: CGFloat = 26
    var enabled = true
    var action: () -> Void = {}
    @Environment(\.settingsPalette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s).font(.system(size: height * 0.44, weight: .bold)) }
                Text(title).font(p.font(height * 0.46, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, height * 0.46)
            .frame(height: height)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        // Не .disabled: тот приглушает вид, а «На острове ✓» — это состояние, а не выключенная кнопка.
        .allowsHitTesting(enabled)
        .accessibilityAddTraits(enabled ? [] : .isStaticText)
    }

    private var fg: Color {
        switch style {
        case .solid: return p.light ? .white : .black
        case .plain: return p.ink2
        case .added: return SettingsColors.ok(p).opacity(p.light ? 1 : 0.95)
        }
    }
    private var bg: Color {
        switch style {
        case .solid: return p.light ? Color(hex: "#111111") : .white
        case .plain: return p.ink.opacity(p.light ? 0.07 : 0.08)
        case .added: return Color(hex: "#39D98A").opacity(p.light ? 0.16 : 0.14)
        }
    }
}

// MARK: - Карточка встроенного модуля

private struct CatalogCard: View {
    var entry: CatalogEntry
    /// «На острове» — полем, а не вычислением внутри: тогда смена значения — новое значение вьюхи, и SwiftUI
    /// перерисует карточку, даже если решит, что `state` не менялся.
    var on: Bool
    @ObservedObject var state: WidgetCatalogState
    @Environment(\.settingsPalette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: entry.gradient.map { Color(hex: $0) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: entry.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(p.font(14, .bold)).foregroundStyle(p.ink).lineLimit(1)
                    Text(entry.subtitle).font(p.font(11, .semibold)).foregroundStyle(p.ink4).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(entry.description).font(p.font(12)).foregroundStyle(p.ink3).lineSpacing(1.5)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if on {
                    CatalogButton(title: "На острове", systemImage: "checkmark", style: .added, enabled: false)
                    if state.canRemove(entry.id) {
                        CatalogButton(title: "Убрать", style: .plain) { state.setOnIsland(entry.id, false) }
                            .accessibilityLabel("Убрать \(entry.title) с острова")
                    }
                } else {
                    CatalogButton(title: "Добавить", systemImage: "plus") { state.setOnIsland(entry.id, true) }
                        .accessibilityLabel("Добавить \(entry.title) на остров")
                }
            }
        }
        .padding(14)
        // Высота — по самой высокой карточке ряда (ряд — fixedSize по вертикали), не меньше 158 как в макете.
        .frame(minHeight: 158, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.ink.opacity(p.light ? 0.04 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(state.focus == entry.id ? p.accent : p.ink.opacity(0.06), lineWidth: state.focus == entry.id ? 2 : 1))
        .help(state.canRemove(entry.id) ? "" : "Работает без вкладки — отдельные события включаются в настройках")
    }
}

// MARK: - Vafa

private struct VafaFeatureCard: View {
    @ObservedObject var state: WidgetCatalogState
    @Environment(\.settingsPalette) private var p

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Group {
                if let img = CatalogImages.image("vafa", points: 96) {
                    Image(nsImage: img).resizable().interpolation(.high)
                } else {
                    ZStack {
                        Color.black
                        Image(systemName: "lock.shield.fill").font(.system(size: 40)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Vafa").font(p.font(20, .bold)).foregroundStyle(p.ink)
                    Text("ОТДЕЛЬНОЕ ПРИЛОЖЕНИЕ").font(p.font(10.5, .bold)).tracking(0.8)
                        .foregroundStyle(p.light ? Color(hex: "#3B4FC4") : Color(hex: "#9FB4FF"))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#788CFF").opacity(p.light ? 0.16 : 0.14)))
                }
                Text(WidgetCatalogData.vafaDescription)
                    .font(p.font(13.5)).foregroundStyle(p.ink2).lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.top, 6)
                HStack(spacing: 12) {
                    ForEach(WidgetCatalogData.vafaMeta, id: \.self) { Text($0) }
                }
                .font(p.font(11.5)).foregroundStyle(p.ink4).padding(.top, 8)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(18)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(p.ink.opacity(p.light ? 0.04 : 0.045))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(EllipticalGradient(colors: [Color(hex: "#7882AA").opacity(p.light ? 0.16 : 0.22), .clear],
                                             center: UnitPoint(x: 0, y: 0.5), startRadiusFraction: 0, endRadiusFraction: 0.6))
            }
        )
        // Открыли «из Vafa» — карточка подсвечена акцентом темы, пока не сменят категорию или поиск.
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(focused ? p.accent : p.ink.opacity(0.08), lineWidth: focused ? 2 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vafa, отдельное приложение")
    }

    private var focused: Bool { state.focus == VafaIslandModule.moduleId }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch state.vafa {
            case .installed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Установлена")
                }
                .font(p.font(12.5, .semibold)).foregroundStyle(SettingsColors.ok(p))
                if state.vafaWidgetOn {
                    HStack(spacing: 6) {
                        CatalogButton(title: "Виджет на острове", systemImage: "checkmark", style: .added, height: 34, enabled: false)
                        CatalogButton(title: "Убрать", style: .plain, height: 34) { state.setOnIsland(VafaIslandModule.moduleId, false) }
                            .accessibilityLabel("Убрать виджет Vafa с острова")
                    }
                } else {
                    CatalogButton(title: "Добавить виджет", systemImage: "plus", height: 38) { state.addVafaWidget() }
                }
            case .installing:
                CatalogButton(title: "Устанавливается…", systemImage: "hourglass", style: .plain, height: 38, enabled: false)
                Text("Введите пароль в Терминале — карточка обновится сама")
                    .font(p.font(11.5)).foregroundStyle(p.ink3)
                command
                // Терминал закрыли, пароль не подошёл, brew упал — отсюда не видно: дать выйти из ожидания.
                HStack(spacing: 6) {
                    CatalogButton(title: "Повторить", systemImage: "arrow.clockwise", style: .plain) { state.retryInstall() }
                        .accessibilityHint("Снова открыть Терминал с командой установки")
                    CatalogButton(title: "Отмена", style: .plain) { state.cancelInstall() }
                        .accessibilityHint("Перестать ждать установку")
                }
            case .canBrew:
                CatalogButton(title: "Установить", systemImage: "arrow.down.to.line", height: 38) { state.installVafa() }
                    .accessibilityHint("Откроется Терминал с командой Homebrew; пароль администратора вводится там")
                if let note = state.installNote {
                    Text(note).font(p.font(11.5)).foregroundStyle(SettingsColors.err(p))
                        .multilineTextAlignment(.trailing).frame(width: 260, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                command
            case .download:
                CatalogButton(title: "Скачать", systemImage: "arrow.down.to.line", height: 38) { state.downloadVafa() }
                    .accessibilityHint("Откроется страница загрузки на GitHub")
                Text("github.com/k33ssa/vafa").font(p.mono).foregroundStyle(p.ink3)
            }
        }
        .fixedSize()
    }

    private var command: some View {
        Text(WidgetCatalogData.vafaCommand)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(p.ink3)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(p.light ? 0.06 : 0.4)))
            .textSelection(.enabled)
            .help("Будет выполнено в Терминале")
    }
}

// MARK: - Ещё от автора

private struct MoreFromAuthor: View {
    var open: () -> Void
    @Environment(\.settingsPalette) private var p

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = CatalogImages.image("simplescreentab", points: 28) {
                    Image(nsImage: img).resizable().interpolation(.high)
                } else {
                    Image(systemName: "command").foregroundStyle(p.ink2)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
            (Text("Ещё от автора: ").font(p.font(12.5, .bold)).foregroundColor(p.ink)
             + Text("SimpleScreenTab — ⌘Tab показывает только приложения с текущего монитора.").font(p.font(12.5)).foregroundColor(p.ink3))
                .lineLimit(1)
            Spacer(minLength: 8)
            CatalogButton(title: "Подробнее", style: .plain, action: open)
                .accessibilityHint("Откроется страница SimpleScreenTab на GitHub")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.ink.opacity(p.light ? 0.03 : 0.03)))
    }
}
