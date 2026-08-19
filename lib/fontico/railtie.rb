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

    rake_tasks { load File.expand_path("../tasks/fontico.rake", __dir__) }
  end
end
