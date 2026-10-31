# frozen_string_literal: true

module HeuristicSyndicate
  module RailsIntegration
    # Optional Railtie that activates only when Ruby on Rails is loaded.
    if defined?(::Rails::Railtie)
      class Railtie < ::Rails::Railtie
        initializer "heuristic_syndicate.autoload_paths" do |app|
          %w[agents tools pipelines actions components].each do |dir|
            path = app.root.join("app", dir)
            app.config.autoload_paths << path.to_s if File.directory?(path)
          end
        end
      end
    end
  end
end
