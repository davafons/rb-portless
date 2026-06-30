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
      if Constants::MACOS
        install_macos
      elsif linux?
        install_linux
      else
        raise Error, unsupported_message
      end
      write_marker
    end

    def uninstall!
      return unless File.exist?(State.ca_cert)

      if Constants::MACOS
        system("security", "remove-trusted-cert", State.ca_cert)
      elsif linux?
        uninstall_linux
      end
      File.delete(State.ca_trusted_marker) if File.exist?(State.ca_trusted_marker)
    end

    # ── macOS ────────────────────────────────────────────────────────────
    def install_macos
      ok = system("security", "add-trusted-cert", "-r", "trustRoot", "-k", login_keychain, State.ca_cert)
      raise Error, "failed to trust the CA via `security add-trusted-cert`" unless ok
    end

    # ── Linux (distro anchors + update tool; needs root) ─────────────────
    def install_linux
      dir, update = linux_anchor
      return elevate if !Privilege.root? && !File.writable?(dir)

      require "fileutils"
      FileUtils.cp(State.ca_cert, File.join(dir, "portless-rb.crt"))
      system(*update) || raise(Error, "failed to run #{update.first}")
    end

    def uninstall_linux
      dir, update = linux_anchor
      crt = File.join(dir, "portless-rb.crt")
      File.delete(crt) if File.exist?(crt)
      system(*update)
    end

    # Map the distro to its CA anchor dir + refresh command.
    def linux_anchor
      id = File.read("/etc/os-release")[/^ID=(\w+)/, 1] rescue nil
      case id
      when "fedora", "rhel", "centos", "rocky", "almalinux"
        [ "/etc/pki/ca-trust/source/anchors", %w[update-ca-trust] ]
      when "arch", "manjaro"
        [ "/etc/ca-certificates/trust-source/anchors", %w[update-ca-trust] ]
      else # debian/ubuntu and friends
        [ "/usr/local/share/ca-certificates", %w[update-ca-certificates] ]
      end
    end

    def elevate
      Privilege.reexec_with_sudo([ "trust" ]) || raise(Error, "sudo required to trust the CA on Linux")
    end

    def linux? = RbConfig::CONFIG["host_os"] =~ /linux/i

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
