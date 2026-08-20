# frozen_string_literal: true

require "rails/railtie"

module Fontico
  class Railtie < ::Rails::Railtie
    initializer "fontico.helper" do
      ActiveSupport.on_load(:action_view) { include Fontico::Helper }
    end

    initializer "fontico.root" do
      Fontico.root = Rails.root.to_s
    end

    # Saving icons.yml — or a local SVG — rebuilds the artifacts and drops the
    # memoized manifest, so a new icon is live on the next request with no
    # restart and no rake. That memo is the only thing that ever needed one:
    # this gem is not Zeitwerk's to reload, so @manifest outlives a code
    # reload, while Propshaft re-digests the rebuilt sprite on its own in dev.
    initializer "fontico.reloader" do |app|
      next unless app.config.enable_reloading

      watcher = app.config.file_watcher.new([Fontico.manifest_path], Railtie.local_dirs) do
        Fontico.reset!
        Fontico.rebuild!
        # Recorded rather than raised: a save that half-breaks the manifest
        # must not take down a page that draws none of the broken icons. The
        # ones that do draw them raise, at the call site. See Fontico.check!.
        Rails.logger.error("fontico: #{Fontico.build_error.message}") if Fontico.build_error
      end

      # Both halves are load-bearing: Rails runs to_run callbacks only when
      # some registered reloader reports itself updated.
      app.reloaders << watcher
      app.reloader.to_run { watcher.execute_if_updated }
    end

    rake_tasks { load File.expand_path("../tasks/fontico.rake", __dir__) }

    # First-party SVGs are sources too, and editing one has to re-preprocess.
    # Asked of the manifest, but never at the cost of the boot: an icons.yml
    # too broken to parse must still come up, because the watcher is what
    # picks up the fix.
    def self.local_dirs
      path = begin
        Fontico.manifest.local_path
      rescue StandardError
        Manifest::LOCAL_PATH
      end
      dir = File.join(Fontico.root, path)
      File.directory?(dir) ? { dir => %w[svg] } : {}
    end
  end
end
