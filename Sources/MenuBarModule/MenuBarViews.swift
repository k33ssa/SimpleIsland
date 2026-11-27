import AppKit
import IslandCore
import SwiftUI

// Вкладка «Значки» (макет 12, состояние 03), стопка в компакте (04), раздел настроек.

/// Картинка значка: настоящая (захват окна, право «Запись экрана») → системный SF Symbol → значок приложения.
struct MenuBarIconView: View {
    var item: MenuBarItem
    var model: MenuBarModel?
    var size: CGFloat
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if let img = model?.images[item.key] {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(height: size * 1.1)
            } else if let s = item.systemSymbol ?? model?.mockSymbols[item.key] {
                Image(systemName: s).font(.system(size: size, weight: .semibold)).foregroundStyle(theme.primary)
            } else if let img = model?.appIcon(item) {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: size * 1.45, height: size * 1.45)
            } else {
                Text(String(item.displayName.prefix(1))).font(theme.font(size, .bold)).foregroundStyle(theme.primary)
            }
        }
        .accessibilityHidden(true)
    }
}

struct MenuBarTabView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    static let columns = 8
    static let tileHeight: CGFloat = 104

    var body: some View {
        let items = MenuBarPlanner.islandItems(model.inventory, model.prefs)
        VStack(alignment: .leading, spacing: 10) {
            if !model.axGranted { AccessBanner(model: model) }
            if items.isEmpty {
                EmptyIconsTile(model: model)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: Self.columns), spacing: 10) {
                    ForEach(items.prefix(Self.columns * 2 - 1)) { item in
                        IconTile(item: item, fromNotch: item.section == .notch || model.prefs.fromNotch.contains(item.key),
                                 model: model)
                    }
                    MoreTile { model.startCleanup() }
                }
            }
            // Подвал как в макете: подсказки слева, «Спрятано совсем: N · в настройках» справа (или строка состояния).
            HStack(spacing: 14) {
                Text("Щелчок — меню значка")
                Text("⌥-щелчок — вернуть в строку меню")
                Spacer(minLength: 8)
                if let s = model.status {
                    Text(s).foregroundStyle(IslandPalette.warmText(theme)).lineLimit(1)
                } else if MenuBarPlanner.hiddenCount(model.prefs) > 0 {
                    Text("Спрятано совсем: \(MenuBarPlanner.hiddenCount(model.prefs)) · в настройках")
                        .foregroundStyle(theme.tertiary.opacity(0.8))
                }
            }
            .font(theme.font(12, .semibold))
            .foregroundStyle(theme.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if !isSnapshot { model.scanNow { _ in model.captureImages() } } }
    }

    /// Высота вкладки под содержимое: баннер прав, одна-две строки плиток, подвал.
    static func height(items: Int, axGranted: Bool) -> CGFloat {
        let banner: CGFloat = axGranted ? 0 : 46
        guard items > 0 else { return banner + 112 + 26 }
        let rows = CGFloat(min(2, (items + 1 + columns - 1) / columns))
        return banner + rows * tileHeight + (rows - 1) * 10 + 10 + 16
    }
}

private struct AccessBanner: View {
    var model: MenuBarModel
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(IslandPalette.warn).font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Нужен Универсальный доступ").font(theme.font(13, .bold)).foregroundStyle(theme.primary)
                Text(MenuBarAgent.isActive || model.inventory.source == .agentNoAccess
                     ? "macOS 27 рисует значки сама: без доступа их не видно и не перенести."
                     : "Без него значки не переносятся и их меню не открыть из острова.")
                    .font(theme.font(11.5, .medium)).foregroundStyle(theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            IslandButton("Разрешить", style: .accent, height: 26) { model.askAccessibility() }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IslandPalette.warn.opacity(0.12)))
    }
}

private struct EmptyIconsTile: View {
    var model: MenuBarModel
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "menubar.rectangle").font(.system(size: 30, weight: .regular)).foregroundStyle(theme.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Здесь будут значки из строки меню").font(theme.font(15, .bold)).foregroundStyle(theme.primary)
                Text("Включи уборку (\(model.prefs.hotKeyEnabled ? model.prefs.hotKey.displayString : "кнопка справа")) и щёлкни лишний значок — он переедет сюда. То, что macOS прячет под вырезом, тоже окажется здесь.")
                    .font(theme.font(12, .medium)).foregroundStyle(theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            IslandButton("Уборка", systemImage: "paintbrush.pointed.fill", style: .accent) { model.startCleanup() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.controlFillColor))
    }
}

private struct IconTile: View {
    var item: MenuBarItem
    var fromNotch: Bool
    var model: MenuBarModel
    @Environment(\.islandTheme) private var theme
    @State private var hover = false

    var body: some View {
        VStack(spacing: 8) {
            MenuBarIconView(item: item, model: model, size: 19)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.primary.opacity(0.08)))
            // Длинные имена («Скриншоты», «Stage Manager») — в две строки, чуть мельче, а не «Скринш…».
            Text(item.displayName).font(theme.font(item.displayName.count > 9 ? 11 : 12, .semibold))
                .foregroundStyle(theme.primary)
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 5)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .frame(height: MenuBarTabView.tileHeight)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(hover ? theme.primary.opacity(0.13) : theme.controlFillColor))
        .overlay(alignment: .topTrailing) {
            if fromNotch {
                Text("из-под выреза").font(.system(size: 9.5, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(IslandPalette.readable(Color(hex: "#FFCF70"), on: theme))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(IslandPalette.warn.opacity(0.16)))
                    .padding(5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option) { model.returnToBar(item.key) } else { model.open(item) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName + (fromNotch ? ", был под вырезом" : ""))
        .accessibilityHint("Открыть меню значка")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Вернуть в строку меню") { model.returnToBar(item.key) }
    }
}

private struct MoreTile: View {
    var action: () -> Void
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 19, weight: .semibold)).frame(width: 46, height: 46)
                Text("Ещё").font(theme.font(12, .semibold))
            }
            .foregroundStyle(theme.tertiary)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
            .frame(height: MenuBarTabView.tileHeight)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Убрать ещё значки — режим уборки")
    }
}

/// Правый верх верхней строки на вкладке: «3 не помещались под вырезом» и кнопка «Уборка».
struct MenuBarHeaderView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let notch = model.inventory.underNotch.count
            + model.inventory.inIslandSection.filter { model.prefs.fromNotch.contains($0.key) }.count
        let button = IslandButton("Уборка", systemImage: "paintbrush.pointed", height: 26,
                                  accessibilityLabel: "Уборка строки меню") { model.startCleanup() }
        let icon = IslandButton(systemImage: "paintbrush.pointed", height: 26, accessibilityLabel: "Уборка строки меню") {
            model.startCleanup()
        }
        // От полного к компактному: место справа делится с «Добавить виджет» ядра.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if notch > 0 { NotchBadge(text: "\(notch) не помещались под вырезом") }
                button
            }
            HStack(spacing: 6) {
                if notch > 0 { NotchBadge(text: "\(notch) под вырезом") }
                button
            }
            HStack(spacing: 6) {
                if notch > 0 { NotchBadge(text: "\(notch)") }
                button
            }
            // Самый тесный (ширина острова по умолчанию, 720): число «под вырезом» — значком-счётчиком на кнопке.
            icon.overlay(alignment: .topTrailing) {
                if notch > 0 {
                    Text("\(notch)").font(.system(size: 9, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(Color(hex: "#1A0F00"))
                        .padding(.horizontal, 3).frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(Color(hex: "#FFCF70")))
                        .offset(x: 4, y: -3)
                        .accessibilityLabel("Не помещались под вырезом: \(notch)")
                }
            }
        }
    }
}

/// Плашка «3 не помещались под вырезом» (макет 12, шапка вкладки): глаз + текст, тёплый цвет, компактная.
private struct NotchBadge: View {
    var text: String
    var compact = false
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            Image(systemName: "eye").font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(text).font(theme.font(11, .bold)).lineLimit(1)
        }
        .foregroundStyle(IslandPalette.readable(Color(hex: "#FFCF70"), on: theme))
        .padding(.horizontal, compact ? 5 : 8)
        .frame(height: 22)
        .background(Capsule().fill(IslandPalette.warn.opacity(0.16)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Не помещались под вырезом: \(text)")
    }
}

/// Стопка в правом ухе компакта: три последних значка и число спрятанных.
struct MenuBarStackView: View {
    var items: [MenuBarItem]
    var count: Int
    var model: MenuBarModel?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -7) {
                ForEach(items) { item in
                    MenuBarIconView(item: item, model: model, size: 11)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: "#2B2A31")))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(theme.surfaceColor, lineWidth: 1.5))
                }
            }
            Text("\(count)").font(theme.font(12, .heavy)).monospacedDigit()
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(theme.primary.opacity(0.16)))
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Спрятано значков: \(count)")
    }
}

// MARK: - Настройки

struct MenuBarSettingsView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var confirmReset = false
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group {
                Text("Уборка правой части строки меню: щёлкни лишний значок — он уедет во вкладку «Значки» острова, спрячется совсем или приложение закроется. Значки, которые macOS прячет под вырезом, тоже видны в острове.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Начать уборку") { model.startCleanup() }
                    Spacer()
                    Button("Вернуть всё как было…") { confirmReset = true }
                }
                Text("«Вернуть всё» убирает наш разделитель: все значки снова в строке меню, ничего не переносится и права не нужны. Если SimpleIsland закрыть или он упадёт — значки тоже сразу вернутся.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            group {
                Text("Значки").font(.headline)
                let rows = rowsList()
                if rows.isEmpty {
                    Text(model.isRunning || isSnapshot ? "Значков не найдено." : "Модуль выключен — включи вкладку «Значки» в «Раскладке».")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.key) { row in
                    HStack(spacing: 10) {
                        if let item = row.item {
                            MenuBarIconView(item: item, model: isSnapshot && !model.isRunning ? MenuBarMocks.settingsModel : model,
                                            size: 13).frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 22, height: 22).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { row.placement }, set: { model.setPlacement(row.key, $0) })) {
                            ForEach(MenuBarPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .disabled(!(row.item?.isMovable ?? true))
                    }
                }
            }
            group {
                Toggle("Стопка спрятанных значков в компакте острова", isOn: $model.prefs.showStack)
                Text("Три последних значка и число. Пока стопка включена и что-то спрятано, остров не уходит в покой — поставь модуль «Значки» в правое ухо в «Раскладке».")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Возвращать значки на место после перезапуска приложений", isOn: $model.prefs.restoreOnLaunch)
                HStack {
                    Toggle("Горячая клавиша уборки", isOn: $model.prefs.hotKeyEnabled)
                    Spacer()
                    Button(recording ? "Нажми сочетание…" : model.prefs.hotKey.displayString) { startRecording() }
                        .disabled(!model.prefs.hotKeyEnabled)
                    if model.prefs.hotKey != MenuBarPrefs.defaultHotKey {
                        Button("Сбросить") { model.prefs.hotKey = MenuBarPrefs.defaultHotKey }
                    }
                }
                if MenuBarHotKey.shared.lastStatus != 0 && model.prefs.hotKeyEnabled {
                    Text("Сочетание занято другим приложением — выбери другое.").font(.callout).foregroundStyle(.orange)
                }
            }
            group {
                PermissionRow(.accessibility, reason: "Переносить значки и открывать их меню из острова")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Настоящие значки").font(.system(size: 13, weight: .semibold))
                        Text("Картинка значка как в строке меню (с цифрами и индикаторами). Нужно право «Запись экрана»: macOS 15 раз в месяц напоминает, что приложение может записывать экран, поэтому по умолчанию выключено — вместо картинки значок приложения.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if model.prefs.realIcons {
                        Button("Выключить") { model.prefs.realIcons = false }
                    } else {
                        Button("Показывать настоящие значки") { model.enableRealIcons() }
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .confirmationDialog("Вернуть все значки в строку меню?", isPresented: $confirmReset) {
            Button("Вернуть всё", role: .destructive) { model.resetAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разделитель уберётся, спрятанные значки снова появятся в строке меню. Назначения забудутся.")
        }
        // Список значков — свежий снимок строки меню при открытии раздела (в покое модуль не сканирует).
        .onAppear { if !isSnapshot { model.scanNow() } }
        // Закрыли настройки посреди записи сочетания — горячая клавиша снята на время записи, вернуть её.
        .onDisappear { if recording { stopRecording(); model.applyHotKey() } else { stopRecording() } }
    }

    struct Row { var key: String; var name: String; var item: MenuBarItem?; var placement: MenuBarPlacement; var note: String? }

    /// Все значки в строке + запомненные, но сейчас не запущенные. В снимках (модуль не запущен) — мок-строка.
    private func rowsList() -> [Row] {
        let model = isSnapshot && !self.model.isRunning ? MenuBarMocks.settingsModel : self.model
        var rows: [Row] = model.inventory.items.map { it in
            Row(key: it.key, name: it.displayName, item: it, placement: model.prefs.placement(it.key),
                note: it.section == .notch ? "под вырезом" : it.isSystemIndicator ? "индикатор macOS — не прячется" : !it.isMovable ? "macOS не даёт двигать" : nil)
        }
        let known = Set(rows.map(\.key))
        for (k, p) in model.prefs.placements where !known.contains(k) {
            rows.append(Row(key: k, name: model.prefs.names[k] ?? k, item: nil, placement: p, note: "приложение не запущено"))
        }
        return rows
    }

    private func startRecording() {
        stopRecording()
        recording = true
        MenuBarHotKey.shared.unregister()
        // Только нажатия в окне настроек (оно ключевое в момент нажатия кнопки): ввод в острове и других окнах
        // приложения запись не перехватывает.
        let settingsWindow = NSApp.keyWindow.map(ObjectIdentifier.init)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard settingsWindow == nil || e.window.map(ObjectIdentifier.init) == settingsWindow else { return e }
            let code = e.keyCode
            let flags = e.modifierFlags
            MainActor.assumeIsolated {
                if code == 53 { stopRecording(); model.applyHotKey(); return }
                if let spec = MenuBarHotKey.spec(keyCode: code, flags: flags) {
                    model.prefs.hotKey = spec
                    stopRecording()
                    model.applyHotKey()
                }
            }
            return nil   // во время записи нажатия поглощаются
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    @ViewBuilder private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
