# Esputifai for iPhone

A personal, serverless iPhone music player backed by YouTube Music: the iPhone version of
[Esputifai for Android](https://github.com/david-navarro/esputifai). The phone talks to YouTube
directly; nothing runs on a server. Personal use only; not distributed, not on the App Store.

**Working on the code (humans or AI agents):** read [`AGENTS.md`](AGENTS.md) first.

## Status (2026-11-13)

- **v0.1.0 not yet built or tried on an iPhone.** Everything the Android app v0.8.1 does is ported
  except Google sign-in and device sync through Google Drive (left out on purpose).
- `Core/` (YouTube Music client, stores, rules) is built and tested on Linux against the real
  YouTube Music: search, albums, artists, public playlists (paged), related songs, "Ir al álbum",
  audio URL resolution, byte ranges and whole-song downloads all pass.
- The app (`App/`, SwiftUI) has not been compiled yet: it needs Xcode on a Mac.

## Features (same as Android)

- **Buscar:** songs, albums, artists and public playlists ("Listas"), with suggestions while
  typing. Under song results, "Relacionadas" (the YouTube Music radio of the first result), 10 at
  a time.
- **Mis listas:** local playlists. Create, rename, delete, share as a link, move songs up/down,
  remove (with "Deshacer"), play or shuffle. Each list is "En streaming" or "Guardada en el móvil".
- **Active list:** "+" next to any song adds it to the active list with one tap; a long press on
  "+" chooses lists. The "Añadir a: [lista ▾]" bar changes the active list.
- **Albumteca:** albums kept with their songs; sort by "Más escuchados", A-Z, Z-A; can be saved
  on the phone.
- **Top:** most played songs, artists and albums. A play counts when a song plays to its end.
- **Artist page:** 5 popular songs ("Ver todas"), then albums.
- **Song menu (long press on a song):** "Ir al álbum", "Añadir a listas…".
- **Reproduciendo:** tap the player for the seek bar and the queue (jump, move, remove).
- **Background playback** with lock screen, Control Center and headphone controls.
- **Offline:** lists and albums saved on the phone play in airplane mode; the "En el móvil"
  line shows what it takes and can turn everything back to streaming.
- **Shared lists:** the same links as the Android app, in both directions. The link's web page
  (served from the Android repo) opens `esputifai://import?d=…`, and the app asks "¿Importar?".

Left out: Google sign-in and device sync (Android v0.7.0). The library lives only on the phone.

## Install on an iPhone without the App Store

Needs a Mac with Xcode (free from the Mac App Store) and the iPhone's USB cable (the first time).
Clone the repo on the Mac and open `Esputifai.xcodeproj` (it is generated from `project.yml` and
committed, so nothing else has to be installed).

In Xcode:

1. **Xcode → Settings → Accounts:** add your Apple ID (a normal free one works).
2. Select the **Esputifai** target → **Signing & Capabilities** → Team: your Apple ID ("Personal
   Team"). If Xcode says the bundle identifier is not available, change
   the Bundle Identifier right there in Xcode (e.g. add your name); to keep it, also change
   `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and regenerate (`scripts/gen-xcodeproj.sh`).
3. Connect the iPhone, pick it as the run destination, press **Run** (▶).
4. On the iPhone, the first time: **Settings → Privacy & Security → Developer Mode** on (it
   restarts), then **Settings → General → VPN & Device Management** → trust your Apple ID.

**How long it lasts:** with a free Apple ID the app stops opening after **7 days**; run it again
from Xcode to renew it (the data stays). With a paid Apple Developer account (99 €/year) it lasts
a year and can go to other people's iPhones (ad hoc, by registering their device). SideStore or
AltStore can renew a free signature by themselves without the Mac each week.

## Layout

```
project.yml                   XcodeGen spec; Esputifai.xcodeproj + App/Info.plist are generated from it (committed)
Core/                         Swift package EsputifaiCore: no UIKit/AVFoundation, builds on Linux
  Sources/EsputifaiCore/
    Models.swift              Track, Album, OnlinePlaylist, Artist, Playlist, LibraryAlbum…
    JSONFile.swift            one value persisted as one JSON file (atomic, unreadable files set aside)
    LibraryStores.swift       PlaylistStore, AlbumStore, PlayCountStore (playlists/albums/plays.json)
    Rankings.swift            Albumteca order and the Top (Spanish ordering)
    OfflineRules.swift        what must be on the phone, sync plan, progress, formatting
    PlaylistShare.swift       playlist <-> link (zlib + base64url), compatible with Android
    JSON.swift                forgiving navigation over YouTube's JSON
    InnerTube.swift           HTTP to YouTube: WEB_REMIX (catalog) and visionOS (audio) clients
    YouTubeMusic.swift        search, albums, playlists, artists, suggestions, radio, audio URLs
    RelatedSongs.swift        "Relacionadas": paged, de-duplicated radio
    AudioFetcher.swift        googlevideo byte ranges (POST, range=, rn=) and whole downloads
  Tests/EsputifaiCoreTests/   LibraryTests (no network), YouTubeSmokeTests (real YouTube Music)
App/
  Sources/
    EsputifaiApp.swift        entry point, shared-link URLs, foreground
    AppModel.swift            the app's state and actions (the Android MusicViewModel)
    Playback/Player.swift     queue + AVPlayer, lock screen and remote controls, play counting
    Playback/AudioLoader.swift  ytm://track/<id> for AVPlayer: lazy resolution + ranged reads
    Playback/OfflineAudio.swift saved songs: downloads, files, network state
    UI/                       SwiftUI screens (RootView is the shell)
  Resources/Assets.xcassets   icon and accent colour
design/                       logo sources; esputifai-ios-icon.svg is the square app icon
scripts/test-core.sh          builds and tests Core/ in Docker (swift image pinned by digest)
scripts/gen-xcodeproj.sh      regenerates the Xcode project with XcodeGen, in Docker
```

## Build and test

```bash
scripts/test-core.sh                                    # Core: all tests, on Linux, in Docker
scripts/test-core.sh --filter YouTubeSmokeTests         # only the real-YouTube smoke tests
```

On a Mac, `cd Core && swift test` also runs the shared-link test (it needs Apple's Compression
framework, so it is skipped on Linux). The app itself builds only in Xcode.

## How it works (differences from Android)

- **No NewPipeExtractor** (it is Java). `Core/` speaks YouTube's internal API ("InnerTube") itself,
  copying the request shapes of NewPipeExtractor v0.27.0, the version the Android app uses:
  - catalog through the YouTube Music web client (`WEB_REMIX`, music.youtube.com): search with
    the same filters NewPipe sends, playlists/albums via `browse VL<id>` (paged), radio via
    `next RDAMVM<id>`, suggestions via `music/get_search_suggestions`;
  - audio through the **visionOS client** (`youtubei.googleapis.com/…/player`, with a
    `visitorData` from `visitor_id`). Its stream URLs work as they come: no signature or `n`
    deciphering, so no JavaScript engine is needed (checked 2026-11-13).
- **AAC, not Opus.** AVPlayer can't play YouTube's Opus/WebM, so the app picks the best
  original-language `audio/mp4` stream: itag 140, AAC ~130 kbps (Android: Opus ~160 kbps).
- **Playback:** AVPlayer opens `ytm://track/<videoId>`; `AudioLoader` (an
  `AVAssetResourceLoaderDelegate`) resolves the URL when AVPlayer first asks, and serves the
  ranges AVPlayer wants with the same request shape as Android (POST `x\0`, `&range=a-b&rn=N`,
  visionOS user agent), 256 KB first then 2 MB chunks; a 403 re-resolves once. Saved songs play
  from their file. The next song's URL is resolved in advance.
- **Offline:** whole files in Application Support/offline-audio (`<videoId>.m4a`, not backed up
  to iCloud), two downloads at a time, on any network. iOS suspends apps in the background, so
  downloads run while the app is open or playing; they resume when it comes back.
- **Artists:** like Android, a search by name keeping only results credited to the artist's
  channel (two pages of songs and of albums).
- **Data files** (Application Support): `playlists.json`, `albums.json`, `plays.json`; plays use
  the Android format. Remembered choices in UserDefaults.

## Maintenance: when YouTube breaks playback or search

1. Run `scripts/test-core.sh --filter YouTubeSmokeTests`: it prints search results, the chosen
   stream and checks three byte ranges and a whole download.
2. Compare `Core/Sources/EsputifaiCore/InnerTube.swift` with the latest NewPipeExtractor
   (`ClientsConstants.java`, `YoutubeParsingHelper.prepareJsonBuilder`,
   `YoutubeStreamHelper.getVisionOsPlayerResponse`, `YoutubeMusicSearchExtractor`): client
   versions, device model, user agent. If the Android app needed a NewPipe bump, the same change
   is probably needed here.
3. If parsing fails (empty results), dump the response (see the probes described in AGENTS.md)
   and adjust `YouTubeMusic.swift`'s parsers.

## Pinned versions and supply chain

- **The app has no third-party code:** only Apple frameworks (SwiftUI, AVFoundation, MediaPlayer,
  Network). `Core/` has no dependencies either (no `Package.resolved` to pin). Keep it that way
  unless there is a strong reason; a new package must be pinned by exact version (`exact:`) and
  its `Package.resolved` committed.
- **Build tools:** the Swift image (6.2.4) by digest in `scripts/*.sh`; XcodeGen by commit
  (`21ac994…`, tag 2.44.1), its dependencies by revision through its own `Package.resolved`.
  Both only run on the Linux host, never in the app.
- **Known vulnerabilities:** only critical ones are patched (owner's policy, CVSS ≥ 9), checked
  against [OSV](https://osv.dev). 2026-11-14: none for XcodeGen 2.44.1 or any of its 10 resolved
  dependencies (AEXML, ArtifactBundleGen, JSONUtilities, PathKit, Rainbow, Spectre, SwiftCLI,
  Version, XcodeProj, Yams). Xcode and iOS themselves are Apple's and update with them.

## License

Copyright (C) 2026 david-navarro. GPL-3.0, like the Android app (see [LICENSE](LICENSE)).

This is an independent personal project, not affiliated with YouTube, Google, Apple or Spotify.

## History

- **2026-11-13:** v0.1.0: port of Esputifai for Android v0.8.1 to iPhone (SwiftUI, AVPlayer, own
  InnerTube client), without Google sign-in and device sync.
