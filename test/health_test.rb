# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class HealthTest < Minitest::Test
  def test_proxy_not_running_on_a_closed_port
    refute Portless::Health.proxy_running?(free_port, timeout: 0.3)
  end

  def test_discover_port_returns_a_port_or_nil
    # No live proxy in tests → nil (or a probed port if one happens to answer).
    result = Portless::Health.discover_port
    assert(result.nil? || result.is_a?(Integer))
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end
