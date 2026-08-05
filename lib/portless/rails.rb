# frozen_string_literal: true

# Opt-in Rails integration. Add to your Gemfile's dev group:
#
#   gem "rb-portless", require: "portless/rails"
#
# It auto-detects when the app is being run through `rb-portless run` (via the
# PORTLESS_URL env the runner injects) and *only then*:
#
#   * whitelists the matching `*.localhost` hosts in development — so Action
#     Dispatch host authorization doesn't 403 your named subdomains, and
#   * points `default_url_options` at the portless URL — so mailers and jobs
#     (which generate links without a request) link to https://<name>.localhost
#     instead of a bare localhost:<random-port>.
#
# Run Rails normally (not under rb-portless) and nothing is touched. Lightweight:
# does NOT load the proxy stack.
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

    # Under rb-portless the app is reached at https://<name>.localhost, not the
    # random backend port — so request-less URL generation must target that. We
    # own default_url_options here (authoritatively, when running under portless)
    # rather than leave every app to hardcode a now-wrong localhost:port in
    # development.rb. `config.action_mailer.default_url_options` is applied to the
    # mailer lazily on load, so setting it after the env config still wins.
    initializer "portless.default_url_options" do |app|
      next unless defined?(Rails) && Rails.env.development?

      options = RailsHosts.url_options or next

      # The router's defaults cover jobs and any request-less url_for (mailers
      # merge them in too). Set the mailer's own default_url_options via on_load
      # so we win over Rails' earlier action_mailer.set_configs regardless of
      # railtie order. merge_url_options drops a stale app-configured :port
      # (e.g. `port: 3000`) that would otherwise survive into every link.
      app.routes.default_url_options.replace(
        RailsHosts.merge_url_options(app.routes.default_url_options, options)
      )
      ActiveSupport.on_load(:action_mailer) do
        self.default_url_options = RailsHosts.merge_url_options(default_url_options, options)
      end
    end

    # Allow the portless origin (and its subdomains) through Action Cable's
    # WebSocket origin check — otherwise the handshake from https://<name>.
    # localhost is rejected and Cable silently never connects.
    initializer "portless.action_cable_origins" do |app|
      next unless defined?(Rails) && Rails.env.development?
      # Apps without Action Cable (API-only, trimmed railties) have no
      # config.action_cable — touching it would crash boot.
      next unless app.config.respond_to?(:action_cable)

      origins = RailsHosts.cable_origins
      next if origins.empty?

      # Array(): apps idiomatically set a bare Regexp (Rails' own dev default
      # is one) — concat on it would crash boot; a frozen array would too.
      app.config.action_cable.allowed_request_origins =
        Array(app.config.action_cable.allowed_request_origins) + origins
    end
  end
end
