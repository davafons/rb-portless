# frozen_string_literal: true

# Opt-in Rails integration. Add to your Gemfile's dev group:
#
#   gem "rb-portless", require: "portless/rails"
#
# It auto-detects when the app is being run through `rb-portless run` (via the
# PORTLESS_URL env the runner injects) and *only then* whitelists the matching
# `*.localhost` hosts in development — so Action Dispatch host authorization
# doesn't 403 your named subdomains. Run Rails normally (not under rb-portless)
# and nothing is touched. Lightweight: does NOT load the proxy stack.
require "rails/railtie"
require_relative "rails_hosts"

module Portless
  class Railtie < ::Rails::Railtie
    initializer "portless.development_hosts" do |app|
      next unless defined?(Rails) && Rails.env.development?
      next unless app.config.respond_to?(:hosts)

      RailsHosts.allowed.each do |pattern|
        app.config.hosts << pattern unless app.config.hosts.include?(pattern)
      end
    end
  end
end
