# frozen_string_literal: true

require "fileutils"

module Fontico
  # Decides where each icon's *filled outline* comes from, which is the whole
  # difficulty of the font target.
  #
  #   :fill    already filled geometry — used as-is (Material Symbols, flat
  #            first-party exports, most Iconify sets)
  #   :glyph   stroke-based, but the provider ships a font whose glyphs are
  #            already expanded — extracted from there, losslessly (Lucide)
  #   :none    stroke-based with no provider font — refused, loudly
  #
  # There is deliberately no raster-trace fallback. Both published JS
  # expanders (svg-outline-stroke, oslllo-svg-fixer) run the artwork through
  # potrace; corners round off and strokes wobble. Refusing beats shipping
  # geometry that quietly stopped matching the sprite.
  class Outliner
    Unsupported = Class.new(Fontico::Error)

    def initialize(runner: NodeRunner.new, cache_dir: nil)
      @runner = runner
      @cache = cache_dir || File.join(Dir.home, ".cache", "fontico", "fonts")
    end

    def self.stroke_based?(body)
      body.match?(/stroke\s*=\s*['"](?!none)/) || body.match?(/stroke\s*:\s*(?!none)/)
    end

    def strategy_for(icon, body)
      return :fill unless self.class.stroke_based?(body)
      return :glyph if ProviderFonts.available?(icon.provider)

      :none
    end

    # => { icon_name => path_data } for every :glyph icon, batched per provider
    # so each provider font is downloaded and parsed once.
    def outlines(pairs, size: 24)
      by_provider = pairs.select { |icon, body| strategy_for(icon, body) == :glyph }
                         .group_by { |icon, _| icon.provider }
      return {} if by_provider.empty?

      FileUtils.mkdir_p(@cache)
      by_provider.each_with_object({}) do |(provider, group), out|
        font, codepoints = ProviderFonts.fetch(provider, cache_dir: @cache)
        result = @runner.run("extract_glyphs.mjs", {
          fontPath: font, codepointsPath: codepoints, size: size,
          names: group.map { |icon, _| icon.slug }.uniq
        })

        if result["missing"]&.any?
          raise Unsupported, "#{provider} font has no glyph for: #{result["missing"].join(", ")}"
        end

        group.each { |icon, _| out[icon.name] = result.dig("glyphs", icon.slug) }
      end
    end

    def refuse(unsupported)
      names = unsupported.map { "#{_1.name} (#{_1.source})" }
      raise Unsupported, <<~MSG
        #{unsupported.size} icon(s) are stroke-based and their provider ships no
        font to take outlines from, so they cannot become glyphs:

          #{names.join("\n  ")}

        A stroked path does not fail loudly in a font — it fills its centreline
        and produces a solid blob. Options:

          * outline the strokes at source (Path > Stroke to Path) for local icons
          * pick the filled variant of the icon from its provider
          * drop `ttf` from targets: and use the sprite, which renders strokes natively

        Providers with extractable fonts: #{ProviderFonts.known.join(", ")}
      MSG
    end
  end
end
