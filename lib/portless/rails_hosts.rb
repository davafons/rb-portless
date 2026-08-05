# frozen_string_literal: true

require "uri"

module Portless
  # The host matchers to whitelist in Rails development, derived from the URL
  # `rb-portless run` injects (PORTLESS_URL). Plain Ruby so it's testable without
  # booting Rails; the Railtie is just glue around it.
  module RailsHosts
    module_function

    # Empty unless we're actually running under rb-portless.
    def allowed(portless_url = ENV["PORTLESS_URL"], lan_host = ENV["PORTLESS_LAN_HOST"])
      return [] if portless_url.to_s.empty?

      # Rails wraps a Regexp as /\A<re>(:port)?\z/, so match the whole host.
      patterns = [ /.+\.localhost/ ]

      host = begin
        URI(portless_url).host
      rescue StandardError
        nil
      end
      # A custom, non-.localhost tld too. A regexp, not a ".host" string —
      # Rails' leading-dot shorthand only matches a single subdomain label,
      # which would 403 a.b.myapp.test while a.b.myapp.localhost passes.
      patterns.push(host, /.+\.#{Regexp.escape(host)}/) if host && !host.end_with?(".localhost")
      # The `--lan` mDNS host (<name>.local) — not covered by any default.
      patterns.push(lan_host) unless lan_host.to_s.empty?
      # Public tunnels forward with their own Host (*.ts.net / *.ngrok.app).
      patterns.concat(share_hosts)
      patterns
    end

    # Hostnames of any active public tunnels (`--tailscale` / `--ngrok`),
    # from the env the runner injects.
    def share_hosts(env = ENV)
      [ env["PORTLESS_TAILSCALE_URL"], env["PORTLESS_NGROK_URL"] ].filter_map do |url|
        next if url.to_s.empty?

        begin
          URI(url).host
        rescue StandardError
          nil
        end
      end
    end

    # default_url_options merge that can't leave a stale :port behind: when the
    # portless URL has no explicit port (443/80), an app-configured
    # `port: 3000` must not survive into https://<name>.localhost:3000 links.
    def merge_url_options(existing, options)
      merged = existing.to_h.merge(options)
      merged.delete(:port) unless options.key?(:port)
      merged
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
    def cable_origins(portless_url = ENV["PORTLESS_URL"], lan_host = ENV["PORTLESS_LAN_HOST"])
      options = url_options(portless_url) or return []

      hosts = [ options[:host] ]
      hosts << lan_host unless lan_host.to_s.empty?
      hosts.concat(share_hosts)
      hosts.map do |host|
        %r{\A#{options[:protocol]}://([\w-]+\.)*#{Regexp.escape(host)}(:\d+)?\z}
      end
    end
  end
end
