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

    def codepoint_for(name)
      @codepoints[name] ||= next_free
    end

    def entry(name) = @entries[name]

    def store(name, source:, body:, multicolor: false, warnings: [])
      @entries[name] = {
        "source"     => source,
        "digest"     => Digest::SHA256.hexdigest(body)[0, 16],
        "multicolor" => multicolor,
        "warnings"   => warnings,
        "body"       => body
      }
      codepoint_for(name)
    end

    # Names present in the lock but absent from the manifest keep their
    # codepoint reserved so it is never handed to a different icon.
    def retire_missing!(names)
      (@codepoints.keys - names).each do |gone|
        @retired[gone] = @codepoints.delete(gone)
        @entries.delete(gone)
      end
    end

    def fresh?(name, source)
      entry(name)&.fetch("source", nil) == source && entry(name)["body"]
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
