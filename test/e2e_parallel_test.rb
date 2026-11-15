# frozen_string_literal: true

require_relative "e2e_cli_helper"
require "set"

# Port of upstream tests/e2e/src/parallel.test.ts: many `<name> <cmd>` runs
# starting at once (monorepo task-runner scale) must all register without
# route-lock failures.
class E2EParallelTest < E2ECliTest
  APP_COUNT = 20

  def test_registers_all_routes_when_many_run_commands_start_in_parallel
    start_proxy(@env, @proxy_port)

    apps = Array.new(APP_COUNT) do |i|
      name = "parallel-app-#{i}"
      app_port = free_port
      @app_ports << app_port
      child = track(spawn_cli(@env.merge("APP_NAME" => name), name, "--app-port", app_port,
                              RbConfig.ruby, "server.rb", chdir: fixture("minimal-server")))
      { name: name, host: "#{name}.localhost", child: child }
    end

    registered = Set.new
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    while registered.size < APP_COUNT && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      apps.each_with_index do |app, i|
        next if registered.include?(i)

        registered << i if app[:child].exited? || (200...400).cover?(status_of(@proxy_port, app[:host]))
      end
      sleep 0.5 if registered.size < APP_COUNT
    end

    lock_failures = apps.select { |a| (a[:child].stderr + a[:child].stdout).include?("Failed to acquire route lock") }
    assert_equal [], lock_failures.map { |a| a[:name] }

    crashed = apps.select { |a| a[:child].exited? && a[:child].exit_code != 0 }
    assert_equal [], crashed.map { |a| { name: a[:name], code: a[:child].exit_code, stderr: a[:child].stderr } }

    apps.each do |app|
      status, body, = request(@proxy_port, app[:host])
      assert_equal 200, status, app[:name]
      assert_includes body, "ok:#{app[:name]}"
    end

    hostnames = read_routes(@state_dir).map { |r| r["hostname"] }.sort
    assert_equal apps.map { |a| a[:host] }.sort, hostnames
  end
end
