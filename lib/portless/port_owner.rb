# frozen_string_literal: true

require "socket"
require "timeout"

module Portless
  # Process and port introspection: who listens on a port, a process's start
  # time / command / group, and whether a port accepts connections. Shells out
  # to lsof/ps like portless's cli-utils.ts (findPidsOnPort, getProcessStartTime,
  # getProcessCommand, getProcessGroupId, isPortListening) and silently returns
  # nothing when the tools are missing.
  module PortOwner
    module_function

    SOCKET_TIMEOUT = 0.5
    PID_LOOKUP_TIMEOUT = 5

    # Every pid listening on TCP `port`. cli-utils.ts findPidsOnPort.
    def pids_on_port(port)
      return windows_pids_on_port(port) if Constants::WINDOWS

      out = capture("lsof", "-ti", "tcp:#{Integer(port)}", "-sTCP:LISTEN")
      return [] unless out

      out.split.filter_map { |p| Integer(p, exception: false) }.select(&:positive?)
    rescue StandardError
      []
    end

    def pid_on_port(port) = pids_on_port(port).first

    def windows_pids_on_port(port)
      out = capture("netstat", "-ano", "-p", "tcp") or return []
      pid = parse_pid_from_netstat(out, port)
      pid ? [ pid ] : []
    end

    # cli-utils.ts parsePidFromNetstat.
    def parse_pid_from_netstat(output, port)
      output.each_line do |line|
        next unless line.include?("LISTENING")

        parts = line.strip.split(/\s+/)
        next if parts.length < 5

        local = parts[1]
        idx = local.rindex(":") or next
        next unless local[(idx + 1)..].to_i == port

        pid = Integer(parts.last, exception: false)
        return pid if pid&.positive?
      end
      nil
    end

    # A stable identity for a live pid, so a recycled pid can be told apart.
    # cli-utils.ts getProcessStartTime.
    def start_time(pid)
      return nil if Constants::WINDOWS || !pid.is_a?(Integer) || pid <= 0

      if linux?
        stat = File.read("/proc/#{pid}/stat")
        fields = stat[(stat.rindex(")") + 2)..].split
        return fields[19]
      end
      out = capture({ "LC_ALL" => "C", "TZ" => "UTC" }, "ps", "-o", "lstart=", "-p", pid.to_s)
      value = out.to_s.strip.gsub(/\s+/, " ")
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    # The executable basename of a pid. cli-utils.ts getProcessCommand.
    def command(pid)
      return nil unless pid.is_a?(Integer) && pid.positive?

      out = capture("ps", "-o", "comm=", "-p", pid.to_s).to_s.strip
      out.empty? ? nil : File.basename(out)
    rescue StandardError
      nil
    end

    # cli-utils.ts getProcessGroupId.
    def process_group_id(pid)
      return nil if Constants::WINDOWS || !pid.is_a?(Integer) || pid <= 0

      pgid = Integer(capture("ps", "-o", "pgid=", "-p", pid.to_s).to_s.strip, exception: false)
      pgid&.positive? ? pgid : nil
    rescue StandardError
      nil
    end

    # The kernel's state letters for a live pid (cli.ts readProcessState).
    def process_state(pid)
      if linux?
        stat = File.read("/proc/#{pid}/stat")
        value = stat[(stat.rindex(")") + 2)..].split.first
        return value.to_s.empty? ? nil : value
      end
      return nil unless Constants::MACOS

      out = capture("ps", "-o", "stat=", "-p", pid.to_s).to_s.strip
      out.empty? ? nil : out
    rescue StandardError
      nil
    end

    # Exists, treating permission denial as alive. utils.ts isProcessAlive.
    def alive?(pid)
      return false unless pid.is_a?(Integer) && pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end

    # Alive and not a zombie. cli.ts isProcessRunning.
    def running?(pid)
      return false unless alive?(pid)

      state = process_state(pid)
      state.nil? ? alive?(pid) : !state.match?(/\A[ZX]/)
    end

    # SIGSTOPped / under a debugger; nil when unknown. cli.ts isProcessSuspended.
    def suspended?(pid)
      state = process_state(pid)
      state.nil? ? nil : state.match?(/\A[Tt]/)
    end

    # Does anything accept TCP connections on either loopback? cli-utils.ts
    # isPortListening.
    # Both loopbacks are raced; an unfinished probe is cancelled at the deadline.
    def port_listening?(port, timeout: SOCKET_TIMEOUT)
      result = Queue.new
      cancel = Utils.create_loopback_connection(port) do |error, socket|
        socket&.close
        result << error.nil?
      end
      listening = result.pop(timeout: timeout)
      return listening unless listening.nil?

      cancel.call
      result.pop
    end

    def linux? = RbConfig::CONFIG["host_os"].match?(/linux/i)

    def capture(*cmd)
      env = cmd.first.is_a?(Hash) ? cmd.shift : {}
      return nil unless Portless.which(cmd.first)

      IO.popen(env, cmd, err: File::NULL) do |io|
        Timeout.timeout(PID_LOOKUP_TIMEOUT) { io.read }
      end
    rescue StandardError
      nil
    end
  end
end
