import Foundation

public enum LyricsError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Для провайдера не хватает данных (нет токена, нет id).
    case notConfigured(String)
    /// Нет авторизации (токен протух или отвергнут).
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case notFound
    case badStatus(Int)
    case badResponse(String)
    case parse(String)
    case decrypt(String)
    case network(String)
    case cancelled

    public var description: String {
        switch self {
        case .notConfigured(let s): return "не настроено: \(s)"
        case .unauthorized: return "нет доступа (401/403)"
        case .rateLimited(let r): return "лимит запросов\(r.map { " (повторить через \(Int($0)) с)" } ?? "")"
        case .notFound: return "не найдено"
        case .badStatus(let c): return "HTTP \(c)"
        case .badResponse(let s): return "неожиданный ответ: \(s)"
        case .parse(let s): return "разбор: \(s)"
        case .decrypt(let s): return "расшифровка: \(s)"
        case .network(let s): return "сеть: \(s)"
        case .cancelled: return "отменено"
        }
    }
}

public extension LyricsError {
    /// Нет подключения к сети (`URLError.notConnectedToInternet` и подобные). Отдельного case нет, чтобы не ломать
    /// исчерпывающие `switch` у потребителей пакета; сравнивать с `LyricsError.offline` или смотреть `LyricsResult.isOffline`.
    static let offline = LyricsError.network("нет сети")

    /// Классификация `URLError`: нет сети / таймаут / прочее (в описание — только код, без URL и заголовков).
    static func from(_ e: URLError) -> LyricsError {
        switch e.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return e.code == .networkConnectionLost ? .network("соединение прервано") : .offline
        case .timedOut: return .network("таймаут запроса")
        case .cannotFindHost, .dnsLookupFailed: return .network("не найден хост (DNS/блокировка?)")
        case .cannotConnectToHost: return .network("хост не отвечает")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .network("TLS (подмена соединения/блокировка?)")
        default: return .network("URLError \(e.code.rawValue)")
        }
    }

    /// Временный сбой: стоит повторить запрос (а «не найдено» по такому ответу не доказано).
    var isTransient: Bool {
        switch self {
        case .rateLimited, .network: return true
        case .badStatus(let c): return c >= 500 || c == 408
        default: return false
        }
    }
}

