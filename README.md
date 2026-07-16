# Apple Music Lyrics

[English](README.md) | [简体中文](README.zh-CN.md)

An unofficial macOS menu bar app that displays synchronized lyrics for the
current track in Music.app. It reads Apple Music's existing on-disk cache and
does not contact a third-party lyrics service.

> [!IMPORTANT]
> This project relies on a private Music.app cache format. It can stop working
> after a macOS update and is not suitable for App Store distribution without
> replacing the data source.

## Features

- Native AppKit menu bar app with no Dock icon
- Word-timed karaoke highlighting from Apple Music TTML
- Smooth 60 fps status bar highlighting between playback samples
- Adaptive status bar width for MacBooks and notched displays
- Long lines scroll inside the status item instead of hiding other menu bar icons
- Always-on-top floating lyrics panel with animated line changes
- Nearby-line preview in the status item menu
- Automatic cache rescanning after track changes
- No third-party packages, analytics, account-token extraction, or lyrics requests

Apple Music supplies timed `<span>` elements that may contain one or more
characters. Highlighting inside a multi-character span is interpolated by this
app; Apple does not necessarily provide a separate timestamp for every character.

## How It Works

```text
Music.app --AppleScript--> track metadata and playback position
    |
    +--local CFNetwork cache--> Apple catalog JSON + word-timed TTML
                                      |
                                      v
                         status bar and floating lyrics
```

The cache reader looks under:

```text
~/Library/Caches/com.apple.Music/Cache.db
~/Library/Caches/com.apple.Music/fsCachedData/
```

It matches responses using the track title, artist, album, and duration. The
cache database is opened read-only. If its schema is unavailable, the app falls
back to scanning recent cache files.

## Compatibility

- macOS 13 or later
- Music.app
- Apple Music catalog tracks whose lyrics response has been cached by Music.app

Arbitrary imported local files are not guaranteed to work. A local track only
works when Music.app has also cached a matching Apple catalog `syllable-lyrics`
response. Cache entries may be evicted by macOS at any time.

Building from source additionally requires Swift 5.9 or Xcode 15 or later.

## Build And Run

Run directly from the Swift package:

```bash
./scripts/run.sh
```

Create a locally signed application bundle:

```bash
./scripts/package-app.sh
open "dist/Apple Music Lyrics.app"
```

Install the generated bundle for the current machine:

```bash
ditto "dist/Apple Music Lyrics.app" "/Applications/Apple Music Lyrics.app"
```

### If The Downloaded App Will Not Open

Release builds use ad-hoc signing and are not yet notarized by Apple. After a
browser download, macOS may report that the app cannot be verified or is
damaged. First confirm that the app came from this project's official GitHub
Release, then remove its quarantine attribute and open it again:

```bash
xattr -dr com.apple.quarantine "/Applications/Apple Music Lyrics.app"
open "/Applications/Apple Music Lyrics.app"
```

If it still will not open, clear all extended attributes from the app bundle:

```bash
xattr -cr "/Applications/Apple Music Lyrics.app"
```

Alternatively, Control-click the app in Finder and choose **Open**, or use
**Open Anyway** under **System Settings > Privacy & Security**. Do not run
these commands on an app obtained from an untrusted source.

## Releases

Pushing a semantic-version tag automatically runs the GitHub Actions release
workflow:

```bash
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

The workflow runs the test suite, builds an `arm64` + `x86_64` universal app,
and publishes these assets to a GitHub Release:

- `Apple-Music-Lyrics-<version>-macos-universal.zip`
- `Apple-Music-Lyrics-<version>-macos-universal.dmg`
- `SHA256SUMS.txt`

Release builds are ad-hoc signed unless `CODESIGN_IDENTITY` is supplied to the
packaging script. Ad-hoc signing does not replace Developer ID signing and Apple
notarization, so downloaded builds may still show a Gatekeeper warning.

## Permissions

On first launch, allow Apple Music Lyrics to control **Music** under:

```text
System Settings > Privacy & Security > Automation
```

The app uses the macOS process API to determine whether Music.app is running,
so it does not need permission to control **System Events**. It also does not
require Full Disk Access or read Apple account credentials.

### Error While Music Is Playing

The first time the app reads the current track, macOS asks whether Apple Music
Lyrics may control Music. Choose **Allow**. If the prompt does not appear, or
the app still shows Error while a song is playing, check:

```text
System Settings > Privacy & Security > Automation > Apple Music Lyrics > Music
```

If Apple Music Lyrics is missing from the Automation list, quit the app, run
the following commands in Terminal, and choose **Allow** when macOS asks again:

```bash
tccutil reset AppleEvents local.applemusiclyrics
open "/Applications/Apple Music Lyrics.app"
```

An ad-hoc signed build may require renewed permission after it is reinstalled
or upgraded.

## Menu Actions

| Action | Description |
| --- | --- |
| Show / Hide Floating Lyrics | Toggle the floating panel (`Command-L` while the menu is focused) |
| Refresh Lyrics | Rescan Music.app's local lyrics cache |
| Quit Apple Music Lyrics | Exit the app |

The floating panel's position, size, and visibility are remembered between
launches.

## Testing

Run deterministic parser and provider tests:

```bash
swift test
```

An opt-in integration test checks the current Music.app track against the real
local cache. Start a cached catalog track first, then run:

```bash
APPLE_MUSIC_CACHE_INTEGRATION=1 \
  swift test --filter AppleMusicCacheIntegrationTests
```

No copyrighted lyrics are stored in the test fixtures.

## Project Layout

```text
Sources/AppleMusicLyrics/
  AppMain.swift                         App entry point
  AppDelegate.swift                     Polling and application state
  NowPlayingService.swift               Music.app AppleScript integration
  AppleMusicCacheLyricsProvider.swift   Cache index and track matching
  AppleTTMLParser.swift                 TTML line and word timing parser
  KaraokeRenderer.swift                 Floating-panel highlighting
  MenuBarController.swift               Status item and smooth title renderer
  FloatingLyricsWindow.swift            Floating lyrics panel
  LyricsService.swift                   Apple-only lyrics service
  Models.swift                          Shared data models
  AppPreferences.swift                  UserDefaults preferences
  AppleScriptRunner.swift               AppleScript execution helper

Tests/AppleMusicLyricsTests/             Unit and opt-in integration tests
Resources/AppIcon.png                    App icon source image
Resources/AppIcon.icns                   macOS application bundle icon
scripts/run.sh                           Release build and direct launch
scripts/package-app.sh                   Local app bundle packaging
scripts/create-release-artifacts.sh      Universal ZIP and DMG creation
.github/workflows/release.yml            Tag-triggered GitHub Release workflow
```

## Known Limitations

- Apple does not provide lyrics content through a supported public MusicKit API.
- The private cache schema and JSON fields may change without notice.
- Lyrics cannot appear until Music.app has downloaded the matching response.
- A cache miss is not automatically fetched by this app; it only rescans locally.
- Status bar items cannot use the application-menu area to the left of a MacBook notch.
- The app bundle is ad-hoc signed for local use, not notarized for distribution.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for development and test expectations.

## License And Disclaimer

The source code is available under the [MIT License](LICENSE).

Lyrics and related metadata remain the property of their respective rights
holders and are not licensed by this repository. This project is not affiliated
with, endorsed by, or sponsored by Apple Inc. Apple Music is a trademark of
Apple Inc.
