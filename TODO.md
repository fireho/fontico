# TODO

Shaken out by the first real consumer — migrating [pokes](https://github.com/nofxx/pokes)
off `lucide-rails` (108 call sites, 92 icons, two providers). The ERB side came
out clean; these are what's left, and they cluster on the JS side.

---

## 1. `variant:` is a dead parameter — **priority**

`Fontico::Helper#icon` accepts `variant:` and throws it away.
[lib/fontico/helper.rb:12](lib/fontico/helper.rb#L12) passes it to
`sprite_path(_variant = nil)` ([:82](lib/fontico/helper.rb#L82)), which ignores
the argument entirely. So this silently does nothing:

```erb
<%= icon "game.flag", variant: "solid" %>
```

Accepting an option and discarding it is worse than either implementing it or
refusing it. **At minimum it should raise**; the real fix is to make variants
work, because the first consumer needed them on day one.

### The motivating case

pokes has an outline/solid toggle on two icons — a flag (hand marked) and a
triangle-alert (blunder). Under `lucide-rails` that was one attribute:

```erb
<%= lucide_icon "flag", fill: (flagged ? "currentColor" : "none") %>
```

That worked because lucide-rails puts `fill="none"` on the root `<svg>`, so an
outer `fill` overrides it. Iconify puts `fill="none"` on the **path**, and our
sprite emitter also hardcodes `fill="none"` on the `<symbol>` — so the same
attribute is a no-op with fontico. The toggle would have died silently.

Worked around in pokes with two manifest entries per icon and two hand-written
first-party SVGs (`app/assets/icons/flag-solid.svg`, `alert-solid.svg`) that
duplicate lucide's geometry with `fill="currentColor"`:

```yaml
flag:        lucide/flag
flagged:     local/flag-solid
blunder:     lucide/triangle-alert
blundered:   local/alert-solid
```

It works and it's honest, but it's four manifest lines and two copied path
strings that go stale if lucide redraws either icon. **When variants land,
delete those two local SVGs and collapse the four entries.**

### Design questions to settle first

- **What is a variant?** Three plausible meanings, and they don't want the same
  machinery:
  1. *A different source per variant* — `flag: { outline: lucide/flag, solid: material-symbols/flag }`.
     Pure manifest, no new rendering; probably the honest one.
  2. *A fill transform of the same body* — derive solid from outline by folding
     `fill="none"` → `fill="currentColor"`. Cheap, but only correct for
     stroke-outline sets, and produces nonsense on icons whose inner marks are
     zero-area (the triangle-alert "!" vanishes into the solid body — which is
     what lucide-rails did too, so arguably fine).
  3. *A provider-level style axis* — Material Symbols really does ship
     `outlined`/`rounded`/`sharp` and a `FILL` axis. Iconify exposes these as
     separate set names (`material-symbols` vs `material-symbols-rounded`), so
     this may already be expressible as (1).
- **Where does it live in the artifact?** `sprite_path(variant)` implies one
  sprite file per variant, which is probably wrong — a second `<symbol>` id in
  the *same* sprite (`game-flag--solid`) is cheaper and keeps one request.
  If that's the answer, `variant:` belongs in the fragment, not the path, and
  `sprite_path` should lose the parameter it isn't using.
- **Lockfile impact.** Codepoints are append-only. A variant is a new icon for
  locking purposes; make sure adding one doesn't renumber siblings.

---

## 2. Nothing validates icon names used from JS

In ERB, `icon("typo")` raises in dev ([helper.rb:92](lib/fontico/helper.rb#L92)).
There is no equivalent for names chosen on the client.

`icon_href` (added for pokes' Vue felt) raises on an unknown name, so the
*hand-it-down* route is safe. But the other documented route — putting the
sprite path in a `<meta>` and letting JS build `${sprite}#${name}` — has no
check at all: a typo is a silent empty box, and removing an icon from
`icons.yml` breaks a JS reference with no build error.

pokes compensates in
`spec/system/live_table_spec.rb` with an assertion that the crosshair's `href`
matches `/assets/icons-\w+\.svg#game-aim` — but that's the app doing the lib's
job, and it only covers the one icon someone remembered to pin.

Options: a build-time grep of JS/template sources for sprite references, or a
generated `icons.json` / TS union of valid names the client can import.

---

## 3. The plumbing tax on the JS side

Every icon a JS component wants has to be handed down from Ruby — a prop, a
data attribute, a meta tag. Compare:

```js
import { Target } from 'lucide'                   // data in the bundle
<iconify-icon icon="lucide:target">               // fetched at runtime
```

Fine for one crosshair riding an existing props blob (what pokes does). It gets
old for a component that wants a dozen conditional icons.

The meta-tag route fixes the ergonomics but gives up the typo check from (2) —
those two trade against each other, so settle (2) first.

Not obviously a bug: `<use>` is plain markup the framework owns, so it survives
a Vue/React re-render for free, and switching to `inline_sprite` for a CDN
changes nothing on the client. Worth being deliberate about rather than fixing
reflexively.

---

## Also noted

- `icons_sprite` re-reads the sprite off disk on every call
  ([helper.rb:55](lib/fontico/helper.rb#L55)) — no caching. Only matters in
  `inline_sprite` mode, where it's ~27KB per request.
- `woff2` target still declared-but-skipped (see README Status).
