import Foundation

/// The user's local playlists, in `playlists.json`:
/// `{"version":1,"playlists":[{id,name,createdAtMs,offline,tracks:[Track…]}]}`.
/// Lists keep creation order (stable, so the screen never jumps around).
public final class PlaylistStore {
    private struct File: Codable, Equatable {
        var version = 1
        var playlists: [Playlist] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            playlists = try c.decode([Playlist].self, forKey: .playlists)
        }
    }

    private let file: JSONFile<File>
    private let clock: () -> Millis

    /// Called after every saved change.
    public var onChange: (() -> Void)?

    public var playlists: [Playlist] { file.value.playlists }

    public init(url: URL, clock: @escaping () -> Millis = nowMillis) {
        file = JSONFile(url: url, empty: File())
        self.clock = clock
    }

    /// Creates a playlist, empty or with `tracks` (an imported list; repeated songs kept once).
    @discardableResult
    public func create(name: String, offline: Bool = false, tracks: [Track] = []) throws -> Playlist {
        let p = Playlist(id: UUID().uuidString.lowercased(), name: Self.clean(name),
                         tracks: tracks.uniqued(), createdAtMs: clock(), offline: offline)
        try save { $0.playlists.append(p) }
        return p
    }

    public func rename(_ id: String, to name: String) throws {
        try edit(id) { $0.name = Self.clean(name) }
    }

    /// Switches a playlist between "saved on the phone" and streaming.
    public func setOffline(_ id: String, _ offline: Bool) throws {
        try edit(id) { $0.offline = offline }
    }

    public func delete(_ id: String) throws {
        try save { $0.playlists.removeAll { $0.id == id } }
    }

    /// Inserts `track` (at the end by default); returns false, changing nothing, if it is
    /// already in the playlist.
    @discardableResult
    public func addTrack(_ id: String, _ track: Track, at index: Int? = nil) throws -> Bool {
        var added = false
        try edit(id) { p in
            guard !p.contains(track.videoId) else { return }
            p.tracks.insert(track, at: min(max(index ?? p.tracks.count, 0), p.tracks.count))
            added = true
        }
        return added
    }

    /// Removes the track; returns its former position (for undo), or nil if it wasn't there.
    @discardableResult
    public func removeTrack(_ id: String, videoId: String) throws -> Int? {
        var removedAt: Int?
        try edit(id) { p in
            removedAt = p.tracks.firstIndex { $0.videoId == videoId }
            if let i = removedAt { p.tracks.remove(at: i) }
        }
        return removedAt
    }

    public func moveTrack(_ id: String, from: Int, to: Int) throws {
        try edit(id) { p in
            guard p.tracks.indices.contains(from), p.tracks.indices.contains(to), from != to else { return }
            p.tracks.insert(p.tracks.remove(at: from), at: to)
        }
    }

    private func edit(_ id: String, _ change: (inout Playlist) -> Void) throws {
        try save { f in
            if let i = f.playlists.firstIndex(where: { $0.id == id }) { change(&f.playlists[i]) }
        }
    }

    private func save(_ change: (inout File) -> Void) throws {
        var next = file.value
        change(&next)
        if try file.set(next) { onChange?() }
    }

    private static func clean(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Lista sin nombre" : n
    }
}

/// The Albumteca, in `albums.json`:
/// `{"version":1,"albums":[{id,title,artist,thumbnailUrl,addedAtMs,offline,tracks:[Track…]}]}`.
public final class AlbumStore {
    private struct Entry: Codable, Equatable {
        var id: String
        var title: String
        var artist: String
        var thumbnailUrl: String?
        var addedAtMs: Millis
        var offline: Bool
        var tracks: [Track]

        init(_ a: LibraryAlbum) {
            id = a.album.id
            title = a.album.title
            artist = a.album.artist
            thumbnailUrl = a.album.thumbnailUrl
            addedAtMs = a.addedAtMs
            offline = a.offline
            tracks = a.tracks
        }

        var album: LibraryAlbum {
            LibraryAlbum(album: Album(id: id, title: title, artist: artist, thumbnailUrl: thumbnailUrl),
                         tracks: tracks, addedAtMs: addedAtMs, offline: offline)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(artist, forKey: .artist)
            try c.encode(thumbnailUrl, forKey: .thumbnailUrl)
            try c.encode(addedAtMs, forKey: .addedAtMs)
            try c.encode(offline, forKey: .offline)
            try c.encode(tracks, forKey: .tracks)
        }
    }

    private struct File: Codable, Equatable {
        var version = 1
        var albums: [Entry] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            albums = try c.decode([Entry].self, forKey: .albums)
        }
    }

    private let file: JSONFile<File>
    private let clock: () -> Millis
    public var onChange: (() -> Void)?

    /// Albums in the order they were added; the screen sorts them.
    public private(set) var albums: [LibraryAlbum] = []

    public init(url: URL, clock: @escaping () -> Millis = nowMillis) {
        file = JSONFile(url: url, empty: File())
        self.clock = clock
        albums = file.value.albums.map(\.album)
    }

    /// Adds the album with its tracks; returns false if it was already there.
    @discardableResult
    public func add(_ album: Album, tracks: [Track], offline: Bool = false) throws -> Bool {
        guard !albums.contains(where: { $0.id == album.id }) else { return false }
        try save { $0.albums.append(Entry(LibraryAlbum(album: album, tracks: tracks, addedAtMs: clock(), offline: offline))) }
        return true
    }

    public func remove(_ id: String) throws {
        try save { $0.albums.removeAll { $0.id == id } }
    }

    /// Switches an album between "saved on the phone" and streaming.
    public func setOffline(_ id: String, _ offline: Bool) throws {
        try save { f in
            if let i = f.albums.firstIndex(where: { $0.id == id }) { f.albums[i].offline = offline }
        }
    }

    private func save(_ change: (inout File) -> Void) throws {
        var next = file.value
        change(&next)
        if try file.set(next) {
            albums = next.albums.map(\.album)
            onChange?()
        }
    }
}

/// How many times a song has been played to its end, with what is needed to show it in the Top.
public struct SongPlays: Codable, Equatable, Sendable {
    public var count: Int
    public var lastPlayedMs: Millis
    public var track: Track?

    public init(count: Int, lastPlayedMs: Millis, track: Track?) {
        self.count = count
        self.lastPlayedMs = lastPlayedMs
        self.track = track
    }
}

/// An album the user has played from its page, remembered so the Top can rank it.
public struct PlayedAlbum: Codable, Equatable, Sendable {
    public var album: Album
    public var trackIds: [String]
}

public struct PlayHistory: Codable, Equatable, Sendable {
    public var version = 2
    public var songs: [String: SongPlays] = [:]
    public var albums: [String: PlayedAlbum] = [:]

    public init(songs: [String: SongPlays] = [:], albums: [String: PlayedAlbum] = [:]) {
        self.songs = songs
        self.albums = albums
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songs = try c.decode([String: SongPlays].self, forKey: .songs)
        albums = try c.decodeIfPresent([String: PlayedAlbum].self, forKey: .albums) ?? [:]
    }

    /// Plays by videoId, the shape the Albumteca order and the song rows need.
    public var counts: [String: Int] { songs.mapValues(\.count) }
}

/// Play history in `plays.json`:
/// `{"version":2,"songs":{"<videoId>":{count,lastPlayedMs,track}},"albums":{"<id>":{album,trackIds}}}`
/// (the Android format, so a file could be carried over).
public final class PlayCountStore {
    private let file: JSONFile<PlayHistory>
    private let clock: () -> Millis
    public var onChange: (() -> Void)?

    public var history: PlayHistory { file.value }

    public init(url: URL, clock: @escaping () -> Millis = nowMillis) {
        file = JSONFile(url: url, empty: PlayHistory())
        self.clock = clock
    }

    /// Called by the player each time `track` is played to its end.
    public func countPlay(_ track: Track) throws {
        var h = file.value
        h.songs[track.videoId] = SongPlays(count: (h.songs[track.videoId]?.count ?? 0) + 1, lastPlayedMs: clock(), track: track)
        if try file.set(h) { onChange?() }
    }

    /// Remembers an album played from its page (no-op if already known with the same songs).
    public func rememberAlbum(_ album: Album, tracks: [Track]) throws {
        var h = file.value
        h.albums[album.id] = PlayedAlbum(album: album, trackIds: tracks.map(\.videoId))
        if try file.set(h) { onChange?() }
    }
}

extension Array where Element == Track {
    /// The tracks in order, each videoId once.
    public func uniqued() -> [Track] {
        var seen = Set<String>()
        return filter { seen.insert($0.videoId).inserted }
    }
}
