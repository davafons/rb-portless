# frozen_string_literal: true

module Portless
  # Hand-rolled command dispatch (no Thor/optparse ceremony, like portless's
  # cli.ts). `portless-rb run <cmd>` is the main path; the rest manage the proxy,
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
      return print_version if flag?("--version", "-v")
      return print_help if @argv.empty? || flag?("--help", "-h")

      command = @argv.first
      command = "run" unless COMMANDS.include?(command)
      send("cmd_#{command}", rest(command))
    rescue Portless::NonInteractiveError => e
      warn "portless-rb: #{e.message}"
      exit 2
    rescue Portless::Error => e
      warn "portless-rb: #{e.message}"
      exit 1
    end

    private

    # ── Commands ────────────────────────────────────────────────────────────
    def cmd_run(args)
      Runner.new(command: strip_flags(args)).run
    end

    def cmd_proxy(args)
      action = args.first
      case action
      when "start"
        Daemon.start(tls: tls_flag(args), port: int_flag(args, "--port"), foreground: flag?("--foreground"))
      when "stop"
        Daemon.stop
      else
        warn "usage: portless-rb proxy start|stop"
        exit 1
      end
    end

    def cmd_trust(_args)
      if Trust.trusted?
        puts "portless-rb: CA already trusted"
      else
        Trust.install!
        puts "portless-rb: local CA trusted"
      end
    end

    def cmd_list(_args)
      routes = RouteStore.new.routes
      if routes.empty?
        puts "portless-rb: no active routes"
      else
        routes.each { |r| puts format("%-40s → :%d", r.hostname, r.port) }
      end
    end

    def cmd_hosts(args)
      case args.first
      when "sync"
        hostnames = RouteStore.new.routes.map(&:hostname).uniq
        with_hosts_write([ "hosts", "sync" ]) { Hosts.sync(hostnames) }
        puts "portless-rb: synced #{hostnames.size} host(s) to #{Hosts.file}"
      when "clean"
        with_hosts_write([ "hosts", "clean" ]) { Hosts.clean }
        puts "portless-rb: cleaned #{Hosts.file}"
      else
        warn "usage: portless-rb hosts sync|clean"
        exit 1
      end
    end

    def cmd_alias(args)
      if args.first == "--remove"
        name = args[1] or abort_usage("alias --remove <name>")
        RouteStore.new.remove(hostname_for(name))
        puts "portless-rb: removed alias #{hostname_for(name)}"
      else
        name, port = args
        abort_usage("alias <name> <port>") unless name && port
        RouteStore.new.add(hostname: hostname_for(name), port: Integer(port), pid: 0, force: true)
        puts "portless-rb: #{hostname_for(name)} → :#{port}"
      end
    end

    def cmd_get(args)
      name = args.first or abort_usage("get <name>")
      config = Config.load
      puts "#{config.tls ? 'https' : 'http'}://#{hostname_for(name)}"
    end

    def cmd_prune(_args)
      store = RouteStore.new
      before = store.routes.size
      store.prune
      puts "portless-rb: pruned #{before - store.routes.size} stale route(s)"
    end

    def cmd_clean(_args)
      Daemon.stop
      begin; Trust.uninstall!; rescue StandardError; end
      begin; with_hosts_write([ "hosts", "clean" ]) { Hosts.clean }; rescue StandardError; end
      require "fileutils"
      FileUtils.rm_rf(State.dir)
      puts "portless-rb: removed all state"
    end

    def cmd_doctor(_args)
      port = Health.discover_port
      routes = RouteStore.new.routes
      report = [
        [ "Ruby >= 3.2", Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2"), RUBY_VERSION ],
        [ "state dir", File.directory?(State.dir), State.dir ],
        [ "proxy running", !port.nil?, port ? "on :#{port}" : "not running" ],
        [ "CA generated", File.exist?(State.ca_cert), nil ],
        [ "CA trusted", safe { Trust.trusted? }, Constants::MACOS ? nil : "macOS only for now" ],
        [ "routes", true, "#{routes.size} active" ]
      ]
      report.each do |label, ok, note|
        puts "  #{ok ? '✓' : '✗'} #{label}#{note ? " — #{note}" : ''}"
      end
    end

    def cmd_service(args)
      case args.first
      when "install" then Service.install(tls: tls_flag(args), port: int_flag(args, "--port"))
      when "uninstall" then Service.uninstall
      when "status" then Service.status
      else
        warn "usage: portless-rb service install|uninstall|status"
        exit 1
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
      warn "usage: portless-rb #{usage}"
      exit 1
    end

    # ── Flag helpers ──────────────────────────────────────────────────────
    def tls_flag(args)
      return false if args.include?("--no-tls")

      true
    end

    def int_flag(args, name)
      i = args.index(name)
      i ? Integer(args[i + 1], exception: false) : nil
    end

    def strip_flags(args)
      # everything after `run`, minus our own flags
      args.reject { |a| a.start_with?("--portless") }
    end

    def todo(name, desc, _args = nil)
      warn "portless-rb #{name}: #{desc} — not yet implemented (#{Portless::VERSION})"
      exit 1
    end

    def rest(command)
      @argv.first == command ? @argv[1..] : @argv
    end

    def flag?(*names) = @argv.any? { |a| names.include?(a) }

    def print_version
      puts "portless-rb #{Portless::VERSION}"
    end

    def print_help
      puts <<~HELP
        portless-rb #{Portless::VERSION} — named .localhost URLs for local dev

        Usage:
          portless-rb run <command>        run a dev server through the proxy
          portless-rb [<command>]          (bare) run the project's dev script
          portless-rb proxy start|stop     manage the proxy daemon
          portless-rb trust                trust the local CA (HTTPS)
          portless-rb hosts sync|clean     manage /etc/hosts (Safari fallback)
          portless-rb list                 show active routes
          portless-rb doctor               diagnose setup
          portless-rb clean | prune        tear down / reap orphans
          portless-rb service install      bind the privileged port at boot

        HTTPS is the default (https://<name>.localhost). Config: portless.json.
      HELP
    end
  end
end
