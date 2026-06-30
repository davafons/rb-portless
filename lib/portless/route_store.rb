# frozen_string_literal: true

require "json"
require "fileutils"

module Portless
  # The on-disk routing table (routes.json): host → backend port → owning pid.
  # No daemon API — apps register/deregister by editing this file under a
  # directory mutex (atomic mkdir), and the proxy watches it. Dead-pid entries
  # are reaped on every load. Mirrors portless's RouteStore.
  class RouteStore
    Route = Struct.new(:hostname, :port, :pid, keyword_init: true) do
      def alias? = pid.to_i.zero? # pid 0 = static alias (never reaped)
    end

    LOCK_STALE_SECONDS = 10
    LOCK_BUDGET_SECONDS = 5

    def initialize(file: State.routes_file, lock: State.routes_lock)
      @file = file
      @lock = lock
    end

    def routes
      load.map { |h| Route.new(hostname: h["hostname"], port: h["port"], pid: h["pid"]) }
    end

    # Register (or replace) a route. Conflicts with a *live* different owner raise
    # unless force, which SIGTERMs the incumbent. Alias routes use pid 0.
    def add(hostname:, port:, pid:, force: false)
      with_lock do
        all = load.reject { |r| dead?(r["pid"]) }
        existing = all.find { |r| r["hostname"] == hostname }
        if existing && existing["pid"].to_i != pid.to_i && !dead?(existing["pid"])
          raise Error, "#{hostname} is already served by pid #{existing['pid']}" unless force
          terminate(existing["pid"])
        end
        all.reject! { |r| r["hostname"] == hostname }
        all << { "hostname" => hostname, "port" => port, "pid" => pid }
        write(all)
      end
    end

    # Remove a route only if still owned by `owner_pid` (so a force-replaced
    # predecessor doesn't delete the successor's route on its way out).
    def remove(hostname, owner_pid: nil)
      with_lock do
        all = load
        all.reject! do |r|
          r["hostname"] == hostname && (owner_pid.nil? || r["pid"].to_i == owner_pid.to_i)
        end
        write(all)
      end
    end

    def prune
      with_lock { write(load.reject { |r| dead?(r["pid"]) }) }
    end

    private

    def load
      return [] unless File.exist?(@file)
      JSON.parse(File.read(@file))
    rescue JSON::ParserError
      []
    end

    def write(routes)
      State.ensure_dir!
      File.write(@file, JSON.pretty_generate(routes))
      File.chmod(0o644, @file)
      State.fix_ownership(@file)
    end

    def with_lock
      State.ensure_dir!
      deadline = monotonic + LOCK_BUDGET_SECONDS
      loop do
        begin
          Dir.mkdir(@lock)
          break
        rescue Errno::EEXIST
          steal_stale_lock
          raise Error, "could not acquire routes lock" if monotonic > deadline
          sleep(0.02 + rand * 0.03)
        end
      end
      begin
        yield
      ensure
        Dir.rmdir(@lock) rescue nil
      end
    end

    def steal_stale_lock
      age = monotonic_mtime(@lock)
      Dir.rmdir(@lock) if age && age > LOCK_STALE_SECONDS
    rescue StandardError
      nil
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def monotonic_mtime(path) = (Time.now - File.mtime(path)) rescue nil

    def dead?(pid)
      pid = pid.to_i
      return false if pid.zero? # alias
      !alive?(pid)
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true # exists, owned by someone else (e.g. root proxy)
    end

    def terminate(pid)
      Process.kill("TERM", pid.to_i)
    rescue StandardError
      nil
    end
  end
end
