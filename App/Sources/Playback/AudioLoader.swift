import AVFoundation
import EsputifaiCore

/// Serves `ytm://track/<videoId>` to AVPlayer: the iPhone counterpart of the Android app's
/// `YouTubeDataSource`.
///
/// AVPlayer can't open a googlevideo URL directly the way YouTube wants it (POST, `range=`
/// parameter, visionOS user agent), and the URL must be resolved on the phone, lazily, because it
/// is tied to the phone's IP and expires. So the asset gets a custom scheme and this delegate:
/// resolves the videoId when AVPlayer first asks (queued songs cost nothing), answers the content
/// information (AAC in MP4, size, byte ranges supported) and serves each requested range in
/// chunks through `AudioFetcher` (which re-resolves once after a 403).
final class AudioLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "ytm"

    static func url(for videoId: String) -> URL { URL(string: "\(scheme)://track/\(videoId)")! }

    /// AVFoundation calls the delegate on this queue; all bookkeeping happens on it too.
    let queue = DispatchQueue(label: "esputifai.audio-loader")
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, url.scheme == Self.scheme else { return false }
        let videoId = url.lastPathComponent
        let key = ObjectIdentifier(request)
        running[key] = Task { [weak self] in
            await self?.serve(request, videoId: videoId)
            self?.queue.async { self?.running[key] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        running.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    /// The first bytes come in a small piece so playback starts quickly; then full chunks.
    private static let firstChunk: Int64 = 256 * 1024

    private func serve(_ request: AVAssetResourceLoadingRequest, videoId: String) async {
        do {
            var audio = try await YouTubeMusic.resolveAudio(videoId)
            if let info = request.contentInformationRequest {
                let length = audio.contentLength
                queue.async {
                    info.contentType = AVFileType.m4a.rawValue
                    info.contentLength = length
                    info.isByteRangeAccessSupported = true
                }
            }
            if let data = request.dataRequest {
                let total = audio.contentLength
                var position = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
                let end = data.requestsAllDataToEndOfResource
                    ? total - 1
                    : min(total - 1, data.requestedOffset + Int64(data.requestedLength) - 1)
                var number = 0
                while position <= end {
                    try Task.checkCancellation()
                    let size = number == 0 ? Self.firstChunk : AudioFetcher.chunkSize
                    let chunkEnd = min(end, position + size - 1)
                    let (bytes, next) = try await AudioFetcher.range(videoId, audio: audio, from: position, through: chunkEnd, number: number)
                    guard !bytes.isEmpty else { throw YouTubeError.unexpected("empty range") }
                    audio = next
                    number += 1
                    position += Int64(bytes.count)
                    queue.async { data.respond(with: bytes) }
                }
            }
            queue.async { if !request.isCancelled { request.finishLoading() } }
        } catch is CancellationError {
            // AVPlayer no longer wants it (seek, skip): nothing to report.
        } catch {
            queue.async { if !request.isCancelled { request.finishLoading(with: error) } }
        }
    }
}
