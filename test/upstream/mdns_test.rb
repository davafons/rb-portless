# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/core"

# Mirror of packages/portless/src/mdns.test.ts
# Fake timers → a short real interval; "advance by one tick" waits for the
# poll to observe the new value.
describe "startLanIpMonitor" do
  include UpstreamCore

  def interval = 0.05

  it "reports LAN IP changes, loss, and recovery" do
    current_ip = "192.168.1.42"
    changes = []
    monitor = Portless::Mdns.start_lan_ip_monitor(
      initial_ip: current_ip,
      interval: interval,
      resolve_ip: -> { current_ip },
      on_change: ->(next_ip, previous_ip) { changes << [ next_ip, previous_ip ] }
    )

    current_ip = "192.168.1.77"
    wait_until { changes.size == 1 }
    current_ip = nil
    wait_until { changes.size == 2 }
    current_ip = "192.168.1.99"
    wait_until { changes.size == 3 }

    monitor.stop

    assert_equal [
      [ "192.168.1.77", "192.168.1.42" ],
      [ nil, "192.168.1.77" ],
      [ "192.168.1.99", nil ]
    ], changes
  end

  it "does not notify when the LAN IP is unchanged" do
    on_change = spy
    calls = 0
    monitor = Portless::Mdns.start_lan_ip_monitor(
      initial_ip: "192.168.1.42",
      interval: interval,
      resolve_ip: -> { calls += 1; "192.168.1.42" },
      on_change: on_change
    )

    wait_until { calls >= 3 }
    monitor.stop

    refute on_change.called?
  end

  it "invokes onError when resolveIp throws" do
    errors = []
    monitor = Portless::Mdns.start_lan_ip_monitor(
      initial_ip: "192.168.1.42",
      interval: interval,
      resolve_ip: -> { raise "network gone" },
      on_change: ->(*) { },
      on_error: ->(err) { errors << err }
    )

    wait_until { errors.size >= 1 }
    monitor.stop

    assert_equal 1, errors.size
    assert_equal "network gone", errors[0].message
  end

  it "stops polling after stop is called" do
    current_ip = "192.168.1.42"
    on_change = spy
    monitor = Portless::Mdns.start_lan_ip_monitor(
      initial_ip: current_ip,
      interval: interval,
      resolve_ip: -> { current_ip },
      on_change: on_change
    )

    monitor.stop
    current_ip = "192.168.1.77"
    sleep interval * 3

    refute on_change.called?
  end
end
