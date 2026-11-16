# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"

# Mirror of tests/e2e/src/zombie.test.ts
#
# Signal handling must take the whole dev-server process group down, and
# `prune` is the safety net for sessions killed with SIGKILL. The
# minimal-server fixtures are Ruby twins of upstream's node scripts.

module ZombieMirror
  def start_cli_app(name, script = "server.rb", extra_env = {})
    start_proxy(@env, @proxy_port)
    child = track(spawn_cli(@env.merge("APP_NAME" => name).merge(extra_env), name, RbConfig.ruby, script,
                            chdir: fixture("minimal-server")))
    host = "#{name}.localhost"
    assert wait_for_app(@proxy_port, host), "CLI did not become ready.\n#{child.logs}"

    route = read_routes(@state_dir).find { |r| r["hostname"] == host && r["pid"] == child.pid }
    refute_nil route, "no route for #{host}"
    @app_ports << route["port"]
    refute_empty pids_on_port(route["port"])
    [ child, route["port"] ]
  end

  def prune(*flags)
    cli(@env, "prune", *flags, timeout: 15)
  end
end

describe "zombie process prevention" do
  include UpstreamE2E
  include ZombieMirror

  it "SIGTERM kills the dev server via process group" do
    # wrapper.rb makes the tree CLI -> /bin/sh -> wrapper -> server, so there
    # is a grandchild to orphan.
    child, app_port = start_cli_app("zombie-sigterm", "wrapper.rb")
    child.kill("TERM")
    sleep 2
    _(pids_on_port(app_port)).must_equal []
  end

  it "SIGHUP kills the dev server via process group" do
    child, app_port = start_cli_app("zombie-sighup", "wrapper.rb")
    child.kill("HUP")
    cli_exited = child.wait(10)
    port_closed = wait_for_port_to_close(app_port, 2)
    _({ cli_exited: cli_exited, port_closed: port_closed }).must_equal({ cli_exited: true, port_closed: true })
  end

  it "SIGINT stops the command's dev server before exiting" do
    child, app_port = start_cli_app("zombie-sigint", "stubborn-wrapper.rb")
    child.kill("INT")
    cli_exited = child.wait(10)
    port_closed = wait_for_port_to_close(app_port, 1)
    _({ cli_exited: cli_exited, port_closed: port_closed }).must_equal({ cli_exited: true, port_closed: true })
  end

  it "forwards a second SIGINT while the command is shutting down" do
    child, app_port = start_cli_app("zombie-second-sigint", "stubborn-wrapper.rb")
    child.kill("INT")
    sleep 0.1
    child.kill("INT")
    cli_exited = child.wait(2)
    port_closed = wait_for_port_to_close(app_port, 2)
    _({ cli_exited: cli_exited, port_closed: port_closed }).must_equal({ cli_exited: true, port_closed: true })
  end

  it "SIGKILL leaves orphan, portless prune cleans it up" do
    child, app_port = start_cli_app("zombie-sigkill")
    child.kill("KILL")
    child.wait(5) # reap: an unreaped zombie still answers kill(0)
    sleep 2
    _(pids_on_port(app_port)).wont_be_empty "dev server should survive SIGKILL of the CLI"

    out, err, st = prune
    _(st.exitstatus).must_equal 0, err
    _(out).must_include "killed"
    sleep 1
    _(pids_on_port(app_port)).must_equal []
  end
end

describe "orphaned process groups" do
  include UpstreamE2E
  include ZombieMirror

  after do
    Process.kill("KILL", @sidecar) if @sidecar && alive?(@sidecar)
  end

  def start_and_crash(name)
    pid_file = File.join(@state_dir, "sidecar.pid")
    child, = start_cli_app(name, "sidecar-wrapper.rb", "SIDECAR_PID_FILE" => pid_file)
    @sidecar = Integer(File.read(pid_file))
    child.kill("KILL")
    child.wait(5)
    sleep 0.5
    _(alive?(@sidecar)).must_equal true
    @sidecar
  end

  it "prune kills the whole process group, not only the route port" do
    sidecar = start_and_crash("orphan-prune")
    out, = prune
    _(out).must_include "killed process group"
    _(wait_for_pid_to_exit(sidecar, 5)).must_equal true
    _(wait_for_port_to_close(@app_ports.last, 5)).must_equal true
  end

  it "reports an orphaned group that ignores SIGTERM and keeps it for a retry" do
    child, old_port = start_cli_app("orphan-stubborn", "stubborn-group.rb")
    child.kill("KILL")
    child.wait(5)

    restarted, = start_cli_app("orphan-stubborn", "server.rb")
    _(restarted.stderr).must_match(
      /Orphaned dev server \(process group \d+\) did not exit\. Run: rb-portless prune --force/
    )
    _(wait_for_port_to_close(old_port, 5)).must_equal true

    records = read_routes(@state_dir)
    stale = records.select { |route| route["port"] == old_port && !alive?(route["pid"]) }
    _(stale.size).must_equal 1, records.inspect
    pgid = stale[0]["childPgid"]
    _(pgid).wont_be_nil

    out, err, st = prune("--force")
    _(st.exitstatus).must_equal 0, err
    _(out).must_include "killed process group #{pgid} (SIGKILL)"
    _ { Process.kill(0, pgid) }.must_raise Errno::ESRCH
  end

  it "run stops the orphaned process group of a crashed session" do
    sidecar = start_and_crash("orphan-restart")
    old_port = @app_ports.last
    hostname = "orphan-restart.localhost"

    child, new_port = start_cli_app("orphan-restart", "server.rb")
    matching = read_routes(@state_dir).select { |route| route["hostname"] == hostname }
    _(matching.map { |r| [ r["port"], r["pid"] ] }).must_equal [ [ new_port, child.pid ] ]
    _(new_port).wont_equal old_port

    _(wait_for_pid_to_exit(sidecar, 5)).must_equal true
    _(wait_for_port_to_close(old_port, 5)).must_equal true

    out, err, st = prune
    _(st.exitstatus).must_equal 0, err
    _(out).must_include "No orphaned routes found"
    _(out).wont_include "killed process group"

    after_prune = read_routes(@state_dir).select { |route| route["hostname"] == hostname }
    _(after_prune.map { |r| r["port"] }).must_equal [ new_port ]
    _(alive?(child.pid)).must_equal true
  end
end

describe "portless prune" do
  include E2ECli

  before do
    @state_dir = make_state_dir("rbp-e2e-prune-")
    @env = { "PORTLESS_STATE_DIR" => @state_dir, "NO_COLOR" => "1", "PORTLESS_SYNC_HOSTS" => "0" }
  end

  after do
    if @orphan
      begin
        Process.kill("KILL", @orphan)
        Process.wait(@orphan)
      rescue SystemCallError
        nil
      end
    end
    FileUtils.rm_rf(@state_dir)
  end

  it "removes stale routes without killing unrelated listeners" do
    orphan_port = free_port
    @orphan = Process.spawn(RbConfig.ruby, "-rsocket", "-e",
                            "s = TCPServer.new('127.0.0.1', #{orphan_port}); loop { s.accept.close }")
    _(wait_until(5) { pids_on_port(orphan_port).include?(@orphan) }).must_equal true, "orphan server did not start"

    # Fake stale route: dead PID owns the orphan's port
    dead_pid = 2_147_483_647
    routes_path = File.join(@state_dir, "routes.json")
    File.write(routes_path, JSON.generate([ { hostname: "orphan-test.localhost", port: orphan_port, pid: dead_pid } ]))

    listener_pid = @orphan
    _(pids_on_port(orphan_port)).must_include listener_pid

    out, err, st = cli(@env, "prune")

    _(st.exitstatus).must_equal 0, err
    _(out).must_include "orphan-test.localhost"
    _(out).must_include "PID #{listener_pid} still holds the port and was not killed"
    _(out).must_include "Pruned 1 stale route, killed 0 orphaned processes"
    _(alive?(listener_pid)).must_equal true
    _(pids_on_port(orphan_port)).must_include listener_pid

    _(JSON.parse(File.read(routes_path))).must_equal []
  end

  it "reports nothing when no orphans exist" do
    out, err, st = cli(@env, "prune")

    _(st.exitstatus).must_equal 0, err
    _(out).must_include "No orphaned routes found"
  end
end
