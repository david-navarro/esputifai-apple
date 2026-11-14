import EsputifaiCore
import SwiftUI

/// App shell: four tabs (Buscar / Mis listas / Albumteca / Top), the player above them, notices
/// with "Deshacer", and the panels. Each tab keeps its own stack of pushed screens
/// (Buscar → Artista → Álbum…); tapping the current tab again returns to its main screen.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: tabSelection) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack(path: path(tab)) {
                    root(tab)
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.player.current != nil { PlayerBar() }
                }
                .tabItem { Label(tab.label, systemImage: tab.icon) }
                .tag(tab)
            }
        }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, model.player.current == nil ? 60 : 130) }
        .sheet(isPresented: $model.showingPlayer) { NowPlayingSheet() }
        // While "Reproduciendo" is up it presents this panel itself (only one sheet at a time).
        .sheet(item: Binding(get: { model.showingPlayer ? nil : model.addingTrack }, set: { model.addingTrack = $0 })) {
            AddToPlaylistSheet(track: $0)
        }
        .sheet(item: $model.newList) { NewPlaylistSheet(request: $0) }
        .sheet(isPresented: $model.showingStorage) { StorageSheet() }
        .alert(importTitle, isPresented: importing, presenting: model.incoming) { _ in
            Button("Importar") { model.importIncoming() }
            Button("Cancelar", role: .cancel) { model.incoming = nil }
        } message: { shared in
            Text("Te han compartido una lista con \(songCount(shared.tracks.count)). Se añadirá a «Mis listas», en streaming.")
        }
    }

    @ViewBuilder
    private func root(_ tab: AppTab) -> some View {
        switch tab {
        case .search: SearchView()
        case .playlists: PlaylistsView()
        case .albums: AlbumtecaView()
        case .top: TopView()
        }
    }

    /// Selecting the tab that is already selected pops it to its main screen.
    private var tabSelection: Binding<AppTab> {
        Binding(get: { model.tab }, set: { tab in
            if tab == model.tab { model.paths[tab] = [] }
            model.tab = tab
        })
    }

    private func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { model.paths[tab] ?? [] }, set: { model.paths[tab] = $0 })
    }

    private var importTitle: String { "¿Importar «\(model.incoming?.name ?? "")»?" }

    private var importing: Binding<Bool> {
        Binding(get: { model.incoming != nil }, set: { if !$0 { model.incoming = nil } })
    }
}

/// The screen for a pushed route.
struct RouteView: View {
    var route: Route

    var body: some View {
        switch route {
        case .playlist(let id): PlaylistDetailView(id: id)
        case .album(let album): AlbumView(album: album)
        case .artist(let artist): ArtistView(artist: artist)
        case .onlinePlaylist(let playlist): OnlinePlaylistView(playlist: playlist)
        }
    }
}

/// Compact player above the tabs: song, "+" (active list), previous / play-pause / next. Tap opens
/// "Reproduciendo"; a long press opens the song menu.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        if let track = p.current {
            VStack(spacing: 0) {
                ProgressView(value: p.duration > 0 ? min(p.position / p.duration, 1) : 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                HStack(spacing: 4) {
                    HStack(spacing: 10) {
                        Artwork(url: track.thumbnailUrl, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Group {
                                if let error = p.error {
                                    Text(model.offline.online ? "No se puede reproducir: \(error)" : "Sin internet y no está guardada en el móvil")
                                        .foregroundStyle(.red)
                                } else {
                                    Text("\(track.artist) · \(clock(p.position)) / \(clock(p.duration))").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.showingPlayer = true }
                    .contextMenu { SongMenu(track: track) }

                    AddToListButton(track: track)
                    Button { p.previous() } label: { Image(systemName: "backward.fill").frame(width: 36, height: 44) }
                        .disabled(!p.hasPrevious)
                    Group {
                        if p.isBuffering {
                            ProgressView()
                        } else {
                            Button { p.togglePlayPause() } label: {
                                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            }
                            .accessibilityLabel(p.isPlaying ? "Pausa" : "Reproducir")
                        }
                    }
                    .frame(width: 44, height: 44)
                    Button { p.next() } label: { Image(systemName: "forward.fill").frame(width: 36, height: 44) }
                        .disabled(!p.hasNext)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

/// The notice at the bottom, with "Deshacer" when it can be undone.
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack {
                Text(toast.text).font(.subheadline).foregroundStyle(.white)
                Spacer(minLength: 8)
                if toast.undo != nil {
                    Button("Deshacer") { model.performUndo() }.font(.subheadline.bold()).foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .animation(.default, value: toast.id)
        }
    }
}

/// "m:ss" for the player clock; 0:00 instead of nothing.
func clock(_ seconds: Double) -> String {
    let s = formatDuration(seconds: Int64(seconds.isFinite ? seconds : 0))
    return s.isEmpty ? "0:00" : s
}
