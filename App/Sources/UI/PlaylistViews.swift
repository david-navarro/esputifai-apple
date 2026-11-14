import EsputifaiCore
import SwiftUI

/// "Mis listas": every playlist, the button to create one, and what is saved on the phone.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.playlists.isEmpty {
                ContentUnavailableView {
                    Label("Todavía no tienes listas", systemImage: "music.note.list")
                } description: {
                    Text("Crea una lista y luego añade canciones desde Buscar con el botón que hay junto a cada canción.")
                } actions: {
                    Button { model.newList = NewListRequest() } label: { Label("Nueva lista", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    let savedLists = model.playlists.filter(\.offline).count
                    let savedAlbums = model.albums.filter(\.offline).count
                    if savedLists > 0 || savedAlbums > 0 {
                        Button { model.showingStorage = true } label: {
                            StorageLine(lists: savedLists, albums: savedAlbums)
                        }
                    }
                    ForEach(model.playlists) { p in
                        let unavailable = !model.offline.online && !p.offline
                        NavigationLink(value: Route.playlist(p.id)) {
                            HStack(spacing: 12) {
                                PlaylistCover(playlist: p, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(songCount(p.tracks.count))
                                        if p.offline {
                                            Text("·")
                                            Label("En el móvil", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                                        } else if unavailable {
                                            Text("·")
                                            Label("Necesita internet", systemImage: "icloud.slash")
                                        }
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .labelStyle(.titleAndIcon)
                                    .lineLimit(1)
                                }
                            }
                            .opacity(unavailable ? 0.45 : 1)
                        }
                    }
                    Text("Esputifai \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Mis listas")
        .toolbar {
            Button { model.newList = NewListRequest() } label: { Image(systemName: "plus") }
                .accessibilityLabel("Nueva lista")
        }
    }
}

/// The app version (there is no settings screen, so it lives at the foot of "Mis listas").
var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}

/// "En el móvil: 3 listas · 1 álbum · 96 MB". Opens the storage panel.
private struct StorageLine: View {
    @Environment(AppModel.self) private var model
    var lists: Int
    var albums: Int

    var body: some View {
        let bytes = model.offline.audio.values.filter { $0.state == .saved }.reduce(Int64(0)) { $0 + $1.bytes }
        let parts = ([lists > 0 ? (lists == 1 ? "1 lista" : "\(lists) listas") : nil,
                     albums > 0 ? (albums == 1 ? "1 álbum" : "\(albums) álbumes") : nil,
                     formatBytes(bytes)] as [String?]).compactMap { $0 }
        HStack {
            Image(systemName: "iphone")
            Text("En el móvil: " + parts.joined(separator: " · ")).font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.primary)
    }
}

/// One playlist: play / shuffle and its songs, each with a menu to move or remove it (or swipe).
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var id: String

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var confirmingStreaming = false

    var body: some View {
        if let playlist = model.playlists.first(where: { $0.id == id }) {
            content(playlist)
        } else {
            Color.clear.onAppear { dismiss() } // deleted
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let tracks = playlist.tracks
        let audio = model.offline.audio
        let online = model.offline.online
        return Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label("Esta lista está vacía", systemImage: "music.note.list")
                } description: {
                    Text("Busca canciones y pulsa el botón que hay junto a cada una para añadirlas aquí."
                         + (playlist.offline ? " Se guardarán en el móvil solas." : ""))
                } actions: {
                    Button("Ir a Buscar") { model.tab = .search }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(countAndLength(tracks)).font(.subheadline).foregroundStyle(.secondary)
                        PlayButtons(onPlay: { model.player.play(tracks, from: 0) },
                                    onShuffle: { model.player.play(tracks.shuffled(), from: 0) })
                        if playlist.offline {
                            OfflineStatus(progress: progressOf(tracks, audio), online: online) { model.retrySaving(tracks) }
                        } else if !online {
                            StatusLine(icon: "icloud.slash", text: "Sin internet. Esta lista se escucha en streaming y necesita conexión.", color: .red)
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4)

                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track, playing: track.videoId == model.player.current?.videoId,
                                 dimmed: !online && audio[track.videoId]?.state != .saved,
                                 onTap: { model.player.play(tracks, from: index) }) {
                            if playlist.offline { SaveIndicator(audio: audio[track.videoId]) }
                            Menu {
                                if index > 0 {
                                    Button { model.moveInPlaylist(playlist.id, from: index, to: index - 1) } label: { Label("Subir", systemImage: "arrow.up") }
                                }
                                if index < tracks.count - 1 {
                                    Button { model.moveInPlaylist(playlist.id, from: index, to: index + 1) } label: { Label("Bajar", systemImage: "arrow.down") }
                                }
                                Button(role: .destructive) { model.removeFromPlaylist(playlist, track) } label: {
                                    Label("Quitar de la lista", systemImage: "minus.circle")
                                }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 36, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Opciones de la canción")
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.removeFromPlaylist(playlist, track) } label: { Label("Quitar", systemImage: "minus.circle") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                if playlist.offline {
                    Button { confirmingStreaming = true } label: { Label("Pasar a streaming", systemImage: "icloud") }
                } else {
                    Button { model.setPlaylistOffline(playlist, true) } label: { Label("Guardar en el móvil", systemImage: "arrow.down.circle") }
                }
                Button { newName = playlist.name; renaming = true } label: { Label("Cambiar nombre", systemImage: "pencil") }
                if !tracks.isEmpty {
                    ShareLink(item: model.shareText(playlist)) { Label("Compartir", systemImage: "square.and.arrow.up") }
                }
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Borrar lista", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Opciones de la lista")
        }
        .alert("Cambiar nombre", isPresented: $renaming) {
            TextField("Nombre", text: $newName)
            Button("Guardar") { model.renamePlaylist(playlist.id, to: newName) }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancelar", role: .cancel) {}
        }
        .alert("¿Pasar «\(playlist.name)» a streaming?", isPresented: $confirmingStreaming) {
            Button("Pasar a streaming", role: .destructive) { model.setPlaylistOffline(playlist, false) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Las canciones de esta lista dejarán de estar en el móvil y hará falta internet para escucharlas. Las que también estén en otra lista guardada se quedan.")
        }
        .alert("¿Borrar «\(playlist.name)»?", isPresented: $confirmingDelete) {
            Button("Borrar", role: .destructive) { model.deletePlaylist(playlist) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borra la lista con sus \(songCount(tracks.count)). Las canciones siguen en YouTube Music; solo desaparece la lista."
                 + (playlist.offline ? " Lo guardado en el móvil para esta lista también se borra." : ""))
        }
    }
}

/// "Nueva lista": a name plus how it is listened to (streaming or saved on the phone).
struct NewPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var request: NewListRequest
    /// Called after creating (the panel that asked for it closes too).
    var onCreated: () -> Void = {}
    @State private var name = ""
    @State private var offline = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Por ejemplo: Para cocinar", text: $name)
                    .focused($focused)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onSubmit(create)
                Section("¿Cómo se escucha?") {
                    ModeOption(selected: !offline, icon: "icloud", title: "En streaming",
                               detail: "Necesita internet. No ocupa espacio.") { offline = false }
                    ModeOption(selected: offline, icon: "arrow.down.circle", title: "Guardada en el móvil",
                               detail: "Se escucha sin internet. Unos 4 MB por canción.") { offline = true }
                }
            }
            .navigationTitle("Nueva lista")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear", action: create).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.createPlaylist(name: name, offline: offline, firstTrack: request.firstTrack, makeActive: request.makeActive)
        dismiss()
        onCreated()
    }
}

/// One big radio option: the whole row is the touch target.
private struct ModeOption: View {
    var selected: Bool
    var icon: String
    var title: String
    var detail: String
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Behind the "En el móvil" line: what each saved list and album takes, and all to streaming.
struct StorageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        let audio = model.offline.audio
        let total = audio.values.filter { $0.state == .saved }.reduce(Int64(0)) { $0 + $1.bytes }
        NavigationStack {
            List {
                Text("Ocupa \(formatBytes(total)). Quedan \(formatBytes(model.offline.freeBytes())) libres en el móvil.")
                ForEach(model.playlists.filter(\.offline)) { p in
                    HStack(spacing: 12) {
                        PlaylistCover(playlist: p, size: 40)
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(formatBytes(progressOf(p.tracks, audio).bytes)).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.albums.filter(\.offline)) { a in
                    HStack(spacing: 12) {
                        Artwork(url: a.album.thumbnailUrl, size: 40)
                        Text(a.album.title).lineLimit(1)
                        Spacer()
                        Text(formatBytes(progressOf(a.tracks, audio).bytes)).foregroundStyle(.secondary)
                    }
                }
                Text("Una canción que está en dos listas o álbumes ocupa espacio una sola vez.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Pasar todo a streaming", role: .destructive) { confirming = true }
            }
            .navigationTitle("Guardado en el móvil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
            .alert("¿Pasar todo a streaming?", isPresented: $confirming) {
                Button("Pasar todo", role: .destructive) { model.allToStreaming(); dismiss() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borra del móvil todo lo guardado (\(formatBytes(total))). Las listas y álbumes no se borran, pero hará falta internet para escucharlos.")
            }
        }
    }
}
