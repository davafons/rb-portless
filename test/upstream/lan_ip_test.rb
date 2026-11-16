# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/core"

# Mirror of packages/portless/src/lan-ip.test.ts
describe "getLocalNetworkIp" do
  # Stand-in for the mocked node:dgram socket.
  class FakeLanProbeSocket
    def initialize(hoisted) = @hoisted = hoisted

    def connect(_host, _port)
      raise Errno::EHOSTUNREACH if @hoisted[:socket_fail]
    end

    def local_address = Addrinfo.udp(@hoisted[:probe_address], 52_341)
    def close; end
  end

  def iface(address: "192.168.1.10", family: "IPv4", mac: "aa:bb:cc:dd:ee:ff", internal: false)
    { address: address, family: family, mac: mac, internal: internal }
  end

  before do
    @hoisted = { probe_address: "192.168.1.10", socket_fail: false, interfaces: { "en0" => [ iface ] } }
  end

  def get_local_network_ip
    UDPSocket.stub(:new, ->(*) { FakeLanProbeSocket.new(@hoisted) }) do
      Portless::LanIp.stub(:network_interfaces, -> { @hoisted[:interfaces] }) do
        Portless::LanIp.local_network_ip
      end
    end
  end

  it "returns the probed address when the interface is not internal" do
    assert_equal "192.168.1.10", get_local_network_ip
  end

  it "accepts numeric IPv4 family from os" do
    @hoisted[:interfaces] = { "eth0" => [ iface(address: "10.0.0.5", family: 4, mac: "aa:bb:cc:dd:ee:01") ] }
    @hoisted[:probe_address] = "10.0.0.5"
    assert_equal "10.0.0.5", get_local_network_ip
  end

  it "returns null when the probe reports 0.0.0.0" do
    @hoisted[:probe_address] = "0.0.0.0"
    assert_nil get_local_network_ip
  end

  it "returns null when the probed address is 127.0.0.1" do
    @hoisted[:probe_address] = "127.0.0.1"
    @hoisted[:interfaces] = { "lo0" => [ iface(address: "127.0.0.1", mac: "00:00:00:00:00:00", internal: true) ] }
    assert_nil get_local_network_ip
  end

  it "returns null when Node marks the interface internal" do
    @hoisted[:interfaces] = { "en0" => [ iface(internal: true) ] }
    assert_nil get_local_network_ip
  end

  it "returns null when the probed IP is not listed in networkInterfaces" do
    @hoisted[:interfaces] = {}
    assert_nil get_local_network_ip
  end

  it "returns null for all-zero MAC" do
    @hoisted[:interfaces] = { "en0" => [ iface(mac: "00:00:00:00:00:00") ] }
    assert_nil get_local_network_ip
  end

  it "returns null for Microsoft virtual MAC prefix" do
    @hoisted[:interfaces] = { "eth0" => [ iface(mac: "00:15:5d:01:02:03") ] }
    assert_nil get_local_network_ip
  end

  it "returns null for vEthernet interface names" do
    @hoisted[:interfaces] = { "vEthernet (Default Switch)" => [ iface ] }
    assert_nil get_local_network_ip
  end

  it "returns null for Linux bridgeN names" do
    @hoisted[:interfaces] = { "bridge0" => [ iface ] }
    assert_nil get_local_network_ip
  end

  it "returns null when the UDP socket errors" do
    @hoisted[:socket_fail] = true
    assert_nil get_local_network_ip
  end
end
