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

    refute Portless::Health.proxy_running?(server.addr[1], true, timeout: 0.1)
  ensure
    server&.close
    thread&.kill
  end

  def test_requires_x_portless_1
    with_server("X-Portless: 1\r\n") { |port| assert Portless::Health.proxy_running?(port) }
    with_server("x-portless: 0.4.0\r\n") { |port| refute Portless::Health.proxy_running?(port) }
    with_server("server: nginx\r\n") { |port| refute Portless::Health.proxy_running?(port) }
  end

  def with_server(headers)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      client.readpartial(1024)
      client.write("HTTP/1.1 404 Not Found\r\n#{headers}Content-Length: 0\r\n\r\n")
      client.close
    end
    yield server.addr[1]
  ensure
    server&.close
    thread&.kill
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end
