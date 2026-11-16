# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/core"
require "json"
require "open3"
require "rbconfig"

# Mirror of packages/portless/src/routes.test.ts
#
# RouteStore returns Route structs; `to_h` gives the on-disk (camelCase,
# string-keyed) RouteMapping that upstream's assertions compare against.
module RoutesMirror
  include UpstreamCore

  LIB_DIR = File.expand_path("../../lib", __dir__)

  def self.included(base)
    base.class_eval do
      before do
        @tmp_dir = mkdtemp("portless-routes-test-")
        @store = Portless::RouteStore.new(@tmp_dir)
      end

      after { FileUtils.rm_rf(@tmp_dir) }
    end
  end

  attr_reader :store

  def hashes(routes) = routes.map(&:to_h)
  def write_json(path, value) = File.write(path, JSON.generate(value))
  def read_json(path) = JSON.parse(File.read(path, encoding: "utf-8"))

  def assert_array_containing(expected, actual)
    expected.each { |entry| assert_includes actual, entry }
  end

  def spawn_sleeper
    pid = Process.spawn("sleep", "60", pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    pid
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue StandardError
    false
  end

  def kill_quietly(pid)
    Process.kill("TERM", pid)
  rescue StandardError
    nil # already dead
  end

  # Process.kill stand-in: `impl` gets (signal, pid) and the real method.
  def with_kill(impl, &block)
    real_kill = Process.method(:kill)
    Process.stub(:kill, ->(signal, *pids) { impl.call(signal, pids.first, real_kill) }, &block)
  end
end

describe "RouteStore" do
  include RoutesMirror

  describe "ensureDir" do
    it "creates directory if it does not exist" do
      nested = File.join(@tmp_dir, "sub", "dir")
      s = Portless::RouteStore.new(nested)
      s.ensure_dir
      assert_equal true, File.exist?(nested)
    end

    it "does not throw if directory already exists" do
      store.ensure_dir
      store.ensure_dir
    end

    it "keeps the directory owner-writable only under a group-writable umask" do
      previous = File.umask(0o002)
      begin
        created = File.join(@tmp_dir, "umask")
        Portless::RouteStore.new(created).ensure_dir
        assert_equal 0o755, File.stat(created).mode & 0o777
      ensure
        File.umask(previous)
      end
    end

    it "refuses a route write in a directory other users can write to and leaves it unchanged" do
      writable = File.join(@tmp_dir, "writable")
      Dir.mkdir(writable)
      File.chmod(0o777, writable)
      writable_store = Portless::RouteStore.new(writable)
      error = assert_raises(Portless::Error) { writable_store.add_route(hostname: "app.localhost", port: 4000, pid: Process.pid) }
      assert_includes error.message, "Cannot use state directory"
      assert_equal 0o777, File.stat(writable).mode & 0o777
      assert_includes writable_store.untrusted_reason, "other users can write to it"
      assert_equal false, File.exist?(writable_store.routes_path)
    end

    it "follows a symlink only another user could not have planted" do
      real = File.join(@tmp_dir, "real")
      Dir.mkdir(real, 0o700)
      link = File.join(@tmp_dir, "link")
      File.symlink(real, link)
      assert_nil Portless::State.ensure_state_dir(link)
      assert_equal 0o755, File.stat(real).mode & 0o777
    end

    %w[directory file].each do |kind|
      it "never changes the mode of a #{kind} behind a symlink in a shared directory" do
        target = File.join(@tmp_dir, "protected")
        if kind == "directory"
          Dir.mkdir(target, 0o700)
        else
          File.write(target, "secret", perm: 0o600)
        end
        shared = File.join(@tmp_dir, "shared")
        Dir.mkdir(shared)
        File.chmod(0o777, shared)
        link = File.join(shared, "state")
        File.symlink(target, link)

        assert_includes Portless::State.ensure_state_dir(link), "other users can redirect it through"
        assert_equal(kind == "directory" ? 0o700 : 0o600, File.stat(target).mode & 0o777)
      end
    end
  end

  describe "loadRoutes" do
    it "refuses trusted route loading from a directory other users can write to" do
      store.add_route(hostname: "app.localhost", port: 4000, pid: Process.pid)
      File.chmod(0o777, @tmp_dir)
      begin
        error = assert_raises(Portless::Error) { store.load_trusted_routes }
        assert_includes error.message, "Cannot use state directory"
      ensure
        File.chmod(0o755, @tmp_dir)
      end
      routes = store.load_trusted_routes
      assert_equal 1, routes.size
      assert_equal [ "app.localhost", 4000 ], [ routes[0].hostname, routes[0].port ]
    end

    it "returns empty array when routes file does not exist" do
      assert_equal [], store.load_routes
    end

    it "throws for invalid JSON instead of returning an empty table" do
      store.ensure_dir
      File.write(store.routes_path, "not json")
      assert_raises(Portless::RoutesFileError) { store.load_routes }
      assert_match(/invalid JSON/, assert_raises(Portless::RoutesFileError) { store.load_routes }.message)
    end

    it "leaves a corrupt routes file in place" do
      store.ensure_dir
      File.write(store.routes_path, "not json")
      assert_match(/invalid JSON/, assert_raises(Portless::RoutesFileError) { store.load_routes }.message)
      assert_equal "not json", File.read(store.routes_path, encoding: "utf-8")
    end

    it "throws when the routes file is not an array" do
      store.ensure_dir
      write_json(store.routes_path, { not: "array" })
      assert_match(/expected array/, assert_raises(Portless::RoutesFileError) { store.load_routes }.message)
    end

    it "moves a corrupt routes file aside for a write path" do
      store.ensure_dir
      File.write(store.routes_path, "not json")
      assert_equal true, store.recover_corrupt_routes_file
      assert_equal [], store.load_routes
      backup = Dir.children(@tmp_dir).find { |name| name.start_with?("routes.json.corrupt-") }
      refute_nil backup
      assert_equal "not json", File.read(File.join(@tmp_dir, backup), encoding: "utf-8")
    end

    it "leaves a valid routes file alone when recovering" do
      store.ensure_dir
      File.write(store.routes_path, "[]")
      assert_equal false, store.recover_corrupt_routes_file
      assert_equal [], store.load_routes
    end

    it "filters out entries with invalid schema" do
      store.ensure_dir
      routes = [
        { hostname: "valid.localhost", port: 4001, pid: Process.pid },
        { hostname: "missing-port.localhost", pid: Process.pid },
        { hostname: 123, port: 4002, pid: Process.pid },
        "not an object",
        nil
      ]
      write_json(store.routes_path, routes)
      loaded = store.load_routes
      assert_equal 1, loaded.size
      assert_equal "valid.localhost", loaded[0].hostname
    end

    it "rejects malformed or unknown upstream fields while retaining valid routes" do
      valid = { "hostname" => "valid.localhost", "port" => 4001, "pid" => 0 }
      upstreams = [
        nil,
        [],
        "https",
        { "tls" => "true" },
        { "host" => 123 },
        { "host" => "" },
        { "host" => "api.internal:0" },
        { "host" => "api.internal:65536" },
        { "host" => "api.internal:000001" },
        { "host" => "256.1.1.1" },
        { "host" => "127.0.0" },
        { "host" => "127.00.0.1" },
        { "host" => "user@api.internal" },
        { "host" => "api.internal/path" },
        { "host" => "[not-ipv6]" },
        { "tls" => true, "extra" => 1 }
      ]
      routes = [
        valid,
        valid.merge("hostname" => "tls.localhost", "upstream" => { "tls" => true, "host" => "api.internal:8443" }),
        *upstreams.each_with_index.map do |upstream, index|
          valid.merge("hostname" => "invalid#{index}.localhost", "upstream" => upstream)
        end
      ]
      store.ensure_dir
      write_json(store.routes_path, routes)
      assert_equal routes[0, 2], hashes(store.load_routes)
    end

    it "loads routes from file" do
      routes = [ { hostname: "app.localhost", port: 4001, pid: Process.pid } ]
      store.ensure_dir
      write_json(store.routes_path, routes)
      loaded = store.load_routes
      assert_equal 1, loaded.size
      assert_equal "app.localhost", loaded[0].hostname
      assert_equal 4001, loaded[0].port
    end

    it "filters out routes with dead PIDs" do
      # Use a PID that is guaranteed not to exist
      dead_pid = 999_999
      routes = [
        { hostname: "alive.localhost", port: 4001, pid: Process.pid },
        { hostname: "dead.localhost", port: 4002, pid: dead_pid }
      ]
      store.ensure_dir
      write_json(store.routes_path, routes)
      loaded = store.load_routes
      assert_equal 1, loaded.size
      assert_equal "alive.localhost", loaded[0].hostname
    end

    it "does not drop stale entries from disk when loading routes" do
      dead_pid = 999_999
      routes = [
        { hostname: "alive.localhost", port: 4001, pid: Process.pid },
        { hostname: "dead.localhost", port: 4002, pid: dead_pid }
      ]
      store.ensure_dir
      write_json(store.routes_path, routes)
      store.load_routes

      # Re-read the file directly; stale entries should still be on disk
      raw = read_json(store.routes_path)
      assert_equal 2, raw.size
    end

    it "keeps routes whose process exists but cannot be signaled (EPERM)" do
      denied_pid = 999_998
      kill = lambda do |signal, pid, real_kill|
        raise Errno::EPERM, "kill" if pid == denied_pid

        real_kill.call(signal, pid)
      end
      with_kill(kill) do
        routes = [ { hostname: "denied.localhost", port: 4001, pid: denied_pid } ]
        store.ensure_dir
        write_json(store.routes_path, routes)

        assert_equal [ "denied.localhost" ], store.load_routes.map(&:hostname)
        raw = read_json(store.routes_path)
        assert_equal 1, raw.size
        assert_raises(Portless::RouteConflictError) do
          store.add_route(hostname: "denied.localhost", port: 4002, pid: Process.pid)
        end
      end
    end
  end

  describe "unsupported stored routes" do
    def unsupported
      { "hostname" => "future.localhost", "port" => 4001, "pid" => 0,
        "upstream" => { "tls" => true, "futureOption" => { "value" => 1 } }, "extra" => "preserve" }
    end

    def malformed = { "hostname" => "malformed.localhost", "port" => 4002, "pid" => 0, "upstream" => nil }
    def incomplete = { "hostname" => "incomplete.localhost", "upstream" => { "tls" => true } }
    def alias_route = { "hostname" => "alias.localhost", "port" => 4003, "pid" => 0 }
    def owned = { "hostname" => "owned.localhost", "port" => 4004, "pid" => Process.pid }
    def stale = { "hostname" => "stale.localhost", "port" => 4005, "pid" => 999_999 }

    def seed
      write_json(store.routes_path, [ unsupported, malformed, incomplete, alias_route, owned, stale ])
    end

    def disk = read_json(store.routes_path)

    it "preserves skipped entries while adding, updating, transferring and removing valid routes" do
      seed
      assert_equal [ alias_route, owned ], hashes(store.load_routes)
      assert_equal [ alias_route, owned, stale ], hashes(store.load_routes_raw)

      store.add_route(hostname: "new.localhost", port: 4006, pid: 0, force: false, upstream: { tls: true })
      assert_array_containing [ unsupported, malformed, incomplete, alias_route, owned ], disk
      refute_includes disk, stale
      store.update_route("owned.localhost", { ngrokUrl: "https://example.test" })
      assert_includes disk, owned.merge("ngrokUrl" => "https://example.test")
      assert_equal true, store.transfer_route("owned.localhost", Process.pid, Process.ppid)
      store.remove_route("alias.localhost", owner_pid: 0)

      assert_array_containing [ unsupported, malformed, incomplete ], disk
      refute_includes disk, alias_route
      loaded = store.load_routes
      assert(loaded.any? { |r| r.hostname == "new.localhost" && r.upstream == { tls: true } })
      assert(loaded.any? { |r| r.hostname == "owned.localhost" && r.pid == Process.ppid })
      refute_includes store.load_routes.map(&:hostname), "future.localhost"
    end

    it "prunes dead supported routes without removing skipped entries" do
      seed
      dead = store.find_stale_routes
      assert_equal [ stale ], hashes(dead)
      assert_equal true, store.remove_stale_route(dead[0].hostname, dead[0].pid)
      assert_array_containing [ unsupported, malformed, incomplete, alias_route, owned ], disk
      refute_includes disk, stale
    end

    it "requires force to replace a skipped hostname" do
      [ unsupported, malformed, incomplete ].each do |entry|
        seed
        error = assert_raises(Portless::Error) { store.add_route(hostname: entry["hostname"], port: 4444, pid: 0) }
        assert_includes error.message, "has an invalid or unsupported stored route. Use --force to replace it."
        assert_includes disk, entry
        store.add_route(hostname: entry["hostname"], port: 4444, pid: 0, force: true)
        matching = disk.select { |route| route.is_a?(Hash) && route["hostname"] == entry["hostname"] }
        assert_equal 1, matching.size
        assert_equal({ "hostname" => entry["hostname"], "port" => 4444, "pid" => 0 },
                     matching[0].slice("hostname", "port", "pid"))
        refute matching[0].key?("upstream")
      end
    end

    it "continues to reject invalid new upstreams without changing the file" do
      seed
      error = assert_raises(Portless::Error) do
        store.add_route(hostname: "new.localhost", port: 4444, pid: 0, force: false, upstream: { tls: "yes" })
      end
      assert_includes error.message, "Invalid upstream configuration"
      assert_equal [ unsupported, malformed, incomplete, alias_route, owned, stale ], disk
    end
  end

  describe "saveRoutes (via addRoute)" do
    it "persists routes to file" do
      store.add_route(hostname: "test.localhost", port: 4123, pid: Process.pid)
      raw = read_json(store.routes_path)
      assert_equal 1, raw.size
      assert_equal "test.localhost", raw[0]["hostname"]
      assert_equal 4123, raw[0]["port"]
      assert_equal Process.pid, raw[0]["pid"]
    end

    it "creates directory if it does not exist" do
      nested = File.join(@tmp_dir, "nested")
      s = Portless::RouteStore.new(nested)
      s.add_route(hostname: "test.localhost", port: 4001, pid: Process.pid)
      assert_equal true, File.exist?(s.routes_path)
    end

    it "never exposes a partially written routes file to readers" do
      store.add_route(hostname: "app.localhost", port: 4001, pid: Process.pid)
      stable = File.read(store.routes_path, encoding: "utf-8")
      File.write("#{store.routes_path}.tmp", "stale", perm: 0o444)
      routes_path = store.routes_path
      real_open = File.method(:open)
      pending = true
      observed_during_write = nil
      # The first write of the new table lands in two halves; read the routes
      # file between them.
      split_open = lambda do |path, *args, **kw, &blk|
        return real_open.call(path, *args, **kw, &blk) unless pending && path == "#{routes_path}.tmp" && blk

        pending = false
        real_open.call(path, *args, **kw) do |file|
          writer = Object.new
          writer.define_singleton_method(:write) do |text|
            text = text.to_s
            file.write(text[0, text.length / 2])
            file.flush
            observed_during_write = File.read(routes_path, encoding: "utf-8")
            file.write(text[(text.length / 2)..])
          end
          blk.call(writer)
        end
      end

      File.stub(:open, split_open) { store.update_route("app.localhost", { childPgid: 4242 }) }

      assert_equal stable, observed_during_write
      assert_equal 4242, store.load_routes[0].child_pgid
    end
  end

  describe "addRoute" do
    it "persists and reloads upstream settings and clears them on replacement" do
      upstream = { tls: true, host: "api.internal:8443" }
      store.add_route(hostname: "api.localhost", port: 4001, pid: 0, force: false, upstream: upstream)
      saved = read_json(store.routes_path)
      assert_equal({ "tls" => true, "host" => "api.internal:8443" }, saved[0]["upstream"])
      assert_equal upstream, Portless::RouteStore.new(@tmp_dir).load_routes[0].upstream

      store.add_route(hostname: "api.localhost", port: 4002, pid: 0, force: true)
      assert_nil Portless::RouteStore.new(@tmp_dir).load_routes[0].upstream
    end

    it "adds a route to empty store" do
      before = (Time.now.to_f * 1000).to_i
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.pid)
      after = (Time.now.to_f * 1000).to_i
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal({ "hostname" => "myapp.localhost", "port" => 4001, "pid" => Process.pid,
                     "registeredAt" => routes[0].registered_at }, routes[0].to_h)
      assert_kind_of Numeric, routes[0].registered_at
      assert_operator routes[0].registered_at, :>=, before
      assert_operator routes[0].registered_at, :<=, after
    end

    it "replaces existing route with same hostname" do
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.pid)
      store.add_route(hostname: "myapp.localhost", port: 4002, pid: Process.pid)
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal 4002, routes[0].port
    end

    it "preserves other routes when adding" do
      store.add_route(hostname: "app1.localhost", port: 4001, pid: Process.pid)
      store.add_route(hostname: "app2.localhost", port: 4002, pid: Process.pid)
      routes = store.load_routes
      assert_equal 2, routes.size
      assert_equal [ "app1.localhost", "app2.localhost" ], routes.map(&:hostname).sort
    end
  end

  describe "addRoute with force" do
    it "throws RouteConflictError without --force when route is owned by another live process" do
      other_pid = spawn_sleeper
      begin
        store.add_route(hostname: "app.localhost", port: 4001, pid: other_pid)
        assert_raises(Portless::RouteConflictError) do
          store.add_route(hostname: "app.localhost", port: 4002, pid: Process.pid)
        end
      ensure
        kill_quietly(other_pid)
      end
    end

    it "kills the existing process and returns its PID when --force is used" do
      other_pid = spawn_sleeper
      begin
        store.add_route(hostname: "app.localhost", port: 4001, pid: other_pid)
        killed_pid = store.add_route(hostname: "app.localhost", port: 4002, pid: Process.pid, force: true)
        assert_equal other_pid, killed_pid
        # Wait for signal delivery
        sleep 0.2
        assert_equal false, alive?(other_pid)
      ensure
        kill_quietly(other_pid)
      end
    end

    it "refuses a --force takeover recorded in a directory other users can write to" do
      other_pid = spawn_sleeper
      begin
        store.add_route(hostname: "app.localhost", port: 4001, pid: other_pid)
        File.chmod(0o777, @tmp_dir)
        error = assert_raises(Portless::Error) do
          store.add_route(hostname: "app.localhost", port: 4002, pid: Process.pid, force: true)
        end
        assert_includes error.message, "Cannot use state directory"
        assert_equal true, alive?(other_pid)
        assert_equal other_pid, store.load_routes.find { |route| route.hostname == "app.localhost" }&.pid
      ensure
        File.chmod(0o755, @tmp_dir)
        kill_quietly(other_pid) if alive?(other_pid)
      end
    end

    it "replaces the route when --force kills the existing process" do
      other_pid = spawn_sleeper
      begin
        store.add_route(hostname: "app.localhost", port: 4001, pid: other_pid)
        store.add_route(hostname: "app.localhost", port: 4002, pid: Process.pid, force: true)
        routes = store.load_routes
        assert_equal 1, routes.size
        assert_equal 4002, routes[0].port
        assert_equal Process.pid, routes[0].pid
      ensure
        kill_quietly(other_pid)
      end
    end

    it "refuses to replace a static alias without --force" do
      store.add_route(hostname: "db.localhost", port: 5432, pid: 0)
      error = assert_raises(Portless::RouteConflictError) do
        store.add_route(hostname: "db.localhost", port: 4002, pid: Process.pid)
      end
      assert_equal '"db.localhost" is a static alias. Use --force to replace it; re-add the alias with ' \
                   '"rb-portless alias" afterwards.', error.message
    end

    it "replaces a static alias with --force without sending any signal" do
      signals = []
      kill = lambda do |signal, pid, real_kill|
        next real_kill.call(signal, pid) if signal.zero?

        signals << [ signal, pid ]
        1
      end
      with_kill(kill) do
        store.add_route(hostname: "db.localhost", port: 5432, pid: 0)
        assert_nil store.add_route(hostname: "db.localhost", port: 4002, pid: Process.pid, force: true)
        assert_equal [], signals
        routes = store.load_routes
        assert_equal 1, routes.size
        assert_equal [ 4002, Process.pid ], [ routes[0].port, routes[0].pid ]
      end
    end

    it "returns undefined when no conflicting process exists" do
      killed_pid = store.add_route(hostname: "app.localhost", port: 4001, pid: Process.pid, force: true)
      assert_nil killed_pid
    end
  end

  describe "removeRoute" do
    it "removes an existing route" do
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.pid)
      store.remove_route("myapp.localhost")
      assert_equal 0, store.load_routes.size
    end

    it "does not fail when removing non-existent route" do
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.pid)
      store.remove_route("other.localhost")
      assert_equal 1, store.load_routes.size
    end

    it "preserves other routes when removing" do
      store.add_route(hostname: "app1.localhost", port: 4001, pid: Process.pid)
      store.add_route(hostname: "app2.localhost", port: 4002, pid: Process.pid)
      store.remove_route("app1.localhost")
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal "app2.localhost", routes[0].hostname
    end

    it "removes the route when the caller still owns it" do
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.pid)
      store.remove_route("myapp.localhost", owner_pid: Process.pid)
      assert_equal 0, store.load_routes.size
    end

    it "does not remove a route the caller no longer owns (post --force takeover)" do
      # Simulate the state right after a --force takeover: the route is owned
      # by another live process. The killed process's exit cleanup (passing
      # its own pid) must not deregister the new owner's route.
      new_owner_pid = Process.ppid
      store.add_route(hostname: "myapp.localhost", port: 4002, pid: new_owner_pid)
      store.remove_route("myapp.localhost", owner_pid: Process.pid)
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal new_owner_pid, routes[0].pid
    end
  end

  describe "stale recovery records" do
    def dead_pid = 999_999

    def stale_route
      @stale_route ||= {
        "hostname" => "stale.localhost", "port" => 4310, "pid" => dead_pid, "childPgid" => 4242,
        "childStartTime" => "leader-start", "tailscaleHttpsPort" => 8443, "ngrokPid" => 5151,
        "registeredAt" => (Time.now.to_f * 1000).to_i - 60_000
      }
    end

    def retired_route = stale_route.merge("retired" => true)
    def write_routes(routes) = write_json(File.join(@tmp_dir, "routes.json"), routes)
    def read_raw = read_json(File.join(@tmp_dir, "routes.json"))

    it "keeps a stale record out of the active view" do
      store.ensure_dir
      write_routes([ stale_route ])

      assert_equal [], store.load_routes
      assert_equal [ stale_route ], hashes(store.load_routes_raw)
      assert_equal [ stale_route ], hashes(store.find_stale_routes)
    end

    it "keeps the record through add, update, transfer and remove of other routes" do
      store.ensure_dir
      write_routes([ stale_route ])

      store.add_route(hostname: "other.localhost", port: 4001, pid: Process.pid)
      store.update_route("other.localhost", { ngrokUrl: "https://other.ngrok.app" })
      assert_equal true, store.transfer_route("other.localhost", Process.pid, Process.ppid)
      store.remove_route("other.localhost", owner_pid: Process.ppid)

      assert_equal [ retired_route ], read_raw
      assert_equal [], store.load_routes
    end

    it "keeps the record when the same hostname is registered again" do
      store.ensure_dir
      write_routes([ stale_route ])

      store.add_route(hostname: "stale.localhost", port: 4999, pid: Process.pid)

      assert_equal 1, store.load_routes.size
      assert_equal 4999, store.load_routes[0].port
      assert_equal 2, read_raw.size
      assert_equal({ "hostname" => "stale.localhost", "port" => 4999, "pid" => Process.pid },
                   read_raw[0].slice("hostname", "port", "pid"))
      assert_equal retired_route, read_raw[1]
    end

    it "keeps a retained record inactive after its PID is reused" do
      store.ensure_dir
      write_routes([ stale_route ])
      store.add_route(hostname: "stale.localhost", port: 4999, pid: Process.pid)

      write_routes(read_raw.map { |route| route["pid"] == dead_pid ? route.merge("pid" => Process.ppid) : route })
      store.remove_route("stale.localhost", owner_pid: Process.pid)

      assert_equal [], store.load_routes
      assert_equal 1, store.find_stale_routes.size
    end

    it "returns the active entry first for a legacy file with a stale record first" do
      store.ensure_dir
      live = { "hostname" => "stale.localhost", "port" => 4999, "pid" => Process.pid }
      write_routes([ stale_route, live ])

      assert_equal [ live, stale_route ], hashes(store.load_routes_raw)
      assert_equal live, store.load_routes_raw.find { |route| route.hostname == "stale.localhost" }.to_h
    end

    it "updates the live entry, not the stale record, for a shared hostname" do
      store.ensure_dir
      live = { "hostname" => "stale.localhost", "port" => 4999, "pid" => Process.pid }
      write_routes([ stale_route, live ])

      store.update_route("stale.localhost", { ngrokUrl: "https://live.ngrok.app" })

      raw = read_raw
      assert_equal live.merge("ngrokUrl" => "https://live.ngrok.app"), raw[0]
      assert_equal retired_route, raw[1]
    end

    it "records a verified member only on the matching stale record" do
      store.ensure_dir
      write_routes([ stale_route ])

      assert_equal false, store.record_stale_orphan(
        Portless::RouteStore::Route.from_h(stale_route.merge("childStartTime" => "other")), 4343, "m"
      )
      assert_equal true, store.record_stale_orphan(Portless::RouteStore::Route.from_h(stale_route), 4343,
                                                   "member-start")

      assert_equal [ retired_route.merge("orphanPid" => 4343, "orphanStartTime" => "member-start") ], read_raw
    end

    it "removes only the dead owner's record" do
      store.ensure_dir
      second = stale_route.merge("hostname" => "second.localhost", "port" => 4311)
      write_routes([ stale_route, second ])

      assert_equal false, store.remove_stale_route("stale.localhost", 111_111)
      assert_equal true, store.remove_stale_route("stale.localhost", dead_pid)
      assert_equal [ second.merge("retired" => true) ], read_raw
    end

    it "drops stale entries without recovery data on the next write" do
      store.ensure_dir
      plain = { "hostname" => "plain.localhost", "port" => 4312, "pid" => dead_pid, "registeredAt" => 1 }
      write_routes([ plain ])

      store.add_route(hostname: "other.localhost", port: 4001, pid: Process.pid)

      assert_equal [ "other.localhost" ], read_raw.map { |route| route["hostname"] }
    end
  end

  describe "transferRoute" do
    it "moves a route to another pid while the caller owns it" do
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.pid)
      assert_equal true, store.transfer_route("myapp.localhost", Process.pid, Process.ppid)
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal Process.ppid, routes[0].pid
      assert_equal 4001, routes[0].port
    end

    it "drops sharing URLs, whose tunnels stop with the previous owner" do
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.pid)
      store.update_route("myapp.localhost", {
        ngrokUrl: "https://abc.ngrok.app",
        ngrokPid: 123,
        cloudflareUrl: "https://abc.trycloudflare.com",
        cloudflarePid: 456,
        tailscaleUrl: "https://dev.tail1234.ts.net",
        tailscaleHttpsPort: 8443,
        tailscaleFunnel: true
      })
      store.transfer_route("myapp.localhost", Process.pid, Process.ppid)
      route = store.load_routes[0]
      assert_nil route.ngrok_url
      assert_nil route.ngrok_pid
      assert_nil route.cloudflare_url
      assert_nil route.cloudflare_pid
      assert_nil route.tailscale_url
      assert_nil route.tailscale_https_port
      assert_nil route.tailscale_funnel
    end

    it "does not move a route owned by another pid" do
      store.add_route(hostname: "myapp.localhost", port: 4001, pid: Process.ppid)
      assert_equal false, store.transfer_route("myapp.localhost", Process.pid, 1)
      assert_equal Process.ppid, store.load_routes[0].pid
    end
  end

  describe "locking (via concurrent addRoute)" do
    it "handles %s lock creation error %s" do
      [
        [ "win32", Errno::EPERM, true ],
        [ "linux", Errno::EPERM, false ],
        [ "win32", Errno::EACCES, false ]
      ].each do |platform, code, retries|
        dir = mkdtemp("portless-routes-test-")
        row_store = Portless::RouteStore.new(dir)
        lock_path = File.join(dir, "routes.lock")
        real_mkdir = Dir.method(:mkdir)
        failed = false
        mkdir = lambda do |path, *rest|
          if !failed && path == lock_path
            failed = true
            raise code, "lock creation failed"
          end
          real_mkdir.call(path, *rest)
        end
        begin
          Portless::Privilege.stub(:host_platform, platform) do
            Dir.stub(:mkdir, mkdir) do
              if retries
                row_store.add_route(hostname: "retry.localhost", port: 4001, pid: Process.pid)
                routes = row_store.load_routes
                assert_equal 1, routes.size
                assert_equal [ "retry.localhost", 4001, Process.pid ], [ routes[0].hostname, routes[0].port, routes[0].pid ]
                assert_equal false, File.exist?(lock_path)
              else
                error = assert_raises(Portless::Error) do
                  row_store.add_route(hostname: "retry.localhost", port: 4001, pid: Process.pid)
                end
                assert_includes error.message, "Failed to acquire route lock"
                assert_equal false, File.exist?(row_store.routes_path)
              end
            end
          end
        ensure
          FileUtils.rm_rf(dir)
        end
      end
    end

    it "handles stale lock by recovering and completing the operation" do
      store.ensure_dir
      lock_path = File.join(@tmp_dir, "routes.lock")
      Dir.mkdir(lock_path)
      stale_time = Time.now - 11
      File.utime(stale_time, stale_time, lock_path)
      store.add_route(hostname: "test.localhost", port: 4001, pid: Process.pid)
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal "test.localhost", routes[0].hostname
    end

    it "handles many parallel addRoute calls without lock errors" do
      count = 20
      script_path = File.join(@tmp_dir, "worker.rb")
      File.write(script_path, <<~RUBY)
        require "rb-portless"
        dir, hostname, port = ARGV
        store = Portless::RouteStore.new(dir)
        begin
          store.add_route(hostname: hostname, port: Integer(port), pid: Process.pid)
          puts "ok"
        rescue StandardError => e
          puts "error:" + e.message
          exit 1
        end
        $stdout.flush
        $stdin.read
      RUBY

      children = Array.new(count) do |i|
        Open3.popen3(RbConfig.ruby, "-I", RoutesMirror::LIB_DIR, script_path, @tmp_dir, "app#{i}.localhost",
                     (4000 + i).to_s)
      end
      begin
        outcomes = children.map do |_stdin, stdout, stderr, _wait|
          line = stdout.gets.to_s.strip
          { stdout: line, stderr: line.start_with?("ok") ? "" : stderr.read.to_s.strip }
        end
        failures = outcomes.reject { |o| o[:stdout].start_with?("ok") }

        children.each { |stdin, *| stdin.close }

        assert_equal [], failures

        raw = read_json(store.routes_path)
        assert_equal count, raw.size

        hostnames = raw.map { |r| r["hostname"] }.sort
        expected = Array.new(count) { |i| "app#{i}.localhost" }.sort
        assert_equal expected, hostnames
      ensure
        children.each do |stdin, stdout, stderr, wait|
          stdin.close unless stdin.closed?
          kill_quietly(wait.pid) unless wait.join(5)
          wait.join
          stdout.close
          stderr.close
        end
      end
    end

    it "survives sustained lock contention that defeats a naive retry strategy" do
      store.ensure_dir
      lock_path = File.join(@tmp_dir, "routes.lock")

      # A child process holds the lock for 1.5s, simulating a slow writer on
      # a loaded machine. The old strategy (20 retries * 50ms = 1s budget)
      # would time out; exponential backoff with a larger budget survives.
      hold = 1.5
      script = <<~RUBY
        require "fileutils"
        lock_path = #{lock_path.dump}
        FileUtils.mkdir_p(lock_path)
        puts "holding"
        $stdout.flush
        sleep #{hold}
        FileUtils.rm_rf(lock_path)
        puts "released"
      RUBY
      stdin, stdout, wait = Open3.popen2(RbConfig.ruby, "-e", script)
      stdin.close
      begin
        # Wait for the holder to acquire the lock
        nil until stdout.gets.to_s.include?("holding")

        # addRoute must wait for the lock to be released (>1.5s)
        store.add_route(hostname: "contended.localhost", port: 5000, pid: Process.pid)

        kill_quietly(wait.pid)

        routes = store.load_routes
        assert_equal 1, routes.size
        assert_equal "contended.localhost", routes[0].hostname
      ensure
        kill_quietly(wait.pid)
        wait.join
        stdout.close
      end
    end
  end

  describe "tailscale metadata" do
    it "persists and loads tailscale fields via updateRoute" do
      store.add_route(hostname: "myapp.localhost", port: 4123, pid: Process.pid)
      store.update_route("myapp.localhost", {
        tailscaleUrl: "https://devbox.example.ts.net",
        tailscaleHttpsPort: 443
      })
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal "https://devbox.example.ts.net", routes[0].tailscale_url
      assert_equal 443, routes[0].tailscale_https_port
      assert_nil routes[0].tailscale_funnel
    end

    it "persists funnel flag via updateRoute" do
      store.add_route(hostname: "api.localhost", port: 4456, pid: Process.pid)
      store.update_route("api.localhost", {
        tailscaleUrl: "https://devbox.example.ts.net:8443",
        tailscaleHttpsPort: 8443,
        tailscaleFunnel: true
      })
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal true, routes[0].tailscale_funnel
    end

    it "updateRoute keeps the original registeredAt" do
      store.add_route(hostname: "myapp.localhost", port: 4123, pid: Process.pid)
      registered_at = store.load_routes[0].registered_at
      store.update_route("myapp.localhost", { tailscaleUrl: "https://devbox.example.ts.net" })
      routes = store.load_routes
      assert_equal "https://devbox.example.ts.net", routes[0].tailscale_url
      assert_equal registered_at, routes[0].registered_at
    end

    it "loads routes with and without registeredAt unchanged (backward compat)" do
      routes = [
        { "hostname" => "old.localhost", "port" => 4001, "pid" => Process.pid },
        { "hostname" => "new.localhost", "port" => 4002, "pid" => Process.pid, "registeredAt" => 1_700_000_000_000 },
        { "hostname" => "odd.localhost", "port" => 4003, "pid" => Process.pid, "registeredAt" => "yesterday" }
      ]
      store.ensure_dir
      write_json(store.routes_path, routes)
      assert_equal routes, hashes(store.load_routes)
    end

    it "loads routes without tailscale fields (backward compat)" do
      store.add_route(hostname: "legacy.localhost", port: 4000, pid: Process.pid)
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_nil routes[0].tailscale_url
      assert_nil routes[0].tailscale_https_port
    end

    it "updateRoute is a no-op for nonexistent hostname" do
      store.add_route(hostname: "myapp.localhost", port: 4123, pid: Process.pid)
      store.update_route("noexist.localhost", { tailscaleUrl: "https://devbox.example.ts.net" })
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_nil routes[0].tailscale_url
    end
  end

  describe "ngrok metadata" do
    it "persists and loads ngrok fields via updateRoute" do
      store.add_route(hostname: "myapp.localhost", port: 4123, pid: Process.pid)
      store.update_route("myapp.localhost", { ngrokUrl: "https://abc123.ngrok.app", ngrokPid: 12_345 })
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_equal "https://abc123.ngrok.app", routes[0].ngrok_url
      assert_equal 12_345, routes[0].ngrok_pid
    end

    it "clears ngrok fields via updateRoute" do
      store.add_route(hostname: "myapp.localhost", port: 4123, pid: Process.pid)
      store.update_route("myapp.localhost", { ngrokUrl: "https://abc123.ngrok.app", ngrokPid: 12_345 })
      store.update_route("myapp.localhost", { ngrokUrl: nil, ngrokPid: nil })
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_nil routes[0].ngrok_url
      assert_nil routes[0].ngrok_pid
    end

    it "loads routes without ngrok fields" do
      store.add_route(hostname: "legacy.localhost", port: 4000, pid: Process.pid)
      routes = store.load_routes
      assert_equal 1, routes.size
      assert_nil routes[0].ngrok_url
      assert_nil routes[0].ngrok_pid
    end
  end
end
