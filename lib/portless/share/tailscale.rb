# frozen_string_literal: true

require "json"

module Portless
  module Share
    # Expose the local app on your tailnet (`serve`) or publicly (`funnel`) via
    # the tailscale CLI. Returns { mode:, url: } or nil. EXPERIMENTAL. Mirrors
    # portless's tailscale.ts.
    module Tailscale
      module_function

      def start(backend_port:, funnel: false)
        return nil unless Portless.which("tailscale")

        mode = funnel ? "funnel" : "serve"
        ok = system("tailscale", mode, "--bg", "--https=443", "http://127.0.0.1:#{backend_port}",
                    out: File::NULL, err: File::NULL)
        return nil unless ok

        url = magic_dns_url
        url ? { mode: mode, url: url } : nil
      rescue StandardError
        nil
      end

      def stop(handle)
        return unless handle && Portless.which("tailscale")

        system("tailscale", handle[:mode], "--https=443", "off", out: File::NULL, err: File::NULL)
      rescue StandardError
        nil
      end

      # The machine's MagicDNS name → its tailnet HTTPS URL.
      def magic_dns_url
        json = JSON.parse(`tailscale status --json 2>/dev/null`)
        dns = json.dig("Self", "DNSName").to_s.chomp(".")
        dns.empty? ? nil : "https://#{dns}"
      rescue StandardError
        nil
      end
    end
  end
end
