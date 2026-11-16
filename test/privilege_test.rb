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

  def test_ruby_env_args_carry_a_custom_gem_home_across_sudo
    assert_equal [ "GEM_HOME=/g", "GEM_PATH=/g:/h" ], P.ruby_env_args({ "GEM_HOME" => "/g", "GEM_PATH" => "/g:/h", "HOME" => "/x" })
    assert_empty P.ruby_env_args({ "GEM_HOME" => "", "PATH" => "/bin" })
  end

  def test_cli_argv_reexecs_this_ruby_with_lib
    argv = P.cli_argv
    assert_equal RbConfig.ruby, argv[0]
    assert_equal "-I", argv[1]
    assert File.exist?(File.join(argv[2], "rb-portless.rb"))
  end

  # A fake sudo on PATH that records its argv and runs `body`.
  def with_fake_sudo(body)
    Dir.mktmpdir do |bin|
      log = File.join(bin, "argv")
      File.write(File.join(bin, "sudo"), "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{log}\n#{body}\n")
      File.chmod(0o755, File.join(bin, "sudo"))
      path = ENV["PATH"]
      ENV["PATH"] = "#{bin}#{File::PATH_SEPARATOR}#{path}"
      yield -> { File.exist?(log) ? File.read(log).split("\n") : nil }
    ensure
      ENV["PATH"] = path
    end
  end

  def test_run_sudo_passes_argv_once_and_reports_status
    with_fake_sudo("exit 0") do |argv|
      assert P.run_sudo(%w[env A=1 ruby x service uninstall]).success?
      assert_equal %w[env A=1 ruby x service uninstall], argv.call
    end
    result = P.run_sudo(%w[true]) # the refusing test shim
    refute result.success?
    assert_equal 1, result.status.exitstatus
  end

  def test_run_sudo_timeout_matches_spawn_sync_error
    with_fake_sudo("exec sleep 5") do
      result = P.run_sudo(%w[x], timeout: 0.2)
      refute result.success?
      assert_equal "spawnSync sudo ETIMEDOUT", result.error
    end
  end
end
