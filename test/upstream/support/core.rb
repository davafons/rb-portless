# frozen_string_literal: true

require "fileutils"
require "minitest/mock"
require "tmpdir"

# Shared helpers for the core mirrors (utils, routes, certs, hosts,
# clean-utils, lan-ip, mdns).
module UpstreamCore
  # fs.mkdtempSync(path.join(os.tmpdir(), prefix)), under the canonical tmpdir
  # (as on upstream's Linux CI; macOS reaches /var/folders through a symlink).
  def mkdtemp(prefix) = Dir.mktmpdir(prefix, File.realpath(Dir.tmpdir))

  # Poll until the block is truthy (stand-in for vitest fake timers).
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
    result
  end

  # Temporarily set (or unset, with nil) environment variables.
  def with_env(vars)
    saved = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # vi.fn(): a callable that records its calls.
  class Spy
    attr_reader :calls

    def initialize(&impl)
      @impl = impl
      @calls = []
    end

    def call(*args)
      @calls << args
      @impl&.call(*args)
    end

    def to_proc = method(:call).to_proc
    def called? = !@calls.empty?
  end

  def spy(&impl) = Spy.new(&impl)
end
