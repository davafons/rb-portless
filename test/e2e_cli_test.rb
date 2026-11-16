# frozen_string_literal: true

require_relative "e2e_cli_helper"

# Harness-level checks from upstream tests/e2e/src/harness.ts (startApp +
# cleanup): proxy start/stop, the `<name> <cmd>` lifecycle with an
# auto-started proxy, and list/get against the live state. The framework
# fixture tests live in test/upstream/e2e.
class E2ECliHarnessTest < E2ECliTest
  def test_proxy_start_and_stop
    out, = start_proxy(@env, @proxy_port)
    assert_includes out, "HTTP proxy started on port #{@proxy_port}"
    status, _, res = request(@proxy_port, "nothing.localhost")
    assert_equal 404, status
    assert_equal "1", res["x-portless"]

    out, = cli(@env, "proxy", "start", "--no-tls", "-p", @proxy_port)
    assert_includes out, "already running"

    out, err, st = cli(@env, "proxy", "stop")
    assert st.success?, err
    assert_includes out, "Proxy stopped."
    assert wait_for_port_to_close(@proxy_port, 5)
  end

  def test_app_lifecycle_with_auto_started_proxy
    child = track(spawn_cli(@env.merge("APP_NAME" => "lifecycle"), "lifecycle", RbConfig.ruby, "server.rb",
                            chdir: fixture("minimal-server")))
    assert wait_for_app(@proxy_port, "lifecycle.localhost"), child.logs
    status, body, = request(@proxy_port, "lifecycle.localhost")
    assert_equal [ 200, "ok:lifecycle" ], [ status, body ]
    route = read_routes(@state_dir).find { |r| r["hostname"] == "lifecycle.localhost" }
    @app_ports << route["port"]

    out, err, st = cli(@env, "get", "lifecycle")
    assert st.success?, err
    assert_equal "http://lifecycle.localhost:#{@proxy_port}", out.strip

    out, = cli(@env, "list")
    assert_includes out, "http://lifecycle.localhost:#{@proxy_port}"
    assert_includes out, "localhost:#{route['port']}"

    out, = cli(@env, "list", "--json")
    json = JSON.parse(out)
    assert_equal [ "lifecycle.localhost" ], json["routes"].map { |r| r["hostname"] }

    child.kill("TERM")
    assert child.wait(10), child.logs
    assert wait_for_port_to_close(route["port"], 5)
    assert_equal [], read_routes(@state_dir)
    assert_equal 404, status_of(@proxy_port, "lifecycle.localhost")
  end

  # Byte-for-byte upstream banner (console.error keeps the blank lines that
  # Ruby's warn would swallow) and the command's exit code passes through.
  def test_run_banner_layout_and_exit_code
    start_proxy(@env, @proxy_port)
    out, err, st = cli(@env, "myapp", "sh", "-c", "exit 3")
    assert_equal 3, st.exitstatus, err
    assert_equal "", out
    port = err[/Using port (\d+)/, 1]
    expected = <<~TEXT

      rb-portless

        Proxy is running
        myapp.localhost (auto-resolves to 127.0.0.1)
        Using port #{port}

        -> http://myapp.localhost:#{@proxy_port}

      Running: PORT=#{port} HOST=127.0.0.1 PORTLESS_URL=http://myapp.localhost:#{@proxy_port} sh -c exit 3

    TEXT
    assert_equal expected, err
  end
end
