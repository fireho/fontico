# frozen_string_literal: true

module Fontico
  module Emitters
    # One <svg> of <symbol> definitions, referenced with <use href="…#name">.
    # Pure Ruby string assembly: no external toolchain, builds anywhere.
    class Sprite
      def initialize(manifest, build)
        @manifest = manifest
        @build = build
      end

      def accepts?(_icon) = true
      def rules_only? = false

      def call
        symbols = @build.map do |icon, body|
          %(<symbol id="#{icon.key}" viewBox="0 0 #{@manifest.size} #{@manifest.size}" ) +
            %(fill="none">#{body}</symbol>)
        end

        <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" aria-hidden="true" style="display:none">
          #{symbols.join("\n")}
          </svg>
        SVG
      end
    end
  end
end
