import Foundation

/// Fixes the header of YouTube's fragmented MP4 audio for AVFoundation.
///
/// YouTube's `audio/mp4` streams are fragmented (`moov` with `mvex`, then `moof`/`mdat` pairs), yet
/// their `moov` also declares the whole song's duration in `mvhd`, `tkhd` and `mdhd`. AVFoundation
/// adds the fragments' duration to that, so every song reports twice its length and AVPlayer only
/// ends it (plays to end, counts the play, moves on) after as much silence again. ExoPlayer ignores
/// those fields. Zeroing them, as fragmented files normally have them, gives the true duration.
public enum FragmentedMP4 {
    /// Clears the movie, track and media durations of a fragmented MP4 whose first bytes are
    /// `data` (offset 0). Data that doesn't start at offset 0, doesn't hold the whole `moov`, or
    /// isn't fragmented (no `mvex`) is left as it is.
    public static func clearHeaderDurations(_ data: inout Data, offset: Int64) {
        guard offset == 0, let moov = boxes(in: data, from: 0, to: data.count).first(where: { $0.type == "moov" }),
              boxes(in: data, from: moov.body, to: moov.end).contains(where: { $0.type == "mvex" }) else { return }
        for box in boxes(in: data, from: moov.body, to: moov.end) {
            switch box.type {
            case "mvhd": clearDuration(&data, box, v0: 16, v1: 24)
            case "trak":
                for inner in boxes(in: data, from: box.body, to: box.end) {
                    if inner.type == "tkhd" { clearDuration(&data, inner, v0: 20, v1: 28) }
                    if inner.type == "mdia", let mdhd = boxes(in: data, from: inner.body, to: inner.end).first(where: { $0.type == "mdhd" }) {
                        clearDuration(&data, mdhd, v0: 16, v1: 24)
                    }
                }
            default: break
            }
        }
    }

    private struct Box { var type: String; var body: Int; var end: Int }

    /// The boxes laid out in `data[from..<to]` (indices relative to `data.startIndex`).
    private static func boxes(in data: Data, from: Int, to: Int) -> [Box] {
        var result: [Box] = []
        var i = from
        while i + 8 <= to {
            let size = Int(uint32(data, i))
            guard size >= 8, i + size <= to,
                  let type = String(data: data.subdata(in: data.startIndex + i + 4 ..< data.startIndex + i + 8), encoding: .ascii)
            else { break }
            result.append(Box(type: type, body: i + 8, end: i + size))
            i += size
        }
        return result
    }

    /// Zeroes the duration of a full box: 4 bytes at `v0` (version 0) or 8 at `v1` (version 1),
    /// both counted from the start of the body (version and flags included).
    private static func clearDuration(_ data: inout Data, _ box: Box, v0: Int, v1: Int) {
        guard box.body < box.end else { return }
        let version = data[data.startIndex + box.body]
        let (start, length) = version == 1 ? (box.body + v1, 8) : (box.body + v0, 4)
        guard start + length <= box.end else { return }
        data.replaceSubrange(data.startIndex + start ..< data.startIndex + start + length, with: Data(count: length))
    }

    private static func uint32(_ data: Data, _ i: Int) -> UInt32 {
        let s = data.startIndex + i
        return data[s ..< s + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
