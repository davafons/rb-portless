# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/proxy"
require "minitest/mock"

# Mirror of packages/portless/src/proxy-upstream.test.ts
#
# Dials are delayed so the proxy has many in flight at once, which is what a
# cold HTTP/2 page load does to a dev server's accept backlog. Upstream mocks
# createLoopbackConnection; here Portless::Proxy.create_loopback_connection is
# stubbed with the same bookkeeping.
describe "upstream dialing" do
  include ProxyTestSupport

  Dials = Struct.new(:pending, :max_pending, :delay, :stalled, :cancelled) # rubocop:disable Lint/ConstantDefinitionInBlock

  before do
    @dials = Dials.new(0, 0, 0, false, 0)
    @dials_lock = Mutex.new
    dials = @dials
    lock = @dials_lock
    fake = lambda do |port|
      lock.synchronize do
        dials.pending += 1
        dials.max_pending = [ dials.max_pending, dials.pending ].max
      end
      settled = false
      begin
        sleep dials.delay if dials.delay.positive?
        sleep if dials.stalled # a stalled dial never connects; only a cancel ends it
        socket = Socket.tcp("127.0.0.1", port)
        settled = true
        socket
      rescue Exception # rubocop:disable Lint/RescueException
        lock.synchronize { dials.cancelled += 1 } unless settled
        raise
      ensure
        lock.synchronize { dials.pending -= 1 }
      end
    end
    @stub_original = Portless::Proxy.method(:create_loopback_connection)
    Portless::Proxy.singleton_class.send(:define_method, :create_loopback_connection, &fake)
  end

  after do
    original = @stub_original
    Portless::Proxy.singleton_class.send(:define_method, :create_loopback_connection) { |port| original.call(port) }
  end

  def dials = @dials

  def get_status(port, keep_alive: nil)
    conn = keep_alive || Net::HTTP.new("127.0.0.1", port)
    conn.read_timeout = 10
    req = Net::HTTP::Get.new("/")
    req["host"] = "myapp.localhost"
    res = keep_alive ? conn.request(req) : conn.start { |c| c.request(req) }
    res.code.to_i
  end

  it "limits dials in progress and reuses sockets for a burst (issue #370)" do
    dials.pending = 0
    dials.max_pending = 0
    dials.delay = 0.02

    backend = listen_backend { [ 200, {}, [ "ok" ] ] }
    routes = [ route("myapp.localhost", backend.port) ]
    proxy_port = start_proxy(routes)

    statuses = Array.new(100) do
      Thread.new do
        conn = Net::HTTP.new("127.0.0.1", proxy_port)
        conn.start
        get_status(proxy_port, keep_alive: conn)
      ensure
        conn.finish rescue nil
      end
    end.map(&:value)

    assert_equal [], statuses.reject { |status| status == 200 }
    assert_operator dials.max_pending, :<=, 8
    assert_operator backend.connections, :<, 100
  end

  it "releases failed dial slots so queued requests receive an answer" do
    backend = TCPServer.new("127.0.0.1", 0)
    backend_port = backend.addr[1]
    backend.close
    proxy_port = start_proxy([ route("myapp.localhost", backend_port) ])
    statuses = Array.new(24) { Thread.new { get_status(proxy_port) } }.map(&:value)
    assert_equal Array.new(24, 502), statuses
    assert_equal 0, dials.pending
    assert_operator dials.max_pending, :<=, 8
  end

  it "cancels disconnected clients and lets a queued request dial" do
    dials.stalled = true
    backend = listen_backend { [ 200, {}, [ "ok" ] ] }
    proxy_port = start_proxy([ route("myapp.localhost", backend.port) ])
    clients = Array.new(8) do
      socket = TCPSocket.new("127.0.0.1", proxy_port)
      socket.write("GET / HTTP/1.1\r\nhost: myapp.localhost\r\nconnection: close\r\n\r\n")
      socket
    end
    assert wait_until { dials.pending == 8 }
    response = Thread.new do
      conn = Net::HTTP.new("127.0.0.1", proxy_port)
      conn.read_timeout = 10
      req = Net::HTTP::Get.new("/")
      req["host"] = "myapp.localhost"
      conn.start { |c| c.request(req) }.body
    end
    sleep 0.05
    dials.stalled = false
    clients.each(&:close)
    assert_equal "ok", response.value
    assert wait_until { dials.pending.zero? }
    assert_equal 8, dials.cancelled
    assert_equal 8, dials.max_pending
    assert_empty proxy_errors
  end

  it "cancels pending upstream dials when the proxy closes" do
    dials.stalled = true
    running = ProxyTestSupport::RunningProxy.new(routes: [ route("myapp.localhost", 19_877) ])
    on_cleanup { running.close }
    proxy_port = running.listen_port
    # Send all nine requests first, as Node's http.get has before vi.waitFor
    # yields; a thread still connecting when the proxy closes would see a
    # different error than the reset.
    sockets = Array.new(9) do
      TCPSocket.new("127.0.0.1", proxy_port).tap do |s|
        s.write("GET / HTTP/1.1\r\nhost: myapp.localhost\r\nconnection: close\r\n\r\n")
      end
    end
    on_cleanup { sockets.each { |s| s.close rescue nil } }
    responses = sockets.map do |socket|
      Thread.new do
        line = socket.gets
        raise EOFError if line.nil?

        line.split[1].to_i
      rescue Errno::ECONNRESET, EOFError
        "ECONNRESET"
      end
    end
    assert wait_until { dials.pending == 8 }
    closed = Thread.new { running.close }
    statuses = responses.map(&:value)
    assert_equal 8, statuses.count(502)
    assert_equal 1, statuses.count("ECONNRESET")
    closed.join
    assert_equal 0, dials.pending
    assert_equal 8, dials.cancelled
  end

  it "can listen again after closing" do
    backend = listen_backend { [ 200, {}, [ "ok" ] ] }
    proxy = Portless::Proxy.new(port: 1355, routes: -> { [ route("myapp.localhost", backend.port) ] },
                                bind_targets: [ { host: "127.0.0.1" } ], loopback_only: true)
    2.times do
      ready = Thread::Queue.new
      proxy.instance_variable_set(:@on_listening, -> { ready << :ok })
      thread = Thread.new { proxy.run(0) }
      ready.pop(timeout: 5)
      status = get_status(proxy.listen_port)
      assert_equal 200, status
      proxy.stop
      thread.join(5)
    end
  end
end
