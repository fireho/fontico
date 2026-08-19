# frozen_string_literal: true

require "rexml/document"

module Fontico
  # Normalises one SVG into a body fragment that is safe to merge with any
  # other. Implements docs/icon-authoring.html section 01.
  #
  # Vendor icons arrive uniform; first-party exports do not. Everything here
  # exists because a real Inkscape or Illustrator export breaks it.
  class Preprocessor
    # Editor state, document furniture, and anything executable.
    DROP_ELEMENTS = %w[
      script metadata foreignObject sodipodi:namedview
      title desc inkscape:templateinfo
    ].freeze

    # Attributes that never survive: editor namespaces and event handlers.
    DROP_ATTR_PREFIXES = %w[sodipodi: inkscape: serif: xml:space].freeze

    # Attributes whose value may contain url(#id) and must be rewritten
    # alongside the ids themselves.
    URL_ATTRS = %w[
      fill stroke clip-path mask filter style
      marker-start marker-mid marker-end
    ].freeze

    COLOR_ATTRS = %w[fill stroke stop-color].freeze

    Result = Struct.new(:body, :width, :height, :warnings, :multicolor, keyword_init: true)

    def initialize(icon, size: 24)
      @icon = icon
      @size = size
      @warnings = []
    end

    # +source+ is a whole SVG document (local files) or a body fragment
    # (Iconify, which returns inner markup only).
    def call(source, width: nil, height: nil)
      doc = REXML::Document.new(wrap(source))
      root = doc.root

      vb_w, vb_h, min_x, min_y = viewbox_of(root, width, height)

      strip_elements!(root)
      strip_attributes!(root)
      namespace_ids!(root)

      # The manifest stays one line per icon: multicolor is detected, not
      # declared, unless the author overrides it explicitly.
      multicolor = @icon.multicolor.nil? ? distinct_colors(root).size > 1 : @icon.multicolor?
      fold_colors!(root) unless multicolor
      flag_hard_failures!(root)

      Result.new(
        body: refit(inner_markup(root), vb_w, vb_h, min_x, min_y),
        width: @size, height: @size, warnings: @warnings, multicolor: multicolor
      )
    end

    private

    def wrap(source)
      return source if source.lstrip.start_with?("<svg", "<?xml", "<!DOCTYPE")

      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@size} #{@size}">#{source}</svg>)
    end

    # Inkscape writes width="1024" alongside viewBox="0 0 270.93 270.93"; the
    # viewBox is authoritative. Iconify supplies dimensions out of band.
    def viewbox_of(root, width, height)
      if (vb = root.attributes["viewBox"])
        min_x, min_y, w, h = vb.split(/[\s,]+/).map(&:to_f)
        return [w, h, min_x, min_y] if w.to_f.positive? && h.to_f.positive?
      end

      w = (width || root.attributes["width"]).to_f
      h = (height || root.attributes["height"]).to_f
      w = @size if w.zero?
      h = @size if h.zero?
      [w, h, 0.0, 0.0]
    end

    def strip_elements!(root)
      each_element(root) do |el|
        el.parent&.delete_element(el) if DROP_ELEMENTS.include?(el.expanded_name)
      end
      # Empty <defs> and childless groups are pure noise in a merged sprite.
      each_element(root) do |el|
        next unless %w[defs g].include?(el.expanded_name)

        el.parent&.delete_element(el) if el.elements.empty? && el.texts.join.strip.empty?
      end
    end

    def strip_attributes!(root)
      each_element(root) do |el|
        el.attributes.each_attribute.to_a.each do |attr|
          name = attr.expanded_name
          drop = DROP_ATTR_PREFIXES.any? { name.start_with?(_1) } ||
                 name.start_with?("on") ||
                 name.start_with?("xmlns:") ||
                 external_reference?(name, attr.value)
          el.attributes.delete(name) if drop
        end
      end
    end

    def external_reference?(name, value)
      return false unless %w[href xlink:href].include?(name)

      !value.to_s.strip.start_with?("#")
    end

    # The collision fix. 34 of 40 sampled exports shared id="layer1"; without
    # this, merging any two of them silently drops one definition.
    def namespace_ids!(root)
      prefix = @icon.key
      seen = {}

      each_element(root) do |el|
        next unless (id = el.attributes["id"])

        seen[id] = "#{prefix}__#{id}"
        el.attributes["id"] = seen[id]
      end
      return if seen.empty?

      each_element(root) do |el|
        el.attributes.each_attribute.to_a.each do |attr|
          next unless URL_ATTRS.include?(attr.name) || %w[href xlink:href].include?(attr.expanded_name)

          value = attr.value.dup
          seen.each do |old, new|
            value.gsub!("url(##{old})", "url(##{new})")
            value.gsub!(/\A##{Regexp.escape(old)}\z/, "##{new}")
          end
          el.attributes[attr.expanded_name] = value
        end
      end
    end

    # Anything that resolves to paint: literal colours plus gradient
    # references, which are multicolour by construction.
    def distinct_colors(root)
      found = []
      each_element(root) do |el|
        COLOR_ATTRS.each do |name|
          v = el.attributes[name].to_s.strip
          found << v unless v.empty? || v == "none" || v == "currentColor"
        end
        next unless (style = el.attributes["style"])

        style.scan(/\b(?:fill|stroke|stop-color)\s*:\s*([^;]+)/i) do
          v = Regexp.last_match(1).strip
          found << v unless v == "none" || v == "currentColor"
        end
      end
      found.map { _1.start_with?("url(") ? "#{_1}-gradient" : _1.downcase }.uniq
    end

    def fold_colors!(root)
      each_element(root) do |el|
        COLOR_ATTRS.each do |name|
          value = el.attributes[name]
          next if value.nil? || value == "none" || value == "currentColor"

          el.attributes[name] = "currentColor"
        end

        next unless (style = el.attributes["style"])

        folded = style.gsub(/\b(fill|stroke|stop-color)\s*:\s*([^;]+)/i) do
          $2.strip.casecmp("none").zero? ? "#{$1}:none" : "#{$1}:currentColor"
        end
        el.attributes["style"] = folded
      end
    end

    # Section 03 of the spec: things no preprocessing can rescue. Surfaced as
    # warnings so the build names the file instead of shipping something broken.
    def flag_hard_failures!(root)
      each_element(root) do |el|
        case el.expanded_name
        when "text", "tspan"
          @warnings << "contains live <#{el.expanded_name}>; convert text to paths"
        when "image"
          @warnings << "embeds a raster <image>; redraw as vector"
        when "filter"
          @warnings << "uses a <filter>; effects do not survive font conversion"
        end
      end
      @warnings.uniq!
    end

    # Fit any source box into the target box, centred, aspect preserved.
    # fa6-solid is 512 with per-icon 576 overrides; bi declares no width at
    # all. The pipeline cannot assume 24.
    def refit(markup, w, h, min_x, min_y)
      scale = @size.to_f / [w, h].max
      return markup if (scale - 1.0).abs < 1e-9 && min_x.zero? && min_y.zero?

      tx = (@size - (w * scale)) / 2.0
      ty = (@size - (h * scale)) / 2.0
      transform = "translate(#{fmt(tx)} #{fmt(ty)}) scale(#{fmt(scale)}) " \
                  "translate(#{fmt(-min_x)} #{fmt(-min_y)})"
      %(<g transform="#{transform}">#{markup}</g>)
    end

    def fmt(n) = format("%g", n.round(4))

    def inner_markup(root)
      out = +""
      formatter = REXML::Formatters::Default.new
      root.children.each { formatter.write(_1, out) }
      out.strip
    end

    def each_element(root, &block)
      root.elements.to_a("//*").each { block.call(_1) if _1.parent }
    end
  end
end
