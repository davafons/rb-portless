# frozen_string_literal: true

module Portless
  # Publish `<name>.local → LAN IP` over mDNS so other devices resolve it. The
  # proxy daemon (LAN mode) publishes one record per route by keeping a
  # `dns-sd -P` (macOS) / `avahi-publish-address -R` (Linux) child alive per
  # hostname. Mirrors portless's mdns.ts.
  module Mdns
    module_function

    LAN_IP_POLL_INTERVAL = 5

    @publishers = {}
    @mutex = Mutex.new

    # {command:, probe_args:, missing_reason:, build_args: ->(fqdn, name, port, ip)}
    def publisher(platform = Privilege.host_platform)
      case platform
      when "darwin"
        { command: "dns-sd", probe_args: [ "-h" ], missing_reason: "dns-sd not found",
          build_args: ->(fqdn, name, port, ip) { [ "-P", name, "_http._tcp", "local", port.to_s, fqdn, ip ] } }
      when "linux"
        { command: "avahi-publish-address", probe_args: [ "--help" ],
          missing_reason: "avahi-publish-address not found. Install avahi-utils: sudo apt install avahi-utils",
          build_args: ->(fqdn, _name, _port, ip) { [ "-R", fqdn, ip ] } }
      end
    end

    # mdns.ts isMdnsSupported → {supported:, reason:}
    def supported(platform = Privilege.host_platform, has_command: method(:command?))
      pub = publisher(platform)
      return { supported: false, reason: "mDNS publishing is not supported on this platform" } unless pub
      return { supported: false, reason: pub[:missing_reason] } unless has_command.call(pub[:command])

      { supported: true }
    end

    def supported? = supported[:supported]

    def command?(command) = Portless.which(command)

    # "api.myapp.local" → "api.myapp"
    def service_name(hostname) = hostname.sub(/\.local\z/, "")

    def build_command(hostname, port, ip, platform = Privilege.host_platform)
      pub = publisher(platform) or return nil
      fqdn = hostname.end_with?(".local") ? hostname : "#{hostname}.local"
      [ pub[:command], *pub[:build_args].call(fqdn, service_name(fqdn), port, ip) ]
    end

    # Publish an mDNS record for a hostname (idempotent). mdns.ts publish.
    def publish(hostname, port, ip, on_error = nil)
      @mutex.synchronize do
        return if @publishers.key?(hostname)

        cmd = build_command(hostname, port, ip) or return
        begin
          pid = Process.spawn(*cmd, in: File::NULL, out: File::NULL, err: File::NULL)
        rescue Errno::ENOENT
          on_error&.call(publisher[:missing_reason])
          return
        rescue SystemCallError => e
          on_error&.call("mDNS publish error for #{hostname}: #{e.message}")
          return
        end
        @publishers[hostname] = pid
        Thread.new do
          Process.wait(pid)
        rescue StandardError
          nil
        ensure
          @mutex.synchronize { @publishers.delete(hostname) if @publishers[hostname] == pid }
        end
      end
    end

    def unpublish(hostname)
      pid = @mutex.synchronize { @publishers.delete(hostname) } or return
      Process.kill("TERM", pid)
    rescue StandardError
      nil
    end

    def cleanup_all
      pids = @mutex.synchronize do
        values = @publishers.values
        @publishers.clear
        values
      end
      pids.each do |pid|
        Process.kill("TERM", pid)
      rescue StandardError
        nil
      end
    end

    def published = @mutex.synchronize { @publishers.keys }

    # Poll the default LAN IP and call on_change(next, previous) when it moves.
    # Used only for auto-detected LAN mode. mdns.ts startLanIpMonitor.
    # Returns an object responding to #stop.
    def start_lan_ip_monitor(initial_ip:, on_change:, on_error: nil, interval: LAN_IP_POLL_INTERVAL,
                             resolve_ip: -> { LanIp.local_network_ip })
      LanIpMonitor.new(initial_ip, on_change, on_error, interval, resolve_ip)
    end

    class LanIpMonitor
      def initialize(initial_ip, on_change, on_error, interval, resolve_ip)
        @current = initial_ip
        @stopped = false
        @thread = Thread.new do
          until @stopped
            sleep interval
            break if @stopped

            begin
              nxt = resolve_ip.call
              next if @stopped || nxt == @current

              previous = @current
              @current = nxt
              on_change.call(nxt, previous)
            rescue StandardError => e
              on_error&.call(e)
            end
          end
        end
      end

      def stop
        @stopped = true
        @thread.kill
      end
    end
  end
end
