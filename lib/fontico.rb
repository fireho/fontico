# frozen_string_literal: true

require "erb"
require_relative "fontico/version"

module Fontico
  class Error < StandardError; end

  autoload :Icon,         "fontico/icon"
  autoload :Manifest,     "fontico/manifest"
  autoload :Preprocessor, "fontico/preprocessor"
  autoload :Resolver,     "fontico/resolver"
  autoload :Lockfile,     "fontico/lockfile"
  autoload :Builder,      "fontico/builder"
  autoload :Helper,       "fontico/helper"
  autoload :NodeRunner,   "fontico/node_runner"
  autoload :ProviderFonts, "fontico/provider_fonts"
  autoload :Outliner,     "fontico/outliner"
  # fontico/prawn is opt-in: `require "fontico/prawn"`, so the gem never
  # loads Prawn for apps that only build a sprite.

  module Emitters
    autoload :Sprite,     "fontico/emitters/sprite"
    autoload :Font,       "fontico/emitters/font"
    autoload :Stylesheet, "fontico/emitters/stylesheet"
  end

  class << self
    attr_writer :manifest_path, :root, :output_dir, :inline_sprite, :css_class

    # Base class on every emitted <svg>; also the stylesheet's selector.
    def css_class = @css_class ||= "ico"

    def root          = @root ||= Dir.pwd
    def output_dir    = @output_dir ||= "app/assets/builds"
    def manifest_path = @manifest_path ||= File.join(root, "icons.yml")
    def manifest      = @manifest ||= Manifest.load(manifest_path)
    def sprite_file   = File.join(root, output_dir, "icons.svg")

    # Inline mode embeds <symbol> definitions in the layout instead of
    # referencing an external file — required when assets are served from a
    # CDN, where cross-origin <use href> silently renders nothing.
    def inline_sprite? = !!@inline_sprite

    def build(**opts) = Builder.new(manifest, root: root, output: output_dir, **opts).call

    # The dev reloader's build, and the only caller that records what went
    # wrong. Building stays forgiving on purpose — one typo must not stop the
    # other 199 icons — so nothing raises here; the complaint is held until
    # someone actually draws an icon. See #check!.
    def rebuild!
      @build_error = nil
      @missing_icons = build.missing || {}
    rescue StandardError => e
      @build_error = e
      @missing_icons = {}
    end

    # Why the last rebuild could not deliver: the exception it died on, and
    # the icons it left out of the sprite.
    attr_reader :build_error

    def missing_icons = @missing_icons ||= {}

    # Raised at the call site, because that is the only place with anything
    # useful to say. An icon left out of the sprite still resolves through the
    # manifest and renders a perfectly valid <use> at a symbol that isn't
    # there — an invisible empty box, on a page that 200s. Silence is the one
    # outcome worse than a stack trace.
    #
    # Free in production: only the dev reloader ever fills these in.
    def check!(name = nil)
      raise Error, "icons.yml did not build: #{@build_error.message}" if @build_error

      reason = missing_icons[name]
      raise Error, "icon #{name.inspect} was left out of the sprite: #{reason}" if reason
    end

    def lockfile = Lockfile.new(File.join(root, "icons.lock"))

    def font_file = File.join(root, output_dir, "icons.ttf")

    # The character to print when drawing this icon from the font — for Prawn,
    # where you write the glyph literally. Pinned append-only in icons.lock so
    # a reference in Ruby source never goes stale.
    def codepoint(name)
      cp = lockfile.codepoint_for(name.to_s)
      raise Error, "no icon named #{name.inspect}; run rake fontico:build" if cp.nil?

      cp
    end

    def glyph(name) = [codepoint(name)].pack("U")
    def reset!        = (@manifest = @build_error = @missing_icons = nil)

    def configure = yield(self)
  end
end

require "fontico/railtie" if defined?(::Rails::Railtie)
