# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

module Fontico
  # Font assembly needs a toolchain the sprite does not. It is installed on
  # demand into a cache directory and never touched unless a font target is
  # actually built, so `targets: [sprite]` stays pure Ruby with no node at all.
  class NodeRunner
    class MissingNode < Fontico::Error; end
    class ScriptFailed < Fontico::Error; end

    SCRIPTS = File.expand_path("node", __dir__)

    def initialize(cache_dir: nil)
      @cache = cache_dir || File.join(Dir.home, ".cache", "fontico", "toolchain")
    end

    def available? = !which("node").nil?

    def run(script, payload)
      ensure_toolchain!
      # Run from inside the cache: ESM resolves bare imports by walking up
      # from the script's own directory, and ignores NODE_PATH entirely.
      path = File.join(@cache, script)

      out, err, status = Open3.capture3(
        which("node"), path, stdin_data: JSON.dump(payload), chdir: @cache
      )
      raise ScriptFailed, "#{script}: #{err.strip.empty? ? "exited #{status.exitstatus}" : err.strip}" unless status.success?

      JSON.parse(out)
    end

    private

    def ensure_toolchain!
      raise MissingNode, <<~MSG unless available?
        Building a font target needs Node.js, which was not found on PATH.

        The sprite target has no such requirement — remove `ttf` from
        `targets:` in your manifest to build without it.
      MSG

      FileUtils.mkdir_p(@cache)
      Dir[File.join(SCRIPTS, "*.mjs")].each { FileUtils.cp(_1, @cache) }
      return if File.directory?(File.join(@cache, "node_modules"))

      FileUtils.cp(File.join(SCRIPTS, "package.json"), @cache)
      _, err, status = Open3.capture3(
        which("npm"), "install", "--silent", "--no-audit", "--no-fund", chdir: @cache
      )
      raise ScriptFailed, "installing font toolchain into #{@cache}: #{err}" unless status.success?
    end

    def which(cmd)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        exe = File.join(dir, cmd)
        return exe if File.executable?(exe) && !File.directory?(exe)
      end
      nil
    end
  end
end
