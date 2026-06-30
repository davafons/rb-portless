# frozen_string_literal: true

require_relative "test_helper"

class LanTest < Minitest::Test
  def test_detect_returns_override
    assert_equal "10.0.0.5", Portless::LanIp.detect("10.0.0.5")
  end

  def test_detect_finds_a_private_ipv4_or_nil
    ip = Portless::LanIp.detect
    assert(ip.nil? || ip =~ /\A(10|192\.168|172\.(1[6-9]|2\d|3[01]))\./, "expected private IPv4, got #{ip.inspect}")
  end

  def test_mdns_command_for_dns_sd
    Portless.stub(:which, ->(bin) { bin == "dns-sd" }) do
      cmd = Portless::Mdns.command_for("demo.local", "10.0.0.5")
      assert_equal "dns-sd", cmd.first
      assert_includes cmd, "demo.local"
      assert_includes cmd, "10.0.0.5"
    end
  end

  def test_mdns_command_for_avahi
    Portless.stub(:which, ->(bin) { bin == "avahi-publish" }) do
      cmd = Portless::Mdns.command_for("demo.local", "10.0.0.5")
      assert_equal "avahi-publish", cmd.first
    end
  end

  def test_mdns_nil_when_no_responder
    Portless.stub(:which, false) do
      assert_nil Portless::Mdns.command_for("demo.local", "10.0.0.5")
    end
  end
end
