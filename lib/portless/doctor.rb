# frozen_string_literal: true

require "json"
require "socket"

module Portless
  # `doctor`: read-only health report with findings ok/warn/fail/info,
  # `--json`, exit 1 on any failure. Mirrors portless's handleDoctor; the
  # runtime check is Ruby >= 3.2 (upstream checks Node.js 24) and reports as
  # `rubyVersion` in JSON.
  class Doctor
    Finding = Struct.new(:status, :message, :hint)
    MIN_RUBY = "3.2"

    # Node's process.platform / process.arch spelling, as upstream reports it.
    def self.node_platform(host_os = RbConfig::CONFIG["host_os"])
      case host_os
      when /darwin/ then "darwin"
      when /linux/ then "linux"
      when /mswin|mingw|cygwin/ then "win32"
      when /freebsd/ then "freebsd"
      else host_os
      end
    end

    def self.node_arch(host_cpu = RbConfig::CONFIG["host_cpu"])
      case host_cpu
      when /\A(arm64|aarch64)\z/ then "arm64"
      when /\A(x86_64|x64|amd64)\z/ then "x64"
      when /\Ai[3-6]86\z/ then "ia32"
      else host_cpu
      end
    end

    def initialize(json: false)
      @json = json
      @findings = []
    end

    def add(status, message, hint = nil) = @findings << Finding.new(status, message, hint)

    def pluralize(count, singular, plural = "#{singular}s") = "#{count} #{count == 1 ? singular : plural}"

    def alive?(pid) = pid.to_i <= 0 || ProcessGroup.running?(pid.to_i)

    def run
      state = begin
        Daemon.discover_state
      rescue StandardError => e
        add("fail", "Could not discover rb-portless state: #{e.message}")
        tls = !Utils.https_env_disabled?
        Struct.new(:dir, :port, :tls, :tld, :tlds, :lan_mode, :lan_ip, keyword_init: true)
              .new(dir: State.dir, port: Daemon.default_port(tls), tls: tls, tld: Utils::DEFAULT_TLD,
                   tlds: [ Utils::DEFAULT_TLD ], lan_mode: Utils.lan_env_enabled?, lan_ip: nil)
      end
      store = RouteStore.new(state.dir, on_warning: ->(msg) { add("warn", msg) })
      port_file = File.join(state.dir, "proxy.port")
      pid_file = File.join(state.dir, "proxy.pid")
      has_port_file = File.exist?(port_file)
      configured_tls = has_port_file ? state.tls : !Utils.https_env_disabled?
      configured_port = has_port_file ? state.port : Daemon.default_port(configured_tls)
      initial_running = Health.proxy_running?(state.port, state.tls)
      use_state = initial_running || has_port_file
      probe_port = use_state ? state.port : configured_port
      probe_tls = use_state ? state.tls : configured_tls
      proxy_running = initial_running && probe_port == state.port ? true : Health.proxy_running?(probe_port, probe_tls)
      port_listening = proxy_running || PortOwner.port_listening?(probe_port)
      known = proxy_running || port_listening || has_port_file
      proxy_port = known ? probe_port : configured_port
      proxy_tls = known ? probe_tls : configured_tls
      current_http = known && !proxy_tls
      custom_cert = proxy_tls && File.exist?(File.join(state.dir, "proxy.custom-cert"))
      state_exists = File.exist?(state.dir)

      platform = "#{self.class.node_platform} #{self.class.node_arch}"
      proxy_target = Utils.format_url("127.0.0.1", proxy_port, proxy_tls)
      mode = "#{proxy_tls ? 'HTTPS' : 'HTTP'}, #{state.tlds.map { |t| ".#{t}" }.join(', ')}#{state.lan_mode ? ', LAN' : ''}"

      unless @json
        print Colors.bold(Colors.blue("\nrb-portless doctor\n")), "\n"
        puts "Version: #{VERSION}"
        puts "Ruby: #{RUBY_VERSION}"
        puts "Platform: #{platform}"
        puts "State dir: #{state.dir}"
        puts "Proxy target: #{proxy_target}"
        puts "Mode: #{mode}"
        puts ""
      end

      if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(MIN_RUBY)
        add("ok", "Ruby #{RUBY_VERSION} satisfies rb-portless requirements.")
      else
        add("fail", "Ruby #{RUBY_VERSION} is unsupported.", "Install Ruby #{MIN_RUBY} or newer.")
      end

      check_state_dir(state.dir, state_exists)

      if proxy_running
        add("ok", "Proxy is responding on port #{proxy_port}.")
      elsif port_listening
        pid = PortOwner.pid_on_port(proxy_port)
        add("fail", "Port #{proxy_port} is in use, but it is not a rb-portless proxy.",
            pid ? "Process on port: PID #{pid}" : "Could not identify the process holding the port.")
      else
        port_args = proxy_port == Daemon.default_port(proxy_tls) ? "" : " -p #{proxy_port}"
        add("warn", "Proxy is not running on port #{proxy_port}.",
            "Run: rb-portless proxy start#{port_args}#{proxy_tls ? '' : ' --no-tls'}")
      end

      check_pid_file(pid_file, proxy_running, proxy_port)

      if custom_cert
        add("ok", "Proxy is configured with a custom TLS certificate.")
      elsif proxy_tls || (!current_http && !Utils.https_env_disabled?)
        add("ok", "OpenSSL is available for certificate generation.") # Ruby's openssl extension is always linked
      else
        add("info", "HTTPS is disabled, so OpenSSL is not required for this run.")
      end

      if proxy_tls && custom_cert
        add("info", "Generated local CA is not required for custom TLS certificates.")
      elsif proxy_tls
        ca = File.join(state.dir, "ca.pem")
        if File.exist?(ca)
          if Trust.trusted?(state.dir)
            add("ok", "Local CA is trusted by the OS trust store.")
          else
            add("warn", "Local CA exists but is not trusted by the OS trust store.", "Run: rb-portless trust")
          end
        elsif proxy_running
          add("warn", "Generated CA file is missing: #{ca}")
        else
          add("info", "Local CA has not been generated yet.")
        end
      else
        add("info", "HTTPS is disabled for the current proxy state.")
      end

      raw = begin
        store.load_routes_raw
      rescue StandardError => e
        add("fail", "Could not read routes: #{e.message}")
        []
      end
      live = raw.select { |r| r.pid.to_i.zero? || alive?(r.pid) }
      stale = raw.reject { |r| r.pid.to_i.zero? || alive?(r.pid) }
      if raw.empty?
        add("info", "No routes are registered.")
      elsif stale.empty?
        add("ok", "Routes: #{pluralize(live.length, 'active route')}.")
      else
        add("warn", "Routes: #{pluralize(live.length, 'active route')}, #{pluralize(stale.length, 'stale route')}.",
            "Run: rb-portless prune")
      end
      stale.first(5).each { |r| add("warn", "Stale route #{r.hostname} is owned by exited PID #{r.pid}.") }
      add("warn", "#{stale.length - 5} additional stale routes hidden.") if stale.length > 5

      live.each do |r|
        unless r.port.is_a?(Integer) && r.port.between?(1, 65_535)
          add("warn", "Route #{r.hostname} has invalid port #{r.port}.",
              r.pid.to_i.zero? ? "Remove or recreate the alias." : "Run: rb-portless prune")
          next
        end
        next if PortOwner.port_listening?(r.port)

        add("warn", "Route #{r.hostname} points to port #{r.port}, but nothing is listening there.",
            r.pid.to_i.zero? ? "Remove the alias or start that service." : "The app may still be starting.")
      end

      if state.lan_mode || Utils.lan_env_enabled?
        mdns = Mdns.supported
        if mdns[:supported]
          add("ok", "mDNS publishing support is available for LAN mode.")
        else
          add("fail", "LAN mode is enabled but mDNS publishing is unavailable: #{mdns[:reason]}")
        end
        if state.lan_ip
          add("ok", "LAN IP is recorded: #{state.lan_ip}")
        else
          add("warn", "LAN mode is enabled but no LAN IP is recorded.")
        end
      elsif !live.empty?
        unresolved = live.map(&:hostname).reject { |h| Hosts.check_host_resolution(h) }
        if unresolved.empty?
          add("ok", "Registered hostnames resolve through the system resolver.")
        else
          add("warn", "#{pluralize(unresolved.length, 'hostname')} did not resolve through the system resolver.",
              "Run: rb-portless hosts sync")
          managed = Hosts.get_managed_hostnames
          unresolved.first(5).each do |h|
            add("warn", "#{h} is #{managed.include?(h) ? 'present in hosts block' : 'missing from hosts block'}.")
          end
        end
      end

      report(platform, state.dir, proxy_target, mode)
    end

    private

    def check_state_dir(dir, exists)
      if exists
        if !File.directory?(dir)
          add("fail", "State path exists but is not a directory: #{dir}")
        elsif File.writable?(dir)
          add("ok", "State directory is writable: #{dir}")
        else
          add("fail", "State directory is not writable: #{dir}")
        end
        return
      end
      ancestor = nil
      Auto.each_ancestor(File.dirname(dir)) do |d|
        if File.exist?(d)
          ancestor = d
          break
        end
      end
      if ancestor.nil?
        add("fail", "State directory does not exist and no writable ancestor was found: #{dir}")
      elsif !File.directory?(ancestor)
        add("fail", "State directory does not exist and ancestor is not a directory: #{ancestor}")
      elsif File.writable?(ancestor)
        add("info", "State directory has not been created yet: #{dir}")
      else
        add("fail", "State directory does not exist and ancestor is not writable: #{ancestor}")
      end
    end

    def check_pid_file(pid_file, proxy_running, proxy_port)
      unless File.exist?(pid_file)
        add("warn", "Proxy is running but the PID file is missing: #{pid_file}") if proxy_running
        return
      end
      raw = File.read(pid_file).strip
      pid = Integer(raw, exception: false)
      if pid.nil? || pid <= 0
        add("fail", "Proxy PID file is invalid: #{pid_file}")
      elsif !alive?(pid)
        add("warn", "Proxy PID file is stale: #{pid}", "Run: rb-portless proxy stop")
      elsif !proxy_running
        add("warn", "Proxy PID file points to PID #{pid}, but no rb-portless proxy is responding on port #{proxy_port}.",
            "Run: rb-portless proxy stop")
      elsif (port_pid = PortOwner.pid_on_port(proxy_port)) && port_pid != pid
        add("warn", "Proxy PID file points to PID #{pid}, but port #{proxy_port} is owned by PID #{port_pid}.",
            "Run: rb-portless proxy stop")
      else
        add("ok", "Proxy PID file points to the responding proxy process: #{pid}")
      end
    rescue StandardError => e
      add("fail", "Could not read proxy PID file: #{e.message}")
    end

    def report(platform, state_dir, proxy_target, mode)
      failures = @findings.count { |f| f.status == "fail" }
      warnings = @findings.count { |f| f.status == "warn" }
      if @json
        puts JSON.generate({ version: VERSION, rubyVersion: RUBY_VERSION, platform: platform, stateDir: state_dir,
                             proxyTarget: proxy_target, mode: mode,
                             findings: @findings.map { |f| { status: f.status, message: f.message, hint: f.hint }.compact },
                             summary: { failures: failures, warnings: warnings } })
        return failures.positive? ? 1 : 0
      end

      @findings.each do |f|
        status = f.status.ljust(5)
        colored = { "fail" => Colors.red(status), "warn" => Colors.yellow(status), "ok" => Colors.green(status) }
        puts "#{colored.fetch(f.status) { Colors.gray(status) }} #{f.message}"
        puts Colors.gray("      #{f.hint}") if f.hint
      end
      puts ""
      if failures.positive?
        puts Colors.red("Summary: #{pluralize(failures, 'failure')}, #{pluralize(warnings, 'warning')}.")
        return 1
      end
      puts Colors.green("Summary: 0 failures, #{pluralize(warnings, 'warning')}.")
      0
    end
  end
end
