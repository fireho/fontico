# frozen_string_literal: true

require "fileutils"

module Fontico
  # Resolve -> preprocess -> lock -> emit. Everything the rake task does.
  class Builder
    # Declared in manifests, emitter not landed yet. Skipped with a notice so
    # the manifest can state intent without breaking the build.
    PENDING = %w[woff2].freeze

    Report = Struct.new(:written, :warnings, :skipped, :cached, :fetched, :pending,
                        :missing, keyword_init: true)

    def initialize(manifest, root: Dir.pwd, output: "app/assets/builds",
                   offline: false, force: false)
      @manifest = manifest
      @root = root
      @output = File.join(root, output)
      @offline = offline
      @force = force
      @lock = Lockfile.new(File.join(root, "icons.lock"))
    end

    def call
      warnings = Hash.new { |h, k| h[k] = [] }
      cached, fetched = [], []
      missing = {}

      # The lock caches Iconify bodies so deploys run offline. Local files
      # are already on disk: treating them as fresh meant editing logo.svg
      # rebuilt nothing. Force is `rake fontico:update` — re-fetch remotes,
      # keep the append-only codepoints.
      stale = @manifest.icons.select { _1.local? || @force || !@lock.fresh?(_1.name, _1.source) }
      cached = @manifest.icons.map(&:name) - stale.map(&:name)

      unless stale.empty?
        remote_stale = stale.reject(&:local?)
        # Local files do not need the network. Offline is a hard fail only
        # when a remote body has to come off the wire — which under force is
        # every remote, lock or no lock. Saying "missing" there would be a
        # lie: the bodies are present, force is what made them stale.
        if @offline && remote_stale.any?
          reason = @force ? "re-fetch #{remote_stale.size} icon(s)" : "resolve #{remote_stale.size} icon(s) missing from icons.lock"
          raise Error, "cannot #{reason} and --offline was given"
        end

        resolver = Resolver.new(@manifest, root: @root)
        sources = resolver.call(only: stale.map(&:name))
        missing = resolver.missing
        stale.each do |icon|
          src = sources[icon.name]
          # Named in #missing already, and reported by the caller. It keeps
          # its codepoint and whatever the lock still holds, so fixing the
          # manifest entry is all it takes to bring it back.
          next if src.nil?

          pre = Preprocessor.new(icon, size: @manifest.size)
                            .call(src.markup, width: src.width, height: src.height)
          # Locals are re-read every build, so "stale" does not mean changed.
          # Compare the stored digest to keep an untouched logo.svg counted as
          # cached rather than reported as a fetch that never happened. A
          # remote is judged by the wire, not the digest: under force it was
          # genuinely re-fetched even when it came back byte-identical.
          before = @lock.entry(icon.name)&.fetch("digest", nil)
          @lock.store(icon.name, source: icon.source, body: pre.body,
                      multicolor: pre.multicolor, warnings: pre.warnings)
          unchanged = icon.local? && @lock.entry(icon.name)["digest"] == before
          (unchanged ? cached : fetched) << icon.name
        end
      end

      # Missing icons stay in the list: their codepoints must not be reissued
      # while the manifest still claims them.
      @lock.retire_missing!(@manifest.icons.map(&:name))
      @lock.save!

      buildable = @manifest.icons.reject { missing.key?(_1.name) }
      buildable.each do |icon|
        found = @lock.warnings(icon.name)
        warnings[icon.name] = found if found.any?
      end

      written, skipped = emit(buildable)
      Report.new(written: written, warnings: warnings, skipped: skipped,
                 cached: cached, fetched: fetched, missing: missing,
                 pending: @manifest.targets & PENDING)
    end

    private

    def emit(icons)
      FileUtils.mkdir_p(@output)
      written = []
      skipped = Hash.new { |h, k| h[k] = [] }

      targets = @manifest.targets - PENDING
      targets += ["css"] if targets.include?("sprite") && !targets.include?("css")

      targets.each do |target|
        path = File.join(@output, filename_for(target))
        emitter = emitter_for(target, [], path: path)

        accepted = icons.select { emitter.accepts?(_1) }
        # A rules-only emitter refuses every icon by design; that is not a skip
        # anyone needs to hear about.
        (icons - accepted).each { skipped[target] << _1.name } unless emitter.rules_only?

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
