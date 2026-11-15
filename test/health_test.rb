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

  def test_recognises_only_x_portless_1
    assert Portless::Health.marker?("HTTP/1.1 404 Not Found\r\nX-Portless: 1\r\n\r\n")
    refute Portless::Health.marker?("HTTP/1.1 404 Not Found\r\nx-portless: 0.4.0\r\n\r\n")
    refute Portless::Health.marker?("HTTP/1.1 200 OK\r\nserver: nginx\r\n\r\n")
    refute Portless::Health.marker?(nil)
  end

  def test_plain_probe_against_a_fake_portless_server
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      client.readpartial(1024)
      client.write("HTTP/1.1 404 Not Found\r\nX-Portless: 1\r\nContent-Length: 0\r\n\r\n")
      client.close
    end
    assert Portless::Health.proxy_running?(server.addr[1], tls: false)
  ensure
    server&.close
    thread&.kill
  end

  def test_discover_port_returns_a_port_or_nil
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
