import EsputifaiCore
import SwiftUI

/// The Albumteca tab: saved albums, sortable by plays or alphabetically.
struct AlbumtecaView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.albums.isEmpty {
                ContentUnavailableView {
                    Label("Todavía no hay álbumes", systemImage: "square.stack")
                } description: {
                    Text("En Buscar, elige «Álbumes» (o abre un artista) y pulsa el botón junto a un álbum para añadirlo aquí.")
                } actions: {
                    Button("Ir a Buscar") {
                        model.setSearchKind(.albums)
                        model.tab = .search
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Picker("Orden", selection: Binding(get: { model.albumOrder }, set: { model.setAlbumOrder($0) })) {
                        ForEach(AlbumOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    ForEach(sortAlbums(model.albums, model.albumOrder, plays: model.plays)) { a in
                        let unavailable = !model.offline.online && !a.offline
                        NavigationLink(value: Route.album(a.album)) {
                            CoverRow(thumbnailUrl: a.album.thumbnailUrl, title: a.album.title, subtitle: ([
                                a.album.artist.isEmpty ? nil : a.album.artist,
                                songCount(a.tracks.count),
                                a.offline ? "En el móvil" : (unavailable ? "Necesita internet" : nil),
                            ] as [String?]).compactMap { $0 }.joined(separator: " · "))
                            .opacity(unavailable ? 0.45 : 1)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Albumteca")
    }
}

/// One album, from search, an artist page, the Top or the Albumteca. Its songs come from the
/// Albumteca when it is there, otherwise from YouTube. Albumteca options are in the "⋯" menu.
struct AlbumView: View {
    @Environment(AppModel.self) private var model
    var album: Album
    @State private var confirmingStreaming = false
    @State private var confirmingRemove = false

    var body: some View {
        let inLib = model.albums.first { $0.id == album.id }
        let shown = inLib?.album ?? album
        Group {
            if let inLib {
                list(shown, inLib.tracks, inLib) // no network needed: the tracks are stored
            } else {
                Loading(failureTitle: "No se ha podido abrir el álbum", load: { try await model.albumTracks(album) }) { tracks in
                    list(shown, tracks, nil)
                }
            }
        }
        .navigationTitle(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let inLib {
                Menu {
                    if inLib.offline {
                        Button { confirmingStreaming = true } label: { Label("Pasar a streaming", systemImage: "icloud") }
                    } else {
                        Button { model.setAlbumOffline(inLib, true) } label: { Label("Guardar en el móvil", systemImage: "arrow.down.circle") }
                    }
                    Button(role: .destructive) { confirmingRemove = true } label: { Label("Quitar de la Albumteca", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Opciones del álbum")
            }
        }
        .alert("¿Pasar «\(album.title)» a streaming?", isPresented: $confirmingStreaming) {
            Button("Pasar a streaming", role: .destructive) { if let inLib { model.setAlbumOffline(inLib, false) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Las canciones de este álbum dejarán de estar en el móvil y hará falta internet para escucharlas. Las que también estén en una lista u otro álbum guardado se quedan.")
        }
        .alert("¿Quitar «\(album.title)» de la Albumteca?", isPresented: $confirmingRemove) {
            Button("Quitar", role: .destructive) { if let inLib { model.removeFromAlbumteca(inLib) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El álbum sigue en YouTube Music y puedes volver a añadirlo."
                 + (inLib?.offline == true ? " Lo guardado en el móvil para este álbum se borra." : ""))
        }
    }

    private func list(_ album: Album, _ tracks: [Track], _ inLib: LibraryAlbum?) -> some View {
        let audio = model.offline.audio
        let online = model.offline.online
        // Playing from here also remembers the album for the Top.
        let play: ([Track], Int) -> Void = { list, i in model.playAlbum(album, tracks: list, from: i) }
        return List {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Artwork(url: album.thumbnailUrl, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title).font(.headline).lineLimit(2)
                        Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                        Text(countAndLength(tracks)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                PlayButtons(onPlay: { play(tracks, 0) }, onShuffle: { play(tracks.shuffled(), 0) })
                if let inLib, inLib.offline {
                    OfflineStatus(progress: progressOf(inLib.tracks, audio), online: online) { model.retrySaving(inLib.tracks) }
                } else if inLib != nil {
                    StatusLine(icon: "checkmark.square.fill", text: "En tu Albumteca", color: .accentColor)
                } else {
                    Button { model.addToAlbumteca(album) } label: {
                        Label("Añadir a la Albumteca", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
            ActiveListBar().listRowInsets(EdgeInsets())
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t, playing: t.videoId == model.player.current?.videoId,
                         dimmed: !online && audio[t.videoId]?.state != .saved,
                         onTap: { play(tracks, i) }) {
                    if inLib?.offline == true { SaveIndicator(audio: audio[t.videoId]) }
                    AddToListButton(track: t)
                }
            }
        }
        .listStyle(.plain)
    }
}

/// An artist on one page (owner's choice): 5 popular songs on top ("Ver todas" shows the rest),
/// albums below. Songs go to playlists with "+", albums to the Albumteca.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    var artist: Artist
    @State private var allSongs = false
    private static let topSongs = 5

    var body: some View {
        Loading(failureTitle: "No se ha podido abrir el artista", load: { try await model.artistPage(artist) }) { page in
            List {
                HStack(spacing: 16) {
                    Artwork(url: artist.thumbnailUrl, size: 72, circle: true)
                    Text(artist.name).font(.title2.bold())
                }
                ActiveListBar().listRowInsets(EdgeInsets())
                Section {
                    if page.songs.isEmpty { Text("No se han encontrado canciones.").foregroundStyle(.secondary) }
                    // Playing a song queues the songs on screen, from that one on.
                    SongRows(tracks: allSongs ? page.songs : Array(page.songs.prefix(Self.topSongs)))
                    if page.songs.count > Self.topSongs {
                        Button(allSongs ? "Ver menos" : "Ver todas (\(page.songs.count))") { allSongs.toggle() }
                    }
                } header: { Text("Canciones").font(.headline) }
                Section {
                    if page.albums.isEmpty { Text("No se han encontrado álbumes.").foregroundStyle(.secondary) }
                    ForEach(page.albums) { a in
                        HStack {
                            NavigationLink(value: Route.album(a)) { CoverRow(thumbnailUrl: a.thumbnailUrl, title: a.title, subtitle: a.artist) }
                            AddToAlbumtecaButton(album: a)
                        }
                    }
                } header: { Text("Álbumes").font(.headline) }
            }
            .listStyle(.plain)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A public YouTube Music playlist found in Buscar → "Listas". It is only browsed and played from
/// YouTube; "Guardar en Mis listas" copies its songs into a new local streaming list.
struct OnlinePlaylistView: View {
    @Environment(AppModel.self) private var model
    var playlist: OnlinePlaylist

    var body: some View {
        Loading(failureTitle: "No se ha podido abrir la lista", load: { try await model.onlinePlaylistTracks(playlist) }) { tracks in
            List {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        Artwork(url: playlist.thumbnailUrl ?? tracks.first?.thumbnailUrl, size: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.title).font(.headline).lineLimit(2)
                            if !playlist.author.isEmpty { Text(playlist.author).font(.subheadline).foregroundStyle(.secondary) }
                            Text(countAndLength(tracks)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if tracks.count >= YouTubeMusic.playlistMaxSongs {
                        Text("Lista larga: se muestran las primeras \(YouTubeMusic.playlistMaxSongs) canciones.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !tracks.isEmpty {
                        PlayButtons(onPlay: { model.player.play(tracks, from: 0) },
                                    onShuffle: { model.player.play(tracks.shuffled(), from: 0) })
                        if let saved = model.savedName(of: playlist) {
                            StatusLine(icon: "checkmark.circle.fill", text: "En Mis listas como «\(saved)»", color: .accentColor)
                        } else {
                            Button { model.saveOnlinePlaylist(playlist, tracks: tracks) } label: {
                                Label("Guardar en Mis listas", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
                ActiveListBar().listRowInsets(EdgeInsets())
                if tracks.isEmpty {
                    Text("Esta lista no tiene canciones que se puedan reproducir").foregroundStyle(.secondary)
                }
                SongRows(tracks: tracks)
            }
            .listStyle(.plain)
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "Top": what the user listens to most, as songs, artists or albums.
struct TopView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let top = model.top
        let kind = model.topKind
        VStack(spacing: 0) {
            Picker("Top", selection: Binding(get: { model.topKind }, set: { model.setTopKind($0) })) {
                ForEach(TopKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 4)
            if kind == .songs { ActiveListBar() }
            let empty = kind == .songs ? top.songs.isEmpty : kind == .artists ? top.artists.isEmpty : top.albums.isEmpty
            if empty {
                ContentUnavailableView("Aún no hay nada", systemImage: "trophy", description: Text(
                    kind == .albums
                        ? "Aquí salen los álbumes de tu Albumteca y los que escuches desde su página."
                        : "Lo que escuches aparecerá aquí, de más a menos escuchado."))
            } else {
                List {
                    switch kind {
                    case .songs:
                        SongRows(tracks: top.songs.map(\.item))
                    case .artists:
                        ForEach(top.artists, id: \.item.name) { r in
                            Button { model.openArtist(named: r.item.name) } label: {
                                HStack {
                                    ArtistRow(name: r.item.name, thumbnailUrl: r.item.thumbnailUrl, subtitle: timesPlayed(r.plays))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    case .albums:
                        ForEach(top.albums, id: \.item.id) { r in
                            NavigationLink(value: Route.album(r.item)) {
                                CoverRow(thumbnailUrl: r.item.thumbnailUrl, title: r.item.title, subtitle: "\(r.item.artist) · \(timesPlayed(r.plays))")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Lo más escuchado")
        .navigationBarTitleDisplayMode(.inline)
    }
}
