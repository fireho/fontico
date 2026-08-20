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
    def icon(name, size: nil, variant: nil, **options)
      Fontico.check!(name.to_s)
      entry = Fontico.manifest[name.to_s]
      return missing(name) if entry.nil?

      symbol = entry.key
      attrs = {
        class: [Fontico.css_class, options.delete(:class)].compact.join(" "),
        width: size || "1em",
        height: size || "1em",
        style: inline_size(size, options.delete(:style)),
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

    # The `<use href>` for one icon, for markup this helper doesn't build —
    # a Vue or Stimulus template, a JSON blob on its way to the client.
    # Both halves are things a template shouldn't have to know: the sprite
    # carries an asset digest, and a dotted manifest name is a dashed symbol
    # id inside the file.
    #
    #   icon_href("game.aim")  # => "/assets/icons-ac89a32b.svg#game-aim"
    #
    # Hand it to the client rather than reconstructing it there; see
    # icons_sprite for the inline case, where the path half is empty and the
    # fragment resolves against the current document.
    def icon_href(name)
      Fontico.check!(name.to_s)
      entry = Fontico.manifest[name.to_s]
      raise Fontico::Error, "no icon named #{name.inspect} in #{Fontico.manifest_path}" if entry.nil?

      "#{sprite_path}##{entry.key}"
    end

    # Embeds the symbol definitions directly, for pages served from a CDN
    # where a cross-origin <use href> would silently render nothing.
    def icons_sprite
      Fontico.check!
      svg = File.read(Fontico.sprite_file)
      svg.respond_to?(:html_safe) ? svg.html_safe : svg
    end

    private

    # width/height on an <svg> are presentation attributes, and *any* CSS
    # declaration outranks those — including icons.css's own `.ico { width:
    # 1em }`. So an explicitly requested size has to be inline or the
    # stylesheet silently swallows it and every icon comes out 1em.
    #
    # With no size given the attributes stay the only word on the matter,
    # which is what lets `class: "size-6"` or `class: "h-7 w-7"` still win.
    def inline_size(size, style = nil)
      return style if size.nil?

      dim = size.is_a?(Numeric) ? "#{size}px" : size.to_s
      ["width:#{dim}", "height:#{dim}", style].compact.join(";")
    end

    # Propshaft always digests, so there is no undigested path to guess at:
    # "/assets/icons.svg" is a 404 in every environment, and a <use> pointing
    # at one renders an empty box rather than raising. That matters most for
    # icon_href, which gets called from serializers, jobs and broadcasts —
    # payload-building code that has no view context to borrow asset_path
    # from. Rails hands one out off ActionController::Base either way.
    def sprite_path(_variant = nil)
      return "" if Fontico.inline_sprite?
      return asset_path("icons.svg") if respond_to?(:asset_path)
      return ActionController::Base.helpers.asset_path("icons.svg") if defined?(::ActionController::Base)

      "/assets/icons.svg"
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
