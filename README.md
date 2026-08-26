# fontico

Name icons by intent. Source them from anywhere. Ship one artifact.

```erb
<%= icon "save" %>      <%# Lucide            %>
<%= icon "delete" %>    <%# Material Symbols  %>
<%= icon "logo" %>      <%# your own SVG file %>
```

Three providers, one call. Templates never name a vendor, so re-skinning the
app — or surviving an upstream rename — is a diff in one file.

## The manifest

`icons.yml`, one line per icon:

```yaml
defaults:
  provider: lucide          # bare names resolve here

targets: [sprite]

providers:
  lucide:           { license: ISC }
  material-symbols: { license: Apache-2.0 }
  local:            { path: app/assets/icons }

icons:
  save:      lucide/save
  delete:    material-symbols/delete
  logo:      local/logo
  nav:
    menu:    lucide/menu     # -> icon("nav.menu")
```

Like pokemon, you gotta catch 'em all.
Any of [Iconify's 200k+ icons](https://icon-sets.iconify.design/) work as a
provider prefix. Your own SVGs go in `app/assets/icons/`, filename as slug.

## Build

```bash
rake fontico:build     # resolve, normalise, emit
rake fontico:update    # re-fetch, ignoring icons.lock
```

Artifacts land in `app/assets/builds/`, which Propshaft serves automatically —
no manifest, no precompile list. `rake assets:precompile` is hooked, so deploys
need no extra step.

That directory is gitignored in a stock Rails app, so nothing is committed from
it. **`icons.lock` is the thing you commit**: it holds every normalised body,
so a deploy rebuilds the sprite from it in milliseconds with no network access
and no Node.

In development you rarely type either one. Saving `icons.yml` — or a local
SVG — rebuilds the artifacts and drops the cached manifest, so the icon is live
on the next request: no rake, no restart. A save that only reshuffles known
icons costs a couple of milliseconds; a brand-new one pays its provider fetch
once, then it is in the lock.

A rebuild never raises — building stays as forgiving as the rake task, so a
half-typed manifest does not take down a page that draws none of the broken
icons. The pages that *do* draw them raise instead, at the call site, and keep
raising until a save fixes it. That is deliberate: an icon left out of the
sprite still resolves through the manifest and renders a valid `<use>` at a
symbol that isn't there, which in a browser is an invisible empty box on a page
that returns 200. Silence is the one outcome worse than a stack trace.

An icon that cannot be resolved — a typo'd slug, a local file that isn't
there — is named in red and left out; the rest of the manifest still builds.
It keeps its codepoint reserved, so fixing the entry and rebuilding brings it
back with the same glyph. A provider that is unreachable is still fatal.

Measured on 35 icons across two remote providers and five local files:
**361ms cold, 2ms warm.** Vendor icons are fetched in one batched request per
provider — not one per icon.

## Why there is a lockfile

`icons.lock` pins two things that must not drift:

- **Codepoints**, append-only. Adding an icon must not renumber the others, or
  every glyph in a built font moves and the committed artifact churns
  whole-file on each addition. Retired codepoints are never reissued.
- **Normalised bodies**, so builds are reproducible and run offline. The
  Iconify API serves *latest*; without this an icon can silently change shape
  between two builds of the same manifest.

Commit it.

## What happens to your SVGs

First-party exports are not uniform the way vendor icons are, so everything
entering `app/assets/icons/` is normalised first:

| | |
| --- | --- |
| Editor chrome | `sodipodi:`, `inkscape:`, `<metadata>`, RDF, empty `<defs>` stripped |
| Ids | rewritten to `slug__id`, with `url(#…)`, `href`, `clip-path`, `mask` following |
| viewBox | any source box refitted into the target, centred, aspect preserved |
| Colour | folded to `currentColor`, unless the icon is detected as multicolour |
| Safety | `<script>`, `on*` handlers, `<foreignObject>`, external refs removed |

The id rewriting is not optional hygiene. Across 40 SVGs sampled from a real
machine, **34 shared `id="layer1"`** and 11 shared `id="path1"` — merging any
two of them into one document silently drops a definition.

Four things cannot be fixed downstream and are reported against the source
file: live `<text>`, embedded raster `<image>`, multicolour in a font target,
and `<filter>` effects. See **[docs/icon-authoring.html](docs/icon-authoring.html)**
for the full authoring spec.

## Making an `<svg>` behave like a glyph

A font glyph inherits `font-size` and `color` from the text around it. An
`<svg>` has no intrinsic size and sits on the baseline's bottom edge, so the
sprite needs a little help to match. `rake fontico:build` emits `icons.css`
alongside the sprite whenever `sprite` is a target:

```css
.ico { display:inline-block; width:1em; height:1em; vertical-align:-0.125em; flex:none; }
```

The helper defaults to `width="1em" height="1em"`, so the same markup scales
with whatever type it sits in, and a CSS class still wins over the attributes:

```erb
<%= icon "save" %>                      <%# 1em, follows font-size          %>
<%= icon "save", size: 18 %>            <%# a bare number means px          %>
<%= icon "save", size: "2em" %>
<%= icon "save", class: "size-6" %>     <%# Tailwind overrides the attrs    %>
<%= icon "save", title: "Save file" %>  <%# role="img" + <title>, not hidden %>
```

The two sizing routes do not fight. `width`/`height` on an `<svg>` are
presentation attributes, and *any* CSS declaration outranks them — including
`icons.css`'s own `.ico { width: 1em }`. So an explicit `size:` is written
inline, where it beats the stylesheet, while an icon with no `size:` carries
only the attributes and stays free for `class: "size-6"` to size instead. Ask
for one or the other, not both.

Colour needs no help: bodies are folded to `currentColor`. That is not a
convenience — host CSS does **not** cascade into a cross-document `<use>`, but
inherited properties like `color` do reach it, so `currentColor` is the only
thing that makes an external sprite themeable.

`flex:none` matters more than it looks: an icon in a flex row gets squashed to
zero width without it.

### Same-origin

Cross-document `<use>` is subject to same-origin. If `asset_host` points at a
CDN the sprite silently renders nothing — reserved space, no icon. Serve the
sprite same-origin, or switch to inline mode:

```ruby
Fontico.inline_sprite = true   # then <%= icons_sprite %> in your layout
```

## Fonts, and Prawn

The `ttf` target exists for **PDF generation**, not the web — Prawn reads
TTF/OTF through ttfunk and cannot read woff2, and on the web the sprite is both
smaller over the wire (2.3KB brotli vs ~6KB woff2 here) and not render-blocking.

```ruby
require "fontico/prawn"

Prawn::Document.generate("invoice.pdf") do |pdf|
  pdf.fontico!                              # register the family once
  pdf.icon "save", size: 18
  pdf.icon_at "mail", at: [40, 700], size: 24
  pdf.text "#{Fontico.glyph("confirm")} done"
end
```

`Fontico.codepoint("save")` and `Fontico.glyph("save")` expose the pinned
codepoint, so nothing gets hardcoded.

### Where outlines come from

A font glyph is filled contours; it has no strokes and no colour. Each icon
takes one of three routes:

| | |
| --- | --- |
| **filled** | used as-is — Material Symbols, most Iconify sets, flat first-party exports |
| **extracted** | stroke-based, but the provider ships a font whose glyphs are already expanded — lifted from there, losslessly (Lucide) |
| **refused** | stroke-based with no provider font — the build stops and names the icon |

There is deliberately no raster-trace fallback. Both published JS expanders
(`svg-outline-stroke`, `oslllo-svg-fixer`) run artwork through potrace and hand
back rounded corners and wobbling stems. Refusing beats shipping geometry that
quietly stopped matching the sprite. Outline strokes at source instead — the
build message says so, by icon name.

Multicolour icons cannot be glyphs at all, so they stay in the sprite and the
build names each one it dropped.

### Toolchain

Font targets need Node, installed on demand into `~/.cache/fontico`. A manifest
with `targets: [sprite]` never touches it and stays pure Ruby.

## Status

- ✅ Manifest, resolver, preprocessor, lockfile, sprite emitter, Rails helper
- ✅ TTF emitter with glyph extraction, codepoint API, Prawn helpers
- ⏳ `woff2` — declared targets are skipped with a notice

## License

MIT
