# frozen_string_literal: true

require "test_helper"

# The foreground server loop (cli.ts startProxyServer) with a stand-in Proxy:
# markers are written once listening and reset on shutdown, routes reload on
# file changes, and the hosts-sync hook honours PORTLESS_SYNC_HOSTS.
class DaemonServerTest < Minitest::Test
  D = Portless::Daemon

  class FakeProxy
    class << self
      attr_accessor :last
    end
    attr_reader :opts

    def initialize(**opts)
      @opts = opts
      @stopped = Queue.new
      self.class.last = self
    end

    def run
      @opts[:on_listening].call
      @stopped.pop
    end

    def stop = @stopped << true
  end

  Route = Struct.new(:hostname, :port, :pid, keyword_init: true)

  class FakeStore
    attr_reader :dir

    def initialize(dir) = @dir = dir
    def ensure_dir = FileUtils.mkdir_p(@dir)
    def routes_path = File.join(@dir, "routes.json")
    def route_owner_alive?(_route) = true

    def load_trusted_routes
      JSON.parse(File.read(routes_path)).map { |r| Route.new(hostname: r["hostname"], port: r["port"], pid: r["pid"]) }
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @env = ENV.to_h
    ENV["PORTLESS_STATE_DIR"] = @dir
    @synced = []
    synced = @synced
    @hosts_stubs = {
      should_auto_sync?: ->(v) { v != "0" && v != "false" },
      sync_hosts_file: ->(names) { synced << names; true },
      clean_hosts_file: -> { synced << :clean; true }
    }
  end

  def teardown
    ENV.replace(@env)
    FileUtils.rm_rf(@dir)
  end

  def with_stubs(&block)
    stubs = @hosts_stubs.dup
    run = lambda do
      Portless.send(:remove_const, :Proxy) if Portless.const_defined?(:Proxy, false)
      Portless.const_set(:Proxy, FakeProxy)
      block.call
    end
    nest = stubs.reduce(run) do |inner, (name, impl)|
      lambda do
        Portless::Hosts.singleton_class.send(:alias_method, :"__orig_#{name}", name) if Portless::Hosts.respond_to?(name)
        Portless::Hosts.define_singleton_method(name, &impl)
        inner.call
      ensure
        if Portless::Hosts.respond_to?(:"__orig_#{name}")
          Portless::Hosts.singleton_class.send(:alias_method, name, :"__orig_#{name}")
        else
          Portless::Hosts.singleton_class.send(:remove_method, name)
        end
      end
    end
    original = Portless::Proxy
    nest.call
  ensure
    Portless.send(:remove_const, :Proxy)
    Portless.const_set(:Proxy, original)
  end

  def run_server(tlds: [ "test" ], unprivileged: false, &block)
    store = FakeStore.new(@dir)
    File.write(store.routes_path, JSON.generate([ { hostname: "app.test", port: 4001, pid: 0 } ]))
    with_stubs do
      thread = Thread.new do
        capture_io { D.start_proxy_server(store, 1355, tlds.first, tlds, nil, nil, false, false, unprivileged) }
      end
      sleep 0.05 until FakeProxy.last&.opts && File.exist?(File.join(@dir, "proxy.pid"))
      block.call(FakeProxy.last)
      FakeProxy.last.stop
      thread.join(5)
    end
  ensure
    FakeProxy.last = nil
  end

  def test_writes_markers_while_listening_and_resets_them_on_exit
    run_server(tlds: %w[test localhost]) do |proxy|
      assert_equal Process.pid.to_s, File.read(File.join(@dir, "proxy.pid"))
      assert_equal "1355", File.read(File.join(@dir, "proxy.port"))
      assert_equal "test\nlocalhost\n", File.read(File.join(@dir, "proxy.tlds"))
      assert Portless::HostsSyncAuth.read_token(@dir)
      assert_equal Portless::HostsSyncAuth.read_token(@dir), proxy.opts[:hosts_sync_token]
      refute proxy.opts[:strict], "wildcard mode passes strict: false"
      assert_equal [ "app.test" ], proxy.opts[:routes].call.map(&:hostname)
    end
    %w[proxy.pid proxy.port proxy.tlds proxy.hosts-sync-token proxy.start].each do |f|
      refute File.exist?(File.join(@dir, f)), f
    end
    assert_equal :clean, @synced.last
  end

  def test_reloads_routes_and_syncs_hosts_on_change
    run_server do |proxy|
      assert_equal [ [ "app.test" ] ], @synced
      File.write(File.join(@dir, "routes.json"),
                 JSON.generate([ { hostname: "app.test", port: 4001, pid: 0 }, { hostname: "api.test", port: 4002, pid: 0 } ]))
      deadline = Time.now + 3
      sleep 0.05 until proxy.opts[:routes].call.size == 2 || Time.now > deadline
      assert_equal %w[app.test api.test], proxy.opts[:routes].call.map(&:hostname)
      assert_includes @synced, %w[app.test api.test]
      assert_equal :acted, proxy.opts[:on_hosts_sync_request].call
    end
  end

  def test_unprivileged_never_syncs_hosts_and_is_loopback_only
    run_server(unprivileged: true) do |proxy|
      assert proxy.opts[:loopback_only]
      assert proxy.opts[:lan_bind], "binds the wildcard address to get the port"
      assert_equal :disabled, proxy.opts[:on_hosts_sync_request].call
      assert File.exist?(File.join(@dir, "proxy.unprivileged"))
    end
    assert_empty @synced
  end
end
