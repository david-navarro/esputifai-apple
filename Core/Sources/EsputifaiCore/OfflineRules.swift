import Foundation

/*
 * The rules of "Guardada en el móvil", as pure functions (unit-tested):
 *
 * - The choice is per playlist or Albumteca album, never per song (owner's decision).
 * - A song must be on the phone iff it is in at least one saved playlist or saved album.
 * - Anything else that is saved gets deleted. So turning a list or album to streaming, deleting
 *   it, or removing a song from it frees exactly the songs nothing else saved still needs.
 */

/// Where a song is in the download pipeline.
public enum SaveState: Sendable { case queued, downloading, saved, failed }

public struct SavedAudio: Equatable, Sendable {
    public var state: SaveState
    /// 0...100, or -1 while unknown.
    public var percent: Double
    public var bytes: Int64

    public init(state: SaveState, percent: Double = -1, bytes: Int64 = 0) {
        self.state = state
        self.percent = percent
        self.bytes = bytes
    }
}

/// videoIds that must be on the phone.
public func wantedOnPhone(_ playlists: [Playlist], _ albums: [LibraryAlbum] = []) -> Set<String> {
    Set(playlists.filter(\.offline).flatMap(\.tracks).map(\.videoId) + albums.filter(\.offline).flatMap(\.tracks).map(\.videoId))
}

public struct SyncPlan: Equatable, Sendable {
    public var add: Set<String>
    public var remove: Set<String>
}

/// What to download and what to delete. Failed downloads are not re-added here (that would retry
/// in a loop on every playlist edit); the "Reintentar" button does that explicitly.
public func planSync(wanted: Set<String>, existing: [String: SavedAudio]) -> SyncPlan {
    SyncPlan(add: wanted.filter { existing[$0] == nil }, remove: Set(existing.keys.filter { !wanted.contains($0) }))
}

/// Download progress of a set of songs (a playlist or an album), for its status line.
public struct OfflineProgress: Equatable, Sendable {
    public var total: Int
    public var saved: Int
    public var failed: Int
    public var bytes: Int64

    public var pending: Int { total - saved - failed }
    public var complete: Bool { saved == total }
}

public func progressOf(_ tracks: [Track], _ audio: [String: SavedAudio]) -> OfflineProgress {
    let states = tracks.map { audio[$0.videoId] }
    return OfflineProgress(
        total: states.count,
        saved: states.filter { $0?.state == .saved }.count,
        failed: states.filter { $0?.state == .failed }.count,
        bytes: states.reduce(0) { $0 + ($1?.state == .saved ? $1!.bytes : 0) })
}

/// "96 MB", "1,2 GB" (Spanish decimal comma).
public func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_000_000
    if mb < 1 { return "menos de 1 MB" }
    if mb < 1000 { return "\(Int(mb.rounded())) MB" }
    return String(format: "%.1f GB", mb / 1000).replacingOccurrences(of: ".", with: ",")
}

/// "3:07", "1:02:03"; empty for zero (unknown).
public func formatDuration(seconds: Int64) -> String {
    guard seconds > 0 else { return "" }
    let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// "1 canción", "12 canciones".
public func songCount(_ n: Int) -> String { n == 1 ? "1 canción" : "\(n) canciones" }
