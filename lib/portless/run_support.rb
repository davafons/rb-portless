# frozen_string_literal: true

module Portless
  # Shared bits of the two run paths (single-app Runner + multi-app Multi):
  # the child env, the display URL, and first-run CA trust. Both expect a
  # `@config`.
  module RunSupport
    private

    def child_env(port, url)
      base = {
        "PORT" => port.to_s,
        "HOST" => "127.0.0.1",
        "PORTLESS_URL" => url,
        # Under --lan, let the app (the Rails railtie) whitelist <name>.local
        # too — it's not covered by any host-authorization default.
        "PORTLESS_LAN_HOST" => @lan_host,
        # Public tunnel URLs (when sharing): tailscale forwards with the raw
        # *.ts.net Host, so the app must whitelist it — and apps can
        # self-reference their public address (mirrors portless).
        "PORTLESS_TAILSCALE_URL" => @tailscale&.dig(:url),
        "PORTLESS_NGROK_URL" => @ngrok&.dig(:url),
        # Let the app's own server-side TLS verification trust our CA — via a
        # bundle that *also* carries the public roots, so SSL_CERT_FILE replacing
        # the trust store doesn't break the app's outbound HTTPS. See CaBundle.
        "SSL_CERT_FILE" => CaBundle.path,
        # Node ignores SSL_CERT_FILE; NODE_EXTRA_CA_CERTS *adds* to its default
        # roots, so the bare CA is enough (mirrors portless). Respect an
        # existing value — additions can only live in one file.
        "NODE_EXTRA_CA_CERTS" => ENV["NODE_EXTRA_CA_CERTS"] ||
          (State.ca_cert if File.exist?(State.ca_cert))
      }.compact
      # Our own bundle (rb-portless is loaded via the app's Bundler binstub) must
      # not leak into the dev command — a foreman-style `bin/dev` isn't in the
      # app Gemfile and each Procfile process re-enters Bundler via its binstub.
      unbundled_overrides.merge(base)
    end

    # ENV deltas that undo Bundler for the child (a nil value unsets the key).
    # Empty when we're not running under Bundler at all.
    def unbundled_overrides
      return {} unless defined?(Bundler) && Bundler.respond_to?(:unbundled_env)

      target = Bundler.unbundled_env
      (ENV.keys | target.keys).each_with_object({}) do |key, deltas|
        deltas[key] = target[key] if ENV[key] != target[key]
      end
    rescue StandardError
      {}
    end

    def display_url(hostname, proxy_port)
      scheme = @config.tls ? "https" : "http"
      default = @config.tls ? Constants::HTTPS_PORT : Constants::HTTP_PORT
      suffix = proxy_port && proxy_port != default ? ":#{proxy_port}" : ""
      "#{scheme}://#{hostname}#{suffix}"
    end

    # Trust the local CA on first run (HTTPS only, interactive; never blocks the
    # run), so HTTPS works without browser warnings — like portless.
    def ensure_trusted
      return unless @config.tls
      return if Trust.trusted?

      unless Privilege.interactive?
        warn "rb-portless: CA not trusted — run `rb-portless trust` (HTTPS shows warnings until then)"
        return
      end

      warn "rb-portless: trusting the local CA (first run)…"
      Trust.install!
    rescue Portless::Error => e
      warn "rb-portless: couldn't auto-trust the CA (#{e.message}) — run `rb-portless trust`"
    end
  end
end
