import EsputifaiCore
import SwiftUI

/// "Buscar": the search box with suggestions, the Canciones/Álbumes/Artistas/Listas selector and
/// the results; song results are followed by "Relacionadas".
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Canciones, álbumes, artistas, listas…", text: $model.query)
                    .focused($typing)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { model.search(model.query) }
                    .onChange(of: model.query) { _, text in model.typed(text) }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Borrar")
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .padding(.horizontal)

            Picker("Buscar", selection: Binding(get: { model.searchKind }, set: { model.setSearchKind($0) })) {
                ForEach(SearchKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // While typing, suggestions take the place of the results.
            if typing && !model.query.trimmingCharacters(in: .whitespaces).isEmpty && !model.suggestions.isEmpty {
                List(model.suggestions, id: \.self) { s in
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text(s).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                typing = false
                                model.query = s
                                model.search(s)
                            }
                        Button { model.query = s + " " } label: { Image(systemName: "arrow.up.left") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Completar sin buscar")
                    }
                }
                .listStyle(.plain)
            } else {
                // Only where songs can be added with "+" straight from the results.
                if model.searchKind == .songs || model.searchKind == .albums { ActiveListBar() }
                results
            }
        }
        .navigationTitle("Buscar")
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var results: some View {
        switch model.searchState {
        case .idle:
            ContentUnavailableView(idleTitle, systemImage: "magnifyingglass",
                                   description: Text("Escribe arriba y pulsa buscar en el teclado."))
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("No se ha podido buscar", systemImage: "wifi.slash",
                                   description: Text("Comprueba que hay internet y vuelve a intentarlo.\n(\(message))"))
        case .songs(let tracks, let related):
            if tracks.isEmpty { noResults } else {
                List {
                    SongRows(tracks: tracks)
                    RelatedSection(related: related)
                }
                .listStyle(.plain)
            }
        case .albums(let albums):
            if albums.isEmpty { noResults } else {
                List(albums) { a in
                    HStack {
                        NavigationLink(value: Route.album(a)) { CoverRow(thumbnailUrl: a.thumbnailUrl, title: a.title, subtitle: a.artist) }
                        AddToAlbumtecaButton(album: a)
                    }
                }
                .listStyle(.plain)
            }
        case .artists(let artists):
            if artists.isEmpty { noResults } else {
                List(artists) { a in
                    NavigationLink(value: Route.artist(a)) { ArtistRow(name: a.name, thumbnailUrl: a.thumbnailUrl, subtitle: "Artista") }
                }
                .listStyle(.plain)
            }
        case .playlists(let lists):
            if lists.isEmpty { noResults } else {
                List(lists) { p in
                    NavigationLink(value: Route.onlinePlaylist(p)) {
                        CoverRow(thumbnailUrl: p.thumbnailUrl, title: p.title, subtitle: playlistSubtitle(p))
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var idleTitle: String {
        switch model.searchKind {
        case .songs: return "Busca una canción"
        case .albums: return "Busca un álbum"
        case .artists: return "Busca un artista"
        case .playlists: return "Busca una lista"
        }
    }

    private var noResults: some View {
        ContentUnavailableView("No hay resultados", systemImage: "magnifyingglass",
                               description: Text("Prueba a escribirlo de otra forma."))
    }
}

/// Song rows with "+"; tapping one plays the list from there.
struct SongRows: View {
    @Environment(AppModel.self) private var model
    var tracks: [Track]
    /// Plays from a song; by default, `tracks` as the queue.
    var onPlay: (([Track], Int) -> Void)?

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
            TrackRow(track: t, playing: t.videoId == model.player.current?.videoId,
                     dimmed: !model.offline.online && model.offline.localFile(t.videoId) == nil) {
                if let onPlay { onPlay(tracks, i) } else { model.player.play(tracks, from: i) }
            }
        }
    }
}

/// "Relacionadas" with the first result, 10 at a time.
private struct RelatedSection: View {
    @Environment(AppModel.self) private var model
    var related: RelatedState

    var body: some View {
        if !related.tracks.isEmpty || related.loading || related.failed {
            Section {
                SongRows(tracks: related.tracks)
                HStack {
                    Spacer()
                    if related.loading {
                        ProgressView()
                    } else if related.failed {
                        Button("No se han podido cargar · Reintentar") { model.moreRelated() }.buttonStyle(.bordered)
                    } else if related.hasMore {
                        Button("Más relacionadas") { model.moreRelated() }.buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } header: {
                Text("Relacionadas").font(.headline)
            }
        }
    }
}

/// "Lista · Warner Music Spain · 50 canciones" (YouTube often gives no song count).
func playlistSubtitle(_ p: OnlinePlaylist) -> String {
    (["Lista", p.author.isEmpty ? nil : p.author, p.songCount > 0 ? songCount(p.songCount) : nil] as [String?])
        .compactMap { $0 }.joined(separator: " · ")
}
