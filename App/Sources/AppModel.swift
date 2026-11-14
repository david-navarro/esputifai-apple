import EsputifaiCore
import Foundation
import Observation

enum SearchKind: String, CaseIterable, Identifiable {
    case songs, albums, artists, playlists
    var id: String { rawValue }
    var label: String {
        switch self {
        case .songs: return "Canciones"
        case .albums: return "Álbumes"
        case .artists: return "Artistas"
        case .playlists: return "Listas"
        }
    }
}

enum TopKind: String, CaseIterable, Identifiable {
    case songs, artists, albums
    var id: String { rawValue }
    var label: String {
        switch self {
        case .songs: return "Canciones"
        case .artists: return "Artistas"
        case .albums: return "Álbumes"
        }
    }
}

/// The "Relacionadas" section under song results; it loads after the results are shown.
struct RelatedState {
    var tracks: [Track] = []
    var loading = true
    var hasMore = true
    var failed = false
}

enum SearchState {
    case idle
    case loading
    case songs([Track], RelatedState)
    case albums([Album])
    case artists([Artist])
    case playlists([OnlinePlaylist])
    case failed(String)
}

struct TopLists {
    var songs: [Ranked<Track>] = []
    var artists: [Ranked<TopArtist>] = []
    var albums: [Ranked<Album>] = []
}

/// What the artist page shows.
struct ArtistPage {
    var songs: [Track]
    var albums: [Album]
}

enum AppTab: String, CaseIterable, Identifiable {
    case search, playlists, albums, top
    var id: String { rawValue }
    var label: String {
        switch self {
        case .search: return "Buscar"
        case .playlists: return "Mis listas"
        case .albums: return "Albumteca"
        case .top: return "Top"
        }
    }
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .playlists: return "music.note.list"
        case .albums: return "square.stack"
        case .top: return "trophy"
        }
    }
}

/// A screen pushed on top of a tab's main screen.
enum Route: Hashable {
    case playlist(String)
    case album(Album)
    case artist(Artist)
    case onlinePlaylist(OnlinePlaylist)
}

/// A short notice at the bottom, optionally with "Deshacer".
struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
}

/// "Nueva lista" asked from somewhere: maybe with a first song, maybe to become the active list.
struct NewListRequest: Identifiable {
    let id = UUID()
    var firstTrack: Track?
    var makeActive = false
}

/// The whole app's state and actions: the iPhone counterpart of the Android `MusicViewModel`.
/// Screens read it from the environment and call its methods; they keep no state of their own
/// beyond what is purely visual.
@MainActor
@Observable
final class AppModel {
    // MARK: Library

    private(set) var playlists: [Playlist] = []
    private(set) var albums: [LibraryAlbum] = []
    private(set) var history = PlayHistory()
    /// Times each song has been played to its end, by videoId.
    private(set) var plays: [String: Int] = [:]
    private(set) var top = TopLists()

    @ObservationIgnored private let playlistStore: PlaylistStore
    @ObservationIgnored private let albumStore: AlbumStore
    @ObservationIgnored private let playStore: PlayCountStore
    @ObservationIgnored private let prefs = UserDefaults.standard

    let player: Player
    let offline: OfflineAudio

    // MARK: Navigation and panels

    var tab: AppTab = .search
    var paths: [AppTab: [Route]] = [:]
    var showingPlayer = false
    var showingStorage = false
    var addingTrack: Track?
    var newList: NewListRequest?
    private(set) var toast: Toast?
    /// A list someone shared, waiting for "¿Importar?".
    var incoming: SharedPlaylist?

    // MARK: Search

    var query = ""
    private(set) var searchState: SearchState = .idle
    private(set) var suggestions: [String] = []
    // Remembered choices (UserDefaults), changed only through their setters.
    private(set) var searchKind: SearchKind
    private(set) var albumOrder: AlbumOrder
    private(set) var topKind: TopKind
    private(set) var activeListId: String?
    /// Public playlists saved in "Mis listas" this session: YouTube id -> local list id. Only so
    /// the page says "En Mis listas" instead of offering to save it twice; not persisted.
    private(set) var savedOnline: [String: String] = [:]

    @ObservationIgnored private var lastQuery = ""
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var related: RelatedSongs?
    @ObservationIgnored private var relatedTask: Task<Void, Never>?
    @ObservationIgnored private var relatedGeneration = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // Album, artist and playlist pages fetched this session; YouTube is slow and they rarely change.
    @ObservationIgnored private var albumTrackCache: [String: [Track]] = [:]
    @ObservationIgnored private var playlistTrackCache: [String: [Track]] = [:]
    @ObservationIgnored private var artistCache: [String: ArtistPage] = [:]
    @ObservationIgnored private var albumOfCache: [String: Album?] = [:]

    init() {
        player = Player()
        offline = OfflineAudio()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        playlistStore = PlaylistStore(url: support.appendingPathComponent("playlists.json"))
        albumStore = AlbumStore(url: support.appendingPathComponent("albums.json"))
        playStore = PlayCountStore(url: support.appendingPathComponent("plays.json"))
        searchKind = SearchKind(rawValue: prefs.string(forKey: "searchKind") ?? "") ?? .songs
        albumOrder = AlbumOrder(rawValue: prefs.string(forKey: "albumOrder") ?? "") ?? .mostPlayed
        topKind = TopKind(rawValue: prefs.string(forKey: "topKind") ?? "") ?? .songs
        activeListId = prefs.string(forKey: "activeList")

        playlistStore.onChange = { [weak self] in self?.libraryChanged() }
        albumStore.onChange = { [weak self] in self?.libraryChanged() }
        playStore.onChange = { [weak self] in self?.playsChanged() }
        libraryChanged()
        playsChanged()

        let offline = offline
        player.localFile = { offline.localFile($0) }
        player.onFinished = { [weak self] track in
            guard let self else { return }
            self.guarded { try self.playStore.countPlay(track) }
        }
    }

    private func libraryChanged() {
        playlists = playlistStore.playlists
        albums = albumStore.albums
        offline.sync(wanted: wantedOnPhone(playlists, albums))
        recomputeTop()
    }

    private func playsChanged() {
        history = playStore.history
        plays = history.counts
        recomputeTop()
    }

    private func recomputeTop() {
        let known = playlists.flatMap(\.tracks) + albums.flatMap(\.tracks)
        top = TopLists(songs: Top.songs(history, known: known),
                       artists: Top.artists(Top.songs(history, known: known, limit: .max)),
                       albums: Top.albums(history, albumteca: albums))
    }

    /// The app came to the front.
    func becameActive() {
        offline.pump()
    }

    // MARK: Navigation

    func push(_ route: Route) { paths[tab, default: []].append(route) }

    func pop() { _ = paths[tab, default: []].popLast() }

    // MARK: Notices

    func say(_ text: String, undo: (() -> Void)? = nil) {
        toast = Toast(text: text, undo: undo)
        toastTask?.cancel()
        let seconds: UInt64 = undo == nil ? 3 : 6 // undo needs time to read and reach for it
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func performUndo() {
        let undo = toast?.undo
        toast = nil
        undo?()
    }

    /// Runs a store change; a failure to save is shown, never silently lost.
    private func guarded(_ change: () throws -> Void) {
        do { try change() } catch { say("No se ha podido guardar: \(error.localizedDescription)") }
    }

    // MARK: Search

    /// The search box changed: fetch suggestions after a pause in typing.
    func typed(_ text: String) {
        suggestTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { suggestions = []; return }
        suggestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // one request per pause, not per key
            guard !Task.isCancelled else { return }
            let found = (try? await YouTubeMusic.suggestions(q)) ?? []
            guard !Task.isCancelled else { return }
            self?.suggestions = found
        }
    }

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        suggestTask?.cancel()
        suggestions = []
        lastQuery = q
        searchTask?.cancel()
        relatedTask?.cancel()
        relatedTask = nil
        relatedGeneration += 1
        related = nil
        let kind = searchKind
        searchState = .loading
        searchTask = Task { [weak self] in
            let state: SearchState
            do {
                switch kind {
                case .songs: state = .songs(try await YouTubeMusic.search(q), RelatedState())
                case .albums: state = .albums(try await YouTubeMusic.searchAlbums(q))
                case .artists: state = .artists(try await YouTubeMusic.searchArtists(q))
                case .playlists: state = .playlists(try await YouTubeMusic.searchPlaylists(q))
                }
            } catch {
                if Task.isCancelled { return }
                self?.searchState = .failed(error.localizedDescription)
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.searchState = state
            // Results are on screen; now the related songs of the first one, without blocking them.
            if case .songs(let results, _) = state {
                if let first = results.first {
                    self.related = RelatedSongs(seed: first.videoId, exclude: results)
                    self.moreRelated()
                } else {
                    self.updateRelated { $0 = RelatedState(loading: false, hasMore: false) }
                }
            }
        }
    }

    /// Switches between songs, albums, artists and playlists, repeating the last search.
    func setSearchKind(_ kind: SearchKind) {
        guard kind != searchKind else { return }
        searchKind = kind
        prefs.set(kind.rawValue, forKey: "searchKind")
        if lastQuery.isEmpty { searchState = .idle } else { search(lastQuery) }
    }

    /// Next 10 related songs ("Más relacionadas").
    func moreRelated() {
        guard let source = related, relatedTask == nil else { return }
        updateRelated { $0.loading = true; $0.failed = false }
        let generation = relatedGeneration
        relatedTask = Task { [weak self] in
            let result: Result<[Track], Error>
            do { result = .success(try await source.next()) } catch { result = .failure(error) }
            // A new search started meanwhile: this belongs to the old one.
            guard let self, generation == self.relatedGeneration else { return }
            self.relatedTask = nil
            switch result {
            case .success(let page): self.updateRelated { $0.tracks += page; $0.loading = false; $0.hasMore = source.hasMore }
            case .failure: self.updateRelated { $0.loading = false; $0.failed = true }
            }
        }
    }

    private func updateRelated(_ change: (inout RelatedState) -> Void) {
        guard case .songs(let tracks, var r) = searchState else { return }
        change(&r)
        searchState = .songs(tracks, r)
    }

    // MARK: Albums and artists

    /// The album's songs: from the Albumteca if it is there, else from YouTube (cached).
    func albumTracks(_ album: Album) async throws -> [Track] {
        if let inLib = albums.first(where: { $0.id == album.id }) { return inLib.tracks }
        if let cached = albumTrackCache[album.id] { return cached }
        let tracks = try await YouTubeMusic.albumTracks(album)
        albumTrackCache[album.id] = tracks
        return tracks
    }

    func artistPage(_ artist: Artist) async throws -> ArtistPage {
        if let cached = artistCache[artist.channelId] { return cached }
        async let songs = YouTubeMusic.artistSongs(artist)
        async let albums = YouTubeMusic.artistAlbums(artist)
        let page = ArtistPage(songs: try await songs, albums: try await albums)
        artistCache[artist.channelId] = page
        return page
    }

    /// Opens the artist of a Top row: the Top only knows the name, the page needs the channel.
    func openArtist(named name: String) {
        Task {
            let found = (try? await YouTubeMusic.searchArtists(name)) ?? []
            if let a = found.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? found.first {
                push(.artist(a))
            } else {
                say("No se ha encontrado a \(name). ¿Hay internet?")
            }
        }
    }

    /// "Ir al álbum": the Albumteca and albums already played know it at once; otherwise YouTube
    /// is searched (about a second).
    func goToAlbum(of track: Track) {
        Task {
            if let album = await albumOf(track) {
                showingPlayer = false
                push(.album(album))
            } else {
                say("No se ha encontrado el álbum de esta canción (o no hay internet)")
            }
        }
    }

    private func albumOf(_ track: Track) async -> Album? {
        if let a = albums.first(where: { $0.tracks.contains { $0.videoId == track.videoId } }) { return a.album }
        if let a = history.albums.values.first(where: { $0.trackIds.contains(track.videoId) }) { return a.album }
        if let cached = albumOfCache[track.videoId] { return cached }
        say("Buscando el álbum…")
        guard let found = try? await YouTubeMusic.findAlbum(track) else { return nil }
        albumOfCache[track.videoId] = found
        return found
    }

    /// Plays from an album page; the album is remembered so it can appear in the Top.
    func playAlbum(_ album: Album, tracks: [Track], from index: Int) {
        player.play(tracks, from: index)
        Task {
            let all = (try? await albumTracks(album)) ?? tracks
            guarded { try playStore.rememberAlbum(album, tracks: all) }
        }
    }

    func isInAlbumteca(_ id: String) -> Bool { albums.contains { $0.id == id } }

    func addToAlbumteca(_ album: Album) {
        if isInAlbumteca(album.id) { return say("«\(album.title)» ya está en la Albumteca") }
        Task {
            do {
                let tracks = try await albumTracks(album)
                if try albumStore.add(album, tracks: tracks) { say("«\(album.title)» añadido a la Albumteca") }
            } catch {
                say("No se ha podido añadir: \(error.localizedDescription)")
            }
        }
    }

    func removeFromAlbumteca(_ album: LibraryAlbum) {
        guarded { try albumStore.remove(album.id) }
        say("«\(album.album.title)» quitado de la Albumteca")
    }

    /// "Guardar en el móvil" / "Pasar a streaming" for an Albumteca album.
    func setAlbumOffline(_ album: LibraryAlbum, _ offline: Bool) {
        guarded { try albumStore.setOffline(album.id, offline) }
        say(offline ? "Guardando «\(album.album.title)» en el móvil" : "«\(album.album.title)» pasa a streaming")
    }

    func retrySaving(_ tracks: [Track]) { offline.retry(tracks.map(\.videoId)) }

    // MARK: Public playlists

    func onlinePlaylistTracks(_ playlist: OnlinePlaylist) async throws -> [Track] {
        if let cached = playlistTrackCache[playlist.id] { return cached }
        let tracks = try await YouTubeMusic.playlistTracks(playlist)
        playlistTrackCache[playlist.id] = tracks
        return tracks
    }

    /// The local copy's current name, if this public playlist was saved this session.
    func savedName(of playlist: OnlinePlaylist) -> String? {
        savedOnline[playlist.id].flatMap { id in playlists.first { $0.id == id }?.name }
    }

    /// "Guardar en Mis listas": copies the songs into a new local streaming list, which from then
    /// on is the user's own and never follows the original.
    func saveOnlinePlaylist(_ playlist: OnlinePlaylist, tracks: [Track]) {
        let name = freeName(playlist.title)
        guarded {
            let created = try playlistStore.create(name: name, tracks: tracks)
            savedOnline[playlist.id] = created.id
            say("Lista «\(name)» guardada en Mis listas")
        }
    }

    // MARK: Active list

    /// The list "+" adds to with one tap; nil until chosen (or after it is deleted).
    var activeList: Playlist? { playlists.first { $0.id == activeListId } }

    func setActiveList(_ playlist: Playlist?) {
        activeListId = playlist?.id
        prefs.set(activeListId, forKey: "activeList")
    }

    func setAlbumOrder(_ order: AlbumOrder) {
        albumOrder = order
        prefs.set(order.rawValue, forKey: "albumOrder")
    }

    func setTopKind(_ kind: TopKind) {
        topKind = kind
        prefs.set(kind.rawValue, forKey: "topKind")
    }

    /// The one-tap "+": adds the song to the active list (with undo); with no active list yet,
    /// opens the panel to choose one.
    func addToActiveList(_ track: Track) {
        guard let list = activeList else { addingTrack = track; return }
        guarded {
            if try playlistStore.addTrack(list.id, track) {
                say("Añadida a «\(list.name)»") { [weak self] in
                    self?.guarded { _ = try self?.playlistStore.removeTrack(list.id, videoId: track.videoId) }
                }
            } else {
                say("Ya está en «\(list.name)»")
            }
        }
    }

    // MARK: Playlists

    /// Creates a playlist; the first list (or one created from the active-list bar) becomes active.
    func createPlaylist(name: String, offline: Bool, firstTrack: Track? = nil, makeActive: Bool = false) {
        guarded {
            let p = try playlistStore.create(name: name, offline: offline)
            if makeActive || activeList == nil { setActiveList(p) }
            if let t = firstTrack {
                try playlistStore.addTrack(p.id, t)
                say("Añadida a «\(p.name)»")
            } else {
                say("Lista «\(p.name)» creada")
            }
        }
    }

    func renamePlaylist(_ id: String, to name: String) { guarded { try playlistStore.rename(id, to: name) } }

    /// "Guardar en el móvil" / "Pasar a streaming". Downloads and deletions follow by themselves.
    func setPlaylistOffline(_ playlist: Playlist, _ offline: Bool) {
        guarded { try playlistStore.setOffline(playlist.id, offline) }
        say(offline ? "Guardando «\(playlist.name)» en el móvil" : "«\(playlist.name)» pasa a streaming")
    }

    func deletePlaylist(_ playlist: Playlist) {
        guarded { try playlistStore.delete(playlist.id) }
        say("Lista «\(playlist.name)» borrada")
    }

    /// Puts the song in the playlist, or takes it out if it was already there.
    func toggle(_ track: Track, in playlist: Playlist) {
        guarded {
            if playlist.contains(track.videoId) {
                try playlistStore.removeTrack(playlist.id, videoId: track.videoId)
            } else {
                try playlistStore.addTrack(playlist.id, track)
                if activeList == nil { setActiveList(playlist) } // the first choice becomes active
            }
        }
    }

    func removeFromPlaylist(_ playlist: Playlist, _ track: Track) {
        guarded {
            guard let at = try playlistStore.removeTrack(playlist.id, videoId: track.videoId) else { return }
            say("Quitada de «\(playlist.name)»") { [weak self] in
                self?.guarded { _ = try self?.playlistStore.addTrack(playlist.id, track, at: at) }
            }
        }
    }

    func moveInPlaylist(_ id: String, from: Int, to: Int) { guarded { try playlistStore.moveTrack(id, from: from, to: to) } }

    /// Everything saved (lists and albums) back to streaming.
    func allToStreaming() {
        guarded {
            for p in playlists where p.offline { try playlistStore.setOffline(p.id, false) }
            for a in albums where a.offline { try albumStore.setOffline(a.id, false) }
        }
        say("Todo pasa a streaming")
    }

    // MARK: Sharing

    /// The app was opened from a shared-list link.
    func receiveShared(_ link: String) {
        if let shared = PlaylistShare.parse(link), !shared.tracks.isEmpty {
            incoming = shared
        } else {
            say("Ese enlace no contiene una lista válida")
        }
    }

    /// Imports the pending shared list as a new streaming list and shows it.
    func importIncoming() {
        guard let shared = incoming else { return }
        incoming = nil
        let name = freeName(shared.name)
        guarded {
            let created = try playlistStore.create(name: name, tracks: shared.tracks)
            paths[.playlists] = [.playlist(created.id)]
            tab = .playlists
        }
        say("Lista «\(name)» importada")
    }

    /// The text to send for a playlist: a sentence and its link.
    func shareText(_ playlist: Playlist) -> String {
        let link = PlaylistShare.link(name: playlist.name, tracks: playlist.tracks) ?? ""
        return "Te paso mi lista «\(playlist.name)» de Esputifai (\(songCount(playlist.tracks.count))): \(link)"
    }

    /// `wanted`, or "wanted (2)", "(3)"… if a list already has that name.
    private func freeName(_ wanted: String) -> String {
        let taken = Set(playlists.map(\.name))
        var n = 1
        while true {
            let name = n == 1 ? wanted : "\(wanted) (\(n))"
            if !taken.contains(name) { return name }
            n += 1
        }
    }
}
