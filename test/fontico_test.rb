# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
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
    with_lock { |lock, _| assert_equal 0xE001, lock.codepoint_for("save") }
  end

  # The reason the lockfile exists: adding an icon must not renumber the rest,
  # or every glyph in a committed font moves on each addition.
  def test_adding_an_icon_does_not_renumber_existing_ones
    with_lock do |lock, dir|
      before = %w[save edit copy].to_h { [_1, lock.codepoint_for(_1)] }
      lock.save!

      reopened = Fontico::Lockfile.new(File.join(dir, "icons.lock"))
      reopened.codepoint_for("aaaa-sorts-first")
      after = before.keys.to_h { [_1, reopened.codepoint_for(_1)] }

      assert_equal before, after
    end
  end

  def test_removed_icons_retire_their_codepoint_instead_of_freeing_it
    with_lock do |lock, _|
      gone = lock.codepoint_for("old")
      lock.codepoint_for("kept")
      lock.retire_missing!(["kept"])
      refute_equal gone, lock.codepoint_for("brand-new")
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
