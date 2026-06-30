# frozen_string_literal: true

module Portless
  # Install / remove our CA in the OS trust store so browsers accept the per-host
  # certs. macOS uses the login keychain (GUI/Touch-ID auth — no sudo). A
  # ca.trusted fingerprint marker short-circuits the check. Linux/Windows land in
  # phase 3. Mirrors portless's trustCA paths.
  module Trust
    module_function

    def certs = @certs ||= Certs.new

    def trusted?
      certs.ensure_ca!
      marker_matches?
    end

    def install!
      certs.ensure_ca!
      raise Error, unsupported_message unless Constants::MACOS

      ok = system("security", "add-trusted-cert", "-r", "trustRoot", "-k", login_keychain, State.ca_cert)
      raise Error, "failed to trust the CA via `security add-trusted-cert`" unless ok

      write_marker
    end

    def uninstall!
      return unless Constants::MACOS && File.exist?(State.ca_cert)

      system("security", "remove-trusted-cert", State.ca_cert)
      File.delete(State.ca_trusted_marker) if File.exist?(State.ca_trusted_marker)
    end

    def marker_matches?
      File.exist?(State.ca_trusted_marker) &&
        File.read(State.ca_trusted_marker).strip == certs.ca_fingerprint
    rescue StandardError
      false
    end

    def write_marker
      File.write(State.ca_trusted_marker, certs.ca_fingerprint)
      State.fix_ownership
    end

    def login_keychain
      out = `security login-keychain -d user 2>/dev/null`.strip.delete('"')
      out.empty? ? File.expand_path("~/Library/Keychains/login.keychain-db") : out
    end

    def unsupported_message
      "automatic CA trust isn't wired for this OS yet — trust #{State.ca_cert} manually (phase 3)"
    end
  end
end
