# frozen_string_literal: true

require_relative "e2e_cli_helper"

# Port of upstream tests/e2e/src/zombie.test.ts: signal handling must take the
# whole dev-server process group down, and `prune` is the safety net for
# sessions killed with SIGKILL.
class E2EZombieTest < E2ECliTest
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

  # --- zombie process prevention -------------------------------------------

  def test_sigterm_kills_the_dev_server_via_process_group
    child, app_port = start_cli_app("zombie-sigterm", "wrapper.rb")
    child.kill("TERM")
    sleep 2
    assert_equal [], pids_on_port(app_port)
  end

  def test_sighup_kills_the_dev_server_via_process_group
    child, app_port = start_cli_app("zombie-sighup", "wrapper.rb")
    child.kill("HUP")
    cli_exited = child.wait(10)
    port_closed = wait_for_port_to_close(app_port, 2)
    assert_equal({ cli_exited: true, port_closed: true }, { cli_exited: cli_exited, port_closed: port_closed })
  end

  def test_sigint_stops_the_dev_server_before_exiting
    child, app_port = start_cli_app("zombie-sigint", "stubborn-wrapper.rb")
    child.kill("INT")
    cli_exited = child.wait(10)
    port_closed = wait_for_port_to_close(app_port, 1)
    assert_equal({ cli_exited: true, port_closed: true }, { cli_exited: cli_exited, port_closed: port_closed })
  end

  def test_forwards_a_second_sigint_while_shutting_down
    child, app_port = start_cli_app("zombie-second-sigint", "stubborn-wrapper.rb")
    child.kill("INT")
    sleep 0.1
    child.kill("INT")
    cli_exited = child.wait(2)
    port_closed = wait_for_port_to_close(app_port, 2)
    assert_equal({ cli_exited: true, port_closed: true }, { cli_exited: cli_exited, port_closed: port_closed })
  end

  def test_sigkill_leaves_orphan_and_prune_cleans_it_up
    child, app_port = start_cli_app("zombie-sigkill")
    child.kill("KILL")
    child.wait(5) # reap: an unreaped zombie still answers kill(0)
    sleep 2
    refute_empty pids_on_port(app_port), "dev server should survive SIGKILL of the CLI"

    out, err, st = prune
    assert_equal 0, st.exitstatus, err
    assert_includes out, "killed"
    sleep 1
    assert_equal [], pids_on_port(app_port)
  end

  # --- orphaned process groups ---------------------------------------------

  def start_and_crash(name)
    pid_file = File.join(@state_dir, "sidecar.pid")
    child, = start_cli_app(name, "sidecar-wrapper.rb", "SIDECAR_PID_FILE" => pid_file)
    @sidecar = Integer(File.read(pid_file))
    child.kill("KILL")
    child.wait(5)
    sleep 0.5
    assert alive?(@sidecar), "sidecar should survive the crash"
    [ child, @sidecar ]
  end

  def teardown
    Process.kill("KILL", @sidecar) if @sidecar && alive?(@sidecar)
    super
  end

  def test_prune_kills_the_whole_process_group
    _, sidecar = start_and_crash("orphan-prune")
    out, = prune
    assert_includes out, "killed process group"
    assert wait_for_pid_to_exit(sidecar, 5)
    assert wait_for_port_to_close(@app_ports.last, 5)
  end

  def test_reports_orphaned_group_ignoring_sigterm_and_keeps_it_for_retry
    child, old_port = start_cli_app("orphan-stubborn", "stubborn-group.rb")
    child.kill("KILL")
    child.wait(5)

    restarted, = start_cli_app("orphan-stubborn", "server.rb")
    assert_match(/Orphaned dev server \(process group \d+\) did not exit\. Run: rb-portless prune --force/,
                 restarted.stderr)
    assert wait_for_port_to_close(old_port, 5)

    stale = read_routes(@state_dir).select { |r| r["port"] == old_port && !alive?(r["pid"]) }
    assert_equal 1, stale.size, read_routes(@state_dir).inspect
    pgid = stale.first["childPgid"]
    refute_nil pgid

    out, err, st = prune("--force")
    assert_equal 0, st.exitstatus, err
    assert_includes out, "killed process group #{pgid} (SIGKILL)"
    assert_raises(Errno::ESRCH) { Process.kill(0, pgid) }
  end

  def test_run_stops_the_orphaned_group_of_a_crashed_session
    _, sidecar = start_and_crash("orphan-restart")
    old_port = @app_ports.last
    host = "orphan-restart.localhost"

    child, new_port = start_cli_app("orphan-restart", "server.rb")
    matching = read_routes(@state_dir).select { |r| r["hostname"] == host }
    assert_equal 1, matching.size, matching.inspect
    assert_equal [ new_port, child.pid ], [ matching[0]["port"], matching[0]["pid"] ]
    refute_equal old_port, new_port

    assert wait_for_pid_to_exit(sidecar, 5)
    assert wait_for_port_to_close(old_port, 5)

    out, err, st = prune
    assert_equal 0, st.exitstatus, err
    assert_includes out, "No orphaned routes found"
    refute_includes out, "killed process group"
    after = read_routes(@state_dir).select { |r| r["hostname"] == host }
    assert_equal [ new_port ], after.map { |r| r["port"] }
    assert alive?(child.pid)
  end
end

# The `portless prune` describe block: no proxy needed.
class E2EPruneTest < Minitest::Test
  include E2ECli

  def setup
    @state_dir = make_state_dir("rbp-e2e-prune-")
    @env = { "PORTLESS_STATE_DIR" => @state_dir, "NO_COLOR" => "1", "PORTLESS_SYNC_HOSTS" => "0" }
  end

  def teardown
    if @orphan
      Process.kill("KILL", @orphan) rescue nil
      Process.wait(@orphan) rescue nil
    end
    FileUtils.rm_rf(@state_dir)
  end

  def test_removes_stale_routes_without_killing_unrelated_listeners
    port = free_port
    @orphan = Process.spawn(RbConfig.ruby, "-rsocket", "-e",
                            "s = TCPServer.new('127.0.0.1', #{port}); loop { s.accept.close }")
    assert wait_until(5) { pids_on_port(port).include?(@orphan) }, "orphan server did not start"

    routes_path = File.join(@state_dir, "routes.json")
    File.write(routes_path, JSON.generate([ { hostname: "orphan-test.localhost", port: port, pid: 2_147_483_647 } ]))

    out, err, st = cli(@env, "prune")
    assert_equal 0, st.exitstatus, err
    assert_includes out, "orphan-test.localhost"
    assert_includes out, "PID #{@orphan} still holds the port and was not killed"
    assert_includes out, "Pruned 1 stale route, killed 0 orphaned processes"
    assert alive?(@orphan)
    assert_includes pids_on_port(port), @orphan
    assert_equal [], JSON.parse(File.read(routes_path))
  end

  def test_reports_nothing_when_no_orphans_exist
    out, err, st = cli(@env, "prune")
    assert_equal 0, st.exitstatus, err
    assert_includes out, "No orphaned routes found"
  end
end
