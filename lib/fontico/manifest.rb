# frozen_string_literal: true

require "yaml"

module Fontico
  # Parses icons.yml. Nested groups flatten to dotted names, so
  # `nav: { menu: lucide/menu }` is addressable as icon("nav.menu").
  class Manifest
    class Error < Fontico::Error; end

    # Where local/ SVGs live when the manifest doesn't say otherwise.
    LOCAL_PATH = "app/assets/icons"

    attr_reader :path, :defaults, :providers, :targets, :icons

    def self.load(*paths)
      paths = paths.flatten.compact.select { File.file?(_1) }
      raise Errno::ENOENT, "icons.yml" if paths.empty?

      data = paths.map { YAML.safe_load_file(_1) || {} }.reduce { |a, b| merge_data(a, b) }
      new(data, path: paths.last)
    end

    # Later overlay wins a leaf; nested groups merge so an engine can ship
    # `auth.google` and the app can add `auth.apple` without copying.
    def self.merge_data(base, overlay)
      {
        "defaults" => (base["defaults"] || {}).merge(overlay["defaults"] || {}),
        "targets" => overlay["targets"] || base["targets"] || ["sprite"],
        "providers" => (base["providers"] || {}).merge(overlay["providers"] || {}),
        "icons" => deep_merge(base["icons"] || {}, overlay["icons"] || {})
      }
    end

    def self.deep_merge(left, right)
      left.merge(right) { |_, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b }
    end

    def initialize(data, path: nil)
      @path      = path
      @defaults  = data["defaults"]  || {}
      @providers = data["providers"] || {}
      @targets   = data["targets"]   || ["sprite"]
      @icons     = flatten(data["icons"] || {}).freeze
      validate!
    end

    def default_provider = defaults.fetch("provider", "lucide")
    def local_path       = providers.dig("local", "path") || LOCAL_PATH
    def size             = defaults.fetch("size", 24).to_i

    def [](name) = icons.find { _1.name == name }

    # Vendor icons grouped by provider so the resolver can batch one HTTP
    # request per provider instead of one per icon.
    def remote_by_provider
      icons.reject(&:local?).group_by(&:provider).transform_values { _1.map(&:slug).uniq.sort }
    end

    def local_icons = icons.select(&:local?)

    private

    def flatten(tree, prefix = nil)
      tree.flat_map do |key, value|
        name = [prefix, key].compact.join(".")
        case value
        when String then [build(name, value)]
        when Hash
          if value.key?("icon") || value.key?("file")
            [build(name, value["icon"] || "local/#{File.basename(value["file"], ".svg")}", value)]
          else
            flatten(value, name)
          end
        else
          raise Error, "icon #{name.inspect} must be a string or a mapping, got #{value.class}"
        end
      end
    end

    def build(name, spec, opts = {})
      provider, slug = spec.include?("/") ? spec.split("/", 2) : [default_provider, spec]
      Icon.new(name: name, provider: provider, slug: slug, multicolor: opts["multicolor"])
    end

    def validate!
      raise Error, "manifest declares no icons" if icons.empty?

      dupes = icons.map(&:name).tally.select { |_, n| n > 1 }.keys
      raise Error, "duplicate icon names: #{dupes.join(", ")}" if dupes.any?

      unknown = icons.map(&:provider).uniq - providers.keys
      raise Error, "icons reference undeclared providers: #{unknown.join(", ")}" if unknown.any?
    end
  end
end
