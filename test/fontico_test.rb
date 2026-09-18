# frozen_string_literal: true

# Run me any way you like: `rake test`, or plain `ruby test/fontico_test.rb`.
# Without this the bare `ruby` run resolves `fontico` to whatever version is
# installed as a gem and fails in ways that have nothing to do with the repo.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
# The suite writes manifests directly. Fontico::Manifest is autoloaded, so it
# is the thing that pulls in yaml — and only once some test touches it. Under
# a random order that is not guaranteed, so ask for it here.
require "yaml"
require "ttfunk"
require "fontico"

# Builder constructs its own Resolver, so a test that needs to see what came
# off the wire has to intercept at the class. Prepended once, and inert
# unless a test sets an override, so a random order cannot leave a stub
# behind. Tests that own their Resolver keep defining a singleton `fetch` —
# the singleton class is ahead of this in the lookup, so it still wins.
module StubbableFetch
  def fetch(provider, slugs)
    stub = Thread.current[:fontico_fetch_stub]
    stub ? stub.call(provider, slugs) : super
  end
  private :fetch
end
Fontico::Resolver.prepend(StubbableFetch)

module FetchStubbing
  def with_stubbed_fetch(builder, &blk)
    Thread.current[:fontico_fetch_stub] = ->(_provider, slugs) { blk.call(slugs) }
    builder.call
  ensure
    Thread.current[:fontico_fetch_stub] = nil
  end
end

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
  include FetchStubbing

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
      # size has to match the manifest's or the body is stale, by design.
      lock.store("save", source: "lucide/save", body: "<path d='M1 1'/>", size: 24)
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

  # The body carries its refit baked in as a <g transform>, but the sprite
  # emitter reads the target size live. Keyed on the source alone, changing
  # `defaults: size:` moved the <symbol> to the new viewBox and left the
  # geometry inside it fit to the old grid — every icon a fraction of its
  # size in the corner of its box, on a page that 200s.
  #
  # It takes a *remote* to see this. Local files are re-read every build and
  # refit on the way through, so they self-heal; a local-only version of this
  # test passes against the very bug it names.
  def test_changing_the_target_size_refits_a_cached_remote
    Dir.mktmpdir do |root|
      lock = Fontico::Lockfile.new(File.join(root, "icons.lock"))
      lock.store("save", source: "lucide/save", size: 24,
                 body: %(<g transform="scale(0.5)"><path d="M0 0h48v48H0Z"/></g>))
      lock.save!

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"], "defaults" => { "size" => 96 },
          "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      # The only way to refit is from the original geometry, which the lock
      # does not keep — so the icon has to come back off the wire.
      asked_for = nil
      report = with_stubbed_fetch(Fontico::Builder.new(m, root: root, output: "builds")) do |slugs|
        asked_for = slugs
        { "icons" => { "save" => { "body" => %(<path d="M0 0h48v48H0Z"/>) } },
          "aliases" => {}, "width" => 48, "height" => 48 }
      end

      assert_equal ["save"], asked_for, "a resize must re-resolve, not reuse"
      assert_equal ["save"], report.fetched
      assert_empty report.cached

      sprite = File.read(File.join(root, "builds", "icons.svg"))
      assert_includes sprite, %(viewBox="0 0 96 96"), "the symbol moves to the new grid"
      assert_includes sprite, "scale(2)", "and the geometry inside moves with it"
      refute_includes sprite, "scale(0.5)", "the body refit for the old grid must be gone"
    end
  end

  # A lock from before sizes were recorded cannot say what grid it was built
  # on. Calling it stale would re-fetch a whole manifest on a gem upgrade and
  # put a network round trip in the first deploy after it, so it is taken at
  # the manifest's word once and stamped.
  def test_a_lock_without_recorded_sizes_is_taken_at_its_word
    Dir.mktmpdir do |root|
      path = File.join(root, "icons.lock")
      File.write(path, { "format" => 1, "codepoints" => { "save" => 0xE001 }, "retired" => {},
                         "icons" => { "save" => { "source" => "lucide/save",
                                                  "multicolor" => false,
                                                  "body" => "<path d='M1 1'/>" } } }.to_yaml)

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"], "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      report = Fontico::Builder.new(m, root: root, output: "builds", offline: true).call

      assert_equal ["save"], report.cached, "an upgrade must not re-fetch"
      assert_equal 24, YAML.safe_load_file(path)["icons"]["save"]["size"],
                   "and the assumption gets written down, so the next change is caught"
    end
  end

  # Same class of bug as the size one: the manifest's multicolor override is
  # an input to the body, so flipping it has to re-preprocess. Keyed on the
  # source alone, the body stayed folded to currentColor and the font emitter
  # kept accepting an icon the author had just declared unrepresentable.
  def test_flipping_the_multicolor_override_invalidates_the_body
    Dir.mktmpdir do |root|
      lock = Fontico::Lockfile.new(File.join(root, "icons.lock"))
      lock.store("brand", source: "lucide/brand", size: 24, multicolor: false,
                 body: %(<path fill="currentColor" d="M0 0"/>))
      lock.save!

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"], "providers" => { "lucide" => {} },
          "icons" => { "brand" => { "icon" => "lucide/brand", "multicolor" => true } } }
      )
      report = with_stubbed_fetch(Fontico::Builder.new(m, root: root, output: "builds")) do |_slugs|
        { "icons" => { "brand" => { "body" => %(<path fill="#5b8def" d="M0 0"/>) } },
          "aliases" => {}, "width" => 24, "height" => 24 }
      end

      assert_equal ["brand"], report.fetched
      assert YAML.safe_load_file(File.join(root, "icons.lock"))["icons"]["brand"]["multicolor"],
             "the override has to reach the lock"
      assert_includes File.read(File.join(root, "builds", "icons.svg")), "#5b8def",
                      "and the palette has to survive into the sprite"
    end
  end

  # An unchanged manifest must still be a no-op, or the two tests above would
  # pass just as well against a lock that never caches anything.
  def test_an_unchanged_size_still_counts_as_cached
    Dir.mktmpdir do |root|
      lock = Fontico::Lockfile.new(File.join(root, "icons.lock"))
      lock.store("save", source: "lucide/save", body: "<path d='M1 1'/>", size: 48)
      lock.save!

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"], "defaults" => { "size" => 48 },
          "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      report = Fontico::Builder.new(m, root: root, output: "builds", offline: true).call
      assert_equal ["save"], report.cached
      assert_empty report.fetched
    end
  end

  # Offline used to blame icons.lock for everything. The bodies are all
  # present here; the size is what invalidated them, and there is nothing on
  # disk to refit from, so say that instead.
  def test_offline_names_the_resize_rather_than_blaming_the_lock
    Dir.mktmpdir do |root|
      lock = Fontico::Lockfile.new(File.join(root, "icons.lock"))
      lock.store("save", source: "lucide/save", body: "<path d='M1 1'/>", size: 24)
      lock.save!

      m = Fontico::Manifest.new(
        { "targets" => ["sprite"], "defaults" => { "size" => 96 },
          "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      err = assert_raises(Fontico::Error) do
        Fontico::Builder.new(m, root: root, output: "builds", offline: true).call
      end
      assert_match(/re-preprocess 1 icon\(s\) at size: 96/, err.message)
      refute_match(/missing/, err.message)
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
      lock.store("save", source: "lucide/save", body: "<path d='M1 1'/>", size: 24)
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
    lock.store("save", source: "lucide/save", body: "<path/>", size: 24)
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
      lock.store("watermark", source: "local/watermark", body: "<path/>", size: 24,
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

# A C header naming icons for firmware. Verified against a real compiler in
# test/c/ — these cover the generation side: the mangling, the byte values,
# and the invariants the device silently depends on.
class HeaderEmitterTest < Minitest::Test
  def build(icons, multicolor: {})
    m = Fontico::Manifest.new(
      { "targets" => { "c" => nil }, "providers" => { "lucide" => {}, "local" => {} },
        "icons" => icons }
    )
    Dir.mktmpdir do |dir|
      lock = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      m.icons.each do |icon|
        lock.store(icon.name, source: icon.source, body: "<path/>", size: 24,
                   multicolor: multicolor.fetch(icon.name, false))
      end
      pairs = m.icons.select { Fontico::Emitters::Header.new(m, [], lock: lock).accepts?(_1) }
                     .map { [_1, "<path/>"] }
      yield Fontico::Emitters::Header.new(m, pairs, lock: lock), lock
    end
  end

  def header(icons, multicolor: {})
    out = nil
    build(icons, multicolor: multicolor) { |e, _| out = e.call }
    out
  end

  def test_dotted_and_dashed_names_become_c_identifiers
    h = header({ "save" => "lucide/save", "nav" => { "menu" => "lucide/menu" },
                 "empty-box" => "lucide/box" })

    assert_includes h, "#define ICON_SAVE "
    assert_includes h, "#define ICON_NAV_MENU "
    assert_includes h, "#define ICON_EMPTY_BOX "
  end

  # The device does no parsing and no String building: the bytes are decided
  # here. U+E001 is EE 80 81, and every byte is a \x escape, so C's greedy hex
  # escapes have nothing extra to swallow.
  def test_codepoints_are_emitted_as_utf8_escapes
    assert_equal "\\xEE\\x80\\x81", Fontico::Emitters::Header.utf8_literal(0xE001)
    assert_equal "\\xEF\\xA3\\xBF", Fontico::Emitters::Header.utf8_literal(0xF8FF)
    assert_includes header({ "save" => "lucide/save" }), %(#define ICON_SAVE "\\xEE\\x80\\x81")
  end

  # The escapes have to say the same thing Ruby would, or the glyph the device
  # draws is not the glyph the sprite draws.
  def test_the_escapes_decode_back_to_the_pinned_codepoint
    literal = Fontico::Emitters::Header.utf8_literal(0xE00A)
    bytes = literal.scan(/\\x(\h\h)/).flatten.map { _1.to_i(16) }
    assert_equal 0xE00A, bytes.pack("C*").force_encoding("UTF-8").ord
  end

  # The header is a map into icons.ttf. If it named a codepoint the font has no
  # glyph for, the device would draw an invisible box on a screen nobody is
  # watching over the wire.
  def test_codepoints_agree_with_the_lockfile
    build({ "save" => "lucide/save", "wifi" => "lucide/wifi" }) do |emitter, lock|
      out = emitter.call
      %w[save wifi].each do |name|
        cp = lock.codepoint_for(name)
        assert_includes out, format("U+%04X", cp)
        assert_includes out, format("0x%04X", cp)
      end
    end
  end

  # C takes the second #define of a macro and says nothing.
  def test_names_that_collide_as_identifiers_are_refused
    err = assert_raises(Fontico::Error) do
      header({ "nav" => { "menu" => "lucide/menu" }, "nav-menu" => "lucide/menu" })
    end
    assert_match(/collide as C identifiers/, err.message)
    assert_match(/ICON_NAV_MENU/, err.message)
    assert_match(/nav\.menu/, err.message)
    assert_match(/nav-menu/, err.message)
  end

  # Sorted here with Ruby's <=>, searched there with strcmp. A byte over 0x7F
  # orders the other way under a signed char, so bsearch would miss it.
  def test_non_ascii_names_are_refused
    err = assert_raises(Fontico::Error) { header({ "café" => "lucide/coffee" }) }
    assert_match(/needs ASCII icon names/, err.message)
    assert_match(/café/, err.message)
  end

  # bsearch is only legal on a sorted table.
  def test_the_lookup_table_is_sorted_by_name
    h = header({ "wifi" => "lucide/wifi", "alpha" => "lucide/a", "mid" => "lucide/m" })
    names = h.scan(/^\s+\{ "([^"]+)",/).flatten

    refute_empty names
    assert_equal names.sort, names
  end

  def test_the_count_matches_the_table
    h = header({ "a" => "lucide/a", "b" => "lucide/b", "c" => "lucide/c" })
    assert_includes h, "#define FONTICO_ICON_COUNT 3"
    assert_equal 3, h.scan(/^\s+\{ "/).size
  end

  # A glyph stores no colour, so the font drops multicolour icons — and a
  # header naming one would point at a codepoint with nothing behind it.
  def test_multicolour_icons_are_left_out_like_the_font_leaves_them_out
    h = header({ "flat" => "lucide/flat", "brand" => "local/brand" },
               multicolor: { "brand" => true })

    assert_includes h, "ICON_FLAT"
    refute_includes h, "ICON_BRAND"
    assert_includes h, "#define FONTICO_ICON_COUNT 1"
  end

  # Emitting must never mint a codepoint: the builder has already save!d the
  # lock, so one invented here would reach the firmware without reaching disk.
  def test_an_icon_with_no_codepoint_refuses_to_emit
    m = Fontico::Manifest.new(
      { "targets" => { "c" => nil }, "providers" => { "lucide" => {} },
        "icons" => { "save" => "lucide/save" } }
    )
    Dir.mktmpdir do |dir|
      lock = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      err = assert_raises(Fontico::Error) do
        Fontico::Emitters::Header.new(m, [[m.icons.first, "<path/>"]], lock: lock).call
      end
      assert_match(/save has no codepoint in icons.lock/, err.message)
      assert_nil lock.codepoint_for("save"), "the raise must not have allocated"
    end
  end

  def test_the_header_is_include_guarded_and_c_plus_plus_safe
    h = header({ "save" => "lucide/save" })
    assert_includes h, "#ifndef FONTICO_ICONS_H"
    assert_includes h, %(extern "C")
    # One translation unit owns the table; the rest link against it.
    assert_includes h, "#ifdef FONTICO_ICONS_IMPLEMENTATION"
    assert_includes h, "extern const FonticoIcon fontico_icons"
  end
end

# The header can be structurally perfect and still not compile, and the
# device is the last place you want to find that out. So this one runs a real
# compiler over it: two translation units, -Werror, and it checks the bytes
# and the lookup at runtime. Skipped where there is no cc.
class HeaderCompilesTest < Minitest::Test
  ICONS = { "save" => "lucide/save", "nav" => { "menu" => "lucide/menu" },
            "empty-box" => "lucide/box", "wifi" => "lucide/wifi" }.freeze

  # Deliberately not a bare `assert`: the point is to exercise the generated
  # header the way firmware does, including the implementation guard.
  MAIN = <<~'CSRC'
    #define FONTICO_ICONS_IMPLEMENTATION
    #include "icons.h"
    #include <stdio.h>
    #include <string.h>

    const char *other_lookup(const char *name);
    static int fails = 0;

    static void want(const char *what, const char *got, const char *expected) {
      if (got && strcmp(got, expected) == 0) return;
      printf("FAIL %s\n", what);
      fails++;
    }

    int main(void) {
      int i;
      /* Compile-time UTF-8: three bytes, no parsing, no heap. */
      want("ICON_SAVE bytes", ICON_SAVE, "\xEE\x80\x81");
      want("ICON_NAV_MENU bytes", ICON_NAV_MENU, "\xEE\x80\x82");
      if (strlen(ICON_SAVE) != 3) { printf("FAIL ICON_SAVE length\n"); fails++; }

      /* Runtime lookup, for a name arriving over the wire. */
      want("lookup save", fontico_icon("save"), ICON_SAVE);
      want("lookup nav.menu", fontico_icon("nav.menu"), ICON_NAV_MENU);
      want("lookup empty-box", fontico_icon("empty-box"), ICON_EMPTY_BOX);

      /* bsearch must find every entry, or some icons are silently invisible. */
      for (i = 0; i < FONTICO_ICON_COUNT; i++) {
        if (fontico_icon(fontico_icons[i].name) != fontico_icons[i].utf8) {
          printf("FAIL bsearch missed %s\n", fontico_icons[i].name);
          fails++;
        }
      }
      /* ...which is only legal because the table is sorted. */
      for (i = 1; i < FONTICO_ICON_COUNT; i++) {
        if (strcmp(fontico_icons[i - 1].name, fontico_icons[i].name) >= 0) {
          printf("FAIL table unsorted\n");
          fails++;
        }
      }

      /* An unknown name is NULL, never a wrong glyph. */
      if (fontico_icon("nope") != NULL) { printf("FAIL unknown name\n"); fails++; }
      if (fontico_icon(NULL) != NULL) { printf("FAIL null name\n"); fails++; }

      /* The other unit links against this table rather than copying it. */
      if (other_lookup("save") != fontico_icon("save")) {
        printf("FAIL second translation unit has its own table\n");
        fails++;
      }
      return fails;
    }
  CSRC

  OTHER = <<~'CSRC'
    #include "icons.h"
    const char *other_lookup(const char *name) { return fontico_icon(name); }
  CSRC

  def cc
    @cc ||= ENV["CC"] || %w[cc gcc clang].find { |c| Open3.capture3("command", "-v", c)[2].success? }
  end

  def compile(dir, *sources, out: "t")
    Open3.capture3(cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-o", out, *sources, chdir: dir)
  end

  def test_the_generated_header_compiles_and_behaves
    skip "no C compiler on PATH" unless cc

    Dir.mktmpdir do |dir|
      m = Fontico::Manifest.new(
        { "targets" => { "c" => nil }, "providers" => { "lucide" => {} }, "icons" => ICONS }
      )
      lock = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      m.icons.each { lock.store(_1.name, source: _1.source, body: "<path/>", size: 24) }

      File.write(File.join(dir, "icons.h"),
                 Fontico::Emitters::Header.new(m, m.icons.map { [_1, "<path/>"] }, lock: lock).call)
      File.write(File.join(dir, "main.c"), MAIN)
      File.write(File.join(dir, "other.c"), OTHER)

      _, err, status = compile(dir, "main.c", "other.c")
      assert_predicate status, :success?, "the header did not compile:\n#{err}"

      ran, _, status = Open3.capture3("./t", chdir: dir)
      assert_predicate status, :success?, "the compiled header misbehaved:\n#{ran}"
    end
  end

  # Two units both claiming the table has to fail at the linker, not quietly
  # ship two copies of it into a flash budget that cannot afford them.
  def test_two_implementations_refuse_to_link
    skip "no C compiler on PATH" unless cc

    Dir.mktmpdir do |dir|
      m = Fontico::Manifest.new(
        { "targets" => { "c" => nil }, "providers" => { "lucide" => {} },
          "icons" => { "save" => "lucide/save" } }
      )
      lock = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      m.icons.each { lock.store(_1.name, source: _1.source, body: "<path/>", size: 24) }
      File.write(File.join(dir, "icons.h"),
                 Fontico::Emitters::Header.new(m, m.icons.map { [_1, "<path/>"] }, lock: lock).call)

      impl = "#define FONTICO_ICONS_IMPLEMENTATION\n#include \"icons.h\"\n"
      File.write(File.join(dir, "a.c"), "#{impl}int main(void) { return 0; }\n")
      File.write(File.join(dir, "b.c"), "#{impl}const char *b(void) { return fontico_icon(\"save\"); }\n")

      _, err, status = compile(dir, "a.c", "b.c")
      refute_predicate status, :success?, "two implementations linked, so the table was duplicated"
      assert_match(/duplicate/i, err)
    end
  end
end

# A GFXfont: icons as 1-bit bitmaps compiled into the binary, for a display
# driven by Adafruit_GFX or Arduino_GFX. No font renderer and no filesystem on
# the device, which is the whole point of it over the TTF target.
class GfxFontTest < Minitest::Test
  def node? = Fontico::NodeRunner.new.available?

  # Rasterised from the TTF, so this builds one and reads it back.
  def build(svgs, size: 24, targets: nil)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      svgs.each { |name, body| File.write(File.join(root, "icons", "#{name}.svg"), body) }

      m = Fontico::Manifest.new(
        { "targets" => targets || { "ttf" => nil, "gfxfont" => { "size" => size } },
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => svgs.keys.to_h { [_1, "local/#{_1}"] } }
      )
      yield Fontico::Builder.new(m, root: root, output: "builds"), root, m
    end
  end

  def square(inset = 0)
    "<svg viewBox='0 0 24 24'><path d='M#{inset} #{inset}h#{24 - 2 * inset}v#{24 - 2 * inset}" \
      "H#{inset}z' fill='#000'/></svg>"
  end

  # Unpack the emitted C back into pixels. If the packing is wrong — row
  # padding, bit order, offsets — a known shape is where it shows.
  def unpack(header, name)
    bytes = header[/_bitmaps\[\] PROGMEM = \{(.*?)\};/m, 1].scan(/0x(\h\h)/).flatten.map { _1.to_i(16) }
    row = header[/\{\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(-?\d+),\s*(-?\d+)\s*\}, \/\* #{Regexp.escape(name)} \*\//]
    off, w, h = row.scan(/-?\d+/).first(3).map(&:to_i)
    rows = (0...h).map do |y|
      (0...w).map { |x| bit = y * w + x; (bytes[off + bit / 8] >> (7 - bit % 8)) & 1 }
    end
    { width: w, height: h, rows: rows }
  end

  # A filled square fills its box. That one shape catches bit order, row
  # padding and a transposed axis all at once.
  def test_a_solid_square_rasterises_solid
    skip "needs Node" unless node?

    build({ "block" => square }) do |builder, root, _|
      builder.call
      g = unpack(File.read(File.join(root, "builds", "icons_font.h")), "block")

      assert_operator g[:width], :>=, 20, "a full-em square should be about the em wide"
      assert_operator g[:height], :>=, 20
      assert(g[:rows].all? { |r| r.all?(1) },
             "every pixel inside a filled square should be set:\n" \
             "#{g[:rows].map { |r| r.map { _1 == 1 ? "#" : "." }.join }.join("\n")}")
    end
  end

  # The hole in a ring has to stay a hole. Even-odd and nonzero disagree
  # exactly here, and a gear or a wifi arc is nothing but this case.
  def test_a_ring_keeps_its_hole
    skip "needs Node" unless node?

    # One path, one colour, two subpaths wound in opposite directions — which
    # is how a real icon punches a hole, and the only thing nonzero winding
    # reads differently from even-odd.
    ring = "<svg viewBox='0 0 24 24'><path d='M0 0h24v24H0z M8 8v8h8V8z' fill='#000'/></svg>"
    build({ "ring" => ring }) do |builder, root, _|
      builder.call
      g = unpack(File.read(File.join(root, "builds", "icons_font.h")), "ring")
      centre = g[:rows][g[:height] / 2][g[:width] / 2]

      assert_equal 0, centre, "the middle of a ring should be unset:\n" \
                              "#{g[:rows].map { |r| r.map { _1 == 1 ? "#" : "." }.join }.join("\n")}"
      assert_equal 1, g[:rows][0][0], "but the outside should still be filled"
    end
  end

  # Char codes are positional, so their order has to come from something that
  # only ever appends. The lockfile codepoints do; manifest order does not.
  def test_char_codes_follow_the_append_only_codepoint_order
    skip "needs Node" unless node?

    build({ "aaa" => square, "bbb" => square(2), "ccc" => square(4) }) do |builder, root, _|
      builder.call
      header = File.read(File.join(root, "builds", "icons_font.h"))
      lock = Fontico::Lockfile.new(File.join(root, "icons.lock"))

      codes = header.scan(/^#define ICON_(\w+)\s+0x(\h\h)/).to_h { [_1.downcase, _2.to_i(16)] }
      by_lock = codes.keys.sort_by { lock.codepoint_for(_1) }

      assert_equal by_lock, codes.keys.sort_by { codes[_1] }
      assert_equal 0x20, codes.values.min, "the range starts past the control characters"
    end
  end

  def test_the_emitted_font_declares_the_range_it_fills
    skip "needs Node" unless node?

    build({ "a" => square, "b" => square(2) }) do |builder, root, _|
      builder.call
      header = File.read(File.join(root, "builds", "icons_font.h"))

      assert_match(/0x20, 0x21, \d+/, header, "first/last should span exactly the two icons")
      assert_includes header, "#ifndef _GFXFONT_H_" # yields to the real library
      assert_includes header, "static const GFXfont fontico_icons24"
    end
  end

  # A GFXfont is indexed off a byte. Failing here beats emitting a font that
  # quietly stops at icon 224.
  def test_too_many_icons_for_a_byte_is_refused
    m = Fontico::Manifest.new(
      { "targets" => { "gfxfont" => nil }, "providers" => { "local" => {} },
        "icons" => (1..300).to_h { ["i#{_1}", "local/i#{_1}"] } }
    )
    Dir.mktmpdir do |dir|
      lock = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      m.icons.each { lock.store(_1.name, source: _1.source, body: "<path/>", size: 24) }

      err = assert_raises(Fontico::Error) do
        Fontico::Emitters::GfxFont.new(m, m.icons.map { [_1, "<path/>"] }, lock: lock).call
      end
      assert_match(/holds 224 icons/, err.message)
      assert_match(/300/, err.message)
      assert_match(/c target instead/, err.message, "should point at the target that has no such limit")
    end
  end

  # Thin strokes fall through a one-bit threshold. Silence would mean an icon
  # that draws as nothing at all.
  def test_an_icon_that_rasterises_blank_is_refused
    skip "needs Node" unless node?

    # Filled, so the outliner is happy with it, but far too thin to survive a
    # one-bit threshold once scaled down.
    hairline = "<svg viewBox='0 0 24 24'><path d='M0 11.96h24v0.08H0z' fill='#000'/></svg>"
    build({ "hair" => hairline }, size: 8) do |builder, _, _|
      err = assert_raises(Fontico::Error) { builder.call }
      assert_match(/rasterised blank at 8px/, err.message)
      assert_match(/hair/, err.message)
    end
  end

  def test_the_gfxfont_target_implies_and_follows_the_font
    skip "needs Node" unless node?

    build({ "a" => square }, targets: { "gfxfont" => nil }) do |builder, root, _|
      report = builder.call

      assert_path_exists File.join(root, "builds", "icons.ttf"), "gfxfont should imply ttf"
      assert_path_exists File.join(root, "builds", "icons_font.h")
      assert_operator report.written.index { _1.end_with?("icons.ttf") },
                      :<,
                      report.written.index { _1.end_with?("icons_font.h") },
                      "the font it rasterises has to be built first"
    end
  end

  def test_the_size_is_taken_from_the_manifest
    skip "needs Node" unless node?

    build({ "a" => square }, size: 32) do |builder, root, _|
      builder.call
      header = File.read(File.join(root, "builds", "icons_font.h"))

      assert_includes header, "fontico_icons32"
      assert_includes header, "rasterised at 32px"
      assert_operator unpack(header, "a")[:height], :>=, 28, "a 32px em should be about 32px tall"
    end
  end

  def test_the_generated_gfxfont_compiles
    skip "needs Node" unless node?
    cc = ENV["CC"] || %w[cc gcc clang].find { |c| Open3.capture3("command", "-v", c)[2].success? }
    skip "no C compiler on PATH" unless cc

    build({ "block" => square, "ring" => square(3) }) do |builder, root, _|
      builder.call
      dir = File.join(root, "builds")
      File.write(File.join(dir, "use.c"), <<~C)
        #include "icons_font.h"
        int main(void) {
          const GFXglyph *g = &fontico_icons24_glyphs[ICON_BLOCK - fontico_icons24.first];
          return g->width > 0 && fontico_icons24.yAdvance > 0 ? 0 : 1;
        }
      C

      _, err, status = Open3.capture3(cc, "-std=c99", "-Wall", "-Wextra", "-Werror",
                                      "-o", "use", "use.c", chdir: dir)
      assert_predicate status, :success?, "the gfxfont header did not compile:\n#{err}"

      _, _, status = Open3.capture3("./use", chdir: dir)
      assert_predicate status, :success?
    end
  end
end

# targets: as a mapping, so a firmware header can land in the device's
# include/ directory instead of among the web artifacts.
class TargetPathTest < Minitest::Test
  def manifest(targets)
    Fontico::Manifest.new(
      { "targets" => targets, "providers" => { "lucide" => {} },
        "icons" => { "save" => "lucide/save" } }
    )
  end

  def test_a_list_names_targets_and_takes_default_locations
    m = manifest(%w[sprite ttf])
    assert_equal %w[sprite ttf], m.targets
    assert_nil m.target_path("sprite")
  end

  def test_a_mapping_names_targets_and_may_place_them
    m = manifest({ "sprite" => nil, "c" => "devs/esplay/include/icons.h" })
    assert_equal %w[sprite c], m.targets
    assert_nil m.target_path("sprite"), "a blank value means the default location"
    assert_equal "devs/esplay/include/icons.h", m.target_path("c")
  end

  def test_anything_else_is_refused
    err = assert_raises(Fontico::Manifest::Error) { manifest("sprite") }
    assert_match(/targets: must be a list or a mapping/, err.message)
  end

  # The font emitter writes its own file through Node rather than handing back
  # a string, so a placed ttf target needs its directory created before the
  # emitter runs, not after it returns. Building into a fresh tree caught this.
  def test_a_placed_font_target_gets_its_directory_before_the_emitter_runs
    skip "font targets need Node" unless Fontico::NodeRunner.new.available?

    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      File.write(File.join(root, "icons", "logo.svg"),
                 "<svg viewBox='0 0 24 24'><path d='M4 4h16v16H4z'/></svg>")

      m = Fontico::Manifest.new(
        { "targets" => { "ttf" => "firmware/data/icons.ttf", "c" => "firmware/include/icons.h" },
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => { "logo" => "local/logo" } }
      )
      Fontico::Builder.new(m, root: root, output: "builds").call

      assert_path_exists File.join(root, "firmware/data/icons.ttf")
      assert_path_exists File.join(root, "firmware/include/icons.h")
    end
  end

  # The one invariant the device cannot check for itself: the header names
  # codepoints, the font supplies glyphs at them, and a disagreement is an
  # invisible box on a screen nobody is watching. Read back through the \x
  # escapes a compiler would see, not the comments beside them.
  def test_the_header_and_the_font_agree_on_every_codepoint
    skip "font targets need Node" unless Fontico::NodeRunner.new.available?

    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      names = %w[alpha beta gamma delta]
      names.each_with_index do |n, i|
        File.write(File.join(root, "icons", "#{n}.svg"),
                   "<svg viewBox='0 0 24 24'><path d='M#{i + 2} #{i + 2}h10v10H#{i + 2}z'/></svg>")
      end

      m = Fontico::Manifest.new(
        { "targets" => { "ttf" => nil, "c" => nil },
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => names.to_h { [_1, "local/#{_1}"] } }
      )
      Fontico::Builder.new(m, root: root, output: "builds").call

      font = TTFunk::File.open(File.join(root, "builds", "icons.ttf"))
      in_font = font.cmap.unicode.first.code_map.keys.select { _1 >= 0xE000 }.sort

      header = File.read(File.join(root, "builds", "icons.h"))
      in_header = header.scan(/^#define ICON_\w+\s+"((?:\\x\h\h)+)"/).flatten.map do |literal|
        literal.scan(/\\x(\h\h)/).flatten.map { _1.to_i(16) }.pack("C*").force_encoding("UTF-8").ord
      end.sort

      assert_equal names.size, in_header.size
      assert_equal in_font, in_header, "the header names codepoints the font has no glyph for"
    end
  end

  # The path is the point: it has to actually be written there.
  def test_the_builder_writes_a_placed_target_where_it_was_told
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "icons"))
      File.write(File.join(root, "icons", "logo.svg"),
                 "<svg viewBox='0 0 24 24'><path d='M9 9'/></svg>")

      m = Fontico::Manifest.new(
        { "targets" => { "sprite" => "firmware/assets/sprite.svg" },
          "providers" => { "local" => { "path" => "icons" } },
          "icons" => { "logo" => "local/logo" } }
      )
      report = Fontico::Builder.new(m, root: root, output: "builds").call
      placed = File.join(root, "firmware/assets/sprite.svg")

      assert_path_exists placed, "the directory has to be created too"
      assert_includes File.read(placed), "M9 9"
      assert_includes report.written, placed
      refute_path_exists File.join(root, "builds", "icons.svg")
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

# The markup for a bare icon(name) is cached, so everything that can still
# change underneath it has to keep working. A regression here is icons
# pointing at a sprite that isn't there — an empty box on a page that 200s.
class HelperCacheTest < Minitest::Test
  class View
    include Fontico::Helper

    class << self
      attr_accessor :host
    end

    # Stands in for Propshaft, which is what supplies asset_path in an app.
    def asset_path(name) = "#{View.host}/assets/#{name.sub(".svg", "-abc123.svg")}"
  end

  def setup
    Fontico.manifest_path = File.expand_path("fixtures/icons.yml", __dir__)
    Fontico.reset!
    View.host = ""
    @view = View.new
  end

  def teardown
    Fontico.manifest_path = nil
    View.host = ""
    Fontico.reset!
  end

  def test_the_digest_path_still_reaches_the_cached_markup
    assert_includes @view.icon("save"), %(href="/assets/icons-abc123.svg#save")
  end

  # The reason the whole string is not cached: asset_host is allowed to be a
  # proc that reads the request, so a path held across requests would serve
  # the wrong host to somebody.
  def test_a_path_that_changes_between_calls_is_followed
    before = @view.icon("save")
    View.host = "https://cdn.example.com"
    after = @view.icon("save")

    assert_includes before, %(href="/assets/icons-abc123.svg#save")
    assert_includes after, %(href="https://cdn.example.com/assets/icons-abc123.svg#save")
  end

  def test_options_are_not_served_out_of_the_bare_cache
    @view.icon("save") # prime it
    assert_includes @view.icon("save", size: 16), 'style="width:16px;height:16px"'
    assert_includes @view.icon("save", class: "size-6"), 'class="ico size-6"'
    assert_includes @view.icon("save", title: "Save"), "<title>Save</title>"
  end

  # ...and an optioned call must not poison the bare one on the way past.
  def test_the_bare_call_survives_an_optioned_one
    @view.icon("save", size: 99, class: "x", title: "T")
    bare = @view.icon("save")

    assert_includes bare, 'width="1em"'
    assert_includes bare, 'class="ico"'
    assert_includes bare, 'aria-hidden="true"'
    refute_includes bare, "99"
    refute_includes bare, "<title>"
  end

  def test_a_name_the_manifest_lacks_still_raises_rather_than_caching_a_blank
    assert_raises(Fontico::Error) { @view.icon("nope") }
    assert_raises(Fontico::Error) { @view.icon("nope") }
  end

  # The cache is keyed by name, so a manifest edit that repoints one has to
  # invalidate it, or a save leaves the old symbol id in place and the <use>
  # lands on a symbol the new sprite never defined.
  def test_a_repointed_name_is_re_rendered_after_reset
    dir = Dir.mktmpdir
    path = File.join(dir, "icons.yml")
    Fontico.manifest_path = path
    write = lambda do |icons|
      File.write(path, YAML.dump("providers" => { "lucide" => {} }, "icons" => icons))
      Fontico.reset!
    end

    write.call("nav" => { "menu" => "lucide/menu" })
    assert_includes @view.icon("nav.menu"), "#nav-menu"
    refute_empty Fontico.icon_cache

    write.call("menu" => "lucide/menu")
    assert_empty Fontico.icon_cache, "reset! has to drop the rendered markup too"
    assert_includes @view.icon("menu"), "#menu"
  ensure
    FileUtils.remove_entry(dir)
  end
end

# Inline mode holds the sprite in memory rather than re-reading 10KB off disk
# per request, so a rebuilt file has to be noticed or the page embeds
# yesterday's symbols.
class InlineSpriteTest < Minitest::Test
  class View; include Fontico::Helper; end

  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "builds"))
    Fontico.root = @dir
    Fontico.output_dir = "builds"
    Fontico.reset!
    @view = View.new
  end

  def teardown
    Fontico.root = Fontico.output_dir = nil
    Fontico.reset!
    FileUtils.remove_entry(@dir)
  end

  def write(svg) = File.write(File.join(@dir, "builds", "icons.svg"), svg)

  def test_a_rebuilt_sprite_is_picked_up_without_a_reset
    write("<svg><symbol id='a'/></svg>")
    assert_includes @view.icons_sprite, "id='a'"

    # Longer on purpose: the stat compares size as well as mtime, so this
    # holds on a filesystem whose mtime granularity is a whole second.
    write("<svg><symbol id='b'/><symbol id='c'/></svg>")
    assert_includes @view.icons_sprite, "id='b'"
    refute_includes @view.icons_sprite, "id='a'"
  end

  def test_repeated_calls_return_the_same_held_string
    write("<svg><symbol id='a'/></svg>")
    assert_same Fontico.sprite_markup, Fontico.sprite_markup
  end

  def test_reset_drops_the_held_sprite
    write("<svg><symbol id='a'/></svg>")
    held = Fontico.sprite_markup
    Fontico.reset!
    refute_same held, Fontico.sprite_markup
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
