# frozen_string_literal: true

require_relative "test_helper"
require "json"

# CLI dispatch, flag parsing, get/list/alias, exit codes. Daemon state is
# stubbed with the hash shape Daemon.discover_state returns.
class CliTest < Minitest::Test
  def setup
    @saved_env = ENV.to_h
    %w[PORTLESS PORTLESS_LAN PORTLESS_LAN_IP PORTLESS_TAILSCALE PORTLESS_FUNNEL PORTLESS_NGROK PORTLESS_CLOUDFLARE
       PORTLESS_PREFIX PORTLESS_APP_PORT].each { |k| ENV.delete(k) }
    @state = { dir: ENV["PORTLESS_STATE_DIR"], port: 1355, tls: true, tld: "localhost",
                       tlds: [ "localhost" ], lan_mode: false, lan_ip: nil }
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
