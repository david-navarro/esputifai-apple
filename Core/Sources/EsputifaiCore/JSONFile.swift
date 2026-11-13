import Foundation

/// One value persisted as one JSON file; the base of the playlist, Albumteca and play stores.
///
/// Why JSON files and not Core Data/SwiftData: small data, always read whole, no queries (the
/// Android app made the same choice). Every change is written to disk (atomic replace, so a crash
/// never leaves half a file) before `value` changes, so what the UI shows is always what is saved.
/// A file that can't be read is renamed to `<name>.unreadable-<ms>` and never overwritten.
///
/// Not thread-safe: the stores that own one use it from the main actor only.
public final class JSONFile<T: Codable & Equatable> {
    public let url: URL
    public private(set) var value: T

    public init(url: URL, empty: T) {
        self.url = url
        self.value = empty
        if let data = try? Data(contentsOf: url) {
            do {
                value = try JSONDecoder().decode(T.self, from: data)
            } catch {
                let aside = url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.lastPathComponent).unreadable-\(nowMillis())")
                try? FileManager.default.moveItem(at: url, to: aside)
            }
        }
    }

    /// Saves `next` and makes it the value; does nothing when it is equal to the current one.
    /// Returns whether anything changed.
    @discardableResult
    public func set(_ next: T) throws -> Bool {
        guard next != value else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(next).write(to: url, options: .atomic)
        value = next
        return true
    }
}
