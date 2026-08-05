# frozen_string_literal: true

require_relative "e2e_helper"

# The daemon orchestration layer end-to-end, in its own state dir so it can't
# clobber the shared harness proxy's marker files: `proxy start` (detached
# spawn + readiness wait), discovery, `proxy stop` (marker cleanup, port
# released) — the paths e2e_helper bypasses with --foreground.
class E2EDaemonTest < Minitest::Test
  def test_detached_start_discover_stop_lifecycle
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    state = Dir.mktmpdir
    port = E2E.free_port
    env = { "PORTLESS_STATE_DIR" => state, "PORTLESS_PORT" => port.to_s }

    assert system(env, RbConfig.ruby, "-I", lib, exe, "proxy", "start",
                  in: File::NULL, out: File::NULL, err: File::NULL),
           "proxy start (detached) failed"
    assert Portless::Health.proxy_running?(port), "daemon not answering after start"
    assert_equal port.to_s, File.read(File.join(state, "proxy.port")).strip

    # An idempotent second start must not spawn a rival daemon.
    assert system(env, RbConfig.ruby, "-I", lib, exe, "proxy", "start",
                  in: File::NULL, out: File::NULL, err: File::NULL)

    assert system(env, RbConfig.ruby, "-I", lib, exe, "proxy", "stop",
                  in: File::NULL, out: File::NULL, err: File::NULL), "proxy stop failed"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    while Portless::Health.proxy_running?(port, timeout: 0.3)
      flunk "daemon still answering after stop" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
    refute File.exist?(File.join(state, "proxy.pid")), "pid marker not reaped"
    refute File.exist?(File.join(state, "proxy.port")), "port marker not reaped"
  ensure
    if state && File.exist?(File.join(state, "proxy.pid"))
      begin
        Process.kill("TERM", Integer(File.read(File.join(state, "proxy.pid")).strip))
      rescue StandardError
        nil
      end
    end
    FileUtils.remove_entry(state) if state
  end
end
