import Foundation

/// "Relacionadas": songs related to a seed, from its YouTube Music radio (`RDAMVM<id>`), handed out
/// `pageSize` at a time for the "Más relacionadas" button.
///
/// The radio comes in pages of ~50 that can bring other versions of songs already given
/// ("ROSALÍA - DI MI NOMBRE (Official Video)" after "DI MI NOMBRE"). So songs are de-duplicated by
/// videoId and by `titleKey`, songs in `exclude` (the search results on screen) are skipped, and
/// after three pages that add nothing new the radio counts as finished. One call at a time.
public final class RelatedSongs {
    public static let pageSize = 10

    private let seed: String
    private var seen: Set<String>
    private var seenTitles: Set<String>
    private var buffer: [Track] = []
    private var started = false
    private var nextToken: String?
    private var exhausted = false

    public init(seed: String, exclude: [Track] = []) {
        self.seed = seed
        seen = Set(exclude.map(\.videoId) + [seed])
        seenTitles = Set(exclude.map(Self.titleKey))
    }

    /// Whether another `next` call can return something.
    public var hasMore: Bool { !buffer.isEmpty || !exhausted }

    public func next(_ count: Int = RelatedSongs.pageSize) async throws -> [Track] {
        var fruitless = 0
        while buffer.count < count && !exhausted {
            if started && nextToken == nil { exhausted = true; break }
            let page = try await YouTubeMusic.radioPage(seed: seed, continuation: started ? nextToken : nil)
            started = true
            nextToken = page.next
            let fresh = page.tracks.filter { seen.insert($0.videoId).inserted && seenTitles.insert(Self.titleKey($0)).inserted }
            buffer += fresh
            fruitless = fresh.isEmpty ? fruitless + 1 : 0
            if nextToken == nil || fruitless >= 3 { exhausted = true }
        }
        let out = Array(buffer.prefix(count))
        buffer.removeFirst(out.count)
        return out
    }

    private static let videoTag = try! NSRegularExpression(
        pattern: #"[(\[][^)\]]*(video|lyric|letra|audio|visuali[sz]er|en vivo|live)[^)\]]*[)\]]"#, options: .caseInsensitive)

    /// "ROSALÍA - DI MI NOMBRE (Official Video)" and "DI MI NOMBRE" by ROSALÍA give the same key.
    public static func titleKey(_ t: Track) -> String {
        var title = videoTag.stringByReplacingMatches(in: t.title, range: NSRange(t.title.startIndex..., in: t.title), withTemplate: "")
        if let dash = title.range(of: #"^(.*?)\s+-\s+"#, options: .regularExpression) {
            let prefix = title[dash].replacingOccurrences(of: #"\s+-\s+$"#, with: "", options: .regularExpression)
            if !t.artist.isEmpty, prefix.range(of: t.artist, options: .caseInsensitive) != nil {
                title = String(title[dash.upperBound...])
            }
        }
        let words = title.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return words + "|" + t.artist.lowercased()
    }
}
