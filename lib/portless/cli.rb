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

    def cmd_hosts(args)    = todo("hosts", "sync|clean /etc/hosts entries", args)
    def cmd_doctor(_args)  = todo("doctor", "health checks")
    def cmd_clean(_args)   = todo("clean", "stop proxy, untrust CA, remove state")
    def cmd_prune(_args)   = todo("prune", "kill orphaned dev servers")
    def cmd_alias(args)    = todo("alias", "static <name> <port> route", args)
    def cmd_get(args)      = todo("get", "print a name's URL", args)
    def cmd_service(args)  = todo("service", "install|uninstall boot service", args)

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
