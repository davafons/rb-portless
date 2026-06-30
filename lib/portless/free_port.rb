# frozen_string_literal: true

require "socket"

module Portless
  # Picks a free backend port for an app (4000-4999). Random-first to keep the
  # check→bind race window small, skipping the WHATWG bad-port set so browsers
  # never refuse the URL. Mirrors portless's findFreePort.
  module FreePort
    module_function

    RANDOM_ATTEMPTS = 50

    def find
      RANDOM_ATTEMPTS.times do
        port = rand(Constants::MIN_APP_PORT..Constants::MAX_APP_PORT)
        next if Constants::BLOCKED_PORTS.include?(port)
        return port if available?(port)
      end

      (Constants::MIN_APP_PORT..Constants::MAX_APP_PORT).each do |port|
        next if Constants::BLOCKED_PORTS.include?(port)
        return port if available?(port)
      end

      raise Error, "no free port available in #{Constants::MIN_APP_PORT}-#{Constants::MAX_APP_PORT}"
    end

    # Truly free = we can bind it right now on loopback. (TOCTOU inherent, same as
    # portless; random-first mitigates.)
    def available?(port)
      server = TCPServer.new("127.0.0.1", port)
      server.close
      true
    rescue Errno::EADDRINUSE, Errno::EACCES
      false
    end
  end
end
