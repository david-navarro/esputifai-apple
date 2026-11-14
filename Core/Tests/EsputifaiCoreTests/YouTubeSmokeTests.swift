import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import EsputifaiCore

/// Against the real YouTube Music (needs network). When these fail and the code didn't change,
/// YouTube changed: see README, "When YouTube breaks playback or search".
final class YouTubeSmokeTests: XCTestCase {

    func testSearchResolveAndDownloadRanges() async throws {
        let songs = try await YouTubeMusic.search("rosalia di mi nombre")
        print("songs:", songs.prefix(5).map { "\($0.title) · \($0.artist) · \($0.durationSec)s · \($0.videoId)" })
        XCTAssertGreaterThan(songs.count, 5)
        let first = try XCTUnwrap(songs.first)
        XCTAssertFalse(first.artist.isEmpty)
        XCTAssertGreaterThan(first.durationSec, 60)
        XCTAssertTrue(first.thumbnailUrl?.contains("w544-h544") == true, first.thumbnailUrl ?? "nil")

        let audio = try await YouTubeMusic.resolveAudio(first.videoId)
        print("audio:", audio.mimeType, audio.bitrate, audio.contentLength, audio.expiresAt)
        XCTAssertTrue(audio.mimeType.hasPrefix("audio/mp4"))
        XCTAssertTrue(audio.url.contains("&c=VISIONOS"))

        // Start, a whole chunk, and the tail: what the player asks for when it opens and seeks.
        let total = audio.contentLength
        for (start, end) in [(Int64(0), Int64(1)), (Int64(0), AudioFetcher.chunkSize - 1), (total - 50_000, total - 1)] {
            let (data, _) = try await AudioFetcher.range(first.videoId, audio: audio, from: start, through: end, number: 0)
            XCTAssertEqual(Int64(data.count), end - start + 1, "range \(start)-\(end)")
        }
        // An MP4 starts with an `ftyp` box.
        let (head, _) = try await AudioFetcher.range(first.videoId, audio: audio, from: 0, through: 11, number: 1)
        XCTAssertEqual(String(decoding: head[4..<8], as: UTF8.self), "ftyp")
    }

    func testDownloadWholeSong() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("esputifai-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        let size = try await AudioFetcher.download("mw2XM-PSqXY", to: file)
        let onDisk = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64
        print("downloaded:", size, "bytes")
        XCTAssertEqual(onDisk, size)
        XCTAssertGreaterThan(size, 1_000_000)
        #if canImport(AVFoundation)
        // AVFoundation reads YouTube's header as twice the song's length unless it is fixed.
        let seconds = try await AVURLAsset(url: file).load(.duration).seconds
        print("AVFoundation duration:", seconds)
        XCTAssertLessThan(seconds, 200, "the song lasts 151 s; double means FragmentedMP4 didn't apply")
        XCTAssertGreaterThan(seconds, 100)
        #endif
    }

    func testCatalog() async throws {
        let suggestions = try await YouTubeMusic.suggestions("rosal")
        print("suggestions:", suggestions)
        XCTAssertFalse(suggestions.isEmpty)

        let albums = try await YouTubeMusic.searchAlbums("el mal querer")
        print("albums:", albums.prefix(3).map { "\($0.title) · \($0.artist) · \($0.id)" })
        let album = try XCTUnwrap(albums.first)
        XCTAssertTrue(album.id.hasPrefix("OLAK"))
        let tracks = try await YouTubeMusic.albumTracks(album)
        print("album tracks:", tracks.map { "\($0.title) \($0.durationSec)s" })
        XCTAssertGreaterThanOrEqual(tracks.count, 8)
        XCTAssertTrue(tracks.allSatisfy { $0.durationSec > 0 && !$0.artist.isEmpty })

        let artists = try await YouTubeMusic.searchArtists("rosalia")
        let artist = try XCTUnwrap(artists.first)
        print("artist:", artist)
        XCTAssertTrue(artist.channelId.hasPrefix("UC"))
        let artistSongs = try await YouTubeMusic.artistSongs(artist)
        let artistAlbums = try await YouTubeMusic.artistAlbums(artist)
        print("artist page:", artistSongs.count, "songs,", artistAlbums.count, "albums")
        XCTAssertGreaterThan(artistSongs.count, 5)
        XCTAssertGreaterThan(artistAlbums.count, 2)

        let lists = try await YouTubeMusic.searchPlaylists("rock en español")
        let list = try XCTUnwrap(lists.first)
        print("playlist:", list.title, "·", list.author, "·", list.id)
        let listTracks = try await YouTubeMusic.playlistTracks(list)
        print("playlist tracks:", listTracks.count)
        XCTAssertGreaterThan(listTracks.count, 100, "more than one page")
        XCTAssertLessThanOrEqual(listTracks.count, YouTubeMusic.playlistMaxSongs)

        let found = try await YouTubeMusic.findAlbum(tracks[2])
        XCTAssertEqual(found?.id, album.id)
    }

    func testRelatedSongs() async throws {
        let results = try await YouTubeMusic.search("rosalia malamente")
        let related = RelatedSongs(seed: results[0].videoId, exclude: results)
        var all: [Track] = []
        for _ in 0..<3 {
            let page = try await related.next()
            print("related page:", page.map { "\($0.title) · \($0.artist)" })
            all += page
        }
        XCTAssertEqual(all.count, 30)
        XCTAssertEqual(Set(all.map(\.videoId)).count, 30, "no repeats")
        XCTAssertTrue(Set(all.map(\.videoId)).isDisjoint(with: results.map(\.videoId)))
    }
}
