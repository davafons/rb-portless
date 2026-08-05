# frozen_string_literal: true

require_relative "e2e_helper"

# `rb-portless run` end-to-end: a real CLI child process that must find the
# running proxy, register its route, inject PORT/HOST/PORTLESS_URL into the dev
# command, proxy real requests to it, and deregister the route on shutdown.
class E2ERunnerTest < Minitest::Test
  HOST = "e2erun.localhost"

  # A minimal dev server honoring the injected env, as one -e arg (no shell).
  # Non-interpolating heredoc: the \r\n and #{} must reach the child verbatim.
  CHILD_SERVER = <<~'RUBY'
    require "socket"
    server = TCPServer.new(ENV.fetch("HOST", "127.0.0.1"), Integer(ENV.fetch("PORT")))
    loop do
      client = server.accept
      client.gets
      nil while (line = client.gets) && line != "\r\n"
      body = "PORT=#{ENV["PORT"]} PORTLESS_URL=#{ENV["PORTLESS_URL"]}"
      client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      client.close
    end
  RUBY

  def test_run_registers_route_serves_through_proxy_and_cleans_up
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)

    workdir = Dir.mktmpdir # kept for the child's lifetime, removed in ensure
    pid = Process.spawn(
      { "PORTLESS_STATE_DIR" => Portless::State.dir, "PORTLESS_PORT" => E2E.proxy_port.to_s },
      RbConfig.ruby, "-I", lib, exe, "run", "--name", "e2erun", "--",
      RbConfig.ruby, "-e", CHILD_SERVER,
      chdir: workdir, in: File::NULL, out: File::NULL, err: File::NULL
    )

    route = wait_for { Portless::RouteStore.new.routes.find { |r| r.hostname == HOST } }
    refute_nil route, "run never registered #{HOST}"

    res = wait_for do
      begin
        r = E2E.get(HOST, "/")
        r if r.code == "200"
      rescue StandardError
        nil
      end
    end
    refute_nil res, "backend never became reachable through the proxy"
    assert_includes res.body, "PORT=#{route.port}"
    assert_includes res.body, "PORTLESS_URL=https://#{HOST}:#{E2E.proxy_port}"

    Process.kill("TERM", pid)
    Process.wait(pid)
    gone = wait_for { Portless::RouteStore.new.routes.none? { |r| r.hostname == HOST } || nil }
    assert gone, "route was not deregistered after TERM"
  ensure
    if pid
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.remove_entry(workdir) if workdir
    E2E.deregister(HOST)
  end

  # Upstream inserts a wrapper process for this on purpose: a plain child kill
  # would pass even without process-group signalling. The dev server here is a
  # *grandchild* (runner → wrapper → server); TERM on the runner must reap it
  # through the process group, or it survives as a zombie holding the port.
  def test_term_kills_the_whole_process_tree_including_grandchildren
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    workdir = Dir.mktmpdir
    File.write(File.join(workdir, "server.rb"), <<~RUBY)
      require "socket"
      server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT")))
      loop { server.accept.close }
    RUBY
    File.write(File.join(workdir, "wrapper.rb"), <<~RUBY)
      pid = Process.spawn(RbConfig.ruby, File.expand_path("server.rb", __dir__))
      Process.wait(pid)
    RUBY

    pid = Process.spawn(
      { "PORTLESS_STATE_DIR" => Portless::State.dir, "PORTLESS_PORT" => E2E.proxy_port.to_s },
      RbConfig.ruby, "-I", lib, exe, "run", "--name", "e2etree", "--",
      RbConfig.ruby, File.join(workdir, "wrapper.rb"),
      chdir: workdir, in: File::NULL, out: File::NULL, err: File::NULL
    )

    route = wait_for { Portless::RouteStore.new.routes.find { |r| r.hostname == "e2etree.localhost" } }
    refute_nil route, "run never registered e2etree.localhost"
    up = wait_for do
      begin
        TCPSocket.new("127.0.0.1", route.port).close
        true
      rescue StandardError
        nil
      end
    end
    assert up, "grandchild dev server never bound its port"

    Process.kill("TERM", pid)
    Process.wait(pid)
    dead = wait_for do
      begin
        TCPSocket.new("127.0.0.1", route.port).close
        nil
      rescue Errno::ECONNREFUSED
        true
      end
    end
    assert dead, "grandchild survived TERM — process-group kill failed"
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
    FileUtils.remove_entry(workdir) if workdir
    E2E.deregister("e2etree.localhost")
  end

  def test_child_exit_status_propagates_through_run
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    env = { "PORTLESS_STATE_DIR" => Portless::State.dir, "PORTLESS_PORT" => E2E.proxy_port.to_s }

    system(env, RbConfig.ruby, "-I", lib, exe, "run", "--name", "e2estatus", "--",
           RbConfig.ruby, "-e", "exit 7", in: File::NULL, out: File::NULL, err: File::NULL)
    assert_equal 7, $?.exitstatus
  ensure
    E2E.deregister("e2estatus.localhost")
  end

  def test_a_missing_command_is_a_clean_error
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    env = { "PORTLESS_STATE_DIR" => Portless::State.dir, "PORTLESS_PORT" => E2E.proxy_port.to_s }

    out = IO.popen(env, [ RbConfig.ruby, "-I", lib, exe, "run", "--name", "e2emissing", "--",
                          "definitely-not-a-real-command" ], err: [ :child, :out ], &:read)
    refute $?.success?
    assert_match(/command not found/, out)
    refute_match(/Traceback|backtrace/, out)
  ensure
    E2E.deregister("e2emissing.localhost")
  end

  def test_portless_zero_bypasses_the_proxy_entirely
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)

    out = IO.popen(
      { "PORTLESS_STATE_DIR" => Portless::State.dir, "PORTLESS" => "0" },
      [ RbConfig.ruby, "-I", lib, exe, "run", "--name", "e2eskip", "--",
        RbConfig.ruby, "-e", 'print "ran-direct PORT=#{ENV["PORT"].inspect}"' ],
      err: [ :child, :out ], &:read
    )

    assert_includes out, "ran-direct PORT=nil"
    assert_nil Portless::RouteStore.new.routes.find { |r| r.hostname == "e2eskip.localhost" }
  end

  private

  def wait_for(timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      value = yield
      return value if value

      sleep 0.1
    end
    nil
  end
end
