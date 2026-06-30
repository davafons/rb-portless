# frozen_string_literal: true

module Portless
  # Best-effort "who is listening on this TCP port" — used by `prune` to reap an
  # orphaned dev server whose owning CLI process already died but whose backend
  # port is still held. Shells out to lsof (present on macOS + most Linux);
  # silently no-ops when it's unavailable. Mirrors portless's port-kill in prune.
  module PortOwner
    module_function

    def listeners(port)
      return [] unless Portless.which("lsof")

      out = IO.popen([ "lsof", "-ti", "tcp:#{Integer(port)}", "-sTCP:LISTEN" ], err: File::NULL, &:read)
      out.split.filter_map { |p| Integer(p, exception: false) }
    rescue StandardError
      []
    end

    # Signal every listener on `port` (TERM, or KILL with force). Never signals
    # ourselves. Returns how many processes were signalled.
    def kill(port, force: false)
      sig = force ? "KILL" : "TERM"
      listeners(port).count do |pid|
        next false if pid == Process.pid

        Process.kill(sig, pid)
        true
      rescue StandardError
        false
      end
    end
  end
end
