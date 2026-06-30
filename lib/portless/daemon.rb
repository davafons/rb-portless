# frozen_string_literal: true

require "rbconfig"

module Portless
  # Starting/stopping the proxy daemon, including the privileged-port dance:
  # for ports < 1024 we re-exec under sudo; the elevated process spawns the
  # detached daemon that binds the socket as root. Falls back to :1355 when sudo
  # is unavailable. Mirrors portless's handleProxy + ensureProxyRunning.
  module Daemon
    module_function

    def ensure_running(tls:)
      port = Health.discover_port
      return port if port

      start(tls: tls)
      Health.discover_port
    end

    # foreground: become the daemon (binds the port, blocks). Otherwise
    # orchestrate: elevate if needed, then spawn the detached foreground daemon.
    def start(tls:, port: nil, foreground: false)
      port ||= Integer(ENV["PORTLESS_PORT"], exception: false) || default_port(tls)

      return Proxy.new(port: port, tls: tls).run if foreground
      return if Health.proxy_running?(port)

      if Privilege.needs_sudo?(port) && !Privilege.root?
        start_privileged(port: port, tls: tls)
      else
        spawn_detached(port: port, tls: tls)
      end
    end

    def stop
      pid = read_pid
      unless pid
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

    def start_privileged(port:, tls:)
      unless Privilege.interactive?
        warn "rb-portless: can't bind :#{port} without a terminal — using :#{Constants::FALLBACK_PROXY_PORT}"
        return spawn_detached(port: Constants::FALLBACK_PROXY_PORT, tls: tls)
      end

      ok = Privilege.reexec_with_sudo([ "proxy", "start", "--port", port.to_s, tls ? "--tls" : "--no-tls" ])
      return wait_until_running(port) if ok

      warn "rb-portless: sudo declined — using :#{Constants::FALLBACK_PROXY_PORT}"
      spawn_detached(port: Constants::FALLBACK_PROXY_PORT, tls: tls)
    end

    def spawn_detached(port:, tls:)
      State.ensure_dir!
      log = File.open(State.proxy_log, "a")
      args = [ RbConfig.ruby, "-I", lib_dir, Privilege.program,
               "proxy", "start", "--foreground", "--port", port.to_s, tls ? "--tls" : "--no-tls" ]
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
