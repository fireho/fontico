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
  autoload :ProviderFonts,"fontico/provider_fonts"
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
    def reset!        = (@manifest = nil)

    def configure = yield(self)
  end
end

require "fontico/railtie" if defined?(::Rails::Railtie)
