# frozen_string_literal: true

require "rbconfig"

module Portless
  # Starting/stopping the proxy daemon, including the privileged-port dance:
  # for ports < 1024 we re-exec under sudo; the elevated process spawns the
  # detached daemon that binds the socket as root. Falls back to :1355 when sudo
  # is unavailable. Mirrors portless's handleProxy + ensureProxyRunning.
  module Daemon
    module_function

    def ensure_running(tls:, lan: false)
      port = Health.discover_port
      port = nil if tls && port == Constants::HTTP_PORT

      if port && lan && !lan_active?
        # The proxy binds loopback-only by default; --lan needs it reachable
        # from the network, so switch the running daemon over.
        warn "rb-portless: restarting the proxy in LAN mode (it was loopback-only)"
        restart(tls: tls, port: port, lan: true)
        return Health.discover_port || port
      end
      if port && !recorded_tls.nil? && recorded_tls != tls
        # Another project started the daemon in the other TLS mode; don't fight
        # over it — that used to spawn a rival proxy on the default port.
        warn "rb-portless: the proxy is serving #{recorded_tls ? 'HTTPS' : 'HTTP'} but this project " \
             "sets tls: #{tls} — keeping the running proxy " \
             "(`rb-portless proxy restart #{tls ? '--tls' : '--no-tls'}` to switch)"
      end
      return refresh_stale(port, tls: tls) if port

      start(tls: tls, lan: lan)
      Health.discover_port
    end

    # Was the running proxy started in LAN mode? (Marker written by the daemon.)
    def lan_active? = File.exist?(State.proxy_lan_file)

    # The TLS mode the running daemon recorded, or nil (no marker / old daemon).
    def recorded_tls
      value = File.read(State.proxy_tls_file).strip
      value != "0"
    rescue StandardError
      nil
    end

    # The daemon outlives gem updates — after a `bundle update` the process on
    # :443 may still be running last week's code. Compare the version it stamps
    # on its responses with ours and offer to restart it; the reverse mismatch
    # (a newer proxy) means this project's gem is the stale side.
    def refresh_stale(port, tls:)
      running = Health.proxy_version(port)
      case version_action(running, VERSION)
      when :restart
        if restart_consented?(running)
          restart(tls: tls, port: port)
          port = Health.discover_port || port
        else
          warn "rb-portless: keeping the v#{running} proxy — run `rb-portless proxy restart` when ready"
        end
      when :update_gem
        warn "rb-portless: the proxy is v#{running} but this project loads rb-portless v#{VERSION} — " \
             "update the gem (`bundle update rb-portless`) so they match"
      end
      port
    end

    # nil → proxy unreadable or versions equal: leave it alone.
    def version_action(running, current)
      return nil unless running

      case Gem::Version.new(running) <=> Gem::Version.new(current)
      when -1 then :restart
      when 1 then :update_gem
      end
    rescue ArgumentError
      nil
    end

    def restart_consented?(running)
      warn "rb-portless: the running proxy is v#{running}; this rb-portless is v#{VERSION}"
      return false unless Privilege.interactive?

      $stderr.print "rb-portless: restart the proxy to pick up the update? [Y/n] "
      !$stdin.gets.to_s.strip.downcase.start_with?("n")
    end

    def restart(tls: nil, port: nil, lan: nil)
      # A plain restart keeps the daemon's recorded modes; explicit flags win.
      tls = recorded_tls if tls.nil?
      tls = true if tls.nil?
      lan = lan_active? if lan.nil?
      port ||= Integer(ENV["PORTLESS_PORT"], exception: false) || default_port(tls)
      stop
      wait_until_stopped(port) if port
      start(tls: tls, port: port, lan: lan)
    end

    # foreground: become the daemon (binds the port, blocks). Otherwise
    # orchestrate: elevate if needed, then spawn the detached foreground daemon.
    def start(tls:, port: nil, foreground: false, lan: false)
      port ||= Integer(ENV["PORTLESS_PORT"], exception: false) || default_port(tls)

      return Proxy.new(port: port, tls: tls, lan: lan).run if foreground
      return if Health.proxy_running?(port)

      if Privilege.needs_sudo?(port) && !Privilege.root?
        start_privileged(port: port, tls: tls, lan: lan)
      else
        spawn_detached(port: port, tls: tls, lan: lan)
      end
    end

    def stop
      pid = read_pid || discovered_pid
      unless pid
        # A proxy answers but we can't see who owns the port (a root daemon
        # whose marker files were lost) — retry the whole stop under sudo.
        return Privilege.reexec_with_sudo([ "proxy", "stop" ]) if Health.discover_port && !Privilege.root?

        warn "rb-portless: no proxy is running"
        return
      end

      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      cleanup_markers
    rescue Errno::EPERM
      # Proxy owned by root (privileged bind) — stop it with sudo.
      Privilege.reexec_with_sudo([ "proxy", "stop" ]) unless Privilege.root?
    end

    # Fallback when the pid marker is missing: whoever listens on the port the
    # proxy answered from (lsof only sees our own processes unless root).
    def discovered_pid
      port = Health.discover_port or return nil

      PortOwner.listeners(port).find { |pid| pid != Process.pid }
    end

    def start_privileged(port:, tls:, lan: false)
      unless Privilege.interactive?
        # Don't silently fall back to :1355 here — that changes every URL
        # (OAuth redirect URIs, bookmarks) with nobody watching. Fail with the
        # ways out instead, like portless does in CI.
        raise NonInteractiveError,
              "binding :#{port} needs sudo and there's no terminal to ask — pre-start the proxy " \
              "(`rb-portless proxy start`), install the boot service (`rb-portless service install`), " \
              "or set PORTLESS_PORT to an unprivileged port"
      end

      warn "rb-portless: binding :#{port} needs sudo (it's a privileged port) — " \
           "enter your password to serve #{tls ? 'HTTPS' : 'HTTP'} without a port number"
      ok = Privilege.reexec_with_sudo([ "proxy", "start", "--port", port.to_s,
                                        tls ? "--tls" : "--no-tls", *(lan ? [ "--lan" ] : []) ])
      return wait_until_running(port) if ok

      warn "rb-portless: sudo declined — using :#{Constants::FALLBACK_PROXY_PORT}"
      spawn_detached(port: Constants::FALLBACK_PROXY_PORT, tls: tls, lan: lan)
    end

    def spawn_detached(port:, tls:, lan: false)
      State.ensure_dir!
      log = File.open(State.proxy_log, "a")
      args = [ RbConfig.ruby, "-I", lib_dir, Privilege.program,
               "proxy", "start", "--foreground", "--port", port.to_s,
               tls ? "--tls" : "--no-tls", *(lan ? [ "--lan" ] : []) ]
      pid = Process.spawn(*args, out: log, err: log, pgroup: true)
      Process.detach(pid)
      log.close
      wait_until_running(port)
    end

    def wait_until_running(port, timeout: 10)
      deadline = monotonic + timeout
      until Health.proxy_running?(port)
        return false if monotonic > deadline

        sleep 0.2
      end
      State.fix_ownership
      true
    end

    # A restart can't rebind the port until the old daemon has let go of it.
    def wait_until_stopped(port, timeout: 10)
      deadline = monotonic + timeout
      while Health.proxy_running?(port)
        return false if monotonic > deadline

        sleep 0.2
      end
      true
    end

    def default_port(tls) = tls ? Constants::HTTPS_PORT : Constants::HTTP_PORT

    def read_pid
      Integer(File.read(State.proxy_pid_file).strip, exception: false) if File.exist?(State.proxy_pid_file)
    end

    def cleanup_markers
      [ State.proxy_pid_file, State.proxy_port_file ].each { |f| File.delete(f) if File.exist?(f) }
    end

    def lib_dir = File.expand_path("..", __dir__)
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
