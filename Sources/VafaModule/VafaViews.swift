import AppKit
import SwiftUI
import IslandCore

// Вкладка Vafa, уши компакта и вспышки. Цвета — из темы (`IslandPalette.readable` — темнее на светлых островах).

enum VafaStyle {
    static let alarm = Color(hex: "#FF5470")
    static let alarm2 = Color(hex: "#B5179E")
    static let okColors = [Color(hex: "#39D98A"), Color(hex: "#0F9D58")]
    static let alarmColors = [Color(hex: "#FF5470"), Color(hex: "#B5179E")]
    static let idleColors = [Color(hex: "#6B7280"), Color(hex: "#374151")]
    static let checkColors = [Color(hex: "#FFB020"), Color(hex: "#FF7A45")]

    /// «DE» → «Германия».
    static func countryName(_ code: String) -> String? {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard c.count == 2 else { return nil }
        return Locale(identifier: "ru_RU").localizedString(forRegionCode: c)
    }

    /// Ширина текста шрифтом темы (для ширины ушей HUD/компакта).
    @MainActor static func width(_ text: String, size: CGFloat, weight: NSFont.Weight, theme: Theme) -> CGFloat {
        let font: NSFont = theme.font.family == .mono
            ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: - Вкладка

struct VafaTabView: View {
    @ObservedObject var model: VafaModel
    var openCatalog: () -> Void
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            switch model.phase {
            case .notInstalled: NotInstalledView(installed: false, openCatalog: openCatalog)
            case .notRunning: NotInstalledView(installed: true, openCatalog: openCatalog)
            default:
                HStack(spacing: 10) {
                    ShieldTile(phase: model.phase, status: model.status).frame(width: 260)
                    ItemsTile(status: model.status, phase: model.phase)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Открыли вкладку — перечитать один раз (служба могла замолчать: «давно не обновлялся»).
        .onAppear { if !isSnapshot && model.isRunning { model.reload() } }
    }
}

/// Щит: состояние охраны, страна выхода, что делать без VPN.
private struct ShieldTile: View {
    var phase: VafaPhase
    var status: VafaStatus?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: symbol).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vafa").font(theme.font(11.5, .bold)).foregroundStyle(theme.tertiary)
                        Text(title).font(theme.font(15, .bold)).foregroundStyle(titleColor)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(note).font(theme.font(12)).foregroundStyle(theme.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    if let exit = exitText { Chip(exit, systemImage: "globe") }
                    if let s = status, !s.iface.isEmpty, phase != .stale { Chip(s.iface) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch phase {
        case .ok: return "checkmark.shield.fill"
        case .triggered: return "lock.shield.fill"
        case .checking: return "shield.lefthalf.filled"
        case .stale, .notInstalled, .notRunning: return "shield.slash.fill"
        }
    }
    private var colors: [Color] {
        switch phase {
        case .ok: return VafaStyle.okColors
        case .triggered: return VafaStyle.alarmColors
        case .checking: return VafaStyle.checkColors
        case .stale, .notInstalled, .notRunning: return VafaStyle.idleColors
        }
    }
    private var title: String {
        switch phase {
        case .ok: return "Охрана включена"
        case .triggered: return status?.state == "down" ? "VPN выключен — охрана сработала" : "Охрана сработала"
        case .checking: return status?.routeIsVPN == false ? "VPN пропал — жду" : "Проверяю страну VPN…"
        case .stale: return "Vafa не отвечает"
        case .notInstalled: return "Vafa не установлена"
        case .notRunning: return "Vafa не запущена"
        }
    }
    private var titleColor: Color {
        phase == .triggered ? IslandPalette.readable(VafaStyle.alarm, on: theme) : theme.primary
    }
    private var note: String {
        switch phase {
        case .ok: return "Выбранные программы работают. Если VPN пропадёт, они замрут, пока он не вернётся."
        case .triggered:
            let n = status?.blocked.count ?? 0
            return n == 0 ? "Без VPN программы под охраной не запустятся." : "Программы под охраной заморожены и оживут сами, когда VPN включится."
        case .checking:
            // unsure у vpn-guard — два разных случая: маршрут через VPN, но страна не подтверждена, или VPN пропал
            // и идёт пауза GRACE. В обоих сеть к сервисам Claude уже закрыта (net: hold), программы не тронуты.
            let closed = status?.netClosed == true
            if status?.routeIsVPN == false {
                return "VPN пропал. Если не вернётся за паузу, программы замрут." + (closed ? " Сеть к Claude уже закрыта." : "")
            }
            return "Страна выхода VPN ещё не подтверждена. "
                + (closed ? "Сеть к Claude закрыта до проверки, программы не трогаю." : "Программы пока не трогаю.")
        case .stale: return "Файл статуса давно не обновлялся — служба Vafa, похоже, остановлена."
        case .notInstalled, .notRunning: return ""
        }
    }
    private var exitText: String? {
        // В паузе GRACE (VPN пропал) страна — от прошлого выхода: не показывать.
        guard let s = status, phase != .stale, s.vpn || (phase == .checking && s.routeIsVPN), !s.country.isEmpty else { return nil }
        let name = VafaStyle.countryName(s.country) ?? s.country
        return "Выход: \(name)"
    }
}

/// Список того, за чем присматривает Vafa.
private struct ItemsTile: View {
    var status: VafaStatus?
    var phase: VafaPhase
    @Environment(\.islandTheme) private var theme
    private let maxRows = 4

    var body: some View {
        let items = status?.items ?? []
        Tile(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ПОД ОХРАНОЙ").font(theme.font(10.5, .bold)).tracking(0.7).foregroundStyle(theme.tertiary)
                    Spacer()
                    if let s = status, s.frozenCount > 0 {
                        Text("заморожено процессов: \(s.frozenCount)").font(theme.font(10.5, .bold))
                            .foregroundStyle(IslandPalette.readable(VafaStyle.alarm, on: theme))
                    }
                }
                if items.isEmpty {
                    Text("Список пуст — выберите программы в Vafa.").font(theme.font(12.5)).foregroundStyle(theme.secondary)
                } else {
                    ForEach(Array(items.prefix(maxRows).enumerated()), id: \.offset) { i, item in
                        ItemRow(item: item, isCLI: status?.cli != nil && i == (status?.apps.count ?? 0))
                    }
                    if items.count > maxRows {
                        Text("и ещё \(items.count - maxRows)").font(theme.font(11.5, .semibold)).foregroundStyle(theme.tertiary)
                    }
                }
            }
        }
    }
}

private struct ItemRow: View {
    var item: VafaStatus.Item
    var isCLI: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCLI ? "terminal.fill" : (item.isBlocked ? "lock.fill" : "macwindow"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.isBlocked ? IslandPalette.readable(VafaStyle.alarm, on: theme) : theme.tertiary)
                .frame(width: 18)
            Text(isCLI ? VafaStatus.cliName : item.name).font(theme.font(13, .semibold)).foregroundStyle(theme.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(state).font(theme.font(11.5, .semibold)).foregroundStyle(stateColor).lineLimit(1)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(item.isBlocked ? VafaStyle.alarm.opacity(theme.isLight ? 0.10 : 0.12) : Color.clear))
        .accessibilityElement(children: .combine)
    }

    private var state: String {
        if item.frozen > 0 { return item.frozen == item.procs ? "заморожено" : "заморожено \(item.frozen) из \(item.procs)" }
        if item.locked { return "запуск запрещён" }
        if item.procs == 0 { return "не запущено" }
        return "работает · \(item.procs) \(Self.procs(item.procs))"
    }
    private var stateColor: Color {
        if item.isBlocked { return IslandPalette.readable(VafaStyle.alarm, on: theme) }
        return item.procs > 0 ? IslandPalette.okText(theme) : theme.tertiary
    }
    static func procs(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "процесс" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "процесса" }
        return "процессов"
    }
}

/// Файла статуса нет: что это и где взять. `installed` — Vafa стоит, но служба ещё не запускалась.
private struct NotInstalledView: View {
    var installed: Bool
    var openCatalog: () -> Void
    @Environment(\.islandTheme) private var theme
    private static let appURL = URL(fileURLWithPath: "/Applications/Vafa.app")

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: VafaStyle.idleColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "lock.shield").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(installed ? "Vafa не запущена" : "Vafa не установлена").font(theme.font(19, .bold)).foregroundStyle(theme.primary)
                Text(installed
                     ? "Vafa установлена, но служба охраны ещё не запускалась. Откройте Vafa и включите охрану — статус появится здесь сам."
                     : "Vafa — охрана приложений без VPN: выбранные программы замирают, пока VPN выключен, и сами оживают, когда он вернётся.")
                    .font(theme.font(12.5)).foregroundStyle(theme.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440, alignment: .leading)
                if installed {
                    IslandButton("Открыть Vafa", systemImage: "lock.shield", style: .solid, height: 28,
                                 accessibilityHint: "Откроется приложение Vafa") {
                        NSWorkspace.shared.open(Self.appURL)
                    }
                    .padding(.top, 4)
                } else {
                    IslandButton("Открыть каталог", systemImage: "square.grid.2x2", style: .solid, height: 28,
                                 accessibilityHint: "Каталог виджетов, раздел «Мои приложения»") { openCatalog() }
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Компакт

/// Левое ухо: замок охраны.
struct VafaCompactLeading: View {
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield.fill").font(.system(size: 13, weight: .semibold))
            Text("VPN").font(theme.font(11.5, .heavy)).strikethrough()
        }
        .foregroundStyle(IslandPalette.readable(VafaStyle.alarm, on: theme))
    }
}

/// Правое ухо: снежинка и сколько программ заморожено (`frozen`); ничего не заморожено — замок и сколько
/// программ с запретом запуска.
struct VafaCompactTrailing: View {
    var count: Int
    var frozen: Bool = true
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: frozen ? "snowflake" : "lock.fill").font(.system(size: 12, weight: .bold))
            Text("\(count)").font(theme.font(12.5, .bold)).monospacedDigit()
        }
        .foregroundStyle(IslandPalette.readable(Color(hex: "#7CC8FF"), on: theme))
    }
}

/// Вспышка «всё снова работает»: слева щит с галочкой.
struct VafaFlashLeading: View {
    var text: String
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 13.5, weight: .semibold))
            Text(text).font(theme.font(12.5, .bold)).lineLimit(1)
        }
        .foregroundStyle(IslandPalette.okText(theme))
    }
}

struct VafaFlashNote: View {
    var text: String
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Text(text).font(theme.font(12.5, .semibold)).foregroundStyle(theme.tertiary).lineLimit(1)
    }
}
