# frozen_string_literal: true

require "open3"

module Portless
  # Process-tree / process-group helpers the run lifecycle needs: tracking a
  # command's descendants for the shutdown grace period, finding the listener
  # a self-daemonizing command left behind, and stopping an orphaned group
  # without ever signalling a recycled group id. Mirrors the matching
  # functions of portless's cli-utils.ts. Per-pid lookups (start time, pgid,
  # listeners) come from PortOwner.
  module ProcessGroup
    module_function

    SIGNAL_CODES = { "HUP" => 1, "INT" => 2, "QUIT" => 3, "ABRT" => 6, "KILL" => 9, "TERM" => 15 }.freeze
    PROCESS_GROUP_EXIT_TIMEOUT = 2.0
    PROCESS_GROUP_POLL = 0.1
    POLL = 0.05

    Stop = Struct.new(:state, :signaled, :survivor, keyword_init: true)

    def ps(*args)
      out, status = Open3.capture2("ps", *args, err: File::NULL)
      status.success? ? out : nil
    rescue StandardError
      nil
    end

    # Adds root + every descendant ({pid => pgid}) to `tracked`.
    def track_process_tree(root_pid, tracked)
      tracked[root_pid] = root_pid
      out = ps("-axo", "pid=,ppid=,pgid=") or return
      rows = out.lines.filter_map do |line|
        m = line.strip.match(/\A(\d+)\s+(\d+)\s+(\d+)\z/)
        m && m.captures.map(&:to_i)
      end
      descendants = [ root_pid ]
      loop do
        found = rows.select { |pid, ppid, _| descendants.include?(ppid) && !descendants.include?(pid) }
        break if found.empty?

        descendants.concat(found.map(&:first))
      end
      rows.each { |pid, _, pgid| tracked[pid] = pgid if descendants.include?(pid) }
    end

    def running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end

    def any_running?(tracked) = tracked.keys.any? { |pid| running?(pid) }

    def signal_tracked(tracked, signal)
      tracked.values.uniq.each do |pgid|
        Process.kill(signal, -pgid)
      rescue StandardError
        nil
      end
    end

    def group_alive?(group_id)
      return false unless group_id.is_a?(Integer) && group_id > 1

      Process.kill(0, -group_id)
      true
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end

    # Live (non-zombie) members of a group, or nil when groups can't be listed.
    def list_members(group_id)
      return nil unless group_id.is_a?(Integer) && group_id > 1

      out = ps("-e", "-o", "pid=,pgid=,stat=") or return nil
      out.lines.filter_map do |line|
        pid, group, stat = line.strip.split(/\s+/)
        next if group.to_i != group_id || pid.to_i <= 1 || stat.to_s.start_with?("Z")

        pid.to_i
      end
    end

    def live_member?(group_id)
      members = list_members(group_id)
      members.nil? ? group_alive?(group_id) : !members.empty?
    end

    def group_member?(pid, start_time, group_id)
      !start_time.nil? && pid > 1 && PortOwner.process_group_id(pid) == group_id &&
        PortOwner.start_time(pid) == start_time
    end

    # The listener a self-daemonizing command left on `port`, waiting up to
    # `timeout` while its group lives (or after a clean exit).
    def find_self_daemonized_listener(port, group_id, timeout, exited_cleanly = false)
      deadline = monotonic + timeout
      loop do
        if PortOwner.port_listening?(port)
          pid = PortOwner.pid_on_port(port)
          return pid if pid
        end
        return nil if !(group_id && group_alive?(group_id)) && !exited_cleanly
        return nil if monotonic >= deadline

        sleep POLL
      end
    end

    def pick_survivor(group_id, excluded, port)
      members = list_members(group_id) || []
      listeners = port ? PortOwner.pids_on_port(port).select { |pid| members.include?(pid) } : []
      (listeners + members).each do |pid|
        next if excluded.include?(pid)

        start = PortOwner.start_time(pid)
        return { pid: pid, start_time: start } if start
      end
      nil
    end

    # Signal a recorded group only while a recorded identity still matches.
    def stop_process_group(group_id, leader_start_times, recorded_members, signal = "TERM", port: nil,
                           timeout: PROCESS_GROUP_EXIT_TIMEOUT)
      return Stop.new(state: "gone", signaled: false) unless live_member?(group_id)

      proven = leader_start_times.any? { |st| group_member?(group_id, st, group_id) } ||
               recorded_members.any? { |m| group_member?(m[:pid], m[:start_time], group_id) }
      return Stop.new(state: "unverified", signaled: false) unless proven

      signaled = begin
        Process.kill(signal, -group_id)
        true
      rescue StandardError
        false
      end
      deadline = monotonic + timeout
      while live_member?(group_id)
        if monotonic < deadline
          sleep PROCESS_GROUP_POLL
          next
        end
        excluded = [ group_id, *recorded_members.map { |m| m[:pid] } ]
        return Stop.new(state: "survived", signaled: signaled, survivor: pick_survivor(group_id, excluded, port))
      end
      Stop.new(state: "stopped", signaled: signaled)
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
