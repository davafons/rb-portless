# frozen_string_literal: true

require "test_helper"

# LanIp (lan-ip.test.ts) and Mdns (mdns.test.ts).
class LanTest < Minitest::Test
  L = Portless::LanIp
  M = Portless::Mdns

  def row(iname: "en0", address: "192.168.1.20", mac: "a4:83:e7:00:11:22", internal: false)
    { iname: iname, address: address, mac: mac, internal: internal }
  end

  def ip(rows, probe = "192.168.1.20") = L.local_network_ip(probe: -> { probe }, rows: rows)

  def test_returns_probed_address_for_physical_nic
    assert_equal "192.168.1.20", ip([ row ])
  end

  def test_rejects_loopback_internal_unlisted_and_virtual
    assert_nil ip([ row(address: "127.0.0.1") ], "127.0.0.1")
    assert_nil ip([ row(internal: true) ])
    assert_nil ip([ row(address: "10.0.0.1") ])
    assert_nil ip([ row(mac: "00:00:00:00:00:00") ])
    assert_nil ip([ row(mac: "00:15:5d:01:02:03") ])
    assert_nil ip([ row(iname: "vEthernet (WSL)") ])
    assert_nil ip([ row(iname: "bridge0") ])
  end

  def test_returns_nil_when_probe_fails
    assert_nil L.local_network_ip(probe: -> { raise Errno::ENETUNREACH }, rows: [ row ])
  end

  def test_mdns_commands
    assert_equal [ "dns-sd", "-P", "api.myapp", "_http._tcp", "local", "1355", "api.myapp.local", "10.0.0.2" ],
                 M.build_command("api.myapp.local", 1355, "10.0.0.2", "darwin")
    assert_equal [ "avahi-publish-address", "-R", "myapp.local", "10.0.0.2" ],
                 M.build_command("myapp", 443, "10.0.0.2", "linux")
    assert_nil M.build_command("x.local", 443, "10.0.0.2", "win32")
  end

  def test_mdns_supported
    assert_equal({ supported: true }, M.supported("darwin", has_command: ->(_) { true }))
    assert_equal "dns-sd not found", M.supported("darwin", has_command: ->(_) { false })[:reason]
    assert_match(/avahi-utils/, M.supported("linux", has_command: ->(_) { false })[:reason])
    refute M.supported("win32")[:supported]
  end

  def test_lan_ip_monitor_reports_changes_loss_and_recovery
    values = [ "10.0.0.2", "10.0.0.3", nil, "10.0.0.4" ]
    changes = []
    monitor = M.start_lan_ip_monitor(initial_ip: "10.0.0.2", interval: 0.01,
                                     resolve_ip: -> { values.size > 1 ? values.shift : values.first },
                                     on_change: ->(n, p) { changes << [ n, p ] })
    sleep 0.2
    monitor.stop
    assert_equal [ [ "10.0.0.3", "10.0.0.2" ], [ nil, "10.0.0.3" ], [ "10.0.0.4", nil ] ], changes
  end

  def test_lan_ip_monitor_on_error_and_stop
    errors = []
    monitor = M.start_lan_ip_monitor(initial_ip: nil, interval: 0.01, resolve_ip: -> { raise "boom" },
                                     on_change: ->(*) { flunk }, on_error: ->(e) { errors << e.message })
    sleep 0.05
    monitor.stop
    count = errors.size
    sleep 0.05
    assert_operator count, :>=, 1
    assert_equal count, errors.size
  end

  def published = M.instance_variable_get(:@publishers).keys

  def test_publish_tracks_children
    skip "no sleep binary" unless Portless.which("sleep")
    M.stub(:build_command, ->(*) { %w[sleep 5] }) do
      M.publish("a.local", 443, "10.0.0.2")
      M.publish("a.local", 443, "10.0.0.2")
      assert_equal [ "a.local" ], published
      M.unpublish("a.local")
      assert_empty published
      M.publish("b.local", 443, "10.0.0.2")
      M.cleanup_all
      assert_empty published
    end
  end
end
