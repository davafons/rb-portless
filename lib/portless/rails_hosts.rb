# frozen_string_literal: true

require "uri"

module Portless
  # The host matchers to whitelist in Rails development, derived from the URL
  # `rb-portless run` injects (PORTLESS_URL). Plain Ruby so it's testable without
  # booting Rails; the Railtie is just glue around it.
  module RailsHosts
    module_function

    # Empty unless we're actually running under rb-portless.
    def allowed(portless_url = ENV["PORTLESS_URL"])
      return [] if portless_url.to_s.empty?

      # Rails wraps a Regexp as /\A<re>(:port)?\z/, so match the whole host.
      patterns = [ /.+\.localhost/ ]

      host = begin
        URI(portless_url).host
      rescue StandardError
        nil
      end
      # Support a custom, non-.localhost tld (e.g. *.myapp.test) too.
      patterns.push(host, ".#{host}") if host && !host.end_with?(".localhost")
      patterns
    end

    # The `default_url_options` (host + scheme) that mailers, jobs, and other
    # request-less URL generation need so their links point at the portless URL
    # instead of a bare `localhost:<random-port>`. Nil unless we're running
    # under rb-portless. The standard 80/443 ports are dropped (portless serves
    # without a port number); a custom one is carried through.
    def url_options(portless_url = ENV["PORTLESS_URL"])
      return if portless_url.to_s.empty?

      uri = begin
        URI(portless_url)
      rescue StandardError
        nil
      end
      return unless uri&.host

      options = { host: uri.host, protocol: uri.scheme }
      options[:port] = uri.port if uri.port && ![ 80, 443 ].include?(uri.port)
      options
    end

    # Action Cable rejects a WebSocket whose `Origin` isn't in
    # `allowed_request_origins`; under rb-portless that's the portless host and
    # any of its subdomains (tenant hosts), over the portless scheme — not the
    # `localhost` default. Empty unless we're running under rb-portless.
    def cable_origins(portless_url = ENV["PORTLESS_URL"])
      options = url_options(portless_url) or return []

      host = Regexp.escape(options[:host])
      [ %r{\A#{options[:protocol]}://([\w-]+\.)*#{host}(:\d+)?\z} ]
    end
  end
end
