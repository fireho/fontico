# frozen_string_literal: true

require "net/http"
require "uri"
require "zlib"
require "rubygems/package"
require "fileutils"

module Fontico
  # Providers that publish their own font alongside a name -> codepoint map.
  #
  # This is the only lossless source of outlines for a stroke-based set: the
  # provider has already expanded the strokes for their font build. Every
  # available JS expander traces a raster and visibly degrades the geometry.
  module ProviderFonts
    REGISTRY = {
      "lucide" => {
        package: "lucide-static",
        version: "1.32.0",
        font: "package/font/lucide.ttf",
        codepoints: "package/font/codepoints.json"
      }
    }.freeze

    module_function

    def available?(provider) = REGISTRY.key?(provider)

    def known = REGISTRY.keys

    # Downloads and unpacks once into the cache; returns local paths.
    def fetch(provider, cache_dir:)
      spec = REGISTRY.fetch(provider) { raise Error, "no known font for provider #{provider}" }
      dir = File.join(cache_dir, "#{spec[:package]}-#{spec[:version]}")
      font = File.join(dir, File.basename(spec[:font]))
      codepoints = File.join(dir, File.basename(spec[:codepoints]))
      return [font, codepoints] if File.exist?(font) && File.exist?(codepoints)

      FileUtils.mkdir_p(dir)
      unpack(download(spec), spec, font, codepoints)
      [font, codepoints]
    end

    def download(spec)
      url = "https://registry.npmjs.org/#{spec[:package]}/-/#{spec[:package]}-#{spec[:version]}.tgz"
      uri = URI(url)
      res = Net::HTTP.get_response(uri)
      res = Net::HTTP.get_response(URI(res["location"])) if res.is_a?(Net::HTTPRedirection)
      raise Error, "downloading #{url}: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      res.body
    end

    def unpack(tgz, spec, font_out, codepoints_out)
      wanted = { spec[:font] => font_out, spec[:codepoints] => codepoints_out }
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(tgz))) do |tar|
        tar.each do |entry|
          dest = wanted[entry.full_name]
          File.binwrite(dest, entry.read) if dest
        end
      end
      missing = wanted.reject { File.exist?(_2) }.keys
      raise Error, "#{spec[:package]} did not contain #{missing.join(", ")}" if missing.any?
    end
  end
end
