# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-06

### Added

- Engine `config/icons.yml` (or `icons.yml` at the gem root) merges under the
  app's `icons.yml`, same load order as I18n: engines first, app last, a name
  the app sets wins. `rake fontico:build` sees the same files without booting
  the environment.

### Fixed

- Editing a local SVG now rebuilds its sprite body. The lockfile still caches
  Iconify responses; first-party files are re-read from disk on every build.
- `rake fontico:update` re-fetches bodies without deleting `icons.lock`, so
  append-only codepoints are not reassigned in manifest order.
- `Fontico.codepoint` / `Fontico.glyph` raise on an unknown name instead of
  allocating a private-use codepoint that maps to nothing. The `ttf` emitter
  refuses the same way: a nil codepoint used to cross into the toolchain as
  JSON `null`, and `String.fromCodePoint(null)` is `"\u0000"` — no error, just
  a glyph silently mapped to NUL.
- Deleting a local SVG now drops the icon and names it in red. The lock used
  to count it as fresh, so the sprite kept rendering the last-known body
  indefinitely. Its codepoint is still retained.

### Changed

- `--offline` no longer blames `icons.lock` when `force` is what made a body
  stale, and no longer fails a manifest of nothing but local files.
- An untouched local SVG counts as cached rather than fetched. It is re-read
  every build, so being stale is not evidence that anything changed.

## [0.1.2]

### Fixed

- Vendor icons on a grid other than 24 shipped cropped to their top-left
  corner. Iconify returns a body fragment with its dimensions out of band,
  and the wrapper the preprocessor built around it hardcoded a 24×24 viewBox,
  so the refit computed a scale of 1 and never ran. arcticons (48) rendered as
  its own top-left quarter, game-icons (512) as a near-empty corner. lucide is
  24, which is why the default provider never showed it.

### Changed

- Releases run from a single tag-triggered workflow: the suite and rubocop
  gate the push, and the gem ships through RubyGems trusted publishing.
  0.1.1 was tagged but never reached rubygems.org, so its contents land here.

## [0.1.0]

- Initial release.
