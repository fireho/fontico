# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Fontico
  # Turns manifest entries into raw SVG. Vendor icons come from the Iconify
  # API in one batched request per provider; first-party icons come off disk.
  class Resolver
    class Error < Fontico::Error; end

    API = "https://api.iconify.design"

    # Guards a malformed set; real chains are one or two hops.
    MAX_ALIAS_DEPTH = 8

    Source = Struct.new(:markup, :width, :height, keyword_init: true)

    # { "save" => "lucide/save: not found in provider lucide" } — icons this
    # run could not resolve. Filled by #call; see the comment there.
    attr_reader :missing

    def initialize(manifest, root: Dir.pwd, api: API)
      @manifest = manifest
      @root = root
      @api = api
      @missing = {}
    end

    # => { "save" => Source, ... } keyed by icon name.
    #
    # One bad name in a manifest of two hundred used to take the whole build
    # down, which meant a typo in an icon nobody had shipped yet blocked
    # everyone. A single icon failing is now recorded in #missing and left
    # out of the result; the caller reports it and builds the rest. Failures
    # that are not per-icon — an unreachable API, a provider that 404s — are
    # still raised, because then nothing would be correct.
    def call(only: nil)
      icons = @manifest.icons
      icons = icons.select { only.include?(_1.name) } if only

      resolved = {}
      icons.select(&:local?).each do |icon|
        try(icon) { resolved[icon.name] = local(icon) }
      end

      icons.reject(&:local?).group_by(&:provider).each do |provider, group|
        payload = fetch(provider, group.map(&:slug).uniq.sort)
        group.each { |icon| try(icon) { resolved[icon.name] = remote(icon, payload) } }
      end

      resolved
    end

    private

    def try(icon)
      yield
    rescue Error => e
      @missing[icon.name] = e.message
      nil
    end

    def local(icon)
      path = File.join(@root, @manifest.local_path, "#{icon.slug}.svg")
      raise Error, "#{icon.source}: no such file #{path}" unless File.exist?(path)

      Source.new(markup: File.read(path))
    end

    # One request per provider, not per icon. 30 icons across two providers
    # measured at ~0.9s and 7KB total.
    def fetch(provider, slugs)
      uri = URI("#{@api}/#{provider}.json?icons=#{slugs.join(",")}")
      body = Net::HTTP.get_response(uri).then do |res|
        raise Error, "#{provider}: API returned #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        res.body
      end
      JSON.parse(body)
    rescue JSON::ParserError, SocketError, Errno::ECONNREFUSED => e
      raise Error, "#{provider}: could not reach #{@api} (#{e.class}). " \
                   "Run with a populated icons.lock to build offline."
    end

    def remote(icon, payload)
      data, transform = lookup(icon, payload)
      raise Error, "#{icon.source}: not found in provider #{icon.provider}" if data.nil?

      # Per-icon dimensions override the set default; fa6-solid ships 512
      # sets with 576 icons inside them.
      width  = data["width"]  || payload["width"]
      height = data["height"] || payload["height"]

      Source.new(
        markup: apply(transform, data.fetch("body"), width, height),
        width: width,
        height: height
      )
    end

    # Iconify keeps renames and mirrored variants out of "icons" and in
    # "aliases", pointing at a parent that may itself be an alias. Without
    # this, `lucide/fingerprint` — an alias since the icon was renamed to
    # fingerprint-pattern — resolves to nothing and the build dies.
    def lookup(icon, payload)
      slug = icon.slug
      transform = {}
      seen = []

      MAX_ALIAS_DEPTH.times do
        return [payload.dig("icons", slug), transform] if payload.dig("icons", slug)

        entry = payload.dig("aliases", slug)
        return [nil, transform] if entry.nil?

        # A transform is expressed relative to the parent, so an alias chain
        # composes outwards: rotation adds, each flip toggles.
        transform[:rotate] = (transform[:rotate].to_i + entry["rotate"].to_i) % 4
        transform[:h_flip] = transform[:h_flip] ^ true if entry["hFlip"]
        transform[:v_flip] = transform[:v_flip] ^ true if entry["vFlip"]

        seen << slug
        slug = entry["parent"]
        raise Error, "#{icon.source}: alias cycle #{(seen << slug).join(" -> ")}" if seen.include?(slug)
      end

      raise Error, "#{icon.source}: alias chain deeper than #{MAX_ALIAS_DEPTH} in #{icon.provider}"
    end

    # Flip about the box centre, then rotate about it in quarter turns —
    # the order Iconify defines. Emitted as one wrapping <g> so the body
    # itself is untouched and still normalises like any other.
    def apply(transform, body, width, height)
      return body if transform.empty? || transform.values.none? { _1 == true || _1.to_i.positive? }

      w = (width || 24).to_f
      h = (height || 24).to_f
      ops = []
      ops << "rotate(#{transform[:rotate] * 90} #{w / 2} #{h / 2})" if transform[:rotate].to_i.positive?
      ops << "translate(#{w} 0) scale(-1 1)" if transform[:h_flip]
      ops << "translate(0 #{h}) scale(1 -1)" if transform[:v_flip]

      %(<g transform="#{ops.join(" ")}">#{body}</g>)
    end
  end
end
