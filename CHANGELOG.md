# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Changing `defaults: size:` left every cached remote body refit to the old
  grid. A body carries its refit baked in as a `<g transform>`, while the
  sprite emitter reads the target size live — so the `<symbol>` moved to the
  new `viewBox` and the geometry inside it did not, drawing every icon a
  fraction of its size in the corner of its box, on a page that returns 200.
  `icons.lock` now records the size each body was built at, and a change to
  it invalidates them. Local files are re-read every build and self-heal,
  which is why this only ever showed on cached remotes: most of a manifest.
- Flipping an icon's `multicolor:` override did nothing to an already-cached
  body. Same root cause — freshness was keyed on the source alone, when the
  body is a function of the size and the override too. The palette stayed
  folded to `currentColor` and the `ttf` emitter kept accepting an icon the
  author had just declared unrepresentable.
- `--offline` no longer reports "missing from icons.lock" when every body is
  present and a size change is what invalidated them.

### Changed

- `icons.lock` gained a `size` per entry. A lock written before it is taken
  at the manifest's word once and stamped, so upgrading does not re-fetch a
  whole manifest or put a network round trip in the first deploy after it.
- `icons.lock` is no longer in `.gitignore`. It was ignored in this repo
  while the README called it the one thing you commit.

### Performance

Measured on a 300-icon manifest, worst-case name, per `icon()` call:

|                        | before          | after          |
| ---------------------- | --------------- | -------------- |
| `icon("save")`         | 12.3µs, 28 objs | 0.7µs, 9 objs  |
| `icon("save", size:)`  | 12.9µs, 38 objs | 2.8µs, 37 objs |
| `icons_sprite`         | 20.8µs, 5 objs  | 1.7µs, 6 objs  |

- Manifest lookup is a hash instead of a linear scan. The cost used to grow
  with the size of the manifest rather than with the icons a page draws, so
  naming icons you never drew slowed down the ones you did — 12.3µs a call at
  300 names against 2.2µs at the front of the list. It is now flat.
- Markup for a bare `icon(name)` is rendered once and held. The attrs hash,
  the `html_escape` of constants like `"1em"`, and the string assembly are
  all deterministic; only the sprite path can vary per request, since
  `asset_host` may be a proc that reads it, so the path is still resolved on
  every call and just the markup either side of the `href` is cached. Calls
  that pass options are rendered as before.
- `icons_sprite` holds the sprite instead of re-reading it off disk on every
  request, which in `inline_sprite` mode was a syscall and a fresh copy of
  the whole file per response. A stat still guards it, so a rebuild from
  anywhere is picked up.
- All three caches are dropped by `Fontico.reset!`, which the dev watcher
  already calls after every rebuild.

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
