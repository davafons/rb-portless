# frozen_string_literal: true

require "json"
require "resolv"

module Portless
  # Command dispatch. Mirrors portless's cli.ts main(): global flags
  # (--lan/--ip/--tailscale/--funnel/--ngrok/--cloudflare/--script) are
  # stripped only from the leading portless flag region and turned into
  # PORTLESS_* env; then a reserved command word dispatches, zero args run the
  # package.json dev script, and anything else is named mode
  # (`rb-portless <name> <cmd…>`). UsageError → exit 2, other errors → 1.
  class CLI
    include Help

    GLOBAL_BOOLEAN_FLAGS = %w[--lan --tailscale --funnel --ngrok --cloudflare].freeze
    GLOBAL_VALUE_FLAGS = [ "--ip", Daemon::INTERNAL_LAN_IP_FLAG, "--script" ].freeze

    RUN_FLAG_SPEC = {
      "--name" => :value, "--prefix" => :text, "--force" => :boolean, "--app-port" => :value,
      "--tailscale" => :boolean, "--funnel" => :boolean, "--ngrok" => :boolean, "--cloudflare" => :boolean,
      "--help" => :boolean, "-h" => :boolean
    }.freeze

    APP_FLAG_SPEC = {
      "--force" => :boolean, "--app-port" => :value, "--tailscale" => :boolean, "--funnel" => :boolean,
      "--ngrok" => :boolean, "--cloudflare" => :boolean, "--help" => :boolean, "-h" => :boolean
    }.freeze

    NAMED_USAGE = [ "Usage:", "  rb-portless <name> <command...>", "Example:", "  rb-portless myapp next dev" ].freeze

    # Raised to stop with an exit code after output was already printed
    # (upstream's process.exit(n) mid-handler).
    class Exit < StandardError
      attr_reader :code

      def initialize(code)
        super("exit #{code}")
        @code = code
      end
    end

    ParsedRunArgs = Struct.new(:force, :app_port, :name, :prefix, :command_args, keyword_init: true)

    def self.start(argv = ARGV)
      code = new(argv).main
      exit(code || 0)
    end

    def initialize(argv)
      @args = argv.dup
    end

    def main
      dispatch || 0
    rescue Exit => e
      e.code
    rescue UsageError => e
      warn Colors.red("Error: #{e.message}", io: $stderr)
      e.hints.each { |hint| warn Colors.blue(hint, io: $stderr) }
      2
    rescue StandardError => e
      warn "#{Colors.red('Error:', io: $stderr)} #{e.message}"
      1
    end

    # ── main() ────────────────────────────────────────────────────────────
    def dispatch
      args = @args
      apply_global_flags(args)
      global_script = @global_script

      if args[0]&.start_with?("--name=")
        args[0, 1] = [ "--name", args[0].delete_prefix("--name=") ]
      end
      explicit_name = args[0] == "--name"
      if explicit_name
        args.shift
        raise UsageError.new("--name requires an app name.", [ "  rb-portless --name <name> <command...>" ]) unless args[0]
      end
      command = explicit_name || !Commands.command_name?(args[0]) ? nil : args[0]
      run_command = command == "run"

      if Portless.skip_proxy? && !explicit_name && !run_command && (args.empty? || args[0] == "--")
        script_args = args[0] == "--" ? args[1..] : []
        app_config = Config.load_app_config
        script_name = global_script || app_config&.dig("script") || "dev"
        forwarded = CLI.forward_script_extra_args(script_name, Dir.pwd, script_args)
        resolved = Config.resolve_script_command(script_name, Dir.pwd, forwarded)
        return RunSupport.spawn_command(resolved) if resolved

        raise UsageError, "No command provided."
      end

      if Portless.skip_proxy? && (run_command || args.empty? || (args.length >= 2 && command.nil?))
        parsed = run_command ? parse_run_args(args[1..]) : parse_app_args(args)
        command_args = parsed.command_args
        if command_args.empty? && run_command
          app_config = Config.load_app_config
          script_name = global_script || app_config&.dig("script") || "dev"
          resolved = Config.resolve_script_command(script_name, Dir.pwd)
          command_args = resolved if resolved
        end
        raise UsageError, "No command provided." if command_args.empty?

        return RunSupport.spawn_command(command_args)
      end

      if command
        return send(HELP_PRINTERS.fetch(command)) if HELP_PRINTERS.key?(command) && Commands.help_flag?(args)

        return run_named_command(command, args, global_script)
      end

      unless explicit_name
        return print_help if [ "--help", "-h" ].include?(args[0])
        if args.empty? || args[0] == "--"
          extra = args[0] == "--" ? args[1..] : []
          handled = handle_default_mode(global_script, extra)
          return handled unless handled.nil?

          return print_help
        end
        return print_version if [ "--version", "-v" ].include?(args[0])
      end

      handle_named_mode(args, explicit_name)
    end

    HELP_PRINTERS = {
      "get" => :print_get_help, "list" => :print_list_help, "proxy" => :print_proxy_help,
      "service" => :print_service_help, "hosts" => :print_hosts_help, "doctor" => :print_doctor_help,
      "trust" => :print_trust_help, "clean" => :print_clean_help, "prune" => :print_prune_help,
      "mcp" => :print_mcp_help
    }.freeze

    def run_named_command(command, args, global_script)
      case command
      when "run" then handle_run_mode(args[1..], global_script)
      when "get" then handle_get(args)
      when "list" then handle_list(args)
      when "alias" then handle_alias(args)
      when "proxy" then handle_proxy(args)
      when "service" then handle_service(args)
      when "hosts" then handle_hosts(args)
      when "doctor" then handle_doctor(args)
      when "trust" then CLI.handle_trust(args)
      when "clean" then handle_clean(args)
      when "prune" then handle_prune(args)
      when "mcp" then Mcp.run(args[1..])
      when "compose" then Compose::Command.new(args[1..]).run
      end
    end

    # The leading portless flag region: global flags (plus `run`'s own) up to
    # the first word that belongs to the wrapped command.
    def global_flag_end(args)
      sep = args.index("--")
      limit = sep || args.length
      index = advance_flags(args, 0, limit, [ "--app-port" ])
      return limit if index >= limit

      mode = args[index]
      return index if %w[mcp compose].include?(mode)
      return advance_flags(args, index + 1, limit, %w[--name --prefix --app-port]) if mode == "run"
      return limit if Commands.command_name?(mode) || %w[--version -v].include?(mode)

      index += mode == "--name" ? 2 : 1
      advance_flags(args, index, limit, [ "--app-port" ])
    end

    def advance_flags(args, index, limit, local_value_flags)
      while index < limit
        arg = args[index]
        eq = arg.start_with?("--") ? arg.index("=") : nil
        flag = eq ? arg[0...eq] : arg
        if GLOBAL_BOOLEAN_FLAGS.include?(flag) || %w[--force --help -h].include?(flag)
          index += 1
        elsif GLOBAL_VALUE_FLAGS.include?(flag) || local_value_flags.include?(flag)
          index += eq ? 1 : 2
        else
          break
        end
      end
      index
    end

    # => true (boolean found), String (value), false (value missing), nil (absent)
    def strip_global_flag(args, flag, has_value)
      last = global_flag_end(args)
      idx = args.each_index.find { |i| i < last && (args[i] == flag || (has_value && args[i].start_with?("#{flag}="))) }
      return nil if idx.nil?

      unless has_value
        args.delete_at(idx)
        return true
      end
      eq = args[idx].index("=")
      value = eq ? args[idx][(eq + 1)..] : args[idx + 1]
      return false if value.nil? || value.empty? || value.start_with?("-")

      args.slice!(idx, eq ? 1 : 2)
      value
    end

    def apply_global_flags(args)
      ENV["PORTLESS_LAN"] = "1" if strip_global_flag(args, "--lan", false)

      ip_hint = [ "  rb-portless --lan --ip 192.168.1.42 run <command>" ]
      ip = strip_global_flag(args, "--ip", true)
      raise UsageError.new("--ip requires an IP address.", ip_hint) if ip == false
      if ip.is_a?(String)
        raise UsageError.new("--ip requires an IP address, but got \"#{ip}\".", ip_hint) unless ip_address?(ip)

        ENV["PORTLESS_LAN_IP"] = ip
        ENV["PORTLESS_LAN"] = "1"
      end

      auto_ip = strip_global_flag(args, Daemon::INTERNAL_LAN_IP_FLAG, true)
      raise UsageError, "#{Daemon::INTERNAL_LAN_IP_FLAG} requires an IP address." if auto_ip == false
      if auto_ip.is_a?(String)
        ENV[Daemon::INTERNAL_LAN_IP_ENV] = auto_ip
        ENV["PORTLESS_LAN"] = "1"
      end

      ENV["PORTLESS_TAILSCALE"] = "1" if strip_global_flag(args, "--tailscale", false)
      if strip_global_flag(args, "--funnel", false)
        ENV["PORTLESS_FUNNEL"] = "1"
        ENV["PORTLESS_TAILSCALE"] = "1"
      end
      ENV["PORTLESS_NGROK"] = "1" if strip_global_flag(args, "--ngrok", false)
      ENV["PORTLESS_CLOUDFLARE"] = "1" if strip_global_flag(args, "--cloudflare", false)

      script = strip_global_flag(args, "--script", true)
      raise UsageError.new("--script requires a script name.", [ "  rb-portless --script start" ]) if script == false

      @global_script = script.is_a?(String) ? script : nil
    end

    # Node's net.isIP: dotted-quad IPv4 or IPv6 (optional %zone), nothing else.
    def ip_address?(value)
      value.match?(Resolv::IPv4::Regex) || value.sub(/%[0-9a-zA-Z\-.:]+\z/, "").match?(Resolv::IPv6::Regex)
    end

    # ── run / named mode argument parsing ─────────────────────────────────
    def parse_app_port(value)
      raise UsageError, "--app-port requires a port number." if value.nil? || value.start_with?("--")

      Utils.parse_port(value) or raise UsageError, "Invalid app port \"#{value}\". Must be 1-65535."
    end

    def self.app_port_from_env
      value = ENV["PORTLESS_APP_PORT"]
      return nil if value.nil? || value.empty?

      port = Utils.parse_port(value)
      unless port
        warn Colors.red("Error: Invalid PORTLESS_APP_PORT=\"#{value}\". Must be 1-65535.", io: $stderr)
        raise Exit, 1
      end
      port
    end

    def enable_sharing_flag(flag)
      case flag
      when "--tailscale" then ENV["PORTLESS_TAILSCALE"] = "1"
      when "--funnel"
        ENV["PORTLESS_FUNNEL"] = "1"
        ENV["PORTLESS_TAILSCALE"] = "1"
      when "--ngrok" then ENV["PORTLESS_NGROK"] = "1"
      when "--cloudflare" then ENV["PORTLESS_CLOUDFLARE"] = "1"
      end
    end

    def parse_run_args(args)
      parsed = ParsedRunArgs.new(force: false)
      parsed.command_args = Args.visit_leading_flags("run", args, RUN_FLAG_SPEC) do |flag, value|
        if [ "--help", "-h" ].include?(flag)
          print_run_help
          raise Exit, 0
        end
        case flag
        when "--force" then parsed.force = true
        when "--app-port" then parsed.app_port = parse_app_port(value)
        when "--name" then parsed.name = value
        when "--prefix" then parsed.prefix = value
        else enable_sharing_flag(flag)
        end
      end
      parsed.app_port ||= CLI.app_port_from_env
      parsed
    end

    def parse_app_args(args)
      parsed = ParsedRunArgs.new(force: false)
      read_flag = lambda do |flag, value|
        if [ "--help", "-h" ].include?(flag)
          print_run_help
          raise Exit, 0
        end
        if flag == "--force" then parsed.force = true
        elsif flag == "--app-port" then parsed.app_port = parse_app_port(value)
        else enable_sharing_flag(flag)
        end
      end
      after = Args.visit_leading_flags("", args, APP_FLAG_SPEC, &read_flag)
      parsed.name = after[0]
      command_args = after[1..] || []
      if !command_args.empty? && (command_args[0].start_with?("--") || command_args[0] == "-h")
        command_args = Args.visit_leading_flags("", command_args, APP_FLAG_SPEC, &read_flag)
      end
      parsed.command_args = command_args
      parsed.app_port ||= CLI.app_port_from_env
      parsed
    end

    # Name + whether a command follows, read before flags are validated so a
    # misspelled command is reported instead of its flags.
    def read_named_args(args)
      stop = args.index("--")
      region = stop ? args[0...stop] : args
      words = region.each_with_index.reject { |a, i| a.start_with?("-") || (i.positive? && region[i - 1] == "--app-port") }
                    .map(&:first)
      words.concat(args[(stop + 1)..]) if stop
      [ words[0], words.length > 1 ]
    end

    def self.truncate_name(name) = name.split(".", -1).map { |l| Auto.truncate_label(l) }.join(".")

    def run_app(name:, command_args:, force:, auto_info:, desired_port:)
      state = Daemon.discover_state
      Runner.new(store: Utils.new_route_store(state.dir), proxy_port: state.port, state_dir: state.dir, name: name,
                 command_args: command_args, tls: state.tls, tlds: state.tlds, force: force,
                 auto_info: auto_info, desired_port: desired_port, lan_mode: state.lan_mode,
                 lan_ip: state.lan_ip).run
    end

    def handle_run_mode(args, global_script)
      parsed = parse_run_args(args)
      ENV["PORTLESS_PREFIX"] = parsed.prefix unless parsed.prefix.nil?
      app_config = Config.load_app_config

      if parsed.command_args.empty?
        script_name = global_script || app_config&.dig("script") || "dev"
        resolved = Config.resolve_script_command(script_name, Dir.pwd)
        parsed.command_args = resolved if resolved
      end
      if parsed.command_args.empty?
        raise UsageError.new("No command provided.",
                             [ "Usage:", "  rb-portless run <command...>", "Example:", "  rb-portless run next dev" ])
      end

      if parsed.name
        base_name = CLI.truncate_name(parsed.name)
        name_source = "--name flag"
      elsif app_config&.dig("name")
        base_name = CLI.truncate_name(app_config["name"])
        name_source = app_config["source"]
      else
        inferred = Auto.infer_project_name
        base_name = inferred.name
        name_source = inferred.source
      end
      parsed.app_port ||= app_config&.dig("appPort")

      worktree = Auto.detect_worktree_prefix(Dir.pwd, app_config&.dig("worktree", "prefix"))
      effective = Auto.apply_worktree_prefix(base_name, worktree, app_config&.dig("worktree", "hostnameTemplate"))
      run_app(name: effective, command_args: parsed.command_args, force: parsed.force,
              auto_info: Runner::AutoInfo.new(name_source: name_source, base_name: base_name,
                                              prefix: worktree&.prefix, prefix_source: worktree&.source),
              desired_port: parsed.app_port)
    end

    def handle_named_mode(args, explicit_name)
      name, has_command = read_named_args(args)
      suggestion = explicit_name || has_command ? nil : Commands.suggest_command(name)
      if name && suggestion
        raise UsageError.new("No command provided.",
                             [ "\"#{name}\" is not a rb-portless command. Did you mean:", "  rb-portless #{suggestion}",
                               *NAMED_USAGE ])
      end

      parsed = parse_app_args(args)
      raise UsageError.new("No command provided.", NAMED_USAGE) if parsed.command_args.empty?

      parsed.app_port ||= Config.load_app_config&.dig("appPort")
      safe_name = CLI.truncate_name(parsed.name)
      Utils.parse_hostname(safe_name, Utils::DEFAULT_TLD)
      run_app(name: safe_name, command_args: parsed.command_args, force: parsed.force, auto_info: nil,
              desired_port: parsed.app_port)
    end

    # ── zero-arg mode ─────────────────────────────────────────────────────
    # nil → not handled (print help).
    def handle_default_mode(global_script, extra_args)
      cwd = Dir.pwd
      ws_root = Workspace.find_workspace_root(cwd)
      if ws_root == File.expand_path(cwd)
        packages = Workspace.discover_workspace_packages(cwd)
        ws_script = global_script || Config.load_config(cwd)&.config&.dig("script") || "dev"
        return Multi.new(cwd, global_script, extra_args).run if packages.any? { |p| p.scripts[ws_script] }
      end

      app_config = Config.load_app_config(cwd)
      script_name = global_script || app_config&.dig("script") || "dev"
      return nil unless Config.script?(script_name, cwd)

      handle_default_single(cwd, script_name, app_config, extra_args)
    end

    def self.forward_script_extra_args(script_name, package_dir, extra_args)
      return [] if extra_args.empty?

      forwarding = Frameworks.resolve_script_arg_forwarding(script_name, package_dir)
      forwarded = extra_args.join(" ")
      case forwarding[:kind]
      when "unsafe"
        raise UsageError.new(
          "Cannot forward arguments through the \"#{forwarding[:script_name]}\" script. It has shell operators or a comment.",
          [ "Run the command directly: rb-portless run <command> #{forwarded}",
            "Or change the \"#{forwarding[:script_name]}\" script to a single command." ]
        )
      when "too-deep"
        raise UsageError.new(
          "Cannot forward arguments through the \"#{script_name}\" script. It runs through too many package " \
          "scripts, or the scripts call each other in a loop.",
          [ "Run the command directly: rb-portless run <command> #{forwarded}" ]
        )
      end
      separators = forwarding[:kind] == "forward" ? forwarding[:separators] : 0
      Array.new(separators, "--") + extra_args
    end

    def handle_default_single(cwd, script_name, app_config, extra_args)
      forwarded = CLI.forward_script_extra_args(script_name, cwd, extra_args)
      resolved = Config.resolve_script_command(script_name, cwd, forwarded)
      unless resolved
        warn Colors.red("Error: No \"#{script_name}\" script found in package.json.", io: $stderr)
        return 1
      end

      if app_config&.dig("name")
        base_name = CLI.truncate_name(app_config["name"])
        name_source = app_config["source"]
      else
        inferred = Auto.infer_project_name(cwd)
        base_name = inferred.name
        name_source = inferred.source
      end
      worktree = Auto.detect_worktree_prefix(cwd, app_config&.dig("worktree", "prefix"))
      effective = Auto.apply_worktree_prefix(base_name, worktree, app_config&.dig("worktree", "hostnameTemplate"))
      run_app(name: effective, command_args: resolved, force: false,
              auto_info: Runner::AutoInfo.new(name_source: name_source, base_name: base_name,
                                              prefix: worktree&.prefix, prefix_source: worktree&.source),
              desired_port: CLI.app_port_from_env || app_config&.dig("appPort"))
    end

    # ── get / list / alias ────────────────────────────────────────────────
    def handle_get(args)
      parsed = Args.parse_command_args("get", args[1..], { "--no-worktree" => :boolean, "--json" => :boolean }, 1)
      name = parsed.positionals[0]
      unless name
        raise UsageError.new("Missing service name.",
                             [ "Usage:", "  rb-portless get <name>", "Example:", "  rb-portless get backend" ])
      end

      skip = parsed.has?("--no-worktree")
      app_config = skip ? nil : Config.load_app_config
      worktree = skip ? nil : Auto.detect_worktree_prefix(Dir.pwd, app_config&.dig("worktree", "prefix"))
      effective = Auto.apply_worktree_prefix(name, worktree, app_config&.dig("worktree", "hostnameTemplate"))
      state = Daemon.discover_state
      hostname = Runner.build_hostnames(effective, state.tlds).first
      url = Utils.format_url(hostname, state.port, state.tls)
      $stdout.puts(parsed.has?("--json") ? JSON.generate({ name: name, hostname: hostname, url: url }) : url)
      0
    end

    def handle_list(args)
      json = Args.parse_command_args("list", args[1..], { "--json" => :boolean }, 0).has?("--json")
      state = Daemon.discover_state
      list_routes(Utils.new_route_store(state.dir), state.port, state.tls, json)
      0
    end

    def list_routes(store, proxy_port, tls, json)
      routes = store.load_routes
      if json
        output = routes.map do |r|
          h = { hostname: r.hostname, url: Utils.format_url(r.hostname, proxy_port, tls), port: r.port, pid: r.pid,
                registeredAt: r.registered_at }
          h[:upstream] = r.upstream if r.upstream
          h[:tailscaleUrl] = r.tailscale_url if r.tailscale_url
          h[:tailscaleFunnel] = r.tailscale_funnel unless r.tailscale_funnel.nil?
          h[:ngrokUrl] = r.ngrok_url if r.ngrok_url
          h[:cloudflareUrl] = r.cloudflare_url if r.cloudflare_url
          h.compact
        end
        puts JSON.generate({ routes: output })
        return
      end

      if routes.empty?
        puts Colors.yellow("No active routes.")
        puts Colors.gray("Start an app with: rb-portless <name> <command>")
        return
      end

      print Colors.bold("\nActive routes:\n"), "\n" # console.log keeps the trailing blank line
      now = (Time.now.to_f * 1000).to_i
      routes.each do |r|
        url = Utils.format_url(r.hostname, proxy_port, tls)
        upstream = r.upstream
        endpoint = upstream ? "#{upstream[:tls] ? 'https' : 'http'}://localhost:#{r.port}" : "localhost:#{r.port}"
        label = r.pid.to_i.zero? ? "(alias)" : "(pid #{r.pid})"
        uptime = r.pid.to_i.zero? ? nil : Utils.format_uptime(r.registered_at, now)
        puts "  #{Colors.cyan(url)}  #{Colors.gray('->')}  #{Colors.white(endpoint)}  #{Colors.gray(label)}" \
             "#{uptime ? " #{Colors.gray("up #{uptime}")}" : ''}"
        puts "    #{Colors.gray('Host:')} #{Colors.white(upstream[:host])}" if upstream&.dig(:host)
        if r.tailscale_url
          puts "    #{Colors.gray("#{r.tailscale_funnel ? 'funnel' : 'tailscale'}:")} #{Colors.green(r.tailscale_url)}"
        end
        Tunnel::PROCESS_TUNNELS.each do |t|
          url = r[t[:url_field]]
          puts "    #{Colors.gray("#{t[:label].downcase}:")} #{Colors.green(url)}" if url
        end
      end
      puts
    end

    def parse_alias_upstream(value)
      usage = 'Use "https", "https://<host>[:<port>]", or "http://<host>[:<port>]".'
      upstream =
        if value == "https"
          { tls: true }
        else
          m = %r{\A(https?)://(.+)\z}m.match(value)
          raise Error, usage unless m

          { tls: m[1] == "https", host: m[2] }
        end
      unless RouteStore.valid_upstream?(upstream)
        raise Error, "#{usage} The authority must be a hostname or IP with an optional port."
      end

      upstream
    end

    def handle_alias(args)
      upstream_help = args.each_with_index.any? { |a, i| a == "--upstream" && %w[--help -h].include?(args[i + 1]) }
      return print_alias_help if Commands.help_flag?(args) && !upstream_help

      parsed = Args.parse_command_args("alias", args[1..],
                                       { "--remove" => :value, "--force" => :boolean, "--tld" => :value,
                                         "--upstream" => :value }, 2)
      remove = parsed.has?("--remove")
      remove_name = parsed.value("--remove")
      alias_name, alias_port = parsed.positionals
      usage = [ "Usage:", "  rb-portless alias <name> <port>", "  rb-portless alias --remove <name>", "Example:",
                "  rb-portless alias my-postgres 5432" ]
      see = [ "See: rb-portless alias --help" ]
      raise UsageError.new("--force cannot be used with --remove.", usage) if remove && parsed.has?("--force")
      if remove && !parsed.positionals.empty?
        raise UsageError.new("Unexpected argument \"#{parsed.positionals[0]}\" for rb-portless alias.", see)
      end
      raise UsageError.new("Missing alias name.", usage) if !remove && !alias_name
      raise UsageError.new("Missing port.", usage) if !remove && !alias_port
      raise UsageError.new("--remove may be specified only once.", see) if parsed.values("--remove").length > 1

      upstream_values = parsed.values("--upstream")
      raise UsageError.new("--upstream may be specified only once.", see) if upstream_values.length > 1
      raise UsageError.new("--upstream can only be used when adding an alias.", see) if remove && !upstream_values.empty?

      upstream = nil
      if upstream_values.length == 1
        begin
          upstream = parse_alias_upstream(upstream_values[0])
        rescue Error => e
          raise UsageError.new("Invalid --upstream value. #{e.message}", see)
        end
      end

      tld_values = parsed.values("--tld")
      raise UsageError.new("--tld requires a TLD value.", see) if tld_values.any? { |v| v.strip.empty? }

      target_tlds = nil
      unless tld_values.empty?
        begin
          target_tlds = tld_values.flat_map { |v| Utils.parse_tld_list(v) }.uniq
        rescue Error => e
          raise UsageError.new(e.message, see)
        end
      end
      port = alias_port ? Utils.parse_port(alias_port) : nil
      raise UsageError.new("Invalid port \"#{alias_port}\". Must be 1-65535.", usage) if !remove && port.nil?

      state = Daemon.discover_state
      if target_tlds && (unconfigured = target_tlds.find { |t| !state.tlds.include?(t) })
        warn Colors.red("Error: TLD \"#{unconfigured}\" is not configured (#{state.tlds.join(', ')}).", io: $stderr)
        return 1
      end
      store = Utils.new_route_store(state.dir)
      store.recover_corrupt_routes_file

      if remove
        hostnames = Runner.build_hostnames(remove_name, state.tlds, target_tlds)
        routes = store.load_routes
        aliases = hostnames.select { |h| routes.any? { |r| r.hostname == h && r.pid.to_i.zero? } }
        if aliases.empty?
          warn Colors.red("Error: No alias found for \"#{hostnames.join(', ')}\".", io: $stderr)
          return 1
        end
        Runner.remove_routes(store, aliases, 0)
        puts Colors.green("Removed alias: #{aliases.join(', ')}")
        return 0
      end

      hostnames = Runner.build_hostnames(alias_name, state.tlds, target_tlds)
      Runner.add_routes(store, hostnames, port, 0, parsed.has?("--force"), upstream)
      puts Colors.green("Alias registered: #{hostnames.join(', ')} -> 127.0.0.1:#{port}")
      CLI.report_hosts_sync_here(hostnames, state.port, state.tls, state.lan_mode)
      0
    end

    # Warn on this terminal if a route it registered will not resolve. Issue #364.
    def self.report_hosts_sync_here(hostnames, port, tls, lan_mode)
      Daemon.report_hosts_sync(hostnames, port, tls, lan_mode) { |msg| warn Colors.yellow(msg, io: $stderr) }
    end

    # ── proxy / service / hosts ───────────────────────────────────────────
    def parse_port_flag!(value)
      Utils.parse_port(value) or raise UsageError.new("Invalid port number: #{value}", [ "Port must be between 1 and 65535." ])
    end

    def handle_proxy(args)
      sub = args[1]
      if sub && ![ "start", "stop" ].include?(sub)
        raise UsageError.new("Unknown proxy subcommand \"#{sub}\".", [ "See: rb-portless proxy --help" ])
      end
      return print_proxy_help unless sub

      if sub == "stop"
        parsed = Args.parse_command_args("proxy stop", args[2..], { "--port" => :value, "-p" => :value }, 0)
        (parsed.values("--port") + parsed.values("-p")).each { |v| parse_port_flag!(v) }
        value = parsed.value("--port") || parsed.value("-p")
        return Daemon.stop(port: value && Utils.parse_port(value)) ? 0 : 1
      end

      flags = Args.parse_command_args(
        "proxy start", args[2..],
        { "--foreground" => :boolean, "--skip-trust" => :boolean, "--unprivileged" => :boolean,
          "--https" => :boolean, "--no-tls" => :boolean, "--wildcard" => :boolean, "--cert" => :value,
          "--key" => :value, "--port" => :value, "-p" => :value, "--tld" => :value }, 0
      )
      cert = flags.value("--cert")
      key = flags.value("--key")
      raise UsageError, "--cert and --key must be used together." if cert.nil? != key.nil?

      port_value = flags.value("--port") || flags.value("-p")
      port = port_value && parse_port_flag!(port_value)
      result = Daemon.start(port: port, https: flags.has?("--https"), no_tls: flags.has?("--no-tls"),
                            tlds: flags.values("--tld"), wildcard: flags.has?("--wildcard"),
                            unprivileged: flags.has?("--unprivileged"), cert: cert, key: key,
                            skip_trust: flags.has?("--skip-trust"), foreground: flags.has?("--foreground"))
      result.is_a?(Integer) ? result : 0
    end

    # handleService (incl. parseServiceInstallConfig) lives in service.ts
    # upstream, so Service owns it.
    def handle_service(args)
      Service.handle(args)
      0
    end

    def handle_hosts(args)
      sub = args[1]
      return print_hosts_help unless sub
      unless %w[sync clean].include?(sub)
        raise UsageError.new("Unknown hosts subcommand \"#{sub}\".", [ "See: rb-portless hosts --help" ])
      end

      Args.parse_command_args("hosts #{sub}", args[2..], {}, 0)
      hosts_display = Hosts.hosts_display
      if sub == "clean"
        if Hosts.clean_hosts_file
          puts Colors.green("Removed rb-portless entries from #{hosts_display}.")
          return 0
        end
        return 0 if !Privilege.root? && run_hosts_with_sudo("clean")

        warn Colors.red("Failed to update #{hosts_display}.", io: $stderr)
        return 1
      end

      state = Daemon.discover_state
      store = Utils.new_route_store(state.dir)
      if (unsafe = store.untrusted_reason)
        warn Colors.red("Cannot sync hosts from routes recorded in #{state.dir}: #{unsafe}", io: $stderr)
        return 1
      end
      hostnames = store.load_routes.map(&:hostname)
      if Hosts.sync_hosts_file(hostnames)
        if hostnames.empty?
          puts Colors.green("No stale rb-portless entries remain in #{hosts_display}.")
        else
          puts Colors.green("Synced #{hostnames.length} hostname(s) to #{hosts_display}:")
          hostnames.each { |h| puts Colors.cyan("  127.0.0.1 #{h}") }
        end
        return 0
      end
      return 0 if !Privilege.root? && run_hosts_with_sudo("sync")

      warn Colors.red("Failed to update #{hosts_display}.", io: $stderr)
      1
    end

    # cli.ts runHostsCleanWithSudo (and handleHosts' inline sync retry).
    def run_hosts_with_sudo(sub)
      puts Colors.yellow("Writing to #{Hosts.hosts_display} requires elevated privileges. Requesting sudo...")
      Privilege.reexec_with_sudo([ "hosts", sub ])
    end

    # ── trust ─────────────────────────────────────────────────────────────
    def self.handle_trust(args = [ "trust" ])
      Args.parse_command_args("trust", args[1..] || [], {}, 0)
      state = Daemon.discover_state
      dir = state.dir
      State.ensure_state_dir(dir) unless File.exist?(dir)
      if (unsafe = State.explain_unsafe_state_dir(dir))
        warn Colors.red("Cannot trust the CA in #{dir}: #{unsafe}", io: $stderr)
        raise Exit, 1
      end
      result = Certs.ensure_certs(dir)
      if result.is_a?(Hash) && result[:ca_generated]
        warn Colors.gray("Generated local CA certificate.", io: $stderr)
        if Daemon.proxy_running?(state.port, state.tls)
          port_flag = state.port == Daemon.default_port(state.tls) ? "" : " -p #{state.port}"
          warn Colors.yellow("The running proxy still serves certificates from the previous CA.", io: $stderr)
          warn Colors.blue("Restart it: rb-portless proxy stop#{port_flag} && rb-portless proxy start#{port_flag}",
                           io: $stderr)
        end
      end
      trust = Trust.trust_ca(dir)
      if trust[:trusted]
        warn Colors.green("Local CA added to system trust store.", io: $stderr)
        warn Colors.gray("Browsers will now trust rb-portless HTTPS certificates.", io: $stderr)
        return 0
      end
      error = trust[:error].to_s
      if (error.include?("Permission denied") || error.include?("EACCES")) && !Privilege.root?
        warn Colors.yellow("Trusting the CA requires elevated privileges. Requesting sudo...", io: $stderr)
        ENV["PORTLESS_STATE_DIR"] = dir # forwarded by the sudo re-exec (PORTLESS_* env)
        return 0 if Privilege.reexec_with_sudo([ "trust" ])

        warn Colors.red("sudo elevation also failed.", io: $stderr)
      end
      warn Colors.red("Failed to trust CA: #{error}", io: $stderr)
      raise Exit, 1
    end

    # ── prune / clean shared helpers ──────────────────────────────────────
    # {pgid => ProcessGroup::Stop}; routes sharing a group share one outcome.
    # Groups are stopped in parallel so one survivor does not delay the others.
    def self.stop_recorded_groups(routes, signal)
      groups = routes.reject { |r| r.child_pgid.nil? }.group_by(&:child_pgid)
      threads = groups.map do |pgid, group|
        members = group.filter_map { |r| r.orphan_pid && { pid: r.orphan_pid, start_time: r.orphan_start_time } }
        Thread.new do
          [ pgid, ProcessGroup.stop_process_group(pgid, group.map(&:child_start_time), members, signal,
                                                  port: group.first.port) ]
        end
      end
      threads.to_h(&:value)
    end

    def handle_prune(args)
      force = Args.parse_command_args("prune", args[1..], { "--force" => :boolean }, 0).has?("--force")
      state = Daemon.discover_state
      store = Utils.new_route_store(state.dir)
      if (unsafe = store.untrusted_reason)
        warn Colors.red("Cannot prune routes recorded in #{state.dir}: #{unsafe}", io: $stderr)
        warn Colors.blue("Nothing was signaled.", io: $stderr)
        return 1
      end
      stale = store.find_stale_routes
      if stale.empty?
        puts "No orphaned routes found."
        return 0
      end
      live_ts_ports = store.load_routes.filter_map(&:tailscale_https_port)

      pruned = skipped = 0
      signal = force ? "KILL" : "TERM"
      stops = CLI.stop_recorded_groups(stale, signal)
      stale.each do |route|
        pgid = route.child_pgid
        stop = pgid && stops[pgid]
        if stop&.state == "survived"
          store.record_stale_orphan(route, stop.survivor[:pid], stop.survivor[:start_time]) if stop.survivor
          skipped += 1
          tail = force ? " after SIGKILL; route kept" : "; route kept. Retry with rb-portless prune --force"
          puts "  #{route.hostname} :#{route.port} - process group #{pgid} did not exit#{tail}"
          next
        end
        if stop&.state == "unverified"
          holder = ProcessGroup.running?(pgid) ? nil : PortOwner.pids_on_port(route.port).find { |pid| PortOwner.process_group_id(pid) == pgid }
          start = holder && PortOwner.start_time(holder)
          recorded = holder && start && store.record_stale_orphan(route, holder, start)
          skipped += 1
          puts(recorded ? "  #{route.hostname} :#{route.port} - process group #{pgid} outlived its leader; route kept and " \
                          "process #{holder} recorded. Retry with rb-portless prune --force"
                        : "  #{route.hostname} :#{route.port} - process group #{pgid} could not be verified; route kept " \
                          "and nothing was killed")
          next
        end
        holders = PortOwner.pids_on_port(route.port)
        held = !holders.empty? || PortOwner.port_listening?(route.port)
        unless store.remove_stale_route(route.hostname, route.pid)
          puts "  #{route.hostname} :#{route.port} - route changed or owner is alive; route kept"
          skipped += 1
          next
        end
        pruned += 1
        holder = holders.empty? ? "another process" : "PID #{holders.join(', ')}"
        puts "  #{route.hostname} :#{route.port} - route removed#{held ? "; #{holder} still holds the port and was not killed" : ''}"
        if route.tailscale_https_port && !live_ts_ports.include?(route.tailscale_https_port)
          begin
            Share::Tailscale.unregister_tailscale(https_port: route.tailscale_https_port, funnel: route.tailscale_funnel)
            puts "  #{route.hostname} - removed tailscale serve on port #{route.tailscale_https_port}"
          rescue StandardError
            warn Colors.yellow("  #{route.hostname} - could not remove tailscale serve", io: $stderr)
          end
        end
        Tunnel.stop_recorded(route, verify: true).each { |t| puts "  #{route.hostname} - stopped #{t[:label]} tunnel" }
      end

      killed = stops.count { |_, s| s.state == "stopped" && s.signaled }
      stops.each { |pgid, s| puts "  killed process group #{pgid} (SIG#{signal})" if s.state == "stopped" && s.signaled }
      skipped_summary = skipped.zero? ? "" : ", skipped #{skipped} #{skipped == 1 ? 'route' : 'routes'}"
      puts Colors.green("\nPruned #{pruned} stale #{pruned == 1 ? 'route' : 'routes'}, killed #{killed} orphaned " \
                        "#{killed == 1 ? 'process' : 'processes'}#{skipped_summary}.")
      0
    end

    def handle_clean(args)
      parsed = Args.parse_command_args("clean", args[1..], { "--yes" => :boolean, "-y" => :boolean }, 0)
      confirmed = parsed.has?("--yes") || parsed.has?("-y")
      requested_steps = CleanUtils.parse_cleanup_steps(ENV[CleanUtils::CLEAN_ELEVATED_STEPS_ENV])
      if requested_steps
        raise UsageError.new("Confirmation required.", [ "Re-run: rb-portless clean --yes" ]) unless confirmed

        return CleanUtils.run_requested_cleanup(requested_steps)
      end

      collected = CleanUtils.collect_state_dirs_for_cleanup_with_failures
      dirs = collected[:dirs]
      warn "Clean will:"
      warn "  Stop the proxy"
      warn "  Remove the startup service if installed"
      warn "  Remove the CA from the trust store"
      warn "  Delete known state files in: #{dirs.empty? ? 'no existing state directories' : dirs.join(', ')}"
      warn "  Remove the rb-portless block from #{Hosts.hosts_display}"
      collected[:failures].each do |failed|
        warn Colors.yellow("  Leave #{failed} alone: #{State.explain_unsafe_state_dir(failed) || 'it cannot be resolved'}", io: $stderr)
      end

      unless confirmed
        if !$stdin.tty? || !$stderr.tty? || ENV["CI"]
          raise UsageError.new("Confirmation required.", [ "Re-run: rb-portless clean --yes" ])
        end

        $stderr.print "Continue? [y/N] "
        answer = $stdin.gets.to_s.strip
        unless %w[y yes].include?(answer)
          warn "Clean canceled."
          return 1
        end
      end

      problems = collected[:failures].length
      service = Service.try_uninstall
      if service[:removed]
        puts Colors.green("Removed startup service.")
      elsif service[:needs_elevation] && !Constants::WINDOWS && !Privilege.root?
        unless run_service_uninstall_with_sudo("Removing the startup service requires elevated privileges.")
          warn Colors.red("Failed to remove startup service with sudo.", io: $stderr)
          return 1
        end
      elsif service[:error]
        message = "Could not remove startup service: #{service[:error]}"
        if service[:installed]
          warn Colors.red(message, io: $stderr)
          return 1
        end
        warn Colors.yellow(message, io: $stderr)
        problems += 1
      end

      puts Colors.cyan("Stopping proxy if it is running...")
      state = Daemon.discover_state
      store = Utils.new_route_store(state.dir)
      proxy_stopped = Daemon.stop_proxy(state.dir, state.port)
      if proxy_stopped && Health.proxy_running?(state.port, state.tls)
        warn Colors.red("Proxy is still running on port #{state.port}. Stop it and retry clean.", io: $stderr)
        proxy_stopped = false
      end
      problems += 1 unless proxy_stopped

      routes = begin
        store.untrusted_reason ? [] : store.load_routes_raw
      rescue StandardError => e
        warn Colors.yellow("Could not read routes for tunnel cleanup: #{e.message}", io: $stderr)
        problems += 1
        []
      end
      routes.each do |route|
        if route.tailscale_https_port
          begin
            Share::Tailscale.unregister_tailscale(https_port: route.tailscale_https_port, funnel: route.tailscale_funnel)
            puts Colors.green("Removed tailscale serve on port #{route.tailscale_https_port}.")
          rescue StandardError => e
            warn Colors.yellow(e.message, io: $stderr)
            problems += 1
          end
        end
        Tunnel.stop_recorded(route, verify: true).each do |t|
          puts Colors.green("Stopped #{t[:label]} tunnel for #{route.hostname}.")
        end
      end

      warn Colors.yellow("Kept the CA in the trust store while proxy stop is unconfirmed.", io: $stderr) unless proxy_stopped
      preserve_proxy_runtime = !proxy_stopped
      outcome = CleanUtils.run_cleanup_steps(proxy_stopped ? CleanUtils::CLEANUP_STEP_ORDER : %w[files hosts], dirs,
                                             preserve_proxy_runtime)
      failed_ca_state_dirs = outcome[:failed_ca_state_dirs].dup
      state_failures = outcome[:state_failures]
      hosts_cleaned = outcome[:hosts_cleaned]

      retry_steps = []
      retry_steps << "ca" unless failed_ca_state_dirs.empty?
      retry_steps << "files" if !state_failures.empty? || !failed_ca_state_dirs.empty?
      retry_steps << "hosts" unless hosts_cleaned
      if !retry_steps.empty? && !Constants::WINDOWS && !Privilege.root?
        if CleanUtils.run_elevated_cleanup(retry_steps, dirs, preserve_proxy_runtime) == 0 # rubocop:disable Style/NumericPredicate
          failed_ca_state_dirs.clear
          state_failures = [] if retry_steps.include?("files")
          hosts_cleaned = true if retry_steps.include?("hosts")
        else
          failed_ca_state_dirs.reject! do |dir|
            CleanUtils.can_inspect_state_dir?(dir) && !Trust.trust_refresh_pending?(dir) && !Trust.trusted?(dir)
          end
          if retry_steps.include?("ca") || retry_steps.include?("files")
            state_failures = CleanUtils.remove_state_files_for_cleanup(dirs, failed_ca_state_dirs, preserve_proxy_runtime)
          end
          hosts_cleaned ||= Hosts.clean_hosts_file
        end
      end

      outcome[:ca_results].each do |dir, result|
        if failed_ca_state_dirs.include?(dir)
          problems += 1
          warn Colors.yellow("Could not remove CA from trust store: #{result[:error] || 'unknown error'}\n" \
                             "Delete the certificate manually, then rerun clean.", io: $stderr)
        else
          puts Colors.green("Removed local CA from the system trust store.")
        end
      end
      state_failures.each { |f| warn Colors.yellow("Could not remove state file: #{f}", io: $stderr) }
      problems += state_failures.length
      puts Colors.green("Removed rb-portless state files from known state directories.") if state_failures.empty?
      unless failed_ca_state_dirs.empty?
        warn Colors.yellow("Retained CA identity files so trust removal can be retried safely.", io: $stderr)
      end
      if hosts_cleaned
        puts Colors.green("Removed rb-portless entries from #{Hosts.hosts_display}.")
      else
        warn Colors.yellow("Could not remove rb-portless entries from #{Hosts.hosts_display}.", io: $stderr)
        problems += 1
      end

      if problems.positive?
        warn "Clean finished with #{problems} problem(s)."
        return 1
      end
      puts Colors.green("Clean finished.")
      0
    end

    def run_service_uninstall_with_sudo(reason)
      puts Colors.yellow("#{reason} Requesting sudo...")
      Privilege.run_sudo(Service.uninstall_sudo_args).success?
    end

    # ── doctor ────────────────────────────────────────────────────────────
    def handle_doctor(args)
      json = Args.parse_command_args("doctor", args[1..], { "--json" => :boolean }, 0).has?("--json")
      Doctor.new(json: json).run
    end

    def print_version
      puts VERSION
      0
    end

    def print_mcp_help = Mcp.print_help
  end
end
