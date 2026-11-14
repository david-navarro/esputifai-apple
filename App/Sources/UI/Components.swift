import EsputifaiCore
import SwiftUI

/*
 * Shared building blocks. Standard iOS sizes; whoever needs bigger text raises the phone's text
 * size, which the app follows (Dynamic Type).
 */

/// A cover picture with rounded corners and a grey placeholder while it loads.
struct Artwork: View {
    var url: String?
    var size: CGFloat
    var circle = false

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color(.secondarySystemFill)
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
    }
}

/// A playlist's cover: its first song's artwork, or a music icon while it is empty.
struct PlaylistCover: View {
    var playlist: Playlist
    var size: CGFloat

    var body: some View {
        if let first = playlist.tracks.first {
            Artwork(url: first.thumbnailUrl, size: size)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "music.note.list").font(.system(size: size / 2.6)).foregroundStyle(Color.accentColor))
        }
    }
}

/// One song: artwork, title, artist, duration and play count, and actions at the end. A long
/// press opens the song menu ("Ir al álbum", "Añadir a listas…").
struct TrackRow<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    var track: Track
    var playing: Bool
    var dimmed = false
    var onTap: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            // Tap and long press on the song itself; the trailing buttons keep their own gestures.
            HStack(spacing: 12) {
                Artwork(url: track.thumbnailUrl, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .fontWeight(playing ? .bold : .regular)
                        .foregroundStyle(playing ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    Text(track.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatDuration(seconds: track.durationSec)).font(.footnote).foregroundStyle(.secondary)
                    PlayCount(plays: model.plays[track.videoId] ?? 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .contextMenu { SongMenu(track: track) }
            trailing()
        }
        .opacity(dimmed ? 0.4 : 1)
    }
}

extension TrackRow where Trailing == AddToListButton {
    /// The usual song row: "+" at the end.
    init(track: Track, playing: Bool, dimmed: Bool = false, onTap: @escaping () -> Void) {
        self.init(track: track, playing: playing, dimmed: dimmed, onTap: onTap) { AddToListButton(track: track) }
    }
}

/// The long-press menu of a song, anywhere in the app.
struct SongMenu: View {
    @Environment(AppModel.self) private var model
    var track: Track

    var body: some View {
        Button { model.goToAlbum(of: track) } label: { Label("Ir al álbum", systemImage: "square.stack") }
        Button { model.addingTrack = track } label: { Label("Añadir a listas…", systemImage: "text.badge.plus") }
    }
}

/// "▶ 12": how many times the user has played something; nothing if never.
struct PlayCount: View {
    var plays: Int

    var body: some View {
        if plays > 0 {
            Label("\(plays)", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The "+" next to each song. Tap: add to the active list. Long press: choose lists. Shows a
/// check when the song is already in the active list.
struct AddToListButton: View {
    @Environment(AppModel.self) private var model
    var track: Track

    var body: some View {
        let inActive = model.activeList?.contains(track.videoId) == true
        Image(systemName: inActive ? "checkmark.circle.fill" : "plus.circle")
            .font(.title2)
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { model.addToActiveList(track) }
            .onLongPressGesture {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                model.addingTrack = track
            }
            .accessibilityLabel(inActive ? "Ya está en la lista activa" : "Añadir a la lista activa")
            .accessibilityAddTraits(.isButton)
    }
}

/// "Añadir a: [Cocina ▾]" above song lists: shows the active list and changes it in two taps.
struct ActiveListBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
            Text("Añadir a:").foregroundStyle(.secondary)
            Menu {
                ForEach(model.playlists) { p in
                    Button {
                        model.setActiveList(p)
                    } label: {
                        if p.id == model.activeList?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                Button { model.newList = NewListRequest(makeActive: true) } label: { Label("Nueva lista…", systemImage: "plus") }
            } label: {
                HStack(spacing: 2) {
                    Text(model.activeList?.name ?? "Elegir lista").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// "+" for albums: add to the Albumteca; a check once it is there.
struct AddToAlbumtecaButton: View {
    @Environment(AppModel.self) private var model
    var album: Album

    var body: some View {
        let inside = model.isInAlbumteca(album.id)
        Button { model.addToAlbumteca(album) } label: {
            Image(systemName: inside ? "checkmark.square.fill" : "plus.square.on.square")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(inside ? "Ya está en la Albumteca" : "Añadir a la Albumteca")
    }
}

/// A square cover, a title and a subtitle: albums and public playlists.
struct CoverRow: View {
    var thumbnailUrl: String?
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: thumbnailUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One artist: round photo and name.
struct ArtistRow: View {
    var name: String
    var thumbnailUrl: String?
    var subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: thumbnailUrl, size: 48, circle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Reproducir" and "Aleatorio", the main buttons of a list, album or playlist page.
struct PlayButtons: View {
    var onPlay: () -> Void
    var onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button(action: onShuffle) {
                Label("Aleatorio", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }
}

/// An icon and a line of text in a colour: the status lines under play buttons.
struct StatusLine: View {
    var icon: String
    var text: String
    var color: Color

    var body: some View {
        Label(text, systemImage: icon).font(.subheadline).foregroundStyle(color)
    }
}

/// Status of a saved list or album under its play buttons.
struct OfflineStatus: View {
    var progress: OfflineProgress
    var online: Bool
    var onRetry: () -> Void

    var body: some View {
        if progress.complete {
            StatusLine(icon: "checkmark.circle.fill", text: "Todo guardado en el móvil · \(formatBytes(progress.bytes))", color: .accentColor)
        } else if progress.pending > 0 && !online {
            StatusLine(icon: "icloud.slash", text: "Sin conexión · \(progress.saved) de \(progress.total) guardadas. Seguirá sola al volver internet.", color: .secondary)
        } else if progress.pending > 0 {
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(icon: "arrow.down.circle", text: "Guardando en el móvil… \(progress.saved) de \(progress.total)", color: .accentColor)
                ProgressView(value: Double(progress.saved), total: Double(max(progress.total, 1)))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(icon: "exclamationmark.circle",
                           text: progress.failed == 1 ? "1 canción no se pudo guardar" : "\(progress.failed) canciones no se pudieron guardar",
                           color: .red)
                Button("Reintentar", action: onRetry).buttonStyle(.bordered)
            }
        }
    }
}

/// Per-song progress inside a saved list or album; nothing once it is saved (the list says so).
struct SaveIndicator: View {
    var audio: SavedAudio?

    var body: some View {
        switch audio?.state {
        case .saved: EmptyView()
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case .downloading:
            if let a = audio, a.percent >= 0 {
                ProgressView(value: a.percent, total: 100).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        default: ProgressView().controlSize(.small).opacity(0.4)
        }
    }
}

/// Loads something for a pushed page: spinner, then the content or a message with "Reintentar".
struct Loading<Value, Content: View>: View {
    var failureTitle: String
    var load: () async throws -> Value
    @ViewBuilder var content: (Value) -> Content
    @State private var result: Result<Value, Error>?
    @State private var attempt = 0

    var body: some View {
        Group {
            switch result {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure:
                ContentUnavailableView {
                    Label(failureTitle, systemImage: "icloud.slash")
                } description: {
                    Text("Comprueba que hay internet.")
                } actions: {
                    Button("Reintentar") { result = nil; attempt += 1 }.buttonStyle(.bordered)
                }
            case .success(let value):
                content(value)
            }
        }
        .task(id: attempt) {
            do { result = .success(try await load()) } catch { result = .failure(error) }
        }
    }
}

func timesPlayed(_ n: Int) -> String { n == 1 ? "1 reproducción" : "\(n) reproducciones" }

/// "12 canciones · 47:10".
func countAndLength(_ tracks: [Track]) -> String {
    [songCount(tracks.count), formatDuration(seconds: tracks.reduce(0) { $0 + $1.durationSec })]
        .filter { !$0.isEmpty }.joined(separator: " · ")
}
