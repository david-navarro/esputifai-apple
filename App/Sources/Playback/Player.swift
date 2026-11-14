import AVFoundation
import EsputifaiCore
import MediaPlayer
import Observation
import UIKit

/// The music player: the queue, one AVPlayer, the lock screen / Control Center / headphone
/// controls, and background playback (the `audio` background mode in Info.plist).
///
/// Rules carried over from the Android app (owner's decisions):
/// - Tapping the song that is already playing doesn't restart it: only the queue around it changes.
/// - A song that can't play (typically: no internet and not saved on the phone) is skipped, at most
///   once around the queue, so a queue where nothing plays ends in the error instead of looping.
/// - A play counts when a song plays to its end (`onFinished`), not when it starts.
@MainActor
@Observable
final class Player {
    private(set) var queue: [Track] = []
    private(set) var index = -1
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// Seconds.
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 || position > 3 }

    /// The saved file of a song, if it is on the phone (then nothing is streamed).
    @ObservationIgnored var localFile: (String) -> URL? = { _ in nil }
    /// A song played to its end.
    @ObservationIgnored var onFinished: (Track) -> Void = { _ in }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let loader = AudioLoader()
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var playerObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var skippedInARow = 0
    @ObservationIgnored private var artwork: (url: String, art: MPMediaItemArtwork)?
    @ObservationIgnored private var artworkLoading: String?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)

        playerObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in self?.statusChanged(status) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in
                // A call or another app took the audio: AVPlayer paused; resume if iOS says so.
                if type == .ended && options.contains(.shouldResume) { self?.player.play() }
            }
        }
        setUpRemoteCommands()
    }

    // MARK: Queue

    /// Plays `tracks` as the queue from `index`. If that song is already playing, it keeps going.
    func play(_ tracks: [Track], from index: Int) {
        guard tracks.indices.contains(index) else { return }
        if let now = current, now.videoId == tracks[index].videoId, error == nil {
            queue = tracks
            self.index = index
            if !isPlaying { resume() }
            updateNowPlayingInfo()
            return
        }
        queue = tracks
        self.index = index
        skippedInARow = 0
        load(andPlay: true)
    }

    func togglePlayPause() {
        if error != nil {
            load(andPlay: true) // retry after an error
        } else if isPlaying {
            player.pause()
        } else {
            resume()
        }
    }

    func next() {
        guard hasNext else { return }
        index += 1
        load(andPlay: true)
    }

    /// Back to the start of the song, or to the previous one if it just started.
    func previous() {
        if position > 3 || index == 0 {
            seek(to: 0)
        } else if index > 0 {
            index -= 1
            load(andPlay: true)
        }
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
        updateNowPlayingInfo()
    }

    /// Jumps to song `i` of the queue ("Reproduciendo"); the current one is not restarted.
    func playQueueItem(_ i: Int) {
        guard i != index, queue.indices.contains(i) else { return }
        index = i
        load(andPlay: true)
    }

    func removeFromQueue(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        queue.remove(at: i)
        if queue.isEmpty {
            stop()
        } else if i < index {
            index -= 1
        } else if i == index {
            index = min(index, queue.count - 1)
            load(andPlay: isPlaying)
        }
    }

    func moveInQueue(from: Int, to: Int) {
        guard queue.indices.contains(from), queue.indices.contains(to), from != to else { return }
        queue.insert(queue.remove(at: from), at: to)
        if index == from { index = to } else if from < index && to >= index { index -= 1 } else if from > index && to <= index { index += 1 }
    }

    func stop() {
        player.replaceCurrentItem(with: nil)
        itemObservations = []
        for token in itemTokens { NotificationCenter.default.removeObserver(token) }
        itemTokens = []
        queue = []
        index = -1
        error = nil
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Playing an item

    private func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if player.currentItem == nil { load(andPlay: true) } else { player.play() }
    }

    private func load(andPlay play: Bool) {
        guard let track = current else { return stop() }
        error = nil
        position = 0
        duration = Double(track.durationSec)
        let asset: AVURLAsset
        if let file = localFile(track.videoId) {
            asset = AVURLAsset(url: file)
        } else {
            asset = AVURLAsset(url: AudioLoader.url(for: track.videoId))
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        }
        let item = AVPlayerItem(asset: asset)
        watch(item)
        player.replaceCurrentItem(with: item)
        if play {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        updateNowPlayingInfo()
        // Resolve the next song's URL now, so moving on to it doesn't wait for YouTube.
        if hasNext, localFile(queue[index + 1].videoId) == nil {
            let nextId = queue[index + 1].videoId
            Task.detached { _ = try? await YouTubeMusic.resolveAudio(nextId) }
        }
    }

    private func watch(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                let message = Player.describe(item.error)
                Task { @MainActor in self?.itemStatusChanged(item, status, message) }
            },
            item.observe(\.duration, options: [.new]) { [weak self] item, _ in
                let seconds = item.duration.seconds
                Task { @MainActor in
                    guard let self, item === self.player.currentItem, seconds.isFinite, seconds > 0 else { return }
                    self.duration = seconds
                    self.updateNowPlayingInfo()
                }
            },
        ]
        let center = NotificationCenter.default
        for token in itemTokens { center.removeObserver(token) }
        itemTokens = [
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.finished() }
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let message = Player.describe(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                Task { @MainActor in self?.failed(message) }
            },
        ]
    }

    private func itemStatusChanged(_ item: AVPlayerItem, _ status: AVPlayerItem.Status, _ message: String) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay: skippedInARow = 0
        case .failed: failed(message)
        default: break
        }
    }

    /// The song played to its end: count it and go on (or stop at the end of the queue).
    private func finished() {
        if let track = current { onFinished(track) }
        if hasNext {
            index += 1
            load(andPlay: true)
        } else {
            player.pause()
            seek(to: 0)
        }
    }

    private func failed(_ message: String) {
        if hasNext && skippedInARow < queue.count {
            skippedInARow += 1
            index += 1
            load(andPlay: true)
        } else {
            error = message
            player.pause()
        }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        isPlaying = status != .paused
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        updateNowPlayingInfo()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        position = seconds
    }

    /// The deepest error message: AVFoundation wraps the real cause ("HTTP 403", "offline").
    private nonisolated static func describe(_ error: Error?) -> String {
        guard var e = error as NSError? else { return "error desconocido" }
        while let inner = e.userInfo[NSUnderlyingErrorKey] as? NSError { e = inner }
        return e.localizedDescription
    }

    // MARK: Lock screen and Control Center

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayPause() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = e.positionTime
            Task { @MainActor in self?.seek(to: seconds) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBuffering ? 1.0 : 0.0,
        ]
        if let url = track.thumbnailUrl {
            if let a = artwork, a.url == url {
                info[MPMediaItemPropertyArtwork] = a.art
            } else if artworkLoading != url {
                loadArtwork(url)
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = hasNext
    }

    private func loadArtwork(_ url: String) {
        guard let u = URL(string: url) else { return }
        artworkLoading = url
        Task {
            guard let loaded = try? await URLSession.shared.data(from: u), let image = UIImage(data: loaded.0) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artwork = (url, art)
            self.updateNowPlayingInfo()
        }
    }
}
