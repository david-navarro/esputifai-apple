# AGENTS.md: Esputifai for iPhone, a reference for AI coding agents

For agents (and humans new to the code). `README.md` holds status, install steps, history and the
reasons behind decisions. When docs and code disagree, the code wins; fix the doc.

The Android app (`github.com/david-navarro/esputifai`, its own `AGENTS.md`) is the reference for
behavior: this app ports its features one by one. When adding a feature to one, consider the other.

## 1. Hard rules

1. **Serverless.** Nothing depends on a server the project runs. Calling YouTube directly is fine;
   so is the static GitHub Pages share page that lives in the Android repo (`docs/l/`).
2. **Language.** Code, comments, docs, commits and file names in American English. Every
   user-visible string in Spanish (Spain), inline in Swift, same wording as Android.
3. **Real data over mocks.** Smoke tests hit the real YouTube Music. No CI: run tests locally.
4. **The repo is public.** No personal data, device names, network details, keys, Apple team IDs.
5. **Owner's product decisions** (§6) are requirements.
6. **Nothing installed on the Linux host.** `Core/` builds in Docker (`scripts/test-core.sh`).
   The app needs Xcode on the owner's Mac.
7. **No Google sign-in, no device sync** (left out of the iPhone port by the owner, 2026-11-13).

## 2. Architecture

```
EsputifaiApp ──▶ RootView (SwiftUI, 4 tabs, NavigationStack per tab)
                    │ reads/calls (environment)
                    ▼
                 AppModel (@MainActor @Observable) ── stores ─▶ PlaylistStore / AlbumStore / PlayCountStore (JSON files)
                    │   ├─ catalog ─▶ YouTubeMusic (async) ─▶ InnerTube (WEB_REMIX) ─▶ music.youtube.com
                    │   ├─ player ──▶ Player (AVPlayer, MPRemoteCommandCenter)
                    │   │                └─ AVURLAsset ytm://track/<id> ─▶ AudioLoader ─▶ AudioFetcher ─▶ googlevideo
                    │   │                                                     └─ YouTubeMusic.resolveAudio (visionOS client)
                    │   └─ offline ─▶ OfflineAudio (files, NWPathMonitor) ─▶ AudioFetcher.download
                    └─ library changes ─▶ wantedOnPhone ─▶ OfflineAudio.sync
```

- `Core/` (Swift package `EsputifaiCore`) has no UIKit/AVFoundation, so it builds and is tested
  on Linux. Anything used by the app must be `public`.
- `App/` is iOS-only. `AppModel` is the only state holder; screens hold only visual state
  (`@State` for dialogs, focus, drag position). Navigation is `AppModel.tab` + `paths[tab]`
  (`Route`); panels are `AppModel` properties (`showingPlayer`, `addingTrack`, `newList`,
  `showingStorage`, `incoming`).
- Stores are plain classes used on the main actor: every change is written to disk (atomic)
  before the value changes, then `onChange` tells `AppModel`, which copies the values into its
  observable properties and re-syncs the offline songs.

## 3. YouTube access (`Core/.../InnerTube.swift`, `YouTubeMusic.swift`)

Request shapes copy NewPipeExtractor v0.27.0 (what Android uses); when YouTube breaks something,
NewPipe's fix is the reference.

| What | Endpoint | Parser |
|---|---|---|
| Search (4 kinds) | `music.youtube.com/youtubei/v1/search` + `params` filter; next page `?ctoken=&continuation=&type=next` | `songItem`, `albumItem`, `playlistItem`, `artistItem` over `musicResponsiveListItemRenderer` |
| Album / public playlist songs | `browse` `VL<playlistId>`; next pages `browse {continuation}` → `onResponseReceivedActions[0].appendContinuationItemsAction` | `songItem` (duration in `fixedColumns`) |
| Related ("Relacionadas") | `next` `{videoId, playlistId: RDAMVM<id>}`; next pages `{playlistId, continuation}` → `continuationContents.playlistPanelContinuation` | `playlistPanelVideoRenderer` |
| Suggestions | `music/get_search_suggestions` | `searchSuggestionRenderer…searchEndpoint.query` |
| Audio URL | `www.youtube.com/youtubei/v1/visitor_id` then `youtubei.googleapis.com/youtubei/v1/player` (visionOS client) | best `audio/mp4` adaptive format; `&cpn=` appended |

- Ids: song = `videoId`; album = its `OLAK5uy_…` playlist id (from the result's play button);
  public playlist = `PL…` (browseId without `VL`); artist = `UC…` channel id.
- An artist "run" is recognized by `pageType == MUSIC_PAGE_TYPE_ARTIST`, never by labels (labels
  are localized: requests use `hl=es`).
- `JSON.findFirst(key)` finds shelves by name anywhere, surviving wrapper changes.
- Audio URLs are tied to the phone's IP and expire (`expire=`): resolved on the phone, cached
  until 10 min before expiry, re-resolved once on a 403 (`AudioFetcher.range`).
- Thumbnails are upscaled by rewriting googleusercontent size suffixes (`=w544-h544-l90-rj`, `=s544`).

## 4. Data

| File (Application Support) | Format |
|---|---|
| `playlists.json` | `{"version":1,"playlists":[{id,name,createdAtMs,offline,tracks:[Track…]}]}` |
| `albums.json` | `{"version":1,"albums":[{id,title,artist,thumbnailUrl,addedAtMs,offline,tracks}]}` |
| `plays.json` | Android's v2: `{"version":2,"songs":{"<videoId>":{count,lastPlayedMs,track}},"albums":{"<id>":{album,trackIds}}}` |
| `offline-audio/<videoId>.m4a` | saved songs; `.part` while downloading (deleted on start-up) |

Track JSON: `{videoId,title,artist,durationSec,thumbnailUrl|null}`. A file that fails to parse is
renamed `<name>.unreadable-<ms>` and never overwritten. To evolve a format: new fields optional
with defaults (`decodeIfPresent`), bump `version` only when old readers would misread.

UserDefaults: `activeList`, `searchKind`, `albumOrder`, `topKind`.

## 5. Playback and offline

- `Player.play(tracks, from:)`: if that song is already playing (and not in error) only the queue
  changes. Otherwise a new `AVPlayerItem`: file URL if saved, else `ytm://track/<id>` with
  `AudioLoader` as resource-loader delegate.
- `AudioLoader` answers content info (`AVFileType.m4a`, length, byte ranges) and serves each data
  request in chunks; responses and `finishLoading` are posted on its serial queue, in order.
- Ends: `AVPlayerItemDidPlayToEndTime` → `onFinished` (count the play) → next. Failures skip to the
  next song at most once around the queue, then show the error in the player bar.
- `OfflineAudio.sync(wanted:)` (from `wantedOnPhone`) queues missing songs and deletes unneeded
  ones; 2 downloads at a time; a failure with network is `failed` (waits for "Reintentar"),
  without network it goes back to `queued`. A background task asks iOS for time to finish.

## 6. Owner's decisions (requirements, from Android)

- No server, no YouTube account. Playlists are never synced with YouTube.
- Offline is per playlist or album, never per song; any network, mobile data included.
- A play counts only when the song plays to its end.
- Tapping the song that is playing doesn't restart it.
- Artist page: 5 popular songs ("Ver todas"), then albums.
- Albumteca "Más escuchados" uses the plays of the album's songs from anywhere.
- "Reproduciendo" is a sheet with seek bar and queue, not a full-screen player.
- A public playlist saved in "Mis listas" is a streaming copy that never follows the original.
- Standard system sizes; text follows the phone's text size.
- Only critical CVEs (CVSS ≥ 9); pinned versions (the Docker image by digest; no third-party
  Swift packages so far: keep it that way unless there is a strong reason).

## 7. Testing

`scripts/test-core.sh` (Docker, Swift 6.2, Swift 5 language mode). `LibraryTests`: stores,
rankings, offline rules, title keys, the shared-link format (Mac only: Compression framework).
`YouTubeSmokeTests`: real YouTube Music; when they fail and the code didn't change, YouTube did.

Only a real iPhone can check: playback, background audio, lock screen, AVPlayer with the
resource loader, downloads and airplane mode, opening shared links. Say so when a change touches
them.

To look at a YouTube response while fixing a parser, POST the same body as `InnerTube.music`
with curl or Python and save the JSON; the smoke tests print what each parser got.

## 8. Glossary (UI Spanish → meaning)

Same as Android's AGENTS.md §13: Buscar, Canciones/Álbumes/Artistas/Listas, Relacionadas,
Mis listas, Albumteca, Top, "Añadir a: [lista ▾]" (active list), En streaming / Guardada en el
móvil, Reintentar, Deshacer, Reproduciendo, Ir al álbum, Compartir / ¿Importar?, Guardar en Mis
listas, Reproducir / Aleatorio, Ver todas / Ver menos.
