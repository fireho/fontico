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
      data = payload.dig("icons", icon.slug)
      raise Error, "#{icon.source}: not found in provider #{icon.provider}" if data.nil?

      # Per-icon dimensions override the set default; fa6-solid ships 512
      # sets with 576 icons inside them.
      Source.new(
        markup: data.fetch("body"),
        width: data["width"] || payload["width"],
        height: data["height"] || payload["height"]
      )
    end
  end
end
