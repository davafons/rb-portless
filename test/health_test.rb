# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class HealthTest < Minitest::Test
  def test_proxy_not_running_on_a_closed_port
    refute Portless::Health.proxy_running?(free_port, timeout: 0.3)
  end

  def test_proxy_not_running_when_tls_handshake_stalls
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      sleep 2
      client.close
    rescue IOError
      nil
    end

    refute Portless::Health.proxy_running?(server.addr[1], timeout: 0.1)
  ensure
    server&.close
    thread&.kill
  end

  def test_discover_port_returns_a_port_or_nil
    # No live proxy in tests → nil (or a probed port if one happens to answer).
    result = Portless::Health.discover_port
    assert(result.nil? || result.is_a?(Integer))
  end

  def test_version_from_reads_the_stamped_version
    assert_equal "0.4.0", Portless::Health.version_from("HTTP/1.1 404 Not Found\r\nx-rb-portless: 0.4.0\r\n\r\n")
  end

  # Pre-0.4 proxies stamped a bare "1" — must read as older than any release.
  def test_version_from_treats_the_legacy_marker_as_ancient
    assert_equal "0.0.0", Portless::Health.version_from("HTTP/1.1 404 Not Found\r\nx-rb-portless: 1\r\n\r\n")
  end

  def test_version_from_is_nil_without_the_header
    assert_nil Portless::Health.version_from("HTTP/1.1 200 OK\r\nserver: nginx\r\n\r\n")
    assert_nil Portless::Health.version_from(nil)
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end
