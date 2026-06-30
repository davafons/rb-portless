# frozen_string_literal: true

require "json"

module Portless
  module Share
    # Expose the local app on your tailnet (`serve`) or publicly (`funnel`) via
    # the tailscale CLI. Returns { mode:, port:, url: } or nil. EXPERIMENTAL.
    #
    # SAFETY (mirrors portless's tailscale.ts): we never clobber your existing
    # serve config — we read `tailscale serve status` for ports already in use
    # and pick the first FREE one from the preferred list, register with `--yes`
    # (no prompt), and on teardown turn off ONLY the port we registered.
    module Tailscale
      module_function

      PREFERRED_SERVE_PORTS = [ 443, 8443, 8444, 8445, 8446, 8447, 8448, 8449, 8450 ].freeze
      FUNNEL_PORTS = [ 443, 8443, 10_000 ].freeze # Funnel supports only these

      def start(backend_port:, funnel: false)
        return nil unless Portless.which("tailscale")

        mode = funnel ? "funnel" : "serve"
        port = available_port(funnel: funnel)
        return nil unless port # all preferred ports already in use → don't fight it

        ok = system("tailscale", mode, "--bg", "--yes", "--https=#{port}",
                    "http://127.0.0.1:#{backend_port}", out: File::NULL, err: File::NULL)
        return nil unless ok

        base = magic_dns_url
        return (off(mode, port) and nil) unless base

        { mode: mode, port: port, url: format_url(base, port) }
      rescue StandardError
        nil
      end

      def stop(handle)
        return unless handle && Portless.which("tailscale")

        off(handle[:mode], handle[:port])
      end

      # Turn off ONLY the registration we created (scoped to our port).
      def off(mode, port)
        system("tailscale", mode, "--yes", "--https=#{port}", "off", out: File::NULL, err: File::NULL)
      rescue StandardError
        nil
      end

      # First free HTTPS port from the preferred pool, never one already in use by
      # the user's existing serve/funnel config. nil if the funnel pool is full.
      def available_port(funnel:)
        used = used_serve_ports
        pool = funnel ? FUNNEL_PORTS : PREFERRED_SERVE_PORTS
        free = pool.find { |port| !used.include?(port) }
        return free if free
        return nil if funnel

        port = PREFERRED_SERVE_PORTS.last + 1
        port += 1 while used.include?(port)
        port
      end

      # HTTPS ports the user's current serve config already occupies.
      def used_serve_ports
        config = JSON.parse(`tailscale serve status --json 2>/dev/null`)
        ports = []
        (config["Web"] || {}).each_key { |host_port| ports << Regexp.last_match(1).to_i if host_port =~ /:(\d+)\z/ }
        (config["TCP"] || {}).each_key { |port| ports << port.to_i }
        ports
      rescue StandardError
        []
      end

      def magic_dns_url
        json = JSON.parse(`tailscale status --json 2>/dev/null`)
        dns = json.dig("Self", "DNSName").to_s.chomp(".")
        dns.empty? ? nil : "https://#{dns}"
      rescue StandardError
        nil
      end

      def format_url(base, port)
        base = base.chomp("/")
        port == 443 ? base : "#{base}:#{port}"
      end
    end
  end
end
