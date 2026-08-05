# frozen_string_literal: true

require_relative "e2e_helper"

# The crash-recovery safety net, modeled on upstream's zombie e2e: a dev server
# orphaned by a SIGKILL'd run (dead owning pid in routes.json, port still held)
# must be found via its port and reaped by `rb-portless prune`.
class E2EPruneTest < Minitest::Test
  ORPHAN = 'require "socket"; s = TCPServer.new("127.0.0.1", Integer(ARGV[0])); sleep'

  def test_prune_reaps_stale_routes_and_kills_the_orphaned_listener
    skip "lsof not available" unless Portless.which("lsof")

    port = E2E.free_port
    orphan = Process.spawn(RbConfig.ruby, "-e", ORPHAN, port.to_s,
                           in: File::NULL, out: File::NULL, err: File::NULL)
    wait_for { TCPSocket.new("127.0.0.1", port).close || true rescue nil }

    # A route whose owner is gone: an impossible pid, exactly what a SIGKILL'd
    # run leaves behind.
    Portless::RouteStore.new.add(hostname: "e2eorphan.localhost", port: port, pid: 2**22 + 7)

    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    out = IO.popen({ "PORTLESS_STATE_DIR" => Portless::State.dir },
                   [ RbConfig.ruby, "-I", lib, exe, "prune" ], err: [ :child, :out ], &:read)

    assert_match(/pruned 1 stale route/, out)
    assert_match(/killed 1 orphan/, out)
    assert_nil Portless::RouteStore.new.routes.find { |r| r.hostname == "e2eorphan.localhost" }

    gone = wait_for do
      begin
        TCPSocket.new("127.0.0.1", port).close
        nil
      rescue Errno::ECONNREFUSED
        true
      end
    end
    assert gone, "orphaned listener still holds the port after prune"
  ensure
    if orphan
      begin
        Process.kill("KILL", orphan)
        Process.wait(orphan)
      rescue StandardError
        nil
      end
    end
    Portless::RouteStore.new.remove("e2eorphan.localhost")
  end

  private

  def wait_for(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      value = yield
      return value if value

      sleep 0.1
    end
    nil
  end
end
