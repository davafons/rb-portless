# frozen_string_literal: true

require "socket"

module Portless
  # The machine's primary private LAN IPv4 — so phones/tablets on the same Wi-Fi
  # can reach the dev app. Pure stdlib. Mirrors portless's lan-ip.ts.
  module LanIp
    module_function

    def detect(override = nil)
      return override if override.to_s.strip != ""

      Socket.ip_address_list
            .find { |addr| addr.ipv4? && addr.ipv4_private? && !addr.ipv4_loopback? }
            &.ip_address
    end
  end
end
