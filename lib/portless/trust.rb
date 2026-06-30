# frozen_string_literal: true

module Portless
  # Install / remove our CA in the OS trust store so browsers accept the per-host
  # certs. macOS uses the login keychain (GUI/Touch-ID auth — no sudo); Linux
  # drops it in the distro anchor dir + runs update-ca-trust (sudo). Firefox and
  # Chrome-on-Linux ignore the OS store and read their own NSS DBs, so we also
  # install via `certutil` into every Firefox profile + `~/.pki/nssdb`. A
  # ca.trusted fingerprint marker short-circuits the check. Mirrors mkcert/
  # portless's trustCA paths.
  module Trust
    module_function

    # The nickname our CA carries inside NSS DBs (Firefox/Chrome).
    NSS_NICKNAME = "rb-portless Local CA"

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
      install_nss # Firefox (every OS) + Chrome-on-Linux read their own NSS DBs.
      write_marker
    end

    def uninstall!
      return unless File.exist?(State.ca_cert)

      uninstall_nss
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
      FileUtils.cp(State.ca_cert, File.join(dir, "rb-portless.crt"))
      system(*update) || raise(Error, "failed to run #{update.first}")
    end

    def uninstall_linux
      dir, update = linux_anchor
      crt = File.join(dir, "rb-portless.crt")
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

    # ── Firefox / Chrome NSS DBs (no sudo — they live under $HOME) ─────────
    # Browsers that ship their own cert store ignore the OS trust anchor, so add
    # the CA to each NSS DB directly. Best-effort: a missing certutil or a single
    # failing profile must never abort the trust flow.
    def install_nss
      dbs = nss_dbs
      return if dbs.empty?
      return warn_no_certutil unless certutil

      dbs.each do |db|
        system(certutil, "-A", "-d", "sql:#{db}", "-t", "C,,", "-n", NSS_NICKNAME, "-i", State.ca_cert,
               out: File::NULL, err: File::NULL)
      end
    end

    def uninstall_nss
      return unless certutil

      nss_dbs.each do |db|
        system(certutil, "-D", "-d", "sql:#{db}", "-n", NSS_NICKNAME, out: File::NULL, err: File::NULL)
      end
    end

    # Every NSS DB worth trusting into: Chrome's shared store plus each Firefox
    # profile. An NSS sql DB is a directory holding a cert9.db.
    def nss_dbs(home = Dir.home)
      ([ File.join(home, ".pki", "nssdb") ] + firefox_profiles(home))
        .select { |db| File.exist?(File.join(db, "cert9.db")) }
        .uniq
    end

    # Firefox keeps a profile dir (each with its own cert9.db) under a handful of
    # roots depending on packaging — native, Snap, Flatpak, and macOS.
    def firefox_profiles(home = Dir.home)
      [
        File.join(home, ".mozilla", "firefox"),
        File.join(home, "snap", "firefox", "common", ".mozilla", "firefox"),
        File.join(home, ".var", "app", "org.mozilla.firefox", ".mozilla", "firefox"),
        File.join(home, "Library", "Application Support", "Firefox", "Profiles")
      ].select { |root| File.directory?(root) }.flat_map do |root|
        Dir.children(root).map { |child| File.join(root, child) }
           .select { |dir| File.exist?(File.join(dir, "cert9.db")) }
      end
    end

    def warn_no_certutil
      warn "rb-portless: install `nss`/`libnss3-tools` (certutil) to trust the CA in Firefox/Chrome"
    end

    # certutil's path, or nil. Memoised; resolved off PATH so we never shell out
    # just to probe for it.
    def certutil
      return @certutil if defined?(@certutil)

      @certutil = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "certutil") }
                     .find { |path| File.executable?(path) && !File.directory?(path) }
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
      "automatic CA trust isn't wired for this OS yet — trust #{State.ca_cert} manually"
    end
  end
end
