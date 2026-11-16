# frozen_string_literal: true

require "rbconfig"
require "socket"
require "timeout"

module Portless
  # The privileged-port trick (ports < 1024): probe-bind first, and only when
  # that fails with EACCES re-run the CLI under `sudo env PORTLESS_*=… ruby
  # <cli> …` so the elevated process binds the socket itself. Mirrors
  # portless's canBindProxyPort / canBindWithoutRoot / getProxyBindTargets /
  # collectPortlessEnvArgs (cli-utils.ts, cli.ts).
  module Privilege
    module_function

    SUDO_SPAWN_TIMEOUT = 30

    IPV4_LOOPBACK = "127.0.0.1"
    IPV6_LOOPBACK = "::1"
    IPV4_ANY = "0.0.0.0"
    IPV6_ANY = "::"

    def root? = Process.respond_to?(:uid) && Process.uid.zero?

    def privileged_port?(port) = port.to_i < Constants::PRIVILEGED_PORT_THRESHOLD

    # Explicit IPv4+IPv6 listener targets. LAN and unprivileged mode bind the
    # unspecified addresses (macOS lets non-root take <1024 only there).
    # cli-utils.ts getProxyBindTargets.
    def bind_targets(lan_mode, unprivileged = false)
      if lan_mode || unprivileged
        [ { host: IPV4_ANY }, { host: IPV6_ANY, ipv6_only: true } ]
      else
        [ { host: IPV4_LOOPBACK }, { host: IPV6_LOOPBACK, ipv6_only: true } ]
      end
    end

    # May this process bind `port` on every target without root? false only on
    # EACCES/EPERM; anything else (EADDRINUSE…) is left for the real listen.
    # cli-utils.ts canBindProxyPort.
    def can_bind_proxy_port?(port, targets)
      targets.none? do |target|
        code = probe_bind(port, target)
        %i[EACCES EPERM].include?(code)
      end
    end

    def probe_bind(port, target)
      family = target[:host].include?(":") ? Socket::AF_INET6 : Socket::AF_INET
      sock = Socket.new(family, Socket::SOCK_STREAM, 0)
      sock.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, 1) if target[:ipv6_only]
      sock.bind(Socket.sockaddr_in(port, target[:host]))
      nil
    rescue Errno::EACCES
      :EACCES
    rescue Errno::EPERM
      :EPERM
    rescue SystemCallError => e
      e.class.name.split("::").last.to_sym
    ensure
      sock&.close
    end

    # Does starting on `port` need sudo? Only when a probe bind on the real
    # listener targets fails. cli.ts proxyPortNeedsElevation.
    def needs_elevation?(port, lan_mode)
      return false if Constants::WINDOWS || !privileged_port?(port) || root?

      lan_bind = lan_mode && Mdns.supported[:supported]
      !can_bind_proxy_port?(port, bind_targets(lan_bind))
    end

    # Can we bind `port` without root on this platform? cli-utils.ts
    # canBindWithoutRoot. → {ok: true} | {ok: false, reason:}
    def can_bind_without_root(port, platform: host_platform,
                              read_unprivileged_port_start: -> { File.read("/proc/sys/net/ipv4/ip_unprivileged_port_start") })
      return { ok: true } if port >= Constants::PRIVILEGED_PORT_THRESHOLD || %w[darwin win32].include?(platform)
      return { ok: false, reason: "Binding port #{port} without root is not supported on #{platform}." } unless platform == "linux"

      start = begin
        Integer(read_unprivileged_port_start.call.to_s.strip, exception: false)
      rescue StandardError
        return { ok: false, reason: "Could not read net.ipv4.ip_unprivileged_port_start." }
      end
      return { ok: true } if start && port >= start

      { ok: false,
        reason: "Port #{port} is below net.ipv4.ip_unprivileged_port_start (#{start || 'unreadable'})." }
    end

    def host_platform
      os = RbConfig::CONFIG["host_os"]
      case os
      when /darwin/i then "darwin"
      when /linux/i then "linux"
      when /mswin|mingw|cygwin/i then "win32"
      else os
      end
    end

    # A real terminal we can prompt on (upstream: stdin TTY and no CI).
    def interactive?
      $stdin.tty? && (ENV["CI"].nil? || ENV["CI"].empty?)
    end

    # PORTLESS_* env as KEY=VAL for `sudo env …` (sudo strips the env).
    # cli.ts collectPortlessEnvArgs.
    def portless_env_args(env = ENV, omit: [])
      env.select { |k, v| k.start_with?("PORTLESS_") && v && !v.empty? && !omit.include?(k) }
         .map { |k, v| "#{k}=#{v}" }
    end

    # spawnSync's result: the exit status, or the spawn error message
    # ("spawnSync sudo ETIMEDOUT" when the timeout killed it).
    SpawnResult = Struct.new(:status, :error) do
      def success? = error.nil? && !!status&.success?
    end

    # spawnSync("sudo", argv, { stdio: "inherit", timeout }).
    def run_sudo(argv, timeout: SUDO_SPAWN_TIMEOUT)
      pid = Process.spawn("sudo", *argv)
      timed_out = false
      status = wait_with_timeout(pid, timeout) { timed_out = true }
      SpawnResult.new(status, timed_out ? "spawnSync sudo ETIMEDOUT" : nil)
    rescue SystemCallError => e
      SpawnResult.new(nil, "spawnSync sudo #{e.class.name.split('::').last}")
    end

    # `sudo env PORTLESS_*… ruby <cli> *args` with inherited stdio.
    def sudo(args, timeout: SUDO_SPAWN_TIMEOUT)
      run_sudo([ "env", *portless_env_args, *cli_argv, *args ], timeout: timeout)
    end

    def reexec_with_sudo(args) = sudo(args).success?

    # Wait for pid; past the timeout SIGTERM it (yielding first) and reap it.
    def wait_with_timeout(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          yield if block_given?
          Process.kill("TERM", pid) rescue nil # rubocop:disable Style/RescueModifier
          _, status = Process.wait2(pid)
          return status
        end
        sleep 0.05
      end
    end

    # The executable to re-invoke: the exe path (gem wrapper or exe/rb-portless).
    def program = File.expand_path($PROGRAM_NAME)

    # How to re-run this CLI: `ruby -I <lib> <exe>` (upstream: execPath + entry
    # script). -I keeps a dev checkout loading its own lib under sudo.
    def cli_argv = [ RbConfig.ruby, "-I", lib_dir, program ]

    def lib_dir = File.expand_path("..", __dir__)
  end
end
