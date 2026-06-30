# frozen_string_literal: true

module Portless
  # Publish `<name>.local → LAN IP` over mDNS so phones/tablets resolve it on the
  # local network (`.localhost` only works on the dev machine). Shells out to the
  # OS responder — `dns-sd` on macOS, `avahi-publish` on Linux — and returns the
  # publisher pid (kill it to unpublish). A no-op (with a hint) if neither tool
  # is present. Mirrors portless's mdns.ts.
  module Mdns
    module_function

    def publish(hostname, ip)
      return nil unless ip

      cmd = command_for(hostname, ip)
      unless cmd
        warn "rb-portless: no mDNS responder (dns-sd / avahi-publish) — `#{hostname}` won't resolve on the LAN"
        return nil
      end

      pid = Process.spawn(*cmd, out: File::NULL, err: File::NULL)
      Process.detach(pid)
      pid
    rescue StandardError
      nil
    end

    def unpublish(pid)
      Process.kill("TERM", pid) if pid
    rescue StandardError
      nil
    end

    def command_for(hostname, ip)
      if Portless.which("dns-sd")
        # Proxy-register an A record: name type domain port host ip.
        [ "dns-sd", "-P", hostname.sub(/\.local\z/, ""), "_http._tcp", "local", "80", hostname, ip ]
      elsif Portless.which("avahi-publish")
        [ "avahi-publish", "-a", "-R", hostname, ip ]
      end
    end
  end
end
