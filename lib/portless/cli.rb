# frozen_string_literal: true

module Portless
  # Hand-rolled command dispatch (no Thor/optparse ceremony, like portless's
  # cli.ts). `rb-portless run <cmd>` is the main path; the rest manage the proxy,
  # CA trust, hosts file, and diagnostics.
  class CLI
    COMMANDS = %w[run proxy trust hosts list doctor clean prune alias get service].freeze

    def self.start(argv = ARGV)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      first = @argv.first
      return print_version if %w[--version -v].include?(first)
      return print_help if @argv.empty? || %w[--help -h].include?(first)

      if COMMANDS.include?(first)
        return command_help(first) if %w[--help -h].include?(@argv[1])

        send("cmd_#{first}", rest(first))
      elsif first.start_with?("--")
        cmd_run(@argv)        # leading flags (incl. --name) → run mode
      else
        cmd_named(@argv)      # `rb-portless <name> <command…>` shorthand
      end
    rescue Portless::NonInteractiveError => e
      warn error_line(e.message)
      exit 2
    rescue Portless::Error => e
      warn error_line(e.message)
      exit 1
    end

    private

    # ── Commands ────────────────────────────────────────────────────────────
    def cmd_run(args)
      options, command = parse_run(args)
      if command.empty? && Config.load.apps.any?
        Multi.new.run # monorepo: portless.json `apps` map
      else
        Runner.new(command: command, options: options).run
      end
    end

    # `rb-portless <name> <command…>`: run the command under the hostname <name>
    # (portless's named-app shorthand). The first non-flag token is the name.
    def cmd_named(args)
      options, rest = parse_run(args)
      name = rest.shift
      if rest.empty?
        raise Error, "no command given — try `rb-portless run #{name}` or `rb-portless #{name} <command>`"
      end

      options[:name] = name
      Runner.new(command: rest, options: options).run
    end

    # Pull known flags out of the run args from anywhere before `--` (mirrors
    # portless's global-flag stripping), leaving the command to execute. Flags:
    # --lan/--ip, sharing (--ngrok/--tailscale/--funnel), --name, --force,
    # --app-port. Everything after `--` is the command verbatim.
    def parse_run(args)
      options = {}
      command = []
      i = 0
      while i < args.length
        case args[i]
        when "--"          then command.concat(args[i + 1..]); break
        when "--lan"       then options[:lan] = true
        when "--ip"        then options[:ip] = args[i += 1]
        when "--ngrok"     then options[:ngrok] = true
        when "--tailscale" then options[:tailscale] = true
        when "--funnel"    then options[:funnel] = true
        when "--force"     then options[:force] = true
        when "--name"      then options[:name] = args[i += 1]
        when "--app-port"  then options[:app_port] = parse_port!(args[i += 1], "--app-port")
        else command << args[i]
        end
        i += 1
      end
      [ options, command ]
    end

    def cmd_proxy(args)
      case args.first
      when "start"
        Daemon.start(tls: tls_flag(args), port: int_flag(args, "--port"), foreground: flag?("--foreground"))
      when "stop" then Daemon.stop
      when nil    then command_help("proxy")
      else invalid_action!("proxy start|stop")
      end
    end

    def cmd_trust(_args)
      if Trust.trusted?
        info "CA already trusted"
      else
        Trust.install!
        ok "local CA trusted"
      end
    end

    def cmd_list(_args)
      routes = RouteStore.new.routes
      return puts(Colors.dim("rb-portless: no active routes")) if routes.empty?

      routes.each do |r|
        tag = r.alias? ? "alias" : "pid #{r.pid}"
        puts "#{Colors.cyan(r.hostname.ljust(40))} → :#{r.port}  #{Colors.dim("(#{tag})")}"
        puts "    #{Colors.dim('↳ tailnet')} #{Colors.green(r.tailscale)}" if r.tailscale
        puts "    #{Colors.dim('↳ ngrok  ')} #{Colors.green(r.ngrok)}" if r.ngrok
      end
    end

    def cmd_hosts(args)
      case args.first
      when "sync"
        hostnames = RouteStore.new.routes.map(&:hostname).uniq
        with_hosts_write([ "hosts", "sync" ]) { Hosts.sync(hostnames) }
        ok "synced #{hostnames.size} host(s) to #{Hosts.file}"
      when "clean"
        with_hosts_write([ "hosts", "clean" ]) { Hosts.clean }
        ok "cleaned #{Hosts.file}"
      when nil then command_help("hosts")
      else invalid_action!("hosts sync|clean")
      end
    end

    def cmd_alias(args)
      if args.first == "--remove"
        name = args[1] or abort_usage("alias --remove <name>")
        host = hostname_for(name)
        raise Error, "no alias found for #{host}" unless RouteStore.new.remove(host, owner_pid: 0)
        ok "removed alias #{host}"
      else
        name, port = args.reject { |a| a.start_with?("--") }
        abort_usage("alias <name> <port> [--force]") unless name && port
        host = hostname_for(name)
        port = parse_port!(port, "port")
        RouteStore.new.add(hostname: host, port: port, pid: 0, force: args.include?("--force"))
        ok "#{host} → :#{port}"
      end
    end

    def cmd_get(args)
      worktree = !args.include?("--no-worktree")
      name = args.find { |a| !a.start_with?("--") } or abort_usage("get <name> [--no-worktree]")
      config = Config.load
      host = hostname_for(name)
      host = "#{config.worktree_prefix}.#{host}" if worktree && config.worktree_prefix
      puts "#{config.tls ? 'https' : 'http'}://#{host}"
    end

    def cmd_prune(args)
      force = args.include?("--force")
      pruned = RouteStore.new.prune
      killed = pruned.sum { |r| PortOwner.kill(r.port, force: force) }
      note = killed.positive? ? ", killed #{killed} orphan process(es)" : ""
      ok "pruned #{pruned.size} stale route(s)#{note}"
    end

    def cmd_clean(_args)
      Daemon.stop
      begin; Trust.uninstall!; rescue StandardError; end
      begin; with_hosts_write([ "hosts", "clean" ]) { Hosts.clean }; rescue StandardError; end
      require "fileutils"
      FileUtils.rm_rf(State.dir)
      ok "removed all state"
    end

    def cmd_doctor(args)
      extra = args.reject { |a| %w[--help -h].include?(a) }
      raise Error, "unknown argument #{extra.first.inspect}" unless extra.empty?

      port = Health.discover_port
      routes = RouteStore.new.routes
      report = [
        [ "Ruby >= 3.2", Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2"), RUBY_VERSION ],
        [ "state dir", File.directory?(State.dir), State.dir ],
        [ "proxy running", !port.nil?, port ? "on :#{port}" : "not running" ],
        [ "CA generated", File.exist?(State.ca_cert), nil ],
        [ "CA trusted", safe { Trust.trusted? }, safe { Trust.trusted? } ? nil : "run `rb-portless trust`" ],
        [ "routes", true, "#{routes.size} active" ]
      ]
      report.each do |label, pass, note|
        mark = pass ? Colors.green("✓") : Colors.red("✗")
        puts "  #{mark} #{label}#{note ? " — #{Colors.dim(note)}" : ''}"
      end
      exit 1 if report.any? { |_label, pass, _note| !pass }
    end

    def cmd_service(args)
      case args.first
      when "install" then Service.install(tls: tls_flag(args), port: int_flag(args, "--port"))
      when "uninstall" then Service.uninstall
      when "status" then Service.status
      when nil then command_help("service")
      else invalid_action!("service install|uninstall|status")
      end
    end

    # ── Shared helpers ────────────────────────────────────────────────────
    # /etc/hosts (and boot service) writes need root; retry once under sudo.
    def with_hosts_write(reexec_args)
      yield
    rescue Portless::Error
      raise if Privilege.root? || !Privilege.reexec_with_sudo(reexec_args)
    end

    def hostname_for(name)
      name.include?(".") ? name : "#{name}.#{Config.load.tld}"
    end

    def safe
      yield
    rescue StandardError
      false
    end

    def abort_usage(usage)
      warn error_line("usage: rb-portless #{usage}")
      exit 1
    end

    # An *unknown* sub-action is an error (exit 1); a bare subcommand prints its
    # help and exits 0 (handled by the `when nil` arms). Mirrors portless's
    # `exit(help || !args[1] ? 0 : 1)`.
    def invalid_action!(usage)
      warn error_line("usage: rb-portless #{usage}")
      exit 1
    end

    # ── Output (colour no-ops when not a TTY / NO_COLOR) ──────────────────
    def ok(msg)   = puts Colors.green("rb-portless: #{msg}")
    def info(msg) = puts "rb-portless: #{msg}"
    def error_line(msg) = Colors.red("rb-portless: #{msg}", io: $stderr)

    # ── Flag helpers ──────────────────────────────────────────────────────
    def tls_flag(args)
      return false if args.include?("--no-tls")

      true
    end

    def int_flag(args, name)
      i = args.index(name)
      i ? Integer(args[i + 1], exception: false) : nil
    end

    # Parse + validate a port in 1–65535, with a clean error (never a backtrace).
    def parse_port!(value, label)
      port = Integer(value.to_s, exception: false)
      raise Error, "invalid #{label} #{value.inspect} — must be 1-65535" unless port&.between?(1, 65_535)

      port
    end

    def rest(command)
      @argv.first == command ? @argv[1..] : @argv
    end

    def flag?(*names) = @argv.any? { |a| names.include?(a) }

    def print_version
      puts "rb-portless #{Portless::VERSION}"
    end

    def print_help
      puts <<~HELP
        #{Colors.bold("rb-portless #{Portless::VERSION}")} — named .localhost URLs for local dev

        #{Colors.blue('Usage:')}
          rb-portless run <command>        run a dev server through the proxy
          rb-portless run                  run the `apps` map, or the dev script
          rb-portless <name> <command>     run <command> at https://<name>.localhost
          rb-portless get <name>           print a service's URL (--no-worktree)
          rb-portless alias <name> <port>  static route for an unmanaged service
          rb-portless proxy start|stop     manage the proxy daemon
          rb-portless trust                trust the local CA (HTTPS)
          rb-portless hosts sync|clean     manage /etc/hosts (Safari fallback)
          rb-portless list                 show active routes
          rb-portless doctor               diagnose setup
          rb-portless clean | prune        tear down / reap orphans (--force kills)
          rb-portless service install      bind the privileged port at boot

        #{Colors.blue('run flags:')}
          --name <name>                    override the inferred hostname
          --app-port <n>                   fix the backend port (else auto)
          --force                          take over a route owned by another run
          --lan [--ip <addr>]              also serve on the LAN (<name>.local)
          --ngrok                          share publicly via ngrok
          --tailscale | --funnel           share via your tailnet / Funnel

        In a linked git worktree on a non-default branch, the branch name is
        prepended as a subdomain (auth.<name>.localhost). PORTLESS=0 runs the
        command directly without the proxy.

        HTTPS is the default (https://<name>.localhost). Config: portless.json.
      HELP
    end

    # Per-command help (`rb-portless <cmd> --help`, or a bare subcommand). Kept
    # as plain data so the renderer can colourise it for the terminal.
    HELP = {
      "run"     => { summary: "Run a dev server through the proxy.",
                     usage: [ "run <command>", "run   (the apps map, or bin/dev / bin/rails server)" ],
                     flags: [ [ "--name <name>", "override the inferred hostname" ],
                              [ "--app-port <n>", "fix the backend port (else auto)" ],
                              [ "--force", "take over a route held by another run" ],
                              [ "--lan [--ip <addr>]", "also serve on the LAN" ],
                              [ "--ngrok | --tailscale | --funnel", "share publicly" ] ],
                     example: "rb-portless run bin/dev" },
      "get"     => { summary: "Print a service's URL (for scripts / env vars).",
                     usage: [ "get <name> [--no-worktree]" ],
                     flags: [ [ "--no-worktree", "skip the git-worktree subdomain prefix" ] ],
                     example: "DB_URL=$(rb-portless get db)" },
      "alias"   => { summary: "Static route for a service portless doesn't manage.",
                     usage: [ "alias <name> <port> [--force]", "alias --remove <name>" ],
                     flags: [ [ "--force", "overwrite an existing route" ] ],
                     example: "rb-portless alias postgres 5432   # -> https://postgres.localhost" },
      "proxy"   => { summary: "Manage the proxy daemon.",
                     usage: [ "proxy start [--no-tls] [--port <n>]", "proxy stop" ] },
      "trust"   => { summary: "Trust the local CA so HTTPS works without warnings.",
                     usage: [ "trust" ] },
      "hosts"   => { summary: "Manage the /etc/hosts block (Safari / non-.localhost TLDs).",
                     usage: [ "hosts sync", "hosts clean" ] },
      "list"    => { summary: "Show active routes.", usage: [ "list" ] },
      "doctor"  => { summary: "Diagnose the setup (read-only).", usage: [ "doctor" ] },
      "clean"   => { summary: "Remove all state: stop proxy, untrust CA, clear routes & hosts.",
                     usage: [ "clean" ] },
      "prune"   => { summary: "Reap routes whose owner died; kill the orphaned dev server.",
                     usage: [ "prune [--force]" ],
                     flags: [ [ "--force", "SIGKILL the orphan instead of SIGTERM" ] ] },
      "service" => { summary: "Install the proxy as an OS startup service (binds 443 at boot).",
                     usage: [ "service install [--no-tls] [--port <n>]", "service uninstall", "service status" ] }
    }.freeze

    def command_help(name)
      h = HELP.fetch(name)
      out = [ "", "  #{Colors.bold("rb-portless #{name}")} — #{h[:summary]}", "", "  #{Colors.blue('Usage:')}" ]
      h[:usage].each { |u| out << "    #{Colors.cyan("rb-portless #{u}")}" }
      if h[:flags]
        out << "" << "  #{Colors.blue('Flags:')}"
        h[:flags].each { |flag, desc| out << "    #{Colors.cyan(flag.ljust(34))} #{desc}" }
      end
      out << "" << "  #{Colors.dim("Example: #{h[:example]}")}" if h[:example]
      out << ""
      puts out.join("\n")
    end
  end
end
