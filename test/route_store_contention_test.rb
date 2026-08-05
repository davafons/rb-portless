# frozen_string_literal: true

require_relative "test_helper"

# The mkdir-lock under real cross-process contention (what a monorepo run or
# several parallel `run`s produce), modeled on upstream's 20-app parallel e2e.
class RouteStoreContentionTest < Minitest::Test
  WRITERS = 15

  def test_concurrent_adds_from_many_processes_all_land
    # Writers must stay alive until we assert: `add` reaps dead-pid routes, so
    # an exited writer's entry is legitimately swept by a later add.
    holds = []
    dones = []
    pids = WRITERS.times.map do |i|
      hold_r, hold_w = IO.pipe
      done_r, done_w = IO.pipe
      holds << hold_w
      dones << done_r
      pid = fork do
        hold_w.close
        done_r.close
        Portless::RouteStore.new.add(hostname: "contend-#{i}.localhost", port: 4000 + i, pid: Process.pid)
        done_w.write(".")
        hold_r.read # block until the parent releases us
        exit! 0
      end
      hold_r.close
      done_w.close
      pid
    end

    Timeout.timeout(20) { dones.each { |r| r.read(1) } } # every writer finished its add

    hostnames = Portless::RouteStore.new.routes.map(&:hostname)
    WRITERS.times do |i|
      assert_includes hostnames, "contend-#{i}.localhost"
    end
  ensure
    holds&.each(&:close)
    pids&.each do |pid|
      Process.wait(pid)
    rescue StandardError
      nil
    end
    Portless::RouteStore.new.prune
  end

  def test_a_stale_lock_is_stolen_not_fatal
    Portless::State.ensure_dir!
    Dir.mkdir(Portless::State.routes_lock)
    # Backdate the lock dir beyond the staleness threshold.
    old = Time.now - (Portless::RouteStore::LOCK_STALE_SECONDS + 5)
    File.utime(old, old, Portless::State.routes_lock)

    store = Portless::RouteStore.new
    store.add(hostname: "stale-lock.localhost", port: 4999, pid: Process.pid)
    assert_includes store.routes.map(&:hostname), "stale-lock.localhost"
  ensure
    Portless::RouteStore.new.remove("stale-lock.localhost")
    Dir.rmdir(Portless::State.routes_lock) rescue nil
  end
end
