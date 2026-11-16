# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "minitest/mock"

# Multi-app mode (cli.ts handleDefaultMulti / runWithDirectSpawn). The proxy
# and hosts sync are stubbed; children are real short-lived processes.
class MultiTest < Minitest::Test
  M = Portless::Multi

  def setup
    @ws = Dir.mktmpdir
    @state_dir = Dir.mktmpdir
    File.chmod(0o700, @state_dir)
    @state = Portless::Daemon::ProxyState.new(dir: @state_dir, port: 1355, tls: false, tld: "localhost",
                                              tlds: [ "localhost" ], lan_mode: false, lan_ip: nil)
  end

  def teardown
    FileUtils.rm_rf(@ws)
    FileUtils.rm_rf(@state_dir)
  end

  def write_json(rel, data)
    path = File.join(@ws, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  def app(name, command, proxied: true)
    pkg = Portless::Workspace::Package.new(dir: @ws, name: name, scripts: {})
    M::App.new(pkg: pkg, name: name, label: name, command_args: command, proxied: proxied)
  end

  def routes = Portless::RouteStore.new(@state_dir).load_routes.map(&:hostname)

  def test_duplicate_hostnames_fail_before_the_proxy_starts
    write_json("package.json", { workspaces: [ "packages/*" ] })
    write_json("portless.json", { apps: { "packages/a" => { name: "same" }, "packages/b" => { name: "same" } } })
    %w[a b].each { |n| write_json("packages/#{n}/package.json", { name: n, scripts: { dev: "next dev" } }) }
    start = ->(*) { flunk "proxy must not start" }
    Portless::Daemon.stub(:discover_state, @state) do
      Portless::Daemon.stub(:proxy_up?, false) do
        Portless::Daemon.stub(:ensure_proxy_running, start) do
          err = nil
          capture_io { err = assert_raises(Portless::Error) { M.new(@ws, nil, []).run } }
          assert_match(/Duplicate hostname "same.localhost" for "same" \(packages\/a\) and "same" \(packages\/b\)/,
                       err.message)
        end
      end
    end
  end

  def test_direct_spawn_drops_an_apps_routes_when_it_exits
    seen_while_running = nil
    reported = []
    quick = app("quick", [ "sh", "-c", "exit 3" ])
    slow = app("slow", [ "ruby", "-e", "sleep 0.1 until File.exist?(ARGV[0])", File.join(@ws, "go") ])
    code = nil
    _, err = capture_io do
      Portless::Daemon.stub(:report_hosts_sync, ->(hostnames, *) { reported.concat(hostnames) }) do
        Portless::ProcessGroup.stub(:find_self_daemonized_listener, nil) do
          watcher = Thread.new do
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
            until (seen_while_running = routes) == [ "slow.localhost" ] ||
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              sleep 0.02
            end
            File.write(File.join(@ws, "go"), "")
          end
          code = M.new(@ws, nil, []).send(:run_with_direct_spawn, @state, [ quick, slow ], [])
          watcher.join
        end
      end
    end
    assert_equal [ "slow.localhost" ], seen_while_running
    assert_equal [], routes
    assert_equal %w[quick.localhost slow.localhost], reported
    assert_equal 1, code
    assert_includes err, "[quick] exited with code 3"
    assert_includes err, "1 app exited with errors: quick (3)"
  end

  def test_task_app_prefix_is_gray_when_color_is_on
    ENV["FORCE_COLOR"] = "1"
    out, = capture_io do
      M.new(@ws, nil, []).send(:run_with_direct_spawn, @state, [], [ app("lint", [ "echo", "ok" ], proxied: false) ])
    end
    assert_equal "\e[2m[lint]\e[22m ok\n", out
  ensure
    ENV.delete("FORCE_COLOR")
  end
end
