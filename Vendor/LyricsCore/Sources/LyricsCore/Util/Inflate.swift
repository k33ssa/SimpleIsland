import Foundation
import Compression

enum Inflate {
    /// Распаковывает zlib-поток (RFC 1950): срезает 2-байтовый заголовок и хвост Adler-32,
    /// остальное — raw DEFLATE, который понимает `COMPRESSION_ZLIB`.
    static func zlib(_ data: Data) throws -> Data {
        guard data.count > 6 else { throw LyricsError.decrypt("слишком короткий zlib-поток") }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        guard b0 & 0x0F == 8, (Int(b0) << 8 | Int(b1)) % 31 == 0 else {
            throw LyricsError.decrypt("нет заголовка zlib (ключ или формат не тот)")
        }
        var start = data.startIndex + 2
        if b1 & 0x20 != 0 { start += 4 }  // preset dictionary id
        // Adler-32 в конце не проверяем: Compression отдаёт данные до конца DEFLATE-блока.
        let body = data[start...]
        return try raw(Data(body))
    }

    static func raw(_ data: Data) throws -> Data {
        let result: Data? = try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: base, src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw LyricsError.decrypt("compression_stream_init")
            }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = base
            stream.src_size = data.count
            let chunk = 64 * 1024
            var out = Data()
            var buf = [UInt8](repeating: 0, count: chunk)
            while true {
                var status = COMPRESSION_STATUS_ERROR
                var produced = 0
                buf.withUnsafeMutableBufferPointer { bp in
                    stream.dst_ptr = bp.baseAddress!
                    stream.dst_size = chunk
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    produced = chunk - stream.dst_size
                }
                if produced > 0 { out.append(buf, count: produced) }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { throw LyricsError.decrypt("DEFLATE: ошибка распаковки") }
                if produced == 0 && stream.src_size == 0 { break }
            }
            return out
        }
        guard let r = result, !r.isEmpty else { throw LyricsError.decrypt("DEFLATE: пустой результат") }
        return r
    }
}
