# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/core"
require "async"
require "socket"

# Mirror of packages/portless/src/utils.test.ts
module UtilsMirror
  include UpstreamCore

  def parse_hostname(...) = Portless::Utils.parse_hostname(...)
  def parse_hostnames(...) = Portless::Utils.parse_hostnames(...)
  def parse_port(value) = Portless::Utils.parse_port(value)
  def format_url(...) = Portless::Utils.format_url(...)
  def format_uptime(...) = Portless::Utils.format_uptime(...)
  def escape_html(text) = Portless::Pages.escape_html(text)
  def process_alive?(pid) = Portless::RouteStore.process_alive?(pid)

  # resolveUserHome({ platform, env, homedir, passwdHome })
  def resolve_user_home(platform:, env:, homedir:, passwd_home: ->(_) { nil })
    Portless::State.resolve_user_home(env: env, windows: platform == "win32", macos: platform == "darwin",
                                      homedir: homedir, passwd_home: passwd_home)
  end

  def assert_raises_message(expected, &block)
    error = assert_raises(Portless::Error, &block)
    expected.is_a?(Regexp) ? assert_match(expected, error.message) : assert_includes(error.message, expected)
  end

  # A stand-in for the net.Socket each loopback attempt creates: connect
  # blocks until the test settles it.
  class FakeSocket
    attr_reader :connected_to

    def initialize
      @outcome = Thread::Queue.new
      @closed = false
    end

    def connect(sockaddr)
      @connected_to = sockaddr
      result = @outcome.pop
      raise result if result.is_a?(Exception)

      0
    end

    def emit_connect = @outcome.push(:connect)
    def emit_error(error) = @outcome.push(error)
    def close = @closed = true
    def closed? = @closed
  end

  # Socket.new returns the two fakes in attempt order (IPv4, then IPv6).
  def mock_attempts
    sockets = [ FakeSocket.new, FakeSocket.new ]
    created = []
    queue = sockets.dup
    new_socket = lambda do |family, *rest|
      created << [ family, *rest ]
      queue.shift or raise "unexpected socket"
    end
    [ sockets, created, new_socket ]
  end

  def refused = Errno::ECONNREFUSED.new("connect")
end

describe "resolveUserHome" do
  include UtilsMirror

  it "uses the invoking user's home under sudo" do
    assert_equal "/home/alice", resolve_user_home(
      platform: "linux",
      env: { "SUDO_USER" => "alice", "HOME" => "/root" },
      homedir: "/root",
      passwd_home: ->(_) { "/home/alice" }
    )
  end

  it "keeps a preserved non-root home under sudo" do
    assert_equal "/Users/alice", resolve_user_home(
      platform: "darwin",
      env: { "SUDO_USER" => "alice", "HOME" => "/Users/alice" },
      homedir: "/var/root"
    )
  end

  it "uses the effective user's home without sudo" do
    assert_equal "/root", resolve_user_home(platform: "linux", env: { "HOME" => "/root" }, homedir: "/root")
  end

  it "falls back to the platform convention when passwd lookup fails" do
    assert_equal "/home/alice", resolve_user_home(
      platform: "linux",
      env: { "SUDO_USER" => "alice", "HOME" => "/root" },
      homedir: "/root",
      passwd_home: ->(_) { nil }
    )
  end
end

describe "escapeHtml" do
  include UtilsMirror

  it "escapes angle brackets" do
    assert_equal "&lt;script&gt;alert(1)&lt;/script&gt;", escape_html("<script>alert(1)</script>")
  end

  it "escapes ampersands" do
    assert_equal "foo &amp; bar", escape_html("foo & bar")
  end

  it "escapes quotes" do
    assert_equal "&quot;hello&quot; &amp; &#39;world&#39;", escape_html("\"hello\" & 'world'")
  end

  it "returns empty string unchanged" do
    assert_equal "", escape_html("")
  end

  it "leaves safe text unchanged" do
    assert_equal "hello world", escape_html("hello world")
  end
end

describe "isErrnoException" do
  ERRNO_GUARD_NODE_ONLY = "Node type guard for NodeJS.ErrnoException; Ruby system errors are SystemCallError " \
              "subclasses, so rb-portless has no equivalent helper"

  it("returns true for a Node.js system error") { skip ERRNO_GUARD_NODE_ONLY }
  it("returns false for a plain Error without code") { skip ERRNO_GUARD_NODE_ONLY }
  it("returns false for a string") { skip ERRNO_GUARD_NODE_ONLY }
  it("returns false for null") { skip ERRNO_GUARD_NODE_ONLY }
  it("returns false for undefined") { skip ERRNO_GUARD_NODE_ONLY }
  it("returns false for a plain object with code") { skip ERRNO_GUARD_NODE_ONLY }
  it("returns false for an Error with a non-string code") { skip ERRNO_GUARD_NODE_ONLY }
end

describe "isProcessAlive" do
  include UtilsMirror

  it "returns true when signal 0 succeeds" do
    Process.stub(:kill, ->(*) { 1 }) do
      assert_equal true, process_alive?(123)
    end
  end

  it "treats EPERM as an alive process" do
    Process.stub(:kill, ->(*) { raise Errno::EPERM, "permission denied" }) do
      assert_equal true, process_alive?(123)
    end
  end

  it "returns false when the process does not exist" do
    Process.stub(:kill, ->(*) { raise Errno::ESRCH, "missing" }) do
      assert_equal false, process_alive?(123)
    end
  end

  it "returns false for non-positive PIDs" do
    spy = spy { 1 }
    Process.stub(:kill, spy) do
      assert_equal false, process_alive?(0)
    end
    refute spy.called?
  end
end

describe "formatUrl" do
  include UtilsMirror

  it "omits port for standard HTTP port (80)" do
    assert_equal "http://myapp.localhost", format_url("myapp.localhost", 80)
  end

  it "includes port for non-standard ports" do
    assert_equal "http://myapp.localhost:1355", format_url("myapp.localhost", 1355)
    assert_equal "http://myapp.localhost:8080", format_url("myapp.localhost", 8080)
    assert_equal "http://myapp.localhost:3000", format_url("myapp.localhost", 3000)
  end
end

describe "formatUptime" do
  include UtilsMirror

  def now = 1_700_000_000_000

  it "a route registered %d ms ago shows %s" do
    [
      [ 59_000, "59s" ],
      [ 60_000, "1m" ],
      [ 59 * 60_000, "59m" ],
      [ 60 * 60_000, "1h" ],
      [ 119 * 60_000, "1h" ],
      [ 23 * 60 * 60_000, "23h" ],
      [ 24 * 60 * 60_000, "1d" ],
      [ 400 * 24 * 60 * 60_000, "400d" ]
    ].each do |age_ms, expected|
      assert_equal expected, format_uptime(now - age_ms, now)
    end
  end

  it "shows 0s for a registration time 30 seconds in the future" do
    assert_equal "0s", format_uptime(now + 30_000, now)
  end

  it "shows nothing for a registration time 2 minutes in the future" do
    assert_nil format_uptime(now + 120_000, now)
  end

  it "shows nothing for an invalid registration time %s" do
    [ nil, 0, -1000, Float::NAN, "1700000000000" ].each do |registered_at|
      assert_nil format_uptime(registered_at, now)
    end
  end
end

describe "parseHostname" do
  include UtilsMirror

  it "appends .localhost to simple name" do
    assert_equal "myapp.localhost", parse_hostname("myapp")
  end

  it "preserves existing .localhost suffix" do
    assert_equal "myapp.localhost", parse_hostname("myapp.localhost")
  end

  it "strips http:// protocol" do
    assert_equal "myapp.localhost", parse_hostname("http://myapp")
  end

  it "strips https:// protocol" do
    assert_equal "myapp.localhost", parse_hostname("https://myapp")
  end

  it "strips an uppercase or mixed-case protocol" do
    assert_equal "myapp.localhost", parse_hostname("HTTP://myapp.localhost")
    assert_equal "myapp.localhost", parse_hostname("HTTPS://myapp")
    assert_equal "myapp.localhost", parse_hostname("Https://MyApp/path")
  end

  it "strips path after hostname" do
    assert_equal "myapp.localhost", parse_hostname("myapp/some/path")
  end

  it "strips protocol and path" do
    assert_equal "myapp.localhost", parse_hostname("http://myapp.localhost/path")
  end

  it "converts to lowercase" do
    assert_equal "myapp.localhost", parse_hostname("MyApp")
  end

  it "handles subdomain-style names" do
    assert_equal "api.myapp.localhost", parse_hostname("api.myapp")
  end

  it "handles hyphens" do
    assert_equal "my-app.localhost", parse_hostname("my-app")
  end

  it "throws on empty input" do
    assert_raises_message("Hostname cannot be empty") { parse_hostname("") }
  end

  it "throws on whitespace-only input" do
    assert_raises_message("Hostname cannot be empty") { parse_hostname("   ") }
  end

  it "throws on invalid characters" do
    assert_raises_message("Invalid hostname") { parse_hostname("my app") }
  end

  it "throws on hostname starting with hyphen" do
    assert_raises_message("Invalid hostname") { parse_hostname("-myapp") }
  end

  it "throws on hostname ending with hyphen" do
    assert_raises_message("Invalid hostname") { parse_hostname("myapp-") }
  end

  it "throws on special characters" do
    assert_raises_message("Invalid hostname") { parse_hostname("my@app") }
  end

  it "throws on consecutive dots" do
    assert_raises_message("consecutive dots are not allowed") { parse_hostname("my..app") }
  end

  it "accepts numeric hostnames" do
    assert_equal "123.localhost", parse_hostname("123")
  end

  it "handles protocol with .localhost already present" do
    assert_equal "test.localhost", parse_hostname("https://test.localhost")
  end

  it "throws on label exceeding 63 characters" do
    long_label = "a" * 64
    assert_raises_message("exceeds 63-character DNS limit") { parse_hostname(long_label) }
  end

  it "accepts label at exactly 63 characters" do
    label63 = "a" * 63
    assert_equal "#{label63}.localhost", parse_hostname(label63)
  end

  it "throws when any label in multi-part hostname exceeds 63 characters" do
    long_label = "a" * 64
    assert_raises_message("exceeds 63-character DNS limit") { parse_hostname("prefix.#{long_label}") }
  end

  describe "custom TLD" do
    it "appends custom TLD suffix" do
      assert_equal "myapp.test", parse_hostname("myapp", "test")
    end

    it "preserves existing custom TLD suffix" do
      assert_equal "myapp.test", parse_hostname("myapp.test", "test")
    end

    it "strips .localhost suffix when using a different TLD" do
      assert_equal "myapp.test", parse_hostname("myapp.localhost", "test")
    end

    it "strips .localhost subdomain suffix when using a different TLD" do
      assert_equal "api.myapp.test", parse_hostname("api.myapp.localhost", "test")
    end

    it "handles subdomain with custom TLD" do
      assert_equal "api.myapp.test", parse_hostname("api.myapp", "test")
    end

    it "handles multi-segment custom TLDs" do
      assert_equal "myapp.local.example.dev", parse_hostname("myapp", "local.example.dev")
      assert_equal "api.myapp.local.example.dev", parse_hostname("api.myapp", "local.example.dev")
      assert_equal "myapp.local.example.dev", parse_hostname("myapp.local.example.dev", "local.example.dev")
    end

    it "rejects a final hostname over 253 characters" do
      label = "a" * 63
      tld = [ label, label, label, "b" * 60 ].join(".")
      assert_raises_message("exceeds 253-character DNS limit") { parse_hostname("myapp", tld) }
    end

    it "throws on empty input with custom TLD" do
      assert_raises_message("Hostname cannot be empty") { parse_hostname("", "test") }
    end

    it "throws on bare TLD suffix" do
      assert_raises_message("Hostname cannot be empty") { parse_hostname(".test", "test") }
    end

    it "validates characters with custom TLD" do
      assert_raises_message("Invalid hostname") { parse_hostname("my app", "test") }
    end

    it "works with dev TLD" do
      assert_equal "myapp.dev", parse_hostname("myapp", "dev")
    end
  end
end

describe "parseHostnames" do
  include UtilsMirror

  it "builds one hostname per TLD" do
    assert_equal [ "myapp.localhost", "myapp.test" ], parse_hostnames("myapp", [ "localhost", "test" ])
  end

  it "strips an active TLD before building all hostnames" do
    assert_equal [ "api.myapp.localhost", "api.myapp.test" ], parse_hostnames("api.myapp.test", [ "localhost", "test" ])
  end

  it "strips a configured TLD before expanding only the selected TLDs" do
    assert_equal [ "api.myapp.localhost" ], parse_hostnames("api.myapp.test", [ "localhost", "test" ], [ "localhost" ])
    assert_raises(Portless::Error) { parse_hostnames("api.myapp.test", [ "localhost", "test" ], [ "dev" ]) }
  end

  it "strips the longest matching TLD when configured TLDs overlap" do
    assert_equal [ "app.example.com", "app.dev.example.com" ],
                 parse_hostnames("app.dev.example.com", [ "example.com", "dev.example.com" ])
  end

  it "strips an uppercase protocol before building hostnames" do
    assert_equal [ "myapp.localhost", "myapp.test" ], parse_hostnames("HTTPS://myapp.test", [ "localhost", "test" ])
  end

  it "deduplicates TLDs" do
    assert_equal [ "myapp.test" ], parse_hostnames("myapp", [ "test", "test" ])
  end

  it "skips a TLD that pushes the hostname past 253 chars and keeps the rest" do
    label = "a" * 62
    long_tld = [ label, label, label, label ].join(".") # 251 chars, valid TLD
    result = nil
    _, err = capture_io { result = parse_hostnames("myapp", [ "localhost", long_tld ]) }
    assert_equal [ "myapp.localhost" ], result
    assert_includes err, long_tld
  end

  it "still throws when no TLD survives" do
    assert_raises_message(/consecutive dots/) { parse_hostnames("my..app", [ "localhost", "test" ]) }
  end
end

describe "parsePort" do
  include UtilsMirror

  it "accepts whole numbers from 1 to 65535" do
    assert_equal 1, parse_port("1")
    assert_equal 8123, parse_port("8123")
    assert_equal 65_535, parse_port("65535")
    assert_equal 3000, parse_port(" 3000 ")
  end

  it "rejects out of range and malformed values" do
    [ "", "0", "65536", "192.168.1.1:8123", "8123abc", "81.23", "1e3", "30 00", "3000abc", "-1" ].each do |value|
      assert_nil parse_port(value)
    end
  end
end

# rb-portless's createLoopbackConnection (Proxy.create_loopback_connection)
# runs inside the proxy's Async reactor: it returns the winning socket or
# raises, and the caller cancels it by stopping its task. Node's callback,
# microtask deferral and socket events have no Ruby counterpart; the race
# itself is exercised with fake sockets.
describe "createLoopbackConnection" do
  include UtilsMirror

  it "waits for pending IPv4 despite refused IPv6 and elapsed time" do
    sockets, created, new_socket = mock_attempts
    Socket.stub(:new, new_socket) do
      Sync do |task|
        attempt = task.async { Portless::Proxy.create_loopback_connection(1234) }
        sleep 0.01
        assert_equal [ [ Socket::AF_INET, Socket::SOCK_STREAM, 0 ], [ Socket::AF_INET6, Socket::SOCK_STREAM, 0 ] ],
                     created
        assert_equal Socket.pack_sockaddr_in(1234, "127.0.0.1"), sockets[0].connected_to
        assert_equal Socket.pack_sockaddr_in(1234, "::1"), sockets[1].connected_to
        sockets[1].emit_error(refused)
        sleep 0.2 # no timer of its own gives up on the pending IPv4 attempt
        refute attempt.finished?
        assert_equal false, sockets[0].closed?
        sockets[0].emit_connect
        assert_same sockets[0], attempt.wait
        assert_equal true, sockets[1].closed?
        assert_equal false, sockets[0].closed?
      end
    end
  end

  it "preserves both family failures in an AggregateError" do
    sockets, _created, new_socket = mock_attempts
    Socket.stub(:new, new_socket) do
      Sync do |task|
        attempt = task.async do
          Portless::Proxy.create_loopback_connection(1234)
        rescue Portless::Proxy::AggregateError => e
          e
        end
        errors = [ refused, refused ]
        sockets[1].emit_error(errors[1])
        sleep 0.01
        refute attempt.finished?
        sockets[0].emit_error(errors[0])
        error = attempt.wait
        assert_kind_of Portless::Proxy::AggregateError, error
        assert_equal errors, error.errors
        assert_kind_of Errno::ECONNREFUSED, error.errors.first
        assert(sockets.all?(&:closed?))
      end
    end
  end

  it "hands off winner %s synchronously and ignores late loser events" do
    [ 0, 1 ].each do |winner|
      sockets, _created, new_socket = mock_attempts
      Socket.stub(:new, new_socket) do
        Sync do |task|
          attempt = task.async { Portless::Proxy.create_loopback_connection(1234) }
          loser = sockets[1 - winner]
          sockets[winner].emit_connect
          assert_same sockets[winner], attempt.wait
          assert_equal true, loser.closed?
          loser.emit_connect
          loser.emit_error(StandardError.new("late failure"))
          assert_equal false, sockets[winner].closed?
        end
      end
    end
  end

  it "counts a close before connect as a family failure" do
    skip "Node emits 'close' on a socket that never connected; a Ruby connect either returns or raises"
  end

  it "cancels before startup without launching sockets" do
    skip "Node defers the attempts to a microtask and returns a cancel function; the Ruby call starts " \
         "connecting immediately and is cancelled by stopping its task"
  end

  it "cancels both pending attempts and ignores late events" do
    sockets, _created, new_socket = mock_attempts
    Socket.stub(:new, new_socket) do
      Sync do |task|
        attempt = task.async { Portless::Proxy.create_loopback_connection(1234) }
        sleep 0.01
        attempt.stop
        attempt.stop
        assert(sockets.all?(&:closed?))
        sockets.each do |socket|
          socket.emit_error(StandardError.new("late failure"))
          socket.emit_connect
        end
        assert_nil attempt.wait
      end
    end
  end

  it "connects to %s despite a 2.6-second event-loop stall" do
    [ "127.0.0.1", "::1" ].each do |host|
      begin
        server = TCPServer.new(host, 0)
      rescue SystemCallError
        raise if host != "::1"

        next # no IPv6 loopback here
      end
      port = server.addr[1]
      acceptor = Thread.new do
        client = server.accept
        client.write("connected")
        client.close
      rescue StandardError
        nil
      end
      socket = nil
      begin
        data = Sync do |task|
          attempt = task.async { Portless::Proxy.create_loopback_connection(port) }
          Fiber.blocking { sleep 2.6 }
          socket = attempt.wait
          socket.read
        end
        assert_equal "connected", data
      ensure
        socket&.close
        server.close
        acceptor.join(1)
      end
    end
  end
end
