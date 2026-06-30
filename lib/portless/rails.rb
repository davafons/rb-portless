# frozen_string_literal: true

# Opt-in Rails integration: `require "portless/rails"` (e.g. in config/application.rb
# or via `gem "portless-rb", require: "portless/rails"` in the dev group). It just
# whitelists *.localhost hosts in development so portless-rb's named subdomains
# aren't blocked by Action Dispatch host authorization. Everything else (PORT,
# X-Forwarded-*) Rails already handles for a loopback proxy.
#
# Lightweight on purpose — does NOT load the proxy stack into your app.
require "rails/railtie"

module Portless
  class Railtie < ::Rails::Railtie
    initializer "portless.development_hosts" do |app|
      next unless defined?(Rails) && Rails.env.development?
      next unless app.config.respond_to?(:hosts)

      # Rails wraps a Regexp as /\A<re>(:port)?\z/, so this must match the whole
      # host (any depth of *.localhost) and leave the port to Rails.
      matcher = /.+\.localhost/
      app.config.hosts << matcher unless app.config.hosts.include?(matcher)
    end
  end
end
