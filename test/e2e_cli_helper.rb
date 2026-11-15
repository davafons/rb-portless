# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "open3"
require "json"
require "socket"
require "fileutils"

# Process-level harness for the CLI e2e tests, ported from upstream's
# tests/e2e/src/harness.ts (+ the helpers zombie/parallel/self-daemon tests
# each inline): every test gets its own state dir and a plain-HTTP proxy on a
# free 16xxx port, drives the real `exe/rb-portless` as a child process, and
# talks to the proxy with a Host header.
module E2ECli
  EXE = File.expand_path("../exe/rb-portless", __dir__)
  LIB = File.expand_path("../lib", __dir__)
  FIXTURES = File.expand_path("fixtures/e2e", __dir__)

  # A background CLI child with its stdout/stderr collected.
  class Child
    attr_reader :pid

    def initialize(pid, out_r, err_r)
      @pid = pid
      @out = +""
      @err = +""
      @readers = [ [ out_r, @out ], [ err_r, @err ] ].map do |io, buf|
        Thread.new do
          loop { buf << io.readpartial(4096) }
        rescue EOFError, IOError
          nil
        end
      end
      @status = nil
    end

    def stdout = @out.dup
    def stderr = @err.dup

    def kill(signal)
      Process.kill(signal, @pid)
    rescue Errno::ESRCH
      nil
    end

    def exited? = !status.nil?

    def status
      @status ||= begin
        _, st = Process.wait2(@pid, Process::WNOHANG)
        st
      rescue Errno::ECHILD
        nil
      end
    end

    def exit_code = status&.exitstatus

    # Returns true when the child exited within the timeout.
    def wait(timeout = 10)
      E2ECli.wait_until(timeout) { exited? }
    end

    def logs = "stdout:\n#{stdout}\nstderr:\n#{stderr}"
  end

  module_function

  def tmp_base
    ENV["PORTLESS_E2E_TMPDIR"] || Dir.tmpdir
  end

  def make_state_dir(prefix = "rbp-e2e-")
    Dir.mktmpdir(prefix, tmp_base)
  end

  def fixture(*parts) = File.join(FIXTURES, *parts)

  # A free TCP port in the 16xxx range (high, unprivileged, away from the
  # random 4000-4999 app ports).
  def free_port
    200.times do
      port = rand(16_000..16_999)
      next unless port_free?(port)

      return port
    end
    raise "no free 16xxx port"
  end

  def port_free?(port)
    [ "127.0.0.1", "::1" ].each do |host|
      TCPServer.new(host, port).close
    rescue Errno::EADDRNOTAVAIL
      next
    rescue Errno::EADDRINUSE, Errno::EACCES
      return false
    end
    true
  end

  def env_for(state_dir, proxy_port, extra = {})
    {
      "PORTLESS_PORT" => proxy_port.to_s,
      "PORTLESS_HTTPS" => "0",
      "PORTLESS_STATE_DIR" => state_dir,
      "PORTLESS_SYNC_HOSTS" => "0",
      "NO_COLOR" => "1",
      "RUBY" => RbConfig.ruby
    }.merge(extra)
  end

  def cli_argv(*args) = [ RbConfig.ruby, "-I", LIB, EXE, *args.map(&:to_s) ]

  # Run the CLI to completion: [stdout, stderr, Process::Status].
  def cli(env, *args, chdir: Dir.pwd, timeout: 30)
    Open3.popen3(env, *cli_argv(*args), chdir: chdir) do |stdin, out, err, thr|
      stdin.close
      o = Thread.new { out.read }
      e = Thread.new { err.read }
      unless thr.join(timeout)
        Process.kill("KILL", thr.pid) rescue nil
        raise "rb-portless #{args.join(' ')} timed out"
      end
      [ o.value, e.value, thr.value ]
    end
  end

  def spawn_cli(env, *args, chdir: Dir.pwd)
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(env, *cli_argv(*args), chdir: chdir, in: File::NULL, out: out_w, err: err_w)
    out_w.close
    err_w.close
    Child.new(pid, out_r, err_r)
  end

  def start_proxy(env, port)
    out, err, st = cli(env, "proxy", "start", "--no-tls", "-p", port)
    raise "proxy start failed (#{st.exitstatus}):\n#{out}\n#{err}" unless st.success?

    [ out, err, st ]
  end

  def stop_proxy(env, port)
    cli(env, "proxy", "stop", timeout: 15)
  rescue StandardError
    nil
  ensure
    kill_port(port)
  end

  # Plain-HTTP request through the proxy with a Host header: [status, body].
  def request(proxy_port, host, path = "/", timeout: 2)
    http = Net::HTTP.new("127.0.0.1", proxy_port)
    http.open_timeout = timeout
    http.read_timeout = timeout
    res = http.start { |c| c.get(path, { "Host" => host }) }
    [ res.code.to_i, res.body.to_s, res ]
  end

  def status_of(proxy_port, host)
    request(proxy_port, host).first
  rescue StandardError
    0
  end

  def wait_for_app(proxy_port, host, timeout: 30)
    wait_until(timeout, interval: 0.2) { (200...400).cover?(status_of(proxy_port, host)) }
  end

  def pids_on_port(port)
    out, = Open3.capture2("lsof", "-ti", "tcp:#{port}", "-sTCP:LISTEN")
    out.split.map(&:to_i).select(&:positive?).uniq
  rescue StandardError
    []
  end

  def kill_port(port, signal = "TERM")
    pids_on_port(port).each do |pid|
      next if pid == Process.pid

      Process.kill(signal, pid) rescue nil
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def wait_until(timeout, interval: 0.05)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep interval
    end
  end

  def wait_for_port_to_close(port, timeout) = wait_until(timeout) { pids_on_port(port).empty? }
  def wait_for_pid_to_exit(pid, timeout) = wait_until(timeout) { !alive?(pid) }

  def read_routes(state_dir)
    JSON.parse(File.read(File.join(state_dir, "routes.json")))
  rescue Errno::ENOENT
    []
  end
end

# Base class: one state dir + proxy port per test, torn down like upstream's
# cleanupTestState (CLI child, app port, `proxy stop`, proxy port, state dir).
class E2ECliTest < Minitest::Test
  include E2ECli

  def setup
    @state_dir = make_state_dir
    @proxy_port = free_port
    @env = env_for(@state_dir, @proxy_port)
    @children = []
    @app_ports = []
  end

  def teardown
    @children.each do |child|
      next if child.exited?

      child.kill("TERM")
      child.kill("KILL") unless child.wait(1)
      child.wait(2)
    end
    @app_ports.each { |port| kill_port(port) }
    stop_proxy(@env, @proxy_port)
    FileUtils.rm_rf(@state_dir)
  end

  def track(child)
    @children << child
    child
  end
end
