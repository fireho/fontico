# frozen_string_literal: true

module Fontico
  # The whole point of the manifest: templates say what they mean, and never
  # name a vendor. icon("save") and icon("logo") are the same call.
  module Helper
    # A glyph inherits font-size and colour from the text around it; an <svg>
    # does not. width/height of 1em restores the first, `currentColor` baked
    # into every body restores the second, and the generated stylesheet puts
    # it on the baseline. Pass size: to override, or a CSS class — classes win
    # over the attributes, so `class: "size-6"` works untouched.
    def icon(name, size: "1em", variant: nil, **options)
      entry = Fontico.manifest[name.to_s]
      return missing(name) if entry.nil?

      symbol = entry.key
      attrs = {
        class: [Fontico.css_class, options.delete(:class)].compact.join(" "),
        width: size,
        height: size,
        "aria-hidden": options.key?(:title) ? nil : "true",
        role: options.key?(:title) ? "img" : nil
      }.merge(options).compact

      title = attrs.delete(:title)
      body = +""
      body << "<title>#{ERB::Util.html_escape(title)}</title>" if title
      body << %(<use href="#{sprite_path(variant)}##{symbol}"></use>)

      tag = %(<svg #{attrs.map { |k, v| %(#{k}="#{ERB::Util.html_escape(v)}") }.join(" ")}>#{body}</svg>)
      tag.respond_to?(:html_safe) ? tag.html_safe : tag
    end

    # Embeds the symbol definitions directly, for pages served from a CDN
    # where a cross-origin <use href> would silently render nothing.
    def icons_sprite
      svg = File.read(Fontico.sprite_file)
      svg.respond_to?(:html_safe) ? svg.html_safe : svg
    end

    private

    def sprite_path(_variant = nil)
      return "" if Fontico.inline_sprite?

      if respond_to?(:asset_path)
        asset_path("icons.svg")
      else
        "/assets/icons.svg"
      end
    end

    # An icon missing from the manifest is a typo, and typos should not reach
    # production as an invisible empty box.
    def missing(name)
      raise Fontico::Error, "no icon named #{name.inspect} in #{Fontico.manifest_path}" unless production?

      "".respond_to?(:html_safe) ? "".html_safe : ""
    end

    def production?
      defined?(Rails) && Rails.env.production?
    end
  end
end
