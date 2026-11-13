import Foundation

/// Spanish ordering: case and accents ignored, so "Ángel" sorts with "A".
public func spanishOrder(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: Locale(identifier: "es_ES")) == .orderedAscending
}

func spanishKey(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
}

/// Albumteca order (owner's rule): "Más escuchados" = plays of the album's songs from anywhere;
/// ties, and never-played albums, go alphabetically.
public func sortAlbums(_ albums: [LibraryAlbum], _ order: AlbumOrder, plays: [String: Int]) -> [LibraryAlbum] {
    switch order {
    case .aToZ: return albums.sorted { spanishOrder($0.album.title, $1.album.title) }
    case .zToA: return albums.sorted { spanishOrder($1.album.title, $0.album.title) }
    case .mostPlayed:
        return albums.sorted { a, b in
            let pa = playsOf(a, plays), pb = playsOf(b, plays)
            return pa != pb ? pa > pb : spanishOrder(a.album.title, b.album.title)
        }
    }
}

public func playsOf(_ album: LibraryAlbum, _ plays: [String: Int]) -> Int {
    album.tracks.reduce(0) { $0 + (plays[$1.videoId] ?? 0) }
}

/// One row of the Top: something and how many times the user has played it.
public struct Ranked<T: Hashable & Sendable>: Hashable, Sendable {
    public var item: T
    public var plays: Int
}

/// An artist as the Top knows them: by name (songs don't carry the channel id).
public struct TopArtist: Hashable, Sendable {
    public var name: String
    public var thumbnailUrl: String?
}

/// The user's most played songs, artists and albums, from the play history. Things never played
/// are left out; lists are capped at `limit` rows.
public enum Top {
    public static let limit = 100

    /// Songs by plays, ties to the most recently played. Songs without stored details are filled
    /// from `known` (the playlists' and Albumteca's songs) or skipped.
    public static func songs(_ history: PlayHistory, known: [Track] = [], limit: Int = Top.limit) -> [Ranked<Track>] {
        var byId: [String: Track] = [:]
        for t in known { byId[t.videoId] = t }
        return history.songs
            .compactMap { id, s -> (Track, Int, Millis)? in
                guard let t = s.track ?? byId[id] else { return nil }
                return (t, s.count, s.lastPlayedMs)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
            .prefix(limit)
            .map { Ranked(item: $0.0, plays: $0.1) }
    }

    /// Artists by the plays of their songs (pass all the songs). Names match ignoring case and
    /// accents, so "Rosalía" and "ROSALÍA" are one artist; the name and picture shown are those
    /// of their most played song.
    public static func artists(_ songs: [Ranked<Track>]) -> [Ranked<TopArtist>] {
        let groups = Dictionary(grouping: songs.filter { !$0.item.artist.trimmingCharacters(in: .whitespaces).isEmpty }) {
            spanishKey($0.item.artist)
        }
        return groups.values
            .map { group -> Ranked<TopArtist> in
                let top = group.max { $0.plays < $1.plays }!
                return Ranked(item: TopArtist(name: top.item.artist.trimmingCharacters(in: .whitespaces), thumbnailUrl: top.item.thumbnailUrl),
                              plays: group.reduce(0) { $0 + $1.plays })
            }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : spanishOrder($0.item.name, $1.item.name) }
            .prefix(limit).map { $0 }
    }

    /// Albums in the Albumteca or played from their page, by the plays of their songs (the same
    /// measure as the Albumteca's "Más escuchados").
    public static func albums(_ history: PlayHistory, albumteca: [LibraryAlbum]) -> [Ranked<Album>] {
        let counts = history.counts
        var candidates: [String: (Album, [String])] = [:]
        for a in history.albums.values { candidates[a.album.id] = (a.album, a.trackIds) }
        for a in albumteca { candidates[a.id] = (a.album, a.tracks.map(\.videoId)) }
        return candidates.values
            .map { album, ids in Ranked(item: album, plays: ids.reduce(0) { $0 + (counts[$1] ?? 0) }) }
            .filter { $0.plays > 0 }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : spanishOrder($0.item.title, $1.item.title) }
            .prefix(limit).map { $0 }
    }
}
