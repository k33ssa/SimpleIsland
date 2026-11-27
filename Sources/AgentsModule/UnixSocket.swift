import Darwin
import Foundation

/// Тонкая обёртка над AF_UNIX-сокетом для хук-клиента и сервера.
enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Подключиться. Нет файла / никто не слушает → nil сразу (у Unix-сокета connect не ждёт сети).
    static func connect(path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setNoSigPipe(fd)
        // Отправка не должна висеть: остров завис — через секунду сдаёмся.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if r != 0 { close(fd); return nil }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Прочитать одну строку до `deadline`. nil — таймаут, обрыв или ошибка.
    static func readLine(_ fd: Int32, deadline: Date, limit: Int = 1 << 20) -> Data? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = buf.firstIndex(of: 0x0A) { return buf.prefix(upTo: nl) }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(min(left * 1000, 1000)).clamped(1, 1000))
            if pr < 0 { if errno == EINTR { continue }; return nil }
            if pr == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buf.append(contentsOf: chunk[0..<n])
                if buf.count > limit { return nil }
            } else if n == 0 {
                return buf.isEmpty ? nil : buf      // закрыли без перевода строки
            } else if errno != EINTR && errno != EAGAIN {
                return nil
            }
        }
    }
}

extension Int32 {
    func clamped(_ lo: Int32, _ hi: Int32) -> Int32 { Swift.min(hi, Swift.max(lo, self)) }
}
