# frozen_string_literal: true

require_relative "lib/fontico/version"

Gem::Specification.new do |spec|
  spec.name        = "fontico"
  spec.version     = Fontico::VERSION
  spec.authors     = ["nofxx"]
  spec.summary     = "Name icons by intent. Source them from anywhere. Ship one artifact."
  spec.description = "Declare every icon in your app in one manifest — from Lucide, " \
                     "Material Symbols, any Iconify set, or your own SVG folder — under " \
                     "names you choose. fontico resolves, normalises and merges them into " \
                     "a single build artifact, so templates never name a vendor."
  spec.homepage    = "https://github.com/fireho/fontico"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "source_code_uri"       => spec.homepage,
    "bug_tracker_uri"       => "#{spec.homepage}/issues",
    "changelog_uri"         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*", "docs/**/*", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rexml", "~> 3.2"

  # Optional, not required: `require "fontico/prawn"` only if you draw icons
  # into PDFs. Font targets additionally need Node on PATH.
  spec.add_development_dependency "prawn", "~> 2.5"
  spec.add_development_dependency "rubocop", "~> 1.79"
  spec.add_development_dependency "rubocop-performance", "~> 1.25"
end
