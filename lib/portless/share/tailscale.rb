# frozen_string_literal: true

require "json"
require "open3"
require "set"
require "timeout"

module Portless
  module Share
    # Share an app on the tailnet (`tailscale serve`) or publicly (`tailscale
    # funnel`). Readiness is checked before the proxy starts; registration
    # never clobbers existing serve config (free port picked from `serve status
    # --json`, including Foreground sessions), and teardown removes only the
    # one registration recorded on the route (https port + funnel flag).
    # Mirrors portless's tailscale.ts.
    module Tailscale
      module_function

      BINARY = "tailscale"
      COMMAND_TIMEOUT = 30
      PREFERRED_SERVE_PORTS = [ 443, 8443, 8444, 8445, 8446, 8447, 8448, 8449, 8450 ].freeze
      FUNNEL_PORTS = [ 443, 8443, 10_000 ].freeze
      NOT_FOUND = "Tailscale CLI not found. Install Tailscale (https://tailscale.com/download) and ensure " \
                  "`tailscale` is on PATH."
      CONFLICT_MESSAGES = {
        "serve" => "Stop the existing serve or let rb-portless auto-assign a different port.",
        "funnel" => "Tailscale Funnel supports ports 443, 8443, and 10000."
      }.freeze

      # → {status:, stdout:, stderr:, error:}
      def default_runner(args)
        stdout, stderr, status = Timeout.timeout(COMMAND_TIMEOUT) { Open3.capture3(BINARY, *args) }
        { status: status.exitstatus, stdout: stdout, stderr: stderr }
      rescue Timeout::Error
        { status: nil, stdout: "", stderr: "", error: Errno::ETIMEDOUT.new("spawnSync #{BINARY}") }
      rescue SystemCallError => e
        { status: nil, stdout: "", stderr: "", error: e }
      end

      # Resolve an existing Windows `.cmd` shim on PATH. tailscale.ts findWindowsCmdShim.
      def find_windows_cmd_shim(name, env = ENV)
        (env["PATH"] || env["Path"] || "").split(File::PATH_SEPARATOR).each do |dir|
          next if dir.empty?

          candidate = File.join(dir, "#{name}.cmd")
          return candidate if File.file?(candidate)
        end
        nil
      end

      def normalize_space(value) = value.to_s.strip.gsub(/\s+/, " ")
      def trim_dot(value) = value.end_with?(".") ? value[0...-1] : value

      def details_of(result)
        normalize_space(result[:stderr].to_s.empty? ? result[:stdout] : result[:stderr])
      end

      def run_or_throw(args, action, runner)
        result = runner.call(args)
        if result[:error]
          raise Error, NOT_FOUND if result[:error].is_a?(Errno::ENOENT)

          raise Error, "Failed to #{action}: #{result[:error].message}"
        end
        unless result[:status] == 0 # rubocop:disable Style/NumericPredicate
          details = details_of(result)
          raise Error, "Failed to #{action}: #{details.empty? ? 'unknown tailscale error' : details}"
        end
        result
      end

      def parse_status_json(raw)
        JSON.parse(raw)
      rescue JSON::ParserError
        raise Error, "Failed to parse `tailscale status --json` output."
      end

      def status_to_dns_name(status)
        dns = status.dig("Self", "DNSName")
        return trim_dot(dns) if dns.is_a?(String) && !dns.empty?

        host = status.dig("Self", "HostName")
        suffix = status.dig("CurrentTailnet", "MagicDNSSuffix")
        if host.is_a?(String) && !host.empty? && suffix.is_a?(String) && !suffix.empty?
          return "#{host}.#{trim_dot(suffix)}"
        end

        raise Error, "Could not determine Tailscale node DNS name from `tailscale status --json`. " \
                     "Is Tailscale connected?"
      end

      def capability?(status, name)
        matches = lambda do |value|
          down = value.to_s.downcase
          down == name || down.end_with?("/#{name}")
        end
        caps = status.dig("Self", "Capabilities")
        return true if caps.is_a?(Array) && caps.any?(&matches)

        cap_map = status.dig("Self", "CapMap")
        cap_map.is_a?(Hash) && cap_map.keys.any?(&matches)
      end

      # Verify the CLI and connection → {dns_name:, base_url:}. Raises Error.
      # tailscale.ts ensureTailscaleReady.
      def ensure_tailscale_ready(require_funnel: false, require_https: false, runner: method(:default_runner))
        run_or_throw([ "version" ], "check tailscale version", runner)
        status = parse_status_json(run_or_throw([ "status", "--json" ], "read tailscale status", runner)[:stdout])
        dns_name = status_to_dns_name(status)
        if require_https && !capability?(status, "https")
          raise Error, "Tailscale HTTPS is not enabled on your tailnet. Enable HTTPS certificates in " \
                       "Tailscale DNS settings, then run rb-portless again."
        end
        if require_funnel && !capability?(status, "funnel")
          node_id = status.dig("Self", "ID")
          link = node_id.is_a?(String) && !node_id.empty? ? " Visit https://login.tailscale.com/f/funnel?node=#{node_id} to enable it." : ""
          raise Error, "Tailscale Funnel is not enabled on your tailnet. Enable Funnel for this node, then run " \
                       "rb-portless again.#{link}"
        end
        { dns_name: dns_name, base_url: "https://#{dns_name}" }
      end

      # HTTPS ports in use by serve/funnel, incl. Foreground sessions (#499).
      def get_used_serve_ports(runner = method(:default_runner)) # rubocop:disable Naming/AccessorMethodName
        result = runner.call([ "serve", "status", "--json" ])
        return Set.new if result[:error] || result[:status] != 0

        config = JSON.parse(result[:stdout])
        sessions = [ config, *(config["Foreground"].is_a?(Hash) ? config["Foreground"].values : []) ]
        ports = Set.new
        sessions.each do |session|
          next unless session.is_a?(Hash)

          (session["Web"] || {}).each_key do |host_port|
            ports << Regexp.last_match(1).to_i if host_port =~ /:(\d+)\z/
          end
          (session["TCP"] || {}).each_key do |port|
            p = Integer(port.to_s, exception: false)
            ports << p if p
          end
        end
        ports
      rescue StandardError
        Set.new
      end

      def find_available_serve_port(used, mode = "serve")
        pool = mode == "funnel" ? FUNNEL_PORTS : PREFERRED_SERVE_PORTS
        free = pool.find { |port| !used.include?(port) }
        return free if free

        if mode == "funnel"
          raise Error, "All Tailscale Funnel ports are in use (443, 8443, 10000). Stop an existing funnel to " \
                       "free a port."
        end
        port = PREFERRED_SERVE_PORTS.last + 1
        port += 1 while used.include?(port)
        port
      end

      def conflict_error?(stderr, stdout)
        text = "#{stderr}\n#{stdout}".downcase
        [ "already in use", "already exists", "port conflict", "address already" ].any? { |s| text.include?(s) }
      end

      def funnel_not_enabled_error?(stderr, stdout)
        "#{stderr}\n#{stdout}".downcase.include?("funnel is not enabled on your tailnet")
      end

      def format_funnel_not_enabled_error(stderr, stdout)
        details = normalize_space("#{stderr}\n#{stdout}")
        "Tailscale Funnel is not enabled on your tailnet. Enable Funnel for this node, then run rb-portless again." \
          "#{details.empty? ? '' : " Tailscale said: #{details}"}"
      end

      def register(mode, local_port, https_port, runner = method(:default_runner))
        result = runner.call([ mode, "--bg", "--yes", "--https=#{https_port}", "http://127.0.0.1:#{local_port}" ])
        if result[:error]
          raise Error, NOT_FOUND if result[:error].is_a?(Errno::ENOENT)
          if mode == "funnel" && funnel_not_enabled_error?(result[:stderr], result[:stdout])
            raise Error, format_funnel_not_enabled_error(result[:stderr], result[:stdout])
          end
          if mode == "funnel" && result[:error].is_a?(Errno::ETIMEDOUT)
            raise Error, "Tailscale Funnel registration timed out. Make sure Funnel is enabled on your tailnet, " \
                         "then run rb-portless again."
          end

          raise Error, "Failed to register tailscale #{mode}: #{result[:error].message}"
        end
        return if result[:status] == 0 # rubocop:disable Style/NumericPredicate

        if mode == "funnel" && funnel_not_enabled_error?(result[:stderr], result[:stdout])
          raise Error, format_funnel_not_enabled_error(result[:stderr], result[:stdout])
        end
        if conflict_error?(result[:stderr], result[:stdout])
          raise Error, "Tailscale #{mode == 'funnel' ? 'Funnel ' : ''}HTTPS port #{https_port} is already in use. " \
                       "#{CONFLICT_MESSAGES[mode]}"
        end
        details = details_of(result)
        raise Error, "Failed to register tailscale #{mode} on port #{https_port}: " \
                     "#{details.empty? ? 'unknown tailscale error' : details}"
      end

      def unregister(mode, https_port, ignore_missing: false, runner: method(:default_runner))
        result = runner.call([ mode, "--yes", "--https=#{https_port}", "off" ])
        if result[:error]
          return if result[:error].is_a?(Errno::ENOENT)

          raise Error, "Failed to remove tailscale #{mode}: #{result[:error].message}"
        end
        return if result[:status] == 0 # rubocop:disable Style/NumericPredicate

        text = "#{result[:stderr]}\n#{result[:stdout]}".downcase
        missing = [ "not found", "no serve config", "nothing to remove", "does not exist" ].any? { |s| text.include?(s) }
        return if ignore_missing && missing

        details = details_of(result)
        raise Error, "Failed to remove tailscale #{mode} on port #{https_port}: " \
                     "#{details.empty? ? 'unknown tailscale error' : details}"
      end

      def register_serve(local_port, https_port, runner: method(:default_runner))
        register("serve", local_port, https_port, runner)
      end

      def register_funnel(local_port, https_port, runner: method(:default_runner))
        register("funnel", local_port, https_port, runner)
      end

      def unregister_serve(https_port, ignore_missing: false, runner: method(:default_runner))
        unregister("serve", https_port, ignore_missing: ignore_missing, runner: runner)
      end

      def unregister_funnel(https_port, ignore_missing: false, runner: method(:default_runner))
        unregister("funnel", https_port, ignore_missing: ignore_missing, runner: runner)
      end

      # Best-effort teardown from route metadata — only the registration that
      # was recorded (tailscaleHttpsPort + tailscaleFunnel). Accepts a route
      # object/hash or keywords. tailscale.ts unregisterTailscale.
      def unregister_tailscale(route = nil, https_port: nil, funnel: nil, runner: method(:default_runner))
        https_port ||= field(route, :tailscale_https_port)
        funnel = field(route, :tailscale_funnel) if funnel.nil?
        return unless https_port

        unregister(funnel ? "funnel" : "serve", https_port.to_i, ignore_missing: true, runner: runner)
      end

      def field(route, name)
        return nil if route.nil?
        return route[name] || route[name.to_s] || route[camel(name)] if route.is_a?(Hash)

        route.respond_to?(name) ? route.public_send(name) : nil
      end

      def camel(name) = name.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }

      def format_tailscale_url(base_url, https_port)
        trimmed = base_url.end_with?("/") ? base_url[0...-1] : base_url
        https_port == 443 ? trimmed : "#{trimmed}:#{https_port}"
      end

      # A registered share. #stop removes exactly this registration.
      Handle = Struct.new(:url, :https_port, :funnel, :runner) do
        def funnel? = !!funnel

        def stop
          Tailscale.unregister(funnel? ? "funnel" : "serve", https_port, ignore_missing: true, runner: runner)
        rescue Error
          nil
        end
      end

      # Upstream runApp's registration loop: pick a free port, retry up to 3×
      # on a port conflict. Raises Error. → Handle
      def start(app_port:, funnel: false, base_url: nil, runner: method(:default_runner), max_attempts: 3)
        base_url ||= ensure_tailscale_ready(require_funnel: funnel, require_https: true, runner: runner)[:base_url]
        https_port = nil
        (1..max_attempts).each do |attempt|
          https_port = find_available_serve_port(get_used_serve_ports(runner), funnel ? "funnel" : "serve")
          begin
            register(funnel ? "funnel" : "serve", app_port, https_port, runner)
            break
          rescue Error => e
            raise unless e.message.include?("already in use") && attempt < max_attempts
          end
        end
        Handle.new(format_tailscale_url(base_url, https_port), https_port, funnel, runner)
      end
    end
  end
end
