# frozen_string_literal: true

require "rackup/handler"

require_relative "../../yamiochi"

module Rackup
  module Handler
    module Yamiochi
      def self.run(app, **options)
        ::Yamiochi::Server.new(
          app: app,
          host: options.fetch(:Host, ::Yamiochi::Server::DEFAULT_HOST),
          port: options.fetch(:Port, ::Yamiochi::Server::DEFAULT_PORT)
        ).run
      end
    end

    register(:yamiochi, Yamiochi)
  end
end
