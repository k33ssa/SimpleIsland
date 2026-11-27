import SwiftUI
import IslandCore

// MARK: - Погода

struct WeatherTile: View {
    @ObservedObject var model: TodayModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        tile.contentShape(Rectangle()).onTapGesture { model.openWeather() }.help("Открыть «Погоду»")
    }

    private var tile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                TileLabel(Self.shortCity(model.prefs.cityName), systemImage: model.weather.map { WeatherAPI.describe($0.code, isDay: $0.isDay).symbol } ?? "cloud") {
                    if let p = model.weatherProblem {
                        Image(systemName: p == .offline ? "wifi.slash" : "exclamationmark.triangle").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(IslandPalette.warmText(theme))
                            .help(p == .offline ? "Нет сети — показано последнее значение" : "open-meteo не ответил — показано последнее значение")
                    }
                }
                if let w = model.weather {
                    Text(WeatherAPI.degrees(w.temperature))
                        .font(theme.font(30, .light)).tracking(-0.8).monospacedDigit()
                        .foregroundStyle(theme.primary)
                        .padding(.top, 3)
                    Group {
                        if let p = model.weatherProblem {
                            Text("\(p == .offline ? "нет сети" : "нет ответа") · \(EventLogic.stamp(w.fetchedAt, now: model.now))")
                                .foregroundStyle(IslandPalette.warmText(theme))
                        } else {
                            Text(WeatherAPI.summary(w, now: model.now)).foregroundStyle(theme.tertiary)
                        }
                    }
                    .font(theme.font(11.5, .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    hours(w)
                } else {
                    Spacer(minLength: 0)
                    Text(model.weatherLoading ? "Загружаю…" : (model.weatherProblem == .offline ? "Нет сети"
                         : (model.weatherProblem == .service ? "Сервис не ответил" : "Нет данных")))
                        .font(theme.font(15, .semibold)).foregroundStyle(theme.secondary)
                    Text(model.weatherProblem == .offline ? "Погода появится, когда вернётся интернет"
                         : (model.weatherProblem == .service ? "open-meteo.com — спрошу позже" : "open-meteo.com"))
                        .font(theme.font(11, .medium)).foregroundStyle(theme.tertiary).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func hours(_ w: WeatherSnapshot) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(w.hours(after: model.now).prefix(4).enumerated()), id: \.offset) { _, h in
                VStack(spacing: 2) {
                    Text(Self.hour(h.time)).font(theme.font(10.5, .medium)).foregroundStyle(theme.tertiary)
                    Group {
                        if WeatherAPI.isPrecipitation(h.code) {
                            Image(systemName: WeatherAPI.describe(h.code).symbol).font(.system(size: 11, weight: .bold))
                                .frame(height: 14)
                        } else {
                            Text(WeatherAPI.degrees(h.temperature)).font(theme.font(11.5, .bold))
                        }
                    }
                    .foregroundStyle(theme.primary)
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Короткое имя для подписи плитки (узкая): «Санкт-Петербург» → «Петербург».
    static func shortCity(_ name: String) -> String {
        let known = ["Санкт-Петербург": "Петербург", "Нижний Новгород": "Н. Новгород", "Ростов-на-Дону": "Ростов"]
        return known[name] ?? name
    }

    static func hour(_ d: Date) -> String {
        String(Calendar.current.component(.hour, from: d))
    }
}

// MARK: - Система

struct SystemTile: View {
    @ObservedObject var model: TodayModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                TileLabel("Система", systemImage: "cpu")
                Spacer(minLength: 0)
                GeometryReader { g in
                    let d = min(52, (g.size.width - 12) / 3)
                    HStack(spacing: 0) {
                        gauge(model.system.map { Self.pct($0.cpu) } ?? "–", value: model.system?.cpu ?? 0,
                              tint: Self.loadColor(model.system?.cpu ?? 0), label: "ЦП", d: d)
                        Spacer(minLength: 0)
                        gauge(model.system.map { Self.pct($0.memory) } ?? "–", value: model.system?.memory ?? 0,
                              tint: Self.loadColor(model.system?.memory ?? 0), label: "ОЗУ", d: d)
                            .help(model.system.map { String(format: "%.1f из %.0f ГБ", $0.memoryUsedGB, $0.memoryTotalGB) } ?? "")
                        Spacer(minLength: 0)
                        let th = model.system?.thermal ?? .nominal
                        gauge(model.system.map { SystemStats.thermalTitle($0.thermal) } ?? "–",
                              value: model.system == nil ? 0 : SystemStats.thermalLevel(th),
                              tint: Self.thermalColor(th), label: "Нагрев", d: d, small: true)
                    }
                }
                .frame(height: 76)
                Spacer(minLength: 0)
            }
        }
    }

    private func gauge(_ text: String, value: Double, tint: Color, label: String, d: CGFloat, small: Bool = false) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Ring(value: value, lineWidth: 4, tint: tint)
                Text(text).font(theme.font(small ? max(9, d * 0.21) : max(11, d * 0.27), .bold))
                    .foregroundStyle(theme.primary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 5)
            }
            .frame(width: d, height: d)
            Text(label).font(theme.font(10.5, .semibold)).foregroundStyle(theme.tertiary).lineLimit(1)
        }
        .frame(width: d + 8)
    }

    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }
    static func loadColor(_ v: Double) -> Color { v < 0.6 ? IslandPalette.ok : (v < 0.85 ? IslandPalette.warn : IslandPalette.err) }
    static func thermalColor(_ s: ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal: return IslandPalette.blue
        case .fair: return IslandPalette.warn
        default: return IslandPalette.err
        }
    }
}

// MARK: - Батареи

struct BatteriesTile: View {
    @ObservedObject var model: TodayModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("Батареи", systemImage: "battery.75percent")
                if model.batteries.isEmpty {
                    Spacer(minLength: 0)
                    Text("Нет батарей").font(theme.font(13, .semibold)).foregroundStyle(theme.secondary)
                    Text("Mac от сети, устройства заряд не отдают").font(theme.font(11, .medium))
                        .foregroundStyle(theme.tertiary).lineLimit(2)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(model.batteries.prefix(4)) { b in row(b) }
                    }
                    .padding(.top, 1)
                }
            }
        }
    }

    private func row(_ b: BatteryItem) -> some View {
        let tint: Color = b.charging ? IslandPalette.ok : (b.level <= 0.2 ? IslandPalette.err : theme.primary)
        return HStack(spacing: 7) {
            Image(systemName: b.symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(b.charging ? IslandPalette.readable(IslandPalette.ok, on: theme) : theme.primary)
                .frame(width: 15)
            Text(b.name).font(theme.font(12, .semibold)).foregroundStyle(theme.primary).lineLimit(1)
                .fixedSize()
            ProgressTrack(value: b.level, height: 5, tint: AnyShapeStyle(tint))
            Text("\(Int((b.level * 100).rounded()))%").font(theme.font(12, .semibold)).monospacedDigit()
                .foregroundStyle(theme.secondary).frame(width: 36, alignment: .trailing)
        }
    }
}
