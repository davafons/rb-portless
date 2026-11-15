# frozen_string_literal: true

require_relative "e2e_cli_helper"

# Port of upstream tests/e2e/src/self-daemon.test.ts: a command that
# daemonizes and exits keeps its route (handed to the server that binds the
# port), a foreground command's route goes when it exits, and a pre-existing
# listener on the port never inherits it.
class E2ESelfDaemonTest < E2ECliTest
  def setup
    super
    start_proxy(@env, @proxy_port)
  end

  def teardown
    kill_port(@app_port) if @app_port
    wait_for_port_to_close(@app_port, 5) if @app_port
    super
  end

  def wait_for_route(host)
    wait_until(15) { status_of(@proxy_port, host) == 200 }
  end

  def test_keeps_serving_after_the_launcher_exits_until_the_server_stops
    child = track(spawn_cli(@env, "self-daemon", fixture("self-daemon", "launcher.sh")))
    assert child.wait(15), child.logs
    assert_equal 0, child.exit_code, child.logs

    route = read_routes(@state_dir).find { |r| r["hostname"] == "self-daemon.localhost" }
    refute_nil route, read_routes(@state_dir).inspect
    @app_port = route["port"]
    assert_equal [ route["pid"] ], pids_on_port(@app_port)
    assert wait_for_route(route["hostname"]), "route never served"

    sleep 1
    Process.kill("TERM", route["pid"])
    assert wait_until(15) { pids_on_port(@app_port).empty? }

    # An unrelated server on the same port must not answer for the old hostname.
    unrelated = TCPServer.new("127.0.0.1", @app_port)
    responder = Thread.new do
      loop do
        c = unrelated.accept
        c.gets
        c.write("HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nunrelated")
        c.close
      end
    rescue IOError
      nil
    end
    begin
      refute_equal 200, status_of(@proxy_port, route["hostname"])
    ensure
      unrelated.close
      responder.kill
    end
    out, = cli(@env, "list")
    refute_includes out, "self-daemon.localhost"
  end

  def test_keeps_the_route_for_a_detached_daemon_that_binds_after_the_launcher_exits
    child = track(spawn_cli(@env, "detached", RbConfig.ruby, fixture("self-daemon", "detached-launcher.rb")))
    assert child.wait(15), child.logs
    assert_equal 0, child.exit_code, child.logs

    route = read_routes(@state_dir).find { |r| r["hostname"] == "detached.localhost" }
    refute_nil route, read_routes(@state_dir).inspect
    @app_port = route["port"]
    assert wait_for_route(route["hostname"]), "route never served"
  end

  def test_removes_the_route_when_a_foreground_command_exits
    child = track(spawn_cli(@env, "foreground", "true"))
    assert child.wait(15), child.logs
    assert_equal 0, child.exit_code, child.logs
    assert_equal [], read_routes(@state_dir)
  end

  def test_does_not_hand_the_route_to_a_server_that_held_the_port_before
    foreign = TCPServer.new("127.0.0.1", 0)
    foreign_port = foreign.addr[1]
    child = track(spawn_cli(@env, "occupied", "--app-port", foreign_port, "sh", "-c", "exit 1"))
    assert child.wait(15), child.logs
    assert_equal 1, child.exit_code, child.logs
    assert_equal [], read_routes(@state_dir)
  ensure
    foreign&.close
  end
end
