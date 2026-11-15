# frozen_string_literal: true

require_relative "e2e_cli_helper"

# Harness-level checks from upstream tests/e2e/src/harness.ts (startApp +
# cleanup): proxy start/stop, the `<name> <cmd>` lifecycle with an
# auto-started proxy, and list/get against the live state. Plus the framework
# fixture tests (express/hono/vite) when PORTLESS_E2E_NODE_FIXTURES points at
# a directory holding npm-installed copies of upstream's fixtures.
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

  # name => [fixture dir, command, expected body]
  FRAMEWORKS = {
    "express" => [ "express-app", %w[node server.js], "hello from express" ],
    "hono" => [ "hono-app", %w[node server.js], "hello from hono" ],
    "vite" => [ "vite-app", %w[vite], "hello from vite" ]
  }.freeze

  FRAMEWORKS.each do |name, (dir, command, expected)|
    define_method("test_framework_#{name}_serves_through_the_proxy") do
      root = ENV["PORTLESS_E2E_NODE_FIXTURES"]
      skip "set PORTLESS_E2E_NODE_FIXTURES to npm-installed upstream fixtures" unless root

      cwd = File.join(root, dir)
      skip "#{cwd} missing" unless Dir.exist?(cwd)
      bin = [ File.join(cwd, "node_modules/.bin", command[0]), File.join(root, "node_modules/.bin", command[0]) ]
              .find { |path| File.exist?(path) } || command[0]
      host = "#{name}-test.localhost"
      child = track(spawn_cli(@env, "#{name}-test", bin, *command.drop(1), chdir: cwd))
      assert wait_for_app(@proxy_port, host, timeout: 60), child.logs
      route = read_routes(@state_dir).find { |r| r["hostname"] == host }
      @app_ports << route["port"] if route
      status, body, = request(@proxy_port, host)
      assert_equal 200, status
      assert_includes body, expected
    end
  end
end
