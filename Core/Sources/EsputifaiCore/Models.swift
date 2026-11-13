import Foundation

/// Milliseconds since 1970, the time unit of every stored timestamp (same as the Android app).
public typealias Millis = Int64

public func nowMillis() -> Millis { Millis(Date().timeIntervalSince1970 * 1000) }

/// A playable song as shown in the UI and queued in the player. Identified everywhere by its
/// YouTube `videoId`. JSON: `{videoId,title,artist,durationSec,thumbnailUrl|null}`.
public struct Track: Codable, Hashable, Identifiable, Sendable {
    public var videoId: String
    public var title: String
    public var artist: String
    public var durationSec: Int64
    public var thumbnailUrl: String?

    public var id: String { videoId }

    public init(videoId: String, title: String, artist: String, durationSec: Int64, thumbnailUrl: String?) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.durationSec = durationSec
        self.thumbnailUrl = thumbnailUrl
    }

    private enum CodingKeys: String, CodingKey { case videoId, title, artist, durationSec, thumbnailUrl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        durationSec = try c.decodeIfPresent(Int64.self, forKey: .durationSec) ?? 0
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(thumbnailUrl, forKey: .thumbnailUrl) // null rather than absent, as on Android
    }
}

/// A YouTube Music album (or single/EP). `id` is its playlist id (`OLAK5uy_…`).
public struct Album: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var thumbnailUrl: String?

    public init(id: String, title: String, artist: String, thumbnailUrl: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.thumbnailUrl = thumbnailUrl
    }
}

/// A public YouTube Music playlist found by search ("Listas"); `id` is its playlist id (`PL…`).
/// Saving it in "Mis listas" copies its songs into a local `Playlist`. `songCount` is -1 when
/// YouTube doesn't say (search results never do).
public struct OnlinePlaylist: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var thumbnailUrl: String?
    public var songCount: Int

    public init(id: String, title: String, author: String, thumbnailUrl: String?, songCount: Int = -1) {
        self.id = id
        self.title = title
        self.author = author
        self.thumbnailUrl = thumbnailUrl
        self.songCount = songCount
    }
}

/// A YouTube Music artist. `channelId` identifies their songs and albums in search results.
public struct Artist: Hashable, Identifiable, Sendable {
    public var channelId: String
    public var name: String
    public var thumbnailUrl: String?

    public var id: String { channelId }

    public init(channelId: String, name: String, thumbnailUrl: String?) {
        self.channelId = channelId
        self.name = name
        self.thumbnailUrl = thumbnailUrl
    }
}

/// A user-made playlist stored on the phone. Tracks are unique by videoId and kept in order.
/// `offline` = "Guardada en el móvil": all its songs are downloaded and kept while it stays on.
public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tracks: [Track]
    public var createdAtMs: Millis
    public var offline: Bool

    public init(id: String, name: String, tracks: [Track], createdAtMs: Millis, offline: Bool = false) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.createdAtMs = createdAtMs
        self.offline = offline
    }

    public func contains(_ videoId: String) -> Bool { tracks.contains { $0.videoId == videoId } }

    private enum CodingKeys: String, CodingKey { case id, name, tracks, createdAtMs, offline }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        createdAtMs = try c.decodeIfPresent(Millis.self, forKey: .createdAtMs) ?? 0
        offline = try c.decodeIfPresent(Bool.self, forKey: .offline) ?? false
    }
}

/// An album in the user's Albumteca. Its tracks are stored when it is added, so it can be saved on
/// the phone and its plays counted without asking YouTube again.
public struct LibraryAlbum: Hashable, Identifiable, Sendable {
    public var album: Album
    public var tracks: [Track]
    public var addedAtMs: Millis
    public var offline: Bool

    public var id: String { album.id }

    public init(album: Album, tracks: [Track], addedAtMs: Millis, offline: Bool = false) {
        self.album = album
        self.tracks = tracks
        self.addedAtMs = addedAtMs
        self.offline = offline
    }
}

/// Albumteca order. "Más escuchados" = plays of the album's songs from anywhere; ties, and
/// never-played albums, go alphabetically.
public enum AlbumOrder: String, CaseIterable, Sendable {
    case mostPlayed, aToZ, zToA

    public var label: String {
        switch self {
        case .mostPlayed: return "Más escuchados"
        case .aToZ: return "A-Z"
        case .zToA: return "Z-A"
        }
    }
}

/// A direct googlevideo URL for a track's audio, valid until `expiresAt`.
public struct ResolvedAudio: Sendable {
    public var videoId: String
    public var url: String
    public var mimeType: String
    public var bitrate: Int
    /// Total size in bytes.
    public var contentLength: Int64
    public var expiresAt: Date
}

/// A playlist received from someone else, before it is imported.
public struct SharedPlaylist: Hashable, Sendable {
    public var name: String
    public var tracks: [Track]

    public init(name: String, tracks: [Track]) {
        self.name = name
        self.tracks = tracks
    }
}
