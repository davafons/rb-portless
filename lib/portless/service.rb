# frozen_string_literal: true

require "etc"
require "fileutils"
require "open3"
require "rbconfig"

module Portless
  # An OS service that runs the proxy at boot (macOS LaunchDaemon, Linux
  # systemd unit) carrying the install flags (--https/--no-tls, -p, --lan,
  # --ip, --tld, --wildcard, --unprivileged, --cert/--key, --state-dir) into
  # the unit's `proxy start` argv + PORTLESS_* env. Mirrors portless's
  # service.ts. The Windows Task Scheduler path is not ported (unverifiable
  # here). Service ids stay rb.portless.proxy / rb-portless.service so the gem
  # coexists with an installed upstream portless.
  module Service
    module_function

    LABEL = "rb.portless.proxy"
    SYSTEMD_SERVICE = "rb-portless.service"
    INTERNAL_ELEVATED_ENV = "PORTLESS_INTERNAL_SERVICE_ELEVATED"
    SERVICE_ENV_KEYS = %w[PORTLESS_SYNC_HOSTS].freeze
    DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    INSTALL_FLAGS = {
      "-p" => :value, "--port" => :value, "--https" => :boolean, "--no-tls" => :boolean, "--lan" => :boolean,
      "--ip" => :value, "--tld" => :value, "--wildcard" => :boolean, "--unprivileged" => :boolean,
      "--cert" => :value, "--key" => :value, "--state-dir" => :value
    }.freeze
    RUNTIME_FLAGS = { "--foreground" => :boolean, "--skip-trust" => :boolean }.freeze

    def default_config
      { state_dir: nil, proxy_port: Constants::HTTPS_PORT, use_https: true, custom_cert_path: nil,
        custom_key_path: nil, lan_mode: false, lan_ip: nil, lan_ip_explicit: false,
        tld: Daemon::DEFAULT_TLD, tlds: [ Daemon::DEFAULT_TLD ], use_wildcard: false, unprivileged: false,
        extra_env: {} }
    end

    def parse_boolean_env(value)
      return nil if value.nil?
      return true if %w[1 true].include?(value)
      return false if %w[0 false].include?(value)

      nil
    end

    def parse_port_value(value, source)
      Daemon.parse_port(value) || raise(Error, "#{source} must be a number between 1 and 65535.")
    end

    def resolve_service_path(value)
      expanded = if value == "~" then Dir.home
      elsif value.start_with?("~/") then File.join(Dir.home, value[2..])
      else value
      end
      File.expand_path(expanded)
    end

    def normalize_install_paths(config)
      config.merge(
        state_dir: config[:state_dir] && resolve_service_path(config[:state_dir]),
        custom_cert_path: config[:custom_cert_path] && resolve_service_path(config[:custom_cert_path]),
        custom_key_path: config[:custom_key_path] && resolve_service_path(config[:custom_key_path])
      )
    end

    def collect_extra_env(env)
      SERVICE_ENV_KEYS.each_with_object({}) { |key, acc| acc[key] = env[key] if env[key] && !env[key].empty? }
    end

    # args.ts visitLeadingFlags (uses the CLI's Args when present).
    def visit_leading_flags(command, args, spec, &visit)
      return Args.visit_leading_flags(command, args, spec, &visit) if defined?(Args) && Args.respond_to?(:visit_leading_flags)

      i = 0
      while i < args.length
        arg = args[i]
        return args[(i + 1)..] if arg == "--"
        return args[i..] if !arg.start_with?("-") || arg == "-"

        eq = arg.start_with?("--") ? arg.index("=") : nil
        flag = eq ? arg[0...eq] : arg
        kind = spec[flag]
        hint = [ "See: rb-portless #{command} --help" ]
        unless kind
          raise UsageError.new("Unknown flag \"#{flag}\" for rb-portless #{command}.",
                               [ "Known flags: #{spec.keys.join(', ')}", *hint ])
        end
        if kind == :boolean
          raise UsageError.new("#{flag} does not take a value.", hint) if eq

          visit.call(flag, nil)
        else
          value = eq ? arg[(eq + 1)..] : args[i + 1]
          raise UsageError.new("#{flag} requires a value.", hint) if value.nil? || value.empty? || (!eq && value.start_with?("-"))

          visit.call(flag, value)
          i += 1 unless eq
        end
        i += 1
      end
      []
    end

    # service.ts parseServiceInstallConfig.
    def parse_install_config(args, env = ENV, allow_runtime_flags: false)
      config = default_config.merge(extra_env: collect_extra_env(env))
      config[:state_dir] = env["PORTLESS_STATE_DIR"] if env["PORTLESS_STATE_DIR"] && !env["PORTLESS_STATE_DIR"].empty?

      env_https = parse_boolean_env(env["PORTLESS_HTTPS"])
      https_explicit = !env_https.nil?
      config[:use_https] = env_https unless env_https.nil?

      env_lan = parse_boolean_env(env["PORTLESS_LAN"])
      config[:lan_mode] = env_lan unless env_lan.nil?

      if env["PORTLESS_LAN_IP"] && !env["PORTLESS_LAN_IP"].empty?
        config[:lan_mode] = true
        config[:lan_ip] = env["PORTLESS_LAN_IP"]
        config[:lan_ip_explicit] = true
      end

      if env["PORTLESS_TLD"] && !env["PORTLESS_TLD"].empty?
        config[:tlds] = Daemon.normalize_tlds(Daemon.parse_tld_list(env["PORTLESS_TLD"], "PORTLESS_TLD"))
        config[:tld] = Daemon.primary_tld(config[:tlds])
      end

      env_wildcard = parse_boolean_env(env["PORTLESS_WILDCARD"])
      config[:use_wildcard] = env_wildcard unless env_wildcard.nil?
      env_unpriv = parse_boolean_env(env["PORTLESS_UNPRIVILEGED"])
      config[:unprivileged] = env_unpriv unless env_unpriv.nil?

      env_port = env["PORTLESS_PORT"]
      config[:proxy_port] = if env_port && !env_port.empty?
                              parse_port_value(env_port, "PORTLESS_PORT")
      else
                              Daemon.protocol_port(config[:use_https])
      end

      tokens = args.first == "service" ? args.drop(2) : args
      port_flag_seen = false
      tld_flag_seen = false
      tld_values = []
      spec = allow_runtime_flags ? INSTALL_FLAGS.merge(RUNTIME_FLAGS) : INSTALL_FLAGS

      rest = visit_leading_flags("service install", tokens, spec) do |flag, value|
        case flag
        when "-p", "--port"
          port = Daemon.parse_port(value)
          raise UsageError.new("Invalid port number: #{value}", [ "Port must be between 1 and 65535." ]) unless port

          config[:proxy_port] = port
          port_flag_seen = true
        when "--https"
          config[:use_https] = true
          https_explicit = true
        when "--no-tls"
          config[:use_https] = false
          https_explicit = true
        when "--lan" then config[:lan_mode] = true
        when "--ip"
          config[:lan_mode] = true
          config[:lan_ip] = value
          config[:lan_ip_explicit] = true
        when "--tld"
          begin
            tld_values += Daemon.parse_tld_list(value)
          rescue Error => e
            raise UsageError.new(e.message, [ "See: rb-portless service install --help" ])
          end
          tld_flag_seen = true
        when "--wildcard" then config[:use_wildcard] = true
        when "--unprivileged" then config[:unprivileged] = true
        when "--cert"
          config[:custom_cert_path] = value
          config[:use_https] = true
          https_explicit = true
        when "--key"
          config[:custom_key_path] = value
          config[:use_https] = true
          https_explicit = true
        when "--state-dir" then config[:state_dir] = value
        end
      end

      unless rest.empty?
        raise UsageError.new("Unexpected argument \"#{rest.first}\" for rb-portless service install.",
                             [ "See: rb-portless service install --help" ])
      end

      if tld_flag_seen
        config[:tlds] = Daemon.normalize_tlds(tld_values)
        config[:tld] = Daemon.primary_tld(config[:tlds])
      end

      if config[:custom_cert_path].nil? != config[:custom_key_path].nil?
        raise UsageError, "--cert and --key must be used together."
      end

      config[:use_https] = false if config[:unprivileged] && !https_explicit
      config[:proxy_port] = Daemon.protocol_port(config[:use_https]) if (env_port.nil? || env_port.empty?) && !port_flag_seen

      if config[:lan_mode]
        config[:tlds] = [ "local" ]
        config[:tld] = "local"
      else
        config[:lan_ip] = nil
        config[:lan_ip_explicit] = false
      end
      config
    end

    def resolve_user_context
      sudo_user = ENV["SUDO_USER"]
      if sudo_user && !sudo_user.empty? && sudo_user != "root"
        return { home: State.resolve_user_home, uid: ENV["SUDO_UID"], gid: ENV["SUDO_GID"], username: sudo_user }
      end

      { home: Dir.home, uid: Process.uid.to_s, gid: Process.gid.to_s, username: Etc.getlogin }
    end

    def build_proxy_command(entry_argv, config)
      args = Daemon.build_start_config(
        use_https: config[:use_https], custom_cert_path: config[:custom_cert_path],
        custom_key_path: config[:custom_key_path], lan_mode: config[:lan_mode], lan_ip: config[:lan_ip],
        lan_ip_explicit: config[:lan_ip_explicit], tld: config[:tld], tlds: config[:tlds],
        use_wildcard: config[:use_wildcard], unprivileged: config[:unprivileged], foreground: true,
        include_port: true, proxy_port: config[:proxy_port], skip_trust: true
      )[:args]
      [ *entry_argv, "proxy", "start", *args ]
    end

    def build_service_env(ctx)
      config = ctx[:config]
      env = {
        "PORTLESS_STATE_DIR" => ctx[:state_dir],
        "PORTLESS_PORT" => config[:proxy_port].to_s,
        "PORTLESS_HTTPS" => config[:use_https] ? "1" : "0",
        "PORTLESS_LAN" => config[:lan_mode] ? "1" : "0",
        "PORTLESS_WILDCARD" => config[:use_wildcard] ? "1" : "0",
        "PORTLESS_UNPRIVILEGED" => config[:unprivileged] ? "1" : "0",
        **config[:extra_env]
      }
      env["PORTLESS_LAN_IP"] = config[:lan_ip] if config[:lan_mode] && config[:lan_ip_explicit] && config[:lan_ip]
      if config[:lan_mode]
        env["PORTLESS_TLD"] = "local"
      elsif config[:tlds].length > 1 || config[:tld] != Daemon::DEFAULT_TLD
        env["PORTLESS_TLD"] = config[:tlds].join(",")
      end
      env["HOME"] = ctx[:user][:home]
      env["SUDO_UID"] = ctx[:user][:uid] if ctx[:user][:uid]
      env["SUDO_GID"] = ctx[:user][:gid] if ctx[:user][:gid]
      env
    end

    def default_state_dir(user_home) = File.join(user_home, File.basename(Constants::DEFAULT_STATE_DIR))

    def xml_escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&apos;")
    end

    def xml_unescape(value)
      value.gsub("&apos;", "'").gsub("&quot;", '"').gsub("&gt;", ">").gsub("&lt;", "<").gsub("&amp;", "&")
    end

    def systemd_escape(value) = "\"#{value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}\""

    def build_launchd_plist(ctx, program_arguments)
      env_entries = build_service_env(ctx).map do |key, value|
        "    <key>#{xml_escape(key)}</key>\n    <string>#{xml_escape(value)}</string>"
      end.join("\n")
      args = program_arguments.map { |arg| "    <string>#{xml_escape(arg)}</string>" }.join("\n")
      log = xml_escape(File.join(ctx[:state_dir], "service.log"))
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{LABEL}</string>
          <key>ProgramArguments</key>
          <array>
        #{args}
          </array>
          <key>EnvironmentVariables</key>
          <dict>
        #{env_entries}
          </dict>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>#{log}</string>
          <key>StandardErrorPath</key>
          <string>#{log}</string>
        </dict>
        </plist>
      PLIST
    end

    def build_systemd_unit(ctx, exec_start)
      env_lines = build_service_env(ctx).map { |key, value| "Environment=#{key}=#{systemd_escape(value)}" }.join("\n")
      <<~UNIT
        [Unit]
        Description=rb-portless HTTPS proxy
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        #{env_lines}
        Environment=PATH=#{systemd_escape(ctx[:path_env])}
        ExecStart=#{exec_start.map { |a| systemd_escape(a) }.join(' ')}
        Restart=on-failure
        RestartSec=2
        KillSignal=SIGTERM
        TimeoutStopSec=5

        [Install]
        WantedBy=multi-user.target
      UNIT
    end

    # service.ts buildServiceSpec. entry_argv = how to run this CLI (ruby -I
    # lib exe/rb-portless), i.e. upstream's [nodePath, entryScript].
    def build_spec(platform:, entry_argv:, user_home:, uid: nil, gid: nil, username: nil, state_dir: nil,
                   path_env: nil, install_config: {})
      config = default_config.merge(install_config)
      config[:extra_env] = install_config[:extra_env] || {}
      config[:tlds] = if config[:lan_mode]
                        [ "local" ]
      else
                        Daemon.normalize_tlds(install_config[:tlds] || (install_config[:tld] ? [ install_config[:tld] ] : config[:tlds]))
      end
      config[:tld] = Daemon.primary_tld(config[:tlds])
      state_dir = state_dir || config[:state_dir] || default_state_dir(user_home)
      config[:state_dir] = state_dir
      ctx = { platform: platform, state_dir: state_dir, config: config,
              user: { home: user_home, uid: uid, gid: gid, username: username },
              path_env: path_env.to_s.empty? ? DEFAULT_PATH : path_env }
      command = build_proxy_command(entry_argv, config)

      case platform
      when "darwin"
        { platform: "darwin", label: LABEL, plist_path: "/Library/LaunchDaemons/#{LABEL}.plist",
          plist: build_launchd_plist(ctx, command), state_dir: state_dir, config: config, program_arguments: command }
      when "linux"
        { platform: "linux", service_name: SYSTEMD_SERVICE, unit_path: "/etc/systemd/system/#{SYSTEMD_SERVICE}",
          unit: build_systemd_unit(ctx, command), state_dir: state_dir, config: config, exec_start: command }
      else
        raise Error, "Unsupported platform: #{platform} (the Windows boot service is not available in rb-portless)"
      end
    end

    def current_spec(install_config = nil)
      platform = Privilege.host_platform
      user = resolve_user_context
      state_dir = install_config&.dig(:state_dir) || (ENV["PORTLESS_STATE_DIR"].to_s.empty? ? nil : ENV["PORTLESS_STATE_DIR"]) ||
                  default_state_dir(user[:home])
      config = install_config || default_config.merge(state_dir: state_dir, extra_env: collect_extra_env(ENV))
      build_spec(platform: platform, entry_argv: Privilege.cli_argv, user_home: user[:home], uid: user[:uid],
                 gid: user[:gid], username: user[:username], state_dir: state_dir, path_env: ENV["PATH"],
                 install_config: config)
    end

    # Words with "…" quoting and \" / \\ escapes. service.ts parseQuotedWords.
    def parse_quoted_words(input)
      words = []
      current = +""
      in_quote = false
      in_word = false
      i = 0
      while i < input.length
        char = input[i]
        if char == '"'
          in_quote = !in_quote
          in_word = true
        elsif char == "\\" && i + 1 < input.length && [ '"', "\\" ].include?(input[i + 1])
          current << input[i + 1]
          in_word = true
          i += 1
        elsif char.match?(/\s/) && !in_quote
          if in_word
            words << current
            current = +""
            in_word = false
          end
        else
          current << char
          in_word = true
        end
        i += 1
      end
      words << current if in_word
      words
    end

    def read_installed_snapshot(spec)
      if spec[:platform] == "darwin"
        return nil unless File.exist?(spec[:plist_path])

        plist = File.read(spec[:plist_path])
        args_block = plist[%r{<key>ProgramArguments</key>\s*<array>([\s\S]*?)</array>}, 1] or return nil
        env_block = plist[%r{<key>EnvironmentVariables</key>\s*<dict>([\s\S]*?)</dict>}, 1]
        command = args_block.scan(%r{<string>([\s\S]*?)</string>}).map { |(v)| xml_unescape(v) }
        env = (env_block || "").scan(%r{<key>([\s\S]*?)</key>\s*<string>([\s\S]*?)</string>})
                               .to_h { |k, v| [ xml_unescape(k), xml_unescape(v) ] }
        return { command: command, env: env }
      end

      return nil unless File.exist?(spec[:unit_path])

      env = {}
      command = nil
      File.read(spec[:unit_path]).each_line do |line|
        line = line.chomp
        if line.start_with?("Environment=")
          entry = line.delete_prefix("Environment=")
          eq = entry.index("=")
          env[entry[0...eq]] = parse_quoted_words(entry[(eq + 1)..]).first || "" if eq&.positive?
        elsif line.start_with?("ExecStart=")
          command = parse_quoted_words(line.delete_prefix("ExecStart="))
        end
      end
      command ? { command: command, env: env } : nil
    rescue StandardError
      nil
    end

    def installed_config_from_snapshot(snapshot, fallback)
      idx = snapshot[:command].each_index.find { |i| snapshot[:command][i] == "proxy" && snapshot[:command][i + 1] == "start" }
      return nil unless idx

      parsed = parse_install_config([ "service", "install", *snapshot[:command][(idx + 2)..] ], snapshot[:env],
                                    allow_runtime_flags: true)
      parsed.merge(state_dir: parsed[:state_dir] || snapshot[:env]["PORTLESS_STATE_DIR"] || fallback[:state_dir])
    rescue StandardError
      nil
    end

    def read_installed_config(spec)
      snapshot = read_installed_snapshot(spec) or return nil
      installed_config_from_snapshot(snapshot, spec[:config])
    end

    def elevated_env_args(home:, state_dir:, env: ENV, extra_env: {})
      omit = [ "PORTLESS_STATE_DIR", *extra_env.keys ]
      [ "env", *Privilege.portless_env_args(env, omit: omit), *extra_env.map { |k, v| "#{k}=#{v}" },
        "HOME=#{home}", "PORTLESS_STATE_DIR=#{state_dir}" ]
    end

    # sudo argv for `service uninstall` (used by `clean`).
    def uninstall_sudo_args(home: Dir.home, state_dir: nil, env: ENV)
      state_dir ||= env["PORTLESS_STATE_DIR"].to_s.empty? ? default_state_dir(home) : env["PORTLESS_STATE_DIR"]
      [ *elevated_env_args(home: home, state_dir: state_dir, env: env), *Privilege.cli_argv, "service", "uninstall" ]
    end

    # Re-run under sudo (exits with its status) unless already elevated.
    def require_unix_elevation(args)
      return unless %w[darwin linux].include?(Privilege.host_platform)
      return if Privilege.root? || ENV[INTERNAL_ELEVATED_ENV] == "1"

      home = Dir.home
      state_dir = ENV["PORTLESS_STATE_DIR"].to_s.empty? ? default_state_dir(home) : ENV["PORTLESS_STATE_DIR"]
      ok = system("sudo", *elevated_env_args(home: home, state_dir: state_dir,
                                             extra_env: { INTERNAL_ELEVATED_ENV => "1" }),
                  *Privilege.cli_argv, *args)
      exit(ok ? 0 : ($?&.exitstatus || 1))
    end

    def run_cmd(*cmd, inherit: false)
      if inherit
        ok = system(*cmd)
        return { status: ok.nil? ? nil : $?.exitstatus, stdout: "", stderr: "" }
      end
      out, errout, status = Open3.capture3(*cmd)
      { status: status.exitstatus, stdout: out, stderr: errout }
    rescue SystemCallError => e
      { status: nil, stdout: "", stderr: "", error: e }
    end

    def command_failure(result, command)
      (result[:stderr].to_s.empty? ? nil : result[:stderr]) || (result[:stdout].to_s.empty? ? nil : result[:stdout]) ||
        result[:error]&.message || "#{command} failed"
    end

    def run_required(*cmd)
      result = run_cmd(*cmd)
      raise Error, command_failure(result, cmd.first).strip unless result[:status] == 0 # rubocop:disable Style/NumericPredicate
    end

    def target_missing?(result)
      "#{result[:stderr]}\n#{result[:stdout]}".match?(
        /(not|could not be) found|could not find|no such process|not exist|not loaded|not running/i
      )
    end

    def run_removal_step(*cmd)
      result = run_cmd(*cmd)
      return if result[:status] == 0 || target_missing?(result) # rubocop:disable Style/NumericPredicate
      raise result[:error] if result[:error]

      raise Error, command_failure(result, cmd.first).strip
    end

    def removal_needs_elevation?(error)
      return false if Constants::WINDOWS || Privilege.root? || ENV[INTERNAL_ELEVATED_ENV] == "1"
      return false if error.is_a?(Errno::ENOENT) || error.is_a?(Errno::EINVAL) || error.is_a?(Errno::ENOTDIR)

      true
    end

    def stop_existing_proxy(proxy_port)
      ports = []
      begin
        state = Daemon.discover_state
        ports << state[:port] if state[:port] != proxy_port && Daemon.proxy_running?(state[:port])
      rescue StandardError
        nil
      end
      ports << proxy_port
      ports.uniq.each { |port| run_required(*Privilege.cli_argv, "proxy", "stop", "--port", port.to_s) }
    end

    def prepare_state(state_dir)
      unsafe = State.ensure_state_dir(state_dir)
      raise Error, "Cannot install the service with state in #{state_dir}: #{unsafe}" if unsafe
    end

    def prepare_trust(state_dir)
      begin
        Daemon.ensure_certs(state_dir)
      rescue StandardError => e
        raise Error, "Failed to generate certificates in #{state_dir}. Ensure OpenSSL is installed.\n#{e.message}"
      end
      return if Trust.trusted?(state_dir)

      puts Colors.gray("Trusting rb-portless CA for service startup...")
      result = Trust.trust_ca(state_dir)
      if result[:trusted]
        puts Colors.green("CA added to the system trust store.")
        return
      end
      warn Colors.yellow("Could not add the CA to the system trust store.", io: $stderr)
      warn Colors.gray(result[:error], io: $stderr) if result[:error]
      warn Colors.yellow("Run `rb-portless trust` if browsers show certificate warnings.", io: $stderr)
    end

    def ensure_config_supported(config)
      return unless config[:lan_mode]

      support = Mdns.supported
      return if support[:supported]

      raise Error, "LAN mode requires mDNS publishing, which is not supported on this platform." \
                   "#{support[:reason] ? "\n#{support[:reason]}" : ''}"
    end

    # CLI entry point: install flags as keywords (nil/false = not given).
    def install(port: nil, https: nil, no_tls: nil, lan: nil, ip: nil, tlds: nil, wildcard: nil,
                unprivileged: nil, cert: nil, key: nil, state_dir: nil)
      args = %w[service install]
      args.push("--port", port.to_s) if port
      args << "--https" if https
      args << "--no-tls" if no_tls
      args << "--lan" if lan
      args.push("--ip", ip) if ip
      Array(tlds).each { |tld| args.push("--tld", tld) }
      args << "--wildcard" if wildcard
      args << "--unprivileged" if unprivileged
      args.push("--cert", cert) if cert
      args.push("--key", key) if key
      args.push("--state-dir", state_dir) if state_dir
      install_from_args(args)
    end

    def install_from_args(args)
      config = normalize_install_paths(parse_install_config(args))
      ensure_config_supported(config)
      require_unix_elevation(args)
      spec = current_spec(config)
      prepare_state(spec[:state_dir])
      with_state_dir(spec[:state_dir]) do
        prepare_trust(spec[:state_dir]) if spec[:config][:use_https] && !spec[:config][:custom_cert_path]
      end

      if spec[:platform] == "darwin"
        run_cmd("launchctl", "bootout", "system", spec[:plist_path])
        stop_existing_proxy(spec[:config][:proxy_port])
        File.write(spec[:plist_path], spec[:plist])
        File.chmod(0o644, spec[:plist_path])
        run_required("chown", "root:wheel", spec[:plist_path])
        run_required("launchctl", "bootstrap", "system", spec[:plist_path])
        run_required("launchctl", "enable", "system/#{spec[:label]}")
        run_required("launchctl", "kickstart", "-k", "system/#{spec[:label]}")
      else
        run_cmd("systemctl", "disable", "--now", spec[:service_name])
        stop_existing_proxy(spec[:config][:proxy_port])
        File.write(spec[:unit_path], spec[:unit])
        File.chmod(0o644, spec[:unit_path])
        run_required("systemctl", "daemon-reload")
        run_required("systemctl", "enable", spec[:service_name])
        run_required("systemctl", "restart", spec[:service_name])
      end

      puts Colors.green("rb-portless service installed.")
      puts Colors.gray("State directory: #{spec[:state_dir]}")
      puts Colors.gray("Proxy port: #{spec[:config][:proxy_port]}")
    end

    def with_state_dir(dir)
      previous = ENV["PORTLESS_STATE_DIR"]
      ENV["PORTLESS_STATE_DIR"] = dir
      yield
    ensure
      ENV["PORTLESS_STATE_DIR"] = previous
    end

    def uninstall
      require_unix_elevation(%w[service uninstall])
      spec = current_spec
      if spec[:platform] == "darwin"
        run_removal_step("launchctl", "bootout", "system/#{spec[:label]}")
        FileUtils.rm_f(spec[:plist_path])
      else
        run_removal_step("systemctl", "disable", "--now", spec[:service_name])
        FileUtils.rm_f(spec[:unit_path])
        run_cmd("systemctl", "daemon-reload")
      end
      puts Colors.green("rb-portless service uninstalled.")
    end

    # Best-effort removal for `clean` (caller already elevated if needed).
    # → {removed:, installed:, error:, needs_elevation:}
    def try_uninstall
      installed = false
      spec = current_spec
      if spec[:platform] == "darwin"
        installed = File.exist?(spec[:plist_path])
        return { removed: false, installed: false } unless installed

        run_removal_step("launchctl", "bootout", "system/#{spec[:label]}")
        FileUtils.rm_f(spec[:plist_path])
      else
        installed = File.exist?(spec[:unit_path])
        return { removed: false, installed: false } unless installed

        run_removal_step("systemctl", "disable", "--now", spec[:service_name])
        FileUtils.rm_f(spec[:unit_path])
        run_cmd("systemctl", "daemon-reload")
      end
      { removed: true, installed: true }
    rescue StandardError => e
      { removed: false, installed: installed, error: e.message, needs_elevation: installed && removal_needs_elevation?(e) }
    end

    # Is a boot service on disk? (world-readable; never needs sudo)
    def installed?
      spec = current_spec
      File.exist?(spec[:platform] == "darwin" ? spec[:plist_path] : spec[:unit_path])
    rescue StandardError
      false
    end

    def status_info
      spec = current_spec
      config = read_installed_config(spec) || spec[:config]
      proxy_running = Daemon.proxy_running?(config[:proxy_port], config[:use_https])
      if spec[:platform] == "darwin"
        installed = File.exist?(spec[:plist_path])
        result = run_cmd("launchctl", "print", "system/#{spec[:label]}")
        output = "#{result[:stdout]}#{result[:stderr]}"
        state = if result[:status] == 0 && output.match?(/state = running|pid = \d+/) then "running" # rubocop:disable Style/NumericPredicate
        elsif installed then "installed"
        else "not installed"
        end
        return { installed: installed, manager_state: state, proxy_running: proxy_running, config: config,
                 details: spec[:plist_path] }
      end

      enabled = run_cmd("systemctl", "is-enabled", spec[:service_name])
      active = run_cmd("systemctl", "is-active", spec[:service_name])
      installed = enabled[:status] == 0 || active[:status] == 0 || File.exist?(spec[:unit_path]) # rubocop:disable Style/NumericPredicate
      active_text = active[:stdout].to_s.strip
      state = if active[:status] == 0 then active_text.empty? ? "active" : active_text # rubocop:disable Style/NumericPredicate
      elsif installed then "installed"
      else "not installed"
      end
      { installed: installed, manager_state: state, proxy_running: proxy_running, config: config,
        details: spec[:unit_path] }
    end

    def status
      info = status_info
      config = info[:config]
      puts Colors.bold("rb-portless service")
      puts "  Manager state: #{info[:manager_state]}"
      puts "  Installed: #{info[:installed] ? 'yes' : 'no'}"
      puts "  Proxy on #{config[:proxy_port]}: #{info[:proxy_running] ? 'responding' : 'not responding'}"
      puts "  HTTPS: #{config[:use_https] ? 'yes' : 'no'}"
      puts "  TLDs: #{config[:lan_mode] ? '.local' : Daemon.format_tld_list(config[:tlds])}"
      puts "  LAN mode: #{config[:lan_mode] ? 'yes' : 'no'}"
      puts "  LAN IP: #{config[:lan_ip]}" if config[:lan_ip_explicit] && config[:lan_ip]
      puts "  Wildcard: #{config[:use_wildcard] ? 'yes' : 'no'}"
      puts "  Unprivileged: #{config[:unprivileged] ? 'yes' : 'no'}"
      puts "  State directory: #{config[:state_dir]}"
      puts "  Service entry: #{info[:details]}" if info[:details]
    end

    # Same text as `service --help` (upstream: one printServiceHelp).
    def print_help = Object.new.extend(Help).print_service_help

    # `rb-portless service …` (argv includes "service"). service.ts handleService.
    def handle(args)
      action = args[1]
      unless action
        print_help
        exit 0
      end
      return install_from_args(args) if action == "install"
      unless %w[uninstall status].include?(action)
        raise UsageError.new("Unknown service command \"#{action}\".", [ "See: rb-portless service --help" ])
      end
      raise UsageError, "Unexpected argument \"#{args[2]}\" for rb-portless service #{action}." if args.length > 2

      action == "uninstall" ? uninstall : status
    end
  end
end
