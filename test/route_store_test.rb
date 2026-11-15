# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"

# Ported from upstream routes.test.ts.
class RouteStoreTest < Minitest::Test
  DEAD_PID = 999_999

  def setup
    @dir = Dir.mktmpdir("portless-routes-test-")
    @store = Portless::RouteStore.new(@dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_routes(routes) = File.write(@store.routes_path, JSON.generate(routes))
  def disk = JSON.parse(File.read(@store.routes_path))

  def test_ensure_dir_creates_nested_directories
    nested = File.join(@dir, "sub", "dir")
    Portless::RouteStore.new(nested).ensure_dir
    assert File.directory?(nested)
    @store.ensure_dir
    @store.ensure_dir
  end

  def test_missing_file_is_an_empty_table
    assert_equal [], @store.load_routes
  end

  def test_invalid_json_raises_and_leaves_the_file_in_place
    File.write(@store.routes_path, "not json{")
    error = assert_raises(Portless::RoutesFileError) { @store.load_routes }
    assert_equal :corrupt, error.reason
    assert_includes error.message, "Corrupted routes file (invalid JSON)"
    assert_equal "not json{", File.read(@store.routes_path)
  end

  def test_non_array_raises
    File.write(@store.routes_path, '{"hostname":"x"}')
    error = assert_raises(Portless::RoutesFileError) { @store.load_routes }
    assert_includes error.message, "expected array"
  end

  def test_recover_moves_a_corrupt_file_aside
    File.write(@store.routes_path, "garbage")
    warnings = []
    store = Portless::RouteStore.new(@dir, on_warning: ->(m) { warnings << m })
    assert store.recover_corrupt_routes_file
    refute File.exist?(store.routes_path)
    assert_equal 1, Dir.glob("#{store.routes_path}.corrupt-*").size
    assert_match(/Moved corrupted routes file/, warnings.first)
    assert_equal [], store.load_routes
  end

  def test_recover_leaves_a_valid_file_alone
    @store.add_route(hostname: "a.localhost", port: 4000, pid: Process.pid)
    refute @store.recover_corrupt_routes_file
    assert_equal 1, @store.load_routes.size
  end

  def test_filters_invalid_entries_and_warns
    warnings = []
    store = Portless::RouteStore.new(@dir, on_warning: ->(m) { warnings << m })
    write_routes([ { hostname: "ok.localhost", port: 4000, pid: 0 }, { hostname: "bad" }, "x" ])
    assert_equal [ "ok.localhost" ], store.load_routes.map(&:hostname)
    assert_match(/Skipped invalid route entries/, warnings.first)
  end

  def test_rejects_malformed_or_unknown_upstream_fields
    write_routes([
                   { hostname: "a.localhost", port: 1, pid: 0, upstream: { tls: true, host: "api.internal:8443" } },
                   { hostname: "b.localhost", port: 1, pid: 0, upstream: { tls: "yes" } },
                   { hostname: "c.localhost", port: 1, pid: 0, upstream: { extra: 1 } },
                   { hostname: "d.localhost", port: 1, pid: 0, upstream: { host: "bad host" } },
                   { hostname: "e.localhost", port: 1, pid: 0, upstream: { host: "[::1]:99999" } }
                 ])
    assert_equal [ "a.localhost" ], @store.load_routes.map(&:hostname)
    assert_equal({ tls: true, host: "api.internal:8443" }, @store.load_routes.first.upstream)
  end

  def test_valid_upstream_examples
    valid = Portless::RouteStore.method(:valid_upstream?)
    assert valid.call({ tls: true })
    assert valid.call({ host: "127.0.0.1:8080" })
    assert valid.call({ host: "[::1]:8443" })
    assert valid.call({ host: "example.com" })
    refute valid.call({ host: "999.1.1.1" })
    refute valid.call({ host: "-bad.com" })
    refute valid.call({ host: "" })
    refute valid.call(nil)
  end

  def test_filters_dead_pids_but_keeps_them_on_disk
    write_routes([ { hostname: "dead.localhost", port: 4000, pid: DEAD_PID },
                   { hostname: "live.localhost", port: 4001, pid: Process.pid } ])
    assert_equal [ "live.localhost" ], @store.load_routes.map(&:hostname)
    assert_equal 2, disk.size
    assert_equal 2, @store.load_routes_raw.size
  end

  def test_unsupported_stored_routes_are_preserved_and_need_force
    unsupported = { "hostname" => "future.localhost", "port" => 4001, "pid" => 0,
                    "upstream" => { "tls" => true, "futureOption" => { "value" => 1 } }, "extra" => "preserve" }
    owned = { "hostname" => "owned.localhost", "port" => 4004, "pid" => Process.pid }
    write_routes([ unsupported, owned ])

    @store.add_route(hostname: "new.localhost", port: 4006, pid: 0, upstream: { tls: true })
    assert_includes disk, unsupported
    @store.update_route("owned.localhost", { ngrok_url: "https://example.test" })
    assert_includes disk, owned.merge("ngrokUrl" => "https://example.test")

    error = assert_raises(Portless::Error) { @store.add_route(hostname: "future.localhost", port: 4444, pid: 0) }
    assert_includes error.message, "has an invalid or unsupported stored route. Use --force to replace it."
    @store.add_route(hostname: "future.localhost", port: 4444, pid: 0, force: true)
    matching = disk.select { |r| r["hostname"] == "future.localhost" }
    assert_equal 1, matching.size
    refute matching.first.key?("upstream")
  end

  def test_invalid_new_upstream_is_rejected_without_writing
    error = assert_raises(Portless::Error) do
      @store.add_route(hostname: "x.localhost", port: 1, pid: 0, upstream: { tls: "yes" })
    end
    assert_equal "Invalid upstream configuration", error.message
    refute File.exist?(@store.routes_path)
  end

  def test_add_persists_camel_case_fields_and_registered_at
    @store.add_route(hostname: "test.localhost", port: 4123, pid: Process.pid)
    raw = disk
    assert_equal 1, raw.size
    assert_equal "test.localhost", raw[0]["hostname"]
    assert_equal 4123, raw[0]["port"]
    assert_equal Process.pid, raw[0]["pid"]
    assert_kind_of Integer, raw[0]["registeredAt"]
    assert_equal 0o644, File.stat(@store.routes_path).mode & 0o777
    refute File.exist?("#{@store.routes_path}.tmp")
  end

  def test_upstream_persists_and_clears_on_replacement
    @store.add_route(hostname: "api.localhost", port: 4001, pid: 0, upstream: { tls: true, host: "api.internal:8443" })
    assert_equal({ "tls" => true, "host" => "api.internal:8443" }, disk[0]["upstream"])
    @store.add_route(hostname: "api.localhost", port: 4002, pid: 0)
    refute disk[0].key?("upstream")
  end

  def test_replaces_same_hostname_and_preserves_others
    @store.add_route(hostname: "a.localhost", port: 4001, pid: Process.pid)
    @store.add_route(hostname: "b.localhost", port: 4002, pid: Process.pid)
    @store.add_route(hostname: "a.localhost", port: 4003, pid: Process.pid)
    assert_equal({ "a.localhost" => 4003, "b.localhost" => 4002 }, @store.load_routes.to_h { |r| [ r.hostname, r.port ] })
  end

  def test_conflict_without_force
    child = spawn("sleep 30")
    @store.add_route(hostname: "a.localhost", port: 4001, pid: child)
    error = assert_raises(Portless::RouteConflictError) { @store.add_route(hostname: "a.localhost", port: 4002, pid: Process.pid) }
    assert_includes error.message, "already registered by a running process (PID #{child})"
    assert_equal child, error.existing_pid
  ensure
    Process.kill("KILL", child) rescue nil
    Process.wait(child) rescue nil
  end

  def test_force_kills_the_existing_process_and_returns_its_pid
    child = spawn("sleep 30")
    @store.add_route(hostname: "a.localhost", port: 4001, pid: child)
    assert_equal child, @store.add_route(hostname: "a.localhost", port: 4002, pid: Process.pid, force: true)
    Process.wait(child)
    assert_equal 4002, @store.load_routes.first.port
  ensure
    Process.kill("KILL", child) rescue nil
  end

  def test_static_alias_needs_force_and_is_replaced_without_signals
    @store.add_route(hostname: "a.localhost", port: 4001, pid: 0)
    error = assert_raises(Portless::RouteConflictError) { @store.add_route(hostname: "a.localhost", port: 4002, pid: Process.pid) }
    assert_includes error.message, "is a static alias"
    assert_nil @store.add_route(hostname: "a.localhost", port: 4002, pid: Process.pid, force: true)
  end

  def test_remove_route_respects_owner
    @store.add_route(hostname: "a.localhost", port: 4001, pid: Process.pid)
    @store.add_route(hostname: "b.localhost", port: 4002, pid: Process.pid)
    @store.remove_route("a.localhost", owner_pid: 12_345)
    assert_equal 2, @store.load_routes.size
    @store.remove_route("a.localhost", owner_pid: Process.pid)
    @store.remove_route("nope.localhost")
    assert_equal [ "b.localhost" ], @store.load_routes.map(&:hostname)
  end

  STALE = { "hostname" => "stale.localhost", "port" => 4310, "pid" => DEAD_PID, "childPgid" => 4242,
            "childStartTime" => "leader-start", "tailscaleHttpsPort" => 8443, "ngrokPid" => 5151,
            "registeredAt" => 1 }.freeze

  def test_stale_record_is_kept_out_of_the_active_view
    write_routes([ STALE ])
    assert_equal [], @store.load_routes
    assert_equal [ STALE ], @store.find_stale_routes.map(&:to_h)
  end

  def test_stale_record_survives_writes_of_other_routes_retired
    write_routes([ STALE ])
    @store.add_route(hostname: "other.localhost", port: 4001, pid: Process.pid)
    @store.update_route("other.localhost", { ngrok_url: "https://other.ngrok.app" })
    assert @store.transfer_route("other.localhost", Process.pid, Process.ppid)
    @store.remove_route("other.localhost", owner_pid: Process.ppid)
    assert_equal [ STALE.merge("retired" => true) ], disk
  end

  def test_same_hostname_registered_again_keeps_the_record_after_the_live_one
    write_routes([ STALE ])
    @store.add_route(hostname: "stale.localhost", port: 4999, pid: Process.pid)
    assert_equal [ 4999 ], @store.load_routes.map(&:port)
    assert_equal 2, disk.size
    assert_equal Process.pid, disk[0]["pid"]
    assert_equal STALE.merge("retired" => true), disk[1]
  end

  def test_retired_record_stays_inactive_after_pid_reuse
    write_routes([ STALE.merge("retired" => true, "pid" => Process.ppid) ])
    assert_equal [], @store.load_routes
    assert_equal 1, @store.find_stale_routes.size
  end

  def test_legacy_file_with_stale_first_returns_live_first
    live = { "hostname" => "stale.localhost", "port" => 4999, "pid" => Process.pid }
    write_routes([ STALE, live ])
    assert_equal 4999, @store.load_routes_raw.first.port
  end

  def test_record_stale_orphan_and_remove_stale_route
    write_routes([ STALE ])
    route = @store.find_stale_routes.first
    assert @store.record_stale_orphan(route, 777, "orphan-start")
    assert_equal 777, disk[0]["orphanPid"]
    refute @store.remove_stale_route("stale.localhost", 1)
    assert @store.remove_stale_route("stale.localhost", DEAD_PID)
    assert_equal [], disk
  end

  def test_stale_entries_without_recovery_data_drop_on_next_write
    write_routes([ { hostname: "gone.localhost", port: 1, pid: DEAD_PID } ])
    @store.add_route(hostname: "a.localhost", port: 2, pid: Process.pid)
    assert_equal [ "a.localhost" ], disk.map { |r| r["hostname"] }
  end

  def test_transfer_route_drops_share_urls_and_checks_owner
    @store.add_route(hostname: "a.localhost", port: 1, pid: Process.pid)
    @store.update_route("a.localhost", { ngrok_url: "https://x", tailscale_url: "https://y",
                                         tailscale_https_port: 8443, tailscale_funnel: true, cloudflare_pid: 9 })
    refute @store.transfer_route("a.localhost", 1, 2)
    assert @store.transfer_route("a.localhost", Process.pid, Process.ppid)
    route = disk[0]
    assert_equal Process.ppid, route["pid"]
    %w[ngrokUrl tailscaleUrl tailscaleHttpsPort tailscaleFunnel cloudflarePid].each { |k| refute route.key?(k) }
  end

  def test_update_route_sets_and_clears_metadata_and_keeps_registered_at
    @store.add_route(hostname: "a.localhost", port: 1, pid: Process.pid)
    registered = disk[0]["registeredAt"]
    @store.update_route("a.localhost", { "ngrokUrl" => "https://n", ngrok_pid: 5 })
    assert_equal "https://n", @store.load_routes.first.ngrok_url
    @store.update_route("a.localhost", { ngrok_url: nil, ngrok_pid: nil })
    refute disk[0].key?("ngrokUrl")
    assert_equal registered, disk[0]["registeredAt"]
    @store.update_route("nope.localhost", { ngrok_url: "x" })
    assert_equal 1, disk.size
  end

  def test_update_route_metadata_requires_the_owner_pid
    @store.add_route(hostname: "a.localhost", port: 1, pid: Process.pid)
    @store.update_route_metadata("a.localhost", 1, { tailscale_url: "https://t" })
    assert_nil @store.load_routes.first.tailscale_url
    @store.update_route_metadata("a.localhost", Process.pid, { tailscale_url: "https://t" })
    assert_equal "https://t", @store.load_routes.first.tailscale_url
  end

  def test_backward_compat_without_registered_at_or_share_fields
    write_routes([ { hostname: "a.localhost", port: 1, pid: 0 } ])
    route = @store.load_routes.first
    assert_nil route.registered_at
    assert_nil route.tailscale_url
    assert_nil route.ngrok_url
  end

  def test_stale_lock_is_recovered
    @store.ensure_dir
    lock = File.join(@dir, "routes.lock")
    Dir.mkdir(lock)
    old = Time.now - 20
    File.utime(old, old, lock)
    @store.add_route(hostname: "a.localhost", port: 1, pid: Process.pid)
    assert_equal 1, @store.load_routes.size
  end

  def test_prune_removes_stale_records
    write_routes([ STALE, { hostname: "a.localhost", port: 1, pid: 0 } ])
    assert_equal [ "stale.localhost" ], @store.prune.map(&:hostname)
    assert_equal [ "a.localhost" ], disk.map { |r| r["hostname"] }
  end
end
