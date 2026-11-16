# frozen_string_literal: true

require_relative "test_helper"
require "json"

# CLI dispatch, flag parsing, get/list/alias, exit codes. Daemon state is
# stubbed with the ProxyState Daemon.discover_state returns.
module CliTestSupport
  def setup
    @saved_env = ENV.to_h
    %w[PORTLESS PORTLESS_LAN PORTLESS_LAN_IP PORTLESS_TAILSCALE PORTLESS_FUNNEL PORTLESS_NGROK PORTLESS_CLOUDFLARE
       PORTLESS_PREFIX PORTLESS_APP_PORT].each { |k| ENV.delete(k) }
    @state = Portless::Daemon::ProxyState.new(dir: ENV["PORTLESS_STATE_DIR"], port: 1355, tls: true, tld: "localhost",
                                              tlds: [ "localhost" ], lan_mode: false, lan_ip: nil)
    state = @state
    @had_discover = Portless::Daemon.respond_to?(:discover_state)
    @orig_discover = Portless::Daemon.method(:discover_state) if @had_discover
    Portless::Daemon.define_singleton_method(:discover_state) { state }
  end

  def teardown
    ENV.replace(@saved_env)
    if @had_discover
      orig = @orig_discover
      Portless::Daemon.define_singleton_method(:discover_state) { |*a, **k| orig.call(*a, **k) }
    else
      Portless::Daemon.singleton_class.send(:remove_method, :discover_state)
    end
  end

  def cli(*argv)
    code = nil
    out, err = capture_io { code = Portless::CLI.new(argv).main }
    [ code, out, err ]
  end
end

class CliTest < Minitest::Test
  include CliTestSupport

  def test_version
    code, out, = cli("--version")
    assert_equal [ 0, "#{Portless::VERSION}\n" ], [ code, out ]
  end

  def test_command_typo_suggests_and_exits_2
    code, _, err = cli("lst")
    assert_equal 2, code
    assert_includes err, '"lst" is not a rb-portless command. Did you mean:'
    assert_includes err, "  rb-portless list"
  end

  def test_unknown_run_flag_exits_2
    code, _, err = cli("run", "--bogus", "cmd")
    assert_equal 2, code
    assert_includes err, 'Unknown flag "--bogus" for rb-portless run.'
  end

  def test_run_flags_only_parsed_before_command
    c = Portless::CLI.new([])
    parsed = c.parse_run_args(%w[--name=foo --force vite --force --name x])
    assert_equal [ "foo", true, %w[vite --force --name x] ], [ parsed.name, parsed.force, parsed.command_args ]
    assert_equal %w[--name y], c.parse_run_args(%w[-- --name y]).command_args
    err = assert_raises(Portless::UsageError) { c.parse_run_args(%w[--app-port 0 x]) }
    assert_equal 'Invalid app port "0". Must be 1-65535.', err.message
  end

  def test_named_mode_flags_after_name
    parsed = Portless::CLI.new([]).parse_app_args(%w[--force myapp --app-port 4100 next dev])
    assert_equal [ "myapp", true, 4100, %w[next dev] ], [ parsed.name, parsed.force, parsed.app_port, parsed.command_args ]
  end

  def test_global_flags_stripped_only_from_leading_region
    c = Portless::CLI.new([])
    args = %w[--lan --tailscale run vite --lan]
    c.apply_global_flags(args)
    assert_equal %w[run vite --lan], args
    assert_equal "1", ENV["PORTLESS_LAN"]
    assert_equal "1", ENV["PORTLESS_TAILSCALE"]
    args = %w[myapp --ngrok next dev --cloudflare]
    c.apply_global_flags(args)
    assert_equal %w[myapp next dev --cloudflare], args
    assert_equal "1", ENV["PORTLESS_NGROK"]
    assert_nil ENV["PORTLESS_CLOUDFLARE"]
  end

  def test_ip_flag_validation
    code, _, err = cli("--ip", "nope", "run", "x")
    assert_equal 2, code
    assert_includes err, '--ip requires an IP address, but got "nope".'
    args = %w[--ip 10.0.0.2 run x]
    Portless::CLI.new([]).apply_global_flags(args)
    assert_equal [ "10.0.0.2", "1" ], [ ENV["PORTLESS_LAN_IP"], ENV["PORTLESS_LAN"] ]
  end

  def test_get_includes_proxy_port_and_full_tld
    code, out, = cli("get", "api.myapp", "--no-worktree")
    assert_equal [ 0, "https://api.myapp.localhost:1355\n" ], [ code, out ]
    @state[:port] = 443
    _, out, = cli("get", "web", "--json", "--no-worktree")
    assert_equal({ "name" => "web", "hostname" => "web.localhost", "url" => "https://web.localhost" }, JSON.parse(out))
    ENV["PORTLESS_PREFIX"] = "feat"
    _, out, = cli("get", "web")
    assert_equal "https://feat.web.localhost\n", out
  end

  def test_get_usage_errors
    assert_equal 2, cli("get").first
    assert_equal 2, cli("get", "a", "b").first
  end

  def test_alias_validation
    assert_equal 2, cli("alias", "--remove", "x", "--force").first
    assert_equal 2, cli("alias", "pg").first
    code, _, err = cli("alias", "pg", "99999")
    assert_equal 2, code
    assert_includes err, 'Invalid port "99999". Must be 1-65535.'
    code, _, err = cli("alias", "pg", "5432", "--upstream", "ftp://x")
    assert_equal 2, code
    assert_includes err, "Invalid --upstream value."
    code, _, err = cli("alias", "pg", "5432", "--tld", "test")
    assert_equal 1, code
    assert_includes err, 'TLD "test" is not configured (localhost).'
  end

  def test_proxy_and_hosts_unknown_subcommands_exit_2
    assert_equal 2, cli("proxy", "restart").first
    assert_equal 2, cli("hosts", "nope").first
    assert_equal 2, cli("proxy", "start", "--cert", "a").first
    assert_equal 2, cli("proxy", "stop", "-p", "0").first
    assert_equal 0, cli("proxy").first
  end

  def test_invalid_portless_tld_is_reported_before_an_invalid_tld_flag
    ENV["PORTLESS_TLD"] = "Bad_"
    _, err = capture_io do
      assert_equal 1, assert_raises(SystemExit) { Portless::CLI.new(%w[proxy start --tld b@d]).main }.status
    end
    assert_match(/Error: PORTLESS_TLD: /, err)
    ENV.delete("PORTLESS_TLD")
    code, _, err = cli("proxy", "start", "--tld", "b@d")
    assert_equal 2, code
    assert_match(/Invalid TLD "b@d"/, err)
  end

  def test_help_flag_anywhere_prints_help
    code, out, = cli("list", "--json", "-h")
    assert_equal 0, code
    assert_includes out, "rb-portless list - Show active routes and their uptime."
  end

  def test_portless_zero_runs_missing_command_via_shell
    ENV["PORTLESS"] = "0"
    code = nil
    capture_subprocess_io { code = Portless::CLI.new(%w[run definitely-not-a-cmd-xyz]).main }
    assert_equal 127, code
    capture_subprocess_io { code = Portless::CLI.new(%w[run sh -c] + [ "exit 3" ]).main }
    assert_equal 3, code
  end

  def test_free_port_skips_blocked_and_is_free_everywhere
    port = Portless::FreePort.find
    assert port.between?(4000, 4999)
    refute_includes Portless::FreePort::BLOCKED_PORTS, port
    assert Portless::FreePort.available?(port)
  end
end

class CliTest
  def test_list_heading_keeps_blank_line_like_console_log
    Portless::RouteStore.new.add_route(hostname: "listed.localhost", port: 4567, pid: 0, force: true)
    code, out, = cli("list")
    assert_equal 0, code
    assert out.start_with?("\nActive routes:\n\n  https://listed.localhost:1355  ->  localhost:4567  (alias)\n"), out.inspect
  ensure
    Portless::RouteStore.new.remove_route("listed.localhost")
  end
end

class DoctorPlatformTest < Minitest::Test
  def test_platform_uses_node_spelling
    assert_equal "darwin", Portless::Doctor.node_platform("darwin25")
    assert_equal "linux", Portless::Doctor.node_platform("linux-gnu")
    assert_equal "win32", Portless::Doctor.node_platform("mingw32")
    assert_equal "arm64", Portless::Doctor.node_arch("aarch64")
    assert_equal "x64", Portless::Doctor.node_arch("x86_64")
  end
end

# hosts sync/clean and trust (cli.ts handleHosts / handleTrust) against a temp
# hosts file and stubbed trust store; sudo is the refusing test shim.
class CliHostsTrustTest < Minitest::Test
  include CliTestSupport

  def setup
    super
    @hosts = File.join(Dir.mktmpdir, "hosts")
    File.write(@hosts, "127.0.0.1 localhost\n")
    Portless::Hosts.hosts_path = @hosts
  end

  def teardown
    Portless::Hosts.hosts_path = nil
    FileUtils.rm_rf(File.dirname(@hosts))
    Portless::RouteStore.new.remove_route("synced.localhost")
    super
  end

  def test_hosts_sync_writes_route_hostnames
    Portless::RouteStore.new.add_route(hostname: "synced.localhost", port: 4567, pid: 0, force: true)
    code, out, = cli("hosts", "sync")
    assert_equal 0, code
    assert_equal "Synced 1 hostname(s) to /etc/hosts:\n  127.0.0.1 synced.localhost\n", out
    assert_includes File.read(@hosts), "127.0.0.1 synced.localhost"
  end

  def test_hosts_sync_with_no_routes_removes_stale_block
    File.write(@hosts, "127.0.0.1 localhost\n\n# rb-portless-start\n127.0.0.1 old.localhost\n# rb-portless-end\n")
    code, out, = cli("hosts", "sync")
    assert_equal [ 0, "No stale rb-portless entries remain in /etc/hosts.\n" ], [ code, out ]
    refute_includes File.read(@hosts), "old.localhost"
  end

  def test_hosts_clean_removes_block
    File.write(@hosts, "127.0.0.1 localhost\n\n# rb-portless-start\n127.0.0.1 old.localhost\n# rb-portless-end\n")
    code, out, = cli("hosts", "clean")
    assert_equal [ 0, "Removed rb-portless entries from /etc/hosts.\n" ], [ code, out ]
    refute_includes File.read(@hosts), "old.localhost"
  end

  def test_hosts_clean_failure_tries_sudo_then_exits_1
    Portless::Hosts.hosts_path = File.join(File.dirname(@hosts), "missing")
    code, out, err = cli("hosts", "clean")
    assert_equal 1, code
    assert_includes out, "Writing to /etc/hosts requires elevated privileges. Requesting sudo..."
    assert_includes err, "Failed to update /etc/hosts."
  end

  def test_trust_success
    Portless::Certs.stub(:ensure_certs, { ca_generated: false }) do
      Portless::Trust.stub(:trust_ca, { trusted: true }) do
        code, _, err = cli("trust")
        assert_equal 0, code
        assert_equal "Local CA added to system trust store.\nBrowsers will now trust rb-portless HTTPS certificates.\n",
                     err
      end
    end
  end

  def test_trust_creates_missing_state_dir
    dir = File.join(Dir.mktmpdir, "fresh")
    @state[:dir] = dir
    Portless::Certs.stub(:ensure_certs, { ca_generated: false }) do
      Portless::Trust.stub(:trust_ca, { trusted: true }) do
        assert_equal 0, cli("trust").first
      end
    end
    assert File.directory?(dir)
  ensure
    FileUtils.rm_rf(File.dirname(dir))
  end

  def test_trust_permission_error_tries_sudo
    Portless::Certs.stub(:ensure_certs, { ca_generated: false }) do
      Portless::Trust.stub(:trust_ca, { trusted: false, error: "Permission denied" }) do
        code, _, err = cli("trust")
        assert_equal 1, code
        assert_includes err, "Trusting the CA requires elevated privileges. Requesting sudo..."
        assert_includes err, "sudo elevation also failed.\nFailed to trust CA: Permission denied\n"
      end
    end
  end
end

class CliHostsTrustTest
  def test_trust_restart_hint_uses_portless_port_default
    ENV["PORTLESS_PORT"] = "1355"
    probed = nil
    running = lambda { |port, tls|
      probed = [ port, tls ]
      true
    }
    Portless::Certs.stub(:ensure_certs, { ca_generated: true }) do
      Portless::Trust.stub(:trust_ca, { trusted: true }) do
        Portless::Daemon.stub(:proxy_running?, running) do
          _, _, err = cli("trust")
          assert_equal [ 1355, true ], probed
          assert_includes err, "Restart it: rb-portless proxy stop && rb-portless proxy start\n"
          ENV.delete("PORTLESS_PORT")
          _, _, err = cli("trust")
          assert_includes err, "Restart it: rb-portless proxy stop -p 1355 && rb-portless proxy start -p 1355\n"
        end
      end
    end
  end
end

class CliTest
  def test_unexpected_errors_print_error_and_exit_1
    Portless::Daemon.stub(:discover_state, ->(*) { raise Errno::EACCES, "routes.json" }) do
      code, _, err = cli("list")
      assert_equal [ 1, "Error: Permission denied - routes.json\n" ], [ code, err ]
    end
  end
end

class CliTest
  def test_alias_reports_hosts_sync_after_registering
    calls = []
    report = lambda { |*args, &block|
      calls << args
      block.call("alias.localhost will not resolve. Run: rb-portless hosts sync")
    }
    Portless::Daemon.stub(:report_hosts_sync, report) do
      code, out, err = cli("alias", "alias", "5432")
      assert_equal 0, code
      assert_equal "Alias registered: alias.localhost -> 127.0.0.1:5432\n", out
      assert_equal [ [ [ "alias.localhost" ], 1355, true, false ] ], calls
      assert_includes err, "alias.localhost will not resolve."
    end
  ensure
    Portless::RouteStore.new.remove_route("alias.localhost")
  end
end

class CliTest
  def test_ip_address_matches_node_is_ip
    c = Portless::CLI.new([])
    %w[192.168.1.42 ::1 :: fe80::1%en0 ::ffff:1.2.3.4 1:2:3:4:5:6:7:8].each { |ip| assert c.ip_address?(ip), ip }
    [ "[::1]", "01.2.3.4", "1.2.3.4/24", "256.1.1.1", "1.2.3", "1::2::3", "fe80::1%", " 1.2.3.4" ].each do |ip|
      refute c.ip_address?(ip), ip
    end
    code, _, err = cli("--ip", "[::1]", "run", "x")
    assert_equal 2, code
    assert_includes err, '--ip requires an IP address, but got "[::1]".'
  end
end

class CliTest
  def test_stop_recorded_groups_stops_groups_in_parallel
    route = ->(pgid, pid) { Portless::RouteStore::Route.new(hostname: "a#{pid}.localhost", port: 4000 + pid, pid: pid, child_pgid: pgid) }
    routes = [ route.(101, 1), route.(101, 2), route.(202, 3), route.(303, 4), route.(nil, 5) ]
    seen = Queue.new
    slow_stop = lambda { |pgid, starts, _members, signal, port:|
      sleep 0.3
      seen << [ pgid, starts.length, signal, port ]
      pgid
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stops = Portless::ProcessGroup.stub(:stop_process_group, slow_stop) do
      Portless::CLI.stop_recorded_groups(routes, "TERM")
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.6
    assert_equal({ 101 => 101, 202 => 202, 303 => 303 }, stops)
    assert_equal [ [ 101, 2, "TERM", 4001 ], [ 202, 1, "TERM", 4003 ], [ 303, 1, "TERM", 4004 ] ],
                 Array.new(seen.size) { seen.pop }.sort
  end
end

class RunnerOrphanTest < Minitest::Test
  FailingStore = Struct.new(:untrusted) do
    def untrusted_reason = untrusted
    def find_stale_routes = raise(Portless::Error, "routes.json is locked")
  end

  def runner(store)
    Portless::Runner.new(store: store, proxy_port: 1355, state_dir: Dir.tmpdir, name: "x", command_args: [],
                         tls: false, tlds: [ "localhost" ])
  end

  def test_orphan_stop_errors_surface_like_upstream
    err = assert_raises(Portless::Error) { runner(FailingStore.new(nil)).send(:stop_orphaned_process_groups) }
    assert_equal "routes.json is locked", err.message
    assert_nil runner(FailingStore.new("unsafe")).send(:stop_orphaned_process_groups)
  end
end

class RunnerTunnelExitTest < Minitest::Test
  class Store
    attr_reader :updates

    def initialize = @updates = []
    def update_route(hostname, fields) = @updates << [ hostname, fields ]
  end

  def setup
    @store = Store.new
    @runner = Portless::Runner.new(store: @store, proxy_port: 1355, state_dir: Dir.tmpdir, name: "x",
                                   command_args: [], tls: false, tlds: [ "localhost" ])
    @ngrok = Portless::Tunnel::PROCESS_TUNNELS.find { |t| t[:name] == :ngrok }
  end

  def start_with_early_exit
    handle = Portless::Tunnel::Handle.new("https://x.ngrok.app", 42)
    start = lambda { |*_args, **_opts, &on_exit|
      on_exit.call(1, nil) # exits before the route records its URL
      handle
    }
    Portless::Tunnel.stub(:start, start) { @runner.send(:start_tunnels, [ @ngrok ], "x.localhost", 4000) }
  end

  def test_early_exit_is_replayed_after_url_is_recorded_and_url_not_exported
    runs = nil
    _, err = capture_io { runs = start_with_early_exit }
    fields = @store.updates.map(&:last)
    assert_equal [ "https://x.ngrok.app", nil ], fields.map { |f| f[@ngrok[:url_field]] }
    assert runs.first[:handled]
    assert_includes err, "Warning: ngrok tunnel for x.localhost stopped (exit 1)."
  end

  def test_exit_while_stopping_is_silent
    @runner.instance_variable_set(:@stopping_tunnels, true)
    _, err = capture_io { start_with_early_exit }
    refute_includes err, "Warning:"
    assert_equal 1, @store.updates.length
  end
end
