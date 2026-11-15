# frozen_string_literal: true

require "test_helper"
require "rbconfig"

# Tunnel/Cloudflare (tunnel.test.ts) and Tailscale (tailscale.test.ts).
class ShareTest < Minitest::Test
  T = Portless::Tunnel
  C = Portless::Cloudflare
  TS = Portless::Share::Tailscale

  def ok(stdout = "") = { status: 0, stdout: stdout, stderr: "" }
  def fail_with(stderr) = { status: 1, stdout: "", stderr: stderr }

  # A spawner running a ruby script whose output we control.
  def script_spawner(code)
    lambda do |_args|
      reader, writer = IO.pipe
      pid = Process.spawn(RbConfig.ruby, "-e", code, out: writer, err: writer)
      writer.close
      [ pid, reader ]
    end
  end

  # ── ngrok ─────────────────────────────────────────────────────────────
  def test_ensure_ngrok_available
    seen = nil
    T.check!(:ngrok, ->(args) { seen = args; ok })
    assert_equal [ "version" ], seen
    err = assert_raises(Portless::Error) { T.check!(:ngrok, ->(_) { { error: Errno::ENOENT.new } }) }
    assert_match(/\Angrok CLI not found\. Install ngrok \(https:\/\/ngrok\.com\/download\)/, err.message)
    err = assert_raises(Portless::Error) { T.check!(:ngrok, ->(_) { fail_with("  bad\n  thing ") }) }
    assert_equal "Failed to check ngrok version: bad thing", err.message
  end

  def test_build_ngrok_args
    assert_equal [ "http", "--log=stdout", "--log-format=logfmt", "--host-header=rewrite", "http://127.0.0.1:4123" ],
                 T.build_ngrok_args(4123)
    assert_equal "--host-header=app.localhost", T.build_ngrok_args(4123, "app.localhost")[3]
  end

  def test_extract_ngrok_url
    assert_equal "https://abc.ngrok-free.app", T.extract_ngrok_url("Forwarding https://abc.ngrok-free.app -> http://x")
    assert_equal "https://abc.ngrok.app", T.extract_ngrok_url('lvl=info msg="started tunnel" url=https://abc.ngrok.app')
    assert_nil T.extract_ngrok_url("ERR see https://ngrok.com/docs/errors url=https://dashboard.ngrok.com/x")
  end

  def test_start_ngrok_resolves_url_and_notifies_exit
    exits = Queue.new
    handle = T.start_tunnel(T.ngrok, 4000, spawner: script_spawner(
      '$stdout.sync = true; puts "t=1 msg=\"started tunnel\" url=https://xyz.ngrok.app"; sleep 0.3'
    )) { |code, _sig| exits << code }
    assert_equal "https://xyz.ngrok.app", handle.url
    assert handle.pid
    assert_equal 0, exits.pop
  end

  def test_start_ngrok_auth_error
    err = assert_raises(Portless::Error) do
      T.start_tunnel(T.ngrok, 4000, spawner: script_spawner('puts "ERR_NGROK_4018 authentication failed"; exit 1'))
    end
    assert_match(/authentication is not configured.*\(exit 1\)\z/, err.message)
  end

  def test_start_ngrok_missing_binary
    err = assert_raises(Portless::Error) { T.start_tunnel(T.ngrok, 4000, spawner: ->(_) { raise Errno::ENOENT }) }
    assert_match(/ngrok CLI not found/, err.message)
  end

  def test_start_ngrok_timeout_kills_process
    pid = nil
    spawner = lambda do |args|
      r = script_spawner("sleep 30").call(args)
      pid = r.first
      r
    end
    err = assert_raises(Portless::Error) { T.start_tunnel(T.ngrok, 4000, timeout: 0.3, spawner: spawner) }
    assert_match(/Timed out waiting for ngrok/, err.message)
    sleep 0.2
    refute Portless::PortOwner.running?(pid)
  end

  def test_stop_recorded_tunnels
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    route = { ngrok_pid: pid, cloudflare_pid: nil }
    assert_empty T.stop_recorded(route, verify: true), "verify skips pids not running the tunnel binary"
    assert_equal [ "ngrok" ], T.stop_recorded(route).map { |t| t[:label] }
    Process.wait(pid)
  end

  def test_print_hint
    _, err = capture_io { T.print_hint(:ngrok, "Failed: authentication is not configured") }
    assert_match(/ngrok config add-authtoken <token>/, err)
    _, err = capture_io { T.print_hint(:cloudflare, "cloudflared CLI not found. Install") }
    assert_match(%r{Install cloudflared: https://developers.cloudflare.com/tunnel/downloads/}, err)
  end

  # ── cloudflare ────────────────────────────────────────────────────────
  def test_cloudflare_args
    assert_equal [ "tunnel", "--no-autoupdate", "--grace-period", "1s", "--config", "/s/cloudflared.yml", "--url",
                   "http://127.0.0.1:4100", "--http-host-header", "app.localhost" ],
                 C.build_args(4100, "app.localhost", "/s/cloudflared.yml")
  end

  def test_cloudflare_url_only_once_registered
    out = "INF |  https://fancy-words.trycloudflare.com  |"
    assert_nil C.extract_url(out)
    assert_equal "https://fancy-words.trycloudflare.com", C.extract_url("#{out}\nINF Registered tunnel connection")
    assert_nil C.extract_url("https://api.trycloudflare.com Registered tunnel connection")
  end

  def test_cloudflare_start_writes_empty_config
    Dir.mktmpdir do |dir|
      config = File.join(dir, "cloudflared.yml")
      handle = C.start(4100, config_path: config, host_header: "a.localhost", spawner: script_spawner(
        '$stdout.sync = true; puts "https://a-b.trycloudflare.com"; puts "Connection abc registered"; sleep 1'
      ))
      assert_equal "{}", File.read(config)
      assert_equal "https://a-b.trycloudflare.com", handle.url
      handle.stop
    end
  end

  def test_cloudflare_early_exit_reports_err_lines
    err = assert_raises(Portless::Error) do
      C.start(1, config_path: File.join(Dir.tmpdir, "cf-#{$$}.yml"),
                 spawner: script_spawner('puts "2024 ERR  failed   to dial"; exit 1'))
    end
    assert_equal "Failed to start Cloudflare tunnel: 2024 ERR failed to dial (exit 1)", err.message
    err = assert_raises(Portless::Error) do
      C.start(1, config_path: File.join(Dir.tmpdir, "cf-#{$$}.yml"), spawner: script_spawner("exit 2"))
    end
    assert_equal "Failed to start Cloudflare tunnel: cloudflared exited before connecting (exit 2)", err.message
  end

  # ── tailscale ─────────────────────────────────────────────────────────
  STATUS = { "Self" => { "DNSName" => "box.tail1.ts.net.", "Capabilities" => [ "https" ], "ID" => "n123" } }.freeze

  def runner_for(status: STATUS, serve: {}, register: ok)
    calls = []
    runner = lambda do |args|
      calls << args
      case args.first(2)
      when [ "version" ] then ok("1.70")
      when %w[status --json] then ok(JSON.generate(status))
      when %w[serve status] then ok(JSON.generate(serve))
      else register.respond_to?(:call) ? register.call(args) : register
      end
    end
    [ runner, calls ]
  end

  def test_ensure_ready
    runner, = runner_for
    assert_equal({ dns_name: "box.tail1.ts.net", base_url: "https://box.tail1.ts.net" },
                 TS.ensure_ready!(require_https: true, runner: runner))
    err = assert_raises(Portless::Error) { TS.ensure_ready!(require_funnel: true, runner: runner) }
    assert_match(%r{Funnel is not enabled.*https://login\.tailscale\.com/f/funnel\?node=n123}, err.message)
    runner, = runner_for(status: { "Self" => { "HostName" => "box" }, "CurrentTailnet" => { "MagicDNSSuffix" => "t.ts.net." } })
    assert_equal "box.t.ts.net", TS.ensure_ready!(runner: runner)[:dns_name]
    err = assert_raises(Portless::Error) { TS.ensure_ready!(require_https: true, runner: runner) }
    assert_match(/HTTPS is not enabled/, err.message)
    err = assert_raises(Portless::Error) { TS.ensure_ready!(runner: ->(_) { { error: Errno::ENOENT.new } }) }
    assert_match(/Tailscale CLI not found/, err.message)
  end

  def test_used_serve_ports_include_foreground_sessions
    serve = { "Web" => { "box:443" => {} }, "TCP" => { "8443" => {} },
              "Foreground" => { "s1" => { "Web" => { "box:8444" => {} } } } }
    runner, = runner_for(serve: serve)
    assert_equal [ 443, 8443, 8444 ].sort, TS.used_serve_ports(runner).sort
    assert_equal 8445, TS.find_available_serve_port([ 443, 8443, 8444 ])
    assert_equal 10_000, TS.find_available_serve_port([ 443, 8443 ], "funnel")
    assert_raises(Portless::Error) { TS.find_available_serve_port([ 443, 8443, 10_000 ], "funnel") }
    assert_equal 8452, TS.find_available_serve_port(TS::PREFERRED_SERVE_PORTS + [ 8451 ])
  end

  def test_register_conflict_and_funnel_errors
    err = assert_raises(Portless::Error) { TS.register("serve", 4000, 443, ->(_) { fail_with("port already in use") }) }
    assert_match(/HTTPS port 443 is already in use\. Stop the existing serve/, err.message)
    err = assert_raises(Portless::Error) do
      TS.register("funnel", 4000, 443, ->(_) { fail_with("Funnel is not enabled on your tailnet") })
    end
    assert_match(/Tailscale said: Funnel is not enabled/, err.message)
  end

  def test_start_retries_conflicts_three_times
    attempts = 0
    runner, calls = runner_for(register: lambda { |_args|
      attempts += 1
      attempts < 3 ? fail_with("already in use") : ok
    })
    handle = TS.start(app_port: 4000, base_url: "https://box.ts.net", runner: runner)
    assert_equal 3, attempts
    assert_equal "https://box.ts.net", handle.url
    refute handle.funnel?
    assert_includes calls, [ "serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:4000" ]
  end

  def test_unregister_only_what_was_recorded
    calls = []
    runner = ->(args) { calls << args; fail_with("handler does not exist") }
    TS.unregister_tailscale({ tailscale_https_port: 8443, tailscale_funnel: true }, runner: runner)
    TS.unregister_tailscale(https_port: 443, funnel: false, runner: runner)
    TS.unregister_tailscale({ tailscale_url: "https://box.ts.net" }, runner: runner)
    assert_equal [ %w[funnel --yes --https=8443 off], %w[serve --yes --https=443 off] ], calls
  end

  def test_format_url
    assert_equal "https://box.ts.net", TS.format_url("https://box.ts.net/", 443)
    assert_equal "https://box.ts.net:8443", TS.format_url("https://box.ts.net", 8443)
  end
end
