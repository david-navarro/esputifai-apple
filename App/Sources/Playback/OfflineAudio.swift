import EsputifaiCore
import Foundation
import Network
import Observation
import UIKit

/// Songs saved on the phone ("Guardada en el móvil"): one `<videoId>.m4a` per song in
/// Application Support/offline-audio (excluded from iCloud backup), downloaded two at a time with
/// `AudioFetcher` over any network (owner's choice: Wi-Fi or mobile data).
///
/// What must be here comes from `sync(wanted:)` (see OfflineRules): missing songs are queued and
/// songs nothing saved needs are deleted. Failed downloads wait for "Reintentar". Downloads run
/// while the app is open or playing music; iOS suspends it otherwise, and the queue picks up again
/// when the app comes back (a half download is never kept).
@MainActor
@Observable
final class OfflineAudio {
    /// Download state of saved and wanted songs, by videoId.
    private(set) var audio: [String: SavedAudio] = [:]
    /// Whether the phone has internet right now.
    private(set) var online = true

    @ObservationIgnored let folder: URL
    /// Downloads in progress, each with its own attempt id (a song can be removed and re-added
    /// while its old download is still winding down).
    @ObservationIgnored private var running: [String: (attempt: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static let parallel = 2

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("offline-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var f = folder
        try? f.setResourceValues(values)

        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files {
            if file.pathExtension == "m4a" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                audio[file.deletingPathExtension().lastPathComponent] = SavedAudio(state: .saved, percent: 100, bytes: Int64(size))
            } else {
                try? FileManager.default.removeItem(at: file) // leftovers of an interrupted download
            }
        }

        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "esputifai.network"))
    }

    func file(_ videoId: String) -> URL { folder.appendingPathComponent("\(videoId).m4a") }

    /// The saved file of a song, if it is complete on the phone.
    func localFile(_ videoId: String) -> URL? { audio[videoId]?.state == .saved ? file(videoId) : nil }

    /// Makes the phone hold exactly `wanted`.
    func sync(wanted: Set<String>) {
        let plan = planSync(wanted: wanted, existing: audio)
        for id in plan.remove {
            running.removeValue(forKey: id)?.task.cancel()
            try? FileManager.default.removeItem(at: file(id))
            audio[id] = nil
        }
        for id in plan.add { audio[id] = SavedAudio(state: .queued) }
        pump()
    }

    /// "Reintentar": queue again the songs that failed.
    func retry(_ videoIds: [String]) {
        for id in videoIds where audio[id]?.state == .failed { audio[id] = SavedAudio(state: .queued) }
        pump()
    }

    /// Free space on the phone, in bytes.
    func freeBytes() -> Int64 {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Starts queued downloads while there is room and network. Called on every change, when the
    /// network returns and when the app comes to the front.
    func pump() {
        guard online else { return }
        let queued = audio.filter { $0.value.state == .queued }.keys.sorted()
        for id in queued where running.count < Self.parallel {
            start(id)
        }
        updateBackgroundTask()
    }

    private func start(_ id: String) {
        audio[id] = SavedAudio(state: .downloading, percent: 0)
        let target = file(id)
        let attempt = UUID()
        let task = Task { [weak self] in
            do {
                let size = try await AudioFetcher.download(id, to: target) { fraction in
                    Task { @MainActor in self?.progress(id, attempt, fraction) }
                }
                self?.done(id, attempt, .success(size))
            } catch {
                self?.done(id, attempt, .failure(error))
            }
        }
        running[id] = (attempt, task)
    }

    private func progress(_ id: String, _ attempt: UUID, _ fraction: Double) {
        guard running[id]?.attempt == attempt, audio[id]?.state == .downloading else { return }
        audio[id]?.percent = fraction * 100
    }

    private func done(_ id: String, _ attempt: UUID, _ result: Result<Int64, Error>) {
        guard running[id]?.attempt == attempt else {
            // Removed meanwhile: don't keep a file that finished just after the removal.
            if audio[id] == nil, case .success = result { try? FileManager.default.removeItem(at: file(id)) }
            return
        }
        running[id] = nil
        switch result {
        case .success(let size):
            audio[id] = SavedAudio(state: .saved, percent: 100, bytes: size)
        case .failure:
            // Without network it isn't the song's fault: it goes on by itself when it returns.
            audio[id] = SavedAudio(state: online ? .failed : .queued)
        }
        pump()
    }

    private func networkChanged(_ up: Bool) {
        guard up != online else { return }
        online = up
        pump()
    }

    /// Asks iOS for a little time to finish downloads when the app goes to the background.
    private func updateBackgroundTask() {
        if !running.isEmpty && backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "esputifai-downloads") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() } // iOS calls it on the main thread
            }
        } else if running.isEmpty {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
