import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads audio bytes from googlevideo the way YouTube's own players (and NewPipe) do: POST with
/// a tiny body, the byte range as a `range=` URL parameter and a request counter `rn=`. Used by the
/// player (streaming) and by the downloads of "Guardada en el móvil".
public enum AudioFetcher {
    /// Bytes per request. Small enough to avoid throttling, big enough to keep the count low.
    public static let chunkSize: Int64 = 2 * 1024 * 1024

    public static func request(_ audio: ResolvedAudio, from start: Int64, through end: Int64, number: Int) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(audio.url)&range=\(start)-\(end)&rn=\(number)")!)
        r.httpMethod = "POST"
        r.httpBody = Data([0x78, 0x00])
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding") // byte counts must match the range
        if audio.url.contains("&c=WEB") {
            r.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            r.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        }
        r.setValue(audio.url.contains("&c=VISIONOS") ? InnerTube.visionOSUserAgent : InnerTube.desktopUserAgent,
                   forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Bytes `start...end` of a track's audio. A 403 means the URL went stale: it is re-resolved
    /// once. Returns the data and the (possibly re-resolved) audio to use for the next range.
    public static func range(_ videoId: String, audio: ResolvedAudio?, from start: Int64, through end: Int64,
                             number: Int) async throws -> (Data, ResolvedAudio) {
        var a: ResolvedAudio
        if let audio { a = audio } else { a = try await YouTubeMusic.resolveAudio(videoId) }
        for attempt in 0..<2 {
            let (data, response) = try await InnerTube.send(request(a, from: start, through: end, number: number))
            if response.statusCode == 403 && attempt == 0 {
                await YouTubeMusic.invalidate(videoId)
                a = try await YouTubeMusic.resolveAudio(videoId)
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw YouTubeError.http(response.statusCode) }
            return (data, a)
        }
        throw YouTubeError.http(403)
    }

    /// Downloads a whole song to `file` (through a temp `.part` file of its own, so a half
    /// download is never taken for a song, and two attempts never share one). `progress` gets 0...1. Returns the size.
    @discardableResult
    public static func download(_ videoId: String, to file: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> Int64 {
        var audio = try await YouTubeMusic.resolveAudio(videoId)
        let total = audio.contentLength
        let part = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).part")
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fm.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        var position: Int64 = 0
        var number = 0
        do {
            while position < total {
                try Task.checkCancellation()
                let end = min(total, position + chunkSize) - 1
                let (data, next) = try await range(videoId, audio: audio, from: position, through: end, number: number)
                guard !data.isEmpty else { throw YouTubeError.unexpected("empty range") }
                audio = next
                handle.write(data)
                position += Int64(data.count)
                number += 1
                progress(Double(position) / Double(total))
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: part)
            throw error
        }
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try fm.moveItem(at: part, to: file)
        return total
    }
}
