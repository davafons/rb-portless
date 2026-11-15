# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "securerandom"
require "timeout"

module Portless
  # Install / remove the local CA in the OS trust store, exactly like
  # portless's certs.ts isCATrusted / trustCA / untrustCA: macOS keychain via
  # `security` (login keychain, or System when root), Linux distro anchor dir
  # + update tool. A ca.trusted fingerprint marker short-circuits the check.
  # Windows / WSL trust (windows-ca.ts) is not ported (no machine to verify).
  module Trust
    module_function

    CA_CERT_FILE = "ca.pem"
    CA_TRUST_MARKER = "ca.trusted"
    CA_TRUST_REFRESH_PENDING = "ca.trust-refresh-pending"
    LINUX_CERT_NAME = "rb-portless-ca.crt"
    MACOS_SECURITY_TIMEOUT = 15
    MACOS_SECURITY_AUTH_TIMEOUT = 120
    MACOS_SECURITY_ROOT_TIMEOUT = 60
    LINUX_UPDATE_TIMEOUT = 30

    LINUX_CA_TRUST_CONFIGS = {
      "debian" => { cert_dir: "/usr/local/share/ca-certificates", update_command: "update-ca-certificates" },
      "arch" => { cert_dir: "/etc/ca-certificates/trust-source/anchors", update_command: "update-ca-trust" },
      "fedora" => { cert_dir: "/etc/pki/ca-trust/source/anchors", update_command: "update-ca-trust" },
      "suse" => { cert_dir: "/etc/pki/trust/anchors", update_command: "update-ca-certificates" }
    }.freeze

    def ca_common_name
      defined?(Certs::CA_COMMON_NAME) ? Certs::CA_COMMON_NAME : Certs::CA_SUBJECT.delete_prefix("/CN=")
    end

    def file_readable?(path) = File.readable?(path)

    def ca_fingerprint(state_dir)
      Digest::SHA256.hexdigest(File.binread(File.join(state_dir, CA_CERT_FILE)))
    rescue StandardError
      nil
    end

    def read_trust_marker(state_dir)
      path = File.join(state_dir, CA_TRUST_MARKER)
      stat = File.lstat(path)
      return nil if !stat.file? || stat.symlink?

      value = File.read(path).strip
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    # Replace a marker without following a symlink at the destination.
    def write_state_marker_file(path, content)
      dir = File.dirname(path)
      raise Error, "Refusing to write marker in unsafe state directory: #{dir}" unless State.cleanable?(dir)

      tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
      flags = File::CREAT | File::EXCL | File::WRONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      begin
        File.open(tmp, flags, 0o644) { |f| f.write(content) }
        State.fix_ownership(tmp)
        File.rename(tmp, path)
      rescue StandardError
        FileUtils.rm_f(tmp)
        raise
      end
    end

    def pending_refresh?(path)
      stat = File.lstat(path)
      stat.file? && !stat.symlink?
    rescue StandardError
      false
    end

    def clear_trust_refresh_pending(state_dir) = FileUtils.rm_f(File.join(state_dir, CA_TRUST_REFRESH_PENDING))

    def write_trust_marker(state_dir)
      fp = ca_fingerprint(state_dir) or return
      canonical = File.realpath(state_dir)
      clear_trust_refresh_pending(canonical)
      write_state_marker_file(File.join(canonical, CA_TRUST_MARKER), "#{fp}\n")
    end

    def clear_trust_marker(state_dir) = FileUtils.rm_f(File.join(state_dir, CA_TRUST_MARKER))

    def platform = Privilege.host_platform

    # Is our CA in the system trust store? certs.ts isCATrusted.
    def trusted?(state_dir = State.dir)
      ca = File.join(state_dir, CA_CERT_FILE)
      return false unless file_readable?(ca)

      marker = read_trust_marker(state_dir)
      return true if marker && marker == ca_fingerprint(state_dir)

      case platform
      when "darwin" then trusted_macos?(ca)
      when "linux" then trusted_linux?(state_dir)
      else false
      end
    end

    def run!(cmd, timeout)
      out, status = Timeout.timeout(timeout) { Open3.capture2e(*cmd) }
      raise Error, out.strip.empty? ? "#{cmd.first} failed" : out.strip unless status.success?

      out
    rescue Timeout::Error
      raise Error, "ETIMEDOUT"
    end

    def run?(cmd, timeout)
      run!(cmd, timeout)
      true
    rescue StandardError
      false
    end

    # Checked from the browser user's view when running as root under sudo.
    def trusted_macos?(ca_path)
      verify = [ "security", "verify-cert", "-c", ca_path, "-L", "-p", "ssl" ]
      sudo_user = ENV["SUDO_USER"]
      cmd = Privilege.root? && sudo_user && !sudo_user.empty? ? [ "sudo", "-u", sudo_user, *verify ] : verify
      run?(cmd, MACOS_SECURITY_TIMEOUT)
    end

    def login_keychain_path
      home = State.resolve_user_home
      sudo_user = ENV["SUDO_USER"]
      if Privilege.root? && sudo_user && !sudo_user.empty? && sudo_user != "root"
        return File.join(home, "Library", "Keychains", "login.keychain-db")
      end

      out = run!([ "security", "default-keychain" ], MACOS_SECURITY_TIMEOUT).strip
      out[/"(.+)"/, 1] || File.join(home, "Library", "Keychains", "login.keychain-db")
    rescue StandardError
      File.join(home, "Library", "Keychains", "login.keychain-db")
    end

    def detect_linux_distro
      begin
        os_release = File.read("/etc/os-release").downcase
        return "arch" if os_release.include?("arch")
        return "fedora" if %w[fedora rhel centos].any? { |n| os_release.include?(n) }
        return "suse" if os_release.include?("suse")
        return "debian" if os_release.include?("debian") || os_release.include?("ubuntu")
      rescue StandardError
        nil
      end
      LINUX_CA_TRUST_CONFIGS.each do |distro, config|
        return distro if Portless.which(config[:update_command]) && File.exist?(File.dirname(config[:cert_dir]))
      end
      nil
    end

    def linux_config = LINUX_CA_TRUST_CONFIGS[detect_linux_distro || "debian"]

    def trusted_linux?(state_dir, config = linux_config)
      system_cert = File.join(config[:cert_dir], LINUX_CERT_NAME)
      return false unless file_readable?(system_cert)

      File.read(File.join(state_dir, CA_CERT_FILE)).strip == File.read(system_cert).strip
    rescue StandardError
      false
    end

    # Add the CA to the system trust store → {trusted:, error:}.
    # certs.ts trustCA.
    def trust_ca(configured_state_dir = State.dir)
      unless file_readable?(File.join(configured_state_dir, CA_CERT_FILE))
        return { trusted: false, error: "CA certificate not found. Run rb-portless trust to generate it." }
      end

      unsafe = State.explain_unsafe_state_dir(configured_state_dir)
      return { trusted: false, error: "Refusing to trust the CA in #{configured_state_dir}: #{unsafe}" } if unsafe

      state_dir = File.realpath(configured_state_dir)
      ca = File.join(state_dir, CA_CERT_FILE)
      case platform
      when "darwin"
        if Privilege.root?
          run!([ "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl", "-k",
                 "/Library/Keychains/System.keychain", ca ], MACOS_SECURITY_ROOT_TIMEOUT)
        else
          run!([ "security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", login_keychain_path, ca ],
               MACOS_SECURITY_AUTH_TIMEOUT)
        end
        write_trust_marker(state_dir)
        { trusted: true }
      when "linux"
        config = linux_config
        FileUtils.mkdir_p(config[:cert_dir])
        FileUtils.cp(ca, File.join(config[:cert_dir], LINUX_CERT_NAME))
        run!([ config[:update_command] ], LINUX_UPDATE_TIMEOUT)
        write_trust_marker(state_dir)
        { trusted: true }
      else
        { trusted: false, error: "Unsupported platform: #{platform}" }
      end
    rescue StandardError => e
      message = e.message
      if message.include?("ETIMEDOUT")
        hint = if platform == "darwin"
                 "The macOS security command timed out. This can happen when the Keychain Services daemon is " \
                   "unresponsive or a system authorization dialog was not dismissed in time. Try restarting " \
                   "Keychain Access (or run: sudo killall securityd) and then: rb-portless trust"
        else
                 "The trust command timed out. Try: rb-portless trust"
        end
        return { trusted: false, error: hint }
      end
      if message.include?("authorization") || message.include?("permission") || e.is_a?(Errno::EACCES) ||
         message.include?("EACCES") || message.include?("Permission denied")
        return { trusted: false, error: "Permission denied. Try: rb-portless trust" }
      end

      { trusted: false, error: message }
    end

    # CLI convenience: generate the CA if needed and trust it; raises Error
    # with trustCA's message on failure.
    def install!(state_dir = State.dir)
      Daemon.ensure_certs(state_dir)
      result = trust_ca(state_dir)
      raise Error, result[:error] || "Could not add the CA to the system trust store." unless result[:trusted]

      true
    end

    def trust_refresh_pending?(state_dir = State.dir) = pending_refresh?(File.join(state_dir, CA_TRUST_REFRESH_PENDING))

    # Remove the CA from the trust store → {removed:, error:}. certs.ts untrustCA.
    def untrust_ca(state_dir = State.dir)
      ca = File.join(state_dir, CA_CERT_FILE)
      unless file_readable?(ca)
        clear_trust_marker(state_dir)
        return { removed: true }
      end

      result = case platform
      when "darwin" then untrust_macos(ca)
      when "linux" then untrust_linux(state_dir)
      else { removed: false, error: "Unsupported platform: #{platform}" }
      end
      clear_trust_marker(state_dir) if result[:removed]
      result
    rescue StandardError => e
      { removed: false, error: e.message }
    end

    def untrust_macos(ca_path)
      errors = []
      try_exec = lambda do |args|
        run!([ "security", *args ], MACOS_SECURITY_ROOT_TIMEOUT)
        true
      rescue StandardError => e
        errors << e.message
        false
      end

      try_exec.call([ "remove-trusted-cert", ca_path ])
      # delete-certificate -c fails when several certs share the CN; loop
      # until each keychain has none left.
      [ login_keychain_path, "/Library/Keychains/System.keychain" ].each do |keychain|
        20.times { break unless try_exec.call([ "delete-certificate", "-c", ca_common_name, keychain ]) }
      end

      if trusted_macos?(ca_path)
        { removed: false, error: errors.empty? ? "Could not remove CA from keychain (try sudo)" : errors.join("; ") }
      else
        { removed: true }
      end
    end

    def untrust_linux(state_dir, configs: LINUX_CA_TRUST_CONFIGS.values, active_config: nil, run_update: nil)
      unless State.cleanable?(state_dir)
        return { removed: false, error: "Refusing to untrust CA from unsafe state directory: #{state_dir}" }
      end

      errors = []
      pending_path = File.join(state_dir, CA_TRUST_REFRESH_PENDING)
      refresh_needed = pending_refresh?(pending_path)
      active_config ||= linux_config
      run_update ||= ->(command) { run!([ command ], LINUX_UPDATE_TIMEOUT) }

      configs.each do |config|
        dest = File.join(config[:cert_dir], LINUX_CERT_NAME)
        next unless file_readable?(dest)

        ca = File.join(state_dir, CA_CERT_FILE)
        stat = File.lstat(ca)
        raise Error, "Refusing symlinked CA certificate: #{ca}" if !stat.file? || stat.symlink?

        next unless File.read(ca).strip == File.read(dest).strip

        unless refresh_needed
          write_state_marker_file(pending_path, "1\n")
          refresh_needed = true
        end
        File.unlink(dest)
      rescue StandardError => e
        errors << e.message
      end

      if refresh_needed
        begin
          run_update.call(active_config[:update_command])
        rescue StandardError => e
          errors << e.message
        end
      end

      if !errors.empty? || trusted_linux?(state_dir, active_config)
        return { removed: false,
                 error: errors.empty? ? "CA still trusted (remove #{LINUX_CERT_NAME} and run the distro CA update " \
                                        "command, often with sudo)" : errors.join("; ") }
      end

      clear_trust_refresh_pending(state_dir)
      { removed: true }
    end
  end
end
