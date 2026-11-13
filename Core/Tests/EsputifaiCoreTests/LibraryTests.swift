import XCTest
@testable import EsputifaiCore

/// Stores, rankings and offline rules. No network.
final class LibraryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("esputifai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func track(_ id: String, _ title: String = "T", _ artist: String = "A") -> Track {
        Track(videoId: id, title: title, artist: artist, durationSec: 180, thumbnailUrl: nil)
    }

    func testPlaylistsPersistAndReload() throws {
        let url = dir.appendingPathComponent("playlists.json")
        let store = PlaylistStore(url: url)
        let p = try store.create(name: "  Para cocinar ", tracks: [track("a"), track("a"), track("b")])
        XCTAssertEqual(p.name, "Para cocinar")
        XCTAssertEqual(p.tracks.map(\.videoId), ["a", "b"])
        XCTAssertTrue(try store.addTrack(p.id, track("c")))
        XCTAssertFalse(try store.addTrack(p.id, track("c")), "a song appears once per list")
        try store.moveTrack(p.id, from: 2, to: 0)
        XCTAssertEqual(try store.removeTrack(p.id, videoId: "a"), 1)
        try store.setOffline(p.id, true)
        try store.create(name: "")

        let again = PlaylistStore(url: url)
        XCTAssertEqual(again.playlists.map(\.name), ["Para cocinar", "Lista sin nombre"])
        XCTAssertEqual(again.playlists[0].tracks.map(\.videoId), ["c", "b"])
        XCTAssertTrue(again.playlists[0].offline)
    }

    func testUnreadableFileIsSetAside() throws {
        let url = dir.appendingPathComponent("playlists.json")
        try Data("{not json".utf8).write(to: url)
        let store = PlaylistStore(url: url)
        XCTAssertTrue(store.playlists.isEmpty)
        try store.create(name: "Nueva")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("playlists.json.unreadable-") }, "\(names)")
    }

    func testAlbumsAndPlays() throws {
        let albums = AlbumStore(url: dir.appendingPathComponent("albums.json"))
        let a = Album(id: "OLAK1", title: "Ángel", artist: "X", thumbnailUrl: nil)
        let b = Album(id: "OLAK2", title: "Zeta", artist: "Y", thumbnailUrl: "https://x")
        let c = Album(id: "OLAK3", title: "beta", artist: "Y", thumbnailUrl: nil)
        XCTAssertTrue(try albums.add(a, tracks: [track("1"), track("2")]))
        XCTAssertFalse(try albums.add(a, tracks: []))
        try albums.add(b, tracks: [track("3")])
        try albums.add(c, tracks: [track("4")])
        try albums.setOffline("OLAK2", true)
        XCTAssertEqual(AlbumStore(url: dir.appendingPathComponent("albums.json")).albums.map(\.album), [a, b, c])

        let plays = PlayCountStore(url: dir.appendingPathComponent("plays.json"))
        try plays.countPlay(track("3", "Z song", "Rosalía"))
        try plays.countPlay(track("3", "Z song", "Rosalía"))
        try plays.countPlay(track("1", "A song", "ROSALIA"))
        try plays.rememberAlbum(Album(id: "OLAK9", title: "Played", artist: "Q", thumbnailUrl: nil), tracks: [track("1")])
        let h = PlayCountStore(url: dir.appendingPathComponent("plays.json")).history
        XCTAssertEqual(h.counts, ["3": 2, "1": 1])

        XCTAssertEqual(sortAlbums(albums.albums, .aToZ, plays: h.counts).map(\.album.title), ["Ángel", "beta", "Zeta"])
        XCTAssertEqual(sortAlbums(albums.albums, .zToA, plays: h.counts).map(\.album.title), ["Zeta", "beta", "Ángel"])
        XCTAssertEqual(sortAlbums(albums.albums, .mostPlayed, plays: h.counts).map(\.album.title), ["Zeta", "Ángel", "beta"])

        let songs = Top.songs(h)
        XCTAssertEqual(songs.map(\.item.videoId), ["3", "1"])
        let artists = Top.artists(songs)
        XCTAssertEqual(artists.count, 1, "Rosalía and ROSALIA are one artist")
        XCTAssertEqual(artists[0].plays, 3)
        XCTAssertEqual(artists[0].item.name, "Rosalía")
        XCTAssertEqual(Top.albums(h, albumteca: albums.albums).map(\.item.id), ["OLAK2", "OLAK1", "OLAK9"])
    }

    func testOfflineRules() {
        let saved = Playlist(id: "p", name: "P", tracks: [track("a"), track("b")], createdAtMs: 0, offline: true)
        let streamed = Playlist(id: "q", name: "Q", tracks: [track("c")], createdAtMs: 0)
        let album = LibraryAlbum(album: Album(id: "x", title: "X", artist: "", thumbnailUrl: nil), tracks: [track("b"), track("d")], addedAtMs: 0, offline: true)
        let wanted = wantedOnPhone([saved, streamed], [album])
        XCTAssertEqual(wanted, ["a", "b", "d"])
        let plan = planSync(wanted: wanted, existing: [
            "a": SavedAudio(state: .saved, bytes: 4_000_000),
            "c": SavedAudio(state: .saved, bytes: 1),
            "d": SavedAudio(state: .failed),
        ])
        XCTAssertEqual(plan.add, ["b"], "failed songs wait for Reintentar")
        XCTAssertEqual(plan.remove, ["c"])
        let p = progressOf(saved.tracks, ["a": SavedAudio(state: .saved, bytes: 4_000_000)])
        XCTAssertEqual(p, OfflineProgress(total: 2, saved: 1, failed: 0, bytes: 4_000_000))
        XCTAssertEqual(formatBytes(96_400_000), "96 MB")
        XCTAssertEqual(formatBytes(1_240_000_000), "1,2 GB")
        XCTAssertEqual(formatDuration(seconds: 3723), "1:02:03")
        XCTAssertEqual(formatDuration(seconds: 187), "3:07")
    }

    func testTitleKeyAndLooseTitle() {
        XCTAssertEqual(RelatedSongs.titleKey(track("1", "ROSALÍA - DI MI NOMBRE (Official Video)", "ROSALÍA")),
                       RelatedSongs.titleKey(track("2", "DI MI NOMBRE", "ROSALÍA")))
        XCTAssertEqual(YouTubeMusic.looseTitle("Let It Be (Remastered 2009)"), "let it be")
        XCTAssertEqual(YouTubeMusic.looseTitle("Let It Be - Remastered"), "let it be")
        XCTAssertEqual(YouTubeMusic.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(YouTubeMusic.parseDuration("131 M reproducciones"), 0)
    }

    /// A link made by the Android app (Java's Deflater; same bytes as Python's zlib) must import.
    /// Compression is Apple-only, so this runs on a Mac (`swift test`), not in the Linux container.
    func testSharedLinkFromAndroid() throws {
        #if canImport(Compression)
        let link = "https://david-navarro.github.io/esputifai/l/#eNqrVipTsjLUUcpTslIKSCxKVEjOT87MSyxS0lEqUbKKjlZKdS8N8_dLidAtzQeKuXgq-Hoq-Pn7OgW5Kmg4JxboWVgpHO6sKEkszizWBCoI8g929Dnc66ikY2hmHKsTrZRbbhThqxsQXBgRCZT2dfRx9HX1C4FqNrRScCxNLy3KzEfTa2oYG1sLAAV_LfM"
        let shared = try XCTUnwrap(PlaylistShare.parse(link))
        XCTAssertEqual(shared.name, "Para cocinar")
        XCTAssertEqual(shared.tracks.map(\.videoId), ["eGuVONdX-uo", "mw2XM-PSqXY"])
        XCTAssertEqual(shared.tracks[0].title, "DI MI NOMBRE (Cap.8: Éxtasis)")
        XCTAssertEqual(shared.tracks[1].durationSec, 151)
        XCTAssertEqual(PlaylistShare.parse("esputifai://import?d=" + link.split(separator: "#")[1])?.tracks.count, 2)
        let made = try XCTUnwrap(PlaylistShare.link(name: "Cocina «ñ»", tracks: [track("dQw4w9WgXcQ", "Never", "Rick")]))
        let back = try XCTUnwrap(PlaylistShare.parse(made))
        XCTAssertEqual(back.name, "Cocina «ñ»")
        XCTAssertEqual(back.tracks.map(\.videoId), ["dQw4w9WgXcQ"])
        XCTAssertEqual(back.tracks[0].durationSec, 180)
        XCTAssertNil(PlaylistShare.parse("https://david-navarro.github.io/esputifai/l/#basura"))
        #else
        throw XCTSkip("Compression framework only on Apple platforms")
        #endif
    }
}
