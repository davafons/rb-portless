# frozen_string_literal: true

require "socket"

module Portless
  # The local IPv4 used for the default route, skipping loopback and virtual
  # NICs (Hyper-V, Docker bridges, all-zero MACs) — what phones on the same
  # Wi-Fi can reach. Mirrors portless's lan-ip.ts (itself after lan-network).
  module LanIp
    module_function

    PROBE_HOST = "1.1.1.1"
    PROBE_PORT = 53
    NO_ROUTE_IP = "0.0.0.0"

    # UDP "connect" (no packets sent) to learn the default-route source IP.
    # lan-ip.ts probeDefaultRouteIPv4. Raises when there is no route.
    def probe_default_route_ipv4
      sock = UDPSocket.new(Socket::AF_INET)
      sock.connect(PROBE_HOST, PROBE_PORT)
      addr = sock.local_address.ip_address
      raise Error, "No route to host" if addr.nil? || addr.empty? || addr == NO_ROUTE_IP

      addr
    ensure
      sock&.close
    end

    def parse_mac(mac)
      mac.to_s.split(":").first(16).map { |seq| seq.to_i(16) }
    end

    # lan-ip.ts isInternalInterface.
    def internal_interface?(iname, mac, internal)
      return true if internal

      bytes = parse_mac(mac)
      return true if bytes.all?(&:zero?)
      return true if bytes[0].zero? && bytes[1] == 21 && bytes[2] == 93 # Hyper-V 00:15:5d
      return true if iname.include?("vEthernet") || iname.match?(/\Abridge\d+\z/)

      false
    end

    # [{iname:, address:, mac:, internal:}] for every IPv4 interface address,
    # with the MAC taken from the interface's link-layer entry.
    def interfaces
      ifaddrs = Socket.getifaddrs
      macs = {}
      ifaddrs.each do |ifa|
        next unless ifa.addr
        next if ifa.addr.ipv4? || ifa.addr.ipv6?

        mac = ifa.addr.inspect_sockaddr[/(?:[0-9a-f]{2}:){5}[0-9a-f]{2}/i]
        macs[ifa.name] = mac if mac
      end
      ifaddrs.filter_map do |ifa|
        next unless ifa.addr&.ipv4?

        { iname: ifa.name, address: ifa.addr.ip_address, mac: macs[ifa.name] || "00:00:00:00:00:00",
          internal: ifa.flags.anybits?(Socket::IFF_LOOPBACK) }
      end
    rescue StandardError
      []
    end

    def find_interface_row_for_ip(ip, rows = interfaces)
      rows.find { |row| row[:address] == ip }
    end

    # Detect the LAN IP used for the default IPv4 route, or nil.
    # lan-ip.ts getLocalNetworkIp.
    def local_network_ip(probe: method(:probe_default_route_ipv4), rows: nil)
      ip = probe.call
      return nil if ip == "127.0.0.1"

      row = find_interface_row_for_ip(ip, rows || interfaces)
      return nil unless row
      return nil if row[:address] == "127.0.0.1"
      return nil if internal_interface?(row[:iname], row[:mac], row[:internal])

      row[:address]
    rescue StandardError
      nil
    end

    # Back-compat: explicit override wins, else auto-detect.
    def detect(override = nil)
      return override if override.to_s.strip != ""

      local_network_ip
    end
  end
end
