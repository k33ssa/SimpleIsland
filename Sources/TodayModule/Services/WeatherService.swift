import Foundation

/// Погода для плитки (уже разобранная).
struct WeatherSnapshot: Codable, Equatable, Sendable {
    struct Hour: Codable, Equatable, Sendable {
        var time: Date
        var temperature: Double
        var code: Int
    }
    var latitude: Double
    var longitude: Double
    var fetchedAt: Date
    var temperature: Double
    var apparent: Double?
    var code: Int
    var isDay: Bool
    /// Часы после текущего (до суток вперёд).
    var hours: [Hour]

    /// Часы после `now`: кеш мог остаться со вчера (без сети), прошедшие не показываем.
    func hours(after now: Date) -> [Hour] { hours.filter { $0.time > now } }
}

/// Open-Meteo (без ключа). Кеш 30 мин в памяти и последнее значение на диске — для офлайна.
enum WeatherAPI {
    static let cacheTTL: TimeInterval = 30 * 60

    static func forecastURL(lat: Double, lon: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", lat)),
            .init(name: "longitude", value: String(format: "%.4f", lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timezone", value: "auto"),
        ]
        return c.url!
    }

    private struct Raw: Decodable {
        struct Current: Decodable {
            var time: String
            var temperature_2m: Double
            var apparent_temperature: Double?
            var weather_code: Int
            var is_day: Int?
        }
        struct Hourly: Decodable {
            var time: [String]
            var temperature_2m: [Double?]
            var weather_code: [Int?]
        }
        var utc_offset_seconds: Int
        var current: Current
        var hourly: Hourly
    }

    /// Разбор ответа /v1/forecast. Время в ответе — местное время точки без зоны (`timezone=auto`), сдвиг — `utc_offset_seconds`.
    static func parse(_ data: Data, lat: Double, lon: Double, fetchedAt: Date = Date()) throws -> WeatherSnapshot {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: raw.utc_offset_seconds)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let now = f.date(from: raw.current.time) ?? fetchedAt
        var hours: [WeatherSnapshot.Hour] = []
        for (i, t) in raw.hourly.time.enumerated() {
            guard let d = f.date(from: t), d > now,
                  i < raw.hourly.temperature_2m.count, let temp = raw.hourly.temperature_2m[i],
                  i < raw.hourly.weather_code.count, let code = raw.hourly.weather_code[i] else { continue }
            hours.append(.init(time: d, temperature: temp, code: code))
            if hours.count >= 24 { break }
        }
        return WeatherSnapshot(latitude: lat, longitude: lon, fetchedAt: fetchedAt,
                               temperature: raw.current.temperature_2m, apparent: raw.current.apparent_temperature,
                               code: raw.current.weather_code, isDay: (raw.current.is_day ?? 1) != 0, hours: hours)
    }

    static func fetch(lat: Double, lon: Double) async throws -> WeatherSnapshot {
        var req = URLRequest(url: forecastURL(lat: lat, lon: lon), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("SimpleIsland", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try parse(data, lat: lat, lon: lon)
    }

    // MARK: Геокодинг (настройки: поиск города)

    struct Place: Decodable, Equatable, Identifiable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
        var country: String?
        var admin1: String?
        var id: String { "\(name)|\(latitude)|\(longitude)" }
        var subtitle: String { [admin1, country].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }.joined(separator: ", ") }
    }

    static func searchCity(_ name: String) async throws -> [Place] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "6"),
                        .init(name: "language", value: "ru"), .init(name: "format", value: "json")]
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.setValue("SimpleIsland", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        struct R: Decodable { var results: [Place]? }
        return try JSONDecoder().decode(R.self, from: data).results ?? []
    }

    /// Ошибка именно подключения («нет сети»), а не ответа сервиса (5xx, неразборчивый JSON).
    static func isNetworkError(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        let net: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                                       .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
                                       .dataNotAllowed, .callIsActive, .secureConnectionFailed]
        return net.contains(u.code)
    }

    // MARK: Диск (последнее значение для офлайна)

    static var cacheFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SimpleIsland/today-weather.json")
    }

    static func loadCached() -> WeatherSnapshot? {
        guard let d = try? Data(contentsOf: cacheFile) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WeatherSnapshot.self, from: d)
    }

    static func saveCached(_ w: WeatherSnapshot) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let d = try? enc.encode(w) else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: cacheFile, options: .atomic)
    }

    // MARK: Подписи

    /// Код погоды WMO → (подпись, SF Symbol).
    static func describe(_ code: Int, isDay: Bool = true) -> (text: String, symbol: String) {
        switch code {
        case 0: return ("Ясно", isDay ? "sun.max" : "moon.stars")
        case 1: return ("Почти ясно", isDay ? "sun.min" : "moon")
        case 2: return ("Переменная облачность", isDay ? "cloud.sun" : "cloud.moon")
        case 3: return ("Пасмурно", "cloud")
        case 45, 48: return ("Туман", "cloud.fog")
        case 51, 53, 55: return ("Морось", "cloud.drizzle")
        case 56, 57: return ("Ледяная морось", "cloud.sleet")
        case 61, 63: return ("Дождь", "cloud.rain")
        case 65: return ("Сильный дождь", "cloud.heavyrain")
        case 66, 67: return ("Ледяной дождь", "cloud.sleet")
        case 71, 73: return ("Снег", "snowflake")
        case 75: return ("Сильный снег", "cloud.snow")
        case 77: return ("Снежная крупа", "cloud.snow")
        case 80, 81: return ("Ливень", "cloud.heavyrain")
        case 82: return ("Сильный ливень", "cloud.heavyrain")
        case 85, 86: return ("Снегопад", "cloud.snow")
        case 95: return ("Гроза", "cloud.bolt.rain")
        case 96, 99: return ("Гроза с градом", "cloud.bolt.rain")
        default: return ("—", "cloud")
        }
    }

    static func isPrecipitation(_ code: Int) -> Bool { code >= 51 }

    /// Подпись под температурой: «Снег к 17:00», если осадки начнутся в ближайшие 6 ч, иначе — текущее состояние.
    static func summary(_ w: WeatherSnapshot, now: Date = Date()) -> String {
        if !isPrecipitation(w.code), let h = w.hours(after: now).prefix(6).first(where: { isPrecipitation($0.code) }) {
            return "\(describe(h.code).text) к \(EventLogic.hm(h.time))"
        }
        return describe(w.code, isDay: w.isDay).text
    }

    static func degrees(_ t: Double) -> String {
        let v = Int(t.rounded())
        return v < 0 ? "−\(-v)°" : "\(v)°"
    }
}
