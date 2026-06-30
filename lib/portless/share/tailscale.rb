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
        unless Portless.which("tailscale")
          warn "rb-portless: tailscale not found — install it (https://tailscale.com/download) to use --tailscale"
          return nil
        end

        status = status_json
        unless status
          warn "rb-portless: tailscale isn't connected — run `tailscale up`, then retry"
          return nil
        end
        unless capability?(status, "https")
          warn "rb-portless: tailscale HTTPS certs aren't enabled — turn on HTTPS in your tailnet DNS settings"
          return nil
        end
        if funnel && !capability?(status, "funnel")
          warn "rb-portless: tailscale Funnel isn't enabled for this node — enable it, then retry --funnel"
          return nil
        end

        mode = funnel ? "funnel" : "serve"
        port = available_port(funnel: funnel)
        unless port
          warn "rb-portless: all tailscale Funnel ports are in use (443/8443/10000)"
          return nil
        end

        unless system("tailscale", mode, "--bg", "--yes", "--https=#{port}",
                      "http://127.0.0.1:#{backend_port}", out: File::NULL, err: File::NULL)
          warn "rb-portless: `tailscale #{mode}` failed to register"
          return nil
        end

        base = dns_name(status)
        return (off(mode, port) and nil) unless base

        { mode: mode, port: port, url: format_url(base, port) }
      rescue StandardError => e
        warn "rb-portless: tailscale sharing failed (#{e.message})"
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

      def status_json
        json = JSON.parse(`tailscale status --json 2>/dev/null`)
        json.is_a?(Hash) ? json : nil
      rescue StandardError
        nil
      end

      def dns_name(status)
        dns = status.dig("Self", "DNSName").to_s.chomp(".")
        dns.empty? ? nil : "https://#{dns}"
      end

      # Does this node have the HTTPS / Funnel capability? (mirrors portless)
      def capability?(status, name)
        node = status["Self"] || {}
        names = Array(node["Capabilities"]) + (node["CapMap"] || {}).keys
        names.any? { |cap| down = cap.to_s.downcase; down == name || down.end_with?("/#{name}") }
      end

      def format_url(base, port)
        base = base.chomp("/")
        port == 443 ? base : "#{base}:#{port}"
      end
    end
  end
end
