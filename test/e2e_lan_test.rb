# frozen_string_literal: true

require_relative "e2e_helper"

# LAN mode end-to-end against a *real* off-loopback client: a second proxy
# daemon started with --lan, reached over this machine's own LAN IP. Only
# routes that opted in (`run --lan`) may answer; everything else 404s without
# naming the other apps.
class E2ELanTest < Minitest::Test
  SHARED = "e2elan-shared.localhost"
  PRIVATE = "e2elan-private.localhost"

  def setup
    @ip = Portless::LanIp.detect(nil)
    skip "no LAN IPv4 on this machine" unless @ip

    @state = Dir.mktmpdir
    @port = E2E.free_port
    @backend = E2E.backend_port # the shared harness echo backend
    boot_lan_proxy
    store = Portless::RouteStore.new(file: File.join(@state, "routes.json"),
                                     lock: File.join(@state, "routes.lock"))
    store.add(hostname: SHARED, port: @backend, pid: Process.pid, lan: true)
    store.add(hostname: PRIVATE, port: @backend, pid: Process.pid)
  end

  def teardown
    if @pid
      begin
        Process.kill("TERM", @pid)
        Process.wait(@pid)
      rescue StandardError
        nil
      end
    end
    FileUtils.remove_entry(@state) if @state
  end

  def test_lan_client_reaches_only_the_shared_app
    assert_equal "200", lan_get(SHARED).code, "an app run with --lan must serve LAN clients"

    res = lan_get(PRIVATE)
    assert_equal "404", res.code, "an app WITHOUT --lan must not answer LAN clients"
    refute_includes res.body, SHARED, "the 404 must not name the other running apps"
  end

  def test_loopback_client_still_reaches_everything
    assert_equal "200", loopback_get(SHARED).code
    assert_equal "200", loopback_get(PRIVATE).code, "loopback access must be unrestricted"
  end

  private

  # Requests that genuinely arrive over the network interface, not loopback.
  def lan_get(host) = fetch(host, @ip)
  def loopback_get(host) = fetch(host, "127.0.0.1")

  def fetch(host, ip)
    http = Net::HTTP.new(host, @port)
    http.ipaddr = ip
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE # this daemon has its own CA
    http.open_timeout = 5
    http.read_timeout = 5
    http.start { |conn| conn.get("/") }
  end

  def boot_lan_proxy
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    log = File.join(@state, "proxy.log")
    @pid = Process.spawn(
      { "PORTLESS_STATE_DIR" => @state },
      RbConfig.ruby, "-I", lib, exe,
      "proxy", "start", "--foreground", "--port", @port.to_s, "--tls", "--lan",
      out: log, err: log
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until port_open?
      raise "LAN proxy did not boot:\n#{File.read(log)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def port_open?
    Socket.tcp(@ip, @port, connect_timeout: 0.5, &:close)
    true
  rescue StandardError
    false
  end
end
