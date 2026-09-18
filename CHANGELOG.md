# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`c` target: `icons.h` for firmware.** A device names icons by intent like
  every other consumer — `display.drawIcon(ICON_WIFI, ...)` instead of a
  hardcoded `"U+e63e"`. The UTF-8 bytes are literals decided at build time, so
  nothing parses a codepoint string or builds a `String` on the heap inside a
  draw loop. The header also carries a name-sorted table and `fontico_icon()`
  for an icon named at runtime rather than compiled in; it lives in whichever
  translation unit defines `FONTICO_ICONS_IMPLEMENTATION`, so a firmware using
  only the macros carries no table at all.

  It draws out of the same TTF, so `c` implies `ttf` the way `sprite` implies
  `css`. Two things this buys over dropping a vendor icon font on the device:
  the font carries only the icons the manifest names (35 icons → 7KB, against
  357KB for an unsubsetted Material Symbols), and the codepoints are pinned
  append-only. The second matters most: a codepoint compiled into a flashed
  image cannot be hotfixed, so an icon added today must not renumber the ones
  already in the field.

  Names fold to macros (`nav.menu` → `ICON_NAV_MENU`). Two names that fold
  together are refused rather than silently redefined, and non-ASCII names are
  refused because the table is sorted in Ruby and `bsearch`ed in C, where a
  byte above `0x7F` orders the other way under a signed `char`. Multicolour
  icons are left out, as they are from the font — there would be no glyph
  behind the codepoint. A real compiler runs over the generated header in the
  suite: two translation units, `-Werror`, then it checks the bytes, the
  lookup, the sort order, and that a second implementation refuses to link.

- **`gfxfont` target: an Adafruit `GFXfont`, compiled in.** The `c` target
  still assumes something on the device can read a TTF. This one removes that
  assumption: 1-bit bitmaps and a glyph table in a header, taken as-is by
  `Adafruit_GFX` and `Arduino_GFX`. No FreeType, no OpenFontRender, no
  filesystem partition.

  221 icons at 24px is 9,961 bytes of bitmap plus a 1,547-byte glyph table —
  about 11KB, against 357KB for an unsubsetted vendor font on a filesystem.

  Bitmaps are rasterised **out of the TTF fontico already builds**, not from
  the SVG bodies. `build_font.mjs` has already normalised every icon to the em
  box and a common baseline, so bitmaps taken from the font inherit the exact
  geometry the PDF uses; rasterising the SVGs separately would re-derive all of
  it and drift. It also needs nothing new — `opentype.js` was already a
  toolchain dependency, and a scanline fill with the nonzero winding rule
  turns its outlines into pixels. Even-odd would punch holes in any glyph
  whose contours overlap, which is most of them.

  A `GFXfont` is fixed-size and indexed off a byte, so the target holds 224
  icons and says so past that, pointing at `c` which addresses codepoints
  directly. Char codes are positional as a result, so they and the bitmaps are
  emitted into one file and cannot disagree; their order follows the
  append-only codepoints in `icons.lock`, so adding an icon appends rather
  than renumbering what is already flashed. An icon that rasterises blank at
  the requested size is refused rather than shipped as one that draws nothing.

- **`targets:` accepts a mapping**, so an artifact can be placed instead of
  taking its default name in `output_dir`. A firmware header belongs in the
  device's `include/`, not among the web files:

  A target with more to say than a path takes a block instead:

  ```yaml
  targets:
    sprite:
    ttf:  devs/data/icons.ttf
    gfxfont:
      path: devs/include/icons_font.h
      size: 24
  ```

  A list still means what it meant. `fontico:clobber` only removes artifacts
  from `output_dir` — a placed target is pointing somewhere the app owns and
  very likely commits, which is not precompile's business to delete.

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
