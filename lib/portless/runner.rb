# frozen_string_literal: true

module Portless
  # One app through the proxy: tunnel/tailscale readiness, proxy auto-start or
  # config-mismatch warning, route registration (one hostname per TLD), child
  # env, spawn, self-daemonized handoff, cleanup. Mirrors portless's runApp.
  class Runner
    EXIT_TIMEOUT = 2.0

    # Shareable process tunnels (PROCESS_TUNNELS): provider key, label, env
    # flag, route url/pid fields.
    def self.process_tunnels
      Tunnel::PROCESS_TUNNELS.map do |t|
        t.merge(provider: t[:name])
      end
    end

    AutoInfo = Struct.new(:name_source, :base_name, :prefix, :prefix_source, keyword_init: true)

    def self.build_hostnames(name, tlds, target_tlds = nil)
      Utils.parse_hostnames(name, tlds.uniq, target_tlds)
    end

    def self.format_vite_allowed_hosts(tlds) = tlds.map { |t| ".#{t}" }.join(",")

    def self.add_routes(store, hostnames, port, pid, force = false, upstream = nil)
      store.recover_corrupt_routes_file
      registered = []
      killed = []
      begin
        hostnames.each do |hostname|
          k = store.add_route(hostname: hostname, port: port, pid: pid, force: force, upstream: upstream)
          registered << hostname
          killed << k if k
        end
      rescue StandardError
        registered.each do |h|
          store.remove_route(h, owner_pid: pid)
        rescue StandardError
          nil
        end
        raise
      end
      killed.uniq
    end

    def self.remove_routes(store, hostnames, owner_pid = nil)
      hostnames.each do |h|
        store.remove_route(h, owner_pid: owner_pid)
      rescue StandardError
        nil
      end
    end

    def initialize(store:, proxy_port:, state_dir:, name:, command_args:, tls:, tlds:, force: false,
                   auto_info: nil, desired_port: nil, lan_mode: false, lan_ip: nil)
      @store = store
      @proxy_port = proxy_port
      @state_dir = state_dir
      @name = name
      @command_args = command_args.dup
      @tls = tls
      @tlds = tlds
      @force = force
      @auto_info = auto_info
      @desired_port = desired_port
      @lan_mode = lan_mode
      @lan_ip = lan_ip
    end

    # Returns the exit code.
    def run
      @store.recover_corrupt_routes_file
      warn Colors.bold("\nrb-portless\n", io: $stderr)

      wants_funnel = Utils.env_enabled?("PORTLESS_FUNNEL")
      wants_tailscale = wants_funnel || Utils.env_enabled?("PORTLESS_TAILSCALE")
      tunnels = self.class.process_tunnels.select { |t| Utils.env_enabled?(t[:env]) }

      # Readiness before auto-starting the proxy: no point starting it if a
      # share will fail afterwards.
      ts_base_url = ensure_tailscale_ready(wants_funnel) if wants_tailscale
      return 1 if wants_tailscale && ts_base_url.nil?

      tunnels.each do |t|
        Tunnel.check!(t[:provider])
      rescue Error => e
        warn Colors.red("Error: #{e.message}", io: $stderr)
        Tunnel.print_hint(t, e.message)
        return 1
      end

      desired = Daemon.resolve_desired_state(@lan_mode)
      self.class.build_hostnames(@name, @tlds) # validate before auto-starting the proxy
      result = Daemon.ensure_proxy_running(@proxy_port, @tls, desired)
      if result[:started]
        state = CLI.state_struct(result[:state])
        @proxy_port = state.port
        @state_dir = state.dir
        @tlds = state.tlds
        @tls = state.tls
        @lan_mode = state.lan_mode
        @lan_ip = state.lan_ip
        @store = RouteStore.new(@state_dir, on_warning: ->(msg) { warn Colors.yellow(msg, io: $stderr) })
        @store.recover_corrupt_routes_file
        CLI.handle_trust if @tls && !Trust.trusted?(@state_dir)
      else
        running = Daemon.read_current_proxy_config(@state_dir)
        messages = Daemon.proxy_config_mismatch_messages(desired[:desired_config], running, desired[:explicit])
        Daemon.print_proxy_config_mismatch(@proxy_port, desired[:desired_config], messages) unless messages.empty?
        @lan_mode = running[:lan_mode]
        @lan_ip = running[:lan_ip]
        @tlds = running[:tlds]
        warn Colors.gray("  Proxy is running", io: $stderr)
      end

      env_tlds = desired[:env_tlds] || []
      if desired.dig(:explicit, :tlds) && env_tlds != @tlds
        warn Colors.yellow("Warning: PORTLESS_TLD=#{env_tlds.join(',')} but the running proxy uses " \
                           "#{@tlds.map { |t| ".#{t}" }.join(', ')}.", io: $stderr)
      end

      hostnames = self.class.build_hostnames(@name, @tlds)
      hostname = hostnames.first
      gray = ->(s) { warn Colors.gray(s, io: $stderr) }
      gray.("  #{hostnames.join(', ')} #{@lan_ip ? "(LAN: #{@lan_ip})" : '(auto-resolves to 127.0.0.1)'}")
      if @auto_info
        gray.("  Name \"#{@auto_info.base_name}\" (from #{@auto_info.name_source})")
        gray.("  Prefix \"#{@auto_info.prefix}\" (from #{@auto_info.prefix_source})") if @auto_info.prefix
      end

      port = @desired_port || FreePort.find
      warn(@desired_port ? "  Using port #{port} (fixed)" : "  Using port #{port}")

      stop_orphaned_process_groups

      begin
        killed = self.class.add_routes(@store, hostnames, port, Process.pid, @force)
        report_hosts_sync(hostnames)
      rescue RouteConflictError => e
        warn Colors.red("Error: #{e.message}", io: $stderr)
        return 1
      end
      warn Colors.yellow("Killed existing process(es): #{killed.join(', ')}", io: $stderr) unless killed.empty?
      @registered = hostnames

      final_url = Utils.format_url(hostname, @proxy_port, @tls)
      all_urls = hostnames.map { |h| Utils.format_url(h, @proxy_port, @tls) }
      warn Colors.bold("\n  -> #{final_url}\n", io: $stderr)
      all_urls.drop(1).each { |u| warn "  also -> #{u}" }
      warn "" if all_urls.length > 1
      if @lan_ip
        warn "  LAN -> #{final_url}"
        gray.("  (accessible from other devices on the same WiFi network)\n")
      end

      tailscale_url = start_tailscale(hostname, port, wants_funnel, ts_base_url) if wants_tailscale
      tunnel_urls = start_tunnels(tunnels, hostname, port)
      return 1 if tunnel_urls.nil?

      framework = Frameworks.resolve_framework_basename(@command_args)
      expo_lan = framework == "expo" && (@lan_mode || Utils.lan_env_enabled?)
      host_bind = expo_lan ? nil : "127.0.0.1"
      ENV["PORTLESS_LAN"] = "1" if @lan_mode && !ENV["PORTLESS_LAN"]

      Frameworks.inject_package_script_framework_flags(@command_args, port)
      Frameworks.inject_framework_flags(@command_args, port)

      ca_env = ca_env_vars
      ca_fragment = ca_env["NODE_EXTRA_CA_CERTS"] ? " NODE_EXTRA_CA_CERTS=\"#{ca_env['NODE_EXTRA_CA_CERTS']}\"" : ""
      gray.("Running: PORT=#{port}#{host_bind ? " HOST=#{host_bind}" : ''} PORTLESS_URL=#{final_url}" \
            "#{ca_fragment} #{@command_args.join(' ')}\n")

      preexisting = PortOwner.port_listening?(port) ? PortOwner.pid_on_port(port) : nil
      env = {
        "PORT" => port.to_s,
        "HOST" => host_bind,
        "PORTLESS_URL" => final_url,
        "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => self.class.format_vite_allowed_hosts(@tlds)
      }
      env.delete("HOST") unless host_bind
      env["PORTLESS_LAN"] = "1" if @lan_mode
      env["PORTLESS_TAILSCALE_URL"] = tailscale_url if tailscale_url
      tunnel_urls.each { |t, url| env["#{t[:env]}_URL"] = url if url }
      env.merge!(ca_env)

      RunSupport.spawn_command(
        @command_args,
        env: env,
        on_spawn: lambda do |pid|
          start = PortOwner.start_time(pid)
          hostnames.each do |h|
            @store.update_route(h, child_pgid: pid, child_start_time: start)
          rescue StandardError
            nil
          end
        end,
        on_exit: ->(pid, code) { transfer_routes_to_daemon(hostnames, port, pid, preexisting, code.zero?) },
        on_cleanup: -> { cleanup(hostnames, wants_funnel) }
      )
    rescue Error => e
      # Tunnel start failures are fatal with upstream's hint.
      warn Colors.red("Error: #{e.message}", io: $stderr)
      e.hints.each { |h| warn Colors.blue(h, io: $stderr) } if e.respond_to?(:hints)
      cleanup(@registered, wants_funnel) if @registered
      1
    end

    private

    # Upstream sets NODE_EXTRA_CA_CERTS when TLS is on and it isn't already set;
    # SSL_CERT_FILE (combined bundle, CaBundle) is the Ruby analogue under the
    # same conditions.
    def ca_env_vars
      env = {}
      return env unless @tls

      ca_path = File.join(@state_dir, "ca.pem")
      env["NODE_EXTRA_CA_CERTS"] = ca_path if !ENV["NODE_EXTRA_CA_CERTS"] && File.exist?(ca_path)
      if !ENV["SSL_CERT_FILE"] && File.exist?(ca_path)
        bundle = begin
          CaBundle.path
        rescue StandardError
          nil
        end
        env["SSL_CERT_FILE"] = bundle if bundle
      end
      env
    end

    def report_hosts_sync(hostnames)
      Daemon.report_hosts_sync(hostnames, @proxy_port, @tls, @lan_mode) { |msg| warn Colors.yellow(msg, io: $stderr) }
    end

    def ensure_tailscale_ready(funnel)
      Share::Tailscale.ensure_ready!(require_funnel: funnel, require_https: true)[:base_url]
    rescue Error => e
      warn Colors.red("Error: #{e.message}", io: $stderr)
      if e.message.include?("not found")
        warn "Install Tailscale: https://tailscale.com/download"
      elsif !e.message.include?("not enabled on your tailnet")
        warn "Make sure Tailscale is connected:"
        warn "  tailscale up"
      end
      nil
    end

    def start_tailscale(hostname, port, funnel, base_url)
      @tailscale = Share::Tailscale.start(app_port: port, funnel: funnel, base_url: base_url)
      label = funnel ? "Funnel (public)" : "Tailscale"
      warn "  #{label} -> #{@tailscale.url}"
      warn Colors.gray(funnel ? "  (accessible from the public internet via Tailscale Funnel)\n" \
                              : "  (accessible from your tailnet)\n", io: $stderr)
      begin
        @store.update_route(hostname, tailscale_url: @tailscale.url, tailscale_https_port: @tailscale.https_port,
                                      tailscale_funnel: funnel || nil)
      rescue StandardError
        nil
      end
      @tailscale.url
    end

    # => [[tunnel, url], ...] or nil after a fatal start failure.
    def start_tunnels(tunnels, hostname, port)
      @tunnel_handles = []
      tunnels.map do |t|
        handle = Tunnel.start(t[:provider], app_port: port, host: hostname, state_dir: @state_dir) do |code, signal|
          tunnel_exited(t, hostname, code, signal)
        end
        @tunnel_handles << handle
        warn "  #{t[:label]} -> #{handle.url}"
        warn Colors.gray("  (accessible from the public internet via #{t[:via]})\n", io: $stderr)
        begin
          @store.update_route(hostname, t[:url_field] => handle.url, t[:pid_field] => handle.pid)
        rescue StandardError
          nil
        end
        [ t, handle.url ]
      rescue Error => e
        warn Colors.red("Error: #{e.message}", io: $stderr)
        Tunnel.print_hint(t, e.message)
        cleanup(@registered, nil)
        return nil
      end
    end

    def tunnel_exited(t, hostname, code, signal)
      return if @stopping_tunnels

      suffix = signal ? " (signal #{signal})" : (code.nil? ? "" : " (exit #{code})")
      warn Colors.yellow("Warning: #{t[:label]} tunnel for #{hostname} stopped#{suffix}. " \
                         "Removing its public URL from the route list.", io: $stderr)
      @store.update_route(hostname, t[:url_field] => nil, t[:pid_field] => nil)
    rescue StandardError
      nil
    end

    def cleanup(hostnames, _funnel)
      @stopping_tunnels = true
      (@tunnel_handles || []).each do |h|
        h.stop
      rescue StandardError
        nil
      end
      begin
        @tailscale&.stop
      rescue StandardError
        nil
      end
      self.class.remove_routes(@store, hostnames || [], Process.pid)
    end

    # Self-daemonizing command: its launcher exited but a listener remains on
    # the port — hand the routes to that pid (issue #411).
    def transfer_routes_to_daemon(hostnames, port, group_id, preexisting, exited_cleanly)
      listener = ProcessGroup.find_self_daemonized_listener(port, group_id, EXIT_TIMEOUT, exited_cleanly)
      return if listener.nil? || listener == preexisting

      transferred = hostnames.map do |h|
        @store.transfer_route(h, Process.pid, listener)
      rescue StandardError
        false
      end.any?
      return unless transferred

      warn Colors.yellow("Command exited but PID #{listener} is still serving port #{port}. Keeping " \
                         "#{hostnames.first} routed to it. Stop it with: kill #{listener}", io: $stderr)
    end

    # Stop dev servers left by sessions that died without cleanup.
    def stop_orphaned_process_groups
      return if @store.respond_to?(:untrusted_reason) && @store.untrusted_reason

      orphaned = @store.find_stale_routes
      stops = CLI.stop_recorded_groups(orphaned, "TERM")
      orphaned.each do |route|
        pgid = route.child_pgid
        stop = pgid && stops[pgid]
        @store.record_stale_orphan(route, stop.survivor[:pid], stop.survivor[:start_time]) if stop&.survivor
        if stop && !%w[gone stopped].include?(stop.state)
          warn Colors.yellow(
            if stop.state == "survived"
              "Orphaned dev server (process group #{pgid}) did not exit. Run: rb-portless prune --force"
            else
              "Orphaned process group #{pgid} could not be verified; nothing was stopped. Run: rb-portless prune"
            end, io: $stderr
          )
          next
        end
        if stop&.state == "stopped"
          warn Colors.yellow("Stopped orphaned dev server from a previous session (process group #{pgid})",
                             io: $stderr)
        end
        Tunnel.stop_recorded(route, verify: true).each do |t|
          warn Colors.yellow("Stopped orphaned #{t[:label]} tunnel from a previous session " \
                             "(pid #{route[t[:pid_field]]})", io: $stderr)
        end
        @store.remove_stale_route(route.hostname, route.pid) if route.tailscale_https_port.nil?
      end
    rescue StandardError
      nil
    end
  end
end
