# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "digest"
require "etc"
require "open3"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"

# Helpers for test/upstream/cli_test.rb, ported from the helpers at the top of
# upstream's packages/portless/src/cli.test.ts. Everything spawns the real
# `exe/rb-portless` with an env derived from ENV, which test_helper.rb already
# points at a temp HOME/state dir with sudo/security/certutil shims on PATH.
module UpstreamCli
  FORWARD_ARGS = [ "--help", "--script", "start", "--prefix", "pr-1", "--marker", "one" ].freeze
  UPSTREAM_ROOT = File.expand_path("../../../references/portless", __dir__)
  # Upstream's own Turbo install (references/portless/node_modules), as its tests use.
  TURBO_DIR = File.join(UPSTREAM_ROOT, "node_modules", "turbo")
  REPO_BIN = File.join(UPSTREAM_ROOT, "node_modules", ".bin")

  TEST_CA_PEM = <<~PEM
    -----BEGIN CERTIFICATE-----
    MIIDFzCCAf+gAwIBAgIUEVh0YNawusstUaCfwLYo2qUO7D8wDQYJKoZIhvcNAQEL
    BQAwGzEZMBcGA1UEAwwQcG9ydGxlc3MtdGVzdC1jYTAeFw0yNjA1MjAyMTIzNDBa
    Fw0zNjA1MTcyMTIzNDBaMBsxGTAXBgNVBAMMEHBvcnRsZXNzLXRlc3QtY2EwggEi
    MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDXVX2d5DSfOOdipeP+k27Omgxd
    UV0C35Yx5wKAQiHVBOWNsLPQVoJzyCASMkroul5idmoSr+9IWDh/oizEqN5iRzzA
    MYGAAaNOXVZHN6Y12p0dFaP77+unD2eOgt4cIqZ2VA7K+j8O1hrLbhQ1Ogiw7Xh0
    WjtgNoge9rv9OIr+2eoQmkJCkY66oa1Pe+lTjjhUcXBCK0j4u/3cTxAzjzLaOnzC
    KDnZU2lZT/1v3Fo8YwB/18eVsoxupMRTsXcai2VnazZMcUwQR5HSa9jJ97Jj5H35
    dRvWFlRU5mqO+0COQUvg0naMvaIGXJG4xBljNAcWbQbW2/bMpfK9Z2c3H8M1AgMB
    AAGjUzBRMB0GA1UdDgQWBBT86mpMdHyIkUBVn+C5r6MGyjFfFjAfBgNVHSMEGDAW
    gBT86mpMdHyIkUBVn+C5r6MGyjFfFjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3
    DQEBCwUAA4IBAQCM0eVaH2I4PUYB3R8GEpfOzM0nqRkcKz5r3eeGfbYabtdKyurQ
    lTFT75LiGsMmIuTGlDjP7iKxbeY7cYn5gTUttPVQGwYVOY1qKkLHGst4GaBK/w5Y
    9Ag42CGCYhk172EMJ0H5zGqYvU7itOXU5QERDOxAfHWXIBN4Al/fkRUoCWZZIkAM
    2AqvSowxptbcbnlRn8/l+RgKMrG+88Pj8J1ei3PtiUBx2haYSxPkoBcMOLH52Cdx
    KnZk8J8eqG+Nc2L778YxXPRDS4egacbNc3FoEIAN/zBk+RWc22V5bVODCM69I4Qa
    VeuruL5f30jD8PbGa2A91T5e1oaoL5ap6bdl
    -----END CERTIFICATE-----
  PEM

  EXE = File.expand_path("../../../exe/rb-portless", __dir__)
  LIB = File.expand_path("../../../lib", __dir__)

  APP_SERVER = <<~'RUBY'
    require "socket"
    server = TCPServer.new(ENV["HOST"] || "127.0.0.1", Integer(ENV["PORT"]))
    loop do
      c = server.accept
      Thread.new(c) do |s|
        while (l = s.gets) && l != "\r\n"; end
        s.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        s.close
      end
    end
  RUBY

  STALE_HOSTS = [
    "127.0.0.1 localhost",
    "",
    "# rb-portless-start",
    "127.0.0.1 stale.test",
    "# rb-portless-end",
    "",
    "192.0.2.10 custom.test",
    ""
  ].join("\n")

  Result = Struct.new(:status, :stdout, :stderr, keyword_init: true)

  # What a CLI test must never change outside Dir.tmpdir: /etc/hosts, the real
  # user's state dir and startup service files.
  def self.system_snapshot
    real_home = Etc.getpwuid.dir
    {
      hosts: (Digest::SHA256.file("/etc/hosts").hexdigest rescue nil),
      real_state_dir: (Dir.children(File.join(real_home, ".rb-portless")).sort rescue nil),
      services: Dir.glob([ File.join(real_home, "Library/LaunchAgents/*portless*"), "/Library/LaunchDaemons/*portless*",
                           File.join(real_home, ".config/systemd/user/*portless*") ]).sort
    }
  end

  SYSTEM_SNAPSHOT = system_snapshot

  def assert_system_untouched
    now = UpstreamCli.system_snapshot
    # Route files in a live real state dir may come and go; only a removed dir counts.
    assert_equal SYSTEM_SNAPSHOT[:hosts], now[:hosts], "/etc/hosts changed"
    assert_equal SYSTEM_SNAPSHOT[:real_state_dir].nil?, now[:real_state_dir].nil?, "real ~/.rb-portless changed"
    assert_equal SYSTEM_SNAPSHOT[:services], now[:services], "startup service files changed"
  end

  module_function

  def cli_argv(*args, ruby_opts: []) = [ RbConfig.ruby, *ruby_opts, "-I", LIB, EXE, *args.map(&:to_s) ]

  # Upstream run(): the CLI with env/cwd overrides, NO_COLOR=1, 10 s timeout.
  # An env value of nil unsets the variable.
  def run_cli(args, env: {}, cwd: nil, ruby_opts: [], timeout: 15, base_env: nil, stdin_data: nil)
    full = (base_env || ENV.to_h).dup
    full.delete("PORTLESS_PREFIX")
    env.each { |k, v| v.nil? ? full.delete(k) : full[k] = v.to_s }
    full["NO_COLOR"] = "1" unless base_env
    full.delete("PNPM_SCRIPT_SRC_DIR")
    full.delete("npm_command") if full["npm_command"] == "exec"
    # Our own `bundle exec` snapshot: without this the child's Bundler would
    # restore this process's PATH etc. for the commands it spawns.
    full.reject! { |k, _| k.start_with?("BUNDLER_ORIG_") }
    spawn_env = ENV.keys.to_h { |k| [ k, nil ] }.merge(full)
    capture(spawn_env, cli_argv(*args, ruby_opts: ruby_opts), cwd: cwd, timeout: timeout, stdin_data: stdin_data)
  end

  def capture(env, argv, cwd: nil, timeout: 15, stdin_data: nil)
    opts = { unsetenv_others: false, pgroup: true }
    opts[:chdir] = cwd if cwd
    Open3.popen3(env, *argv, **opts) do |stdin, out, err, thr|
      stdin.write(stdin_data) if stdin_data
      stdin.close
      o = Thread.new { out.read }
      e = Thread.new { err.read }
      unless thr.join(timeout)
        kill_group(thr.pid, "TERM")
        kill_group(thr.pid, "KILL") unless thr.join(1)
        thr.join
        return Result.new(status: nil, stdout: o.value, stderr: e.value)
      end
      Result.new(status: thr.value.exitstatus, stdout: o.value, stderr: e.value)
    end
  end

  def tmpdir(prefix)
    Dir.mktmpdir(prefix)
  end

  # rm -rf, but only for paths this suite created under Dir.tmpdir.
  def rm_tmp(path)
    return unless path

    real = File.realpath(path) rescue File.expand_path(path)
    roots = [ Dir.tmpdir, (File.realpath(Dir.tmpdir) rescue Dir.tmpdir) ]
    raise "refusing to remove #{path}: outside #{Dir.tmpdir}" unless roots.any? { |r| real.start_with?("#{r}/") }

    FileUtils.rm_rf(path)
  end

  def write_exe(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  def get_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def kill_group(pgid, signal = "KILL")
    Process.kill(signal, -pgid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def alive_pid?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  # A PATH whose lsof fails, so socket owner lookups find nothing.
  def failing_lsof_path(dir)
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    write_exe(File.join(bin, "lsof"), "#!/bin/sh\nexit 1\n")
    "#{bin}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
  end

  def find_pids_on_port(port) = Portless::PortOwner.pids_on_port(port)
  def get_process_start_time(pid) = Portless::PortOwner.start_time(pid)

  # A tailscale shim that records its arguments in $PORTLESS_TEST_TAILSCALE_LOG.
  def write_tailscale_shim(dir)
    write_exe(File.join(dir, "tailscale"), "#!/bin/sh\nprintf \"%s\\n\" \"$*\" >> \"$PORTLESS_TEST_TAILSCALE_LOG\"\n")
  end

  # A background process: its own process group (detached) when asked, reaped
  # by a waiter thread so a dead pid really disappears. stdout/stderr collected.
  class Bg
    attr_reader :pid

    # reap: false leaves an exited child as a zombie (still visible to ps)
    # until the test waits on it, like Node before its exit event runs.
    def initialize(argv, detached: false, env: {}, out: true, chdir: nil, reap: true)
      opts = { in: File::NULL }
      opts[:pgroup] = true if detached
      opts[:chdir] = chdir if chdir
      @stdout = +""
      @stderr = +""
      @lock = Mutex.new
      pipes = []
      if out
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        opts[:out] = out_w
        opts[:err] = err_w
        pipes = [ [ out_r, @stdout ], [ err_r, @stderr ] ]
      else
        opts[:out] = File::NULL
        opts[:err] = File::NULL
      end
      env = ENV.keys.grep(/\ABUNDLER_ORIG_/).to_h { |k| [ k, nil ] }.merge(env)
      @pid = Process.spawn(env, *argv, **opts)
      [ out_w, err_w ].compact.each(&:close)
      @readers = pipes.map do |io, buf|
        Thread.new do
          loop { (chunk = io.readpartial(4096)) && @lock.synchronize { buf << chunk } }
        rescue EOFError, IOError
          nil
        end
      end
      waiter if reap
      @line_pos = 0
    end

    def stdout = @lock.synchronize { @stdout.dup }
    def stderr = @lock.synchronize { @stderr.dup }
    def output = stdout + stderr

    # The next complete stdout line.
    def read_line(timeout = 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        @lock.synchronize do
          nl = @stdout.index("\n", @line_pos)
          if nl
            line = @stdout[@line_pos...nl]
            @line_pos = nl + 1
            return line.strip
          end
        end
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end

    def waiter = @waiter ||= Process.detach(@pid)
    def exited? = !waiter.alive?
    def wait(timeout = 10) = !waiter.join(timeout).nil?
    def exit_code = exited? ? waiter.value.exitstatus : nil

    def finish(timeout = 5)
      @readers.each { |t| t.join(timeout) }
    end

    def kill(signal = "KILL")
      Process.kill(signal, @pid)
    rescue Errno::ESRCH
      nil
    end
  end

  def spawn_bg(argv, **opts) = Bg.new(argv, **opts)

  # A copy of the Ruby binary named like a tunnel binary, so `ps -o comm=`
  # reports it (upstream copies the node binary).
  def spawn_fake_binary(dir, name)
    path = File.join(dir, name)
    FileUtils.cp(RbConfig.ruby, path)
    bg = spawn_bg([ path, "-e", "sleep" ], out: false)
    wait_until(5) { Portless::PortOwner.command(bg.pid) == name } or raise "#{name} did not start"
    bg
  end

  # A tiny HTTP server for the test process (upstream http.createServer):
  # the block gets [method, path, headers] and returns [status, headers, body].
  class HttpServer
    attr_reader :port

    def initialize(host = "127.0.0.1", port = 0, &handler)
      @server = TCPServer.new(host, port)
      @port = @server.addr[1]
      @handler = handler || ->(*) { [ 200, {}, "ok" ] }
      @thread = Thread.new { loop { serve(@server.accept) } rescue nil }
    end

    def serve(sock)
      Thread.new do
        line = sock.gets.to_s
        method, path = line.split
        headers = {}
        while (h = sock.gets) && h != "\r\n"
          k, v = h.split(":", 2)
          headers[k.strip.downcase] = v.to_s.strip
        end
        sock.read(headers["content-length"].to_i) if headers["content-length"]
        status, extra, body = @handler.call(method, path, headers)
        out = +"HTTP/1.1 #{status} X\r\n"
        extra.each { |k, v| out << "#{k}: #{v}\r\n" }
        out << "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
        out << body unless method == "HEAD"
        sock.write(out)
      rescue StandardError
        nil
      ensure
        sock.close rescue nil
      end
    end

    def close
      @server.close rescue nil
      @thread.kill
    end

    def listening? = !@server.closed?
  end

  def http_server(...) = HttpServer.new(...)

  MOCK_PROXY_SCRIPT = <<~'RUBY'
    require "socket"
    require "openssl"
    port, header, token, sigterm_delay, pid_file = ARGV[0].to_i, ARGV[1] == "1", ARGV[2], ARGV[3].to_f, ARGV[4]
    server = TCPServer.new("127.0.0.1", port)
    trap("TERM") do
      Thread.new do
        File.write(pid_file, "999999") unless pid_file.to_s.empty?
        sleep sigterm_delay
        server.close rescue nil
        exit 0
      end
    end
    loop do
      sock = server.accept rescue break
      Thread.new(sock) do |s|
        method, path = s.gets.to_s.split
        headers = {}
        while (h = s.gets) && h != "\r\n"
          k, v = h.split(":", 2)
          headers[k.strip.downcase] = v.to_s.strip
        end
        s.read(headers["content-length"].to_i) if headers["content-length"]
        out = []
        out << "X-Portless: 1" if header
        status = 200
        body = "ok"
        if !token.to_s.empty?
          challenge = headers["x-portless-hosts-sync-challenge"]
          out << "x-portless-hosts-sync-proof: #{OpenSSL::HMAC.hexdigest("SHA256", token, challenge)}" if challenge
          if method == "POST" && path == "/.portless/hosts-sync"
            status = 204
            body = ""
          end
        end
        s.write("HTTP/1.1 #{status} X\r\n#{out.map { |l| "#{l}\r\n" }.join}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{method == 'HEAD' ? '' : body}")
      rescue StandardError
        nil
      ensure
        s.close rescue nil
      end
    end
  RUBY

  MockProxy = Struct.new(:port, :child, keyword_init: true)

  # Upstream startMockProxy: a separate process answering with X-Portless: 1
  # (and the hosts-sync proof, with a token written to `dir`).
  def start_mock_proxy(dir, acknowledge_hosts_sync: true, port: nil, sigterm_delay_ms: nil, pid_file_on_sigterm: nil,
                       portless_header: true)
    port ||= get_free_port
    token = acknowledge_hosts_sync && portless_header ? Portless::HostsSyncAuth.generate_token : nil
    Portless::HostsSyncAuth.write_token(dir, token) if token
    script = File.join(dir, "mock-proxy-#{port}.rb")
    File.write(script, MOCK_PROXY_SCRIPT)
    child = spawn_bg([ RbConfig.ruby, script, port.to_s, portless_header ? "1" : "0", token.to_s,
                       (sigterm_delay_ms.to_f / 1000).to_s, pid_file_on_sigterm.to_s ], out: false)
    begin
      wait_for_http_header(port, "X-Portless", portless_header ? "1" : nil)
    rescue StandardError
      child.kill
      raise
    end
    MockProxy.new(port: port, child: child)
  end

  def wait_for_http_header(port, header_name, expected_value, hostname = "127.0.0.1")
    50.times do
      begin
        http = Net::HTTP.new(hostname, port)
        http.open_timeout = 0.2
        http.read_timeout = 0.2
        res = http.start { |c| c.head("/") }
        return if expected_value.nil? || res[header_name] == expected_value
      rescue StandardError
        nil
      end
      sleep 0.05
    end
    raise "Timed out waiting for #{header_name} on #{hostname}:#{port}"
  end

  # waitForHttpHeader over TLS (self-signed): X-Portless: 1 on a HEAD.
  def wait_for_https_header(port, hostname = "127.0.0.1")
    50.times do
      begin
        http = Net::HTTP.new(hostname, port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.open_timeout = 0.5
        http.read_timeout = 0.5
        return if http.start { |c| c.head("/") }["X-Portless"] == "1"
      rescue StandardError, OpenSSL::SSL::SSLError
        nil
      end
      sleep 0.1
    end
    raise "Timed out waiting for X-Portless over TLS on #{hostname}:#{port}"
  end

  def stop_child(child)
    return if child.exited?

    child.kill("TERM")
    child.wait(1)
  end

  # Upstream runComposeUpDetached: `compose up -d` against a mock proxy and a
  # docker stub answering config/ps/up. No real docker, no real proxy.
  def run_compose_up_detached(model:, up_stdout:, up_exit: 0)
    tmp = tmpdir("portless-compose-streams-")
    proxy = start_mock_proxy(tmp)
    File.write(File.join(tmp, "proxy.port"), proxy.port.to_s)
    bin = File.join(tmp, "bin")
    Dir.mkdir(bin)
    containers = JSON.generate(Project: "myapp", Service: "web", State: "running",
                               Publishers: [ { TargetPort: 3000, PublishedPort: 14_501, Protocol: "tcp" } ])
    write_exe(File.join(bin, "docker"), [
      "#!/bin/sh",
      'case "$*" in',
      "  *\" config \"*) printf '%s' '#{JSON.generate(model)}' ;;",
      "  *\" ps \"*) printf '%s\\n' '#{containers}' ;;",
      "  *\" up \"*) printf '%s' '#{up_stdout}'; exit #{up_exit} ;;",
      "esac",
      "exit 0",
      ""
    ].join("\n"))
    r = run_cli(%w[compose up -d], env: { "PORTLESS_STATE_DIR" => tmp, "PATH" => "#{bin}:#{ENV['PATH']}", "PORTLESS" => nil })
    { status: r.status, stdout: r.stdout, stderr: r.stderr, proxy_port: proxy.port }
  ensure
    stop_child(proxy.child) if proxy
    rm_tmp(tmp)
  end

  # An `expo` on PATH that records its argv and env in $PORTLESS_TEST_CAPTURE_FILE.
  def write_expo_shim(dir)
    capture_script = File.join(dir, "capture-expo.rb")
    File.write(capture_script, <<~'RUBY')
      require "json"
      keys = %w[PORT HOST PORTLESS_LAN PORTLESS_LAN_IP PORTLESS_URL]
      File.write(ENV["PORTLESS_TEST_CAPTURE_FILE"], JSON.generate(args: ARGV, env: keys.to_h { |k| [ k, ENV[k] ] }.compact))
    RUBY
    write_exe(File.join(dir, "expo"), "#!/bin/sh\n\"#{RbConfig.ruby}\" \"#{capture_script}\" \"$@\"\n")
  end

  def capture_bypassed_expo(args)
    shim_dir = tmpdir("portless-bypass-args-shim-")
    capture_path = File.join(shim_dir, "capture.json")
    write_expo_shim(shim_dir)
    r = run_cli(args, env: { "PATH" => "#{shim_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}", "PORTLESS" => "0",
                             "PORTLESS_TEST_CAPTURE_FILE" => capture_path })
    capture = JSON.parse(File.read(capture_path))
    { status: r.status, args: capture["args"], env: capture["env"] }
  ensure
    rm_tmp(shim_dir)
  end

  HOSTS_PRELOAD = File.expand_path("hosts_preload.rb", __dir__)

  # Upstream runWithHostsFileMock: the CLI with hosts_preload.rb loaded through
  # RUBYOPT (so a re-exec under the fake sudo inherits it, like NODE_OPTIONS),
  # never reading, writing or elevating against the real system files.
  def run_with_hosts_file_mock(args, content:, state_dir:, read_mode: "ok", write_mode: "ok", uid: 0, sudo_status: 1,
                               fail_privileged_cleanup: false, fail_ca_only: false, fail_ca_always: false,
                               sudo_runs_command: false, extra_env: {})
    shim_dir = tmpdir("portless-hosts-cli-shim-")
    capture_path = File.join(shim_dir, "hosts-capture.json")
    env = {
      "PORTLESS_STATE_DIR" => state_dir,
      "PORTLESS_TEST_HOSTS_CAPTURE" => capture_path,
      "PORTLESS_TEST_HOSTS_CONTENT" => content,
      "PORTLESS_TEST_HOSTS_READ_MODE" => read_mode,
      "PORTLESS_TEST_HOSTS_WRITE_MODE" => write_mode,
      "PORTLESS_TEST_HOSTS_UID" => uid.to_s,
      "PORTLESS_TEST_HOSTS_SUDO_STATUS" => sudo_status.to_s,
      "PORTLESS_TEST_FAIL_PRIVILEGED" => fail_privileged_cleanup ? "1" : "0",
      "PORTLESS_TEST_FAIL_CA_ONLY" => fail_ca_only ? "1" : "0",
      "PORTLESS_TEST_FAIL_CA_ALWAYS" => fail_ca_always ? "1" : "0",
      "PORTLESS_TEST_SUDO_RUNS" => sudo_runs_command ? "1" : "0"
    }.merge(extra_env)
    env["RUBYOPT"] = [ "-r#{HOSTS_PRELOAD}", ENV["RUBYOPT"] ].compact.join(" ")
    # Extra guard beyond upstream: startup-service tools refuse on PATH.
    guard = File.join(shim_dir, "guard-bin")
    Dir.mkdir(guard)
    %w[launchctl systemctl].each { |tool| write_exe(File.join(guard, tool), "#!/bin/sh\necho \"test guard: refusing #{tool}\" >&2\nexit 1\n") }
    env["PATH"] = [ guard, env.fetch("PATH", ENV["PATH"]) ].join(File::PATH_SEPARATOR)
    result = run_cli(args, env: env)
    capture = JSON.parse(File.read(capture_path))
    Struct.new(:status, :stdout, :stderr, :capture).new(result.status, result.stdout, result.stderr, capture)
  ensure
    rm_tmp(shim_dir)
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
end
