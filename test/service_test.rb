# frozen_string_literal: true

require_relative "test_helper"

# The boot-service file generation is pure string-building (installing needs
# root, so that's not unit-tested). Verify the generated launchd plist + systemd
# unit carry the right command, port, and state dir.
class ServiceTest < Minitest::Test
  def test_launchd_plist_runs_the_foreground_proxy_on_the_port
    plist = Portless::Service.launchd_plist(443, true)
    assert_includes plist, "<key>Label</key><string>rb.portless.proxy</string>"
    assert_includes plist, "<string>--foreground</string>"
    assert_includes plist, "<string>443</string>"
    assert_includes plist, "<string>--tls</string>"
    assert_includes plist, "<key>RunAtLoad</key><true/>"
    assert_includes plist, "<key>KeepAlive</key><true/>"
  end

  def test_systemd_unit_runs_the_foreground_proxy
    unit = Portless::Service.systemd_unit(80, false)
    assert_includes unit, "ExecStart="
    assert_includes unit, "proxy start --foreground --port 80 --no-tls"
    assert_includes unit, "Restart=on-failure"
    assert_includes unit, "WantedBy=multi-user.target"
  end
end
