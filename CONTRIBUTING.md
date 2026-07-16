# Contributing

Thanks for contributing to Apple Music Lyrics.

## Development Setup

Requirements:

- macOS 13 or later
- Swift 5.9 or Xcode 15 or later
- Music.app for integration testing

Build and test before opening a pull request:

```bash
swift build
swift test
```

To validate the private Music.app cache integration, start a catalog track whose
lyrics have already appeared in Music.app, then run:

```bash
APPLE_MUSIC_CACHE_INTEGRATION=1 \
  swift test --filter AppleMusicCacheIntegrationTests
```

## Pull Requests

- Keep changes focused and consistent with the existing AppKit architecture.
- Add or update tests for TTML parsing, cache matching, and timing behavior.
- Preserve read-only access to Music.app's cache.
- Do not add account-token extraction, request interception, or hidden network calls.
- Preserve the `com.apple.security.automation.apple-events` entitlement when
  packaging with Hardened Runtime; without it, Music automation is denied
  before macOS can show the permission prompt.
- Do not commit `.build`, `dist`, app bundles, local cache data, or copyrighted lyrics.
- Document behavior that depends on a private Apple format.

## Test Fixtures

Use short, synthetic text in fixtures. Do not copy production lyrics or cache
responses into the repository. Reduce reported cache samples to the smallest
structure necessary to reproduce a parser or matching issue.

## Releases

Maintainers publish releases with annotated tags in `vMAJOR.MINOR.PATCH` form.
The tag workflow runs tests and uploads universal ZIP and DMG artifacts. Do not
manually commit generated files from `dist/`.
