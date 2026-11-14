import EsputifaiCore
import SwiftUI

/// "Reproduciendo", opened by tapping the player: a seek bar and the queue (jump to a song, move
/// it, take it out). A sheet, not a full-screen player (owner's choice).
struct NowPlayingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// While the finger is on the bar: where it is. Applied when it lifts.
    @State private var dragging: Double?

    var body: some View {
        let p = model.player
        Group {
            if let track = p.current {
                ScrollViewReader { scroll in
                    List {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Artwork(url: track.thumbnailUrl, size: 64)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).font(.headline).lineLimit(2)
                                    Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contextMenu { SongMenu(track: track) }
                            if let error = p.error {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            }
                            Slider(value: Binding(get: { dragging ?? min(p.position, max(p.duration, 0)) },
                                                  set: { dragging = $0 }),
                                   in: 0...max(p.duration, 1), onEditingChanged: { editing in
                                if !editing, let d = dragging {
                                    p.seek(to: d)
                                    dragging = nil
                                }
                            })
                            .disabled(p.duration <= 0)
                            HStack {
                                Text(clock(dragging ?? p.position))
                                Spacer()
                                Text(clock(p.duration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            HStack(spacing: 40) {
                                Button { p.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                                    .disabled(!p.hasPrevious)
                                Group {
                                    if p.isBuffering {
                                        ProgressView().controlSize(.large)
                                    } else {
                                        Button { p.togglePlayPause() } label: {
                                            Image(systemName: p.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                                        }
                                        .accessibilityLabel(p.isPlaying ? "Pausa" : "Reproducir")
                                    }
                                }
                                .frame(width: 72, height: 72)
                                Button { p.next() } label: { Image(systemName: "forward.fill").font(.title) }
                                    .disabled(!p.hasNext)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)

                        Section {
                            ForEach(Array(p.queue.enumerated()), id: \.offset) { i, t in
                                TrackRow(track: t, playing: i == p.index, onTap: { p.playQueueItem(i) }) {
                                    Menu {
                                        if i > 0 { Button { p.moveInQueue(from: i, to: i - 1) } label: { Label("Subir", systemImage: "arrow.up") } }
                                        if i < p.queue.count - 1 { Button { p.moveInQueue(from: i, to: i + 1) } label: { Label("Bajar", systemImage: "arrow.down") } }
                                        Button(role: .destructive) { p.removeFromQueue(i) } label: { Label("Quitar de la cola", systemImage: "minus.circle") }
                                    } label: {
                                        Image(systemName: "ellipsis").frame(width: 36, height: 44).contentShape(Rectangle())
                                    }
                                }
                                .id(i)
                            }
                        } header: {
                            Text(p.queue.count == 1 ? "Cola · 1 canción" : "Cola · \(p.queue.count) canciones").font(.headline)
                        }
                    }
                    .listStyle(.plain)
                    // Open with the current song in view, so what comes next is visible.
                    .onAppear { if p.index > 0 { scroll.scrollTo(p.index, anchor: .top) } }
                }
            } else {
                Color.clear.onAppear { dismiss() } // the queue was emptied
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Over this sheet, the app's own panels can't open: "Añadir a listas…" opens here.
        .sheet(item: Binding(get: { model.addingTrack }, set: { model.addingTrack = $0 })) { AddToPlaylistSheet(track: $0) }
    }
}

/// Puts one song into playlists. Each list is a row that toggles: tap to add, tap again to take
/// it out; the check shows where the song already is. "Nueva lista" creates a list with the song
/// inside and closes the panel.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var track: Track
    @State private var creating: NewListRequest?

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 12) {
                    Artwork(url: track.thumbnailUrl, size: 40)
                    VStack(alignment: .leading) {
                        Text(track.title).lineLimit(1)
                        Text(track.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button { creating = NewListRequest(firstTrack: track) } label: {
                    Label("Nueva lista", systemImage: "plus.circle.fill").fontWeight(.medium)
                }
                ForEach(model.playlists) { p in
                    let inside = p.contains(track.videoId)
                    Button { model.toggle(track, in: p) } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(playlist: p, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary).lineLimit(1)
                                Text(inside ? "Ya está en esta lista" : (p.offline ? "\(songCount(p.tracks.count)) · En el móvil" : songCount(p.tracks.count)))
                                    .font(.footnote)
                                    .foregroundStyle(inside ? Color.accentColor : .secondary)
                            }
                            Spacer()
                            Image(systemName: inside ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(inside ? Color.accentColor : .secondary)
                        }
                    }
                    .accessibilityValue(inside ? "Está en la lista" : "No está en la lista")
                }
            }
            .navigationTitle("Añadir a una lista")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .sheet(item: $creating) { NewPlaylistSheet(request: $0, onCreated: { dismiss() }) }
        }
        .presentationDetents([.medium, .large])
    }
}
