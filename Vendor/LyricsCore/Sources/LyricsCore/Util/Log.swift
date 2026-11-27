import Foundation
import os

/// Логи пакета. Подсистема `app.amnl.lyrics`. Токены и заголовки авторизации сюда не попадают:
/// писать в лог можно только id треков, имена провайдеров, коды ответов и длительности.
enum Log {
    static let subsystem = "app.amnl.lyrics"
    static let core = Logger(subsystem: subsystem, category: "core")
    static let net = Logger(subsystem: subsystem, category: "network")
    static let parse = Logger(subsystem: subsystem, category: "parse")
    static let cascade = Logger(subsystem: subsystem, category: "cascade")
    static let cache = Logger(subsystem: subsystem, category: "cache")
}
