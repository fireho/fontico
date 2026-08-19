# frozen_string_literal: true

require_relative "lib/fontico/version"

Gem::Specification.new do |spec|
  spec.name        = "fontico"
  spec.version     = Fontico::VERSION
  spec.authors     = ["Duto"]
  spec.summary     = "Name icons by intent. Source them from anywhere. Ship one artifact."
  spec.description = "Declare every icon in your app in one manifest — from Lucide, " \
                     "Material Symbols, any Iconify set, or your own SVG folder — under " \
                     "names you choose. fontico resolves, normalises and merges them into " \
                     "a single build artifact, so templates never name a vendor."
  spec.homepage    = "https://github.com/duto/fontico"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*", "docs/**/*", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rexml", "~> 3.2"

  # Optional, not required: `require "fontico/prawn"` only if you draw icons
  # into PDFs. Font targets additionally need Node on PATH.
  spec.add_development_dependency "prawn", "~> 2.5"
end
