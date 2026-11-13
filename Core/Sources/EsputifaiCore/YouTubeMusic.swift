import Foundation

/// Every call to YouTube Music the app makes: search, albums, public playlists, artists,
/// suggestions, related songs and audio URLs. All `async`; nothing is called on a server of ours.
public enum YouTubeMusic {
    // Search filters of music.youtube.com (the same params NewPipe sends).
    static let songsFilter = "Eg-KAQwIARAAGAAgACgAMABqChAEEAUQAxAKEAk="
    static let albumsFilter = "Eg-KAQwIABAAGAEgACgAMABqChAEEAUQAxAKEAk="
    static let playlistsFilter = "Eg-KAQwIABAAGAAgACgBMABqChAEEAUQAxAKEAk="
    static let artistsFilter = "Eg-KAQwIABAAGAAgASgAMABqChAEEAUQAxAKEAk="

    /// Public playlists can have thousands of songs and each page of 100 is a request.
    public static let playlistMaxSongs = 200

    // MARK: Search

    public static func search(_ query: String) async throws -> [Track] {
        try await searchItems(query, songsFilter, pages: 1).compactMap { songItem($0)?.track }
    }

    public static func searchAlbums(_ query: String) async throws -> [Album] {
        try await searchItems(query, albumsFilter, pages: 1).compactMap { albumItem($0)?.album }
    }

    public static func searchPlaylists(_ query: String) async throws -> [OnlinePlaylist] {
        try await searchItems(query, playlistsFilter, pages: 1).compactMap(playlistItem)
    }

    public static func searchArtists(_ query: String) async throws -> [Artist] {
        try await searchItems(query, artistsFilter, pages: 1).compactMap(artistItem)
    }

    /// Autocomplete for the search box. Terms that are never music are dropped.
    public static func suggestions(_ query: String) async throws -> [String] {
        let r = try await InnerTube.music("music/get_search_suggestions", ["input": query])
        let queries = r["contents"].array
            .flatMap { $0.path("searchSuggestionsSectionRenderer.contents").array }
            .compactMap { $0.path("searchSuggestionRenderer.navigationEndpoint.searchEndpoint.query").string }
        return Array(queries.filter { s in !notMusic.contains { s.lowercased().contains($0) } }.prefix(8))
    }

    static let notMusic = ["reaction", "reaccion", "reacción", "react ", "karaoke", "tutorial", "how to"]

    /// Search results (the `musicResponsiveListItemRenderer`s), `pages` pages of ~20.
    static func searchItems(_ query: String, _ filter: String, pages: Int) async throws -> [JSON] {
        let first = try await InnerTube.music("search", ["query": query, "params": filter])
        let shelf = first.path("contents.tabbedSearchResultsRenderer.tabs").array.first?
            .path("tabRenderer.content.sectionListRenderer.contents").array
            .first { !$0["musicShelfRenderer"].isNull }?["musicShelfRenderer"] ?? JSON(nil)
        var items = shelf["contents"].array
        var next = shelf["continuations"][0].path("nextContinuationData.continuation").string
        var page = 1
        while page < pages, let token = next {
            let more = try await InnerTube.music("search", [:], query: "&ctoken=\(token)&continuation=\(token)&type=next")
            let c = more.path("continuationContents.musicShelfContinuation")
            items += c["contents"].array
            next = c["continuations"][0].path("nextContinuationData.continuation").string
            page += 1
        }
        return items.map { $0["musicResponsiveListItemRenderer"] }.filter {
            !$0.isNull && $0["musicItemRendererDisplayPolicy"].string != "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
        }
    }

    // MARK: Albums, playlists, artists

    /// All songs of an album, in album order, each with the album cover.
    public static func albumTracks(_ album: Album) async throws -> [Track] {
        try await playlistItems(album.id, limit: .max).map {
            var t = $0
            if let cover = album.thumbnailUrl { t.thumbnailUrl = cover }
            return t
        }
    }

    /// Songs of a public playlist, in its order, at most `playlistMaxSongs`.
    public static func playlistTracks(_ playlist: OnlinePlaylist) async throws -> [Track] {
        try await playlistItems(playlist.id, limit: playlistMaxSongs).uniqued()
    }

    /// The songs of any YouTube playlist (albums are playlists too), up to `limit`.
    static func playlistItems(_ playlistId: String, limit: Int) async throws -> [Track] {
        let first = try await InnerTube.music("browse", ["browseId": "VL" + playlistId])
        guard let shelf = first.findFirst("musicPlaylistShelfRenderer") else { throw YouTubeError.unexpected("playlist") }
        var rows = shelf["contents"].array
        var tracks: [Track] = []
        while true {
            tracks += rows.compactMap { songItem($0["musicResponsiveListItemRenderer"])?.track }
            let token = rows.last?.path("continuationItemRenderer.continuationEndpoint.continuationCommand.token").string
            guard tracks.count < limit, let token else { break }
            let more = try await InnerTube.music("browse", ["continuation": token])
            rows = more["onResponseReceivedActions"][0].path("appendContinuationItemsAction.continuationItems").array
            if rows.isEmpty { break }
        }
        return Array(tracks.prefix(limit))
    }

    /// An artist's songs (~25 for a big artist). Like the Android app: a search by the artist's
    /// name keeping only results credited to their channel, which also drops namesakes.
    public static func artistSongs(_ artist: Artist) async throws -> [Track] {
        try await searchItems(artist.name, songsFilter, pages: 2)
            .compactMap(songItem).filter { $0.artistId == artist.channelId }.map(\.track).uniqued()
    }

    public static func artistAlbums(_ artist: Artist) async throws -> [Album] {
        var seen = Set<String>()
        return try await searchItems(artist.name, albumsFilter, pages: 2)
            .compactMap(albumItem).filter { $0.artistId == artist.channelId && seen.insert($0.album.id).inserted }.map(\.album)
    }

    /// The album a song belongs to ("Ir al álbum"): searches albums for "artist title" and opens
    /// the first few; the first one containing the song wins, else (remasters and reissues use
    /// other ids) the first one with a song of the same title. Nil if none matches.
    public static func findAlbum(_ track: Track) async throws -> Album? {
        let candidates = Array(try await searchAlbums("\(track.artist) \(track.title)").prefix(4))
        var lists: [String: [Track]] = [:]
        for a in candidates {
            let list = (try? await albumTracks(a)) ?? []
            lists[a.id] = list
            if list.contains(where: { $0.videoId == track.videoId }) { return a }
        }
        let wanted = looseTitle(track.title)
        return candidates.first { a in lists[a.id, default: []].contains { looseTitle($0.title) == wanted } }
    }

    /// "Let It Be (Remastered 2009)" and "Let It Be - Remastered" compare equal to "let it be".
    static func looseTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"[(\[][^)\]]*[)\]]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: " ", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Radio ("Relacionadas")

    /// One page of the YouTube Music radio of `seed` (`RDAMVM<id>`), and the token for the next.
    static func radioPage(seed: String, continuation: String?) async throws -> (tracks: [Track], next: String?) {
        var body: [String: Any] = ["playlistId": "RDAMVM" + seed, "isAudioOnly": true]
        if let continuation { body["continuation"] = continuation } else { body["videoId"] = seed }
        let r = try await InnerTube.music("next", body)
        let panel = continuation == nil ? r.findFirst("playlistPanelRenderer") : r.path("continuationContents.playlistPanelContinuation")
        guard let panel, !panel.isNull else { throw YouTubeError.unexpected("radio") }
        let tracks = panel["contents"].array.compactMap { item -> Track? in
            let v = item["playlistPanelVideoRenderer"].isNull
                ? item.path("playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer")
                : item["playlistPanelVideoRenderer"]
            guard let id = v["videoId"].string, let title = v["title"].text else { return nil }
            let byline = v["longBylineText"]["runs"].array
            let artist = byline.first { $0.path("navigationEndpoint.browseEndpoint").isNull == false && pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" }?["text"].string
                ?? byline.first?["text"].string ?? ""
            return Track(videoId: id, title: title, artist: artist,
                         durationSec: parseDuration(v["lengthText"].text ?? ""),
                         thumbnailUrl: bestThumbnail(v.path("thumbnail.thumbnails")))
        }
        return (tracks, panel["continuations"][0].path("nextRadioContinuationData.continuation").string)
    }

    // MARK: Audio

    private static let audioCache = AudioURLCache()

    /// Direct audio URL for a track, cached until 10 minutes before it expires. The highest
    /// bitrate original-language AAC stream (the iPhone's player can't play YouTube's Opus/WebM):
    /// in practice itag 140, ~130 kbps.
    public static func resolveAudio(_ videoId: String) async throws -> ResolvedAudio {
        if let cached = await audioCache.get(videoId) { return cached }
        let cpn = InnerTube.randomNonce(16)
        let r = try await InnerTube.player(videoId: videoId, cpn: cpn)
        let status = r.path("playabilityStatus.status").string ?? "OK"
        guard status == "OK" else {
            throw YouTubeError.unplayable(r.path("playabilityStatus.reason").string ?? status)
        }
        let candidates = r.path("streamingData.adaptiveFormats").array.filter { f in
            (f["mimeType"].string ?? "").hasPrefix("audio/mp4") && f["url"].string != nil
                && (f["audioTrack"].isNull || f.path("audioTrack.audioIsDefault").raw as? Bool == true)
        }
        guard let best = candidates.max(by: { ($0["bitrate"].int ?? 0) < ($1["bitrate"].int ?? 0) }),
              let base = best["url"].string else { throw YouTubeError.noAudio }
        let url = base + "&cpn=" + cpn
        let length = Int64(best["contentLength"].string ?? "") ?? Int64(queryParam(url, "clen") ?? "") ?? -1
        guard length > 0 else { throw YouTubeError.unexpected("contentLength") }
        let expire = TimeInterval(queryParam(url, "expire") ?? "").map { Date(timeIntervalSince1970: $0 - 600) }
            ?? Date().addingTimeInterval(3600)
        let resolved = ResolvedAudio(videoId: videoId, url: url, mimeType: best["mimeType"].string ?? "audio/mp4",
                                     bitrate: best["bitrate"].int ?? 0, contentLength: length, expiresAt: expire)
        await audioCache.put(resolved)
        return resolved
    }

    /// Forget a cached URL (googlevideo answered 403: it went stale).
    public static func invalidate(_ videoId: String) async {
        await audioCache.remove(videoId)
    }

    // MARK: Parsing

    struct SongItem { var track: Track; var artistId: String? }
    struct AlbumItem { var album: Album; var artistId: String? }

    /// A song row (search results, album and playlist pages).
    static func songItem(_ r: JSON) -> SongItem? {
        let flex0 = r["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"]
        guard let id = r.path("playlistItemData.videoId").string
                ?? flex0["runs"][0].path("navigationEndpoint.watchEndpoint.videoId").string,
              let title = flex0.text else { return nil }
        let runs = r["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array
        let artistRun = runs.first { pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" }
        let artist = artistRun?["text"].string ?? runs.first?["text"].string ?? ""
        let durationText = r["fixedColumns"][0].path("musicResponsiveListItemFixedColumnRenderer.text").text
            ?? runs.last { isDuration($0["text"].string ?? "") }?["text"].string ?? ""
        return SongItem(
            track: Track(videoId: id, title: title, artist: artist, durationSec: parseDuration(durationText),
                         thumbnailUrl: bestThumbnail(r.path("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails"))),
            artistId: artistRun?.path("navigationEndpoint.browseEndpoint.browseId").string)
    }

    static func albumItem(_ r: JSON) -> AlbumItem? {
        guard let id = r.path("overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchPlaylistEndpoint.playlistId").string,
              let title = r["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"].text else { return nil }
        let runs = r["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array
        let artistRun = runs.first { pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" }
        // Without a link the artist is the text after the type ("Álbum • Varios artistas • 2019").
        let plain = runs.compactMap { $0["text"].string }.filter { $0 != " • " }
        let artist = artistRun?["text"].string ?? (plain.count > 1 ? plain[1] : "")
        return AlbumItem(
            album: Album(id: id, title: title, artist: artist,
                         thumbnailUrl: bestThumbnail(r.path("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails"))),
            artistId: artistRun?.path("navigationEndpoint.browseEndpoint.browseId").string)
    }

    static func playlistItem(_ r: JSON) -> OnlinePlaylist? {
        let browseId = r.path("navigationEndpoint.browseEndpoint.browseId").string
        guard let id = browseId.map({ $0.hasPrefix("VL") ? String($0.dropFirst(2)) : $0 })
                ?? r.path("overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchPlaylistEndpoint.playlistId").string,
              let title = r["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"].text else { return nil }
        let runs = r["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array
        let author = runs.first { !$0.path("navigationEndpoint.browseEndpoint").isNull }?["text"].string
            ?? runs.first?["text"].string ?? ""
        return OnlinePlaylist(id: id, title: title, author: author,
                              thumbnailUrl: bestThumbnail(r.path("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails")))
    }

    static func artistItem(_ r: JSON) -> Artist? {
        guard let id = r.path("navigationEndpoint.browseEndpoint.browseId").string, id.hasPrefix("UC"),
              let name = r["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"].text else { return nil }
        return Artist(channelId: id, name: name,
                      thumbnailUrl: bestThumbnail(r.path("thumbnail.musicThumbnailRenderer.thumbnail.thumbnails")))
    }

    static func pageType(_ run: JSON) -> String? {
        run.path("navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string
    }

    static func isDuration(_ s: String) -> Bool {
        s.range(of: #"^\d+(:\d{2}){1,2}$"#, options: .regularExpression) != nil
    }

    /// "3:07" → 187, "1:02:03" → 3723; 0 if it isn't a duration.
    static func parseDuration(_ s: String) -> Int64 {
        guard isDuration(s) else { return 0 }
        return s.split(separator: ":").reduce(Int64(0)) { $0 * 60 + (Int64($1) ?? 0) }
    }

    /// The largest thumbnail, upscaled: YouTube Music gives 60-120 px pictures whose
    /// googleusercontent URLs encode the size (`=w60-h60-…` covers, `=s88-…` avatars).
    static func bestThumbnail(_ thumbnails: JSON) -> String? {
        guard let url = thumbnails.array.last?["url"].string else { return nil }
        guard url.contains("googleusercontent.com") || url.contains("ggpht.com") else { return url }
        if url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) != nil {
            return url.replacingOccurrences(of: #"=w\d+-h\d+.*$"#, with: "=w544-h544-l90-rj", options: .regularExpression)
        }
        if url.range(of: #"=s\d+"#, options: .regularExpression) != nil {
            return url.replacingOccurrences(of: #"=s\d+.*$"#, with: "=s544", options: .regularExpression)
        }
        return url
    }

    static func queryParam(_ url: String, _ name: String) -> String? {
        guard let r = url.range(of: "[?&]\(name)=([^&]+)", options: .regularExpression) else { return nil }
        return String(url[r].split(separator: "=", maxSplits: 1)[1])
    }
}

/// Resolved audio URLs, by videoId, until they are about to expire.
actor AudioURLCache {
    private var entries: [String: ResolvedAudio] = [:]

    func get(_ id: String) -> ResolvedAudio? {
        guard let e = entries[id], e.expiresAt > Date() else { return nil }
        return e
    }

    func put(_ a: ResolvedAudio) { entries[a.videoId] = a }
    func remove(_ id: String) { entries[id] = nil }
}

extension JSON {
    /// The first value under `key` anywhere in the document (depth-first). YouTube moves shelves
    /// between wrappers from time to time; looking them up by name survives that.
    func findFirst(_ key: String) -> JSON? {
        if let dict = raw as? [String: Any] {
            if let v = dict[key] { return JSON(v) }
            for v in dict.values {
                if let found = JSON(v).findFirst(key) { return found }
            }
        } else if let array = raw as? [Any] {
            for v in array {
                if let found = JSON(v).findFirst(key) { return found }
            }
        }
        return nil
    }
}
