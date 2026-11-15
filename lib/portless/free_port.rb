# frozen_string_literal: true

require "socket"

module Portless
  # Picks a free backend port for an app (4000-4999). Random-first to keep the
  # check→bind race window small, skipping the WHATWG bad-port set so browsers
  # never refuse the URL. Mirrors portless's findFreePort.
  module FreePort
    module_function

    MIN_APP_PORT = 4000
    MAX_APP_PORT = 4999
    RANDOM_PORT_ATTEMPTS = 50

    # WHATWG fetch "bad ports" (https://fetch.spec.whatwg.org/#port-blocking).
    BLOCKED_PORTS = [
      0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102,
      103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465,
      512, 513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993,
      995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566, 6665, 6666, 6667, 6668,
      6669, 6679, 6697, 10080
    ].freeze

    # A bind on one address doesn't see a listener on another (macOS), and the
    # proxy dials apps on both loopbacks — so the port must be free on all four.
    APP_PORT_PROBE_HOSTS = [ "127.0.0.1", "::1", "0.0.0.0", "::" ].freeze

    def find(min_port = MIN_APP_PORT, max_port = MAX_APP_PORT)
      raise Error, "minPort (#{min_port}) must be <= maxPort (#{max_port})" if min_port > max_port

      RANDOM_PORT_ATTEMPTS.times do
        port = rand(min_port..max_port)
        return port if !BLOCKED_PORTS.include?(port) && available?(port)
      end
      (min_port..max_port).each do |port|
        return port if !BLOCKED_PORTS.include?(port) && available?(port)
      end
      raise Error, "No free port found in range #{min_port}-#{max_port}"
    end

    # Sequential: a dual-stack `::` bind collides with a concurrent `0.0.0.0` one.
    def available?(port)
      APP_PORT_PROBE_HOSTS.all? { |host| free_on?(port, host) }
    end

    def free_on?(port, host)
      server = TCPServer.new(host, port)
      server.close
      true
    rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT
      true # this address family doesn't exist here, so it can't hold the port
    rescue SystemCallError, SocketError
      false
    end
  end
end
