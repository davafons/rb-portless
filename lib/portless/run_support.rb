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
        # Let the app's own server-side TLS verification trust our CA.
        "SSL_CERT_FILE" => (File.exist?(State.ca_cert) ? State.ca_cert : nil)
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
