# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../support/e2e"
require "set"

# Mirror of tests/e2e/src/parallel.test.ts

describe "parallel route registration" do
  include UpstreamE2E

  # Matches real-world monorepo scale (json-render has 19 parallel portless commands)
  app_count = 20

  it "registers all routes when many portless run commands start in parallel" do
    # Start the proxy explicitly first so all parallel runs don't race to start it
    start_proxy(@env, @proxy_port)

    # Launch all apps in parallel, just like a monorepo task runner would
    apps = Array.new(app_count) do |i|
      name = "parallel-app-#{i}"
      app_port = free_port
      app_port = free_port while @app_ports.include?(app_port)
      @app_ports << app_port
      child = track(spawn_cli(@env.merge("APP_NAME" => name), name, "--app-port", app_port,
                              RbConfig.ruby, "server.rb", chdir: fixture("minimal-server")))
      { name: name, hostname: "#{name}.localhost", child: child }
    end

    # Wait for all apps to be registered (or for early failures)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    registered = Set.new
    while registered.size < app_count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      apps.each_with_index do |app, i|
        next if registered.include?(i)

        # If the process exited early, that's a failure we'll catch below
        registered << i if app[:child].exited? || (200...400).cover?(status_of(@proxy_port, app[:hostname]))
      end
      sleep 0.5 if registered.size < app_count
    end

    # Verify no app crashed with a lock error
    lock_failures = apps.select do |a|
      a[:child].stderr.include?("Failed to acquire route lock") || a[:child].stdout.include?("Failed to acquire route lock")
    end
    _(lock_failures.map { |a| a[:name] }).must_equal []

    # Verify no app exited unexpectedly
    crashed_apps = apps.select { |a| a[:child].exited? && a[:child].exit_code != 0 }
    _(crashed_apps.map { |a| { name: a[:name], code: a[:child].exit_code, stderr: a[:child].stderr } }).must_equal []

    # Verify all apps are reachable through the proxy
    app_count.times do |i|
      status, body, = request(@proxy_port, apps[i][:hostname])
      _(status).must_equal 200
      _(body).must_include "ok:parallel-app-#{i}"
    end

    # Verify the routes file has all entries
    registered_hostnames = read_routes(@state_dir).map { |r| r["hostname"] }.sort
    expected_hostnames = Array.new(app_count) { |i| "parallel-app-#{i}.localhost" }.sort
    _(registered_hostnames).must_equal expected_hostnames
  end
end
