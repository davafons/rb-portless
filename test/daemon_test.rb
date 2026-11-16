# frozen_string_literal: true

require "test_helper"
require "socket"
require "rbconfig"

# Daemon config/state helpers and `proxy stop` safety (ported from
# cli-utils.test.ts / cli.test.ts cases for these functions).
class DaemonTest < Minitest::Test
  D = Portless::Daemon

  def setup
    @dir = Dir.mktmpdir("rb-portless-daemon")
    File.chmod(0o755, @dir)
    @env = ENV.to_h
    ENV["PORTLESS_STATE_DIR"] = @dir
    %w[PORTLESS_TLD PORTLESS_PORT PORTLESS_HTTPS PORTLESS_LAN PORTLESS_LAN_IP PORTLESS_WILDCARD
       PORTLESS_UNPRIVILEGED PORTLESS_SYNC_HOSTS].each { |k| ENV.delete(k) }
  end

  def teardown
    ENV.replace(@env)
    FileUtils.rm_rf(@dir)
  end

  def explicit(**over)
    { use_https: false, custom_cert: false, lan_mode: false, lan_ip: false, tlds: false, use_wildcard: false,
      unprivileged: false }.merge(over)
  end

  def resolve(**over)
    D.resolve_config(**{ persisted_lan_mode: false, persisted_unprivileged: false, explicit: explicit,
                         default_tlds: [ "localhost" ], use_https: true, custom_cert_path: nil,
                         custom_key_path: nil, lan_mode: false, lan_ip: nil, tlds: [ "localhost" ],
                         use_wildcard: false, unprivileged: false }.merge(over))
  end

  # ── TLDs ──────────────────────────────────────────────────────────────
  def test_validate_tld
    assert_nil Portless::Utils.validate_tld("test")
    assert_nil Portless::Utils.validate_tld("dev.example.com")
    assert_equal "TLD cannot be empty", Portless::Utils.validate_tld("")
    assert_match(/labels cannot be empty/, Portless::Utils.validate_tld("a..b"))
    assert_match(/lowercase letters/, Portless::Utils.validate_tld("-bad"))
    assert_match(/63-character/, Portless::Utils.validate_tld("a" * 64))
    assert_match(/253-character/, Portless::Utils.validate_tld("a." * 127 + "ab"))
  end

  def test_parse_tld_list_dedupes_and_prefixes_source
    assert_equal %w[test localhost], Portless::Utils.parse_tld_list(" Test, localhost ,test")
    assert_empty Portless::Utils.parse_tld_list("  ")
    err = assert_raises(Portless::Error) { Portless::Utils.parse_tld_list("ok,b@d", "PORTLESS_TLD") }
    assert_match(/\APORTLESS_TLD: Invalid TLD "b@d"/, err.message)
  end

  def test_default_tlds_from_env
    assert_equal [ "localhost" ], Portless::Utils.default_tlds
    ENV["PORTLESS_TLD"] = "test,dev.example.com"
    assert_equal %w[test dev.example.com], Portless::Utils.default_tlds
    ENV["PORTLESS_TLD"] = "Bad_"
    assert_raises(Portless::Error) { Portless::Utils.default_tlds }
  end

  def test_risky_tld_reason
    assert_match(/mDNS/, Portless::Utils.risky_tld_reason("local"))
    assert_match(/HSTS/, Portless::Utils.risky_tld_reason("example.dev"))
    assert_match(/public TLD/, Portless::Utils.risky_tld_reason("com"))
    assert_nil Portless::Utils.risky_tld_reason("dev.example.com") # ownership-class risk is bare-only
    assert_nil Portless::Utils.risky_tld_reason("test")
  end

  def test_tlds_file_round_trip_and_legacy_fallback
    assert_equal [ "localhost" ], D.read_tlds(@dir)
    D.write_tlds(@dir, %w[test localhost test])
    assert_equal "test\nlocalhost\n", File.read(File.join(@dir, "proxy.tlds"))
    assert_equal "test", File.read(File.join(@dir, "proxy.tld"))
    assert_equal %w[test localhost], D.read_tlds(@dir)
    D.write_tlds(@dir, [ "localhost" ])
    refute File.exist?(File.join(@dir, "proxy.tlds"))
    File.write(File.join(@dir, "proxy.tld"), "legacy")
    assert_equal [ "legacy" ], D.read_tlds(@dir)
    File.write(File.join(@dir, "proxy.tlds"), '["json", "B@D"]')
    _, err = capture_io { assert_equal [ "json" ], D.read_tlds(@dir) }
    assert_match(/ignoring invalid TLD entry/, err)
  end

# The daemon may run as root against a user-owned state dir: a symlink at a
# marker path must be replaced, never followed.
def test_marker_writes_do_not_follow_symlinks
  Dir.mktmpdir do |dir|
    victim = File.join(dir, "victim")
    File.write(victim, "untouched")
    marker = File.join(dir, "proxy.port")
    File.symlink(victim, marker)

    Portless::Daemon.write_marker_file(marker, "1355")

    assert_equal "untouched", File.read(victim)
    refute File.symlink?(marker)
    assert_equal "1355", File.read(marker)
    assert_empty Dir.glob(File.join(dir, ".*.tmp"))
  end
end

  def test_markers
    D.write_tls_marker(@dir, true)
    assert D.read_tls_marker(@dir)
    D.write_tls_marker(@dir, false)
    refute D.read_tls_marker(@dir)
    D.write_lan_marker(@dir, "192.168.1.5")
    assert_equal "192.168.1.5", D.read_lan_marker(@dir)
    D.write_lan_marker(@dir, nil)
    assert_nil D.read_lan_marker(@dir)
    D.write_unprivileged_marker(@dir, true)
    assert D.read_unprivileged_marker(@dir)
  end

  def test_reset_proxy_markers_forgets_runtime_settings
    %w[proxy.start proxy.start.tmp].each { |f| File.write(File.join(@dir, f), "x") }
    D.write_tls_marker(@dir, true)
    D.write_custom_cert_marker(@dir, true)
    D.write_tlds(@dir, [ "test" ])
    D.write_lan_marker(@dir, "10.0.0.2")
    D.write_unprivileged_marker(@dir, true)
    D.reset_proxy_markers(@dir)
    %w[proxy.start proxy.start.tmp proxy.tls proxy.custom-cert proxy.tlds proxy.tld proxy.lan].each do |f|
      refute File.exist?(File.join(@dir, f)), f
    end
    assert D.read_unprivileged_marker(@dir), "unprivileged mode persists across stops"
  end

  # ── ports ─────────────────────────────────────────────────────────────
  def test_default_port
    assert_equal 443, D.default_port(true)
    assert_equal 80, D.default_port(false)
    assert_equal 1355, D.default_port
    ENV["PORTLESS_PORT"] = "8443"
    assert_equal 8443, D.default_port(false)
    ENV["PORTLESS_PORT"] = "nope"
    assert_equal 443, D.default_port(true)
  end

  # ── buildProxyStartConfig ────────────────────────────────────────────
  def test_build_start_config
    assert_equal [ "--https" ], D.build_start_config(use_https: true, lan_mode: false)[:args]
    assert_equal %w[--foreground --port 1355 --no-tls --tld test --tld localhost --wildcard --unprivileged --skip-trust],
                 D.build_start_config(use_https: false, lan_mode: false, tlds: %w[test localhost], use_wildcard: true,
                                      unprivileged: true, foreground: true, include_port: true, proxy_port: 1355,
                                      skip_trust: true)[:args]
    lan = D.build_start_config(use_https: true, lan_mode: true, tlds: [ "test" ], lan_ip: "10.0.0.2")
    assert_equal %w[--https --lan --lan-ip-auto 10.0.0.2], lan[:args]
    assert_equal [ "local" ], lan[:effective_tlds]
    assert_equal %w[--cert c --key k --lan --ip 10.0.0.3],
                 D.build_start_config(use_https: true, custom_cert_path: "c", custom_key_path: "k", lan_mode: true,
                                      lan_ip: "10.0.0.3", lan_ip_explicit: true)[:args]
  end

  # ── resolveProxyConfig ───────────────────────────────────────────────
  def test_resolve_config_defaults
    c = resolve
    assert c.use_https
    assert_equal [ "localhost" ], c.tlds
    refute c.lan_mode
  end

  def test_resolve_config_unprivileged_serves_http_unless_https_explicit
    refute resolve(explicit: explicit(unprivileged: true), unprivileged: true).use_https
    assert resolve(explicit: explicit(unprivileged: true, use_https: true), unprivileged: true).use_https
    refute resolve(persisted_unprivileged: true).use_https, "persisted unprivileged mode carries over"
  end

  def test_resolve_config_lan_forces_local_and_keeps_explicit_ip
    c = resolve(persisted_lan_mode: true, explicit: explicit(tlds: true), tlds: [ "test" ])
    assert_equal [ "local" ], c.tlds
    c = resolve(explicit: explicit(lan_ip: true), lan_ip: "10.1.1.1")
    assert c.lan_mode
    assert c.lan_ip_explicit
    assert_equal "10.1.1.1", c.lan_ip
    c = resolve(persisted_lan_mode: true, explicit: explicit(lan_mode: true), lan_mode: false)
    refute c.lan_mode
    assert_equal [ "localhost" ], c.tlds
  end

  def test_resolve_config_custom_cert_implies_https
    c = resolve(use_https: false, explicit: explicit(custom_cert: true), custom_cert_path: "c", custom_key_path: "k")
    assert c.use_https
    assert_equal "c", c.custom_cert_path
  end

  def test_config_mismatch_messages
    desired = resolve(explicit: explicit(use_https: true, tlds: true), use_https: false, tlds: [ "test" ])
    actual = resolve
    messages = D.proxy_config_mismatch_messages(desired, actual, explicit(use_https: true, tlds: true))
    assert_equal [ "requested HTTP, but the running proxy is using HTTPS",
                   "requested .test, but the running proxy is using .localhost" ], messages
    assert_empty D.proxy_config_mismatch_messages(desired, actual, explicit)
  end

  def test_format_proxy_start_command
    assert_equal "sudo rb-portless proxy start --https", D.format_proxy_start_command(443, resolve)
    assert_equal "rb-portless proxy start --port 1355 --https", D.format_proxy_start_command(1355, resolve)
    unpriv = resolve(explicit: explicit(unprivileged: true), unprivileged: true)
    assert_equal "rb-portless proxy start --no-tls --unprivileged", D.format_proxy_start_command(80, unpriv)
  end

  def test_print_config_mismatch_exits_1_with_recovery
    _, err = capture_io do
      assert_raises(SystemExit) { D.print_proxy_config_mismatch(1355, resolve, [ "requested HTTPS" ]) }
    end
    assert_match(/already running on port 1355 with a different config/, err)
    assert_match(/rb-portless proxy stop -p 1355/, err)
  end

  # ── resolveProxyStart (auto-start reuses persisted settings) ─────────
  def test_resolve_start_reuses_persisted_state
    File.write(File.join(@dir, "proxy.port"), "1355")
    D.write_tlds(@dir, [ "test" ])
    desired = D.resolve_desired_state(false)
    start = D.resolve_start(desired)
    refute start[:start_config].use_https
    assert_equal [ "test" ], start[:start_config].tlds
    assert_equal 1355, start[:start_port]

    ENV["PORTLESS_HTTPS"] = "1"
    ENV["PORTLESS_PORT"] = "1355"
    start = D.resolve_start(D.resolve_desired_state(false))
    assert start[:start_config].use_https, "explicit env wins over persisted state"
    assert_nil start[:start_port]
  end

  def test_resolve_start_without_persisted_state
    start = D.resolve_start(D.resolve_desired_state(false))
    assert start[:start_config].use_https
    assert_nil start[:start_port]
  end

  # ── health / discovery ───────────────────────────────────────────────
  def test_discover_state_reads_markers_with_state_dir_override
    with_fake_proxy(header: true) do |port|
      File.write(File.join(@dir, "proxy.port"), port.to_s)
      D.write_tls_marker(@dir, true)
      D.write_tlds(@dir, %w[test localhost])
      D.write_lan_marker(@dir, "10.0.0.9")
      state = D.discover_state
      assert_equal port, state[:port]
      assert state[:tls]
      assert_equal %w[test localhost], state[:tlds]
      assert_equal "10.0.0.9", state[:lan_ip]
      assert state[:lan_mode]
    end
    state = D.discover_state
    assert_nil state[:lan_ip], "LAN IP only reported while the proxy is up"
  end

  # ── proxy stop ───────────────────────────────────────────────────────
  def test_stop_when_nothing_recorded
    out, = capture_io { assert D.stop_proxy(@dir, free_port) }
    assert_match(/Proxy is not running/, out)
  end

  def test_stop_cleans_up_dead_pid
    pid = spawn_and_reap
    File.write(File.join(@dir, "proxy.pid"), pid.to_s)
    File.write(File.join(@dir, "proxy.port"), "1355")
    D.write_tls_marker(@dir, true)
    out, = capture_io { assert D.stop_proxy(@dir, 1355) }
    assert_match(/no longer running/, out)
    refute File.exist?(File.join(@dir, "proxy.pid"))
    refute File.exist?(File.join(@dir, "proxy.tls"))
  end

  def test_stop_removes_corrupt_pid_file
    File.write(File.join(@dir, "proxy.pid"), "garbage")
    _, err = capture_io { assert D.stop_proxy(@dir, 1355) }
    assert_match(/Corrupted PID file/, err)
  end

  def test_stop_refuses_unsafe_state_dir
    File.chmod(0o777, @dir)
    File.write(File.join(@dir, "proxy.pid"), Process.pid.to_s)
    _, err = capture_io { refute D.stop_proxy(@dir, 1355) }
    assert_match(/Cannot stop the proxy recorded in .*other users can write to it/, err)
    assert_match(/Nothing was signaled/, err)
  ensure
    File.chmod(0o755, @dir)
  end

  def test_stop_never_signals_a_recycled_pid
    sleeper = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    File.write(File.join(@dir, "proxy.pid"), sleeper.to_s)
    File.write(File.join(@dir, "proxy.start"), "Mon Jan  1 00:00:00 2001")
    port = free_port
    File.write(File.join(@dir, "proxy.port"), port.to_s)
    out, = capture_io { assert D.stop_proxy(@dir, port) }
    assert_match(/is not a proxy listening on port #{port}/, out)
    assert Portless::PortOwner.alive?(sleeper), "the unrelated process must survive"
    refute File.exist?(File.join(@dir, "proxy.pid"))
  ensure
    Process.kill("KILL", sleeper) rescue nil # rubocop:disable Style/RescueModifier
    Process.wait(sleeper) rescue nil # rubocop:disable Style/RescueModifier
  end

  def test_stop_reports_mismatched_pid_and_keeps_state
    sleeper = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    with_fake_proxy(header: true) do |port|
      File.write(File.join(@dir, "proxy.pid"), sleeper.to_s)
      File.write(File.join(@dir, "proxy.start"), "Mon Jan  1 00:00:00 2001")
      _, err = capture_io { refute D.stop_proxy(@dir, port) }
      assert_match(/PID #{sleeper} .* is not the proxy answering on port #{port}/, err)
      assert File.exist?(File.join(@dir, "proxy.pid"))
    end
  ensure
    Process.kill("KILL", sleeper) rescue nil # rubocop:disable Style/RescueModifier
    Process.wait(sleeper) rescue nil # rubocop:disable Style/RescueModifier
  end

  def test_stop_terminates_the_verified_proxy
    port = free_port
    pid = spawn_fake_proxy_process(port)
    File.write(File.join(@dir, "proxy.pid"), pid.to_s)
    File.write(File.join(@dir, "proxy.port"), port.to_s)
    start = Portless::PortOwner.start_time(pid)
    File.write(File.join(@dir, "proxy.start"), start) if start
    out, = capture_io { assert D.stop(port: port) }
    assert_match(/Proxy stopped/, out)
    refute File.exist?(File.join(@dir, "proxy.pid"))
    refute File.exist?(File.join(@dir, "proxy.port"))
  ensure
    Process.kill("KILL", pid) rescue nil # rubocop:disable Style/RescueModifier
  end

  def test_stop_with_a_missing_state_dir_reports_not_running
    missing = File.join(@dir, "missing")
    out, = capture_io { assert D.stop_proxy(missing, free_port) }
    assert_match(/Proxy is not running/, out)
  end

  # ── proxy start argument validation ──────────────────────────────────
  def test_proxy_start_usage_errors_are_caught_by_the_cli
    _, err = capture_io { assert_equal 2, Portless::CLI.new(%w[proxy start --cert a.pem]).main }
    assert_match(/--cert and --key must be used together/, err)
    _, err = capture_io { assert_equal 2, Portless::CLI.new(%w[proxy start -p 0]).main }
    assert_match(/Port must be between 1 and 65535/, err)
  end

  def test_start_refuses_sync_hosts_with_unprivileged
    ENV["PORTLESS_SYNC_HOSTS"] = "1"
    _, err = capture_io { assert_raises(SystemExit) { D.start(port: free_port, unprivileged: true) } }
    assert_match(/PORTLESS_SYNC_HOSTS=1 cannot be combined with unprivileged mode/, err)
  end

  def test_start_reports_already_running_with_restart_hint
    with_fake_proxy(header: true) do |port|
      out, = capture_io { assert D.start(port: port) }
      assert_match(/Proxy is already running on port #{port}\./, out)
      assert_match(/To restart: rb-portless proxy stop -p #{port} && rb-portless proxy start -p #{port}/, out)
    end
  end

  def test_start_elevated_reports_the_sudo_failure_like_spawn_sync
    config = resolve
    store = Portless::RouteStore.new(@dir)
    { Portless::Privilege::SpawnResult.new(nil, "spawnSync sudo ETIMEDOUT") => "spawnSync sudo ETIMEDOUT",
      Portless::Privilege::SpawnResult.new(signaled_status, nil) => "terminated by signal SIGTERM" }.each do |result, failure|
      _, err = capture_io do
        Portless::Privilege.stub(:sudo, result) do
          assert_raises(SystemExit) { D.start_elevated(store, 443, config, config, nil, false) }
        end
      end
      assert_includes err, "but sudo elevation failed: #{failure}."
    end
  end

  def test_spawn_daemon_lets_the_daemon_redetect_an_auto_lan_ip
    spawned = nil
    config = resolve(explicit: explicit(lan_mode: true), lan_mode: true)
    capture_io do
      Process.stub(:spawn, ->(*args, **) { spawned = args; 0 }) do
        Process.stub(:detach, nil) do
          D.stub(:wait_for_proxy, true) do
            D.spawn_daemon(Portless::RouteStore.new(@dir), @dir, 1355, config, "10.0.0.5")
          end
        end
      end
    end
    refute_kind_of Hash, spawned.first, "no PORTLESS_INTERNAL_LAN_IP for the child"
    refute_includes spawned, "10.0.0.5"
    assert_includes spawned, "--lan"
  end

  # ── hosts sync client ────────────────────────────────────────────────
  def test_sync_hosts_with_warning_latches
    calls = 0
    warn_once = -> { calls += 1 }
    warned = D.sync_hosts_with_warning([ "a.test" ], false, warn_once, ->(_) { false })
    warned = D.sync_hosts_with_warning([ "a.test" ], warned, warn_once, ->(_) { false })
    assert warned
    assert_equal 1, calls
    refute D.sync_hosts_with_warning([ "a.test" ], true, warn_once, ->(_) { true })
    assert_equal false, D.sync_hosts_with_warning([], false, warn_once, ->(_) { false })
  end

  def test_report_hosts_sync_warns_on_unresolved
    warnings = []
    D.report_hosts_sync(%w[a.test b.local], 1, false, true, trigger: ->(*) { :acted },
                                                            resolves: ->(h) { h != "a.test" }) { |m| warnings << m }
    assert_equal [ "a.test will not resolve. Run: rb-portless hosts sync" ], warnings
    warnings.clear
    D.report_hosts_sync(%w[x.local], 1, false, true, trigger: ->(*) { raise "not called" }) { |m| warnings << m }
    assert_empty warnings
  end

  def test_report_hosts_sync_waits_for_mute_proxy
    reads = 0
    warnings = []
    D.report_hosts_sync([ "a.test" ], 1, false, false, trigger: ->(*) { :mute }, resolves: ->(_) { true },
                                                       read_managed: lambda {
                                                         reads += 1
                                                         reads > 2 ? [ "a.test" ] : []
                                                       }, ceiling: 2) { |m| warnings << m }
    assert_equal 3, reads
    assert_empty warnings
  end

  def test_trigger_hosts_sync_verifies_proof_before_sending_token
    token = Portless::HostsSyncAuth.generate_token
    Portless::HostsSyncAuth.write_token(@dir, token)
    with_hosts_sync_server(token) { |port| assert_equal :acted, D.trigger_hosts_sync(port, false, @dir) }
    with_hosts_sync_server(Portless::HostsSyncAuth.generate_token) do |port|
      assert_equal :mute, D.trigger_hosts_sync(port, false, @dir), "a proxy that can't prove the token gets nothing"
    end
    assert_equal :absent, D.trigger_hosts_sync(free_port, false, @dir)
  end

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def signaled_status
    pid = Process.spawn(RbConfig.ruby, "-e", "Process.kill('TERM', Process.pid); sleep 5")
    Process.wait2(pid).last
  end

  def spawn_and_reap
    pid = Process.spawn(RbConfig.ruby, "-e", "exit 0")
    Process.wait(pid)
    pid
  end

  # Minimal HTTP server answering every request; optional X-Portless header.
  def with_fake_proxy(header:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        client.readpartial(4096) rescue nil # rubocop:disable Style/RescueModifier
        client.write("HTTP/1.1 200 OK\r\n#{header ? "X-Portless: 1\r\n" : ''}Content-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      rescue IOError, SystemCallError
        break
      end
    end
    yield port
  ensure
    server&.close
    thread&.kill
  end

  def spawn_fake_proxy_process(port)
    code = <<~RUBY
      require "socket"
      s = TCPServer.new("127.0.0.1", #{port})
      trap("TERM") { exit 0 }
      loop do
        c = s.accept
        c.readpartial(4096) rescue nil
        c.write("HTTP/1.1 200 OK\\r\\nX-Portless: 1\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n")
        c.close
      end
    RUBY
    pid = Process.spawn(RbConfig.ruby, "-e", code)
    Process.detach(pid)
    50.times do
      break if D.proxy_running?(port)

      sleep 0.05
    end
    pid
  end

  # Fake proxy implementing the hosts-sync challenge/proof + POST endpoint.
  def with_hosts_sync_server(token)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        request = client.readpartial(8192)
        challenge = request[/x-portless-hosts-sync-challenge: (\h+)/i, 1]
        if request.start_with?("POST #{Portless::Daemon::HOSTS_SYNC_PATH}")
          ok = request[/x-portless-hosts-sync-token: (\h+)/i, 1] == token
          client.write("HTTP/1.1 #{ok ? '204 No Content' : '403 Forbidden'}\r\nX-Portless: 1\r\nConnection: close\r\n\r\n")
        else
          proof = challenge && Portless::HostsSyncAuth.create_proof(token, challenge)
          client.write("HTTP/1.1 200 OK\r\nX-Portless: 1\r\n#{proof ? "x-portless-hosts-sync-proof: #{proof}\r\n" : ''}" \
                       "Content-Length: 0\r\nConnection: close\r\n\r\n")
        end
        client.close
      rescue IOError, SystemCallError
        break
      end
    end
    yield port
  ensure
    server&.close
    thread&.kill
  end
end
