# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/cli_utils"
require "minitest/mock"
require "rbconfig"

# Mirror of packages/portless/src/cli-utils.test.ts

describe "proxy listener interface" do
  include CliUtilsSupport

  it "uses only IPv4 and IPv6 loopback outside LAN mode" do
    assert_equal [ { host: "127.0.0.1" }, { host: "::1", ipv6_only: true } ],
                 Portless::Privilege.bind_targets(false)
  end

  it "uses IPv4 and IPv6 unspecified addresses in LAN mode" do
    assert_equal [ { host: "0.0.0.0" }, { host: "::", ipv6_only: true } ], Portless::Privilege.bind_targets(true)
  end

  it "uses the unspecified addresses in unprivileged mode outside LAN mode" do
    assert_equal [ { host: "0.0.0.0" }, { host: "::", ipv6_only: true } ],
                 Portless::Privilege.bind_targets(false, true)
  end

  it "binds IPv4 loopback outside LAN mode" do
    target = Portless::Privilege.bind_targets(false)[0]

    server = Portless::Privilege.listen_on_proxy_interface(0, target)
    begin
      assert_equal "127.0.0.1", server.local_address.ip_address
    ensure
      server.close
    end
  end

  it "binds IPv6 loopback outside LAN mode when available" do
    target = Portless::Privilege.bind_targets(false)[1]

    server = begin
      Portless::Privilege.listen_on_proxy_interface(0, target)
    rescue Errno::EAFNOSUPPORT, Errno::EADDRNOTAVAIL
      skip "IPv6 loopback unavailable"
    end

    begin
      assert_equal "::1", server.local_address.ip_address
    ensure
      server.close
    end
  end

  it "binds the IPv4 unspecified address in LAN mode" do
    target = Portless::Privilege.bind_targets(true)[0]

    server = Portless::Privilege.listen_on_proxy_interface(0, target)
    begin
      assert_equal "0.0.0.0", server.local_address.ip_address
    ensure
      server.close
    end
  end
end

describe "augmentedPath (issue #241)" do
  include CliUtilsSupport

  let(:node_dir) { File.dirname(RbConfig.ruby) }

  before { @tmp_dir = Dir.mktmpdir("portless-path-") }
  after { FileUtils.rm_rf(@tmp_dir) }

  it "keeps the caller's PATH ahead of the running node's directory" do
    user_bin = File.join(@tmp_dir, "version-manager", "bin")
    entries = Portless::RunSupport.augmented_path({ "PATH" => user_bin }, @tmp_dir).split(File::PATH_SEPARATOR)
    assert_operator entries.index(user_bin), :>=, 0
    assert_operator entries.index(user_bin), :<, entries.rindex(node_dir)
  end

  it "keeps project node_modules/.bin first and node's directory as a fallback" do
    local_bin = File.join(@tmp_dir, "node_modules", ".bin")
    FileUtils.mkdir_p(local_bin)
    entries = Portless::RunSupport.augmented_path({ "PATH" => "" }, @tmp_dir).split(File::PATH_SEPARATOR)
    assert_equal local_bin, entries[0]
    assert_equal node_dir, entries[-1]
    refute_includes entries, ""
  end
end

describe "findFreePort" do
  include CliUtilsSupport

  it "skips a port held on %s (issue #288)" do
    [ "127.0.0.1", "::1", "0.0.0.0", "::" ].each do |host|
      server = begin
        TCPServer.new(host, 0)
      rescue SystemCallError, SocketError
        next # only a missing address family fails here: port 0 is always available
      end
      port = server.addr[1]
      begin
        error = assert_raises(Portless::Error) { Portless::FreePort.find(port, port) }
        assert_includes error.message, "No free port found"
      ensure
        server.close
      end
    end
  end

  it "returns a port in the default range" do
    port = Portless::FreePort.find
    assert_operator port, :>=, 4000
    assert_operator port, :<=, 4999
  end

  it "returns a port that is actually bindable" do
    port = Portless::FreePort.find
    server = TCPServer.new("::", port)
    server.close
  end

  it "respects custom port range" do
    port = Portless::FreePort.find(9000, 9010)
    assert_operator port, :>=, 9000
    assert_operator port, :<=, 9010
  end

  it "throws when no port is available in a tiny occupied range" do
    # Occupy a single-port range
    server = TCPServer.new("::", 9999)
    begin
      error = assert_raises(Portless::Error) { Portless::FreePort.find(9999, 9999) }
      assert_includes error.message, "No free port found"
    ensure
      server.close
    end
  end

  it "throws when minPort > maxPort" do
    error = assert_raises(Portless::Error) { Portless::FreePort.find(5000, 4000) }
    assert_includes error.message, "minPort"
  end

  it "never returns a blocked port (WHATWG bad ports)" do
    20.times do
      port = Portless::FreePort.find
      refute_includes Portless::FreePort::BLOCKED_PORTS, port
    end
  end

  it "skips a blocked port even when it is the only one in range" do
    error = assert_raises(Portless::Error) { Portless::FreePort.find(4045, 4045) }
    assert_includes error.message, "No free port found"
  end
end

describe "isProxyRunning" do
  include CliUtilsSupport

  before { @servers = [] }
  after { @servers.each(&:close) }

  it "returns false when nothing is listening" do
    result = Portless::Health.proxy_running?(19_876)
    assert_equal false, result
  end

  it "returns true when a portless proxy is listening" do
    server, port = start_http_server("127.0.0.1", headers: { "X-Portless" => "1" })
    @servers << server

    result = Portless::Health.proxy_running?(port)
    assert_equal true, result
  end

  it "returns false when a non-portless server is listening" do
    server, port = start_http_server("127.0.0.1", body: "not portless")
    @servers << server

    result = Portless::Health.proxy_running?(port)
    assert_equal false, result
  end
end

describe "isPortListening" do
  include CliUtilsSupport

  before { @servers = [] }
  after { @servers.each(&:close) }

  it "returns false when nothing is listening" do
    assert_equal false, Portless::PortOwner.port_listening?(19_877)
  end

  it "detects a server listening on IPv6 loopback only (issue #320)" do
    server, port = begin
      start_http_server("::1")
    rescue SystemCallError, SocketError
      skip "IPv6 loopback unavailable"
    end
    @servers << server

    assert_equal true, Portless::PortOwner.port_listening?(port)
  end

  it "cancels an unfinished probe after its short deadline" do
    cancel_calls = 0
    connect = lambda do |_port, &callback|
      lambda do
        cancel_calls += 1
        callback.call(Errno::ECANCELED.new("Cancelled"), nil)
      end
    end
    threads_before = Thread.list.size
    Portless::Utils.stub(:create_loopback_connection, connect) do
      started = monotonic_ms
      assert_equal false, Portless::PortOwner.port_listening?(19_877)
      assert_operator monotonic_ms - started, :>=, 500
      assert_equal 1, cancel_calls
      assert_equal threads_before, Thread.list.size
    end
  end
end

describe "resolveStateDir" do
  include CliUtilsSupport

  it "returns user dir for all ports" do
    with_env("PORTLESS_STATE_DIR" => nil) do
      user_state_dir = File.join(Dir.home, ".rb-portless")
      [ 80, 443, 1023, 1024, 8080, 3000 ].each do |_port|
        assert_equal user_state_dir, Portless::State.dir
      end
    end
  end

  it "uses the invoking user's home when loaded under sudo" do
    expected_home = Portless::Constants::MACOS ? "/Users/alice" : "/home/alice"
    root_home = Portless::Constants::MACOS ? "/var/root" : "/root"
    sudo_env = { "HOME" => root_home, "SUDO_USER" => "alice" }
    sudo_home = Portless::State.resolve_user_home(env: sudo_env, homedir: root_home)

    with_env("PORTLESS_STATE_DIR" => nil) do
      Portless::State.stub(:resolve_user_home, sudo_home) do
        assert_equal File.join(expected_home, ".rb-portless"), Portless::State.dir
      end
    end
  end
end

describe "constants" do
  include CliUtilsSupport

  it "FALLBACK_PROXY_PORT is 1355" do
    assert_equal 1355, Portless::Constants::FALLBACK_PROXY_PORT
  end

  it "PRIVILEGED_PORT_THRESHOLD is 1024" do
    assert_equal 1024, Portless::Constants::PRIVILEGED_PORT_THRESHOLD
  end

  it "USER_STATE_DIR is in home directory" do
    with_env("PORTLESS_STATE_DIR" => nil) do
      assert_equal File.join(Dir.home, ".rb-portless"), Portless::State.dir
    end
  end
end

describe "parsePidFromNetstat" do
  include CliUtilsSupport

  let(:sample_output) do
    [
      "Active Connections",
      "",
      "  Proto  Local Address          Foreign Address        State           PID",
      "  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1104",
      "  TCP    0.0.0.0:1355           0.0.0.0:0              LISTENING       9876",
      "  TCP    0.0.0.0:5432           0.0.0.0:0              LISTENING       3200",
      "  TCP    [::]:1355              [::]:0                  LISTENING       9876",
      "  TCP    127.0.0.1:1355         127.0.0.1:52000        ESTABLISHED     9876",
      "  TCP    192.168.1.10:13550     10.0.0.1:443           ESTABLISHED     5500"
    ].join("\r\n")
  end

  it "finds PID for a matching LISTENING port" do
    assert_equal 9876, Portless::PortOwner.parse_pid_from_netstat(sample_output, 1355)
  end

  it "returns null when port is not listening" do
    assert_nil Portless::PortOwner.parse_pid_from_netstat(sample_output, 9999)
  end

  it "does not match ESTABLISHED connections" do
    assert_equal 9876, Portless::PortOwner.parse_pid_from_netstat(sample_output, 1355)
  end

  it "does not false-match on port prefix (13550 vs 1355)" do
    assert_nil Portless::PortOwner.parse_pid_from_netstat(sample_output, 13_550)
  end

  it "matches IPv6 addresses ([::]:port)" do
    ipv6_only = [
      "  Proto  Local Address          Foreign Address        State           PID",
      "  TCP    [::]:1355              [::]:0                  LISTENING       4444"
    ].join("\r\n")
    assert_equal 4444, Portless::PortOwner.parse_pid_from_netstat(ipv6_only, 1355)
  end

  it "matches 127.0.0.1 bound addresses" do
    loopback = [
      "  Proto  Local Address          Foreign Address        State           PID",
      "  TCP    127.0.0.1:8080         0.0.0.0:0              LISTENING       7777"
    ].join("\r\n")
    assert_equal 7777, Portless::PortOwner.parse_pid_from_netstat(loopback, 8080)
  end

  it "returns null for empty output" do
    assert_nil Portless::PortOwner.parse_pid_from_netstat("", 1355)
  end

  it "handles Unix-style line endings" do
    unix_output = [
      "  TCP    0.0.0.0:3000           0.0.0.0:0              LISTENING       1234"
    ].join("\n")
    assert_equal 1234, Portless::PortOwner.parse_pid_from_netstat(unix_output, 3000)
  end
end

describe "getProtocolPort" do
  include CliUtilsSupport

  it "returns 443 for TLS" do
    assert_equal 443, Portless::Daemon.protocol_port(true)
  end

  it "returns 80 for plain HTTP" do
    assert_equal 80, Portless::Daemon.protocol_port(false)
  end
end

describe "getDefaultPort" do
  include CliUtilsSupport

  before { @original_env = ENV.fetch("PORTLESS_PORT", nil) }
  after { @original_env.nil? ? ENV.delete("PORTLESS_PORT") : ENV["PORTLESS_PORT"] = @original_env }

  it "returns FALLBACK_PROXY_PORT when called without tls argument" do
    ENV.delete("PORTLESS_PORT")
    assert_equal Portless::Constants::FALLBACK_PROXY_PORT, Portless::Daemon.default_port
  end

  it "returns 443 when tls is true" do
    ENV.delete("PORTLESS_PORT")
    assert_equal 443, Portless::Daemon.default_port(true)
  end

  it "returns 80 when tls is false" do
    ENV.delete("PORTLESS_PORT")
    assert_equal 80, Portless::Daemon.default_port(false)
  end

  it "returns PORTLESS_PORT when set, regardless of tls argument" do
    ENV["PORTLESS_PORT"] = "8080"
    assert_equal 8080, Portless::Daemon.default_port
    assert_equal 8080, Portless::Daemon.default_port(true)
    assert_equal 8080, Portless::Daemon.default_port(false)
  end

  it "returns protocol default when PORTLESS_PORT is invalid" do
    ENV["PORTLESS_PORT"] = "not-a-number"
    assert_equal Portless::Constants::FALLBACK_PROXY_PORT, Portless::Daemon.default_port
    assert_equal 443, Portless::Daemon.default_port(true)
    assert_equal 80, Portless::Daemon.default_port(false)
  end

  it "returns protocol default when PORTLESS_PORT is out of range" do
    ENV["PORTLESS_PORT"] = "0"
    assert_equal 443, Portless::Daemon.default_port(true)

    ENV["PORTLESS_PORT"] = "70000"
    assert_equal 80, Portless::Daemon.default_port(false)
  end

  it "returns FALLBACK_PROXY_PORT when PORTLESS_PORT is empty and tls is undefined" do
    ENV["PORTLESS_PORT"] = ""
    assert_equal Portless::Constants::FALLBACK_PROXY_PORT, Portless::Daemon.default_port
  end
end

describe "isHttpsEnvDisabled" do
  include CliUtilsSupport

  before { @original_env = ENV.fetch("PORTLESS_HTTPS", nil) }
  after { @original_env.nil? ? ENV.delete("PORTLESS_HTTPS") : ENV["PORTLESS_HTTPS"] = @original_env }

  it "returns true when PORTLESS_HTTPS is '0'" do
    ENV["PORTLESS_HTTPS"] = "0"
    assert_equal true, Portless::Utils.https_env_disabled?
  end

  it "returns true when PORTLESS_HTTPS is 'false'" do
    ENV["PORTLESS_HTTPS"] = "false"
    assert_equal true, Portless::Utils.https_env_disabled?
  end

  it "returns false when PORTLESS_HTTPS is '1'" do
    ENV["PORTLESS_HTTPS"] = "1"
    assert_equal false, Portless::Utils.https_env_disabled?
  end

  it "returns false when PORTLESS_HTTPS is unset" do
    ENV.delete("PORTLESS_HTTPS")
    assert_equal false, Portless::Utils.https_env_disabled?
  end
end
describe "injectFrameworkFlags" do
  include CliUtilsSupport

  it "injects --port, --strictPort, and --host for vite command" do
    args = %w[vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for absolute/relative vite paths" do
    args = %w[./node_modules/.bin/vite dev]
    inject_framework_flags(args, 4000)
    assert_equal %w[./node_modules/.bin/vite dev --port 4000 --strictPort --host 127.0.0.1], args
  end

  it "skips --port injection when --port is already present" do
    args = %w[vite dev --port 3000]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite dev --port 3000 --host 127.0.0.1], args
  end

  it "skips injection when flags use the --flag=value form" do
    args = %w[vite dev --port=3000 --host=0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite dev --port=3000 --host=0.0.0.0], args
  end

  it "skips --host injection when --host is already present" do
    args = %w[vite dev --host 0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite dev --host 0.0.0.0 --port 4567 --strictPort], args
  end

  it "skips all injection when both --port and --host are present" do
    args = %w[vite dev --port 3000 --host 0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite dev --port 3000 --host 0.0.0.0], args
  end

  it "injects --port, --strictPort, and --host for vp (viteplus) command" do
    args = %w[vp dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[vp dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects for react-router with --strictPort" do
    args = %w[react-router dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[react-router dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects for vitepress dev but not build" do
    dev = %w[vitepress dev docs]
    inject_framework_flags(dev, 4567)
    assert_equal %w[vitepress dev docs --port 4567 --strictPort --host 127.0.0.1], dev

    build = %w[vitepress build]
    inject_framework_flags(build, 4567)
    assert_equal %w[vitepress build], build
  end

  it "injects for rsbuild without --strictPort" do
    args = %w[rsbuild dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[rsbuild dev --port 4567 --host 127.0.0.1], args
  end

  it "injects for astro without --strictPort" do
    args = %w[astro dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[astro dev --port 4567 --host 127.0.0.1], args
  end

  it "injects for astro when a global flag precedes the subcommand" do
    dev_args = %w[astro --root apps/web dev]
    inject_framework_flags(dev_args, 4567)
    assert_equal %w[astro --root apps/web dev --port 4567 --host 127.0.0.1], dev_args

    preview_args = %w[astro --config astro.config.mjs preview]
    inject_framework_flags(preview_args, 4567)
    assert_equal %w[astro --config astro.config.mjs preview --port 4567 --host 127.0.0.1], preview_args
  end

  it "preserves an explicit astro host choice before the subcommand: %j" do
    [ %w[--host 0.0.0.0], %w[--host=0.0.0.0] ].each do |host_args|
      command = [ "astro", "--root", "apps/web", *host_args, "dev" ]
      args = command.dup
      inject_framework_flags(args, 4567)
      assert_equal [ *command, "--port", "4567" ], args
    end
  end

  it "injects astro flags before -- without treating trailing host data as an option" do
    args = %w[astro --root apps/web dev -- --host=0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[astro --root apps/web dev --port 4567 --host 127.0.0.1 -- --host=0.0.0.0], args
  end

  it "does not mistake astro %s %s for a server subcommand" do
    [ %w[--root dev], %w[--root preview], %w[--config dev], %w[--config preview] ].each do |flag, value|
      command = [ "astro", flag, value, "build" ]
      args = command.dup
      assert_equal [], inject_framework_flags(args, 4567)
      assert_equal command, args
    end
  end

  it "recognizes astro dev after the consumed value %s %s" do
    [ %w[--root dev], %w[--root preview], %w[--config dev], %w[--config preview] ].each do |flag, value|
      command = [ "astro", flag, value, "dev" ]
      args = command.dup
      inject_framework_flags(args, 4567)
      assert_equal [ *command, "--port", "4567", "--host", "127.0.0.1" ], args
    end
  end

  it "injects for ng without --strictPort" do
    args = %w[ng serve]
    inject_framework_flags(args, 4567)
    assert_equal %w[ng serve --port 4567 --host 127.0.0.1], args
  end

  it "injects for react-native without --strictPort" do
    args = %w[react-native start]
    inject_framework_flags(args, 4567)
    assert_equal %w[react-native start --port 4567 --host 127.0.0.1], args
  end

  it "injects for expo without --strictPort (defaults to localhost)" do
    args = %w[expo start]
    inject_framework_flags(args, 4567)
    assert_equal %w[expo start --port 4567 --host localhost], args
  end

  it "injects --port and --ip for wrangler dev" do
    args = %w[wrangler dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[wrangler dev --port 4567 --ip 127.0.0.1], args
  end

  it "skips --ip injection for wrangler when --ip is already present" do
    args = %w[wrangler dev --ip 0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[wrangler dev --ip 0.0.0.0 --port 4567], args
  end

  it "skips --ip injection for wrangler when --ip=value is present" do
    args = %w[wrangler dev --ip=0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[wrangler dev --ip=0.0.0.0 --port 4567], args
  end

  it "skips --host for expo in LAN mode (Metro defaults to LAN)" do
    with_env("PORTLESS_LAN" => "1") do
      args = %w[expo start]
      inject_framework_flags(args, 4567)
      assert_equal %w[expo start --port 4567], args
    end
  end

  it "does not inject for frameworks that read PORT" do
    next_args = %w[next dev]
    inject_framework_flags(next_args, 4567)
    assert_equal %w[next dev], next_args

    nuxt_args = %w[nuxt dev]
    inject_framework_flags(nuxt_args, 4567)
    assert_equal %w[nuxt dev], nuxt_args

    node_args = %w[node server.js]
    inject_framework_flags(node_args, 4567)
    assert_equal %w[node server.js], node_args
  end

  it "does nothing for empty args" do
    args = []
    inject_framework_flags(args, 4567)
    assert_equal [], args
  end

  # `vite optimize --port 4567` exits with `CACError: Unknown option --port`.

  it "does not inject into %s %s" do
    [
      %w[vite build],
      %w[vite optimize],
      %w[vp test],
      %w[vp build],
      %w[astro check],
      %w[expo export],
      %w[ng generate],
      %w[react-router typegen],
      %w[rsbuild inspect],
      %w[react-native bundle],
      %w[wrangler deploy]
    ].each do |framework, subcommand|
      args = [ framework, subcommand ]
      inject_framework_flags(args, 4567)
      assert_equal [ framework, subcommand ], args
    end
  end

  it "does not inject into a runner-wrapped non-server subcommand" do
    args = %w[bunx --bun vite optimize]
    inject_framework_flags(args, 4567)
    assert_equal %w[bunx --bun vite optimize], args
  end

  # A flag value that happens to spell a server subcommand (`--mode dev`) must
  # not be read as one. `dev`, `serve` and `preview` are ordinary mode names.

  it "does not inject when a flag value precedes %j" do
    [
      %w[vite --mode production build],
      %w[vite --mode dev build],
      %w[vite --mode preview build],
      %w[vite -m dev optimize],
      %w[vite --mode=dev build],
      %w[vite --logLevel dev optimize],
      %w[rsbuild --mode dev build],
      %w[rsbuild --env-mode dev build],
      %w[bunx --bun vite --mode dev build]
    ].each do |command|
      args = command.dup
      inject_framework_flags(args, 4567)
      assert_equal command, args
    end
  end

  it "injects for a bare rsbuild dev server behind a consumed flag value" do
    # Distinguishes arity from the unknown-grammar bail: without rsbuild's own
    # value flags, `production` would read as an unrecognized subcommand.
    args = %w[rsbuild --env-mode production]
    inject_framework_flags(args, 4567)
    assert_equal %w[rsbuild --env-mode production --port 4567 --host 127.0.0.1], args
  end

  it "injects for expo serve, which serves the export on a port" do
    args = %w[expo serve]
    inject_framework_flags(args, 4567)
    assert_equal %w[expo serve --port 4567 --host localhost], args
  end

  it "does not inject when the flag grammar of the CLI is unknown" do
    # `vp` declares no value flags, so `--mode dev build` and `--open build`
    # cannot both be resolved and the subcommand stays unidentified.
    args = %w[vp --mode dev build]
    inject_framework_flags(args, 4567)
    assert_equal %w[vp --mode dev build], args
  end

  it "injects when a flag follows the server subcommand of an unlisted grammar" do
    args = %w[astro dev --config x.ts]
    inject_framework_flags(args, 4567)
    assert_equal %w[astro dev --config x.ts --port 4567 --host 127.0.0.1], args
  end

  it "injects for preview, which serves the built output on a port" do
    args = %w[vite preview]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite preview --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects for a bare invocation whose default command is the dev server" do
    args = %w[vite]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite --port 4567 --strictPort --host 127.0.0.1], args

    expo_args = %w[expo]
    inject_framework_flags(expo_args, 4567)
    assert_equal %w[expo --port 4567 --host localhost], expo_args
  end

  it "does not inject for a bare invocation that only prints help" do
    args = %w[astro]
    inject_framework_flags(args, 4567)
    assert_equal %w[astro], args
  end

  it "injects past a root positional that follows a server subcommand" do
    args = %w[vite dev ./app]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite dev ./app --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "treats a Vite positional root as the default server command" do
    args = %w[vite ./app]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite ./app --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects when only a consumed flag value precedes the default command" do
    args = %w[vite --config ./cfg.ts]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite --config ./cfg.ts --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects when a consumed flag value precedes the server subcommand" do
    args = %w[vite --logLevel info dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite --logLevel info dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "places flags before a bare -- so the framework parses them as options" do
    # Appended past `--` they arrive as positional data: vite keeps port 5173.
    args = %w[vite dev -- --mode build]
    inject_framework_flags(args, 4567)
    assert_equal %w[vite dev --port 4567 --strictPort --host 127.0.0.1 -- --mode build], args
  end

  it "returns the flags it added" do
    assert_equal %w[--port 4567 --strictPort --host 127.0.0.1], inject_framework_flags(%w[vite dev], 4567)
    assert_equal [], inject_framework_flags(%w[vite optimize], 4567)
    assert_equal [], inject_framework_flags(%w[node server.js], 4567)
  end

  # Package runner support (issue #146: bunx --bun vite dev gives 502)

  # Simple runners (npx, bunx, pnpx)

  it "injects flags for bunx vite dev" do
    args = %w[bunx vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[bunx vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for bunx --bun vite dev" do
    args = %w[bunx --bun vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[bunx --bun vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for npx vite dev" do
    args = %w[npx vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for npx with flags before framework" do
    args = %w[npx --yes vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx --yes vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "keeps an npx option separator before the framework command" do
    args = %w[npx -- vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx -- vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for pnpx vite dev" do
    args = %w[pnpx vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[pnpx vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  # Subcommand runners (yarn dlx/exec, pnpm dlx/exec)

  it "injects flags for yarn dlx vite dev" do
    args = %w[yarn dlx vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[yarn dlx vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for yarn exec vite dev" do
    args = %w[yarn exec vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[yarn exec vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for pnpm dlx vite dev" do
    args = %w[pnpm dlx vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[pnpm dlx vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects flags for pnpm exec astro dev" do
    args = %w[pnpm exec astro dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[pnpm exec astro dev --port 4567 --host 127.0.0.1], args
  end

  it "injects flags for npm exec astro dev with a separator" do
    args = %w[npm exec astro dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npm exec astro dev -- --port 4567 --host 127.0.0.1], args
  end

  it "injects flags for npm exec -- astro dev without an extra separator" do
    args = %w[npm exec -- astro dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npm exec -- astro dev --port 4567 --host 127.0.0.1], args
  end

  it "injects flags for npm x astro dev with a separator" do
    args = %w[npm x astro dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npm x astro dev -- --port 4567 --host 127.0.0.1], args
  end

  it "injects flags for npm exec --package astro -- astro dev" do
    args = %w[npm exec --package astro -- astro dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npm exec --package astro -- astro dev --port 4567 --host 127.0.0.1], args
    prefixed = %w[npm --prefix ./app exec -- vite dev]
    inject_framework_flags(prefixed, 4567)
    assert_equal %w[npm --prefix ./app exec -- vite dev --port 4567 --strictPort --host 127.0.0.1], prefixed
  end

  it "appends only missing flags after a separator for npm exec astro dev -- --port 3000" do
    args = %w[npm exec astro dev -- --port 3000]
    inject_framework_flags(args, 4567)
    assert_equal %w[npm exec astro dev -- --port 3000 --host 127.0.0.1], args
  end

  it "injects past an option npm consumes for npm exec vite dev --port=3000" do
    args = %w[npm exec vite dev --port=3000]
    inject_framework_flags(args, 4567)
    assert_equal %w[npm exec vite dev --port=3000 -- --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "does not inject when npm may consume an option value for npm exec vite --loglevel info build" do
    args = %w[npm exec vite --loglevel info build]
    assert_equal [], inject_framework_flags(args, 4567)
    assert_equal %w[npm exec vite --loglevel info build], args
  end

  it "injects flags for npx rsbuild dev" do
    args = %w[npx rsbuild dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx rsbuild dev --port 4567 --host 127.0.0.1], args
  end

  # Implicit bin (yarn <framework>)

  it "injects flags for yarn vite (implicit bin)" do
    args = %w[yarn vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[yarn vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  # Runner with multiple flags

  it "skips multiple runner flags before framework" do
    args = %w[npx --yes --quiet vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx --yes --quiet vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  # Runner + --port / --host already present

  it "skips --port when already present via runner" do
    args = %w[bunx vite dev --port 3000]
    inject_framework_flags(args, 4567)
    assert_includes args, "3000"
    refute_includes args, "4567"
  end

  it "skips --host when already present via runner" do
    args = %w[npx vite dev --host 0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx vite dev --host 0.0.0.0 --port 4567 --strictPort], args
  end

  it "skips all injection when both --port and --host present via runner" do
    args = %w[bunx --bun vite dev --port 3000 --host 0.0.0.0]
    inject_framework_flags(args, 4567)
    assert_equal %w[bunx --bun vite dev --port 3000 --host 0.0.0.0], args
  end

  it "does not treat runner options as framework options" do
    args = %w[npx --package=host-tool -- vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx --package=host-tool -- vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "consumes separate runner option values before the framework command" do
    args = %w[npx --package vite -- vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx --package vite -- vite dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "preserves Expo connection mode %s while still injecting the port" do
    %w[--localhost --lan --tunnel].each do |mode|
      args = [ "expo", "start", mode ]
      inject_framework_flags(args, 4567)
      assert_equal [ "expo", "start", mode, "--port", "4567" ], args
    end
  end

  # Negative cases: runner with non-framework commands

  it "does not inject for bunx with non-framework command" do
    args = %w[bunx --bun next dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[bunx --bun next dev], args
  end

  it "does not inject for npx with non-framework command" do
    args = %w[npx next dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx next dev], args
  end

  it "does not inject for yarn with unrecognized subcommand" do
    args = %w[yarn run next dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[yarn run next dev], args
  end

  it "does not inject for pnpm with unrecognized subcommand" do
    args = %w[pnpm run vite dev]
    inject_framework_flags(args, 4567)
    assert_equal %w[pnpm run vite dev], args
  end

  # Edge cases

  it "does not inject when runner has only flags and no command" do
    args = %w[bunx --bun]
    inject_framework_flags(args, 4567)
    assert_equal %w[bunx --bun], args
  end

  it "does not inject for runner alone with no arguments" do
    args = %w[npx]
    inject_framework_flags(args, 4567)
    assert_equal %w[npx], args
  end

  it "does not inject for yarn subcommand with no further arguments" do
    args = %w[yarn dlx]
    inject_framework_flags(args, 4567)
    assert_equal %w[yarn dlx], args
  end

  it "does not inject for yarn with only flags and no subcommand" do
    args = %w[yarn --silent]
    inject_framework_flags(args, 4567)
    assert_equal %w[yarn --silent], args
  end
end
describe "injectPackageScriptFrameworkFlags" do
  include CliUtilsSupport

  before { @pkg_dir = Dir.mktmpdir("portless-pkg-script-") }
  after { FileUtils.rm_rf(@pkg_dir) }

  def write_scripts(scripts) = write_package(@pkg_dir, scripts)

  it "forwards vite flags through bun run <script>" do
    write_scripts(dev: "vite dev --host 127.0.0.1")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort], args
  end

  it "inserts -- before forwarded flags for npm run <script>" do
    write_scripts(dev: "vite dev --host 127.0.0.1")
    args = %w[npm run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[npm run dev -- --port 4567 --strictPort], args
  end

  it "forwards flags directly for pnpm run <script>" do
    write_scripts(dev: "vite dev --host 127.0.0.1")
    args = %w[pnpm run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[pnpm run dev --port 4567 --strictPort], args
  end

  it "forwards flags directly for yarn run <script>" do
    write_scripts(dev: "vite dev --host 127.0.0.1")
    args = %w[yarn run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[yarn run dev --port 4567 --strictPort], args
  end

  it "forwards --host too when the script does not set it" do
    write_scripts(dev: "vite dev")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "does not forward when the script already sets --port" do
    write_scripts(dev: "vite dev --port 5000 --host 127.0.0.1")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "does not duplicate --port supplied by user trailing args" do
    write_scripts(dev: "vite dev --host 127.0.0.1")
    args = %w[npm run dev -- --port 3000]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[npm run dev -- --port 3000], args
  end

  it "does not duplicate --port=<number> supplied by the script or user" do
    write_scripts(dev: "vite dev --port=5000 --host=127.0.0.1")
    script_args = %w[bun run dev]
    inject_package_script_framework_flags(script_args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], script_args

    write_scripts(dev: "vite dev --host=127.0.0.1")
    user_args = %w[bun run dev --port=3000]
    inject_package_script_framework_flags(user_args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port=3000], user_args
  end

  it "does not forward flags to compound scripts" do
    write_scripts(dev: "vite dev && node second.js")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "does not forward flags to compound scripts with glued operators" do
    write_scripts(dev: "vite dev&&node second.js")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "does not forward flags to compound scripts separated by a newline" do
    write_scripts(dev: "vite dev\nnode second.js")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "does not forward flags to compound scripts piped between commands" do
    write_scripts(dev: "vite dev | tee log.txt")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "still forwards flags when a shell metacharacter is inside quotes (single command)" do
    write_scripts(dev: "vite dev --open '/foo&bar'")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "still forwards flags when the script redirects output (single command)" do
    write_scripts(dev: "vite dev >vite.log 2>&1")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "injects the missing --host even when --port is already present in the script" do
    write_scripts(dev: "expo start --port 4567")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --host localhost], args
  end

  it "preserves Expo connection mode %s through a package script" do
    %w[--localhost --lan --tunnel].each do |mode|
      write_scripts(dev: "expo start #{mode}")
      args = %w[pnpm run dev]
      inject_package_script_framework_flags(args, 4567, @pkg_dir)
      assert_equal %w[pnpm run dev --port 4567], args
    end
  end

  it "injects the missing --port even when --host is already present in the script" do
    write_scripts(dev: "vite dev --host 127.0.0.1")
    args = %w[bun run dev -- --host 0.0.0.0]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev -- --host 0.0.0.0 --port 4567 --strictPort], args
  end

  it "does not forward server flags to framework build commands" do
    write_scripts(build: "vite build")
    args = %w[bun run build]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run build], args
  end

  it "does not forward server flags to runner-wrapped build commands" do
    write_scripts(build: "bunx vite build")
    args = %w[bun run build]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run build], args
  end

  it "does not forward server flags when a flag value precedes the build subcommand" do
    write_scripts(build: "vite --mode production build")
    args = %w[bun run build]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run build], args
  end

  it "does not forward server flags to non-server subcommands beyond build" do
    write_scripts(
      optimize: "vite optimize",
      test: "vp test",
      export: "expo export",
      check: "astro check"
    )
    %w[optimize test export check].each do |script|
      args = [ "bun", "run", script ]
      inject_package_script_framework_flags(args, 4567, @pkg_dir)
      assert_equal [ "bun", "run", script ], args
    end
  end

  it "does not forward into a script that ends its own option list" do
    # Appending cannot reach past the script's own `--`, so the flags would
    # arrive as positional data and the framework would keep its default port.
    write_scripts(dev: "vite dev -- --extra")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "forwards server flags to preview, the other server subcommand" do
    write_scripts(preview: "vite preview")
    args = %w[bun run preview]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run preview --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "does not forward for non-framework scripts" do
    write_scripts(dev: "node server.js")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "resolves package runners inside the script (bunx vite dev)" do
    write_scripts(dev: "bunx vite dev --host 127.0.0.1")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort], args
  end

  it "forwards flags through a script that uses npm exec with a separator" do
    write_scripts(dev: "npm exec -- vite dev")
    args = %w[npm run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[npm run dev -- --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "ignores commands that are not <pm> run <script>" do
    write_scripts(dev: "vite dev")
    [
      %w[vite dev],
      %w[bun dev],
      %w[bun run --bun],
      %w[bunx vite dev],
      %w[cargo run dev]
    ].each do |args|
      before = args.dup
      inject_package_script_framework_flags(args, 4567, @pkg_dir)
      assert_equal before, args
    end
  end

  it "ignores scripts that do not exist in package.json" do
    write_scripts(start: "vite dev")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "resolves the runner through an absolute path" do
    write_scripts(dev: "vite dev --host 127.0.0.1")
    args = %w[/usr/local/bin/bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[/usr/local/bin/bun run dev --port 4567 --strictPort], args
  end

  # A trailing comment makes the shell discard everything appended after it,
  # so injection would look successful and deliver nothing.
  it "skips a script ending in a shell comment" do
    write_scripts(dev: "vite dev # keep this note")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "skips a script with a comment after the framework flags" do
    write_scripts(dev: "vite dev --open  # opens a browser")
    args = %w[npm run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[npm run dev], args
  end

  # Not a guard clause: the resolver declines these because "(vite" is not a
  # framework name. Pinned so a future resolver that tokenizes shell syntax
  # does not start injecting into them.
  it "skips a subshell script" do
    write_scripts(dev: "(vite dev)")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "still injects when # is inside a word or quoted" do
    write_scripts(dev: "vite dev --tag v1#2")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  # A backslash-newline is a line continuation, not an escaped character: the
  # shell joins the lines and the `#` still opens a comment.
  it "skips a script whose comment follows a line continuation" do
    write_scripts(dev: "vite dev \\\n# note")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "still injects when an escaped space precedes a #" do
    # `--open /foo\ #bar` is a single argument, not a comment: the space is
    # escaped, so the `#` does not begin a word.
    write_scripts(dev: "vite dev --open /foo\\ #bar")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort --host 127.0.0.1], args
  end

  it "still injects when a script substitutes a command mid-word" do
    write_scripts(dev: "vite dev --define SHA=$(git rev-parse HEAD)")
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev --port 4567 --strictPort --host 127.0.0.1], args
  end
end

describe "resolveFrameworkBasename" do
  include CliUtilsSupport

  before { @pkg_dir = Dir.mktmpdir("portless-fw-resolve-") }
  after { FileUtils.rm_rf(@pkg_dir) }

  def write_scripts(scripts) = write_package(@pkg_dir, scripts)

  it "resolves a direct invocation" do
    assert_equal "vite", resolve_framework_basename(%w[vite dev], @pkg_dir)
  end

  it "resolves through a package runner" do
    assert_equal "vite", resolve_framework_basename(%w[bunx --bun vite dev], @pkg_dir)
  end

  # The env binder in cli.ts uses this to decide whether to export HOST.
  # Reading commandArgs[0] there saw `bun` and broke Expo's HMR in LAN mode.
  it "resolves expo through a package script" do
    write_scripts(dev: "expo start")
    assert_equal "expo", resolve_framework_basename(%w[bun run dev], @pkg_dir)
  end

  # Resolution and append-safety are different questions. A script portless
  # refuses to append flags to still runs Metro, and the LAN carve-out that
  # suppresses HOST keys off the framework, not off whether flags were added.
  it "still identifies expo in a script portless will not append to" do
    write_scripts(dev: "expo start --port 4567 # note")
    assert_equal "expo", resolve_framework_basename(%w[bun run dev], @pkg_dir)
    args = %w[bun run dev]
    inject_package_script_framework_flags(args, 4567, @pkg_dir)
    assert_equal %w[bun run dev], args
  end

  it "still identifies expo in a build script" do
    write_scripts(dev: "expo build")
    assert_equal "expo", resolve_framework_basename(%w[bun run dev], @pkg_dir)
  end

  it "returns null when no known framework is reached" do
    write_scripts(dev: "node server.js")
    assert_nil resolve_framework_basename(%w[bun run dev], @pkg_dir)
    assert_nil resolve_framework_basename(%w[node server.js], @pkg_dir)
  end
end

describe "resolveTurboRootForwarding" do
  include CliUtilsSupport

  before { @pkg_dir = Dir.mktmpdir("portless-turbo-root-") }
  after { FileUtils.rm_rf(@pkg_dir) }

  def write_root_package(scripts, package_manager = nil)
    write_package(@pkg_dir, scripts, name: "test-root", package_manager: package_manager)
  end

  def resolve(dev, extra_scripts = {}, package_manager = nil)
    write_root_package({ dev: dev, **extra_scripts }, package_manager)
    Portless::Frameworks.resolve_turbo_root_forwarding("dev", @pkg_dir)
  end

  it "resolves %s with %i separator(s)" do
    [
      [ "turbo dev", 1 ],
      [ "./node_modules/.bin/turbo dev", 1 ],
      [ "/opt/tools/turbo run dev --filter web", 1 ],
      [ "npx turbo dev", 1 ],
      [ "npx --yes -p turbo turbo dev", 1 ],
      [ "npx turbo@2 dev", 1 ],
      [ "npm exec turbo dev", 2 ],
      [ "npm exec -- turbo dev", 1 ],
      [ "npm exec turbo dev --", 1 ],
      [ "npm exec turbo@2 dev", 2 ],
      [ "env npm exec turbo dev", 2 ],
      [ "pnpm exec turbo dev", 1 ],
      [ "pnpm dlx turbo dev", 1 ],
      [ "pnpm dlx turbo@2 dev", 1 ],
      [ "bunx turbo dev", 1 ],
      [ "yarn turbo dev", 2 ],
      [ "yarn exec turbo dev", 2 ],
      [ "yarn exec -- turbo dev", 1 ],
      [ "yarn dlx turbo@2 dev", 1 ],
      [ "FOO=bar turbo dev", 1 ],
      [ "env FOO=bar turbo dev", 1 ],
      [ "env -i turbo dev", 1 ],
      [ "env --ignore-environment turbo dev", 1 ],
      [ "env -i FOO=bar turbo dev", 1 ],
      [ "env -u FOO turbo dev", 1 ],
      [ "env --unset FOO turbo dev", 1 ],
      [ "env --unset=FOO turbo dev", 1 ],
      [ "env -u FOO npm exec turbo dev", 2 ],
      [ "env --ignore-environment -- turbo dev", 1 ],
      [ "cross-env NODE_ENV=test turbo dev", 1 ],
      [ "cross-env NODE_ENV=test npx turbo dev", 1 ],
      [ "dotenv -- turbo dev", 1 ],
      [ "dotenv -e .env.local -- turbo dev", 1 ],
      [ "dotenv turbo dev", 2 ],
      [ "dotenv turbo dev --", 1 ],
      [ "bun x turbo dev", 1 ],
      [ "bun --bun x turbo@2 dev", 1 ],
      [ "bun run turbo dev", 1 ],
      [ "turbo dev --", 0 ],
      [ "turbo dev -- --inspect", 0 ],
      [ "npx turbo dev --", 0 ]
    ].each do |script, separators|
      assert_equal({ kind: "forward", separators: separators }, resolve(script), script)
    end
  end

  it "resolves Yarn Berry %s with %i separator(s)" do
    [
      [ "yarn turbo dev", 1 ],
      [ "yarn exec turbo dev", 1 ]
    ].each do |script, separators|
      assert_equal({ kind: "forward", separators: separators }, resolve(script, {}, "yarn@4.0.0"), script)
    end
  end

  it "reports an unsafe %s" do
    [
      [ "turbo dev && node mark.cjs", true ],
      [ "turbo dev || exit 1", true ],
      [ "turbo dev; node mark.cjs", true ],
      [ "turbo dev | tee turbo.log", true ],
      [ "turbo dev # note", true ],
      [ "node mark.cjs && node mark.cjs", false ]
    ].each do |script, turbo|
      assert_equal({ kind: "unsafe", turbo: turbo }, resolve(script), script)
    end
  end

  it "returns none for %s" do
    [
      "node mark.cjs",
      "npx next dev",
      "env node mark.cjs",
      "pnpm exec next dev",
      "npm run dev",
      "npm run missing",
      "turbo@2 dev",
      "pnpm exec turbo@2 dev",
      "yarn turbo@2 dev",
      "env -u",
      "env -u FOO"
    ].each do |script|
      assert_equal({ kind: "none" }, resolve(script), script)
    end
  end

  it "normalizes %s one level through %s" do
    [
      [ "npm@10.0.0", "npm run turbo-dev", "turbo dev", 2 ],
      [ "npm@10.0.0", "npm run turbo-dev --", "turbo dev", 1 ],
      [ "npm@10.0.0", "npm run turbo-dev", "turbo dev -- --fixed", 1 ],
      [ "npm@10.0.0", "npm run turbo-dev --", "turbo dev -- --fixed", 0 ],
      [ "pnpm@11.1.3", "pnpm run turbo-dev", "turbo dev", 1 ],
      [ "pnpm@11.1.3", "pnpm run turbo-dev --", "turbo dev", 0 ],
      [ "pnpm@11.1.3", "pnpm run turbo-dev", "turbo dev -- --fixed", 0 ],
      [ "pnpm@11.1.3", "pnpm run turbo-dev --", "turbo dev -- --fixed", 0 ],
      [ "bun@1.4.4", "bun run turbo-dev", "turbo dev", 2 ],
      [ "bun@1.4.4", "bun run turbo-dev --", "turbo dev", 1 ],
      [ "bun@1.4.4", "bun run turbo-dev", "turbo dev -- --fixed", 1 ],
      [ "bun@1.4.4", "bun run turbo-dev --", "turbo dev -- --fixed", 0 ],
      [ "yarn@1.22.19", "yarn run turbo-dev", "turbo dev", 2 ],
      [ "yarn@1.22.19", "yarn run turbo-dev --", "turbo dev", 1 ],
      [ "yarn@4.0.0", "yarn run turbo-dev", "turbo dev", 1 ],
      [ "yarn@4.0.0", "yarn run turbo-dev --", "turbo dev", 0 ],
      [ "yarn@1.22.19", "yarn turbo-dev", "turbo dev", 2 ],
      [ "yarn@1.22.19", "yarn turbo-dev --", "turbo dev", 1 ],
      [ "yarn@4.0.0", "yarn turbo-dev", "turbo dev", 1 ],
      [ "yarn@4.0.0", "yarn turbo-dev --", "turbo dev", 0 ],
      [ "npm@10.0.0", "FOO=1 npm run turbo-dev", "turbo dev", 2 ],
      [ "npm@10.0.0", "FOO=1 npm run turbo-dev --", "turbo dev", 1 ],
      [ "npm@10.0.0", "FOO=1 npm run turbo-dev", "turbo dev -- --fixed", 1 ],
      [ "npm@10.0.0", "env FOO=1 npm run turbo-dev", "turbo dev", 2 ],
      [ "npm@10.0.0", "env -u FOO npm run turbo-dev", "turbo dev", 2 ],
      [ "npm@10.0.0", "env --unset=FOO npm run turbo-dev", "turbo dev", 2 ],
      [ "npm@10.0.0", "cross-env NODE_ENV=test npm run turbo-dev", "turbo dev", 2 ],
      [ "pnpm@11.1.3", "FOO=1 pnpm run turbo-dev", "turbo dev", 1 ],
      [ "bun@1.4.4", "FOO=1 bun run turbo-dev", "turbo dev", 2 ],
      [ "yarn@1.22.19", "FOO=1 yarn run turbo-dev", "turbo dev", 2 ],
      [ "yarn@4.0.0", "FOO=1 yarn run turbo-dev", "turbo dev", 1 ],
      [ "npm@10.0.0", "npm run turbo-dev", "npx turbo@2 dev", 2 ]
    ].each do |package_manager, dev, nested, separators|
      assert_equal({ kind: "forward", separators: separators },
                   resolve(dev, { "turbo-dev": nested }, package_manager), [ package_manager, dev, nested ].join(" | "))
    end
  end

  it "reports an unsafe nested Turbo script" do
    assert_equal({ kind: "unsafe", turbo: true },
                 resolve("npm run turbo-dev", { "turbo-dev": "turbo dev && node mark.cjs" }, "npm@10.0.0"))
  end

  it "returns none for a one-level non-Turbo script" do
    assert_equal({ kind: "none" }, resolve("npm run turbo-dev", { "turbo-dev": "node mark.cjs" }, "npm@10.0.0"))
  end

  it "follows delegation through several scripts and stops at a cycle" do
    nested = { "turbo-dev": "npm run deeper", deeper: "turbo dev" }
    assert_equal({ kind: "forward", separators: 3 }, resolve("npm run turbo-dev", nested, "npm@10.0.0"))
    assert_equal({ kind: "none" }, resolve("npm run other", { other: "npm run dev" }, "npm@10.0.0"))
  end

  it "reports when Turbo delegation exceeds the depth limit" do
    nested = {
      one: "npm run two",
      two: "npm run three",
      three: "npm run four",
      four: "npm run five",
      five: "npm run six",
      six: "turbo dev"
    }
    assert_equal({ kind: "too-deep" }, resolve("npm run one", nested, "npm@10.0.0"))
  end

  it "returns none when the script is missing" do
    write_root_package({})
    assert_equal({ kind: "none" }, Portless::Frameworks.resolve_turbo_root_forwarding("dev", @pkg_dir))
  end
end

describe "resolveScriptArgForwarding" do
  include CliUtilsSupport

  before { @pkg_dir = Dir.mktmpdir("portless-script-forward-") }
  after { FileUtils.rm_rf(@pkg_dir) }

  def resolve(dev, extra_scripts = {}, package_manager = nil)
    write_package(@pkg_dir, { dev: dev, **extra_scripts }, package_manager: package_manager)
    Portless::Frameworks.resolve_script_arg_forwarding("dev", @pkg_dir)
  end

  it "resolves %s with %i separator(s)" do
    [
      [ "node server.js", {}, nil, 0 ],
      [ "npm run start", { start: "node server.js" }, "npm@10.0.0", 1 ],
      [ "npm run start --", { start: "node server.js" }, "npm@10.0.0", 0 ],
      [ "npm run mid", { mid: "npm run start", start: "node server.js" }, "npm@10.0.0", 2 ],
      [ "pnpm run start", { start: "node server.js" }, "pnpm@11.1.3", 0 ],
      [ "bun run start", { start: "node server.js" }, "bun@1.4.4", 1 ],
      [ "yarn run start", { start: "node server.js" }, "yarn@1.22.19", 1 ],
      [ "yarn run start", { start: "node server.js" }, "yarn@4.0.0", 0 ],
      [ "yarn start", { start: "node server.js" }, "yarn@1.22.19", 1 ],
      [ "yarn start", { start: "node server.js" }, "yarn@4.0.0", 0 ],
      [ "npm exec vite", {}, "npm@10.0.0", 1 ],
      [ "npm exec -- vite", {}, "npm@10.0.0", 0 ]
    ].each do |dev, extra, pm, separators|
      assert_equal({ kind: "forward", separators: separators }, resolve(dev, extra, pm), "#{dev} (#{pm})")
    end
  end

  it "keeps a parent separator when the leaf has a literal separator" do
    assert_equal({ kind: "forward", separators: 1 },
                 resolve("npm run start", { start: "node a.cjs -- --a" }, "npm@10.0.0"))
  end

  it "stops delegation when a workspace target loops to the current script" do
    assert_equal({ kind: "forward", separators: 1 }, resolve("npm run dev -w web", {}, "npm@10.0.0"))
  end

  it "reports unsafe nested scripts and treats delegation cycles as leaves" do
    assert_equal({ kind: "unsafe", script_name: "start" },
                 resolve("npm run start", { start: "node a.js && node b.js" }, "npm@10.0.0"))
    assert_equal({ kind: "forward", separators: 2 }, resolve("npm run start", { start: "npm run dev" }, "npm@10.0.0"))
  end
end

describe "DEFAULT_TLD" do
  include CliUtilsSupport

  it "is localhost" do
    assert_equal "localhost", Portless::Utils::DEFAULT_TLD
  end
end

describe "getDefaultTld" do
  include CliUtilsSupport

  before { @original_env = ENV.fetch("PORTLESS_TLD", nil) }
  after { @original_env.nil? ? ENV.delete("PORTLESS_TLD") : ENV["PORTLESS_TLD"] = @original_env }

  def default_tld = Portless::Utils.default_tlds.first

  it "returns DEFAULT_TLD when PORTLESS_TLD is not set" do
    ENV.delete("PORTLESS_TLD")
    assert_equal Portless::Utils::DEFAULT_TLD, default_tld
  end

  it "returns PORTLESS_TLD when set" do
    ENV["PORTLESS_TLD"] = "test"
    assert_equal "test", default_tld
  end

  it "lowercases the value" do
    ENV["PORTLESS_TLD"] = "TEST"
    assert_equal "test", default_tld
  end

  it "trims whitespace" do
    ENV["PORTLESS_TLD"] = "  test  "
    assert_equal "test", default_tld
  end

  it "returns DEFAULT_TLD when PORTLESS_TLD is empty" do
    ENV["PORTLESS_TLD"] = ""
    assert_equal Portless::Utils::DEFAULT_TLD, default_tld
  end

  it "returns the first TLD when PORTLESS_TLD contains a list" do
    ENV["PORTLESS_TLD"] = "localhost,test"
    assert_equal "localhost", default_tld
  end
end

describe "getDefaultTlds" do
  include CliUtilsSupport

  before { @original_env = ENV.fetch("PORTLESS_TLD", nil) }
  after { @original_env.nil? ? ENV.delete("PORTLESS_TLD") : ENV["PORTLESS_TLD"] = @original_env }

  it "returns DEFAULT_TLD when PORTLESS_TLD is not set" do
    ENV.delete("PORTLESS_TLD")
    assert_equal [ Portless::Utils::DEFAULT_TLD ], Portless::Utils.default_tlds
  end

  it "parses comma separated values" do
    ENV["PORTLESS_TLD"] = "localhost, test"
    assert_equal %w[localhost test], Portless::Utils.default_tlds
  end

  it "deduplicates values in order" do
    ENV["PORTLESS_TLD"] = "test,localhost,test"
    assert_equal %w[test localhost], Portless::Utils.default_tlds
  end
end

describe "parseTldList" do
  include CliUtilsSupport

  it "parses and normalizes values" do
    assert_equal %w[test localhost], Portless::Utils.parse_tld_list(" TEST,localhost ")
  end

  it "rejects empty list entries" do
    error = assert_raises(Portless::Error) { Portless::Utils.parse_tld_list("test,") }
    assert_includes error.message, "TLD cannot be empty"
  end

  it "accepts a mix of single- and multi-segment TLDs" do
    assert_equal %w[localhost dev.example.com], Portless::Utils.parse_tld_list("localhost,dev.example.com")
  end
end

describe "buildProxyStartConfig" do
  include CliUtilsSupport

  it "forces .local and keeps explicit --ip in LAN mode" do
    assert_equal(
      {
        effective_tld: "local",
        effective_tlds: [ "local" ],
        args: %w[--foreground --port 8080 --https --lan --ip 192.168.1.42 --wildcard]
      },
      Portless::Daemon.build_start_config(
        use_https: true,
        lan_mode: true,
        lan_ip: "192.168.1.42",
        lan_ip_explicit: true,
        tld: "test",
        use_wildcard: true,
        foreground: true,
        include_port: true,
        proxy_port: 8080
      )
    )
  end

  it "emits --unprivileged only when requested" do
    base = { use_https: false, lan_mode: false, tld: "localhost" }
    assert_equal %w[--no-tls --unprivileged], Portless::Daemon.build_start_config(**base, unprivileged: true)[:args]
    assert_equal %w[--no-tls], Portless::Daemon.build_start_config(**base)[:args]
  end

  it "passes auto-detected LAN IP through an internal flag" do
    assert_equal(
      {
        effective_tld: "local",
        effective_tlds: [ "local" ],
        args: [ "--no-tls", "--lan", Portless::Daemon::INTERNAL_LAN_IP_FLAG, "192.168.1.42" ]
      },
      Portless::Daemon.build_start_config(
        use_https: false,
        lan_mode: true,
        lan_ip: "192.168.1.42",
        lan_ip_explicit: false,
        tld: "localhost"
      )
    )
  end

  it "keeps custom TLDs outside LAN mode" do
    assert_equal(
      { effective_tld: "test", effective_tlds: [ "test" ], args: %w[--no-tls --tld test] },
      Portless::Daemon.build_start_config(use_https: false, lan_mode: false, tld: "test")
    )
  end

  it "emits each TLD outside LAN mode" do
    assert_equal(
      {
        effective_tld: "localhost",
        effective_tlds: %w[localhost test],
        args: %w[--https --tld localhost --tld test]
      },
      Portless::Daemon.build_start_config(use_https: true, lan_mode: false, tld: "localhost", tlds: %w[localhost test])
    )
  end
end

describe "readLanMarker / writeLanMarker" do
  include CliUtilsSupport

  before { @tmp_dir = Dir.mktmpdir("portless-lan-test-") }
  after { FileUtils.rm_rf(@tmp_dir) }

  it "writes and reads a LAN IP" do
    Portless::Daemon.write_lan_marker(@tmp_dir, "192.168.1.42")
    assert_equal "192.168.1.42", Portless::Daemon.read_lan_marker(@tmp_dir)
  end

  it "removes the file when writing null" do
    Portless::Daemon.write_lan_marker(@tmp_dir, "192.168.1.42")
    assert_equal true, File.exist?(File.join(@tmp_dir, "proxy.lan"))

    Portless::Daemon.write_lan_marker(@tmp_dir, nil)
    assert_equal false, File.exist?(File.join(@tmp_dir, "proxy.lan"))
    assert_nil Portless::Daemon.read_lan_marker(@tmp_dir)
  end

  it "uses the LAN marker to remember LAN mode when the proxy is stopped" do
    File.write(File.join(@tmp_dir, "proxy.port"), "1355")
    Portless::Daemon.write_tlds(@tmp_dir, [ "local" ])
    Portless::Daemon.write_lan_marker(@tmp_dir, "192.168.1.42")
    with_env("PORTLESS_STATE_DIR" => @tmp_dir) do
      state = Portless::Daemon.discover_state
      assert_equal @tmp_dir, state.dir
      assert_equal 1355, state.port
      assert_equal "local", state.tld
      assert_equal true, state.lan_mode
      assert_nil state.lan_ip
    end
  end
end

describe "readTldFromDir / writeTldFile" do
  include CliUtilsSupport

  before { @tmp_dir = Dir.mktmpdir("portless-tld-test-") }
  after { FileUtils.rm_rf(@tmp_dir) }

  def read_tld_from_dir(dir) = Portless::Daemon.read_tlds(dir).first
  def write_tld_file(dir, tld) = Portless::Daemon.write_tlds(dir, [ tld ])

  it "returns DEFAULT_TLD when file does not exist" do
    assert_equal Portless::Utils::DEFAULT_TLD, read_tld_from_dir(@tmp_dir)
    assert_equal [ Portless::Utils::DEFAULT_TLD ], Portless::Daemon.read_tlds(@tmp_dir)
  end

  it "writes and reads a custom TLD" do
    write_tld_file(@tmp_dir, "test")
    assert_equal "test", read_tld_from_dir(@tmp_dir)
    assert_equal [ "test" ], Portless::Daemon.read_tlds(@tmp_dir)
  end

  it "writes and reads multiple TLDs" do
    Portless::Daemon.write_tlds(@tmp_dir, %w[localhost test])
    assert_equal "localhost", read_tld_from_dir(@tmp_dir)
    assert_equal %w[localhost test], Portless::Daemon.read_tlds(@tmp_dir)
    assert_equal "localhost", File.read(File.join(@tmp_dir, "proxy.tld"))
  end

  it "removes the file when writing the default TLD" do
    write_tld_file(@tmp_dir, "test")
    assert_equal true, File.exist?(File.join(@tmp_dir, "proxy.tld"))

    write_tld_file(@tmp_dir, Portless::Utils::DEFAULT_TLD)
    assert_equal false, File.exist?(File.join(@tmp_dir, "proxy.tld"))
    assert_equal false, File.exist?(File.join(@tmp_dir, "proxy.tlds"))
    assert_equal Portless::Utils::DEFAULT_TLD, read_tld_from_dir(@tmp_dir)
  end

  it "handles removing the default TLD file when it does not exist" do
    write_tld_file(@tmp_dir, Portless::Utils::DEFAULT_TLD)
    assert_equal Portless::Utils::DEFAULT_TLD, read_tld_from_dir(@tmp_dir)
  end

  it "skips invalid persisted entries instead of resetting the whole list" do
    too_long = "a" * 70
    File.write(File.join(@tmp_dir, "proxy.tlds"), JSON.generate([ "test", too_long, "internal" ]))
    tlds = nil
    _, warned = capture_io { tlds = Portless::Daemon.read_tlds(@tmp_dir) }
    assert_equal %w[test internal], tlds
    refute_empty warned
  end
end

describe "getRiskyTldReason" do
  include CliUtilsSupport

  it "matches exact risky TLDs" do
    assert_match(/HSTS/, Portless::Utils.risky_tld_reason("dev"))
    assert_match(/HSTS/, Portless::Utils.risky_tld_reason("app"))
    assert_match(/public TLD/, Portless::Utils.risky_tld_reason("com"))
  end

  it "matches multi-segment TLDs under tree-wide risky suffixes" do
    assert_match(/HSTS/, Portless::Utils.risky_tld_reason("example.dev"))
    assert_match(/HSTS/, Portless::Utils.risky_tld_reason("myapp.app"))
    assert_match(/mDNS/, Portless::Utils.risky_tld_reason("foo.local"))
  end

  it "does not suffix-match ownership-class TLDs" do
    assert_nil Portless::Utils.risky_tld_reason("dev.example.com")
    assert_nil Portless::Utils.risky_tld_reason("internal.example.org")
  end

  it "returns undefined for safe TLDs" do
    assert_nil Portless::Utils.risky_tld_reason("test")
    assert_nil Portless::Utils.risky_tld_reason("dev.internal")
    assert_nil Portless::Utils.risky_tld_reason("devx")
  end
end

describe "validateTld" do
  include CliUtilsSupport

  it "returns null for valid TLDs" do
    assert_nil Portless::Utils.validate_tld("localhost")
    assert_nil Portless::Utils.validate_tld("test")
    assert_nil Portless::Utils.validate_tld("internal")
  end

  it "rejects empty string" do
    assert_match(/cannot be empty/, Portless::Utils.validate_tld(""))
  end

  it "rejects TLDs with invalid characters" do
    assert_match(/must contain only/, Portless::Utils.validate_tld("MY_TLD"))
    assert_match(/must contain only/, Portless::Utils.validate_tld("tld!"))
    assert_match(/must contain only/, Portless::Utils.validate_tld("my tld"))
  end

  it "accepts multi-segment TLDs" do
    assert_nil Portless::Utils.validate_tld("dev.example.com")
    assert_nil Portless::Utils.validate_tld("local.example.dev")
    assert_nil Portless::Utils.validate_tld("a.b.c.d.e")
  end

  it "accepts hyphens inside labels" do
    assert_nil Portless::Utils.validate_tld("my-tld")
    assert_nil Portless::Utils.validate_tld("dev.my-network.com")
  end

  it "rejects empty labels" do
    assert_match(/labels cannot be empty/, Portless::Utils.validate_tld(".example.com"))
    assert_match(/labels cannot be empty/, Portless::Utils.validate_tld("example.com."))
    assert_match(/labels cannot be empty/, Portless::Utils.validate_tld("example..com"))
  end

  it "rejects hyphens at label edges" do
    assert_match(/must contain only/, Portless::Utils.validate_tld("-bad.example.com"))
    assert_match(/must contain only/, Portless::Utils.validate_tld("bad-.example.com"))
  end

  it "rejects labels over 63 characters" do
    assert_match(/63-character/, Portless::Utils.validate_tld("#{'a' * 64}.example.com"))
  end

  it "rejects TLDs over 253 characters" do
    label = "a" * 63
    long = [ label, label, label, label, "example" ].join(".")
    assert_match(/253-character/, Portless::Utils.validate_tld(long))
  end

  it "allows public TLDs (they produce warnings elsewhere)" do
    %w[com org net io app].each do |tld|
      assert_nil Portless::Utils.validate_tld(tld)
      assert_equal true, Portless::Utils::RISKY_TLDS.key?(tld)
    end
  end

  it "allows risky TLDs (they produce warnings elsewhere)" do
    %w[local dev].each do |tld|
      assert_nil Portless::Utils.validate_tld(tld)
      assert_equal true, Portless::Utils::RISKY_TLDS.key?(tld)
    end
  end
end

describe "readPersistedProxyState" do
  include CliUtilsSupport

  before do
    @tmp_dir = Dir.mktmpdir("portless-persist-test-")
    @prev_state_dir = ENV.fetch("PORTLESS_STATE_DIR", nil)
    ENV["PORTLESS_STATE_DIR"] = @tmp_dir
  end

  after do
    FileUtils.rm_rf(@tmp_dir)
    @prev_state_dir.nil? ? ENV.delete("PORTLESS_STATE_DIR") : ENV["PORTLESS_STATE_DIR"] = @prev_state_dir
  end

  it "returns null when no state files exist" do
    assert_nil Portless::Daemon.read_persisted_state
  end

  it "reads port from persisted state" do
    File.write(File.join(@tmp_dir, "proxy.port"), "1355")
    state = Portless::Daemon.read_persisted_state
    refute_nil state
    assert_equal 1355, state[:port]
  end

  it "reads TLS marker from persisted state" do
    File.write(File.join(@tmp_dir, "proxy.port"), "443")
    Portless::Daemon.write_tls_marker(@tmp_dir, true)
    state = Portless::Daemon.read_persisted_state
    refute_nil state
    assert_equal true, state[:tls]
  end

  it "reads TLD from persisted state" do
    File.write(File.join(@tmp_dir, "proxy.port"), "1355")
    Portless::Daemon.write_tlds(@tmp_dir, [ "test" ])
    state = Portless::Daemon.read_persisted_state
    refute_nil state
    assert_equal "test", state[:tld]
    assert_equal [ "test" ], state[:tlds]
  end

  it "reads TLD list from persisted state" do
    File.write(File.join(@tmp_dir, "proxy.port"), "1355")
    Portless::Daemon.write_tlds(@tmp_dir, %w[localhost test])
    state = Portless::Daemon.read_persisted_state
    refute_nil state
    assert_equal "localhost", state[:tld]
    assert_equal %w[localhost test], state[:tlds]
  end

  it "reads LAN mode from persisted state" do
    File.write(File.join(@tmp_dir, "proxy.port"), "1355")
    Portless::Daemon.write_lan_marker(@tmp_dir, "192.168.1.10")
    state = Portless::Daemon.read_persisted_state
    refute_nil state
    assert_equal true, state[:lan_mode]
  end

  it "returns full previous config for a custom proxy setup" do
    File.write(File.join(@tmp_dir, "proxy.port"), "1355")
    Portless::Daemon.write_tls_marker(@tmp_dir, true)
    Portless::Daemon.write_tlds(@tmp_dir, [ "local" ])
    Portless::Daemon.write_lan_marker(@tmp_dir, "192.168.1.42")
    state = Portless::Daemon.read_persisted_state
    assert_equal({ port: 1355, tls: true, tld: "local", tlds: [ "local" ], lan_mode: true, unprivileged: false },
                 state)
  end

  it "does not infer LAN mode from a custom local TLD" do
    File.write(File.join(@tmp_dir, "proxy.port"), "1355")
    File.write(File.join(@tmp_dir, "proxy.tld"), "local")
    state = Portless::Daemon.read_persisted_state
    assert_equal [ "local" ], state[:tlds]
    assert_equal false, state[:lan_mode]
  end
end

# Issue #364: the automatic sync ignored its result, so an unprivileged run
# registered a route, skipped the hosts block and said nothing. The sync runs in
# the detached daemon whose stdio goes to proxy.log, so the answer has to cross a
# process boundary. It crosses on the request that asked for it, which is what
# lets the outcome carry no timestamp, no owner and no schema version: a response
# cannot be stale, cannot belong to another caller, and cannot be left behind by
# a previous daemon.
describe "reportHostsSync" do
  include CliUtilsSupport

  let(:warnings) { [] }
  let(:on_warn) { ->(m) { warnings << m } }
  let(:acted) { ->(*) { :acted } }
  let(:mute) { ->(*) { :mute } }
  let(:absent) { ->(*) { :absent } }
  let(:disabled) { ->(*) { :disabled } }

  def report_hosts_sync(hostnames, port, tls, lan_mode, on_warn, trigger, resolves = nil, ceiling_ms = nil,
                        read_managed = nil)
    opts = { trigger: trigger }
    opts[:resolves] = resolves if resolves
    opts[:ceiling] = ceiling_ms / 1000.0 if ceiling_ms
    opts[:read_managed] = read_managed if read_managed
    Portless::Daemon.report_hosts_sync(hostnames, port, tls, lan_mode, **opts, &on_warn)
  end

  it "says nothing when the hostname already resolves" do
    report_hosts_sync([ "a.localhost" ], 1, false, false, on_warn, acted, ->(_) { true })
    assert_equal [], warnings
  end

  it "does not warn when the system resolver selects IPv6 loopback" do
    report_hosts_sync([ "::1" ], 1, false, false, on_warn, acted)
    assert_equal [], warnings
  end

  it "warns when the system resolver selects non-loopback IPv6" do
    report_hosts_sync([ "2001:db8::1" ], 1, false, false, on_warn, acted)
    assert_equal [ "2001:db8::1 will not resolve. Run: rb-portless hosts sync" ], warnings
  end

  it "warns naming only the hostnames that do not resolve" do
    report_hosts_sync(
      [ "good.test", "bad.test" ],
      1,
      false,
      false,
      on_warn,
      acted,
      ->(hostname) { hostname == "good.test" },
      50
    )
    assert_equal 1, warnings.length
    assert_includes warnings[0], "bad.test"
    refute_includes warnings[0], "good.test"
  end

  it "gives an older daemon its watcher window" do
    reads = 0
    report_hosts_sync(
      [ "a.test" ],
      1,
      false,
      false,
      on_warn,
      mute,
      ->(_) { true },
      2000,
      -> { (reads += 1) >= 3 ? [ "a.test" ] : [] }
    )
    assert_operator reads, :>, 1
    assert_equal [], warnings
  end

  it "warns at the ceiling when an older daemon never syncs" do
    started = monotonic_ms
    report_hosts_sync(
      [ "a.test" ],
      1,
      false,
      false,
      on_warn,
      mute,
      ->(_) { false },
      150,
      -> { [] }
    )
    assert_operator monotonic_ms - started, :>=, 150
    assert_equal 1, warnings.length
  end

  it "does not wait when no producer exists" do
    started = monotonic_ms
    report_hosts_sync([ "a.test" ], 1, false, false, on_warn, absent, ->(_) { false }, 3000)
    assert_operator monotonic_ms - started, :<, 200
    assert_equal 1, warnings.length
  end

  it "does not wait when hosts sync is disabled" do
    started = monotonic_ms
    report_hosts_sync([ "a.test" ], 1, false, false, on_warn, disabled, ->(_) { false }, 3000)
    assert_operator monotonic_ms - started, :<, 200
    assert_equal 1, warnings.length
  end

  it "checks custom .local names outside LAN mode" do
    asked = 0
    report_hosts_sync([ "app.local" ], 1, false, false, on_warn, acted, lambda { |_|
      asked += 1
      false
    })
    assert_equal 1, asked
    assert_equal 1, warnings.length
  end

  it "skips .local names in active LAN mode" do
    triggered = false
    report_hosts_sync([ "app.local" ], 1, false, true, on_warn, lambda { |*|
      triggered = true
      :acted
    })
    assert_equal false, triggered
    assert_equal [], warnings
  end
end

describe "triggerHostsSync" do
  include CliUtilsSupport

  it "reports absent when nothing is listening" do
    assert_equal :absent, Portless::Daemon.trigger_hosts_sync(19_899)
  end
end

describe "syncHostsWithWarning" do
  include CliUtilsSupport

  # This latch bounds the daemon's own proxy.log on repeated route reloads. It
  # never bounds what users are told: delivery is per request, so each
  # registering CLI gets its own answer even while this is latched.
  it "warns once and stays quiet while the sync keeps failing" do
    warns = 0
    fail_sync = ->(_) { false }
    latched = Portless::Daemon.sync_hosts_with_warning([ "a.localhost" ], false, -> { warns += 1 }, fail_sync)
    assert_equal 1, warns
    latched = Portless::Daemon.sync_hosts_with_warning([ "a.localhost" ], latched, -> { warns += 1 }, fail_sync)
    assert_equal 1, warns
    assert_equal true, latched
  end

  it "re-arms after a success so a later failure warns again" do
    warns = 0
    latched = Portless::Daemon.sync_hosts_with_warning(
      [ "a.localhost" ],
      true,
      -> { warns += 1 },
      ->(_) { true }
    )
    assert_equal false, latched
    Portless::Daemon.sync_hosts_with_warning(
      [ "a.localhost" ],
      latched,
      -> { warns += 1 },
      ->(_) { false }
    )
    assert_equal 1, warns
  end

  # The startup warm-up runs with no routes. If its failure spent the latch, the
  # first real route's failure would find it already gone and log nothing.
  it "does not let an empty warm-up sync consume the latch" do
    warns = 0
    latched = Portless::Daemon.sync_hosts_with_warning(
      [],
      false,
      -> { warns += 1 },
      ->(_) { false }
    )
    assert_equal 0, warns
    assert_equal false, latched
  end
end

describe "stopProcessGroup" do
  include CliUtilsSupport

  # A detached grandchild leads its own group and outlives its parent, like
  # an orphaned dev server.
  def spawn_unrelated_orphan
    script = <<~RUBY
      child = Process.spawn(RbConfig.ruby, "-e", "loop { sleep 1 }",
                            pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
      print child
    RUBY
    Integer(IO.popen([ RbConfig.ruby, "-rrbconfig", "-e", script ], &:read))
  end

  after do
    Process.kill("KILL", @orphan_pid) if @orphan_pid && process_alive?(@orphan_pid)
    @orphan_pid = nil
  end

  it "does not signal a group whose recorded leader start time was not recorded or differs" do
    @orphan_pid = spawn_unrelated_orphan

    stop = Portless::ProcessGroup.stop_process_group(@orphan_pid, [], [], "KILL")
    assert_equal [ "unverified", false, nil ], [ stop.state, stop.signaled, stop.survivor ]
    stop = Portless::ProcessGroup.stop_process_group(@orphan_pid, [ "Thu Jan  1 00:00:00 1970" ], [], "KILL")
    assert_equal [ "unverified", false, nil ], [ stop.state, stop.signaled, stop.survivor ]
    assert_equal true, process_alive?(@orphan_pid)
  end

  it "reports a group stopped only after every member exits" do
    @orphan_pid = spawn_unrelated_orphan
    start_time = Portless::PortOwner.start_time(@orphan_pid)
    assert start_time

    stop = Portless::ProcessGroup.stop_process_group(@orphan_pid, [ start_time ], [], "KILL")
    assert_equal [ "stopped", true, nil ], [ stop.state, stop.signaled, stop.survivor ]
    assert_equal false, process_alive?(@orphan_pid)
  end

  it "signals a group that only one of its recorded identities matches" do
    @orphan_pid = spawn_unrelated_orphan
    start_time = Portless::PortOwner.start_time(@orphan_pid)
    assert start_time

    stop = Portless::ProcessGroup.stop_process_group(
      @orphan_pid,
      [ "Thu Jan  1 00:00:00 1970", nil, start_time ],
      [],
      "KILL"
    )
    assert_equal [ "stopped", true, nil ], [ stop.state, stop.signaled, stop.survivor ]
    assert_equal false, process_alive?(@orphan_pid)
  end

  it "reports a leader that ignores the signal and names a surviving member" do
    ready = File.join(Dir.mktmpdir("portless-group-"), "ready")
    leader_script = <<~'RUBY'
      ready = ARGV[0]
      child = Process.spawn(RbConfig.ruby, "-e",
                            'trap("TERM") {}; File.write(ARGV[0], "ready"); loop { sleep 1 }', ready,
                            in: File::NULL, out: File::NULL, err: File::NULL)
      trap("TERM") {}
      sleep 0.02 until File.exist?(ready)
      $stdout.puts child
      $stdout.flush
      loop { sleep 1 }
    RUBY
    reader, writer = IO.pipe
    leader = Process.spawn(RbConfig.ruby, "-rrbconfig", "-e", leader_script, ready,
                           pgroup: true, in: File::NULL, out: writer, err: File::NULL)
    writer.close
    @orphan_pid = leader
    child_pid = Integer(reader.gets)
    start_time = Portless::PortOwner.start_time(@orphan_pid)
    assert start_time

    begin
      stop = Portless::ProcessGroup.stop_process_group(@orphan_pid, [ start_time ], [], "TERM", timeout: 0.5)
      assert_equal [ "survived", true ], [ stop.state, stop.signaled ]
      refute_nil stop.survivor
      assert_equal child_pid, stop.survivor[:pid]
      assert_equal true, process_alive?(child_pid)
    ensure
      Process.kill("KILL", -@orphan_pid)
      Process.wait(leader)
      reader.close
      FileUtils.rm_rf(File.dirname(ready))
    end
  end
end

describe "canBindProxyPort" do
  include CliUtilsSupport

  it "returns true for a free unprivileged port" do
    port = Portless::FreePort.find
    assert_equal true, Portless::Privilege.can_bind_proxy_port?(port, Portless::Privilege.bind_targets(false))
  end

  it "leaves EADDRINUSE to the real listen" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    begin
      assert_equal true, Portless::Privilege.can_bind_proxy_port?(port, [ { host: "127.0.0.1" } ])
    ensure
      server.close
    end
  end

  it "reports EACCES for a privileged loopback bind and allows the wildcard on macOS" do
    skip "macOS non-root only" unless Portless::Constants::MACOS && Process.uid != 0
    # Probe-binds port 81, which the test-suite safety rules forbid by default.
    skip "set PORTLESS_TEST_PRIVILEGED_BIND=1 to probe-bind port 81" unless ENV["PORTLESS_TEST_PRIVILEGED_BIND"] == "1"

    assert_equal false, Portless::Privilege.can_bind_proxy_port?(81, Portless::Privilege.bind_targets(false))
    assert_equal true, Portless::Privilege.can_bind_proxy_port?(81, Portless::Privilege.bind_targets(true))
  end
end

describe "canBindWithoutRoot" do
  include CliUtilsSupport

  let(:unreadable) { -> { raise Errno::ENOENT } }

  def can_bind_without_root(port, platform, read)
    Portless::Privilege.can_bind_without_root(port, platform: platform, read_unprivileged_port_start: read)
  end

  it "allows any port at or above the privileged threshold on every platform" do
    assert_equal({ ok: true }, can_bind_without_root(Portless::Constants::PRIVILEGED_PORT_THRESHOLD, "freebsd", unreadable))
    assert_equal({ ok: true }, can_bind_without_root(8080, "linux", unreadable))
  end

  it "allows a privileged port on macOS and Windows without consulting a sysctl" do
    assert_equal({ ok: true }, can_bind_without_root(80, "darwin", unreadable))
    assert_equal({ ok: true }, can_bind_without_root(443, "win32", unreadable))
  end

  it "follows net.ipv4.ip_unprivileged_port_start on Linux" do
    assert_equal({ ok: true }, can_bind_without_root(80, "linux", -> { "80\n" }))
    assert_equal({ ok: true }, can_bind_without_root(443, "linux", -> { "80\n" }))
    assert_equal({ ok: false, reason: "Port 79 is below net.ipv4.ip_unprivileged_port_start (80)." },
                 can_bind_without_root(79, "linux", -> { "80\n" }))
    assert_equal false, can_bind_without_root(80, "linux", -> { "1024\n" })[:ok]
  end

  it "reports an unreadable sysctl instead of guessing" do
    assert_equal({ ok: false, reason: "Could not read net.ipv4.ip_unprivileged_port_start." },
                 can_bind_without_root(80, "linux", unreadable))
  end

  it "refuses a privileged port on platforms it does not know" do
    assert_equal false, can_bind_without_root(80, "freebsd", unreadable)[:ok]
  end
end

describe "isUnprivilegedEnvEnabled" do
  include CliUtilsSupport

  it "is on for PORTLESS_UNPRIVILEGED=%s" do
    %w[1 true].each do |value|
      with_env("PORTLESS_UNPRIVILEGED" => value) do
        assert_equal true, Portless::Utils.unprivileged_env_enabled?
      end
    end
  end

  it "is off for PORTLESS_UNPRIVILEGED=%s" do
    [ "0", "false", "yes", "" ].each do |value|
      with_env("PORTLESS_UNPRIVILEGED" => value) do
        assert_equal false, Portless::Utils.unprivileged_env_enabled?
      end
    end
  end

  it "is off when unset" do
    with_env("PORTLESS_UNPRIVILEGED" => nil) do
      assert_equal false, Portless::Utils.unprivileged_env_enabled?
    end
  end
end

describe "readUnprivilegedMarker / writeUnprivilegedMarker" do
  include CliUtilsSupport

  before { @tmp_dir = Dir.mktmpdir("portless-unpriv-marker-") }
  after { FileUtils.rm_rf(@tmp_dir) }

  it "is absent by default" do
    assert_equal false, Portless::Daemon.read_unprivileged_marker(@tmp_dir)
  end

  it "round-trips through write and remove" do
    Portless::Daemon.write_unprivileged_marker(@tmp_dir, true)
    assert_equal true, Portless::Daemon.read_unprivileged_marker(@tmp_dir)
    Portless::Daemon.write_unprivileged_marker(@tmp_dir, false)
    assert_equal false, Portless::Daemon.read_unprivileged_marker(@tmp_dir)
  end

  it "is part of the persisted proxy state" do
    with_env("PORTLESS_STATE_DIR" => @tmp_dir) do
      File.write(File.join(@tmp_dir, "proxy.port"), "8080")
      assert_equal false, Portless::Daemon.read_persisted_state&.dig(:unprivileged)
      Portless::Daemon.write_unprivileged_marker(@tmp_dir, true)
      assert_equal true, Portless::Daemon.read_persisted_state&.dig(:unprivileged)
    end
  end
end
