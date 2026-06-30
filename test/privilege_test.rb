# frozen_string_literal: true

require_relative "test_helper"

class PrivilegeTest < Minitest::Test
  def test_privileged_port_detection
    assert Portless::Privilege.privileged_port?(443)
    assert Portless::Privilege.privileged_port?(80)
    assert Portless::Privilege.privileged_port?(1023)
    refute Portless::Privilege.privileged_port?(1024)
    refute Portless::Privilege.privileged_port?(8443)
  end

  def test_needs_sudo_only_for_privileged_ports
    skip "running as root" if Process.uid.zero?
    skip "windows has no privileged-port concept" if Portless::Constants::WINDOWS

    assert Portless::Privilege.needs_sudo?(443)
    assert Portless::Privilege.needs_sudo?(80)
    refute Portless::Privilege.needs_sudo?(1355)
    refute Portless::Privilege.needs_sudo?(8443)
  end

  def test_portless_env_args_only_passes_portless_keys
    ENV["PORTLESS_DEMO"] = "yes"
    ENV["NOT_PORTLESS"] = "no"
    args = Portless::Privilege.portless_env_args
    assert_includes args, "PORTLESS_DEMO=yes"
    refute(args.any? { |a| a.start_with?("NOT_PORTLESS") })
  ensure
    ENV.delete("PORTLESS_DEMO")
    ENV.delete("NOT_PORTLESS")
  end
end
