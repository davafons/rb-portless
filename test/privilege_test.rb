# frozen_string_literal: true

require "test_helper"
require "socket"

class PrivilegeTest < Minitest::Test
  P = Portless::Privilege

  def test_bind_targets
    assert_equal [ { host: "127.0.0.1" }, { host: "::1", ipv6_only: true } ], P.bind_targets(false)
    assert_equal [ { host: "0.0.0.0" }, { host: "::", ipv6_only: true } ], P.bind_targets(true)
    assert_equal P.bind_targets(true), P.bind_targets(false, true)
  end

  def test_can_bind_without_root
    assert P.can_bind_without_root(80, platform: "darwin")[:ok]
    assert P.can_bind_without_root(8443, platform: "linux")[:ok]
    assert P.can_bind_without_root(80, platform: "linux", read_unprivileged_port_start: -> { "0\n" })[:ok]
    res = P.can_bind_without_root(80, platform: "linux", read_unprivileged_port_start: -> { "1024" })
    assert_equal "Port 80 is below net.ipv4.ip_unprivileged_port_start (1024).", res[:reason]
    res = P.can_bind_without_root(80, platform: "linux", read_unprivileged_port_start: -> { raise Errno::ENOENT })
    assert_equal "Could not read net.ipv4.ip_unprivileged_port_start.", res[:reason]
    assert_match(/not supported on freebsd/, P.can_bind_without_root(80, platform: "freebsd")[:reason])
  end

  def test_can_bind_proxy_port_ignores_address_in_use
    server = TCPServer.new("127.0.0.1", 0)
    assert P.can_bind_proxy_port?(server.addr[1], P.bind_targets(false)), "EADDRINUSE is left to the real listen"
  ensure
    server&.close
  end

  def test_high_ports_never_need_elevation
    refute P.needs_elevation?(1355, false)
  end

  def test_portless_env_args
    env = { "PORTLESS_TLD" => "test", "PORTLESS_EMPTY" => "", "HOME" => "/x", "PORTLESS_STATE_DIR" => "/s" }
    assert_equal [ "PORTLESS_TLD=test", "PORTLESS_STATE_DIR=/s" ], P.portless_env_args(env)
    assert_equal [ "PORTLESS_TLD=test" ], P.portless_env_args(env, omit: [ "PORTLESS_STATE_DIR" ])
  end

  def test_cli_argv_reexecs_this_ruby_with_lib
    argv = P.cli_argv
    assert_equal RbConfig.ruby, argv[0]
    assert_equal "-I", argv[1]
    assert File.exist?(File.join(argv[2], "rb-portless.rb"))
  end
end
