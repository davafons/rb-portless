# frozen_string_literal: true

require_relative "e2e_helper"

# Monorepo mode end-to-end: `rb-portless run` with an `apps` map boots every
# app under one proxy, each at its own hostname, and tears all of them (and
# their routes) down together.
class E2EMultiTest < Minitest::Test
  APP_SERVER = 'require "socket"; s = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT"))); ' \
               'loop { c = s.accept; c.gets; nil while (l = c.gets) && l != "\r\n"; ' \
               'b = ENV.fetch("PORTLESS_URL"); ' \
               'c.write("HTTP/1.1 200 OK\r\nContent-Length: #{b.bytesize}\r\n\r\n#{b}"); c.close }'

  def test_apps_map_runs_every_app_and_reaps_all_routes_on_term
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    workdir = Dir.mktmpdir
    command = "#{RbConfig.ruby} -e '#{APP_SERVER}'"
    File.write(File.join(workdir, "portless.json"),
               JSON.generate({ "apps" => { "e2eweb" => command, "e2eapi" => command } }))

    pid = Process.spawn(
      { "PORTLESS_STATE_DIR" => Portless::State.dir, "PORTLESS_PORT" => E2E.proxy_port.to_s },
      RbConfig.ruby, "-I", lib, exe, "run",
      chdir: workdir, in: File::NULL, out: File::NULL, err: File::NULL
    )

    %w[e2eweb.localhost e2eapi.localhost].each do |host|
      res = wait_for do
        begin
          r = E2E.get(host, "/")
          r if r.code == "200"
        rescue StandardError
          nil
        end
      end
      refute_nil res, "#{host} never became reachable through the proxy"
      assert_equal "https://#{host}:#{E2E.proxy_port}", res.body
    end

    Process.kill("TERM", pid)
    Process.wait(pid)
    gone = wait_for do
      Portless::RouteStore.new.routes.none? { |r| r.hostname.start_with?("e2eweb", "e2eapi") } || nil
    end
    assert gone, "multi-app routes were not deregistered after TERM"
  ensure
    if pid
      begin
        Process.kill("KILL", -Process.getpgid(pid))
      rescue StandardError
        nil
      end
      begin
        Process.wait(pid)
      rescue StandardError
        nil
      end
    end
    %w[e2eweb.localhost e2eapi.localhost].each { |h| E2E.deregister(h) }
    FileUtils.remove_entry(workdir) if workdir
  end

  private

  def wait_for(timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      value = yield
      return value if value

      sleep 0.1
    end
    nil
  end
end
