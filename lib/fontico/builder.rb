# frozen_string_literal: true

require "fileutils"

module Fontico
  # Resolve -> preprocess -> lock -> emit. Everything the rake task does.
  class Builder
    # Declared in manifests, emitter not landed yet. Skipped with a notice so
    # the manifest can state intent without breaking the build.
    PENDING = %w[woff2].freeze

    Report = Struct.new(:written, :warnings, :skipped, :cached, :fetched, :pending,
                        keyword_init: true)

    def initialize(manifest, root: Dir.pwd, output: "app/assets/builds", offline: false)
      @manifest = manifest
      @root = root
      @output = File.join(root, output)
      @offline = offline
      @lock = Lockfile.new(File.join(root, "icons.lock"))
    end

    def call
      warnings = Hash.new { |h, k| h[k] = [] }
      cached, fetched = [], []

      stale = @manifest.icons.reject { @lock.fresh?(_1.name, _1.source) }
      cached = @manifest.icons.map(&:name) - stale.map(&:name)

      unless stale.empty?
        raise Error, "icons.lock is missing #{stale.size} icon(s) and --offline was given" if @offline

        sources = Resolver.new(@manifest, root: @root).call(only: stale.map(&:name))
        stale.each do |icon|
          src = sources.fetch(icon.name)
          pre = Preprocessor.new(icon, size: @manifest.size)
                            .call(src.markup, width: src.width, height: src.height)
          @lock.store(icon.name, source: icon.source, body: pre.body,
                      multicolor: pre.multicolor, warnings: pre.warnings)
          fetched << icon.name
        end
      end

      @lock.retire_missing!(@manifest.icons.map(&:name))
      @lock.save!

      @manifest.icons.each do |icon|
        found = @lock.warnings(icon.name)
        warnings[icon.name] = found if found.any?
      end

      written, skipped = emit
      Report.new(written: written, warnings: warnings, skipped: skipped,
                 cached: cached, fetched: fetched,
                 pending: @manifest.targets & PENDING)
    end

    private

    def emit
      FileUtils.mkdir_p(@output)
      written = []
      skipped = Hash.new { |h, k| h[k] = [] }

      targets = @manifest.targets - PENDING
      targets += ["css"] if targets.include?("sprite") && !targets.include?("css")

      targets.each do |target|
        path = File.join(@output, filename_for(target))
        emitter = emitter_for(target, [], path: path)

        accepted = @manifest.icons.select { emitter.accepts?(_1) }
        (@manifest.icons - accepted).each { skipped[target] << _1.name }

        pairs = accepted.map { [_1, @lock.body(_1.name)] }
        result = emitter_for(target, pairs, path: path).call
        File.write(path, result) if result.is_a?(String)
        written << path
      end

      [written, skipped]
    end

    def emitter_for(target, build = [], path: nil)
      case target
      when "sprite" then Emitters::Sprite.new(@manifest, build)
      when "css"    then Emitters::Stylesheet.new(@manifest, build)
      when "ttf"    then Emitters::Font.new(@manifest, build, lock: @lock, output: path)
      else raise Error, "unknown target #{target.inspect} (have: sprite, ttf)"
      end
    end

    def filename_for(target)
      case target
      when "sprite" then "icons.svg"
      when "css"    then "icons.css"
      when "ttf"    then "icons.ttf"
      else raise Error, "unknown target #{target.inspect}"
      end
    end
  end
end
