# frozen_string_literal: true

# Run me any way you like: `rake test`, or plain `ruby test/fontico_test.rb`.
# Without this the bare `ruby` run resolves `fontico` to whatever version is
# installed as a gem and fails in ways that have nothing to do with the repo.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "fileutils"
# The suite writes manifests directly. Fontico::Manifest is autoloaded, so it
# is the thing that pulls in yaml — and only once some test touches it. Under
# a random order that is not guaranteed, so ask for it here.
require "yaml"
require "fontico"

class ManifestTest < Minitest::Test
  def manifest(data) = Fontico::Manifest.new(data)

  def base(icons)
    { "providers" => { "lucide" => {}, "material-symbols" => {}, "local" => {} },
      "icons" => icons }
  end

  def test_bare_names_use_the_default_provider
    icon = manifest(base("save" => "save")).icons.first
    assert_equal "lucide", icon.provider
    assert_equal "save", icon.slug
  end

  def test_slash_syntax_selects_a_provider
    icon = manifest(base("delete" => "material-symbols/delete")).icons.first
    assert_equal "material-symbols", icon.provider
    assert_equal "delete", icon.slug
  end

  def test_nested_groups_flatten_to_dotted_names
    m = manifest(base("nav" => { "menu" => "lucide/menu" }))
    assert_equal ["nav.menu"], m.icons.map(&:name)
    assert_equal "nav-menu", m.icons.first.key
  end

  def test_undeclared_provider_is_rejected
    err = assert_raises(Fontico::Manifest::Error) { manifest(base("x" => "bogus/x")) }
    assert_match(/undeclared providers: bogus/, err.message)
  end

  def test_remote_icons_are_grouped_for_batching
    m = manifest(base("a" => "lucide/a", "b" => "lucide/b", "c" => "material-symbols/c"))
    assert_equal({ "lucide" => %w[a b], "material-symbols" => %w[c] }, m.remote_by_provider)
  end
end

# Iconify answers a renamed or mirrored icon out of "aliases", not "icons".
# lucide/fingerprint is the live example: renamed to fingerprint-pattern, and
# still the name every app in the wild asks for.
class ResolverAliasTest < Minitest::Test
  def resolve(slug, payload)
    icon = Fontico::Icon.new(name: slug, provider: "lucide", slug: slug)
    Fontico::Resolver.new(nil).send(:remote, icon, payload)
  end

  def payload(icons: {}, aliases: {}, **rest)
    { "icons" => icons, "aliases" => aliases, "width" => 24, "height" => 24 }.merge(rest)
  end

  def test_alias_resolves_to_its_parent_body
    src = resolve("fingerprint", payload(
                    icons: { "fingerprint-pattern" => { "body" => "<path d='M0 0'/>" } },
                    aliases: { "fingerprint" => { "parent" => "fingerprint-pattern" } }
                  ))
    assert_equal "<path d='M0 0'/>", src.markup
  end

  def test_alias_chain_is_followed_to_the_end
    src = resolve("a", payload(
                    icons: { "c" => { "body" => "<path/>" } },
                    aliases: { "a" => { "parent" => "b" }, "b" => { "parent" => "c" } }
                  ))
    assert_equal "<path/>", src.markup
  end

  def test_mirrored_alias_wraps_the_parent_in_the_flip
    src = resolve("arrow-left", payload(
                    icons: { "arrow-right" => { "body" => "<path/>" } },
                    aliases: { "arrow-left" => { "parent" => "arrow-right", "hFlip" => true } }
                  ))
    assert_equal %(<g transform="translate(24.0 0) scale(-1 1)"><path/></g>), src.markup
  end

  def test_rotation_composes_along_the_chain
    src = resolve("a", payload(
                    icons: { "c" => { "body" => "<path/>" } },
                    aliases: { "a" => { "parent" => "b", "rotate" => 1 },
                               "b" => { "parent" => "c", "rotate" => 1 } }
                  ))
    assert_equal %(<g transform="rotate(180 12.0 12.0)"><path/></g>), src.markup
  end

  def test_untransformed_alias_leaves_the_body_alone
    src = resolve("a", payload(icons: { "b" => { "body" => "<path/>" } },
                               aliases: { "a" => { "parent" => "b", "rotate" => 0 } }))
    assert_equal "<path/>", src.markup
  end

  def test_alias_to_nowhere_still_reports_a_miss
    err = assert_raises(Fontico::Resolver::Error) do
      resolve("a", payload(aliases: { "a" => { "parent" => "gone" } }))
    end
    assert_match(%r{lucide/a: not found}, err.message)
  end

  def test_alias_cycle_is_named_rather_than_hung_on
    err = assert_raises(Fontico::Resolver::Error) do
      resolve("a", payload(aliases: { "a" => { "parent" => "b" }, "b" => { "parent" => "a" } }))
    end
    assert_match(/alias cycle a -> b -> a/, err.message)
  end
end

# A manifest is a long list maintained by hand, so one entry is eventually
# going to be wrong. That must cost the one icon, not the build.
class ResolverMissingTest < Minitest::Test
  def manifest(icons)
    Fontico::Manifest.new(
      { "providers" => { "lucide" => {}, "local" => { "path" => "icons" } },
        "icons" => icons }
    )
  end

  def with_icons(files)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      files.each { |name| File.write(File.join(root, "icons", "#{name}.svg"), "<svg><path/></svg>") }
      yield root
    end
  end

  def test_a_local_icon_with_no_file_is_recorded_and_the_rest_resolve
    with_icons(%w[here]) do |root|
      m = manifest("here" => "local/here", "gone" => "local/gone")
      resolver = Fontico::Resolver.new(m, root: root)
      resolved = resolver.call

      assert_equal ["here"], resolved.keys
      assert_match(%r{local/gone: no such file}, resolver.missing.fetch("gone"))
    end
  end

  def test_an_unknown_remote_icon_does_not_take_its_batch_down
    m = manifest("real" => "lucide/real", "typo" => "lucide/typo")
    resolver = Fontico::Resolver.new(m)
    def resolver.fetch(_provider, _slugs)
      { "icons" => { "real" => { "body" => "<path/>" } }, "aliases" => {},
        "width" => 24, "height" => 24 }
    end

    resolved = resolver.call

    assert_equal ["real"], resolved.keys
    assert_match(%r{lucide/typo: not found}, resolver.missing.fetch("typo"))
  end

  def test_an_unreachable_provider_is_still_fatal
    m = manifest("a" => "lucide/a")
    resolver = Fontico::Resolver.new(m, api: "http://127.0.0.1:1")

    assert_raises(Fontico::Resolver::Error) { resolver.call }
  end
end

# The build keeps going, and the artifacts come out without the bad icon.
class BuilderMissingTest < Minitest::Test
  def test_the_sprite_is_written_without_the_missing_icon
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      File.write(File.join(root, "icons", "here.svg"), "<svg viewBox='0 0 24 24'><path d='M0 0'/></svg>")

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"],
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => { "here" => "local/here", "gone" => "local/gone" } }
      )
      report = Fontico::Builder.new(m, root: root, output: "builds").call

      assert_equal ["gone"], report.missing.keys
      assert_equal ["here"], report.fetched

      sprite = File.read(File.join(root, "builds", "icons.svg"))
      assert_includes sprite, %(id="here")
      refute_includes sprite, %(id="gone")
    end
  end

  # An icon that built yesterday and whose entry was broken today must not
  # hand its codepoint to the next icon added — the glyph it names in
  # committed Prawn code would silently become a different picture.
  def test_a_broken_entry_does_not_release_the_codepoint_it_already_holds
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      File.write(File.join(root, "icons", "logo.svg"), "<svg viewBox='0 0 24 24'><path d='M0 0'/></svg>")

      build = lambda do |spec|
        m = Fontico::Manifest.new(
          { "targets" => ["sprite"],
            "providers" => { "local" => { "path" => "icons" } },
            "icons" => { "brand" => spec } }
        )
        Fontico::Builder.new(m, root: root, output: "builds").call
      end

      build.call("local/logo")
      before = YAML.safe_load_file(File.join(root, "icons.lock"))["codepoints"]

      report = build.call("local/logotype") # typo'd on the way in
      after = YAML.safe_load_file(File.join(root, "icons.lock"))

      assert_equal ["brand"], report.missing.keys
      assert_equal before, after["codepoints"]
      assert_empty after["retired"]
    end
  end

  # The lock caches Iconify; a local file is already on disk. Editing it
  # must re-preprocess, or the advertised save-and-refresh loop is a lie.
  def test_editing_a_local_svg_rebuilds_the_body
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      File.write(File.join(root, "icons", "logo.svg"),
                 "<svg viewBox='0 0 24 24'><path d='M0 0'/></svg>")

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"],
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => { "logo" => "local/logo" } }
      )
      Fontico::Builder.new(m, root: root, output: "builds").call
      refute_includes File.read(File.join(root, "builds", "icons.svg")), "M9 9"

      File.write(File.join(root, "icons", "logo.svg"),
                 "<svg viewBox='0 0 24 24'><path d='M9 9'/></svg>")
      Fontico::Builder.new(m, root: root, output: "builds").call
      assert_includes File.read(File.join(root, "builds", "icons.svg")), "M9 9"
    end
  end

  def test_a_cached_remote_builds_offline
    Dir.mktmpdir do |root|
      m = Fontico::Manifest.new(
        { "targets" => ["sprite"],
          "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      lock = Fontico::Lockfile.new(File.join(root, "icons.lock"))
      lock.store("save", source: "lucide/save", body: "<path d='M1 1'/>")
      lock.save!

      report = Fontico::Builder.new(m, root: root, output: "builds", offline: true).call
      assert_equal ["save"], report.cached
      assert_empty report.fetched
      assert_includes File.read(File.join(root, "builds", "icons.svg")), "M1 1"
    end
  end

  # `rake fontico:update` used to delete the lock, which reassigned every
  # codepoint in manifest order. Force re-fetches bodies and leaves them.
  #
  # It takes two icons and a reordered manifest to see this: with one icon
  # the codepoints come out identical either way, so a single-icon version of
  # this test passes against the very bug it names.
  def test_force_keeps_codepoints_when_the_manifest_is_reordered
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      %w[alpha beta].each do |name|
        File.write(File.join(root, "icons", "#{name}.svg"),
                   "<svg viewBox='0 0 24 24'><path d='M0 0'/></svg>")
      end
      base = { "targets" => ["sprite"], "providers" => { "local" => { "path" => "icons" } } }
      ab = Fontico::Manifest.new(base.merge("icons" => { "alpha" => "local/alpha", "beta" => "local/beta" }))
      ba = Fontico::Manifest.new(base.merge("icons" => { "beta" => "local/beta", "alpha" => "local/alpha" }))

      Fontico::Builder.new(ab, root: root, output: "builds").call
      before = YAML.safe_load_file(File.join(root, "icons.lock"))["codepoints"]
      assert_equal({ "alpha" => 0xE001, "beta" => 0xE002 }, before)

      Fontico::Builder.new(ba, root: root, output: "builds", force: true).call
      after = YAML.safe_load_file(File.join(root, "icons.lock"))["codepoints"]

      # Deleting the lock and rebuilding in manifest order swaps these.
      assert_equal before, after
    end
  end

  # The counters answer "did this come off the wire". A local file is re-read
  # on every build, so being stale is not evidence that anything changed.
  def test_an_untouched_local_counts_as_cached_not_fetched
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      path = File.join(root, "icons", "logo.svg")
      File.write(path, "<svg viewBox='0 0 24 24'><path d='M0 0'/></svg>")

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"],
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => { "logo" => "local/logo" } }
      )
      first = Fontico::Builder.new(m, root: root, output: "builds").call
      assert_equal ["logo"], first.fetched, "a brand-new icon is a fetch"

      second = Fontico::Builder.new(m, root: root, output: "builds").call
      assert_equal ["logo"], second.cached
      assert_empty second.fetched

      File.write(path, "<svg viewBox='0 0 24 24'><path d='M9 9'/></svg>")
      third = Fontico::Builder.new(m, root: root, output: "builds").call
      assert_equal ["logo"], third.fetched
      assert_empty third.cached
    end
  end

  def test_force_treats_a_cached_remote_as_stale
    Dir.mktmpdir do |root|
      m = Fontico::Manifest.new(
        { "targets" => ["sprite"],
          "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      lock = Fontico::Lockfile.new(File.join(root, "icons.lock"))
      lock.store("save", source: "lucide/save", body: "<path d='M1 1'/>")
      lock.save!

      err = assert_raises(Fontico::Error) do
        Fontico::Builder.new(m, root: root, output: "builds", offline: true, force: true).call
      end
      # The lock is not missing anything here; force is what made it stale.
      assert_match(/cannot re-fetch 1 icon\(s\) and --offline was given/, err.message)
      refute_match(/missing/, err.message)
    end
  end

  def test_offline_names_the_lock_when_a_body_really_is_absent
    Dir.mktmpdir do |root|
      m = Fontico::Manifest.new(
        { "targets" => ["sprite"],
          "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      err = assert_raises(Fontico::Error) do
        Fontico::Builder.new(m, root: root, output: "builds", offline: true).call
      end
      assert_match(/missing from icons.lock/, err.message)
    end
  end

  # Offline is about the network. A manifest of nothing but local files has
  # no wire to be cut off from.
  def test_a_local_only_manifest_builds_offline
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      File.write(File.join(root, "icons", "logo.svg"),
                 "<svg viewBox='0 0 24 24'><path d='M9 9'/></svg>")

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"],
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => { "logo" => "local/logo" } }
      )
      Fontico::Builder.new(m, root: root, output: "builds", offline: true).call
      assert_includes File.read(File.join(root, "builds", "icons.svg")), "M9 9"
    end
  end
end

class CodepointApiTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    Fontico.root = @dir
    lock = Fontico.lockfile
    lock.store("save", source: "lucide/save", body: "<path/>")
    lock.save!
  end

  def teardown
    Fontico.root = nil
    Fontico.reset!
    FileUtils.remove_entry(@dir)
  end

  def test_known_name_returns_the_pinned_codepoint
    assert_equal 0xE001, Fontico.codepoint("save")
    assert_equal [0xE001].pack("U"), Fontico.glyph("save")
  end

  def test_unknown_name_raises_instead_of_inventing_a_codepoint
    err = assert_raises(Fontico::Error) { Fontico.codepoint("nope") }
    assert_match(/no icon named "nope"/, err.message)
    assert_nil Fontico.lockfile.codepoint_for("nope"), "the raise must not have allocated"
  end
end

class PreprocessorTest < Minitest::Test
  def icon(name = "logo", multicolor: nil)
    Fontico::Icon.new(name: name, provider: "local", slug: name, multicolor: multicolor)
  end

  def run_on(svg, ic = icon) = Fontico::Preprocessor.new(ic).call(svg)

  INKSCAPE = <<~SVG
    <?xml version="1.0"?>
    <svg width="1024" height="1024" viewBox="0 0 270.93333 270.93333"
       xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
       xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd"
       xmlns="http://www.w3.org/2000/svg">
      <sodipodi:namedview id="namedview1" inkscape:zoom="0.19"/>
      <g inkscape:groupmode="layer" id="layer1">
        <path id="path1" fill="#1f2937" d="M0 0h10v10H0Z"/>
      </g>
    </svg>
  SVG

  def test_strips_author_comments
    body = run_on(%(<svg viewBox="0 0 24 24"><!-- where this came from --><path d="M0 0"/></svg>)).body
    refute_includes body, "where this came from"
    assert_includes body, "<path"
  end

  def test_strips_editor_state
    body = run_on(INKSCAPE).body
    refute_includes body, "sodipodi"
    refute_includes body, "inkscape"
    refute_includes body, "namedview"
  end

  def test_namespaces_every_id
    body = run_on(INKSCAPE).body
    assert_includes body, "logo__layer1"
    assert_includes body, "logo__path1"
    refute_match(/id=['"]layer1['"]/, body)
  end

  def test_rewrites_url_references_alongside_ids
    svg = <<~SVG
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <defs><linearGradient id="path1"><stop stop-color="#f00"/><stop stop-color="#00f"/></linearGradient></defs>
        <rect fill="url(#path1)" width="24" height="24"/>
      </svg>
    SVG
    body = run_on(svg).body
    assert_includes body, "url(#logo__path1)"
    refute_includes body, "url(#path1)"
  end

  def test_refits_viewbox_to_the_target_box
    body = run_on(INKSCAPE).body
    # 24 / 270.93333 == 0.0886
    assert_match(/scale\(0\.0886\)/, body)
  end

  # Iconify sends inner markup plus the set's dimensions out of band. Those
  # dimensions are the only record of the grid, so a fragment that ignores
  # them ships cropped: arcticons draws on 48, game-icons on 512.
  def test_fragment_is_refitted_from_its_supplied_dimensions
    frag = %(<path d="M24 46.28c-5.36 0-21.5-3.66-21.5-22.3"/>)
    assert_match(/scale\(0\.5\)/, Fontico::Preprocessor.new(icon).call(frag, width: 48, height: 48).body)
    # 24 / 512 == 0.046875
    assert_match(/scale\(0\.0469\)/, Fontico::Preprocessor.new(icon).call(frag, width: 512, height: 512).body)
  end

  def test_fragment_on_the_target_grid_needs_no_transform
    frag = %(<path d="M0 0h1v1H0Z"/>)
    refute_includes Fontico::Preprocessor.new(icon).call(frag, width: 24, height: 24).body, "transform="
    refute_includes Fontico::Preprocessor.new(icon).call(frag).body, "transform="
  end

  def test_no_transform_when_source_is_already_the_target_box
    svg = %(<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M0 0h1v1H0Z"/></svg>)
    refute_includes run_on(svg).body, "transform="
  end

  def test_folds_single_colour_to_currentcolor
    assert_includes run_on(INKSCAPE).body, "currentColor"
  end

  def test_detects_multicolour_and_leaves_the_palette_alone
    svg = <<~SVG
      <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <rect fill="#5b8def" width="24" height="24"/><path fill="#ffffff" d="M0 0h4v4H0Z"/>
      </svg>
    SVG
    result = run_on(svg)
    assert result.multicolor, "expected two distinct fills to be detected as multicolour"
    assert_includes result.body, "#5b8def"
    refute_includes result.body, "currentColor"
  end

  def test_explicit_multicolour_false_overrides_detection
    svg = %(<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><rect fill="#f00" width="1" height="1"/><rect fill="#00f" width="1" height="1"/></svg>)
    result = Fontico::Preprocessor.new(icon(multicolor: false)).call(svg)
    refute result.multicolor
    assert_includes result.body, "currentColor"
  end

  def test_warns_about_live_text
    svg = %(<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><text x="0" y="0">F</text></svg>)
    assert_match(/live <text>/, run_on(svg).warnings.join)
  end

  def test_drops_scripts_and_event_handlers
    svg = %(<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><rect onload="x()" width="1" height="1"/></svg>)
    body = run_on(svg).body
    refute_includes body, "script"
    refute_includes body, "onload"
  end
end

class LockfileTest < Minitest::Test
  def with_lock
    Dir.mktmpdir do |dir|
      yield Fontico::Lockfile.new(File.join(dir, "icons.lock")), dir
    end
  end

  def test_codepoints_start_in_the_private_use_area
    with_lock { |lock, _| assert_equal 0xE001, lock.allocate("save") }
  end

  # Lookup must not invent a codepoint. Fontico.codepoint / Prawn would
  # otherwise draw a private-use character that maps to nothing.
  def test_codepoint_for_does_not_allocate
    with_lock do |lock, _|
      assert_nil lock.codepoint_for("save")
      lock.allocate("save")
      assert_equal 0xE001, lock.codepoint_for("save")
      assert_nil lock.codepoint_for("other")
    end
  end

  # The reason the lockfile exists: adding an icon must not renumber the rest,
  # or every glyph in a committed font moves on each addition.
  def test_adding_an_icon_does_not_renumber_existing_ones
    with_lock do |lock, dir|
      before = %w[save edit copy].to_h { [_1, lock.allocate(_1)] }
      lock.save!

      reopened = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      reopened.allocate("aaaa-sorts-first")
      after = before.keys.to_h { [_1, reopened.codepoint_for(_1)] }

      assert_equal before, after
    end
  end

  def test_removed_icons_retire_their_codepoint_instead_of_freeing_it
    with_lock do |lock, _|
      gone = lock.allocate("old")
      lock.allocate("kept")
      lock.retire_missing!(["kept"])
      refute_equal gone, lock.allocate("brand-new")
      assert_nil lock.codepoint_for("old")
    end
  end

  def test_warnings_survive_a_reload
    with_lock do |lock, dir|
      lock.store("watermark", source: "local/watermark", body: "<path/>",
                 warnings: ["contains live <text>"])
      lock.save!
      reopened = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      assert_equal ["contains live <text>"], reopened.warnings("watermark")
    end
  end
end

# Real Inkscape exports, not hand-written approximations of them.
class FixtureTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def preprocess(slug)
    icon = Fontico::Icon.new(name: slug, provider: "local", slug: slug, multicolor: nil)
    Fontico::Preprocessor.new(icon)
                         .call(File.read(File.join(ROOT, "test/fixtures/icons/#{slug}.svg")))
  end

  # width="24" but viewBox="0 0 6.35 6.35" — Inkscape's mm document at 96dpi.
  # The viewBox is authoritative; 24 / 6.35 == 3.7795.
  def test_millimetre_document_is_refitted_from_its_viewbox
    assert_match(/scale\(3\.7795\)/, preprocess("inkspace-1").body)
  end

  def test_style_attribute_fill_is_folded
    body = preprocess("inkspace-1").body
    assert_includes body, "fill:currentColor"
    refute_includes body, "#1a1a1a"
  end

  def test_generic_inkscape_ids_are_namespaced
    body = preprocess("inkspace-1").body
    assert_includes body, "inkspace-1__layer1"
    assert_includes body, "inkspace-1__rect1"
  end

  def test_two_exports_sharing_ids_do_not_collide
    logo = preprocess("logo").body
    mark = preprocess("logomark").body
    assert_includes logo, "url(#logo__path1)"
    assert_includes mark, "url(#logomark__path1)"
    assert_empty logo.scan(/id='([^']+)'/).flatten & mark.scan(/id='([^']+)'/).flatten
  end

  def test_gradients_are_kept_as_multicolour
    assert preprocess("logo").multicolor
    assert preprocess("logomark").multicolor
  end

  def test_flat_exports_are_monochrome
    refute preprocess("empty-box").multicolor
    refute preprocess("inkspace-1").multicolor
  end

  def test_live_text_export_is_flagged
    icon = Fontico::Icon.new(name: "live-text", provider: "local", slug: "live-text",
                             multicolor: nil)
    result = Fontico::Preprocessor.new(icon)
                                  .call(File.read(File.join(ROOT, "test/fixtures/live-text.svg")))
    assert_match(/live <text>/, result.warnings.join)
  end

  def test_outlined_export_is_not_flagged
    assert_empty preprocess("watermark").warnings
  end
end

class OutlinerTest < Minitest::Test
  def setup = @outliner = Fontico::Outliner.new

  def icon(provider) = Fontico::Icon.new(name: "x", provider: provider, slug: "x")

  STROKE = %(<g fill="none" stroke="currentColor" stroke-width="2"><path d="M1 1"/></g>)
  STROKE_STYLE = %(<path style="fill:none;stroke:currentColor" d="M1 1"/>)
  FILL = %(<path fill="currentColor" d="M1 1"/>)

  def test_detects_stroke_based_geometry
    assert Fontico::Outliner.stroke_based?(STROKE)
    assert Fontico::Outliner.stroke_based?(STROKE_STYLE)
    refute Fontico::Outliner.stroke_based?(FILL)
  end

  def test_stroke_none_is_not_stroke_based
    refute Fontico::Outliner.stroke_based?(%(<path stroke="none" fill="currentColor" d="M1 1"/>))
  end

  def test_filled_geometry_passes_straight_through
    assert_equal :fill, @outliner.strategy_for(icon("material-symbols"), FILL)
    assert_equal :fill, @outliner.strategy_for(icon("local"), FILL)
  end

  # Lucide ships a font whose glyphs are already expanded, so outlines come
  # from there rather than from a lossy raster trace.
  def test_stroke_based_provider_with_a_font_uses_glyph_extraction
    assert_equal :glyph, @outliner.strategy_for(icon("lucide"), STROKE)
  end

  def test_stroke_based_provider_without_a_font_is_unsupported
    assert_equal :none, @outliner.strategy_for(icon("local"), STROKE)
    assert_equal :none, @outliner.strategy_for(icon("tabler"), STROKE)
  end

  def test_refusal_names_the_icons_and_the_way_out
    err = assert_raises(Fontico::Outliner::Unsupported) do
      @outliner.refuse([Fontico::Icon.new(name: "spinner", provider: "local", slug: "spinner")])
    end
    assert_match(/spinner \(local\/spinner\)/, err.message)
    assert_match(/Stroke to Path/, err.message)
    assert_match(/lucide/, err.message)
  end
end

class FontEmitterTest < Minitest::Test
  def manifest
    Fontico::Manifest.new({
      "providers" => { "lucide" => {}, "local" => {} },
      "targets" => %w[sprite ttf],
      "icons" => { "save" => "lucide/save", "logo" => "local/logo" }
    })
  end

  # Glyphs store no colour at all, so a multicolour icon cannot be represented.
  def test_multicolour_icons_are_excluded_from_the_font
    emitter = Fontico::Emitters::Font.new(manifest, [])
    mono  = Fontico::Icon.new(name: "save", provider: "lucide", slug: "save")
    color = Fontico::Icon.new(name: "logo", provider: "local", slug: "logo", multicolor: true)

    assert emitter.accepts?(mono)
    refute emitter.accepts?(color)
  end

  def test_sprite_accepts_everything_the_font_refuses
    emitter = Fontico::Emitters::Sprite.new(manifest, [])
    color = Fontico::Icon.new(name: "logo", provider: "local", slug: "logo", multicolor: true)
    assert emitter.accepts?(color)
  end

  # A nil codepoint is not caught downstream: it crosses into build_font.mjs
  # as JSON null, and String.fromCodePoint(null) is "\u0000" — no error, just
  # a glyph mapped to NUL. Refuse before the toolchain ever starts. Filled
  # geometry keeps this off the :glyph path, so the test needs no Node.
  def test_an_icon_with_no_codepoint_refuses_to_emit
    Dir.mktmpdir do |dir|
      path = File.join(dir, "icons.lock")
      File.write(path, { "format" => 1, "codepoints" => {}, "retired" => {},
                         "icons" => { "save" => { "body" => "<path d='M1 1' fill='currentColor'/>" } } }.to_yaml)
      lock = Fontico::Lockfile.new(path)
      assert_nil lock.codepoint_for("save"), "the fixture must reproduce the gap"

      icon = Fontico::Icon.new(name: "save", provider: "lucide", slug: "save")
      pairs = [[icon, lock.body("save")]]

      err = assert_raises(Fontico::Error) do
        Fontico::Emitters::Font.new(manifest, pairs, lock: lock, output: File.join(dir, "icons.ttf")).call
      end
      assert_match(/save has no codepoint in icons.lock/, err.message)
      refute_path_exists File.join(dir, "icons.ttf")
    end
  end

  # Emitting must never mint one either: the builder has already save!d the
  # lock by then, so the font would carry a codepoint nothing on disk records.
  def test_refusing_does_not_allocate_behind_the_build
    Dir.mktmpdir do |dir|
      path = File.join(dir, "icons.lock")
      File.write(path, { "format" => 1, "codepoints" => {}, "retired" => {},
                         "icons" => { "save" => { "body" => "<path d='M1 1' fill='currentColor'/>" } } }.to_yaml)
      lock = Fontico::Lockfile.new(path)
      icon = Fontico::Icon.new(name: "save", provider: "lucide", slug: "save")

      assert_raises(Fontico::Error) do
        Fontico::Emitters::Font.new(manifest, [[icon, lock.body("save")]],
                                    lock: lock, output: File.join(dir, "icons.ttf")).call
      end
      assert_nil lock.codepoint_for("save")
    end
  end
end

class HelperTest < Minitest::Test
  class View; include Fontico::Helper; end

  def setup
    Fontico.manifest_path = File.expand_path("fixtures/icons.yml", __dir__)
    Fontico.reset!
    @view = View.new
  end

  def teardown
    Fontico.manifest_path = nil
    Fontico.reset!
  end

  # A glyph inherits font-size; an <svg> has no intrinsic size at all. 1em
  # restores the behaviour so the same markup works at any type size.
  def test_defaults_to_one_em_so_it_scales_with_type
    markup = @view.icon("save")
    assert_includes markup, 'width="1em"'
    assert_includes markup, 'height="1em"'
  end

  def test_carries_the_base_class_alongside_user_classes
    assert_includes @view.icon("save", class: "size-6"), 'class="ico size-6"'
  end

  def test_size_is_overridable
    assert_includes @view.icon("save", size: "2em"), 'width="2em"'
  end

  # icons.css sets .ico { width: 1em }, and a stylesheet rule beats a
  # presentation attribute — so an asked-for size only survives inline.
  def test_explicit_size_is_inline_so_the_stylesheet_cannot_swallow_it
    assert_includes @view.icon("save", size: 16), 'style="width:16px;height:16px"'
    assert_includes @view.icon("save", size: "2em"), 'style="width:2em;height:2em"'
  end

  # ...and with no size asked for, nothing inline, so a utility class wins.
  def test_unsized_icons_stay_class_drivable
    refute_includes @view.icon("save", class: "h-7 w-7"), "style="
  end

  def test_caller_style_is_kept_alongside_the_size
    markup = @view.icon("save", size: 16, style: "opacity:.5")
    assert_includes markup, 'style="width:16px;height:16px;opacity:.5"'
  end

  def test_decorative_by_default_and_labelled_when_titled
    assert_includes @view.icon("save"), 'aria-hidden="true"'
    titled = @view.icon("save", title: "Save file")
    assert_includes titled, 'role="img"'
    assert_includes titled, "<title>Save file</title>"
    refute_includes titled, "aria-hidden"
  end

  def test_references_the_symbol_by_manifest_name
    assert_includes @view.icon("save"), "#save"
  end

  # What a Vue/Stimulus template needs: the digest path and the dotted->dashed
  # key are both things the client should be handed, not rebuild.
  def test_icon_href_is_the_use_target_for_markup_built_elsewhere
    assert_equal "/assets/icons.svg#save", @view.icon_href("save")
    assert_equal "/assets/icons.svg#nav-menu", @view.icon_href("nav.menu")
  end

  def test_icon_href_refuses_a_name_the_manifest_does_not_have
    err = assert_raises(Fontico::Error) { @view.icon_href("nope") }
    assert_match(/no icon named "nope"/, err.message)
  end

  # Payload-building code — a serializer, a job, an ActionCable broadcast —
  # has no view context, and that is exactly where icon_href gets used. The
  # plain fallback only stands when there is no Rails at all.
  def test_icon_href_outside_a_view_still_names_the_sprite
    assert_equal "/assets/icons.svg#save", View.new.icon_href("save")
  end

  def test_icon_href_drops_the_path_in_inline_mode
    Fontico.inline_sprite = true
    assert_equal "#save", @view.icon_href("save")
  ensure
    Fontico.inline_sprite = false
  end
end

class StylesheetTest < Minitest::Test
  def css
    manifest = Fontico::Manifest.new({
      "providers" => { "lucide" => {} }, "icons" => { "save" => "lucide/save" }
    })
    Fontico::Emitters::Stylesheet.new(manifest, []).call
  end

  def test_sizes_to_the_em_and_sits_on_the_baseline
    assert_match(/width:\s*1em/, css)
    assert_match(/vertical-align:\s*-0\.125em/, css)
  end

  # An icon in a flex row gets squashed to zero without this.
  def test_opts_out_of_flex_shrinking
    assert_match(/flex:\s*none/, css)
  end

  def test_contributes_no_icons
    manifest = Fontico::Manifest.new({
      "providers" => { "lucide" => {} }, "icons" => { "save" => "lucide/save" }
    })
    emitter = Fontico::Emitters::Stylesheet.new(manifest, [])
    refute emitter.accepts?(manifest.icons.first)
  end
end

# What the dev reloader exists to undo: the module memoizes the manifest, so
# an edited icons.yml stays invisible to a running process until reset!.
class ManifestMemoTest < Minitest::Test
  def setup
    @dir  = Dir.mktmpdir
    @path = File.join(@dir, "icons.yml")
    write("save" => "lucide/save")
    Fontico.manifest_path = @path
    Fontico.reset!
  end

  def teardown
    Fontico.manifest_path = nil
    Fontico.reset!
    FileUtils.remove_entry(@dir)
  end

  def write(icons)
    File.write(@path, YAML.dump("providers" => { "lucide" => {} }, "icons" => icons))
  end

  def test_an_edited_manifest_is_invisible_until_reset
    assert Fontico.manifest["save"]

    write("save" => "lucide/save", "trash" => "lucide/trash-2")
    assert_nil Fontico.manifest["trash"], "memo should still hold the old manifest"

    Fontico.reset!
    assert Fontico.manifest["trash"], "reset! should re-read icons.yml"
  end

  def test_local_path_falls_back_to_the_documented_default
    assert_equal "app/assets/icons", Fontico.manifest.local_path
    assert_equal Fontico::Manifest::LOCAL_PATH, Fontico.manifest.local_path
  end
end

# Building is forgiving; drawing is not. An icon the build left out still has
# a manifest entry, so the helper would happily render a <use> at a symbol
# that isn't there — an invisible box on a page that 200s.
class RuntimeFailureTest < Minitest::Test
  class View; include Fontico::Helper; end

  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "icons"))
    File.write(File.join(@dir, "icons", "here.svg"), "<svg viewBox='0 0 24 24'><path d='M0 0'/></svg>")
    Fontico.root = @dir
    Fontico.output_dir = "builds"
    write("local" => { "path" => "icons" })
    @view = View.new
  end

  def teardown
    Fontico.root = Fontico.output_dir = Fontico.manifest_path = nil
    Fontico.reset!
    FileUtils.remove_entry(@dir)
  end

  # here.svg exists, gone.svg never did.
  def write(providers)
    File.write(File.join(@dir, "icons.yml"), YAML.dump(
                 "targets" => ["sprite"], "providers" => providers,
                 "icons" => { "here" => "local/here", "gone" => "local/gone" }
               ))
    Fontico.reset!
  end

  def test_an_icon_left_out_of_the_sprite_raises_where_it_is_drawn
    Fontico.rebuild!

    assert_equal ["gone"], Fontico.missing_icons.keys
    assert_nil Fontico.check!("here"), "a built icon must not raise"

    err = assert_raises(Fontico::Error) { @view.icon("gone") }
    assert_match(/left out of the sprite/, err.message)
    assert_match(/no such file/, err.message, "say why, not just that")
  end

  # The other 199 icons keep working — that is the whole reason the build
  # itself does not raise.
  def test_the_icons_that_did_build_still_draw
    Fontico.rebuild!
    assert_includes @view.icon("here"), "#here"
  end

  def test_a_build_that_died_outright_is_raised_at_the_next_icon
    write("bogus" => {}) # every icon now names an undeclared provider
    Fontico.rebuild!

    refute_nil Fontico.build_error
    err = assert_raises(Fontico::Error) { @view.icon("here") }
    assert_match(/did not build/, err.message)
    assert_match(/undeclared providers: local/, err.message)
  end

  def test_the_save_that_fixes_it_clears_the_complaint
    write("bogus" => {})
    Fontico.rebuild!
    refute_nil Fontico.build_error

    write("local" => { "path" => "icons" })
    Fontico.rebuild!

    assert_nil Fontico.build_error
    assert_includes @view.icon("here"), "#here"
  end
end

# Engines ship a floor, the app overlays it. Same load order as I18n.
class ManifestMergeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @engine = File.join(@dir, "engine.yml")
    @app = File.join(@dir, "app.yml")
    File.write(@engine, YAML.dump(
                   "defaults" => { "provider" => "material-symbols" },
                   "targets" => ["sprite"],
                   "providers" => { "material-symbols" => { "license" => "Apache-2.0" },
                                    "simple-icons" => { "license" => "CC0-1.0" },
                                    "lucide" => { "license" => "ISC" } },
                   "icons" => { "add" => "material-symbols/add",
                                "auth" => { "google" => "simple-icons/google",
                                            "facebook" => "simple-icons/facebook" },
                                "fire" => { "painel" => "material-symbols/grid-view-outline" } }
                 ))
    File.write(@app, YAML.dump(
                   "defaults" => { "provider" => "lucide" },
                   "providers" => { "lucide" => { "license" => "ISC" }, "local" => {} },
                   "icons" => { "logo" => "local/logo",
                                "add" => "lucide/plus",
                                "auth" => { "google" => "lucide/chrome" } }
                 ))
    Fontico.load_path = [@engine, @app]
  end

  def teardown
    Fontico.load_path = nil
    Fontico.reset!
    FileUtils.remove_entry(@dir)
  end

  def test_keeps_engine_names_the_app_never_listed
    m = Fontico.manifest
    assert m["fire.painel"]
    assert m["auth.facebook"]
    assert m["logo"]
  end

  def test_the_app_wins_a_name_and_keeps_the_rest_of_the_group
    m = Fontico.manifest
    assert_equal "lucide", m["add"].provider
    assert_equal "plus", m["add"].slug
    assert_equal "chrome", m["auth.google"].slug
    assert m["auth.facebook"], "engine sibling in the group must survive"
  end

  def test_app_defaults_and_providers_layer
    m = Fontico.manifest
    assert_equal "lucide", m.default_provider
    assert m.providers.key?("material-symbols")
    assert m.providers.key?("lucide")
  end

  def test_a_single_file_still_loads
    Fontico.load_path = [@app]
    assert Fontico.manifest["logo"]
    assert_nil Fontico.manifest["fire.painel"]
  end
end

# A sprite can be structurally perfect and still draw 36 blank boxes. No
# assertion catches that — only a pair of eyes — so this one builds the
# fixture manifest for real and leaves a page behind, every icon grouped by
# what this build did to it. Opt-in: it goes to Iconify.
#
#   FONTICO_HTML=1 ruby test/fontico_test.rb -n /preview/ && open tmp/preview/index.html
class SpritePreviewTest < Minitest::Test
  ROOT_DIR = File.expand_path("..", __dir__)
  OUT      = "tmp/preview"

  def test_preview_page_groups_every_icon_by_what_the_build_did
    skip "set FONTICO_HTML=1 — this one fetches from Iconify" unless ENV["FONTICO_HTML"]

    before = digests
    manifest = Fontico::Manifest.load(File.join(ROOT_DIR, "test/fixtures/icons.yml"))
    Fontico::Builder.new(manifest, root: ROOT_DIR, output: OUT).call
    after = digests

    groups = {
      "added"     => after.keys - before.keys,
      "changed"   => after.keys.select { before[_1] && before[_1] != after[_1] },
      "removed"   => before.keys - after.keys,
      "unchanged" => after.keys.select { before[_1] == after[_1] }
    }.transform_values(&:sort)

    page = File.join(ROOT_DIR, OUT, "index.html")
    File.write(page, render(groups))

    drawn = groups.values_at("added", "changed", "unchanged").flatten
    assert_equal manifest.icons.map(&:name).sort, drawn.sort,
                 "every icon in the manifest lands in exactly one group"
    puts "\n  #{page} — #{groups.map { |k, v| "#{v.size} #{k}" }.join(", ")}"
  end

  private

  # The lock is the only record of the previous build. Read it flat: Lockfile
  # answers per name, and this needs the whole set on both sides of a build.
  def digests
    path = File.join(ROOT_DIR, "icons.lock")
    return {} unless File.file?(path)

    (YAML.safe_load_file(path)["icons"] || {}).transform_values { _1["digest"] }
  end

  def render(groups)
    sprite = File.read(File.join(ROOT_DIR, OUT, "icons.svg"))
    sections = groups.reject { |_, names| names.empty? }.map { |label, names| section(label, names) }
    <<~HTML
      <!doctype html><meta charset="utf-8"><title>fontico preview</title>
      <style>
        body { font: 14px system-ui; margin: 2rem; }
        h2 { text-transform: capitalize; border-bottom: 1px solid #ddd; padding-bottom: .3rem; }
        h2 small { color: #888; font-weight: normal; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(7rem, 1fr)); gap: 1rem; }
        figure { margin: 0; text-align: center; }
        figure svg { width: 2rem; height: 2rem; }
        figcaption { color: #666; font-size: 11px; word-break: break-all; }
        .removed figure { opacity: .4; }
        .removed figure::before { content: "—"; display: block; font-size: 2rem; line-height: 2rem; }
      </style>
      <div style="display:none">#{sprite}</div>
      #{sections.join("\n")}
    HTML
  end

  def section(label, names)
    cells = names.map do |name|
      glyph = label == "removed" ? "" : %(<svg><use href="##{name.tr(".", "-")}"/></svg>)
      %(<figure>#{glyph}<figcaption>#{name}</figcaption></figure>)
    end
    %(<h2>#{label} <small>#{names.size}</small></h2>\n<div class="grid #{label}">#{cells.join}</div>)
  end
end
