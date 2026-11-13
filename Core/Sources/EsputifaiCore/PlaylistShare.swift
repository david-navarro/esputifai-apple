import Foundation
#if canImport(Compression)
import Compression
#endif

/// Playlists as links that can be sent by WhatsApp, with no server; the same links as the
/// Android app, so lists travel between both.
///
/// The whole list travels inside the link, after the `#`:
/// `https://david-navarro.github.io/esputifai/l/#<data>`. Browsers never send the part after `#`
/// to the server, so GitHub Pages serves a static page that shows the list and opens the app with
/// `esputifai://import?d=<data>`.
///
/// `<data>` = base64url (no padding) of zlib-wrapped DEFLATE of the JSON
/// `{"v":1,"n":"<name>","t":[["<videoId>","<title>","<artist>",<durationSec>],…]}`. Thumbnails are
/// left out to keep links short; the importer uses YouTube's.
public enum PlaylistShare {
    public static let page = "https://david-navarro.github.io/esputifai/l/"
    static let version = 1

    public static func link(name: String, tracks: [Track]) -> String? {
        encode(name: name, tracks: tracks).map { page + "#" + $0 }
    }

    public static func encode(name: String, tracks: [Track]) -> String? {
        let json: [String: Any] = [
            "v": version,
            "n": name,
            "t": tracks.map { [$0.videoId, $0.title, $0.artist, $0.durationSec] as [Any] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json), let z = Zlib.compress(data) else { return nil }
        return base64url(z)
    }

    /// Reads a shared list from a link: the web page (`…/l/#<data>`), the app link
    /// (`esputifai://import?d=<data>`) or the bare data. Nil if it isn't a valid list.
    public static func parse(_ link: String) -> SharedPlaylist? {
        var data = link
        if let hash = link.firstIndex(of: "#") {
            data = String(link[link.index(after: hash)...])
        } else if let d = link.range(of: "d=") {
            data = String(link[d.upperBound...].prefix { $0 != "&" })
        }
        data = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = unbase64url(data), let json = Zlib.decompress(raw),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let v = root["v"] as? Int, v <= version,
              let name = root["n"] as? String, let t = root["t"] as? [[Any]] else { return nil }
        var tracks: [Track] = []
        for a in t {
            guard a.count >= 3, let id = a[0] as? String, let title = a[1] as? String, let artist = a[2] as? String else { return nil }
            let duration = a.count > 3 ? ((a[3] as? NSNumber)?.int64Value ?? 0) : 0
            tracks.append(Track(videoId: id, title: title, artist: artist, durationSec: duration, thumbnailUrl: thumbnailOf(id)))
        }
        return SharedPlaylist(name: name, tracks: tracks)
    }

    /// YouTube's own picture of a song; for music it is the cover with side bars, cropped in the UI.
    public static func thumbnailOf(_ videoId: String) -> String { "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg" }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// zlib format (RFC 1950), what Java's `Deflater`/`Inflater` and the web page's
/// `DecompressionStream("deflate")` speak. Apple's Compression framework only does the raw
/// DEFLATE inside it (RFC 1951), so the 2-byte header and the Adler-32 trailer are added here.
enum Zlib {
    static func compress(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard let raw = run(data, operation: COMPRESSION_STREAM_ENCODE) else { return nil }
        var out = Data([0x78, 0xDA])
        out.append(raw)
        let a = adler32(data)
        out.append(contentsOf: [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)])
        return out
        #else
        return nil
        #endif
    }

    static func decompress(_ data: Data) -> Data? {
        #if canImport(Compression)
        // Header: CMF (method 8 = deflate) + FLG, multiple of 31; no preset dictionary.
        guard data.count > 6, data[data.startIndex] & 0x0F == 8,
              (UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])) % 31 == 0,
              data[data.startIndex + 1] & 0x20 == 0 else { return nil }
        return run(data.dropFirst(2), operation: COMPRESSION_STREAM_DECODE)
        #else
        return nil
        #endif
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    #if canImport(Compression)
    /// Streams through Compression's raw DEFLATE; refuses output over 2 MB (a link is never that big).
    private static func run(_ input: Data, operation: compression_stream_operation) -> Data? {
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: UnsafePointer(destination), src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        let source = [UInt8](input)
        return source.withUnsafeBufferPointer { src -> Data? in
            stream.src_ptr = src.baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let flags = operation == COMPRESSION_STREAM_ENCODE ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(&stream, flags)
                output.append(destination, count: bufferSize - stream.dst_size)
                if output.count > 2_000_000 { return nil }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if stream.src_size == 0 && stream.dst_size == bufferSize && operation == COMPRESSION_STREAM_DECODE {
                        return nil // truncated input: no progress possible
                    }
                case COMPRESSION_STATUS_END: return output
                default: return nil
                }
            }
        }
    }
    #endif
}
