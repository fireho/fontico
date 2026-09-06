# frozen_string_literal: true

module Fontico
  module Emitters
    # A TTF for Prawn. Not for the web: at this icon count the sprite is both
    # smaller over the wire and not render-blocking. Prawn reads TTF/OTF via
    # ttfunk and cannot read woff2, so TTF is the right container here.
    class Font
      def initialize(manifest, build, lock: nil, outliner: nil, output: nil)
        @manifest = manifest
        @build = build
        @lock = lock
        @outliner = outliner || Outliner.new
        @output = output
      end

      # Glyphs store no colour, so multicolour icons cannot be represented at
      # all. They stay in the sprite and the build names each one it dropped.
      def accepts?(icon) = !(@lock&.multicolor?(icon.name) || icon.multicolor?)
      def rules_only? = false

      def call
        unsupported = @build.select { |icon, body| @outliner.strategy_for(icon, body) == :none }
        @outliner.refuse(unsupported.map(&:first)) if unsupported.any?

        outlines = @outliner.outlines(@build, size: @manifest.size)

        glyphs = @build.map do |icon, body|
          # Never fall back to allocating here. The builder has already
          # save!d the lock by the time it emits, so a codepoint minted now
          # would never reach disk: the font would ship a glyph that
          # Fontico.glyph cannot name. A nil is worse still — it reaches
          # String.fromCodePoint as null and maps the glyph to U+0000
          # without complaint.
          cp = @lock.codepoint_for(icon.name)
          raise Fontico::Error, "#{icon.name} has no codepoint in icons.lock" if cp.nil?

          { name: icon.key, codepoint: cp, svg: document(outlines[icon.name], body) }
        end

        result = @outliner.instance_variable_get(:@runner)
                          .run("build_font.mjs", {
                                 fontName: "fontico", size: @manifest.size,
                                 output: @output, glyphs: glyphs
                               })
        if result["empty"]&.any?
          raise Fontico::Error, <<~MSG
            #{result["empty"].size} icon(s) produced an empty glyph and would ship invisible:

              #{result["empty"].join("\n  ")}

            The usual cause is live <text> in the source SVG, which has no outline
            to convert. Convert text to paths (Path > Object to Path), or remove
            the icon from the font target.
          MSG
        end

        result
      end

      private

      def document(outline, body)
        inner = outline ? %(<path d="#{outline}"/>) : body.gsub("currentColor", "#000")
        %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@manifest.size} #{@manifest.size}">#{inner}</svg>)
      end
    end
  end
end
