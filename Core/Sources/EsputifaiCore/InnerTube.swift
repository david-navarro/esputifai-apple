import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The HTTP side of YouTube's internal API ("InnerTube"), the one its own apps and web use.
///
/// The request shapes copy NewPipeExtractor v0.27.0 (what the Android app uses), so when YouTube
/// breaks something, NewPipe's fix is the reference: compare with its `ClientsConstants`,
/// `YoutubeParsingHelper.prepareJsonBuilder`, `YoutubeStreamHelper.getVisionOsPlayerResponse` and
/// `YoutubeMusicSearchExtractor`.
///
/// - Catalog (search, playlists, radio, suggestions): the YouTube Music web client (`WEB_REMIX`)
///   on music.youtube.com, which returns clean song metadata.
/// - Audio URLs: the visionOS client, whose stream URLs work as they are (no signature or `n`
///   deciphering; checked 2026-11-13 against real YouTube).
public enum InnerTube {
    static let musicClientVersion = "1.20260804.16.00"
    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:153.0) Gecko/20100101 Firefox/153.0"

    static let visionOSClientVersion = "1.04"
    static let visionOSDeviceModel = "RealityDevice17,1"
    static let visionOSVersion = "26.6.0.23O770"
    static let visionOSUserAgent =
        "com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; es_ES)"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: YouTube Music (WEB_REMIX)

    static func music(_ endpoint: String, _ body: [String: Any], query: String = "") async throws -> JSON {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false\(query)")!)
        request.httpMethod = "POST"
        var b = body
        b["context"] = [
            "client": [
                "clientName": "WEB_REMIX", "clientVersion": musicClientVersion,
                "hl": "es", "gl": "ES", "platform": "DESKTOP", "utcOffsetMinutes": 0,
            ],
            "request": ["internalExperimentFlags": [] as [Any], "useSsl": true],
            "user": ["lockedSafetyMode": false],
        ] as [String: Any]
        request.httpBody = try JSONSerialization.data(withJSONObject: b)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(musicClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        return try await json(request)
    }

    // MARK: visionOS player

    private static var visitorData: (value: String, at: Date)?

    private static func visionOSContext(visitorData: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": "VISIONOS", "clientVersion": visionOSClientVersion, "clientScreen": "WATCH",
            "platform": "MOBILE", "deviceMake": "Apple", "deviceModel": visionOSDeviceModel,
            "osName": "visionOS", "osVersion": visionOSVersion,
            "hl": "es", "gl": "ES", "utcOffsetMinutes": 0,
        ]
        if let v = visitorData { client["visitorData"] = v }
        return [
            "client": client,
            "request": ["internalExperimentFlags": [] as [Any], "useSsl": true],
            "user": ["lockedSafetyMode": false],
        ]
    }

    private static func visionOSRequest(_ url: String, _ body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(visionOSUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        return request
    }

    /// The player response for a video. YouTube wants a fresh-ish `visitorData` with it (NewPipe
    /// fetches one per video; here one is reused for an hour).
    static func player(videoId: String, cpn: String) async throws -> JSON {
        let visitor: String
        if let v = visitorData, v.at.timeIntervalSinceNow > -3600 {
            visitor = v.value
        } else {
            let r = try await json(visionOSRequest("https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false",
                                                   ["context": visionOSContext(visitorData: nil)]))
            guard let v = r.path("responseContext.visitorData").string, !v.isEmpty else { throw YouTubeError.unexpected("visitorData") }
            visitorData = (v, Date())
            visitor = v
        }
        let url = "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=\(randomNonce(12))&id=\(videoId)"
        return try await json(visionOSRequest(url, [
            "context": visionOSContext(visitorData: visitor),
            "videoId": videoId, "cpn": cpn, "contentCheckOk": true, "racyCheckOk": true,
        ]))
    }

    // MARK: Plumbing

    static func json(_ request: URLRequest) async throws -> JSON {
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 429 { throw YouTubeError.rateLimited }
            throw YouTubeError.http(response.statusCode)
        }
        return try JSON(data: data)
    }

    /// `URLSession.data(for:)` through a continuation, so it also works on Linux.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let http = response as? HTTPURLResponse else { cont.resume(throwing: YouTubeError.unexpected("no response")); return }
                    cont.resume(returning: (data ?? Data(), http))
                }
                holder.task = task
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    private final class TaskHolder: @unchecked Sendable {
        var task: URLSessionDataTask?
    }

    /// Random string over YouTube's nonce alphabet (`cpn`, `t`).
    static func randomNonce(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

public enum YouTubeError: Error, LocalizedError {
    case http(Int)
    case rateLimited
    case unplayable(String)
    case noAudio
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "YouTube respondió \(code)"
        case .rateLimited: return "YouTube pide esperar un poco (demasiadas peticiones)"
        case .unplayable(let reason): return reason
        case .noAudio: return "No hay audio reproducible"
        case .unexpected(let what): return "Respuesta inesperada de YouTube (\(what))"
        }
    }
}
