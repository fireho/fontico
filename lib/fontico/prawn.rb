# frozen_string_literal: true

module Fontico
  # Icons in generated PDFs, from the same manifest as the web sprite.
  #
  # This is what the TTF target is actually for. Prawn reads TTF/OTF through
  # ttfunk and cannot read woff2, so TTF is the right container — it is not a
  # web font, and at this icon count the sprite beats one on the web anyway.
  #
  #   require "fontico/prawn"
  #
  #   Prawn::Document.generate("out.pdf") do |pdf|
  #     pdf.fontico!                        # register the family once
  #     pdf.icon "save", size: 18
  #     pdf.text "#{pdf.glyph("mail")} hello", inline_format: false
  #   end
  module Prawn
    FAMILY = "Fontico"

    module DocumentExtensions
      # Registers the built TTF as a font family. Call once per document.
      def fontico!(family: FAMILY, path: Fontico.font_file)
        unless File.exist?(path)
          raise Fontico::Error,
                "#{path} does not exist — add `ttf` to targets: and run rake fontico:build"
        end

        font_families.update(family => { normal: path })
        self
      end

      # The glyph character for +name+, for interpolating into a text run.
      # Wrap the run in font(Fontico::Prawn::FAMILY) so it renders.
      def glyph(name) = Fontico.glyph(name)

      # Draws one icon. Colour and size come from Prawn, exactly like text,
      # because a glyph *is* text.
      def icon(name, size: font_size, color: nil, family: FAMILY, **options)
        if Fontico.lockfile.multicolor?(name.to_s)
          raise Fontico::Error,
                "#{name} is multicolour and is not in the font. Draw it with " \
                "prawn-svg from the sprite source instead."
        end

        previous = fill_color
        fill_color(color) if color
        font(family, size: size) { text(Fontico.glyph(name), **options) }
        fill_color(previous) if color
        self
      end

      # Same, positioned — for letterheads and table cells.
      def icon_at(name, at:, size: font_size, family: FAMILY)
        font(family, size: size) { draw_text(Fontico.glyph(name), at: at) }
        self
      end
    end
  end
end

require "prawn"
Prawn::Document.include(Fontico::Prawn::DocumentExtensions)
