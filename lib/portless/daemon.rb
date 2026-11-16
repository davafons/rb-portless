# frozen_string_literal: true

require "rbconfig"
require "fileutils"
require "securerandom"
require "json"
require "monitor"
require "net/http"
require "openssl"
require "socket"

module Portless
  # The proxy daemon's lifecycle: `proxy start` (config resolution, mismatch
  # refusal, sudo re-exec after a failed probe bind, detached spawn), the
  # foreground server loop (markers, route reloads, daemon-owned hosts sync,
  # LAN mDNS for every route), `proxy stop` (pid identity checks), auto-start
  # for `run`, and discoverState. A port of portless's cli.ts handleProxy /
  # startProxyServer / stopProxy / ensureProxyRunning and the state helpers in
  # cli-utils.ts.
  module Daemon
    module_function

    DEFAULT_TLD = "localhost"
    HEALTH_HEADER = "x-portless"
    WAIT_FOR_PROXY_MAX_ATTEMPTS = 20
    WAIT_FOR_PROXY_INTERVAL = 0.25
    PROXY_STOP_TIMEOUT = 5
    PROXY_STOP_POLL = 0.05
    EXIT_TIMEOUT = 2
    ROUTES_POLL_INTERVAL = 0.1
    INTERNAL_LAN_IP_ENV = "PORTLESS_INTERNAL_LAN_IP"
    INTERNAL_LAN_IP_FLAG = "--lan-ip-auto"
    HOSTS_DISPLAY = Constants::WINDOWS ? "hosts file" : "/etc/hosts"
    HOSTS_SYNC_PATH = "/.portless/hosts-sync"
    HOSTS_SYNC_TRIGGER_TIMEOUT = 0.5
    UNTRIGGERED_SYNC_CEILING = 3.5
    FILE_MODE = 0o644
    NOFOLLOW = defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0

    # discoverState's result (+ `started`). Struct, so
    # both `state.port` and `state[:port]` work.
    ProxyState = Struct.new(:dir, :port, :tls, :tld, :tlds, :lan_mode, :lan_ip, :started, keyword_init: true)

    # The (snake_cased) shape of upstream's ProxyConfig.
    Config = Struct.new(:use_https, :custom_cert_path, :custom_key_path, :lan_mode, :lan_ip,
                        :lan_ip_explicit, :tld, :tlds, :use_wildcard, :unprivileged, keyword_init: true)

    # ── output ────────────────────────────────────────────────────────────
    def out(msg, color = nil) = $stdout.puts(color ? Colors.public_send(color, msg, io: $stdout) : msg)
    def err(msg, color = nil) = $stderr.puts(color ? Colors.public_send(color, msg, io: $stderr) : msg)

    def die!
      $stdout.flush
      exit 1
    end

    # ── TLDs (cli-utils.ts) ──────────────────────────────────────────────
    def normalize_tlds(tlds) = (tlds.nil? || tlds.empty? ? [ DEFAULT_TLD ] : tlds).uniq
    def primary_tld(tlds) = tlds.first || DEFAULT_TLD
    def format_tld_list(tlds) = tlds.map { |t| ".#{t}" }.join(", ")

    def read_legacy_tld(dir)
      raw = File.read(File.join(dir, "proxy.tld")).strip
      raw.empty? ? DEFAULT_TLD : raw
    rescue StandardError
      DEFAULT_TLD
    end

    def read_tlds(dir = State.dir)
      raw = File.read(File.join(dir, "proxy.tlds")).strip
      parsed = if raw.start_with?("[")
                 JSON.parse(raw)
      else
                 raw.split(/\r?\n/).flat_map { |l| l.split(",") }.map(&:strip).reject(&:empty?)
      end
      return [ read_legacy_tld(dir) ] unless parsed.is_a?(Array)

      tlds = parsed.flat_map do |value|
        next [] unless value.is_a?(String)

        begin
          Utils.parse_tld_list(value)
        rescue Error => e
          warn "Warning: ignoring invalid TLD entry in proxy.tlds: #{e.message}"
          []
        end
      end
      tlds.empty? ? [ DEFAULT_TLD ] : tlds.uniq
    rescue StandardError
      [ read_legacy_tld(dir) ]
    end

    def write_tlds(dir, tlds)
      unique = tlds.uniq
      tlds_path = File.join(dir, "proxy.tlds")
      tld_path = File.join(dir, "proxy.tld")
      if unique == [ DEFAULT_TLD ]
        FileUtils.rm_f(tlds_path)
        FileUtils.rm_f(tld_path)
      else
        write_marker_file(tlds_path, "#{unique.join("\n")}\n")
        write_marker_file(tld_path, unique.first || DEFAULT_TLD)
      end
    end

    # ── markers (cli-utils.ts) ───────────────────────────────────────────
    # Markers live in a user-owned state dir the daemon may write as root, so
    # never follow a symlink planted at the destination: write an exclusive
    # no-follow temp file and rename it into place (certs.ts writeStateMarkerFile).
    def write_marker_file(path, content)
      tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
      begin
        File.open(tmp, File::CREAT | File::EXCL | File::WRONLY | NOFOLLOW, FILE_MODE) { |f| f.write(content) }
        File.rename(tmp, path)
      rescue StandardError
        FileUtils.rm_f(tmp)
        raise
      end
    rescue Errno::EPERM
      nil
    end

    # Open an existing-or-new state file without following a symlink.
    def open_state_file(path, flags, &block)
      File.open(path, flags | NOFOLLOW, FILE_MODE, &block)
    end

    def flag_marker(dir, name) = File.exist?(File.join(dir, name))

    def write_flag_marker(dir, name, enabled)
      path = File.join(dir, name)
      enabled ? write_marker_file(path, "1") : FileUtils.rm_f(path)
    rescue StandardError
      nil
    end

    def read_tls_marker(dir = State.dir) = flag_marker(dir, "proxy.tls")
    def write_tls_marker(dir, enabled) = write_flag_marker(dir, "proxy.tls", enabled)
    def read_unprivileged_marker(dir = State.dir) = flag_marker(dir, "proxy.unprivileged")
    def write_unprivileged_marker(dir, enabled) = write_flag_marker(dir, "proxy.unprivileged", enabled)
    def read_custom_cert_marker(dir = State.dir) = flag_marker(dir, "proxy.custom-cert")
    def write_custom_cert_marker(dir, enabled) = write_flag_marker(dir, "proxy.custom-cert", enabled)

    # proxy.lan holds the last known LAN IP while LAN mode is on.
    def read_lan_marker(dir = State.dir)
      raw = File.read(File.join(dir, "proxy.lan")).strip
      raw.empty? ? nil : raw
    rescue StandardError
      nil
    end

    def write_lan_marker(dir, ip)
      path = File.join(dir, "proxy.lan")
      ip ? write_marker_file(path, ip) : FileUtils.rm_f(path)
    rescue StandardError
      nil
    end

    def read_port_from_dir(dir)
      Integer(File.read(File.join(dir, "proxy.port")).strip[/\A\d+/].to_s, exception: false)
    rescue StandardError
      nil
    end

    # ── env (cli-utils.ts) ───────────────────────────────────────────────
    def env_on?(name) = %w[1 true].include?(ENV[name])
    def env_off?(name) = %w[0 false].include?(ENV[name])
    def env_set?(name) = !ENV[name].nil?
    def https_env_disabled? = env_off?("PORTLESS_HTTPS")
    def wildcard_env_enabled? = env_on?("PORTLESS_WILDCARD")
    def lan_env_enabled? = env_on?("PORTLESS_LAN")
    def unprivileged_env_enabled? = env_on?("PORTLESS_UNPRIVILEGED")

    def protocol_port(tls) = tls ? Constants::HTTPS_PORT : Constants::HTTP_PORT

    # PORTLESS_PORT, else 443/80; nil tls → the legacy 1355.
    def default_port(tls = nil)
      env = ENV["PORTLESS_PORT"]
      if env && !env.empty?
        port = Utils.parse_port(env)
        return port if port
      end
      tls.nil? ? Constants::FALLBACK_PROXY_PORT : protocol_port(tls)
    end

    # Kept for callers outside this file; the probe lives in Health.
    def proxy_running?(port, tls = false) = Health.proxy_running?(port, tls)

    # cli.ts isProxyUp.
    def proxy_up?(port, tls)
      return true if Health.proxy_running?(port, tls)

      env_set?("PORTLESS_STATE_DIR") && !ENV["PORTLESS_STATE_DIR"].empty? && PortOwner.port_listening?(port)
    end

    def wait_for_proxy(port, max_attempts = WAIT_FOR_PROXY_MAX_ATTEMPTS, interval = WAIT_FOR_PROXY_INTERVAL,
                       tls = false)
      max_attempts.times do
        sleep interval
        return true if Health.proxy_running?(port, tls)
      end
      false
    end

    # ── persisted / discovered state ─────────────────────────────────────
    def state_from(dir, port, lan_ip: read_lan_marker(dir), tls: read_tls_marker(dir))
      tlds = read_tlds(dir)
      ProxyState.new(dir: dir, port: port, tls: tls, tld: tlds.first || DEFAULT_TLD, tlds: tlds,
                        lan_mode: !read_lan_marker(dir).nil?, lan_ip: lan_ip)
    end

    # Last-known settings on disk, running or not. cli-utils.ts
    # readPersistedProxyState.
    def read_persisted_state
      dir = State.dir
      port = read_port_from_dir(dir) or return nil
      tlds = read_tlds(dir)
      { port: port, tls: read_tls_marker(dir), tld: tlds.first || DEFAULT_TLD, tlds: tlds,
        lan_mode: !read_lan_marker(dir).nil?, unprivileged: read_unprivileged_marker(dir) }
    end

    # The active proxy's dir/port/tls/tlds/LAN state. cli-utils.ts discoverState
    # (minus upstream's legacy /tmp/portless dir, which rb-portless never used).
    def discover_state
      if env_set?("PORTLESS_STATE_DIR") && !ENV["PORTLESS_STATE_DIR"].empty?
        dir = State.dir
        port = read_port_from_dir(dir) || default_port
        live = Health.proxy_running?(port) || PortOwner.port_listening?(port)
        return state_from(dir, port, lan_ip: live ? read_lan_marker(dir) : nil)
      end

      dir = State.dir
      user_port = read_port_from_dir(dir)
      return state_from(dir, user_port) if user_port && Health.proxy_running?(user_port)

      configured = default_port
      [ Constants::HTTPS_PORT, Constants::HTTP_PORT, Constants::FALLBACK_PROXY_PORT, configured ].uniq.each do |port|
        next unless Health.proxy_running?(port)

        tls = read_tls_marker(dir) || port == protocol_port(true)
        return state_from(dir, port, tls: tls)
      end

      state_from(dir, configured, lan_ip: nil)
    end

    # ── proxy config resolution (cli.ts) ─────────────────────────────────
    def default_config(tlds, use_https, lan_mode)
      effective = lan_mode ? [ "local" ] : normalize_tlds(tlds)
      Config.new(use_https: use_https, custom_cert_path: nil, custom_key_path: nil, lan_mode: lan_mode,
                 lan_ip: nil, lan_ip_explicit: false, tld: primary_tld(effective), tlds: effective,
                 use_wildcard: false, unprivileged: false)
    end

    # cli.ts resolveProxyConfig. `explicit` is a Hash of booleans keyed like
    # ProxyConfigExplicitness (use_https, custom_cert, lan_mode, lan_ip, tlds,
    # use_wildcard, unprivileged).
    def resolve_config(persisted_lan_mode:, persisted_unprivileged:, explicit:, default_tlds:, use_https:,
                       custom_cert_path:, custom_key_path:, lan_mode:, lan_ip:, tlds:, use_wildcard:, unprivileged:)
      config = default_config(default_tlds, use_https, explicit[:lan_mode] ? lan_mode : persisted_lan_mode)

      if explicit[:use_https]
        config.use_https = use_https
        unless use_https
          config.custom_cert_path = nil
          config.custom_key_path = nil
        end
      end

      if explicit[:custom_cert]
        config.use_https = true
        config.custom_cert_path = custom_cert_path
        config.custom_key_path = custom_key_path
      end

      if explicit[:lan_mode]
        config.lan_mode = lan_mode
        unless lan_mode
          config.lan_ip = nil
          config.lan_ip_explicit = false
          unless explicit[:tlds]
            config.tlds = normalize_tlds(default_tlds)
            config.tld = primary_tld(config.tlds)
          end
        end
      end

      if explicit[:lan_ip] && lan_ip
        config.lan_mode = true
        config.lan_ip = lan_ip
        config.lan_ip_explicit = true
      end

      if explicit[:tlds]
        config.tlds = normalize_tlds(tlds)
        config.tld = primary_tld(config.tlds)
      end

      config.use_wildcard = use_wildcard if explicit[:use_wildcard]
      config.unprivileged = explicit[:unprivileged] ? unprivileged : persisted_unprivileged

      # Unprivileged promises no prompt; trusting a CA is one → plain HTTP.
      config.use_https = false if config.unprivileged && !explicit[:use_https] && !explicit[:custom_cert]

      unless config.lan_mode
        config.lan_ip = nil
        config.lan_ip_explicit = false
      end

      if config.lan_mode
        config.tlds = [ "local" ]
        config.tld = "local"
        config.lan_ip = nil unless config.lan_ip_explicit
      end

      unless config.use_https
        config.custom_cert_path = nil
        config.custom_key_path = nil
      end
      config
    end

    def read_current_proxy_config(dir)
      lan_ip = read_lan_marker(dir)
      tlds = read_tlds(dir)
      Config.new(use_https: read_tls_marker(dir), custom_cert_path: nil, custom_key_path: nil,
                 lan_mode: !lan_ip.nil?, lan_ip: lan_ip, lan_ip_explicit: false, tld: primary_tld(tlds),
                 tlds: tlds, use_wildcard: false, unprivileged: read_unprivileged_marker(dir))
    end

    # cli.ts getProxyConfigMismatchMessages.
    def proxy_config_mismatch_messages(desired, actual, explicit)
      messages = []
      if explicit[:lan_mode] && desired.lan_mode != actual.lan_mode
        messages << (if desired.lan_mode
                       "requested LAN mode, but the running proxy is not using LAN mode"
                     else
                       "requested non-LAN mode, but the running proxy is using LAN mode"
        end)
      end
      if explicit[:lan_ip] && desired.lan_ip != actual.lan_ip
        messages << "requested LAN IP #{desired.lan_ip}, but the running proxy is using " \
                    "#{actual.lan_ip || 'auto-detected LAN mode'}"
      end
      if explicit[:use_https] && desired.use_https != actual.use_https
        messages << (if desired.use_https
                       "requested HTTPS, but the running proxy is using HTTP"
                     else
                       "requested HTTP, but the running proxy is using HTTPS"
        end)
      end
      if explicit[:unprivileged] && desired.unprivileged != actual.unprivileged
        messages << (if desired.unprivileged
                       "requested unprivileged mode, but the running proxy was started with elevation"
                     else
                       "requested elevated mode, but the running proxy is unprivileged"
        end)
      end
      if explicit[:tlds] && desired.tlds != actual.tlds
        messages << "requested #{format_tld_list(desired.tlds)}, but the running proxy is using " \
                    "#{format_tld_list(actual.tlds)}"
      end
      messages
    end

    # cli-utils.ts buildProxyStartConfig → {effective_tld:, effective_tlds:, args:}
    def build_start_config(use_https:, lan_mode:, tld: DEFAULT_TLD, tlds: nil, custom_cert_path: nil,
                           custom_key_path: nil, lan_ip: nil, lan_ip_explicit: false, use_wildcard: false,
                           unprivileged: false, foreground: false, include_port: false, proxy_port: nil,
                           skip_trust: false)
      requested = tlds && !tlds.empty? ? tlds.dup : [ tld ]
      effective = lan_mode ? [ "local" ] : requested.uniq
      effective_tld = effective.first || DEFAULT_TLD
      args = []
      args << "--foreground" if foreground
      args.push("--port", proxy_port.to_s) if include_port && proxy_port
      if use_https
        if custom_cert_path && custom_key_path
          args.push("--cert", custom_cert_path, "--key", custom_key_path)
        else
          args << "--https"
        end
      else
        args << "--no-tls"
      end
      if lan_mode
        args << "--lan"
        args.push(lan_ip_explicit ? "--ip" : INTERNAL_LAN_IP_FLAG, lan_ip) if lan_ip
      elsif effective.length > 1 || effective_tld != DEFAULT_TLD
        effective.each { |t| args.push("--tld", t) }
      end
      args << "--wildcard" if use_wildcard
      args << "--unprivileged" if unprivileged
      args << "--skip-trust" if skip_trust
      { effective_tld: effective_tld, effective_tlds: effective, args: args }
    end

    def start_args_for(config, **extra)
      build_start_config(use_https: config.use_https, custom_cert_path: config.custom_cert_path,
                         custom_key_path: config.custom_key_path, lan_mode: config.lan_mode,
                         lan_ip: config.lan_ip_explicit ? config.lan_ip : nil,
                         lan_ip_explicit: config.lan_ip_explicit, tld: config.tld, tlds: config.tlds,
                         use_wildcard: config.use_wildcard, unprivileged: config.unprivileged, **extra)[:args]
    end

    def needs_sudo_hint?(port, config)
      !Constants::WINDOWS && port < Constants::PRIVILEGED_PORT_THRESHOLD && !config.unprivileged
    end

    # cli.ts formatProxyStartCommand.
    def format_proxy_start_command(port, config)
      args = start_args_for(config, include_port: port != default_port(config.use_https), proxy_port: port)
      "#{needs_sudo_hint?(port, config) ? 'sudo ' : ''}rb-portless proxy start#{args.empty? ? '' : " #{args.join(' ')}"}"
    end

    # cli.ts printProxyConfigMismatch (exits 1).
    def print_proxy_config_mismatch(port, desired, messages)
      port_flag = port == default_port(desired.use_https) ? "" : " -p #{port}"
      err("Proxy is already running on port #{port} with a different config.", :yellow)
      messages.each { |m| err("- #{m}", :yellow) }
      err("Stop it first, then restart with the desired settings:", :blue)
      err("  #{needs_sudo_hint?(port, desired) ? 'sudo ' : ''}rb-portless proxy stop#{port_flag}", :cyan)
      err("  #{format_proxy_start_command(port, desired)}", :cyan)
      die!
    end

    # ── `proxy start` (cli.ts handleProxy) ───────────────────────────────
    # Keyword args are upstream's flags (already validated by the CLI: the
    # port is an Integer, --cert/--key come together); nil = flag not given.
    def start(port: nil, https: nil, no_tls: nil, cert: nil, key: nil, tlds: nil, wildcard: nil,
              unprivileged: nil, skip_trust: false, foreground: false)
      skip_trust = !!skip_trust
      has_unprivileged_flag = !!unprivileged
      has_https_flag = !!https
      has_no_tls = !!no_tls || (!has_https_flag && https_env_disabled?)
      want_https = !has_no_tls

      custom_cert_path = cert
      custom_key_path = key
      use_https = want_https || !!(custom_cert_path && custom_key_path)

      has_explicit_port = !port.nil?
      proxy_port = port || default_port(use_https)

      begin
        flag_tlds = Utils.default_tlds
      rescue Error => e
        err("Error: #{e.message}", :red)
        die!
      end
      tld_flag_values = Array(tlds)
      unless tld_flag_values.empty?
        begin
          flag_tlds = normalize_tlds(tld_flag_values.flat_map { |v| Utils.parse_tld_list(v) })
        rescue Error => e
          raise UsageError.new(e.message, [ "See: rb-portless proxy start --help" ])
        end
      end
      use_wildcard = !!wildcard || wildcard_env_enabled?

      explicit = {
        use_https: has_https_flag || has_no_tls || !custom_cert_path.nil? || !custom_key_path.nil? ||
          env_set?("PORTLESS_HTTPS"),
        custom_cert: !custom_cert_path.nil? || !custom_key_path.nil?,
        lan_mode: env_set?("PORTLESS_LAN"),
        lan_ip: env_set?("PORTLESS_LAN_IP"),
        tlds: !tld_flag_values.empty? || env_set?("PORTLESS_TLD"),
        use_wildcard: !!wildcard || env_set?("PORTLESS_WILDCARD"),
        unprivileged: has_unprivileged_flag || env_set?("PORTLESS_UNPRIVILEGED")
      }

      state_dir = State.dir
      persisted_lan_mode = !read_lan_marker(state_dir).nil?
      running_port = nil
      unless has_explicit_port
        current = discover_state
        persisted_lan_mode = current[:lan_mode]
        if Health.proxy_running?(current[:port]) ||
           (env_set?("PORTLESS_STATE_DIR") && PortOwner.port_listening?(current[:port]))
          running_port = current[:port]
          proxy_port = current[:port]
          state_dir = current[:dir]
        end
      end

      desired = resolve_config(
        persisted_lan_mode: persisted_lan_mode, persisted_unprivileged: read_unprivileged_marker(state_dir),
        explicit: explicit, default_tlds: Utils.default_tlds, use_https: use_https,
        custom_cert_path: custom_cert_path, custom_key_path: custom_key_path, lan_mode: lan_env_enabled?,
        lan_ip: ENV["PORTLESS_LAN_IP"].to_s.empty? ? nil : ENV["PORTLESS_LAN_IP"], tlds: flag_tlds,
        use_wildcard: use_wildcard, unprivileged: has_unprivileged_flag || unprivileged_env_enabled?
      )
      lan_mode = desired.lan_mode
      use_https = desired.use_https
      custom_cert_path = desired.custom_cert_path
      custom_key_path = desired.custom_key_path
      flag_tlds = desired.tlds
      lan_ip = desired.lan_ip_explicit ? desired.lan_ip : nil

      if !has_explicit_port && running_port.nil?
        proxy_port = default_port(use_https)
        state_dir = State.dir
      end

      if lan_mode && !tld_flag_values.empty?
        user_tlds = tld_flag_values.join(", ")
        if user_tlds != "local"
          warn Colors.yellow("Warning: --lan forces .local TLD (mDNS requirement). Ignoring --tld #{user_tlds}.",
                             io: $stderr)
        end
      end

      flag_tlds.each do |configured|
        reason = Utils.risky_tld_reason(configured)
        warn Colors.yellow("Warning: .#{configured}: #{reason}", io: $stderr) if reason && !lan_mode
      end

      sync_explicitly_on = %w[1 true].include?(ENV["PORTLESS_SYNC_HOSTS"])
      if desired.unprivileged && sync_explicitly_on
        err("Error: PORTLESS_SYNC_HOSTS=1 cannot be combined with unprivileged mode.", :red)
        err("Writing #{HOSTS_DISPLAY} needs root, which unprivileged mode never asks for.", :blue)
        err("Unset PORTLESS_SYNC_HOSTS, or start without --unprivileged. To add entries once:", :blue)
        err("  rb-portless hosts sync", :cyan)
        die!
      end

      sync_disabled = desired.unprivileged || %w[0 false].include?(ENV["PORTLESS_SYNC_HOSTS"])
      non_default = flag_tlds.reject { |t| t == DEFAULT_TLD }
      if !non_default.empty? && !lan_mode && sync_disabled
        warn Colors.yellow("Warning: #{format_tld_list(non_default)} domains require #{HOSTS_DISPLAY} entries " \
                           "to resolve to 127.0.0.1.", io: $stderr)
        warn Colors.yellow("Hosts sync is disabled. To add entries manually, run:", io: $stderr)
        warn Colors.cyan("  rb-portless hosts sync", io: $stderr)
      end

      store = route_store(state_dir)
      store.recover_corrupt_routes_file

      if running_port || Health.proxy_running?(proxy_port)
        running = read_current_proxy_config(state_dir)
        messages = proxy_config_mismatch_messages(desired, running, explicit)
        print_proxy_config_mismatch(proxy_port, desired, messages) unless messages.empty?
        return true if foreground

        port_flag = proxy_port == default_port(use_https) ? "" : " -p #{proxy_port}"
        out("Proxy is already running on port #{proxy_port}.", :yellow)
        out("To restart: rb-portless proxy stop#{port_flag} && rb-portless proxy start#{port_flag}", :blue)
        return true
      end

      if lan_mode
        support = Mdns.supported
        unless support[:supported]
          err("Error: LAN mode requires mDNS publishing, which is not supported on this platform.", :red)
          err(support[:reason], :gray) if support[:reason]
          die!
        end
        inherited = ENV.delete(INTERNAL_LAN_IP_ENV)
        inherited = nil if inherited.to_s.empty?
        lan_ip ||= inherited || LanIp.local_network_ip
        unless lan_ip
          err("Error: Could not detect LAN IP. Are you connected to a network?", :red)
          err("Specify manually:", :blue)
          err("  rb-portless proxy start --lan --ip 192.168.1.42", :cyan)
          die!
        end
      else
        ENV.delete(INTERNAL_LAN_IP_ENV)
      end

      resolved = desired.dup
      resolved.lan_ip = desired.lan_ip_explicit ? lan_ip : nil

      if desired.unprivileged && !Constants::WINDOWS && !Privilege.root?
        check = Privilege.can_bind_without_root(proxy_port)
        unless check[:ok]
          err("Error: #{check[:reason]}", :red)
          if Privilege.host_platform == "linux"
            err("Allow it once per machine:", :blue)
            err("  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=#{proxy_port}", :cyan)
          end
          err("Or start without --unprivileged to elevate with sudo.", :blue)
          die!
        end
      end

      if !desired.unprivileged && Privilege.needs_elevation?(proxy_port, lan_mode)
        return start_elevated(store, proxy_port, desired, resolved, lan_ip, foreground)
      end

      tls_options = nil
      if use_https
        store.ensure_dir
        tls_options = if custom_cert_path && custom_key_path
                        load_custom_cert(custom_cert_path, custom_key_path)
        else
                        prepare_generated_certs(state_dir, flag_tlds, desired.unprivileged, skip_trust)
        end
      end

      if foreground
        $stdout.write(Colors.bold("\nrb-portless proxy\n", io: $stdout), "\n")
        return start_proxy_server(store, proxy_port, desired.tld, flag_tlds, tls_options, lan_ip,
                                  desired.use_wildcard ? false : nil, !!(custom_cert_path && custom_key_path),
                                  desired.unprivileged)
      end

      spawn_daemon(store, state_dir, proxy_port, desired, lan_ip)
    end

    # Re-run `proxy start` under sudo after the probe bind failed. Never falls
    # back to another port (upstream #528): scripted callers would carry on
    # with URLs nothing listens on.
    def start_elevated(store, proxy_port, desired, resolved, lan_ip, foreground)
      args = [ "proxy", "start", *build_start_config(
        use_https: desired.use_https, custom_cert_path: desired.custom_cert_path,
        custom_key_path: desired.custom_key_path, lan_mode: desired.lan_mode,
        lan_ip: desired.lan_ip_explicit ? lan_ip : nil, lan_ip_explicit: desired.lan_ip_explicit,
        tld: desired.tld, tlds: desired.tlds, use_wildcard: desired.use_wildcard, foreground: foreground,
        include_port: true, proxy_port: proxy_port
      )[:args] ]
      recovery = format_proxy_start_command(proxy_port, resolved)

      out("Port #{proxy_port} requires elevated privileges. Requesting sudo...", :yellow)
      store.ensure_dir if File.directory?(store.dir)
      result = Privilege.sudo(args)

      if result.success?
        unless foreground
          if wait_for_proxy(proxy_port)
            out("Proxy started on port #{proxy_port}.", :green)
          else
            err("Proxy process started but is not responding.", :red)
            log = File.join(State.dir, "proxy.log")
            err("Logs: #{log}", :gray) if File.exist?(log)
          end
        end
        return true
      end

      failure = if result.error
                  result.error
      elsif result.status.signaled?
                  "terminated by signal SIG#{Signal.signame(result.status.termsig)}"
      else
                  "exited with status #{result.status.exitstatus}"
      end
      err("Error: Port #{proxy_port} requires elevated privileges, but sudo elevation failed: #{failure}.", :red)
      err("Resolve the sudo error, then rerun the requested startup:", :blue)
      err("  #{recovery}", :cyan)
      die!
    end

    def load_custom_cert(cert_path, key_path)
      cert = File.binread(cert_path)
      key = File.binread(key_path)
      unless cert.include?("-----BEGIN CERTIFICATE-----")
        err("Error: #{cert_path} is not a valid PEM certificate.", :red)
        err("Expected a file starting with -----BEGIN CERTIFICATE-----", :gray)
        die!
      end
      unless key.match?(/-----BEGIN [\w\s]*PRIVATE KEY-----/)
        err("Error: #{key_path} is not a valid PEM private key.", :red)
        err("Expected a file starting with -----BEGIN ...PRIVATE KEY-----", :gray)
        die!
      end
      { cert: cert, key: key, custom: true }
    rescue SystemCallError => e
      err("Error reading certificate files: #{e.message}", :red)
      die!
    end

    def prepare_generated_certs(state_dir, tlds, unprivileged, skip_trust)
      err("Ensuring TLS certificates...", :gray)
      certs = Certs.ensure_certs(state_dir)
      err("Generated local CA certificate.", :green) if certs[:ca_generated]

      if unprivileged && !Trust.trusted?(state_dir)
        warn Colors.yellow("The rb-portless CA is not in the system trust store.", io: $stderr)
        warn Colors.yellow("Browsers will show certificate warnings. Trust it once (asks for admin rights):",
                           io: $stderr)
        warn Colors.cyan("  rb-portless trust", io: $stderr)
      elsif !skip_trust && !Trust.trusted?(state_dir)
        err("Adding CA to system trust store...", :yellow)
        result = Trust.trust_ca(state_dir)
        if result[:trusted]
          err("CA added to system trust store. Browsers will trust rb-portless certs.", :green)
        else
          warn Colors.yellow("Could not add CA to system trust store.", io: $stderr)
          warn Colors.gray(result[:error], io: $stderr) if result[:error]
          warn Colors.yellow("Browsers will show certificate warnings. To fix this later, run:", io: $stderr)
          warn Colors.cyan("  rb-portless trust", io: $stderr)
        end
      end

      { cert: File.binread(certs[:cert_path]), key: File.binread(certs[:key_path]),
        ca: File.binread(certs[:ca_path]), state_dir: state_dir, tlds: tlds }
    end

    # Kept for trust.rb; certs.ts ensureCerts lives in Certs.
    def ensure_certs(state_dir) = Certs.ensure_certs(state_dir)

    # Fork the foreground daemon detached, logging to proxy.log.
    def spawn_daemon(store, state_dir, proxy_port, desired, lan_ip)
      store.ensure_dir
      log_path = File.join(state_dir, "proxy.log")
      log = open_state_file(log_path, File::WRONLY | File::APPEND | File::CREAT)
      begin
        log.chmod(FILE_MODE)
      rescue SystemCallError
        nil
      end
      State.fix_ownership(log_path)
      args = [ "proxy", "start", *build_start_config(
        use_https: desired.use_https, custom_cert_path: desired.custom_cert_path,
        custom_key_path: desired.custom_key_path, lan_mode: desired.lan_mode,
        lan_ip: desired.lan_ip_explicit ? lan_ip : nil, lan_ip_explicit: desired.lan_ip_explicit,
        tld: desired.tld, tlds: desired.tlds, use_wildcard: desired.use_wildcard,
        unprivileged: desired.unprivileged, foreground: true, include_port: true, proxy_port: proxy_port,
        skip_trust: true
      )[:args] ]
      pid = Process.spawn(*Privilege.cli_argv, *args, in: File::NULL, out: log, err: log, pgroup: true)
      Process.detach(pid)
      log.close

      unless wait_for_proxy(proxy_port, WAIT_FOR_PROXY_MAX_ATTEMPTS, WAIT_FOR_PROXY_INTERVAL, desired.use_https)
        err("Proxy failed to start (timed out waiting for it to listen).", :red)
        err("Try starting the proxy in the foreground to see the error:", :blue)
        err("  rb-portless proxy start --foreground", :cyan)
        err("Logs: #{log_path}", :gray) if File.exist?(log_path)
        die!
      end

      out("#{desired.use_https ? 'HTTPS/2' : 'HTTP'} proxy started on port #{proxy_port}", :green)
      hostnames = store.load_routes.map(&:hostname)
      report_hosts_sync(hostnames, proxy_port, desired.use_https, desired.lan_mode) do |msg|
        warn Colors.yellow(msg, io: $stderr)
      end
      if desired.lan_mode && lan_ip
        out("LAN mode active. IP: #{lan_ip}", :green)
        out("Services will be discoverable as <name>.local on your network.", :gray)
      end
      true
    end

    # ── the foreground server (cli.ts startProxyServer) ──────────────────
    def start_proxy_server(store, proxy_port, tld, tlds, tls_options, lan_ip, strict, custom_cert, unprivileged)
      # Node writes console output to files synchronously; proxy.log is read live.
      # Flush first: Ruby < 4.0 keeps buffering after `sync = true` while
      # earlier output (the heading) is still pending.
      $stdout.flush
      $stdout.sync = true
      store.ensure_dir
      dir = store.dir
      is_tls = !tls_options.nil?
      mdns = Mdns.supported
      active_lan_ip = lan_ip && mdns[:supported] ? lan_ip : nil
      lan_mode_active = !active_lan_ip.nil?
      bind_targets = Privilege.bind_targets(lan_mode_active, unprivileged)
      loopback_only = unprivileged && !lan_mode_active
      lan_ip_pinned = !ENV["PORTLESS_LAN_IP"].to_s.empty?
      lan_monitor = nil
      if lan_ip && !mdns[:supported]
        reason = mdns[:reason] || "mDNS publishing is not supported on this platform."
        warn Colors.yellow("LAN mode disabled: #{reason}", io: $stderr)
      end

      routes_path = File.join(dir, "routes.json")
      begin
        open_state_file(routes_path, File::WRONLY | File::CREAT | File::EXCL) { |f| f.write("[]") }
      rescue Errno::EEXIST
        nil
      end
      begin
        open_state_file(routes_path, File::RDONLY) { |f| f.chmod(FILE_MODE) }
      rescue SystemCallError
        nil
      end
      State.fix_ownership(routes_path)

      lock = Monitor.new
      cached = []
      begin
        cached = store.load_trusted_routes
      rescue StandardError => e
        warn Colors.yellow("Could not read routes: #{e.message}", io: $stderr)
      end
      reload_warning_shown = false

      auto_sync_hosts = !unprivileged && Hosts.should_auto_sync_hosts?(ENV["PORTLESS_SYNC_HOSTS"])
      hosts_sync_token = HostsSyncAuth.generate_token
      on_mdns_error = ->(msg) { warn Colors.yellow(msg, io: $stderr) }

      publish_cached = lambda do
        next unless active_lan_ip

        cached.each { |route| Mdns.publish(route.hostname, proxy_port, active_lan_ip, on_mdns_error) }
      end

      update_lan_ip = lambda do |next_ip, previous_ip|
        lock.synchronize do
          next if next_ip == active_lan_ip

          Mdns.cleanup_all if active_lan_ip
          active_lan_ip = next_ip
          write_lan_marker(dir, active_lan_ip)
          if previous_ip && next_ip
            out("LAN IP changed: #{previous_ip} -> #{next_ip}", :green)
          elsif previous_ip
            warn Colors.yellow("LAN mode temporarily unavailable: no active LAN IP", io: $stderr)
          elsif next_ip
            out("LAN mode restored: #{next_ip}", :green)
          end
          publish_cached.call
        end
      end

      hosts_sync_warned = false
      sync_hosts_and_latch = lambda do |hostnames|
        ok = true
        hosts_sync_warned = sync_hosts_with_warning(
          hostnames, hosts_sync_warned,
          -> { warn Colors.yellow("Could not write #{HOSTS_DISPLAY} for route hostnames.", io: $stderr) },
          lambda { |names|
            ok = Hosts.sync_hosts_file(names)
            ok
          }
        )
        ok
      end

      on_hosts_sync_request = lambda do
        next :disabled unless auto_sync_hosts

        hostnames = begin
          store.load_trusted_routes.map(&:hostname)
        rescue StandardError
          lock.synchronize { cached.map(&:hostname) }
        end
        lock.synchronize { sync_hosts_and_latch.call(hostnames) }
        :acted
      end

      reload_routes = lambda do
        lock.synchronize do
          previous = cached.to_h { |r| [ r.hostname, r.port ] }
          cached = store.load_trusted_routes
          reload_warning_shown = false
          sync_hosts_and_latch.call(cached.map(&:hostname)) if auto_sync_hosts
          if active_lan_ip
            current = cached.to_h { |r| [ r.hostname, r.port ] }
            cached.each do |route|
              prev_port = previous[route.hostname]
              if prev_port.nil?
                Mdns.publish(route.hostname, proxy_port, active_lan_ip, on_mdns_error)
              elsif prev_port != route.port
                Mdns.unpublish(route.hostname)
                Mdns.publish(route.hostname, proxy_port, active_lan_ip, on_mdns_error)
              end
            end
            previous.each_key { |h| Mdns.unpublish(h) unless current.key?(h) }
          end
        rescue StandardError => e
          unless reload_warning_shown
            reload_warning_shown = true
            warn Colors.yellow("Could not reload routes: #{e.message}", io: $stderr)
          end
        end
      end

      # fs.watch analogue: poll routes.json's identity and reload on change.
      watcher = Thread.new do
        last = file_signature(routes_path)
        loop do
          sleep ROUTES_POLL_INTERVAL
          sig = file_signature(routes_path)
          next if sig == last

          last = sig
          reload_routes.call
        end
      end

      sync_hosts_and_latch.call(cached.map(&:hostname)) if auto_sync_hosts
      publish_cached.call

      get_routes = lambda do
        snapshot = lock.synchronize { cached }
        reload_routes.call unless snapshot.all? { |route| store.route_owner_alive?(route) }
        lock.synchronize { cached }
      end

      proto = is_tls ? "HTTPS/2" : "HTTP"
      tld_label = tlds.length > 1 || tld != DEFAULT_TLD ? " (TLDs: #{format_tld_list(tlds)})" : ""
      mode_label = "#{strict == false ? ' (wildcard)' : ''}" \
                   "#{loopback_only ? ' (unprivileged, loopback peers only)' : ''}"

      on_auxiliary_listen = lambda do |kind, host, port, error|
        if error
          next if kind == :redirect || unavailable_ipv6_bind?(error, host)

          warn Colors.yellow("Could not listen on #{format_bind_endpoint(host, port)}: #{error.message}", io: $stderr)
        elsif kind == :redirect
          out("HTTP-to-HTTPS redirect listening on #{format_bind_endpoint(host, port)}", :green)
        else
          out("#{proto} proxy listening on #{format_bind_endpoint(host, port)}#{tld_label}#{mode_label}", :green)
        end
      end

      on_listening = lambda do
        warn Colors.yellow("Could not publish hosts sync authorization.", io: $stderr) unless
          HostsSyncAuth.write_token(dir, hosts_sync_token)
        write_proxy_start_time(dir)
        write_marker_file(File.join(dir, "proxy.pid"), Process.pid.to_s)
        write_marker_file(File.join(dir, "proxy.port"), proxy_port.to_s)
        write_tls_marker(dir, is_tls)
        write_custom_cert_marker(dir, is_tls && custom_cert)
        write_tlds(dir, tlds)
        write_lan_marker(dir, active_lan_ip)
        write_unprivileged_marker(dir, unprivileged)
        State.fix_ownership(File.join(dir, "proxy.pid"), File.join(dir, "proxy.port"), File.join(dir, "proxy.start"))
        out("#{proto} proxy listening on #{format_bind_endpoint(bind_targets.first[:host], proxy_port)}" \
            "#{tld_label}#{mode_label}", :green)
        if active_lan_ip
          out("LAN mode: #{active_lan_ip}", :green)
          out("Services are discoverable as <name>.local on your network", :gray)
          if is_tls && !custom_cert
            out("For HTTPS on devices, install the CA certificate:", :yellow)
            out("  #{File.join(dir, 'ca.pem')}", :gray)
          end
          unless lan_ip_pinned
            lan_monitor = Mdns.start_lan_ip_monitor(
              initial_ip: active_lan_ip,
              on_change: ->(nxt, prev) { update_lan_ip.call(nxt, prev) },
              on_error: ->(e) { warn Colors.yellow("Failed to refresh LAN IP: #{e.message}", io: $stderr) }
            )
          end
        end
      end

      proxy = Proxy.new(
        port: proxy_port, routes: get_routes, tlds: tlds, strict: strict != false, tls: tls_options,
        loopback_only: loopback_only, bind_targets: bind_targets,
        redirect_http: is_tls && proxy_port != Constants::HTTP_PORT,
        on_hosts_sync_request: on_hosts_sync_request, hosts_sync_token: hosts_sync_token,
        on_listening: on_listening, on_auxiliary_listen: on_auxiliary_listen,
        on_error: ->(msg) { warn Colors.red(msg, io: $stderr) }
      )

      exiting = false
      cleanup = lambda do
        next if exiting

        exiting = true
        watcher.kill
        lan_monitor&.stop
        Mdns.cleanup_all if active_lan_ip
        FileUtils.rm_f(File.join(dir, "proxy.pid"))
        FileUtils.rm_f(File.join(dir, "proxy.port"))
        reset_proxy_markers(dir)
        HostsSyncAuth.remove_token(dir)
        Hosts.clean_hosts_file if auto_sync_hosts
        proxy.stop
      end

      %w[INT TERM].each do |sig|
        trap(sig) do
          Thread.new do
            cleanup.call
          ensure
            $stdout.flush
            $stderr.flush
            Process.exit!(0)
          end
        end
      end

      $stdout.write(Colors.cyan("\nProxy is running. Press Ctrl+C to stop.\n", io: $stdout), "\n")
      out("Routes file: #{routes_path}", :gray)

      begin
        proxy.run
      rescue Errno::EADDRINUSE
        err("Port #{proxy_port} is already in use.", :red)
        err("Stop the existing proxy first:", :blue)
        err("  rb-portless proxy stop", :cyan)
        err("Or check what is using the port:", :blue)
        err(Constants::WINDOWS ? "  netstat -ano | findstr :#{proxy_port}" : "  lsof -ti tcp:#{proxy_port}", :cyan)
        die!
      rescue Errno::EACCES
        err("Permission denied for port #{proxy_port}.", :red)
        err("Use an unprivileged port (no sudo needed):", :blue)
        err("  rb-portless proxy start -p 1355", :cyan)
        die!
      rescue SystemCallError => e
        err("Proxy error: #{e.message}", :red)
        die!
      end
      cleanup.call
      true
    end

    def file_signature(path)
      st = File.stat(path)
      [ st.ino, st.size, st.mtime.to_r ]
    rescue SystemCallError
      nil
    end

    def format_bind_endpoint(host, port) = host.include?(":") ? "[#{host}]:#{port}" : "#{host}:#{port}"

    def unavailable_ipv6_bind?(error, host)
      host.include?(":") && (error.is_a?(Errno::EAFNOSUPPORT) || error.is_a?(Errno::EADDRNOTAVAIL))
    end

    def route_store(dir)
      RouteStore.new(dir, on_warning: ->(msg) { warn Colors.yellow(msg, io: $stderr) })
    end

    # Record our start time so `stop` can tell us from a recycled pid.
    def write_proxy_start_time(dir)
      path = File.join(dir, "proxy.start")
      tmp = "#{path}.tmp"
      start_time = PortOwner.start_time(Process.pid)
      FileUtils.rm_f(tmp)
      if start_time.nil?
        FileUtils.rm_f(path)
        return
      end
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) { |f| f.write(start_time) }
      State.fix_ownership(tmp)
      File.rename(tmp, path)
    rescue StandardError
      FileUtils.rm_f(tmp)
    end

    # Forget the recorded identity and runtime settings once the proxy is gone.
    def reset_proxy_markers(dir)
      path = File.join(dir, "proxy.start")
      [ path, "#{path}.tmp" ].each { |f| FileUtils.rm_f(f) }
      write_tls_marker(dir, false)
      write_custom_cert_marker(dir, false)
      write_tlds(dir, [ DEFAULT_TLD ])
      write_lan_marker(dir, nil)
    end

    # ── `proxy stop` (cli.ts stopProxy & friends) ────────────────────────
    def stop(port: nil)
      if port
        stop_proxy(State.dir, port)
      else
        state = discover_state
        stop_proxy(state[:dir], state[:port])
      end
    end

    def read_state_file(file)
      File.read(file).strip
    rescue Errno::ENOENT
      nil
    end

    def remove_state_file_if_matches(file, expected)
      current = read_state_file(file)
      return true if current.nil?
      return false if current != expected

      FileUtils.rm_f(file)
      true
    end

    # :proxy | :recycled | :unknown — cli.ts identifyRecordedProxy.
    def identify_recorded_proxy(dir, pid, proxy_port)
      recorded = read_state_file(File.join(dir, "proxy.start"))
      live = PortOwner.start_time(pid)
      return recorded == live ? :proxy : :recycled if recorded && live

      holders = PortOwner.pids_on_port(proxy_port)
      return :proxy if holders.include?(pid)
      return :recycled unless holders.empty?
      return :recycled if !PortOwner.port_listening?(proxy_port) && PortOwner.suspended?(pid) != true

      :unknown
    end

    def clear_proxy_state_after_stop(dir, proxy_port)
      port_file = File.join(dir, "proxy.port")
      unless remove_state_file_if_matches(port_file, proxy_port.to_s)
        err("Port file changed to #{read_state_file(port_file)}; leaving it in place.", :red)
        return false
      end
      if Health.proxy_running?(proxy_port)
        err("Proxy restarted on port #{proxy_port}; leaving its state in place.", :red)
        return false
      end
      reset_proxy_markers(dir)
      true
    end

    def wait_for_proxy_to_close(proxy_port, pid, timeout)
      deadline = monotonic + timeout
      loop do
        return true if !PortOwner.running?(pid) && !Health.proxy_running?(proxy_port)
        return false if monotonic >= deadline

        sleep PROXY_STOP_POLL
      end
    end

    # cli.ts readRecordedProxy → {state:, pid:, reason:, identity:}
    def read_recorded_proxy(dir, proxy_port)
      unsafe = File.exist?(dir) ? State.explain_unsafe_state_dir(dir) : nil # routes.ts untrustedReason
      return { state: :untrusted, reason: unsafe } if unsafe

      pid_path = File.join(dir, "proxy.pid")
      unless File.exist?(pid_path)
        return { state: :stopped } unless Health.proxy_running?(proxy_port)

        return { state: :unrecorded, pid: PortOwner.pid_on_port(proxy_port) }
      end
      pid = Integer(File.read(pid_path).strip[/\A-?\d+/].to_s, exception: false)
      return { state: :corrupt } if pid.nil?

      begin
        Process.kill(0, pid)
      rescue Errno::EPERM
        return { state: :forbidden }
      rescue StandardError
        return { state: :dead }
      end
      answering = Health.proxy_running?(proxy_port)
      identity = identify_recorded_proxy(dir, pid, proxy_port)
      return { state: answering ? :mismatched : :recycled, pid: pid } if identity == :recycled
      return { state: :running, pid: pid } if answering

      { state: :unverified, pid: pid, identity: identity }
    end

    def terminate_proxy(proxy_port, pid)
      Process.kill("TERM", pid)
      return true if wait_for_proxy_to_close(proxy_port, pid, PROXY_STOP_TIMEOUT)

      err("Proxy did not stop within #{PROXY_STOP_TIMEOUT}s.", :red)
      false
    end

    def forget_proxy(dir, proxy_port, pid)
      pid_path = File.join(dir, "proxy.pid")
      unchanged = pid.nil? ? !File.exist?(pid_path) : remove_state_file_if_matches(pid_path, pid.to_s)
      return clear_proxy_state_after_stop(dir, proxy_port) if unchanged

      err("Proxy PID file changed to #{read_state_file(pid_path)}; leaving it in place.", :red)
      false
    end

    def sudo_stop(port)
      out("Proxy is running as root. Elevating with sudo to stop it...", :yellow)
      Privilege.sudo([ "proxy", "stop", "-p", port.to_s ]).success?
    end

    def sudo_stop_or_hint(port)
      unless Constants::WINDOWS
        return true if sudo_stop(port)

        err("Failed to stop proxy with sudo.", :red)
        err("Try manually:", :blue)
        err("  rb-portless proxy stop -p #{port}", :cyan)
        return false
      end
      err("Permission denied. The proxy was started with elevated privileges.", :red)
      err("Stop it with:", :blue)
      err("  Run rb-portless proxy stop as Administrator", :cyan)
      false
    end

    def stop_proxy(dir, proxy_port)
      proxy = read_recorded_proxy(dir, proxy_port)
      pid_path = File.join(dir, "proxy.pid")
      case proxy[:state]
      when :stopped
        out("Proxy is not running.", :yellow)
        true
      when :forbidden
        sudo_stop_or_hint(proxy_port)
      when :untrusted
        err("Cannot stop the proxy recorded in #{dir}: #{proxy[:reason]}", :red)
        err("Nothing was signaled.", :blue)
        false
      when :mismatched
        err("PID #{proxy[:pid]} in #{pid_path} is not the proxy answering on port #{proxy_port}.", :red)
        err("It was not signaled, and the proxy state is kept.", :blue)
        err(if Constants::WINDOWS
              "Find the proxy with: netstat -ano | findstr :#{proxy_port}"
            else
              "Find the proxy with: lsof -ti tcp:#{proxy_port} -sTCP:LISTEN"
            end, :cyan)
        false
      when :corrupt
        err("Corrupted PID file. Removing it.", :red)
        File.unlink(pid_path)
        reset_proxy_markers(dir)
        true
      when :dead
        out("Proxy process is no longer running. Cleaning up stale files.", :yellow)
        File.unlink(pid_path)
        FileUtils.rm_f(File.join(dir, "proxy.port"))
        reset_proxy_markers(dir)
        true
      when :unrecorded
        out("PID file is missing but port #{proxy_port} is still in use.", :yellow)
        if proxy[:pid].nil?
          return sudo_stop_or_hint(proxy_port) if !Constants::WINDOWS && !Privilege.root?

          err("Could not identify the process on port #{proxy_port}.", :red)
          err("Try manually:", :blue)
          err(Constants::WINDOWS ? "  taskkill /F /PID <pid>" : "  sudo kill \"$(lsof -ti tcp:#{proxy_port})\"", :cyan)
          return false
        end
        stopped = terminate_proxy(proxy_port, proxy[:pid]) && forget_proxy(dir, proxy_port, nil)
        out("Killed process #{proxy[:pid]}. Proxy stopped.", :green) if stopped
        stopped
      when :recycled
        return false unless forget_proxy(dir, proxy_port, proxy[:pid])

        out("PID #{proxy[:pid]} is not a proxy listening on port #{proxy_port}. Removed stale proxy state.", :yellow)
        true
      when :unverified
        pid = proxy[:pid]
        err(if proxy[:identity] == :proxy
              "Proxy PID #{pid} is not responding on port #{proxy_port}."
            else
              "Could not verify that PID #{pid} is the proxy on port #{proxy_port}."
            end, :red)
        err("It was not signaled, and its state and CA files are kept.", :blue)
        if !Constants::WINDOWS && PortOwner.suspended?(pid) == true
          err("The process is suspended. Resume it with: kill -CONT #{pid}", :cyan)
        elsif proxy[:identity] == :proxy
          err("If it stays unresponsive, stop it with: #{Constants::WINDOWS ? "taskkill /F /PID #{pid}" : "sudo kill #{pid}"}",
              :cyan)
        end
        false
      when :running
        stopped = terminate_proxy(proxy_port, proxy[:pid]) && forget_proxy(dir, proxy_port, proxy[:pid])
        out("Proxy stopped.", :green) if stopped
        stopped
      end
    rescue Errno::EPERM
      sudo_stop_or_hint(proxy_port)
    rescue StandardError => e
      err("Failed to stop proxy: #{e.message}", :red)
      err("Check if the process is still running:", :blue)
      err(Constants::WINDOWS ? "  netstat -ano | findstr :#{proxy_port}" : "  lsof -ti tcp:#{proxy_port}", :cyan)
      false
    end

    # ── auto-start for `run` (cli.ts) ────────────────────────────────────
    # cli.ts resolveProxyDesiredState → {explicit:, desired_config:, env_tld:, env_tlds:}
    def resolve_desired_state(lan_mode)
      env_tlds = Utils.default_tlds
      explicit = {
        use_https: env_set?("PORTLESS_HTTPS"), custom_cert: false, lan_mode: env_set?("PORTLESS_LAN"),
        lan_ip: env_set?("PORTLESS_LAN_IP"), tlds: env_set?("PORTLESS_TLD"),
        use_wildcard: env_set?("PORTLESS_WILDCARD"), unprivileged: env_set?("PORTLESS_UNPRIVILEGED")
      }
      desired = resolve_config(
        persisted_lan_mode: lan_mode, persisted_unprivileged: read_unprivileged_marker(State.dir),
        explicit: explicit, default_tlds: env_tlds, use_https: !https_env_disabled?, custom_cert_path: nil,
        custom_key_path: nil, lan_mode: lan_env_enabled?,
        lan_ip: ENV["PORTLESS_LAN_IP"].to_s.empty? ? nil : ENV["PORTLESS_LAN_IP"], tlds: env_tlds,
        use_wildcard: wildcard_env_enabled?, unprivileged: unprivileged_env_enabled?
      )
      { explicit: explicit, desired_config: desired, env_tld: primary_tld(env_tlds), env_tlds: env_tlds }
    end

    # Settings a stopped proxy restarts with: persisted ones (left by an
    # unexpected exit — a clean stop resets the markers) unless the env is
    # explicit. cli.ts resolveProxyStart → {start_config:, start_port:}
    def resolve_start(desired_state)
      explicit = desired_state[:explicit]
      desired = desired_state[:desired_config]
      persisted = read_persisted_state
      configured_env_port = ENV["PORTLESS_PORT"].to_s.strip
      start_config = desired.dup
      start_port = nil
      if persisted
        start_config.use_https = persisted[:tls] if !explicit[:use_https] && persisted[:tls] != desired.use_https
        if !explicit[:tlds] && persisted[:tlds] != desired.tlds
          start_config.tlds = persisted[:tlds]
          start_config.tld = primary_tld(persisted[:tlds])
        end
        start_config.lan_mode = persisted[:lan_mode] if !explicit[:lan_mode] && persisted[:lan_mode] != desired.lan_mode
        if !explicit[:unprivileged] && persisted[:unprivileged] != desired.unprivileged
          start_config.unprivileged = persisted[:unprivileged]
        end
        env_port = default_port(start_config.use_https)
        start_port = persisted[:port] if configured_env_port.empty? && persisted[:port] != env_port
      end
      { start_config: start_config, start_port: start_port }
    end

    # cli.ts ensureProxyRunning → {started: false} | {started: true, state:}
    def ensure_proxy_running(proxy_port, tls, desired_state)
      return { started: false } if proxy_up?(proxy_port, tls)

      resolved = resolve_start(desired_state)
      start_config = resolved[:start_config]
      start_port = resolved[:start_port]
      effective_port = start_port || default_port(start_config.use_https)
      needs_sudo = !start_config.unprivileged && Privilege.needs_elevation?(effective_port, start_config.lan_mode)
      manual = format_proxy_start_command(effective_port, start_config)
      fallback = format_proxy_start_command(Constants::FALLBACK_PROXY_PORT, start_config)

      if needs_sudo && !Privilege.interactive?
        err("Proxy is not running and no TTY is available for sudo.", :red)
        err("Option 1: start the proxy in a terminal (will prompt for sudo):", :blue)
        err("  #{manual}", :cyan)
        err("Option 2: use an unprivileged port (no sudo needed, URLs will include " \
            ":#{Constants::FALLBACK_PROXY_PORT}):", :blue)
        err("  #{fallback}", :cyan)
        die!
      end

      err("Starting proxy...", :gray)
      args = start_args_for(start_config, include_port: !start_port.nil?, proxy_port: start_port)
      pid = Process.spawn(*Privilege.cli_argv, "proxy", "start", *args, out: :err)
      status = Privilege.wait_with_timeout(pid, Privilege::SUDO_SPAWN_TIMEOUT)

      discovered = nil
      unless status&.signaled?
        WAIT_FOR_PROXY_MAX_ATTEMPTS.times do
          sleep WAIT_FOR_PROXY_INTERVAL
          state = discover_state
          if Health.proxy_running?(state[:port])
            discovered = state
            break
          end
        end
      end

      unless discovered
        err("Failed to start proxy.", :red)
        log_path = File.join(State.dir, "proxy.log")
        err("Try starting it manually:", :blue)
        err("  #{manual}", :cyan)
        err("Logs: #{log_path}", :gray) if File.exist?(log_path)
        die!
      end
      { started: true, state: discovered }
    end

    # ── hosts sync client (cli-utils.ts) ─────────────────────────────────
    def hosts_unresolved_message(hostnames)
      "#{hostnames.join(', ')} will not resolve. Run: rb-portless hosts sync"
    end

    # One deadline shared by every request of a trigger (AbortSignal.timeout).
    def http_for(port, tls, deadline)
      remaining = deadline - monotonic
      raise Net::ReadTimeout, "hosts sync deadline" unless remaining.positive?

      http = Net::HTTP.new("127.0.0.1", port)
      http.open_timeout = remaining
      http.read_timeout = remaining
      http.write_timeout = remaining
      http.ssl_timeout = remaining
      if tls
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      http
    end

    def absent_error?(error) = error.is_a?(Errno::ECONNREFUSED) || error.is_a?(SocketError)

    # :available | :absent | :mute
    def probe_hosts_sync_auth(port, tls, token, challenge, deadline = monotonic + HOSTS_SYNC_TRIGGER_TIMEOUT)
      res = http_for(port, tls, deadline).start do |h|
        h.head("/", HostsSyncAuth::HOSTS_SYNC_AUTH_CHALLENGE_HEADER => challenge)
      end
      expected = token ? HostsSyncAuth.create_proof(token, challenge) : nil
      supplied = res[HostsSyncAuth::HOSTS_SYNC_AUTH_PROOF_HEADER]
      available = res[HEALTH_HEADER] == "1" && supplied && expected &&
                  HostsSyncAuth.valid_token?(supplied) && HostsSyncAuth.secure_compare(supplied, expected)
      available ? :available : :mute
    rescue StandardError => e
      absent_error?(e) ? :absent : :mute
    end

    # Ask the running proxy to sync the hosts file now. → :acted | :absent |
    # :disabled | :mute. cli-utils.ts triggerHostsSync.
    def trigger_hosts_sync(port, tls = false, state_dir = State.dir)
      deadline = monotonic + HOSTS_SYNC_TRIGGER_TIMEOUT
      token = HostsSyncAuth.read_token(state_dir)
      challenge = HostsSyncAuth.generate_challenge
      capability = probe_hosts_sync_auth(port, tls, token, challenge, deadline)
      return capability unless capability == :available
      return :mute unless token

      res = http_for(port, tls, deadline).start do |h|
        h.post(HOSTS_SYNC_PATH, "", HostsSyncAuth::HOSTS_SYNC_AUTH_HEADER => token)
      end
      # A late wakeup (macOS timer coalescing) can deliver an answer past the
      # read timeout; the 500 ms budget is shared, so past it means no answer.
      return :mute if monotonic > deadline

      case res.code.to_i
      when 204 then :acted
      when 409 then :disabled
      else :mute
      end
    rescue StandardError => e
      absent_error?(e) ? :absent : :mute
    end

    # Warn (via the block) when route hostnames will not resolve. Issue #364.
    # cli-utils.ts reportHostsSync.
    def report_hosts_sync(hostnames, port, tls, lan_mode, trigger: method(:trigger_hosts_sync),
                          resolves: ->(h) { Hosts.check_host_resolution(h) }, ceiling: UNTRIGGERED_SYNC_CEILING,
                          read_managed: -> { Hosts.get_managed_hostnames }, &on_warn)
      managed = lan_mode ? hostnames.reject { |h| h.end_with?(".local") } : hostnames
      return if managed.empty?

      found = trigger.call(port, tls)
      unresolved = -> { managed.reject { |h| resolves.call(h) } }

      if found != :mute
        missing = unresolved.call
        on_warn&.call(hosts_unresolved_message(missing)) unless missing.empty?
        return
      end

      deadline = monotonic + ceiling
      while monotonic < deadline
        written = read_managed.call
        break if managed.all? { |h| written.include?(h) }

        sleep 0.1
      end
      missing = unresolved.call
      on_warn&.call(hosts_unresolved_message(missing)) unless missing.empty?
    end

    # One-time warning latch for the daemon log. Returns the next "warned"
    # state. cli-utils.ts syncHostsWithWarning.
    def sync_hosts_with_warning(hostnames, already_warned, on_warn, sync = ->(names) { Hosts.sync_hosts_file(names) })
      return false if sync.call(hostnames)
      return already_warned if hostnames.empty?

      on_warn.call unless already_warned
      true
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
