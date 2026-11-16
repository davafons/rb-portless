# frozen_string_literal: true

module Portless
  # Cloudflare quick tunnels via `cloudflared tunnel --url …`. The URL counts
  # only once a tunnel connection has registered. Mirrors portless's
  # cloudflare.ts.
  module Cloudflare
    module_function

    def build_args(port, host, config)
      flags = [ "--no-autoupdate", "--grace-period", "1s", "--config", config ]
      [ "tunnel", *flags, "--url", "http://127.0.0.1:#{port}", "--http-host-header", host ]
    end

    def extract_url(output)
      url = output[%r{https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com}]
      url && output.match?(/Registered tunnel connection|Connection \S+ registered/) ? url : nil
    end

    def format_output_error(output)
      errors = output.scan(/.* ERR .*/)
      details = errors.map { |line| Tunnel.normalize_space(line) }.join(" ")
      details = "cloudflared exited before connecting" if details.empty?
      Error.new("Failed to start Cloudflare tunnel: #{details}")
    end

    def provider(host: "", config: "")
      Tunnel::Provider.new(
        binary: "cloudflared", version_args: [ "--version" ],
        build_args: ->(port, _opts) { build_args(port, host, config) },
        extract_url: method(:extract_url), format_output_error: method(:format_output_error),
        not_found: "cloudflared CLI not found. Install cloudflared " \
                   "(https://developers.cloudflare.com/tunnel/downloads/) and ensure `cloudflared` is on PATH.",
        timeout: "Timed out waiting for cloudflared to connect. Check that outbound UDP port 7844 is open, " \
                 "or set TUNNEL_TRANSPORT_PROTOCOL=http2 and try again."
      )
    end

    # Writes an empty config so cloudflared ignores ~/.cloudflared/config.yml.
    def start(port, config_path:, host_header: "", **opts, &on_exit)
      File.write(config_path, "{}")
      Tunnel.start_tunnel(provider(host: host_header, config: config_path), port, **opts, &on_exit)
    end
  end
end
