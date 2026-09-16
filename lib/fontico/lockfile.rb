# frozen_string_literal: true

require "yaml"
require "digest"

module Fontico
  # icons.lock pins two things that must never drift:
  #
  #   codepoints — append-only. Adding an icon must not renumber the others,
  #                or every glyph in the built font moves and the committed
  #                artifact churns whole-file on each addition. Codepoints of
  #                removed icons are retired, never reissued.
  #
  #   bodies     — the normalised SVG for each icon, so builds are
  #                reproducible and run offline. The Iconify API serves
  #                *latest*; without this an icon can change shape between
  #                two builds of the same manifest.
  class Lockfile
    PUA_START = 0xE001
    FORMAT = 1

    attr_reader :path

    def initialize(path)
      @path = path
      data = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      @codepoints = data["codepoints"] || {}
      @retired    = data["retired"]    || {}
      @entries    = data["icons"]      || {}
    end

    # Lookup only. A missing name is nil — callers that draw a glyph must
    # not invent a codepoint, or a typo silently becomes a .notdef.
    def codepoint_for(name) = @codepoints[name]

    # Append-only reservation. store is the production caller; tests use it
    # to pin order without going through a full build.
    def allocate(name)
      @codepoints[name] ||= next_free
    end

    def entry(name) = @entries[name]

    # +size+ is the grid the body was refit to. It is recorded because it is
    # an input to the body, not a property of the request for it — see #fresh?.
    def store(name, source:, body:, size:, multicolor: false, warnings: [])
      @entries[name] = {
        "source"     => source,
        "size"       => size,
        "digest"     => Digest::SHA256.hexdigest(body)[0, 16],
        "multicolor" => multicolor,
        "warnings"   => warnings,
        "body"       => body
      }
      allocate(name)
    end

    # A lock written before sizes were recorded cannot say what grid its
    # bodies were refit to. Taking them at the size now in the manifest costs
    # nothing when it is right, and `rake fontico:update` fixes it when it is
    # not. The alternative — calling every body stale — would re-fetch a whole
    # manifest on a gem upgrade, and put a network round trip in the first
    # deploy after it.
    def assume_size(size)
      @entries.each_value { _1["size"] ||= size }
    end

    # Names present in the lock but absent from the manifest keep their
    # codepoint reserved so it is never handed to a different icon.
    def retire_missing!(names)
      (@codepoints.keys - names).each do |gone|
        @retired[gone] = @codepoints.delete(gone)
        @entries.delete(gone)
      end
    end

    # A cached body is only reusable if every input that produced it still
    # holds. The source is the obvious one; the other two were the bug.
    #
    #   size        the body carries its refit baked in as a <g transform>,
    #               while the sprite emitter reads the target size live. Keyed
    #               on the source alone, changing `defaults: size:` moved every
    #               <symbol> to the new viewBox and left the geometry inside
    #               fit to the old grid — every icon a fraction of its size in
    #               the corner of its box, on a page that 200s. Local files are
    #               re-read every build and self-heal, so this only ever showed
    #               on cached remotes: most of a real manifest.
    #
    #   multicolor  the *override* from the manifest, not the detected result.
    #               When one is set the result always equals it, so the stored
    #               result is the record of whether this body was preprocessed
    #               under it. Nil leaves detection in charge, and detection on
    #               an unchanged body gives an unchanged answer.
    def fresh?(name, source, size:, multicolor: nil)
      e = entry(name)
      return false unless e && e["body"] && e["source"] == source && e["size"] == size

      multicolor.nil? || e["multicolor"] == multicolor
    end

    def body(name) = entry(name)&.fetch("body", nil)
    def multicolor?(name) = !!entry(name)&.fetch("multicolor", false)

    # Replayed on cached builds so a hard failure keeps being reported until
    # the source file is actually fixed.
    def warnings(name) = entry(name)&.fetch("warnings", nil) || []

    def save!
      File.write(@path, {
        "format"     => FORMAT,
        "codepoints" => @codepoints.sort.to_h,
        "retired"    => @retired.sort.to_h,
        "icons"      => @entries.sort.to_h
      }.to_yaml)
    end

    private

    def next_free
      used = (@codepoints.values + @retired.values).map(&:to_i)
      cp = PUA_START
      cp += 1 while used.include?(cp)
      cp
    end
  end
end
