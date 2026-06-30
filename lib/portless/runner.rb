# frozen_string_literal: true

module Portless
  # `rb-portless run <cmd>`: pick a free backend port, inject PORT/HOST, ensure
  # the proxy is up, register the named route, run the child in its own process
  # group (forwarding signals), and deregister on exit. Rails/puma respect PORT
  # natively. Mirrors portless's runApp/spawnCommand.
  class Runner
    def initialize(command:, config: Config.load, route_store: RouteStore.new, options: {})
      @command = Array(command)
      @config = config
      @route_store = route_store
      @options = options # :lan, :ip, :ngrok, :tailscale, :funnel
    end

    def run
      command = resolved_command
      raise Error, "nothing to run — pass a command, e.g. rb-portless run bin/dev" if command.empty?

      port = @config.app_port&.to_i || FreePort.find
      command = Frameworks.inject(command, port) # --port/--host for vite/astro/etc.
      hostname = @config.hostname

      warn "rb-portless: #{@config.tld_warning}" if @config.tld_warning
      ensure_trusted if @config.tls
      proxy_port = Daemon.ensure_running(tls: @config.tls)
      @route_store.add(hostname: hostname, port: port, pid: Process.pid, force: true)

      url = display_url(hostname, proxy_port)
      rows = [ [ "Local", url, :cyan ] ]
      rows.concat(lan_rows(port, proxy_port))
      rows.concat(share_rows(hostname, port))
      Banner.app(rows: rows, backend_port: port)

      status = supervise(command, port, url)
      exit(status)
    ensure
      teardown
      @route_store.remove(hostname, owner_pid: Process.pid) if hostname
    end

    private

    def display_url(hostname, proxy_port)
      scheme = @config.tls ? "https" : "http"
      default = @config.tls ? Constants::HTTPS_PORT : Constants::HTTP_PORT
      suffix = proxy_port && proxy_port != default ? ":#{proxy_port}" : ""
      "#{scheme}://#{hostname}#{suffix}"
    end

    # ── LAN mode (--lan) ──────────────────────────────────────────────────
    # Register a `<name>.local` route, publish it over mDNS, and surface the URL
    # so phones/tablets on the Wi-Fi can reach the app.
    def lan_rows(backend_port, proxy_port)
      return [] unless @options[:lan]

      ip = LanIp.detect(@options[:ip])
      return [ [ "Network", "no LAN IPv4 found", :dim ] ] unless ip

      @lan_host = "#{@config.name}.local"
      @route_store.add(hostname: @lan_host, port: backend_port, pid: Process.pid, force: true)
      @mdns_pid = Mdns.publish(@lan_host, ip)
      warn "rb-portless: trust #{State.ca_cert} on the device for HTTPS over the LAN" if @config.tls
      [ [ "Network", display_url(@lan_host, proxy_port), :green ] ]
    end

    # ── Public sharing (--ngrok / --tailscale / --funnel) ─────────────────
    def share_rows(hostname, backend_port)
      rows = []
      if @options[:ngrok] && (@ngrok = Share::Ngrok.start(hostname: hostname, backend_port: backend_port))
        rows << [ "Public", @ngrok[:url], :green ]
      end
      if (@options[:tailscale] || @options[:funnel]) &&
         (@tailscale = Share::Tailscale.start(backend_port: backend_port, funnel: @options[:funnel]))
        rows << [ @options[:funnel] ? "Funnel" : "Tailnet", @tailscale[:url], :green ]
      end
      rows
    end

    def teardown
      Mdns.unpublish(@mdns_pid)
      @route_store.remove(@lan_host, owner_pid: Process.pid) if @lan_host
      Share::Ngrok.stop(@ngrok) if @ngrok
      Share::Tailscale.stop(@tailscale) if @tailscale
    end

    # Trust the local CA on first run (like portless), so HTTPS works without
    # browser warnings out of the box. Interactive only — macOS prompts for
    # keychain auth; in CI/no-TTY we skip with a hint rather than hang. Never
    # blocks the run if trusting fails.
    def ensure_trusted
      return if Trust.trusted?

      unless Privilege.interactive?
        warn "rb-portless: CA not trusted — run `rb-portless trust` (HTTPS shows warnings until then)"
        return
      end

      warn "rb-portless: trusting the local CA (first run)…"
      Trust.install!
    rescue Portless::Error => e
      warn "rb-portless: couldn't auto-trust the CA (#{e.message}) — run `rb-portless trust`"
    end

    # Run the child in its own process group so we can signal the whole tree,
    # forwarding INT/TERM and propagating its exit status.
    def supervise(command, port, url)
      child = Process.spawn(child_env(port, url), *command, pgroup: true)

      %w[INT TERM].each do |sig|
        trap(sig) { signal_group(child, sig) }
      end

      _pid, status = Process.wait2(child)
      status.exitstatus || (status.termsig ? 128 + status.termsig : 1)
    rescue Errno::ENOENT
      raise Error, "command not found: #{command.first}"
    end

    def signal_group(child, sig)
      Process.kill(sig, -Process.getpgid(child))
    rescue StandardError
      nil
    end

    def child_env(port, url)
      {
        "PORT" => port.to_s,
        "HOST" => "127.0.0.1",
        "PORTLESS_URL" => url,
        # Let the app's own server-side TLS verification trust our CA.
        "SSL_CERT_FILE" => (File.exist?(State.ca_cert) ? State.ca_cert : nil)
      }.compact
    end

    # Explicit command wins; bare `rb-portless` falls back to the project's dev
    # runner (bin/dev, then bin/rails server).
    def resolved_command
      return @command unless @command.empty?
      return [ "bin/dev" ] if File.executable?("bin/dev")
      return [ "bin/rails", "server" ] if File.executable?("bin/rails")

      []
    end
  end
end
