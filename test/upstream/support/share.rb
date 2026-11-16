# frozen_string_literal: true

require "minitest/mock"

# Shared helpers for the tunnel/tailscale/service/compose/mcp mirrors.
module UpstreamShare
  # tunnel.test.ts MockNgrokChild: a fake tunnel child whose output and exit
  # the test drives.
  class MockNgrokChild
    attr_reader :pid, :stdout, :stderr, :killed_with

    def initialize
      @pid = 12_345
      @stdout, @stdout_w = IO.pipe
      @stderr, @stderr_w = IO.pipe
      @exits = Queue.new
    end

    def write_stdout(text) = @stdout_w.write(text)
    def write_stderr(text) = @stderr_w.write(text)

    def kill(signal = nil)
      @killed_with = signal
      true
    end

    # child.emit("exit", code, signal): the streams end, then the exit fires.
    def emit_exit(code, signal)
      @stdout_w.close unless @stdout_w.closed?
      @stderr_w.close unless @stderr_w.closed?
      @exits << [ code, signal ]
    end

    def wait = @exits.pop
  end

  module_function

  # tunnel.test.ts createSpawner.
  def create_spawner(child, calls = [])
    lambda do |args|
      calls << args
      child
    end
  end

  def wait_until(timeout = 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    result
  end
end
