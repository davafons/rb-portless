# frozen_string_literal: true

require "rbconfig"
require "fileutils"

module Portless
  # An OS service that binds the privileged port at boot, so after a one-time
  # `service install` you never see a sudo prompt again. macOS → LaunchDaemon,
  # Linux → systemd unit, Windows → Task Scheduler (phase 3). Mirrors portless's
  # service.ts. Install/uninstall self-elevate via sudo.
  module Service
    module_function

    LABEL = "rb.portless.proxy"

    def install(tls: true, port: nil)
      port ||= Daemon.default_port(tls)
      return elevate([ "service", "install", "--port", port.to_s, tls ? "--tls" : "--no-tls" ]) unless privileged_ok?

      Constants::MACOS ? install_launchd(port, tls) : install_systemd(port, tls)
      puts "portless-rb: boot service installed (binds :#{port})"
    end

    def uninstall
      return elevate([ "service", "uninstall" ]) unless privileged_ok?

      Constants::MACOS ? uninstall_launchd : uninstall_systemd
      puts "portless-rb: boot service removed"
    end

    def status
      if Constants::MACOS
        system("launchctl", "print", "system/#{LABEL}", out: $stdout, err: $stdout) ||
          puts("portless-rb: service not installed")
      else
        system("systemctl", "status", "portless-rb", out: $stdout, err: $stdout)
      end
    end

    # ── macOS (launchd) ─────────────────────────────────────────────────────
    def install_launchd(port, tls)
      path = launchd_plist_path
      File.write(path, launchd_plist(port, tls))
      FileUtils.chown("root", "wheel", path)
      system("launchctl", "bootout", "system/#{LABEL}", err: File::NULL)
      system("launchctl", "bootstrap", "system", path) || raise(Error, "launchctl bootstrap failed")
      system("launchctl", "enable", "system/#{LABEL}")
      system("launchctl", "kickstart", "-k", "system/#{LABEL}")
    end

    def uninstall_launchd
      system("launchctl", "bootout", "system/#{LABEL}", err: File::NULL)
      File.delete(launchd_plist_path) if File.exist?(launchd_plist_path)
    end

    def launchd_plist_path = "/Library/LaunchDaemons/#{LABEL}.plist"

    def launchd_plist(port, tls)
      args = daemon_argv(port, tls).map { |a| "    <string>#{a}</string>" }.join("\n")
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>#{LABEL}</string>
          <key>ProgramArguments</key>
          <array>
        #{args}
          </array>
          <key>EnvironmentVariables</key>
          <dict><key>PORTLESS_STATE_DIR</key><string>#{State.dir}</string></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardOutPath</key><string>#{State.proxy_log}</string>
          <key>StandardErrorPath</key><string>#{State.proxy_log}</string>
        </dict>
        </plist>
      PLIST
    end

    # ── Linux (systemd) ─────────────────────────────────────────────────────
    def install_systemd(port, tls)
      File.write(systemd_unit_path, systemd_unit(port, tls))
      system("systemctl", "daemon-reload")
      system("systemctl", "enable", "--now", "portless-rb") || raise(Error, "systemctl enable failed")
    end

    def uninstall_systemd
      system("systemctl", "disable", "--now", "portless-rb", err: File::NULL)
      File.delete(systemd_unit_path) if File.exist?(systemd_unit_path)
      system("systemctl", "daemon-reload")
    end

    def systemd_unit_path = "/etc/systemd/system/portless-rb.service"

    def systemd_unit(port, tls)
      <<~UNIT
        [Unit]
        Description=portless-rb proxy
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        Environment=PORTLESS_STATE_DIR=#{State.dir}
        ExecStart=#{daemon_argv(port, tls).join(' ')}
        Restart=on-failure

        [Install]
        WantedBy=multi-user.target
      UNIT
    end

    # The argv the service runs at boot: the proxy daemon in the foreground.
    def daemon_argv(port, tls)
      [ RbConfig.ruby, "-I", Daemon.lib_dir, Privilege.program,
        "proxy", "start", "--foreground", "--port", port.to_s, tls ? "--tls" : "--no-tls" ]
    end

    def privileged_ok? = Constants::WINDOWS || Privilege.root?

    def elevate(args)
      raise Error, "Windows service install is not wired yet (phase 3)" if Constants::WINDOWS

      ENV["PORTLESS_STATE_DIR"] ||= State.dir # bake the user's state dir for the root daemon
      Privilege.reexec_with_sudo(args) || raise(Error, "sudo required to manage the boot service")
    end
  end
end
