# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/self-daemon.test.ts
#
# A command that daemonizes and exits keeps its route (handed to the server
# that binds the port), a foreground command's route goes when it exits, and
# a pre-existing listener on the port never inherits it. The fixtures are Ruby
# twins of upstream's node scripts.

describe "self-daemonizing command lifecycle" do
  include UpstreamE2E

  before do
    start_proxy(@env, @proxy_port)
  end

  after do
    if @app_port
      kill_port(@app_port)
      wait_for_port_to_close(@app_port, 5)
    end
  end

  def wait_for_route(host)
    wait_until(15) { status_of(@proxy_port, host) == 200 }
  end

  it "keeps serving the route after the launcher exits, until the server stops" do
    child = track(spawn_cli(@env, "self-daemon", fixture("self-daemon", "launcher.sh")))
    _(child.wait(15)).must_equal true, child.logs
    _(child.exit_code).must_equal 0, child.logs

    route = read_routes(@state_dir).find { |entry| entry["hostname"] == "self-daemon.localhost" }
    _(route).wont_be_nil read_routes(@state_dir).inspect
    @app_port = route["port"]
    _(pids_on_port(@app_port)).must_equal [ route["pid"] ]
    _(wait_for_route(route["hostname"])).must_equal true, "route never served"

    # Let the proxy settle on the transferred route, as it would for a daemon
    # that runs for a while.
    sleep 1
    Process.kill("TERM", route["pid"])
    _(wait_until(15) { pids_on_port(@app_port).empty? }).must_equal true
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
      _(status_of(@proxy_port, route["hostname"])).wont_equal 200
    ensure
      unrelated.close
      responder.kill
    end
    list, = cli(@env, "list")
    _(list).wont_include "self-daemon.localhost"
  end

  it "keeps the route for a detached daemon that binds after the launcher exits" do
    child = track(spawn_cli(@env, "detached", RbConfig.ruby, fixture("self-daemon", "detached-launcher.rb")))
    _(child.wait(15)).must_equal true, child.logs
    _(child.exit_code).must_equal 0, child.logs

    route = read_routes(@state_dir).find { |entry| entry["hostname"] == "detached.localhost" }
    _(route).wont_be_nil read_routes(@state_dir).inspect
    @app_port = route["port"]
    _(wait_for_route(route["hostname"])).must_equal true, "route never served"
  end

  it "removes the route when a foreground command exits" do
    child = track(spawn_cli(@env, "foreground", "true"))
    _(child.wait(15)).must_equal true, child.logs
    _(child.exit_code).must_equal 0, child.logs
    _(read_routes(@state_dir).length).must_equal 0
  end

  it "does not hand the route to a server that held the port before the command ran" do
    foreign = TCPServer.new("127.0.0.1", 0)
    foreign_port = foreign.addr[1]
    begin
      child = track(spawn_cli(@env, "occupied", "--app-port", foreign_port, "sh", "-c", "exit 1"))
      _(child.wait(15)).must_equal true, child.logs
      _(child.exit_code).must_equal 1, child.logs
      _(read_routes(@state_dir).length).must_equal 0
    ensure
      foreign.close
    end
  end
end
